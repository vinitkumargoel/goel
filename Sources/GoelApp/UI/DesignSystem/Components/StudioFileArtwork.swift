import SwiftUI
import GoelCore

/// The artwork families. Mirrors ``FileType`` (whose classification decides it) plus Folder for
/// SFTP and file trees; `.disc` is `FileType.iso`.
enum StudioArtKind: String, CaseIterable, Hashable, Sendable {
    case video, audio, image, disc, archive, app, doc, magnet, folder, other

    init(_ type: FileType) {
        switch type {
        case .video: self = .video
        case .audio: self = .audio
        case .image: self = .image
        case .iso: self = .disc
        case .archive: self = .archive
        case .app: self = .app
        case .doc: self = .doc
        case .magnet: self = .magnet
        case .other: self = .other
        }
    }

    /// From the task's own classification (`DownloadTask.fileType`), so a magnet without metadata
    /// gets the magnet tile and "release.iso.zip" stays a disc image.
    init(task: DownloadTask) {
        self.init(task.fileType)
    }

    /// SF Symbol for the glyph; nil means a custom-drawn glyph (the magnet).
    var symbol: String? {
        switch self {
        case .video: return "film"
        case .audio: return "music.note"
        case .image: return "photo"
        case .disc: return "opticaldisc"
        case .archive: return "archivebox"
        case .app: return "shippingbox"
        case .doc: return "doc.text"
        case .magnet: return nil
        case .folder: return "folder"
        case .other: return "doc"
        }
    }

    var accessibilityName: String {
        switch self {
        case .video: return FileType.video.accessibilityName
        case .audio: return FileType.audio.accessibilityName
        case .image: return FileType.image.accessibilityName
        case .disc: return FileType.iso.accessibilityName
        case .archive: return FileType.archive.accessibilityName
        case .app: return FileType.app.accessibilityName
        case .doc: return FileType.doc.accessibilityName
        case .magnet: return FileType.magnet.accessibilityName
        case .folder: return L10n.t("Folder")
        case .other: return FileType.other.accessibilityName
        }
    }

    var tint: StudioFileTint { Studio.Palette.fileTint(self) }
}

/// Tile sizes from the mockup: `.art.xs` 24, `.art.s` 32, `.art` 44, `.art.l` 64.
enum StudioArtSize: CaseIterable, Sendable {
    case xs, s, m, l

    var side: CGFloat {
        switch self {
        case .xs: return 24
        case .s: return 32
        case .m: return 44
        case .l: return 64
        }
    }

    var radius: CGFloat {
        switch self {
        case .xs: return 7
        case .s: return Studio.Radius.artSmall
        case .m: return Studio.Radius.tile
        case .l: return Studio.Radius.artLarge
        }
    }

    var glyph: CGFloat {
        switch self {
        case .xs: return 12
        case .s: return 15
        case .m: return 20
        case .l: return 28
        }
    }
}

/// A file-type artwork tile: a two-stop tint, the type's pattern and its glyph.
///
///     StudioFileArtwork(kind: StudioArtKind(task: task), size: .s)
///     StudioFileArtwork(kind: .magnet, size: .s, isFetchingMetadata: true)
///     StudioFileArtwork(kind: .archive, size: .s, isFaded: true)   // paused
///
/// Decorative by default (the row or card names the file); pass `accessibilityLabel` to make it
/// an element of its own.
struct StudioFileArtwork: View {
    let kind: StudioArtKind
    var size: StudioArtSize = .m
    /// Grey and see-through, for paused or missing files (`.art.faded`).
    var isFaded = false
    /// A placeholder tile with no tint (`.art.ghost`), for loading rows.
    var isGhost = false
    /// The magnet / metadata variant: a turning ring around the glyph while metadata is fetched.
    var isFetchingMetadata = false
    var accessibilityLabel: String?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size.radius, style: .continuous)
        ZStack {
            if isGhost {
                shape.fill(Studio.Palette.segment)
            } else {
                StudioArtworkFill(kind: kind)
                    .clipShape(shape)
                shape.strokeBorder(Studio.Palette.artHighlight, lineWidth: 1)
            }
            StudioArtGlyph(kind: kind, size: size.glyph)
                .foregroundStyle(isGhost ? Studio.Palette.ink3 : Studio.Palette.artInk)
            if isFetchingMetadata && !isGhost {
                StudioMetadataRing(diameter: size.glyph + size.side * 0.32)
            }
        }
        .frame(width: size.side, height: size.side)
        .grayscale(isFaded ? 0.85 : 0)
        .opacity(isFaded ? 0.6 : 1)
        .modifier(StudioArtworkAccessibility(label: accessibilityLabel))
    }
}

