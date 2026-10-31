import AppKit
import SceneKit

/// Shows a 3D model floating on the user's screen. GPT-6.1 Sol Ultrafast streams the model as JSON lines, one part
/// per line, and each part is added to a native SceneKit view as it arrives, so the model assembles live. No
/// generated code runs: the lines only describe shapes.
struct ModelTool: Tool {
    private static let maxOutputTokens = 32000
    private static let maxParts = 3000
    /// Higher effort designs better but delays the first part; DSHIFT_MODEL_EFFORT overrides it for experiments.
    private static var effort: String { Config.value("DSHIFT_MODEL_EFFORT") ?? "low" }

    let name = "show_3d_model"
    let description = """
        Show an interactive 3D model floating on the user's screen: molecules, anatomy, planets and orbits, machines, \
        buildings, math surfaces, anything that's clearer in 3D. A 3D designer model streams it in part by part, so the \
        user watches it assemble, and moving parts can animate. The user can drag it anywhere, swipe with two fingers or \
        Option-drag to rotate, and pinch to zoom; Esc or right-click closes it. Every call designs and builds from \
        scratch. When the user asks to rebuild, retry, or improve a model, don't repeat the same request: pick a clearly \
        different creative direction (cutaway vs exterior, exploded view, x-ray, stylized vs realistic, palette, level \
        of detail) and put it in `direction`. Keep your chat reply short.
        """
    let inputSchema: JSON = [
        "type": "object",
        "properties": [
            "description": [
                "type": "string",
                "description":
                    "What to model and what to emphasize or label, e.g. \"A wind turbine showing how wind becomes electricity.\"",
            ],
            "direction": [
                "type": "string",
                "description":
                    "Optional creative direction, e.g. \"exploded view, brushed metal and glowing power path\". Use a new one for each rebuild.",
            ],
        ],
        "required": ["description"],
        "additionalProperties": false,
    ]
    let maxCallsPerTurn: Int? = 2

    func requiresApproval(for input: JSON) -> Bool { false }

    func run(_ input: JSON) async throws -> ToolOutput {
        let request = input["description"] as? String ?? ""
        let direction = input["direction"] as? String ?? ""
        // Earlier builds this session, so a rebuild explores something new instead of reproducing the last one.
        let previous = ModelHistory.builds.suffix(4).map { "- \($0)" }.joined(separator: "\n")
        let prompt = """
            Build: \(request)
            \(direction.isEmpty ? "" : "Creative direction: \(direction)")
            \(previous.isEmpty ? "" : "Already built this session (make this one clearly different unless the request says otherwise):\n\(previous)")
            """
        let window = ModelWindow.open()
        let started = Date()
        let build: Build
        do {
            build = try await Self.stream(instructions: Self.instructions, input: prompt, image: nil, into: window)
        } catch {
            window.close()
            throw error
        }
        Log.info(
            "model",
            "built \(build.title) (\(build.concept)) from \(build.parts) parts, \(build.timing(since: started)), \(build.costSummary)"
        )
        guard build.parts > 0 else {
            window.close()
            throw ToolError.failed("The model builder returned no usable parts.")
        }
        ModelHistory.builds.append("\(build.title): \(build.concept)")
        ModelHistory.lastWindow = window
        // The user already has a model; a second pass looks at the render and improves it while they watch.
        if Config.value("DSHIFT_MODEL_POLISH") != "0" {
            window.polish = Task { await Self.polish(build, request: request, in: window) }
        }
        return ToolOutput(
            text:
                "Showing \"\(build.title)\" (\(build.parts) parts) floating on the user's screen, with a polish pass still refining it. Design: \(build.concept)"
        )
    }

    /// Reviews a snapshot of the first build and streams fixes and detail into the same window.
    private static func polish(_ first: Build, request: String, in window: ModelWindow) async {
        try? await Task.sleep(for: .milliseconds(400))  // let the last parts fade in before the snapshot
        guard !Task.isCancelled, let image = window.snapshotJPEG() else { return }
        let started = Date()
        let input = """
            Request: \(request)
            Your design concept: \(first.concept)
            The attached image is your first build, rendered from the front. Its JSON Lines:
            \(first.lines.joined(separator: "\n"))
            """
        do {
            let pass = try await stream(
                instructions: instructions + polishInstructions, input: input, image: image, into: window)
            Log.info(
                "model",
                "polished \(first.title) with \(pass.parts) parts, \(pass.timing(since: started)), \(pass.costSummary)")
        } catch {
            Log.info("model", "polish failed: \(error.localizedDescription)")
        }
    }

    /// What one streamed pass produced.
    private struct Build {
        var title = "model"
        var concept = ""
        var parts = 0
        var lines: [String] = []
        var tokens = (input: 0, output: 0)
        var firstPart: TimeInterval?

        func timing(since start: Date) -> String {
            String(format: "first part after %.1fs, done after %.1fs", firstPart ?? 0, Date().timeIntervalSince(start))
        }

        var costSummary: String { OpenAIClient.costSummary(input: tokens.input, output: tokens.output) }
    }

