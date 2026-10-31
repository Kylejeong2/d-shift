import AppKit
import WebKit

/// Draws graphics straight onto the user's screen. Claude describes what to draw; GPT-6.1 Sol Ultrafast writes the
/// HTML from that description plus the live frame of every element in the focused window, and it renders as it streams.
struct OverlayTool: Tool {
    private static let maxOutputTokens = 8000

    let tracker: AppTracker

    let name = "draw_on_screen"
    let description = """
    Draw graphics directly on the user's screen, over the app they're looking at: circle or highlight UI elements, \
    arrows with callouts pointing at things, numbered step-by-step annotations, charts, or diagrams. A fast \
    graphics model draws from your description using the live position of every element in the focused window, so \
    name the elements to point at by their visible text. For 3D models use show_3d_model instead. A new drawing replaces the previous one, and it stays until \
    the user presses Esc or switches apps (standalone drawings stay until Esc). Cards can be dragged around. Prefer this over make_diagram when the answer is about something on screen. \
    Keep your chat reply short afterwards; the drawing is the answer.
    """
    let inputSchema: JSON = [
        "type": "object",
        "properties": [
            "description": [
                "type": "string",
                "description": "What to draw and where, e.g. \"Circle the Export button and add a callout: exports go to Downloads.\"",
            ],
            "standalone": [
                "type": "boolean",
                "description": "True when the drawing isn't about anything on screen (a general visual or chart). Skips reading the window, so it's faster, and centers the drawing on the display the user is on.",
            ],
        ],
        "required": ["description"],
        "additionalProperties": false,
    ]
    let maxCallsPerTurn: Int? = 3

    func requiresApproval(for input: JSON) -> Bool { false }

    func run(_ input: JSON) async throws -> ToolOutput {
        let request = input["description"] as? String ?? ""
        let isStandalone = input["standalone"] as? Bool ?? false
        let overlay = OverlayController.shared

        var windowFrame: CGRect?
        var screenContext = "Nothing on screen is relevant: center the drawing on the display."
        var jpeg: Data?
        if !isStandalone, let app = tracker.app {
            let started = Date()
            let context = await Task.detached { AXSnapshot.capture(app: app, includeFrames: true) }.value
            let treeTime = Date().timeIntervalSince(started)
            // Web and Electron apps leave a lot out of the tree, so Sol also sees the window. Without Screen Recording
            // permission this comes back without an image and Sol works from the tree alone.
            let screenshot = try? await ScreenshotTool(tracker: tracker).run(["scope": "window"])
            let image = screenshot?.jpeg.flatMap { NSBitmapImageRep(data: $0) }
            Log.info("overlay", String(format: "context: tree %.2fs, screenshot %.2fs", treeTime, Date().timeIntervalSince(started) - treeTime))
            windowFrame = context.windowFrame
            jpeg = image == nil ? nil : screenshot?.jpeg
            screenContext = """
            Focused window: \(context.appName) "\(context.windowTitle)" \
            \(context.windowFrame.map { "[\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))]" } ?? "")

            \(Self.screenshotNote(image: image, window: context.windowFrame))

            Accessibility tree of the focused window, with element frames:
            \(context.tree)
            """
        }
        let screen = OverlayController.screen(containing: windowFrame)
        let display = OverlayController.globalFrame(of: screen)

        let prompt = """
        Display to draw on: [\(Int(display.minX)),\(Int(display.minY)) \(Int(display.width))x\(Int(display.height))]

        Request: \(request)

        \(screenContext)
        """

        overlay.lastPrompt = prompt
        let drawing = await overlay.begin(on: screen, standalone: isStandalone)
        var html = ""
        var tokens = (input: 0, output: 0)
        var lastPreview = Date.distantPast
        do {
            for try await event in OpenAIClient.stream(
                instructions: Self.instructions, input: prompt, jpeg: jpeg, effort: "low", maxOutputTokens: Self.maxOutputTokens
            ) {
                switch event {
                case .text(let delta):
                    html += delta
                    // Re-rendering the whole fragment on every token would thrash WebKit; ~12 fps looks live.
                    if Date().timeIntervalSince(lastPreview) > 0.08 {
                        overlay.preview(html, drawing: drawing)
                        lastPreview = Date()
                    }
                case .usage(let input, let output):
                    tokens = (input, output)
                }
            }
        } catch {
            overlay.dismiss(reason: "error")
            throw error
        }
        await overlay.commit(html, drawing: drawing, clearsOnAppSwitch: !isStandalone)

        Log.info("overlay", "drew \(html.count) chars, \(OpenAIClient.costSummary(input: tokens.input, output: tokens.output))")
        return ToolOutput(text: "Drawn on the user's screen. They can see it now; Esc clears it.")
    }

