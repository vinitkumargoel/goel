import SwiftUI
import GoelCore

/// The window's top row: the omnibox, then live ↓/↑ totals, the optional toolbar items, Add (⌘N),
/// the inspector toggle and the Customize menu. Sort, Filter and Select belong to the content
/// header now (Downloads area), so they are not here.
struct HeaderBar: View {
    @EnvironmentObject private var vm: AppViewModel
    @Binding var omniboxText: String
    var omniboxFocus: FocusState<Bool>.Binding
    /// Off on the first-run screen, which centres its own omnibox.
    var showsOmnibox = true

    @AppStorage(ToolbarSlot.storageKey) private var slotsRaw = ""
    @Environment(\.mainWindowPreview) private var preview
    @State private var showsCustomize = false
    /// With Search hidden, the compact button (or ⌘F) opened the omnibox; leaving it empty folds it.
    @State private var searchOpened = false

    private var slots: Set<ToolbarSlot> { preview?.toolbarSlots ?? ToolbarSlot.decode(slotsRaw) }

    private var showsFullOmnibox: Bool {
        HeaderSearch.showsOmnibox(searchShown: slots.contains(.search), isOpened: searchOpened,
                                  text: omniboxText, hasClipboardSuggestion: vm.clipboardSuggestion != nil)
    }

    static let omniboxMaxWidth: CGFloat = 820
    static let inputHeight: CGFloat = 58

    var body: some View {
        HStack(alignment: .top, spacing: Studio.Space.ml) {
            if showsOmnibox {
                if showsFullOmnibox {
                    MainOmnibox(text: $omniboxText, isFocused: omniboxFocus)
                        .frame(maxWidth: Self.omniboxMaxWidth)
                        .layoutPriority(1)
                        .onAppear { if searchOpened { omniboxFocus.wrappedValue = true } }
                } else {
                    compactSearchButton
                        .frame(height: Self.inputHeight)
                }
            }
            Spacer(minLength: 0)
            controls
                .frame(height: Self.inputHeight)
        }
        .padding(.horizontal, Studio.Space.gutter)
        .padding(.top, Studio.Space.l)
        .padding(.bottom, Studio.Space.sm)
        .contextMenu { HeaderCustomizeMenu(raw: $slotsRaw) }
        // ⌘F reaches the omnibox through RootView; a hidden Search has to unfold first.
        .onReceive(NotificationCenter.default.publisher(for: FocusBus.focusSearch)) { _ in
            searchOpened = true
        }
        .onChange(of: omniboxFocus.wrappedValue) { wasFocused, isFocused in
            if wasFocused && !isFocused { searchOpened = false }
        }
    }

    /// Search hidden under Customize: a magnifier that unfolds the omnibox and focuses it.
    private var compactSearchButton: some View {
        StudioIconButton("magnifyingglass", label: L10n.t("Search downloads"), bordered: true,
                         shortcutHint: "⌘F") {
            searchOpened = true
            omniboxFocus.wrappedValue = true
        }
    }

    private var controls: some View {
        HStack(spacing: Studio.Space.s) {
            HeaderToolbarItems(slots: slots)
            Button(L10n.t("Add"), systemImage: "plus") { vm.isAddSheetPresented = true }
                .buttonStyle(.studio(.primary))
                // ⌘N lives in File ▸ Add Download…; binding it here too made the shortcut ambiguous.
                .help(ShortcutHint.help(L10n.t("Add download"), "⌘N"))
                .accessibilityLabel(L10n.t("Add download"))
            if slots.contains(.inspector) {
                // ⌘I is bound once, in View ▸ Toggle Detail Panel; the palette advertises the same key.
                StudioIconButton("sidebar.right", label: L10n.t("Toggle detail panel"),
                                 bordered: true, isOn: vm.detailPanelVisible, shortcutHint: "⌘I") {
                    vm.detailPanelVisible.toggle()
                }
                .accessibilityLabel(L10n.t("Detail panel"))
                .accessibilityValue(vm.detailPanelVisible ? L10n.t("Shown") : L10n.t("Hidden"))
            }
            StudioIconButton("ellipsis", label: L10n.t("Customize Toolbar"), bordered: true) {
                showsCustomize.toggle()
            }
            .popover(isPresented: $showsCustomize, arrowEdge: .bottom) {
                HeaderCustomizePopover(raw: $slotsRaw)
            }
        }
        .fixedSize()
    }
}

/// Right-click on the header: one checkable item per optional button (native menu).
struct HeaderCustomizeMenu: View {
    @Binding var raw: String

    var body: some View {
        Section(L10n.t("Show in Toolbar")) {
            ForEach(HeaderCustomizePopover.customizable) { slot in
                Toggle(slot.title, isOn: Binding(
                    get: { ToolbarSlot.decode(raw).contains(slot) },
                    set: { _ in raw = ToolbarSlot.toggling(slot, in: raw) }))
            }
        }
        Divider()
        Button(L10n.t("Reset Toolbar")) { raw = "" }
    }
}

/// The ⋯ button's popover: the same choices as the right-click menu, in Studio chrome.
struct HeaderCustomizePopover: View {
    @Binding var raw: String

    /// Every optional item. Hiding Search folds the omnibox to a magnifier until it is needed.
    static var customizable: [ToolbarSlot] { ToolbarSlot.allCases }

    var body: some View {
        StudioPopover(title: L10n.t("Show in Toolbar"), width: 240) {
            VStack(alignment: .leading, spacing: Studio.Space.s) {
                ForEach(Self.customizable) { slot in
                    Toggle(slot.title, isOn: Binding(
                        get: { ToolbarSlot.decode(raw).contains(slot) },
                        set: { _ in raw = ToolbarSlot.toggling(slot, in: raw) }))
                        .toggleStyle(.studioCheckbox)
                }
                StudioDivider(strong: true)
                Button(L10n.t("Reset Toolbar")) { raw = "" }
                    .buttonStyle(.studio(.ghost, size: .small))
            }
        }
    }
}
