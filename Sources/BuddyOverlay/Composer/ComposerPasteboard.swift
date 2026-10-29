import AppKit
import BuddyCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What a ⌘V or a drop brings into the composer (61-COMPOSER §4).
nonisolated public enum ComposerPaste: Sendable, Equatable {
    /// Copied or dropped files and folders: pictures attach, the rest become `@path`.
    case files([URL])
    /// Picture data (a screenshot copied with ⌃⇧⌘4, "Copy Image" in a browser), already written
    /// to PNG files.
    case images([URL])
    case text(String)
    case nothing
}

@MainActor
public enum ComposerPasteboard {
    /// The pasteboard's content, most specific first: file URLs, then picture data (unless it
    /// comes with real text, as rich text from Pages or Excel does), then plain text.
    public static func read(_ pb: NSPasteboard, into folder: URL = BuddyCore.paths.pastedImages) -> ComposerPaste {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return .files(urls)
        }
        let text = pb.string(forType: .string)
        let pictures = (pb.pasteboardItems ?? []).compactMap(picture)
        if !pictures.isEmpty, text.map(isJustALink) ?? true {
            let written = pictures.compactMap { try? ComposerImages.writePNG($0, in: folder) }
            if !written.isEmpty { return .images(written) }
        }
        if let text, !text.isEmpty { return .text(text) }
        return .nothing
    }

    /// Bitmap data on one item (PNG, TIFF, JPEG, HEIC…), not PDF: a PDF rendition rides along
    /// with copied text and shapes, and isn't what the user meant as a picture.
    private static func picture(_ item: NSPasteboardItem) -> Data? {
        for type in item.types {
            guard let ut = UTType(type.rawValue), ut.conforms(to: .image), !ut.conforms(to: .pdf) else { continue }
            if let data = item.data(forType: type) { return data }
        }
        return nil
    }

    /// "Copy Image" in a browser also puts the image's address as text.
    static func isJustALink(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || (!t.contains(where: \.isWhitespace) && (t.hasPrefix("http://") || t.hasPrefix("https://") || t.hasPrefix("data:")))
    }
}

nonisolated public enum ComposerImages {
    /// Writes `data` (any bitmap ImageIO reads) as a PNG in `folder`, and clears out week-old ones.
    public static func writePNG(_ data: Data, in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        prune(folder, olderThan: 7 * 24 * 3600)
        // Short, so the token shows the name ("Image 3F2A.png"), and never over another paste.
        var url: URL
        repeat { url = folder.appending(path: "Image \(UUID().uuidString.prefix(4)).png") } while FileManager.default.fileExists(atPath: url.path)
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            try data.write(to: url)
            return url
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    private static func prune(_ folder: URL, olderThan age: TimeInterval) {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-age)
        for url in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, date < cutoff {
                try? fm.removeItem(at: url)
            }
        }
    }

    /// A small PNG thumbnail (64 px on the long edge, for a 22 pt token at 2×), off the caller's actor.
    @concurrent
    public static func thumbnail(_ url: URL, maxPixels: Int = 64) async -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixels]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}
