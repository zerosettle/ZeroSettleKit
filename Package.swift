// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ZeroSettleKit",
    platforms: [
        .iOS(.v17)
    ],

    // MARK: - Products
    products: [
        .library(
            name: "ZeroSettleKit",
            targets: ["ZeroSettleKit"]
        ),
    ],

    // MARK: - Targets
    targets: [
        // Internal: ZeroSettleCore (logging, HTTP, extensions)
        .target(
            name: "ZeroSettleCore",
            dependencies: [],
            path: "Sources/ZeroSettleCore"
        ),

        // Public: ZeroSettleKit (Merchant of Record web checkout)
        .target(
            name: "ZeroSettleKit",
            dependencies: [
                "ZeroSettleCore",
            ],
            path: "Sources/ZeroSettleKit",
            swiftSettings: [
                .define("DEBUG", .when(configuration: .debug)),
            ]
        ),

        // Tests
        .testTarget(
            name: "ZeroSettleCoreTests",
            dependencies: ["ZeroSettleCore"],
            path: "Tests/ZeroSettleCoreTests"
        ),
        .testTarget(
            name: "ZeroSettleKitTests",
            dependencies: ["ZeroSettleKit"],
            path: "Tests/ZeroSettleKitTests"
        ),
    ]
)
