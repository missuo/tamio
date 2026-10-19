// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TamioTerminal",
    defaultLocalization: "en",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "TamioTerminal", targets: ["TamioTerminal"]),
        .executable(name: "TamioConfigurationPreview", targets: ["TamioConfigurationPreview"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", exact: "2.2.2026100703"),
        .package(name: "TamioDesign", path: "../TamioDesign"),
    ],
    targets: [
        .target(
            name: "TamioTerminal",
            dependencies: [
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
                .product(name: "TamioDesign", package: "TamioDesign"),
            ],
            resources: [.process("Configuration/Resources")]
        ),
        .testTarget(name: "TamioTerminalTests", dependencies: ["TamioTerminal"]),
        .executableTarget(name: "TamioConfigurationPreview", dependencies: ["TamioTerminal"]),
    ]
)
