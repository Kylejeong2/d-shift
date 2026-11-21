import AVFoundation
import AppKit
import CoreImage
import WebKit

@MainActor
final class JarvisController: NSObject {
    static let shared = JarvisController()

    private static let maxOutputTokens = 8000
    private static let cameraOpacity: Float = 0.5
    private static let backdrop = NSColor(calibratedRed: 0.01, green: 0.05, blue: 0.09, alpha: 1)

    private(set) var isOpen = false
    private let window: NSPanel
    private let webView: WKWebView
    private let cameraView = NSView()
    private let appTracker = AppTracker()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var tracker: HandTracker?
    private var recognizer = GestureRecognizer()
    private var itemRects: [CGRect] = []
    private var isLoaded = false
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []
    private var drawings: [String: Task<Void, Never>] = [:]
    private var framesReceived = 0
    private var isShowingCameraWarning = false
    private var voice: VoiceSession?
    private var toolTurn = ToolTurn()

    override init() {
        window = NSPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isOpaque = true
        window.backgroundColor = Self.backdrop
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.ignoresMouseEvents = true
        let configuration = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        super.init()
        configuration.userContentController.add(JarvisMessageReceiver(controller: self), name: "jarvis")
        webView.navigationDelegate = self

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = Self.backdrop.cgColor
        cameraView.wantsLayer = true
        cameraView.layerUsesCoreImageFilters = true
        for view in [cameraView, webView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                view.topAnchor.constraint(equalTo: container.topAnchor),
                view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        window.contentView = container
    }

    func toggle() {
        if isOpen { close() } else { Task { await open() } }
    }

    func open(useCamera: Bool = true, useVoice: Bool = true) async {
        guard !isOpen else { return }
        isOpen = true
        let screen = NSScreen.underMouse
        window.setFrame(screen.frame, display: false)
        await loadIfNeeded()
        let origin = OverlayController.globalFrame(of: screen).origin
        call("jarvis.setOrigin(x, y)", ["x": origin.x, "y": origin.y])
        window.orderFrontRegardless()
        call("jarvis.showGuide()")
        if useVoice { startVoice() }
        guard useCamera else { return }
        let tracker = HandTracker { [weak self] frame in self?.receive(frame) }
        self.tracker = tracker
        do {
            try await tracker.start()
            guard isOpen, self.tracker === tracker else { return tracker.stop() }
            attachPreview(to: tracker.session)
            Log.info("jarvis", "camera started")
            framesReceived = 0
            try? await Task.sleep(for: .seconds(5))
            if isOpen, self.tracker === tracker, !tracker.hasDeliveredFrame {
                isShowingCameraWarning = true
                call(
                    "jarvis.showStatus(text, 0)",
                    ["text": "No video from the camera. Check that no other app is using it, or connect a webcam."])
            }
        } catch {
            self.tracker = nil
            call("jarvis.showStatus(text, 0)", ["text": error.localizedDescription])
        }
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        voice?.stop()
        voice = nil
        tracker?.stop()
        tracker = nil
        previewLayer?.removeFromSuperlayer()
        previewLayer = nil
        recognizer = GestureRecognizer()
        toolTurn = ToolTurn()
        drawings.values.forEach { $0.cancel() }
        drawings = [:]
        window.orderOut(nil)
        isLoaded = false
        webView.loadHTMLString("", baseURL: nil)
        Log.info("jarvis", "closed, camera and microphone off")
    }

    func feed(_ samples: [HandSample], at time: TimeInterval) {
        let rects = itemRects
        let frame = recognizer.update(samples, at: time) { point in rects.contains { $0.contains(point) } }
        let pointers = frame.pointers.map { pointer -> [String: Any] in
            [
                "hand": pointer.hand, "x": pointer.point.x, "y": pointer.point.y, "pose": pointer.pose.rawValue,
                "action": pointer.action.rawValue,
                "joints": [String: [CGFloat]](
                    uniqueKeysWithValues: pointer.joints.map { ($0.key.rawValue, [$0.value.x, $0.value.y]) }),
            ]
        }
        let events = frame.events.map { event -> [String: Any] in
            switch event {
            case .draw(let hand, let phase, let point):
                ["type": "draw", "hand": hand, "phase": phase.rawValue, "x": point.x, "y": point.y]
            case .hold(let hand, let phase, let point, let scale):
                ["type": "hold", "hand": hand, "phase": phase.rawValue, "x": point.x, "y": point.y, "scale": scale]
            case .rub(let point, let radius):
                ["type": "rub", "x": point.x, "y": point.y, "radius": radius]
            }
        }
        call("jarvis.frame(pointers, events)", ["pointers": pointers, "events": events])
    }

    func drawOnScreen(request: String, aboutScreen: Bool) async throws {
        if !isOpen { await open() }
        guard OpenAIClient.hasKey else { throw ToolError.failed("No OpenAI API key, so Jarvis can't draw.") }
        let id = await startDrawing(request: request, aboutScreen: aboutScreen)
        if let id { await drawings[id]?.value }
    }

    func evaluate(_ script: String, _ arguments: [String: Any] = [:]) async -> Any? {
        do {
            return try await webView.callAsyncJavaScript(script, arguments: arguments, contentWorld: .page)
        } catch {
            return "error: \(error)"
        }
    }

    func snapshot() async -> Data? {
        guard let image = try? await webView.takeSnapshot(configuration: nil), let tiff = image.tiffRepresentation
        else { return nil }
        return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }

    fileprivate func handle(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "items":
            itemRects = (message["rects"] as? [[Double]] ?? []).prefix(200).compactMap { values in
                values.count == 4 ? CGRect(x: values[0], y: values[1], width: values[2], height: values[3]) : nil
            }
        default:
            break
        }
    }

