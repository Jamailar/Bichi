import Foundation
import simd

/// Pure-Swift mirror of the per-pixel math in `FurKernels.ci.metal`.
///
/// The Metal kernels are what actually run; this file exists so the color
/// model can be unit-tested and reasoned about without a GPU. Keep the two in
/// sync when tuning constants.
///
/// All values are linear-light RGB (Core Image's working space).
enum ColorMath {
    static let lumaWeights = SIMD3<Float>(0.2126, 0.7152, 0.0722)

    static func luma(_ rgb: SIMD3<Float>) -> Float {
        simd_dot(rgb, lumaWeights)
    }

    /// Luminance-normalised chromaticity. Neutral grey/white is (1, 1, 1).
    static func chroma(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        rgb / max(luma(rgb), 1e-4)
    }

    static func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
        let t = simd_clamp((x - e0) / (e1 - e0), 0, 1)
        return t * t * (3 - 2 * t)
    }

    /// Opponent chroma: u = warm (R−B), v = green−magenta. Neutral is (0, 0).
    static func opponent(_ c: SIMD3<Float>) -> SIMD2<Float> {
        SIMD2(c.x - c.z, c.y - 0.5 * (c.x + c.z))
    }

    /// Hue windows for the stain-direction gate, radians from the warm axis.
    /// Porphyrin (tears, saliva) is red-brown; food adds yellow-brown.
    static let tearHue = SIMD2<Float>(-1.2, 0.25)
    static let mouthHue = SIMD2<Float>(-1.2, 1.1)

    /// Stain score against this dog's own clean-fur model: (soft, seed).
    /// See `bichi::stainScore` in the Metal file.
    static func stainScore(
        _ rgb: SIMD3<Float>, furChroma: SIMD3<Float>, furLuma: Float, sigma: Float, hue: SIMD2<Float>
    ) -> SIMD2<Float> {
        let d = opponent(chroma(rgb)) - opponent(furChroma)
        let z = d.x / max(sigma, 0.03)
        let angle = atan2(d.y, max(d.x, 1e-4))
        let hueGate = smoothstep(hue.x - 0.15, hue.x + 0.05, angle) * (1 - smoothstep(hue.y - 0.05, hue.y + 0.15, angle))
        let notDark = smoothstep(0.06, 0.18, luma(rgb) / max(furLuma, 1e-3))
        let g = hueGate * notDark
        return SIMD2(smoothstep(2.5, 4.5, z) * g, smoothstep(5, 7, z) * g)
    }

    /// Stain removal: pull chroma toward the clean fur and lift luminance by
    /// a *ratio* toward the local clean-fur level, which keeps every hair's
    /// relative brightness, i.e. the real texture. Nothing is painted in.
    static func destain(
        _ rgb: SIMD3<Float>, base: Float, amount: Float,
        targetChroma: SIMD3<Float>, localFurLuma: Float, maxGain: Float
    ) -> SIMD3<Float> {
        let c = chroma(rgb)
        let y = luma(rgb)
        let gain = simd_clamp(localFurLuma / max(base, 1e-4), 1, maxGain)
        let newC = simd_mix(c, targetChroma, SIMD3(repeating: amount))
        let newY = y * (1 + (gain - 1) * amount)
        return newC * newY
    }

    /// Von Kries style cast removal referenced to the fur itself, so the
    /// background keeps its colour. Brighter fur gets more correction; dark
    /// features (eyes, nose) are left alone.
    static func whiten(
        _ rgb: SIMD3<Float>, amount: Float, furChroma: SIMD3<Float>,
        furLuma: Float, targetLuma: Float
    ) -> SIMD3<Float> {
        let y = luma(rgb)
        let light = smoothstep(0.25, 0.6, y / max(furLuma, 1e-3))
        let a = amount * light
        let divisor = simd_mix(SIMD3<Float>(repeating: 1), furChroma, SIMD3(repeating: a))
        var out = rgb / divisor
        // Grey fur: lift only, never darken. Capped so shadows stay shadows.
        let lift = simd_clamp(targetLuma / max(furLuma, 1e-3), 1, 1.35)
        out *= 1 + (lift - 1) * a
        return out
    }

    /// Highlight shoulder + local contrast. Pixels already clipped on every
    /// channel at capture have no detail left; this only helps near-clipped fur,
    /// which is why the camera biases exposure down for white dogs.
    static func recoverHighlight(_ y: Float, base: Float, amount: Float, knee: Float = 0.62) -> Float {
        func shoulder(_ v: Float) -> Float {
            guard v > knee else { return v }
            let range: Float = 1 - knee
            let t = (v - knee) / range
            // Slope 1 at the knee (no kink); 1.0 maps to ≈ knee + 0.63·range.
            return knee + range * t / (1 + 0.6 * t)
        }
        let detail = y / max(base, 1e-4)
        let compressedBase = base + (shoulder(base) - base) * amount
        let boosted = compressedBase * pow(detail, 1 + 0.9 * amount)
        return boosted
    }
}
