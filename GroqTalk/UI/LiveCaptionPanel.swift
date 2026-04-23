import AppKit

final class LiveCaptionPanel {
    static let shared = LiveCaptionPanel()

    private var panel: NSPanel?
    private var label: NSTextField?

    private init() {}

    func show() {
        DispatchQueue.main.async { [weak self] in self?.showOnMain() }
    }

    func update(text: String) {
        DispatchQueue.main.async { [weak self] in self?.updateOnMain(text: text) }
    }

    func hide() {
        DispatchQueue.main.async { [weak self] in self?.hideOnMain() }
    }

    private func showOnMain() {
        if panel == nil { buildPanel() }
        guard let panel else { return }
        panel.alphaValue = 0
        updatePosition()
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            panel.animator().alphaValue = 1
        }
    }

    private func updateOnMain(text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if panel == nil { buildPanel() }
        guard let panel, let label else { return }
        label.stringValue = text
        let maxWidth: CGFloat = 520
        let size = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: maxWidth, height: .greatestFiniteMagnitude))
            ?? NSSize(width: maxWidth, height: 64)
        let width = min(maxWidth, max(260, size.width + 36))
        let height = min(180, max(64, size.height + 28))
        panel.setContentSize(NSSize(width: width, height: height))
        label.frame = NSRect(x: 18, y: 14, width: width - 36, height: height - 28)
        updatePosition()
        if !panel.isVisible { showOnMain() }
    }

    private func hideOnMain() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    private func buildPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 88),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 0.88)
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let content = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        content.wantsLayer = true
        content.layer?.cornerRadius = 18
        content.layer?.masksToBounds = true

        let label = NSTextField(wrappingLabelWithString: "")
        label.textColor = NSColor(calibratedWhite: 0.95, alpha: 1)
        label.font = NSFont(name: "Iowan Old Style", size: 19) ?? NSFont.systemFont(ofSize: 19, weight: .medium)
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 4
        label.frame = NSRect(x: 18, y: 14, width: 304, height: 60)
        content.addSubview(label)

        panel.contentView = content
        self.panel = panel
        self.label = label
    }

    private func updatePosition() {
        guard let panel, let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.midX - panel.frame.width / 2,
            y: visible.minY + 80
        )
        panel.setFrameOrigin(origin)
    }
}
