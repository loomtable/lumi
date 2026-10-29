import BuddyBridge
import BuddyCore
import BuddyOverlay
import Foundation
import ImageIO
import Synchronization
import UniformTypeIdentifiers
import Testing
@testable import BuddyApp

private let plugin = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("buddy-plugin")

/// A `claude` that records each user line it's sent and answers it (replay echo, then a result).
private final class Recording: ClaudeTransport {
    let lines: AsyncStream<Data>
    private let out: AsyncStream<Data>.Continuation
    private let sent = Mutex<[Data]>([])

    init() { (lines, out) = AsyncStream<Data>.makeStream() }

    var userLines: [Data] { sent.withLock { $0 } }

    func send(_ data: Data) async throws {
        let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard o?["type"] as? String == "user" else { return }
        sent.withLock { $0.append(data) }
        let uuid = o?["uuid"] as? String ?? ""
        for object: [String: Any] in [
            ["type": "user", "isReplay": true, "uuid": uuid, "message": ["role": "user", "content": [["type": "text", "text": "x"]]]],
            ["type": "result", "subtype": "success", "is_error": false, "session_id": "c-1", "result": "Read them.",
             "user_message_uuids": [uuid]],
        ] {
            out.yield(try! JSONSerialization.data(withJSONObject: object))
        }
    }

    func closeInput() { out.finish() }
    func terminate() { out.finish() }
    func exitStatus() async -> Int32 { 0 }
    var stderrTail: String { "" }
}

/// Wire (a): a composer send's attachments reach Claude, from the page's `PageSubmit` to the bytes of
/// the user line written to `claude`.
@MainActor
struct AttachmentWireTests {
    @Test func composerAttachmentsBecomeImageBlocksAndPathLines() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "attach-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appending(path: "chart.png"), notes = dir.appending(path: "notes.md"), spaced = dir.appending(path: "Q3 plan.pdf")
        let pixels = picture(width: 4, height: 3)
        try pixels.write(to: png)
        try Data("# notes".utf8).write(to: notes)
        try Data("%PDF".utf8).write(to: spaced)

