#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

/// Errors produced while validating or sizing Bloom-filter parameters.
public enum BloomFilterParametersError: Error, Equatable, Sendable {
  /// The bit count was zero; valid bit counts are `1...UInt32.max`.
  case bitCountMustBePositive

  /// The hash count was zero; valid hash counts are `1...UInt32.max`.
  case hashCountMustBePositive

  /// The expected key count was less than one.
  case expectedKeyCountMustBePositive(expectedKeyCount: Int)

  /// The false-positive rate was NaN or infinite.
  case falsePositiveRateMustBeFinite(falsePositiveRate: Double)

  /// The false-positive rate was not strictly between zero and one.
  case falsePositiveRateOutOfRange(falsePositiveRate: Double)

  /// A sized bit or hash count could not be represented by `UInt32`.
  case sizingExceedsUInt32
}

/// Validated parameters for an Apple NEURLFilter-compatible Bloom prefilter.
public struct BloomFilterParameters: Equatable, Sendable {
  /// The number of addressable bits in the filter, in `1...UInt32.max`.
  public let bitCount: UInt32

  /// The number of double-hash probes per key, in `1...UInt32.max`.
  public let hashCount: UInt32

  /// The unsigned 32-bit seed supplied to MurmurHash3 for every key.
  public let murmurSeed: UInt32

  /// Creates validated Bloom-filter parameters.
  ///
  /// - Parameters:
  ///   - bitCount: The number of addressable bits, in `1...UInt32.max`.
  ///   - hashCount: The number of probes, in `1...UInt32.max`.
  ///   - murmurSeed: The unsigned 32-bit MurmurHash3 seed.
  /// - Throws: ``BloomFilterParametersError`` if either count is invalid.
  public init(bitCount: UInt32, hashCount: UInt32, murmurSeed: UInt32) throws {
    guard bitCount > 0 else {
      throw BloomFilterParametersError.bitCountMustBePositive
    }
    guard hashCount > 0 else {
      throw BloomFilterParametersError.hashCountMustBePositive
    }

    self.bitCount = bitCount
    self.hashCount = hashCount
    self.murmurSeed = murmurSeed
  }

  /// Sizes parameters using the formulas documented for Apple's NEURLFilter
  /// Bloom prefilter.
  ///
  /// Both results round upward: `bitCount = ceil(-n * ln(p) / ln(2)^2)` and
  /// `hashCount = ceil(bitCount / n * ln(2))`.
  ///
  /// - Parameters:
  ///   - expectedKeyCount: The expected number of distinct keys; must be at
  ///     least one.
  ///   - falsePositiveRate: The target rate as a finite value strictly between
  ///     zero and one.
  ///   - murmurSeed: The unsigned 32-bit MurmurHash3 seed.
  /// - Returns: Validated parameters whose bit and hash counts fit `UInt32`.
  /// - Throws: ``BloomFilterParametersError`` if an input or sized count is
  ///   invalid.
  public static func sized(
    expectedKeyCount: Int,
    falsePositiveRate: Double,
    murmurSeed: UInt32
  ) throws -> Self {
    guard expectedKeyCount >= 1 else {
      throw BloomFilterParametersError.expectedKeyCountMustBePositive(
        expectedKeyCount: expectedKeyCount
      )
    }
    guard falsePositiveRate.isFinite else {
      throw BloomFilterParametersError.falsePositiveRateMustBeFinite(
        falsePositiveRate: falsePositiveRate
      )
    }
    guard falsePositiveRate > 0, falsePositiveRate < 1 else {
      throw BloomFilterParametersError.falsePositiveRateOutOfRange(
        falsePositiveRate: falsePositiveRate
      )
    }

    let naturalLogOfTwo = log(2.0)
    let expectedKeyCountAsDouble = Double(expectedKeyCount)
    let sizedBitCount = ceil(
      -expectedKeyCountAsDouble * log(falsePositiveRate)
        / (naturalLogOfTwo * naturalLogOfTwo)
    )

    guard
      sizedBitCount.isFinite,
      sizedBitCount >= 1,
      let bitCount = UInt32(exactly: sizedBitCount)
    else {
      throw BloomFilterParametersError.sizingExceedsUInt32
    }

    let sizedHashCount = ceil(
      Double(bitCount) / expectedKeyCountAsDouble * naturalLogOfTwo
    )
    guard
      sizedHashCount.isFinite,
      sizedHashCount >= 1,
      let hashCount = UInt32(exactly: sizedHashCount)
    else {
      throw BloomFilterParametersError.sizingExceedsUInt32
    }

    return Self(
      validatedBitCount: bitCount,
      validatedHashCount: hashCount,
      murmurSeed: murmurSeed
    )
  }

  /// The exact byte length of the packed bit vector under the serialization
  /// contract, computed as `(bitCount + 7) / 8` without 32-bit overflow.
  public var byteCount: Int {
    Int((UInt64(bitCount) + 7) / 8)
  }

  private init(
    validatedBitCount: UInt32,
    validatedHashCount: UInt32,
    murmurSeed: UInt32
  ) {
    bitCount = validatedBitCount
    hashCount = validatedHashCount
    self.murmurSeed = murmurSeed
  }
}
