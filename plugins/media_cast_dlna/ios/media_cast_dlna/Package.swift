// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.
import PackageDescription

let package = Package(
    name: "media_cast_dlna",
    platforms: [
        .iOS("14.0")
    ],
    products: [
        .library(name: "media-cast-dlna", targets: ["media_cast_dlna"])
    ],
    dependencies: [
        .package(url: "https://github.com/katoemba/SwiftUPnP.git", branch: "main")
    ],
    targets: [
        .target(
            name: "media_cast_dlna",
            dependencies: [
                .product(name: "SwiftUPnP", package: "SwiftUPnP")
            ],
            resources: [
                .process("PrivacyInfo.xcprivacy")
            ]
        )
    ]
)
