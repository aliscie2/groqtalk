import AppKit
import QuartzCore

/// Minimal, click-through caption for direct Fn dictation.
final class MinimalDictationOverlay {
    static let shared = MinimalDictationOverlay()

    private let panelSize = NSSize(width: 560, height: 34)
    private let dotSize: CGFloat = 7
    private var panel: NSPanel?
    private var label: NSTextField?
    private var dotLayer: CALayer?
    private var glowLayer: CALayer?
    private var lastText = ""

    private init() {}

    func show() {
        DispatchQueue.main.async { [weak self] in self?.showOnMain() }
    }

    func update(text: String) {
        DispatchQueue.main.async { [weak self] in self?.setText(text) }
    }

    func update(snapshot: LiveCaptionSnapshot) {
        update(text: [snapshot.committedText, snapshot.tentativeText]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " "))
    }

    func setLevel(_ level: Float) {
        DispatchQueue.main.async { [weak self] in self?.setLevelOnMain(level) }
    }

    func hide() {
        DispatchQueue.main.async { [weak self] in self?.hideOnMain() }
    }

    private func showOnMain() {
        if panel == nil { build() }
        lastText = ""
        setText("Listening")
        setLevelOnMain(0)
        position()
        panel?.alphaValue = 0
        panel?.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.10
            panel?.animator().alphaValue = 1
        }
    }

    private func hideOnMain() {
        lastText = ""
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.10
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil) })
    }

    private func build() {
        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .floating
        p.isOpaque = false
        p.hasShadow = false
        p.backgroundColor = .clear
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .transient]

        let view = NSView(frame: NSRect(origin: .zero, size: panelSize))
        view.wantsLayer = true
        view.layer?.cornerRadius = panelSize.height / 2
        view.layer?.backgroundColor = CGColor(red: 0.015, green: 0.015, blue: 0.018, alpha: 0.90)
        view.layer?.borderWidth = 1
        view.layer?.borderColor = CGColor(red: 1, green: 1, blue: 1, alpha: 0.16)

        let dotFrame = CGRect(x: 14, y: (panelSize.height - dotSize) / 2, width: dotSize, height: dotSize)
        let glow = CALayer()
        glow.frame = dotFrame
        glow.cornerRadius = dotSize / 2
        glow.backgroundColor = NSColor.systemRed.withAlphaComponent(0.18).cgColor
        view.layer?.addSublayer(glow)
        glowLayer = glow

        let dot = CALayer()
        dot.frame = dotFrame
        dot.cornerRadius = dotSize / 2
        dot.backgroundColor = NSColor.systemRed.withAlphaComponent(0.92).cgColor
        view.layer?.addSublayer(dot)
        dotLayer = dot

        let text = NSTextField(labelWithString: "Listening")
        text.frame = NSRect(x: 32, y: 7, width: panelSize.width - 46, height: 20)
        text.font = .systemFont(ofSize: 14, weight: .medium)
        text.textColor = NSColor(calibratedWhite: 1.0, alpha: 0.98)
        text.lineBreakMode = .byTruncatingHead
        text.maximumNumberOfLines = 1
        text.drawsBackground = false
        text.wantsLayer = true
        view.addSubview(text)
        label = text

        p.contentView = view
        panel = p
    }

    private func setText(_ text: String) {
        let compact = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let corrected = TranscriptPostProcessor.clean(compact)
        guard !corrected.isEmpty, corrected != lastText else { return }
        lastText = corrected
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.12
            label?.layer?.add(fade, forKey: "captionText")
        }
        label?.stringValue = corrected
    }

    private func setLevelOnMain(_ level: Float) {
        guard panel?.isVisible == true, let dotLayer, let glowLayer else { return }
        let amount = sqrt(min(1, max(0, CGFloat(level)) * 8))
        CATransaction.begin()
        CATransaction.setAnimationDuration(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.07)
        dotLayer.transform = CATransform3DMakeScale(0.9 + amount, 0.9 + amount, 1)
        dotLayer.opacity = Float(0.62 + amount * 0.38)
        glowLayer.transform = CATransform3DMakeScale(1.3 + amount * 3, 1.3 + amount * 3, 1)
        glowLayer.opacity = Float(0.10 + amount * 0.30)
        CATransaction.commit()
    }

    private func position() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let visibleFrame = NSScreen.screens
            .first(where: { $0.frame.contains(mouse) })?
            .visibleFrame ?? NSScreen.main?.visibleFrame
        guard let visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(
            x: visibleFrame.midX - panelSize.width / 2,
            y: visibleFrame.minY + min(96, max(54, visibleFrame.height * 0.10))
        ))
    }
}
