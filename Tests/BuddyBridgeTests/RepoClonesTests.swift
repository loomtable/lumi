import BuddyCore
import Foundation
import Testing
@testable import BuddyBridge

// "Always find the project": a repo's web page maps to its local clone among trusted folders.

struct HostedRepoTests {
    @Test func repoPagesNameTheRepo() {
        let qt = HostedRepo(host: .github, path: "acme/widgets")
        #expect(HostedRepo(browserURL: "https://github.com/acme/widgets") == qt)
        #expect(HostedRepo(browserURL: "https://github.com/Acme/Widgets/pull/141/files") == qt)
        #expect(HostedRepo(browserURL: "https://www.github.com/acme/widgets/blob/main/BRIEF.md") == qt)
        #expect(HostedRepo(browserURL: "https://gitlab.com/acme/platform/api/-/merge_requests/7")
                == HostedRepo(host: .gitlab, path: "acme/platform/api"))
    }

    @Test func otherPagesNameNoRepo() {
        for url in ["https://github.com/settings/profile", "https://github.com/acme", "https://github.com",
                    "https://bitbucket.org/acme/api", "https://example.com/acme/api", "file:///Users/me/github.com/a/b"] {
            #expect(HostedRepo(browserURL: url) == nil, "\(url)")
        }
    }

    @Test func remotesInEveryUsualShape() {
        let r = HostedRepo(host: .github, path: "acme/widgets")
        for remote in ["git@github.com:acme/widgets.git",
                       "git@github.com-acme:acme/widgets.git",   // an ~/.ssh/config alias
                       "ssh://git@github.com:22/acme/widgets.git",
                       "https://github.com/acme/widgets.git",
                       "https://github.com/acme/widgets"] {
            #expect(HostedRepo(remote: remote) == r, "\(remote)")
        }
        #expect(HostedRepo(remote: "git@gitlab.com:acme/platform/api.git") == HostedRepo(host: .gitlab, path: "acme/platform/api"))
        #expect(HostedRepo(remote: "git@bitbucket.org:acme/api.git") == nil)
        #expect(HostedRepo(remote: "/Users/me/bare.git") == nil)
    }

    @Test func onlyRemoteSectionsCount() {
        let config = """
        [core]
        \turl = https://github.com/not/this
        [remote "origin"]
        \turl = git@github.com:a/b.git
        \tfetch = +refs/heads/*:refs/remotes/origin/*
        [remote "upstream"]
        \turl=https://github.com/c/d
        [branch "main"]
        \tremote = origin
        """
        #expect(RepoClones.remoteURLs(inConfig: config) == ["git@github.com:a/b.git", "https://github.com/c/d"])
    }
}

/// A trusted folder on disk holding clones, a worktree and an unrelated repo.
private struct Tree {
    let root: URL
    var trusted: String { FolderTrust.normalize(root.path) }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("clones-\(UUID().uuidString)")
        try clone("buddy", remote: "git@github.com-work:Acme/widgets.git")
        try clone("other", remote: "https://github.com/acme/other.git")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("notes"), withIntermediateDirectories: true)
        // A worktree of "buddy" with a shorter name: the main clone must still come first.
        let wt = root.appendingPathComponent("wt")
        let gitDir = root.appendingPathComponent("buddy/.git/worktrees/wt")
        try FileManager.default.createDirectory(at: wt, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try Data("gitdir: \(gitDir.path)\n".utf8).write(to: wt.appendingPathComponent(".git"))
        try Data("../..\n".utf8).write(to: gitDir.appendingPathComponent("commondir"))
    }

    func clone(_ name: String, remote: String) throws {
        let git = root.appendingPathComponent(name).appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try Data("[core]\n\tbare = false\n[remote \"origin\"]\n\turl = \(remote)\n".utf8).write(to: git.appendingPathComponent("config"))
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

struct RepoClonesTests {
    @Test func findsTheCloneAndItsWorktreeMainCloneFirst() throws {
        let tree = try Tree()
        defer { tree.remove() }
        let found = RepoClones.find(HostedRepo(host: .github, path: "acme/widgets"),
                                    in: FolderTrust(trustedPaths: [tree.trusted]))
        #expect(found == [tree.trusted + "/buddy", tree.trusted + "/wt"])
    }

    @Test func untrustedFoldersAreNotSearched() throws {
        let tree = try Tree()
        defer { tree.remove() }
        #expect(RepoClones.find(HostedRepo(host: .github, path: "acme/other"), in: FolderTrust(trustedPaths: [])).isEmpty)
    }

    @Test func aRepoPageFindsTheProjectForTheConversationAndDeep() throws {
        let tree = try Tree()
        defer { tree.remove() }
        let trust = FolderTrust(trustedPaths: [tree.trusted])
        var p = ContextPacket(askedAt: Date(), utterance: "why does this test fail?")
        p.browser = .init(url: "https://github.com/acme/widgets/pull/141", host: "github.com")
        let home = URL(fileURLWithPath: "/Users/me")
        #expect(ProjectResolver.project(in: p, trust: trust, home: home.path)?.path == tree.trusted + "/buddy")
        let f = ProjectResolver.folder(for: p, state: ConversationState(id: "c"), trust: trust, policy: .default, home: home)
        #expect(f.url.path == tree.trusted + "/buddy")
    }

    @Test func thePacketsOwnFolderStillWins() throws {
        let tree = try Tree()
        defer { tree.remove() }
        var p = ContextPacket(askedAt: Date(), utterance: "x")
        p.browser = .init(url: "https://github.com/acme/widgets", host: "github.com")
        p.localServer = .init(port: 3000, pid: 1, cwd: tree.trusted + "/other")
        #expect(ProjectResolver.project(in: p, trust: FolderTrust(trustedPaths: [tree.trusted]), home: "/Users/me")?.path
                == tree.trusted + "/other")
    }

    @Test func noCloneMeansNoProject() throws {
        let tree = try Tree()
        defer { tree.remove() }
        var p = ContextPacket(askedAt: Date(), utterance: "x")
        p.browser = .init(url: "https://github.com/someone/elsewhere", host: "github.com")
        #expect(ProjectResolver.project(in: p, trust: FolderTrust(trustedPaths: [tree.trusted]), home: "/Users/me") == nil)
        #expect(ProjectResolver.project(in: p) == nil)   // no trust given: the browser isn't consulted
    }
}

