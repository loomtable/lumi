import BuddyCore
import Foundation
import Testing
@testable import BuddyContext

@Suite("Redact")
struct RedactTests {
    let m = Redact.mask

    @Test("flag values, key=value, headers and attached mysql passwords are masked")
    func arguments() {
        #expect(Redact.arguments(["ngrok", "http", "3000", "--authtoken", "abc"]) == ["ngrok", "http", "3000", "--authtoken", m])
        #expect(Redact.arguments(["jupyter", "lab", "--ServerApp.token=xyz"]) == ["jupyter", "lab", "--ServerApp.token=" + m])
        #expect(Redact.arguments(["curl", "-H", "Authorization: Bearer abc.def"]) == ["curl", "-H", "Authorization: " + m])
        #expect(Redact.arguments(["mysql", "-uroot", "-pS3cret"]) == ["mysql", "-uroot", "-p" + m])
        #expect(Redact.arguments(["deploy", "--api-key", "k", "API_KEY=v"]) == ["deploy", "--api-key", m, "API_KEY=" + m])
        #expect(Redact.arguments(["tool", "--password=hunter2"]) == ["tool", "--password=" + m])
    }

    @Test("ordinary arguments are kept")
    func kept() {
        let args = ["next", "dev", "-p", "3000", "--turbo", "src/keyboard.ts", "--port=8080", "-p8080"]
        #expect(Redact.arguments(args) == args)
        #expect(Redact.arguments(["mysqlx", "-pfoo"]) == ["mysqlx", "-pfoo"])  // only mysql clients
    }

    @Test("long random-looking strings are masked; long words and paths are not")
    func random() {
        #expect(Redact.arguments(["x", "sk_live_51HxT9aBcDeFgHiJkLmNoPq12345"]) == ["x", m])
        #expect(Redact.arguments(["x", "supercalifragilisticexpialidocious"]) == ["x", "supercalifragilisticexpialidocious"])
        #expect(Redact.arguments(["x", "/Users/me/projects/a1b2c3d4e5f6g7h8i9j0"]) == ["x", "/Users/me/projects/a1b2c3d4e5f6g7h8i9j0"])
    }

    @Test("URLs lose userinfo and fragment; sensitive query values are masked")
    func urls() {
        #expect(Redact.url("http://localhost:8888/lab?token=abc&tree=1") == "http://localhost:8888/lab?token=REDACTED&tree=1")
        #expect(Redact.url("https://user:pw@example.com/a#access_token=x") == "https://example.com/a")
        #expect(Redact.url("http://localhost:3000/today") == "http://localhost:3000/today")
        #expect(Redact.url("https://x.com/cb?code=1&session_id=9") == "https://x.com/cb?code=1&session_id=REDACTED")
    }
}

@Suite("Editor workspace roots")
struct EditorRootTests {
    @Test("with several same-named ancestors the project root wins, else the nearest")
    func root() {
        let file = "/x/web/packages/web/src/a.ts"
        #expect(EditorTitle.workspace(file: file, title: "a.ts — web", isProjectRoot: { $0 == "/x/web" }) == "/x/web")
        #expect(EditorTitle.workspace(file: file, title: "a.ts — web", isProjectRoot: { _ in false }) == "/x/web/packages/web")
    }

    @Test("' - ' is only a separator when no em or en dash is present")
    func dashes() {
        #expect(EditorTitle.segments("a.ts — my - app") == ["a.ts", "my - app"])
        #expect(EditorTitle.segments("a.ts - app") == ["a.ts", "app"])
    }
}

@Suite("Local server privacy")
struct LocalServerPrivacyTests {
    /// BlockedPIDs resolves real bundle IDs, so dropping a blocked app's server needs a running
    /// blocked app (live only). Here: an unblocked server is kept and the tab title is filled in.
    @Test("an unblocked local server is kept; tab title comes from the window")
    func keptServer() async {
        let list = BlockedPIDs(blocklist: Blocklist(userBundleIDs: ["com.example.never"]))
        #expect(!list.contains(getpid()))
        let sensors = ContextSensors(
            frontApp: FakeSensor<FrontApp?>(FrontApp(pid: 4242, name: "Chrome", bundle: "com.google.Chrome")),
            window: FakeSensor<ContextPacket.Window?>(ContextPacket.Window(title: "Today")),
            selection: FakeSensor<ContextPacket.Selection?>(nil), cursor: FakeSensor<ContextPacket.Cursor?>(nil),
            display: FakeSensor<ContextPacket.Display?>(nil), recent: FakeSensor<[ContextPacket.RecentApp]>([]),
            browser: FakeSensor<ContextPacket.Browser?>(ContextPacket.Browser(url: "http://localhost:3000/")),
            localServer: FakeSensor<ContextPacket.LocalServer?>(ContextPacket.LocalServer(port: 3000, pid: getpid())))
        guard case .packet(let p, _) = await ContextBuilder(sensors: sensors).capture() else {
            Issue.record("no packet")
            return
        }
        #expect(p.localServer?.pid == getpid())
        #expect(p.browser?.tabTitle == "Today")  // filled from the window sensor
    }
}
