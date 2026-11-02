// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "k_id_core",
    platforms: [
        .iOS("15.0")
    ],
    products: [
        .library(name: "k-id-core", targets: ["k_id_core"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "k_id_core",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            resources: [
                .process("PrivacyInfo.xcprivacy")
            ]
        )
    ]
)
