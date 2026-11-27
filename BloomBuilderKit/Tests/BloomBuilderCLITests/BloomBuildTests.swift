import Foundation
import XCTest

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif

@testable import BloomBuilderCLI
@testable import BloomBuilderKit
@testable import BloomBuilderTestSupport

final class BloomBuildTests: XCTestCase {
  private let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "BloomBuildTests-\(UUID().uuidString)",
    isDirectory: true
  )

  override func setUpWithError() throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try FileManager.default.removeItem(at: directory)
  }

  func testOutputMatchesLibraryWithAlignedAndUnalignedCountsAndExtremeSeeds() throws {
    let inputBytes = [
      Array("orchid.example\nfern.example/leaf\n".utf8),
      Array("moss.example\n".utf8),
    ]
    let inputs = try inputBytes.enumerated().map { index, bytes in
      try writeInput(bytes, name: "input-\(index).keys")
    }

    for bitCount: UInt32 in [64, 73] {
      for seed: UInt32 in [0, .max] {
        let parameters = try BloomFilterParameters(
          bitCount: bitCount,
          hashCount: 5,
          murmurSeed: seed
        )
        var expected = BloomFilter(parameters: parameters)
        for bytes in inputBytes {
          try expected.insertLFDelimitedKeys(from: bytes)
        }

        let actual = try build(
          inputs,
          parameters: parameters,
          name: "vector-\(bitCount)-\(seed).bin"
        )

        XCTAssertEqual(actual, expected.bitVector)
        XCTAssertEqual(actual.count, parameters.byteCount)
      }
    }
  }

  func testSmallExplicitFilterMatchesFrozenBitVector() throws {
    let input = try writeInput(
      Array("alpha.example\nbeta.example/path?query=1\ngamma.example\n".utf8)
    )
    let parameters = try BloomFilterParameters(bitCount: 37, hashCount: 5, murmurSeed: 0x1234_5678)

    XCTAssertEqual(try build([input], parameters: parameters), GoldenBitVectors.smallExplicit)
  }

  func testMediumFilterWithExplicitParametersMatchesFrozenBitVector() throws {
    let bytes = (0..<100).flatMap { Array("medium-key-\($0)\n".utf8) }
    let input = try writeInput(bytes)
    let parameters = try BloomFilterParameters(bitCount: 959, hashCount: 7, murmurSeed: 0xa5a5_5a5a)

    XCTAssertEqual(try build([input], parameters: parameters), GoldenBitVectors.sizedMedium)
  }

  func testOverlappingInputFilesMatchFrozenUnionBitVector() throws {
    let left = try writeInput(
      (0..<16).flatMap { Array("union-key-\($0)\n".utf8) },
      name: "left.keys"
    )
    let right = try writeInput(
      (10..<26).flatMap { Array("union-key-\($0)\n".utf8) },
      name: "right.keys"
    )
    let parameters = try BloomFilterParameters(bitCount: 257, hashCount: 6, murmurSeed: 0xcafe_babe)

    XCTAssertEqual(try build([left, right], parameters: parameters), GoldenBitVectors.union)
  }

  func testRawKeysPreserveInvalidUTF8NULAndSignificantWhitespace() throws {
    let keys: [[UInt8]] = [
      [0xff, 0x80, 0xc0],
      [0x00, 0x61, 0x00],
      Array("  willow.example \t".utf8),
      Array("willow.example".utf8),
      [0x20, 0x09, 0x20],
    ]
    let input = try writeInput(keys.flatMap { $0 + [0x0a] })
    let parameters = try BloomFilterParameters(bitCount: 1_031, hashCount: 7, murmurSeed: 42)
    var expected = BloomFilter(parameters: parameters)
    for key in keys {
      expected.insert(key)
    }

    XCTAssertEqual(try build([input], parameters: parameters), expected.bitVector)
  }

  func testReorderingInputsDoesNotChangeBytes() throws {
    let first = try writeInput(Array("oak.example\nash.example\n".utf8), name: "first.keys")
    let second = try writeInput(Array("ash.example\nelm.example\n".utf8), name: "second.keys")
    let parameters = try makeParameters()

    XCTAssertEqual(
      try build([first, second], parameters: parameters, name: "forward.bin"),
      try build([second, first], parameters: parameters, name: "reverse.bin")
    )
  }

  func testRepeatedInputPathDoesNotChangeBytes() throws {
    let input = try writeInput(Array("birch.example\nmaple.example\n".utf8))
    let parameters = try makeParameters()

    XCTAssertEqual(
      try build([input], parameters: parameters, name: "once.bin"),
      try build([input, input], parameters: parameters, name: "twice.bin")
    )
  }

  func testDuplicateKeysDoNotChangeBytes() throws {
    let distinct = try writeInput(
      Array("reed.example\nwillow.example\n".utf8),
      name: "distinct.keys"
    )
    let repeated = try writeInput(
      Array("willow.example\nreed.example\nreed.example\nwillow.example\n".utf8),
      name: "repeated.keys"
    )
    let parameters = try makeParameters()

    XCTAssertEqual(
      try build([distinct], parameters: parameters, name: "distinct.bin"),
      try build([repeated], parameters: parameters, name: "repeated.bin")
    )
  }

  func testEmptyInputProducesZeroVector() throws {
    let input = try writeInput([])
    let parameters = try makeParameters()

    XCTAssertEqual(
      try build([input], parameters: parameters),
      [UInt8](repeating: 0, count: parameters.byteCount)
    )
  }

  func testCommandBuildsFromParsedArguments() throws {
    let input = try writeInput(Array("lily.example\n".utf8))
    let output = directory.appendingPathComponent("command.bin")
    let entries = try directoryEntries()
    let result = BloomBuilderCommand.run(arguments: [
      "--bit-count", "9", "--hash-count", "3", "--murmur-seed", "0",
      "--output", output.path, input.path,
    ])
    var expected = BloomFilter(
      parameters: try BloomFilterParameters(bitCount: 9, hashCount: 3, murmurSeed: 0)
    )
    expected.insert("lily.example".utf8)

    XCTAssertEqual(result.exitStatus, 0)
    XCTAssertEqual(result.standardError, "")
    XCTAssertFalse(result.standardOutput.isEmpty)
    XCTAssertEqual(Array(try Data(contentsOf: output)), expected.bitVector)
    XCTAssertEqual(try directoryEntries(), (entries + [output.lastPathComponent]).sorted())
  }

  func testMissingFinalLFInFirstInputIsRejected() throws {
    try assertKeyRejection(
      "iris\npetal",
      detail: "missing final LF",
      afterValidInput: false
    )
  }

  func testMissingFinalLFInLaterInputIsRejected() throws {
    try assertKeyRejection(
      "iris\npetal",
      detail: "missing final LF",
      afterValidInput: true
    )
  }

  func testEmptyLineInFirstInputIsRejected() throws {
    try assertKeyRejection(
      "iris\n\npetal\n",
      detail: "empty line at line 2",
      afterValidInput: false
    )
  }

  func testEmptyLineInLaterInputIsRejected() throws {
    try assertKeyRejection(
      "iris\n\npetal\n",
      detail: "empty line at line 2",
      afterValidInput: true
    )
  }

  func testCarriageReturnInFirstInputIsRejected() throws {
    try assertKeyRejection(
      "iris\npe\rtal\n",
      detail: "CR at line 2, byte offset 7 (zero-based)",
      afterValidInput: false
    )
  }

  func testCarriageReturnInLaterInputIsRejected() throws {
    try assertKeyRejection(
      "iris\npe\rtal\n",
      detail: "CR at line 2, byte offset 7 (zero-based)",
      afterValidInput: true
    )
  }

  func testMissingInputPathIsRejected() throws {
    try assertInputReadFailure(directory.appendingPathComponent("missing.keys"))
  }

  func testInputDirectoryIsRejected() throws {
    let input = directory.appendingPathComponent("input-directory", isDirectory: true)
    try FileManager.default.createDirectory(at: input, withIntermediateDirectories: false)

    try assertInputReadFailure(input)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: input.path), [])
  }

  func testUnreadableInputIsRejected() throws {
    let input = try writeInput(Array("azalea.example\n".utf8))
    XCTAssertEqual(chmod(input.path, 0), 0)
    defer {
      XCTAssertEqual(chmod(input.path, 0o600), 0)
    }

    if (try? Data(contentsOf: input, options: [.alwaysMapped])) != nil {
      throw XCTSkip(
        "Cannot make input unreadable: this process can read a file with no permission bits "
          + "(for example, when running as root)."
      )
    }

    try assertInputReadFailure(input)
  }

  func testExistingOutputIsRefusedAndUnchanged() throws {
    let input = try writeInput(Array("spruce.example\n".utf8))
    let original: [UInt8] = [0x11, 0x22, 0x33]
    let output = try writeInput(original, name: "existing.bin")
    let invocation = try BuildInvocation(
      parameters: makeParameters(),
      outputPath: output.path,
      inputPaths: [input.path]
    )
    let entries = try directoryEntries()

    XCTAssertThrowsError(try BloomBuild.run(invocation)) { error in
      XCTAssertEqual(error as? BloomBuildError, .destinationExists(path: output.path))
    }
    XCTAssertEqual(try directoryEntries(), entries)
    try assertExistingDestinationIsRefused(output, input: input)
    XCTAssertEqual(Array(try Data(contentsOf: output)), original)
  }

  func testExistingOutputDirectoryIsRefusedAndUnchanged() throws {
    let input = try writeInput(Array("heather.example\n".utf8))
    let output = directory.appendingPathComponent("existing-directory", isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
    let child = output.appendingPathComponent("retained.bin")
    let original = Data([0x4a, 0x5b])
    try original.write(to: child)

    try assertExistingDestinationIsRefused(output, input: input)

    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: output.path),
      [child.lastPathComponent]
    )
    XCTAssertEqual(try Data(contentsOf: child), original)
  }

  func testExistingOutputSymlinkIsRefusedAndUnchanged() throws {
    let input = try writeInput(Array("clover.example\n".utf8))
    let original: [UInt8] = [0x61, 0x72, 0x83]
    let target = try writeInput(original, name: "target.bin")
    let output = directory.appendingPathComponent("linked.bin")
    let linkDestination = target.lastPathComponent
    try FileManager.default.createSymbolicLink(
      atPath: output.path,
      withDestinationPath: linkDestination
    )

    try assertExistingDestinationIsRefused(output, input: input)

    XCTAssertEqual(
      try FileManager.default.destinationOfSymbolicLink(atPath: output.path),
      linkDestination
    )
    XCTAssertEqual(Array(try Data(contentsOf: target)), original)
  }

  func testDanglingOutputSymlinkIsRefusedAndTargetRemainsAbsent() throws {
    let input = try writeInput(Array("violet.example\n".utf8))
    let target = directory.appendingPathComponent("absent-target.bin")
    let output = directory.appendingPathComponent("dangling.bin")
    let linkDestination = target.lastPathComponent
    try FileManager.default.createSymbolicLink(
      atPath: output.path,
      withDestinationPath: linkDestination
    )

    try assertExistingDestinationIsRefused(output, input: input)

    XCTAssertEqual(
      try FileManager.default.destinationOfSymbolicLink(atPath: output.path),
      linkDestination
    )
    XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
  }

  func testMissingDestinationDirectoryFailsWithoutCreatingAnything() throws {
    let input = try writeInput(Array("dahlia.example\n".utf8))
    let output = directory.appendingPathComponent("absent-directory/filter.bin")

    try assertRejected(
      [input],
      output: output,
      diagnostic: "\(String(reflecting: output.path)): "
        + "cannot write output: create output:",
      exactDiagnostic: false
    )
    XCTAssertFalse(FileManager.default.fileExists(atPath: output.deletingLastPathComponent().path))
  }

  private func assertKeyRejection(
    _ contents: String,
    detail: String,
    afterValidInput: Bool,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    let valid = try writeInput(Array("cedar.example\npine.example\n".utf8), name: "valid.keys")
    let invalid = try writeInput(Array(contents.utf8), name: "invalid.keys")
    let inputs = afterValidInput ? [valid, invalid] : [invalid, valid]

    try assertRejected(
      inputs,
      output: directory.appendingPathComponent("filter.bin"),
      diagnostic: "\(String(reflecting: invalid.path)): \(detail)",
      file: file,
      line: line
    )
  }

  private func assertInputReadFailure(
    _ input: URL,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    let valid = try writeInput(Array("aster.example\n".utf8), name: "valid.keys")
    for inputs in [[input], [valid, input]] {
      try assertRejected(
        inputs,
        output: directory.appendingPathComponent("filter.bin"),
        diagnostic: "\(String(reflecting: input.path)): cannot read input:",
        exactDiagnostic: false,
        file: file,
        line: line
      )
    }
  }

  private func assertExistingDestinationIsRefused(
    _ output: URL,
    input: URL,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    try assertRejected(
      [input],
      output: output,
      diagnostic: "\(String(reflecting: output.path)): "
        + "destination already exists; it is never replaced",
      file: file,
      line: line
    )
  }

  private func assertRejected(
    _ inputs: [URL],
    output: URL,
    diagnostic: String,
    exactDiagnostic: Bool = true,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    let entries = try directoryEntries()
    let result = BloomBuilderCommand.run(arguments: [
      "--bit-count", "257", "--hash-count", "6", "--murmur-seed", "0",
      "--output", output.path,
    ] + inputs.map(\.path))

    XCTAssertEqual(result.exitStatus, 1, file: file, line: line)
    XCTAssertEqual(result.standardOutput, "", file: file, line: line)
    XCTAssertEqual(result.standardError.filter(\.isNewline).count, 1, file: file, line: line)
    let expected = "bloombuilder: \(diagnostic)"
    if exactDiagnostic {
      XCTAssertEqual(result.standardError, expected + "\n", file: file, line: line)
    } else {
      XCTAssertTrue(
        result.standardError.hasPrefix(expected),
        result.standardError,
        file: file,
        line: line
      )
    }
    XCTAssertEqual(try directoryEntries(), entries, file: file, line: line)
  }

  private func directoryEntries() throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
  }

  private func writeInput(_ bytes: [UInt8], name: String = "input.keys") throws -> URL {
    let url = directory.appendingPathComponent(name)
    try Data(bytes).write(to: url)
    return url
  }

  private func makeParameters() throws -> BloomFilterParameters {
    try BloomFilterParameters(bitCount: 257, hashCount: 6, murmurSeed: 0)
  }

  private func build(
    _ inputs: [URL],
    parameters: BloomFilterParameters,
    name: String = "filter.bin"
  ) throws -> [UInt8] {
    let output = directory.appendingPathComponent(name)
    let invocation = try BuildInvocation(
      parameters: parameters,
      outputPath: output.path,
      inputPaths: inputs.map(\.path)
    )
    let entries = try directoryEntries()
    let summary = try BloomBuild.run(invocation)

    XCTAssertEqual(summary.outputPath, output.path)
    XCTAssertEqual(summary.byteCount, parameters.byteCount)
    XCTAssertEqual(summary.inputFileCount, inputs.count)
    XCTAssertEqual(try directoryEntries(), (entries + [output.lastPathComponent]).sorted())
    return Array(try Data(contentsOf: output))
  }
}
