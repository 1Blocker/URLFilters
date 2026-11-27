import BloomBuilderKit
import Foundation

enum BloomBuildError: Error, Equatable, CustomStringConvertible {
  case inputRead(path: String, reason: String)
  case invalidKeys(path: String, reason: BloomFilterKeyFileError)
  case destinationExists(path: String)
  case outputWrite(path: String, reason: String)

  var description: String {
    switch self {
    case .inputRead(let path, let reason):
      return "\(String(reflecting: path)): cannot read input: \(reason)"
    case .invalidKeys(let path, .missingFinalLineFeed):
      return "\(String(reflecting: path)): missing final LF"
    case .invalidKeys(let path, .emptyLine(let lineNumber)):
      return "\(String(reflecting: path)): empty line at line \(lineNumber)"
    case .invalidKeys(let path, .carriageReturn(let lineNumber, let byteOffset)):
      return "\(String(reflecting: path)): CR at line \(lineNumber), "
        + "byte offset \(byteOffset) (zero-based)"
    case .destinationExists(let path):
      return "\(String(reflecting: path)): destination already exists; it is never replaced"
    case .outputWrite(let path, let reason):
      return "\(String(reflecting: path)): cannot write output: \(reason)"
    }
  }
}

struct BloomBuildSummary: Equatable {
  let outputPath: String
  let byteCount: Int
  let inputFileCount: Int
}

enum BloomBuild {
  static func run(_ invocation: BuildInvocation) throws -> BloomBuildSummary {
    var filter = BloomFilter(parameters: invocation.parameters)

    for path in invocation.inputPaths {
      let bytes: Data
      do {
        bytes = try Data(
          contentsOf: URL(fileURLWithPath: path),
          options: [.alwaysMapped]
        )
      } catch {
        throw BloomBuildError.inputRead(path: path, reason: error.localizedDescription)
      }

      do {
        try filter.insertLFDelimitedKeys(from: bytes)
      } catch let error as BloomFilterKeyFileError {
        throw BloomBuildError.invalidKeys(path: path, reason: error)
      }
    }

    do {
      try filter.withUnsafeBitVectorBytes { bytes in
        try CommandFileIO.writeNewFile(bytes, to: invocation.outputPath)
      }
    } catch CommandFileIOError.destinationExists {
      throw BloomBuildError.destinationExists(path: invocation.outputPath)
    } catch {
      throw BloomBuildError.outputWrite(
        path: invocation.outputPath,
        reason: String(describing: error)
      )
    }

    return BloomBuildSummary(
      outputPath: invocation.outputPath,
      byteCount: invocation.parameters.byteCount,
      inputFileCount: invocation.inputPaths.count
    )
  }
}
