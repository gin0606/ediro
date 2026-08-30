// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "Ediro",
  platforms: [.macOS(.v26)],
  targets: [
    .target(
      name: "EdiroCore",
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .target(
      name: "EdiroUI",
      dependencies: ["EdiroCore"],
      swiftSettings: [
        // UI 層はほぼ全てメインスレッド上で動くため、既定の隔離を MainActor にする。
        .defaultIsolation(MainActor.self),
        .swiftLanguageMode(.v6)
      ]
    ),
    .target(
      name: "TestSupport",
      dependencies: ["EdiroCore"],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .executableTarget(
      name: "Ediro",
      dependencies: ["EdiroUI"],
      swiftSettings: [
        .defaultIsolation(MainActor.self),
        .swiftLanguageMode(.v6)
      ]
    ),
    .testTarget(
      name: "EdiroCoreTests",
      dependencies: ["EdiroCore", "TestSupport"],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .testTarget(
      name: "EdiroUITests",
      dependencies: ["EdiroUI", "TestSupport"],
      swiftSettings: [
        .defaultIsolation(MainActor.self),
        .swiftLanguageMode(.v6)
      ]
    )
  ]
)
