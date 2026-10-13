// swift-tools-version: 6.4
import PackageDescription

let package = Package(
  name: "Ediro",
  platforms: [.macOS(.v27)],
  dependencies: [
    .package(path: "Packages/SwiftEditorEngine")
  ],
  targets: [
    .target(name: "TextCheckingBridge"),
    .target(
      name: "EdiroCore",
      dependencies: [.product(name: "EditorMarkdown", package: "SwiftEditorEngine")],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .target(
      name: "EdiroUI",
      dependencies: [
        "EdiroCore", "TextCheckingBridge",
        .product(name: "EditorEngine", package: "SwiftEditorEngine"),
        .product(name: "EditorMarkdown", package: "SwiftEditorEngine"),
      ],
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
      dependencies: [
        "EdiroUI", "TestSupport", .product(name: "EditorEngine", package: "SwiftEditorEngine"),
        .product(name: "EditorMarkdown", package: "SwiftEditorEngine"),
      ],
      swiftSettings: [
        .defaultIsolation(MainActor.self),
        .swiftLanguageMode(.v6)
      ]
    )
  ]
)
