import SwiftUI
import AppKit
import UniformTypeIdentifiers
import GoelCore

/// The File-menu import / export / paste actions, shared by the menu bar and the command palette
/// so both run exactly the same code.
@MainActor
enum MenuActions {

    static func exportBackup(_ vm: AppViewModel) {
        guard let url = FilePicker.save(name: "GoelDownloader-backup.json", type: .json) else { return }
        vm.exportBackup(to: url)
    }

    static func importBackup(_ vm: AppViewModel) {
        guard let url = FilePicker.openFile(types: [.json]) else { return }
        vm.importBackup(from: url)
    }

    /// Through the Add sheet: several links get the review step, one gets its preview.
    static func pasteFromClipboard(_ vm: AppViewModel) {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        vm.addFromClipboard()
    }

    static func pasteFromFile(_ vm: AppViewModel) {
        guard let contents = readTextFile(vm) else { return }
        vm.add(rawLines: contents, saveDirectory: nil, priority: .normal)
    }

    static func exportList(_ vm: AppViewModel) {
        guard let url = FilePicker.save(name: "GoelDownloader-list.txt", type: .plainText) else { return }
        let body = vm.tasks.map(\.source.locator).joined(separator: "\n")
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
            vm.toastSuccess(L10n.t("Download list exported"))
        } catch {
            vm.toastError(L10n.t("Export failed"))
        }
    }

    static func importList(_ vm: AppViewModel) {
        guard let contents = readTextFile(vm) else { return }
        vm.add(rawLines: contents, saveDirectory: nil, priority: .normal)
    }

    static func importForeign(_ vm: AppViewModel) {
        guard let url = FilePicker.openFile(
            message: L10n.t("Choose a file exported by aria2, JDownloader, IDM, a browser, etc.")
        ) else { return }
        guard let data = try? Data(contentsOf: url) else {
            vm.toastError(L10n.t("Couldn’t read that file"))
            return
        }
        let text = String(decoding: data, as: UTF8.self)
        let locators = ForeignImportParser.extractLocators(from: text)
        guard !locators.isEmpty else {
            vm.toastWarning(L10n.t("No downloadable links found in that file"))
            return
        }
        // `add` reports what it queued and what it skipped; a second "Imported N" toast here
        // used to overwrite "All N are already in your list" before anyone could read it.
        vm.add(rawLines: locators.joined(separator: "\n"), saveDirectory: nil, priority: .normal)
    }

    private static func readTextFile(_ vm: AppViewModel) -> String? {
        guard let url = FilePicker.openFile(types: [.plainText, .text]) else { return nil }
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            vm.toastError(L10n.t("Couldn’t read that file"))
            return nil
        }
        return contents
    }
}
