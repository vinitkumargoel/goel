import Foundation

/// The one thing ``AppDelegate`` needs to know about the download queue.
///
/// `AppDelegate` is instantiated by `@NSApplicationDelegateAdaptor` and never
/// sees ``AppViewModel``, so the two cannot be wired directly — but the delegate
/// is where macOS asks whether closing the last window should quit, and quitting
/// there abandons every in-flight transfer with no warning. This is the smallest
/// possible seam: two booleans the view model publishes and the delegate reads.
///
/// Its only mutable state is guarded by a lock, hence `@unchecked Sendable` —
/// matching ``PowerManager``'s house style.
final class ActiveWorkGate: @unchecked Sendable {

    static let shared = ActiveWorkGate()

    private let lock = NSLock()
    private var _hasActiveWork = false
    private var _menuBarVisible = true

    private init() {}

    /// Whether any download or SFTP transfer is currently running. Published by
    /// ``AppViewModel``'s snapshot pump on every tick.
    var hasActiveWork: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _hasActiveWork }
        set { lock.lock(); _hasActiveWork = newValue; lock.unlock() }
    }

    /// Whether the menu-bar status item is showing — i.e. whether there is a way
    /// back into the app after its last window closes. With it hidden, staying
    /// resident would strand the user with an invisible process, so the app must
    /// be allowed to quit even with work in flight (the terminate confirmation
    /// still gets its say).
    var menuBarVisible: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _menuBarVisible }
        set { lock.lock(); _menuBarVisible = newValue; lock.unlock() }
    }
}
