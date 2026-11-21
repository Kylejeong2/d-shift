import AVFoundation
import AppKit

// `DShift --codex-test "<task>"` runs one Computer Use task headlessly, answering app permission prompts with
// "allow once", and prints the result. For debugging the Codex integration without the UI.
if let flag = CommandLine.arguments.firstIndex(of: "--codex-test"), CommandLine.arguments.count > flag + 1 {
    let task = CommandLine.arguments[flag + 1]
    Task { @MainActor in
        guard let codex = ComputerUseTool.locateCodex() else {
            print("Codex CLI not found")
            exit(1)
        }
        do {
            let result = try await CodexRunner.run(
                task: task, codexPath: codex,
                progress: { print("progress:", String($0.split(separator: "\n").last ?? "")) },
                requestAccess: { app in
                    print("access requested:", app, "-> allowing once")
                    return .once
                })
            print("RESULT:", result)
            exit(0)
        } catch {
            print("ERROR:", error.localizedDescription)
            exit(1)
        }
    }
    RunLoop.main.run()
}

// `DShift --diagram-test <out.jpg>` renders a sample Mermaid diagram, for checking the renderer headlessly.
if let flag = CommandLine.arguments.firstIndex(of: "--diagram-test"), CommandLine.arguments.count > flag + 1 {
    let out = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
    Task { @MainActor in
        do {
            let image = try await DiagramRenderer.shared.render(
                """
                flowchart TD
                  subgraph You
                    A[User enters card] --> B[Evervault SDK encrypts]
                    B --> C[(Your DB: ciphertext)]
                  end
                  subgraph Evervault
                    K[Keys]
                    R[Relay decrypts in transit]
                  end
                  C --> R --> P[Stripe / Adyen]
                  K -.-> R
                """)
            try image.write(to: out)
            print("wrote", out.path, image.count, "bytes")
            exit(0)
        } catch {
            print("ERROR:", error.localizedDescription)
            exit(1)
        }
    }
    _ = NSApplication.shared
    RunLoop.main.run()
}

