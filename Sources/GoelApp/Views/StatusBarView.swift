import SwiftUI
import GoelCore

/// The bottom status bar: the speed-limit "snail" toggle, aggregate ↓/↑ totals,
/// and the Low / Medium / High profile picker.
struct StatusBarView: View {
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        HStack(spacing: 14) {
            snail
            stat(symbol: "arrow.down", value: vm.totalDownloadSpeed.speedString, color: Theme.green)
            stat(symbol: "arrow.up", value: vm.totalUploadSpeed.speedString, color: Theme.teal)
            Spacer()
            Text("Profile").font(.system(size: 11)).foregroundStyle(.tertiary)
            profilePicker
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .background(.bar)
    }

    private var snail: some View {
        Button(action: vm.toggleSnail) {
            HStack(spacing: 6) {
                Snail()
                    .stroke(style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                    .frame(width: 15, height: 15)
                Text(vm.settings.speedLimitEnabled ? vm.settings.selectedProfileName : "Unlimited")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(vm.settings.speedLimitEnabled ? Theme.orange.opacity(0.18) : Color.primary.opacity(0.08))
            )
            .foregroundStyle(vm.settings.speedLimitEnabled ? Theme.orange : Color.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Toggle global speed limit")
    }

    private func stat(symbol: String, value: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 11))
            Text(value).font(.system(size: 12, weight: .semibold)).monospacedDigit()
        }
        .foregroundStyle(color)
    }

    private var profilePicker: some View {
        HStack(spacing: 2) {
            ForEach(vm.settings.profiles) { profile in
                let selected = profile.name == vm.settings.selectedProfileName
                Button {
                    vm.setProfile(profile.name)
                } label: {
                    Text(profile.name)
                        .font(.system(size: 11.5, weight: .medium))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(selected ? Theme.accent : Color.clear)
                        )
                        .foregroundStyle(selected ? Color.white : Color.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
    }
}

// MARK: - Snail glyph

/// The speed-limit glyph the brief and mockup call "the snail" — a spiral shell,
/// a humped body, and a raised antenna with an upward chevron. Ported faithfully
/// from the design's inline SVG (visual.html), drawn in its 24×24 space and
/// scaled to whatever frame the view assigns. No SF Symbol "snail" exists, so the
/// path is reproduced here rather than shipped as an asset.
private struct Snail: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 24
        let sy = rect.height / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy)
        }
        var path = Path()

        // Body: tail → over the back → down the neck → foot.
        // (SVG: M2 18 h6 a6 6 0 0 1 6 -6 a5 5 0 0 1 5 5 v1)
        path.move(to: p(2, 18))
        path.addLine(to: p(8, 18))
        path.addCurve(to: p(14, 12), control1: p(8, 14.69), control2: p(10.69, 12))
        path.addCurve(to: p(19, 17), control1: p(16.76, 12), control2: p(19, 14.24))
        path.addLine(to: p(19, 18))

        // Shell spiral, rendered as a ring. (SVG: circle cx7 cy16 r4)
        path.addEllipse(in: CGRect(x: rect.minX + 3 * sx, y: rect.minY + 12 * sy,
                                   width: 8 * sx, height: 8 * sy))

        // Antenna stalk + upward chevron. (SVG: M19 12 V8 … l-1.5 1.5 / l1.5 1.5)
        path.move(to: p(19, 12))
        path.addLine(to: p(19, 8))
        path.move(to: p(17.5, 9.5))
        path.addLine(to: p(19, 8))
        path.addLine(to: p(20.5, 9.5))

        return path
    }
}
