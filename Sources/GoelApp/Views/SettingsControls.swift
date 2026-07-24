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
            Text(title).scaledFont(size: 15, weight: .semibold)
                // Lets the VoiceOver rotor jump straight to a pane's title.
                .accessibilityAddTraits(.isHeader)
            Text(subtitle).scaledFont(size: 12).foregroundStyle(.secondary).padding(.bottom, 16)
            content
        }
    }
}

struct SectionHeader: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .scaledFont(size: 10.5, weight: .bold)
            .foregroundStyle(.tertiary)
            .padding(.top, 16)
            .padding(.bottom, 4)
            // Uppercased for the eye; spoken in its natural case, since some
            // screen readers spell all-caps words out letter by letter.
            .accessibilityLabel(text)
            .accessibilityAddTraits(.isHeader)
    }
}

struct SetRow<Control: View>: View {
    let name: String
    let desc: String
    @ViewBuilder let control: Control
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).scaledFont(size: 13)
                if !desc.isEmpty {
                    Text(desc).scaledFont(size: 11).foregroundStyle(.tertiary).lineLimit(2)
                }
            }
            // Name and explanation are one reading, not two stray strings before
            // an unrelated control.
            .accessibilityElement(children: .combine)
            Spacer()
            control
        }
        // ── Naming every settings control, once ─────────────────────────────
        // A `SetRow` puts the control's name in a `Text` on the left and the
        // control itself on the right, and every bound control below calls
        // `labelsHidden()`. Visually the pairing is obvious; structurally there
        // is none, so each of the ~150 switches and fields in Preferences was an
        // anonymous "switch" / "text field" with the name a separate string
        // somewhere before it.
        //
        // Rather than touch every call site, the row publishes its name through
        // the environment and the four bound control types below adopt it as
        // their accessibility label. Anything else placed in a row (a button, a
        // `Dropdown`, a stack of several controls) is untouched and keeps
        // whatever label it defines itself.
        .environment(\.settingRowName, name)
        .padding(.vertical, 10)
        Divider()
    }
}

// MARK: - Bound controls

private struct SettingRowNameKey: EnvironmentKey {
    static let defaultValue: String = ""
}

extension EnvironmentValues {
    /// The name of the enclosing ``SetRow``, supplied so a `labelsHidden()`
    /// control can still be announced by the label the user can see.
    var settingRowName: String {
        get { self[SettingRowNameKey.self] }
        set { self[SettingRowNameKey.self] = newValue }
    }
}

/// A switch backed by a real settings `Binding`, so its initial state reflects
/// the persisted value and toggling commits through ``AppViewModel/update(_:)``.
struct SettingSwitch: View {
    @Binding var isOn: Bool
    @Environment(\.settingRowName) private var rowName
    var body: some View {
        Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch)
            .accessibilityLabel(rowName)
    }
}

/// A free-text field bound to a settings string.
struct SettingText: View {
    @Binding var text: String
    var width: CGFloat = 80
    @Environment(\.settingRowName) private var rowName
    var body: some View {
        TextField("", text: $text).textFieldStyle(.roundedBorder).frame(width: width)
            .accessibilityLabel(rowName)
    }
}

/// A numeric field bound to a settings integer.
struct SettingInt: View {
    @Binding var value: Int
    var width: CGFloat = 80
    @Environment(\.settingRowName) private var rowName
    var body: some View {
        TextField("", value: $value, format: .number).textFieldStyle(.roundedBorder).frame(width: width)
            .accessibilityLabel(rowName)
    }
}

/// A numeric field bound to a settings double (timeouts, intervals, speeds, ratio).
struct SettingDouble: View {
    @Binding var value: Double
    var width: CGFloat = 80
    @Environment(\.settingRowName) private var rowName
    var body: some View {
        TextField("", value: $value, format: .number).textFieldStyle(.roundedBorder).frame(width: width)
            .accessibilityLabel(rowName)
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
            // `help` is a hover tooltip and therefore pointer-only: without the
            // hint, a locked control is simply a dimmed switch that ignores you,
            // with no reachable explanation.
            self.disabled(true)
                .help(AppViewModel.managedFootnote)
                .accessibilityHint(AppViewModel.managedFootnote)
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
                .scaledFont(size: 11)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