// `DShift --overlay-test "<request>" <out-dir> [--standalone] [--model] [--drag]` draws on screen over the frontmost app, screenshots the screen every
// half second while it streams and once after it settles, and saves the HTML, for iterating on the overlay.
if let flag = CommandLine.arguments.firstIndex(of: "--overlay-test"), CommandLine.arguments.count > flag + 2 {
    let request = CommandLine.arguments[flag + 1]
    let outDir = URL(fileURLWithPath: CommandLine.arguments[flag + 2], isDirectory: true)
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    Task { @MainActor in
        // Runs screencapture off the main actor: it takes about a second per large display, and blocking the main
        // thread would starve the overlay's web view.
        let isModel = CommandLine.arguments.contains("--model")
        let capture = { (name: String) async in
            if isModel { return }  // models are checked through their own renders below
            let paths = NSScreen.screens.indices.map {
                outDir.appendingPathComponent("\(name)-display\($0 + 1).png").path
            }
            await Task.detached {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = ["-x"] + paths
                try? process.run()
                process.waitUntilExit()
            }.value
        }
        let tracker = AppTracker()
        print("drawing over", tracker.app?.localizedName ?? "nothing")
        let started = Date()
        var finished = false
        let drawing = Task {
            defer { finished = true }
            if CommandLine.arguments.contains("--model") { return try await ModelTool().run(["description": request]) }
            return try await OverlayTool(tracker: tracker).run([
                "description": request, "standalone": CommandLine.arguments.contains("--standalone"),
            ])
        }
        var frame = 0
        while !finished {
            try? await Task.sleep(for: .milliseconds(500))
            frame += 1
            await capture(String(format: "stream-%02d", frame))
        }
        do {
            let output = try await drawing.value
            print(output.text, String(format: "%.1fs", Date().timeIntervalSince(started)))
        } catch {
            print("ERROR:", error.localizedDescription)
        }
        if isModel, let window = ModelHistory.lastWindow {
            try? window.snapshotJPEG()?.write(to: outDir.appendingPathComponent("model-first.jpg"))
            await window.polish?.value
            try? await Task.sleep(for: .milliseconds(500))
            try? window.snapshotJPEG()?.write(to: outDir.appendingPathComponent("model-polished.jpg"))
        }
        try? await Task.sleep(for: .milliseconds(2500))
        await capture("final")
        // Drag the first card by its top edge (moves it), then across its middle (rotates a 3D model inside it).
        let post = { (type: CGEventType, point: CGPoint) in
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(
                tap: .cghidEventTap)
        }
        let drag = { (from: CGPoint, offset: CGVector) async in
            post(.mouseMoved, from)
            try? await Task.sleep(for: .milliseconds(150))
            post(.leftMouseDown, from)
            for step in 1...30 {
                let fraction = CGFloat(step) / 30
                post(.leftMouseDragged, CGPoint(x: from.x + offset.dx * fraction, y: from.y + offset.dy * fraction))
                try? await Task.sleep(for: .milliseconds(16))
            }
            post(.leftMouseUp, CGPoint(x: from.x + offset.dx, y: from.y + offset.dy))
            try? await Task.sleep(for: .milliseconds(800))
        }
        // Synthetic drags land on whatever app is underneath if the overlay misses them, so only run them when asked
        // (`--drag`), over a window that's safe to click into.
        if CommandLine.arguments.contains("--drag"), let card = OverlayController.shared.interactiveAreas.first {
            await drag(CGPoint(x: card.midX, y: card.minY + 6), CGVector(dx: -300, dy: 120))
            await capture("after-move")
            let moved = card.offsetBy(dx: -300, dy: 120)
            await drag(CGPoint(x: moved.midX - 60, y: moved.midY), CGVector(dx: 160, dy: 40))
            await capture("after-rotate")
            print("dragged card at", card)
        }
        try? OverlayController.shared.lastPrompt.write(
            to: outDir.appendingPathComponent("prompt.txt"), atomically: true, encoding: .utf8)
        try? OverlayController.shared.lastHTML.write(
            to: outDir.appendingPathComponent("drawing.html"), atomically: true, encoding: .utf8)
        print("wrote", outDir.path)
        exit(0)
    }
    RunLoop.main.run()
}

// `DShift --scratchpad-test <out.png>` writes and draws in the scratchpad, then saves a snapshot of it and prints what
// `read` returns, for checking drawings without a chat.
if let flag = CommandLine.arguments.firstIndex(of: "--scratchpad-test"), CommandLine.arguments.count > flag + 1 {
    let out = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    Task { @MainActor in
        let tool = ScratchpadTool()
        for input: JSON in [
            [
                "action": "write",
                "text": """
                # Trip budget
                Flights and hotel for **3 nights** in Lisbon.

                1. Flights: `$420`
                2. Hotel: 3 x $140 = `$420`
                3. Food and transit: about $60/day

                - [x] Book flights
                - [ ] Book hotel
                - [ ] Pick a day trip

                > Total: about **$1,020**
                """,
            ],
            [
                "action": "draw", "caption": "y = sin(x)", "height": 200,
                "code": """
                ctx.strokeStyle = "#ff9f0a"; ctx.lineWidth = 2; ctx.beginPath();
                for (let x = 0; x <= width; x++) { const y = height / 2 - Math.sin(x / width * Math.PI * 4) * 70; x ? ctx.lineTo(x, y) : ctx.moveTo(x, y); }
                ctx.stroke(); ctx.fillStyle = "#fff"; ctx.beginPath(); ctx.arc(width / 8, height / 2 - 70, 5, 0, Math.PI * 2); ctx.fill();
                """,
            ],
            ["action": "draw", "caption": "Broken code", "code": "undefinedFunction()"],
            ["action": "read"],
        ] {
            do {
                print(input["action"]!, "->", try await tool.run(input).text)
            } catch {
                print(input["action"]!, "-> ERROR", error.localizedDescription)
            }
        }
        try? await Task.sleep(for: .seconds(1))
        try? await Scratchpad.shared.snapshot()?.write(to: out)
        print("wrote", out.path)
        exit(0)
    }
    RunLoop.main.run()
}

