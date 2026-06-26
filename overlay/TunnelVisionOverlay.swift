import AppKit

// Tunnel Vision overlay helper.
//
// Draws a borderless, always-on-top, click-through HUD near the top-center of the
// main screen showing the current goal and an optional countdown. The HUD fades to
// transparent when the cursor is near it AND actively moving, and snaps back to full
// opacity once the cursor leaves the area or goes still for longer than the
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

final class OverlayController {
    let window: NSWindow
    let label: NSTextField
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

    init(goal: String, durationSeconds: Double, inactivityThreshold: TimeInterval, nearMargin: CGFloat, effectIds: [String]) {
        self.goal = goal
        self.endDate = durationSeconds > 0 ? Date().addingTimeInterval(durationSeconds) : nil
        self.inactivityThreshold = inactivityThreshold
        self.nearMargin = nearMargin
        self.effects = effectIds.compactMap { makeEffect(id: $0) }

        let screen = NSScreen.main ?? NSScreen.screens.first!
        let visible = screen.frame
        let width = min(960, visible.width * 0.82)
        let height: CGFloat = 96
        let originX = visible.midX - width / 2
        let originY = visible.maxY - height - 56 // 56pt below the top edge
        let baseFrame = NSRect(x: originX, y: originY, width: width, height: height)

        let baseFontSize: CGFloat = 30

        // Pre-compute the zoom target: a font size large enough that the final
        // "time's up" string fills ~92% of the screen width on a single line.
        let zoomString = durationSeconds > 0 ? "\(goal)   ·   TIME'S UP" : goal
        let referenceSize: CGFloat = 100
        let referenceFont = NSFont.monospacedSystemFont(ofSize: referenceSize, weight: .heavy)
        let measured = (zoomString as NSString)
            .size(withAttributes: [.font: referenceFont, .kern: 1.5]).width
        let zoomFontSize = measured > 0 ? referenceSize * (visible.width * 0.92 / measured) : referenceSize

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

        let container = NSView(frame: NSRect(origin: .zero, size: baseFrame.size))
        label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isEditable = false
        label.isSelectable = false
        label.drawsBackground = false
        label.isBezeled = false
        label.alignment = .center
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),
        ])
        window.contentView = container

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

    private func displayString() -> String {
        guard let t = timeString() else { return goal }
        return (t == "00:00") ? "\(goal)   ·   TIME'S UP" : "\(goal)   ·   \(t)"
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

        let glow = NSShadow()
        glow.shadowColor = style.glowColor
        // Scale the glow with the font so it stays proportional when zoomed.
        glow.shadowBlurRadius = (14 + 6 * sin(pulse)) * (style.fontSize / context.baseFontSize)
        glow.shadowOffset = .zero

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: style.textColor,
            .font: NSFont.monospacedSystemFont(ofSize: style.fontSize, weight: .heavy),
            .shadow: glow,
            .strokeColor: NSColor.black.withAlphaComponent(0.85),
            .strokeWidth: -3.0, // negative = fill + outline (legibility on any backdrop)
            .paragraphStyle: paragraph,
            .kern: 1.5,
        ]
        label.attributedStringValue = NSAttributedString(string: displayString(), attributes: attrs)
    }

    private func tick() {
        pulse += 0.12

        // Advance (or hold) the time's-up ramp.
        let target: CGFloat = isTimeUp() ? 1 : 0
        timeUpProgress += (target - timeUpProgress) * 0.06

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

        // Fade away only while the cursor is near AND being actively moved.
        let alphaTarget: CGFloat = (near && active) ? 0.0 : 1.0
        currentAlpha += (alphaTarget - currentAlpha) * 0.25 // smooth easing
        window.alphaValue = currentAlpha

        render()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // no Dock icon, never steals focus
let controller = OverlayController(
    goal: goalText,
    durationSeconds: durationSeconds,
    inactivityThreshold: inactivityThreshold,
    nearMargin: nearMargin,
    effectIds: effectIds
)
_ = controller
app.run()
