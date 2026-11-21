import Foundation

enum OverlayPage {
    static let baseURL = URL(string: "https://cdn.jsdelivr.net/")!

    // Only the CDN may serve scripts, and nothing may be fetched or framed, so screen text the model saw can't be
    // sent anywhere even if a page on screen tries to inject instructions.
    static let contentSecurityPolicy = """
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline' https://cdn.jsdelivr.net; \
        style-src 'unsafe-inline'; img-src data: blob:; font-src data:">
        """

    static let streamRenderer = #"""
        const unfence = html => html.replace(/^\s*```(?:html)?\s*/i, "").replace(/```\s*$/, "");
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
        const scriptsRun = new WeakMap();
        const runNewScripts = container => {
          const scripts = [...container.querySelectorAll("script")];
          for (let index = scriptsRun.get(container) ?? 0; index < scripts.length; index++) {
            const parsed = scripts[index];
            const script = document.createElement("script");
            for (const attribute of parsed.attributes) script.setAttribute(attribute.name, attribute.value);
            script.textContent = parsed.textContent;
            document.getElementById("runtime").appendChild(script);
            scriptsRun.set(container, index + 1);
          }
        };
        const withoutOpenScript = html => {
          const start = html.lastIndexOf("<script");
          return start !== -1 && html.indexOf("<\/script>", start) === -1 ? html.slice(0, start) : html;
        };
        // Mid-stream: hold back a script that's still being written and any half-written trailing tag.
        const renderStream = (container, html, isFinal) => {
          const source = isFinal ? unfence(html) : withoutOpenScript(unfence(html)).replace(/<[^>]*$/, "");
          morph(container, parse(source));
          runNewScripts(container);
        };
        """#
}
