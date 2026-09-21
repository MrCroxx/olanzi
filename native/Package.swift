// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Olanzi",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Olanzi", targets: ["OlanziApp"])],
    targets: [
        .target(name: "OlanziCore"),
        .executableTarget(name: "OlanziApp", dependencies: ["OlanziCore"]),
        .testTarget(name: "OlanziCoreTests", dependencies: ["OlanziCore"]),
        .testTarget(name: "OlanziAppTests", dependencies: ["OlanziApp", "OlanziCore"]),
    ],
    swiftLanguageModes: [.v5]
)
