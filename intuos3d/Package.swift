// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "intuos3d",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "intuos3d",
            path: "Sources/intuos3d",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ApplicationServices"),
            ]
        )
    ]
)
