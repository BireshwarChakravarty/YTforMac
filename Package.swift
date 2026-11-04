// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Encore",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Encore", targets: ["Encore"])
    ],
    targets: [
        .executableTarget(
            name: "Encore",
            path: "Sources/Encore",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("WebKit"),
                .linkedFramework("MediaPlayer"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Speech"),
                .linkedFramework("AVFoundation")
            ]
        )
    ]
)
