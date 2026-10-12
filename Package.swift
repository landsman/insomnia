// swift-tools-version: 6.0
// For `swift test` and for editors. The app itself is still built by scripts/build.sh.
import PackageDescription

let package = Package(
    name: "Insomnia",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Insomnia", path: "Sources"),
        .testTarget(name: "InsomniaTests", dependencies: ["Insomnia"], path: "Tests"),
    ]
)
