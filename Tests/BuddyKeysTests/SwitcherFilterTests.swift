import CoreGraphics
import Testing
@testable import BuddyKeys

@Suite("SwitcherFilter")
struct SwitcherFilterTests {
    typealias Code = SwitcherKeyMap.Code
    let buddy = BuddyKey.rightOption
    var map: SwitcherKeyMap { SwitcherKeyMap(buddy: buddy) }
    var held: UInt64 { buddy.downFlags }

    func filter(open: Bool) -> SwitcherFilter {
        SwitcherFilter(arming: .init(map: map, open: open))
    }

    @Test("disarmed: everything passes")
    func disarmed() {
        var f = SwitcherFilter()
        #expect(f.consume(.keyDown, keyCode: Code.tab, flags: held) == .pass)
        #expect(f.consume(.keyUp, keyCode: Code.tab, flags: held) == .pass)
        #expect(!f.drops(keyCode: Code.tab, flags: held))
    }

    @Test("openers only: Tab is taken with its key-up; N and Esc pass")
    func openersOnly() {
        var f = filter(open: false)
        #expect(f.consume(.keyDown, keyCode: Code.tab, flags: held) == .init(consume: true, key: .next))
        #expect(f.awaitingKeyUp)
        #expect(f.consume(.keyUp, keyCode: Code.tab, flags: held) == .init(consume: true, key: nil))
        #expect(!f.awaitingKeyUp)
        #expect(f.consume(.keyDown, keyCode: Code.n, flags: held) == .pass)
        #expect(f.consume(.keyDown, keyCode: Code.escape, flags: held) == .pass)
        #expect(f.consume(.keyUp, keyCode: Code.n, flags: held) == .pass)
        #expect(!f.drops(keyCode: Code.n, flags: held))
        #expect(f.drops(keyCode: Code.tab, flags: held))
    }

    @Test("open: the whole map is taken")
    func open() {
        var f = filter(open: true)
        #expect(f.consume(.keyDown, keyCode: Code.n, flags: held) == .init(consume: true, key: .new))
        #expect(f.consume(.keyDown, keyCode: Code.escape, flags: held) == .init(consume: true, key: .cancel))
        #expect(f.consume(.keyDown, keyCode: 0x14, flags: held) == .init(consume: true, key: .index(3)))
        #expect(f.consume(.keyDown, keyCode: 0x0E, flags: held) == .pass)  // E: a stray key
    }

    @Test("autorepeat: Tab and arrows keep moving, other keys repeat silently")
    func autorepeat() {
        var f = filter(open: true)
        _ = f.consume(.keyDown, keyCode: Code.tab, flags: held)
        #expect(f.consume(.keyDown, keyCode: Code.tab, flags: held, isRepeat: true) == .init(consume: true, key: .next))
        _ = f.consume(.keyDown, keyCode: Code.p, flags: held)
        #expect(f.consume(.keyDown, keyCode: Code.p, flags: held, isRepeat: true) == .init(consume: true, key: nil))
    }

    @Test("a repeat of a press that passed before arming keeps passing")
    func repeatOfPassedPress() {
        var f = filter(open: true)
        #expect(f.consume(.keyDown, keyCode: Code.tab, flags: held, isRepeat: true) == .pass)
        #expect(f.consume(.keyUp, keyCode: Code.tab, flags: held) == .pass)
    }

    @Test("disarmed after a take: the key-up and repeats are still consumed, new presses pass")
    func drainAfterDisarm() {
        var f = filter(open: true)
        _ = f.consume(.keyDown, keyCode: Code.tab, flags: held)
        f.arming = nil
        #expect(f.consume(.keyDown, keyCode: Code.tab, flags: held, isRepeat: true) == .init(consume: true, key: nil))
        #expect(f.drops(keyCode: Code.tab, flags: held))
        #expect(f.consume(.keyDown, keyCode: Code.n, flags: held) == .pass)
        #expect(f.consume(.keyUp, keyCode: Code.tab, flags: held) == .init(consume: true, key: nil))
        #expect(!f.awaitingKeyUp)
        #expect(!f.drops(keyCode: Code.tab, flags: held))
    }

    @Test("several keys held at once are paired one by one")
    func overlapping() {
        var f = filter(open: true)
        _ = f.consume(.keyDown, keyCode: Code.tab, flags: held)
        _ = f.consume(.keyDown, keyCode: Code.space, flags: held)
        #expect(f.consume(.keyUp, keyCode: Code.tab, flags: held).consume)
        #expect(f.awaitingKeyUp)
        #expect(f.consume(.keyUp, keyCode: Code.space, flags: held).consume)
        #expect(!f.awaitingKeyUp)
    }

    @Test("KeyArming shares one filter between the taps")
    func sharedArming() {
        let arming = KeyArming()
        #expect(!arming.drops(keyCode: Code.tab, flags: held))
        arming.set(.init(map: map))
        #expect(arming.drops(keyCode: Code.tab, flags: held))
        #expect(arming.consume(.keyDown, keyCode: Code.tab, flags: held, isRepeat: false).key == .next)
        arming.set(nil)
        #expect(arming.awaitingKeyUp)
        #expect(arming.drops(keyCode: Code.tab, flags: held))
        #expect(arming.consume(.keyUp, keyCode: Code.tab, flags: held, isRepeat: false).consume)
        #expect(!arming.drops(keyCode: Code.tab, flags: held))
    }

    @Test("the listen-only tap drops key-downs the switcher takes, and nothing else")
    func listenOnlyDrop() {
        let arming = KeyArming()
        let tab = CGEvent(keyboardEventSource: nil, virtualKey: Code.tab, keyDown: true)!
        tab.flags = CGEventFlags(rawValue: held)
        #expect(!EventTapSource.dropped(type: .keyDown, event: tab, arming: arming))
        arming.set(.init(map: map))
        #expect(EventTapSource.dropped(type: .keyDown, event: tab, arming: arming))
        #expect(!EventTapSource.dropped(type: .keyDown, event: tab, arming: nil))
        #expect(!EventTapSource.dropped(type: .flagsChanged, event: tab, arming: arming))
        let e = CGEvent(keyboardEventSource: nil, virtualKey: kVKE, keyDown: true)!
        e.flags = CGEventFlags(rawValue: held)
        #expect(!EventTapSource.dropped(type: .keyDown, event: e, arming: arming))
    }
}
