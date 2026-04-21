import AppKit
import QuartzCore

/// Tiny pulsing red dot that appears next to the cursor while the user is
/// dictating (Fn or Cmd+Shift+Space). A borderless, click-through NSPanel
/// at .floating level follows the mouse at 60 Hz via NSEvent.mouseLocation.
///
/// Minimal by design — a 14 px red dot with an opacity+scale pulse. No
/// mic-level bars, no text, no settings. Respects Reduce Motion (static
/// dot when the system setting is on).
final class RecordingIndicator {
    static let shared = RecordingIndicator()

    private var panel: NSPanel?
    private var layer: CALayer?
    private var followTimer: Timer?
    private let dotSize: CGFloat = 14
    private let panelSize: CGFloat = 28     // outer panel; extra space lets pulse scale without clipping
    private let cursorOffset = NSPoint(x: 18, y: -26)  // up-and-right of cursor tip

    private init() {}

    // MARK: - Public API

    func show() {
        DispatchQueue.main.async { [weak self] in self?.showOnMain() }
    }

    func hide() {
        DispatchQueue.main.async { [weak self] in self?.hideOnMain() }
    }

    // MARK: - Impl

    private func showOnMain() {
        if panel == nil { build() }
        guard let panel else { return }
        updatePosition()   // place at current cursor before fade-in
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }
        startPulse()
        startFollowing()
    }

    private func hideOnMain() {
        stopFollowing()
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel?.orderOut(nil)
            self?.layer?.removeAllAnimations()
        })
    }

    private func build() {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelSize, height: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        p.level = .floating
        p.isOpaque = false
        p.hasShadow = false
        p.backgroundColor = .clear
        p.ignoresMouseEvents = true    // critical — never steal clicks
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .transient]

        let view = NSView(frame: NSRect(x: 0, y: 0, width: panelSize, height: panelSize))
        view.wantsLayer = true

        // Single red dot centered in the panel. The PULSE animation scales
        // the dot between 0.85x and 1.15x via a CAKeyframeAnimation loop.
        let dotLayer = CALayer()
        let d = dotSize
        dotLayer.frame = CGRect(x: (panelSize - d) / 2, y: (panelSize - d) / 2, width: d, height: d)
        dotLayer.cornerRadius = d / 2
        dotLayer.backgroundColor = NSColor.systemRed.cgColor
        // Subtle warm glow so the dot reads against any desktop background.
        dotLayer.shadowColor = NSColor.systemRed.cgColor
        dotLayer.shadowOpacity = 0.65
        dotLayer.shadowRadius = 6
        dotLayer.shadowOffset = .zero
        view.layer?.addSublayer(dotLayer)

        p.contentView = view
        self.panel = p
        self.layer = dotLayer
    }

    private func startPulse() {
        guard let layer else { return }
        // Respect Reduce Motion — static dot, no animation.
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            layer.removeAllAnimations()
            return
        }
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.85
        scale.toValue = 1.15
        scale.duration = 0.7
        scale.autoreverses = true
        scale.repeatCount = .infinity
        scale.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(scale, forKey: "pulse")
    }

    private func startFollowing() {
        stopFollowing()
        // 60 Hz follow keeps up with fast cursor movement without noticeable CPU.
        let t = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.updatePosition()
        }
        RunLoop.main.add(t, forMode: .common)
        followTimer = t
    }

    private func stopFollowing() {
        followTimer?.invalidate()
        followTimer = nil
    }

    private func updatePosition() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let origin = NSPoint(
            x: mouse.x + cursorOffset.x,
            y: mouse.y + cursorOffset.y - panelSize
        )
        panel.setFrameOrigin(origin)
    }
}
