import SwiftUI
import AppKit
import GoelCore

// ============================================================================
// Settings ▸ Licence.
//
// READ THIS BEFORE CHANGING ANYTHING HERE.
//
// This pane is INFORMATIONAL AND NOTHING ELSE. It states the terms, says who
// needs a paid licence, and offers a way to ask for one. It does not — and must
// never — verify a key, count days, compare a date, hide a feature, degrade
// behaviour, nag on a timer, or send a single byte anywhere.
//
// That is a product decision, not an oversight. Compliance for Goel° is
// honour-based, and the reasoning is stated in LICENSE-COMMERCIAL.md: a false
// positive from a licence check — a paying customer locked out of their own
// downloads at the worst possible moment — costs far more than the revenue any
// check could plausibly recover. Every user runs the identical binary with the
// identical capabilities.
//
// The one editable field below is a free-text note the *user* keeps for their
// *own* audit file. It is never read by any other code path, never validated,
// never transmitted, and leaving it blank changes nothing whatsoever. It lives
// in `UserDefaults`, not ``AppSettings``, so it cannot reach the download
// engine, the settings export, or the diagnostics bundle.
// ============================================================================

/// Local, user-owned licensing notes. Deliberately outside ``AppSettings``:
/// nothing in the engine, the backup export, or ``DiagnosticsBundle`` should be
/// able to see these, and keeping them here makes that structural rather than a
/// rule someone has to remember.
enum LicenseNotes {

    private static let referenceKey = "licence.commercialReference"
    private static let holderKey = "licence.commercialHolder"

    /// The commercial licence reference an administrator chose to record. Purely
    /// a note to themselves — no format, no validation, no meaning to the app.
    static var reference: String {
        get { UserDefaults.standard.string(forKey: referenceKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: referenceKey) }
    }

    /// The legal entity the licence was issued to, for the same reason.
    static var holder: String {
        get { UserDefaults.standard.string(forKey: holderKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: holderKey) }
    }

    /// Licensing contact, kept in step with LICENSE-COMMERCIAL.md.
    static let contactEmail = "licensing@vinitk.dev"
}

/// The Licence pane: what the terms are, who needs to pay, and how to ask.
struct LicensePane: View {

    @EnvironmentObject private var vm: AppViewModel

    /// Mirrors ``LicenseNotes/reference``. Written straight back on every edit —
    /// there is no Save button because there is nothing to validate.
    @State private var reference: String = LicenseNotes.reference
    @State private var holder: String = LicenseNotes.holder

    /// Whether the "who needs one" detail is expanded. Collapsed by default so
    /// a personal user — the overwhelming majority — sees one short answer and
    /// moves on rather than a wall of legal text.
    @State private var showsDetail = false

    var body: some View {
        PaneScaffold(title: "Licence",
                     subtitle: "What you may do with Goel°, and how to license it for work.") {
            currentLicence
            SectionHeader("Using Goel° at work?")
            atWorkPanel
            SectionHeader("What this app never does")
            neverPanel
            SectionHeader("For your own records")
            recordsPanel
        }
    }