    /// Tells Sol how screenshot pixels map to screen points.
    private static func screenshotNote(image: NSBitmapImageRep?, window: CGRect?) -> String {
        guard let image, let window else { return "No screenshot available; work from the accessibility tree." }
        let scale = Double(image.pixelsWide) / window.width
        return """
        The attached screenshot shows the focused window at \(image.pixelsWide)x\(image.pixelsHigh) pixels. A pixel (px, py) \
        in it is at screen point (\(Int(window.minX)) + px / \(String(format: "%.3f", scale)), \(Int(window.minY)) + py / \(String(format: "%.3f", scale))).
        """
    }

    private static let instructions = """
    You are a motion and information designer drawing live graphics on a transparent overlay that covers the user's \
    screen, on top of their apps. The bar is a polished product demo people want to share, not a generic tooltip. \
    Output only an HTML fragment: no markdown fences, no <html>, <head>, or <body>, and no commentary.

    Coordinates: use position:absolute with left/top in CSS pixels equal to macOS screen points, the same space as the \
    [x,y wxh] frames in the accessibility tree (origin at the top-left of the main display). Point at an element using \
    its frame from the tree when it has one. Elements marked [offscreen] are scrolled out of view: don't draw on them. \
    For anything the tree lacks or that's drawn as an image, locate it in the screenshot and convert with the given \
    mapping. Stay inside the display rectangle you're given.

    Design: before writing, pick a visual idea that fits this request and this screen, then execute it with care. \
    Ideas to draw from, not a checklist: hand-drawn-feeling SVG strokes that draw themselves on (stroke-dasharray \
    animation); a spotlight that dims everything except the subject; glowing outlines that pulse once; numbered steps \
    connected by a curved path; small inline SVG illustrations and icons; live charts that animate in; frosted glass \
    cards (backdrop-filter: blur) with real typographic hierarchy (a bold 20-28px headline, quieter 13-14px body, \
    tabular numbers for data). Choose a palette that suits the content and contrasts with the app underneath, and \
    vary it between requests. Motion should be quick and purposeful (150-600ms, eased, staggered), never looping \
    forever except a subtle idle effect. Avoid the generic look: identical dark boxes, one flat accent, plain arrows.

    Never cover the whole screen or the thing being explained; leave what you aren't annotating readable. Put \
    explanations, charts, and diagrams beside the relevant area. Text must stay legible on any background.

    The HTML renders while you stream it, and each <script> runs as soon as its closing tag arrives. Write the <style> \
    first, then elements in the order the user should read them. Never wait until the end to make things appear: the \
    user should watch the drawing build up.

    Scripts: plain <script> or <script type="module">. The only allowed network source is https://cdn.jsdelivr.net. \
    No fetch, external images, or web fonts.

    Interaction: the overlay lets clicks through to the apps underneath, except over <canvas> elements and elements \
    with the data-interactive attribute, which receive the mouse and scroll wheel. Mark buttons, sliders, and other \
    controls data-interactive. Keep interactive areas compact so the user can still reach their apps.

    Moving: put each card (callouts, legends, charts) in its own absolutely positioned container with \
    the data-draggable attribute and cursor: grab, so the user can drag it anywhere by its frame or caption. Keep \
    padding around any canvas inside so there is something to grab. Don't make arrows or outlines draggable; they \
    point at fixed things.

    Keep it under about 200 lines.
    """
}

/// A mostly click-through, transparent window over one display, with a web view that renders the drawing.
@MainActor
final class OverlayController: NSObject, WKNavigationDelegate {
    static let shared = OverlayController()

