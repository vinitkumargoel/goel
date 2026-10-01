import SwiftUI
import GoelCore

/// The optional toolbar buttons, each shown only when switched on in "Customize Toolbar".
struct ToolbarExtras: View {
    @EnvironmentObject private var vm: AppViewModel
    let slots: Set<ToolbarSlot>

    var body: some View {
        HStack(spacing: 8) {
            if slots.contains(.remove) { removeButton }
            if slots.contains(.speedLimit) { speedLimitButton }
            if slots.contains(.profile) { profileMenu }
            if slots.contains(.linkGrabber) {
                iconButton("link.badge.plus", L10n.t("Link Grabber")) { vm.isLinkGrabberPresented = true }
            }
            if slots.contains(.dropBasket) {
                iconButton("tray.and.arrow.down", L10n.t("Drop Basket")) { DropBasketController.shared.toggle() }
            }
            if slots.contains(.sftp) { serversMenu }
        }
    }

    private func iconButton(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .help(title)
            .a11yButton(title)
    }

    private var removeButton: some View {
        iconButton("trash", L10n.t("Remove from List")) { vm.removeSelected(deleteData: false) }
            .disabled(vm.selection.isEmpty)
    }

    private var speedLimitButton: some View {
        let on = vm.settings.speedLimitEnabled
        return iconButton(on ? "tortoise.fill" : "tortoise", on ? L10n.t("Turn Speed Limit Off") : L10n.t("Turn Speed Limit On")) {
            vm.toggleSnail()
        }
        .tint(on ? Theme.orange : nil)
        .disabled(vm.managedPolicy.isLocked(.speedLimitEnabled))
    }

    private var profileMenu: some View {
        Menu {
            ForEach(vm.settings.profiles) { profile in
                Button {
                    vm.setProfile(profile.name)
                } label: {
                    if profile.name == vm.settings.selectedProfileName {
                        Label(profile.name, systemImage: "checkmark")
                    } else {
                        Text(profile.name)
                    }
                }
            }
        } label: {
            Label(vm.settings.selectedProfileName, systemImage: "gauge.with.dots.needle.33percent")
        }
        .menuStyle(.borderedButton)
        .controlSize(.large)
        .fixedSize()
        .help(L10n.t("Queue profile"))
        .accessibilityLabel(L10n.t("Queue profile"))
    }

    private var serversMenu: some View {
        Menu {
            ForEach(vm.servers) { server in
                Button(server.label) { vm.selectServer(server.id) }
            }
            if !vm.servers.isEmpty { Divider() }
            Button(L10n.t("Add Server…")) { vm.presentNewServer() }
        } label: {
            Image(systemName: "server.rack")
        }
        .menuStyle(.borderedButton)
        .controlSize(.large)
        .fixedSize()
        .help(L10n.t("SFTP Servers"))
        .accessibilityLabel(L10n.t("SFTP Servers"))
    }
}

/// Right-click on the toolbar: one checkable item per optional button.
struct ToolbarCustomizeMenu: View {
    @Binding var raw: String

    var body: some View {
        Section(L10n.t("Show in Toolbar")) {
            ForEach(ToolbarSlot.allCases) { slot in
                Toggle(slot.title, isOn: Binding(
                    get: { ToolbarSlot.decode(raw).contains(slot) },
                    set: { _ in raw = ToolbarSlot.toggling(slot, in: raw) }))
            }
        }
        Divider()
        Button(L10n.t("Reset Toolbar")) { raw = "" }
    }
}
