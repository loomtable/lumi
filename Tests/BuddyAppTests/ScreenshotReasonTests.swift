import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import BuddyApp
@testable import BuddyBridge
import BuddyContext
import BuddyCore
import BuddyKeys
import BuddyOverlay

/// A missing screenshot says why in the packet, so the answer is truthful (not_granted vs a
/// capture that failed).
@MainActor
struct ScreenshotReasonTests {
    /// Answers each capture with the next result; counts attempts.
    final class ScriptedShooter: Screenshotter {
        private let results: Mutex<[Result<Void, ScreenshotError>]>
        let attempts = Mutex(0)
        let displays = Mutex<[UInt32?]>([])
        let regions = Mutex<[CGRect?]>([])
        init(_ results: [Result<Void, ScreenshotError>]) { self.results = Mutex(results) }

        func capture(displayID: UInt32?, blocklist: Blocklist, options: ScreenshotOptions, region: CGRect?) async throws(ScreenshotError) -> Screenshot {
            attempts.withLock { $0 += 1 }
            displays.withLock { $0.append(displayID) }
            regions.withLock { $0.append(region) }
            let next = results.withLock { $0.isEmpty ? .success(()) : $0.removeFirst() }
            if case .failure(let error) = next { throw error }
            let ctx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            return Screenshot(file: URL(fileURLWithPath: "/tmp/s.jpg"), fileData: Data([1]), fileWidth: 4, fileHeight: 4,
                              full: ctx.makeImage()!, displayID: 1, scale: 1, displayFrame: CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }

    static func live(_ shooter: any Screenshotter) -> LiveContext {
        LiveContext(builder: ContextBuilder(sensors: .init(
            frontApp: FakeSensor<FrontApp?>(nil), window: FakeSensor<ContextPacket.Window?>(nil),
            selection: FakeSensor<ContextPacket.Selection?>(nil), cursor: FakeSensor<ContextPacket.Cursor?>(nil),
            display: FakeSensor<ContextPacket.Display?>(nil), recent: FakeSensor<[ContextPacket.RecentApp]>([]))),
            shooter: shooter, blocklist: { Blocklist() })
    }

    @Test func aFailedCaptureIsRetriedOnce() async {
        let flaky = ScriptedShooter([.failure(.captureFailed("SCK busy"))])
        #expect(await Self.live(flaky).screenshot(displayID: nil).shot != nil)
        #expect(flaky.attempts.withLock { $0 } == 2)

        let broken = ScriptedShooter([.failure(.captureFailed("a")), .failure(.displayNotFound)])
        #expect(await Self.live(broken).screenshot(displayID: nil) == .unavailable(.captureFailed))
        #expect(broken.attempts.withLock { $0 } == 2)
    }

    @Test func anUnpluggedDisplayRetriesOnTheMainOne() async {
        let unplugged = ScriptedShooter([.failure(.displayNotFound)])
        #expect(await Self.live(unplugged).screenshot(displayID: 7).shot != nil)
        #expect(unplugged.displays.withLock { $0 } == [7, nil])
    }

    @Test func aMissingGrantIsntRetried() async {
        let denied = ScriptedShooter([.failure(.screenRecordingNotGranted)])
        #expect(await Self.live(denied).screenshot(displayID: nil) == .unavailable(.notGranted))
        #expect(denied.attempts.withLock { $0 } == 1)
    }

    @Test(arguments: [ContextPacket.ScreenshotUnavailable.notGranted, .captureFailed])
    func theReasonReachesThePacket(reason: ContextPacket.ScreenshotUnavailable) async {
        var context = FakeContext.packet()
        context.shot = nil
        context.unavailable = reason
        let bridge = FakeBridge(script: [BuddyCoordinatorTests.done(BuddyBlock(say: "Yes.", shape: .chip))])
        var settings = BuddyCoordinator.Settings()
        settings.sounds = false
        let c = BuddyCoordinator(settings: settings, voice: FakeVoice(), context: context, bridge: bridge,
                                 overlay: FakeOverlay(), pointer: FixedPointer())
        c.start()
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.holdBegan))
        await c.handle(.gesture(.holdEnded))
        let deadline = ContinuousClock.now + .seconds(2)
        while bridge.asked.isEmpty, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        #expect(bridge.asked.first?.packet.screenshotUnavailable == reason)
        #expect(bridge.asked.first?.packet.screenshot == nil)
    }

