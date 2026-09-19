// swift-tools-version: 6.2
import PackageDescription

/// Local wrapper package around `mlx-swift-lm` and `swift-transformers`.
///
/// `LectureRecorder.xcodeproj` is a plain Xcode project with no app-level
/// `Package.swift`, so it has no manifest of its own in which to disable
/// `mlx-swift-lm`'s default-on `FoundationModelsIntegration` trait (SwiftPM
/// traits are configured at the `.package(...)` dependency-declaration site,
/// which only a manifest — never a bare Xcode project — can express). This
/// wrapper exists solely to hold that one dependency declaration; each
/// target below is a trivial re-export of one upstream library product so
/// the Xcode project can depend on this package locally and link the
/// individual products it needs.
let package = Package(
    name: "MLXRuntime",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MLXRuntimeMLX", targets: ["MLXRuntimeMLX"]),
        .library(name: "MLXRuntimeLLM", targets: ["MLXRuntimeLLM"]),
        .library(name: "MLXRuntimeLMCommon", targets: ["MLXRuntimeLMCommon"]),
        .library(name: "MLXRuntimeGuidedGeneration", targets: ["MLXRuntimeGuidedGeneration"]),
        .library(name: "MLXRuntimeTokenizers", targets: ["MLXRuntimeTokenizers"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/ml-explore/mlx-swift-lm",
            revision: "c6446cf7bfb7cea76408013b614d4b2c530eaa03",
            traits: []
        ),
        // Already a transitive dependency of mlx-swift-lm (its `MLX` product
        // declares `MLXArray`, which every direct consumer of `MLXLMCommon`
        // needs in scope, e.g. to construct `LMInput.Text(tokens:)`) —
        // declared directly here only so this wrapper has a product to
        // re-export; not a new or unrelated dependency.
        .package(
            url: "https://github.com/ml-explore/mlx-swift",
            .upToNextMinor(from: "0.31.6")
        ),
        .package(
            url: "https://github.com/huggingface/swift-transformers",
            exact: "1.3.4"
        ),
    ],
    targets: [
        .target(
            name: "MLXRuntimeMLX",
            dependencies: [.product(name: "MLX", package: "mlx-swift")],
            path: "Sources/MLXRuntimeMLX"
        ),
        .target(
            name: "MLXRuntimeLLM",
            dependencies: [.product(name: "MLXLLM", package: "mlx-swift-lm")],
            path: "Sources/MLXRuntimeLLM"
        ),
        .target(
            name: "MLXRuntimeLMCommon",
            dependencies: [.product(name: "MLXLMCommon", package: "mlx-swift-lm")],
            path: "Sources/MLXRuntimeLMCommon"
        ),
        .target(
            name: "MLXRuntimeGuidedGeneration",
            dependencies: [.product(name: "MLXGuidedGeneration", package: "mlx-swift-lm")],
            path: "Sources/MLXRuntimeGuidedGeneration"
        ),
        .target(
            name: "MLXRuntimeTokenizers",
            dependencies: [.product(name: "Tokenizers", package: "swift-transformers")],
            path: "Sources/MLXRuntimeTokenizers"
        ),
    ]
)