    /// Streams JSON Lines from Sol into `window`, adding each part the moment its line completes.
    private static func stream(instructions: String, input: String, image: Data?, into window: ModelWindow) async throws
        -> Build
    {
        var build = Build()
        var pending = ""
        let started = Date()
        let handle = { (line: String) in
            guard build.parts < maxParts, let part = parse(line) else { return }
            build.lines.append(line.trimmingCharacters(in: .whitespaces))
            if let value = part["title"] as? String { build.title = value }
            if let value = part["concept"] as? String { build.concept = value }
            if window.add(part) {
                build.parts += 1
                build.firstPart = build.firstPart ?? Date().timeIntervalSince(started)
            }
        }
        for try await event in OpenAIClient.stream(
            instructions: instructions, input: input, jpeg: image, effort: effort, maxOutputTokens: maxOutputTokens
        ) {
            try Task.checkCancellation()
            switch event {
            case .text(let delta):
                pending += delta
                while let newline = pending.firstIndex(of: "\n") {
                    handle(String(pending[..<newline]))
                    pending = String(pending[pending.index(after: newline)...])
                }
            case .usage(let input, let output):
                build.tokens = (input, output)
            }
        }
        handle(pending)
        return build
    }

    private static func parse(_ line: String) -> JSON? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{") else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? JSON
    }

    private static let instructions = """
        You are a 3D designer making a showpiece model for a native viewer, the kind of thing people screenshot and share. \
        The model floats over the user's apps with no background, lit by soft studio lighting with reflections, shadows, \
        and bloom on emissive parts.

        Before writing anything, decide the most striking and explanatory way to show the subject: a cutaway with the \
        shell peeled back, an exploded view with parts floating apart along their axes, a translucent x-ray shell with \
        glowing internals, a precise scientific illustration, a stylized low-poly sculpture, a blueprint built from thin \
        glowing struts. Commit to one direction and execute it with craft:
        - Accurate proportions and silhouette first; a viewer should recognize it before any label appears.
        - Smooth, continuous forms. Build organic and curved shapes from lathes and tapered tubes, not stacks of spheres \
        and capsules, which look lumpy. Join pieces so seams overlap rather than leaving gaps.
        - Detail where it matters. 300 to 1500 parts is normal; repeat elements (bolts, ribs, teeth, atoms, panels) \
        instead of leaving surfaces bare.
        - A deliberate palette: two or three hues plus neutrals, not a rainbow. Contrast materials: brushed metal \
        (metalness 0.9, roughness 0.3), matte (roughness 0.8), gloss (roughness 0.1), glass (opacity 0.25).
        - Emission for energy, flow, heat, signal, or to make the key part pop. Bloom makes emissive parts glow.
        - Make moving parts move: rotors, gears, orbits, flows.

        Output JSON Lines only: one complete JSON object per line, no prose, no markdown fences, no wrapping array. \
        Each line appears the moment it arrives, so build in a satisfying order: silhouette and main masses first, then \
        structure, then fine detail, then labels.

        First line: {"title":"Short name","concept":"One sentence: your design direction, palette, and what it emphasizes"}
        Give every major part a short unique "id" (like "torso", "left_wing", "blade_set") so it can be refined later.

        Positions are scene units with y up; keep the whole model within about -5..5 on every axis. Rotations are degrees.
        {"shape":"sphere","position":[x,y,z],"radius":r}
        {"shape":"box","position":[x,y,z],"size":[w,h,d],"rotation":[rx,ry,rz]}
        {"shape":"cylinder","from":[x,y,z],"to":[x,y,z],"radius":r}   rods, shafts, struts, bonds
        {"shape":"capsule","from":[x,y,z],"to":[x,y,z],"radius":r}   rounded rods, limbs, pills
        {"shape":"cone","from":[x,y,z],"to":[x,y,z],"radius":r}   base at from, tip at to
        {"shape":"torus","position":[x,y,z],"ringRadius":R,"pipeRadius":r,"rotation":[rx,ry,rz]}   flat in the xz plane before rotation
        {"shape":"tube","points":[[x,y,z],...],"radius":r}   smooth curve through up to 200 points: strands, cables, \
        orbits, flows, tails, horns, tentacles. Add "radii":[r,...] (one per point) to taper it: limbs, necks, tails
        {"shape":"lathe","profile":[[radius,y],...],"position":[x,y,z],"rotation":[rx,ry,rz]}   a smooth surface of \
        revolution around the local y axis, from a profile listed bottom to top: torsos, bodies, heads, vases, bottles, \
        domes, fuselages, nose cones. Use 8 to 30 profile points for a smooth silhouette
        {"shape":"extrude","points":[[x,y],...],"depth":d,"position":[x,y,z],"rotation":[rx,ry,rz]}   a 2D outline (in the \
        xy plane, centered near 0,0) extruded along z: blades, airfoils, gear teeth, plates, brackets, letters
        {"label":"Text","position":[x,y,z]}   small floating label; at most about 8, only where they explain something

        Materials: define each once, then reference it with "m" on shapes (keys on a shape override its material):
        {"mat":"pearl","color":"#rrggbb","metalness":0.1,"roughness":0.35}   also "opacity" (0..1) and "emission":"#rrggbb"
        {"shape":"sphere","position":[0,1,0],"radius":0.2,"m":"pearl"}
        Use a handful of materials, declared up front, rather than repeating colors on every line.

        Repeats: any shape can take "repeat" to place copies, so write one line instead of many:
        "repeat":{"count":3,"axis":[0,0,1],"pivot":[x,y,z]}   copies spread evenly around the axis through pivot (blades, \
        teeth, bolts, spokes, petals); add "angle":90 to spread across 90 degrees instead of a full turn
        "repeat":{"count":12,"step":[dx,dy,dz]}   copies offset by step each (rows of panels, rungs, vertebrae)
        Shapes also take "group":"name".
        Groups move together. Declare a group before its parts:
        {"group":"rotor","pivot":[x,y,z],"spin":[ax,ay,az],"rps":0.3}   parts with "group":"rotor" spin around the axis \
        through pivot, rps turns per second (0 for a static group). Keep spins calm: 0.05 to 0.5 rps.

        Playbooks. Use the one that fits; they apply to any subject in the category.
        - Creatures and characters: lathe the torso, head, and snout; tapered tubes ("radii") for limbs, necks, tails, \
        and fingers, overlapping into the body at joints; spheres only for eyes and joint caps. Check leg count, \
        symmetry, and that feet touch one ground plane. Give the pose some life: weight on one leg, a turned head.
        - Vehicles and machines: a lathe or box for the main hull, extrudes for fins, blades, brackets, and panels, \
        cylinders for axles and pistons, repeats for wheels, bolts, vents, and teeth. Show function: a cutaway or \
        exploded layer, and spin what spins.
        - Architecture: massing first (boxes and extrudes), then repeated windows, columns, and ribs with "step"; a \
        thin ground plate; warm emissive windows for life.
        - Molecules and chemistry: CPK colors (C #3c3c3c, H #ffffff, O #e8322e, N #3050f8, S #ffd23f, P #ff8000), \
        atoms scaled by element, bonds as cylinders, double bonds as two thin parallel cylinders; real geometry \
        (tetrahedral 109.5, planar rings 120).
        - Astronomy: compress distances and sizes but keep order and ratios readable; orbits as thin emissive tubes; \
        a glowing star; rings as tori or flat extrudes.
        - Anatomy and biology: lathes for organs and vessels, tapered tubes for branching structures, translucent \
        outer layers over colored internals.
        - Plants and nature: tapered tubes for stems and branches, extruded leaf and petal outlines repeated around an \
        axis, slight random variation so it doesn't look printed.
        - Products and objects: lathes for anything turned (cups, bottles, lenses), boxes with small chamfered details, \
        one hero material.
        - Math and data: tubes for curves, grids of thin tubes for surfaces, emissive color ramps for value.

        Speed matters: the user is watching it build. Use repeats and materials wherever they fit, write numbers with at \
        most 2 decimals, and spend parts on what makes the model read well, not on invisible interior detail. \
        Compute coordinates yourself (helices, rings, surfaces of revolution, airfoils).
        """

