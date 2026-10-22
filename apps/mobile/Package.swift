// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MeetingScheduler",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v26)
    ],
    products: [
        .library(
            name: "MeetingSchedulerApp",
            targets: ["MeetingSchedulerApp"]
        ),
        .library(
            name: "Shared",
            targets: ["Shared"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/supabase-community/supabase-swift.git", from: "2.0.0"),
        // Includes the upstream PaywallColor initializer fix for Xcode 27 / Swift 6.4.
        .package(url: "https://github.com/RevenueCat/purchases-ios.git", from: "5.97.0"),
    ],
    targets: [
        // Shared cross-platform code
        .target(
            name: "Shared",
            dependencies: [
                .product(name: "Supabase", package: "supabase-swift"),
                .product(name: "RevenueCat", package: "purchases-ios")
            ],
            path: "Sources/Shared"
        ),
        // iOS App
        .target(
            name: "MeetingSchedulerApp",
            dependencies: [
                "Shared",
            ],
            path: "Sources/MeetingSchedulerApp"
        ),
        // Tests
        .testTarget(
            name: "MeetingSchedulerTests",
            dependencies: [
                "Shared",
            ],
            path: "Tests"
        )
    ]
)
