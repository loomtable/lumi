import Accelerate
import BuddyCore
import CoreGraphics
import Vision

/// Density of edges (text, controls, borders) in a snapshot, with O(1) rect queries.
/// Edge density suits UI screens better than photo saliency.
nonisolated struct EdgeMap: Sendable {
    let width: Int
    let height: Int
    /// (width+1) × (height+1) integral image of edge pixels, row 0 = top.
    let integral: [UInt32]

    /// Fraction (0...1) of edge pixels inside `r`, given in image pixels, top-left origin.
    func density(_ r: CGRect) -> Double {
        let x0 = clamp(Int(r.minX.rounded(.down)), width), x1 = clamp(Int(r.maxX.rounded(.up)), width)
        let y0 = clamp(Int(r.minY.rounded(.down)), height), y1 = clamp(Int(r.maxY.rounded(.up)), height)
        guard x1 > x0, y1 > y0 else { return 0 }
        let w = width + 1
        let sum = integral[y1 * w + x1] &- integral[y0 * w + x1] &- integral[y1 * w + x0] &+ integral[y0 * w + x0]
        return Double(sum) / Double((x1 - x0) * (y1 - y0))
    }

    private func clamp(_ v: Int, _ m: Int) -> Int { max(0, min(m, v)) }

    /// Sobel magnitude above `threshold`, fused with the integral pass. About 1–2 ms for a
    /// quarter-size capture on Apple Silicon.
    static func make(_ image: CGImage, threshold: Int32 = 48) throws -> EdgeMap {
        var format = vImage_CGImageFormat(bitsPerComponent: 8, bitsPerPixel: 8,
                                          colorSpace: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue))!
        let gray = try vImage.PixelBuffer(cgImage: image, cgImageFormat: &format, pixelFormat: vImage.Planar8.self)
        let w = gray.width, h = gray.height, stride = gray.rowStride, iw = w + 1
        var ii = [UInt32](repeating: 0, count: iw * (h + 1))
        gray.withUnsafeBufferPointer { g in
            ii.withUnsafeMutableBufferPointer { out in
                for y in 0..<h {
                    var run: UInt32 = 0
                    let above = max(y - 1, 0) * stride, row = y * stride, below = min(y + 1, h - 1) * stride
                    for x in 0..<w {
                        let l = max(x - 1, 0), r = min(x + 1, w - 1)
                        func p(_ base: Int, _ col: Int) -> Int32 { Int32(g[base + col]) }
                        let gx = p(above, r) + 2 * p(row, r) + p(below, r) - p(above, l) - 2 * p(row, l) - p(below, l)
                        let gy = p(below, l) + 2 * p(below, x) + p(below, r) - p(above, l) - 2 * p(above, x) - p(above, r)
                        run &+= (abs(gx) + abs(gy)) > threshold ? 1 : 0
                        out[(y + 1) * iw + x + 1] = out[y * iw + x + 1] &+ run
                    }
                }
            }
        }
        return EdgeMap(width: w, height: h, integral: ii)
    }
}

/// Vision attention saliency as a 68×68 grid with O(1) rect means.
nonisolated struct SaliencyGrid: Sendable {
    let width: Int
    let height: Int
    let integral: [Float]

    /// Mean saliency (0...1) inside `r`, in pixels of an image of `size`, top-left origin.
    func mean(_ r: CGRect, imageSize size: CGSize) -> Double {
        let sx = CGFloat(width) / size.width, sy = CGFloat(height) / size.height
        func c(_ v: CGFloat, _ m: Int) -> Int { max(0, min(m, Int(v))) }
        let x0 = c((r.minX * sx).rounded(.down), width), x1 = c((r.maxX * sx).rounded(.up), width)
        let y0 = c((r.minY * sy).rounded(.down), height), y1 = c((r.maxY * sy).rounded(.up), height)
        guard x1 > x0, y1 > y0 else { return 0 }
        let w = width + 1
        let sum = integral[y1 * w + x1] - integral[y0 * w + x1] - integral[y1 * w + x0] + integral[y0 * w + x0]
        return Double(sum) / Double((x1 - x0) * (y1 - y0))
    }

    /// Legacy request for raw, stride-aware access to the heat map (row 0 = top). The
    /// Swift `pixel(at:)` accessor is slow and traps at 1.0.
    static func make(_ image: CGImage) throws -> SaliencyGrid {
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        try VNImageRequestHandler(cgImage: image).perform([request])
        guard let pb = request.results?.first?.pixelBuffer else { throw CocoaError(.featureUnsupported) }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), iw = w + 1
        let stride = CVPixelBufferGetBytesPerRow(pb) / MemoryLayout<Float>.size
        guard let base = CVPixelBufferGetBaseAddress(pb) else { throw CocoaError(.featureUnsupported) }
        let f = base.assumingMemoryBound(to: Float.self)
        var ii = [Float](repeating: 0, count: iw * (h + 1))
        for y in 0..<h {
            var run: Float = 0
            for x in 0..<w {
                run += f[y * stride + x]
                ii[(y + 1) * iw + x + 1] = ii[y * iw + x + 1] + run
            }
        }
        return SaliencyGrid(width: w, height: h, integral: ii)
    }
}