    private static let polishInstructions = """


        Polish pass. You built the model below and can now see it rendered. The user is already looking at it, so \
        improve it in place rather than starting over. Look hard at the image: proportions, silhouette, gaps between \
        parts, floating or intersecting pieces, lumpy forms, missing defining features, flat or muddy materials, \
        unreadable labels. Then output only JSON Lines that fix and enrich it:
        - {"remove":"id"} deletes a part; a shape line with an existing "id" replaces that part.
        - New parts, materials, and groups use the same format as before.
        Prioritize the fixes a viewer would notice first. Don't repeat the title line. At most about 80 lines.
        """
}

/// Titles and design directions of the models built this session.
@MainActor
enum ModelHistory {
    static var builds: [String] = []
    /// The most recent model, for `--overlay-test --model` to wait on and snapshot.
    static var lastWindow: ModelWindow?
}

/// A borderless, transparent window holding one floating model. Drag moves it; a two-finger swipe or Option-drag
/// rotates it; pinch zooms; a toolbar on hover resets the view, toggles labels, and closes. Esc closes every model.
@MainActor
final class ModelWindow: NSObject {
    private static let size: CGFloat = 560
    private static var openWindows: [ModelWindow] = []
    private static var escapeMonitor: EventMonitor?

    private let window: ModelPanel
    private let view: ModelView
    private let model = SCNNode()
    private let rotator = SCNNode()
    private let camera = SCNNode()
    private var labels: [SCNNode] = []
    private var groups: [String: SCNNode] = [:]
    private var materials: [String: JSON] = [:]
    private var parts: [String: SCNNode] = [:]
    /// The background polish pass; closing the window cancels it.
    var polish: Task<Void, Never>?
    private var framedDistance: CGFloat = 14

    static func open() -> ModelWindow {
        let model = ModelWindow(cascade: openWindows.count)
        openWindows.append(model)
        startEscapeMonitors()
        return model
    }