        // The page: a typed send with a picture and two files.
        let submit = PageSubmit(text: "what do these say?", attachments: [
            PageAttachment(url: png, kind: .image), PageAttachment(url: notes, kind: .file), PageAttachment(url: spaced, kind: .file),
        ])
        let coordinator = BuddyCoordinator(voice: FakeVoice(), context: FakeContext.packet(), turns: FakeSessionEngine(),
                                           overlay: FakeOverlay(), pointer: FixedPointer())
        let id = SessionID(rawValue: "s_attach")
        let launch = SessionLaunch(claudeSession: UUID(), exists: false, cwd: dir)
        let request = try #require(await coordinator.pageRequest(id, submit, plan: SessionTurnPlan(id: id, harness: .open, kind: .typed,
                                                                                                launch: launch, seed: nil)))
        #expect(request.attachments == [TurnAttachment(url: png, isImage: true), TurnAttachment(url: notes, isImage: false),
                                        TurnAttachment(url: spaced, isImage: false)])

        // The engine: what `claude` receives.
        let transport = Recording()
        let pool = SessionPool(caps: PoolCaps(live: 1), spec: { launch in
            .open(executable: URL(fileURLWithPath: "/c"), launch: launch, permissionMode: nil, environment: [:])
        }, transport: { _ in transport }, restart: RestartPolicy(delays: []), sweepEvery: nil)
        let turns = LiveSessionTurns(pool: pool, plugin: plugin, settings: { SessionSettings() })
        for await _ in await turns.run(request, id: id, launch: launch) {}

        let line = try #require(transport.userLines.first)
        let object = try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])
        let content = try #require((object["message"] as? [String: Any])?["content"] as? [[String: Any]])
        let image = try #require(content.first { $0["type"] as? String == "image" })
        let source = try #require(image["source"] as? [String: Any])
        #expect(source["media_type"] as? String == "image/png")
        #expect(source["data"] as? String == pixels.base64EncodedString(), "the picture's own bytes")
        let text = try #require(content.last?["text"] as? String)
        #expect(text.hasPrefix("what do these say?"), "the user's words first")
        #expect(text.contains("\n@\(notes.standardizedFileURL.path)"))
        #expect(text.contains("\n@\"\(spaced.standardizedFileURL.path)\""), "a path with a space is quoted")
        #expect(!text.contains("chart.png"), "the picture went as an image, not a path")
        _ = await pool.shutdownAll()
    }

    @Test func pictureNothingCanReadGoesAsAPath() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let heic = dir.appending(path: "photo.heic"), big = dir.appending(path: "big.png"), gone = dir.appending(path: "gone.jpg")
        try Data([1]).write(to: heic)
        try Data(count: TypedTurn.maxImageBytes + 1).write(to: big)
        let loaded = await TypedTurn.load([heic, big, gone].map { TurnAttachment(url: $0, isImage: true) })
        #expect(loaded.images.isEmpty)
        #expect(loaded.references == [heic, big, gone].map(\.standardizedFileURL))
    }

    /// A Retina screenshot over the limit, a picture too tall, and a TIFF all go as images the API
    /// takes: scaled to 1568 px and re-encoded, not dropped to a path (owner: paste a screenshot).
    @Test func pictureTheAPICantTakeAsIsIsScaledToFit() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let shot = dir.appending(path: "Screenshot.png"), tall = dir.appending(path: "tall.png"), tiff = dir.appending(path: "scan.tiff")
        try picture(width: 2400, height: 1600, noise: true).write(to: shot)
        try picture(width: 40, height: 8_400).write(to: tall)
        try picture(width: 300, height: 200, type: .tiff).write(to: tiff)
        #expect(try Data(contentsOf: shot).count > TypedTurn.maxImageBytes, "the fixture is over the limit")

        let loaded = await TypedTurn.load([shot, tall, tiff].map { TurnAttachment(url: $0, isImage: true) })
        #expect(loaded.references.isEmpty)
        try #require(loaded.images.count == 3)
        for image in loaded.images {
            #expect(image.data.count <= TypedTurn.maxImageBytes)
            let source = try #require(CGImageSourceCreateWithData(image.data as CFData, nil))
            let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            let side = max(props[kCGImagePropertyPixelWidth] as? Int ?? 0, props[kCGImagePropertyPixelHeight] as? Int ?? 0)
            #expect(side <= TypedTurn.scaledSide)
            #expect(["image/png", "image/jpeg"].contains(image.mediaType))
        }
        #expect(loaded.images[0].mediaType == "image/jpeg", "noise doesn't fit as PNG, so JPEG")
        #expect(loaded.images[2].mediaType == "image/png", "a small TIFF becomes a PNG")
    }

    @Test func pictureTheAPITakesGoesAsItsOwnBytes() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appending(path: "small.png"), jpeg = dir.appending(path: "photo.JPG")
        let bytes = picture(width: 20, height: 10), photo = picture(width: 20, height: 10, type: .jpeg)
        try bytes.write(to: png)
        try photo.write(to: jpeg)
        let loaded = await TypedTurn.load([png, jpeg].map { TurnAttachment(url: $0, isImage: true) })
        #expect(loaded.images == [TurnInput.Image(data: bytes, mediaType: "image/png"), TurnInput.Image(data: photo, mediaType: "image/jpeg")])
    }

    private func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "attach-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// A real picture: a flat colour, or random pixels (which compress badly, for size limits).
func picture(width: Int, height: Int, noise: Bool = false, type: UTType = .png) -> Data {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    if noise, let base = ctx.data {
        var rng = SystemRandomNumberGenerator()
        let bytes = base.bindMemory(to: UInt8.self, capacity: width * height * 4)
        for i in 0..<(width * height) {
            let v = rng.next() as UInt32
            bytes[i * 4] = UInt8(truncatingIfNeeded: v)
            bytes[i * 4 + 1] = UInt8(truncatingIfNeeded: v >> 8)
            bytes[i * 4 + 2] = UInt8(truncatingIfNeeded: v >> 16)
            bytes[i * 4 + 3] = 255
        }
    } else {
        ctx.setFillColor(CGColor(red: 0.9, green: 0.4, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out as CFMutableData, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    return out as Data
}
