// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MacdowsCommander",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0"),
        .package(url: "https://github.com/SDWebImage/libwebp-Xcode.git", exact: "1.5.0"),
    ],
    targets: [
        .target(name: "CCurlShim", linkerSettings: [.linkedLibrary("curl")]),
        .target(name: "MacdowsCore", dependencies: ["CCurlShim", .product(name: "libwebp", package: "libwebp-Xcode")]),
        .executableTarget(name: "MacdowsCommander", dependencies: ["MacdowsCore", .product(name: "SwiftTerm", package: "SwiftTerm")]),
        .testTarget(name: "MacdowsCoreTests", dependencies: ["MacdowsCore"]),
        .testTarget(name: "MacdowsCommanderTests", dependencies: ["MacdowsCommander"]),
    ]
)
