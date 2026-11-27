import XCTest

@testable import BloomBuilderKit

final class MurmurHash3Tests: XCTestCase {
  func testPublishedVerificationVector() {
    // This is the canonical verification procedure and expected x86_32 value
    // published with the public-domain SMHasher reference implementation.
    let key = (0..<256).map(UInt8.init)
    var hashes: [UInt8] = []
    hashes.reserveCapacity(256 * MemoryLayout<UInt32>.size)

    for length in 0..<256 {
      let hash = MurmurHash3.hash(
        key.prefix(length),
        seed: UInt32(256 - length)
      )
      hashes.append(UInt8(truncatingIfNeeded: hash))
      hashes.append(UInt8(truncatingIfNeeded: hash >> 8))
      hashes.append(UInt8(truncatingIfNeeded: hash >> 16))
      hashes.append(UInt8(truncatingIfNeeded: hash >> 24))
    }

    XCTAssertEqual(MurmurHash3.hash(hashes, seed: 0), 0xb0f5_7ee3)
  }

  func testPublishedVectorsCoverEmptyInputAndTailLengths() {
    // Selected cases from SMHasher's canonical key and seed sequence.
    let vectors: [(bytes: [UInt8], seed: UInt32, expectedHash: UInt32)] = [
      ([], 256, 0x4570_315f),
      ([0x00], 255, 0xcea2_a54e),
      ([0x00, 0x01], 254, 0x15cc_3b39),
      ([0x00, 0x01, 0x02], 253, 0xca6f_1663),
      ([0x00, 0x01, 0x02, 0x03], 252, 0xe548_3c42),
      ([0x00, 0x01, 0x02, 0x03, 0x04], 251, 0xb942_544f),
    ]

    for vector in vectors {
      XCTAssertEqual(
        MurmurHash3.hash(vector.bytes, seed: vector.seed),
        vector.expectedHash,
        "Unexpected hash for \(vector.bytes.count)-byte input"
      )
    }
  }

  func testPublishedVectorCoversMultipleBlocks() {
    let input = (0..<16).map(UInt8.init)

    XCTAssertEqual(MurmurHash3.hash(input, seed: 240), 0xfe07_2073)
  }

  func testPublishedVectorsCoverSeedVariation() {
    let input = Array("foo".utf8)

    XCTAssertEqual(MurmurHash3.hash(input, seed: 0), 0xf6a5_c420)
    XCTAssertEqual(MurmurHash3.hash(input, seed: 42), 0xb12f_489e)
  }

  func testNonZeroBasedSliceCoversBlocksAndTail() {
    let key = (0..<11).map(UInt8.init)
    let storage = [UInt8](repeating: 0xff, count: 3) + key + [0xff]
    let input = storage[3..<14]

    XCTAssertEqual(input.startIndex, 3)
    XCTAssertEqual(MurmurHash3.hash(input, seed: 245), 0x738c_3caa)
  }

  func testContiguousFastPathMatchesGenericFallback() {
    let lengths = Array(0...17) + [31, 32, 33, 64, 65, 66, 67]

    for length in lengths {
      let bytes = (0..<length).map {
        UInt8(truncatingIfNeeded: $0 * 37 + 11)
      }
      let paddedBytes = [0xff, 0xfe] + bytes + [0xfd]
      let contiguousSlice = paddedBytes[2..<(2 + length)]
      let noncontiguousBytes = NoncontiguousBytes(bytes)
      let seed = 0xa5a5_5a5a &+ UInt32(length)

      XCTAssertNotNil(
        bytes.withContiguousStorageIfAvailable(\.count),
        "Expected contiguous storage for \(length)-byte array"
      )
      XCTAssertNotNil(
        contiguousSlice.withContiguousStorageIfAvailable(\.count),
        "Expected contiguous storage for \(length)-byte slice"
      )
      XCTAssertNil(
        noncontiguousBytes.withContiguousStorageIfAvailable(\.count),
        "Expected generic fallback for \(length)-byte input"
      )
      XCTAssertEqual(
        MurmurHash3.hash(bytes, seed: seed),
        MurmurHash3.hash(noncontiguousBytes, seed: seed),
        "Unexpected array hash for \(length)-byte input"
      )
      XCTAssertEqual(
        MurmurHash3.hash(contiguousSlice, seed: seed),
        MurmurHash3.hash(noncontiguousBytes, seed: seed),
        "Unexpected slice hash for \(length)-byte input"
      )
    }
  }
}