/// Smart placement: score 8 candidate rectangles by how much on-screen
/// content they would cover, and take the cheapest that fits.
nonisolated enum SmartPlacement {
    /// What a candidate costs beyond the content it covers, so the plain order (below, then
    /// above, then the sides) still wins unless it would cover clearly more content.
    static let sidePenalty = 0.10
    static let alignmentPenalty = 0.02
    /// Saliency's weight when it is available; edge density carries the rest.
    static let saliencyWeight = 0.4

    struct Scores: Sendable {
        let edges: EdgeMap?
        let saliency: SaliencyGrid?
        let snapshot: DisplaySnapshot
    }

    /// Off the main actor: both maps for one snapshot.
    @concurrent static func scores(for snapshot: DisplaySnapshot, withSaliency: Bool) async -> Scores {
        async let edges = try? EdgeMap.make(snapshot.image)
        async let saliency = withSaliency ? try? SaliencyGrid.make(snapshot.image) : nil
        return await Scores(edges: edges, saliency: saliency, snapshot: snapshot)
    }

    /// Loads the saliency model (about 40 ms the first time, measured) so later calls take ~4 ms.
    @concurrent static func prewarm() async {
        let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        if let image = ctx?.makeImage() { _ = try? SaliencyGrid.make(image) }
    }

    /// Content cost (0...1) of a global top-left rect.
    static func cost(_ globalRect: CGRect, _ s: Scores) -> Double {
        let snap = s.snapshot
        let r = CGRect(x: (globalRect.minX - snap.frame.minX) * snap.scale,
                       y: (globalRect.minY - snap.frame.minY) * snap.scale,
                       width: globalRect.width * snap.scale, height: globalRect.height * snap.scale)
        let size = CGSize(width: snap.image.width, height: snap.image.height)
        let edge = s.edges?.density(r)
        let sal = s.saliency?.mean(r, imageSize: size)
        switch (edge, sal) {
        case let (e?, v?): return (1 - saliencyWeight) * e + saliencyWeight * min(v * 2, 1)
        case let (e?, nil): return e
        case let (nil, v?): return min(v * 2, 1)
        case (nil, nil): return 0
        }
    }

    /// The 8 next-to-anchor candidates in plain order: below (centred, shifted right, shifted
    /// left), above (the same three), trailing side, leading side. The shifted ones move only
    /// as far as keeps the tail on the anchor's centre clear of the rounded corner.
    static func anchoredCandidates(size: CGSize, anchor: CGRect, in area: CGRect) -> [(PlacementEdge, Int, CGRect)] {
        let g = Placer.gap
        let belowY = anchor.maxY + g, aboveY = anchor.minY - g - size.height
        let lo = Tokens.cardRadius + Placer.tailHalfWidth
        let xs = [anchor.midX - size.width / 2, anchor.midX - lo, anchor.midX - size.width + lo]
        var out: [(PlacementEdge, Int, CGRect)] = []
        for (i, x) in xs.enumerated() { out.append((.below, i, CGRect(x: x, y: belowY, width: size.width, height: size.height))) }
        for (i, x) in xs.enumerated() { out.append((.above, i, CGRect(x: x, y: aboveY, width: size.width, height: size.height))) }
        let sideY = anchor.midY - size.height / 2
        out.append((.trailing, 0, CGRect(x: anchor.maxX + g, y: sideY, width: size.width, height: size.height)))
        out.append((.leading, 0, CGRect(x: anchor.minX - g - size.width, y: sideY, width: size.width, height: size.height)))
        return out.map { e, i, r in (e, i, Placer.slideAlongEdge(r, edge: e, in: area)) }
    }

    /// Next to the anchor, avoiding content. Falls back to the plain rule when nothing
    /// fits or there are no scores.
    static func placeNextTo(size: CGSize, anchor: Anchor, in bounds: CGRect, style: Placer.Style,
                            scores: Scores?) -> Placement {
        let plain = Placer.place(size: size, anchor: anchor, in: bounds, style: style)
        guard let scores else { return plain }
        let area = bounds.insetBy(dx: Placer.edgeMargin, dy: Placer.edgeMargin)
        let a = anchor.rect
        let sides: [PlacementEdge] = [.below, .above, .trailing, .leading]
        let fitting = anchoredCandidates(size: size, anchor: a, in: area).filter { area.contains($0.2) }
        guard let best = fitting.min(by: { lhs, rhs in
            total(lhs, sides, scores) < total(rhs, sides, scores)
        }) else { return plain }
        return Placer.finish(best.2, edge: best.0, anchor: a, style: style, cornerRadius: Tokens.cardRadius, avoids: true)
    }

    private static func total(_ c: (PlacementEdge, Int, CGRect), _ sides: [PlacementEdge], _ s: Scores) -> Double {
        cost(c.2, s) + sidePenalty * Double(sides.firstIndex(of: c.0) ?? 0) + alignmentPenalty * Double(c.1)
    }

    /// Whole-page answers (no anchor): the emptiest of 8 regions (corners and edge
    /// middles of the display), with no tail.
    static func placeOnPage(size: CGSize, in bounds: CGRect, scores: Scores?) -> Placement {
        let area = bounds.insetBy(dx: Placer.edgeMargin, dy: Placer.edgeMargin)
        let w = min(size.width, area.width), h = min(size.height, area.height)
        let xs = [area.minX, area.midX - w / 2, area.maxX - w]
        let ys = [area.minY, area.midY - h / 2, area.maxY - h]
        var rects: [CGRect] = []
        for y in ys { for x in xs where !(x == xs[1] && y == ys[1]) { rects.append(CGRect(x: x, y: y, width: w, height: h)) } }
        // Without scores, prefer the trailing middle: off the reading column, near the eye line.
        let fallback = CGRect(x: xs[2], y: ys[1], width: w, height: h)
        let pick = scores.flatMap { s in rects.min { cost($0, s) < cost($1, s) } } ?? fallback
        return Placement(frame: pick.integral, edge: .centered, tailOffset: nil, avoidsAnchor: true)
    }
}
