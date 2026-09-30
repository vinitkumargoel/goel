import Foundation
import GoelCore

/// Turns a `DownloadError` into what the user can do about it. The error message itself says
/// what went wrong; this says why it probably happened and which button to press next.
enum FailureAdvice {

    static func hint(for error: DownloadError) -> String? {
        switch error {
        case .httpStatus(let code):
            return hint(forHTTPStatus: code)
        case .diskFull:
            return L10n.t("The disk is full. Free up space or choose another folder, then retry.")
        case .network(let message):
            return looksLikeDiskFull(message)
                ? L10n.t("The disk is full. Free up space or choose another folder, then retry.")
                : L10n.t("Check your internet connection, then retry.")
        case .unknown(let message):
            return looksLikeDiskFull(message)
                ? L10n.t("The disk is full. Free up space or choose another folder, then retry.")
                : nil
        case .timedOut:
            return L10n.t("The server stopped answering. Check your connection, then retry.")
        case .checksumMismatch:
            return L10n.t("The file doesn’t match its published checksum — it may be damaged. Retry to download it again.")
        case .rangeNotSupported:
            return L10n.t("This server can’t resume. Retry starts the download from the beginning.")
        case .remoteFileChanged:
            return L10n.t("The file changed on the server. Retry starts the download from the beginning.")
        case .fileMissing:
            return L10n.t("The partial file was moved or deleted. Retry starts the download from the beginning.")
        case .canceled:
            return nil
        }
    }

    static func hint(forHTTPStatus code: Int) -> String? {
        switch code {
        case 401, 403:
            return L10n.t("The link may have expired or needs a login. Copy a fresh link from the page, or attach browser cookies.")
        case 404, 410:
            return L10n.t("The file is no longer at this address. Check the link on the page you got it from.")
        case 407:
            return L10n.t("Your proxy needs a login. Check the proxy settings.")
        case 408, 429:
            return L10n.t("The server is busy or limiting requests. Wait a few minutes, then retry.")
        case 500...599:
            return L10n.t("The server had a problem. Try again later.")
        default:
            return nil
        }
    }

    /// The one step most likely to fix this failure, shown as the card's filled button. Retry
    /// stays next to it as the fallback; nil means Retry itself is the best next step.
    enum Recovery: Equatable {
        /// 401/403: the server wants a login — attach the browser's cookies.
        case attachCookies
        /// 404/410: the link is stale — point the download at a fresh one.
        case updateLink
        /// No room left — move the download somewhere that has it.
        case changeFolder
        /// 407: the proxy wants credentials.
        case proxySettings
        /// 408/429/5xx/timeout: the server is overloaded — come back in a few minutes.
        case retryLater(TimeInterval)

        static let retryLaterDelay: TimeInterval = 5 * 60

        var title: String {
            switch self {
            case .attachCookies: return L10n.t("Attach Cookies…")
            case .updateLink: return L10n.t("Update Link…")
            case .changeFolder: return L10n.t("Change Folder…")
            case .proxySettings: return L10n.t("Proxy Settings")
            case .retryLater(let delay):
                return L10n.t("Retry in %@", DisplayFormat.duration(delay, locale: DisplayFormat.appLocale))
            }
        }

        var symbol: String {
            switch self {
            case .attachCookies: return "person.badge.key"
            case .updateLink: return "link"
            case .changeFolder: return "folder.badge.plus"
            case .proxySettings: return "network"
            case .retryLater: return "clock.arrow.circlepath"
            }
        }
    }

    /// Only what the task can actually take: a link or cookie swap needs an HTTP download, and
    /// only HTTP carries a partial file to another folder.
    static func recovery(for error: DownloadError, kind: DownloadKind, hasData: Bool) -> Recovery? {
        switch error {
        case .httpStatus(let code):
            switch code {
            case 401, 403: return kind == .http ? .attachCookies : nil
            case 404, 410: return kind == .http ? .updateLink : nil
            case 407: return .proxySettings
            case 408, 429, 500...599: return .retryLater(Recovery.retryLaterDelay)
            default: return nil
            }
        case .timedOut:
            return .retryLater(Recovery.retryLaterDelay)
        case .diskFull:
            return canChangeFolder(kind: kind, hasData: hasData) ? .changeFolder : nil
        case .network(let message), .unknown(let message):
            return looksLikeDiskFull(message) && canChangeFolder(kind: kind, hasData: hasData)
                ? .changeFolder : nil
        case .checksumMismatch, .rangeNotSupported, .remoteFileChanged, .fileMissing, .canceled:
            return nil
        }
    }

    static func recovery(for task: DownloadTask, error: DownloadError) -> Recovery? {
        recovery(for: error, kind: task.kind, hasData: task.bytesDownloaded > 0)
    }

    /// Mirrors `DownloadManager.relocate`: only HTTP carries its partial across folders.
    private static func canChangeFolder(kind: DownloadKind, hasData: Bool) -> Bool {
        kind == .http || !hasData
    }

    /// POSIX ENOSPC surfaces through several layers as free text; match its common spellings.
    static func looksLikeDiskFull(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("no space left")
            || lower.contains("disk full")
            || lower.contains("not enough disk space")
            || lower.contains("enospc")
    }

    /// The text "Copy error details" puts on the pasteboard: enough for a bug report or a forum post.
    /// Cookie and header values are left out on purpose — they are live credentials.
    static func details(for task: DownloadTask, error: DownloadError) -> String {
        var lines = [
            L10n.t("Download: %@", task.name),
            L10n.t("Error: %@", error.message),
        ]
        if let hint = hint(for: error) { lines.append(L10n.t("Suggestion: %@", hint)) }
        lines.append(L10n.t("Source: %@", redactedLocator(task.source.locator)))
        lines.append(L10n.t("Save path: %@", task.savePath))
        return lines.joined(separator: "\n")
    }

    /// `https://user:pass@host/…` keeps its host and path but loses the inline credentials.
    static func redactedLocator(_ locator: String) -> String {
        guard var components = URLComponents(string: locator),
              components.user != nil || components.password != nil else { return locator }
        components.user = nil
        components.password = nil
        return components.string ?? locator
    }
}