if let flag = CommandLine.arguments.firstIndex(of: "--hand-record"), CommandLine.arguments.count > flag + 1 {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    Task { @MainActor in
        do {
            try await HandRecorder(url: URL(fileURLWithPath: CommandLine.arguments[flag + 1])).run()
            exit(0)
        } catch {
            print("ERROR:", error.localizedDescription)
            exit(1)
        }
    }
    RunLoop.main.run()
}

if let flag = CommandLine.arguments.firstIndex(of: "--voice-latency"), CommandLine.arguments.count > flag + 1 {
    let phrase = CommandLine.arguments[flag + 1]
    let detection = CommandLine.arguments.dropFirst(flag + 2).first ?? "semantic_vad"
    Task {
        let aiff = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("jarvis-latency.aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", aiff.path, phrase]
        try say.run()
        say.waitUntilExit()
        let file = try AVAudioFile(forReading: aiff)
        let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true)!
        let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: source)
        let converter = AVAudioConverter(from: file.processingFormat, to: target)!
        let converted = AVAudioPCMBuffer(
            pcmFormat: target,
            frameCapacity: AVAudioFrameCount(Double(file.length) * 24_000 / file.processingFormat.sampleRate) + 64)!
        var consumed = false
        converter.convert(to: converted, error: nil) { _, status in
            defer { consumed = true }
            status.pointee = consumed ? .endOfStream : .haveData
            return consumed ? nil : source
        }
        let speech = Data(bytes: converted.int16ChannelData![0], count: Int(converted.frameLength) * 2)

        var request = URLRequest(url: RealtimeEvents.url)
        request.setValue("Bearer \(Config.value("OPENAI_API_KEY") ?? "")", forHTTPHeaderField: "authorization")
        let socket = URLSession.shared.webSocketTask(with: request)
        socket.resume()
        let turnDetection: [String: Any] =
            switch detection {
            case "server_vad": ["type": "server_vad", "silence_duration_ms": 350]
            case "semantic_high": ["type": "semantic_vad", "eagerness": "high"]
            default: ["type": "semantic_vad"]
            }
        try await socket.send(
            .string(
                RealtimeEvents.sessionUpdate(
                    instructions: "Answer in one short sentence.", tools: [], turnDetection: turnDetection)))
        let chunk = 4800
        let silence = Data(count: chunk)
        var speechEnded = 0.0
        let streamer = Task {
            try? await Task.sleep(for: .milliseconds(500))
            for offset in stride(from: 0, to: speech.count, by: chunk) {
                try await socket.send(
                    .string(RealtimeEvents.appendAudio(speech.subdata(in: offset..<min(offset + chunk, speech.count)))))
                try await Task.sleep(for: .milliseconds(100))
            }
            speechEnded = CACurrentMediaTime()
            for _ in 0..<40 {
                try await socket.send(.string(RealtimeEvents.appendAudio(silence)))
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        var marks: [(String, Double)] = []
        while true {
            guard case .string(let text) = try await socket.receive() else { continue }
            let now = CACurrentMediaTime()
            switch RealtimeEvents.parse(text) {
            case .speechStopped: marks.append(("speech stopped", now))
            case .responseCreated: marks.append(("response created", now))
            case .audioDelta:
                if !marks.contains(where: { $0.0 == "first audio" }) { marks.append(("first audio", now)) }
            case .responseDone: marks.append(("response done", now))
            case .error(let message): print("ERROR:", message)
            default: break
            }
            if marks.contains(where: { $0.0 == "response done" }) { break }
        }
        streamer.cancel()
        print("turn detection:", detection)
        for (name, time) in marks {
            print(String(format: "  %@: %+.0f ms after speech ended", name, (time - speechEnded) * 1000))
        }
        exit(0)
    }
    RunLoop.main.run()
}