    // MARK: Current licence

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
                    Text("Free for personal use, forever. The full source is available to read and modify. "
                         + "Commercial and business use requires a separate paid licence.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                if let licenceFile = Self.bundledText(named: "LICENSE") {
                    Button("Read the Licence") { NSWorkspace.shared.open(licenceFile) }
                }
                if let commercialFile = Self.bundledText(named: "LICENSE-COMMERCIAL") {
                    Button("Commercial Terms") { NSWorkspace.shared.open(commercialFile) }
                }
                Button("Third-Party Notices") { openThirdPartyNotices() }
            }
            Text("Version \(DiagnosticsBundle.hostAppVersion) (\(DiagnosticsBundle.hostBuildNumber)) · "
                 + "© 2026 Vinit Kumar Goel")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
    }

    // MARK: At work

    private var atWorkPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("If Goel° is used in the course of a business — even by one person, on one laptop, "
                 + "for internal work — that is commercial use and needs a paid licence. "
                 + "Personal downloads, study, charities, schools and public research bodies do not.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            DisclosureGroup(isExpanded: $showsDetail) {
                VStack(alignment: .leading, spacing: 10) {
                    LicenceList(title: "You need a commercial licence if", tint: Theme.orange, items: [
                        "You are a company, partnership or sole trader and Goel° is used for that business.",
                        "You are a contractor or consultant using it in work you bill to a client.",
                        "You deploy it to a managed fleet — MDM, Jamf, Intune, a golden image, shared infrastructure.",
                        "You bundle, resell, host, or offer it as part of a product or service.",
                        "You need a warranty, an indemnity, support, or a signed agreement to file.",
                    ])
                    LicenceList(title: "You do not need to buy anything if", tint: Theme.green, items: [
                        "You are an individual downloading for personal purposes.",
                        "You are a student or researcher with no commercial application in view.",
                        "You are a charity, school, university, or public research, safety or health body.",
                        "You are evaluating Goel° to decide whether to buy. Evaluation is not metered or reported.",
                    ])
                    Text("Not sure which side you fall on? Ask. A one-line email costs nothing and the "
                         + "answer is usually “you’re fine”.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 8)
            } label: {
                Text(showsDetail ? "Hide the detail" : "Who needs one, exactly?")
                    .font(.system(size: 12))
            }

            HStack(spacing: 8) {
                Button("Request a Commercial Licence") {
                    NSWorkspace.shared.open(OnboardingState.commercialURL)
                }
                .buttonStyle(.borderedProminent)
                Button("Email \(LicenseNotes.contactEmail)") { composeLicensingEmail() }
                Spacer()
            }
            .padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.accent.opacity(0.25)))
    }

    // MARK: The guarantees

    /// The other half of honour-based licensing: stating plainly what the app
    /// will never do to you. These are product guarantees, and the code has to
    /// keep matching them.
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
                // A green ✗ is a deliberately odd pairing — it means "this never
                // happens", which is good news. Read as a bare symbol name it is
                // actively misleading, so state the sense in words.
                .a11yGroup(label: "Guarantee, never: \(line)")
            }
        }
        .padding(.top, 4)
    }

    private static let guarantees = [
        "No licence key, activation, serial number, or online check.",
        "No trial clock. Nothing expires and nothing stops working.",
        "No feature gating — paying unlocks nothing, because nothing is locked.",
        "No telemetry, no analytics, no phone-home. Nothing checks whether you have paid.",
        "Diagnostics are only ever sent by you, by hand, from Settings ▸ Advanced.",
    ]

    // MARK: Records

    private var recordsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Bought a commercial licence? You can note the details here so they travel with the "
                 + "install for your own audit or asset records. Goel° never reads these fields, never "
                 + "checks them, and never sends them anywhere — leaving them blank changes nothing.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            SetRow(name: "Licensed to", desc: "The legal entity named on your licence.") {
                TextField("", text: $holder)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    // A raw `TextField` doesn't pick up `SetRow`'s environment
                    // name the way the `Setting*` wrappers do.
                    .accessibilityLabel("Licensed to")
                    .onChange(of: holder) { _, new in LicenseNotes.holder = new }
            }
            SetRow(name: "Licence reference",
                   desc: "Whatever your invoice or agreement calls it. Free text — no format is expected.") {
                TextField("", text: $reference)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .accessibilityLabel("Licence reference")
                    .onChange(of: reference) { _, new in LicenseNotes.reference = new }
            }
        }
    }

    // MARK: Actions

    /// A pre-addressed enquiry. `mailto:` hands off to the user's mail client —
    /// the app itself sends nothing.
    private func composeLicensingEmail() {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = LicenseNotes.contactEmail
        components.queryItems = [
            URLQueryItem(name: "subject", value: "Goel° commercial licence enquiry"),
        ]
        guard let url = components.url else { return }
        NSWorkspace.shared.open(url)
    }

    /// Third-party notices ship beside the licence in the packaged app. In a dev
    /// build the resource is absent, so say so rather than doing nothing.
    private func openThirdPartyNotices() {
        if let url = Self.bundledText(named: "THIRD-PARTY-NOTICES") {
            NSWorkspace.shared.open(url)
        } else {
            vm.settingsMessage("Third-Party Notices",
                "The notices file ships inside the packaged app. In a source build, read "
                + "THIRD-PARTY-NOTICES.md in the repository.")
        }
    }

    /// A legal text copied into `Contents/Resources` by the build script. Both
    /// `.txt` (what the script writes) and `.md` (a source checkout) are tried,
    /// and `nil` simply hides the button — a missing file is never an error.
    private static func bundledText(named name: String) -> URL? {
        for ext in ["txt", "md"] {
            if let url = Bundle.main.url(forResource: name, withExtension: ext) {
                return url
            }
        }
        return nil
    }
}

/// A titled bullet list. Its own type so the two lists in the "at work" panel
/// cannot drift apart on spacing or bullet treatment.
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
