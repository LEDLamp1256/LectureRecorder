// swift-tools-version: 6.2
import PackageDescription

/// Local wrapper package around FluidAudio, for the same reason as
/// `Dependencies/MLXRuntime`: a plain Xcode project cannot express SwiftPM
/// traits, and FluidAudio's default-on `NemoTextProcessing` trait links a
/// prebuilt text-normalization binary that speaker diarization never uses.
/// Declaring the dependency here with `traits: []` leaves it out. The single
/// target is a trivial re-export of FluidAudio's library product.
///
/// FluidAudio is pinned to the exact commit of release v0.16.1. That release
/// itself pins the `FluidInference/speaker-diarization-coreml` model repo to
/// revision df2625ac79a7ac6b65ad868fee6d80f320da4232 — the same revision
/// `Scripts/provision-fluidaudio-diarization-model.sh` stages. The app never
/// uses FluidAudio's model downloader.
let package = Package(
    name: "DiarizationRuntime",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "DiarizationRuntimeFluidAudio", targets: ["DiarizationRuntimeFluidAudio"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/FluidInference/FluidAudio",
            revision: "b811a61569aa02691c99b808d08ee989b630c133",
            traits: []
        ),
    ],
    targets: [
        .target(
            name: "DiarizationRuntimeFluidAudio",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/DiarizationRuntimeFluidAudio"
        ),
    ]
)
