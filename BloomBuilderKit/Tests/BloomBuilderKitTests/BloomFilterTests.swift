import XCTest

@testable import BloomBuilderKit

final class BloomFilterTests: XCTestCase {
  func testEmptyFilterHasExpectedZeroedStorage() throws {
    let parameters = try makeParameters(bitCount: 17, hashCount: 3)
    let filter = BloomFilter(parameters: parameters)

    XCTAssertEqual(filter.parameters, parameters)
    XCTAssertEqual(filter.bitVector, [0, 0, 0])
    XCTAssertFalse(filter.mayContain(Array("unseen".utf8)))
  }

  func testProbeMathAndLSBFirstPackingMatchPinnedVector() throws {
    let parameters = try makeParameters(
      bitCount: 17,
      hashCount: 4,
      murmurSeed: 42
    )
    var filter = BloomFilter(parameters: parameters)

    filter.insert(Array("foo".utf8))

    XCTAssertEqual(filter.bitVector, [0x20, 0x04, 0x01])
    XCTAssertTrue(filter.mayContain(Array("foo".utf8)))
  }

  func testLSBFirstPackingAtBothEndsOfByte() throws {
    let parameters = try makeParameters(bitCount: 8, hashCount: 1)
    var lowBitFilter = BloomFilter(parameters: parameters)
    var highBitFilter = BloomFilter(parameters: parameters)

    lowBitFilter.insert(Array("foobar".utf8))
    highBitFilter.insert(Array("foo".utf8))

    XCTAssertEqual(lowBitFilter.bitVector, [0x01])
    XCTAssertEqual(highBitFilter.bitVector, [0x80])
  }

  func testBitCountPackingEdgesAndTrailingBitInvariant() throws {
    let cases:
      [(
        bitCount: UInt32,
        validBytes: [UInt8],
        allowedLastByteMask: UInt8
      )] = [
        (1, [0x01], 0x01),
        (7, [0x7f], 0x7f),
        (8, [0xff], 0xff),
        (9, [0xff, 0x01], 0x01),
      ]

    for packingCase in cases {
      let parameters = try makeParameters(
        bitCount: packingCase.bitCount,
        hashCount: 3
      )
      let deserialized = try BloomFilter(
        parameters: parameters,
        bytes: packingCase.validBytes
      )

      XCTAssertEqual(deserialized.bitVector, packingCase.validBytes)

      var inserted = BloomFilter(parameters: parameters)
      let key = [UInt8(truncatingIfNeeded: packingCase.bitCount)]
      inserted.insert(key)

      XCTAssertTrue(inserted.mayContain(key))
      XCTAssertEqual(
        inserted.bitVector.last! & ~packingCase.allowedLastByteMask,
        0
      )

      if packingCase.allowedLastByteMask != .max {
        var invalidBytes = packingCase.validBytes
        invalidBytes[invalidBytes.index(before: invalidBytes.endIndex)] |=
          ~packingCase.allowedLastByteMask

        XCTAssertThrowsError(
          try BloomFilter(parameters: parameters, bytes: invalidBytes)
        ) { error in
          XCTAssertEqual(
            error as? BloomFilterSerializationError,
            .nonzeroTrailingBits(
              lastByte: invalidBytes.last!,
              allowedMask: packingCase.allowedLastByteMask
            )
          )
        }
      }
    }
  }

  func testNonZeroBasedArraySliceMatchesContiguousKey() throws {
    let parameters = try makeParameters(bitCount: 512, hashCount: 5)
    let key = Array("slice-key".utf8)
    let storage = [0xff, 0xff] + key + [0xff]
    let slice = storage[2..<(2 + key.count)]
    var sliceFilter = BloomFilter(parameters: parameters)
    var contiguousFilter = BloomFilter(parameters: parameters)

    XCTAssertEqual(slice.startIndex, 2)
    sliceFilter.insert(slice)
    contiguousFilter.insert(key)

    XCTAssertEqual(sliceFilter.bitVector, contiguousFilter.bitVector)
    XCTAssertTrue(sliceFilter.mayContain(slice))
  }

  func testSerializationRoundTripPreservesBytes() throws {
    let parameters = try makeParameters(bitCount: 17, hashCount: 4)
    let bytes: [UInt8] = [0xa5, 0x5a, 0x01]

    let filter = try BloomFilter(parameters: parameters, bytes: bytes)

    XCTAssertEqual(filter.bitVector, bytes)
  }

