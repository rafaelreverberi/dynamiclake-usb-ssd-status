// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "TransferCenter",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "TransferCore", targets: ["TransferCore"]),
        .executable(name: "transfer-center", targets: ["TransferCenter"]),
        .executable(name: "transfer-probe", targets: ["TransferProbe"]),
    ],
    targets: [
        .target(
            name: "TransferCore",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreServices"),
                .linkedFramework("DiskArbitration"),
            ]
        ),
        .executableTarget(name: "TransferCenter", dependencies: ["TransferCore"]),
        .executableTarget(name: "TransferProbe", dependencies: ["TransferCore"]),
        .testTarget(name: "TransferCoreTests", dependencies: ["TransferCore"]),
    ]
)