// "Always find the project", part (b): the most recent trusted terminal or editor folder.

private func slackPacket(recent: [ContextPacket.RecentApp]) -> ContextPacket {
    var p = ContextPacket(askedAt: Date(), utterance: "why does my build fail?")
    p.recent = recent
    return p
}

struct RecentProjectTests {
    let trust = FolderTrust(trustedPaths: ["/Users/me/Developer"])
    let home = URL(fileURLWithPath: "/Users/me")
    let repo: (String) -> Bool = { $0 == "/Users/me/Developer/app" || $0 == "/Users/me/Developer/site" }

    @Test func theNewestTrustedRecentFolderIsTheProject() {
        let p = slackPacket(recent: [
            .init(app: "Mail", title: "Inbox"),                                    // no folder
            .init(app: "Terminal", title: "zsh", cwd: "/tmp/scratch", command: "zsh"),   // not trusted: skipped
            .init(app: "Code", title: "app", cwd: "/Users/me/Developer/app/src"),
            .init(app: "Terminal", title: "zsh", cwd: "/Users/me/Developer/site"),  // older
        ])
        #expect(ProjectResolver.project(in: p, trust: trust, home: home.path, isRepo: repo)?.path == "/Users/me/Developer/app")
        let f = ProjectResolver.folder(for: p, state: ConversationState(id: "c"), trust: trust, policy: .default,
                                       home: home, isRepo: repo)
        #expect(f.url.path == "/Users/me/Developer/app")
    }

    @Test func theFrontFolderWinsOverRecent() {
        var p = slackPacket(recent: [.init(app: "Code", cwd: "/Users/me/Developer/app")])
        p.terminal = .init(cwd: "/Users/me/Developer/site")
        #expect(ProjectResolver.project(in: p, trust: trust, home: home.path, isRepo: repo)?.path == "/Users/me/Developer/site")
    }

    @Test func aRepoPageWinsOverRecent() throws {
        let tree = try Tree()
        defer { tree.remove() }
        var p = slackPacket(recent: [.init(app: "Code", cwd: tree.trusted + "/other")])
        p.browser = .init(url: "https://github.com/acme/widgets", host: "github.com")
        #expect(ProjectResolver.project(in: p, trust: FolderTrust(trustedPaths: [tree.trusted]), home: home.path)?.path
                == tree.trusted + "/buddy")
    }

    @Test func nothingTrustedInRecentMeansNoProject() {
        let p = slackPacket(recent: [.init(app: "Terminal", cwd: "/tmp/scratch"), .init(app: "Code", cwd: "/Users/me/Downloads/x")])
        #expect(ProjectResolver.project(in: p, trust: trust, home: home.path, isRepo: repo) == nil)
        #expect(ProjectResolver.folder(for: p, state: ConversationState(id: "c"), trust: trust, policy: .default,
                                       home: home, isRepo: repo).url == home)
        // No trust given (as before this change): recent isn't consulted.
        #expect(ProjectResolver.project(in: slackPacket(recent: [.init(app: "Code", cwd: "/Users/me/Developer/app")])) == nil)
    }
}
