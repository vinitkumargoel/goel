import SwiftUI
import GoelCore

/// Kept for `SpeedGraphViews` (Windows area), which titles its 14-day chart with it. Same name
/// and init as the old Details-tab label, drawn as a Studio eyebrow. Remove once Windows has
/// moved to `StudioSectionHeader`.
struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .studioFont(.eyebrow)
            .foregroundStyle(Studio.Palette.ink3)
            .padding(.top, Studio.Space.l)
            .padding(.bottom, Studio.Space.s)
            .accessibilityLabel(text)
            .accessibilityAddTraits(.isHeader)
    }
}
