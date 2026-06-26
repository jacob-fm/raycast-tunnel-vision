import AppKit
import CoreText

// Tunnel Vision overlay helper.
//
// Draws a borderless, always-on-top, click-through HUD near the top-center of the
// main screen showing the current goal and an optional countdown. When the cursor is
// near it AND actively moving, the solid glowing text fades out — leaving a dashed
// light-grey outline of the text so the goal stays faintly legible — and snaps back
// to full opacity once the cursor leaves the area or goes still for longer than the
// inactivity threshold.
//
// When the countdown reaches zero, an optional set of "time's up" visual effects
// can take over (e.g. turning the text red, or zooming it to fill the screen). See
// the TimeUpEffect protocol below.
//
// Usage:
//   tunnelvision-overlay "<goal>" <durationSeconds> [inactivityThreshold] [nearMargin] [effects]
//
//   durationSeconds      0 = no timer (goal only)
//   inactivityThreshold  seconds of stillness before the HUD reappears (default 0.5)
//   nearMargin           points of padding around the HUD that count as "near" (default 90)
//   effects              comma-separated time's-up effect ids (e.g. "red,zoom")

let arguments = CommandLine.arguments
let goalText = arguments.count > 1 ? arguments[1] : "Focus"
let durationSeconds = arguments.count > 2 ? (Double(arguments[2]) ?? 0) : 0
let inactivityThreshold = arguments.count > 3 ? (Double(arguments[3]) ?? 0.5) : 0.5
let nearMargin: CGFloat = arguments.count > 4 ? CGFloat(Double(arguments[4]) ?? 90) : 90
let effectIds: [String] =
    arguments.count > 5
    ? arguments[5].split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    : []
// Optional "centerX,centerY,fontSize" chosen in place mode; nil = default top-center.
let placement = arguments.count > 6 ? parsePlacement(arguments[6]) : nil

// Place mode is a distinct subcommand:
//   tunnelvision-overlay place <outputPath> <goal> <sampleSeconds> <deeplink>
let isPlaceMode = arguments.count > 1 && arguments[1] == "place"

// MARK: - Small math helpers

func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

func lerpRect(_ a: NSRect, _ b: NSRect, _ t: CGFloat) -> NSRect {
    NSRect(
        x: lerp(a.minX, b.minX, t),
        y: lerp(a.minY, b.minY, t),
        width: lerp(a.width, b.width, t),
        height: lerp(a.height, b.height, t)
    )
}

func lerpColor(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
    let ca = a.usingColorSpace(.deviceRGB) ?? a
    let cb = b.usingColorSpace(.deviceRGB) ?? b
    return NSColor(
        deviceRed: lerp(ca.redComponent, cb.redComponent, t),
        green: lerp(ca.greenComponent, cb.greenComponent, t),
        blue: lerp(ca.blueComponent, cb.blueComponent, t),
        alpha: lerp(ca.alphaComponent, cb.alphaComponent, t)
    )
}

func easeInOut(_ t: CGFloat) -> CGFloat {
    let c = min(max(t, 0), 1)
    return c < 0.5 ? 2 * c * c : 1 - pow(-2 * c + 2, 2) / 2
}

// MARK: - Effect architecture
//
// A RenderStyle is the full set of knobs the overlay draws with on a given frame.
// The controller computes a "base" style each tick, then lets every active
// TimeUpEffect mutate it. `progress` ramps 0 → 1 once the timer hits zero, so
// effects can animate in rather than snapping. Because effects compose by each
// editing an independent facet of the style, any number can run at once; conflicts
// are resolved upstream in the form, not here.

struct RenderStyle {
    var textColor: NSColor
    var glowColor: NSColor
    var fontSize: CGFloat
    var frame: NSRect
}

// Immutable per-session reference values an effect may interpolate against.
struct EffectContext {
    let screen: NSRect
    let baseFrame: NSRect
    let baseFontSize: CGFloat
    let fullScreenFrame: NSRect
    let zoomFontSize: CGFloat
}

protocol TimeUpEffect {
    /// Mutate `style` toward this effect's "time's up" appearance.
    /// - Parameter progress: eased 0 → 1 ramp since the timer reached zero.
    func apply(to style: inout RenderStyle, progress: CGFloat, context: EffectContext)
}

