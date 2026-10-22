import AVFoundation
import CoreAudio
import Foundation
import Testing
@testable import BuddyVoice

/// The real mic, ten listens in a row with voice processing on. Needs Microphone access. Voice processing
/// must be off between listens: while it's on, other apps' audio is ducked.
///   BUDDYVOICE_LIVE_MIC=1 Scripts/test.sh --filter EngineMicLive
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BUDDYVOICE_LIVE_MIC"] == "1"), .serialized)
struct EngineMicLiveTests {
    @Test func tenWarmListensWithVoiceProcessing() async throws {
        try #require(AVCaptureDevice.authorizationStatus(for: .audio) == .authorized, "grant Microphone to the terminal")
        // The voice-processing path, forced: in the app it's taken only while another app plays audio.
        let mic = EngineMic(voiceProcessing: true, permission: EngineMic.micAuthorized, requestPermission: EngineMic.requestMicAccess,
                            engineFactory: AVMicEngine.factory, otherAudioPlaying: { true })
        print("idle, before prepare: input running = \(AudioHAL.isDefaultInputRunning())")
        try await mic.prepare()
        try await Task.sleep(for: .milliseconds(500))
        let preparedIdle = AudioHAL.isDefaultInputRunning()
        print("prepared, not started: input running = \(preparedIdle)")
        #expect(!preparedIdle)
        #expect(!(await mic.voiceProcessingActive), "idle VP ducks other apps' audio by 30 dB")

        var returned: [Double] = [], firstChunk: [Double] = [], firstVoice: [Double] = []
        for listen in 1 ... 10 {
            let t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            let stream = try await mic.start()
            await mic.untilLive()
            let r = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e6
            #expect(await mic.voiceProcessingActive)
            var chunkAt: UInt64?, voiceAt: UInt64?, rebuilt = 0, problems: [MicProblem] = []
            let deadline = t0 + 700_000_000
            for await event in stream {
                let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                switch event {
                case .audio(let c):
                    if chunkAt == nil { chunkAt = now }
                    if voiceAt == nil, c.samples.contains(where: { $0 != 0 }) { voiceAt = now }
                case .rebuilt: rebuilt += 1
                case .problem(let p): problems.append(p)
                }
                if now > deadline { break }
            }
            await mic.stop()
            let c = chunkAt.map { Double($0 - t0) / 1e6 } ?? .nan
            let v = voiceAt.map { Double($0 - t0) / 1e6 } ?? .nan
            returned.append(r); firstChunk.append(c); firstVoice.append(v)
            try await Task.sleep(for: .milliseconds(300))
            let idleRunning = AudioHAL.isDefaultInputRunning()
            print(String(format: "listen %2d: live %.1f ms, first chunk %.1f ms, first non-zero %.1f ms, rebuilt %d, problems %@, input running after stop = %@",
                         listen, r, c, v, rebuilt, "\(problems)", "\(idleRunning)"))
            #expect(!idleRunning, "an idle engine must not keep the mic on")
            #expect(!(await mic.voiceProcessingActive), "idle VP ducks other apps' audio by 30 dB")
            #expect(problems.isEmpty, "VP's warm-up zeros must not read as a revoked mic")
        }
        func p50(_ xs: [Double]) -> Double { xs.sorted()[xs.count / 2] }
        print(String(format: "listens 2–10: live p50 %.1f max %.1f ms; first chunk p50 %.1f ms; first non-zero p50 %.1f max %.1f ms",
                     p50(Array(returned.dropFirst())), returned.dropFirst().max()!, p50(Array(firstChunk.dropFirst())),
                     p50(Array(firstVoice.dropFirst())), firstVoice.dropFirst().max()!))
    }

    /// First real audio after the press on each path (VP only while other audio plays).
    @Test func firstAudioPerPath() async throws {
        try #require(AVCaptureDevice.authorizationStatus(for: .audio) == .authorized, "grant Microphone to the terminal")
        for vp in [false, true] {
            let mic = EngineMic(voiceProcessing: true, permission: EngineMic.micAuthorized, requestPermission: EngineMic.requestMicAccess,
                                engineFactory: AVMicEngine.factory, otherAudioPlaying: { vp })
            try await mic.prepare()
            try await Task.sleep(for: .milliseconds(300))
            var live: [Double] = []
            for _ in 1 ... 10 {
                let t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                _ = try await mic.start()
                await mic.untilLive()
                live.append(Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e6)
                #expect(await mic.voiceProcessingActive == vp)
                await mic.stop()
                try await Task.sleep(for: .milliseconds(300))
            }
            let warm = Array(live.dropFirst()).sorted()
            print(String(format: "%@ path, listens 2–10: first real audio p50 %.0f ms, max %.0f ms",
                         vp ? "voice-processing" : "plain", warm[warm.count / 2], warm.last!))
        }
    }

    /// A sentence that starts right at the press keeps its first word on the plain path. The speech is
    /// played through the speakers (the plain path has no echo canceller, so the mic hears it), starting
    /// just after the press so it isn't itself "other audio" at the decision. Needs Parakeet models:
    ///   BUDDYVOICE_LIVE_MIC=1 BUDDYVOICE_MODELS_DIR=<dir> Scripts/test.sh --filter plainCaptureKeepsTheFirstWord
    @Test func plainCaptureKeepsTheFirstWordSpokenAtThePress() async throws {
        try #require(AVCaptureDevice.authorizationStatus(for: .audio) == .authorized, "grant Microphone to the terminal")
        // Headphones or Bluetooth (a headset's mic doesn't hear its own playback) would test nothing.
        try #require(Self.builtIn(kAudioHardwarePropertyDefaultInputDevice) && Self.builtIn(kAudioHardwarePropertyDefaultOutputDevice),
                     "needs the built-in mic and speakers as the default devices")
        var settings = VoiceSettings()
        if let dir = ProcessInfo.processInfo.environment["BUDDYVOICE_MODELS_DIR"] {
            settings.modelsDirectory = URL(filePath: dir, directoryHint: .isDirectory)
        }
        let speech = FileManager.default.temporaryDirectory.appending(path: "buddyvoice-first-word.aiff")
        let say = try Process.run(URL(filePath: "/usr/bin/say"), arguments: ["-o", speech.path, "Why is this list empty?"])
        say.waitUntilExit()
        let mic = EngineMic(voiceProcessing: true, permission: EngineMic.micAuthorized, requestPermission: EngineMic.requestMicAccess,
                            engineFactory: AVMicEngine.factory, otherAudioPlaying: { false })
        let voice = VoiceController.live(settings: settings, mic: mic)
        try await voice.prepare()
        var kept = 0
        let runs = 6
        for run in 1 ... runs {
            try await voice.startListening()
            let play = try Process.run(URL(filePath: "/usr/bin/afplay"), arguments: [speech.path])
            play.waitUntilExit()
            try await Task.sleep(for: .milliseconds(400))
            let text = try await voice.finishListening()
            let first = text.lowercased().split(whereSeparator: { !$0.isLetter }).first.map(String.init) ?? ""
            if first == "why" { kept += 1 }
            print("run \(run): \(text)")
            try await Task.sleep(for: .milliseconds(500))
        }
        print("first word kept: \(kept)/\(runs)")
        #expect(kept == runs)
    }

    static func builtIn(_ selector: AudioObjectPropertySelector) -> Bool {
        func get(_ object: AudioObjectID, _ sel: AudioObjectPropertySelector) -> UInt32 {
            var address = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : 0
        }
        let device = get(AudioObjectID(kAudioObjectSystemObject), selector)
        return device != 0 && get(device, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeBuiltIn
    }
}
