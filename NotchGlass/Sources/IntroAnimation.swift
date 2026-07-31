import AppKit
import AVFoundation
import CoreImage
import SceneKit

/// The first-run intro — the app's whole onboarding, and the only one.
///
/// The screen dims to a veil of black — not a blackout; the desktop stays faintly
/// there behind it — and the Notchi mark swings in dead center, already a solid of
/// glass. It idles there, turning slowly so the light travels across its bevels,
/// then spins once, fast, the way the Dynamic Island flips a transit card —
/// shrinking and rising as it turns — and tucks into the notch. The panel opens on
/// the chat prompt the instant it lands.
///
/// The mark is only the glyph — the flag and its dot, the shapes from the middle
/// of the app icon, lifted out and given depth. No plate, no rounded square: what
/// flies is the mark itself.
///
/// Built in SceneKit because the "3D" has to be real: extruded geometry with
/// chamfered edges, plus a fragment shader that refracts an environment through
/// the solid (see `glassShader`) — SceneKit's own transparency is a flat alpha
/// blend and reads as tinted plastic. A faked pseudo-3D (layer transforms on a
/// PNG) falls apart at exactly the moment this animation is about — the turn.
///
/// Every value is written per frame from our own clock rather than handed to
/// SceneKit as an implicit animation. In a borderless overlay window SceneKit's
/// animation clock never advances (the symptom: a scene frozen on frame zero —
/// model values set, presentation values never moving) and the view's own display
/// link never fires, so a plain run-loop timer drives it and `sceneTime` is what
/// pushes each redraw. It also makes the whole run a pure function of elapsed
/// time, so a skip can cut in anywhere.
///
/// Plays once ever, on a fresh install (see `OnboardingService`). Esc or a click
/// skips straight to the panel; reduce-motion skips it entirely.
@MainActor
final class IntroAnimation {
    static let shared = IntroAnimation()
    private init() {}

    // MARK: - Timeline
    //
    // Seconds from the moment the overlay shows. It is a solid of glass from the
    // first frame — there is no flat-then-3D beat, because there is nothing for a
    // flat one to become. What fills the hold is the drift: glass only reads as
    // glass while the highlights are moving across it.
    private enum T {
        static let veilIn: TimeInterval      = 0.75
        /// The emergence: the mark starts screen-filling and barely there, then
        /// rises and gathers into the solid at its resting size.
        static let emergeAt: TimeInterval    = 0.20
        static let emerge: TimeInterval      = 3.60
        /// The turn + shrink + flight into the notch — unchanged.
        static let flightAt: TimeInterval    = 6.20
        static let flight: TimeInterval      = 1.15
        static let veilOut: TimeInterval     = 0.90
        static var end: TimeInterval { flightAt + flight + 0.04 }
    }

    // MARK: - Scene constants (icon units: the 1024px icon canvas ÷ 10)

    /// How deep the glass runs. Chunky on purpose — a thin one would read as a
    /// decal, and the depth is what the refraction has to work with.
    private static let glyphDepth: CGFloat = 30
    /// The mark's width/height in those units (the flag plus its dot).
    private static let markSize: CGFloat = 44.4

    /// How much of the screen's height the mark occupies while it's on stage.
    private static let stageFraction: CGFloat = 0.29

    /// The veil over the desktop, as a vignette: heavier at the corners, lighter
    /// through the middle, so the frame closes in around the mark instead of
    /// flattening the whole screen to one grey. Neither end is opaque — the desktop
    /// reads through both.
    private static let veilCentre: Double = 0.34
    private static let veilEdge: Double = 0.82

    /// Where the emergence starts: big enough to overfill the screen, lifted from
    /// below, so the mark rises INTO its resting size rather than fading up in
    /// place. (Resting size is `stageFraction` of the screen height, so 1/0.29 ≈ 3.4
    /// already fills it — 4.2 overfills, and the shape reads as passing the camera.)
    private static let emergeScale: CGFloat = 4.2
    private static let emergeRise: CGFloat = 62

