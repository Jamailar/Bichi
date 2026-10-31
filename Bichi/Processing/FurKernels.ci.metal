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

    inline float stainProb(float3 rgb, float3 furChroma, float furLuma) {
        float3 c = chroma(rgb);
        float warmth = (c.r - c.b) - (furChroma.r - furChroma.b);
        float warm = smoothstep(0.08, 0.35, warmth);
        float notDark = smoothstep(0.06, 0.18, luma(rgb) / max(furLuma, 1e-3));
        return warm * notDark;
    }
}

extern "C" { namespace coreimage {

    float4 bichiLuma(sample_t s) {
        float y = bichi::luma(s.rgb);
        return float4(y, y, y, 1.0);
    }

    float4 bichiStainProbability(sample_t s, float3 furChroma, float furLuma) {
        float p = bichi::stainProb(s.rgb, furChroma, furLuma);
        return float4(p, p, p, 1.0);
    }

    /// Weight for estimating the clean-fur reference: inside the subject,
    /// bright, low-saturation, not stained.
    float4 bichiCleanFurWeight(sample_t s, sample_t subject, float3 furChroma, float furLuma) {
        float y = bichi::luma(s.rgb);
        float3 c = bichi::chroma(s.rgb);
        float sat = length(c - float3(1.0));
        float w = subject.r
            * smoothstep(0.12, 0.30, y)
            * (1.0 - smoothstep(0.35, 0.6, sat))
            * (1.0 - bichi::stainProb(s.rgb, furChroma, furLuma));
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

    float4 bichiDestain(sample_t s, sample_t base, sample_t mask, float amount,
                        float3 furChroma, float3 targetChroma, float furLuma, float maxGain) {
        float a = clamp(amount * mask.r * bichi::stainProb(s.rgb, furChroma, furLuma), 0.0, 1.0);
        float3 c = bichi::chroma(s.rgb);
        float y = bichi::luma(s.rgb);
        float gain = clamp(furLuma / max(base.r, 1e-4), 1.0, maxGain);
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
