import SwiftUI
import AppKit
import GoelCore

/// Kept outside ``AppSettings`` so backup export and ``DiagnosticsBundle`` cannot see these.
enum LicenseNotes {

    private static let referenceKey = "licence.commercialReference"
    private static let holderKey = "licence.commercialHolder"

    static var reference: String {
        get { UserDefaults.standard.string(forKey: referenceKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: referenceKey) }
    }

    static var holder: String {
        get { UserDefaults.standard.string(forKey: holderKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: holderKey) }
    }

    static let contactEmail = "licensing@vinitk.dev"
}

/// Licence: what you may do with Goel°, and how to license it for work.
struct LicenceSettingsPane: View {
    @EnvironmentObject private var vm: AppViewModel

    @State private var reference: String = LicenseNotes.reference
    @State private var holder: String = LicenseNotes.holder
    @State private var showsDetail: Bool

    init(showsDetail: Bool = false) {
        _showsDetail = State(initialValue: showsDetail)
    }

    var body: some View {
        SettingsPane(title: L10n.t("Licence"),
                     subtitle: L10n.t("What you may do with Goel°, and how to license it for work.")) {
            currentLicence
            atWorkCard
            neverCard
                .settingsColumn(.trailing)
            recordsCard
                .settingsColumn(.trailing)
        }
    }