    // Only the CDN may serve scripts, and nothing may be fetched or framed, so screen text the model saw can't be
    // sent anywhere even if a page on screen tries to inject instructions.
    private static let page = """
    <!doctype html><html><head><meta charset="utf-8">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline' https://cdn.jsdelivr.net; \
    style-src 'unsafe-inline'; img-src data: blob:; font-src data:">
    <style>
      html, body { margin: 0; width: 100%; height: 100%; overflow: hidden; background: transparent; }
      body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; }
      #stage { position: absolute; inset: 0; }
    </style>
    <script>
      window.addEventListener("error", event => log(`error: ${event.message} at ${event.lineno}:${event.colno}`));
      window.addEventListener("unhandledrejection", event => log(`rejection: ${event.reason}`));
      const log = message => window.webkit.messageHandlers.overlayLog.postMessage(message);
      // Standalone drawings (general visuals) aren't pinned to anything, so every top-level card can be moved
      // even when the model forgot data-draggable.
      const standaloneCards = () => document.body.dataset.standalone === "true"
        ? [...stage().children].filter(element => !["STYLE", "SCRIPT"].includes(element.tagName))
        : [];
      window.setStandalone = isStandalone => { document.body.dataset.standalone = String(isStandalone); };
      // Movable cards. The overlay can't receive drag events, so the app tracks the drag natively and calls moveCard;
      // `translate` is separate from `transform`, so moving doesn't fight the cards' entrance animations.
      let cards = [];
      let moveStart = [0, 0];
      window.moveCard = (index, dx, dy, isStart) => {
        const card = cards[index];
        if (!card) return;
        if (isStart) moveStart = (card.style.translate || "0px 0px").split(" ").map(value => parseFloat(value) || 0);
        card.style.translate = `${moveStart[0] + dx}px ${moveStart[1] + dy}px`;
      };
      // Where the overlay should catch the mouse, in window coordinates: [x, y, width, height, card index or -1].
      // Controls come first so a button inside a card still gets its click. Everywhere else, clicks pass through.
      setInterval(() => {
        cards = [...new Set([...document.querySelectorAll("[data-draggable]"), ...standaloneCards()])];
        const area = (element, index) => {
          const rect = element.getBoundingClientRect();
          return [rect.left, rect.top, rect.width, rect.height, index];
        };
        const areas = [
          ...[...document.querySelectorAll("canvas, [data-interactive], button, input, select, textarea")].map(element => area(element, -1)),
          ...cards.map(area),
        ].filter(([, , width, height]) => width > 0 && height > 0);
        window.webkit.messageHandlers.hitAreas.postMessage(areas);
      }, 200);
      const stage = () => document.getElementById("stage");
      const unfence = html => html.replace(/^\\s*```(?:html)?\\s*/i, "").replace(/```\\s*$/, "");
      // The stage is shifted so the model can use global screen points on any display.
      window.setOrigin = (x, y) => { stage().style.transform = `translate(${-x}px, ${-y}px)`; };
      // Streamed HTML only ever grows, so everything before the first difference is already final. Keep those
      // nodes (their entrance animations play once) and patch the one still being written instead of rebuilding.
      const sameShell = (a, b) => a.nodeType === 1 && b.nodeType === 1 && a.tagName === b.tagName
        && a.attributes.length === b.attributes.length
        && [...a.attributes].every(attribute => b.getAttribute(attribute.name) === attribute.value);
      // Nodes that came from the streamed HTML. Anything scripts add (a three.js canvas, say) isn't in the HTML, so
      // the morph leaves it alone instead of deleting it on the next update.
      const owned = new WeakSet();
      const own = node => { owned.add(node); node.childNodes.forEach(own); };
      const morph = (target, source) => {
        const next = [...source.childNodes], current = [...target.childNodes].filter(node => owned.has(node));
        let i = 0;
        while (i < next.length && i < current.length && current[i].isEqualNode(next[i])) i++;
        if (i < next.length && i < current.length) {
          const [a, b] = [current[i], next[i]];
          if (a.nodeType === 3 && b.nodeType === 3) { a.nodeValue = b.nodeValue; i++; }
          else if (sameShell(a, b)) { morph(a, b); i++; }
        }
        current.slice(i).forEach(node => node.remove());
        next.slice(i).forEach(node => { own(node); target.appendChild(node); });
      };
      const parse = html => {
        const template = document.createElement("template");
        template.innerHTML = html;
        return template.content;
      };
      // Parsed scripts never run, so each one is run once, as soon as its closing tag has streamed in, by copying it
      // into #runtime. The parsed copy stays in the stage untouched so the morph keeps matching it.
      let scriptsRun = 0;
      const runNewScripts = () => {
        const scripts = [...stage().querySelectorAll("script")];
        for (; scriptsRun < scripts.length; scriptsRun++) {
          const parsed = scripts[scriptsRun];
          const script = document.createElement("script");
          for (const attribute of parsed.attributes) script.setAttribute(attribute.name, attribute.value);
          script.textContent = parsed.textContent;
          document.getElementById("runtime").appendChild(script);
        }
      };
      const withoutOpenScript = html => {
        const start = html.lastIndexOf("<script");
        return start !== -1 && html.indexOf("<\\/script>", start) === -1 ? html.slice(0, start) : html;
      };
      // Mid-stream: hold back a script that's still being written and any half-written trailing tag.
      window.preview = html => {
        morph(stage(), parse(withoutOpenScript(unfence(html)).replace(/<[^>]*$/, "")));
        runNewScripts();
      };
      window.commit = html => {
        morph(stage(), parse(unfence(html)));
        runNewScripts();
      };
    </script>
    </head><body><div id="stage"></div><div id="runtime" hidden></div></body></html>
    """
    private static let baseURL = URL(string: "https://cdn.jsdelivr.net/")!

