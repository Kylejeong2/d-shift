import AppKit
import WebKit

/// A floating notepad the model opens only when it decides it needs one: to work something out step by step, draft
/// text the user may copy or edit, sketch with code, or keep notes across turns. It's a list of blocks: editable text
/// and drawings. The user can edit the text, and the model reads it back to see their edits. Saved to
/// `scratchpad.json` in the data dir.
struct ScratchpadTool: Tool {
    let name = "scratchpad"
    let description = """
        A floating notepad on the user's screen that you and the user share. Use it only when it helps: working through \
        a multi-step problem or calculation, drafting text the user will copy or edit (an email, a message, a plan), \
        sketching something with code (a plot, geometry, a quick diagram of your working), or keeping notes or a \
        checklist across turns. Don't use it for short answers that fit in chat.
        Actions:
        - "write": replace everything with `text`.
        - "append": add `text` as a new block at the end.
        - "draw": add a drawing at the end. Give `code`, JavaScript that draws on a 2D canvas with `canvas`, `ctx`, \
        `width`, and `height` already defined (the canvas is transparent on a dark card, so draw with light colors), or \
        `svg` markup. Optional `height` in points (default 240) and `caption`. Drawings run sandboxed with no network.
        - "read": returns the text blocks (the user may have edited them) and drawing captions.
        - "clear": empties it.
        Writing or drawing opens the notepad if it's closed.
        """
    let inputSchema: JSON = [
        "type": "object",
        "properties": [
            "action": ["type": "string", "enum": ["write", "append", "draw", "read", "clear"]],
            "text": ["type": "string", "description": "Text for write or append."],
            "code": ["type": "string", "description": "For draw: JavaScript drawing on the canvas."],
            "svg": ["type": "string", "description": "For draw: SVG markup, instead of code."],
            "height": ["type": "integer", "description": "For draw: height in points, 80 to 600."],
            "caption": ["type": "string", "description": "For draw: short caption under the drawing."],
        ],
        "required": ["action"],
        "additionalProperties": false,
    ]

    func requiresApproval(for input: JSON) -> Bool { false }

    func run(_ input: JSON) async throws -> ToolOutput {
        let pad = Scratchpad.shared
        let text = input["text"] as? String ?? ""
        switch input["action"] as? String {
        case "read":
            let contents = await pad.read()
            return ToolOutput(text: contents.isEmpty ? "(the scratchpad is empty)" : contents)
        case "clear":
            await pad.call("clearPad()")
            return ToolOutput(text: "Cleared the scratchpad.")
        case "write", "append":
            guard !text.isEmpty else { throw ToolError.invalidInput("\(input["action"] ?? "") needs text") }
            if input["action"] as? String == "write" { await pad.call("clearPad()") }
            await pad.call("await appendText(text)", ["text": text])
            return ToolOutput(text: "Wrote to the scratchpad. The user can see and edit it.")
        case "draw":
            let code = input["code"] as? String ?? ""
            let svg = input["svg"] as? String ?? ""
            guard !code.isEmpty || !svg.isEmpty else { throw ToolError.invalidInput("draw needs code or svg") }
            let height = min(max(input["height"] as? Int ?? 240, 80), 600)
            let error =
                await pad.call(
                    "return await appendDrawing(code, svg, height, caption)",
                    ["code": code, "svg": svg, "height": height, "caption": input["caption"] as? String ?? ""]
                ) as? String
            if let error, !error.isEmpty {
                return ToolOutput(text: "The drawing threw an error: \(error). Fix the code and draw again.")
            }
            return ToolOutput(text: "Drew in the scratchpad. The user can see it.")
        default:
            throw ToolError.invalidInput("action must be write, append, draw, read, or clear")
        }
    }
}

