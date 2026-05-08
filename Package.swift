// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "google-tasks",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "GoogleTasksCore", targets: ["GoogleTasksCore"]),
        .executable(name: "google-tasks", targets: ["google-tasks"]),
        .executable(name: "google-tasks-selftest", targets: ["google-tasks-selftest"]),
        .executable(name: "google-tasks-icon", targets: ["google-tasks-icon"])
    ],
    targets: [
        .target(
            name: "GoogleTasksCore"
        ),
        .executableTarget(
            name: "google-tasks",
            dependencies: ["GoogleTasksCore"],
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ]
        ),
        .executableTarget(
            name: "google-tasks-selftest",
            dependencies: ["GoogleTasksCore"]
        ),
        .executableTarget(
            name: "google-tasks-icon"
        ),
    ],
    swiftLanguageModes: [.v6]
)