    /// A slow push through the hold: the mark's on-screen size is held by the
    /// framing maths, so opening the lens only deepens the perspective — the shape
    /// keeps unfolding rather than sitting still.
    private static let fovNear: CGFloat = 30
    private static let fovFar: CGFloat = 38

    /// The mark's resting attitude — enough of a turn to show it has sides, not so
    /// much that it stops reading as the mark.
    private static let tiltX: CGFloat = -0.10
    private static let tiltY: CGFloat = 0.20
    /// How fast it idles round, in radians per second, while it's on stage.
    private static let driftRate: CGFloat = 0.14

    // MARK: - Live state

    private var window: NSWindow?
    /// The veil's material — a plane inside the scene, see `buildScene`.
    private var veilMaterial: SCNMaterial?
    private var sceneView: SCNView?
    /// Carries the flight: position + uniform scale.
    private var flyNode: SCNNode?
    /// Carries the turn, the tilt and the thickening.
    private var spinNode: SCNNode?
    private var cameraNode: SCNNode?
    private var camera: SCNCamera?
    /// Every glass material in the mark (two per piece — see `glassPasses`), so the
    /// per-frame `presence` can be pushed to all of them at once.
    private var glassMaterials: [SCNMaterial] = []
    /// Held past teardown on purpose so the tail can ring out (see `playArrivalCue`).
    private var audioPlayer: AVAudioPlayer?
    /// The cue fires exactly once, on the frame the emergence starts.
    private var chimed = false
    private var ticker: Timer?
    private var startedAt: CFTimeInterval = 0
    /// How far above center the notch sits, in world units (set once, at build).
    private var notchY: CGFloat = 0

    private var keyMonitor: Any?
    private var completion: (() -> Void)?
    /// Fired once, the moment the veil is fully down — see `play`.
    private var veiled: (() -> Void)?
    private var veilCalled = false
    private var done = false

    /// True while the overlay is up.
    private(set) var isPlaying = false

    // MARK: - Entry point

    /// Play the intro over `screen`, then call `finished` — always exactly once,
    /// whether the run ends naturally, is skipped, or never starts.
    ///
    /// `veiled` fires once the veil is fully down and the screen behind it can no
    /// longer be seen — the window to rearrange what's underneath without the user
    /// watching it happen. It never fires when the intro doesn't actually run (the
    /// Reduce Motion path below), because then there is no veil to hide behind.
    func play(on screen: NSScreen,
              veiled: (() -> Void)? = nil,
              finished: @escaping () -> Void) {
        guard !isPlaying else { return }
        completion = finished
        self.veiled = veiled
        veilCalled = false
        done = false

        // Reduce Motion: a full-screen dim with a spinning object is exactly what
        // that setting exists to opt out of. Land straight on the panel.
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            finish()
            return
        }

