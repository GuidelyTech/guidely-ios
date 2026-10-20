// swift-tools-version:5.9
// Guidely native iOS SDK (https://guidelytech.com).
// Released from the Guidely monorepo by scripts/build-ios-mirror.sh; do not edit this repository directly.
import PackageDescription

let package = Package(
    name: "Guidely",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "Guidely", targets: ["Guidely"]),
    ],
    targets: [
        // Foundation-only engine: models, targeting, frequency, event queue, API client, step machine, feature flags.
        .target(name: "GuidelyCore", path: "Sources/GuidelyCore"),
        // Public API + UIKit/SwiftUI rendering (compiled only where UIKit exists).
        .target(name: "Guidely", dependencies: ["GuidelyCore"], path: "Sources/Guidely"),
    ]
)
