import AVFoundation
import AppKit

@MainActor
final class HandRecorder {
    struct Step {
        let label: String
        let title: String
        let detail: String
    }

    static let steps = [
        Step(label: "none", title: "Hands down", detail: "Rest both hands out of view."),
        Step(
            label: "point", title: "Point",
            detail: "Only your index finger out, other fingers curled. Move it around the screen."),
        Step(
            label: "pinch", title: "Pinch and draw",
            detail: "Touch thumb and index fingertips, move like drawing. Let go and pinch again a few times."),
        Step(label: "fist", title: "Fist", detail: "Close your whole hand into a fist and move it around."),
        Step(
            label: "grip", title: "Ball grip",
            detail: "Curve all five fingers like you're holding a ball. Move it around."),
        Step(label: "open", title: "Open hand, still", detail: "Fingers spread, palm facing the camera. Hold still."),
        Step(
            label: "spread", title: "Gather and spread",
            detail: "Bring all five fingertips together, then spread them wide. Keep repeating."),
        Step(label: "rub", title: "Rub", detail: "Open hand, rub back and forth quickly, like erasing a whiteboard."),
    ]
    static let readySeconds = 4
    static let recordSeconds = 7

    private static let accent = NSColor(calibratedRed: 0.55, green: 0.86, blue: 1, alpha: 1)

    private let output: FileHandle
    private let panel: NSPanel
    private let stepLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let phaseLabel = NSTextField(labelWithString: "")
    private let preview = NSView()
    private let jointsLayer = CAShapeLayer()
    private let progressTrack = CALayer()
    private let progressFill = CALayer()
    private let speech = AVSpeechSynthesizer()
    private var tracker: HandTracker?
    private var currentLabel = "setup"
    private let started = CACurrentMediaTime()
    private var frameCounts: [String: (frames: Int, withHand: Int)] = [:]

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        output = try FileHandle(forWritingTo: url)
        let screen = NSScreen.underMouse.frame
        let size = NSSize(width: 760, height: 660)
        panel = NSPanel(
            contentRect: NSRect(
                x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width,
                height: size.height),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.contentView = makeContent(size: size)
    }