    private init(cascade: Int) {
        let screen = NSScreen.underMouse
        let offset = CGFloat(cascade) * 40
        let frame = NSRect(
            x: screen.frame.midX - Self.size / 2 + offset, y: screen.frame.midY - Self.size / 2 - offset,
            width: Self.size, height: Self.size
        )
        window = ModelPanel(
            contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Above the sidebar (which floats at .floating), so a model can be dragged over it.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.hidesOnDeactivate = false

        view = ModelView(frame: NSRect(origin: .zero, size: frame.size))
        super.init()
        let scene = SCNScene()
        view.scene = scene
        view.backgroundColor = .clear
        // 8x multisampling smooths silhouettes against the transparent background, where jaggies show most.
        view.antialiasingMode = view.device?.supportsTextureSampleCount(8) == true ? .multisampling8X : .multisampling4X
        scene.lightingEnvironment.contents = Self.studioEnvironment
        scene.lightingEnvironment.intensity = 1.4
        view.onRotate = { [weak self] dx, dy in self?.rotate(dx: dx, dy: dy) }
        view.onZoom = { [weak self] amount in self?.resize(by: amount) }
        view.onClose = { [weak self] in self?.close() }

        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 35
        // HDR with bloom so emissive parts glow; exposure stays fixed so the model doesn't pulse as it grows.
        camera.camera?.wantsHDR = true
        camera.camera?.wantsExposureAdaptation = false
        camera.camera?.bloomIntensity = 0.9
        camera.camera?.bloomThreshold = 0.75
        camera.camera?.bloomBlurRadius = 10
        camera.position = SCNVector3(0, 0, framedDistance)
        scene.rootNode.addChildNode(camera)
        view.pointOfView = camera
        // Three-point studio lighting: a key light with soft shadows, a cool fill, and a rim to separate the model
        // from whatever is behind it on screen.
        for (position, intensity, color, castsShadow) in [
            (SCNVector3(6, 9, 8), 1400.0, NSColor.white, true),
            (SCNVector3(-8, 2, 5), 450.0, NSColor(srgbRed: 0.75, green: 0.85, blue: 1, alpha: 1), false),
            (SCNVector3(0, 4, -9), 900.0, NSColor(srgbRed: 1, green: 0.92, blue: 0.85, alpha: 1), false),
        ] {
            let light = SCNNode()
            light.light = SCNLight()
            light.light?.type = .directional
            light.light?.intensity = intensity
            light.light?.color = color
            light.light?.castsShadow = castsShadow
            light.light?.shadowMode = .deferred
            light.light?.shadowRadius = 6
            light.light?.shadowSampleCount = 8
            light.light?.shadowColor = NSColor(white: 0, alpha: 0.45)
            light.position = position
            light.look(at: SCNVector3Zero)
            scene.rootNode.addChildNode(light)
        }
        scene.rootNode.addChildNode(rotator)
        rotator.addChildNode(model)

        view.addSubview(makeToolbar())
        window.contentView = view
        window.orderFrontRegardless()
    }

    /// Adds one streamed part. Returns false for lines that aren't a part (like the title) or don't parse.
    @discardableResult
    func add(_ line: JSON) -> Bool {
        if let id = line["remove"] as? String {
            parts.removeValue(forKey: id)?.removeFromParentNode()
            return false
        }
        if line["shape"] == nil, line["label"] == nil {
            if let name = line["group"] as? String { declareGroup(name, line) }
            if let name = line["mat"] as? String { materials[name] = line }
            return false
        }
        // A named material supplies color and surface; anything on the line itself wins.
        let part = (line["m"] as? String).flatMap { materials[$0] }?.merging(line) { _, own in own } ?? line
        guard var node = ModelPart.node(from: part) else { return false }
        if let spec = part["repeat"] as? JSON { node = repeated(node, spec) }
        if part["label"] != nil {
            // Labels come last, so the model's size is known: keep them small relative to it.
            let scale = max(CGFloat(model.boundingSphere.radius), 1) * 0.08
            node.scale = SCNVector3(scale, scale, scale)
            labels.append(node)
        }
        if let id = part["id"] as? String {
            // Reusing an id replaces that part, so the polish pass can fix things in place.
            parts[id]?.removeFromParentNode()
            parts[id] = node
        }
        node.opacity = 0
        if let name = part["group"] as? String, let group = groups[name] {
            // Groups sit at their pivot, so parts given in model coordinates are shifted into the group's frame.
            node.position = SCNVector3(
                node.position.x - group.position.x, node.position.y - group.position.y,
                node.position.z - group.position.z
            )
            group.addChildNode(node)
        } else {
            model.addChildNode(node)
        }
        node.runAction(.fadeOpacity(to: CGFloat(part["opacity"] as? Double ?? 1), duration: 0.2))
        if part["label"] == nil { frameModel() }
        return true
    }

    /// Copies of one part: `count` of them rotated evenly (or by `angle` in total) around `axis` through `pivot`, or
    /// offset by `step` each. One streamed line becomes blades, gear teeth, bolts, or a row of panels.
    private func repeated(_ node: SCNNode, _ spec: JSON) -> SCNNode {
        let count = min(max((spec["count"] as? NSNumber)?.intValue ?? 1, 1), 200)
        let container = SCNNode()
        let pivot = ModelPart.vector(spec["pivot"]) ?? SCNVector3Zero
        let axis = ModelPart.vector(spec["axis"])
        let step = ModelPart.vector(spec["step"]) ?? SCNVector3Zero
        let totalAngle = (spec["angle"] as? NSNumber)?.doubleValue ?? 360
        let angleStep =
            (totalAngle >= 360 ? totalAngle / Double(count) : totalAngle / Double(max(count - 1, 1))) * .pi / 180
        for index in 0..<count {
            let copy = node.clone()
            if let axis, axis.x != 0 || axis.y != 0 || axis.z != 0 {
                let spinner = SCNNode()
                spinner.position = pivot
                spinner.rotation = SCNVector4(axis.x, axis.y, axis.z, CGFloat(angleStep * Double(index)))
                copy.position = SCNVector3(
                    copy.position.x - pivot.x, copy.position.y - pivot.y, copy.position.z - pivot.z)
                spinner.addChildNode(copy)
                container.addChildNode(spinner)
            } else {
                let offset = CGFloat(index)
                copy.position = SCNVector3(
                    copy.position.x + step.x * offset, copy.position.y + step.y * offset,
                    copy.position.z + step.z * offset
                )
                container.addChildNode(copy)
            }
        }
        return container
    }

    /// A named set of parts that moves together, optionally spinning around an axis through its pivot.
    private func declareGroup(_ name: String, _ part: JSON) {
        guard groups[name] == nil, let pivot = ModelPart.vector(part["pivot"]) ?? Optional(SCNVector3Zero) else {
            return
        }
        let group = SCNNode()
        group.position = pivot
        model.addChildNode(group)
        groups[name] = group
        let turnsPerSecond = min(max((part["rps"] as? NSNumber)?.doubleValue ?? 0, 0), 2)
        if turnsPerSecond > 0, let axis = ModelPart.vector(part["spin"]) {
            let length = sqrt(axis.x * axis.x + axis.y * axis.y + axis.z * axis.z)
            guard length > 0 else { return }
            let spin = SCNAction.rotate(
                by: .pi * 2, around: SCNVector3(axis.x / length, axis.y / length, axis.z / length),
                duration: 1 / turnsPerSecond
            )
            group.runAction(.repeatForever(spin))
        }
    }

    /// A soft studio backdrop for reflections: bright overhead, a warm horizon band, and a dark floor.
    private static let studioEnvironment: NSImage = {
        NSImage(size: NSSize(width: 256, height: 128), flipped: false) { rect in
            NSGradient(
                colorsAndLocations: (NSColor(white: 0.08, alpha: 1), 0),
                (NSColor(white: 0.25, alpha: 1), 0.42),
                (NSColor(srgbRed: 1, green: 0.93, blue: 0.85, alpha: 1), 0.52),
                (NSColor(white: 0.55, alpha: 1), 0.62),
                (NSColor(white: 0.95, alpha: 1), 1)
            )?.draw(in: rect, angle: 90)
            return true
        }
    }()

    /// The rendered model on a dark backdrop, for the polish pass to look at.
    func snapshotJPEG() -> Data? {
        let image = view.snapshot()
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    func close() {
        polish?.cancel()
        window.orderOut(nil)
        view.scene = nil
        Self.openWindows.removeAll { $0 === self }
        if Self.openWindows.isEmpty { Self.stopEscapeMonitors() }
    }

    private func rotate(dx: CGFloat, dy: CGFloat) {
        var angles = rotator.eulerAngles
        angles.y += dx * 0.01
        angles.x = min(max(angles.x + dy * 0.01, -.pi / 2), .pi / 2)
        rotator.eulerAngles = angles
    }

    /// Pinching grows or shrinks the window around its center, so the whole model gets bigger on screen instead of
    /// being cropped by a closer camera.
    private func resize(by amount: CGFloat) {
        let frame = window.frame
        let side = min(max(frame.width * (1 + amount), 200), 1800)
        window.setFrame(
            NSRect(x: frame.midX - side / 2, y: frame.midY - side / 2, width: side, height: side), display: true)
    }

    private func resetView() {
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.3
        rotator.eulerAngles = SCNVector3Zero
        camera.position = SCNVector3(0, 0, framedDistance)
        SCNTransaction.commit()
    }

    private func toggleLabels() {
        let isHidden = !(labels.first?.isHidden ?? true)
        labels.forEach { $0.isHidden = isHidden }
    }

    /// Keeps the growing model centered and fully in view.
    private func frameModel() {
        let (center, radius) = model.boundingSphere
        model.pivot = SCNMatrix4MakeTranslation(center.x, center.y, center.z)
        framedDistance = max(CGFloat(radius), 0.5) / sin(CGFloat(camera.camera?.fieldOfView ?? 35) * .pi / 360) * 1.1
        camera.position = SCNVector3(0, 0, framedDistance)
    }

    /// Reset view, show or hide labels, close. Appears while the pointer is over the model.
    private func makeToolbar() -> NSView {
        let buttons = [
            ("arrow.counterclockwise", "Reset view", #selector(resetPressed)),
            ("tag", "Show or hide labels", #selector(labelsPressed)),
            ("xmark", "Close", #selector(closePressed)),
        ].map { symbol, tip, action in
            let button = FirstMouseButton(
                image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: action
            )
            button.isBordered = false
            button.contentTintColor = .white
            button.toolTip = tip
            return button
        }
        let stack = NSStackView(views: buttons)
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 14)
        let pill = NSVisualEffectView()
        pill.material = .hudWindow
        pill.state = .active
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 15
        pill.appearance = NSAppearance(named: .darkAqua)
        pill.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        pill.frame = NSRect(origin: .zero, size: stack.fittingSize)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: pill.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: pill.trailingAnchor),
            stack.topAnchor.constraint(equalTo: pill.topAnchor),
            stack.bottomAnchor.constraint(equalTo: pill.bottomAnchor),
        ])
        pill.setFrameOrigin(NSPoint(x: (Self.size - pill.frame.width) / 2, y: Self.size - pill.frame.height - 12))
        // Stays centered at the top as pinching resizes the window.
        pill.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
        pill.alphaValue = 0
        view.toolbar = pill
        return pill
    }

    @objc private func resetPressed() { resetView() }
    @objc private func labelsPressed() { toggleLabels() }
    @objc private func closePressed() { close() }

    private static func startEscapeMonitors() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = .escape { openWindows.forEach { $0.close() } }
    }