/// The wide artwork band across the top of a board card (`.art.band`, 66 pt tall). Put a glass
/// badge in `trailing`: `StudioArtworkBand(kind: .disc) { StudioKindBadge(kind: .http, style: .glass) }`.
struct StudioArtworkBand<Trailing: View>: View {
    let kind: StudioArtKind
    var height: CGFloat = 66
    var isFaded = false
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        ZStack(alignment: .topTrailing) {
            StudioArtworkFill(kind: kind)
            StudioArtGlyph(kind: kind, size: 24)
                .foregroundStyle(Studio.Palette.artInk.opacity(0.95))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(.leading, Studio.Space.l)
            trailing()
                .padding(Studio.Space.sm)
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipped()
        .grayscale(isFaded ? 0.85 : 0)
        .opacity(isFaded ? 0.6 : 1)
        .accessibilityHidden(true)
    }
}

extension StudioArtworkBand where Trailing == EmptyView {
    init(kind: StudioArtKind, height: CGFloat = 66, isFaded: Bool = false) {
        self.init(kind: kind, height: height, isFaded: isFaded, trailing: { EmptyView() })
    }
}

private struct StudioArtworkAccessibility: ViewModifier {
    let label: String?

    func body(content: Content) -> some View {
        if let label {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
                .accessibilityAddTraits(.isImage)
        } else {
            content.accessibilityHidden(true)
        }
    }
}

/// The glyph: an SF Symbol, or the mockup's magnet drawn as a path (SF Symbols has none).
struct StudioArtGlyph: View {
    let kind: StudioArtKind
    let size: CGFloat

    var body: some View {
        if let symbol = kind.symbol {
            Image(systemName: symbol)
                .font(StudioFonts.font(.ui, size: size * 0.82, weight: 600))
                .imageScale(.medium)
                .frame(width: size, height: size)
        } else {
            StudioMagnetShape()
                .stroke(style: StrokeStyle(lineWidth: max(1.4, size / 11), lineCap: .round, lineJoin: .round))
                .frame(width: size, height: size)
        }
    }
}

/// The mockup's magnet icon (`studio-i-magnet`), in its 24×24 viewBox.
struct StudioMagnetShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        let ox = rect.midX - 12 * s, oy = rect.midY - 12 * s
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }
        var path = Path()
        // M5 4h4.5v7 a2.5 2.5 0 0 0 5 0 V4 H19 v7 a7 7 0 0 1 -14 0 z
        path.move(to: p(5, 4))
        path.addLine(to: p(9.5, 4))
        path.addLine(to: p(9.5, 11))
        path.addArc(center: p(12, 11), radius: 2.5 * s, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: true)
        path.addLine(to: p(14.5, 4))
        path.addLine(to: p(19, 4))
        path.addLine(to: p(19, 11))
        path.addArc(center: p(12, 11), radius: 7 * s, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
        path.closeSubpath()
        // M5 8h4.5 M14.5 8H19
        path.move(to: p(5, 8))
        path.addLine(to: p(9.5, 8))
        path.move(to: p(14.5, 8))
        path.addLine(to: p(19, 8))
        return path
    }
}

/// The tinted gradient plus the per-type pattern, drawn to whatever frame it is given.
struct StudioArtworkFill: View {
    let kind: StudioArtKind

    var body: some View {
        let tint = kind.tint
        ZStack {
            if kind == .magnet {
                // `conic-gradient(from 200deg at 30% 120%, mag, mag-2, mag)`; CSS 0° is up, SwiftUI's is right.
                AngularGradient(colors: [tint.fill, tint.fillDeep, tint.fill],
                                center: UnitPoint(x: 0.3, y: 1.2),
                                startAngle: .degrees(110), endAngle: .degrees(470))
            } else {
                // `linear-gradient(145deg, fill, fill-2)`.
                LinearGradient(colors: [tint.fill, tint.fillDeep],
                               startPoint: UnitPoint(x: 0.21, y: 0.09), endPoint: UnitPoint(x: 0.79, y: 0.91))
            }
            StudioArtworkPattern(kind: kind)
        }
    }
}

/// Each family's pattern, in the mockup's absolute point sizes so a bigger tile shows more of it.
private struct StudioArtworkPattern: View {
    let kind: StudioArtKind

