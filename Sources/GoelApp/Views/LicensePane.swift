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

struct LicensePane: View {

    @EnvironmentObject private var vm: AppViewModel

    @State private var reference: String = LicenseNotes.reference
    @State private var holder: String = LicenseNotes.holder

    @State private var showsDetail = false

    var body: some View {
        PaneScaffold(title: L10n.t("Licence"),
                     subtitle: L10n.t("What you may do with Goel°, and how to license it for work.")) {
            currentLicence
            SectionHeader(L10n.t("Using Goel° at work?"))
            atWorkPanel
            SectionHeader(L10n.t("What this app never does"))
            neverPanel
            SectionHeader(L10n.t("For your own records"))
            recordsPanel
        }
    }

    private var currentLicence: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 11) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.green)
                    .a11yDecorative()
                VStack(alignment: .leading, spacing: 3) {
                    Text("PolyForm Noncommercial 1.0.0")
                        .font(.system(size: 14, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(L10n.t("Free for personal use, forever. The full source is available to read and modify. "
                         + "Commercial and business use requires a separate paid licence."))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                if let licenceFile = Self.bundledText(named: "LICENSE") {
                    Button(L10n.t("Read the Licence")) { NSWorkspace.shared.open(licenceFile) }
                }
                if let commercialFile = Self.bundledText(named: "LICENSE-COMMERCIAL") {
                    Button(L10n.t("Commercial Terms")) { NSWorkspace.shared.open(commercialFile) }
                }
                Button(L10n.t("Third-Party Notices")) { openThirdPartyNotices() }
            }
            Text(L10n.t("Version %1$@ (%2$@)",
                        DiagnosticsBundle.hostAppVersion, DiagnosticsBundle.hostBuildNumber)
                 + " · © 2026 Vinit Kumar Goel")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
    }

    private var atWorkPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("If Goel° is used in the course of a business — even by one person, on one laptop, "
                 + "for internal work — that is commercial use and needs a paid licence. "
                 + "Personal downloads, study, charities, schools and public research bodies do not."))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            DisclosureGroup(isExpanded: $showsDetail) {
                VStack(alignment: .leading, spacing: 10) {
                    LicenceList(title: L10n.t("You need a commercial licence if"), tint: Theme.orange, items: [
                        L10n.t("You are a company, partnership or sole trader and Goel° is used for that business."),
                        L10n.t("You are a contractor or consultant using it in work you bill to a client."),
                        L10n.t("You deploy it to a managed fleet — MDM, Jamf, Intune, a golden image, shared infrastructure."),
                        L10n.t("You bundle, resell, host, or offer it as part of a product or service."),
                        L10n.t("You need a warranty, an indemnity, support, or a signed agreement to file."),
                    ])
                    LicenceList(title: L10n.t("You do not need to buy anything if"), tint: Theme.green, items: [
                        L10n.t("You are an individual downloading for personal purposes."),
                        L10n.t("You are a student or researcher with no commercial application in view."),
                        L10n.t("You are a charity, school, university, or public research, safety or health body."),
                        L10n.t("You are evaluating Goel° to decide whether to buy. Evaluation is not metered or reported."),
                    ])
                    Text(L10n.t("Not sure which side you fall on? Ask. A one-line email costs nothing and the "
                         + "answer is usually “you’re fine”."))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 8)
            } label: {
                Text(showsDetail ? L10n.t("Hide the detail") : L10n.t("Who needs one, exactly?"))
                    .font(.system(size: 12))
            }

            HStack(spacing: 8) {
                Button(L10n.t("Request a Commercial Licence")) {
                    NSWorkspace.shared.open(OnboardingState.commercialURL)
                }
                .buttonStyle(.borderedProminent)
                Button(L10n.t("Email %@", LicenseNotes.contactEmail)) { composeLicensingEmail() }
                Spacer()
            }
            .padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.accent.opacity(0.25)))
    }

    /// These are product guarantees — the code has to keep matching them.
    private var neverPanel: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Self.guarantees, id: \.self) { line in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.green)
                    Text(line)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .a11yGroup(label: L10n.t("Guarantee, never: %@", line))
            }
        }
        .padding(.top, 4)
    }

    private static var guarantees: [String] {
        [
            L10n.t("No licence key, activation, serial number, or online check."),
            L10n.t("No trial clock. Nothing expires and nothing stops working."),
            L10n.t("No feature gating — paying unlocks nothing, because nothing is locked."),
            L10n.t("No telemetry, no analytics, no phone-home. Nothing checks whether you have paid."),
            L10n.t("Diagnostics are only ever sent by you, by hand, from Settings ▸ Advanced."),
        ]
    }

    private var recordsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("Bought a commercial licence? You can note the details here so they travel with the "
                 + "install for your own audit or asset records. Goel° never reads these fields, never "
                 + "checks them, and never sends them anywhere — leaving them blank changes nothing."))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            SetRow(name: L10n.t("Licensed to"), desc: L10n.t("The legal entity named on your licence.")) {
                TextField("", text: $holder)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .accessibilityLabel(L10n.t("Licensed to"))
                    .onChange(of: holder) { _, new in LicenseNotes.holder = new }
            }
            SetRow(name: L10n.t("Licence reference"),
                   desc: L10n.t("Whatever your invoice or agreement calls it. Free text — no format is expected.")) {
                TextField("", text: $reference)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .accessibilityLabel(L10n.t("Licence reference"))
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
    let tint: Color
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
            ForEach(items, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Circle()
                        .fill(tint.opacity(0.6))
                        .frame(width: 4, height: 4)
                        .offset(y: -2)
                    Text(item)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}
