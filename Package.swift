// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HanvonToolbox",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "HanvonToolbox", targets: ["HanvonToolbox"]),
        .executable(name: "toolbox-check", targets: ["ToolboxCheck"]),
    ],
    targets: [
        .target(
            name: "CHanvonUSB",
            cSettings: [.unsafeFlags(["-I/opt/homebrew/opt/libusb/include/libusb-1.0"])],
            linkerSettings: [
                .unsafeFlags(["/opt/homebrew/opt/libusb/lib/libusb-1.0.a"]),
                .linkedLibrary("objc"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("IOKit"),
                .linkedFramework("Security"),
            ]
        ),
        .systemLibrary(name: "CSQLite"),
        .target(name: "ToolboxCore", dependencies: ["CHanvonUSB", "CSQLite"]),
        .executableTarget(name: "HanvonToolbox", dependencies: ["ToolboxCore"]),
        .executableTarget(name: "ToolboxCheck", dependencies: ["ToolboxCore"]),
        .testTarget(name: "TransferHistoryTests", dependencies: ["HanvonToolbox", "ToolboxCore"]),
    ]
)
