// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FactorySwitcher",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SwitcherCore", targets: ["SwitcherCore"]),
        .executable(name: "FactorySwitcher", targets: ["FactorySwitcher"]),
    ],
    targets: [
        .target(name: "SwitcherCore"),
        .executableTarget(name: "FactorySwitcher", dependencies: ["SwitcherCore"]),
        .testTarget(name: "SwitcherCoreTests", dependencies: ["SwitcherCore"]),
    ],
    swiftLanguageModes: [.v5]
)
