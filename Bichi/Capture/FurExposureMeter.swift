import CoreGraphics
import Foundation
import CoreVideo
import simd

/// Highlight statistics of the dog's fur in one preview frame.
struct FurFrameStats: Equatable {
    /// Share of fur pixels at the top of the range (luma ≥ 250/255).
    var clippedFraction: Float
    /// 95th percentile luma of fur pixels, 0...1 (gamma-encoded).
    var p95: Float
    /// Mean RGB of the brightest fur pixels, linearised; used to set white balance.
    var brightFurRGB: SIMD3<Float>
    var sampleCount: Int
}

/// Decides how far to push exposure bias so white fur keeps detail.
/// Pure logic so it can be tested without a camera.
struct FurExposureController {
    var bias: Float = 0
    var minBias: Float = -2.0
    var maxBias: Float = 0.5

    /// Fur is "blown" if more than this share is clipped.
    static let clipLimit: Float = 0.015
    /// Below this p95 the fur looks grey; allow raising exposure again.
    static let dimLimit: Float = 0.86

    mutating func update(with s: FurFrameStats) -> Float {
        guard s.sampleCount > 200 else { return bias }
        if s.clippedFraction > Self.clipLimit {
            // Step harder the more is blown.
            bias -= min(0.1 + s.clippedFraction * 2, 0.33)
        } else if s.p95 < Self.dimLimit && s.clippedFraction < Self.clipLimit / 3 {
            bias += 0.05
        }
        bias = min(max(bias, minBias), maxBias)
        return bias
    }
}

enum FurFrameSampler {
    /// Samples a 4:2:0 full-range bi-planar buffer inside `box`
    /// (normalised, top-left origin, in *buffer* orientation).
    static func stats(_ buffer: CVPixelBuffer, box: CGRect, stride step: Int = 4) -> FurFrameStats? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferGetPlaneCount(buffer) >= 2,
              let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let cBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return nil }
        let w = CVPixelBufferGetWidthOfPlane(buffer, 0), h = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let yRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0), cRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let yp = yBase.assumingMemoryBound(to: UInt8.self), cp = cBase.assumingMemoryBound(to: UInt8.self)

        let x0 = max(Int(box.minX * CGFloat(w)), 0), x1 = min(Int(box.maxX * CGFloat(w)), w)
        let y0 = max(Int(box.minY * CGFloat(h)), 0), y1 = min(Int(box.maxY * CGFloat(h)), h)
        guard x1 > x0, y1 > y0 else { return nil }

        var hist = [Int](repeating: 0, count: 256)
        var fur = 0, clipped = 0
        var bright = SIMD3<Float>(repeating: 0), brightN: Float = 0
        for y in Swift.stride(from: y0, to: y1, by: step) {
            for x in Swift.stride(from: x0, to: x1, by: step) {
                let luma = Int(yp[y * yRow + x])
                // White-fur candidates only: bright pixels. Background and eyes are ignored.
                guard luma >= 150 else { continue }
                fur += 1
                hist[luma] += 1
                if luma >= 250 { clipped += 1 }
                if luma >= 200 && luma < 250 {
                    let ci = (y / 2) * cRow + (x / 2) * 2
                    let cb = Float(cp[ci]) - 128, cr = Float(cp[ci + 1]) - 128
                    let yf = Float(luma)
                    let rgb = SIMD3<Float>(yf + 1.5748 * cr, yf - 0.1873 * cb - 0.4681 * cr, yf + 1.8556 * cb) / 255
                    bright += componentPow(simd_clamp(rgb, .zero, .one), 2.2)
                    brightN += 1
                }
            }
        }
        guard fur > 0 else { return nil }
        var acc = 0, p95 = 255
        let target = Int(Float(fur) * 0.95)
        for (v, n) in hist.enumerated() {
            acc += n
            if acc >= target { p95 = v; break }
        }
        return FurFrameStats(
            clippedFraction: Float(clipped) / Float(fur),
            p95: Float(p95) / 255,
            brightFurRGB: brightN > 0 ? bright / brightN : SIMD3(repeating: 1),
            sampleCount: fur
        )
    }
}

/// Coordinate conversions between Vision results on a portrait-oriented
/// preview frame and the camera's native (landscape-right) buffer space.
enum VisionGeometry {
    /// Vision point (normalised, bottom-left origin, in an image analysed
    /// with orientation `.right`) → buffer point (normalised, top-left origin).
    /// This is also the space `AVCaptureDevice.focusPointOfInterest` uses.
    static func bufferPoint(fromPortraitVision p: CGPoint) -> CGPoint {
        CGPoint(x: 1 - p.y, y: 1 - p.x)
    }

    static func bufferRect(fromPortraitVision r: CGRect) -> CGRect {
        let a = bufferPoint(fromPortraitVision: CGPoint(x: r.minX, y: r.minY))
        let b = bufferPoint(fromPortraitVision: CGPoint(x: r.maxX, y: r.maxY))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Vision point → portrait view point (normalised, top-left origin).
    static func viewPoint(fromPortraitVision p: CGPoint) -> CGPoint {
        CGPoint(x: p.x, y: 1 - p.y)
    }

    /// White-balance gains that would make `furRGB` neutral, starting from
    /// `current`. `damping` < 1 under-corrects so cream-coloured dogs keep
    /// some warmth. Result is normalised so the smallest gain is 1.
    static func neutralisingGains(furRGB: SIMD3<Float>, current: SIMD3<Float>, maxGain: Float, damping: Float = 0.8) -> SIMD3<Float> {
        let g = max(furRGB.y, 1e-4)
        let corr = SIMD3<Float>(g / max(furRGB.x, 1e-4), 1, g / max(furRGB.z, 1e-4))
        var gains = current * componentPow(corr, damping)
        gains /= gains.min()
        return simd_clamp(gains, SIMD3(repeating: 1), SIMD3(repeating: maxGain))
    }
}

private func componentPow(_ v: SIMD3<Float>, _ e: Float) -> SIMD3<Float> {
    SIMD3(pow(v.x, e), pow(v.y, e), pow(v.z, e))
}
