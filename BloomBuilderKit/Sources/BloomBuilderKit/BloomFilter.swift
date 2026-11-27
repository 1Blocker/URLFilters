/// Errors produced when deserializing a Bloom-filter bit vector.
public enum BloomFilterSerializationError: Error, Equatable, Sendable {
  /// The byte count did not equal `ceil(bitCount / 8)`.
  case incorrectByteCount(expected: Int, actual: Int)

  /// At least one unused high bit in the final byte was nonzero.
  case nonzeroTrailingBits(lastByte: UInt8, allowedMask: UInt8)
}

/// Errors produced when combining Bloom filters.
public enum BloomFilterUnionError: Error, Equatable, Sendable {
  /// The source filter's bit count, hash count, or MurmurHash3 seed differed.
  case parameterMismatch(
    expected: BloomFilterParameters,
    actual: BloomFilterParameters
  )
}

/// Errors produced while ingesting LF-delimited raw keys.
public enum BloomFilterKeyFileError: Error, Equatable, Sendable {
  /// The final nonempty key was not terminated by an LF byte (`0x0a`).
  case missingFinalLineFeed

  /// A one-based line number contained no key bytes before its LF delimiter.
  case emptyLine(lineNumber: Int)

  /// A CR byte (`0x0d`) occurred at a one-based line and zero-based byte offset.
  case carriageReturn(lineNumber: Int, byteOffset: Int)
}

/// A mutable Bloom filter compatible with Apple's NEURLFilter prefilter
/// hashing and LSB-first bit-packing rules.
public struct BloomFilter: Sendable {
  /// The parameters used to hash keys and address the bit vector.
  public let parameters: BloomFilterParameters

  /// The packed bit vector containing exactly `ceil(bitCount / 8)` bytes.
  ///
  /// Bit zero in each byte is stored in its least-significant bit. Unused high
  /// bits in the final byte are always zero.
  public var bitVector: [UInt8] {
    bits
  }

  /// Calls `body` with a borrowed raw view of the packed bit vector.
  ///
  /// The bytes are identical to ``bitVector`` but are lent without copying,
  /// so writing them out does not allocate a second vector-sized buffer. The
  /// pointer is valid only until `body` returns and must not escape.
  ///
  /// - Parameter body: A closure receiving the packed bytes.
  /// - Returns: The value returned by `body`.
  public func withUnsafeBitVectorBytes<Result>(
    _ body: (UnsafeRawBufferPointer) throws -> Result
  ) rethrows -> Result {
    try bits.withUnsafeBytes(body)
  }

  private var bits: [UInt8]

  /// Creates an empty filter whose entire bit vector is zero.
  ///
  /// - Parameter parameters: Validated bit count, hash count, and MurmurHash3
  ///   seed.
  public init(parameters: BloomFilterParameters) {
    self.parameters = parameters
    bits = [UInt8](repeating: 0, count: parameters.byteCount)
  }

  /// Deserializes a strict packed bit vector.
  ///
  /// The byte count must equal `ceil(bitCount / 8)`. When `bitCount` is not a
  /// multiple of eight, unused high bits in the final byte must all be zero.
  ///
  /// - Parameters:
  ///   - parameters: Validated bit count, hash count, and MurmurHash3 seed.
  ///   - bytes: LSB-first packed bytes to copy into the filter.
  /// - Throws: ``BloomFilterSerializationError`` for a wrong byte count or
  ///   nonzero trailing padding.
  public init(
    parameters: BloomFilterParameters,
    bytes: some Collection<UInt8>
  ) throws {
    guard bytes.count == parameters.byteCount else {
      throw BloomFilterSerializationError.incorrectByteCount(
        expected: parameters.byteCount,
        actual: bytes.count
      )
    }

    let bits = Array(bytes)
    let allowedMask = Self.allowedLastByteMask(for: parameters.bitCount)
    if let lastByte = bits.last, lastByte & ~allowedMask != 0 {
      throw BloomFilterSerializationError.nonzeroTrailingBits(
        lastByte: lastByte,
        allowedMask: allowedMask
      )
    }

    self.parameters = parameters
    self.bits = bits
  }

  /// Inserts a key's raw bytes by setting every double-hash probe bit.
  ///
  /// Probe arithmetic wraps at 32 bits. The key must be a multi-pass
  /// `Collection` because FNV-1a and MurmurHash3 each traverse it.
  ///
  /// - Parameter key: The raw bytes of one key.
  public mutating func insert(_ key: some Collection<UInt8>) {
    let firstHash = FNV1a.hash(key)
    let secondHash = MurmurHash3.hash(key, seed: parameters.murmurSeed)

    for probeIndex in 0..<parameters.hashCount {
      let position = (firstHash &+ (probeIndex &* secondHash)) % parameters.bitCount
      let byteIndex = Int(position >> 3)
      let bitMask = UInt8(1) << Int(position & 7)
      bits[byteIndex] |= bitMask
    }

    clearTrailingBits()
  }

  /// Returns whether every probe bit for a key is set.
  ///
  /// A `false` result is definitive; a `true` result can be a false positive.
  /// Probe arithmetic wraps at 32 bits. The key must be a multi-pass
  /// `Collection` because FNV-1a and MurmurHash3 each traverse it.
  ///
  /// - Parameter key: The raw bytes of one key.
  /// - Returns: `true` when all addressed bits are set.
  public func mayContain(_ key: some Collection<UInt8>) -> Bool {
    let firstHash = FNV1a.hash(key)
    let secondHash = MurmurHash3.hash(key, seed: parameters.murmurSeed)

    for probeIndex in 0..<parameters.hashCount {
      let position = (firstHash &+ (probeIndex &* secondHash)) % parameters.bitCount
      let byteIndex = Int(position >> 3)
      let bitMask = UInt8(1) << Int(position & 7)

      if bits[byteIndex] & bitMask == 0 {
        return false
      }
    }

    return true
  }

