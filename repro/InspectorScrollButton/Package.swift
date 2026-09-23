// swift-tools-version:6.0
import PackageDescription
let package = Package(
    name: "InspectorScrollButton",
    platforms: [.macOS(.v15)],
    targets: [.executableTarget(name: "InspectorScrollButton", path: "Sources/InspectorScrollButton")],
    swiftLanguageModes: [.v5]
)
