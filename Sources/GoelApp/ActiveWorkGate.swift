import Foundation

final class ActiveWorkGate: @unchecked Sendable {

    static let shared = ActiveWorkGate()

    private let lock = NSLock()
    private var _hasActiveWork = false
    private var _menuBarVisible = true

    private init() {}

    var hasActiveWork: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _hasActiveWork }
        set { lock.lock(); _hasActiveWork = newValue; lock.unlock() }
    }

    var menuBarVisible: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _menuBarVisible }
        set { lock.lock(); _menuBarVisible = newValue; lock.unlock() }
    }
}
