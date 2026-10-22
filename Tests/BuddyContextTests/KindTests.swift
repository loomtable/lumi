import BuddyCore
import CoreGraphics
import CoreServices
import Foundation
import Testing
@testable import BuddyContext

/// Unit tests for the app-kind fields (M2): pure parsing, Apple-event descriptor building (never
/// sent), libproc reads of the test process itself, and builder dispatch with fakes.
extension BuddyContextTests {
    // MARK: - LocalURL

    @Suite("LocalURL")
    struct LocalURLTests {
        @Test("local hosts with explicit ports", arguments: [
            ("http://localhost:3000/feed", 3000),
            ("http://127.0.0.1:8000", 8000),
            ("http://[::1]:5173/", 5173),
            ("http://0.0.0.0:4000/x?y=1", 4000),
            ("http://app.foo.localhost:8080", 8080),
            ("https://localhost:8443", 8443),
        ])
        func explicitPort(url: String, port: Int) {
            #expect(LocalURL.port(of: url) == port)
        }

        @Test("scheme default ports")
        func defaultPorts() {
            #expect(LocalURL.port(of: "http://localhost/") == 80)
            #expect(LocalURL.port(of: "https://localhost/") == 443)
            #expect(LocalURL.port(of: "https://127.0.0.1") == 443)
        }

        @Test("non-local hosts give nil", arguments: [
            "https://example.com:3000", "http://192.168.1.5:8080", "http://localhost.example.com:3000",
            "https://example.com",
        ])
        func nonLocal(url: String) {
            #expect(LocalURL.port(of: url) == nil)
        }

        @Test("garbage and file URLs give nil", arguments: [
            "", "not a url", "file:///Users/me/index.html", "localhost:3000", "ws://localhost",
        ])
        func garbage(url: String) {
            #expect(LocalURL.port(of: url) == nil)
        }

        @Test("host matching is case-insensitive")
        func uppercase() {
            #expect(LocalURL.port(of: "http://LOCALHOST:3000") == 3000)
            #expect(LocalURL.port(of: "HTTP://LocalHost") == 80)
        }
    }

    // MARK: - EditorTitle

    @Suite("EditorTitle")
    struct EditorTitleTests {
        @Test("segments split on em dash, en dash and hyphen, dropping dirty markers")
        func segments() {
            #expect(EditorTitle.segments("● useFeed.ts — web") == ["useFeed.ts", "web"])
            #expect(EditorTitle.segments("aipulse – useFeed.kt") == ["aipulse", "useFeed.kt"])
            #expect(EditorTitle.segments("main.go - server - Zed") == ["main.go", "server", "Zed"])
        }

        @Test("VS Code: workspace is the ancestor named in the title")
        func vscode() {
            #expect(EditorTitle.workspace(file: "/Users/me/dev/aipulse/web/src/useFeed.ts", title: "● useFeed.ts — web")
                == "/Users/me/dev/aipulse/web")
        }