    @Test func aScreenshotMeansNoReason() async {
        let bridge = FakeBridge(script: [BuddyCoordinatorTests.done(BuddyBlock(say: "Yes.", shape: .chip))])
        var settings = BuddyCoordinator.Settings()
        settings.sounds = false
        let c = BuddyCoordinator(settings: settings, voice: FakeVoice(), context: FakeContext.packet(), bridge: bridge,
                                 overlay: FakeOverlay(), pointer: FixedPointer())
        c.start()
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.holdBegan))
        await c.handle(.gesture(.holdEnded))
        let deadline = ContinuousClock.now + .seconds(2)
        while bridge.asked.isEmpty, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        #expect(bridge.asked.first?.packet.screenshotUnavailable == nil)
    }

    @Test func wireFormat() throws {
        var packet = ContextPacket(askedAt: Date(timeIntervalSince1970: 0), utterance: "x")
        packet.screenshotUnavailable = .notGranted
        let json = String(decoding: try ContextPacket.makeEncoder().encode(packet), as: UTF8.self)
        #expect(json.contains(#""screenshot_unavailable":"not_granted""#))
        packet.screenshotUnavailable = nil
        let none = String(decoding: try ContextPacket.makeEncoder().encode(packet), as: UTF8.self)
        #expect(!none.contains("screenshot_unavailable")) // absent, not null
    }

    /// The window region is chosen against the display being captured, and only from a focus.
    @Test func theRegionIsTheFocusedWindowUnlessThePointerIsElsewhere() async {
        let main = CGDisplayBounds(CGMainDisplayID())
        let window = CGRect(x: main.minX + 50, y: main.minY + 50, width: 600, height: 400)
        let shooter = ScriptedShooter([])
        let live = Self.live(shooter)
        _ = await live.screenshot(displayID: nil, focus: .init(window: window, cursor: CGPoint(x: window.midX, y: window.midY)))
        _ = await live.screenshot(displayID: nil, focus: .init(window: window, cursor: CGPoint(x: window.maxX + 20, y: window.minY)))
        _ = await live.screenshot(displayID: nil, focus: nil)
        _ = await live.screenshot(displayID: nil)
        #expect(shooter.regions.withLock { $0 } == [window, nil, nil, nil])
    }

    /// Returns a 4× downscaled window shot, so a close-up adds detail.
    final class WindowShooter: Screenshotter {
        func capture(displayID: UInt32?, blocklist: Blocklist, options: ScreenshotOptions, region: CGRect?) async throws(ScreenshotError) -> Screenshot {
            let frame = CGDisplayBounds(CGMainDisplayID())
            let ctx = CGContext(data: nil, width: Int(frame.width * 2), height: Int(frame.height * 2), bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            let shown = region ?? frame
            return Screenshot(file: URL(fileURLWithPath: "/tmp/s.jpg"), fileData: Data([1]), fileWidth: Int(shown.width / 2),
                              fileHeight: Int(shown.height / 2), full: ctx.makeImage()!, displayID: CGMainDisplayID(), scale: 2,
                              displayFrame: frame, fileRect: shown)
        }
    }

    @Test func aCloseUpGoesOnlyBesideAWindowImage() async {
        let main = CGDisplayBounds(CGMainDisplayID())
        let window = CGRect(x: main.minX + 50, y: main.minY + 50, width: 600, height: 400)
        let caret = CGRect(x: window.midX, y: window.midY, width: 2, height: 16)
        let live = Self.live(WindowShooter())
        let inside = await live.screenshot(displayID: nil, focus: .init(window: window, cursor: CGPoint(x: window.midX, y: window.midY), detail: caret))
        guard let d = inside.shot?.detail else { Issue.record("no close-up"); return }
        #expect(window.contains(d.rect))
        let elsewhere = await live.screenshot(displayID: nil, focus: .init(window: window, cursor: CGPoint(x: window.maxX + 20, y: window.minY), detail: caret))
        #expect(elsewhere.shot != nil && elsewhere.shot?.detail == nil, "whole display: no close-up")
    }
}
