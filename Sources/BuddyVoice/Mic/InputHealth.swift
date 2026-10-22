/// Spots input that is all zeros and says why.
///
/// A revoked Microphone permission doesn't raise an error: the engine keeps delivering buffers of exact
/// zeros (S5). Voice processing also gives about 160 ms of zeros right after a start or rebuild, so the
/// first `warmUpGrace` seconds are ignored.
public struct InputHealth: Sendable {
    public var warmUpGrace: Double
    public var zeroLimit: Double

    private var sinceGrace = 0.0
    private var zeroRun = 0.0
    private var reported = false

    public init(warmUpGrace: Double = 0.3, zeroLimit: Double = 1.0) {
        self.warmUpGrace = warmUpGrace
        self.zeroLimit = zeroLimit
    }

    /// A new capture: grace starts again and a problem may be reported again.
    public mutating func reset() {
        restartGrace()
        reported = false
    }

    /// The engine was rebuilt mid-capture: give the new one its warm-up, but report at most once per start.
    public mutating func restartGrace() {
        sinceGrace = 0
        zeroRun = 0
    }

    /// Feeds 16 kHz samples. Returns a problem the first time `zeroLimit` seconds of exact zeros pass.
    public mutating func observe(_ samples: [Float], permissionGranted: () -> Bool) -> MicProblem? {
        guard !samples.isEmpty else { return nil }
        let duration = Double(samples.count) / AudioChunk.sampleRate
        let inGrace = sinceGrace < warmUpGrace
        sinceGrace += duration
        if samples.contains(where: { $0 != 0 }) {
            zeroRun = 0
            return nil
        }
        guard !inGrace else { return nil }
        zeroRun += duration
        guard zeroRun >= zeroLimit, !reported else { return nil }
        reported = true
        return permissionGranted() ? .silentInput : .permissionDenied
    }
}