    private static func stopEscapeMonitors() {
        escapeMonitor = nil
    }
}

/// Can become key so drags and scrolls reach the view, without activating D-Shift.
private final class ModelPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Buttons in a panel that isn't key ignore the first click by default.
private final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class ModelView: SCNView {
    var onRotate: (CGFloat, CGFloat) -> Void = { _, _ in }
    var onZoom: (CGFloat) -> Void = { _ in }
    var onClose: () -> Void = {}
    weak var toolbar: NSView?
    private var isRotating = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { toolbar?.animator().alphaValue = 1 }
    override func mouseExited(with event: NSEvent) { toolbar?.animator().alphaValue = 0 }

    /// Plain drag moves the window; Option-drag rotates the model.
    override func mouseDown(with event: NSEvent) {
        isRotating = event.modifierFlags.contains(.option)
        if !isRotating { window?.performDrag(with: event) }
    }

    override func mouseDragged(with event: NSEvent) {
        if isRotating { onRotate(event.deltaX, event.deltaY) }
    }

    /// Two-finger swipes rotate; a mouse wheel turns the model around its vertical axis.
    override func scrollWheel(with event: NSEvent) {
        if event.hasPreciseScrollingDeltas {
            onRotate(-event.scrollingDeltaX, -event.scrollingDeltaY)
        } else {
            onRotate(-event.scrollingDeltaY * 8, 0)
        }
    }

    override func magnify(with event: NSEvent) {
        onZoom(event.magnification)
    }

    override func rightMouseDown(with event: NSEvent) {
        onClose()
    }
}

