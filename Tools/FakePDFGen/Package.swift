// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "FakePDFGen",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "FakePDFGen",
            targets: ["FakePDFGen"]
        )
    ],
    targets: [
        .executableTarget(
            name: "FakePDFGen"
        )
    ]
)
