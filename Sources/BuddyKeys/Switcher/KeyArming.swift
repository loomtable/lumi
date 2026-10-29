import Synchronization

/// The switcher filter shared by the two taps: the consuming `SwitcherTap` decides with it, and
/// the listen-only `EventTapSource` drops what it takes. Which of two taps sees an event first
/// isn't guaranteed, so both read one state and a key is never seen twice.
public final class KeyArming: Sendable {
    private let filter = Mutex(SwitcherFilter())

    public init() {}

    public var arming: SwitcherFilter.Arming? { filter.withLock { $0.arming } }
    public var awaitingKeyUp: Bool { filter.withLock { $0.awaitingKeyUp } }

    public func set(_ arming: SwitcherFilter.Arming?) {
        filter.withLock { $0.arming = arming }
    }

    func consume(_ kind: SwitcherFilter.Kind, keyCode: UInt16, flags: UInt64, isRepeat: Bool) -> SwitcherFilter.Decision {
        filter.withLock { $0.consume(kind, keyCode: keyCode, flags: flags, isRepeat: isRepeat) }
    }

    func drops(keyCode: UInt16, flags: UInt64) -> Bool {
        filter.withLock { $0.drops(keyCode: keyCode, flags: flags) }
    }
}
