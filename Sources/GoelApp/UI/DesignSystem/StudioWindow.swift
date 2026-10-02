import SwiftUI
import AppKit

extension NSWindow {
    /// Makes an AppKit window or panel look like a Studio window: canvas background (so the area
    /// behind the title bar and any resize gap is never system grey) and, if given, a pinned
    /// appearance. Pass `nil` to follow the app / system appearance.
    func applyStudioChrome(appearance mode: StudioAppearanceMode? = nil, transparentTitlebar: Bool = true) {
        backgroundColor = Studio.Tones.canvas.nsColor
        if transparentTitlebar {
            titlebarAppearsTransparent = true
        }
        if let mode {
            appearance = mode.nsAppearance
        }
    }
}

/// Reaches the hosting `NSWindow` once it exists and applies Studio chrome to it.
private struct StudioWindowConfigurator: NSViewRepresentable {
    let transparentTitlebar: Bool

    func makeNSView(context: Context) -> NSView {
        let view = ConfiguringView()
        view.transparentTitlebar = transparentTitlebar
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ConfiguringView: NSView {
        var transparentTitlebar = true

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.applyStudioChrome(transparentTitlebar: transparentTitlebar)
        }
    }
}

extension View {
    /// The root modifier for every new Studio window's content: canvas behind everything, the
    /// window's own background set to match, and the title bar blended into the canvas.
    func studioWindowBackground(transparentTitlebar: Bool = true) -> some View {
        background {
            ZStack {
                Studio.Palette.canvas
                StudioWindowConfigurator(transparentTitlebar: transparentTitlebar)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
            .ignoresSafeArea()
        }
    }

    /// Recessed chrome (the icon rail, a settings sidebar).
    func studioRailBackground() -> some View {
        background(Studio.Palette.rail.ignoresSafeArea())
    }

    /// `--glass`: a translucent fill over artwork or video, blurred like `backdrop-filter`.
    func studioGlass<S: InsettableShape>(in shape: S) -> some View {
        background {
            shape.fill(.ultraThinMaterial)
                .overlay(shape.fill(Studio.Palette.glass))
        }
        .clipShape(shape)
    }

    /// Dims and blurs what is behind a modal Studio surface.
    func studioScrim(_ visible: Bool = true) -> some View {
        overlay {
            if visible {
                Studio.Palette.scrim
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
            }
        }
    }
}