        isPlaying = true
        chimed = false
        buildWindow(on: screen)
        buildScene(on: screen)
        start()
    }

    // MARK: - Window

    private func buildWindow(on screen: NSScreen) {
        let frame = screen.frame
        let win = NSWindow(contentRect: frame,
                           styleMask: .borderless,
                           backing: .buffered,
                           defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.isMovable = false
        win.isReleasedWhenClosed = false
        // Above the island itself (`.statusBar`): nothing can draw over the veil,
        // and the mark shrinks into the notch rather than under it.
        win.level = .screenSaver
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                  .stationary, .ignoresCycle]
        win.appearance = NSAppearance(named: .darkAqua)

        let root = SkipCatcherView(frame: NSRect(origin: .zero, size: frame.size))
        root.wantsLayer = true
        root.onSkip = { [weak self] in self?.finish() }

        win.contentView = root
        win.setFrame(frame, display: true)
        win.orderFrontRegardless()

        window = win

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isPlaying else { return event }
            if event.keyCode == 53 { self.finish(); return nil }   // Esc
            return event
        }
    }

    // MARK: - Scene

    private func buildScene(on screen: NSScreen) {
        guard let root = window?.contentView else { return }

        let scene = SCNScene()
        scene.background.contents = NSColor.clear

        // --- the mark ---------------------------------------------------------
        // Just the glyph: the flag as an extruded slab, the dot as a marble.
        let spin = SCNNode()
        spin.addChildNode(Self.glassNode(path: Self.flagPath()))
        spin.addChildNode(Self.dotNode())

        let fly = SCNNode()
        fly.addChildNode(spin)
        scene.rootNode.addChildNode(fly)
        glassMaterials = spin.childNodes
            .flatMap(\.childNodes)
            .compactMap { $0.geometry?.firstMaterial }

        // --- the veil ----------------------------------------------------------
        // A vignette rather than a flat dim: heavier at the corners, lighter through
        // the middle (see `veilShader`). Drawn as a plane inside the scene rather
        // than as a layer behind the view — both AppKit routes failed on screen: a
        // layer-backed NSView has its backing layer re-synced by AppKit (which
        // discarded the background colour), and a hand-added sublayer is dropped when
        // the window takes over the content view. Geometry in a render we already
        // know works is the one dependable place to put it.
        //
        // Parented to the camera so the dolly can't slide it out of frame, and sized
        // to cover the frustum at the *widest* focal length the run reaches — that
        // way its UVs map onto the screen, which is what makes a screen-shaped
        // vignette possible at all.
        let veilDistance: CGFloat = 600
        let veilHeight = 2 * veilDistance * tan(Self.fovFar * .pi / 180 / 2)
        let aspect = screen.frame.width / max(screen.frame.height, 1)
        let veilPlane = SCNPlane(width: veilHeight * aspect * 1.02, height: veilHeight * 1.02)
        let veilMat = SCNMaterial()
        veilMat.lightingModel = .constant
        veilMat.diffuse.contents = NSColor.black
        veilMat.blendMode = .alpha
        veilMat.writesToDepthBuffer = false
        veilMat.isDoubleSided = true
        veilMat.shaderModifiers = [.fragment: Self.veilShader]
        veilMat.setValue(CGFloat(0), forKey: "strength")
        veilMat.setValue(CGFloat(Self.veilCentre), forKey: "inner")
        veilMat.setValue(CGFloat(Self.veilEdge), forKey: "outer")
        veilPlane.materials = [veilMat]
        let veilNode = SCNNode(geometry: veilPlane)
        veilNode.position = SCNVector3(0, 0, -veilDistance)
        veilNode.renderingOrder = -10
        veilMaterial = veilMat

        // --- light -------------------------------------------------------------
        // The glass builds its own colour in the fragment shader, so this is only
        // here to keep SceneKit's pipeline lit; the look comes from the environment
        // the shader samples, not from these.
        let keyLight = SCNLight()
        keyLight.type = .directional
        keyLight.color = NSColor.white
        keyLight.intensity = 900
        let keyNode = SCNNode()
        keyNode.light = keyLight
        keyNode.eulerAngles = SCNVector3(-0.5, -0.5, 0)
        scene.rootNode.addChildNode(keyNode)

        // --- camera -----------------------------------------------------------
        let cam = SCNCamera()
        cam.projectionDirection = .vertical
        cam.fieldOfView = Self.fovNear
        cam.zNear = 1
        cam.zFar = 8000
        let camNode = SCNNode()
        camNode.camera = cam
        camNode.position = SCNVector3(0, 0, Self.cameraDistance(fov: Self.fovNear))
        camNode.addChildNode(veilNode)
        scene.rootNode.addChildNode(camNode)

        // --- view -------------------------------------------------------------
        let view = SCNView(frame: root.bounds, options: nil)
        view.scene = scene
        view.pointOfView = camNode
        view.backgroundColor = .clear
        view.autoenablesDefaultLighting = false
        view.allowsCameraControl = false
        view.antialiasingMode = .multisampling4X
        view.autoresizingMask = [.width, .height]
        view.wantsLayer = true
        view.layer?.isOpaque = false
        root.addSubview(view)
        view.rendersContinuously = true
        view.isPlaying = true

        sceneView = view
        flyNode = fly
        spinNode = spin
        cameraNode = camNode
        camera = cam
        notchY = Self.notchTargetY(on: screen)
    }

    // MARK: - The run

    private func start() {
        apply(at: 0)
        startedAt = CACurrentMediaTime()
        // A plain run-loop timer, not `NSView.displayLink` — the view's display
        // link is never fired in this window (see the note on the type).
        guard sceneView != nil else { finish(); return }
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func tick() {
        let t = CACurrentMediaTime() - startedAt
        apply(at: min(t, T.end))
        // The veil has reached full strength: from here to the end nothing behind
        // it can be seen, so this is the moment the caller can rearrange what's on
        // the screen unnoticed (see `play`'s `veiled`).
        if !veilCalled, t >= T.veilIn {
            veilCalled = true
            let hand = veiled
            veiled = nil
            hand?()
        }
        if t >= T.end { finish() }
    }

    /// The whole animation as a pure function of elapsed time. Every frame writes
    /// every value, so there's no state to fall out of step and a skip can cut in
    /// anywhere.
    private func apply(at t: TimeInterval) {
        // 0…1 progress through each beat.
        let emerge = Self.easeInOut(Self.clamp01((t - T.emergeAt) / T.emerge))
        let flight = Self.clamp01((t - T.flightAt) / T.flight)

        // The veil: down at the start, lifted from the moment the mark takes
        // flight, so the last beat plays against the real desktop and the real
        // notch. It never reaches opaque — the desktop stays faintly present the
        // whole way through.
        let veilIn = Self.easeInOut(Self.clamp01(t / T.veilIn))
        let veilOut = Self.easeInOut(Self.clamp01((t - T.flightAt) / T.veilOut))
        veilMaterial?.setValue(CGFloat(veilIn * (1 - veilOut)), forKey: "strength")

        // SceneKit writes have to be instantaneous — an implicit animation here
        // would fight the per-frame values (and wouldn't advance anyway).
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0

        // The turn. A slow constant drift while it's on stage (highlights sliding
        // across the bevels is most of what makes glass read as glass), plus an
        // extra quarter that unwinds as it arrives so it *swings* into place. The
        // full revolution rides on top of both.
        let drift = Self.driftRate * min(t, T.flightAt)
        let swing = 0.40 * (1 - emerge)
        let turn = 2 * CGFloat.pi * Self.easeInOut(flight)
        spinNode?.eulerAngles = SCNVector3(Self.tiltX,
                                           Self.tiltY + drift + swing + turn,
                                           0)
        // It goes out in the last breath of the flight, not before.
        let tail = 1 - Self.clamp01((flight - 0.88) / 0.12)
        spinNode?.opacity = tail

        // How *there* the glass is. It comes in as a whisper — almost no alpha, no
        // brightness — and firms up as it settles, so the arrival reads as something
        // condensing out of the dark rather than a fade-in of a finished object.
        // Raised to a power so most of the solidity lands late: it stays ghostly
        // while it's still huge.
        let presence = 0.12 + 0.88 * pow(emerge, 1.8)
        for m in glassMaterials { m.setValue(CGFloat(presence), forKey: "presence") }
        if !chimed, t >= T.emergeAt {
            chimed = true
            playArrivalCue()
        }

        // The slow push — apparent size held, perspective deepening.
        let push = Self.clamp01(t / T.flightAt)
        let fov = Self.fovNear + (Self.fovFar - Self.fovNear) * push
        camera?.fieldOfView = fov
        cameraNode?.position = SCNVector3(0, 0, Self.cameraDistance(fov: fov))

        // The flight itself: rising on an accelerating curve (it's being pulled
        // in, not drifting), shrinking a touch behind the travel so the collapse
        // lands right as it arrives.
        //
        // The emergence rides these same two channels: it starts screen-filling and
        // low, and rises as it contracts to its resting size. The two never overlap
        // in time (the emergence has settled long before the flight starts), so
        // composing them — scale multiplied, rise summed — is exact.
        let travel = pow(flight, 1.35)
        let shrink = 1 - (1 - 0.004) * pow(flight, 2.4)
        let grand = Self.emergeScale + (1 - Self.emergeScale) * emerge
        let lift = -Self.emergeRise * (1 - emerge)
        let size = grand * shrink
        flyNode?.position = SCNVector3(0, lift + notchY * travel, 0)
        flyNode?.scale = SCNVector3(size, size, size)

        SCNTransaction.commit()

        // Advancing the scene's clock is what makes a paused SceneKit view redraw.
        sceneView?.sceneTime = t
    }

    // MARK: - Teardown

    /// Tear the overlay down and hand back to the caller. Safe to call twice (Esc
    /// during the last beat) — only the first call does anything.
    private func finish() {
        guard !done else { return }
        done = true
        isPlaying = false

        ticker?.invalidate()
        ticker = nil
        if let monitor = keyMonitor { NSEvent.removeMonitor(monitor) }
        keyMonitor = nil

        // A skip (Esc / click) can land before the veil ever reached full strength,
        // so the hook hasn't run. Still give it its turn — while the overlay is up
        // and in the same runloop pass as the handback below, so whatever it
        // rearranges is put back before a frame is ever drawn without it.
        if !veilCalled, window != nil {
            veilCalled = true
            let hand = veiled
            veiled = nil
            hand?()
        }
        veiled = nil

        sceneView?.removeFromSuperview()
        window?.orderOut(nil)
        window?.close()

        window = nil
        veilMaterial = nil
        sceneView = nil
        flyNode = nil
        spinNode = nil
        cameraNode = nil
        camera = nil
        glassMaterials = []

        let hand = completion
        completion = nil
        hand?()
    }

    // MARK: - Sound

    /// The arrival's sound: the low pedal that opens Strauss's *Sonnenaufgang* —
    /// organ and double basses, no brass, no melody, nothing that resolves. Cut
    /// from the recording rather than synthesised: two attempts at generating
    /// something ("a struck bell", "designed air") both came out as either a temple
    /// gong or a whoosh, because what this moment wants is an orchestra holding one
    /// chord, and that is not a thing you can fake with sine waves.
    ///
    /// The recording is Philip Milman's, from classicals.de, under CC BY 4.0 —
    /// which is why the About pane credits it. That licence is the whole reason
    /// this performance and not a better-known one: the famous recordings of this
    /// piece are all still in copyright (US sound recordings from 1954 run to 2049),
    /// and an intro that ships in a product can't rest on one.
    ///
    /// The cut is 17.8s–25.9s of the source: pure pedal, stopping half a second
    /// short of where the trumpet enters at 26.4s (measured, not eyeballed — the
    /// loudness envelope rises well before the brass does, so the entry has to be
    /// found spectrally). Long fades at both ends, peaked at 0.32.
    ///
    /// It is a bed, not a hit. There is deliberately no accent to sync the visuals
    /// to — an edit that lands a cymbal on the frame the mark solidifies reads as
    /// contrived, and did when it was tried. The cue simply runs underneath.
    ///
    /// Played through `AVAudioPlayer` and *not* torn down with the rest of the
    /// overlay: the tail is still fading when the panel opens, and cutting the
    /// engine there is exactly the abrupt stop this replaced.
    private func playArrivalCue() {
        guard let url = Bundle.main.url(forResource: "intro-sunrise", withExtension: "m4a"),
              let player = try? AVAudioPlayer(contentsOf: url)
        else { return }
        player.volume = 0.85
        player.prepareToPlay()
        player.play()
        audioPlayer = player
    }

    // MARK: - Geometry

    /// Every glass piece is drawn as two passes — back faces, then front faces —
    /// rather than as one double-sided material. Transparent surfaces don't write
    /// depth, so a double-sided pass blends its faces in whatever order they happen
    /// to be submitted: grazing side walls landed on top of face-on ones and the
    /// solid filled in as a milky wash. Two ordered single-sided passes mean exactly
    /// two glass layers per pixel, back behind front, the way looking through a
    /// solid actually works. `build` is called once per pass — the geometry can't be
    /// shared, since each pass needs its own material.
    private static func glassPasses(_ build: () -> SCNGeometry) -> SCNNode {
        let node = SCNNode()
        for (order, cull) in [(10, SCNCullMode.front), (20, SCNCullMode.back)] {
            let geometry = build()
            let material = glass()
            material.cullMode = cull
            material.isDoubleSided = false
            geometry.materials = [material]
            let face = SCNNode(geometry: geometry)
            face.renderingOrder = order
            node.addChildNode(face)
        }
        return node
    }

    /// The flag: extruded and chamfered. The chamfer is generous on purpose — the
    /// bevel is where a real glass solid does its lensing, and a hairline one gives
    /// the refraction nothing to bend around.
    private static func glassNode(path: NSBezierPath) -> SCNNode {
        path.flatness = 0.02
        return glassPasses {
            let shape = SCNShape(path: path, extrusionDepth: glyphDepth)
            shape.chamferRadius = 2.4
            shape.chamferMode = .both
            return shape
        }
    }

    /// The dot, as a marble. A sphere is the one shape whose whole surface is
    /// curved, so the refraction sweeps across it continuously as the mark turns —
    /// the extruded disc it replaced was a puck with two flat faces, and read as a
    /// short cylinder rather than a lens.
    private static func dotNode() -> SCNNode {
        let node = glassPasses {
            let sphere = SCNSphere(radius: dotRadius)
            sphere.segmentCount = 72
            return sphere
        }
        node.position = SCNVector3(dotCenter.x, dotCenter.y, 0)
        return node
    }

    /// The fragment stage of the glass: it discards SceneKit's shading entirely and
    /// rebuilds the surface the way glass actually works — a refracted look *through*
    /// the solid, a reflection off it, mixed by Fresnel, with the refraction sampled
    /// once per colour channel at slightly different indices so the bevels split
    /// into colour the way thick glass does.
    ///
    /// Stock SceneKit can't do this: its transparency is a flat alpha blend, which
    /// is why the material read as tinted plastic no matter how it was tuned. There
    /// is no refraction in the fixed pipeline at all.
    ///
    /// The one thing it can't be is a lens onto the actual desktop — the desktop
    /// isn't in our render target, and getting at it would mean screen recording
    /// permission. What bends is the environment below; what shows through the
    /// clear middle is the real desktop, undistorted.
    private static let glassShader = """
    #pragma arguments
    texture2d<float, access::sample> envTex;
    float ior;
    float dispersion;
    float clarity;
    float rimEdge;
    float rimBoost;
    float smoke;
    float gain;
    float presence;

    #pragma body
    constexpr sampler envSmp(filter::linear, address::repeat, mip_filter::linear);

    float3 n = normalize(_surface.normal);
    float3 v = normalize(_surface.view);
    // The solid is drawn double-sided, and SceneKit does NOT flip the normal on
    // back faces — so every back-facing pixel came out with dot(n,v) < 0, which
    // saturated Fresnel to 1 and painted the whole silhouette opaque white. Turn
    // the normal to face the eye first; everything downstream depends on it.
    if (dot(n, v) < 0.0) { n = -n; }
    float fres = pow(1.0 - saturate(dot(n, v)), 5.0);

    float3x3 toWorld = float3x3(scn_frame.inverseViewTransform[0].xyz,
                                scn_frame.inverseViewTransform[1].xyz,
                                scn_frame.inverseViewTransform[2].xyz);

    // Refraction — one sample per channel, so the rim splits into colour.
    float3 rr = toWorld * refract(-v, n, 1.0 / (ior - dispersion));
    float3 rg = toWorld * refract(-v, n, 1.0 / ior);
    float3 rb = toWorld * refract(-v, n, 1.0 / (ior + dispersion));
    float2 uvR = float2(atan2(rr.z, rr.x) / (2.0 * M_PI_F) + 0.5, acos(clamp(rr.y, -1.0, 1.0)) / M_PI_F);
    float2 uvG = float2(atan2(rg.z, rg.x) / (2.0 * M_PI_F) + 0.5, acos(clamp(rg.y, -1.0, 1.0)) / M_PI_F);
    float2 uvB = float2(atan2(rb.z, rb.x) / (2.0 * M_PI_F) + 0.5, acos(clamp(rb.y, -1.0, 1.0)) / M_PI_F);
    float3 refr = float3(envTex.sample(envSmp, uvR).r,
                         envTex.sample(envSmp, uvG).g,
                         envTex.sample(envSmp, uvB).b);

    // Reflection off the surface.
    float3 rl = toWorld * reflect(-v, n);
    float2 uvL = float2(atan2(rl.z, rl.x) / (2.0 * M_PI_F) + 0.5, acos(clamp(rl.y, -1.0, 1.0)) / M_PI_F);
    float3 refl = envTex.sample(envSmp, uvL).rgb;

    // Smoked, not milky: everything the glass gathers is scaled hard down, so what
    // it lays over the desktop is darkness rather than white. The rim highlight is
    // added AFTER the smoke and is the one thing allowed to be bright — without it
    // a dark solid on a dark veil has no edges at all.
    float3 col = mix(refr * 0.55, refl, saturate(0.05 + 0.95 * fres)) * smoke;
    col += rimBoost * fres * float3(0.86, 0.91, 1.0);

    // Clear through the middle, dense at the edges — the tell of a real solid.
    // Because the colour is now near-black, alpha reads as *how smoked* the glass
    // is rather than how white — so it can sit much higher than it could when the
    // body was bright, and the tint over the desktop is what gives the solid its
    // presence.
    // `presence` is the arrival: at 0 the glass is barely a rumour, at 1 it's the
    // solid. It scales alpha *and* the light the surface gathers, so a faint one
    // doesn't just go see-through, it goes dim too — the difference between glass
    // that isn't there yet and thin glass that is.
    _output.color.rgb = col * gain * presence;
    _output.color.a = mix(clarity, rimEdge, fres) * presence;
    """

    /// The veil, as a vignette: near-black everywhere, but denser toward the corners
    /// than through the middle, so the screen closes in around the mark rather than
    /// going uniformly grey. `strength` fades the whole thing in and back out.
    ///
    /// The plane's own UVs are the screen (see where it's built), so `r` is simply
    /// the distance from the centre of the frame.
    private static let veilShader = """
    #pragma arguments
    float strength;
    float inner;
    float outer;

    #pragma body
    float2 d = _surface.diffuseTexcoord - 0.5;
    float r = saturate(length(d) * 1.9);
    float a = mix(inner, outer, smoothstep(0.0, 1.0, r));
    _output.color = float4(0.0, 0.0, 0.0, a * strength);
    """

    /// The glass. Everything visible is built in `glassShader`; these properties
    /// only set up the blend and hand the shader its knobs.
    ///
    /// Two of these are made per piece, one per face direction — see `glassNode`.
    private static func glass() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = NSColor.black
        m.metalness.contents = 0.0
        m.roughness.contents = 0.02
        m.transparencyMode = .aOne
        m.blendMode = .alpha
        m.writesToDepthBuffer = false
        m.shaderModifiers = [.fragment: glassShader]

        let env = SCNMaterialProperty(contents: environmentImage())
        env.wrapS = .repeat
        env.wrapT = .clamp
        env.minificationFilter = .linear
        env.magnificationFilter = .linear
        m.setValue(env, forKey: "envTex")
        m.setValue(CGFloat(1.34), forKey: "ior")
        m.setValue(CGFloat(0.14), forKey: "dispersion")
        m.setValue(CGFloat(0.30), forKey: "clarity")
        m.setValue(CGFloat(0.55), forKey: "rimEdge")
        m.setValue(CGFloat(0.16), forKey: "rimBoost")
        m.setValue(CGFloat(0.08), forKey: "smoke")
        m.setValue(CGFloat(1.00), forKey: "gain")
        m.setValue(CGFloat(1.0), forKey: "presence")
        return m
    }

    /// The flag: the big square with the bite out of its bottom-right — traced off
    /// the shipped icon (1024px artwork, ÷10, origin re-centered).
    private static func flagPath() -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: -22.2, y: 22.2))
        path.line(to: NSPoint(x: 7.3, y: 22.2))
        path.line(to: NSPoint(x: 7.3, y: -7.3))
        path.line(to: NSPoint(x: -7.5, y: -7.3))
        path.line(to: NSPoint(x: -7.5, y: -22.1))
        path.line(to: NSPoint(x: -22.2, y: -22.1))
        path.close()
        return path
    }

    /// The dot that sits in the bite — centre and radius traced off the same
    /// artwork as the flag, so the marble lands exactly where the drawn dot is.
    private static let dotCenter = CGPoint(x: 14.8, y: -14.8)
    private static let dotRadius: CGFloat = 7.3

    // MARK: - Framing

    /// World units spanning the full height of the view — fixed, so the dolly and
    /// the zoom cancel out and the mark holds its size while its *perspective*
    /// changes.
    private static var stageHeight: CGFloat { markSize / stageFraction }

    /// How far back the camera must sit, at `fov`, to frame exactly `stageHeight`.
    private static func cameraDistance(fov: CGFloat) -> CGFloat {
        stageHeight / (2 * tan(fov * .pi / 180 / 2))
    }

    /// The notch's center, in world units above the screen's center — where the
    /// mark is headed.
    private static func notchTargetY(on screen: NSScreen) -> CGFloat {
        let height = screen.frame.height
        let inset = screen.safeAreaInsets.top
        let rest: CGFloat = inset > 0
            ? inset
            : max(24, min(40, screen.frame.maxY - screen.visibleFrame.maxY))
        return (height / 2 - rest / 2) * (stageHeight / height)
    }

    /// The room the glass is standing in, as an equirectangular map: a bright sky,
    /// a couple of softboxes, a warm kicker low and to one side, a dark floor with a
    /// bounce. This is the whole look — everything the shader shows is this image,
    /// bent. It is deliberately soft (a heavy blur at the end) so what travels
    /// across the bevels reads as light rather than as shapes.
    private static func environmentImage() -> CGImage? {
        let size = NSSize(width: 1024, height: 512)
        let image = NSImage(size: size)
        image.lockFocus()
        NSGradient(colors: [NSColor(calibratedRed: 1.00, green: 1.00, blue: 1.00, alpha: 1),
                            NSColor(calibratedRed: 0.86, green: 0.91, blue: 1.00, alpha: 1),
                            NSColor(calibratedRed: 0.45, green: 0.50, blue: 0.62, alpha: 1),
                            NSColor(calibratedRed: 0.62, green: 0.56, blue: 0.50, alpha: 1),
                            NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.22, alpha: 1)],
                   atLocations: [0, 0.30, 0.52, 0.72, 1],
                   colorSpace: .deviceRGB)?
            .draw(in: NSRect(origin: .zero, size: size), angle: 90)

        NSColor(calibratedWhite: 1, alpha: 0.95).setFill()
        NSBezierPath(roundedRect: NSRect(x: 90, y: 330, width: 300, height: 120),
                     xRadius: 60, yRadius: 60).fill()
        NSColor(calibratedWhite: 1, alpha: 0.75).setFill()
        NSBezierPath(roundedRect: NSRect(x: 600, y: 300, width: 180, height: 170),
                     xRadius: 85, yRadius: 85).fill()
        NSColor(calibratedRed: 0.55, green: 0.72, blue: 1.0, alpha: 0.6).setFill()
        NSBezierPath(roundedRect: NSRect(x: 420, y: 250, width: 120, height: 90),
                     xRadius: 45, yRadius: 45).fill()
        NSColor(calibratedRed: 1.0, green: 0.76, blue: 0.52, alpha: 0.45).setFill()
        NSBezierPath(ovalIn: NSRect(x: 830, y: 150, width: 150, height: 90)).fill()
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation, let ci = CIImage(data: tiff) else {
            return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        let soft = ci.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 22])
            .cropped(to: ci.extent)
        return CIContext().createCGImage(soft, from: soft.extent)
    }

    // MARK: - Easing

    private static func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }
    private static func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
    private static func easeInOut(_ x: Double) -> Double {
        x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    }
}

/// The overlay's content view: swallows every click that lands on the blackout
/// (nothing underneath should be reachable while it's up) and treats one as a
/// request to skip — the same escape hatch Esc gives.
private final class SkipCatcherView: NSView {
    var onSkip: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onSkip?() }
    override func rightMouseDown(with event: NSEvent) { onSkip?() }
    override func hitTest(_ point: NSPoint) -> NSView? { self }
}
