import AppKit
import QuartzCore

/// Floating pill next to the cursor while the user is dictating.
/// Contents: a red "REC" dot + 5 vertical bars that dance with the mic
/// level in a VU-meter-like chase (the dot pulses at 1.5 Hz; the bars
/// shift a level-history buffer so the rightmost bar shows "now" and
/// earlier bars show recent past — looks alive even in silence).
///
/// Lives in a borderless, click-through NSPanel at .floating level.
/// Follows the cursor at 60 Hz via NSEvent.mouseLocation.
/// Respects macOS Reduce Motion — dot becomes static and bars freeze at
/// a subtle resting height.
final class RecordingIndicator {
    static let shared = RecordingIndicator()

    // Geometry
    private let dotSize: CGFloat   = 12
    private let barCount: Int      = 5
    private let barWidth: CGFloat  = 3
    private let barGap: CGFloat    = 2
    private let barMaxH: CGFloat   = 18
    private let barMinH: CGFloat   = 3
    private let padding: CGFloat   = 6
    private let panelH: CGFloat    = 28
    private let cursorOffset = NSPoint(x: 18, y: -26)   // up-and-right of cursor tip

    // State
    private var panel: NSPanel?
    private var dotLayer: CALayer?
    private var barLayers: [CALayer] = []
    private var followTimer: Timer?
    /// History of recent RMS values, oldest → newest. Each bar reads one slot.
    private var levelHistory: [Float] = []

    private init() {}

    // MARK: - Public API

    func show() {
        DispatchQueue.main.async { [weak self] in self?.showOnMain() }
    }

    func hide() {
        DispatchQueue.main.async { [weak self] in self?.hideOnMain() }
    }

    /// Feed a mic-level sample (usually RMS in [0, 1]). Safe to call from
    /// any thread — marshals to main. Noop when the panel is hidden.
    func setLevel(_ level: Float) {
        DispatchQueue.main.async { [weak self] in self?.pushLevel(level) }
    }

    // MARK: - Show / Hide

    private func showOnMain() {
        if panel == nil { build() }
        guard let panel else { return }
        levelHistory = Array(repeating: 0, count: barCount)
        updateBarHeights()
        updatePosition()
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
            self?.dotLayer?.removeAllAnimations()
        })
    }

    // MARK: - Build

    private func build() {
        let panelW = padding + dotSize + padding
            + CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barGap
            + padding

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelW, height: panelH),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        p.level = .floating
        p.isOpaque = false
        p.hasShadow = false
        p.backgroundColor = .clear
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .transient]

        let view = NSView(frame: NSRect(x: 0, y: 0, width: panelW, height: panelH))
        view.wantsLayer = true

        // Soft translucent pill backdrop so the dot + bars read on any background.
        let bg = CALayer()
        bg.frame = view.bounds
        bg.cornerRadius = panelH / 2
        bg.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 0.55)
        bg.shadowColor = .black
        bg.shadowOpacity = 0.35
        bg.shadowRadius = 4
        bg.shadowOffset = .zero
        view.layer?.addSublayer(bg)

        // Dot
        let dot = CALayer()
        let dotX = padding
        let dotY = (panelH - dotSize) / 2
        dot.frame = CGRect(x: dotX, y: dotY, width: dotSize, height: dotSize)
        dot.cornerRadius = dotSize / 2
        dot.backgroundColor = NSColor.systemRed.cgColor
        dot.shadowColor = NSColor.systemRed.cgColor
        dot.shadowOpacity = 0.65
        dot.shadowRadius = 5
        dot.shadowOffset = .zero
        view.layer?.addSublayer(dot)
        dotLayer = dot

        // Bars
        let barsStartX = dotX + dotSize + padding
        barLayers.removeAll(keepingCapacity: true)
        for i in 0..<barCount {
            let b = CALayer()
            let x = barsStartX + CGFloat(i) * (barWidth + barGap)
            b.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            b.frame = CGRect(x: x, y: (panelH - barMinH) / 2, width: barWidth, height: barMinH)
            b.cornerRadius = barWidth / 2
            // Gentle gradient from warm amber (newest) to dimmer red (oldest)
            // purely via alpha — one color keeps the look coherent.
            let alpha = 0.55 + 0.45 * Double(i) / Double(max(1, barCount - 1))
            b.backgroundColor = NSColor(red: 0.91, green: 0.70, blue: 0.41, alpha: alpha).cgColor
            view.layer?.addSublayer(b)
            barLayers.append(b)
        }

        p.contentView = view
        panel = p
    }

    // MARK: - Pulse + level-driven bars

    private func startPulse() {
        guard let dotLayer else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            dotLayer.removeAllAnimations()
            return
        }
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.85
        scale.toValue = 1.15
        scale.duration = 0.7
        scale.autoreverses = true
        scale.repeatCount = .infinity
        scale.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dotLayer.add(scale, forKey: "pulse")
    }

    /// Push a new level into the history ring. Rightmost bar is "now";
    /// bars to the left show progressively older samples. Gives an EMG /
    /// VU meter feel as voice energy rolls across the bars over time.
    private func pushLevel(_ level: Float) {
        guard panel?.isVisible == true else { return }
        // Trim + lightly boost the mic level so quiet speech still shows
        // visible motion. Cap at 1.0. Normal conversational RMS lands around
        // 0.05-0.20 — 5x gain brings that to 0.25-1.0.
        let boosted = min(1.0, max(0.0, level) * 5.0)
        if levelHistory.count < barCount {
            levelHistory.append(boosted)
        } else {
            levelHistory.removeFirst()
            levelHistory.append(boosted)
        }
        updateBarHeights()
    }

    private func updateBarHeights() {
        guard barLayers.count == barCount else { return }
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        CATransaction.begin()
        CATransaction.setAnimationDuration(reduced ? 0 : 0.08)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        for (i, bar) in barLayers.enumerated() {
            let level = i < levelHistory.count ? levelHistory[i] : 0
            let h = reduced
                ? barMinH + (barMaxH - barMinH) * 0.25
                : barMinH + CGFloat(level) * (barMaxH - barMinH)
            var frame = bar.frame
            frame.size.height = h
            frame.origin.y = (panelH - h) / 2
            bar.frame = frame
        }
        CATransaction.commit()
    }

    // MARK: - Cursor follow

    private func startFollowing() {
        stopFollowing()
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
            y: mouse.y + cursorOffset.y - panelH
        )
        panel.setFrameOrigin(origin)
    }
}
