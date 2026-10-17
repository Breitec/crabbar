// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "ClawdCore",
  platforms: [.macOS(.v15), .iOS(.v18)],
  products: [
    .library(name: "ClawdCore", targets: ["ClawdCore"])
  ],
  targets: [
    .target(
      name: "ClawdCore",
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .testTarget(
      name: "ClawdCoreTests",
      dependencies: ["ClawdCore"],
      resources: [.copy("Fixtures")],
      swiftSettings: [.swiftLanguageMode(.v5)]
    )
  ]
)
