# BloomBuilderKit

BloomBuilderKit is a dependency-free, pure-Swift package for constructing
Bloom prefilters compatible with Apple's NEURLFilter format. It implements the
format's 32-bit FNV-1a and MurmurHash3 double hashing and produces a canonical,
byte-stable bit vector suitable for building, distributing, and merging
filters across processes and platforms.

## Installation

Add BloomBuilderKit to a Swift package manifest and use an appropriate release
version:

```swift
dependencies: [
  .package(
    url: "https://github.com/1Blocker/BloomBuilderKit.git",
    .upToNextMinor(from: "0.2.0")
  )
]
```

Then add the product to a target:

```swift
.target(
  name: "YourTarget",
  dependencies: ["BloomBuilderKit"]
)
```

In Xcode, the same dependency can be added with **File > Add Package
Dependencies**.

## Usage

### Build and serialize a filter from an LF-delimited key file

Choose parameters for the expected number of distinct keys and the desired
false-positive rate, then ingest the file's raw bytes:

```swift
import BloomBuilderKit
import Foundation

let parameters = try BloomFilterParameters.sized(
  expectedKeyCount: 50_000,
  falsePositiveRate: 0.001,
  murmurSeed: 0x1234_5678
)

let keyFileURL = URL(fileURLWithPath: "keys.txt")
let keyFileBytes = try Data(contentsOf: keyFileURL, options: [.alwaysMapped])
var filter = BloomFilter(parameters: parameters)
let insertedRecordCount = try filter.insertLFDelimitedKeys(
  from: keyFileBytes
)

let serializedURL = URL(fileURLWithPath: "filter.bin")
try Data(filter.bitVector).write(to: serializedURL)
```

LF ingestion is intentionally strict. Every key, including the last, must end
with LF (`0x0a`). Empty lines and CR (`0x0d`) bytes are rejected, and malformed
input never partially mutates the filter. Keys are raw byte sequences: the
package does not trim, decode, case-fold, or otherwise normalize them. The
returned record count includes duplicates, although duplicate insertions do
not change the serialized filter.

The parameters are metadata, not part of `bitVector`; persist or convey them
alongside the bytes. Deserialization validates the canonical representation:

```swift
let serializedBytes = try Data(contentsOf: serializedURL)
let restoredFilter = try BloomFilter(
  parameters: parameters,
  bytes: serializedBytes
)
```

### OR-merge filters from separate key files

Filters can be built independently and OR-merged only when `bitCount`,
`hashCount`, and `murmurSeed` are identical. Size the shared parameters for the
expected combined key set, not for each partition in isolation:

```swift
func buildPartialFilter(
  from keyFileURL: URL,
  parameters: BloomFilterParameters
) throws -> BloomFilter {
  let bytes = try Data(contentsOf: keyFileURL, options: [.alwaysMapped])
  var filter = BloomFilter(parameters: parameters)
  try filter.insertLFDelimitedKeys(from: bytes)
  return filter
}

let sharedParameters = try BloomFilterParameters.sized(
  expectedKeyCount: 100_000,
  falsePositiveRate: 0.001,
  murmurSeed: 0x1234_5678
)
var primaryFilter = try buildPartialFilter(
  from: URL(fileURLWithPath: "primary-keys.txt"),
  parameters: sharedParameters
)
let supplementalFilter = try buildPartialFilter(
  from: URL(fileURLWithPath: "supplemental-keys.txt"),
  parameters: sharedParameters
)

try primaryFilter.formUnion(supplementalFilter)
let mergedBytes = Data(primaryFilter.bitVector)
```

### Check membership

Pass exactly the same raw key bytes used by the producer:

```swift
if restoredFilter.mayContain("example.com/path".utf8) {
  // The key may be present; Bloom filters can return false positives.
} else {
  // The key is definitely absent.
}
```

### Memory-constrained processes

App extensions run under tight physical-memory limits, and iOS enforces them
against the dirty footprint, not resident size. Two practices keep
BloomBuilderKit's footprint near the size of the bit vector itself
(`byteCount`, about 1.8 bytes per key at a 0.001 false-positive rate):

- Supply file-mapped bytes to `insertLFDelimitedKeys` and to
  deserialization, as the examples above do. Mapped input
  (`Data(contentsOf:options:[.alwaysMapped])`) uses the same specialized
  contiguous scan as an array while its pages stay clean and file-backed, so
  a build costs the filter's size rather than the key file's. Loading the
  file into an array instead can dirty tens of megabytes at large key
  counts. The mapped file must stay unchanged on disk while the `Data` is
  alive; replace filter and key files atomically.