    private let window: NSPanel
    private let webView: WKWebView
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []
    /// Bumped on every begin and dismiss, so a stream that was cleared or replaced stops drawing.
    private var currentDrawing = 0
    /// The last drawing's prompt and committed HTML, for `--overlay-test`.
    private(set) var lastHTML = ""
    var lastPrompt = ""
    private var escapeMonitor: EventMonitor?
    private let hitAreas: HitAreaReceiver
    private var mouseTimer: Timer?
    private var appSwitchObserver: NSObjectProtocol?

    override init() {
        window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Above normal app windows, below the sidebar.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        let configuration = WKWebViewConfiguration()
        let hitAreas = HitAreaReceiver()
        configuration.userContentController.add(hitAreas, name: "hitAreas")
        configuration.userContentController.add(OverlayLogReceiver(), name: "overlayLog")
        let overlayWebView = OverlayWebView(frame: .zero, configuration: configuration)
        // The first matching area wins, and controls come before cards, so a press on a card's button isn't a move.
        overlayWebView.cardAt = { point in hitAreas.areas.first { $0.rect.contains(point) }?.card }
        overlayWebView.moveCard = { [weak overlayWebView] card, dx, dy, isStart in
            overlayWebView?.callAsyncJavaScript(
                "moveCard(card, dx, dy, isStart)", arguments: ["card": card, "dx": dx, "dy": dy, "isStart": isStart],
                in: nil, in: .page, completionHandler: nil
            )
        }
        webView = overlayWebView
        self.hitAreas = hitAreas
        webView.setValue(false, forKey: "drawsBackground")
        window.contentView = webView
        super.init()
        webView.navigationDelegate = self
    }

    /// The display holding most of the focused window, or the one under the mouse.
    static func screen(containing windowFrame: CGRect?) -> NSScreen {
        let screens = NSScreen.screens
        if let windowFrame {
            let center = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
            if let match = screens.first(where: { globalFrame(of: $0).contains(center) }) { return match }
        }
        return .underMouse
    }

    /// A screen's frame in accessibility coordinates: global points with the origin at the main display's top-left.
    static func globalFrame(of screen: NSScreen) -> CGRect {
        let mainHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        return CGRect(x: screen.frame.minX, y: mainHeight - screen.frame.maxY, width: screen.frame.width, height: screen.frame.height)
    }

    /// Clears any previous drawing (and its running scripts) and shows an empty overlay on `screen`.
    func begin(on screen: NSScreen, standalone: Bool) async -> Int {
        currentDrawing += 1
        let drawing = currentDrawing
        window.setFrame(screen.frame, display: false)
        await reload()
        let origin = Self.globalFrame(of: screen).origin
        _ = try? await webView.callAsyncJavaScript(
            "setOrigin(x, y); setStandalone(standalone)",
            arguments: ["x": origin.x, "y": origin.y, "standalone": standalone], contentWorld: .page
        )
        if drawing == currentDrawing {
            window.orderFrontRegardless()
            startDismissMonitors()
            startMouseRouting()
        }
        return drawing
    }

    func preview(_ html: String, drawing: Int) {
        guard drawing == currentDrawing else { return }
        webView.callAsyncJavaScript("preview(html)", arguments: ["html": html], in: nil, in: .page, completionHandler: nil)
    }