    @discardableResult
    private func startDrawing(request: String, aboutScreen: Bool) async -> String? {
        let mode = aboutScreen ? "screen" : "flow"
        guard
            let id = await evaluate(
                "return jarvis.beginVisual(label, mode)", ["label": request, "mode": mode]) as? String
        else { return nil }
        let context =
            aboutScreen
            ? await OverlayTool.screenContext(for: request, tracker: appTracker, standalone: false) : nil
        if let screen = context?.screen, screen.frame != window.frame {
            window.setFrame(screen.frame, display: true)
            let origin = OverlayController.globalFrame(of: screen).origin
            call("jarvis.setOrigin(x, y)", ["x": origin.x, "y": origin.y])
            call("jarvis.placeAtOrigin(id)", ["id": id])
        }
        let instructions = aboutScreen ? OverlayTool.instructions + "\n\n" + Self.jarvisLook : Self.visualInstructions
        let input = context?.prompt ?? "Item id prefix: \(id)-\n\nRequest: \(request)"
        drawings[id] = Task { [weak self] in
            var html = ""
            var lastPreview = Date.distantPast
            do {
                for try await event in OpenAIClient.stream(
                    instructions: instructions, input: input, jpeg: context?.jpeg, effort: "low",
                    maxOutputTokens: Self.maxOutputTokens)
                {
                    guard case .text(let delta) = event else { continue }
                    html += delta
                    if Date().timeIntervalSince(lastPreview) > 0.08 {
                        self?.call("jarvis.streamVisual(id, html, false)", ["id": id, "html": html])
                        lastPreview = Date()
                    }
                }
                self?.call("jarvis.streamVisual(id, html, true)", ["id": id, "html": html])
            } catch {
                self?.call("jarvis.failVisual(id, message)", ["id": id, "message": error.localizedDescription])
            }
            self?.drawings[id] = nil
        }
        return id
    }

    private func receive(_ frame: CameraFrame) {
        guard isOpen else { return }
        framesReceived += 1
        if isShowingCameraWarning {
            isShowingCameraWarning = false
            call("jarvis.showStatus('', 0)")
        }
        if framesReceived == 1 || framesReceived.isMultiple(of: 300) {
            Log.info(
                "jarvis",
                String(
                    format: "camera frame %d: %dx%d, vision %.1f ms, hands %d", framesReceived,
                    Int(frame.imageSize.width), Int(frame.imageSize.height), frame.visionSeconds * 1000,
                    frame.hands.count))
        }
        let bounds = window.frame.size
        let samples = frame.hands.map { hand in
            HandSample(
                joints: hand.joints.filter { $0.value.confidence > 0.2 }.mapValues {
                    Self.screenPoint(devicePoint: $0.point, imageSize: frame.imageSize, viewSize: bounds)
                })
        }
        feed(samples, at: CACurrentMediaTime())
    }