- Serialize through the borrowed view instead of copying the vector:

  ```swift
  try filter.withUnsafeBitVectorBytes { bytes in
    let borrowed = Data(
      bytesNoCopy: UnsafeMutableRawPointer(mutating: bytes.baseAddress!),
      count: bytes.count,
      deallocator: .none
    )
    // The borrowed Data must not outlive the closure.
    try borrowed.write(to: serializedURL)
  }
  ```

  `Data(filter.bitVector)` also works but transiently doubles the
  vector-sized footprint.

A release pipeline can build and serialize filters in CI. An app or extension
can instead receive key files, rebuild the same filter on-device, and OR-merge
compatible partitions. Projects that vendor the package can use it as the
reference builder shipped with each release.

## Command-line builder

`bloombuilder` builds one raw packed vector from one or more key files and
explicit parameters. From the package root, whether in a checkout or a
vendored copy, build the command and locate its executable with SwiftPM:

```sh
swift build -c release --product bloombuilder
bin_dir=$(swift build -c release --product bloombuilder --show-bin-path)
"$bin_dir/bloombuilder" --help
```

To keep the source tree unmodified, put build products in a scratch directory
outside it. Use the same configuration and scratch path to locate the binary:

```sh
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/bloombuilder-build.XXXXXX")
swift build -c release --product bloombuilder --scratch-path "$build_dir"
bin_dir=$(swift build -c release --product bloombuilder \
  --scratch-path "$build_dir" --show-bin-path)
"$bin_dir/bloombuilder" --help
```

With `bin_dir` set by either form, this complete example creates synthetic
keys and builds a vector. Keep the input and output files outside the source
tree as well; `TMPDIR`, if set, must point outside that tree.

```sh
example_dir=$(mktemp -d "${TMPDIR:-/tmp}/bloombuilder-example.XXXXXX")
printf '%s\n' 'alpha.example' 'beta.example/path?query=1' 'gamma.example' \
  > "$example_dir/keys.txt"
"$bin_dir/bloombuilder" --bit-count 37 --hash-count 5 \
  --murmur-seed 305419896 --output "$example_dir/filter.bin" \
  "$example_dir/keys.txt"
```

The result is exactly five bytes: `60 4a 41 c0 05` in hexadecimal. Compare the
bytes and calculate their SHA-256 digest:

```sh
printf '\140\112\101\300\005' > "$example_dir/expected.bin"
cmp "$example_dir/expected.bin" "$example_dir/filter.bin"
shasum -a 256 "$example_dir/filter.bin"
```

`cmp` exits 0 without output when the files match. On Linux, use
`sha256sum "$example_dir/filter.bin"` in place of `shasum -a 256`. The expected
digest is:

```text
6bf9876c2d9d55c075747879566e6267c824f2885ca65cb9b331a6ccd69c5a3f
```

Remove the example files with `rm -rf "$example_dir"` when finished. If you
used an external build directory, also remove it with `rm -rf "$build_dir"`.
The same exported-copy build and byte comparison can be checked from the
package root with `sh .github/scripts/check-exported-tree.sh`; it also verifies
that the copy is unchanged and removes its temporary files.

All four options are required and accept either `--name <value>` or
`--name=<value>`. Numeric values must be ASCII decimal integers that fit in
`UInt32` (`0...4294967295`), without signs, whitespace, hex prefixes, or
separators. Bit and hash counts must be positive; seed 0 is valid. The command
uses these values directly, without choosing a size or seed. Options may
precede or follow input paths. Use `--` before input paths beginning with a
dash; every argument after it is an input path. For an output path beginning
with a dash, use `--output=-name`.

Each key is a raw byte sequence terminated by LF (`0x0a`), including the last
key in each file. Empty lines and CR (`0x0d`) bytes are rejected. No trimming,
text decoding, case-folding, or normalization is performed; whitespace, NUL,
and invalid UTF-8 remain significant bytes. An empty file contributes zero
keys, but at least one input path is required. All inputs feed one filter;
their order, duplicate keys, and repeated file paths do not affect its bytes.
Keep input files unchanged while the command reads them.

