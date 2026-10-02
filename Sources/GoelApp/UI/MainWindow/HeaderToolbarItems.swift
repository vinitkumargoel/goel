import SwiftUI
import GoelCore

/// The optional header buttons, each shown only when switched on under Customize.
struct HeaderToolbarItems: View {
    @EnvironmentObject private var vm: AppViewModel
    let slots: Set<ToolbarSlot>

    @State private var showsProfiles = false
    @State private var showsServers = false

    var body: some View {
        HStack(spacing: Studio.Space.s) {
            if slots.contains(.pauseResume) { pauseResumeAllButton }
            if slots.contains(.remove) {
                StudioIconButton("trash", label: L10n.t("Remove from List"), bordered: true) {
                    vm.removeSelected(deleteData: false)
                }
                .disabled(vm.selection.isEmpty)
            }
            if slots.contains(.speedLimit) { speedLimitButton }
            if slots.contains(.profile) { profileButton }
            if slots.contains(.linkGrabber) {
                StudioIconButton("link.badge.plus", label: L10n.t("Link Grabber"), bordered: true,
                                 shortcutHint: "⇧⌘L") {
                    vm.isLinkGrabberPresented = true
                }
            }
            if slots.contains(.dropBasket) {
                StudioIconButton("basket", label: L10n.t("Drop Basket"), bordered: true, shortcutHint: "⇧⌘B") {
                    DropBasketController.shared.toggle()
                }
            }
            if slots.contains(.sftp) { serversButton }
        }
    }

    /// Pause All while anything is running or waiting, Resume All once everything is paused.
    /// Disabled, not hidden, when there is nothing to do, so the header doesn't shift.
    private var pauseResumeAllButton: some View {
        let state = vm.commandState.snapshot
        let pausing = state.pauseAllPauses
        let title = pausing ? L10n.t("Pause All") : L10n.t("Resume All")
        return StudioIconButton(pausing ? "pause.circle" : "play.circle", label: title, bordered: true) {
            if pausing { vm.pauseAll() } else { vm.resumeAll() }
        }
        .disabled(!state.pauseAllEnabled)
    }

    private var speedLimitButton: some View {
        let on = vm.settings.speedLimitEnabled
        return StudioIconButton(on ? "tortoise.fill" : "tortoise",
                                label: on ? L10n.t("Turn Speed Limit Off") : L10n.t("Turn Speed Limit On"),
                                bordered: true, isOn: on) {
            vm.toggleSnail()
        }
        .disabled(vm.managedPolicy.isLocked(.speedLimitEnabled))
    }

    private var profileButton: some View {
        Button(vm.settings.selectedProfileName, systemImage: "gauge.with.dots.needle.33percent") {
            showsProfiles.toggle()
        }
        .buttonStyle(.studio(.secondary))
        .help(L10n.t("Speed profile"))
        .accessibilityLabel(L10n.t("Speed profile"))
        .accessibilityValue(vm.settings.selectedProfileName)
        .popover(isPresented: $showsProfiles, arrowEdge: .bottom) {
            StudioPopover(width: 220) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(vm.settings.profiles) { profile in
                        StudioMenuRow(symbol: "gauge.with.dots.needle.33percent", title: profile.name,
                                      isChecked: profile.name == vm.settings.selectedProfileName) {
                            showsProfiles = false
                            vm.setProfile(profile.name)
                        }
                    }
                }
            }
        }
    }

    private var serversButton: some View {
        StudioIconButton("server.rack", label: L10n.t("SFTP Servers"), bordered: true) {
            showsServers.toggle()
        }
        .popover(isPresented: $showsServers, arrowEdge: .bottom) {
            StudioPopover(width: 240) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(vm.servers) { server in
                        StudioMenuRow(symbol: "server.rack", title: server.label) {
                            showsServers = false
                            vm.selectServer(server.id)
                        }
                    }
                    if !vm.servers.isEmpty { StudioDivider().padding(.vertical, Studio.Space.xxs) }
                    StudioMenuRow(symbol: "plus", title: L10n.t("Add Server…")) {
                        showsServers = false
                        vm.presentNewServer()
                    }
                }
            }
        }
    }
}
