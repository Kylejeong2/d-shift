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
            let result = try await CodexRunner.run(task: task, codexPath: codex, progress: { print("progress:", String($0.split(separator: "\n").last ?? "")) }, requestAccess: { app in
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
            let image = try await DiagramRenderer.shared.render("""
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
                   let jpeg = NSBitmapImageRep(data: tiff)?.representation(using: .jpeg, properties: [:]) {
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
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
