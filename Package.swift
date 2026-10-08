// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ms100bt-tool",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MS100BTKit", targets: ["MS100BTKit"]),
        .executable(name: "ms100bt", targets: ["ms100bt"]),
        .executable(name: "MS100BTManager", targets: ["MS100BTManager"]),
    ],
    targets: [
        // Protocol, Bluetooth transport, ZDL parsing and effect-index editing.
        .target(name: "MS100BTKit", linkerSettings: [.linkedFramework("IOBluetooth")]),
        // Command-line engine. The GUI runs it as a helper process.
        .executableTarget(name: "ms100bt", dependencies: ["MS100BTKit"]),
        // SwiftUI app with drag-and-drop effect management.
        .executableTarget(name: "MS100BTManager", dependencies: ["MS100BTKit"]),
    ],
    swiftLanguageVersions: [.v5]
)
