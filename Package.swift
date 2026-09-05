// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GlobalTranslator",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "GlobalTranslatorCore", targets: ["GlobalTranslatorCore"]),
        .library(name: "GlobalTranslatorRuntime", targets: ["GlobalTranslatorRuntime"]),
        .library(name: "GlobalTranslatorCapture", targets: ["GlobalTranslatorCapture"]),
        .library(name: "GlobalTranslatorEngine", targets: ["GlobalTranslatorEngine"]),
        .library(name: "GlobalTranslatorUI", targets: ["GlobalTranslatorUI"]),
        .library(name: "GlobalTranslatorApp", targets: ["GlobalTranslatorApp"]),
        .executable(name: "global-translator", targets: ["GlobalTranslatorCLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-testing.git", exact: "6.3.2")
    ],
    targets: [
        .target(name: "GlobalTranslatorCore"),
        .target(
            name: "GlobalTranslatorRuntime",
            dependencies: ["GlobalTranslatorCore"]
        ),
        .target(
            name: "GlobalTranslatorCapture",
            dependencies: ["GlobalTranslatorCore"]
        ),
        .target(
            name: "GlobalTranslatorEngine",
            dependencies: ["GlobalTranslatorCore", "GlobalTranslatorCapture"]
        ),
        .executableTarget(
            name: "GlobalTranslatorCLI",
            dependencies: ["GlobalTranslatorRuntime", "GlobalTranslatorCore", "GlobalTranslatorApp"]
        ),
        .target(
            name: "GlobalTranslatorApp",
            dependencies: [
                "GlobalTranslatorCore",
                "GlobalTranslatorRuntime",
                "GlobalTranslatorCapture",
                "GlobalTranslatorEngine",
                "GlobalTranslatorUI"
            ]
        ),
        .target(
            name: "GlobalTranslatorUI",
            dependencies: ["GlobalTranslatorCore", "GlobalTranslatorCapture", "GlobalTranslatorEngine"]
        ),
        .testTarget(
            name: "GlobalTranslatorCoreTests",
            dependencies: [
                "GlobalTranslatorCore",
                .product(name: "Testing", package: "swift-testing")
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L/Library/Developer/CommandLineTools/Library/Developer/usr/lib",
                    "-Xlinker",
                    "-rpath",
                    "-Xlinker",
                    "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
                ])
            ]
        ),
        .testTarget(
            name: "GlobalTranslatorRuntimeTests",
            dependencies: [
                "GlobalTranslatorRuntime",
                "GlobalTranslatorCore",
                .product(name: "Testing", package: "swift-testing")
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
                ])
            ]
        ),
        .testTarget(
            name: "GlobalTranslatorCaptureTests",
            dependencies: [
                "GlobalTranslatorCapture",
                "GlobalTranslatorCore",
                .product(name: "Testing", package: "swift-testing")
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
                ])
            ]
        ),
        .testTarget(
            name: "GlobalTranslatorEngineTests",
            dependencies: [
                "GlobalTranslatorEngine",
                "GlobalTranslatorCapture",
                "GlobalTranslatorCore",
                .product(name: "Testing", package: "swift-testing")
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
                ])
            ]
        ),
        .testTarget(
            name: "GlobalTranslatorUITests",
            dependencies: [
                "GlobalTranslatorUI",
                "GlobalTranslatorEngine",
                "GlobalTranslatorCapture",
                "GlobalTranslatorCore",
                .product(name: "Testing", package: "swift-testing")
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
                ])
            ]
        ),
        .testTarget(
            name: "GlobalTranslatorAppTests",
            dependencies: [
                "GlobalTranslatorApp",
                "GlobalTranslatorUI",
                "GlobalTranslatorEngine",
                "GlobalTranslatorCapture",
                "GlobalTranslatorCore",
                "GlobalTranslatorRuntime",
                .product(name: "Testing", package: "swift-testing")
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
                ])
            ]
        )
    ]
)
