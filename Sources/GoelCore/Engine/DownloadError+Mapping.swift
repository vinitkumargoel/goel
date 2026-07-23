import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // URLError lives here on Linux
#endif

// `URLError` is a *networking* type, not a domain primitive. Keeping this mapping
// here — in the engine layer — rather than beside the `DownloadError` declaration
// (`Model/Primitives.swift`) is what lets the domain model stay platform-free: the
// contract depends on `Foundation` value types only, never `URLSession`/`URLError`.
// That boundary is what a future `GoelContracts` target (and a non-Apple / JNI
// consumer) needs the domain enum to hold to.
public extension DownloadError {
    /// Best-effort mapping of an arbitrary transfer error to a `DownloadError`:
    /// pass an existing `DownloadError` through unchanged, translate the common
    /// `URLError` codes, and otherwise fall back to `.network` with the
    /// underlying description. Shared by the HTTP and HLS engines.
    init(mapping error: Error) {
        if let de = error as? DownloadError { self = de; return }
        if let ue = error as? URLError {
            switch ue.code {
            case .timedOut: self = .timedOut
            case .cancelled: self = .canceled
            case .fileDoesNotExist: self = .fileMissing
            default: self = .network(ue.localizedDescription)
            }
            return
        }
        self = .network((error as NSError).localizedDescription)
    }
}
