// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "google-tasks",
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .executableTarget(
            name: "google-tasks"
        ),
        .testTarget(
            name: "google-tasksTests",
            dependencies: ["google-tasks"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
