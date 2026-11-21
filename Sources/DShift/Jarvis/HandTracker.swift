import AVFoundation
import Vision
import os

enum HandJoint: String, CaseIterable, Sendable {
    case wrist
    case thumbCMC, thumbMP, thumbIP, thumbTip
    case indexMCP, indexPIP, indexDIP, indexTip
    case middleMCP, middlePIP, middleDIP, middleTip
    case ringMCP, ringPIP, ringDIP, ringTip
    case littleMCP, littlePIP, littleDIP, littleTip

    var visionName: VNHumanHandPoseObservation.JointName {
        switch self {
        case .wrist: .wrist
        case .thumbCMC: .thumbCMC
        case .thumbMP: .thumbMP
        case .thumbIP: .thumbIP
        case .thumbTip: .thumbTip
        case .indexMCP: .indexMCP
        case .indexPIP: .indexPIP
        case .indexDIP: .indexDIP
        case .indexTip: .indexTip
        case .middleMCP: .middleMCP
        case .middlePIP: .middlePIP
        case .middleDIP: .middleDIP
        case .middleTip: .middleTip
        case .ringMCP: .ringMCP
        case .ringPIP: .ringPIP
        case .ringDIP: .ringDIP
        case .ringTip: .ringTip
        case .littleMCP: .littleMCP
        case .littlePIP: .littlePIP
        case .littleDIP: .littleDIP
        case .littleTip: .littleTip
        }
    }
}

struct TrackedJoint: Sendable {
    let point: CGPoint
    let confidence: Float
}

struct CameraHand: Sendable {
    let chirality: Int
    let joints: [HandJoint: TrackedJoint]
}

struct CameraFrame: Sendable {
    let hands: [CameraHand]
    let imageSize: CGSize
    let visionSeconds: Double
}

final class HandTracker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    enum StartError: LocalizedError {
        case denied, noCamera, suspended

        var errorDescription: String? {
            switch self {
            case .denied: "Camera access is off. Turn on D-Shift in System Settings > Privacy & Security > Camera."
            case .noCamera: "No camera found."
            case .suspended:
                "The camera is off, probably because the laptop lid is closed. Open it or connect a webcam to use your hands. Voice still works."
            }
        }
    }

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "dshift.jarvis.hands", qos: .userInteractive)
    private let request: VNDetectHumanHandPoseRequest = {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2
        return request
    }()
    private let onFrame: @MainActor (CameraFrame) -> Void
    private let delivered = OSAllocatedUnfairLock(initialState: false)

    var hasDeliveredFrame: Bool { delivered.withLock { $0 } }

    init(onFrame: @escaping @MainActor (CameraFrame) -> Void) {
        self.onFrame = onFrame
    }

    func start() async throws {
        guard await AVCaptureDevice.requestAccess(for: .video) else { throw StartError.denied }
        let request = request
        queue.async { Self.warmUp(request) }
        let cameras = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video,
            position: .unspecified
        ).devices
        guard !cameras.isEmpty else { throw StartError.noCamera }
        guard let camera = cameras.first(where: { !$0.isSuspended }),
            let input = try? AVCaptureDeviceInput(device: camera)
        else { throw StartError.suspended }
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        session.beginConfiguration()
        session.sessionPreset = session.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .high
        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)
        if session.canAddInput(input) { session.addInput(input) }
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        Self.preferHighFrameRate(camera)
        let session = session
        await withCheckedContinuation { continuation in
            queue.async {
                session.startRunning()
                continuation.resume()
            }
        }
    }

    func stop() {
        let session = session
        queue.async { session.stopRunning() }
    }

    func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection
    ) {
        delivered.withLock { $0 = true }
        let started = CACurrentMediaTime()
        let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: .up)
        guard (try? handler.perform([request])) != nil else { return }
        let hands = (request.results ?? []).map { observation in
            let chirality: Int =
                switch observation.chirality {
                case .left: 0
                case .right: 1
                default: -1
                }
            var joints: [HandJoint: TrackedJoint] = [:]
            for joint in HandJoint.allCases {
                guard let point = try? observation.recognizedPoint(joint.visionName), point.confidence > 0.05 else {
                    continue
                }
                joints[joint] = TrackedJoint(
                    point: CGPoint(x: point.location.x, y: 1 - point.location.y), confidence: point.confidence)
            }
            return CameraHand(chirality: chirality, joints: joints)
        }
        let imageSize =
            CMSampleBufferGetImageBuffer(sampleBuffer).map {
                CGSize(width: CVPixelBufferGetWidth($0), height: CVPixelBufferGetHeight($0))
            } ?? CGSize(width: 16, height: 9)
        let frame = CameraFrame(hands: hands, imageSize: imageSize, visionSeconds: CACurrentMediaTime() - started)
        let onFrame = onFrame
        Task { @MainActor in onFrame(frame) }
    }

    private static func warmUp(_ request: VNDetectHumanHandPoseRequest) {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
        guard let buffer else { return }
        let started = CACurrentMediaTime()
        try? VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up).perform([request])
        Log.info("jarvis", String(format: "hand model ready in %.1f s", CACurrentMediaTime() - started))
    }

    private static func preferHighFrameRate(_ camera: AVCaptureDevice) {
        guard
            let range = camera.activeFormat.videoSupportedFrameRateRanges.max(by: { $0.maxFrameRate < $1.maxFrameRate }
            ),
            range.maxFrameRate > 30, (try? camera.lockForConfiguration()) != nil
        else { return }
        let duration = CMTime(value: 1, timescale: CMTimeScale(min(60, range.maxFrameRate)))
        camera.activeVideoMinFrameDuration = duration
        camera.activeVideoMaxFrameDuration = duration
        camera.unlockForConfiguration()
    }
}
