import SwiftUI

// MARK: - TrafficProfilePolicy

/// The pure rules behind the Transfers section, kept out of the views so they can be tested
/// without a simulator.
///
/// The interesting one is ``applying(_:to:)``. A traffic profile whose only effect is the word
/// on the row would be exactly the "setting that does nothing" T12 warns against, so choosing a
/// profile also moves the explicit connection count to that profile's preference. The user can
/// still override the number afterwards — the profile sets it, it does not lock it.
public enum TrafficProfilePolicy {

    /// The connection count the engine will honour. `EngineTuning.init` clamps to this too;
    /// the range is named here so the `Stepper` and the clamp cannot drift apart.
    public static let connectionRange: ClosedRange<Int> = 1...8

    public static func clampConnections(_ value: Int) -> Int {
        min(max(value, connectionRange.lowerBound), connectionRange.upperBound)
    }

    /// Applies a profile to a tuning, carrying every unrelated field through untouched.
    ///
    /// Goes through `EngineTuning.init` rather than mutating in place, because the initialiser
    /// is where the connection clamp lives.
    public static func applying(_ profile: TrafficProfile, to tuning: EngineTuning) -> EngineTuning {
        EngineTuning(
            trafficProfile: profile,
            maxConnections: profile.connections,
            speedLimitBytesPerSec: tuning.speedLimitBytesPerSec,
            allowCellular: tuning.allowCellular,
            finishOnWiFi: tuning.finishOnWiFi,
            verifyChecksums: tuning.verifyChecksums
        )
    }
}

// MARK: - TrafficProfilePicker

/// The push destination behind Settings ▸ Transfers ▸ Traffic profile.
///
/// Each row states what the profile actually does — `TrafficProfile.detail` is written in
/// connections, not adjectives — because "Aggressive" on its own tells nobody anything.
public struct TrafficProfilePicker: View {

    @Environment(AppModel.self) private var app

    @ScaledMetric(relativeTo: .body) private var titleSize: CGFloat = Theme.Typo.Size.rowTitle
    @ScaledMetric(relativeTo: .footnote) private var detailSize: CGFloat = Theme.Typo.Size.rowSubtitle

    public init() {}

    public var body: some View {
        List {
            Section {
                ForEach(TrafficProfile.allCases, id: \.self) { profile in
                    row(for: profile)
                }
            } footer: {
                Text("The profile chooses how many connections a transfer opens and how much each one reads at a time. Picking one moves Maximum connections with it; change that number afterwards if you want something in between.")
            }
        }
        .navigationTitle("Traffic profile")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(for profile: TrafficProfile) -> some View {
        let isSelected = app.tuning.trafficProfile == profile

        return Button {
            app.tuning = TrafficProfilePolicy.applying(profile, to: app.tuning)
        } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(profile.displayName)
                        .font(.system(size: titleSize))
                        .foregroundStyle(Theme.Color.label1)
                    Text(profile.detail)
                        .font(.system(size: detailSize))
                        .foregroundStyle(Theme.Color.label2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.Color.ember)
                }
            }
            .frame(minHeight: Theme.Metric.minHitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(profile.displayName). \(profile.detail)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
