import Foundation

/// The one thing ``AppDelegate`` needs to know about the download queue: two booleans,
/// since the delegate never sees ``AppViewModel`` but decides whether closing quits.
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

    /// Whether the menu-bar item is showing — i.e. whether there is a way back into the app
    /// after its last window closes. Hidden, the app must be allowed to quit regardless.
    var menuBarVisible: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _menuBarVisible }
        set { lock.lock(); _menuBarVisible = newValue; lock.unlock() }
    }
}