  func testWithUnsafeBitVectorBytesMatchesBitVectorAcrossFilterStates() throws {
    let parameters = try makeParameters(bitCount: 17, hashCount: 4)

    var insertedFilter = BloomFilter(parameters: parameters)
    insertedFilter.insert(Array("foo".utf8))
    let deserializedFilter = try BloomFilter(
      parameters: parameters,
      bytes: [0xa5, 0x5a, 0x01]
    )
    let filters = [
      BloomFilter(parameters: parameters),
      insertedFilter,
      deserializedFilter,
    ]

    for filter in filters {
      let borrowedBytes = filter.withUnsafeBitVectorBytes { Array($0) }

      XCTAssertEqual(borrowedBytes, filter.bitVector)
      XCTAssertEqual(borrowedBytes.count, parameters.byteCount)
    }
  }

  func testWithUnsafeBitVectorBytesPropagatesBodyError() throws {
    struct BitVectorViewBodyError: Error, Equatable {}

    let parameters = try makeParameters(bitCount: 17, hashCount: 4)
    let filter = try BloomFilter(
      parameters: parameters,
      bytes: [0xa5, 0x5a, 0x01]
    )

    XCTAssertThrowsError(
      try filter.withUnsafeBitVectorBytes { _ in
        throw BitVectorViewBodyError()
      }
    ) { error in
      XCTAssertEqual(error as? BitVectorViewBodyError, BitVectorViewBodyError())
    }
    XCTAssertEqual(filter.bitVector, [0xa5, 0x5a, 0x01])
  }

  func testDeserializationRejectsWrongByteCounts() throws {
    let parameters = try makeParameters(bitCount: 9, hashCount: 2)

    for bytes: [UInt8] in [[], [0], [0, 0, 0]] {
      XCTAssertThrowsError(
        try BloomFilter(parameters: parameters, bytes: bytes)
      ) { error in
        XCTAssertEqual(
          error as? BloomFilterSerializationError,
          .incorrectByteCount(expected: 2, actual: bytes.count)
        )
      }
    }
  }

  func testDeserializationRejectsNonzeroTrailingPadding() throws {
    let parameters = try makeParameters(bitCount: 9, hashCount: 2)

    XCTAssertThrowsError(
      try BloomFilter(parameters: parameters, bytes: [0, 0x80])
    ) { error in
      XCTAssertEqual(
        error as? BloomFilterSerializationError,
        .nonzeroTrailingBits(lastByte: 0x80, allowedMask: 0x01)
      )
    }
  }

  func testInsertedDeterministicSetHasNoFalseNegatives() throws {
    let parameters = try BloomFilterParameters.sized(
      expectedKeyCount: 512,
      falsePositiveRate: 0.01,
      murmurSeed: 0x1357_9bdf
    )
    let keys = (0..<512).map(deterministicKey)
    var filter = BloomFilter(parameters: parameters)

    for key in keys {
      filter.insert(key)
    }

    for key in keys {
      XCTAssertTrue(filter.mayContain(key), "False negative for \(key)")
    }
  }

  func testShuffledInsertionProducesIdenticalBitVector() throws {
    let parameters = try makeParameters(
      bitCount: 4_096,
      hashCount: 7,
      murmurSeed: 0x2468_ace0
    )
    let keys = (0..<128).map(deterministicKey)
    let shuffledKeys = (0..<keys.count).map { index in
      keys[(index * 73 + 19) % keys.count]
    }
    var orderedFilter = BloomFilter(parameters: parameters)
    var shuffledFilter = BloomFilter(parameters: parameters)

    for key in keys {
      orderedFilter.insert(key)
    }
    for key in shuffledKeys {
      shuffledFilter.insert(key)
    }

    XCTAssertEqual(orderedFilter.bitVector, shuffledFilter.bitVector)
  }

  func testFormUnionEqualsFilterBuiltFromCombinedSet() throws {
    let parameters = try makeParameters(
      bitCount: 2_049,
      hashCount: 6,
      murmurSeed: 0xdead_beef
    )
    let leftKeys = (0..<80).map(deterministicKey)
    let rightKeys = (60..<140).map(deterministicKey)
    let combinedKeys = (0..<140).map(deterministicKey)
    var leftFilter = BloomFilter(parameters: parameters)
    var rightFilter = BloomFilter(parameters: parameters)
    var combinedFilter = BloomFilter(parameters: parameters)

    for key in leftKeys {
      leftFilter.insert(key)
    }
    for key in rightKeys {
      rightFilter.insert(key)
    }
    for key in combinedKeys {
      combinedFilter.insert(key)
    }

    try leftFilter.formUnion(rightFilter)

    XCTAssertEqual(leftFilter.bitVector, combinedFilter.bitVector)
    XCTAssertEqual(leftFilter.bitVector.last! & 0xfe, 0)
  }

