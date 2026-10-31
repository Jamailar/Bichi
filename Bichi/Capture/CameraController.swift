import AVFoundation
import CoreImage
import Vision

/// Camera tuned for white dogs:
/// - meters on the dog's fur, not the whole frame, and biases exposure down
///   until the fur stops clipping (white fur is what auto-exposure blows out);
/// - focuses and meters on the eyes found by Vision;
/// - "锁定" locks exposure and sets white balance using the fur as a grey card.
@MainActor
final class CameraController: NSObject, ObservableObject {
    enum Status: Equatable { case idle, unauthorized, running, failed(String) }

    @Published private(set) var status: Status = .idle
    @Published private(set) var dogDetected = false
    /// Dog outline box for the overlay, normalised to the portrait view, top-left origin.
    @Published private(set) var dogBox: CGRect?
    @Published private(set) var eyeBox: CGRect?
    @Published private(set) var furClipped: Float = 0
    @Published private(set) var exposureBias: Float = 0
    @Published private(set) var isLocked = false
    @Published var furMetering = true

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "bichi.camera.session")
    private let videoQueue = DispatchQueue(label: "bichi.camera.video")
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var device: AVCaptureDevice?
    private var photoContinuation: CheckedContinuation<Data, Error>?

    // Touched only on videoQueue.
    nonisolated(unsafe) private var exposure = FurExposureController()
    nonisolated(unsafe) private var lastAnalysis = Date.distantPast
    nonisolated(unsafe) private var lastFocus = CGPoint(x: -1, y: -1)
    nonisolated(unsafe) private var lastFurRGB = SIMD3<Float>(repeating: 1)
    nonisolated(unsafe) private var meteringEnabled = true
    nonisolated(unsafe) private var locked = false

    func start() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else { status = .unauthorized; return }
        default:
            status = .unauthorized; return
        }
        let result: Status = await withCheckedContinuation { cont in
            sessionQueue.async { [self] in cont.resume(returning: configureAndStart()) }
        }
        status = result
    }

    func stop() {
        sessionQueue.async { [session] in session.stopRunning() }
    }

    nonisolated private func configureAndStart() -> Status {
        session.beginConfiguration()
        session.sessionPreset = .photo
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera],
            mediaType: .video, position: .back
        )
        guard let dev = discovery.devices.first,
              let input = try? AVCaptureDeviceInput(device: dev),
              session.canAddInput(input), session.canAddOutput(photoOutput), session.canAddOutput(videoOutput) else {
            session.commitConfiguration()
            return .failed("无法打开相机")
        }
        session.addInput(input)
        session.addOutput(photoOutput)
        photoOutput.maxPhotoQualityPrioritization = .quality
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        session.addOutput(videoOutput)
        session.commitConfiguration()
        DispatchQueue.main.async { self.device = dev }
        session.startRunning()
        return .running
    }

    // MARK: - Lock

    func toggleLock() {
        isLocked ? unlock() : lock()
    }

    func lock() {
        guard let dev = device else { return }
        let fur = lastFurRGBSnapshot()
        sessionQueue.async { [weak self] in
            guard (try? dev.lockForConfiguration()) != nil else { return }
            defer { dev.unlockForConfiguration() }
            if dev.isExposureModeSupported(.locked) { dev.exposureMode = .locked }
            if dev.isLockingWhiteBalanceWithCustomDeviceGainsSupported {
                let cur = dev.deviceWhiteBalanceGains
                let gains = VisionGeometry.neutralisingGains(
                    furRGB: fur, current: SIMD3(cur.redGain, cur.greenGain, cur.blueGain),
                    maxGain: dev.maxWhiteBalanceGain
                )
                dev.setWhiteBalanceModeLocked(with: .init(redGain: gains.x, greenGain: gains.y, blueGain: gains.z))
            } else if dev.isWhiteBalanceModeSupported(.locked) {
                dev.whiteBalanceMode = .locked
            }
            self?.videoQueue.async { self?.locked = true }
        }
        isLocked = true
    }

    func unlock() {
        guard let dev = device else { return }
        sessionQueue.async { [weak self] in
            guard (try? dev.lockForConfiguration()) != nil else { return }
            defer { dev.unlockForConfiguration() }
            if dev.isExposureModeSupported(.continuousAutoExposure) { dev.exposureMode = .continuousAutoExposure }
            if dev.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { dev.whiteBalanceMode = .continuousAutoWhiteBalance }
            self?.videoQueue.async { self?.locked = false }
        }
        isLocked = false
    }

    nonisolated private func lastFurRGBSnapshot() -> SIMD3<Float> {
        videoQueue.sync { lastFurRGB }
    }

    func setFurMetering(_ on: Bool) {
        furMetering = on
        videoQueue.async { [weak self] in
            self?.meteringEnabled = on
            if !on { self?.exposure.bias = 0 }
        }
        if !on, let dev = device {
            sessionQueue.async {
                guard (try? dev.lockForConfiguration()) != nil else { return }
                dev.setExposureTargetBias(0)
                dev.unlockForConfiguration()
            }
        }
    }

    // MARK: - Capture

    /// Captures a full-quality HEIF photo and returns its encoded data
    /// (orientation and metadata included).
    func capturePhoto() async throws -> Data {
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        settings.photoQualityPrioritization = .quality
        if let conn = photoOutput.connection(with: .video) {
            if conn.isVideoRotationAngleSupported(90) { conn.videoRotationAngle = 90 }
        }
        return try await withCheckedThrowingContinuation { cont in
            photoContinuation = cont
            photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }
}

