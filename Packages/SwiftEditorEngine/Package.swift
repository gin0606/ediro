// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftEditorEngine",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "EditorEngine", targets: ["EditorEngine"]),
        .executable(name: "editor-example", targets: ["EditorExample"]),
        .executable(name: "editor-benchmark", targets: ["EditorBenchmark"])
    ],
    targets: [
        .target(name: "EditorEngine"),
        .executableTarget(name: "EditorExample", dependencies: ["EditorEngine"]),
        .executableTarget(name: "EditorBenchmark", dependencies: ["EditorEngine"]),
        .testTarget(name: "EditorEngineTests", dependencies: ["EditorEngine"])
    ]
)