  func testFormUnionRejectsEveryParameterMismatch() throws {
    let parameters = try makeParameters(
      bitCount: 64,
      hashCount: 3,
      murmurSeed: 7
    )
    let mismatchedParameters = [
      try makeParameters(bitCount: 65, hashCount: 3, murmurSeed: 7),
      try makeParameters(bitCount: 64, hashCount: 4, murmurSeed: 7),
      try makeParameters(bitCount: 64, hashCount: 3, murmurSeed: 8),
    ]

    for mismatch in mismatchedParameters {
      var filter = BloomFilter(parameters: parameters)
      filter.insert([0x01])
      let originalBytes = filter.bitVector
      let other = BloomFilter(parameters: mismatch)

      XCTAssertThrowsError(try filter.formUnion(other)) { error in
        XCTAssertEqual(
          error as? BloomFilterUnionError,
          .parameterMismatch(expected: parameters, actual: mismatch)
        )
      }
      XCTAssertEqual(filter.bitVector, originalBytes)
    }
  }

  func testLFDelimitedIngestionReturnsCountAndInsertsRawKeys() throws {
    let parameters = try makeParameters(bitCount: 1_025, hashCount: 5)
    let keys = ["alpha", "beta", "alpha", "gamma"].map {
      Array($0.utf8)
    }
    let fileBytes = Array("alpha\nbeta\nalpha\ngamma\n".utf8)
    var filter = BloomFilter(parameters: parameters)

    let insertedKeyCount = try filter.insertLFDelimitedKeys(from: fileBytes)

    XCTAssertEqual(insertedKeyCount, 4)
    for key in keys {
      XCTAssertTrue(filter.mayContain(key))
    }
    XCTAssertEqual(filter.bitVector.last! & 0xfe, 0)
  }

  func testLFDelimitedIngestionAcceptsEmptyFile() throws {
    let parameters = try makeParameters(bitCount: 64, hashCount: 2)
    var filter = BloomFilter(parameters: parameters)

    let insertedKeyCount = try filter.insertLFDelimitedKeys(from: [UInt8]())

    XCTAssertEqual(insertedKeyCount, 0)
    XCTAssertEqual(filter.bitVector, [UInt8](repeating: 0, count: 8))
  }

  func testLFDelimitedIngestionContiguousFastPathMatchesGenericFallback()
    throws
  {
    let parameters = try makeParameters(
      bitCount: 4_097,
      hashCount: 7,
      murmurSeed: 0xa5a5_5a5a
    )
    let cases: [(name: String, keys: [[UInt8]])] = [
      (
        "multiple keys with block boundaries",
        [
          Array("abc".utf8),
          Array("defgh".utf8),
          Array("ijklmnopq".utf8),
          Array("rstuvwxyzabc".utf8),
        ]
      ),
      ("empty input", []),
      ("single key", [Array("single-key".utf8)]),
    ]

    for ingestionCase in cases {
      let fileBytes = ingestionCase.keys.reduce(into: [UInt8]()) {
        fileBytes,
        key in
        fileBytes.append(contentsOf: key)
        fileBytes.append(0x0a)
      }
      let paddedFileBytes = [UInt8.max] + fileBytes + [UInt8.max]
      let contiguousSlice =
        paddedFileBytes[1..<(1 + fileBytes.count)]
      let noncontiguousBytes = NoncontiguousBytes(fileBytes)

      XCTAssertNotNil(
        fileBytes.withContiguousStorageIfAvailable(\.count),
        "Expected array fast path for \(ingestionCase.name)"
      )
      XCTAssertNotNil(
        contiguousSlice.withContiguousStorageIfAvailable(\.count),
        "Expected slice fast path for \(ingestionCase.name)"
      )
      XCTAssertNil(
        noncontiguousBytes.withContiguousStorageIfAvailable(\.count),
        "Expected generic fallback for \(ingestionCase.name)"
      )

      var arrayFilter = BloomFilter(parameters: parameters)
      var sliceFilter = BloomFilter(parameters: parameters)
      var fallbackFilter = BloomFilter(parameters: parameters)
      var expectedFilter = BloomFilter(parameters: parameters)

      let arrayCount = try arrayFilter.insertLFDelimitedKeys(from: fileBytes)
      let sliceCount = try sliceFilter.insertLFDelimitedKeys(
        from: contiguousSlice
      )
      let fallbackCount = try fallbackFilter.insertLFDelimitedKeys(
        from: noncontiguousBytes
      )
      for key in ingestionCase.keys {
        expectedFilter.insert(key)
      }

      XCTAssertEqual(
        arrayCount,
        ingestionCase.keys.count,
        ingestionCase.name
      )
      XCTAssertEqual(sliceCount, arrayCount, ingestionCase.name)
      XCTAssertEqual(fallbackCount, arrayCount, ingestionCase.name)
      XCTAssertEqual(
        arrayFilter.bitVector,
        expectedFilter.bitVector,
        ingestionCase.name
      )
      XCTAssertEqual(
        sliceFilter.bitVector,
        arrayFilter.bitVector,
        ingestionCase.name
      )
      XCTAssertEqual(
        fallbackFilter.bitVector,
        arrayFilter.bitVector,
        ingestionCase.name
      )
    }
  }

