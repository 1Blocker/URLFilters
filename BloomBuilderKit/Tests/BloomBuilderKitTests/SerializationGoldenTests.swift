import XCTest

@testable import BloomBuilderKit
@testable import BloomBuilderTestSupport

final class SerializationGoldenTests: XCTestCase {
  func testSmallExplicitFilterMatchesFrozenBitVector() throws {
    let parameters = try BloomFilterParameters(
      bitCount: 37,
      hashCount: 5,
      murmurSeed: 0x1234_5678
    )
    let keys = [
      "alpha.example",
      "beta.example/path?query=1",
      "gamma.example",
    ]
    let expectedBytes = GoldenBitVectors.smallExplicit
    var filter = BloomFilter(parameters: parameters)

    for key in keys {
      filter.insert(key.utf8)
    }

    XCTAssertEqual(filter.bitVector, expectedBytes)
    XCTAssertEqual(filter.bitVector.last! & 0xe0, 0)

    let deserialized = try BloomFilter(
      parameters: parameters,
      bytes: expectedBytes
    )
    XCTAssertEqual(deserialized.bitVector, expectedBytes)
  }

  func testSizedMediumFilterMatchesFrozenBitVector() throws {
    let parameters = try BloomFilterParameters.sized(
      expectedKeyCount: 100,
      falsePositiveRate: 0.01,
      murmurSeed: 0xa5a5_5a5a
    )
    let expectedBytes = GoldenBitVectors.sizedMedium
    var filter = BloomFilter(parameters: parameters)

    for index in 0..<100 {
      filter.insert("medium-key-\(index)".utf8)
    }

    XCTAssertEqual(parameters.bitCount, 959)
    XCTAssertEqual(parameters.hashCount, 7)
    XCTAssertEqual(filter.bitVector, expectedBytes)
  }

  func testUnionMatchesFrozenBitVector() throws {
    let parameters = try BloomFilterParameters(
      bitCount: 257,
      hashCount: 6,
      murmurSeed: 0xcafe_babe
    )
    let expectedBytes = GoldenBitVectors.union
    var leftFilter = BloomFilter(parameters: parameters)
    var rightFilter = BloomFilter(parameters: parameters)

    for index in 0..<16 {
      leftFilter.insert("union-key-\(index)".utf8)
    }
    for index in 10..<26 {
      rightFilter.insert("union-key-\(index)".utf8)
    }

    try leftFilter.formUnion(rightFilter)

    XCTAssertEqual(leftFilter.bitVector, expectedBytes)
    XCTAssertEqual(leftFilter.bitVector.last! & 0xfe, 0)
  }
}
