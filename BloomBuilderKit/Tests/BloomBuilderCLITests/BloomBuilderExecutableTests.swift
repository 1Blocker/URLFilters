import BloomBuilderKit
import Foundation
import XCTest

final class BloomBuilderExecutableTests: XCTestCase {
  private let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "BloomBuilderExecutableTests-\(UUID().uuidString)",
    isDirectory: true
  )

  override func setUpWithError() throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try FileManager.default.removeItem(at: directory)
  }

  func testSuccessfulBuildMatchesLibraryBytes() throws {
    let inputBytes = [
      Array("marigold.example\nzinnia.example/petal\n".utf8),
      Array("zinnia.example/petal\ncosmos.example\n".utf8),
    ]
    let inputs = try inputBytes.enumerated().map { index, bytes in
      try writeInput(bytes, name: "input-\(index).keys")
    }
    let parameters = try BloomFilterParameters(
      bitCount: 73,
      hashCount: 5,
      murmurSeed: .max
    )
    var expected = BloomFilter(parameters: parameters)
    for bytes in inputBytes {
      try expected.insertLFDelimitedKeys(from: bytes)
    }
    let output = directory.appendingPathComponent("filter.bin")
    let entries = try directoryEntries()

    let result = try run([
      "--bit-count", "73", "--hash-count", "5", "--murmur-seed", "4294967295",
      "--output", output.path,
    ] + inputs.map(\.path))

    XCTAssertEqual(result.reason, .exit)
    XCTAssertEqual(result.status, 0)
    XCTAssertEqual(result.standardError, "")
    XCTAssertFalse(result.standardOutput.isEmpty)
    XCTAssertEqual(Array(try Data(contentsOf: output)), expected.bitVector)
    XCTAssertEqual(try directoryEntries(), (entries + [output.lastPathComponent]).sorted())
  }

  func testUnwritableStandardOutputPreservesSuccessfulBuild() throws {
    let inputBytes = Array("amaranth.example\nsalvia.example/path\n".utf8)
    let input = try writeInput(inputBytes, name: "input.keys")
    let output = directory.appendingPathComponent("filter.bin")
    let entries = try directoryEntries()
    let readOnlyOutput = try FileHandle(forReadingFrom: input)
    defer {
      readOnlyOutput.closeFile()
    }
    var expected = BloomFilter(
      parameters: try BloomFilterParameters(bitCount: 37, hashCount: 5, murmurSeed: 42)
    )
    try expected.insertLFDelimitedKeys(from: inputBytes)

    let result = try run([
      "--bit-count", "37", "--hash-count", "5", "--murmur-seed", "42",
      "--output", output.path, input.path,
    ], outputHandle: readOnlyOutput)

    XCTAssertEqual(result.reason, .exit)
    XCTAssertEqual(result.status, 0)
    XCTAssertEqual(result.standardError, "")
    XCTAssertEqual(Array(try Data(contentsOf: output)), expected.bitVector)
    XCTAssertEqual(Array(try Data(contentsOf: input)), inputBytes)
    XCTAssertEqual(try directoryEntries(), (entries + [output.lastPathComponent]).sorted())
  }

  func testRejectedLaterInputReportsDiagnosticWithoutCreatingOutput() throws {
    let valid = try writeInput(Array("poppy.example\n".utf8), name: "valid.keys")
    let invalid = try writeInput(Array("iris\npe\rtal\n".utf8), name: "invalid.keys")
    let output = directory.appendingPathComponent("filter.bin")
    let entries = try directoryEntries()

    let result = try run([
      "--bit-count", "73", "--hash-count", "5", "--murmur-seed", "0",
      "--output", output.path, valid.path, invalid.path,
    ])

    XCTAssertEqual(result.reason, .exit)
    XCTAssertEqual(result.status, 1)
    XCTAssertEqual(result.standardOutput, "")
    XCTAssertEqual(
      result.standardError,
      "bloombuilder: \(String(reflecting: invalid.path)): "
        + "CR at line 2, byte offset 7 (zero-based)\n"
    )
    XCTAssertEqual(try directoryEntries(), entries)
  }

  func testHelpPrintsUsageWithoutCreatingFiles() throws {
    let entries = try directoryEntries()

    let result = try run(["--help"])

    XCTAssertEqual(result.reason, .exit)
    XCTAssertEqual(result.status, 0)
    XCTAssertEqual(result.standardError, "")
    XCTAssertTrue(result.standardOutput.hasPrefix("Usage: bloombuilder "))
    for option in ["--bit-count", "--hash-count", "--murmur-seed", "--output", "--help"] {
      XCTAssertTrue(result.standardOutput.contains(option))
    }
    XCTAssertTrue(result.standardOutput.contains("<key-file>..."))
    XCTAssertEqual(try directoryEntries(), entries)
  }

  private func executableURL() throws -> URL {
    #if os(macOS)
      let bundle = try XCTUnwrap(
        Bundle.allBundles.first { $0.bundleURL.pathExtension == "xctest" },
        "Cannot locate the loaded .xctest bundle in Bundle.allBundles"
      )
      let products = bundle.bundleURL.deletingLastPathComponent()
    #else
      let products = Bundle.main.bundleURL
    #endif
    let executable = products.appendingPathComponent("bloombuilder")
    return try XCTUnwrap(
      FileManager.default.isExecutableFile(atPath: executable.path) ? executable : nil,
      "Built bloombuilder executable was not found at \(executable.path)"
    )
  }

  private func run(
    _ arguments: [String],
    outputHandle: FileHandle? = nil
  ) throws -> ProcessResult {
    let process = Process()
    process.executableURL = try executableURL()
    process.arguments = arguments
    let output = outputHandle == nil ? Pipe() : nil
    let diagnostics = Pipe()
    if let outputHandle {
      process.standardOutput = outputHandle
    } else if let output {
      process.standardOutput = output
    }
    process.standardError = diagnostics
    defer {
      output?.fileHandleForReading.closeFile()
      output?.fileHandleForWriting.closeFile()
      diagnostics.fileHandleForReading.closeFile()
      diagnostics.fileHandleForWriting.closeFile()
    }

    try process.run()
    // These invocations emit only a short summary, usage text, or diagnostic.
    // Drain captured pipes before waiting so their buffers cannot block exit.
    let standardOutput = output?.fileHandleForReading.readDataToEndOfFile() ?? Data()
    let standardError = diagnostics.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    return ProcessResult(
      status: process.terminationStatus,
      reason: process.terminationReason,
      standardOutput: String(decoding: standardOutput, as: UTF8.self),
      standardError: String(decoding: standardError, as: UTF8.self)
    )
  }

  private func writeInput(_ bytes: [UInt8], name: String) throws -> URL {
    let input = directory.appendingPathComponent(name)
    try Data(bytes).write(to: input)
    return input
  }

  private func directoryEntries() throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
  }

  private struct ProcessResult {
    let status: Int32
    let reason: Process.TerminationReason
    let standardOutput: String
    let standardError: String
  }
}