extension CameraController: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let result: Result<Data, Error> = if let error { .failure(error) }
            else if let data = photo.fileDataRepresentation() { .success(data) }
            else { .failure(CocoaError(.fileWriteUnknown)) }
        Task { @MainActor in
            self.photoContinuation?.resume(with: result)
            self.photoContinuation = nil
        }
    }
}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // ~6 Hz is plenty for metering and keeps the preview smooth.
        let now = Date()
        guard now.timeIntervalSince(lastAnalysis) > 0.16,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastAnalysis = now

        let animals = VNRecognizeAnimalsRequest()
        let pose = VNDetectAnimalBodyPoseRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .right)
        try? handler.perform([animals, pose])

        let dog = (animals.results ?? [])
            .filter { $0.labels.contains { $0.identifier == VNAnimalIdentifier.dog.rawValue } }
            .max { $0.confidence < $1.confidence }
        guard let dog else {
            Task { @MainActor in self.dogDetected = false; self.dogBox = nil; self.eyeBox = nil }
            return
        }

        var eyeMid: CGPoint?
        var eyeRect: CGRect?
        if let obs = pose.results?.first,
           let l = try? obs.recognizedPoint(.leftEye), let r = try? obs.recognizedPoint(.rightEye),
           l.confidence > 0.3, r.confidence > 0.3 {
            let mid = CGPoint(x: (l.location.x + r.location.x) / 2, y: (l.location.y + r.location.y) / 2)
            eyeMid = mid
            let dx = abs(l.location.x - r.location.x)
            let a = VisionGeometry.viewPoint(fromPortraitVision: mid)
            eyeRect = CGRect(x: a.x - dx * 0.8, y: a.y - dx * 0.35, width: dx * 1.6, height: dx * 0.7)
        }

        let bufferBox = VisionGeometry.bufferRect(fromPortraitVision: dog.boundingBox)
        let stats = FurFrameSampler.stats(buffer, box: bufferBox)
        if let stats, stats.sampleCount > 200 { lastFurRGB = stats.brightFurRGB }

        var newBias: Float?
        if meteringEnabled, !locked, let stats {
            let before = exposure.bias
            let after = exposure.update(with: stats)
            if abs(after - before) > 0.01 { newBias = after }
        }
        var focus: CGPoint?
        if !locked, let mid = eyeMid {
            let p = VisionGeometry.bufferPoint(fromPortraitVision: mid)
            if hypot(p.x - lastFocus.x, p.y - lastFocus.y) > 0.05 { focus = p; lastFocus = p }
        }

        let viewBox: CGRect = {
            let b = dog.boundingBox
            return CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
        }()
        Task { @MainActor in
            self.dogDetected = true
            self.dogBox = viewBox
            self.eyeBox = eyeRect
            if let stats { self.furClipped = stats.clippedFraction }
            if let newBias { self.exposureBias = newBias }
            self.apply(bias: newBias, focus: focus)
        }
    }

    private func apply(bias: Float?, focus: CGPoint?) {
        guard (bias != nil || focus != nil), let dev = device else { return }
        sessionQueue.async {
            guard (try? dev.lockForConfiguration()) != nil else { return }
            defer { dev.unlockForConfiguration() }
            if let bias {
                dev.setExposureTargetBias(min(max(bias, dev.minExposureTargetBias), dev.maxExposureTargetBias))
            }
            if let focus {
                if dev.isFocusPointOfInterestSupported {
                    dev.focusPointOfInterest = focus
                    dev.focusMode = .continuousAutoFocus
                }
                if dev.isExposurePointOfInterestSupported {
                    dev.exposurePointOfInterest = focus
                    dev.exposureMode = .continuousAutoExposure
                }
            }
        }
    }
}
