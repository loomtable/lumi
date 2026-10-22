import Foundation

/// Turns raw RMS into the 0…1 level that drives the listening dots, the rim and the speaking glow:
/// rises over 30 ms, falls over 120 ms for the reply or 250 ms for the mic.
///
/// "Over N ms" means the envelope covers 95% of a step in N ms (a one-pole filter with τ = N / 3).
public struct LevelMeter: Sendable, Equatable {
    public var riseSeconds: Double
    public var fallSeconds: Double
    /// dBFS mapped to 0 and to 1.
    public var floorDB: Float
    public var ceilingDB: Float
    public private(set) var level: Float = 0

    public init(riseSeconds: Double = 0.030, fallSeconds: Double, floorDB: Float = -60, ceilingDB: Float = -12) {
        self.riseSeconds = riseSeconds
        self.fallSeconds = fallSeconds
        self.floorDB = floorDB
        self.ceilingDB = ceilingDB
    }

    public static func mic() -> LevelMeter { LevelMeter(fallSeconds: 0.250) }
    public static func reply() -> LevelMeter { LevelMeter(fallSeconds: 0.120) }

    /// Maps linear RMS to 0…1 on a dB scale between `floorDB` and `ceilingDB`.
    public func normalized(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return min(1, max(0, (db - floorDB) / (ceilingDB - floorDB)))
    }

    /// Feeds one frame's RMS, `dt` seconds after the previous frame, and returns the new level.
    @discardableResult
    public mutating func update(rms: Float, dt: Double) -> Float {
        let target = normalized(rms: rms)
        let duration = target > level ? riseSeconds : fallSeconds
        let tau = max(duration / 3, 1e-6)
        let alpha = Float(1 - exp(-max(dt, 0) / tau))
        level += (target - level) * alpha
        return level
    }

    public mutating func reset() { level = 0 }

    /// Linear RMS of a slice of samples.
    public static func rms(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }
}

/// Splits a 16 kHz sample stream into 20 ms frames (320 samples) for the meter, carrying the remainder.
public struct MeterFramer: Sendable, Equatable {
    public static let frameSamples = 320
    public static var frameSeconds: Double { Double(frameSamples) / AudioChunk.sampleRate }

    private var pending: [Float] = []

    public init() {}

    /// Returns the RMS of every complete frame now available.
    public mutating func push(_ samples: [Float]) -> [Float] {
        pending.append(contentsOf: samples)
        var out: [Float] = []
        var start = 0
        while pending.count - start >= Self.frameSamples {
            out.append(LevelMeter.rms(pending[start ..< start + Self.frameSamples]))
            start += Self.frameSamples
        }
        pending.removeFirst(start)
        return out
    }

    public mutating func reset() { pending.removeAll() }
}