/// Turns one JSON line into a SceneKit node.
@MainActor
private enum ModelPart {
    static func node(from part: JSON) -> SCNNode? {
        if let text = part["label"] as? String, let position = vector(part["position"]) {
            return label(text, at: position)
        }
        let material = material(for: part)
        switch part["shape"] as? String {
        case "sphere":
            guard let position = vector(part["position"]) else { return nil }
            let sphere = SCNSphere(radius: number(part["radius"], 0.2))
            sphere.segmentCount = 72
            return positioned(sphere, at: position, material: material)
        case "box":
            guard let position = vector(part["position"]), let size = vector(part["size"]) else { return nil }
            let box = SCNBox(
                width: size.x, height: size.y, length: size.z, chamferRadius: min(size.x, size.y, size.z) * 0.08)
            return rotated(positioned(box, at: position, material: material), part["rotation"])
        case "capsule":
            guard let from = vector(part["from"]), let to = vector(part["to"]) else { return nil }
            let radius = number(part["radius"], 0.1)
            return span(from: from, to: to, material: material) {
                let capsule = SCNCapsule(capRadius: radius, height: $0 + radius * 2)
                capsule.radialSegmentCount = 64
                capsule.capSegmentCount = 24
                return capsule
            }
        case "extrude":
            let outline = (part["points"] as? [Any] ?? []).prefix(300).compactMap { value -> CGPoint? in
                guard let pair = value as? [NSNumber], pair.count == 2 else { return nil }
                return CGPoint(x: pair[0].doubleValue, y: pair[1].doubleValue)
            }
            guard outline.count > 2, let position = vector(part["position"]) else { return nil }
            let path = NSBezierPath()
            path.move(to: outline[0])
            outline.dropFirst().forEach { path.line(to: $0) }
            path.close()
            path.flatness = 0.01
            let shape = SCNShape(path: path, extrusionDepth: max(number(part["depth"], 0.1), 0.001))
            shape.chamferMode = .both
            shape.chamferRadius = min(number(part["depth"], 0.1) * 0.15, 0.03)
            return rotated(positioned(shape, at: position, material: material), part["rotation"])
        case "cylinder":
            guard let from = vector(part["from"]), let to = vector(part["to"]) else { return nil }
            return span(from: from, to: to, material: material) {
                let cylinder = SCNCylinder(radius: number(part["radius"], 0.1), height: $0)
                cylinder.radialSegmentCount = 64
                return cylinder
            }
        case "cone":
            guard let from = vector(part["from"]), let to = vector(part["to"]) else { return nil }
            return span(from: from, to: to, material: material) {
                let cone = SCNCone(topRadius: 0, bottomRadius: number(part["radius"], 0.2), height: $0)
                cone.radialSegmentCount = 64
                return cone
            }
        case "torus":
            guard let position = vector(part["position"]) else { return nil }
            let torus = SCNTorus(ringRadius: number(part["ringRadius"], 1), pipeRadius: number(part["pipeRadius"], 0.1))
            torus.ringSegmentCount = 96
            torus.pipeSegmentCount = 32
            return rotated(positioned(torus, at: position, material: material), part["rotation"])
        case "tube":
            let points = (part["points"] as? [Any] ?? []).prefix(200).compactMap(vector)
            guard points.count > 1 else { return nil }
            let radius = number(part["radius"], 0.08)
            let given = (part["radii"] as? [NSNumber] ?? []).map { CGFloat($0.doubleValue) }
            let radii = given.count == points.count ? given : Array(repeating: radius, count: points.count)
            let tube = SCNNode(geometry: Mesh.tube(through: points, radii: radii))
            tube.geometry?.materials = [material]
            // Rounded ends.
            for (point, end) in [(points[0], radii[0]), (points[points.count - 1], radii[radii.count - 1])]
            where end > 0.005 {
                let cap = SCNSphere(radius: end)
                cap.segmentCount = 48
                tube.addChildNode(positioned(cap, at: point, material: material))
            }
            return tube
        case "lathe":
            let profile = (part["profile"] as? [Any] ?? []).prefix(200).compactMap { value -> CGPoint? in
                guard let pair = value as? [NSNumber], pair.count == 2 else { return nil }
                return CGPoint(x: max(pair[0].doubleValue, 0), y: pair[1].doubleValue)
            }
            guard profile.count > 1, let position = vector(part["position"]) else { return nil }
            let lathe = SCNNode(geometry: Mesh.lathe(profile))
            lathe.geometry?.materials = [material]
            lathe.position = position
            return rotated(lathe, part["rotation"])
        default:
            return nil
        }
    }

