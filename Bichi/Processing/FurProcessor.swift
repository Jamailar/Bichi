import CoreImage

/// Applies the retouch to an image of any size using a `FurAnalysis` made
/// from (a downscaled copy of) the same image.
///
/// Order matters: stains are removed first, measured against the original
/// clean-fur colour, then the whole coat is neutralised so stain and fur end up
/// the same white.
enum FurProcessor {
    static let maxStainGain: Float = 1.6

    static func render(
        _ image: CIImage, analysis: FurAnalysis,
        parameters p: RetouchParameters, strokes: [BrushStroke] = []
    ) -> CIImage {
        let k = FurKernels.shared
        let src = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let extent = src.extent
        let ref = analysis.reference

        func mask(_ region: RetouchRegion) -> CIImage {
            let auto = analysis.autoMasks[region] ?? CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: analysis.size))
            let edited = MaskPainter.apply(strokes, region: region, to: auto, size: analysis.size)
            let s = extent.width / analysis.size.width
            return edited.clampedToExtent()
                .transformed(by: CGAffineTransform(scaleX: s, y: extent.height / analysis.size.height))
                .cropped(to: extent)
        }

        // Base must be blurrier than individual hairs, or the luminance gain
        // would flatten them. Detail = pixel / base is what we preserve.
        let sigma = max(max(extent.width, extent.height) * 0.006, 4)
        let base = k.luma.apply(extent, [src])
            .clampedToExtent()
            .applyingGaussianBlur(sigma: sigma)
            .cropped(to: extent)

        let localFur = analysis.localFurLuma.clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: extent.width / analysis.size.width, y: extent.height / analysis.size.height))
            .cropped(to: extent)

        var out = src
        if p.tear > 0.001 {
            out = k.destain.apply(extent, [out, base, mask(.tear), localFur, Float(p.tear), ref.chroma.ciVector, maxStainGain])
        }
        if p.mouth > 0.001 {
            out = k.destain.apply(extent, [out, base, mask(.mouth), localFur, Float(p.mouth), ref.chroma.ciVector, maxStainGain])
        }
        let fur = (p.highlight > 0.001 || p.whiten > 0.001) ? mask(.fur) : nil
        if p.highlight > 0.001, let fur {
            out = k.highlight.apply(extent, [out, base, fur, Float(p.highlight)])
        }
        if p.whiten > 0.001, let fur {
            out = k.whiten.apply(extent, [out, fur, Float(p.whiten), ref.chroma.ciVector, ref.luma, FurAnalyzer.targetFurLuma])
        }
        if p.eyes > 0.001 {
            out = k.eyes.apply(extent, [out, base, mask(.eyes), Float(p.eyes), ref.luma])
        }
        return out.cropped(to: extent)
    }

    /// Overlay of the automatic + edited masks for the "区域微调" screen.
    /// Colours follow the design: tear amber, mouth blue, eyes white, fur mint.
    static func maskOverlay(analysis: FurAnalysis, strokes: [BrushStroke], visible: Set<RetouchRegion>, extent: CGRect) -> CIImage {
        let colors: [RetouchRegion: CIColor] = [
            .tear: CIColor(red: 0.95, green: 0.71, blue: 0.42),
            .mouth: CIColor(red: 0.56, green: 0.72, blue: 1.0),
            .eyes: CIColor(red: 1, green: 1, blue: 1),
            .fur: CIColor(red: 0.50, green: 0.84, blue: 0.78),
        ]
        var overlay = CIImage(color: .clear).cropped(to: extent)
        for region in RetouchRegion.allCases where visible.contains(region) {
            let auto = analysis.autoMasks[region] ?? CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: analysis.size))
            let m = MaskPainter.apply(strokes, region: region, to: auto, size: analysis.size)
                .transformed(by: CGAffineTransform(scaleX: extent.width / analysis.size.width, y: extent.height / analysis.size.height))
                .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0.5, y: 0, z: 0, w: 0)])
            let tint = CIImage(color: colors[region]!).cropped(to: extent)
            let layer = tint.applyingFilter("CIBlendWithAlphaMask", parameters: [
                kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: extent),
                kCIInputMaskImageKey: m,
            ])
            overlay = layer.composited(over: overlay)
        }
        return overlay.cropped(to: extent)
    }
}
