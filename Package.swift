// swift-tools-version: 5.5
import PackageDescription

let package = Package(
    name: "lil-agents",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "lil agents",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "LilAgents",
            exclude: [
                "Info.plist",
                "LilAgents.entitlements"
            ],
            resources: [
                .copy("walk-bruce-01.mov"),
                .copy("walk-jazz-01.mov"),
                .copy("Assets.xcassets"),
                .copy("Sounds"),
                .copy("menuicon.png"),
                .copy("menuicon-2x.png"),
            ]
        )
    ]
)