    private static func positioned(_ geometry: SCNGeometry, at position: SCNVector3, material: SCNMaterial) -> SCNNode {
        geometry.materials = [material]
        let node = SCNNode(geometry: geometry)
        node.position = position
        return node
    }

    /// A shape stretched between two points, for geometry that SceneKit builds along its y axis.
    private static func span(from: SCNVector3, to: SCNVector3, material: SCNMaterial, make: (CGFloat) -> SCNGeometry)
        -> SCNNode?
    {
        let direction = SCNVector3(to.x - from.x, to.y - from.y, to.z - from.z)
        let length = sqrt(direction.x * direction.x + direction.y * direction.y + direction.z * direction.z)
        guard length > 0.0001 else { return nil }
        let node = positioned(
            make(length), at: SCNVector3((from.x + to.x) / 2, (from.y + to.y) / 2, (from.z + to.z) / 2),
            material: material)
        let isVertical = abs(direction.y) / length > 0.999
        node.look(at: to, up: isVertical ? SCNVector3(1, 0, 0) : SCNVector3(0, 1, 0), localFront: SCNVector3(0, 1, 0))
        return node
    }

    private static func rotated(_ node: SCNNode, _ value: Any?) -> SCNNode {
        if let degrees = vector(value) {
            node.eulerAngles = SCNVector3(degrees.x * .pi / 180, degrees.y * .pi / 180, degrees.z * .pi / 180)
        }
        return node
    }

    private static func material(for part: JSON) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = color(part["color"]) ?? NSColor.systemOrange
        material.metalness.contents = number(part["metalness"], 0.1)
        material.roughness.contents = number(part["roughness"], 0.5)
        if let emission = color(part["emission"]) {
            material.emission.contents = emission
            material.emission.intensity = 2
        }
        if number(part["opacity"], 1) < 1 {
            // See-through shells: blend, and skip depth writes so the parts inside still show.
            material.blendMode = .alpha
            material.writesToDepthBuffer = false
            material.isDoubleSided = true
        }
        return material
    }

    /// A pill-shaped label that always faces the camera and draws on top of the model.
    private static func label(_ text: String, at position: SCNVector3) -> SCNNode {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 28, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let string = String(text.prefix(40)) as NSString
        let textSize = string.size(withAttributes: attributes)
        let padding = CGSize(width: 20, height: 10)
        let imageSize = NSSize(width: textSize.width + padding.width * 2, height: textSize.height + padding.height * 2)
        let image = NSImage(size: imageSize, flipped: false) { rect in
            NSColor(white: 0.08, alpha: 0.88).setFill()
            NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
            string.draw(at: NSPoint(x: padding.width, y: padding.height), withAttributes: attributes)
            return true
        }
        // Unit height; ModelWindow scales labels to the model.
        let height: CGFloat = 1
        let plane = SCNPlane(width: height * imageSize.width / imageSize.height, height: height)
        let material = SCNMaterial()
        material.diffuse.contents = image
        material.lightingModel = .constant
        material.readsFromDepthBuffer = false
        plane.materials = [material]
        let node = SCNNode(geometry: plane)
        node.position = position
        node.renderingOrder = 100
        node.constraints = [SCNBillboardConstraint()]
        return node
    }

    static func vector(_ value: Any?) -> SCNVector3? {
        guard let values = value as? [Any], values.count == 3 else { return nil }
        let numbers = values.compactMap { ($0 as? NSNumber)?.doubleValue }
        guard numbers.count == 3, numbers.allSatisfy(\.isFinite) else { return nil }
        return SCNVector3(numbers[0], numbers[1], numbers[2])
    }

    private static func number(_ value: Any?, _ fallback: CGFloat) -> CGFloat {
        guard let value = (value as? NSNumber)?.doubleValue, value.isFinite else { return fallback }
        return CGFloat(value)
    }

    private static func color(_ value: Any?) -> NSColor? {
        guard var hex = value as? String else { return nil }
        hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard hex.count == 6, let rgb = UInt32(hex, radix: 16) else { return nil }
        return NSColor(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255, alpha: 1
        )
    }
}

