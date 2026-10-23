// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Earshot",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Earshot", targets: ["Earshot"]),
        .executable(name: "earshot-hook", targets: ["earshot-hook"]),
    ],
    targets: [
        .target(name: "EarshotCore"),
        .executableTarget(name: "earshot-hook", dependencies: ["EarshotCore"], path: "Sources/EarshotHook"),
        .executableTarget(name: "Earshot", dependencies: ["EarshotCore"], path: "Sources/EarshotApp"),
        .testTarget(name: "EarshotCoreTests", dependencies: ["EarshotCore"], resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v5]
)