    nonisolated static func screenPoint(devicePoint: CGPoint, imageSize: CGSize, viewSize: CGSize) -> CGPoint {
        let scale = max(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let shown = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGPoint(
            x: (viewSize.width - shown.width) / 2 + (1 - devicePoint.x) * shown.width,
            y: (viewSize.height - shown.height) / 2 + devicePoint.y * shown.height)
    }

    private func attachPreview(to session: AVCaptureSession) {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = cameraView.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer.opacity = Self.cameraOpacity
        layer.filters = [CIFilter(name: "CIColorControls", parameters: [kCIInputSaturationKey: 0.55])].compactMap { $0 }
        if let connection = layer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        cameraView.layer?.addSublayer(layer)
        previewLayer = layer
    }

    private func startVoice() {
        let voice = VoiceSession(
            onEvent: { [weak self] in self?.handleVoice($0) },
            onLevel: { [weak self] in self?.call("jarvis.level(value)", ["value": $0]) })
        self.voice = voice
        call("jarvis.voiceState('connecting')")
        Task {
            do {
                try await voice.start(
                    sessionUpdate: RealtimeEvents.sessionUpdate(
                        instructions: Self.voiceInstructions, tools: Self.voiceTools))
                guard self.voice === voice else { return voice.stop() }
                call("jarvis.voiceState('listening')")
                Log.info("jarvis", "voice connected")
            } catch {
                voice.stop()
                guard self.voice === voice else { return }
                self.voice = nil
                call("jarvis.voiceState('off')")
                call("jarvis.showStatus(text, 8)", ["text": error.localizedDescription])
            }
        }
    }

    private func handleVoice(_ event: RealtimeServerEvent) {
        guard let voice, isOpen else { return }
        switch event {
        case .audioDelta:
            call("jarvis.voiceState('speaking')")
        case .speechStarted:
            call("jarvis.voiceState('listening')")
        case .functionCall(let callId, let name, let arguments):
            toolTurn.toolStarted()
            Task {
                let output = await runVoiceTool(name: name, arguments: arguments)
                Log.info("jarvis", "voice tool \(name) -> \(output.prefix(160))")
                voice.send(RealtimeEvents.functionOutput(callId: callId, output: output))
                if toolTurn.toolFinished() { voice.send(RealtimeEvents.responseCreate) }
            }
        case .responseCreated:
            toolTurn.responseCreated()
        case .responseDone:
            call("jarvis.voiceState('listening')")
            if toolTurn.responseDone() { voice.send(RealtimeEvents.responseCreate) }
        case .error(let message):
            Log.info("jarvis", "voice error: \(message)")
            call("jarvis.showStatus(text, 6)", ["text": "Voice: \(message)"])
        case .speechStopped, .other:
            break
        }
    }

    func runVoiceTool(name: String, arguments: String) async -> String {
        let input = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any] ?? [:]
        let selector: Any = (input["ids"] as? [String]).flatMap { $0.isEmpty ? nil : $0 } ?? input["target"] ?? "all"
        let result: Any?
        switch name {
        case "draw":
            let request = String((input["request"] as? String ?? "").prefix(2000))
            guard OpenAIClient.hasKey else { return #"{"ok":false,"error":"no OpenAI key"}"# }
            let id = await startDrawing(request: request, aboutScreen: input["about_screen"] as? Bool ?? false)
            return Self.json(["ok": id != nil, "id": id ?? "", "status": "drawing now, visible in a few seconds"])
        case "write_note":
            let text = String((input["text"] as? String ?? "").prefix(500))
            result = await evaluate(
                "return jarvis.addNote(text, x, y)",
                ["text": text, "x": input["x"] ?? NSNull(), "y": input["y"] ?? NSNull()])
        case "list_items":
            result = await evaluate("return jarvis.listItems()")
        case "arrange_items":
            result = await evaluate(
                "return jarvis.arrange(selector, place, layout)",
                [
                    "selector": selector, "place": input["place"] as? String ?? "center",
                    "layout": input["layout"] as? String ?? "grid",
                ])
        case "move_item":
            result = await evaluate(
                "return jarvis.moveItem(id, x, y)",
                ["id": input["id"] as? String ?? "", "x": input["x"] ?? 0, "y": input["y"] ?? 0])
        case "scale_items":
            result = await evaluate(
                "return jarvis.scaleItems(selector, factor)", ["selector": selector, "factor": input["factor"] ?? 1])
        case "delete_items":
            result = await evaluate("return jarvis.deleteItems(selector)", ["selector": selector])
        case "restore_deleted":
            result = await evaluate("return jarvis.restore()")
        case "look_at_screen":
            return await lookAtScreen(scope: input["scope"] as? String == "screen" ? "screen" : "window")
        case "close_jarvis":
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                close()
            }
            return #"{"ok":true}"#
        default:
            return #"{"ok":false,"error":"unknown tool"}"#
        }
        return Self.json(["ok": true, "result": result ?? NSNull()])
    }

