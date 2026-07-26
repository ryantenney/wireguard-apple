// swift-tools-version:5.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "WireGuardKit",
    platforms: [
        .macOS(.v12),
        .iOS(.v15)
    ],
    products: [
        .library(name: "WireGuardKit", targets: ["WireGuardKit"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "WireGuardKit",
            dependencies: ["WireGuardKitGo", "WireGuardKitC"]
        ),
        .target(
            name: "WireGuardKitC",
            dependencies: [],
            publicHeadersPath: "."
        ),
        .target(
            name: "WireGuardKitGo",
            dependencies: [],
            exclude: [
                "goruntime-boottime-over-monotonic.diff",
                "go.mod",
                "go.sum",
                "Makefile",
                // Go sources are compiled by the external Makefile target
                // (see README), not by SPM.
                "api-apple.go",
                "bridge-helpers.go",
                "handles.go",
                "handles_test.go",
                "main.go",
                "probe-apple.go",
                "probeproto.go",
                "probeproto_test.go",
                "stats.go",
                "stats_test.go",
                "tit-apple.go",
                "warmspare-export.go",
                "warmspare.go"
            ],
            publicHeadersPath: ".",
            linkerSettings: [.linkedLibrary("wg-go")]
        )
    ]
)
