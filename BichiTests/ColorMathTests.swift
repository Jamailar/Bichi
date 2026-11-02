import XCTest
import simd
@testable import Bichi

final class ColorMathTests: XCTestCase {
    // Slightly warm, well-exposed white fur (linear).
    let fur = SIMD3<Float>(0.66, 0.62, 0.55)
    // Red-brown tear stain (linear).
    let stain = SIMD3<Float>(0.42, 0.28, 0.17)
    var furChroma: SIMD3<Float> { ColorMath.chroma(fur) }
    var furLuma: Float { ColorMath.luma(fur) }

    func score(_ rgb: SIMD3<Float>, sigma: Float = 0.03, hue: SIMD2<Float> = ColorMath.tearHue) -> SIMD2<Float> {
        ColorMath.stainScore(rgb, furChroma: furChroma, furLuma: furLuma, sigma: sigma, hue: hue)
    }

    func testStainScoreSeparatesStainFromFur() {
        XCTAssertLessThan(score(fur).x, 0.05)
        XCTAssertGreaterThan(score(stain).x, 0.8)
        XCTAssertGreaterThan(score(stain).y, 0.8, "a strong stain is also a seed")
        // A black nose is not a stain.
        XCTAssertLessThan(score(SIMD3<Float>(0.02, 0.018, 0.016)).x, 0.05)
    }

    func testHueSeparatesRedTearFromYellowFood() {
        let food = SIMD3<Float>(0.6, 0.55, 0.25)
        XCTAssertLessThan(score(food, hue: ColorMath.tearHue).x, 0.05, "yellow is not a tear stain")
        XCTAssertGreaterThan(score(food, hue: ColorMath.mouthHue).x, 0.8, "but it is a mouth stain")
        XCTAssertGreaterThan(score(stain, hue: ColorMath.mouthHue).x, 0.8)
    }

    func testThresholdAdaptsToEachDogsSpread() {
        // Slightly warmer patch: a stain on a uniform white dog, normal
        // variation on a dog whose coat is naturally uneven cream.
        let patch = fur * SIMD3<Float>(1.065, 1, 0.935)
        XCTAssertGreaterThan(score(patch, sigma: 0.03).x, 0.5)
        XCTAssertLessThan(score(patch, sigma: 0.1).x, 0.05)
    }

    func testDestainMovesTowardFurAndKeepsTexture() {
        let base = ColorMath.luma(stain)
        let out = ColorMath.destain(stain, base: base, amount: 1, targetChroma: furChroma, localFurLuma: furLuma, maxGain: 1.6)
        let warmthBefore = ColorMath.chroma(stain).x - ColorMath.chroma(stain).z
        let warmthAfter = ColorMath.chroma(out).x - ColorMath.chroma(out).z
        XCTAssertEqual(warmthAfter, furChroma.x - furChroma.z, accuracy: 0.01)
        XCTAssertLessThan(warmthAfter, warmthBefore)

        // Two neighbouring hairs, one 20% brighter: the ratio must survive.
        let bright = stain * 1.2
        let outBright = ColorMath.destain(bright, base: base, amount: 1, targetChroma: furChroma, localFurLuma: furLuma, maxGain: 1.6)
        XCTAssertEqual(ColorMath.luma(outBright) / ColorMath.luma(out), 1.2, accuracy: 0.001)
    }

    func testDestainZeroAmountIsIdentity() {
        let out = ColorMath.destain(stain, base: 0.3, amount: 0, targetChroma: furChroma, localFurLuma: furLuma, maxGain: 1.6)
        XCTAssertEqual(simd_distance(out, stain), 0, accuracy: 1e-5)
    }

