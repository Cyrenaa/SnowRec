// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "LauncherApp",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", from: "0.5.0")
    ],
    targets: [
        .executableTarget(
            name: "LauncherApp",
            dependencies: [
                .product(name: "Subprocess", package: "swift-subprocess")
            ]
        )
    ]
)
