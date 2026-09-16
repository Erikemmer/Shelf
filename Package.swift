// swift-tools-version: 6.0
// ShelfCore: UI-free core of the Shelf eBook manager.
//
// Builds and tests on macOS *and* Linux, so every rule that can be wrong – the
// index schema, the EPUB reader, duplicate detection, folder names – can be
// verified in CI without Xcode. Nothing in here may import AppKit, ImageIO or
// PDFKit; those live in `App/Shelf`.
import PackageDescription

let package = Package(
    name: "ShelfCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ShelfCore", targets: ["ShelfCore"])
    ],
    dependencies: [
        // The only external dependency in the core (CONCEPT §5.2). Swift-6
        // ready, actively maintained, and it builds on Linux, which the
        // core-on-Linux CI job depends on.
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0")
    ],
    targets: [
        .target(
            name: "ShelfCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            path: "Sources/ShelfCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Command-line proof that the library, the EPUB reader and the importer
        // agree with the file system on real files, before there is any window
        // to click. `make synthetic` and `make import-dry` use it.
        .executableTarget(
            name: "shelf-tool",
            dependencies: ["ShelfCore"],
            path: "Sources/shelf-tool",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ShelfCoreTests",
            dependencies: ["ShelfCore"],
            path: "Tests/ShelfCoreTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
