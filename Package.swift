// swift-tools-version:5.10
import PackageDescription
import Foundation

// Platform-conditional wiring: macOS builds the SwiftUI app against Homebrew libs,
// Linux a headless daemon against distro libs. `#if os(Linux)` = the build host.

#if os(Linux)

// Ubuntu's `libtorrent-rasterbar.pc` emits exactly these ABI defines; libtorrent,
// boost and libssh2 headers sit on the default include path.
let torrentCxx: [CXXSetting] = [
    .unsafeFlags([
        "-fexceptions",
        "-DTORRENT_LINKING_SHARED",
        "-DBOOST_ASIO_ENABLE_CANCELIO",
        "-DBOOST_ASIO_NO_DEPRECATED",
        "-DTORRENT_USE_OPENSSL",
        "-DTORRENT_USE_LIBCRYPTO",
        "-DTORRENT_SSL_PEERS",
        "-DOPENSSL_NO_SSL2",
    ]),
]
let torrentLink: [LinkerSetting] = [
    .unsafeFlags(["-ltorrent-rasterbar", "-lssl", "-lcrypto"]),
]
let sshC: [CSetting] = []
let sshLink: [LinkerSetting] = [.unsafeFlags(["-lssh2"])]
let curlLink: [LinkerSetting] = [.linkedLibrary("curl")]

// Ubuntu's libsqlite3 declares `sqlite3_snapshot_*` but omits them, so GRDB fails
// to link — point at a vendored SQLITE_ENABLE_SNAPSHOT build (GOEL_SQLITE_DIR).
let sqliteDir = ProcessInfo.processInfo.environment["GOEL_SQLITE_DIR"] ?? "Vendor/linux/sqlite"
let linuxCoreLink: [LinkerSetting] = [
    .unsafeFlags(["-L\(sqliteDir)", "-Xlinker", "-rpath", "-Xlinker", sqliteDir]),
]

#else

// Homebrew prefix for the native libraries; defaults to Apple Silicon's
// /opt/homebrew. Set GOEL_BREW_PREFIX=/usr/local for an Intel build.
let brewPrefix = ProcessInfo.processInfo.environment["GOEL_BREW_PREFIX"] ?? "/opt/homebrew"

let torrentCxx: [CXXSetting] = [
    .unsafeFlags([
        "-I\(brewPrefix)/opt/libtorrent-rasterbar/include",
        "-I\(brewPrefix)/opt/boost/include",
        "-I\(brewPrefix)/opt/openssl@3/include",
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
]
let torrentLink: [LinkerSetting] = [
    .unsafeFlags([
        "-L\(brewPrefix)/opt/libtorrent-rasterbar/lib",
        "-L\(brewPrefix)/lib",
        "-L\(brewPrefix)/opt/openssl@3/lib",
        "-ltorrent-rasterbar",
        "-lssl",
        "-lcrypto",
        "-Xlinker", "-rpath", "-Xlinker", "\(brewPrefix)/lib",
    ]),
]
let sshC: [CSetting] = [.unsafeFlags(["-I\(brewPrefix)/opt/libssh2/include"])]
let sshLink: [LinkerSetting] = [.unsafeFlags(["-L\(brewPrefix)/opt/libssh2/lib", "-lssh2"])]
let curlLink: [LinkerSetting] = [.linkedLibrary("curl")]
let linuxCoreLink: [LinkerSetting] = []

#endif

// ---- Dependencies ---------------------------------------------------------
var dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
]
#if os(Linux)
dependencies += [
    .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
]
#else
dependencies += [
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
]
#endif

// ---- GoelCore dependencies ------------------------------------------------
var coreDeps: [Target.Dependency] = [
    .product(name: "GRDB", package: "GRDB.swift"),
    "TorrentBridge",
    "CurlBridge",
    "SSHBridge",
]
#if os(Linux)
coreDeps += [
    "CryptoBridge",
    .product(name: "Crypto", package: "swift-crypto"),
    .product(name: "NIOCore", package: "swift-nio"),
    .product(name: "NIOPosix", package: "swift-nio"),
    .product(name: "NIOHTTP1", package: "swift-nio"),
]
#endif

// ---- Targets & products ---------------------------------------------------
var targets: [Target] = [
    .target(name: "TorrentBridge", cxxSettings: torrentCxx, linkerSettings: torrentLink),
    .target(name: "CurlBridge", linkerSettings: curlLink),
    .target(name: "SSHBridge", cSettings: sshC, linkerSettings: sshLink),
    .target(
        name: "GoelCore",
        dependencies: coreDeps,
        resources: [
            // Localization tables (en + de today). `.process` treats the
            // `.lproj` folders as localizations in the target's resource bundle.
            .process("Resources"),
        ],
        linkerSettings: linuxCoreLink
    ),
]
var products: [Product] = [
    .library(name: "GoelCore", targets: ["GoelCore"]),
]

// The `goel` admin CLI: dependency-free (portal HTTP + systemctl) so `goel doctor`
// still works when the daemon won't start. Built on macOS too — only macOS CI exists.
targets += [
    .executableTarget(name: "GoelCLI"),
    // Not macOS-gated: Linux ships the daemon and `goel` but had no coverage. Files
    // needing Network.framework or the Keychain guard with `#if !os(Linux)`.
    .testTarget(name: "GoelCoreTests", dependencies: ["GoelCore"]),
    // `goel config set` rewrites /etc/goel/config, systemd's environment for the
    // service — a corrupt line stops the daemon booting, so it is tested, not trusted.
    .testTarget(name: "GoelCLITests", dependencies: ["GoelCLI"]),
]
products += [
    .executable(name: "goel", targets: ["GoelCLI"]),
]

#if os(Linux)
targets += [
    // Tiny OpenSSL shim for AES-128-CBC (HLS), reusing the already-linked libcrypto.
    .target(name: "CryptoBridge", linkerSettings: [.linkedLibrary("crypto")]),
    .executableTarget(name: "GoelDaemon", dependencies: ["GoelCore"]),
]
products += [
    .executable(name: "GoelDaemon", targets: ["GoelDaemon"]),
]
#else
targets += [
    .executableTarget(
        name: "GoelApp",
        dependencies: [
            "GoelCore",
            .product(name: "Sparkle", package: "Sparkle"),
        ],
        resources: [
            // The WebExtension ships as-is (a folder the user loads unpacked), so
            // it is copied verbatim, not processed.
            .copy("BrowserExtension"),
            .process("Resources"),
        ]
    ),
    // GoelApp's top-level `main.swift` doesn't clash with a test host, so `@testable
    // import` works — its pure helpers were untested only for lack of somewhere to put them.
    .testTarget(name: "GoelAppTests", dependencies: ["GoelApp"]),
]
products += [
    .executable(name: "GoelDownloader", targets: ["GoelApp"]),
]
#endif

let package = Package(
    name: "GoelDownloader",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
    ],
    products: products,
    dependencies: dependencies,
    targets: targets,
    cxxLanguageStandard: .cxx17
)