/// Fades the neon-green text (and its glow) to alarm red.
struct RedTextEffect: TimeUpEffect {
    func apply(to style: inout RenderStyle, progress: CGFloat, context: EffectContext) {
        let redText = NSColor(calibratedRed: 1.0, green: 0.18, blue: 0.16, alpha: 1.0)
        let redGlow = NSColor(calibratedRed: 1.0, green: 0.12, blue: 0.10, alpha: 0.95)
        style.textColor = lerpColor(style.textColor, redText, progress)
        style.glowColor = lerpColor(style.glowColor, redGlow, progress)
    }
}

/// Fades the neon-green text (and its glow) to electric blue.
struct BlueTextEffect: TimeUpEffect {
    func apply(to style: inout RenderStyle, progress: CGFloat, context: EffectContext) {
        let blueText = NSColor(calibratedRed: 0.20, green: 0.55, blue: 1.0, alpha: 1.0)
        let blueGlow = NSColor(calibratedRed: 0.15, green: 0.45, blue: 1.0, alpha: 0.95)
        style.textColor = lerpColor(style.textColor, blueText, progress)
        style.glowColor = lerpColor(style.glowColor, blueGlow, progress)
    }
}

/// Glides the HUD to screen center and grows the text until it spans the screen.
struct ZoomEffect: TimeUpEffect {
    func apply(to style: inout RenderStyle, progress: CGFloat, context: EffectContext) {
        style.frame = lerpRect(style.frame, context.fullScreenFrame, progress)
        style.fontSize = lerp(style.fontSize, context.zoomFontSize, progress)
    }
}

/// Maps the form's effect ids onto concrete effects. Keep these ids in sync with
/// `TIME_UP_EFFECTS` in src/effects.ts.
func makeEffect(id: String) -> TimeUpEffect? {
    switch id {
    case "red": return RedTextEffect()
    case "blue": return BlueTextEffect()
    case "zoom": return ZoomEffect()
    default: return nil
    }
}

// MARK: - HUD rendering
//
// Draws the HUD text by stroking/filling the actual glyph outlines, which lets the
// fill cross-fade independently of a dashed "ghost" outline. `visibility` is the
// fade level (1 = solid glowing text, 0 = faded): as the filled text fades out when
// the cursor reaches for the HUD, a dashed light-grey outline of the same text fades
// in, so the goal stays faintly legible instead of vanishing entirely.

// The HUD text font. Helvetica Neue Bold, falling back to the heavy
// monospaced system font if it is somehow unavailable.
func tunnelVisionFont(ofSize size: CGFloat) -> NSFont {
    NSFont(name: "HelveticaNeue-Bold", size: size)
        ?? NSFont.monospacedSystemFont(ofSize: size, weight: .heavy)
}

final class GlyphHUDView: NSView {
    // The countdown sits on its own line above the goal at a smaller, secondary size.
    static let timeScale: CGFloat = 0.7

    var goalText = ""
    var timeText: String? = nil // nil ⇒ no timer ⇒ goal-only single line
    var font = tunnelVisionFont(ofSize: 30) // the goal (headline) font
    var fillColor = NSColor.green
    var glowColor = NSColor.green
    var glowRadius: CGFloat = 14
    var visibility: CGFloat = 1

    private let kern: CGFloat = 1.5

    private var timeFont: NSFont { tunnelVisionFont(ofSize: font.pointSize * Self.timeScale) }

