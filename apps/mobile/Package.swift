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
        .package(url: "https://source.skip.tools/skip.git", from: "1.0.0"),
        .package(url: "https://source.skip.tools/skip-ui.git", from: "1.0.0"),
        .package(url: "https://source.skip.tools/skip-foundation.git", from: "1.0.0"),
        .package(url: "https://source.skip.tools/skip-model.git", from: "1.0.0"),
        .package(url: "https://github.com/supabase-community/supabase-swift.git", from: "2.0.0"),
        .package(url: "https://github.com/RevenueCat/purchases-ios.git", from: "5.0.0")
    ],
    targets: [
        // Shared cross-platform code
        .target(
            name: "Shared",
            dependencies: [
                .product(name: "SkipFoundation", package: "skip-foundation"),
                .product(name: "SkipModel", package: "skip-model"),
                .product(name: "Supabase", package: "supabase-swift"),
                .product(name: "RevenueCat", package: "purchases-ios")
            ],
            path: "Sources/Shared",
            plugins: [.plugin(name: "skipstone", package: "skip")]
        ),
        // iOS App
        .target(
            name: "MeetingSchedulerApp",
            dependencies: [
                "Shared",
                .product(name: "SkipUI", package: "skip-ui")
            ],
            path: "Sources/MeetingSchedulerApp",
            plugins: [.plugin(name: "skipstone", package: "skip")]
        ),
        // Tests
        .testTarget(
            name: "MeetingSchedulerTests",
            dependencies: [
                "Shared",
                .product(name: "SkipTest", package: "skip")
            ],
            path: "Tests"
        )
    ]
)
