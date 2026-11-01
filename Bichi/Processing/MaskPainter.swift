import CoreGraphics
import CoreImage

/// A user brush stroke on the "区域微调" screen.
/// Points are normalised image coordinates with a bottom-left origin
/// (same convention as Vision and Core Image); `radius` is a fraction of the
/// image width.
struct BrushStroke: Equatable, Codable {
    enum Mode: String, Codable { case add, erase }
    var region: RetouchRegion
    var mode: Mode
    var radius: Double
    var points: [CGPoint]
}

/// Rasterises soft region priors and brush strokes into grayscale masks.
enum MaskPainter {
    struct SoftEllipse {
        var center: CGPoint      // normalised, bottom-left origin
        var radii: CGSize        // normalised to image width
        var angle: CGFloat = 0   // radians
        var intensity: CGFloat = 1
        var subtract = false
    }

    static func render(_ shapes: [SoftEllipse], size: CGSize) -> CIImage {
        draw(size: size) { ctx in
            for s in shapes {
                ctx.saveGState()
                ctx.setBlendMode(s.subtract ? .multiply : .lighten)
                ctx.translateBy(x: s.center.x * size.width, y: s.center.y * size.height)
                ctx.rotate(by: s.angle)
                ctx.scaleBy(x: s.radii.width * size.width, y: s.radii.height * size.width)
                ctx.drawRadialGradient(
                    softGradient(intensity: s.intensity, inverted: s.subtract),
                    startCenter: .zero, startRadius: 0,
                    endCenter: .zero, endRadius: 1, options: []
                )
                ctx.restoreGState()
            }
        }
    }

    /// Combines an automatic mask with the user's strokes for one region:
    /// `max(auto, added) · (1 − erased)`. Strokes are replayed in order on
    /// both layers so a later erase beats an earlier add and vice versa.
    static func apply(_ strokes: [BrushStroke], region: RetouchRegion, to auto: CIImage, size: CGSize) -> CIImage {
        let mine = strokes.filter { $0.region == region }
        guard !mine.isEmpty else { return auto }
        let added = draw(size: size) { ctx in replay(mine, positive: .add, in: ctx, size: size) }
        let erased = draw(size: size) { ctx in replay(mine, positive: .erase, in: ctx, size: size) }
        let unioned = auto.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: added])
        let keep = erased.applyingFilter("CIColorInvert")
        return unioned.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: keep])
            .cropped(to: CGRect(origin: .zero, size: size))
    }

    private static func replay(_ strokes: [BrushStroke], positive: BrushStroke.Mode, in ctx: CGContext, size: CGSize) {
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for s in strokes {
            let paint = s.mode == positive
            ctx.setStrokeColor(gray: paint ? 1 : 0, alpha: 1)
            ctx.setLineWidth(s.radius * 2 * size.width)
            // Soft edge, so a stroke blends into the auto mask.
            ctx.setShadow(offset: .zero, blur: s.radius * size.width * 0.6, color: CGColor(gray: paint ? 1 : 0, alpha: 1))
            let pts = s.points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
            guard let first = pts.first else { continue }
            ctx.beginPath()
            ctx.move(to: first)
            if pts.count == 1 { ctx.addLine(to: first) }
            for p in pts.dropFirst() { ctx.addLine(to: p) }
            ctx.strokePath()
        }
    }

    /// Bright centre fading to 0 at radius 1. Inverted (for `.multiply`), the
    /// centre goes to `1 − intensity` and the edge to 1, i.e. no change.
    private static func softGradient(intensity: CGFloat, inverted: Bool) -> CGGradient {
        let space = CGColorSpaceCreateDeviceGray()
        let levels: [CGFloat] = [intensity, intensity * 0.85, intensity * 0.35, 0].map { inverted ? 1 - $0 : $0 }
        let comps: [CGFloat] = levels.flatMap { level -> [CGFloat] in [level, 1] }
        return CGGradient(colorSpace: space, colorComponents: comps, locations: [0, 0.45, 0.8, 1], count: 4)!
    }

    private static func draw(size: CGSize, _ body: (CGContext) -> Void) -> CIImage {
        let w = max(Int(size.width.rounded()), 1), h = max(Int(size.height.rounded()), 1)
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: w, height: h)) }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        body(ctx)
        guard let cg = ctx.makeImage() else { return CIImage.empty() }
        // Masks are data, not colour: skip colour management so 0.5 stays 0.5.
        return CIImage(cgImage: cg, options: [.colorSpace: NSNull()])
    }
}