    private var currentLicence: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: Studio.Space.m) {
                HStack(alignment: .top, spacing: Studio.Space.m) {
                    Image(systemName: "checkmark.seal.fill")
                        .studioFont(.ui, size: 18, weight: 600)
                        .foregroundStyle(Studio.Palette.good)
                        .frame(width: 36, height: 36)
                        .background(Studio.Palette.goodSoft, in: RoundedRectangle(cornerRadius: Studio.Radius.control, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: "PolyForm Noncommercial 1.0.0")
                            .studioFont(.title3)
                            .foregroundStyle(Studio.Palette.ink)
                            .accessibilityAddTraits(.isHeader)
                        Text(L10n.t("Free for personal use, forever. The full source is available to read and modify. "
                             + "Commercial and business use requires a separate paid licence."))
                            .studioFont(.small)
                            .foregroundStyle(Studio.Palette.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: Studio.Space.s) {
                    if let licenceFile = Self.bundledText(named: "LICENSE") {
                        Button(L10n.t("Read the Licence")) { NSWorkspace.shared.open(licenceFile) }
                            .buttonStyle(.studio(.secondary, size: .small))
                    }
                    if let commercialFile = Self.bundledText(named: "LICENSE-COMMERCIAL") {
                        Button(L10n.t("Commercial Terms")) { NSWorkspace.shared.open(commercialFile) }
                            .buttonStyle(.studio(.secondary, size: .small))
                    }
                    Button(L10n.t("Third-Party Notices")) { openThirdPartyNotices() }
                        .buttonStyle(.studio(.secondary, size: .small))
                }
                Text(L10n.t("Version %1$@ (%2$@)",
                            DiagnosticsBundle.hostAppVersion, DiagnosticsBundle.hostBuildNumber)
                     + " · © 2026 Vinit Kumar Goel")
                    .studioFont(.monoSmall)
                    .foregroundStyle(Studio.Palette.ink3)
            }
        }
    }

    private var atWorkCard: some View {
        SettingsCard(title: L10n.t("Using Goel° at work?"), symbol: "briefcase") {
            SettingsCardBlock(showsDivider: false) {
                Text(L10n.t("If Goel° is used in the course of a business — even by one person, on one laptop, "
                     + "for internal work — that is commercial use and needs a paid licence. "
                     + "Personal downloads, study, charities, schools and public research bodies do not."))
                    .studioFont(.small)
                    .foregroundStyle(Studio.Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    showsDetail.toggle()
                } label: {
                    Label(showsDetail ? L10n.t("Hide the detail") : L10n.t("Who needs one, exactly?"),
                          systemImage: showsDetail ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.studio(.ghost, size: .small))
                .padding(.leading, -Studio.Space.sm)

                if showsDetail {
                    VStack(alignment: .leading, spacing: Studio.Space.m) {
                        LicenceList(title: L10n.t("You need a commercial licence if"), tone: .warn, items: [
                            L10n.t("You are a company, partnership or sole trader and Goel° is used for that business."),
                            L10n.t("You are a contractor or consultant using it in work you bill to a client."),
                            L10n.t("You deploy it to a managed fleet — MDM, Jamf, Intune, a golden image, shared infrastructure."),
                            L10n.t("You bundle, resell, host, or offer it as part of a product or service."),
                            L10n.t("You need a warranty, an indemnity, support, or a signed agreement to file."),
                        ])
                        LicenceList(title: L10n.t("You do not need to buy anything if"), tone: .good, items: [
                            L10n.t("You are an individual downloading for personal purposes."),
                            L10n.t("You are a student or researcher with no commercial application in view."),
                            L10n.t("You are a charity, school, university, or public research, safety or health body."),
                            L10n.t("You are evaluating Goel° to decide whether to buy. Evaluation is not metered or reported."),
                        ])
                        Text(L10n.t("Not sure which side you fall on? Ask. A one-line email costs nothing and the "
                             + "answer is usually “you’re fine”."))
                            .studioFont(.caption)
                            .foregroundStyle(Studio.Palette.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Studio.Space.s) { commercialButtons }
                    VStack(alignment: .leading, spacing: Studio.Space.xs) { commercialButtons }
                }
                .padding(.top, 2)
            }
        }
    }

    @ViewBuilder private var commercialButtons: some View {
        Button(L10n.t("Request a Commercial Licence")) {
            NSWorkspace.shared.open(OnboardingState.commercialURL)
        }
        .buttonStyle(.studio(.primary, size: .small))
        .fixedSize()
        Button(L10n.t("Email %@", LicenseNotes.contactEmail)) { composeLicensingEmail() }
            .buttonStyle(.studio(.secondary, size: .small))
            .fixedSize()
    }

    /// These are product guarantees — the code has to keep matching them.
    private var neverCard: some View {
        SettingsCard(title: L10n.t("What this app never does"), symbol: "hand.raised") {
            SettingsCardBlock(showsDivider: false) {
                ForEach(Self.guarantees, id: \.self) { line in
                    HStack(alignment: .firstTextBaseline, spacing: Studio.Space.s) {
                        Image(systemName: "xmark.circle")
                            .studioFont(.ui, size: 12, weight: 650)
                            .foregroundStyle(Studio.Palette.good)
                        Text(line)
                            .studioFont(.small)
                            .foregroundStyle(Studio.Palette.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .a11yGroup(label: L10n.t("Guarantee, never: %@", line))
                }
            }
        }
    }

    private static var guarantees: [String] {
        [
            L10n.t("No licence key, activation, serial number, or online check."),
            L10n.t("No trial clock. Nothing expires and nothing stops working."),
            L10n.t("No feature gating — paying unlocks nothing, because nothing is locked."),
            L10n.t("No telemetry, no analytics, no phone-home. Nothing checks whether you have paid."),
            L10n.t("Diagnostics are only ever sent by you, by hand, from Settings ▸ Diagnostics."),
        ]
    }

    private var recordsCard: some View {
        SettingsCard(title: L10n.t("For your own records"), symbol: "doc.text") {
            SettingsCardBlock(showsDivider: false) {
                Text(L10n.t("Bought a commercial licence? You can note the details here so they travel with the "
                     + "install for your own audit or asset records. Goel° never reads these fields, never "
                     + "checks them, and never sends them anywhere — leaving them blank changes nothing."))
                    .studioFont(.caption)
                    .foregroundStyle(Studio.Palette.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SettingRow(L10n.t("Licensed to"), detail: L10n.t("The legal entity named on your licence.")) {
                SettingsTextField(text: $holder, width: 180, accessibilityName: L10n.t("Licensed to"))
                    .onChange(of: holder) { _, new in LicenseNotes.holder = new }
            }
            SettingRow(L10n.t("Licence reference"),
                       detail: L10n.t("Whatever your invoice or agreement calls it. Free text — no format is expected.")) {
                SettingsTextField(text: $reference, width: 180, isMonospaced: true,
                                  accessibilityName: L10n.t("Licence reference"))
                    .onChange(of: reference) { _, new in LicenseNotes.reference = new }
            }
        }
    }

    private func composeLicensingEmail() {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = LicenseNotes.contactEmail
        components.queryItems = [
            URLQueryItem(name: "subject", value: L10n.t("Goel° commercial licence enquiry")),
        ]
        guard let url = components.url else { return }
        NSWorkspace.shared.open(url)
    }

    private func openThirdPartyNotices() {
        if let url = Self.bundledText(named: "THIRD-PARTY-NOTICES") {
            NSWorkspace.shared.open(url)
        } else {
            vm.settingsMessage(L10n.t("Third-Party Notices"),
                L10n.t("The notices file ships inside the packaged app. In a source build, read "
                + "THIRD-PARTY-NOTICES.md in the repository."))
        }
    }

    private static func bundledText(named name: String) -> URL? {
        for ext in ["txt", "md"] {
            if let url = Bundle.main.url(forResource: name, withExtension: ext) {
                return url
            }
        }
        return nil
    }
}

private struct LicenceList: View {
    let title: String
    let tone: StudioTone
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .studioFont(.small.weight(650))
                .foregroundStyle(tone.foreground)
            ForEach(items, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: Studio.Space.s) {
                    Circle()
                        .fill(tone.foreground.opacity(0.7))
                        .frame(width: 4, height: 4)
                        .offset(y: -2)
                    Text(item)
                        .studioFont(.caption)
                        .foregroundStyle(Studio.Palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}
