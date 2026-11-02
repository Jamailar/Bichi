// Core Image color kernels for white-fur retouching.
// Built with -fcikernel / -cikernel (see project.yml).
// Math is mirrored in ColorMath.swift for unit tests; keep them in sync.
//
// Every kernel works on linear RGB, touches only pixels inside its mask, and
// changes them by ratios of the original value, so the fur texture captured by
// the sensor is preserved. Nothing is synthesised.

#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;

namespace bichi {
    constant float3 kLuma = float3(0.2126, 0.7152, 0.0722);

    inline float luma(float3 c) { return dot(c, kLuma); }
    inline float3 chroma(float3 c) { return c / max(luma(c), 1e-4); }

    /// Opponent chroma: u = warm (R−B), v = green−magenta. Neutral is (0, 0).
    inline float2 opponent(float3 c) {
        return float2(c.r - c.b, c.g - 0.5 * (c.r + c.b));
    }

    /// Stain score against this dog's own clean-fur colour model, the way
    /// beauty apps build a per-face skin model instead of fixed thresholds.
    /// Returns (low, high): `low` is a soft membership (z 2.5→4.5 σ warmer
    /// than clean fur), `high` a confident seed (z 5→7 σ) for hysteresis.
    /// `hue` gates the direction of the shift: red-brown porphyrin vs
    /// yellow-brown food stains (radians, measured from the warm axis).
    inline float2 stainScore(float3 rgb, float3 furChroma, float furLuma, float sigma, float2 hue) {
        float2 d = opponent(chroma(rgb)) - opponent(furChroma);
        float z = d.x / max(sigma, 0.03);
        float angle = atan2(d.y, max(d.x, 1e-4));
        float hueGate = smoothstep(hue.x - 0.15, hue.x + 0.05, angle)
                      * (1.0 - smoothstep(hue.y - 0.05, hue.y + 0.15, angle));
        float notDark = smoothstep(0.06, 0.18, luma(rgb) / max(furLuma, 1e-3));
        float g = hueGate * notDark;
        return float2(smoothstep(2.5, 4.5, z) * g, smoothstep(5.0, 7.0, z) * g);
    }
}