    /// `clearsOnAppSwitch` is for annotations tied to a window; standalone drawings stay until Esc.
    func commit(_ html: String, drawing: Int, clearsOnAppSwitch: Bool) async {
        guard drawing == currentDrawing else { return }
        lastHTML = html
        _ = try? await webView.callAsyncJavaScript("commit(html)", arguments: ["html": html], contentWorld: .page)
        // Watch for app switches only once the drawing is done: focus often bounces while the user is still asking.
        guard clearsOnAppSwitch, drawing == currentDrawing, appSwitchObserver == nil else { return }
        appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            MainActor.assumeIsolated { self?.dismiss(reason: "switched to \(app?.localizedName ?? "another app")") }
        }
    }

    func dismiss(reason: String) {
        Log.info("overlay", "cleared: \(reason)")
        currentDrawing += 1
        window.orderOut(nil)
        stopDismissMonitors()
        mouseTimer?.invalidate()
        mouseTimer = nil
        hitAreas.areas = []
        window.ignoresMouseEvents = true
        // Reloading stops animation loops that would otherwise keep running in the hidden window.
        webView.loadHTMLString(Self.page, baseURL: Self.baseURL)
    }

    private func reload() async {
        webView.loadHTMLString(Self.page, baseURL: Self.baseURL)
        await withCheckedContinuation { loadWaiters.append($0) }
    }

    /// Interactive areas in global screen points (top-left origin), for `--overlay-test` to drag on.
    var interactiveAreas: [CGRect] {
        let top = Self.globalFrame(of: window.screen ?? NSScreen.screens[0]).minY
        return hitAreas.areas.map { $0.rect.offsetBy(dx: window.frame.minX, dy: top) }
    }

    /// The window can't be partly click-through, so it catches the mouse only while the cursor is over an interactive
    /// area, and keeps it for the rest of a drag that started there.
    private func startMouseRouting() {
        guard mouseTimer == nil else { return }
        mouseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.routeMouse() }
        }
    }

    private func routeMouse() {
        if NSEvent.pressedMouseButtons != 0 && !window.ignoresMouseEvents { return }
        let mouse = NSEvent.mouseLocation
        let point = CGPoint(x: mouse.x - window.frame.minX, y: window.frame.maxY - mouse.y)
        let isOverInteractive = hitAreas.areas.contains { $0.rect.contains(point) }
        if window.ignoresMouseEvents == isOverInteractive {
            window.ignoresMouseEvents = !isOverInteractive
            Log.info("overlay", isOverInteractive ? "catching mouse at \(Int(point.x)),\(Int(point.y))" : "passing mouse through")
        }
    }

    /// Esc anywhere clears the drawing. Switching apps does too, once it's committed.
    private func startDismissMonitors() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = .escape { [weak self] in self?.dismiss(reason: "esc") }
    }

    private func stopDismissMonitors() {
        escapeMonitor = nil
        if let appSwitchObserver { NSWorkspace.shared.notificationCenter.removeObserver(appSwitchObserver) }
        appSwitchObserver = nil
    }

    /// Only the overlay page itself may load; scripts can't navigate the view somewhere else.
    nonisolated func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        MainActor.assumeIsolated {
            let url = navigationAction.request.url
            decisionHandler(url == Self.baseURL || url?.absoluteString == "about:blank" ? .allow : .cancel)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { finishLoad() }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { finishLoad() }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { finishLoad() }
    }

    /// A replaced load fails rather than finishing, so waiters resume either way and never hang.
    private func finishLoad() {
        loadWaiters.forEach { $0.resume() }
        loadWaiters = []
    }
}

/// An area of the drawing that catches the mouse: a control, or a movable card (with its index on the page).
private struct HitArea {
    let rect: CGRect
    let card: Int?
}

/// Receives the drawing's interactive areas from the page. Only numbers are accepted from the model's code.
@MainActor
private final class HitAreaReceiver: NSObject, WKScriptMessageHandler {
    var areas: [HitArea] = []

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            let received = (message.body as? [[Double]] ?? []).prefix(100).compactMap { values -> HitArea? in
                guard values.count == 5 else { return nil }
                let rect = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
                return HitArea(rect: rect, card: values[4] >= 0 ? Int(values[4]) : nil)
            }
            if areas.isEmpty != received.isEmpty { Log.info("overlay", "interactive areas: \(received.count)") }
            areas = Array(received)
        }
    }
}

/// Takes the first click without needing the overlay to be key. WebKit never gets drag events in this window, so a
/// press on a movable card is tracked here and the card is moved through `moveCard`.
private final class OverlayWebView: WKWebView {
    var cardAt: (CGPoint) -> Int? = { _ in nil }
    var moveCard: (Int, CGFloat, CGFloat, Bool) -> Void = { _, _, _, _ in }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return super.mouseDown(with: event) }
        let start = event.locationInWindow
        guard let card = cardAt(CGPoint(x: start.x, y: window.frame.height - start.y)) else {
            return super.mouseDown(with: event)
        }
        moveCard(card, 0, 0, true)
        NSCursor.closedHand.push()
        defer { NSCursor.pop() }
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            moveCard(card, next.locationInWindow.x - start.x, start.y - next.locationInWindow.y, false)
            if next.type == .leftMouseUp { break }
        }
    }
}

/// Forwards the page's interaction events to the log, to debug dragging without driving the mouse.
private final class OverlayLogReceiver: NSObject, WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let text = message.body as? String else { return }
        Log.info("overlay", "page: \(text.prefix(200))")
    }
}