The output follows the
[normative serialization contract](#normative-serialization-contract):
exactly `(bitCount + 7) / 8` bytes, with no header or trailing newline. The
parameters are not in the output file and must be conveyed with it.

An existing file, directory, symlink, or dangling symlink at the destination
is refused and left untouched. All inputs must be accepted before any output
is created. The vector is written directly to a newly created destination
file. A failure while writing removes the incomplete file, so a nonzero status
means the command left nothing at the destination. If the process is killed
or the machine stops while writing, an incomplete file can remain; status 0
is the only signal that the vector is complete.

Exit status is 0 on success or `--help`, which prints usage to stdout. Every
failure returns status 1 with one diagnostic on stderr. Input diagnostics
name the file and include the line for an empty line, or the line and
zero-based byte offset for CR; a missing final LF has no location detail.
The stdout success summary is informational only, not a machine-readable
interface. A summary that cannot be printed does not change status 0. Check
the exit status and output bytes when automating builds.

## Normative serialization contract

`BloomFilter.bitVector` is only the packed bit vector. Its parameters must be
stored separately and must be known before the bytes can be interpreted.

### Parameters and sizing

`bitCount`, `hashCount`, and `murmurSeed` are unsigned 32-bit values;
`bitCount` and `hashCount` must be positive. Given an expected distinct-key
count `n` and false-positive rate `p`, `BloomFilterParameters.sized` uses:

```text
bitCount  = ceil(-n * ln(p) / ln(2)^2)
hashCount = ceil((bitCount / n) * ln(2))
```

Both results round upward and must fit in `UInt32`.

### Hashing and probes

For each raw key byte sequence, calculate 32-bit FNV-1a and MurmurHash3 x86_32.
All hash and probe arithmetic is unsigned 32-bit wrapping arithmetic.
MurmurHash3 uses the filter's `murmurSeed`. For probe indices
`i = 0 ..< hashCount`, set:

```text
pos_i = (fnv1a(key) + i * murmur3(key, seed)) mod bitCount
```

The addition and multiplication are unsigned 32-bit wrapping operations. In
other words, the double-hash expression wraps modulo `2^32` before the final
modulo by `bitCount`.

### Bit packing and canonical validation

Bits are packed least-significant-bit first. Position `pos` maps to:

```text
byte index = pos >> 3
bit index  = pos & 7
mask       = 1 << bit index
```

The serialized byte length is exactly `(bitCount + 7) / 8`, where `/` is
integer division and the addition is evaluated without 32-bit overflow. If
`bitCount` is not byte-aligned, every high bit in the final byte beyond
`bitCount` must be zero. BloomBuilderKit maintains those padding bits as zero
after insertion and union, and deserialization rejects rather than masks a
noncanonical final byte.

This zero-padding rule is the canonical fail-closed policy: malformed input is
not silently normalized, so byte equality remains meaningful and bitwise OR
merges cannot preserve hidden out-of-range state. With fixed parameters, the
bit vector depends only on the set of raw keys. Insertion order and duplicate
insertions do not affect the serialized bytes.

## Conformance

Serialization is verified by an opt-in differential test against Apple's
published [Filtering Traffic by URL sample](https://docs-assets.developer.apple.com/published/ab6517c07cf8/FilteringTrafficByURL.zip).
The pinned archive SHA-256 is
`f77eb013b334790a6e42c44f529170119588d2c90f9cc97a7b44d6519cd310d2`.
No Apple sample files or expected output bytes are stored in this repository.

Download the archive, verify that digest, extract it, and point the test at the
extraction root:

```sh
BLOOM_BUILDER_KIT_APPLE_SAMPLE_ROOT=/path/to/FilteringTrafficByURL swift test --filter AppleSampleDifferentialTests
```

The root must contain
`BloomFilterTool/BloomFilterTool/input_urls.txt` and
`SimpleURLFilter/SimpleURLFilterExtension/bloom_filter.plist`. When the
environment variable is absent, the differential tests report a clear skip so
public CI does not require the downloaded sample.

## Versioning

Byte-output invariance across all BloomBuilderKit versions is the compatibility
contract. This serialization is consumed as a device-enforced format, so any
change that affects output bytes requires a coordinated format migration; it
is never a routine package version bump. Frozen golden vectors and the Apple
sample differential enforce that contract.

The command uses the library's serialization directly and defines no separate
format. With the same raw keys and parameters, its output bytes are invariant
across package versions and platforms.

BloomBuilderKit is pre-1.0 while its initial public API and release process are
being established. During this period, select an explicit compatible minor
release range while continuing to treat serialized output as invariant.

## Platform support

The library has no runtime dependencies and no explicit SwiftPM platform
constraint. It is pure Swift and is tested for use on macOS, iOS, and Linux
with Swift 6 or newer. Foundation is not required by the library; the command
and examples use it for file I/O. The command is built and tested on macOS and
Linux with Swift 6 or newer.

## License

BloomBuilderKit is available under the MIT License. See [LICENSE](LICENSE).
