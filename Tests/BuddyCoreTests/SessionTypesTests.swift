import Foundation
import Testing
@testable import BuddyCore

struct SessionTypesTests {
    @Test func newSessionIDsArePrefixedAndUnique() {
        let a = SessionID.new(), b = SessionID.new()
        #expect(a.rawValue.hasPrefix("s_"))
        #expect(a.rawValue == a.rawValue.lowercased())
        #expect(a != b)
    }

    @Test func sessionIDCodesAsAPlainString() throws {
        let id = SessionID(rawValue: "c_123")
        #expect(String(decoding: try JSONEncoder().encode(id), as: UTF8.self) == #""c_123""#)
        #expect(try JSONDecoder().decode(SessionID.self, from: Data(#""c_123""#.utf8)) == id)
    }

    private func packet(bundle: String? = "com.apple.Safari", configure: (inout ContextPacket) -> Void = { _ in }) -> ContextPacket {
        var p = ContextPacket(askedAt: .now, utterance: "hi")
        p.app = ContextPacket.App(name: "Safari", bundle: bundle, kind: .browser)
        configure(&p)
        return p
    }

    @Test func contextKeyNeedsABundleID() {
        #expect(ContextKey.from(packet(bundle: nil)) == nil)
        #expect(ContextKey.from(packet(bundle: "")) == nil)
        #expect(ContextKey.from(packet()) == ContextKey(bundleID: "com.apple.Safari"))
    }

