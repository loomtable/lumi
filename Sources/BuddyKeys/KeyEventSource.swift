/// What a key event source reports: raw input for the gesture machine, plus secure input changes.
public enum KeySourceEvent: Sendable, Equatable {
    case input(InputEvent)
    /// Another process turned Secure Event Input on or off. While it is on, the tap still sees
    /// `flagsChanged` but not `keyDown`, so a modifier used to type a character looks like a tap.
    case secureInput(Bool)
}

/// A sensor that delivers keyboard and pointer input. Real: `EventTapSource`. Fake: `FakeKeySource`.
public protocol KeyEventSource: Sendable {
    /// Starts delivering events. Throws if the source cannot start (e.g. no Input Monitoring).
    func start() throws(KeySourceError) -> AsyncStream<KeySourceEvent>
    func stop()
    /// The hardware modifier state right now (`CGEventFlags.rawValue`), used to recover a
    /// release the source never delivered.
    func currentFlags() -> UInt64
}

public enum KeySourceError: Error, Sendable, Equatable {
    case inputMonitoringNotGranted
    case accessibilityNotGranted
    case tapCreationFailed
    case alreadyStarted
}