        @Test("JetBrains en-dash title")
        func jetbrains() {
            #expect(EditorTitle.workspace(file: "/Users/me/dev/aipulse/src/main/kotlin/useFeed.kt",
                                          title: "aipulse – useFeed.kt") == "/Users/me/dev/aipulse")
        }

        @Test("hyphen separator")
        func hyphen() {
            #expect(EditorTitle.workspace(file: "/Users/me/dev/server/cmd/main.go", title: "main.go - server")
                == "/Users/me/dev/server")
        }

        @Test("nearest ancestor wins when two share the name")
        func nearest() {
            #expect(EditorTitle.workspace(file: "/Users/me/web/apps/web/src/a.ts", title: "a.ts — web")
                == "/Users/me/web/apps/web")
        }

        @Test("no matching ancestor or no title gives nil")
        func noMatch() {
            #expect(EditorTitle.workspace(file: "/Users/me/dev/aipulse/web/a.ts", title: "a.ts — mobile") == nil)
            #expect(EditorTitle.workspace(file: "/Users/me/dev/aipulse/web/a.ts", title: nil) == nil)
        }
    }

    // MARK: - BrowserScripting (descriptors are built, never sent)

    @Suite("BrowserScripting")
    struct BrowserScriptingTests {
        @Test("fourCC packs big-endian ASCII")
        func fourCC() {
            #expect(BrowserScripting.fourCC("acTa") == 0x6163_5461)
            #expect(BrowserScripting.fourCC("URL ") == 0x5552_4C20)
            #expect(BrowserScripting.fourCC("----") == keyDirectObject)
        }

        @Test("paths per browser")
        func paths() {
            #expect(BrowserScripting.path(for: "com.apple.Safari") == BrowserScripting.safari)
            for id in ["com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac",
                       "company.thebrowser.Browser", "com.vivaldi.Vivaldi"] {
                #expect(BrowserScripting.path(for: id) == BrowserScripting.chromium, "\(id)")
            }
            #expect(BrowserScripting.safari.tab == BrowserScripting.fourCC("cTab"))
            #expect(BrowserScripting.safari.url == BrowserScripting.fourCC("pURL"))
            #expect(BrowserScripting.path(for: "org.mozilla.firefox") == nil)
            #expect(BrowserScripting.path(for: "com.example.unknown") == nil)
            #expect(BrowserScripting.path(for: nil) == nil)
        }

        @Test("specifier builds an 'obj ' record with want/form/seld/from")
        func specifier() throws {
            let cc = BrowserScripting.fourCC
            let spec = BrowserScripting.specifier(
                want: cc("cwin"), form: cc("indx"), data: NSAppleEventDescriptor(int32: 1), from: .null())
            #expect(spec.descriptorType == cc("obj "))
            #expect(spec.forKeyword(cc("want"))?.typeCodeValue == cc("cwin"))
            #expect(spec.forKeyword(cc("form"))?.enumCodeValue == cc("indx"))
            #expect(spec.forKeyword(cc("seld"))?.int32Value == 1)
            #expect(spec.forKeyword(cc("from"))?.descriptorType == cc("null"))
        }

        @Test("property specifies a 'prop' of its container")
        func property() throws {
            let cc = BrowserScripting.fourCC
            let container = NSAppleEventDescriptor.null()
            let prop = BrowserScripting.property(cc("pURL"), of: container)
            #expect(prop.descriptorType == cc("obj "))
            #expect(prop.forKeyword(cc("want"))?.typeCodeValue == cc("prop"))
            #expect(prop.forKeyword(cc("form"))?.enumCodeValue == cc("prop"))
            #expect(prop.forKeyword(cc("seld"))?.typeCodeValue == cc("pURL"))
            #expect(prop.forKeyword(cc("from"))?.descriptorType == cc("null"))
        }

        @Test("Chrome chain: URL of acTa of window index 1")
        func chromeChain() throws {
            let cc = BrowserScripting.fourCC
            let path = try #require(BrowserScripting.path(for: "com.google.Chrome"))
            let window = BrowserScripting.specifier(
                want: cc("cwin"), form: cc("indx"), data: NSAppleEventDescriptor(int32: 1), from: .null())
            let url = BrowserScripting.property(path.url, of: BrowserScripting.property(path.tab, of: window))

            #expect(url.forKeyword(cc("seld"))?.typeCodeValue == cc("URL "))
            let tab = try #require(url.forKeyword(cc("from")))
            #expect(tab.descriptorType == cc("obj "))
            #expect(tab.forKeyword(cc("want"))?.typeCodeValue == cc("prop"))
            #expect(tab.forKeyword(cc("seld"))?.typeCodeValue == cc("acTa"))
            let win = try #require(tab.forKeyword(cc("from")))
            #expect(win.descriptorType == cc("obj "))
            #expect(win.forKeyword(cc("want"))?.typeCodeValue == cc("cwin"))
            #expect(win.forKeyword(cc("form"))?.enumCodeValue == cc("indx"))
            #expect(win.forKeyword(cc("seld"))?.int32Value == 1)
            #expect(win.forKeyword(cc("from"))?.descriptorType == cc("null"))
        }

        @Test("AutomationConsent is Equatable over its cases")
        func consentEquatable() {
            #expect(AutomationConsent.granted == .granted)
            #expect(AutomationConsent.granted != .denied)
            #expect(AutomationConsent.notAsked != .denied)
            #expect(AutomationConsent.unavailable(-600) == .unavailable(-600))
            #expect(AutomationConsent.unavailable(-600) != .unavailable(-1708))
            #expect(AutomationConsent.unavailable(0) != .granted)
        }
    }

    // MARK: - Processes (on the test process itself; no permissions needed)

    @Suite("Processes")
    struct ProcessesTests {
        private static func resolved(_ path: String) -> String {
            URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        }

        @Test("info of ourselves has our ppid and name")
        func info() throws {
            let me = try #require(Processes.info(getpid()))
            #expect(me.pid == getpid())
            #expect(me.ppid == getppid())
            #expect(!me.name.isEmpty)
            // p_comm is the executable's name, truncated to MAXCOMLEN (16).
            let exe = Processes.basename(CommandLine.arguments[0])
            #expect(exe.hasPrefix(me.name), "\(me.name) vs \(exe)")
        }

        @Test("userProcesses contains us and our parent")
        func userProcesses() {
            let pids = Set(Processes.userProcesses().map(\.pid))
            #expect(pids.contains(getpid()))
            #expect(pids.contains(getppid()))
            #expect(Processes.userPIDs().contains(getpid()))
        }

        @Test("cwd of ourselves is the current directory")
        func cwd() throws {
            let cwd = try #require(Processes.cwd(getpid()))
            #expect(Self.resolved(cwd) == Self.resolved(FileManager.default.currentDirectoryPath))
        }

        @Test("arguments of ourselves start with the test binary")
        func arguments() throws {
            let args = try #require(Processes.arguments(getpid()))
            let first = try #require(args.first)
            #expect(!first.isEmpty)
            let name = Processes.basename(first)
            let known = ["swiftpm-testing-helper", "xctest", Processes.basename(CommandLine.arguments[0])]
            #expect(known.contains(name), "\(args)")
        }

        @Test("command caps its length with an ellipsis")
        func commandCap() throws {
            let line = try #require(Processes.command(getpid(), maxLength: 5))
            #expect(line.count == 6)
            #expect(line.hasSuffix("…"))
            let full = try #require(Processes.command(getpid()))
            #expect(full.hasPrefix(String(line.dropLast())))
        }

        @Test("basename")
        func basename() {
            #expect(Processes.basename("/usr/local/bin/node") == "node")
            #expect(Processes.basename("node") == "node")
            #expect(Processes.basename("/a/b/") == "b")
            #expect(Processes.basename("") == "")
        }

        @Test("a spawned child: cwd and command")
        func child() async throws {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kindtests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let sleep = Process()
            sleep.executableURL = URL(fileURLWithPath: "/bin/sleep")
            sleep.arguments = ["30"]
            sleep.currentDirectoryURL = dir
            try sleep.run()
            defer {
                sleep.terminate()
                sleep.waitUntilExit()
            }
            let pid = sleep.processIdentifier

            // posix_spawn is effectively atomic, but allow a moment for exec to land.
            var command: String?
            for _ in 0..<50 {
                command = Processes.command(pid)
                if command == "sleep 30" { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(command == "sleep 30")
            let cwd = try #require(Processes.cwd(pid))
            #expect(Self.resolved(cwd) == Self.resolved(dir.path))
            #expect(Processes.info(pid)?.ppid == getpid())
            #expect(Processes.info(pid)?.name == "sleep")
        }

        @Test("nothing of ours listens on port 1")
        func unusedPort() {
            #expect(Processes.listeningPID(port: 1) == nil)
        }
    }

    // MARK: - Builder kind dispatch

    @Suite("Builder kind dispatch")
    struct KindDispatchTests {
        static let browserValue = ContextPacket.Browser(
            url: "http://localhost:3000/feed", host: "localhost", tabTitle: "Feed")
        static let serverValue = ContextPacket.LocalServer(
            port: 3000, pid: 999, cwd: "/Users/me/dev/aipulse/web", command: "next dev")
        static let terminalValue = ContextPacket.Terminal(cwd: "/Users/me/dev", command: "npm test")
        static let editorValue = ContextPacket.Editor(workspace: "/Users/me/dev/web", file: "/Users/me/dev/web/a.ts")
        static let window = ContextPacket.Window(title: "Feed", document: nil)
        static let display = ContextPacket.Display(id: 1, scale: 2, appearance: .dark)

        struct Fakes {
            var frontApp: FakeSensor<FrontApp?>
            var window = FakeSensor<ContextPacket.Window?>(KindDispatchTests.window)
            var selection = FakeSensor<ContextPacket.Selection?>(nil)
            var cursor = FakeSensor<ContextPacket.Cursor?>(ContextPacket.Cursor(x: 1, y: 2, element: nil))
            var display = FakeSensor<ContextPacket.Display?>(KindDispatchTests.display)
            var recent = FakeSensor<[ContextPacket.RecentApp]>([ContextPacket.RecentApp(app: "Slack")])
            var browser: FakeSensor<ContextPacket.Browser?>
            var localServer = FakeSensor<ContextPacket.LocalServer?>(KindDispatchTests.serverValue)
            var terminal = FakeSensor<ContextPacket.Terminal?>(KindDispatchTests.terminalValue)
            var editor = FakeSensor<ContextPacket.Editor?>(KindDispatchTests.editorValue)

            init(bundle: String, browser: ContextPacket.Browser? = KindDispatchTests.browserValue,
                 kindDelay: Duration = .zero) {
                frontApp = FakeSensor<FrontApp?>(FrontApp(pid: 4242, name: "App", bundle: bundle))
                self.browser = FakeSensor<ContextPacket.Browser?>(browser, delay: kindDelay)
                if kindDelay > .zero {
                    terminal = FakeSensor<ContextPacket.Terminal?>(KindDispatchTests.terminalValue, delay: kindDelay)
                    editor = FakeSensor<ContextPacket.Editor?>(KindDispatchTests.editorValue, delay: kindDelay)
                }
            }

            var sensors: ContextSensors {
                ContextSensors(
                    frontApp: frontApp, window: window, selection: selection, cursor: cursor, display: display,
                    recent: recent, browser: browser, localServer: localServer, terminal: terminal, editor: editor)
            }

            var kindCalls: [String: Int] {
                ["browser": browser.callCount, "localServer": localServer.callCount,
                 "terminal": terminal.callCount, "editor": editor.callCount]
            }
        }

        static func packet(_ fakes: Fakes, budget: Duration = .milliseconds(180), hardCap: Duration = .seconds(1))
            async -> (ContextPacket, ContextTimings)?
        {
            let result = await ContextBuilder(sensors: fakes.sensors, budget: budget, hardCap: hardCap).capture()
            guard case .packet(let packet, let timings) = result else {
                Issue.record("expected a packet, got \(result)")
                return nil
            }
            return (packet, timings)
        }

        @Test("browser: browser read, then its URL's local server")
        func browser() async throws {
            let fakes = Fakes(bundle: "com.google.Chrome")
            let (packet, timings) = try #require(await Self.packet(fakes))
            #expect(packet.app?.kind == .browser)
            #expect(packet.browser == Self.browserValue)
            #expect(packet.localServer == Self.serverValue)
            #expect(packet.terminal == nil)
            #expect(packet.editor == nil)
            #expect(fakes.kindCalls == ["browser": 1, "localServer": 1, "terminal": 0, "editor": 0])
            #expect(timings.sensorMs["kind"] != nil)
        }

        @Test("browser with nothing: the local server isn't looked up")
        func browserNil() async throws {
            let fakes = Fakes(bundle: "com.google.Chrome", browser: nil)
            let (packet, _) = try #require(await Self.packet(fakes))
            #expect(packet.browser == nil)
            #expect(packet.localServer == nil)
            #expect(fakes.kindCalls == ["browser": 1, "localServer": 0, "terminal": 0, "editor": 0])
        }

        @Test("terminal")
        func terminal() async throws {
            let fakes = Fakes(bundle: "com.googlecode.iterm2")
            let (packet, _) = try #require(await Self.packet(fakes))
            #expect(packet.app?.kind == .terminal)
            #expect(packet.terminal == Self.terminalValue)
            #expect(packet.browser == nil && packet.localServer == nil && packet.editor == nil)
            #expect(fakes.kindCalls == ["browser": 0, "localServer": 0, "terminal": 1, "editor": 0])
        }

        @Test("editor")
        func editor() async throws {
            let fakes = Fakes(bundle: "com.microsoft.VSCode")
            let (packet, _) = try #require(await Self.packet(fakes))
            #expect(packet.app?.kind == .editor)
            #expect(packet.editor == Self.editorValue)
            #expect(packet.browser == nil && packet.localServer == nil && packet.terminal == nil)
            #expect(fakes.kindCalls == ["browser": 0, "localServer": 0, "terminal": 0, "editor": 1])
        }

        @Test("finder: no kind sensor runs")
        func finder() async throws {
            let fakes = Fakes(bundle: "com.apple.finder")
            let (packet, timings) = try #require(await Self.packet(fakes))
            #expect(packet.app?.kind == .finder)
            #expect(packet.browser == nil && packet.localServer == nil && packet.terminal == nil && packet.editor == nil)
            #expect(fakes.kindCalls.values.allSatisfy { $0 == 0 }, "\(fakes.kindCalls)")
            #expect(timings.late.isEmpty)
        }

        @Test("a slow browser read over the budget keeps its URL")
        func overBudgetKeepsTheURL() async throws {
            let fakes = Fakes(bundle: "com.google.Chrome", kindDelay: .milliseconds(150))
            let (packet, timings) = try #require(await Self.packet(fakes, budget: .milliseconds(50)))
            #expect(packet.browser != nil)
            #expect(timings.late.contains("kind"))
        }

        @Test("a kind sensor past the cap is late; the other fields are still there")
        func slowKind() async throws {
            let fakes = Fakes(bundle: "com.google.Chrome", kindDelay: .milliseconds(400))
            let clock = ContinuousClock()
            let start = clock.now
            let (packet, timings) = try #require(await Self.packet(fakes, budget: .milliseconds(50), hardCap: .milliseconds(100)))
            #expect(clock.now - start < .milliseconds(300))
            #expect(timings.late == ["kind"])
            #expect(timings.sensorMs["kind"] == nil)
            #expect(packet.browser == nil && packet.localServer == nil)
            #expect(packet.window == Self.window)
            #expect(packet.display == Self.display)
            #expect(packet.cursor != nil)
            #expect(packet.recent == [ContextPacket.RecentApp(app: "Slack")])
            #expect(packet.app?.kind == .browser)
        }
    }
}

/// `recent[].cwd`: the folder an app was in when the user left it.
@Suite("Recent folder")
struct RecentFolderTests {
    let terminal = FakeSensor<ContextPacket.Terminal?>(ContextPacket.Terminal(cwd: "/Users/me/app", command: "npm run dev"))
    let editor = FakeSensor<ContextPacket.Editor?>(ContextPacket.Editor(workspace: "/Users/me/site", file: "/Users/me/site/a.ts"))

    func entry(_ bundle: String) -> ContextPacket.RecentApp {
        var entry = ContextPacket.RecentApp(app: "x", title: "t")
        WorkspaceRecentApps.addFolder(to: &entry, of: FrontApp(pid: 9, name: "x", bundle: bundle), terminal: terminal, editor: editor)
        return entry
    }

    @Test("a terminal: its front tab's folder and command")
    func terminalFolder() {
        #expect(entry("com.googlecode.iterm2") == ContextPacket.RecentApp(app: "x", title: "t", cwd: "/Users/me/app", command: "npm run dev"))
        #expect(editor.callCount == 0)
    }

    @Test("an editor: its workspace")
    func editorFolder() {
        #expect(entry("com.microsoft.VSCode") == ContextPacket.RecentApp(app: "x", title: "t", cwd: "/Users/me/site"))
        #expect(terminal.callCount == 0)
    }

    @Test("anything else: no folder, and nothing else is read")
    func other() {
        #expect(entry("com.apple.Safari") == ContextPacket.RecentApp(app: "x", title: "t"))
        #expect(terminal.callCount == 0 && editor.callCount == 0)
    }
}

/// `window.bounds`: what a window-cropped screenshot shows (bf's model-image crop).
@Suite("Window bounds")
struct WindowBoundsTests {
    @Test("a frame becomes global-point bounds; an empty one is left out")
    func rect() {
        #expect(AXWindowSensor.rect(CGRect(x: 100, y: 40, width: 800, height: 600))
            == ContextPacket.Rect(x: 100, y: 40, width: 800, height: 600))
        #expect(AXWindowSensor.rect(CGRect(x: 0, y: 0, width: 0, height: 300)) == nil)
    }

    @Test("wire format: window.bounds, absent when nil")
    func wire() throws {
        var packet = ContextPacket(askedAt: Date(timeIntervalSince1970: 0), utterance: "")
        packet.window = .init(title: "Doc", bounds: .init(x: 1, y: 2, width: 3, height: 4))
        let json = String(decoding: try ContextPacket.makeEncoder().encode(packet), as: UTF8.self)
        #expect(json.contains(#""bounds":{"height":4,"width":3,"x":1,"y":2}"#))
        packet.window = .init(title: "Doc")
        #expect(!String(decoding: try ContextPacket.makeEncoder().encode(packet), as: UTF8.self).contains("bounds"))
    }
}