    @Test func contextKeyPrefersFileThenDocumentThenPageThenTitle() {
        let all = packet {
            $0.editor = .init(workspace: "/w", file: "/w/a.swift")
            $0.window = .init(title: "Title", document: "/d/report.pages")
            $0.browser = .init(url: "https://Example.com/a/b?utm=1#x")
        }
        #expect(ContextKey.from(all)?.target == "/w/a.swift")
        #expect(ContextKey.from(packet { $0.window = .init(title: "Title", document: "/d/report.pages") })?.target == "/d/report.pages")
        #expect(ContextKey.from(packet {
            $0.window = .init(title: "Title")
            $0.browser = .init(url: "https://Example.com/a/b?utm=1#x")
        })?.target == "example.com/a/b")
        #expect(ContextKey.from(packet { $0.browser = .init(url: "https://example.com/") })?.target == "example.com")
        #expect(ContextKey.from(packet { $0.window = .init(title: "  Inbox  ") })?.target == "Inbox")
    }

    @Test(arguments: [
        ("Read", "/anywhere/x", ApprovalTier.reversible),
        ("Glob", "", .reversible),
        ("Grep", "", .reversible),
        ("Edit", "/Users/me/repo/a.swift", .reversible),
        ("Write", "/Users/me/repo/sub/new.md", .reversible),
        ("MultiEdit", "/Users/me/notes/n.md", .reversible),
        ("Edit", "/Users/me/repository/a.swift", .needsClick),
        ("Edit", "/Users/me/repo/../secrets/a", .needsClick),
        ("Edit", "/Users/me/repo", .needsClick),
        ("Edit", "relative/a.swift", .needsClick),
        ("Edit", "", .needsClick),
        ("Bash", "/Users/me/repo/a", .needsClick),
        ("WebFetch", "", .needsClick),
        ("mcp__gmail__send_message", "", .needsClick),
        ("mcp__github__get_issue", "", .needsClick),
        ("SomethingNew", "/Users/me/repo/a", .needsClick),
    ])
    func classifiesApprovalTier(tool: String, path: String, tier: ApprovalTier) {
        let dirs = [URL(filePath: "/Users/me/repo"), URL(filePath: "/Users/me/notes/")]
        let input = path.isEmpty ? [:] : ["file_path": path]
        #expect(ApprovalTier.classify(tool: tool, input: input, sessionDirs: dirs) == tier)
    }

    /// Gatekeeper P0: with no trusted project a session runs in home, and every Edit or Write under
    /// ~ was voice-approvable. Only a real project folder counts, and never for a sensitive path.
    @Test func onlyATrustedProjectNeverHomeOrRootMakesAnEditVoiceApprovable() {
        let home = URL(filePath: "/Users/me")
        func tier(_ path: String, _ dirs: [String]) -> ApprovalTier {
            ApprovalTier.classify(tool: "Edit", input: ["file_path": path], sessionDirs: dirs.map { URL(filePath: $0) }, home: home)
        }
        #expect(tier("/Users/me/notes.txt", ["/Users/me"]) == .needsClick, "the home fallback is no project")
        #expect(tier("/Users/me/Developer/app/a.swift", ["/Users/me"]) == .needsClick)
        #expect(tier("/etc/hosts", ["/"]) == .needsClick, "nor the filesystem root")
        #expect(tier("/Users/me/notes.txt", ["/Users"]) == .needsClick, "nor anything that holds home")
        #expect(tier("/Users/me/repo/a.swift", ["/Users/me/repo"]) == .reversible, "a trusted repo's file")
        #expect(tier("/Users/me/repo/.env", ["/Users/me/repo"]) == .needsClick, "a dotfile in the repo")
        #expect(tier("/Users/me/repo/.git/config", ["/Users/me/repo"]) == .needsClick)
        #expect(tier("/Users/me/repo/sub/../../.zshrc", ["/Users/me/repo"]) == .needsClick, "traversal resolved first")
        #expect(tier("/Users/me/.ssh/config", ["/Users/me/repo", "/Users/me"]) == .needsClick)
        #expect(tier("/Users/me/Library/Prefs/x.plist", ["/Users/me/Library/Prefs"]) == .needsClick, "~/Library")
        #expect(tier("/Users/me/repo/login.keychain-db", ["/Users/me/repo"]) == .needsClick, "keychains")
        // Protected files inside a project (gatekeeper P1): Claude Code's own settings, hooks and
        // agents, git's hooks and config, MCP config, env files, any dotfile or dot folder.
        for protected in [".claude/settings.json", ".claude/settings.local.json", ".claude/hooks/pre.sh", ".claude/agents/a.md",
                          ".git/hooks/pre-commit", ".git/config", ".mcp.json", ".env", ".env.local", ".github/workflows/ci.yml",
                          "src/.hidden/x.swift"] {
            #expect(tier("/Users/me/repo/" + protected, ["/Users/me/repo"]) == .needsClick, "\(protected)")
        }
    }

    /// Symlinks are resolved before the check: a repo reached through a link still counts, and a
    /// link inside the repo that points out of it doesn't carry the edit in.
    @Test func symlinksAreResolvedBeforeTheCheck() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "tier-\(UUID().uuidString)", directoryHint: .isDirectory)
        let real = root.appending(path: "real", directoryHint: .isDirectory)
        let outside = root.appending(path: "outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let link = root.appending(path: "repo")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        try FileManager.default.createSymbolicLink(at: real.appending(path: "out"), withDestinationURL: outside)
        let home = URL(filePath: "/Users/me")
        func tier(_ file: URL, _ dir: URL) -> ApprovalTier {
            ApprovalTier.classify(tool: "Write", input: ["file_path": file.path], sessionDirs: [dir], home: home)
        }
        #expect(tier(real.appending(path: "new.md"), link) == .reversible, "the project through its link")
        #expect(tier(link.appending(path: "new.md"), real) == .reversible)
        #expect(tier(real.appending(path: "out/escape.txt"), real) == .needsClick, "a link out of the project")
    }

    @Test func notebookEditReadsItsOwnPathKey() {
        let dirs = [URL(filePath: "/r")]
        #expect(ApprovalTier.classify(tool: "NotebookEdit", input: ["notebook_path": "/r/n.ipynb"], sessionDirs: dirs) == .reversible)
        #expect(ApprovalTier.classify(tool: "Edit", input: ["file_path": "/r/a"], sessionDirs: []) == .needsClick)
    }
}

