import BuddyCore
import CoreGraphics
import Foundation
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers

public enum ScreenshotError: Error, Sendable, Equatable {
    case screenRecordingNotGranted
    case displayNotFound
    case captureFailed(String)
}

/// How the screenshot file for the model is encoded. The full-resolution image is always kept
/// in memory as well (`Screenshot.full`) for rings and OCR.
public struct ScreenshotOptions: Sendable, Equatable {
    public enum Format: Sendable, Equatable {
        /// Quality 0...1.
        case jpeg(quality: Double)
        case png
    }

    /// Longest side of the file in pixels; nil keeps the display's full resolution.
    public var maxLongEdge: Int?
    public var format: Format

    public init(maxLongEdge: Int?, format: Format) {
        self.maxLongEdge = maxLongEdge
        self.format = format
    }

    /// What the bridge sends to the model: the front window (`ModelRegion`) or the whole display,
    /// at most 1568 px. Image size made no visible difference to Quick latency (n=8 per variant,
    /// 580 to 1,730 image tokens), so legibility wins: 13 pt text in a 2000 pt wide window on a
    /// 27" display is about 10 px tall, where the whole display at 1280 px made it about 6 px.
    /// Under 2000 px, the API's limit once a request carries more than 20 images (history counts).
    public static let model = ScreenshotOptions(maxLongEdge: 1568, format: .jpeg(quality: 0.7))
    public static let fullPNG = ScreenshotOptions(maxLongEdge: nil, format: .png)

    var fileExtension: String {
        switch format {
        case .jpeg: "jpg"
        case .png: "png"
        }
    }
}

/// One summon screenshot.
public struct Screenshot: Sendable {
    /// The encoded file, per the options.
    public let file: URL
    /// The same bytes as `file`, for sending inline without reading the disk back.
    public let fileData: Data
    /// Pixel size of `file`.
    public let fileWidth: Int
    public let fileHeight: Int
    /// The display at full resolution, without our or blocked apps' windows. In memory only.
    public let full: CGImage
    public let displayID: UInt32
    /// Pixels per point of `full`, to map AX/global points onto it.
    public let scale: Double
    /// The display in global points, top-left origin (`CGDisplayBounds`), the same space as AX
    /// rects and `ContextPacket.selection.bounds`.
    public let displayFrame: CGRect
    /// What `file` shows, in global points: the front window's part of the display, or the whole
    /// display (`displayFrame`).
    public let fileRect: CGRect

    public init(
        file: URL, fileData: Data, fileWidth: Int, fileHeight: Int, full: CGImage, displayID: UInt32,
        scale: Double, displayFrame: CGRect, fileRect: CGRect? = nil
    ) {
        self.file = file
        self.fileData = fileData
        self.fileWidth = fileWidth
        self.fileHeight = fileHeight
        self.full = full
        self.displayID = displayID
        self.scale = scale
        self.displayFrame = displayFrame
        self.fileRect = fileRect ?? displayFrame
    }

    /// The part of `full` the model gets: `region` (global points) clipped to the display, or the
    /// whole display when there's no region or it isn't on this display. Its pixels are snapped
    /// outward to whole pixels of `full`, and the returned rect is exactly what they show.
    public static func modelArea(of full: CGImage, displayFrame: CGRect, region: CGRect?) -> (image: CGImage, rect: CGRect) {
        guard let region, displayFrame.width > 0, displayFrame.height > 0 else { return (full, displayFrame) }
        let sx = Double(full.width) / displayFrame.width, sy = Double(full.height) / displayFrame.height
        let px = CGRect(x: (region.minX - displayFrame.minX) * sx, y: (region.minY - displayFrame.minY) * sy,
                        width: region.width * sx, height: region.height * sy)
            .integral.intersection(CGRect(x: 0, y: 0, width: full.width, height: full.height))
        guard !px.isNull, !px.isEmpty, let cropped = full.cropping(to: px) else { return (full, displayFrame) }
        let rect = CGRect(x: displayFrame.minX + px.minX / sx, y: displayFrame.minY + px.minY / sy,
                          width: px.width / sx, height: px.height / sy)
        return (cropped, rect)
    }

