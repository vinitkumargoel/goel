import SwiftUI
import GoelCore

// Reusable building blocks for the Preferences panes. Split out of
// `SettingsView.swift` so each pane reads as a flat list of `SetRow`s.

// MARK: - Building blocks

struct PaneScaffold<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).padding(.bottom, 16)
            content
        }
    }
}

struct SectionHeader: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .bold))
            .foregroundStyle(.tertiary)
            .padding(.top, 16)
            .padding(.bottom, 4)
    }
}

struct SetRow<Control: View>: View {
    let name: String
    let desc: String
    @ViewBuilder let control: Control
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 13))
                if !desc.isEmpty {
                    Text(desc).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(2)
                }
            }
            Spacer()
            control
        }
        .padding(.vertical, 10)
        Divider()
    }
}

// MARK: - Bound controls

/// A switch backed by a real settings `Binding`, so its initial state reflects
/// the persisted value and toggling commits through ``AppViewModel/update(_:)``.
struct SettingSwitch: View {
    @Binding var isOn: Bool
    var body: some View { Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch) }
}

/// A free-text field bound to a settings string.
struct SettingText: View {
    @Binding var text: String
    var width: CGFloat = 80
    var body: some View {
        TextField("", text: $text).textFieldStyle(.roundedBorder).frame(width: width)
    }
}

/// A numeric field bound to a settings integer.
struct SettingInt: View {
    @Binding var value: Int
    var width: CGFloat = 80
    var body: some View {
        TextField("", value: $value, format: .number).textFieldStyle(.roundedBorder).frame(width: width)
    }
}

/// A numeric field bound to a settings double (timeouts, intervals, speeds, ratio).
struct SettingDouble: View {
    @Binding var value: Double
    var width: CGFloat = 80
    var body: some View {
        TextField("", value: $value, format: .number).textFieldStyle(.roundedBorder).frame(width: width)
    }
}

// MARK: - Managed (MDM) policy

extension View {

    /// Disable a control an administrator has *forced* through a configuration
    /// profile, and say so on hover.
    ///
    /// Only `isLocked` keys are disabled. A managed key that is merely a
    /// *default* (supplied but not forced) stays editable by design — that is
    /// the difference between "your organisation set this up for you" and "your
    /// organisation requires this", and collapsing the two would make every
    /// deployed default feel like a lockout.
    @ViewBuilder
    func managed(_ key: ManagedPolicy.Key, _ policy: ManagedPolicy) -> some View {
        if policy.isLocked(key) {
            self.disabled(true).help(AppViewModel.managedFootnote)
        } else {
            self
        }
    }
}

/// Banner shown at the top of a settings pane when anything in it is locked, so
/// a greyed-out control has a visible explanation rather than looking broken.
struct ManagedPolicyNotice: View {

    let policy: ManagedPolicy

    /// The keys this pane actually renders; the notice hides when none is locked.
    let keys: [ManagedPolicy.Key]

    var body: some View {
        if keys.contains(where: policy.isLocked) {
            Label("Some settings here are managed by your organisation and can’t be changed.",
                  systemImage: "lock.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