if let flag = CommandLine.arguments.firstIndex(of: "--hand-replay"), CommandLine.arguments.count > flag + 1 {
    let lines =
        (try? String(contentsOfFile: CommandLine.arguments[flag + 1], encoding: .utf8))?.split(separator: "\n") ?? []
    var counts: [String: [HandPose: Int]] = [:]
    var stable: [String: (pose: HandPose, candidate: HandPose?, count: Int)] = [:]
    for line in lines {
        guard let record = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
            let label = record["label"] as? String, let width = record["width"] as? Double,
            let height = record["height"] as? Double,
            let hand = (record["hands"] as? [[String: Any]])?.max(by: {
                ($0["joints"] as? [String: Any])?.count ?? 0 < ($1["joints"] as? [String: Any])?.count ?? 0
            }),
            let joints = hand["joints"] as? [String: [Double]]
        else { continue }
        var points: [HandJoint: CGPoint] = [:]
        for (name, value) in joints where value[2] > 0.2 {
            if let joint = HandJoint(rawValue: name) {
                points[joint] = CGPoint(x: value[0] * width, y: value[1] * height)
            }
        }
        var state = stable[label] ?? (.between, nil, 0)
        if let raw = HandFeatures(points)?.pose {
            if raw == state.pose {
                state.candidate = nil
            } else if raw == state.candidate {
                state.count += 1
                if state.count >= GestureRecognizer.stableFrames - 1 { state = (raw, nil, 0) }
            } else {
                state = (state.pose, raw, 0)
            }
        }
        stable[label] = state
        counts[label, default: [:]][state.pose, default: 0] += 1
    }
    for label in ["point", "pinch", "fist", "grip", "open", "spread", "rub"] {
        let row = counts[label] ?? [:]
        let total = max(1, row.values.reduce(0, +))
        let cells = [HandPose.point, .open, .closed, .between].map { "\($0.rawValue) \(100 * (row[$0] ?? 0) / total)%" }
        print(label.padding(toLength: 8, withPad: " ", startingAt: 0), cells.joined(separator: "  "))
    }
    print()
    print("Full recognizer per label (isOverItem always true):")
    let view = CGSize(width: 1728, height: 1117)
    var framesByLabel: [String: [(Double, HandSample)]] = [:]
    for line in lines {
        guard let record = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
            let label = record["label"] as? String, let time = record["t"] as? Double,
            let width = record["width"] as? Double, let height = record["height"] as? Double,
            let hands = record["hands"] as? [[String: Any]]
        else { continue }
        for hand in hands.prefix(1) {
            var points: [HandJoint: CGPoint] = [:]
            for (name, value) in hand["joints"] as? [String: [Double]] ?? [:] where value[2] > 0.2 {
                guard let joint = HandJoint(rawValue: name) else { continue }
                points[joint] = JarvisController.screenPoint(
                    devicePoint: CGPoint(x: value[0], y: value[1]), imageSize: CGSize(width: width, height: height),
                    viewSize: view)
            }
            framesByLabel[label, default: []].append((time, HandSample(joints: points)))
        }
    }
    for label in ["point", "pinch", "fist", "grip", "open", "spread", "rub"] {
        var recognizer = GestureRecognizer()
        var strokes = 0, holds = 0, drops = 0, rubs = 0, firstRub: Int?
        var scales: [CGFloat] = []
        for (index, (time, sample)) in (framesByLabel[label] ?? []).enumerated() {
            for event in recognizer.update([sample], at: time, isOverItem: { _ in true }).events {
                switch event {
                case .draw(_, .began, _): strokes += 1
                case .hold(_, .began, _, _): holds += 1
                case .hold(_, .ended, _, let scale):
                    drops += 1
                    scales.append(scale)
                case .hold(_, .moved, _, let scale): scales.append(scale)
                case .rub:
                    rubs += 1
                    if firstRub == nil { firstRub = index }
                default: break
                }
            }
        }
        let range = scales.isEmpty ? "-" : String(format: "%.2f to %.2f", scales.min()!, scales.max()!)
        print(
            label.padding(toLength: 8, withPad: " ", startingAt: 0),
            "strokes \(strokes)  holds \(holds)  drops \(drops)  rub frames \(rubs) (first at \(firstRub.map(String.init) ?? "-"))  scale \(range)"
        )
    }
    exit(0)
}

