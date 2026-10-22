import Foundation
import Synchronization
import Testing
@testable import BuddyContext

/// Looking for a project root must never touch a privacy-protected folder: macOS would ask
/// "Lumi would like to access files in your Desktop folder" mid-question.
@Suite("Protected folders")
struct ProtectedFolderTests {
    static let roots = ProtectedFolders.roots(home: "/Users/me")

    final class Probe: Sendable {
        let touched = Mutex<[String]>([])
        func fileExists(_ path: String) -> Bool { touched.withLock { $0.append(path) }; return false }
        func list(_ path: String) -> [String]? { touched.withLock { $0.append(path) }; return ["x.code-workspace"] }
    }

    @Test("nothing in a protected folder is read", arguments: [
        "/Users/me/Desktop/site", "/Users/me/Documents/work/app", "/Users/me/Downloads/repo",
        "/Users/me/Library/Mobile Documents/com~apple~CloudDocs/proj", "/Users/me/Desktop", "/Volumes/USB/proj",
        "/Users/me/desktop/site", "/Users/me/Desktop/", "/Volumes", "/Users/me/Library/CloudStorage/Dropbox/proj",
        "/System/Volumes/Data/Users/me/Documents/app", "/Network/share/proj",
    ])
    func protected(path: String) {
        let probe = Probe()
        #expect(!EditorTitle.looksLikeProjectRoot(path, protectedRoots: Self.roots,
                                                  fileExists: probe.fileExists, list: probe.list))
        #expect(probe.touched.withLock { $0 }.isEmpty)
    }

    @Test("other folders are checked as before")
    func unprotected() {
        let probe = Probe()
        #expect(EditorTitle.looksLikeProjectRoot("/Users/me/dev/app", protectedRoots: Self.roots,
                                                 fileExists: probe.fileExists, list: probe.list))
        #expect(probe.touched.withLock { $0 } == ["/Users/me/dev/app/.git", "/Users/me/dev/app/.vscode", "/Users/me/dev/app"])
    }

    @Test("a name that only starts like a protected folder isn't one")
    func prefixIsNotAFolder() {
        #expect(!ProtectedFolders.contains("/Users/me/DesktopStuff/app", roots: Self.roots))
        #expect(ProtectedFolders.contains("/Users/me/Desktop/../Desktop/app", roots: Self.roots))
    }

    @Test("in a protected folder the workspace is still the nearest title match")
    func workspaceFallsBack() {
        // Two matching ancestors and nothing may be probed: the nearest wins.
        let found = EditorTitle.workspace(file: "/Users/me/Documents/aipulse/web/src/a.ts", title: "a.ts — web — aipulse") {
            EditorTitle.looksLikeProjectRoot($0, protectedRoots: Self.roots, fileExists: { _ in Issue.record("touched"); return false },
                                             list: { _ in Issue.record("listed"); return nil })
        }
        #expect(found == "/Users/me/Documents/aipulse/web")
    }

    @Test("a terminal cwd in a protected folder is compared without resolving symlinks")
    func terminalCwd() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let cwd = home + "/Desktop/proj/../proj"
        #expect(ProcessTreeTerminalSensor.realpath(cwd) == home + "/Desktop/proj")
    }
}
