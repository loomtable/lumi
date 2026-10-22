@testable import BuddyApp
import BuddyCompanion
import BuddyContext
import BuddyConversations
import BuddyCore
import BuddyKeys
import BuddyOverlay
import BuddyTrace
import Foundation
import Synchronization
import Testing

/// Settings › Privacy and Keys reach the live engine, and a change applies without a relaunch.
@MainActor
struct EnginePreferencesTests {
    private static func sensors(front: FrontApp) -> ContextSensors {
        ContextSensors(
            frontApp: FakeSensor<FrontApp?>(front), window: FakeSensor<ContextPacket.Window?>(nil),
            selection: FakeSensor<ContextPacket.Selection?>(nil), cursor: FakeSensor<ContextPacket.Cursor?>(nil),
            display: FakeSensor<ContextPacket.Display?>(nil), recent: FakeSensor<[ContextPacket.RecentApp]>([]))
    }

    @Test func aBlockedAppAddedInSettingsIsBlockedAtTheNextCapture() async {
        let blocked = Mutex<Set<String>>([])
        let bank = FrontApp(pid: 42, name: "Bank", bundle: "com.example.bank")
        let context = LiveContext(
            builder: ContextBuilder(sensors: Self.sensors(front: bank)),
            blocklist: { EnginePreferences(blockedBundleIDs: blocked.withLock { $0 }).blocklist })
        let first = await context.capture()
        guard case .packet = first.result else { Issue.record("not blocked yet, so a packet"); return }
        #expect(first.pid == 42) // the process the packet was built from, for locating points
        blocked.withLock { $0 = ["com.example.bank"] }
        #expect(await context.capture() == SummonContext(result: .blocked(app: "Bank"))) // no pid
    }

    @Test func applyFeedsRetentionAndBlocklistToTheRuntime() async {
        let traceDir = FileManager.default.temporaryDirectory.appending(path: "trace-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: traceDir) }
        let runtime = AppRuntime(voice: UnavailableVoice(), conversationIndex: { try ConversationIndex(url: nil) },
                                 overlay: { FakeOverlay() }, traceDirectory: traceDir)
        #expect(!runtime.traceLog.isEnabled)
        await runtime.apply(EnginePreferences(blockedBundleIDs: ["com.example.bank"], screenshotRetention: 3600))
        let store = AppRuntime.screenshotStore(runtime.preferences)
        #expect(store.retention() == 3600)
        #expect(runtime.preferences.current.blocklist.isBlocked(bundleID: "com.example.bank"))
        var tracing = EnginePreferences(screenshotRetention: 6 * 3600)
        tracing.traceLogEnabled = true
        await runtime.apply(tracing)
        #expect(runtime.traceLog.isEnabled, "Settings › Privacy › Trace log turns it on")
        #expect(FileManager.default.fileExists(atPath: traceDir.path), "its folder exists at once, for Show in Finder")
        #expect(store.retention() == 6 * 3600, "the store reads the current value at each sweep")
        #expect(!runtime.preferences.current.blocklist.isBlocked(bundleID: "com.example.bank"))
    }

    @Test func theBoxReturnsWhatItReplaced() {
        let box = EnginePreferencesBox()
        let fn = EnginePreferences(keys: BuddyKeyMonitor.Options(key: .function))
        #expect(box.set(fn) == EnginePreferences())
        #expect(box.set(EnginePreferences()) == fn)
    }
}

/// SettingsStore → engine, field for field.
@MainActor
struct EnginePreferencesMappingTests {
    private func store() -> SettingsStore {
        // A path suite lives in the temp folder: a named one leaves an empty plist in
        // ~/Library/Preferences even after removePersistentDomain (cfprefsd writes it late).
        let suite = NSTemporaryDirectory() + "engine-prefs-\(UUID().uuidString)"
        return SettingsStore(defaults: UserDefaults(suiteName: suite)!)
    }

    @Test func defaultsMapToTheEngineDefaults() {
        let prefs = EnginePreferences(store: store())
        var expected = BuddyCoordinator.Settings()
        expected.keySymbol = BuddyKey.rightOption.symbol
        #expect(prefs.coordinator == expected)
        #expect(prefs.research == .default(for: .research))
        #expect(prefs.overlay == OverlaySettings())
        #expect(prefs.screenshotRetention == 24 * 3600 && prefs.blockedBundleIDs.isEmpty)
    }

