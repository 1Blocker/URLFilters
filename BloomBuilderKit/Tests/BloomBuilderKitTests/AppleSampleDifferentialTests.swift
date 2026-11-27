import Foundation
import XCTest

@testable import BloomBuilderKit

#if canImport(CryptoKit)
  import CryptoKit
#endif

final class AppleSampleDifferentialTests: XCTestCase {
  private static let sampleRootEnvironmentVariable =
    "BLOOM_BUILDER_KIT_APPLE_SAMPLE_ROOT"
  private static let inputURLsPath =
    "BloomFilterTool/BloomFilterTool/input_urls.txt"
  private static let bloomFilterPlistPath =
    "SimpleURLFilter/SimpleURLFilterExtension/bloom_filter.plist"
  private static let inputURLsSHA256 =
    "b216b1994409930ed7cbf2f1ee907b9d6293329dff134b2327acbd9e7aea54c2"
  private static let bloomFilterPlistSHA256 =
    "7ff2a88d6d722927c88556b20333efbf6b1c087babdde2f427c24cbc419ef816"

  func testConsumedFilesMatchPinnedSHA256Digests() throws {
    try requireFixtureAuthenticationSupport()
    let sample = try loadSample()

    #if canImport(CryptoKit)
      XCTAssertTrue(consumedFilesMatchPinnedDigests(sample))
    #endif
  }

  func testGeneratedFilterMatchesPublishedSample() throws {
    try requireFixtureAuthenticationSupport()
    let sample = try loadSample()

    #if canImport(CryptoKit)
      guard consumedFilesMatchPinnedDigests(sample) else {
        return
      }
    #endif

    let propertyListObject = try PropertyListSerialization.propertyList(
      from: sample.bloomFilterPlist,
      options: [],
      format: nil
    )
    let propertyList = try XCTUnwrap(
      propertyListObject as? [String: Any],
      "Expected the Bloom filter property list to contain a dictionary."
    )
    let bitCount = try uint32Value(for: "bitCount", in: propertyList)
    let byteCount = try intValue(for: "byteCount", in: propertyList)
    let expectedBytes = try XCTUnwrap(
      propertyList["data"] as? Data,
      "Expected the data property to contain Bloom filter bytes."
    )
    let falsePositiveRate = try doubleValue(
      for: "falsePositiveTolerance",
      in: propertyList
    )
    let hashCount = try uint32Value(for: "hashCount", in: propertyList)
    let itemCount = try intValue(for: "itemCount", in: propertyList)
    let murmurSeed = try uint32Value(for: "murmurSeed", in: propertyList)
    let input = try XCTUnwrap(
      String(data: sample.inputURLs, encoding: .utf8),
      "Expected the URL list to be valid UTF-8."
    )
    let keys = input.components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }

    XCTAssertEqual(keys.count, itemCount)
    XCTAssertEqual(expectedBytes.count, byteCount)

    let parameters = try BloomFilterParameters.sized(
      expectedKeyCount: itemCount,
      falsePositiveRate: falsePositiveRate,
      murmurSeed: murmurSeed
    )

    XCTAssertEqual(parameters.bitCount, bitCount)
    XCTAssertEqual(parameters.hashCount, hashCount)

    var filter = BloomFilter(parameters: parameters)
    for key in keys {
      filter.insert(key.utf8)
    }

    XCTAssertEqual(filter.bitVector, [UInt8](expectedBytes))

    let deserialized = try BloomFilter(
      parameters: parameters,
      bytes: expectedBytes
    )
    XCTAssertEqual(deserialized.bitVector, [UInt8](expectedBytes))
  }

  private func requireFixtureAuthenticationSupport() throws {
    #if !canImport(CryptoKit)
      throw XCTSkip(
        "CryptoKit is unavailable; skipping the Apple-sample differential "
          + "because its fixtures cannot be authenticated."
      )
    #endif
  }

  private func loadSample() throws -> AppleSample {
    let environment = ProcessInfo.processInfo.environment
    guard
      let rootPath = environment[Self.sampleRootEnvironmentVariable],
      !rootPath.isEmpty
    else {
      throw XCTSkip(
        "Set \(Self.sampleRootEnvironmentVariable) to the extracted "
          + "FilteringTrafficByURL sample root to run this differential."
      )
    }

    let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
    return try AppleSample(
      inputURLs: Data(
        contentsOf: rootURL.appendingPathComponent(Self.inputURLsPath)
      ),
      bloomFilterPlist: Data(
        contentsOf: rootURL.appendingPathComponent(
          Self.bloomFilterPlistPath
        )
      )
    )
  }

  private func intValue(
    for key: String,
    in propertyList: [String: Any]
  ) throws -> Int {
    let number = try XCTUnwrap(
      propertyList[key] as? NSNumber,
      "Expected \(key) to contain a number."
    )
    let value = number.doubleValue
    let integer =
      value.isFinite && value.rounded(.towardZero) == value
      ? Int(exactly: number.int64Value)
      : nil

    return try XCTUnwrap(integer, "Expected \(key) to contain an integer.")
  }

  private func uint32Value(
    for key: String,
    in propertyList: [String: Any]
  ) throws -> UInt32 {
    let value = try intValue(for: key, in: propertyList)
    return try XCTUnwrap(
      UInt32(exactly: value),
      "Expected \(key) to fit UInt32."
    )
  }

  private func doubleValue(
    for key: String,
    in propertyList: [String: Any]
  ) throws -> Double {
    let number = try XCTUnwrap(
      propertyList[key] as? NSNumber,
      "Expected \(key) to contain a number."
    )
    return number.doubleValue
  }

  #if canImport(CryptoKit)
    private func consumedFilesMatchPinnedDigests(
      _ sample: AppleSample
    ) -> Bool {
      let inputURLsDigest = sha256HexDigest(sample.inputURLs)
      let bloomFilterPlistDigest = sha256HexDigest(sample.bloomFilterPlist)

      XCTAssertEqual(
        inputURLsDigest,
        Self.inputURLsSHA256,
        "The consumed URL list does not match the pinned sample file."
      )
      XCTAssertEqual(
        bloomFilterPlistDigest,
        Self.bloomFilterPlistSHA256,
        "The consumed Bloom filter plist does not match the pinned sample file."
      )

      return inputURLsDigest == Self.inputURLsSHA256
        && bloomFilterPlistDigest == Self.bloomFilterPlistSHA256
    }

    private func sha256HexDigest(_ data: Data) -> String {
      SHA256.hash(data: data).map {
        String(format: "%02x", $0)
      }.joined()
    }
  #endif
}

private struct AppleSample {
  let inputURLs: Data
  let bloomFilterPlist: Data
}
