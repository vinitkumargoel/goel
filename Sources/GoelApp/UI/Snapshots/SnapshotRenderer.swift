#if DEBUG
import SwiftUI
import AppKit

/// `GoelDownloader --studio-snapshots <outdir> [--only <prefix>] [--scale 1|2]`
///
/// `--scale` is the pixel density (default 2, Retina).
/// Renders every registered ``StudioSnapshotEntry`` into `<outdir>/<name>-light.png` and
/// `<outdir>/<name>-dark.png`, prints each path, and exits. Rendering goes through an offscreen
/// `NSWindow` + `NSHostingView` and `cacheDisplay(in:to:)` rather than `ImageRenderer`, which
/// leaves AppKit-backed controls (text fields, toggles, menus) blank. The window's appearance is
/// set per pass, so dynamic colours resolve exactly as in a real window. Animations render as
/// still frames (`\.studioStillFrames`). Compiled into DEBUG builds only.
@MainActor
enum StudioSnapshotCommand {

    /// nil when the flag is absent (launch normally); otherwise the process exit code.
    static func runIfRequested(_ arguments: [String]) -> Int32? {
        guard let flag = arguments.firstIndex(of: "--studio-snapshots") else { return nil }
        guard flag + 1 < arguments.count, !arguments[flag + 1].hasPrefix("--") else {
            let usage = "usage: GoelDownloader --studio-snapshots <outdir> [--only <prefix>] [--scale 1|2]\n"
            FileHandle.standardError.write(Data(usage.utf8))
            return 64
        }
        let outDir = URL(fileURLWithPath: (arguments[flag + 1] as NSString).expandingTildeInPath, isDirectory: true)
        let only = value(after: "--only", in: arguments)
        let scale = value(after: "--scale", in: arguments).flatMap(Double.init).map { CGFloat($0) }
        return run(outDir: outDir, only: only, scale: scale)
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    static func run(outDir: URL, only: String?, scale: CGFloat?) -> Int32 {
        let app = NSApplication.shared
        // No Dock icon, no menu bar, no activation: this process only draws into bitmaps.
        app.setActivationPolicy(.prohibited)
        do {
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        } catch {
            let message = "error: can't create \(outDir.path): \(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(message.utf8))
            return 73
        }
        let entries = StudioSnapshotRegistry.all.filter { only == nil || $0.name.hasPrefix(only!) }
        if entries.isEmpty {
            FileHandle.standardError.write(Data("error: no snapshot entries match \(only ?? "")\n".utf8))
            return 1
        }
        let names = Set(entries.map(\.name))
        if names.count != entries.count {
            FileHandle.standardError.write(Data("error: duplicate snapshot names\n".utf8))
            return 1
        }
        var failures = 0
        for entry in entries {
            for pass in [(suffix: "light", scheme: ColorScheme.light, appearance: NSAppearance.Name.aqua),
                         (suffix: "dark", scheme: ColorScheme.dark, appearance: NSAppearance.Name.darkAqua)] {
                let url = outDir.appendingPathComponent("\(entry.name)-\(pass.suffix).png")
                do {
                    let png = try render(entry, scheme: pass.scheme, appearance: pass.appearance, scale: scale)
                    try png.write(to: url)
                    print(url.path)
                } catch {
                    failures += 1
                    FileHandle.standardError.write(Data("error: \(entry.name) (\(pass.suffix)): \(error)\n".utf8))
                }
            }
        }
        return failures == 0 ? 0 : 1
    }

    enum RenderError: Error, CustomStringConvertible {
        case emptyBounds, noBitmap, noPNG

        var description: String {
            switch self {
            case .emptyBounds: return "the view laid out at zero size"
            case .noBitmap: return "couldn't allocate a bitmap"
            case .noPNG: return "couldn't encode PNG"
            }
        }
    }

    static func render(_ entry: StudioSnapshotEntry, scheme: ColorScheme,
                       appearance: NSAppearance.Name, scale: CGFloat?) throws -> Data {
        let context = StudioSnapshotContext(colorScheme: scheme)
        let root = entry.render(context)
            .environment(\.studioStillFrames, true)
            .frame(width: entry.width, height: entry.height)
            .frame(maxHeight: entry.height == nil ? nil : entry.height, alignment: .topLeading)
            .background(Studio.Palette.canvas)

        let hosting = NSHostingView(rootView: AnyView(root))
        let initialHeight = entry.height ?? 10
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: entry.width, height: initialHeight),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.appearance = NSAppearance(named: appearance)
        window.backgroundColor = Studio.Tones.canvas.nsColor
        window.contentView = hosting

        if entry.height == nil {
            hosting.layoutSubtreeIfNeeded()
            let fitting = hosting.fittingSize
            window.setContentSize(NSSize(width: entry.width, height: max(1, ceil(fitting.height))))
        }
        // Let SwiftUI run its update passes (onAppear state, async layout) before capturing.
        for _ in 0..<4 {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        hosting.layoutSubtreeIfNeeded()
        hosting.display()

        let bounds = hosting.bounds
        guard bounds.width > 0, bounds.height > 0 else { throw RenderError.emptyBounds }
        let pixelScale = scale ?? 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int((bounds.width * pixelScale).rounded()),
                                         pixelsHigh: Int((bounds.height * pixelScale).rounded()),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)
                ?? hosting.bitmapImageRepForCachingDisplay(in: bounds) else { throw RenderError.noBitmap }
        rep.size = bounds.size
        hosting.cacheDisplay(in: bounds, to: rep)
        window.close()
        // Converted, not just tagged: the pixels end up in sRGB, so a viewer that ignores the
        // embedded profile still sees the colours the tokens specify.
        let output = rep.converting(to: .sRGB, renderingIntent: .default) ?? rep
        guard let data = output.representation(using: .png, properties: [:]) else { throw RenderError.noPNG }
        return data
    }
}
#endif
