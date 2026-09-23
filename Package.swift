// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ContactsInspector",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ContactsInspector", path: "Sources/ContactsInspector"),
        .testTarget(name: "ContactsInspectorTests", dependencies: ["ContactsInspector"], path: "Tests/ContactsInspectorTests"),
    ]
)
