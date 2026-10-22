import Foundation
import Testing
@testable import BuddyCore

struct ContextPacketTests {
    @Test func decodesExamplePacket() throws {
        let json = """
        {
          "v": 1,
          "asked_at": "2026-10-14T10:42:07+05:30",
          "utterance": "why is this list empty?",
          "app": { "name": "Google Chrome", "bundle": "com.google.Chrome", "kind": "browser" },
          "window": { "title": "AI Pulse – Today", "document": null },
          "browser": { "url": "http://localhost:3000/today", "host": "localhost", "tab_title": "AI Pulse – Today" },
          "local_server": { "port": 3000, "pid": 48211, "cwd": "/Users/me/Developer/aipulse/web", "command": "next dev" },
          "selection": null,
          "cursor": { "x": 812, "y": 440, "element": { "role": "AXList", "label": "Today's stories" } },
          "screenshot": "/Users/me/Library/Caches/com.loomtable.lumi/shots/1739.png",
          "display": { "id": 1, "scale": 2, "appearance": "dark" },
          "recent": [
            { "app": "Visual Studio Code", "title": "useFeed.ts — web" },
            { "app": "Ghostty", "cwd": "/Users/me/Developer/aipulse/web", "command": "npm run dev" }
          ],
          "conversation": { "id": "c_812", "turn": 3, "previous": ["a", "b", "c"] }
        }
        """
        let packet = try ContextPacket.makeDecoder().decode(ContextPacket.self, from: Data(json.utf8))
        #expect(packet.app?.kind == .browser)
        #expect(packet.browser?.tabTitle == "AI Pulse – Today")
        #expect(packet.localServer?.port == 3000)
        #expect(packet.localServer?.cwd == "/Users/me/Developer/aipulse/web")
        #expect(packet.selection == nil)
        #expect(packet.cursor?.element?.role == "AXList")
        #expect(packet.display?.appearance == .dark)
        #expect(packet.recent?.count == 2)
        #expect(packet.conversation?.turn == 3)
        #expect(packet.askedAt == Date(timeIntervalSince1970: 1_791_954_727))
    }

    @Test func missingFieldsAreOmittedNotNull() throws {
        let packet = ContextPacket(askedAt: .now, utterance: "what is this?")
        let json = String(decoding: try ContextPacket.makeEncoder().encode(packet), as: UTF8.self)
        #expect(!json.contains("null"))
        #expect(!json.contains("local_server"))
        #expect(json.contains("\"asked_at\""))
        #expect(json.contains("\"v\":1"))
    }

    @Test func roundTrips() throws {
        var packet = ContextPacket(askedAt: Date(timeIntervalSince1970: 1_791_954_727), utterance: "hi")
        packet.app = .init(name: "Ghostty", bundle: "com.mitchellh.ghostty", kind: .terminal)
        packet.terminal = .init(cwd: "/tmp", command: "npm run dev")
        let data = try ContextPacket.makeEncoder().encode(packet)
        #expect(try ContextPacket.makeDecoder().decode(ContextPacket.self, from: data) == packet)
    }

    @Test func encodesAskedAtWithLocalOffset() throws {
        let packet = ContextPacket(askedAt: Date(timeIntervalSince1970: 1_791_954_727), utterance: "hi")
        let kolkata = try #require(TimeZone(identifier: "Asia/Kolkata"))
        let json = String(decoding: try ContextPacket.makeEncoder(timeZone: kolkata).encode(packet), as: UTF8.self)
        #expect(json.contains(#""asked_at":"2026-10-14T10:42:07+05:30""#))
    }

    @Test func reencodingExamplePacketKeepsWireKeysAndIntegers() throws {
        var packet = ContextPacket(askedAt: Date(timeIntervalSince1970: 1_791_954_727), utterance: "why?")
        packet.browser = .init(url: "http://localhost:3000/today", host: "localhost", tabTitle: "AI Pulse")
        packet.localServer = .init(port: 3000, pid: 48211, cwd: "/w", command: "next dev")
        packet.cursor = .init(x: 812, y: 440)
        packet.display = .init(id: 1, scale: 2, appearance: .dark)
        packet.finder = .init(folder: "/Users/me", selected: ["/Users/me/a.pdf"])
        let json = String(decoding: try ContextPacket.makeEncoder().encode(packet), as: UTF8.self)
        for key in ["\"local_server\"", "\"tab_title\"", "\"asked_at\"", "\"selected\""] {
            #expect(json.contains(key))
        }
        #expect(json.contains(#""x":812"#))
        #expect(json.contains(#""scale":2"#))
        #expect(!json.contains("localServer"))
        #expect(!json.contains("tabTitle"))
    }

    @Test func decodedConversationKeepsLastThreeTurns() throws {
        let json = #"{ "id": "c", "turn": 5, "previous": ["1", "2", "3", "4"] }"#
        let c = try JSONDecoder().decode(ContextPacket.Conversation.self, from: Data(json.utf8))
        #expect(c.previous == ["2", "3", "4"])
    }

    @Test func selectionCapsLongText() {
        let long = String(repeating: "a", count: ContextPacket.Selection.maxTextLength + 5)
        let selection = ContextPacket.Selection(text: long)
        #expect(selection.text?.count == ContextPacket.Selection.maxTextLength)
        #expect(selection.length == long.count)
        #expect(selection.truncated)
    }

    @Test func selectionWithBoundsOnly() throws {
        let rect = ContextPacket.Rect(x: 10, y: 20, width: 0, height: 18)
        let selection = ContextPacket.Selection(text: nil, bounds: rect, boundsSource: .axTextMarker)
        let json = String(decoding: try JSONEncoder().encode(selection), as: UTF8.self)
        #expect(json.contains(#""bounds_source":"ax_text_marker""#))
        #expect(!json.contains("\"text\""))
        #expect(selection.length == 0 && !selection.truncated)
    }

    @Test func appWithoutBundleDecodes() throws {
        let json = #"{ "name": "node", "kind": "other" }"#
        let app = try JSONDecoder().decode(ContextPacket.App.self, from: Data(json.utf8))
        #expect(app.bundle == nil)
    }

    @Test func conversationKeepsLastThreeTurns() {
        let c = ContextPacket.Conversation(id: "c", turn: 5, previous: ["1", "2", "3", "4", "5"])
        #expect(c.previous == ["3", "4", "5"])
    }
}
