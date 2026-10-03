// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "ToggleLocalNetwork",
  platforms: [.macOS(.v15)],
  products: [
    .executable(name: "ToggleLocalNetwork", targets: ["ToggleLocalNetwork"])
  ],
  targets: [
    .target(name: "LocalNetworkCore"),
    .executableTarget(
      name: "ToggleLocalNetwork",
      dependencies: ["LocalNetworkCore"]
    ),
    .testTarget(
      name: "LocalNetworkCoreTests",
      dependencies: ["LocalNetworkCore"]
    ),
  ]
)
