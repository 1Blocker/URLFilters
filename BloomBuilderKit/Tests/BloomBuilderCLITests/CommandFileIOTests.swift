import Foundation
import XCTest

@testable import BloomBuilderCLI

final class CommandFileIOTests: XCTestCase {
  private let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "CommandFileIOTests-\(UUID().uuidString)",
    isDirectory: true
  )

  override func setUpWithError() throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try FileManager.default.removeItem(at: directory)
  }

  func testFillFailureRemovesIncompleteOutputAndPropagatesOriginalError() throws {
    let output = directory.appendingPathComponent("filter.bin")
    let entries = try directoryEntries()
    let partialBytes: [UInt8] = [0x31, 0x42, 0x53]

    XCTAssertThrowsError(try CommandFileIO.createNewFile(at: output.path) { descriptor in
      try partialBytes.withUnsafeBytes { bytes in
        try CommandFileIO.writeAll(bytes, to: descriptor)
      }
      XCTAssertEqual(Array(try Data(contentsOf: output)), partialBytes)
      XCTAssertEqual(try directoryEntries(), (entries + [output.lastPathComponent]).sorted())
      throw FillFailure.injected
    }) { error in
      XCTAssertEqual(error as? FillFailure, .injected)
    }

    XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    XCTAssertEqual(try directoryEntries(), entries)
  }

  func testRemovalFailureReportsBothFailuresInOneDiagnostic() throws {
    let output = directory.appendingPathComponent("filter.bin")

    XCTAssertThrowsError(try CommandFileIO.createNewFile(at: output.path) { descriptor in
      try CommandFileIO.writeText("partial", to: descriptor)
      // Replacing the file with a directory makes unlink fail without permissions.
      try FileManager.default.removeItem(at: output)
      try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
      throw FillFailure.injected
    }) { error in
      guard let failure = error as? OutputCleanupFailure else {
        return XCTFail("Expected OutputCleanupFailure, got \(error)")
      }
      XCTAssertEqual(failure.originalFailure as? FillFailure, .injected)
      XCTAssertNotEqual(failure.removalFailure.code, 0)
      XCTAssertEqual(
        failure.removalFailure.operation,
        "incomplete output could not be removed"
      )
      XCTAssertEqual(
        failure.description,
        "\(FillFailure.injected); \(failure.removalFailure)"
      )
      let result = CommandResult(.failed(BloomBuildError.outputWrite(
        path: output.path,
        reason: failure.description
      )))
      XCTAssertEqual(result.exitStatus, 1)
      XCTAssertEqual(result.standardError.filter(\.isNewline).count, 1)
      XCTAssertTrue(result.standardError.contains(failure.description))
    }
    XCTAssertEqual(try directoryEntries(), [output.lastPathComponent])
  }

  private func directoryEntries() throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
  }

  private enum FillFailure: Error, Equatable {
    case injected
  }
}