/// Smooth surfaces SceneKit has no primitive for, built as triangle meshes with smooth normals.
private enum Mesh {
    /// A profile of (radius, height) points spun around the y axis: bodies, torsos, limbs, vases, domes, nose cones.
    static func lathe(_ profile: [CGPoint], segments: Int = 72) -> SCNGeometry {
        // Normals assume the profile runs upward.
        let profile = (profile.last?.y ?? 0) < (profile.first?.y ?? 0) ? profile.reversed() : profile
        var vertices: [SCNVector3] = []
        var normals: [SCNVector3] = []
        for (index, point) in profile.enumerated() {
            let previous = profile[max(index - 1, 0)]
            let next = profile[min(index + 1, profile.count - 1)]
            let (dr, dy) = (next.x - previous.x, next.y - previous.y)
            let length = max(sqrt(dr * dr + dy * dy), 1e-6)
            for step in 0...segments {
                let angle = CGFloat(step) / CGFloat(segments) * 2 * .pi
                vertices.append(SCNVector3(point.x * cos(angle), point.y, point.x * sin(angle)))
                normals.append(SCNVector3(dy / length * cos(angle), -dr / length, dy / length * sin(angle)))
            }
        }
        return mesh(vertices: vertices, normals: normals, rings: profile.count, ringSize: segments + 1)
    }

    /// A tube swept along a Catmull-Rom curve through `points`, with radii interpolated between them.
    static func tube(through points: [SCNVector3], radii: [CGFloat], sides: Int = 24, samplesPerSegment: Int = 8)
        -> SCNGeometry
    {
        let control = points.map { SIMD3<Double>(Double($0.x), Double($0.y), Double($0.z)) }
        var centers: [SIMD3<Double>] = []
        var sampleRadii: [Double] = []
        for index in 0..<(control.count - 1) {
            let p0 = control[max(index - 1, 0)]
            let p1 = control[index]
            let p2 = control[index + 1]
            let p3 = control[min(index + 2, control.count - 1)]
            let last = index == control.count - 2
            for step in 0..<(samplesPerSegment + (last ? 1 : 0)) {
                let t = Double(step) / Double(samplesPerSegment)
                let t2 = t * t
                let t3 = t2 * t
                let a: SIMD3<Double> = 2 * p1
                let b: SIMD3<Double> = p2 - p0
                let c: SIMD3<Double> = 2 * p0 - 5 * p1 + 4 * p2 - p3
                let d: SIMD3<Double> = 3 * p1 - p0 - 3 * p2 + p3
                let point: SIMD3<Double> = a + b * t + c * t2 + d * t3
                centers.append(0.5 * point)
                sampleRadii.append(Double(radii[index]) * (1 - t) + Double(radii[index + 1]) * t)
            }
        }
        // Parallel-transport frames keep the tube from twisting along the curve.
        var tangents = centers.indices.map { index in
            simd_normalize(centers[min(index + 1, centers.count - 1)] - centers[max(index - 1, 0)] + SIMD3(0, 1e-9, 0))
        }
        if tangents.isEmpty { tangents = [SIMD3(0, 1, 0)] }
        var normal = simd_normalize(simd_cross(tangents[0], abs(tangents[0].y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)))
        var vertices: [SCNVector3] = []
        var normals: [SCNVector3] = []
        for (index, center) in centers.enumerated() {
            let tangent = tangents[index]
            normal = simd_normalize(normal - tangent * simd_dot(normal, tangent))
            let binormal = simd_cross(normal, tangent)
            for step in 0...sides {
                let angle = Double(step) / Double(sides) * 2 * .pi
                let direction = normal * cos(angle) + binormal * sin(angle)
                let point = center + direction * sampleRadii[index]
                vertices.append(SCNVector3(point.x, point.y, point.z))
                normals.append(SCNVector3(direction.x, direction.y, direction.z))
            }
        }
        return mesh(vertices: vertices, normals: normals, rings: centers.count, ringSize: sides + 1)
    }

    /// Stitches consecutive rings of vertices into triangles.
    private static func mesh(vertices: [SCNVector3], normals: [SCNVector3], rings: Int, ringSize: Int) -> SCNGeometry {
        var indices: [UInt32] = []
        for ring in 0..<UInt32(max(rings - 1, 0)) {
            for step in 0..<UInt32(ringSize - 1) {
                let a = ring * UInt32(ringSize) + step
                let b = a + UInt32(ringSize)
                indices += [a, b, a + 1, a + 1, b, b + 1]
            }
        }
        return SCNGeometry(
            sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals)],
            elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)]
        )
    }
}
