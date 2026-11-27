import XCTest

@testable import BloomBuilderCLI
@testable import BloomBuilderKit

final class CommandArgumentsTests: XCTestCase {
  private let validArguments = [
    "--bit-count", "37",
    "--hash-count", "5",
    "--murmur-seed", "305419896",
    "--output", "filter.bin",
    "first.keys", "second.keys",
  ]

  func testCompleteInvocationPreservesParametersAndPaths() throws {
    guard case .build(let invocation) = try CommandArguments.parse(validArguments) else {
      return XCTFail("Expected a build invocation")
    }

    XCTAssertEqual(invocation.parameters.bitCount, 37)
    XCTAssertEqual(invocation.parameters.hashCount, 5)
    XCTAssertEqual(invocation.parameters.murmurSeed, 305_419_896)
    XCTAssertEqual(invocation.outputPath, "filter.bin")
    XCTAssertEqual(invocation.inputPaths, ["first.keys", "second.keys"])
  }

  func testOptionsCanBeInterspersedWithInputs() throws {
    let arguments = [
      "first.keys", "--murmur-seed", "305419896",
      "--hash-count", "5", "second.keys",
      "--output", "filter.bin", "--bit-count", "37",
    ]

    XCTAssertEqual(
      try CommandArguments.parse(arguments),
      try CommandArguments.parse(validArguments)
    )
  }

  func testEqualsValuesAndTerminatorAllowDashPrefixedPaths() throws {
    let arguments = [
      "--bit-count=37", "--hash-count=5", "--murmur-seed=0",
      "--output=--vector.bin", "--", "-keys", "--help", "--output",
    ]
    guard case .build(let invocation) = try CommandArguments.parse(arguments) else {
      return XCTFail("Expected a build invocation")
    }

    XCTAssertEqual(invocation.outputPath, "--vector.bin")
    XCTAssertEqual(invocation.inputPaths, ["-keys", "--help", "--output"])
    XCTAssertEqual(invocation.parameters.murmurSeed, 0)
  }

  func testEveryRequiredOptionIsRequired() {
    for index in stride(from: 0, to: 8, by: 2) {
      var arguments = validArguments
      arguments.removeSubrange(index...index + 1)
      assertFailure(arguments, .missingOption(validArguments[index]))
    }
  }

  func testOptionRequiresAValueBeforeAnotherOptionOrEndOfArguments() {
    for option in ["--bit-count", "--hash-count", "--murmur-seed", "--output"] {
      assertFailure([option], .missingValue(option))
      assertFailure([option, "--output=filter.bin"], .missingValue(option))
    }
  }

  func testRepeatedOptionsAreRejectedIncludingMixedValueSyntax() {
    for index in stride(from: 0, to: 8, by: 2) {
      let option = validArguments[index]
      assertFailure(validArguments + [option, validArguments[index + 1]], .repeatedOption(option))
      assertFailure(
        validArguments + ["\(option)=\(validArguments[index + 1])"],
        .repeatedOption(option)
      )
    }
  }

  func testUnknownOptionsAreRejected() {
    for option in ["--unknown", "--version", "-h"] {
      assertFailure(validArguments + [option], .unknownOption(option))
    }
  }

  func testNumbersMustBeStrictASCIIDecimals() {
    let invalidValues = [
      "", "-1", "+1", " 1", "1 ", "1\t", "1\n", "0x10", "1_000", "1.0", "1e2", "١", "１",
    ]

    for index in [0, 2, 4] {
      for value in invalidValues {
        var arguments = validArguments
        arguments[index + 1] = value
        assertFailure(arguments, .invalidDecimal(option: validArguments[index], value: value))
      }
    }
  }

  func testNumbersBeyondUInt32AreRejected() {
    for index in [0, 2, 4] {
      for value in ["4294967296", "9999999999999999999999999999999999999999"] {
        var arguments = validArguments
        arguments[index + 1] = value
        assertFailure(arguments, .invalidDecimal(option: validArguments[index], value: value))
      }
    }
  }

  func testZeroCountsUseLibraryValidation() {
    var zeroBits = validArguments
    zeroBits[1] = "0"
    assertFailure(zeroBits, .invalidParameters(.bitCountMustBePositive))

    var zeroHashes = validArguments
    zeroHashes[3] = "0"
    assertFailure(zeroHashes, .invalidParameters(.hashCountMustBePositive))
  }

  func testZeroSeedAndLeadingZeroDecimalsAreAccepted() throws {
    var arguments = validArguments
    arguments[1] = "00037"
    arguments[3] = "005"
    arguments[5] = "000"
    guard case .build(let invocation) = try CommandArguments.parse(arguments) else {
      return XCTFail("Expected a build invocation")
    }

    XCTAssertEqual(invocation.parameters.bitCount, 37)
    XCTAssertEqual(invocation.parameters.hashCount, 5)
    XCTAssertEqual(invocation.parameters.murmurSeed, 0)
  }

  func testUInt32MaximumIsAcceptedForEveryNumericOption() throws {
    var arguments = validArguments
    for index in [1, 3, 5] {
      arguments[index] = "4294967295"
    }
    guard case .build(let invocation) = try CommandArguments.parse(arguments) else {
      return XCTFail("Expected a build invocation")
    }

    XCTAssertEqual(invocation.parameters.bitCount, .max)
    XCTAssertEqual(invocation.parameters.hashCount, .max)
    XCTAssertEqual(invocation.parameters.murmurSeed, .max)
  }

  func testAtLeastOneInputPathIsRequired() {
    assertFailure(Array(validArguments.prefix(8)), .missingInput)
    assertFailure(Array(validArguments.prefix(8)) + ["--"], .missingInput)
  }

  func testHelpDoesNotRequireBuildArguments() throws {
    XCTAssertEqual(try CommandArguments.parse(["--help"]), .help)
    XCTAssertEqual(try CommandArguments.parse(["--bit-count", "37", "--help"]), .help)
  }

  func testEmptyAndNULContainingPathsAreRejected() {
    for path in ["", "keys\0suffix"] {
      var arguments = validArguments
      arguments[7] = path
      assertFailure(arguments, .invalidPath(argument: "--output", path: path))

      arguments = validArguments
      arguments[8] = path
      assertFailure(arguments, .invalidPath(argument: "key-file", path: path))
    }
  }

  private func assertFailure(
    _ arguments: [String],
    _ expected: CommandArgumentError,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertThrowsError(try CommandArguments.parse(arguments), file: file, line: line) { error in
      XCTAssertEqual(error as? CommandArgumentError, expected, file: file, line: line)
    }
  }
}
