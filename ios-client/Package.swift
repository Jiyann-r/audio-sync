// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AudioSync",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(
            name: "AudioSyncCore",
            targets: ["AudioSyncCore"]
        )
    ],
    targets: [
        .target(
            name: "AudioSyncCore",
            path: "AudioSync",
            exclude: [
                "Info.plist",
                "AudioSyncApp.swift"
            ]
        )
    ]
)
