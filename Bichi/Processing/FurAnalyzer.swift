import CoreImage
import CoreVideo
import simd
import Vision

/// Eye/nose positions, normalised with a bottom-left origin.
struct DogLandmarks: Equatable {
    var leftEye: CGPoint
    var rightEye: CGPoint
    var nose: CGPoint

    /// Eye spacing in normalised width units; every region prior is sized by it.
    func eyeDistance(aspect: CGFloat) -> CGFloat {
        hypot(leftEye.x - rightEye.x, (leftEye.y - rightEye.y) / aspect)
    }
}

/// Clean-fur colour of this particular dog in this particular light.
struct FurReference: Equatable {
    var chroma: SIMD3<Float>
    var luma: Float
    /// Spread of clean-fur warmth (opponent u) for this dog. Stains are
    /// judged in units of it, so a cream dog and a paper-white dog each get
    /// their own threshold.
    var warmthSigma: Float = 0.05
    static let neutral = FurReference(chroma: .one, luma: 0.6)
}

/// Everything the processor needs, computed once per photo.
struct FurAnalysis {
    /// Size of the analysis image; all masks live at this size, origin 0.
    let size: CGSize
    let dogFound: Bool
    let landmarks: DogLandmarks?
    let subjectMask: CIImage
    let reference: FurReference
    /// Automatic masks per region, before the user's brush strokes.
    let autoMasks: [RetouchRegion: CIImage]
    /// Local clean-fur luminance (low frequency), the lift target for stains.
    let localFurLuma: CIImage
    let suggestion: RetouchParameters
    let tearSeverity: Float
    let mouthSeverity: Float
    let clippedFraction: Float
}

enum FurAnalyzer {
    static let analysisLongEdge: CGFloat = 1536
    /// Fur exposure target (linear). ~0.7 linear ≈ 87% sRGB: bright but not paper.
    static let targetFurLuma: Float = 0.70

