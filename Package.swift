// swift-tools-version:5.9
// Unit tests for Notch Agent's pure parsing code. Run with `swift test` from the repo root.
// (The app itself is built from boringNotch.xcodeproj.)
import PackageDescription

let package = Package(
    name: "NotchAgentTests",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "RequestParsing", path: "boringNotch/components/Agent/Parsing"),
        .testTarget(name: "RequestParsingTests", dependencies: ["RequestParsing"], path: "Tests/RequestParsingTests"),
    ]
)
