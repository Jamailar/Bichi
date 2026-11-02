import CoreImage
import XCTest
import simd
@testable import Bichi

/// Runs the real Metal Core Image kernels on a synthetic "white fur with a
/// tear stain" image. Verifies behaviour, not looks: real-photo quality still
/// has to be judged on device.
final class FurProcessorTests: XCTestCase {
    let size = 128
    let context = CIContext(options: [.workingFormat: CIFormat.RGBAf])
    let fur = SIMD3<Float>(0.66, 0.62, 0.55)
    let stain = SIMD3<Float>(0.42, 0.28, 0.17)
    let background = SIMD3<Float>(0.15, 0.10, 0.07)

    /// Left 3/4: fur with fine hair texture; a stain stripe in the middle;
    /// right quarter: brown floor that must stay untouched.
    /// `weakPatch` adds a faintly warm 6×6 patch far from the stain at (8…14, 8…14).
    func makeImage(weakPatch: Bool = false) -> CIImage {
        var px = [Float](repeating: 1, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let hair: Float = 1 + 0.12 * sin(Float(x) * 1.7 + Float(y) * 0.3)
                var c: SIMD3<Float>
                if x >= size * 3 / 4 { c = background }
                else if x >= 40 && x < 56 { c = stain * hair }
                else if weakPatch && (8..<14).contains(x) && (8..<14).contains(y) { c = fur * SIMD3(1.065, 1, 0.935) * hair }
                else { c = fur * hair }
                let i = (y * size + x) * 4
                px[i] = c.x; px[i + 1] = c.y; px[i + 2] = c.z; px[i + 3] = 1
            }
        }
        let data = px.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: data, bytesPerRow: size * 16, size: CGSize(width: size, height: size),
                       format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
    }

    func read(_ image: CIImage) -> [SIMD3<Float>] {
        var px = [Float](repeating: 0, count: size * size * 4)
        px.withUnsafeMutableBytes { buf in
            context.render(image, toBitmap: buf.baseAddress!, rowBytes: size * 16,
                           bounds: CGRect(x: 0, y: 0, width: size, height: size), format: .RGBAf, colorSpace: nil)
        }
        return (0..<(size * size)).map { SIMD3(px[$0 * 4], px[$0 * 4 + 1], px[$0 * 4 + 2]) }
    }

    func analysis(for image: CIImage) -> FurAnalysis {
        let rect = image.extent
        let black = CIImage(color: .black).cropped(to: rect)
        // The "dog" is the left three quarters.
        let subject = CIImage(color: .white)
            .cropped(to: CGRect(x: 0, y: 0, width: CGFloat(size * 3 / 4), height: CGFloat(size)))
            .composited(over: black)
        let ref = FurReference(chroma: ColorMath.chroma(fur), luma: ColorMath.luma(fur), warmthSigma: 0.03)
        let k = FurKernels.shared
        let furMask = k.furMask.apply(rect, [image, subject, ref.luma])
        let clean = k.cleanFurWeight.apply(rect, [image, subject, ref.chroma.ciVector, ref.luma, ref.warmthSigma])
        let tear = FurAnalyzer.stainMask(image, prior: subject, reference: ref, hue: ColorMath.tearHue, growRadius: 6)
        return FurAnalysis(
            size: rect.size, dogFound: true, landmarks: nil, subjectMask: subject, reference: ref,
            autoMasks: [.tear: tear, .mouth: black, .eyes: black, .fur: furMask],
            localFurLuma: FurAnalyzer.localFurLuma(image, weight: clean, reference: ref),
            suggestion: .none, tearSeverity: 1, mouthSeverity: 0, clippedFraction: 0
        )
    }

    func testStainMaskCoversStainAndDropsIsolatedWeakSpecks() {
        let img = makeImage(weakPatch: true)
        let mask = read(analysis(for: img).autoMasks[.tear]!)
        let row = size / 2
        for x in 44..<52 { XCTAssertGreaterThan(mask[row * size + x].x, 0.8, "stain x=\(x)") }
        XCTAssertLessThan(mask[row * size + 10].x, 0.05, "clean fur")
        // Faintly warm on its own, with no confident stain nearby: hysteresis drops it.
        XCTAssertLessThan(mask[11 * size + 11].x, 0.1, "weak isolated patch")
        XCTAssertLessThan(mask[row * size + 110].x, 0.01, "background")
    }

    func testKernelsLoad() {
        XCTAssertNotNil(FurKernels.shared)
    }

    func testTearStainIsRemovedTextureKeptBackgroundUntouched() {
        let img = makeImage()
        let before = read(img)
        var p = RetouchParameters.none
        p.tear = 1
        let after = read(FurProcessor.render(img, analysis: analysis(for: img), parameters: p))

        func warmth(_ c: SIMD3<Float>) -> Float { let k = ColorMath.chroma(c); return k.x - k.z }
        let row = size / 2
        let stainIdx = (40..<56).map { row * size + $0 }
        let meanWarmBefore = stainIdx.map { warmth(before[$0]) }.reduce(0, +) / Float(stainIdx.count)
        let meanWarmAfter = stainIdx.map { warmth(after[$0]) }.reduce(0, +) / Float(stainIdx.count)
        XCTAssertLessThan(meanWarmAfter, meanWarmBefore * 0.5, "stain should lose most of its red-brown")

        // Texture: neighbouring-hair luminance ratios are preserved.
        for x in 46..<51 {
            let i = row * size + x
            let rb = ColorMath.luma(before[i]) / ColorMath.luma(before[i - 1])
            let ra = ColorMath.luma(after[i]) / ColorMath.luma(after[i - 1])
            XCTAssertEqual(ra, rb, accuracy: 0.04)
        }

        // Clean fur and the brown floor stay as they were.
        for x in [10, 100, 120] {
            let i = row * size + x
            XCTAssertLessThan(simd_distance(before[i], after[i]), 0.01, "x=\(x) changed")
        }
    }

    func testWhitenNeutralisesFurButNotBackground() {
        let img = makeImage()
        let before = read(img)
        var p = RetouchParameters.none
        p.whiten = 1
        let after = read(FurProcessor.render(img, analysis: analysis(for: img), parameters: p))
        let furPx = after[(size / 2) * size + 10]
        let c = ColorMath.chroma(furPx)
        XCTAssertEqual(c.x - c.z, 0, accuracy: 0.05)
        let bg = (size / 2) * size + 120
        XCTAssertLessThan(simd_distance(before[bg], after[bg]), 0.01)
    }

    func testEraseStrokeRemovesRegion() {
        let rect = CGRect(x: 0, y: 0, width: 64, height: 64)
        let auto = CIImage(color: .white).cropped(to: rect)
        let stroke = BrushStroke(region: .tear, mode: .erase, radius: 0.2, points: [CGPoint(x: 0.5, y: 0.5)])
        let m = MaskPainter.apply([stroke], region: .tear, to: auto, size: rect.size)
        var v = [Float](repeating: 0, count: 4)
        v.withUnsafeMutableBytes { buf in
            context.render(m, toBitmap: buf.baseAddress!, rowBytes: 16,
                           bounds: CGRect(x: 32, y: 32, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        }
        XCTAssertLessThan(v[0], 0.1)
        // Other regions are unaffected.
        XCTAssertTrue(MaskPainter.apply([stroke], region: .mouth, to: auto, size: rect.size) === auto)
    }
}
