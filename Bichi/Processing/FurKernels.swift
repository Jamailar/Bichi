import CoreImage

/// Loads the color kernels compiled from `FurKernels.ci.metal`.
final class FurKernels {
    static let shared: FurKernels = {
        do { return try FurKernels() } catch { fatalError("Bichi: Core Image kernels failed to load: \(error)") }
    }()

    let luma: CIColorKernel
    let stainProbability: CIColorKernel
    let cleanFurWeight: CIColorKernel
    let furMask: CIColorKernel
    let clipped: CIColorKernel
    let destain: CIColorKernel
    let whiten: CIColorKernel
    let highlight: CIColorKernel
    let eyes: CIColorKernel

    private init() throws {
        guard let url = Bundle(for: FurKernels.self).url(forResource: "default", withExtension: "metallib") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let data = try Data(contentsOf: url)
        func k(_ name: String) throws -> CIColorKernel {
            try CIColorKernel(functionName: name, fromMetalLibraryData: data)
        }
        luma = try k("bichiLuma")
        stainProbability = try k("bichiStainProbability")
        cleanFurWeight = try k("bichiCleanFurWeight")
        furMask = try k("bichiFurMask")
        clipped = try k("bichiClipped")
        destain = try k("bichiDestain")
        whiten = try k("bichiWhiten")
        highlight = try k("bichiHighlight")
        eyes = try k("bichiEyes")
    }
}

extension SIMD3 where Scalar == Float {
    var ciVector: CIVector { CIVector(x: CGFloat(x), y: CGFloat(y), z: CGFloat(z)) }
}

extension CIColorKernel {
    func apply(_ extent: CGRect, _ args: [Any]) -> CIImage {
        apply(extent: extent, arguments: args) ?? CIImage.empty()
    }
}
