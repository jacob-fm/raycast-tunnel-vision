import AppKit

// Tunnel Vision overlay helper.
//
// Draws a borderless, always-on-top, click-through HUD near the top-center of the
// main screen showing the current goal and an optional countdown. The HUD fades to
// transparent when the cursor is near it AND actively moving, and snaps back to full
// opacity once the cursor leaves the area or goes still for longer than the
// inactivity threshold.
//
// Usage:
//   tunnelvision-overlay "<goal>" <durationSeconds> [inactivityThreshold] [nearMargin]
//
//   durationSeconds      0 = no timer (goal only)
//   inactivityThreshold  seconds of stillness before the HUD reappears (default 0.5)
//   nearMargin           points of padding around the HUD that count as "near" (default 90)

let arguments = CommandLine.arguments
let goalText = arguments.count > 1 ? arguments[1] : "Focus"
let durationSeconds = arguments.count > 2 ? (Double(arguments[2]) ?? 0) : 0
let inactivityThreshold = arguments.count > 3 ? (Double(arguments[3]) ?? 0.5) : 0.5
let nearMargin: CGFloat = arguments.count > 4 ? CGFloat(Double(arguments[4]) ?? 90) : 90

final class OverlayController {
    let window: NSWindow
    let label: NSTextField
    let goal: String
    let endDate: Date?
    let inactivityThreshold: TimeInterval
    let nearMargin: CGFloat

    private var lastMouse: NSPoint = NSEvent.mouseLocation
    private var lastMoveTime: Date = Date()
    private var currentAlpha: CGFloat = 1.0
    private var pulse: CGFloat = 0
    private var tickTimer: Timer?

    init(goal: String, durationSeconds: Double, inactivityThreshold: TimeInterval, nearMargin: CGFloat) {
        self.goal = goal
        self.endDate = durationSeconds > 0 ? Date().addingTimeInterval(durationSeconds) : nil
        self.inactivityThreshold = inactivityThreshold
        self.nearMargin = nearMargin

        let screen = NSScreen.main ?? NSScreen.screens.first!
        let visible = screen.frame
        let width = min(960, visible.width * 0.82)
        let height: CGFloat = 96
        let originX = visible.midX - width / 2
        let originY = visible.maxY - height - 56 // 56pt below the top edge
        let frame = NSRect(x: originX, y: originY, width: width, height: height)

        window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .screenSaver // floats above ordinary app windows
        window.ignoresMouseEvents = true // fully click-through
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.isReleasedWhenClosed = false

        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
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

    private func render() {
        let neon = NSColor(calibratedRed: 0.36, green: 1.0, blue: 0.20, alpha: 1.0)

        let glow = NSShadow()
        glow.shadowColor = NSColor(calibratedRed: 0.20, green: 1.0, blue: 0.15, alpha: 0.95)
        glow.shadowBlurRadius = 14 + 6 * sin(pulse) // gentle "shiny" pulse
        glow.shadowOffset = .zero

        let display: String
        if let t = timeString() {
            display = (t == "00:00") ? "\(goal)   ·   TIME'S UP" : "\(goal)   ·   \(t)"
        } else {
            display = goal
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: neon,
            .font: NSFont.monospacedSystemFont(ofSize: 30, weight: .heavy),
            .shadow: glow,
            .strokeColor: NSColor.black.withAlphaComponent(0.85),
            .strokeWidth: -3.0, // negative = fill + outline (legibility on any backdrop)
            .paragraphStyle: paragraph,
            .kern: 1.5,
        ]
        label.attributedStringValue = NSAttributedString(string: display, attributes: attrs)
    }

    private func tick() {
        pulse += 0.12

        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - lastMouse.x
        let dy = mouse.y - lastMouse.y
        if (dx * dx + dy * dy) > 1.0 {
            lastMoveTime = Date()
        }
        lastMouse = mouse

        let hotZone = window.frame.insetBy(dx: -nearMargin, dy: -nearMargin)
        let near = hotZone.contains(mouse)
        let active = Date().timeIntervalSince(lastMoveTime) <= inactivityThreshold

        // Fade away only while the cursor is near AND being actively moved.
        let target: CGFloat = (near && active) ? 0.0 : 1.0
        currentAlpha += (target - currentAlpha) * 0.25 // smooth easing
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
    nearMargin: nearMargin
)
_ = controller
app.run()