  func testLFDelimitedIngestionErrorsMatchBetweenFastPathAndFallback()
    throws
  {
    let parameters = try makeParameters(
      bitCount: 257,
      hashCount: 4,
      murmurSeed: 0x1234_5678
    )
    let cases:
      [(
        name: String,
        fileBytes: [UInt8],
        expectedError: BloomFilterKeyFileError
      )] = [
        (
          "CR at first byte",
          Array("\rkey\n".utf8),
          .carriageReturn(lineNumber: 1, byteOffset: 0)
        ),
        (
          "CR within first key",
          Array("ab\rc\n".utf8),
          .carriageReturn(lineNumber: 1, byteOffset: 2)
        ),
        (
          "CR at start of second line",
          Array("one\n\rkey\n".utf8),
          .carriageReturn(lineNumber: 2, byteOffset: 4)
        ),
        (
          "CR within third line",
          Array("a\nbc\nx\ry\n".utf8),
          .carriageReturn(lineNumber: 3, byteOffset: 6)
        ),
        (
          "CR at final byte",
          Array("one\ntwo\r".utf8),
          .carriageReturn(lineNumber: 2, byteOffset: 7)
        ),
        (
          "empty first line",
          Array("\nkey\n".utf8),
          .emptyLine(lineNumber: 1)
        ),
        (
          "empty middle line",
          Array("one\n\ntwo\n".utf8),
          .emptyLine(lineNumber: 2)
        ),
        (
          "empty final line",
          Array("one\ntwo\n\n".utf8),
          .emptyLine(lineNumber: 3)
        ),
        (
          "single key missing final LF",
          Array("one".utf8),
          .missingFinalLineFeed
        ),
        (
          "later key missing final LF",
          Array("one\ntwo".utf8),
          .missingFinalLineFeed
        ),
      ]

    var originalFilter = BloomFilter(parameters: parameters)
    originalFilter.insert(Array("existing-key".utf8))
    let originalBitVector = originalFilter.bitVector

    for ingestionCase in cases {
      let paddedFileBytes =
        [UInt8.max] + ingestionCase.fileBytes + [UInt8.max]
      let contiguousSlice =
        paddedFileBytes[1..<(1 + ingestionCase.fileBytes.count)]
      let noncontiguousBytes = NoncontiguousBytes(ingestionCase.fileBytes)

      XCTAssertNotNil(
        ingestionCase.fileBytes.withContiguousStorageIfAvailable(\.count),
        "Expected array fast path for \(ingestionCase.name)"
      )
      XCTAssertNotNil(
        contiguousSlice.withContiguousStorageIfAvailable(\.count),
        "Expected slice fast path for \(ingestionCase.name)"
      )
      XCTAssertNil(
        noncontiguousBytes.withContiguousStorageIfAvailable(\.count),
        "Expected generic fallback for \(ingestionCase.name)"
      )

      var arrayFilter = originalFilter
      var sliceFilter = originalFilter
      var fallbackFilter = originalFilter
      let arrayError = captureLFDelimitedIngestionError(
        from: ingestionCase.fileBytes,
        filter: &arrayFilter
      )
      let sliceError = captureLFDelimitedIngestionError(
        from: contiguousSlice,
        filter: &sliceFilter
      )
      let fallbackError = captureLFDelimitedIngestionError(
        from: noncontiguousBytes,
        filter: &fallbackFilter
      )

      XCTAssertEqual(
        arrayError,
        ingestionCase.expectedError,
        ingestionCase.name
      )
      XCTAssertEqual(sliceError, arrayError, ingestionCase.name)
      XCTAssertEqual(fallbackError, arrayError, ingestionCase.name)
      XCTAssertEqual(
        arrayFilter.bitVector,
        originalBitVector,
        ingestionCase.name
      )
      XCTAssertEqual(
        sliceFilter.bitVector,
        originalBitVector,
        ingestionCase.name
      )
      XCTAssertEqual(
        fallbackFilter.bitVector,
        originalBitVector,
        ingestionCase.name
      )
    }
  }

