import Foundation

/// Smooths an RMS level for the glow, dots and rim (Effects): rises with a 30 ms
/// time constant and falls over 120 ms (speech) or 250 ms (mic).
nonisolated public struct LevelEnvelope: Sendable, Equatable {
    public var attack: Double
    public var release: Double
    public private(set) var value: Double = 0

    public init(attack: Double, release: Double) {
        self.attack = attack
        self.release = release
    }

    public static let speech = LevelEnvelope(attack: 0.030, release: 0.120)
    public static let mic = LevelEnvelope(attack: 0.030, release: 0.250)

    /// Advances by `dt` seconds toward `target` (clamped to 0...1) and returns the new value.
    @discardableResult
    public mutating func step(toward target: Double, dt: Double) -> Double {
        let target = min(max(target, 0), 1)
        guard dt > 0 else { return value }
        let tau = target > value ? attack : release
        value += (target - value) * (1 - exp(-dt / tau))
        return value
    }

    public mutating func reset() { value = 0 }
}
