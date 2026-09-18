// swift-tools-version: 6.0
import PackageDescription

// Standalone engine for the Fabric Math Expression node: the MathExpressionEngine
// target has no package dependencies and no Fabric / Metal / Satin, so a host that
// evaluates expressions links nothing else, and the correctness suite runs with no
// GPU or app. Transforms/quaternions use Apple `simd` at the port boundary, so it
// targets Apple platforms.
//
// MathExpressionEditorSupport is a second product, for a host that edits expressions
// rather than only evaluating them. It is what pulls in CodeEditorView: a host that
// does not link it does not build it, though running this package's own tests does.
// The platform floor below is CodeEditorView's, and SwiftPM declares platforms per
// package rather than per target, so the engine target carries it too.
let package = Package(
    name: "MathExpressionEngine",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "MathExpressionEngine", targets: ["MathExpressionEngine"]),
        .library(name: "MathExpressionEditorSupport", targets: ["MathExpressionEditorSupport"]),
    ],
    dependencies: [
        .package(url: "https://github.com/bradhowes/swift-math-parser", exact: "3.7.3"),
        .package(url: "https://github.com/mchakravarty/CodeEditorView.git", from: "0.7.0"),
    ],
    targets: [
        .target(name: "MathExpressionEngine"),
        .target(
            name: "MathExpressionEditorSupport",
            dependencies: [
                "MathExpressionEngine",
                .product(name: "LanguageSupport", package: "CodeEditorView"),
            ]
        ),
        .testTarget(
            name: "MathExpressionEngineTests",
            dependencies: [
                "MathExpressionEngine",
                .product(name: "MathParser", package: "swift-math-parser"),
            ]
        ),
        .testTarget(
            name: "MathExpressionEditorSupportTests",
            dependencies: ["MathExpressionEditorSupport"]
        ),
    ]
)