if CommandLine.arguments.contains("--voice-image-test") {
    _ = NSApplication.shared
    Task { @MainActor in
        let image = NSImage(size: NSSize(width: 640, height: 240), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            ("The secret word is pineapple" as NSString).draw(
                at: NSPoint(x: 40, y: 100), withAttributes: [.font: NSFont.systemFont(ofSize: 36, weight: .bold)])
            return true
        }
        guard let tiff = image.tiffRepresentation,
            let jpeg = NSBitmapImageRep(data: tiff)?.representation(using: .jpeg, properties: [:])
        else { exit(1) }
        var request = URLRequest(url: RealtimeEvents.url)
        request.setValue("Bearer \(Config.value("OPENAI_API_KEY") ?? "")", forHTTPHeaderField: "authorization")
        let socket = URLSession.shared.webSocketTask(with: request)
        socket.resume()
        try await socket.send(.string(RealtimeEvents.sessionUpdate(instructions: "Be brief.", tools: [])))
        try await socket.send(.string(RealtimeEvents.inputImage(jpeg)))
        let question: [String: Any] = [
            "type": "conversation.item.create",
            "item": [
                "type": "message", "role": "user",
                "content": [["type": "input_text", "text": "What is the secret word in the image?"]],
            ],
        ]
        try await socket.send(
            .string(String(decoding: try JSONSerialization.data(withJSONObject: question), as: UTF8.self)))
        try await socket.send(.string(RealtimeEvents.responseCreate))
        while true {
            guard case .string(let text) = try await socket.receive() else { continue }
            if text.contains("output_audio_transcript.done") || text.contains("\"type\":\"error\"") {
                print(text.prefix(400))
            }
            if text.contains("\"type\":\"response.done\"") || text.contains("\"type\":\"error\"") { exit(0) }
        }
    }
    RunLoop.main.run()
}

if let flag = CommandLine.arguments.firstIndex(of: "--voice-test") {
    let phrase = CommandLine.arguments.dropFirst(flag + 1).first ?? "Move all my drawings into the corner."
    Task { @MainActor in
        var request = URLRequest(url: RealtimeEvents.url)
        request.setValue("Bearer \(Config.value("OPENAI_API_KEY") ?? "")", forHTTPHeaderField: "authorization")
        let socket = URLSession.shared.webSocketTask(with: request)
        socket.resume()
        let message: [String: Any] = [
            "type": "conversation.item.create",
            "item": ["type": "message", "role": "user", "content": [["type": "input_text", "text": phrase]]],
        ]
        let fakeItems =
            #"[{"id":"d1","kind":"drawing","label":"hand-drawn stroke"},{"id":"d2","kind":"drawing","label":"hand-drawn stroke"},{"id":"n3","kind":"note","label":"Groceries"}]"#
        try await socket.send(
            .string(
                RealtimeEvents.sessionUpdate(
                    instructions: JarvisController.voiceInstructions, tools: JarvisController.voiceTools)))
        try await socket.send(
            .string(String(decoding: try JSONSerialization.data(withJSONObject: message), as: UTF8.self)))
        try await socket.send(.string(RealtimeEvents.responseCreate))
        var pendingOutput = false
        var responses = 0
        while responses < 4 {
            guard case .string(let text) = try await socket.receive() else { continue }
            switch RealtimeEvents.parse(text) {
            case .functionCall(let callId, let name, let arguments):
                print("tool call:", name, arguments)
                if name == "look_at_screen" {
                    let image = NSImage(size: NSSize(width: 640, height: 240), flipped: false) { rect in
                        NSColor.white.setFill()
                        rect.fill()
                        ("Invoice total: $4,210" as NSString).draw(
                            at: NSPoint(x: 40, y: 100),
                            withAttributes: [.font: NSFont.systemFont(ofSize: 36, weight: .bold)])
                        return true
                    }
                    if let tiff = image.tiffRepresentation,
                        let jpeg = NSBitmapImageRep(data: tiff)?.representation(using: .jpeg, properties: [:])
                    {
                        try await socket.send(.string(RealtimeEvents.inputImage(jpeg)))
                    }
                }
                let output =
                    name == "list_items"
                    ? fakeItems
                    : name == "look_at_screen"
                        ? #"{"ok":true,"app":"Preview","screenshot":"attached as an image in the conversation"}"#
                        : #"{"ok":true,"result":2}"#
                try await socket.send(.string(RealtimeEvents.functionOutput(callId: callId, output: output)))
                pendingOutput = true
            case .responseDone:
                responses += 1
                guard pendingOutput else {
                    responses = 99
                    break
                }
                pendingOutput = false
                try await socket.send(.string(RealtimeEvents.responseCreate))
            case .error(let message):
                print("ERROR:", message)
                exit(1)
            case .other(let type) where type == "response.output_audio_transcript.done":
                if let data = text.data(using: .utf8),
                    let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                {
                    print("said:", event["transcript"] ?? "")
                }
            default: break
            }
        }
        exit(0)
    }
    RunLoop.main.run()
}

