import XCTest

@testable import BloomBuilderKit

final class BloomFilterParametersTests: XCTestCase {
  func testInitializerStoresValidatedValues() throws {
    let parameters = try BloomFilterParameters(
      bitCount: 9,
      hashCount: 4,
      murmurSeed: 0x1234_5678
    )

    XCTAssertEqual(parameters.bitCount, 9)
    XCTAssertEqual(parameters.hashCount, 4)
    XCTAssertEqual(parameters.murmurSeed, 0x1234_5678)
    XCTAssertEqual(parameters.byteCount, 2)
  }

  func testByteCountUsesWidenedArithmeticAtUInt32Maximum() throws {
    let parameters = try BloomFilterParameters(
      bitCount: .max,
      hashCount: 1,
      murmurSeed: 0
    )

    XCTAssertEqual(parameters.byteCount, 536_870_912)
  }

  func testInitializerRejectsZeroBitCount() {
    XCTAssertThrowsError(
      try BloomFilterParameters(bitCount: 0, hashCount: 1, murmurSeed: 0)
    ) { error in
      XCTAssertEqual(
        error as? BloomFilterParametersError,
        .bitCountMustBePositive
      )
    }
  }

  func testInitializerRejectsZeroHashCount() {
    XCTAssertThrowsError(
      try BloomFilterParameters(
        bitCount: 8,
        hashCount: 0,
        murmurSeed: 0
      )
    ) { error in
      XCTAssertEqual(
        error as? BloomFilterParametersError,
        .hashCountMustBePositive
      )
    }
  }

  func testInitializerAcceptsUInt32MaximumHashCount() throws {
    let parameters = try BloomFilterParameters(
      bitCount: 8,
      hashCount: .max,
      murmurSeed: 0
    )

    XCTAssertEqual(parameters.hashCount, .max)
  }

  func testSizingPinsRepresentativeValuesAndSeed() throws {
    let cases:
      [(
        expectedKeyCount: Int,
        falsePositiveRate: Double,
        expectedBitCount: UInt32,
        expectedHashCount: UInt32
      )] = [
        (1, 0.5, 2, 2),
        (100, 0.01, 959, 7),
        (1_000, 0.01, 9_586, 7),
        (10, 0.001, 144, 10),
      ]

    for sizingCase in cases {
      let parameters = try BloomFilterParameters.sized(
        expectedKeyCount: sizingCase.expectedKeyCount,
        falsePositiveRate: sizingCase.falsePositiveRate,
        murmurSeed: 0xa5a5_5a5a
      )

      XCTAssertEqual(
        parameters.bitCount,
        sizingCase.expectedBitCount,
        "Unexpected bit count for \(sizingCase)"
      )
      XCTAssertEqual(
        parameters.hashCount,
        sizingCase.expectedHashCount,
        "Unexpected hash count for \(sizingCase)"
      )
      XCTAssertEqual(parameters.murmurSeed, 0xa5a5_5a5a)
    }
  }

  func testSizingRoundsHashCountUpAtCeilBoundary() throws {
    let parameters = try BloomFilterParameters.sized(
      expectedKeyCount: 10,
      falsePositiveRate: 0.1,
      murmurSeed: 7
    )

    XCTAssertEqual(parameters.bitCount, 48)
    XCTAssertEqual(parameters.hashCount, 4)
  }

  func testSizingRejectsExpectedKeyCountsBelowOne() {
    for expectedKeyCount in [0, -1] {
      XCTAssertThrowsError(
        try BloomFilterParameters.sized(
          expectedKeyCount: expectedKeyCount,
          falsePositiveRate: 0.01,
          murmurSeed: 0
        )
      ) { error in
        XCTAssertEqual(
          error as? BloomFilterParametersError,
          .expectedKeyCountMustBePositive(
            expectedKeyCount: expectedKeyCount
          )
        )
      }
    }
  }

  func testSizingRejectsNonfiniteFalsePositiveRates() {
    for falsePositiveRate in [Double.nan, .infinity, -.infinity] {
      XCTAssertThrowsError(
        try BloomFilterParameters.sized(
          expectedKeyCount: 10,
          falsePositiveRate: falsePositiveRate,
          murmurSeed: 0
        )
      ) { error in
        guard
          let parametersError = error as? BloomFilterParametersError,
          case .falsePositiveRateMustBeFinite = parametersError
        else {
          return XCTFail("Unexpected error: \(error)")
        }
      }
    }
  }

  func testSizingRejectsOutOfRangeFalsePositiveRates() {
    for falsePositiveRate in [-0.1, 0, 1, 1.1] {
      XCTAssertThrowsError(
        try BloomFilterParameters.sized(
          expectedKeyCount: 10,
          falsePositiveRate: falsePositiveRate,
          murmurSeed: 0
        )
      ) { error in
        XCTAssertEqual(
          error as? BloomFilterParametersError,
          .falsePositiveRateOutOfRange(
            falsePositiveRate: falsePositiveRate
          )
        )
      }
    }
  }

  func testSizingRejectsUInt32Overflow() {
    XCTAssertThrowsError(
      try BloomFilterParameters.sized(
        expectedKeyCount: Int.max,
        falsePositiveRate: 0.01,
        murmurSeed: 0
      )
    ) { error in
      XCTAssertEqual(
        error as? BloomFilterParametersError,
        .sizingExceedsUInt32
      )
    }
  }
}
