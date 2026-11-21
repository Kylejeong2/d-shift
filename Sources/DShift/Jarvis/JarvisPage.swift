enum JarvisPage {
    static let html = """
        <!doctype html><html><head><meta charset="utf-8">
        \(OverlayPage.contentSecurityPolicy)
        <style>\(style)</style>
        </head><body>
        <div id="items"></div>
        <svg id="live"></svg>
        <div id="focus"></div>
        <svg id="hands"></svg>
        <div id="pointers"></div>
        <div id="legend"></div>
        <div id="core"><div class="ring outer"></div><div class="dot"></div></div>
        <div id="status"></div>
        <div id="runtime" hidden></div>
        <script>
        \(OverlayPage.streamRenderer)
        \(script)
        </script>
        </body></html>
        """

    private static let style = #"""
        :root { --accent: #8fd8ff; --ink: #f2f8fc; --muted: #8aa3b4; --warn: #ff9a70; --panel: #0b1d2b;
          --line: #2c5a75; --radius: 12px; }
        html, body { margin: 0; width: 100%; height: 100%; overflow: hidden; background: transparent; }
        body { font-family: "SF Pro Text", -apple-system, BlinkMacSystemFont, sans-serif; color: var(--ink);
          -webkit-font-smoothing: antialiased; user-select: none; -webkit-user-select: none;
          font-variant-numeric: tabular-nums; }
        #items, #live, #hands, #pointers { position: absolute; inset: 0; pointer-events: none; }
        #live, #hands { width: 100%; height: 100%; overflow: visible; }
        .jv-item { position: absolute; left: 0; top: 0; transform-origin: center;
          opacity: calc(1 - var(--wear, 0) * 0.8); transition: scale 140ms ease-out;
          animation: jv-arrive 320ms cubic-bezier(0.2, 0.8, 0.2, 1); }
        .jv-item.jv-held { transition: none; }
        .jv-item.jv-gliding { transition: translate 480ms cubic-bezier(0.2, 0.8, 0.2, 1), scale 480ms cubic-bezier(0.2, 0.8, 0.2, 1); }
        @keyframes jv-arrive { from { opacity: 0; scale: 0.96; } }
        .jv-stroke path, #live path { fill: none; stroke: var(--accent); stroke-width: 3; stroke-linecap: round;
          stroke-linejoin: round; }
        .jv-note { max-width: 420px; padding: 14px 18px; background: var(--panel); border-radius: var(--radius);
          font-family: "SF Pro Display", -apple-system, sans-serif; font-size: 20px; font-weight: 500;
          line-height: 1.35; white-space: pre-wrap; }
        .jv-visual { min-width: 40px; min-height: 40px; }
        .jv-visual.jv-loading::before { content: ""; display: block; width: 40px; height: 40px; border-radius: 50%;
          border: 1.5px solid var(--line); border-top-color: var(--accent); animation: jv-spin 0.8s linear infinite; }
        .jv-failed { padding: 12px 16px; background: var(--panel); border-radius: var(--radius); color: var(--warn);
          font-size: 14px; max-width: 360px; }
        @keyframes jv-spin { to { rotate: 360deg; } }
        #focus { position: absolute; left: 0; top: 0; pointer-events: none; opacity: 0; border-radius: var(--radius);
          outline: 1.5px solid var(--accent); outline-offset: 10px; transition: opacity 140ms ease-out; }
        #focus.jv-on { opacity: 1; }
        #focus.jv-held { outline-color: var(--ink); }
        #hands line { stroke: var(--accent); stroke-opacity: 0.55; stroke-width: 1.5; stroke-linecap: round; }
        #hands circle { fill: var(--accent); }
        .jv-reticle { position: absolute; left: 0; top: 0; width: 0; height: 0; }
        .jv-reticle .ring { position: absolute; width: 36px; height: 36px; margin: -18px; border-radius: 50%;
          border: 1.5px solid var(--accent); box-sizing: border-box;
          transition: width 140ms ease-out, height 140ms ease-out, margin 140ms ease-out, background-color 140ms ease-out; }
        .jv-reticle.jv-point .ring { width: 16px; height: 16px; margin: -8px; }
        .jv-reticle.jv-drawing .ring { width: 10px; height: 10px; margin: -5px; background: var(--accent); }
        .jv-reticle.jv-holding .ring { width: 72px; height: 72px; margin: -36px; border-color: var(--ink); }
        .jv-reticle.jv-erasing .ring { width: 140px; height: 140px; margin: -70px; border-color: var(--warn); }
        .jv-reticle.jv-closed .ring { width: 20px; height: 20px; margin: -10px; border-color: var(--line); }
        #legend { position: absolute; left: 32px; bottom: 32px; display: grid; grid-template-columns: auto auto;
          gap: 8px 20px; padding: 16px 20px; background: var(--panel); border-radius: var(--radius);
          font-size: 13px; color: var(--muted); }
        #legend b { font-weight: 500; color: var(--muted); }
        #legend .jv-active, #legend .jv-active b { color: var(--ink); }
        #core { position: absolute; left: 50%; bottom: 36px; width: 0; height: 0; opacity: 0; transition: opacity 240ms ease-out; }
        #core.jv-listening, #core.jv-speaking, #core.jv-connecting { opacity: 1; }
        #core .ring, #core .dot { position: absolute; border-radius: 50%; box-sizing: border-box; }
        #core .outer { width: 40px; height: 40px; margin: -20px; border: 1.5px solid var(--line);
          scale: calc(1 + var(--level, 0) * 0.45); transition: scale 80ms linear; }
        #core .dot { width: 10px; height: 10px; margin: -5px; background: var(--accent); }
        #core.jv-speaking .outer { border-color: var(--accent); }
        #core.jv-speaking .dot { background: var(--ink); }
        #core.jv-connecting .dot { animation: jv-pulse 0.9s ease-in-out infinite alternate; }
        @keyframes jv-pulse { to { opacity: 0.3; } }
        #status { position: absolute; left: 50%; top: 28px; translate: -50% 0; max-width: 560px; padding: 10px 16px;
          background: var(--panel); border-radius: var(--radius); font-size: 14px; color: var(--ink); opacity: 0;
          transition: opacity 240ms ease-out; pointer-events: none; }
        .jv-spark { position: absolute; width: 3px; height: 3px; border-radius: 50%; background: var(--accent);
          pointer-events: none; animation: jv-spark 520ms ease-out forwards; }
        @keyframes jv-spark { to { translate: var(--dx) var(--dy); opacity: 0; } }
        """#

    private static let script = #"""
        const svgNS = "http://www.w3.org/2000/svg";
        const itemsLayer = document.getElementById("items");
        const live = document.getElementById("live");
        const handsLayer = document.getElementById("hands");
        const pointerLayer = document.getElementById("pointers");
        const focusBox = document.getElementById("focus");
        const legend = document.getElementById("legend");
        const core = document.getElementById("core");
        const statusLine = document.getElementById("status");
        const post = message => window.webkit.messageHandlers.jarvis.postMessage(message);

        const gestures = [
          ["drawing", "Point", "Draw"],
          ["holding", "Open hand, held still on something", "Pick up and move"],
          ["scaling", "Spread or gather fingers", "Resize"],
          ["dropping", "Close your hand", "Let go"],
          ["erasing", "Rub back and forth", "Erase"],
          ["voice", "Talk", "Anything else"],
        ];
        legend.innerHTML = gestures.map(([key, gesture, action]) =>
          `<b data-key="${key}">${gesture}</b><span data-key="${key}">${action}</span>`).join("");
        const highlight = keys => legend.querySelectorAll("[data-key]").forEach(cell =>
          cell.classList.toggle("jv-active", keys.has(cell.dataset.key)));

        let nextId = 1;
        let statusTimer;
        const erased = [];
        const wear = new Map();
        const strokePoints = new WeakMap();
        const drawing = new Map();
        const holding = new Map();
        let lastAim = { x: innerWidth / 2, y: innerHeight / 2 };
        let origin = { x: 0, y: 0 };

        const showStatus = (text, seconds = 5) => {
          statusLine.textContent = text;
          statusLine.style.opacity = text ? 1 : 0;
          clearTimeout(statusTimer);
          if (seconds) statusTimer = setTimeout(() => { statusLine.style.opacity = 0; }, seconds * 1000);
        };

        const items = () => [...itemsLayer.children].filter(element => element.classList.contains("jv-item"));
        const byId = id => itemsLayer.querySelector(`.jv-item[data-id="${CSS.escape(String(id))}"]`);
        const position = item => (item.style.translate || "0px 0px").split(" ").map(value => parseFloat(value) || 0);
        const scaleOf = item => parseFloat(item.style.scale || "1") || 1;
        const place = (item, x, y) => { item.style.translate = `${x}px ${y}px`; };

        const boundsOf = item => {
          const rects = [item, ...[...item.querySelectorAll("*")].slice(0, 400)]
            .map(element => element.getBoundingClientRect()).filter(rect => rect.width > 0 && rect.height > 0);
          if (!rects.length) { const [x, y] = position(item); return new DOMRect(x, y, 1, 1); }
          const left = Math.min(...rects.map(rect => rect.left)), top = Math.min(...rects.map(rect => rect.top));
          const right = Math.max(...rects.map(rect => rect.right)), bottom = Math.max(...rects.map(rect => rect.bottom));
          return new DOMRect(left, top, right - left, bottom - top);
        };

        const within = (rect, x, y) => x >= rect.left - 24 && x <= rect.right + 24 && y >= rect.top - 24 && y <= rect.bottom + 24;
        const itemAt = (x, y) => items().reverse().find(item => within(boundsOf(item), x, y));
        let boundsCache = [];
        const cachedItemAt = (x, y) => [...boundsCache].reverse().find(entry => entry.item.isConnected && within(entry.rect, x, y))?.item;

        const freeSpot = (x, y, width, height) => {
          const taken = items().map(boundsOf);
          const fits = (left, top) => left >= 20 && top >= 20 && left + width <= innerWidth - 20
            && top + height <= innerHeight - 20 && !taken.some(rect => left < rect.right + 16
              && left + width > rect.left - 16 && top < rect.bottom + 16 && top + height > rect.top - 16);
          for (let ring = 0; ring < 12; ring++) {
            for (let step = 0; step < Math.max(1, ring * 8); step++) {
              const angle = (step / Math.max(1, ring * 8)) * Math.PI * 2;
              const left = x + Math.cos(angle) * ring * 90, top = y + Math.sin(angle) * ring * 70;
              if (fits(left, top)) return { x: left, y: top };
            }
          }
          return { x: Math.min(Math.max(20, x), innerWidth - width - 20), y: Math.min(Math.max(20, y), innerHeight - height - 20) };
        };

        const makeItem = (kind, label, x, y) => {
          const item = document.createElement("div");
          item.className = `jv-item jv-${kind}-item`;
          item.dataset.id = `${kind[0]}${nextId++}`;
          item.dataset.kind = kind;
          item.dataset.label = label.slice(0, 200);
          place(item, x, y);
          itemsLayer.appendChild(item);
          return item;
        };

        const smoothPath = points => {
          if (points.length < 2) return `M${points[0].x} ${points[0].y} l0.1 0`;
          let d = `M${points[0].x} ${points[0].y}`;
          for (let i = 1; i < points.length - 1; i++) {
            const mid = { x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2 };
            d += ` Q${points[i].x} ${points[i].y} ${mid.x} ${mid.y}`;
          }
          const last = points[points.length - 1];
          return d + ` L${last.x} ${last.y}`;
        };

        const drawBegin = (hand, x, y) => {
          const path = document.createElementNS(svgNS, "path");
          live.appendChild(path);
          drawing.set(hand, { path, points: [{ x, y }] });
          path.setAttribute("d", smoothPath([{ x, y }]));
        };
        const drawMove = (hand, x, y) => {
          const stroke = drawing.get(hand);
          if (!stroke) return;
          const last = stroke.points[stroke.points.length - 1];
          if (Math.hypot(x - last.x, y - last.y) < 2) return;
          stroke.points.push({ x, y });
          stroke.path.setAttribute("d", smoothPath(stroke.points));
        };
        const drawEnd = hand => {
          const stroke = drawing.get(hand);
          drawing.delete(hand);
          if (!stroke) return;
          stroke.path.remove();
          if (stroke.points.length < 4) return;
          commitStroke(stroke.points);
        };
        const commitStroke = points => {
          const pad = 8;
          const xs = points.map(point => point.x), ys = points.map(point => point.y);
          const left = Math.min(...xs) - pad, top = Math.min(...ys) - pad;
          const width = Math.max(...xs) - left + pad, height = Math.max(...ys) - top + pad;
          const local = points.map(point => ({ x: point.x - left, y: point.y - top }));
          const item = makeItem("drawing", "hand-drawn stroke", left, top);
          item.classList.add("jv-stroke");
          const svg = document.createElementNS(svgNS, "svg");
          svg.setAttribute("width", width);
          svg.setAttribute("height", height);
          svg.style.overflow = "visible";
          const path = document.createElementNS(svgNS, "path");
          path.setAttribute("d", smoothPath(local));
          svg.appendChild(path);
          item.appendChild(svg);
          strokePoints.set(item, { points: local, width, height });
          return item;
        };

        const holdBegin = (hand, x, y) => {
          const item = itemAt(x, y);
          if (!item) return;
          const [left, top] = position(item);
          holding.set(hand, { item, start: { x, y }, origin: [left, top], baseScale: scaleOf(item) });
          item.classList.add("jv-held");
          itemsLayer.appendChild(item);
        };
        const holdMove = (hand, x, y, scale) => {
          const held = holding.get(hand);
          if (!held) return;
          place(held.item, held.origin[0] + x - held.start.x, held.origin[1] + y - held.start.y);
          held.item.style.scale = Math.min(12, Math.max(0.1, held.baseScale * scale));
        };
        const holdEnd = (hand, scale) => {
          const held = holding.get(hand);
          holding.delete(hand);
          if (!held) return;
          held.item.style.scale = Math.min(12, Math.max(0.1, held.baseScale * scale));
          held.item.classList.remove("jv-held");
        };

        const sparks = rect => {
          for (let i = 0; i < 26; i++) {
            const spark = document.createElement("div");
            spark.className = "jv-spark";
            spark.style.left = `${rect.left + Math.random() * rect.width}px`;
            spark.style.top = `${rect.top + Math.random() * rect.height}px`;
            spark.style.setProperty("--dx", `${(Math.random() - 0.5) * 160}px`);
            spark.style.setProperty("--dy", `${(Math.random() - 0.5) * 160}px`);
            document.body.appendChild(spark);
            setTimeout(() => spark.remove(), 700);
          }
        };

        const remove = item => {
          wear.delete(item);
          item.style.removeProperty("--wear");
          sparks(boundsOf(item));
          for (const [hand, held] of holding) if (held.item === item) holding.delete(hand);
          erased.push({ item, next: item.nextSibling });
          if (erased.length > 12) erased.shift();
          item.remove();
        };

        const addWear = (item, amount) => {
          const value = Math.min(1, (wear.get(item) ?? 0) + amount);
          wear.set(item, value);
          item.style.setProperty("--wear", value);
          if (value >= 1) { remove(item); showStatus("Erased. Say \"bring it back\" to undo.", 4); }
        };
        setInterval(() => {
          for (const [item, value] of wear) {
            const next = value - 0.04;
            if (next <= 0) { wear.delete(item); item.style.removeProperty("--wear"); }
            else { wear.set(item, next); item.style.setProperty("--wear", next); }
          }
        }, 100);

        const strokeNear = (item, x, y, radius) => {
          const stroke = strokePoints.get(item);
          if (!stroke) return true;
          const rect = item.getBoundingClientRect();
          return stroke.points.some(point => Math.hypot(
            rect.left + point.x / stroke.width * rect.width - x, rect.top + point.y / stroke.height * rect.height - y) <= radius);
        };
        const rub = (x, y, radius) => {
          for (const item of items()) {
            const rect = boundsOf(item);
            const nearestX = Math.max(rect.left, Math.min(x, rect.right));
            const nearestY = Math.max(rect.top, Math.min(y, rect.bottom));
            if (Math.hypot(x - nearestX, y - nearestY) <= radius && strokeNear(item, x, y, radius)) {
              addWear(item, item.dataset.kind === "drawing" ? 0.16 : 0.08);
            }
          }
        };

        const bones = [["wrist","thumbCMC"],["thumbCMC","thumbMP"],["thumbMP","thumbIP"],["thumbIP","thumbTip"],
          ["wrist","indexMCP"],["indexMCP","indexPIP"],["indexPIP","indexDIP"],["indexDIP","indexTip"],
          ["indexMCP","middleMCP"],["middleMCP","middlePIP"],["middlePIP","middleDIP"],["middleDIP","middleTip"],
          ["middleMCP","ringMCP"],["ringMCP","ringPIP"],["ringPIP","ringDIP"],["ringDIP","ringTip"],
          ["ringMCP","littleMCP"],["wrist","littleMCP"],["littleMCP","littlePIP"],["littlePIP","littleDIP"],["littleDIP","littleTip"]];
        const tips = ["thumbTip", "indexTip", "middleTip", "ringTip", "littleTip"];
        const drawSkeletons = pointers => {
          let markup = "";
          for (const pointer of pointers) {
            const joints = pointer.joints;
            for (const [a, b] of bones) {
              if (joints[a] && joints[b]) markup += `<line x1="${joints[a][0]}" y1="${joints[a][1]}" x2="${joints[b][0]}" y2="${joints[b][1]}"/>`;
            }
            for (const tip of tips) if (joints[tip]) markup += `<circle cx="${joints[tip][0]}" cy="${joints[tip][1]}" r="2.5"/>`;
          }
          handsLayer.innerHTML = markup;
        };

        const reticles = new Map();
        const showPointers = pointers => {
          const seen = new Set();
          for (const pointer of pointers) {
            seen.add(pointer.hand);
            let reticle = reticles.get(pointer.hand);
            if (!reticle) {
              reticle = document.createElement("div");
              reticle.innerHTML = `<div class="ring"></div>`;
              pointerLayer.appendChild(reticle);
              reticles.set(pointer.hand, reticle);
            }
            const state = pointer.action !== "idle" ? pointer.action : pointer.pose;
            reticle.className = `jv-reticle jv-${state}`;
            reticle.style.translate = `${pointer.x}px ${pointer.y}px`;
          }
          for (const [hand, reticle] of reticles) if (!seen.has(hand)) { reticle.remove(); reticles.delete(hand); }
          drawSkeletons(pointers);

          const lead = pointers[0];
          if (lead) lastAim = { x: lead.x, y: lead.y };
          const heldItem = [...holding.values()][0]?.item;
          const aimed = heldItem ?? pointers.map(pointer => pointer.action === "idle" && pointer.pose === "open" ? cachedItemAt(pointer.x, pointer.y) : null).find(Boolean);
          if (aimed) {
            const rect = heldItem ? boundsOf(aimed) : boundsCache.find(entry => entry.item === aimed).rect;
            focusBox.style.translate = `${rect.left}px ${rect.top}px`;
            focusBox.style.width = `${rect.width}px`;
            focusBox.style.height = `${rect.height}px`;
            focusBox.classList.add("jv-on");
            focusBox.classList.toggle("jv-held", Boolean(heldItem));
          } else {
            focusBox.classList.remove("jv-on");
          }
          const active = new Set(pointers.map(pointer => pointer.action));
          if (active.has("holding")) active.add("scaling");
          highlight(active);
        };

        const regionFor = where => {
          const margin = 60, w = innerWidth, h = innerHeight;
          const regions = {
            "top-left": [margin, margin], "top-right": [w * 0.62, margin], "bottom-left": [margin, h * 0.58],
            "bottom-right": [w * 0.62, h * 0.58], "center": [w * 0.3, h * 0.25], "left": [margin, h * 0.25],
            "right": [w * 0.62, h * 0.25], "top": [w * 0.3, margin], "bottom": [w * 0.3, h * 0.58],
          };
          const [x, y] = regions[where] ?? regions.center;
          return { x, y, width: w * 0.36, height: h * 0.36 };
        };

        const glide = item => {
          item.classList.add("jv-gliding");
          setTimeout(() => item.classList.remove("jv-gliding"), 560);
        };

        const select = selector => {
          if (Array.isArray(selector)) return selector.map(byId).filter(Boolean);
          const kinds = { all: null, drawings: "drawing", notes: "note", visuals: "visual" };
          const kind = kinds[selector];
          return items().filter(item => kind === undefined ? false : kind === null || item.dataset.kind === kind);
        };

        const pivotOf = item => {
          const [x, y] = position(item);
          const [ox, oy] = getComputedStyle(item).transformOrigin.split(" ").map(parseFloat);
          return { x: x + ox, y: y + oy };
        };
        const rescaledRect = (item, nextScale) => {
          const rect = boundsOf(item), pivot = pivotOf(item), ratio = nextScale / scaleOf(item);
          return new DOMRect(pivot.x + (rect.left - pivot.x) * ratio, pivot.y + (rect.top - pivot.y) * ratio,
            rect.width * ratio, rect.height * ratio);
        };
        const moveTo = (item, nextScale, left, top) => {
          const projected = rescaledRect(item, nextScale);
          const [x, y] = position(item);
          glide(item);
          item.style.scale = nextScale;
          place(item, x + left - projected.left, y + top - projected.top);
        };

        const arrange = (selector, where, layout) => {
          const chosen = select(selector);
          const region = regionFor(where);
          const columns = layout === "row" ? chosen.length : layout === "column" ? 1 : Math.ceil(Math.sqrt(chosen.length));
          const rows = Math.ceil(chosen.length / Math.max(1, columns));
          const cellWidth = region.width / Math.max(1, columns), cellHeight = region.height / Math.max(1, rows);
          chosen.forEach((item, index) => {
            const rect = boundsOf(item);
            const fit = Math.min(1, (cellWidth - 16) / rect.width, (cellHeight - 16) / rect.height);
            const nextScale = layout === "stack" ? scaleOf(item) : Math.max(0.2, scaleOf(item) * fit);
            const column = index % Math.max(1, columns), row = Math.floor(index / Math.max(1, columns));
            const left = layout === "stack" ? region.x + index * 24 : region.x + column * cellWidth;
            const top = layout === "stack" ? region.y + index * 24 : region.y + row * cellHeight;
            moveTo(item, nextScale, left, top);
          });
          return chosen.length;
        };

        window.jarvis = {
          frame: (pointers, events) => {
            for (const event of events) {
              if (event.type === "draw") {
                if (event.phase === "began") drawBegin(event.hand, event.x, event.y);
                else if (event.phase === "moved") drawMove(event.hand, event.x, event.y);
                else drawEnd(event.hand);
              } else if (event.type === "hold") {
                if (event.phase === "began") holdBegin(event.hand, event.x, event.y);
                else if (event.phase === "moved") holdMove(event.hand, event.x, event.y, event.scale);
                else holdEnd(event.hand, event.scale);
              } else if (event.type === "rub") rub(event.x, event.y, event.radius);
            }
            showPointers(pointers);
          },
          setOrigin: (x, y) => { origin = { x, y }; },
          placeAtOrigin: id => { const item = byId(id); if (item) place(item, -origin.x, -origin.y); },
          addNote: (text, x, y) => {
            const spot = x == null || y == null ? freeSpot(lastAim.x - 40, lastAim.y - 30, 440, 90) : { x, y };
            const item = makeItem("note", text, spot.x, spot.y);
            const note = document.createElement("div");
            note.className = "jv-note";
            note.textContent = text;
            item.appendChild(note);
            return item.dataset.id;
          },
          beginVisual: (label, mode) => {
            const isScreen = mode === "screen";
            const spot = isScreen ? { x: -origin.x, y: -origin.y } : freeSpot(lastAim.x - 280, lastAim.y - 210, 560, 480);
            const item = makeItem("visual", label, spot.x, spot.y);
            const body = document.createElement("div");
            body.className = "jv-visual jv-loading";
            item.appendChild(body);
            return item.dataset.id;
          },
          streamVisual: (id, html, isFinal) => {
            const body = byId(id)?.querySelector(".jv-visual");
            if (!body) return;
            body.classList.remove("jv-loading");
            renderStream(body, html, isFinal);
            if (!isFinal) return;
            const item = byId(id);
            setTimeout(() => {
              const rect = boundsOf(item);
              const [x, y] = position(item);
              item.style.transformOrigin = `${rect.left + rect.width / 2 - x}px ${rect.top + rect.height / 2 - y}px`;
            }, 900);
          },
          failVisual: (id, message) => {
            const body = byId(id)?.querySelector(".jv-visual");
            if (!body) return;
            body.className = "jv-visual jv-failed";
            body.textContent = message;
          },
          listItems: () => items().map(item => {
            const rect = boundsOf(item);
            return { id: item.dataset.id, kind: item.dataset.kind, label: item.dataset.label,
              x: Math.round(rect.left), y: Math.round(rect.top), width: Math.round(rect.width), height: Math.round(rect.height),
              scale: Math.round(scaleOf(item) * 100) / 100 };
          }),
          arrange,
          moveItem: (id, x, y) => {
            const item = byId(id);
            if (!item) return false;
            moveTo(item, scaleOf(item), x, y);
            return true;
          },
          scaleItems: (selector, factor) => {
            const chosen = select(selector);
            chosen.forEach(item => { glide(item); item.style.scale = Math.min(12, Math.max(0.1, scaleOf(item) * factor)); });
            return chosen.length;
          },
          deleteItems: selector => {
            const chosen = select(selector);
            chosen.forEach(remove);
            return chosen.length;
          },
          restore: () => {
            const last = erased.pop();
            if (!last) return false;
            itemsLayer.insertBefore(last.item, last.next?.parentNode === itemsLayer ? last.next : null);
            showStatus("Restored.", 2);
            return true;
          },
          voiceState: state => { core.className = `jv-${state}`; },
          level: value => core.style.setProperty("--level", value),
          showStatus,
          showGuide: () => { legend.style.opacity = 1; },
        };

        setInterval(() => {
          boundsCache = items().map(item => ({ item, rect: boundsOf(item) }));
          post({ type: "items", rects: boundsCache.map(({ rect }) => [rect.left - 24, rect.top - 24, rect.width + 48, rect.height + 48]) });
        }, 150);
        """#
}