    func run() async throws {
        panel.orderFrontRegardless()
        let tracker = HandTracker { [weak self] frame in self?.receive(frame) }
        self.tracker = tracker
        show(step: nil, title: "Starting the camera", detail: "Sit where you normally would.")
        try await tracker.start()
        attachPreview(tracker.session)
        show(
            step: nil, title: "Hand recording",
            detail: "8 short poses, about a minute and a half. Watch the dots: they show what the camera sees.")
        speak("Let's record your hands. Watch the dots to see what the camera sees.")
        try? await Task.sleep(for: .seconds(5))
        for (index, step) in Self.steps.enumerated() {
            currentLabel = "transition"
            show(step: index, title: step.title, detail: step.detail)
            speak("\(step.title). \(step.detail)")
            for remaining in stride(from: Self.readySeconds, to: 0, by: -1) {
                setPhase("Get ready  \(remaining)", progress: 0, recording: false)
                try? await Task.sleep(for: .seconds(1))
            }
            currentLabel = step.label
            let ticks = Self.recordSeconds * 10
            for tick in 0..<ticks {
                let secondsLeft = Int((Double(ticks - tick) / 10).rounded(.up))
                setPhase("Recording  \(secondsLeft)", progress: Double(tick) / Double(ticks), recording: true)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        currentLabel = "done"
        tracker.stop()
        show(step: nil, title: "Done, thank you", detail: "The camera is off. You can go back to the chat.")
        setPhase("", progress: 1, recording: false)
        speak("Done. Thank you.")
        try? await Task.sleep(for: .seconds(3))
        try output.close()
        for step in Self.steps {
            let counts = frameCounts[step.label] ?? (0, 0)
            print("\(step.label): \(counts.frames) frames, hand seen in \(counts.withHand)")
        }
    }

    private func makeContent(size: NSSize) -> NSView {
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(calibratedRed: 0.02, green: 0.07, blue: 0.11, alpha: 0.94).cgColor
        content.layer?.cornerRadius = 18

        stepLabel.font = .systemFont(ofSize: 15, weight: .medium)
        stepLabel.textColor = Self.accent.withAlphaComponent(0.7)
        stepLabel.frame = NSRect(x: 40, y: size.height - 52, width: 680, height: 22)
        titleLabel.font = .systemFont(ofSize: 34, weight: .bold)
        titleLabel.textColor = Self.accent
        titleLabel.frame = NSRect(x: 40, y: size.height - 96, width: 680, height: 42)
        detailLabel.font = .systemFont(ofSize: 18, weight: .regular)
        detailLabel.textColor = NSColor(calibratedWhite: 0.92, alpha: 1)
        detailLabel.frame = NSRect(x: 40, y: size.height - 156, width: 680, height: 54)

        preview.frame = NSRect(x: 60, y: 110, width: 640, height: 360)
        preview.wantsLayer = true
        preview.layer?.backgroundColor = NSColor.black.cgColor
        preview.layer?.cornerRadius = 18
        preview.layer?.masksToBounds = true
        jointsLayer.frame = preview.bounds
        jointsLayer.isGeometryFlipped = true
        jointsLayer.fillColor = Self.accent.cgColor
        jointsLayer.zPosition = 10
        preview.layer?.addSublayer(jointsLayer)

        phaseLabel.font = .monospacedDigitSystemFont(ofSize: 26, weight: .semibold)
        phaseLabel.textColor = .white
        phaseLabel.alignment = .center
        phaseLabel.frame = NSRect(x: 40, y: 54, width: 680, height: 34)
        progressTrack.frame = CGRect(x: 60, y: 34, width: 640, height: 6)
        progressTrack.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.12).cgColor
        progressTrack.cornerRadius = 3
        progressFill.frame = CGRect(x: 0, y: 0, width: 0, height: 6)
        progressFill.backgroundColor = Self.accent.cgColor
        progressFill.cornerRadius = 3
        progressTrack.addSublayer(progressFill)

        [stepLabel, titleLabel, detailLabel, preview, phaseLabel].forEach(content.addSubview)
        content.layer?.addSublayer(progressTrack)
        return content
    }

    private func attachPreview(_ session: AVCaptureSession) {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspect
        layer.frame = preview.bounds
        if let connection = layer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        preview.layer?.insertSublayer(layer, below: jointsLayer)
    }

    private func show(step: Int?, title: String, detail: String) {
        stepLabel.stringValue = step.map { "Step \($0 + 1) of \(Self.steps.count)" } ?? ""
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
    }

    private func setPhase(_ text: String, progress: Double, recording: Bool) {
        phaseLabel.stringValue = text
        phaseLabel.textColor = recording ? Self.accent : NSColor(calibratedWhite: 0.75, alpha: 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        progressFill.frame.size.width = progressTrack.bounds.width * progress
        CATransaction.commit()
    }

    private func speak(_ text: String) {
        speech.stopSpeaking(at: .immediate)
        speech.speak(AVSpeechUtterance(string: text))
    }

    private func receive(_ frame: CameraFrame) {
        drawJoints(frame)
        write(frame)
    }

    private func drawJoints(_ frame: CameraFrame) {
        let bounds = preview.bounds.size
        let scale = min(bounds.width / frame.imageSize.width, bounds.height / frame.imageSize.height)
        let shown = CGSize(width: frame.imageSize.width * scale, height: frame.imageSize.height * scale)
        let origin = CGPoint(x: (bounds.width - shown.width) / 2, y: (bounds.height - shown.height) / 2)
        let path = CGMutablePath()
        for hand in frame.hands {
            for joint in hand.joints.values where joint.confidence > 0.3 {
                let point = CGPoint(
                    x: origin.x + (1 - joint.point.x) * shown.width, y: origin.y + joint.point.y * shown.height)
                path.addEllipse(in: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8))
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        jointsLayer.path = path
        CATransaction.commit()
    }

    private func write(_ frame: CameraFrame) {
        guard currentLabel != "transition", currentLabel != "done", currentLabel != "setup" else { return }
        var counts = frameCounts[currentLabel] ?? (0, 0)
        counts.frames += 1
        if !frame.hands.isEmpty { counts.withHand += 1 }
        frameCounts[currentLabel] = counts
        let record: [String: Any] = [
            "label": currentLabel,
            "t": CACurrentMediaTime() - started,
            "visionMs": frame.visionSeconds * 1000,
            "width": frame.imageSize.width,
            "height": frame.imageSize.height,
            "hands": frame.hands.map { hand in
                [
                    "chirality": hand.chirality,
                    "joints": [String: [Double]](
                        uniqueKeysWithValues: hand.joints.map { joint, tracked in
                            (joint.rawValue, [tracked.point.x, tracked.point.y, Double(tracked.confidence)])
                        }),
                ] as [String: Any]
            },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: record) else { return }
        output.write(data + Data("\n".utf8))
    }
}