    // Build the glyph outline of a single string at `f`, baseline at the origin, plus
    // its typographic metrics so callers can stack lines on consistent baselines.
    private func linePath(
        _ string: String, _ f: NSFont
    ) -> (path: CGPath, width: CGFloat, ascent: CGFloat, descent: CGFloat)? {
        guard !string.isEmpty else { return nil }
        let attributed = NSAttributedString(string: string, attributes: [.font: f, .kern: kern])
        let line = CTLineCreateWithAttributedString(attributed)

        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))

        let path = CGMutablePath()
        for runAny in CTLineGetGlyphRuns(line) as NSArray {
            let run = runAny as! CTRun
            let attrs = CTRunGetAttributes(run) as NSDictionary
            let runFontValue = attrs[kCTFontAttributeName as String]
            let runFont = runFontValue != nil ? (runFontValue as! CTFont) : (f as CTFont)
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            for i in 0..<count {
                guard let glyph = CTFontCreatePathForGlyph(runFont, glyphs[i], nil) else { continue }
                let transform = CGAffineTransform(translationX: positions[i].x, y: positions[i].y)
                path.addPath(glyph, transform: transform)
            }
        }
        return path.isEmpty ? nil : (path, width, ascent, descent)
    }

    // Compose a single path: the goal on its baseline, with the time stacked above it
    // (when present). Each line is centered horizontally about x = 0.
    func combinedPath() -> CGPath? {
        guard let goal = linePath(goalText, font) else { return nil }

        let combined = CGMutablePath()
        combined.addPath(
            goal.path, transform: CGAffineTransform(translationX: -goal.width / 2, y: 0)
        )

        if let timeText, let time = linePath(timeText, timeFont) {
            let gap = font.pointSize * 0.18
            let timeBaseline = goal.ascent + gap + time.descent
            combined.addPath(
                time.path,
                transform: CGAffineTransform(translationX: -time.width / 2, y: timeBaseline)
            )
        }

        return combined.isEmpty ? nil : combined
    }

    // Render `path` so its bounding box is centered on `c`, applying the current fill,
    // glow, outline and dashed-ghost styling. Shared by the HUD and the placement view.
    func drawGlyphs(_ path: CGPath, centeredAt c: CGPoint, in ctx: CGContext) {
        let box = path.boundingBoxOfPath
        ctx.saveGState()
        ctx.translateBy(x: c.x - box.midX, y: c.y - box.midY)

        // Solid, glowing fill + thin black outline — fades out as the HUD ghosts.
        if visibility > 0.001 {
            ctx.saveGState()
            ctx.setShadow(
                offset: .zero,
                blur: glowRadius,
                color: glowColor.withAlphaComponent(0.95 * visibility).cgColor
            )
            ctx.addPath(path)
            ctx.setFillColor(fillColor.withAlphaComponent(visibility).cgColor)
            ctx.fillPath()
            ctx.restoreGState()

            ctx.addPath(path)
            ctx.setLineWidth(font.pointSize * 0.03) // matches the old strokeWidth: -3
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.85 * visibility).cgColor)
            ctx.setLineJoin(.round)
            ctx.strokePath()
        }

        // Dashed light-grey ghost outline — fades in as the fill fades out.
        let ghost = 1 - visibility
        if ghost > 0.001 {
            let dash = font.pointSize * 0.12
            ctx.addPath(path)
            ctx.setLineDash(phase: 0, lengths: [dash, dash * 0.7])
            ctx.setLineWidth(max(1, font.pointSize * 0.02))
            ctx.setLineJoin(.round)
            ctx.setStrokeColor(NSColor(white: 0.82, alpha: ghost).cgColor)
            ctx.strokePath()
        }

        ctx.restoreGState()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let path = combinedPath() else { return }
        drawGlyphs(path, centeredAt: CGPoint(x: bounds.midX, y: bounds.midY), in: ctx)
    }
}

// The on-screen size of the HUD text (both lines) at a given goal font size. Used to
// frame the HUD around a chosen center and to lay out the placement-mode handles.
func hudContentSize(goal: String, timeText: String?, fontSize: CGFloat) -> CGSize {
    let goalFont = tunnelVisionFont(ofSize: fontSize)
    var width = (goal as NSString).size(withAttributes: [.font: goalFont, .kern: 1.5]).width
    var height = goalFont.ascender - goalFont.descender

    if let timeText {
        let timeFont = tunnelVisionFont(ofSize: fontSize * GlyphHUDView.timeScale)
        let timeWidth = (timeText as NSString).size(withAttributes: [.font: timeFont, .kern: 1.5]).width
        width = max(width, timeWidth)
        height += fontSize * 0.18 + (timeFont.ascender - timeFont.descender) // gap + time line
    }
    return CGSize(width: width, height: height)
}

// MARK: - Placement (drag to position, resize to scale the text)

struct Placement {
    var centerX: CGFloat
    var centerY: CGFloat
    var fontSize: CGFloat
}

// Parse the "centerX,centerY,fontSize" argument the form passes to normal mode.
func parsePlacement(_ s: String) -> Placement? {
    let parts = s.split(separator: ",").compactMap { Double($0) }
    guard parts.count == 3 else { return nil }
    return Placement(centerX: CGFloat(parts[0]), centerY: CGFloat(parts[1]), fontSize: CGFloat(parts[2]))
}

// Load a previously saved placement so re-entering place mode resumes where you left off.
func loadPlacementFile(_ path: String) -> Placement? {
    guard
        let data = FileManager.default.contents(atPath: path),
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let cx = obj["centerX"] as? Double,
        let cy = obj["centerY"] as? Double,
        let f = obj["fontSize"] as? Double
    else { return nil }
    return Placement(centerX: CGFloat(cx), centerY: CGFloat(cy), fontSize: CGFloat(f))
}

