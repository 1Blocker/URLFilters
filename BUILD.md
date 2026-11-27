# Building the NEURLFilter Bloom prefilter

Each release that carries this document conveys the prebuilt Bloom vector.
The `bloombuilder` command below produced it from the canonical and mandatory
key files.

The following deterministic record is part of this document's build contract.
Its input paths are relative to the publication-set root, and each digest is
SHA-256 over the file's exact bytes.

<!-- BEGIN NEURLFILTER BUILD DATA V2 -->
```json
{
  "bloomBuilderKit" : {
    "revision" : "5a2e0ee05b16119e445a4005f0c300e8c4b69ac1",
    "treeDigestAlgorithm" : "sha256-length-prefixed-path-and-content-v1",
    "treeSHA256" : "70af8c9665f73af8197bfdc43897e8b1232982563fdb387ce672f1dc739b2a59",
    "version" : "0.2.0"
  },
  "bloomParameters" : {
    "bitCount" : 1062864,
    "hashCount" : 17,
    "murmurSeed" : 2538058380
  },
  "command" : {
    "build" : {
      "arguments" : [
        "build",
        "-c",
        "release",
        "--product",
        "bloombuilder",
        "--scratch-path",
        "<scratch-path>"
      ],
      "executable" : "swift",
      "workingDirectory" : "BloomBuilderKit"
    },
    "run" : {
      "arguments" : [
        "--bit-count",
        "1062864",
        "--hash-count",
        "17",
        "--murmur-seed",
        "2538058380",
        "--output",
        "<output-path>",
        "layers/easylist/canonical-keys.txt",
        "mandatory-keys.txt"
      ],
      "executable" : "bloombuilder",
      "workingDirectory" : "."
    }
  },
  "expectedOutput" : {
    "byteCount" : 132858,
    "sha256" : "821d07f89703ea459ec8510a843cc5690a419c57142e4a12ba382c1c8be59b20"
  },
  "inputs" : [
    {
      "byteCount" : 848219,
      "path" : "layers/easylist/canonical-keys.txt",
      "sha256" : "e8b866b5238cdcd8d97403a015a72e9148e302c721a662cabc47a2b6ccfca7f4"
    },
    {
      "byteCount" : 61,
      "path" : "mandatory-keys.txt",
      "sha256" : "b066dcaaec87195e4bfb8cce06d17bfeea88c24e41817833936ffdd140d70fd5"
    }
  ],
  "observedSwiftCompilerIdentity" : "swift-driver version: 1.168.6 Apple Swift version 6.4.4 (swiftlang-6.4.4.3.6 clang-2100.5.3.3)",
  "swiftCompilerIdentity" : "swift-driver version: 1.148.6 Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)",
  "version" : 2
}
```
<!-- END NEURLFILTER BUILD DATA V2 -->

`BloomBuilderKit/VENDOR.json` records the same source revision and vendored-tree
identity. The Swift compiler identity records the pinned build environment for
the module.

Start at the root of the extracted source archive or the tag tree. Both contain
the publication set at their root, with the builder in `BloomBuilderKit/` and
the key files at the recorded input paths. Replace the angle-bracketed values
before running each command. Quote each path as needed and stop if a command
fails.

Choose an absolute path outside the tree for `<scratch-path>`. From the root,
enter the builder directory, build the product with the recorded arguments,
then locate it with the same arguments plus `--show-bin-path`.

```sh
cd BloomBuilderKit
swift build -c release --product bloombuilder --scratch-path <scratch-path>
swift build -c release --product bloombuilder --scratch-path <scratch-path> \
    --show-bin-path
```

Use the printed directory for `<bin-path>`. Return to the publication-set root
and run the located product with the bit count, hash count and Murmur seed
from `command.run.arguments`. Choose a fresh output path for `<output-path>`
where no file or directory exists. Replace `<inputs>` with every recorded
input path in the recorded order, one argument per path.

```sh
cd ..
"<bin-path>/bloombuilder" --bit-count <bit-count> --hash-count <hash-count> \
    --murmur-seed <seed> --output <output-path> <inputs>
```

Require exit status 0 before checking the output. Compare the byte count and
SHA-256 from these commands with `expectedOutput.byteCount` and
`expectedOutput.sha256` in the record. Both must match.

```sh
wc -c <output-path>
shasum -a 256 <output-path>
```
