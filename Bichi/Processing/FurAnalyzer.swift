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

        // Two passes: a rough reference to find stains, then the reference from
        // clean fur only (stains and shadows would bias it warm/dark).
        var reference = FurReference.neutral
        for _ in 0..<2 {
            let w = k.cleanFurWeight.apply(small.extent, [small, subject, reference.chroma.ciVector, reference.luma])
            if let mean = weightedMean(small, weight: w, context: context) {
                let y = ColorMath.luma(mean)
                if y > 0.02 { reference = FurReference(chroma: ColorMath.chroma(mean), luma: y) }
            }
        }

        let fur = k.furMask.apply(small.extent, [small, subject, reference.luma])
        var masks: [RetouchRegion: CIImage] = [.fur: fur]
        if let lm = landmarks {
            let priors = regionPriors(lm, size: size)
            for (region, prior) in priors {
                masks[region] = prior.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: subject])
            }
        } else {
            let empty = CIImage(color: .black).cropped(to: small.extent)
            masks[.tear] = empty; masks[.mouth] = empty; masks[.eyes] = empty
        }

        let stain = k.stainProbability.apply(small.extent, [small, reference.chroma.ciVector, reference.luma])
        let tearSeverity = landmarks == nil ? 0 : weightedMean(stain, weight: masks[.tear]!, context: context).map { $0.x } ?? 0
        let mouthSeverity = landmarks == nil ? 0 : weightedMean(stain, weight: masks[.mouth]!, context: context).map { $0.x } ?? 0
        let clipped = weightedMean(k.clipped.apply(small.extent, [small]), weight: subject, context: context)?.x ?? 0

        let suggestion = suggest(
            reference: reference, hasLandmarks: landmarks != nil,
            tear: tearSeverity, mouth: mouthSeverity, clipped: clipped
        )
        return FurAnalysis(
            size: size, dogFound: dogBox != nil, landmarks: landmarks, subjectMask: subject,
            reference: reference, autoMasks: masks, suggestion: suggestion,
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