// A borderless window that can still take keyboard focus (so place mode can read
// Enter/Esc and receive mouse drags).
final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// Full-screen interactive view used in place mode: drag the body to move the HUD, drag
// the corner handle to scale the text, Enter to confirm, Esc to cancel.
final class PlacementView: NSView {
    var center = NSPoint.zero
    var fontSize: CGFloat = 30 { didSet { hud.font = tunnelVisionFont(ofSize: fontSize) } }
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?

    private let hud = GlyphHUDView(frame: .zero) // used purely as a drawing helper

    init(frame: NSRect, goal: String, timeText: String?) {
        super.init(frame: frame)
        hud.goalText = goal
        hud.timeText = timeText
        hud.fillColor = NSColor(calibratedRed: 0.36, green: 1.0, blue: 0.20, alpha: 1.0)
        hud.glowColor = NSColor(calibratedRed: 0.20, green: 1.0, blue: 0.15, alpha: 0.95)
        hud.glowRadius = 16
        hud.visibility = 1
        hud.font = tunnelVisionFont(ofSize: fontSize)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    private func boxRect() -> NSRect {
        let s = hudContentSize(goal: hud.goalText, timeText: hud.timeText, fontSize: fontSize)
        return NSRect(x: center.x - s.width / 2, y: center.y - s.height / 2, width: s.width, height: s.height)
            .insetBy(dx: -18, dy: -18)
    }
    private func handleRect() -> NSRect {
        let b = boxRect()
        let size: CGFloat = 18
        return NSRect(x: b.maxX - size / 2, y: b.minY - size / 2, width: size, height: size)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Dim the rest of the screen so the preview reads clearly.
        NSColor.black.withAlphaComponent(0.20).setFill()
        bounds.fill()

        if let path = hud.combinedPath() {
            hud.drawGlyphs(path, centeredAt: center, in: ctx)
        }

        // Dashed selection border + a round resize handle at the bottom-right corner.
        let border = NSBezierPath(roundedRect: boxRect(), xRadius: 10, yRadius: 10)
        border.lineWidth = 1.5
        border.setLineDash([6, 4], count: 2, phase: 0)
        NSColor.white.withAlphaComponent(0.7).setStroke()
        border.stroke()

        NSColor.white.withAlphaComponent(0.95).setFill()
        NSBezierPath(ovalIn: handleRect()).fill()

        // Instructions pinned near the bottom of the screen.
        let hint = "Drag to move   ·   drag the handle to resize   ·   Enter to confirm   ·   Esc to cancel"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9),
        ]
        let hintSize = (hint as NSString).size(withAttributes: attrs)
        (hint as NSString).draw(at: NSPoint(x: bounds.midX - hintSize.width / 2, y: 44), withAttributes: attrs)
    }

    private enum DragMode { case idle, moving, resizing }
    private var dragMode: DragMode = .idle
    private var dragStart = NSPoint.zero
    private var startCenter = NSPoint.zero
    private var startFont: CGFloat = 30
    private var startDistance: CGFloat = 1

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        dragStart = p
        startCenter = center
        startFont = fontSize
        if handleRect().insetBy(dx: -10, dy: -10).contains(p) {
            dragMode = .resizing
            startDistance = max(1, hypot(p.x - center.x, p.y - center.y))
        } else {
            dragMode = .moving
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch dragMode {
        case .moving:
            center = NSPoint(x: startCenter.x + (p.x - dragStart.x), y: startCenter.y + (p.y - dragStart.y))
        case .resizing:
            // Scale the text by how far the cursor is from the (fixed) center vs. the start.
            let distance = hypot(p.x - center.x, p.y - center.y)
            fontSize = min(400, max(12, startFont * distance / startDistance))
        case .idle:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) { dragMode = .idle }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onConfirm?() // Return / keypad Enter
        case 53: onCancel?() // Escape
        default: super.keyDown(with: event)
        }
    }
}

final class PlacementController {
    let window: KeyableWindow
    let view: PlacementView
    let outputPath: String
    let deeplink: String?