    private func lookAtScreen(scope: String) async -> String {
        let screenshot = try? await ScreenshotTool(tracker: appTracker).run(["scope": scope])
        if let jpeg = screenshot?.jpeg { voice?.send(RealtimeEvents.inputImage(jpeg)) }
        let app = appTracker.app
        let snapshot = await Task.detached { app.map { AXSnapshot.capture(app: $0) } }.value
        return Self.json([
            "ok": true,
            "app": snapshot?.appName ?? "unknown",
            "window": snapshot?.windowTitle ?? "",
            "screenshot": screenshot?.jpeg == nil
                ? "unavailable: Screen Recording permission is off, so use the window text below"
                : "attached as an image in the conversation",
            "windowText": String((snapshot?.tree ?? "").prefix(6000)),
        ])
    }

    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed]) else {
            return #"{"ok":false}"#
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func call(_ script: String, _ arguments: [String: Any] = [:]) {
        webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page, completionHandler: nil)
    }

    private func loadIfNeeded() async {
        guard !isLoaded else { return }
        webView.loadHTMLString(JarvisPage.html, baseURL: OverlayPage.baseURL)
        await withCheckedContinuation { loadWaiters.append($0) }
        isLoaded = true
    }

    private func finishLoad() {
        loadWaiters.forEach { $0.resume() }
        loadWaiters = []
    }

    private static let jarvisLook = """
        Jarvis mode style: a deep-navy space (#02121d) with the user's own camera image behind it. Use crisp 1.5px \
        lines and text in ice blue (#8fd8ff) for what matters and near-white (#f2f8fc) for content, on solid navy \
        panels (#0b1d2b) with 12px corners when a panel is needed. No glows, drop shadows, gradients, grids, scan \
        lines, corner brackets, or decorative spinning arcs. Use the system font (SF Pro) in sentence case with few, \
        short labels. Motion is quick and eased: strokes that draw on once, never looping effects.
        """

    private static let visualInstructions = """
        You are drawing one visual that floats in Jarvis mode's dark, deep-navy holographic space, which covers the user's screen. The user \
        moves and resizes it with their hands. Output only an HTML fragment: no markdown fences, no <html>, <head>, or \
        <body>, and no commentary.

        Layout: normal document flow inside a box at most 560px wide and 480px tall. Never use position: fixed, \
        viewport units, or screen coordinates. Keep the background transparent apart from translucent panels. Other \
        visuals share the page, so start every class name and id with the item id prefix you're given, and never \
        style bare element selectors like body, div, or svg.

        \(jarvisLook)

        Make it a visual, not a paragraph: an animated SVG diagram, chart, schematic, or illustration. For a 3D object \
        or scene, use three.js from https://cdn.jsdelivr.net (an ES module import) rendering into a <canvas> of at \
        most 520x420 with a transparent background, a wireframe or glowing light-blue material, and a slow rotation. \
        Keep labels to a few words.

        The HTML renders while you stream it, and each <script> runs as soon as its closing tag arrives. Write the \
        <style> first, then elements in reading order.

        \(OverlayTool.scriptRules)

        Keep it under about 180 lines.
        """

    static let voiceInstructions = """
        You are Jarvis, the voice of D-Shift's heads-up display. Everything you create floats in a dark holographic \
        space that covers their screen. The user also draws (pointing), picks things up (open hand held still), resizes \
        (spread fingers), and erases (rubbing) with their hands, so items may change between turns: call list_items \
        before moving, resizing, or deleting existing items, and not before creating new ones.

        You control the whole overlay with tools: draw creates visuals, diagrams, charts, and 3D models (set \
        about_screen only when it should point at or annotate something in their focused window); write_note pins text; \
        arrange_items, move_item, and scale_items reposition and resize; delete_items removes; restore_deleted undoes \
        the last removal. "Drawings" means hand-drawn strokes; "visuals" are what you drew; "everything" is all items.

        Jarvis covers the user's screen, but you can see what's behind it: call look_at_screen whenever they ask \
        about or refer to their screen, then answer from the screenshot. Only look when they ask.

        Act first, then confirm in a few words. Keep speech to one short sentence unless asked for more. Never read \
        item contents aloud.
        """

    private static let selectorProperties: [String: Any] = [
        "target": [
            "type": "string", "enum": ["all", "drawings", "notes", "visuals"],
            "description": "Which kind of items, when not naming ids.",
        ],
        "ids": ["type": "array", "items": ["type": "string"], "description": "Specific item ids from list_items."],
    ]

    static let voiceTools = [
        RealtimeTool(
            name: "draw",
            description: "Draw a visual on the screen: a diagram, chart, illustration, schematic, or 3D model.",
            parameters: [
                "type": "object",
                "properties": [
                    "request": ["type": "string", "description": "What to draw, specifically."],
                    "about_screen": [
                        "type": "boolean",
                        "description":
                            "Only true when the user refers to something visible in their focused window (this button, what's on my screen). False for general diagrams and explanations.",
                    ],
                ],
                "required": ["request"],
            ]),
        RealtimeTool(
            name: "write_note", description: "Pin a short text note on the screen.",
            parameters: [
                "type": "object",
                "properties": [
                    "text": ["type": "string"], "x": ["type": "number"], "y": ["type": "number"],
                ],
                "required": ["text"],
            ]),
        RealtimeTool(
            name: "list_items",
            description:
                "List everything on the overlay with ids, kinds, labels, positions, and sizes in screen points.",
            parameters: ["type": "object", "properties": [String: Any]()]),
        RealtimeTool(
            name: "arrange_items", description: "Move a group of items to a region of the screen and lay them out.",
            parameters: [
                "type": "object",
                "properties": selectorProperties.merging([
                    "place": [
                        "type": "string",
                        "enum": [
                            "top-left", "top-right", "bottom-left", "bottom-right", "center", "left", "right", "top",
                            "bottom",
                        ],
                    ],
                    "layout": ["type": "string", "enum": ["grid", "row", "column", "stack"]],
                ]) { current, _ in current },
                "required": ["place"],
            ]),
        RealtimeTool(
            name: "move_item", description: "Move one item so its top-left corner is at x, y in screen points.",
            parameters: [
                "type": "object",
                "properties": ["id": ["type": "string"], "x": ["type": "number"], "y": ["type": "number"]],
                "required": ["id", "x", "y"],
            ]),
        RealtimeTool(
            name: "scale_items", description: "Resize items by a factor, such as 2 for twice as big.",
            parameters: [
                "type": "object",
                "properties": selectorProperties.merging(["factor": ["type": "number"]]) { current, _ in current },
                "required": ["factor"],
            ]),
        RealtimeTool(
            name: "delete_items", description: "Remove items from the screen. They can be restored.",
            parameters: ["type": "object", "properties": selectorProperties]),
        RealtimeTool(
            name: "restore_deleted", description: "Bring back the most recently removed item.",
            parameters: ["type": "object", "properties": [String: Any]()]),
        RealtimeTool(
            name: "look_at_screen",
            description:
                "See what's on the user's screen behind Jarvis: a screenshot of their focused window (or the whole screen) plus the window's text. Call it whenever they ask about or refer to their screen.",
            parameters: [
                "type": "object",
                "properties": ["scope": ["type": "string", "enum": ["window", "screen"]]],
            ]),
        RealtimeTool(
            name: "close_jarvis",
            description: "Close Jarvis mode when the user asks to exit or close it. This clears the overlay.",
            parameters: ["type": "object", "properties": [String: Any]()]),
    ]
}

extension JarvisController: WKNavigationDelegate {
    nonisolated func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        MainActor.assumeIsolated {
            let url = navigationAction.request.url
            decisionHandler(url == OverlayPage.baseURL || url?.absoluteString == "about:blank" ? .allow : .cancel)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { finishLoad() }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { finishLoad() }
    }

    nonisolated func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
    ) {
        MainActor.assumeIsolated { finishLoad() }
    }
}

private final class JarvisMessageReceiver: NSObject, WKScriptMessageHandler {
    private weak var controller: JarvisController?

    init(controller: JarvisController) {
        self.controller = controller
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        MainActor.assumeIsolated { self.controller?.handle(body) }
    }
}