  func testLFDelimitedIngestionRejectsMissingFinalLFWithoutMutation() throws {
    let parameters = try makeParameters(bitCount: 128, hashCount: 3)
    var filter = BloomFilter(parameters: parameters)
    filter.insert(Array("existing".utf8))
    let originalBytes = filter.bitVector

    XCTAssertThrowsError(
      try filter.insertLFDelimitedKeys(from: Array("one\ntwo".utf8))
    ) { error in
      XCTAssertEqual(
        error as? BloomFilterKeyFileError,
        .missingFinalLineFeed
      )
    }
    XCTAssertEqual(filter.bitVector, originalBytes)
  }

  func testLFDelimitedIngestionRejectsEmptyLinesWithoutMutation() throws {
    let parameters = try makeParameters(bitCount: 128, hashCount: 3)
    let cases: [(contents: String, lineNumber: Int)] = [
      ("\none\n", 1),
      ("one\n\ntwo\n", 2),
      ("one\n\n", 2),
    ]

    for ingestionCase in cases {
      var filter = BloomFilter(parameters: parameters)
      let originalBytes = filter.bitVector

      XCTAssertThrowsError(
        try filter.insertLFDelimitedKeys(
          from: Array(ingestionCase.contents.utf8)
        )
      ) { error in
        XCTAssertEqual(
          error as? BloomFilterKeyFileError,
          .emptyLine(lineNumber: ingestionCase.lineNumber)
        )
      }
      XCTAssertEqual(filter.bitVector, originalBytes)
    }
  }

  func testLFDelimitedIngestionRejectsCRBytesWithoutMutation() throws {
    let parameters = try makeParameters(bitCount: 128, hashCount: 3)
    var filter = BloomFilter(parameters: parameters)
    let originalBytes = filter.bitVector

    XCTAssertThrowsError(
      try filter.insertLFDelimitedKeys(from: Array("one\nb\rr\n".utf8))
    ) { error in
      XCTAssertEqual(
        error as? BloomFilterKeyFileError,
        .carriageReturn(lineNumber: 2, byteOffset: 5)
      )
    }
    XCTAssertEqual(filter.bitVector, originalBytes)
  }

  func testFalsePositiveRateStaysWithinLooseDeterministicBound() throws {
    let parameters = try BloomFilterParameters.sized(
      expectedKeyCount: 1_000,
      falsePositiveRate: 0.01,
      murmurSeed: 0x1020_3040
    )
    var filter = BloomFilter(parameters: parameters)

    for value in 0..<1_000 {
      filter.insert(deterministicKey(value))
    }

    let falsePositiveCount = (10_000..<15_000).reduce(into: 0) {
      count,
      value in
      if filter.mayContain(deterministicKey(value)) {
        count += 1
      }
    }

    XCTAssertLessThan(falsePositiveCount, 250)
  }

  private func makeParameters(
    bitCount: UInt32,
    hashCount: UInt32,
    murmurSeed: UInt32 = 0
  ) throws -> BloomFilterParameters {
    try BloomFilterParameters(
      bitCount: bitCount,
      hashCount: hashCount,
      murmurSeed: murmurSeed
    )
  }

  private func deterministicKey(_ value: Int) -> [UInt8] {
    let value = UInt32(truncatingIfNeeded: value)

    return [
      UInt8(truncatingIfNeeded: value),
      UInt8(truncatingIfNeeded: value >> 8),
      UInt8(truncatingIfNeeded: value >> 16),
      UInt8(truncatingIfNeeded: value >> 24),
    ]
  }

  private func captureLFDelimitedIngestionError(
    from fileBytes: some Collection<UInt8>,
    filter: inout BloomFilter,
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> BloomFilterKeyFileError? {
    do {
      let insertedKeyCount = try filter.insertLFDelimitedKeys(from: fileBytes)
      XCTFail(
        "Expected ingestion to throw; inserted \(insertedKeyCount) keys",
        file: file,
        line: line
      )
      return nil
    } catch let error as BloomFilterKeyFileError {
      return error
    } catch {
      XCTFail("Unexpected error: \(error)", file: file, line: line)
      return nil
    }
  }
}
