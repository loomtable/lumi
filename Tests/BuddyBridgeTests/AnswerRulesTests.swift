import Foundation
import Testing
@testable import BuddyBridge

/// What each lane is told, read from the real plugin: the shared core plus only its own notes.
struct AnswerRulesTests {
    static let plugin = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("buddy-plugin")

    static let core = ["## Reply format", "`say` (required, first)", "## Picking the form", "## Tone for problems",
                       "Never answer from the visible part as if it were the whole.",
                       "A black or blank capture is a can't-do chip, not a hand-off.",
                       "`screenshot_unchanged_since_turn: N`", "`handoff`: null, unless the rules below say to hand off."]
    static let quickOnly = ["## Answer or hand off", "Hand off with `\"handoff\": \"deep\"`", "<handoff>off</handoff>",
                            "In Quick, when the user asks you to change something"]
    static let deepOnly = ["`link`: `{\"label\": \"Open draft\"", "a `<quick-note>` is what Quick said",
                           "When the prompt carries `<approved-action/>`"]

    @Test func quickGetsTheCoreAndItsOwnNotesOnly() throws {
        let text = try #require(AnswerRules.text(for: [.quick], in: Self.plugin))
        for s in Self.core + Self.quickOnly { #expect(text.contains(s), "\(s)") }
        for s in Self.deepOnly { #expect(!text.contains(s), "Deep-only in Quick: \(s)") }
        #expect(!text.hasPrefix("---"), "frontmatter isn't instruction")
    }

    @Test func deepGetsTheCoreAndItsOwnNotesOnly() throws {
        let text = try #require(AnswerRules.text(for: [.deep], in: Self.plugin))
        for s in Self.core + Self.deepOnly { #expect(text.contains(s), "\(s)") }
        for s in Self.quickOnly { #expect(!text.contains(s), "Quick-only in Deep: \(s)") }
    }

    @Test func researchStillGetsAllOfIt() throws {
        let text = try #require(AnswerRules.text(for: [.quick, .deep], in: Self.plugin))
        for s in Self.core + Self.quickOnly + Self.deepOnly { #expect(text.contains(s), "\(s)") }
    }

    @Test func theLanesLaunchWithTheirRules() throws {
        let q = LaunchSpec.quick(executable: URL(fileURLWithPath: "/c"), home: URL(fileURLWithPath: "/h"),
                                 plugin: Self.plugin, environment: [:]).arguments
        let i = try #require(q.firstIndex(of: "--append-system-prompt"))
        #expect(q[i + 1] == AnswerRules.text(for: [.quick], in: Self.plugin))
        #expect(!q.contains("--append-system-prompt-file"))
        let d = LaunchSpec.deep(executable: URL(fileURLWithPath: "/c"), folder: URL(fileURLWithPath: "/p"),
                                plugin: Self.plugin, resume: nil, environment: [:]).arguments
        let j = try #require(d.firstIndex(of: "--append-system-prompt"))
        #expect(d[j + 1] == AnswerRules.text(for: [.deep], in: Self.plugin))
    }

    @Test func aMissingNotesFileStillGivesTheCore() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "sb-rules-\(UUID().uuidString)")
        let skills = folder.appending(path: "skills/buddy-answer")
        try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "---\nname: x\n---\n\nCore rules.\n".write(to: skills.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        #expect(AnswerRules.text(for: [.quick], in: folder) == "Core rules.\n")
    }

    @Test func aMissingPluginFallsBackToTheSkillFile() {
        let plugin = URL(fileURLWithPath: "/nonexistent/plugin")
        #expect(AnswerRules.text(for: [.quick], in: plugin) == nil)
        let q = LaunchSpec.quick(executable: URL(fileURLWithPath: "/c"), home: URL(fileURLWithPath: "/h"),
                                 plugin: plugin, environment: [:]).arguments
        #expect(q.contains("--append-system-prompt-file"))
    }
}