    init(goal: String, timeText: String?, outputPath: String, deeplink: String?) {
        self.outputPath = outputPath
        self.deeplink = deeplink

        let screen = NSScreen.main ?? NSScreen.screens.first!
        let frame = screen.frame

        window = KeyableWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .screenSaver
        window.ignoresMouseEvents = false // interactive, unlike the live HUD
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false

        view = PlacementView(frame: NSRect(origin: .zero, size: frame.size), goal: goal, timeText: timeText)
        view.autoresizingMask = [.width, .height]
        if let existing = loadPlacementFile(outputPath) {
            view.fontSize = existing.fontSize
            view.center = NSPoint(x: existing.centerX, y: existing.centerY)
        } else {
            view.fontSize = 30
            view.center = NSPoint(x: frame.midX, y: frame.maxY - 122) // the default HUD spot
        }
        view.onConfirm = { [weak self] in self?.confirm() }
        view.onCancel = { exit(0) }
        window.contentView = view

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
    }

    private func confirm() {
        let json = "{\"centerX\":\(view.center.x),\"centerY\":\(view.center.y),\"fontSize\":\(view.fontSize)}"
        try? json.write(toFile: outputPath, atomically: true, encoding: .utf8)
        // Reopen the Raycast form so the user can submit with their chosen placement.
        if let deeplink, let url = URL(string: deeplink) {
            NSWorkspace.shared.open(url)
        }
        exit(0)
    }
}

final class OverlayController {
    let window: NSWindow
    let hudView: GlyphHUDView
    let goal: String
    let endDate: Date?
    let inactivityThreshold: TimeInterval
    let nearMargin: CGFloat
    let effects: [TimeUpEffect]
    let context: EffectContext

    private let baseTextColor = NSColor(calibratedRed: 0.36, green: 1.0, blue: 0.20, alpha: 1.0)
    private let baseGlowColor = NSColor(calibratedRed: 0.20, green: 1.0, blue: 0.15, alpha: 0.95)

    private var lastMouse: NSPoint = NSEvent.mouseLocation
    private var lastMoveTime: Date = Date()
    private var currentAlpha: CGFloat = 1.0
    private var pulse: CGFloat = 0
    private var timeUpProgress: CGFloat = 0 // raw 0 → 1 ramp after the timer ends
    private var tickTimer: Timer?

