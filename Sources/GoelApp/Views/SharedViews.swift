import SwiftUI
import GoelCore

/// The accent-icon-tile + title row that heads the Add and Link-Grabber sheets.
struct SheetHeader: View {
    let systemImage: String
    let title: String

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: systemImage)
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 8))
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Spacer()
        }
        .padding(18)
    }
}

/// The colored rounded type tile with an SF Symbol (the `.ftype` chip).
struct FileTypeIcon: View {
    let type: FileType
    var size: CGFloat = 30

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
            .fill(LinearGradient(colors: type.gradient, startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: type.symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            )
    }
}

/// The HTTP / BT badge.
struct KindBadge: View {
    let task: DownloadTask
    var body: some View {
        Text(task.kindBadge)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(task.kindBadgeColor.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(task.kindBadgeColor)
    }
}

/// A thin progress bar tinted by the task's state. Shimmers while resolving
/// metadata (indeterminate).
struct MiniProgressBar: View {
    let task: DownloadTask
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                if task.status == .requestingMetadata {
                    Capsule()
                        .fill(Theme.orange.opacity(0.7))
                        .frame(width: geo.size.width * 0.4)
                } else {
                    Capsule()
                        .fill(task.progressTint)
                        .frame(width: max(0, geo.size.width * task.fractionCompleted))
                }
            }
        }
        .frame(height: height)
    }
}

/// The circular state button shown in each row (play / pause / retry / folder).
/// Holds `vm` as a plain reference (not `@EnvironmentObject`) so it doesn't make
/// every row re-render on each progress publish — see `DownloadRow`.
struct StateButton: View {
    let task: DownloadTask
    let vm: AppViewModel

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.primary.opacity(0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(helpText)
    }

    private var symbol: String {
        switch task.status {
        case .completed: return "folder"
        case .failed: return "arrow.clockwise"
        case .paused, .queued: return "play.fill"
        default: return "pause.fill"
        }
    }

    private var helpText: String {
        switch task.status {
        case .completed: return "Open folder"
        case .failed: return "Retry"
        case .paused, .queued: return "Resume"
        default: return "Pause"
        }
    }

    private func action() {
        switch task.status {
        case .completed: vm.revealInFinder(task)
        case .failed: vm.retry(task.id)
        case .paused, .queued: vm.resume(task.id)
        default: vm.pause(task.id)
        }
    }
}