    @Test func everyChangedFieldReachesTheEngine() {
        let s = store()
        s.models.routing = .alwaysDeep
        s.models.set(ModeConfig(model: .sonnet, effort: .low), for: .quick)
        s.models.set(ModeConfig(model: .sonnet, effort: .medium), for: .deep)
        s.models.set(ModeConfig(model: .sonnet, effort: .high), for: .research)
        s.voice.voiceReplies = .always
        s.appearance.sounds = false
        s.appearance.speakingGlow = false
        s.appearance.dotField = false
        s.appearance.inkIn = false
        s.appearance.placement = .centre
        s.keys.key = .function
        s.privacy.blockedBundleIDs = ["com.example.bank"]
        s.privacy.screenshotRetentionHours = 1
        s.privacy.traceLogEnabled = true
        let p = EnginePreferences(store: s)
        #expect(p.coordinator.routing == .alwaysDeep)
        #expect(p.coordinator.quick == ModeConfig(model: .sonnet, effort: .low))
        #expect(p.coordinator.deep == ModeConfig(model: .sonnet, effort: .medium))
        #expect(p.research == ModeConfig(model: .sonnet, effort: .high))
        #expect(p.coordinator.voiceReplies == .always && !p.coordinator.sounds)
        #expect(p.coordinator.keySymbol == BuddyKey.function.symbol, "hints name the bound key")
        #expect(p.overlay == OverlaySettings(glow: false, dotField: false, inkIn: false, placement: .centre))
        #expect(p.keys.key == .function && p.blockedBundleIDs == ["com.example.bank"] && p.screenshotRetention == 3600)
        #expect(p.traceLogEnabled)
        s.voice.voiceReplies = .off
        #expect(EnginePreferences(store: s).coordinator.voiceReplies == .off)
    }

    @Test func theAppearanceTogglesReachTheCoordinatorAndOverlay() {
        let s = store()
        s.appearance.showRings = false
        s.appearance.insertAndReplace = false
        let p = EnginePreferences(store: s)
        #expect(!p.coordinator.rings && !p.coordinator.insert, "the features packet says off")
        #expect(!p.overlay.rings)
        let live = AppRuntime.coordinatorSettings(p)   // what `apply` hands the running coordinator
        #expect(!live.rings && !live.insert)
        s.appearance.showRings = true
        #expect(EnginePreferences(store: s).coordinator.rings && EnginePreferences(store: s).overlay.rings)
    }
}

@MainActor
struct CoordinatorSettingsTests {
    @Test func hintsAlwaysNameTheBoundKeyEvenIfKeysChangeAfterInit() {
        var prefs = EnginePreferences()
        prefs.keys = BuddyKeyMonitor.Options(key: .function)
        #expect(AppRuntime.coordinatorSettings(prefs).keySymbol == BuddyKey.function.symbol)
    }

    @Test func theResearchLabelFollowsSettings() {
        let prefs = EnginePreferences(research: ModeConfig(model: .sonnet, effort: .high))
        #expect(AppRuntime.coordinatorSettings(prefs).research == ModeConfig(model: .sonnet, effort: .high))
    }
}

struct DeepFallbackTests {
    @Test func deepFallsBackToSonnetThenHaikuNeverToItself() {
        #expect(AppRuntime.deepFallbacks(for: .opus) == [.sonnet, .haiku])
        #expect(AppRuntime.deepFallbacks(for: .sonnet) == [.haiku])
        #expect(AppRuntime.deepFallbacks(for: .haiku) == [.sonnet])
    }
}

/// How many `claude` processes stay alive, by the Mac's memory.
struct ProcessLimitsTests {
    @Test func eightGigabytesKeepsLessAlive() {
        let low = AppRuntime.ProcessLimits(physicalMemory: 8 << 30)
        #expect(low.deepIdle == .zero && !low.keepQuickSpare && low.researchJobs == 1 && low.holdResearchDuringDeep)
        #expect(low.quickIdle == .seconds(30 * 60))
        #expect(AppRuntime.ProcessLimits(physicalMemory: 4 << 30) == low)
    }

    @Test func sixteenGigabytesAndUpIsUnchanged() {
        let normal = AppRuntime.ProcessLimits(physicalMemory: 16 << 30)
        #expect(normal.deepIdle == .seconds(10 * 60) && normal.quickIdle == .seconds(30 * 60))
        #expect(normal.keepQuickSpare && normal.researchJobs == 2 && !normal.holdResearchDuringDeep)
        #expect(AppRuntime.ProcessLimits(physicalMemory: 64 << 30) == normal)
    }

    @Test func onboardingsMemoryLineUsesTheSameLimit() {
        #expect(AppRuntime.isLowMemory(8 << 30) && AppRuntime.isLowMemory(4 << 30))
        #expect(!AppRuntime.isLowMemory(16 << 30) && !AppRuntime.isLowMemory((8 << 30) + 1))
    }
}
