// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ShellHarbor",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ShellHarbor", targets: ["ShellHarbor"]),
        .executable(name: "shcli", targets: ["ShellHarborCLI"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/migueldeicaza/SwiftTerm.git",
            exact: "1.15.0"
        )
    ],
    targets: [
        .executableTarget(
            name: "ShellHarbor",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Sources/ShellHarbor"
        ),
        .target(
            name: "ShellHarborCLIKit",
            path: "Sources/ShellHarborCLIKit"
        ),
        .executableTarget(
            name: "ShellHarborCLI",
            dependencies: ["ShellHarborCLIKit"],
            path: "Sources/ShellHarborCLI"
        ),
        .testTarget(
            name: "ShellHarborTests",
            dependencies: [
                "ShellHarbor",
                "ShellHarborCLIKit",
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Tests/ShellHarborTests"
        )
    ]
)
