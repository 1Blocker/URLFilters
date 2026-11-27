import Foundation
import XCTest

@testable import BloomBuilderCLI

final class CommandResultTests: XCTestCase {
  func testHelpReturnsUsageOnStandardOutput() {
    let result = BloomBuilderCommand.run(arguments: ["--help"])

    XCTAssertEqual(result.exitStatus, 0)
    XCTAssertEqual(result.standardOutput, CommandArguments.usage)
    XCTAssertEqual(result.standardError, "")
    XCTAssertTrue(
      result.standardOutput.contains("Exit status: 0 for success or help; 1 for every failure.")
    )
  }

  func testSuccessfulBuildReturnsInformationalSummaryOnStandardOutput() {
    let result = CommandResult(.built(BloomBuildSummary(
      outputPath: "vector.bin",
      byteCount: 33,
      inputFileCount: 2
    )))

    XCTAssertEqual(result.exitStatus, 0)
    XCTAssertEqual(result.standardError, "")
    XCTAssertTrue(result.standardOutput.contains("33 bytes"))
    XCTAssertTrue(result.standardOutput.contains("vector.bin"))
  }

  func testArgumentFailureReturnsOneDiagnosticOnStandardError() {
    let result = BloomBuilderCommand.run(arguments: [])

    XCTAssertEqual(result.exitStatus, 1)
    XCTAssertEqual(result.standardOutput, "")
    XCTAssertEqual(result.standardError, "bloombuilder: --bit-count: required option is missing\n")
  }

  func testFailureTextStaysOnOneLineWithUnusualPathsAndUnderlyingMessages() {
    let result = CommandResult(.failed(BloomBuildError.inputRead(
      path: "input\nname.keys",
      reason: "first line\r\nsecond line"
    )))

    XCTAssertEqual(result.exitStatus, 1)
    XCTAssertEqual(result.standardOutput, "")
    XCTAssertEqual(result.standardError.filter(\.isNewline).count, 1)
    XCTAssertTrue(result.standardError.contains("input\\nname.keys"))
    XCTAssertTrue(result.standardError.contains("first line second line"))
  }

  func testStandardOutputWriteFailureReportsStreamOnStandardError() {
    let output = Pipe()
    let diagnostics = Pipe()
    defer {
      output.fileHandleForReading.closeFile()
      output.fileHandleForWriting.closeFile()
      diagnostics.fileHandleForReading.closeFile()
    }

    let status = CommandResult(.help).write(
      to: output.fileHandleForReading.fileDescriptor,
      errorDescriptor: diagnostics.fileHandleForWriting.fileDescriptor
    )
    diagnostics.fileHandleForWriting.closeFile()
    let message = String(
      decoding: diagnostics.fileHandleForReading.readDataToEndOfFile(),
      as: UTF8.self
    )

    XCTAssertEqual(status, 1)
    XCTAssertTrue(
      message.hasPrefix("bloombuilder: stdout: cannot write standard stream: write:"),
      message
    )
    XCTAssertEqual(message.filter(\.isNewline).count, 1)
  }

  func testSummaryWriteFailurePreservesSuccessWithoutDiagnostic() {
    let output = Pipe()
    let diagnostics = Pipe()
    defer {
      output.fileHandleForReading.closeFile()
      output.fileHandleForWriting.closeFile()
      diagnostics.fileHandleForReading.closeFile()
    }
    let result = CommandResult(.built(BloomBuildSummary(
      outputPath: "vector.bin",
      byteCount: 33,
      inputFileCount: 2
    )))

    let status = result.write(
      to: output.fileHandleForReading.fileDescriptor,
      errorDescriptor: diagnostics.fileHandleForWriting.fileDescriptor
    )
    diagnostics.fileHandleForWriting.closeFile()
    let diagnostic = diagnostics.fileHandleForReading.readDataToEndOfFile()

    XCTAssertEqual(status, 0)
    XCTAssertTrue(diagnostic.isEmpty)
  }

  func testStandardErrorWriteFailureReturnsFailureStatus() {
    let pipe = Pipe()
    defer {
      pipe.fileHandleForReading.closeFile()
      pipe.fileHandleForWriting.closeFile()
    }
    let result = CommandResult(.failed(CommandArgumentError.missingInput))

    let status = result.write(
      to: pipe.fileHandleForWriting.fileDescriptor,
      errorDescriptor: pipe.fileHandleForReading.fileDescriptor
    )

    XCTAssertEqual(status, 1)
  }

  func testStandardStreamFailureDiagnosticNamesAffectedStream() {
    for name in ["stdout", "stderr"] {
      let result = CommandResult(.failed(
        CommandResultError.standardStreamWrite(name: name, reason: "synthetic write failure")
      ))

      XCTAssertEqual(result.exitStatus, 1)
      XCTAssertEqual(result.standardOutput, "")
      XCTAssertEqual(
        result.standardError,
        "bloombuilder: \(name): cannot write standard stream: synthetic write failure\n"
      )
    }
  }
}
