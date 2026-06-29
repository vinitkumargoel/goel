// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "GoelDownloader",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "GoelCore", targets: ["GoelCore"]),
        .executable(name: "GoelDownloader", targets: ["GoelApp"]),
    ],
    dependencies: [
        // GRDB is added in the persistence phase.
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
    ],
    targets: [
        // C/C++ bridge over Homebrew's libtorrent-rasterbar (2.0.x). Exposes a
        // pure-C header so the Swift `TorrentEngine` can drive a real BitTorrent
        // session. The compile/link flags mirror `pkg-config libtorrent-rasterbar`
        // (the ABI defines MUST match how libtorrent was built) plus the Boost and
        // OpenSSL include/lib paths its headers pull in. Paths are Homebrew's
        // arm64 prefix; adjust if your install lives elsewhere.
        .target(
            name: "TorrentBridge",
            cxxSettings: [
                .unsafeFlags([
                    "-I/opt/homebrew/opt/libtorrent-rasterbar/include",
                    "-I/opt/homebrew/opt/boost/include",
                    "-I/opt/homebrew/opt/openssl@3/include",
                    "-fexceptions",
                ]),
                .define("TORRENT_LINKING_SHARED"),
                .define("BOOST_ASIO_ENABLE_CANCELIO"),
                .define("BOOST_ASIO_NO_DEPRECATED"),
                .define("TORRENT_USE_OPENSSL"),
                .define("TORRENT_USE_LIBCRYPTO"),
                .define("TORRENT_SSL_PEERS"),
                .define("OPENSSL_NO_SSL2"),
                .define("OPENSSL_NO_SSL3"),
                .define("OPENSSL_NO_TLS1"),
                .define("OPENSSL_NO_TLS1_1"),
                .define("OPENSSL_NO_DTLS1"),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L/opt/homebrew/opt/libtorrent-rasterbar/lib",
                    "-L/opt/homebrew/lib",
                    "-L/opt/homebrew/opt/openssl@3/lib",
                    "-ltorrent-rasterbar",
                    "-lssl",
                    "-lcrypto",
                    "-Xlinker", "-rpath", "-Xlinker", "/opt/homebrew/lib",
                ]),
            ]
        ),
        .target(
            name: "GoelCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                "TorrentBridge",
            ]
        ),
        .executableTarget(
            name: "GoelApp",
            dependencies: ["GoelCore"],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "GoelCoreTests",
            dependencies: ["GoelCore"]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