    static func analyze(_ image: CIImage, context: CIContext) throws -> FurAnalysis {
        let small = downscaled(image)
        let size = small.extent.size
        let k = FurKernels.shared

        let handler = VNImageRequestHandler(ciImage: small, orientation: .up)
        let animals = VNRecognizeAnimalsRequest()
        let pose = VNDetectAnimalBodyPoseRequest()
        let instances = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([animals, pose, instances])

        let dogBox = (animals.results ?? [])
            .filter { $0.labels.contains { $0.identifier == VNAnimalIdentifier.dog.rawValue && $0.confidence > 0.3 } }
            .max { $0.boundingBox.area < $1.boundingBox.area }?
            .boundingBox

        let subject = subjectMask(instances.results?.first, dogBox: dogBox, handler: handler, size: size)
        let landmarks = pose.results.flatMap { bestLandmarks($0, near: dogBox) }

        // Per-dog colour model from clean fur, two passes: a rough model to
        // find stains, then mean and spread from clean fur only (stains and
        // shadows would bias it warm/dark and inflate the spread).
        var reference = FurReference.neutral
        var weight = subject
        for _ in 0..<2 {
            weight = k.cleanFurWeight.apply(small.extent, [small, subject, reference.chroma.ciVector, reference.luma, reference.warmthSigma])
            guard let mean = weightedMean(small, weight: weight, context: context) else { break }
            let y = ColorMath.luma(mean)
            guard y > 0.02 else { break }
            var next = FurReference(chroma: ColorMath.chroma(mean), luma: y)
            if let m = weightedMean(k.chromaMoments.apply(small.extent, [small]), weight: weight, context: context) {
                next.warmthSigma = max(sqrt(max(m.z - m.x * m.x, 0)), 0.03)
            }
            reference = next
        }
        let localFur = localFurLuma(small, weight: weight, reference: reference)

        let fur = k.furMask.apply(small.extent, [small, subject, reference.luma])
        var masks: [RetouchRegion: CIImage] = [.fur: fur]
        var tearSeverity: Float = 0, mouthSeverity: Float = 0
        if let lm = landmarks {
            let priors = regionPriors(lm, size: size)
            let d = lm.eyeDistance(aspect: size.width / size.height) * size.width
            for (region, prior) in priors {
                let p = prior.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: subject])
                switch region {
                case .tear, .mouth:
                    let m = stainMask(small, prior: p, reference: reference,
                                      hue: region == .tear ? ColorMath.tearHue : ColorMath.mouthHue,
                                      growRadius: d * 0.12)
                    masks[region] = m
                    let severity = weightedMean(m, weight: p, context: context)?.x ?? 0
                    if region == .tear { tearSeverity = severity } else { mouthSeverity = severity }
                default:
                    masks[region] = p
                }
            }
        } else {
            let empty = CIImage(color: .black).cropped(to: small.extent)
            masks[.tear] = empty; masks[.mouth] = empty; masks[.eyes] = empty
        }

        let clipped = weightedMean(k.clipped.apply(small.extent, [small]), weight: subject, context: context)?.x ?? 0

        let suggestion = suggest(
            reference: reference, hasLandmarks: landmarks != nil,
            tear: tearSeverity, mouth: mouthSeverity, clipped: clipped
        )
        return FurAnalysis(
            size: size, dogFound: dogBox != nil, landmarks: landmarks, subjectMask: subject,
            reference: reference, autoMasks: masks, localFurLuma: localFur, suggestion: suggestion,
            tearSeverity: tearSeverity, mouthSeverity: mouthSeverity, clippedFraction: clipped
        )
    }

    // MARK: - Suggestion

    static func suggest(reference: FurReference, hasLandmarks: Bool, tear: Float, mouth: Float, clipped: Float) -> RetouchParameters {
        func clamp(_ v: Float, _ lo: Float, _ hi: Float) -> Double { Double(min(max(v, lo), hi)) }
        let cast = simd_length(reference.chroma - .one)
        var p = RetouchParameters(auto: 1)
        p.tear = hasLandmarks ? clamp(tear * 3, 0.25, 0.9) : 0
        p.mouth = hasLandmarks ? clamp(mouth * 3, 0.2, 0.85) : 0
        p.whiten = clamp(cast * 6 + max(0, FurAnalyzer.targetFurLuma - reference.luma), 0.15, 0.85)
        p.highlight = clamp(0.3 + clipped * 20, 0.3, 0.8)
        p.eyes = hasLandmarks ? 0.5 : 0
        return p
    }

    // MARK: - Stain masks

    /// Precise stain mask inside a location prior, built the way portrait
    /// retouching builds skin/blemish masks:
    /// 1. per-pixel membership against this dog's colour model (soft + seed);
    /// 2. hysteresis: soft pixels count only near a confident seed, which
    ///    grows the stain from its core and drops isolated warm specks;
    /// 3. guided filter with luminance as the guide so the edge follows hairs.
    static func stainMask(_ image: CIImage, prior: CIImage, reference: FurReference,
                          hue: SIMD2<Float>, growRadius: CGFloat) -> CIImage {
        let k = FurKernels.shared
        let rect = image.extent
        let score = k.stainScore.apply(rect, [image, reference.chroma.ciVector, reference.luma,
                                              reference.warmthSigma, CIVector(x: CGFloat(hue.x), y: CGFloat(hue.y))])
        let soft = k.multiply.apply(rect, [score, prior])
        let seed = k.multiply.apply(rect, [
            score.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 0, y: 1, z: 0, w: 0)]),
            prior,
        ])
        let grownSeed = seed.clampedToExtent()
            .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: max(growRadius, 2)])
            .applyingGaussianBlur(sigma: max(growRadius * 0.3, 1))
            .cropped(to: rect)
        let grown = k.multiply.apply(rect, [soft, grownSeed.applyingFilter("CIColorClamp")])
        let guide = k.luma.apply(rect, [image])
        let radius = max(rect.width * 0.004, 3)
        return guidedFilter(grown, guide: guide, radius: radius, eps: 1e-3)
    }

    /// He et al. guided filter, built from box blurs.
    static func guidedFilter(_ p: CIImage, guide: CIImage, radius: CGFloat, eps: Float) -> CIImage {
        let k = FurKernels.shared
        let rect = p.extent
        func box(_ img: CIImage) -> CIImage {
            img.clampedToExtent().applyingFilter("CIBoxBlur", parameters: [kCIInputRadiusKey: radius]).cropped(to: rect)
        }
        let m = box(k.guidedPack.apply(rect, [guide, p]))
        let mii = box(k.guidedSquare.apply(rect, [guide]))
        let ab = box(k.guidedCoeffs.apply(rect, [m, mii, eps]))
        return k.guidedApply.apply(rect, [guide, ab])
    }

    /// Low-frequency clean-fur luminance: blur(luma·w) / blur(w).
    static func localFurLuma(_ image: CIImage, weight: CIImage, reference: FurReference) -> CIImage {
        let k = FurKernels.shared
        let rect = image.extent
        let sigma = max(rect.width, rect.height) * 0.03
        let blurred = k.weightedLuma.apply(rect, [image, weight])
            .clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: rect)
        return k.localFurLuma.apply(rect, [blurred, reference.luma])
    }

    // MARK: - Region priors

    /// Soft location priors from eye/nose landmarks. Stain colour is checked
    /// per pixel in the kernels, so these only say *where* to look.
    static func regionPriors(_ lm: DogLandmarks, size: CGSize) -> [RetouchRegion: CIImage] {
        let aspect = size.width / size.height
        let d = max(lm.eyeDistance(aspect: aspect), 0.02)
        // Work in width-normalised units so circles stay circles.
        func w(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: p.y / aspect) }
        func back(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: p.y * aspect) }
        let le = w(lm.leftEye), re = w(lm.rightEye), nose = w(lm.nose)
        let eyeMid = CGPoint(x: (le.x + re.x) / 2, y: (le.y + re.y) / 2)
        var down = CGVector(dx: nose.x - eyeMid.x, dy: nose.y - eyeMid.y)
        let len = max(hypot(down.dx, down.dy), 1e-4)
        down = CGVector(dx: down.dx / len, dy: down.dy / len)
        let downAngle = atan2(down.dy, down.dx)

        var tear: [MaskPainter.SoftEllipse] = []
        for eye in [le, re] {
            // Tear tracks run from the inner corner down toward the muzzle.
            let inner = CGPoint(x: eye.x + (nose.x - eye.x) * 0.25, y: eye.y + (nose.y - eye.y) * 0.25)
            let c = CGPoint(x: inner.x + down.dx * d * 0.35, y: inner.y + down.dy * d * 0.35)
            tear.append(.init(center: back(c), radii: CGSize(width: d * 0.6, height: d * 0.32), angle: downAngle))
        }
        for eye in [le, re] {
            tear.append(.init(center: back(eye), radii: CGSize(width: d * 0.2, height: d * 0.2), intensity: 1, subtract: true))
        }

        let mouthCenter = CGPoint(x: nose.x + down.dx * d * 0.45, y: nose.y + down.dy * d * 0.45)
        let mouth: [MaskPainter.SoftEllipse] = [
            .init(center: back(mouthCenter), radii: CGSize(width: d * 0.5, height: d * 0.75), angle: downAngle),
            .init(center: back(nose), radii: CGSize(width: d * 0.2, height: d * 0.2), intensity: 1, subtract: true),
        ]

        let eyes: [MaskPainter.SoftEllipse] = [
            .init(center: back(le), radii: CGSize(width: d * 0.24, height: d * 0.24)),
            .init(center: back(re), radii: CGSize(width: d * 0.24, height: d * 0.24)),
            .init(center: back(nose), radii: CGSize(width: d * 0.28, height: d * 0.28)),
        ]

        return [
            .tear: MaskPainter.render(tear, size: size),
            .mouth: MaskPainter.render(mouth, size: size),
            .eyes: MaskPainter.render(eyes, size: size),
        ]
    }

    // MARK: - Vision helpers

    private static func subjectMask(_ obs: VNInstanceMaskObservation?, dogBox: CGRect?, handler: VNImageRequestHandler, size: CGSize) -> CIImage {
        let full = CGRect(origin: .zero, size: size)
        guard let obs, !obs.allInstances.isEmpty else {
            return CIImage(color: .white).cropped(to: full)
        }
        var chosen = obs.allInstances
        if let box = dogBox, let best = instanceCovering(box, in: obs.instanceMask) {
            chosen = IndexSet(integer: best)
        }
        guard let buffer = try? obs.generateScaledMaskForImage(forInstances: chosen, from: handler) else {
            return CIImage(color: .white).cropped(to: full)
        }
        let mask = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
        let sx = size.width / mask.extent.width, sy = size.height / mask.extent.height
        return mask.transformed(by: CGAffineTransform(scaleX: sx, y: sy)).cropped(to: full)
    }

    /// The instance label with the most pixels inside the dog's bounding box.
    static func instanceCovering(_ box: CGRect, in labels: CVPixelBuffer) -> Int? {
        CVPixelBufferLockBaseAddress(labels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(labels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(labels) else { return nil }
        let w = CVPixelBufferGetWidth(labels), h = CVPixelBufferGetHeight(labels)
        let row = CVPixelBufferGetBytesPerRow(labels)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        // Vision boxes are bottom-left origin; buffer rows are top-down.
        let x0 = Int(box.minX * CGFloat(w)), x1 = Int(box.maxX * CGFloat(w))
        let y0 = Int((1 - box.maxY) * CGFloat(h)), y1 = Int((1 - box.minY) * CGFloat(h))
        var counts = [Int](repeating: 0, count: 256)
        for y in max(y0, 0)..<min(y1, h) {
            for x in max(x0, 0)..<min(x1, w) { counts[Int(ptr[y * row + x])] += 1 }
        }
        counts[0] = 0 // background
        guard let best = counts.indices.max(by: { counts[$0] < counts[$1] }), counts[best] > 0 else { return nil }
        return best
    }

    private static func bestLandmarks(_ results: [VNAnimalBodyPoseObservation], near box: CGRect?) -> DogLandmarks? {
        let candidates: [DogLandmarks] = results.compactMap { obs in
            func p(_ j: VNAnimalBodyPoseObservation.JointName) -> CGPoint? {
                guard let pt = try? obs.recognizedPoint(j), pt.confidence > 0.25 else { return nil }
                return pt.location
            }
            guard let l = p(.leftEye), let r = p(.rightEye), let n = p(.nose) else { return nil }
            return DogLandmarks(leftEye: l, rightEye: r, nose: n)
        }
        guard let box else { return candidates.first }
        return candidates.first { box.insetBy(dx: -0.05, dy: -0.05).contains($0.nose) } ?? candidates.first
    }

    // MARK: - Image helpers

    static func downscaled(_ image: CIImage) -> CIImage {
        let e = image.extent
        let scale = min(1, analysisLongEdge / max(e.width, e.height))
        return image
            .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
            .cropped(to: CGRect(x: 0, y: 0, width: (e.width * scale).rounded(.down), height: (e.height * scale).rounded(.down)))
    }

    /// Σ(image·w) / Σ(w) as linear RGB, or nil if the weight is ~empty.
    static func weightedMean(_ image: CIImage, weight: CIImage, context: CIContext) -> SIMD3<Float>? {
        let extent = image.extent
        let product = image.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: weight])
        let num = areaAverage(product.cropped(to: extent), context: context)
        let den = areaAverage(weight.cropped(to: extent), context: context)
        guard den.x > 1e-4 else { return nil }
        return SIMD3(num.x, num.y, num.z) / den.x
    }

    static func areaAverage(_ image: CIImage, context: CIContext) -> SIMD4<Float> {
        let avg = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)])
        var px = SIMD4<Float>(repeating: 0)
        withUnsafeMutableBytes(of: &px) { buf in
            context.render(avg, toBitmap: buf.baseAddress!, rowBytes: 16,
                           bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBAf, colorSpace: nil)
        }
        return px
    }
}

private extension CGRect {
    var area: CGFloat { width * height }
}