/// The notepad window. Titled so it moves, resizes, and closes like any window; it floats above the sidebar without
/// activating D-Shift, and remembers where the user put it.
@MainActor
final class Scratchpad: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    static let shared = Scratchpad()
    nonisolated private static let file = Config.dataDir.appendingPathComponent("scratchpad.json")

    private let window: NSPanel
    private let webView: WKWebView
    private var isLoaded = false
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []

    override init() {
        window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 520),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = "Scratchpad"
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // The page draws its own header with title, status, and actions.
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 280, height: 200)

        let configuration = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        for name in ["changed", "copy", "close"] {
            configuration.userContentController.add(self, name: name)
        }
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = self

        let backdrop = NSVisualEffectView()
        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.addPinnedSubview(webView)
        // The web view can't start a window drag, so a native strip over the header's left side does. The header's
        // buttons sit to its right and stay clickable.
        let dragHandle = DragHandle()
        dragHandle.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(dragHandle)
        NSLayoutConstraint.activate([
            dragHandle.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            dragHandle.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -110),
            dragHandle.topAnchor.constraint(equalTo: backdrop.topAnchor),
            dragHandle.heightAnchor.constraint(equalToConstant: 52),
        ])
        window.contentView = backdrop
        if !window.setFrameUsingName("dshift.scratchpad") {
            let screen = NSScreen.main?.visibleFrame ?? .zero
            window.setFrameTopLeftPoint(NSPoint(x: screen.maxX - 420 - 420, y: screen.maxY - 40))
        }
        window.setFrameAutosaveName("dshift.scratchpad")
        webView.loadHTMLString(Self.page, baseURL: nil)
    }

    /// Runs page JavaScript after showing the window. Returns the script's result.
    @discardableResult
    func call(_ script: String, _ arguments: [String: Any] = [:]) async -> Any? {
        window.orderFrontRegardless()
        await waitForLoad()
        return try? await webView.callAsyncJavaScript(script, arguments: arguments, contentWorld: .page)
    }

    /// PNG of the pad's contents, for `--scratchpad-test`.
    func snapshot() async -> Data? {
        guard let image = try? await webView.takeSnapshot(configuration: nil), let tiff = image.tiffRepresentation
        else { return nil }
        return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }

    func read() async -> String {
        await waitForLoad()
        return (try? await webView.callAsyncJavaScript("return readPad()", contentWorld: .page)) as? String ?? ""
    }

    private func waitForLoad() async {
        if isLoaded { return }
        await withCheckedContinuation { loadWaiters.append($0) }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            let saved = (try? String(contentsOf: Self.file, encoding: .utf8)) ?? "[]"
            webView.callAsyncJavaScript("loadPad(saved)", arguments: ["saved": saved], in: nil, in: .page) { _ in
                MainActor.assumeIsolated {
                    self.isLoaded = true
                    self.loadWaiters.forEach { $0.resume() }
                    self.loadWaiters = []
                }
            }
        }
    }

    /// Only the pad page itself loads; nothing in it can navigate the view away.
    nonisolated func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        MainActor.assumeIsolated {
            let isPad =
                navigationAction.targetFrame?.isMainFrame == false
                || navigationAction.request.url?.absoluteString == "about:blank"
            decisionHandler(isPad ? .allow : .cancel)
        }
    }

    /// The page saves its blocks whenever they change (including the user's edits), copies, and closes through here.
    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            let body = message.body as? String ?? ""
            switch message.name {
            case "changed":
                try? body.write(to: Self.file, atomically: true, encoding: .utf8)
            case "copy":
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(body, forType: .string)
            case "close":
                window.orderOut(nil)
            default:
                break
            }
        }
    }

    /// Markdown text blocks that render and edit in place, and drawings that run in sandboxed frames with an opaque
    /// origin and no network. A raw string, so the page's regexes need no extra escaping.
    private static let page = #"""
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; frame-src about: data:">
        <style>
          :root { --accent: #ff9f0a; --text: #ececf1; --muted: #8e8e96; --faint: #6e6e76; }
          html, body { margin: 0; height: 100%; background: transparent; color: var(--text);
            font: 14px/1.6 -apple-system, BlinkMacSystemFont, sans-serif; -webkit-font-smoothing: antialiased; }
          body { display: flex; flex-direction: column; user-select: none; }
          header { height: 52px; flex: none; display: flex; align-items: center; gap: 10px; padding: 0 10px 0 16px;
            border-bottom: 1px solid rgba(255,255,255,.07); }
          .title { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 1px; }
          .title b { font-size: 13px; font-weight: 600; display: flex; align-items: center; gap: 7px; }
          .title b svg { color: var(--accent); }
          #status { font-size: 11px; color: var(--muted); display: flex; align-items: center; gap: 6px; }
          #status i { width: 6px; height: 6px; border-radius: 50%; background: #55555c; }
          #status.writing { color: #d8d8de; }
          #status.writing i { background: var(--accent); animation: pulse 1s ease-in-out infinite; }
          .actions { display: flex; gap: 2px; }
          .actions button { all: unset; width: 30px; height: 30px; border-radius: 8px; display: grid; place-items: center;
            color: #a0a0a8; transition: background .12s, color .12s; }
          .actions button:hover { background: rgba(255,255,255,.08); color: #fff; }
          .actions button.done { color: var(--accent); }
          main { flex: 1; overflow-y: auto;
            -webkit-mask-image: linear-gradient(transparent, #000 12px, #000 calc(100% - 28px), transparent); }
          #pad { padding: 14px 16px 48px; user-select: text; }
          #pad:empty::before { content: "Claude uses this to think out loud, draft, and sketch."; display: block;
            margin-top: 56px; text-align: center; color: var(--faint); font-size: 13px; }
          .block { position: relative; padding: 8px 12px; margin: 0 -12px 6px; border-radius: 10px; transition: background .15s; }
          .block:hover { background: rgba(255,255,255,.035); }
          .block.text.claude { box-shadow: inset 2px 0 0 rgba(255,159,10,.55); }
          .block.enter { animation: enter .25s ease-out; }
          .meta { position: absolute; top: 7px; right: 10px; font-size: 10.5px; color: var(--faint); opacity: 0;
            transition: opacity .15s; pointer-events: none; }
          .block:hover .meta { opacity: 1; }
          .body { cursor: text; }
          .body p { margin: 0; }
          .body h1 { font-size: 19px; line-height: 1.3; margin: 4px 0 6px; letter-spacing: -.01em; }
          .body h2 { font-size: 16px; line-height: 1.35; margin: 4px 0 4px; }
          .body h3 { font-size: 11.5px; letter-spacing: .06em; text-transform: uppercase; color: var(--muted); margin: 6px 0 2px; }
          .gap { height: .55em; }
          ul, ol { margin: 2px 0; padding-left: 20px; }
          li { margin: 1px 0; }
          li::marker { color: var(--muted); }
          ul.checks { list-style: none; padding-left: 0; }
          ul.checks label { display: flex; gap: 9px; align-items: baseline; }
          ul.checks input { accent-color: var(--accent); margin: 0; transform: translateY(2px); }
          ul.checks input:checked + span { color: var(--faint); text-decoration: line-through; }
          strong { color: #fff; font-weight: 600; }
          code { font: 12.5px ui-monospace, SFMono-Regular, Menlo, monospace; background: rgba(255,255,255,.08);
            padding: 1px 5px; border-radius: 5px; }
          pre { background: rgba(0,0,0,.35); border: 1px solid rgba(255,255,255,.06); border-radius: 8px;
            padding: 10px 12px; overflow-x: auto; margin: 6px 0; }
          pre code { background: none; padding: 0; }
          blockquote { margin: 4px 0; padding-left: 11px; border-left: 2px solid rgba(255,255,255,.2); color: #b4b4bc; }
          hr { border: 0; border-top: 1px solid rgba(255,255,255,.1); margin: 10px 0; }
          textarea { all: unset; display: block; width: 100%; white-space: pre-wrap; overflow: hidden;
            font: 12.5px/1.6 ui-monospace, SFMono-Regular, Menlo, monospace; color: var(--text); caret-color: var(--accent); }
          .caret { display: inline-block; width: 2px; height: 1.05em; background: var(--accent); margin-left: 2px;
            vertical-align: -2px; animation: blink 1s steps(1) infinite; }
          .drawing iframe { display: block; width: 100%; border: 0; border-radius: 10px; background: #16161a;
            box-shadow: 0 0 0 1px rgba(255,255,255,.06), 0 10px 28px rgba(0,0,0,.35); }
          .drawing figcaption { font-size: 12px; color: var(--muted); margin-top: 7px; }
          @keyframes enter { from { opacity: 0; transform: translateY(4px); } }
          @keyframes pulse { 50% { opacity: .35; } }
          @keyframes blink { 50% { opacity: 0; } }
        </style>
        </head><body>
        <header>
          <div class="title">
            <b><svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 20h9"/><path d="M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4Z"/></svg>Scratchpad</b>
            <div id="status"><i></i><span>Empty</span></div>
          </div>
          <div class="actions">
            <button id="copy" title="Copy all text"><svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="9" width="12" height="12" rx="2"/><path d="M5 15V5a2 2 0 0 1 2-2h10"/></svg></button>
            <button id="clear" title="Clear"><svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 6h18"/><path d="M8 6V4h8v2"/><path d="M6 6l1 14h10l1-14"/></svg></button>
            <button id="close" title="Close"><svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"><path d="M6 6l12 12M18 6 6 18"/></svg></button>
          </div>
        </header>
        <main><div id="pad"></div></main>
        <script>
          const pad = () => document.getElementById("pad");
          const post = (name, body) => window.webkit.messageHandlers[name].postMessage(body);
          let writing = 0;

          // A small Markdown renderer: headings, emphasis, code, lists, checkboxes, quotes, and rules.
          const escape = text => text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
          const inline = text => escape(text)
            .replace(/`([^`]+)`/g, "<code>$1</code>")
            .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
            .replace(/(^|[^*\w])\*([^*\s][^*]*?)\*(?!\*)/g, "$1<em>$2</em>")
            .replace(/~~([^~]+)~~/g, "<del>$1</del>");
          const render = source => {
            let html = "", list = null, inCode = false, code = [];
            const closeList = () => { if (list) { html += `</${list}>`; list = null; } };
            const openList = (tag, className = "") => {
              if (list !== tag + className) { closeList(); html += `<${tag}${className ? ` class="${className}"` : ""}>`; list = tag + className; }
            };
            source.split("\n").forEach((line, index) => {
              if (line.trim().startsWith("```")) {
                if (inCode) { html += `<pre><code>${escape(code.join("\n"))}</code></pre>`; code = []; inCode = false; }
                else { closeList(); inCode = true; }
                return;
              }
              if (inCode) { code.push(line); return; }
              let match;
              if ((match = line.match(/^(#{1,3})\s+(.*)/))) { closeList(); html += `<h${match[1].length}>${inline(match[2])}</h${match[1].length}>`; }
              else if ((match = line.match(/^\s*[-*]\s+\[( |x|X)\]\s*(.*)/))) {
                openList("ul", "checks");
                html += `<li><label><input type="checkbox" data-line="${index}"${match[1] === " " ? "" : " checked"}><span>${inline(match[2])}</span></label></li>`;
              }
              else if ((match = line.match(/^\s*[-*•]\s+(.*)/))) { openList("ul"); html += `<li>${inline(match[1])}</li>`; }
              else if ((match = line.match(/^\s*\d+[.)]\s+(.*)/))) { openList("ol"); html += `<li>${inline(match[1])}</li>`; }
              else if ((match = line.match(/^>\s?(.*)/))) { closeList(); html += `<blockquote>${inline(match[1])}</blockquote>`; }
              else if (/^\s*(---|\*\*\*)\s*$/.test(line)) { closeList(); html += "<hr>"; }
              else if (!line.trim()) { closeList(); html += `<div class="gap"></div>`; }
              else { closeList(); html += `<p>${inline(line)}</p>`; }
            });
            if (inCode) html += `<pre><code>${escape(code.join("\n"))}</code></pre>`;
            closeList();
            return html;
          };

          const ago = time => {
            const seconds = (Date.now() - time) / 1000;
            if (seconds < 45) return "just now";
            if (seconds < 3600) return `${Math.round(seconds / 60)}m ago`;
            if (seconds < 86400) return `${Math.round(seconds / 3600)}h ago`;
            return new Date(time).toLocaleDateString();
          };
          const blocks = () => [...pad().children];
          const refreshTimes = () => {
            for (const block of blocks()) {
              block.querySelector(".meta").textContent = `${block.dataset.author === "you" ? "You" : "Claude"} · ${ago(+block.dataset.time)}`;
            }
            const status = document.getElementById("status");
            status.classList.toggle("writing", writing > 0);
            const latest = Math.max(0, ...blocks().map(block => +block.dataset.time));
            status.querySelector("span").textContent = writing > 0 ? "Claude is writing…" : latest ? `Updated ${ago(latest)}` : "Empty";
          };
          setInterval(refreshTimes, 30000);

          const save = () => {
            post("changed", JSON.stringify(blocks().map(block => block.classList.contains("text")
              ? { type: "text", source: block.source, author: block.dataset.author, time: +block.dataset.time }
              : { type: "drawing", ...JSON.parse(block.dataset.drawing), author: block.dataset.author, time: +block.dataset.time })));
            refreshTimes();
          };

          const makeBlock = (kind, author, time) => {
            const block = document.createElement("section");
            block.className = `block ${kind} ${author}`;
            block.dataset.author = author;
            block.dataset.time = time;
            block.innerHTML = `<div class="meta"></div>`;
            pad().appendChild(block);
            return block;
          };

          // Click a text block to edit its Markdown; click away to render it. Checkboxes toggle in place.
          const addText = (source, author = "claude", time = Date.now()) => {
            const block = makeBlock("text", author, time);
            block.source = source;
            const body = document.createElement("div");
            body.className = "body";
            body.innerHTML = render(source);
            block.appendChild(body);
            body.addEventListener("change", event => {
              const line = +event.target.dataset.line;
              const lines = block.source.split("\n");
              lines[line] = lines[line].replace(/\[( |x|X)\]/, event.target.checked ? "[x]" : "[ ]");
              block.source = lines.join("\n");
              block.dataset.time = Date.now();
              save();
            });
            body.addEventListener("click", event => {
              if (event.target.closest("input, label") || writing > 0 || block.querySelector("textarea")) return;
              const editor = document.createElement("textarea");
              editor.value = block.source;
              const fit = () => { editor.style.height = "auto"; editor.style.height = editor.scrollHeight + "px"; };
              editor.addEventListener("input", fit);
              editor.addEventListener("blur", () => {
                if (editor.value !== block.source) {
                  block.source = editor.value;
                  block.dataset.author = "you";
                  block.className = "block text you";
                  block.dataset.time = Date.now();
                }
                body.innerHTML = render(block.source);
                editor.replaceWith(body);
                if (!block.source.trim()) block.remove();
                save();
              });
              body.replaceWith(editor);
              fit();
              editor.focus();
            });
            return block;
          };

          // Each drawing runs in its own sandboxed frame: scripts allowed, but no same-origin access and no network.
          const addDrawing = ({ code, svg, height, caption }, author = "claude", time = Date.now()) => new Promise(resolve => {
            const block = makeBlock("drawing", author, time);
            block.dataset.drawing = JSON.stringify({ code, svg, height, caption });
            const frame = document.createElement("iframe");
            frame.setAttribute("sandbox", "allow-scripts");
            frame.style.height = height + "px";
            const width = pad().clientWidth - 32;
            const id = Math.random().toString(36).slice(2);
            const onMessage = event => {
              if (event.data?.id !== id) return;
              window.removeEventListener("message", onMessage);
              resolve(event.data.error || "");
            };
            window.addEventListener("message", onMessage);
            const script = (code || "").replace(/<\/script/gi, "<\\/script");
            frame.srcdoc = `<!doctype html><meta charset="utf-8"><style>html,body{margin:0;overflow:hidden}svg{display:block;width:100%;height:${height}px}</style>`
              + (svg || `<canvas></canvas><script>
                const width = ${width}, height = ${height}, canvas = document.querySelector("canvas");
                canvas.width = width * devicePixelRatio; canvas.height = height * devicePixelRatio;
                canvas.style.width = width + "px"; canvas.style.height = height + "px";
                const ctx = canvas.getContext("2d"); ctx.scale(devicePixelRatio, devicePixelRatio);
                let error = "";
                try { ${script} } catch (e) { error = String(e && e.message || e); }
                parent.postMessage({ id: "${id}", error }, "*");
              <\/script>`);
            setTimeout(() => resolve(""), svg ? 0 : 3000);
            const figure = document.createElement("figure");
            figure.style.margin = "0";
            figure.appendChild(frame);
            if (caption) {
              const label = document.createElement("figcaption");
              label.textContent = caption;
              figure.appendChild(label);
            }
            block.appendChild(figure);
          });

          window.loadPad = saved => {
            for (const block of JSON.parse(saved)) {
              if (block.type === "text" || typeof block.text === "string") addText(block.source ?? block.text, block.author, block.time);
              else addDrawing(block, block.author, block.time);
            }
            refreshTimes();
          };
          window.clearPad = () => { pad().innerHTML = ""; save(); };

          // Types text in over about a second, rendering as it goes with a caret at the end.
          window.appendText = async text => {
            writing++;
            refreshTimes();
            const block = addText("");
            block.classList.add("enter");
            const body = block.querySelector(".body");
            const step = Math.max(1, Math.ceil(text.length / 40));
            for (let i = 0; i < text.length; i += step) {
              block.source = text.slice(0, i + step);
              body.innerHTML = render(block.source);
              const last = body.lastElementChild;
              (last && !last.classList.contains("gap") ? (last.querySelector("li:last-child span, li:last-child") || last) : body)
                .insertAdjacentHTML("beforeend", `<span class="caret"></span>`);
              block.scrollIntoView({ block: "end" });
              await new Promise(resolve => setTimeout(resolve, 25));
            }
            block.source = text;
            body.innerHTML = render(text);
            writing--;
            save();
          };
          window.appendDrawing = async (code, svg, height, caption) => {
            writing++;
            refreshTimes();
            const error = await addDrawing({ code, svg, height, caption });
            const block = pad().lastElementChild;
            // A failed drawing would leave an empty card; drop it so the model's fixed version replaces it.
            if (error) block?.remove(); else { block?.classList.add("enter"); block?.scrollIntoView({ behavior: "smooth", block: "end" }); }
            writing--;
            save();
            return error;
          };
          // What the model reads back: the Markdown of each text block, marking what the user wrote, and drawing captions.
          window.readPad = () => blocks().map(block => block.classList.contains("text")
            ? (block.dataset.author === "you" ? "(written or edited by the user)\n" : "") + block.source
            : `[Drawing${JSON.parse(block.dataset.drawing).caption ? ": " + JSON.parse(block.dataset.drawing).caption : ""}]`
          ).join("\n\n");

          document.getElementById("copy").addEventListener("click", event => {
            post("copy", blocks().filter(block => block.classList.contains("text")).map(block => block.source).join("\n\n"));
            const button = event.currentTarget;
            button.classList.add("done");
            setTimeout(() => button.classList.remove("done"), 900);
          });
          document.getElementById("clear").addEventListener("click", () => window.clearPad());
          document.getElementById("close").addEventListener("click", () => post("close", ""));
        </script>
        </body></html>
        """#
}

/// Drags the window from the page's header, which the web view can't do itself.
private final class DragHandle: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}
