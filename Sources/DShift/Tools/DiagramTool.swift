import AppKit
import WebKit

/// Renders a Mermaid diagram to an image shown in the chat. The image also goes back to Claude so it can check
/// the result and fix layout or syntax problems.
struct DiagramTool: Tool {
    let name = "make_diagram"
    let description = """
    Draw a diagram (flowchart, sequence, architecture, state, class, ER, timeline, mindmap) from Mermaid source and \
    show it to the user as an image. Use this whenever a visual explanation helps, and never draw diagrams in ASCII \
    or code blocks. The sidebar is narrow: prefer top-to-bottom layouts (`flowchart TD`), short node labels, and at \
    most about 15 nodes. Use subgraphs to show ownership or boundaries. Returns the rendered image, or the Mermaid \
    error so you can fix the source and try again.
    """
    let inputSchema: JSON = [
        "type": "object",
        "properties": [
            "mermaid": ["type": "string", "description": "Mermaid diagram source, without code fences."],
            "title": ["type": "string", "description": "Short caption shown above the diagram."],
        ],
        "required": ["mermaid"],
        "additionalProperties": false,
    ]
    let maxCallsPerTurn: Int? = 4

    func requiresApproval(for input: JSON) -> Bool { false }

    func run(_ input: JSON) async throws -> ToolOutput {
        let source = (input["mermaid"] as? String ?? "")
            .replacingOccurrences(of: "```mermaid", with: "")
            .replacingOccurrences(of: "```", with: "")
        let image = try await DiagramRenderer.shared.render(source)
        let title = input["title"] as? String
        Log.info("diagram", "rendered \(title ?? "untitled") \(image.count) bytes")
        return ToolOutput(text: "Rendered\(title.map { " \"\($0)\"" } ?? ""). The user sees the image.", jpeg: image)
    }
}

/// One offscreen WKWebView running Mermaid. Mermaid loads from jsDelivr on first use and is cached by WebKit.
@MainActor
final class DiagramRenderer: NSObject, WKNavigationDelegate {
    static let shared = DiagramRenderer()

    private static let maxWidth: CGFloat = 1400

    private let webView: WKWebView
    private let window: NSWindow
    private var isLoaded = false
    private var loadWaiters: [CheckedContinuation<Void, Error>] = []

    override init() {
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: Self.maxWidth, height: 1000))
        // Snapshots need the view in a window; keep it far offscreen and out of screenshots.
        window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: Self.maxWidth, height: 1000),
                          styleMask: .borderless, backing: .buffered, defer: false)
        window.sharingType = .none
        window.contentView = webView
        window.orderBack(nil)
        super.init()
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.loadHTMLString(Self.page, baseURL: URL(string: "https://cdn.jsdelivr.net/"))
    }

    /// JPEG of the rendered diagram.
    func render(_ source: String) async throws -> Data {
        try await waitForLoad()
        let result = try await webView.callAsyncJavaScript(
            "return await window.renderDiagram(source)",
            arguments: ["source": source],
            contentWorld: .page
        )
        guard let size = result as? [String: Any], let width = size["width"] as? Double, let height = size["height"] as? Double else {
            throw ToolError.failed("Diagram rendered with no size.")
        }
        if let error = size["error"] as? String {
            throw ToolError.failed("Mermaid error: \(error)")
        }
        let rect = NSRect(x: 0, y: 0, width: min(width, Self.maxWidth), height: height)
        webView.setFrameSize(NSSize(width: Self.maxWidth, height: max(height, 1)))
        window.setContentSize(webView.frame.size)
        let configuration = WKSnapshotConfiguration()
        configuration.rect = rect
        configuration.afterScreenUpdates = true
        configuration.snapshotWidth = NSNumber(value: Double(rect.width * 2)) // Retina-sharp
        let image = try await webView.takeSnapshot(configuration: configuration)
        // JPEG because tool images are sent to Claude as image/jpeg. The diagram sits on an opaque dark card.
        guard let tiff = image.tiffRepresentation,
              let jpeg = NSBitmapImageRep(data: tiff)?.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else {
            throw ToolError.failed("Couldn't encode the diagram.")
        }
        return jpeg
    }

    private func waitForLoad() async throws {
        if isLoaded { return }
        try await withCheckedThrowingContinuation { loadWaiters.append($0) }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            isLoaded = true
            loadWaiters.forEach { $0.resume() }
            loadWaiters = []
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { failLoad(error) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { failLoad(error) }
    }

    private func failLoad(_ error: Error) {
        loadWaiters.forEach { $0.resume(throwing: error) }
        loadWaiters = []
    }

    /// Dark theme to match the sidebar. `renderDiagram` waits for Mermaid's module to load, renders, and returns
    /// the SVG's size, or `{error}` with Mermaid's parse message.
    private static let page = """
    <!doctype html><html><head><meta charset="utf-8">
    <style>
      html, body { margin: 0; background: transparent; }
      #out { display: inline-block; padding: 16px; background: #1e1e22; }
      #out svg { display: block; max-width: \(Int(maxWidth) - 32)px; height: auto; }
    </style>
    <script type="module">
      import mermaid from "https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs";
      mermaid.initialize({ startOnLoad: false, theme: "dark", securityLevel: "strict",
        fontFamily: "-apple-system, BlinkMacSystemFont, sans-serif",
        flowchart: { htmlLabels: true, curve: "basis" } });
      window.mermaid = mermaid;
      window.mermaidReady?.();
    </script>
    <script>
      const ready = new Promise(resolve => {
        if (window.mermaid) resolve(); else window.mermaidReady = resolve;
      });
      let counter = 0;
      window.renderDiagram = async (source) => {
        await ready;
        const out = document.getElementById("out");
        try {
          const { svg } = await window.mermaid.render("d" + (counter++), source);
          out.innerHTML = svg;
        } catch (e) {
          out.innerHTML = "";
          return { width: 0, height: 0, error: String(e && e.message || e) };
        }
        const box = out.getBoundingClientRect();
        return { width: Math.ceil(box.width), height: Math.ceil(box.height) };
      };
    </script>
    </head><body><div id="out"></div></body></html>
    """
}
