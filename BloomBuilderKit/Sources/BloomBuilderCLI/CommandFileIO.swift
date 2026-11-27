#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif

struct SystemCallFailure: Error, CustomStringConvertible {
  let operation: String
  let code: Int32

  var description: String {
    "\(operation): \(String(cString: strerror(code))) (errno \(code))"
  }
}

enum CommandFileIOError: Error {
  case destinationExists
}

struct OutputCleanupFailure: Error, CustomStringConvertible {
  let originalFailure: any Error
  let removalFailure: SystemCallFailure

  var description: String {
    "\(originalFailure); \(removalFailure)"
  }
}

enum CommandFileIO {
  static func writeNewFile(_ bytes: UnsafeRawBufferPointer, to outputPath: String) throws {
    try createNewFile(at: outputPath) { descriptor in
      try writeAll(bytes, to: descriptor)
      while fsync(descriptor) != 0 {
        let code = errno
        if code != EINTR {
          throw SystemCallFailure(operation: "flush output", code: code)
        }
      }
    }
  }

  static func createNewFile(
    at outputPath: String,
    body: (Int32) throws -> Void
  ) throws {
    let descriptor = open(outputPath, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o666))
    guard descriptor >= 0 else {
      let code = errno
      if code == EEXIST {
        throw CommandFileIOError.destinationExists
      }
      throw SystemCallFailure(operation: "create output", code: code)
    }

    var needsClose = true
    do {
      try body(descriptor)
      // Do not retry close: on Linux an interrupted close may release the fd.
      needsClose = false
      guard close(descriptor) == 0 else {
        throw SystemCallFailure(operation: "close output", code: errno)
      }
    } catch {
      if needsClose {
        _ = close(descriptor)
      }
      guard unlink(outputPath) == 0 else {
        throw OutputCleanupFailure(
          originalFailure: error,
          removalFailure: SystemCallFailure(
            operation: "incomplete output could not be removed",
            code: errno
          )
        )
      }
      throw error
    }
  }

  static func writeAll(_ bytes: UnsafeRawBufferPointer, to descriptor: Int32) throws {
    guard let baseAddress = bytes.baseAddress else {
      return
    }
    var offset = 0
    while offset < bytes.count {
      let count = write(descriptor, baseAddress.advanced(by: offset), bytes.count - offset)
      if count < 0 {
        let code = errno
        if code == EINTR {
          continue
        }
        throw SystemCallFailure(operation: "write", code: code)
      }
      guard count > 0 else {
        throw SystemCallFailure(operation: "write made no progress", code: EIO)
      }
      offset += count
    }
  }

  static func writeText(_ text: String, to descriptor: Int32) throws {
    try Array(text.utf8).withUnsafeBytes { bytes in
      try writeAll(bytes, to: descriptor)
    }
  }
}