  /// Forms the bitwise union with a filter using exactly the same parameters.
  ///
  /// - Parameter other: The filter whose bits should be added.
  /// - Throws: ``BloomFilterUnionError`` if any parameter differs.
  public mutating func formUnion(_ other: Self) throws {
    guard parameters == other.parameters else {
      throw BloomFilterUnionError.parameterMismatch(
        expected: parameters,
        actual: other.parameters
      )
    }

    for index in bits.indices {
      bits[index] |= other.bits[index]
    }

    clearTrailingBits()
  }

  /// Inserts raw keys from a strict LF-delimited byte collection.
  ///
  /// Every nonempty key must end in one LF byte (`0x0a`), including the final
  /// key. Empty lines and CR bytes (`0x0d`) are rejected. An empty collection
  /// contains zero keys and is valid. Validation completes before mutation, so
  /// malformed input leaves the filter unchanged. Duplicate records are each
  /// included in the returned count.
  ///
  /// Collections with contiguous storage take a specialized scan. In
  /// memory-constrained processes, supply file-mapped storage such as
  /// `Data(contentsOf: url, options: [.alwaysMapped])`: mapped input uses the
  /// specialized scan while its pages stay clean and file-backed, keeping the
  /// physical footprint of ingestion near the filter's own size.
  ///
  /// - Parameter fileBytes: Raw file bytes; delimiters are not part of keys.
  /// - Returns: The number of LF-terminated key records inserted.
  /// - Throws: ``BloomFilterKeyFileError`` when the input is malformed.
  @discardableResult
  public mutating func insertLFDelimitedKeys(
    from fileBytes: some Collection<UInt8>
  ) throws -> Int {
    if let insertedKeyCount = try fileBytes.withContiguousStorageIfAvailable({
      try Self.validateLFDelimitedKeysContiguous($0)
      return insertLFDelimitedKeysContiguous($0)
    }) {
      return insertedKeyCount
    }

    try Self.validateLFDelimitedKeysGeneric(fileBytes)
    return insertLFDelimitedKeysGeneric(fileBytes)
  }

  private mutating func insertLFDelimitedKeysContiguous(
    _ fileBytes: UnsafeBufferPointer<UInt8>
  ) -> Int {
    var insertedKeyCount = 0
    var lineStart = 0

    for index in fileBytes.indices where fileBytes[index] == 0x0a {
      let keyBytes = UnsafeBufferPointer(
        rebasing: fileBytes[lineStart..<index]
      )
      insert(keyBytes)
      insertedKeyCount += 1
      lineStart = index + 1
    }

    return insertedKeyCount
  }

  private mutating func insertLFDelimitedKeysGeneric(
    _ fileBytes: some Collection<UInt8>
  ) -> Int {
    var insertedKeyCount = 0
    var lineStart = fileBytes.startIndex
    var index = lineStart

    while index != fileBytes.endIndex {
      let nextIndex = fileBytes.index(after: index)

      if fileBytes[index] == 0x0a {
        insert(fileBytes[lineStart..<index])
        insertedKeyCount += 1
        lineStart = nextIndex
      }

      index = nextIndex
    }

    return insertedKeyCount
  }

  private static func validateLFDelimitedKeysContiguous(
    _ fileBytes: UnsafeBufferPointer<UInt8>
  ) throws {
    var lineNumber = 1
    var lineIsEmpty = true

    for byteOffset in fileBytes.indices {
      let byte = fileBytes[byteOffset]

      if byte == 0x0d {
        throw BloomFilterKeyFileError.carriageReturn(
          lineNumber: lineNumber,
          byteOffset: byteOffset
        )
      }

      if byte == 0x0a {
        guard !lineIsEmpty else {
          throw BloomFilterKeyFileError.emptyLine(lineNumber: lineNumber)
        }

        lineNumber += 1
        lineIsEmpty = true
      } else {
        lineIsEmpty = false
      }
    }

    guard lineIsEmpty else {
      throw BloomFilterKeyFileError.missingFinalLineFeed
    }
  }

  private static func validateLFDelimitedKeysGeneric(
    _ fileBytes: some Collection<UInt8>
  ) throws {
    var byteOffset = 0
    var lineNumber = 1
    var lineIsEmpty = true

    for byte in fileBytes {
      if byte == 0x0d {
        throw BloomFilterKeyFileError.carriageReturn(
          lineNumber: lineNumber,
          byteOffset: byteOffset
        )
      }

      if byte == 0x0a {
        guard !lineIsEmpty else {
          throw BloomFilterKeyFileError.emptyLine(lineNumber: lineNumber)
        }

        lineNumber += 1
        lineIsEmpty = true
      } else {
        lineIsEmpty = false
      }

      byteOffset += 1
    }

    guard lineIsEmpty else {
      throw BloomFilterKeyFileError.missingFinalLineFeed
    }
  }

  private static func allowedLastByteMask(for bitCount: UInt32) -> UInt8 {
    let usedBitCount = Int(bitCount & 7)

    if usedBitCount == 0 {
      return .max
    }

    return UInt8.max >> (8 - usedBitCount)
  }

  private mutating func clearTrailingBits() {
    bits[bits.index(before: bits.endIndex)] &= Self.allowedLastByteMask(
      for: parameters.bitCount
    )
  }
}