    var body: some View {
        Canvas { context, size in
            let ink = GraphicsContext.Shading.color(Studio.Palette.artHighlight)
            switch kind {
            case .video:
                // Film perforations along the top and bottom edge.
                var x: CGFloat = 7
                while x < size.width {
                    context.fill(Path(CGRect(x: x, y: 0, width: 4, height: 5)), with: ink)
                    context.fill(Path(CGRect(x: x, y: size.height - 5, width: 4, height: 5)), with: ink)
                    x += 11
                }
            case .audio:
                // Ripples from the bottom-right corner.
                let corner = CGPoint(x: size.width, y: size.height)
                let reach = hypot(size.width, size.height)
                var r: CGFloat = 5.75
                while r < reach {
                    context.stroke(Path(ellipseIn: CGRect(x: corner.x - r, y: corner.y - r, width: r * 2, height: r * 2)),
                                   with: ink, lineWidth: 1.5)
                    r += 6.5
                }
            case .disc:
                let centre = CGPoint(x: size.width / 2, y: size.height / 2)
                let reach = hypot(size.width, size.height) / 2
                var r: CGFloat = 5.5
                while r < reach {
                    context.stroke(Path(ellipseIn: CGRect(x: centre.x - r, y: centre.y - r, width: r * 2, height: r * 2)),
                                   with: ink, lineWidth: 1)
                    r += 6
                }
            case .archive:
                // 135° stripes: 3 pt bands every 9 pt.
                var stripes = Path()
                var offset: CGFloat = -size.height
                while offset < size.width + size.height {
                    stripes.move(to: CGPoint(x: offset + 6, y: 0))
                    stripes.addLine(to: CGPoint(x: offset + 9, y: 0))
                    stripes.addLine(to: CGPoint(x: offset + 9 + size.height, y: size.height))
                    stripes.addLine(to: CGPoint(x: offset + 6 + size.height, y: size.height))
                    stripes.closeSubpath()
                    offset += 9 * 1.414
                }
                context.fill(stripes, with: ink)
            case .app:
                // A dot grid on 8 pt centres.
                var dots = Path()
                var y: CGFloat = 4
                while y < size.height {
                    var x: CGFloat = 4
                    while x < size.width {
                        dots.addEllipse(in: CGRect(x: x - 1.6, y: y - 1.6, width: 3.2, height: 3.2))
                        x += 8
                    }
                    y += 8
                }
                context.fill(dots, with: ink)
            case .doc:
                // Ruled lines.
                var y: CGFloat = 6
                while y < size.height {
                    context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1.5)), with: ink)
                    y += 7.5
                }
            case .folder:
                // A hard-edged highlight across the top-left (`linear-gradient(160deg, hi 0 30%, transparent 30%)`).
                var wedge = Path()
                wedge.move(to: .zero)
                wedge.addLine(to: CGPoint(x: size.width, y: 0))
                wedge.addLine(to: CGPoint(x: size.width, y: size.height * 0.12))
                wedge.addLine(to: CGPoint(x: 0, y: size.height * 0.42))
                wedge.closeSubpath()
                context.fill(wedge, with: ink)
            case .image:
                // A sun and a hill line.
                let sun = min(size.width, size.height) * 0.16
                context.fill(Path(ellipseIn: CGRect(x: size.width * 0.72 - sun, y: size.height * 0.28 - sun,
                                                    width: sun * 2, height: sun * 2)), with: ink)
                var hill = Path()
                hill.move(to: CGPoint(x: 0, y: size.height * 0.78))
                hill.addQuadCurve(to: CGPoint(x: size.width, y: size.height * 0.70),
                                  control: CGPoint(x: size.width * 0.45, y: size.height * 0.50))
                hill.addLine(to: CGPoint(x: size.width, y: size.height))
                hill.addLine(to: CGPoint(x: 0, y: size.height))
                hill.closeSubpath()
                context.fill(hill, with: ink)
            case .other:
                // A folded corner.
                let fold = min(size.width, size.height) * 0.32
                var corner = Path()
                corner.move(to: CGPoint(x: size.width - fold, y: 0))
                corner.addLine(to: CGPoint(x: size.width, y: 0))
                corner.addLine(to: CGPoint(x: size.width, y: fold))
                corner.closeSubpath()
                context.fill(corner, with: ink)
            case .magnet:
                break
            }
        }
        .allowsHitTesting(false)
    }
}

/// The turning ring on a magnet tile while its metadata is fetched; still under Reduce Motion.
private struct StudioMetadataRing: View {
    let diameter: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.studioStillFrames) private var stillFrames

    var body: some View {
        if reduceMotion || stillFrames {
            ring(angle: .degrees(-40))
        } else {
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                ring(angle: .degrees(t.truncatingRemainder(dividingBy: 1.6) / 1.6 * 360))
            }
        }
    }

    private func ring(angle: Angle) -> some View {
        ZStack {
            Circle()
                .stroke(Studio.Palette.artInk.opacity(0.28), lineWidth: 1.6)
            Circle()
                .trim(from: 0, to: 0.28)
                .stroke(Studio.Palette.artInk.opacity(0.95), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .rotationEffect(angle)
        }
        .frame(width: diameter, height: diameter)
    }
}
