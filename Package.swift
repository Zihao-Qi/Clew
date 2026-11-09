// swift-tools-version:6.1
import PackageDescription

// Layering is enforced here (AGENTS.md rule 4):
//   ClewDomain  -> Foundation only
//   ClewCore    -> ClewDomain
//   ClewStore   -> ClewCore, GRDB
//   ClewGateway -> ClewCore (the local API, v1.1; Apple platforms only)
// Never add a dependency to ClewDomain or ClewCore.
let package = Package(
    name: "Clew",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ClewDomain", targets: ["ClewDomain"]),
        .library(name: "ClewCore", targets: ["ClewCore"]),
        .library(name: "ClewStore", targets: ["ClewStore"]),
        .library(name: "ClewGateway", targets: ["ClewGateway"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", exact: "7.11.1"),
    ],
    targets: [
        .target(name: "ClewDomain"),
        .target(name: "ClewCore", dependencies: ["ClewDomain"]),
        .target(name: "ClewStore", dependencies: [
            "ClewCore",
            .product(name: "GRDB", package: "GRDB.swift"),
        ]),
        .target(name: "ClewGateway", dependencies: ["ClewCore"]),
        .testTarget(name: "ClewDomainTests", dependencies: ["ClewDomain"]),
        .testTarget(name: "ClewCoreTests", dependencies: ["ClewCore"]),
        .testTarget(name: "ClewStoreTests", dependencies: ["ClewStore"]),
        .testTarget(name: "ClewGatewayTests", dependencies: ["ClewGateway", "ClewStore"]),
    ]
)