    func testWhitenNeutralisesTheFurReference() {
        let out = ColorMath.whiten(fur, amount: 1, furChroma: furChroma, furLuma: furLuma, targetLuma: 0.7)
        let c = ColorMath.chroma(out)
        XCTAssertEqual(c.x, c.z, accuracy: 0.01)
        XCTAssertEqual(c.x, c.y, accuracy: 0.01)
        // Dark features are left alone.
        let eye = SIMD3<Float>(0.03, 0.025, 0.02)
        let eyeOut = ColorMath.whiten(eye, amount: 1, furChroma: furChroma, furLuma: furLuma, targetLuma: 0.7)
        XCTAssertEqual(simd_distance(eye, eyeOut), 0, accuracy: 1e-5)
    }

    func testHighlightShoulderIsMonotonicAndContinuous() {
        var prev: Float = 0
        for i in 0...120 {
            let v = Float(i) / 100
            let out = ColorMath.recoverHighlight(v, base: v, amount: 1)
            XCTAssertGreaterThanOrEqual(out, prev - 1e-5)
            if v <= 0.62 { XCTAssertEqual(out, v, accuracy: 1e-5) }
            prev = out
        }
        XCTAssertLessThan(ColorMath.recoverHighlight(1, base: 1, amount: 1), 0.9)
    }

    func testHighlightBoostsLocalContrast() {
        let base: Float = 0.8
        let hair = ColorMath.recoverHighlight(0.88, base: base, amount: 1)
        let gap = ColorMath.recoverHighlight(0.72, base: base, amount: 1)
        XCTAssertGreaterThan(hair / gap, 0.88 / 0.72)
    }
}

final class CaptureLogicTests: XCTestCase {
    func testPortraitVisionToBufferPoint() {
        // Top-left of the portrait view (Vision (0,1)) is buffer (0,1):
        // the sensor's bottom-left when the phone is held upright.
        XCTAssertEqual(VisionGeometry.bufferPoint(fromPortraitVision: CGPoint(x: 0, y: 1)), CGPoint(x: 0, y: 1))
        XCTAssertEqual(VisionGeometry.bufferPoint(fromPortraitVision: CGPoint(x: 0.5, y: 0.5)), CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(VisionGeometry.bufferPoint(fromPortraitVision: CGPoint(x: 1, y: 1)), CGPoint(x: 0, y: 0))
    }

    func testNeutralisingGainsMakeFurGrey() {
        let fur = SIMD3<Float>(0.8, 0.7, 0.5)
        let g = VisionGeometry.neutralisingGains(furRGB: fur, current: .one, maxGain: 8, damping: 1)
        let corrected = fur * g
        XCTAssertEqual(corrected.x / corrected.y, 1, accuracy: 0.001)
        XCTAssertEqual(corrected.z / corrected.y, 1, accuracy: 0.001)
        XCTAssertEqual(g.min(), 1, accuracy: 1e-6)
    }

    func testExposureStepsDownWhenFurClips() {
        var c = FurExposureController()
        let blown = FurFrameStats(clippedFraction: 0.1, p95: 1, brightFurRGB: .one, sampleCount: 1000)
        for _ in 0..<5 { _ = c.update(with: blown) }
        XCTAssertLessThan(c.bias, -1)
        for _ in 0..<100 { _ = c.update(with: blown) }
        XCTAssertEqual(c.bias, c.minBias)

        let dim = FurFrameStats(clippedFraction: 0, p95: 0.7, brightFurRGB: .one, sampleCount: 1000)
        let before = c.bias
        _ = c.update(with: dim)
        XCTAssertGreaterThan(c.bias, before)
    }

    func testExposureIgnoresTinySamples() {
        var c = FurExposureController()
        _ = c.update(with: FurFrameStats(clippedFraction: 1, p95: 1, brightFurRGB: .one, sampleCount: 10))
        XCTAssertEqual(c.bias, 0)
    }

    func testAutoScalesSuggestion() {
        var s = RetouchParameters(auto: 1)
        s.tear = 0.8; s.whiten = 0.5
        let p = RetouchParameters.auto(s, strength: 0.5)
        XCTAssertEqual(p.tear, 0.4, accuracy: 1e-9)
        XCTAssertEqual(p.whiten, 0.25, accuracy: 1e-9)
        XCTAssertEqual(p.auto, 0.5, accuracy: 1e-9)
    }
}
