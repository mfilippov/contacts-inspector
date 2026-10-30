// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ContactsInspector",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/Swiftgram/TDLibKit", exact: "1.5.2-tdlib-1.8.69-fb464979"),
    ],
    targets: [
        .executableTarget(
            name: "ContactsInspector",
            dependencies: [.product(name: "TDLibKit", package: "TDLibKit")],
            path: "Sources/ContactsInspector"
        ),
        .testTarget(name: "ContactsInspectorTests", dependencies: ["ContactsInspector"], path: "Tests/ContactsInspectorTests"),
    ],
    swiftLanguageModes: [.v5]
)
