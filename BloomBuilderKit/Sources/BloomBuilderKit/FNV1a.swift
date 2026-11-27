enum FNV1a {
  private static let offsetBasis: UInt32 = 0x811c_9dc5
  private static let prime: UInt32 = 0x0100_0193

  @inline(__always)
  static func hash(_ bytes: some Collection<UInt8>) -> UInt32 {
    if let contiguousHash = bytes.withContiguousStorageIfAvailable({
      hashContiguous($0)
    }) {
      return contiguousHash
    }

    return hashGeneric(bytes)
  }

  @inline(__always)
  private static func hashContiguous(
    _ bytes: UnsafeBufferPointer<UInt8>
  ) -> UInt32 {
    var hash = offsetBasis

    for byte in bytes {
      hash ^= UInt32(byte)
      hash = hash &* prime
    }

    return hash
  }

  @inline(__always)
  private static func hashGeneric(
    _ bytes: some Collection<UInt8>
  ) -> UInt32 {
    var hash = offsetBasis

    for byte in bytes {
      hash ^= UInt32(byte)
      hash = hash &* prime
    }

    return hash
  }
}
