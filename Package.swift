// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PrivDoc",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "PrivDoc", targets: ["PrivDoc"])
    ],
    targets: [
        .executableTarget(
            name: "PrivDoc",
            path: "Sources/PrivDoc",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CryptoKit")
            ]
        ),
        .testTarget(
            name: "PrivDocTests",
            dependencies: ["PrivDoc"],
            path: "Tests/PrivDocTests"
        )
    ]
)