    /// Maps a rect in global points to pixels of `file` (top-left origin), clipped to the image.
    /// Nil if it doesn't intersect this display.
    public func filePixels(ofGlobal rect: CGRect) -> CGRect? {
        pixels(ofGlobal: rect, in: fileRect, width: fileWidth, height: fileHeight)
    }

    /// The same for `full`.
    public func fullPixels(ofGlobal rect: CGRect) -> CGRect? {
        pixels(ofGlobal: rect, in: displayFrame, width: full.width, height: full.height)
    }

    private func pixels(ofGlobal rect: CGRect, in frame: CGRect, width: Int, height: Int) -> CGRect? {
        guard frame.width > 0, frame.height > 0 else { return nil }
        let sx = Double(width) / frame.width, sy = Double(height) / frame.height
        let r = CGRect(
            x: (rect.minX - frame.minX) * sx, y: (rect.minY - frame.minY) * sy,
            width: rect.width * sx, height: rect.height * sy)
        let clipped = r.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        return clipped.isNull || clipped.isEmpty ? nil : clipped
    }

    /// The close-up: up to `side` pixels of `full` at full resolution, centred on `rect` (global
    /// points) and kept inside `fileRect`, so nothing outside the window the model was shown can
    /// appear in it. Nil when it wouldn't add detail (the file is within `minGain` of full
    /// resolution) or `rect` isn't in `fileRect`.
    public func detail(around rect: CGRect, side: Int = 512, minGain: Double = 1.5,
                       options: ScreenshotOptions = ScreenshotOptions(maxLongEdge: nil, format: .jpeg(quality: 0.8)))
        -> ScreenshotDetail? {
        guard fileWidth > 0, displayFrame.width > 0, displayFrame.height > 0, rect.intersects(fileRect),
              let area = fileArea(), Double(area.width) / Double(fileWidth) > minGain else { return nil }
        let sx = Double(full.width) / displayFrame.width, sy = Double(full.height) / displayFrame.height
        let originX = ((fileRect.minX - displayFrame.minX) * sx).rounded(), originY = ((fileRect.minY - displayFrame.minY) * sy).rounded()
        let w = min(side, area.width), h = min(side, area.height)
        let cx = (rect.midX - displayFrame.minX) * sx - originX, cy = (rect.midY - displayFrame.minY) * sy - originY
        let x = min(max(0, Int((cx - Double(w) / 2).rounded())), area.width - w)
        let y = min(max(0, Int((cy - Double(h) / 2).rounded())), area.height - h)
        guard let crop = area.cropping(to: CGRect(x: x, y: y, width: w, height: h)),
              let data = try? ImageFile.data(crop, options: options) else { return nil }
        let shown = CGRect(x: displayFrame.minX + (originX + Double(x)) / sx, y: displayFrame.minY + (originY + Double(y)) / sy,
                           width: Double(w) / sx, height: Double(h) / sy)
        return ScreenshotDetail(data: data, rect: shown, width: w, height: h)
    }

    /// `fileRect`'s pixels of `full`. `fileRect` came from whole pixels, so mapping it back rounds
    /// to the nearest pixel: snapping outward again could add a column a scaled display's float
    /// error put a hair over the edge.
    func fileArea() -> CGImage? {
        guard displayFrame.width > 0, displayFrame.height > 0 else { return nil }
        let sx = Double(full.width) / displayFrame.width, sy = Double(full.height) / displayFrame.height
        let minX = ((fileRect.minX - displayFrame.minX) * sx).rounded(), maxX = ((fileRect.maxX - displayFrame.minX) * sx).rounded()
        let minY = ((fileRect.minY - displayFrame.minY) * sy).rounded(), maxY = ((fileRect.maxY - displayFrame.minY) * sy).rounded()
        return full.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
    }