if let flag = CommandLine.arguments.firstIndex(of: "--jarvis-test"), CommandLine.arguments.count > flag + 1 {
    let outDir = URL(fileURLWithPath: CommandLine.arguments[flag + 1], isDirectory: true)
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    Task { @MainActor in
        let jarvis = JarvisController.shared
        if CommandLine.arguments.contains("--camera") {
            await jarvis.open(useCamera: true, useVoice: CommandLine.arguments.contains("--voice"))
            try? await Task.sleep(for: .seconds(20))
            jarvis.close()
            try? await Task.sleep(for: .seconds(1))
            exit(0)
        }
        await jarvis.open(useCamera: false, useVoice: false)
        var clock: TimeInterval = 0
        enum Shape { case point, open, closed }
        let hand = { (shape: Shape, palm: CGPoint, spread: CGFloat) -> HandSample in
            var joints: [HandJoint: CGPoint] = [.wrist: CGPoint(x: palm.x, y: palm.y + 100), .middleMCP: palm]
            let fingers: [(HandJoint, HandJoint, HandJoint, CGFloat)] = [
                (.indexMCP, .indexPIP, .indexTip, -24), (.middleMCP, .middlePIP, .middleTip, 0),
                (.ringMCP, .ringPIP, .ringTip, 22), (.littleMCP, .littlePIP, .littleTip, 42),
            ]
            for (index, (base, middle, tip, offset)) in fingers.enumerated() {
                let mcp = CGPoint(x: palm.x + offset, y: palm.y)
                joints[base] = mcp
                let extended = shape == .open || (shape == .point && index == 0)
                joints[middle] = CGPoint(x: mcp.x + offset * (spread - 1), y: mcp.y - (extended ? 35 : 30))
                joints[tip] = CGPoint(x: mcp.x + offset * (spread - 1) * 2, y: mcp.y + (extended ? -80 : 10))
            }
            joints[.thumbTip] = CGPoint(x: palm.x - 40 - 40 * spread, y: palm.y - 10)
            return HandSample(joints: joints)
        }
        let play = { (frames: [[HandSample]]) async in
            for samples in frames {
                clock += 1.0 / 30
                jarvis.feed(samples, at: clock)
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
        let step = { (name: String) async in
            try? await Task.sleep(for: .milliseconds(600))
            try? await jarvis.snapshot()?.write(to: outDir.appendingPathComponent("\(name).png"))
            let items = await jarvis.evaluate("return JSON.stringify(jarvis.listItems())")
            print(name, items ?? "")
        }
        await step("open")
        let stroke = (0...40).map { index -> [HandSample] in
            let t = CGFloat(index) / 40
            return [hand(.point, CGPoint(x: 300 + 500 * t, y: 800 + sin(t * .pi * 4) * 60), 1)]
        }
        await play(stroke + (0..<6).map { _ in [hand(.closed, CGPoint(x: 800, y: 800), 1)] })
        await step("drew")
        print(
            "note:",
            await jarvis.runVoiceTool(
                name: "write_note", arguments: #"{"text":"Ship the hand demo Friday","x":900,"y":300}"#))
        await play((0..<12).map { _ in [hand(.closed, CGPoint(x: 400, y: 400), 1)] })
        await step("noted")
        let still = (0..<20).map { _ in [hand(.open, CGPoint(x: 1000, y: 330), 1)] }
        let carry = (0..<25).map { [hand(.open, CGPoint(x: 1000 - CGFloat($0) * 12, y: 330 + CGFloat($0) * 10), 1.8)] }
        let drop = (0..<6).map { _ in [hand(.closed, CGPoint(x: 700, y: 580), 1)] }
        await play(still + carry + drop)
        await step("carried")
        await play(
            (0..<60).map { index -> [HandSample] in
                let phase = CGFloat(index % 6)
                return [hand(.open, CGPoint(x: 330 + (phase < 3 ? phase : 6 - phase) * 25, y: 820), 1)]
            } + (0..<12).map { _ in [hand(.closed, CGPoint(x: 400, y: 400), 1)] })
        await step("rubbed")
        print("restore:", await jarvis.runVoiceTool(name: "restore_deleted", arguments: "{}"))
        await step("restored")
        print(
            "arrange:",
            await jarvis.runVoiceTool(name: "arrange_items", arguments: #"{"target":"drawings","place":"top-right"}"#))
        await step("arranged")
        if CommandLine.arguments.contains("--ask") {
            print(
                "draw:",
                await jarvis.runVoiceTool(name: "draw", arguments: #"{"request":"A rotating 3D wireframe globe"}"#))
            try? await Task.sleep(for: .seconds(25))
            await step("visual")
        }
        jarvis.close()
        await jarvis.open(useCamera: false, useVoice: false)
        print("reopen note:", await jarvis.runVoiceTool(name: "write_note", arguments: #"{"text":"Back again"}"#))
        await step("reopened")
        jarvis.close()
        print("wrote", outDir.path)
        exit(0)
    }
    RunLoop.main.run()
}

// `DShift --chat-test "<message>"` sends one real message through a chat headlessly and prints what happened:
// tool calls, their status, and the reply. Diagrams are written to /tmp/dshift-chat-test-<n>.jpg.
if let flag = CommandLine.arguments.firstIndex(of: "--chat-test"), CommandLine.arguments.count > flag + 1 {
    let message = CommandLine.arguments[flag + 1]
    _ = NSApplication.shared
    Task { @MainActor in
        let chat = ChatModel(tracker: AppTracker())
        chat.input = message
        chat.send()
        while chat.isRunning { try? await Task.sleep(for: .milliseconds(200)) }
        var imageCount = 0
        for entry in chat.entries {
            switch entry {
            case .text(let text):
                print("[\(text.role)] \(text.text)")
            case .tool(let call):
                print("[tool] \(call.name) \(call.status) input=\(call.inputSummary.prefix(400))")
                print("       output=\(call.output.prefix(300))")
                if let image = call.image, let tiff = image.tiffRepresentation,
                    let jpeg = NSBitmapImageRep(data: tiff)?.representation(using: .jpeg, properties: [:])
                {
                    imageCount += 1
                    let url = URL(fileURLWithPath: "/tmp/dshift-chat-test-\(imageCount).jpg")
                    try? jpeg.write(to: url)
                    print("       image -> \(url.path)")
                }
            }
        }
        exit(0)
    }
    RunLoop.main.run()
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
MainActor.assumeIsolated { SingleInstance.claim(onRelaunch: delegate.showSidebar) }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
