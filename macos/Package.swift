// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "RemoteSSH",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "RemoteSSH", targets: ["RemoteSSH"]),
        .library(name: "RemoteSSHCore", targets: ["RemoteSSHCore"]),
    ],
    dependencies: [
        // Pinned exactly: 0.12.1 switched swift-nio-ssh to an unvetted personal fork.
        .package(url: "https://github.com/orlandos-nl/Citadel.git", exact: "0.12.0"),
        // Same sources Citadel 0.12.0 resolves; declared to use NIOSSH host-key types directly.
        .package(url: "https://github.com/Joannis/swift-nio-ssh.git", "0.3.4"..<"0.4.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        // Capped so the package also builds against the macOS 26.x SDK (see CLAUDE.md, "Build").
        .package(url: "https://github.com/apple/swift-collections.git", "1.1.0"..<"1.5.0"),
        // Capped: swift-log 1.16 needs Swift tools 6.2, but the macos-15 CI runners have Swift 6.1.
        .package(url: "https://github.com/apple/swift-log.git", "1.5.0"..<"1.16.0"),
        // Terminal emulator view. Pinned: 1.20 is a pre-release and 1.99 previews 2.0's I/O changes.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.19.0"),
    ],
    targets: [
        // Thin C shim over the system libcurl (FTP/FTPS); curl_easy_setopt is variadic and not callable from Swift.
        .target(
            name: "CCurl",
            linkerSettings: [.linkedLibrary("curl")]
        ),
        // BoringSSL RSA prototypes (symbols come from swift-crypto via Citadel).
        .target(name: "CRSAShim"),
        .target(
            name: "RemoteSSHCore",
            dependencies: [
                "CCurl",
                "CRSAShim",
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
            ],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "RemoteSSH",
            dependencies: ["RemoteSSHCore", .product(name: "SwiftTerm", package: "SwiftTerm")]
        ),
        .testTarget(
            name: "RemoteSSHCoreTests",
            dependencies: ["RemoteSSHCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