    init(goal: String, durationSeconds: Double, inactivityThreshold: TimeInterval, nearMargin: CGFloat, effectIds: [String], placement: Placement?) {
        self.goal = goal
        self.endDate = durationSeconds > 0 ? Date().addingTimeInterval(durationSeconds) : nil
        self.inactivityThreshold = inactivityThreshold
        self.nearMargin = nearMargin
        self.effects = effectIds.compactMap { makeEffect(id: $0) }

        let screen = NSScreen.main ?? NSScreen.screens.first!
        let visible = screen.frame

        let baseFrame: NSRect
        let baseFontSize: CGFloat
        if let placement {
            // Use the user-chosen center + text size from placement mode, framing the
            // window around the text (with margin for glow and the fade hot zone).
            baseFontSize = placement.fontSize
            let content = hudContentSize(
                goal: goal,
                timeText: durationSeconds > 0 ? "00:00" : nil,
                fontSize: placement.fontSize
            )
            let w = content.width + 80
            let h = content.height + 80
            baseFrame = NSRect(x: placement.centerX - w / 2, y: placement.centerY - h / 2, width: w, height: h)
        } else {
            // Default: a fixed strip pinned near the top-center of the screen.
            let width = min(960, visible.width * 0.82)
            let height: CGFloat = 132 // tall enough for the time line stacked above the goal
            let originX = visible.midX - width / 2
            let originY = visible.maxY - height - 56 // 56pt below the top edge
            baseFrame = NSRect(x: originX, y: originY, width: width, height: height)
            baseFontSize = 30
        }

        // Pre-compute the zoom target: a goal font size large enough that the wider of
        // the two stacked lines fills ~92% of the screen width. The time line renders
        // at GlyphHUDView.timeScale, so measure it at that scale to compare fairly.
        let referenceSize: CGFloat = 100
        let goalWidth = (goal as NSString)
            .size(withAttributes: [.font: tunnelVisionFont(ofSize: referenceSize), .kern: 1.5]).width
        let timeWidth =
            durationSeconds > 0
            ? ("TIME'S UP" as NSString).size(withAttributes: [
                .font: tunnelVisionFont(ofSize: referenceSize * GlyphHUDView.timeScale), .kern: 1.5,
            ]).width
            : 0
        let widest = max(goalWidth, timeWidth)
        let zoomFontSize = widest > 0 ? referenceSize * (visible.width * 0.92 / widest) : referenceSize

        self.context = EffectContext(
            screen: visible,
            baseFrame: baseFrame,
            baseFontSize: baseFontSize,
            fullScreenFrame: visible,
            zoomFontSize: zoomFontSize
        )

        window = NSWindow(contentRect: baseFrame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .screenSaver // floats above ordinary app windows
        window.ignoresMouseEvents = true // fully click-through
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.isReleasedWhenClosed = false

        hudView = GlyphHUDView(frame: NSRect(origin: .zero, size: baseFrame.size))
        hudView.autoresizingMask = [.width, .height] // stays centered when an effect resizes the window
        window.contentView = hudView

        render()
        window.orderFrontRegardless()

        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func timeString() -> String? {
        guard let end = endDate else { return nil }
        let remaining = max(0, end.timeIntervalSinceNow)
        let total = Int(remaining.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func isTimeUp() -> Bool {
        timeString() == "00:00"
    }

    private func timeLine() -> String? {
        guard let t = timeString() else { return nil }
        return t == "00:00" ? "TIME'S UP" : t
    }

    // Compose the base look with every active effect, scaled by the eased ramp.
    private func currentStyle() -> RenderStyle {
        var style = RenderStyle(
            textColor: baseTextColor,
            glowColor: baseGlowColor,
            fontSize: context.baseFontSize,
            frame: context.baseFrame
        )
        if timeUpProgress > 0.001 {
            let p = easeInOut(timeUpProgress)
            for effect in effects {
                effect.apply(to: &style, progress: p, context: context)
            }
        }
        return style
    }

    private func render() {
        let style = currentStyle()

        if !style.frame.equalTo(window.frame) {
            window.setFrame(style.frame, display: true)
        }

        hudView.goalText = goal
        hudView.timeText = timeLine()
        hudView.font = tunnelVisionFont(ofSize: style.fontSize)
        hudView.fillColor = style.textColor
        hudView.glowColor = style.glowColor
        // Scale the glow with the font so it stays proportional when zoomed.
        hudView.glowRadius = (14 + 6 * sin(pulse)) * (style.fontSize / context.baseFontSize)
        hudView.visibility = currentAlpha
        hudView.needsDisplay = true
    }

    private func tick() {
        pulse += 0.12

        // Advance (or hold) the time's-up ramp.
        let timeUp = isTimeUp()
        timeUpProgress += ((timeUp ? 1 : 0) - timeUpProgress) * 0.06

        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - lastMouse.x
        let dy = mouse.y - lastMouse.y
        if (dx * dx + dy * dy) > 1.0 {
            lastMoveTime = Date()
        }
        lastMouse = mouse

        // "Reach for it" detection always keys off the original top-of-screen
        // spot, even if an effect has since moved/grown the window.
        let hotZone = context.baseFrame.insetBy(dx: -nearMargin, dy: -nearMargin)
        let near = hotZone.contains(mouse)
        let active = Date().timeIntervalSince(lastMoveTime) <= inactivityThreshold

        // Fade the filled text away only while the cursor is near AND being actively
        // moved. The window itself stays opaque so the dashed ghost outline (drawn by
        // GlyphHUDView as `visibility` drops) remains visible underneath the cursor.
        // Once time's up, the HUD stays fully solid and refuses to fade — you can't
        // dismiss it by reaching for it anymore.
        let alphaTarget: CGFloat = (!timeUp && near && active) ? 0.0 : 1.0
        currentAlpha += (alphaTarget - currentAlpha) * 0.25 // smooth easing

        render()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // no Dock icon, never steals focus

// Held for the whole program lifetime — otherwise the controller (and its repeating
// timer / event handlers) would deallocate before app.run() and the HUD would freeze.
var retainedController: AnyObject?

if isPlaceMode {
    let outputPath = arguments.count > 2 ? arguments[2] : ""
    let placeGoal = arguments.count > 3 ? arguments[3] : "Focus"
    let sampleSeconds = arguments.count > 4 ? (Double(arguments[4]) ?? 0) : 0
    let deeplink = arguments.count > 5 ? arguments[5] : nil
    let total = Int(sampleSeconds.rounded())
    let sampleTime = total > 0 ? String(format: "%02d:%02d", total / 60, total % 60) : nil
    retainedController = PlacementController(
        goal: placeGoal.isEmpty ? "Focus" : placeGoal,
        timeText: sampleTime,
        outputPath: outputPath,
        deeplink: deeplink
    )
} else {
    retainedController = OverlayController(
        goal: goalText,
        durationSeconds: durationSeconds,
        inactivityThreshold: inactivityThreshold,
        nearMargin: nearMargin,
        effectIds: effectIds,
        placement: placement
    )
}
_ = retainedController
app.run()
