// swift-tools-version: 6.1
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
            type: .dynamic,
            targets: ["ZeroSettleKit"]
        ),
    ],

    // MARK: - Traits
    traits: [
        .trait(
            name: "NativePay",
            description: "Enables native Apple Pay checkout via Stripe STPApplePayContext"
        ),
    ],

    // MARK: - Dependencies
    dependencies: [
        .package(url: "https://github.com/stripe/stripe-ios.git", from: "24.0.0"),
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
                .product(
                    name: "StripeApplePay",
                    package: "stripe-ios",
                    condition: .when(traits: ["NativePay"])
                ),
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
