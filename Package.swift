// swift-tools-version:5.10
import PackageDescription
import Foundation

#if os(Linux)

// Ubuntu's `libtorrent-rasterbar.pc` emits exactly these ABI defines.
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

// Ubuntu's libsqlite3 declares but omits `sqlite3_snapshot_*`, so GRDB fails to link without this.
let sqliteDir = ProcessInfo.processInfo.environment["GOEL_SQLITE_DIR"] ?? "Vendor/linux/sqlite"
let linuxCoreLink: [LinkerSetting] = [
    .unsafeFlags(["-L\(sqliteDir)", "-Xlinker", "-rpath", "-Xlinker", sqliteDir]),
]

#else

// Where libtorrent/OpenSSL/libssh2/Boost come from, in order of precedence:
//   1. GOEL_BREW_PREFIX, if set (CI sets it explicitly).
//   2. Vendor/macos/<arch> next to this manifest, if Scripts/macos/build-deps.sh has
//      populated it. Those libraries are built against the 14.0 floor, whereas
//      Homebrew's bottles target the build machine's OS and ship a broken app.
//   3. /opt/homebrew, as a last resort for a quick local `swift build`. build_app.sh
//      refuses to produce a release (GOEL_RELEASE=1) linked against it.
// SwiftPM caches the evaluated manifest keyed on this file and the environment, so after
// populating Vendor/ for the first time build once with `--manifest-cache none` (or set
// GOEL_BREW_PREFIX) for the change to be noticed. build_app.sh always exports it.
#if arch(arm64)
let vendoredArch = "arm64"
#else
let vendoredArch = "x86_64"
#endif
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let vendoredPrefix = "\(packageRoot)/Vendor/macos/\(vendoredArch)"
let brewPrefix: String = {
    if let explicit = ProcessInfo.processInfo.environment["GOEL_BREW_PREFIX"], !explicit.isEmpty {
        return explicit
    }
    // Probe a header directory, not just the prefix: an interrupted build-deps.sh can
    // leave the prefix behind without the libraries, and that must not win.
    if FileManager.default.fileExists(atPath: "\(vendoredPrefix)/opt/libtorrent-rasterbar/include") {
        return vendoredPrefix
    }
    return "/opt/homebrew"
}()

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

var dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
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

var targets: [Target] = [
    .target(name: "TorrentBridge", cxxSettings: torrentCxx, linkerSettings: torrentLink),
    .target(name: "CurlBridge", linkerSettings: curlLink),
    .target(name: "SSHBridge", cSettings: sshC, linkerSettings: sshLink),
    .target(
        name: "GoelCore",
        dependencies: coreDeps,
        resources: [
            .process("Resources"),
        ],
        linkerSettings: linuxCoreLink
    ),
]
var products: [Product] = [
    .library(name: "GoelCore", targets: ["GoelCore"]),
]

// GoelCLI stays dependency-free so `goel doctor` still works when the daemon won't start.
// GoelDaemon builds everywhere: on macOS it is the headless alternative to the app,
// so the CLI + web portal work on a Mac without a GUI session.
targets += [
    .executableTarget(name: "GoelCLI"),
    .executableTarget(name: "GoelDaemon", dependencies: ["GoelCore"]),
    .testTarget(name: "GoelCoreTests", dependencies: ["GoelCore"]),
    .testTarget(name: "GoelCLITests", dependencies: ["GoelCLI"]),
]
products += [
    .executable(name: "goel", targets: ["GoelCLI"]),
    .executable(name: "GoelDaemon", targets: ["GoelDaemon"]),
]

#if os(Linux)
targets += [
    .target(name: "CryptoBridge", linkerSettings: [.linkedLibrary("crypto")]),
]
#else
targets += [
    .executableTarget(
        name: "GoelApp",
        dependencies: [
            "GoelCore",
            .product(name: "Sparkle", package: "Sparkle"),
        ],
        // The Studio porting guide sits next to the code it describes; it isn't a resource.
        exclude: ["UI/README.md"],
        resources: [
            // The WebExtension is loaded unpacked, so it must be copied verbatim, not processed.
            .copy("BrowserExtension"),
            .process("Resources"),
        ],
        // SwiftUI's VideoPlayer lives in the _AVKit_SwiftUI overlay, which autolinks
        // but leaves AVKit itself out; without it AVPlayerView is absent at runtime
        // and the player traps on superclass metadata lookup.
        linkerSettings: [.linkedFramework("AVKit")]
    ),
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
