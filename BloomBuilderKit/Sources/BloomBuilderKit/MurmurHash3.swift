enum MurmurHash3 {
  private static let blockMultiplier: UInt32 = 0xcc9e_2d51
  private static let blockRotationMultiplier: UInt32 = 0x1b87_3593

  static func hash(_ bytes: some Collection<UInt8>, seed: UInt32) -> UInt32 {
    if let contiguousHash = bytes.withContiguousStorageIfAvailable({
      hashContiguous($0, seed: seed)
    }) {
      return contiguousHash
    }

    return hashGeneric(bytes, seed: seed)
  }

  private static func hashContiguous(
    _ bytes: UnsafeBufferPointer<UInt8>,
    seed: UInt32
  ) -> UInt32 {
    let byteCount = bytes.count
    let blockCount = byteCount / 4
    var hash = seed
    var index = 0

    for _ in 0..<blockCount {
      var block = UInt32(bytes[index])
      block |= UInt32(bytes[index + 1]) << 8
      block |= UInt32(bytes[index + 2]) << 16
      block |= UInt32(bytes[index + 3]) << 24
      index += 4

      hash ^= mix(block)
      hash = rotateLeft(hash, by: 13)
      hash = hash &* 5
      hash = hash &+ 0xe654_6b64
    }

    let tailByteCount = byteCount % 4
    if tailByteCount > 0 {
      var tail: UInt32 = 0

      for byteOffset in 0..<tailByteCount {
        tail |= UInt32(bytes[index + byteOffset]) << (byteOffset * 8)
      }

      hash ^= mix(tail)
    }

    hash ^= UInt32(truncatingIfNeeded: byteCount)
    hash ^= hash >> 16
    hash = hash &* 0x85eb_ca6b
    hash ^= hash >> 13
    hash = hash &* 0xc2b2_ae35
    hash ^= hash >> 16

    return hash
  }

  private static func hashGeneric(
    _ bytes: some Collection<UInt8>,
    seed: UInt32
  ) -> UInt32 {
    let byteCount = bytes.count
    let blockCount = byteCount / 4
    var hash = seed
    var index = bytes.startIndex

    for _ in 0..<blockCount {
      var block: UInt32 = 0

      for byteOffset in 0..<4 {
        block |= UInt32(bytes[index]) << (byteOffset * 8)
        bytes.formIndex(after: &index)
      }

      hash ^= mix(block)
      hash = rotateLeft(hash, by: 13)
      hash = hash &* 5
      hash = hash &+ 0xe654_6b64
    }

    let tailByteCount = byteCount % 4
    if tailByteCount > 0 {
      var tail: UInt32 = 0

      for byteOffset in 0..<tailByteCount {
        tail |= UInt32(bytes[index]) << (byteOffset * 8)
        bytes.formIndex(after: &index)
      }

      hash ^= mix(tail)
    }

    hash ^= UInt32(truncatingIfNeeded: byteCount)
    hash ^= hash >> 16
    hash = hash &* 0x85eb_ca6b
    hash ^= hash >> 13
    hash = hash &* 0xc2b2_ae35
    hash ^= hash >> 16

    return hash
  }

  @inline(__always)
  private static func mix(_ block: UInt32) -> UInt32 {
    var mixedBlock = block
    mixedBlock = mixedBlock &* blockMultiplier
    mixedBlock = rotateLeft(mixedBlock, by: 15)
    mixedBlock = mixedBlock &* blockRotationMultiplier
    return mixedBlock
  }

  @inline(__always)
  private static func rotateLeft(_ value: UInt32, by count: Int) -> UInt32 {
    (value << count) | (value >> (UInt32.bitWidth - count))
  }
}
