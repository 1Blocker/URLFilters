import XCTest

@testable import BloomBuilderKit

final class FNV1aTests: XCTestCase {
  func testPublished32BitVectors() {
    // Published in the public FNV test-vector set maintained by Landon Curt Noll.
    let vectors: [(input: String, expectedHash: UInt32)] = [
      ("", 0x811c_9dc5),
      ("a", 0xe40c_292c),
      ("b", 0xe70c_2de5),
      ("c", 0xe60c_2c52),
      ("d", 0xe10c_2473),
      ("e", 0xe00c_22e0),
      ("f", 0xe30c_2799),
      ("fo", 0x6222_e842),
      ("foo", 0xa9f3_7ed7),
      ("foob", 0x3f50_76ef),
      ("fooba", 0x39aa_a18a),
      ("foobar", 0xbf9c_f968),
    ]

    for vector in vectors {
      XCTAssertEqual(
        FNV1a.hash(vector.input.utf8),
        vector.expectedHash,
        "Unexpected hash for \(String(reflecting: vector.input))"
      )
    }
  }

  func testNonZeroBasedSliceMatchesPublishedVector() {
    let storage = Array("--foobar--".utf8)
    let input = storage[2..<8]

    XCTAssertEqual(input.startIndex, 2)
    XCTAssertEqual(FNV1a.hash(input), 0xbf9c_f968)
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
        FNV1a.hash(bytes),
        FNV1a.hash(noncontiguousBytes),
        "Unexpected array hash for \(length)-byte input"
      )
      XCTAssertEqual(
        FNV1a.hash(contiguousSlice),
        FNV1a.hash(noncontiguousBytes),
        "Unexpected slice hash for \(length)-byte input"
      )
    }
  }
}