struct LastSayTests {
    @Test func aSayWinsElseTheMarkdownIsFlattenedAndCut() {
        #expect(SessionSnapshot.lastSay(say: " Three days. ", markdown: "x") == "Three days.")
        #expect(SessionSnapshot.lastSay(say: nil, markdown: "## Fixed\n\n```swift\nlet x = 1\n```\n- one") == "Fixed let x = 1 one")
        let long = String(repeating: "word ", count: 60)
        let cut = SessionSnapshot.lastSay(say: nil, markdown: long)
        #expect(cut?.count ?? 0 <= SessionSnapshot.lastSayLimit && cut?.hasSuffix("…") == true)
        #expect(SessionSnapshot.lastSay(say: "", markdown: "  ") == nil)
    }

    /// Inspire #5: the card leads with what goes out, then why.
    @Test func anApprovalLeadsWithItsExactPayloadThenItsReason() {
        let bash = PermissionAsk(id: "1", title: "Run the auth tests", toolName: "Bash",
                                 detail: .command("swift test --filter Auth\nswift build"), tier: .reversible)
        #expect(bash.payload == "swift test --filter Auth")
        #expect(bash.reason == "Run the auth tests")
        let bare = PermissionAsk(id: "2", title: "Run ls -la", toolName: "Bash", detail: .command("ls -la"), tier: .reversible)
        #expect(bare.payload == "ls -la" && bare.reason == nil, "the title only repeats it")
        let edit = PermissionAsk(id: "3", title: "Edit budget.md", toolName: "Edit",
                                 detail: .diff(path: "/x/budget.md", old: "a\nb\nc", new: "a\nB"), tier: .reversible)
        #expect(edit.payload == "budget.md +1 −2" && edit.reason == nil, "changed lines, not each side's total")
        let write = PermissionAsk(id: "4", title: "Write new.md", toolName: "Write", detail: .diff(path: "/x/new.md", old: "", new: "hi"),
                                  tier: .reversible)
        #expect(write.payload == "new.md +1 −0")
        let send = PermissionAsk(id: "5", title: "Send an email to Dana", toolName: "mcp__mail__send",
                                 detail: .plain("Sharing the March numbers"), tier: .needsClick)
        #expect(send.payload == "Send an email to Dana" && send.reason == "Sharing the March numbers")
    }

    /// QA U61: an edit that changes 1 line and adds 2 reads "+3 −1", as its diff tile does, never
    /// each side's line count ("+7 −5").
    @Test func anEditsPayloadCountsItsChangedLines() {
        let old = "a\nb\nc\nd\ne"
        let new = "a\nb\nC\nx\ny\nd\ne"
        let edit = PermissionAsk(id: "e", title: "Edit budget-notes.md", toolName: "Edit",
                                 detail: .diff(path: "/x/budget-notes.md", old: old, new: new), tier: .reversible)
        #expect(edit.payload == "budget-notes.md +3 −1")
    }

    /// QA U62: the reason is plain text, and gone when it only restates the command.
    @Test func aReasonThatRestatesTheCommandIsDropped() {
        let publish = PermissionAsk(id: "p", title: "Run `npm publish`", toolName: "Bash",
                                    detail: .command("npm publish --access public"), tier: .needsClick)
        #expect(publish.payload == "npm publish --access public" && publish.reason == nil)
        let why = PermissionAsk(id: "w", title: "Ship **v2** to the registry", toolName: "Bash",
                                detail: .command("npm publish --access public"), tier: .needsClick)
        #expect(why.reason == "Ship v2 to the registry")
    }

    /// Inspire #4: 90 s with no event, a running line says how long it's been quiet.
    @Test func aQuietLineShowsItsAgeAfterNinetySeconds() {
        let t0 = Date(timeIntervalSince1970: 1_793_000_000)
        #expect(Liveness.line("Running tests", since: t0, now: t0.addingTimeInterval(89)) == "Running tests")
        #expect(Liveness.line("Running tests", since: t0, now: t0.addingTimeInterval(130)) == "Running tests · 2m")
        #expect(Liveness.line("Running tests", since: t0, now: t0.addingTimeInterval(7300)) == "Running tests · 2h")
        #expect(Liveness.line("Running tests", since: nil, now: t0) == "Running tests")
    }
}
