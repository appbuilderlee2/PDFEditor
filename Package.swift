// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "PDFEditor",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "PDFEditor", targets: ["PDFEditorApp"]),
    ],
    dependencies: [
        // No external dependencies for Phase 1 - using Apple PDFKit only
    ],
    targets: [
        .executableTarget(
            name: "PDFEditorApp",
            dependencies: [],
            path: "Sources",
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .define("DEBUG", .when(configuration: .debug)),
            ]
        ),
        .testTarget(
            name: "PDFEditorTests",
            dependencies: ["PDFEditorApp"],
            path: "Tests",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
    ]
)