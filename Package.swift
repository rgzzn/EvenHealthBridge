// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "EvenHealthCore",
    platforms: [.iOS(.v27), .macOS(.v15)],
    products: [.library(name: "EvenHealthCore", targets: ["EvenHealthCore"])],
    dependencies: [.package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.0")],
    targets: [
        .target(name: "EvenHealthCore", dependencies: ["ZIPFoundation"]),
        .testTarget(name: "EvenHealthCoreTests", dependencies: ["EvenHealthCore", "ZIPFoundation"])
    ]
)
