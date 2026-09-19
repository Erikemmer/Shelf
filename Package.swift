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
            // The device profiles are data, not code (ADR 0013): four JSON
            // files read at runtime through `Bundle.module`, which SwiftPM
            // makes on macOS and on Linux alike — so the Linux CI job sees the
            // same profiles the app does.
            resources: [.copy("Devices/Profiles")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Test material, and nothing the app ever calls.
        //
        // `ZipWriter`, `MinimalPNG` and the five `Synthetic…` builders exist so
        // that the tests and `shelf-tool synthesise` can *build* the books this
        // project is measured against — no borrowed book is in this repository
        // and none needs to be (CLAUDE.md). In `ShelfCore` they were 1 343
        // lines of public surface that production never called, and every one
        // of them was code the Linux job had to keep compiling into the
        // shipped core.
        //
        // A target of their own says what they are for, and the dependency
        // arrows say it again: the tests and the tool depend on this, and
        // `App/Shelf` does not — so a `ZipWriter` that appeared in the app
        // would not compile rather than merely being odd.
        .target(
            name: "ShelfFixtures",
            dependencies: ["ShelfCore", .product(name: "GRDB", package: "GRDB.swift")],
            path: "Sources/ShelfFixtures",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Command-line proof that the library, the EPUB reader and the importer
        // agree with the file system on real files, before there is any window
        // to click. `make synthetic` and `make import-dry` use it.
        .executableTarget(
            name: "shelf-tool",
            dependencies: ["ShelfCore", "ShelfFixtures"],
            path: "Sources/shelf-tool",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ShelfCoreTests",
            dependencies: ["ShelfCore", "ShelfFixtures"],
            path: "Tests/ShelfCoreTests",
            // Stored answers from Open Library and Google Books, fetched once
            // by `Scripts/online-proof.sh` and trimmed. The readers are tested
            // against these and never against the live services: no network in
            // the tests, none in CI (CONCEPT §14). Their provenance, including
            // the one file that is *not* a live answer, is in
            // `Tests/ShelfCoreTests/Fixtures/online/README.md`.
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
