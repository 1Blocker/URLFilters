// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "BloomBuilderKit",
  products: [
    .library(
      name: "BloomBuilderKit",
      targets: ["BloomBuilderKit"]
    ),
    .executable(name: "bloombuilder", targets: ["BloomBuilderCLI"]),
  ],
  dependencies: [],
  targets: [
    .target(name: "BloomBuilderKit"),
    .executableTarget(
      name: "BloomBuilderCLI",
      dependencies: ["BloomBuilderKit"]
    ),
    .target(
      name: "BloomBuilderTestSupport",
      path: "Tests/BloomBuilderTestSupport"
    ),
    .testTarget(
      name: "BloomBuilderKitTests",
      dependencies: ["BloomBuilderKit", "BloomBuilderTestSupport"]
    ),
    .testTarget(
      name: "BloomBuilderCLITests",
      dependencies: ["BloomBuilderCLI", "BloomBuilderKit", "BloomBuilderTestSupport"]
    ),
  ],
  swiftLanguageModes: [.v6]
)