    /// What the model was sent (`fileRect` of `full`) in colour at the model image's size
    /// (`maxLongEdge`), to tell whether it changed since a session's last image. Its frame is
    /// `fileRect`, so another window, a moved one, or a full-display image never compares equal to
    /// a window image. About 20 ms; run it off the main actor.
    public func fingerprint(maxLongEdge: Int = ScreenshotOptions.model.maxLongEdge ?? 1280) -> ScreenFingerprint? {
        let (area, rect) = fileRect == displayFrame ? (full, displayFrame) : (fileArea() ?? full, fileRect)
        let longEdge = max(area.width, area.height)
        let f = min(1, Double(maxLongEdge) / Double(max(1, longEdge)))
        let width = max(1, Int((Double(area.width) * f).rounded()))
        let height = max(1, Int((Double(area.height) * f).rounded()))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            ctx.interpolationQuality = .medium
            // A bitmap context's first row is the image's top row, like global points.
            ctx.draw(area, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? ScreenFingerprint(displayID: displayID, frame: rect, width: width, height: height,
                                         pixels: pixels) : nil
    }

    /// `backdrop` as the overlay's `DisplaySnapshot`, for `overlay.showAnswer(_:anchor:snapshot:)`.
    public func displaySnapshot(pointScale: Double = 0.25) -> DisplaySnapshot? {
        backdrop(pointScale: pointScale).map {
            DisplaySnapshot(image: $0, displayID: displayID, frame: displayFrame, scale: pointScale)
        }
    }

    /// A small in-memory copy of the whole display for backdrop brightness: `pointScale` pixels
    /// per point (0.25 gives 378×246 for a 1512×982 pt display). Made from `full`, so it needs no
    /// second capture and, like `full`, has no Lumi or blocked-app windows in it.
    public func backdrop(pointScale: Double = 0.25) -> CGImage? {
        let width = max(1, Int((displayFrame.width * pointScale).rounded()))
        let height = max(1, Int((displayFrame.height * pointScale).rounded()))
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(full, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    /// A crop of `full` around a global-points rect with `padding` points on each side, encoded
    /// per `options` (e.g. a 512 px JPEG of the selection for the model). Nil if off this display.
    public func crop(
        aroundGlobal rect: CGRect, padding: Double = 40, options: ScreenshotOptions
    ) throws(ScreenshotError) -> Data? {
        guard let px = fullPixels(ofGlobal: rect.insetBy(dx: -padding, dy: -padding)),
              let cropped = full.cropping(to: px.integral) else { return nil }
        return try ImageFile.data(cropped, options: options)
    }
}

/// The close-up sent beside the model's image.
public struct ScreenshotDetail: Sendable, Equatable {
    /// JPEG bytes.
    public let data: Data
    /// What it shows, in global points.
    public let rect: CGRect
    public let width: Int
    public let height: Int

    public init(data: Data, rect: CGRect, width: Int, height: Int) {
        self.data = data
        self.rect = rect
        self.width = width
        self.height = height
    }
}

/// Which part of the display the model's image shows.
public enum ModelRegion {
    /// Smaller than this (points, either side) is a palette or popover, not the thing asked about.
    public static let minSide: Double = 200

    /// What the region is chosen from: the front window and the pointer, in global points.
    public struct Focus: Sendable, Equatable {
        public var window: CGRect
        public var cursor: CGPoint?
        /// The selected text, from AX only (never OCR or a guess): the close-up's centre. A bare
        /// caret gives none: the selection sensor reports no selection without text.
        public var detail: CGRect?

        public init(window: CGRect, cursor: CGPoint?, detail: CGRect? = nil) {
            self.window = window
            self.cursor = cursor
            self.detail = detail
        }
    }

    /// The packet's front window and pointer. Only a built packet has them, and a blocked front app
    /// never gets one, so the region is only ever a non-blocked app's window.
    public static func focus(in packet: ContextPacket) -> Focus? {
        guard let b = packet.window?.bounds else { return nil }
        let window = CGRect(x: b.x, y: b.y, width: b.width, height: b.height)
        var detail: CGRect?
        if let s = packet.selection, let r = s.bounds, s.boundsSource == .axRange || s.boundsSource == .axTextMarker {
            let rect = CGRect(x: r.x, y: r.y, width: r.width, height: r.height)
            detail = rect.intersects(window) ? rect : nil
        }
        return Focus(window: window, cursor: packet.cursor.map { CGPoint(x: $0.x, y: $0.y) }, detail: detail)
    }

    /// The front window (global points), so its text is legible on a large display; nil, for the
    /// whole display, when there's no window, the pointer is outside it (the question may be about
    /// what it points at in another window), it's tiny, or less than a quarter of it is on the
    /// captured display. The caller passes only a non-blocked front app's window (`focus(in:)`).
    public static func choose(window: CGRect?, cursor: CGPoint?, display: CGRect) -> CGRect? {
        guard let window, !window.isNull, window.width >= minSide, window.height >= minSide else { return nil }
        if let cursor, !window.contains(cursor) { return nil }
        let visible = window.intersection(display)
        guard !visible.isNull, visible.width * visible.height >= window.width * window.height / 4 else { return nil }
        return visible
    }
}

/// Takes the summon screenshot while the user speaks (not part of the packet's 200 ms budget).
/// Real: `ScreenCaptureKitShooter`. Fake: `FakeScreenshotter`.
public protocol Screenshotter: Sendable {
    /// Captures `displayID` (or the main display) without our own windows or any blocked app's
    /// windows, and writes the file per `options`: only `region` (global points, the front
    /// window) when given and on that display, else the whole display. `full` is always the whole
    /// display.
    func capture(
        displayID: UInt32?, blocklist: Blocklist, options: ScreenshotOptions, region: CGRect?
    ) async throws(ScreenshotError) -> Screenshot
}

extension Screenshotter {
    /// The whole display.
    public func capture(
        displayID: UInt32?, blocklist: Blocklist, options: ScreenshotOptions
    ) async throws(ScreenshotError) -> Screenshot {
        try await capture(displayID: displayID, blocklist: blocklist, options: options, region: nil)
    }
}

public struct ScreenCaptureKitShooter: Screenshotter {
    public let store: ScreenshotStore

    public init(store: ScreenshotStore = ScreenshotStore()) {
        self.store = store
    }

    public func capture(
        displayID: UInt32?, blocklist: Blocklist, options: ScreenshotOptions = .model, region: CGRect? = nil
    ) async throws(ScreenshotError) -> Screenshot {
        // Preflight so a missing grant fails cleanly instead of prompting mid-question.
        guard CGPreflightScreenCaptureAccess() else { throw .screenRecordingNotGranted }
        let url = store.newFileURL(extension: options.fileExtension)
        do {
            // All windows, not just on-screen ones: a blocked app with no window now (1Password
            // Quick Access, the Passwords menu bar popover) can open one before the capture.
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let target = displayID ?? CGMainDisplayID()
            guard let display = content.displays.first(where: { $0.displayID == target }) else {
                throw ScreenshotError.displayNotFound
            }
            let ownPID = getpid()
            let excluded = content.applications.filter {
                $0.processID == ownPID || blocklist.isBlocked(bundleID: $0.bundleIdentifier)
            }
            let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
            let config = SCScreenshotConfiguration()
            config.showsCursor = false
            // On macOS 26.6 a configured fileURL is ignored (5 of 5 live runs: no file and a nil
            // output.fileURL), so encode the SDR image ourselves.
            let output = try await SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: config)
            guard let image = output.sdrImage else { throw ScreenshotError.captureFailed("no image") }
            let displayFrame = CGDisplayBounds(display.displayID)
            let area = Screenshot.modelArea(of: image, displayFrame: displayFrame, region: region)
            // Encode once in memory, then write those bytes, so the file and fileData match.
            let encoded = try ImageFile.data(area.image, options: options)
            let (_, width, height) = ImageFile.properties(for: area.image, options)
            do {
                try encoded.write(to: url, options: .atomic)
            } catch {
                try? FileManager.default.removeItem(at: url)
                throw ScreenshotError.captureFailed("write failed: \(error.localizedDescription)")
            }
            store.sweep()
            return Screenshot(
                file: url, fileData: encoded, fileWidth: width, fileHeight: height, full: image,
                displayID: display.displayID, scale: Double(image.width) / Double(max(display.width, 1)),
                displayFrame: displayFrame, fileRect: area.rect)
        } catch let error as ScreenshotError {
            throw error
        } catch let error as SCStreamError where error.code == .userDeclined {
            // The preflight can say yes while ScreenCaptureKit refuses (a revoked grant).
            throw .screenRecordingNotGranted
        } catch {
            throw .captureFailed(String(describing: error))
        }
    }
}

/// Where screenshots live and how long (up to 24 h).
public struct ScreenshotStore: Sendable {
    /// The largest allowed size, and the default.
    public static let retention: TimeInterval = 24 * 60 * 60

    public let directory: URL
    /// How long screenshots are kept, read at each sweep (Settings › Privacy can shorten it).
    /// Capped at `ScreenshotStore.retention`.
    public let retention: @Sendable () -> TimeInterval

    public init(directory: URL = ScreenshotStore.defaultDirectory,
                retention: @escaping @Sendable () -> TimeInterval = { ScreenshotStore.retention }) {
        self.directory = directory
        self.retention = retention
    }

    public static var defaultDirectory: URL {
        BuddyCore.paths.screenshots
    }

    func newFileURL(extension ext: String = "png", now: Date = Date()) -> URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ms = Int64(now.timeIntervalSince1970 * 1000)
        return directory.appending(path: "\(ms)-\(UUID().uuidString.prefix(8)).\(ext)")
    }

    static let extensions: Set<String> = ["png", "jpg"]

    /// Runs `sweep` now and then every `interval` until the task is cancelled. The shell keeps
    /// the task for the app's lifetime, so old files go even when nothing is captured.
    public func startPeriodicSweep(every interval: Duration = .seconds(3600)) -> Task<Void, Never> {
        let store = self
        return Task.detached(priority: .background) {
            while !Task.isCancelled {
                store.sweep()
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Deletes screenshots older than the retention. Run at launch, after each capture and
    /// periodically (`startPeriodicSweep`).
    /// Returns how many files were removed.
    @discardableResult
    public func sweep(now: Date = Date()) -> Int {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
        else { return 0 }
        var removed = 0
        let keep = min(retention(), Self.retention)
        for file in files where Self.extensions.contains(file.pathExtension) {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, now.timeIntervalSince(modified) > keep, (try? fm.removeItem(at: file)) != nil {
                removed += 1
            }
        }
        return removed
    }
}

enum ImageFile {
    /// Encodes in memory (for inline base64), per `options`.
    static func data(_ image: CGImage, options: ScreenshotOptions) throws(ScreenshotError) -> Data {
        let out = NSMutableData()
        let type: UTType = if case .png = options.format { .png } else { .jpeg }
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, type.identifier as CFString, 1, nil)
        else { throw .captureFailed("cannot create encoder") }
        CGImageDestinationAddImage(dest, image, properties(for: image, options).props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw .captureFailed("encode failed") }
        return out as Data
    }

    static func properties(
        for image: CGImage, _ options: ScreenshotOptions
    ) -> (props: [CFString: Any], width: Int, height: Int) {
        var props: [CFString: Any] = [:]
        if case .jpeg(let quality) = options.format {
            props[kCGImageDestinationLossyCompressionQuality] = min(max(quality, 0), 1)
        }
        let longEdge = max(image.width, image.height)
        guard let maxEdge = options.maxLongEdge, maxEdge < longEdge else { return (props, image.width, image.height) }
        props[kCGImageDestinationImageMaxPixelSize] = maxEdge
        let f = Double(maxEdge) / Double(longEdge)
        return (props, Int((Double(image.width) * f).rounded()), Int((Double(image.height) * f).rounded()))
    }

    /// Encodes `image` per `options`, downscaling while encoding. Returns the written pixel size.
    @discardableResult
    static func write(
        _ image: CGImage, to url: URL, options: ScreenshotOptions
    ) throws(ScreenshotError) -> (width: Int, height: Int) {
        let type: UTType = if case .png = options.format { .png } else { .jpeg }
        let (props, width, height) = properties(for: image, options)
        let size = (width: width, height: height)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)
        else { throw .captureFailed("cannot create \(url.lastPathComponent)") }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw .captureFailed("encode failed") }
        return size
    }
}
