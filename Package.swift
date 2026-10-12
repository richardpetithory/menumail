// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "menumail",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "menumail",
            path: "Sources/menumail",
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "menumailTests",
            dependencies: ["menumail"],
            path: "Tests/menumailTests",
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
    ]
)
