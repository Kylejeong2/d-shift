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