extern "C" { namespace coreimage {

    float4 bichiLuma(sample_t s) {
        float y = bichi::luma(s.rgb);
        return float4(y, y, y, 1.0);
    }

    /// r = soft stain membership, g = confident seed.
    float4 bichiStainScore(sample_t s, float3 furChroma, float furLuma, float sigma, float2 hue) {
        float2 p = bichi::stainScore(s.rgb, furChroma, furLuma, sigma, hue);
        return float4(p.x, p.y, 0.0, 1.0);
    }

    /// (u, v, u², v²) for the per-dog colour model, weighted later.
    float4 bichiChromaMoments(sample_t s) {
        float2 o = bichi::opponent(bichi::chroma(s.rgb));
        return float4(o.x, o.y, o.x * o.x, o.y * o.y);
    }

    /// (luma·w, w) so a blur of it gives a local clean-fur average.
    float4 bichiWeightedLuma(sample_t s, sample_t w) {
        return float4(bichi::luma(s.rgb) * w.r, w.r, 0.0, 1.0);
    }

    /// Local clean-fur luminance = blurred(luma·w) / blurred(w), falling back
    /// to the global fur luminance where no clean fur is nearby.
    float4 bichiLocalFurLuma(sample_t s, float furLuma) {
        float local = s.r / max(s.g, 1e-4);
        float y = mix(furLuma, local, smoothstep(0.01, 0.1, s.g));
        return float4(y, y, y, 1.0);
    }

    float4 bichiMultiply(sample_t a, sample_t b) {
        float v = a.r * b.r;
        return float4(v, v, v, 1.0);
    }

    // Guided filter (He et al.), the edge-aware mask refinement portrait
    // tools use so a mask hugs hair instead of being a blob. Guide = luma.
    float4 bichiGuidedPack(sample_t guide, sample_t p) {
        float i = guide.r;
        return float4(i, p.r, i * p.r, 1.0);
    }
    float4 bichiGuidedSquare(sample_t guide) {
        float i = guide.r;
        return float4(i * i, 0.0, 0.0, 1.0);
    }
    float4 bichiGuidedCoeffs(sample_t m, sample_t mii, float eps) {
        float varI = max(mii.r - m.r * m.r, 0.0);
        float cov = m.b - m.r * m.g;
        float a = cov / (varI + eps);
        float b = m.g - a * m.r;
        return float4(a, b, 0.0, 1.0);
    }
    float4 bichiGuidedApply(sample_t guide, sample_t ab) {
        float q = clamp(ab.r * guide.r + ab.g, 0.0, 1.0);
        return float4(q, q, q, 1.0);
    }

    /// Weight for estimating the clean-fur reference: inside the subject,
    /// bright, low-saturation, not stained.
    float4 bichiCleanFurWeight(sample_t s, sample_t subject, float3 furChroma, float furLuma, float sigma) {
        float y = bichi::luma(s.rgb);
        float3 c = bichi::chroma(s.rgb);
        float sat = length(c - float3(1.0));
        float w = subject.r
            * smoothstep(0.12, 0.30, y)
            * (1.0 - smoothstep(0.35, 0.6, sat))
            * (1.0 - bichi::stainScore(s.rgb, furChroma, furLuma, sigma, float2(-1.4, 1.4)).x);
        return float4(w, w, w, 1.0);
    }

    /// Fur mask: subject, light enough to be fur (excludes eyes, nose, dark
    /// collar), not strongly saturated (excludes coloured clothes/toys).
    float4 bichiFurMask(sample_t s, sample_t subject, float furLuma) {
        float y = bichi::luma(s.rgb);
        float sat = length(bichi::chroma(s.rgb) - float3(1.0));
        float m = subject.r
            * smoothstep(0.18, 0.40, y / max(furLuma, 1e-3))
            * (1.0 - smoothstep(0.55, 0.9, sat));
        return float4(m, m, m, 1.0);
    }

    float4 bichiClipped(sample_t s) {
        float v = step(0.985, min(min(s.r, s.g), s.b));
        return float4(v, v, v, 1.0);
    }

    /// Stain removal, like under-eye dark-circle correction: chroma goes to
    /// the clean-fur colour, luminance is lifted toward the *local* clean fur
    /// around it (not a global value, so shadows stay shadows), by a ratio so
    /// each hair keeps its brightness relative to its neighbours.
    float4 bichiDestain(sample_t s, sample_t base, sample_t mask, sample_t localFur, float amount,
                        float3 targetChroma, float maxGain) {
        float a = clamp(amount * mask.r, 0.0, 1.0);
        float3 c = bichi::chroma(s.rgb);
        float y = bichi::luma(s.rgb);
        float gain = clamp(localFur.r / max(base.r, 1e-4), 1.0, maxGain);
        float3 outC = mix(c, targetChroma, a);
        float outY = y * (1.0 + (gain - 1.0) * a);
        return float4(outC * outY, s.a);
    }

    float4 bichiWhiten(sample_t s, sample_t mask, float amount,
                       float3 furChroma, float furLuma, float targetLuma) {
        float y = bichi::luma(s.rgb);
        float light = smoothstep(0.25, 0.6, y / max(furLuma, 1e-3));
        float a = clamp(amount * mask.r * light, 0.0, 1.0);
        float3 outRGB = s.rgb / mix(float3(1.0), furChroma, a);
        float lift = clamp(targetLuma / max(furLuma, 1e-3), 1.0, 1.35);
        outRGB *= 1.0 + (lift - 1.0) * a;
        return float4(outRGB, s.a);
    }

    float4 bichiHighlight(sample_t s, sample_t base, sample_t mask, float amount) {
        float a = clamp(amount * mask.r, 0.0, 1.0);
        float y = bichi::luma(s.rgb);
        float b = max(base.r, 1e-4);
        const float knee = 0.62;
        float shoulder = b;
        if (b > knee) {
            float range = 1.0 - knee;
            float t = (b - knee) / range;
            shoulder = knee + range * t / (1.0 + 0.6 * t);
        }
        float detail = y / b;
        float compressed = b + (shoulder - b) * a;
        float outY = compressed * pow(max(detail, 1e-4), 1.0 + 0.9 * a);
        return float4(s.rgb * (outY / max(y, 1e-4)), s.a);
    }

    /// Eyes and nose lost in fur: deepen the dark feature, add local
    /// contrast so catchlights and the iris edge read, neutralise the brown
    /// tinge stains leave on the rim.
    float4 bichiEyes(sample_t s, sample_t base, sample_t mask, float amount, float furLuma) {
        float y = bichi::luma(s.rgb);
        float rel = y / max(furLuma, 1e-3);
        float dark = 1.0 - smoothstep(0.15, 0.45, rel);
        float a = clamp(amount * mask.r, 0.0, 1.0);
        float detail = y / max(base.r, 1e-4);
        float outY = y * pow(max(detail, 1e-4), 0.6 * a) * (1.0 - 0.3 * a * dark);
        float3 c = mix(bichi::chroma(s.rgb), float3(1.0), 0.35 * a * dark);
        return float4(c * outY, s.a);
    }
}}
