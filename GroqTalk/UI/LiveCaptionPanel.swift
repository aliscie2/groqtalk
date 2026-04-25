import AppKit

struct LiveCaptionPanelLayout: Equatable {
    let panelSize: NSSize
    let textFrame: NSRect

    static func calculate(
        textSize: NSSize,
        textMaxHeight: CGFloat,
        minPanelWidth: CGFloat = 230,
        maxPanelWidth: CGFloat = 360,
        minPanelHeight: CGFloat = 48,
        maxPanelHeight: CGFloat = 92,
        horizontalPadding: CGFloat = 16,
        verticalPadding: CGFloat = 12
    ) -> LiveCaptionPanelLayout {
        let textHeight = min(max(22, ceil(textSize.height)), textMaxHeight)
        let width = min(
            maxPanelWidth,
            max(minPanelWidth, ceil(textSize.width) + (horizontalPadding * 2))
        )
        let height = min(
            maxPanelHeight,
            max(minPanelHeight, textHeight + (verticalPadding * 2))
        )
        let availableTextHeight = max(0, height - (verticalPadding * 2))

        return LiveCaptionPanelLayout(
            panelSize: NSSize(width: width, height: height),
            textFrame: NSRect(
                x: horizontalPadding,
                y: verticalPadding,
                width: width - (horizontalPadding * 2),
                height: min(textHeight, availableTextHeight)
            )
        )
    }
}

final class LiveCaptionPanel {
    static let shared = LiveCaptionPanel()

    private let minPanelWidth: CGFloat = 230
    private let maxPanelWidth: CGFloat = 360
    private let minPanelHeight: CGFloat = 48
    private let maxPanelHeight: CGFloat = 92
    private let horizontalPadding: CGFloat = 16
    private let verticalPadding: CGFloat = 12
    private let maxDisplayWords = 13

    private var panel: NSPanel?
    private var textLabel: NSTextField?
    private var currentText = ""

    private init() {}

    func show() {
        DispatchQueue.main.async { [weak self] in self?.showOnMain() }
    }

    func update(snapshot: LiveCaptionSnapshot) {
        DispatchQueue.main.async { [weak self] in self?.updateOnMain(snapshot: snapshot) }
    }

    func update(text: String) {
        update(snapshot: LiveCaptionSnapshot(committedText: "", tentativeText: text))
    }

    func hide() {
        DispatchQueue.main.async { [weak self] in self?.hideOnMain() }
    }

    private func showOnMain() {
        if panel == nil { buildPanel() }
        guard let panel, !currentText.isEmpty else { return }
        guard !panel.isVisible else { return }
        panel.alphaValue = 0
        updatePosition()
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    private func updateOnMain(snapshot: LiveCaptionSnapshot) {
        let text = displayText(from: snapshot)
        guard !text.isEmpty else { return }
        if panel == nil { buildPanel() }
        guard let panel, let textLabel else { return }

        currentText = text
        textLabel.attributedStringValue = styledText(text)
        resizePanel()
        if !panel.isVisible { showOnMain() }
    }

    private func hideOnMain() {
        currentText = ""
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    private func buildPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: minPanelWidth, height: minPanelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 0.90)
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let content = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        content.wantsLayer = true
        content.layer?.cornerRadius = 16
        content.layer?.masksToBounds = true
        content.layer?.backgroundColor = NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.14, alpha: 0.88).cgColor
        content.layer?.borderWidth = 1
        content.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.06).cgColor

        let textLabel = NSTextField(wrappingLabelWithString: "")
        textLabel.textColor = NSColor(calibratedWhite: 0.96, alpha: 1)
        textLabel.font = NSFont(name: "Iowan Old Style", size: 16) ?? NSFont.systemFont(ofSize: 16, weight: .medium)
        textLabel.lineBreakMode = .byWordWrapping
        textLabel.maximumNumberOfLines = 2
        textLabel.frame = NSRect(
            x: horizontalPadding,
            y: verticalPadding,
            width: minPanelWidth - (horizontalPadding * 2),
            height: minPanelHeight - (verticalPadding * 2)
        )
        content.addSubview(textLabel)

        panel.contentView = content
        self.panel = panel
        self.textLabel = textLabel
    }

    private func updatePosition() {
        guard let panel, let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.midX - panel.frame.width / 2,
            y: visible.minY + 72
        )
        panel.setFrameOrigin(origin)
    }

    private func resizePanel() {
        guard let panel, let textLabel else { return }

        let availableWidth = maxPanelWidth - (horizontalPadding * 2)
        let textRect = textLabel.attributedStringValue.boundingRect(
            with: NSSize(width: availableWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let font = attributedFont(from: textLabel)
            ?? NSFont(name: "Iowan Old Style", size: 16)
            ?? NSFont.systemFont(ofSize: 16, weight: .medium)
        let textMaxHeight = lineHeight(for: font, multiple: 1.06) * 2

        let layout = LiveCaptionPanelLayout.calculate(
            textSize: textRect.size,
            textMaxHeight: textMaxHeight,
            minPanelWidth: minPanelWidth,
            maxPanelWidth: maxPanelWidth,
            minPanelHeight: minPanelHeight,
            maxPanelHeight: maxPanelHeight,
            horizontalPadding: horizontalPadding,
            verticalPadding: verticalPadding
        )

        panel.setContentSize(layout.panelSize)
        textLabel.frame = layout.textFrame
        updatePosition()
    }

    private func displayText(from snapshot: LiveCaptionSnapshot) -> String {
        let pieces = [snapshot.committedText, snapshot.tentativeText]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !pieces.isEmpty else { return "" }

        let joined = pieces.joined(separator: " ")
            .replacingOccurrences(of: #"\s+([,.;:!?])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return suffixWords(from: joined, limit: maxDisplayWords)
    }

    private func suffixWords(from text: String, limit: Int) -> String {
        let words = text.split(separator: " ")
        guard words.count > limit else { return text }
        return "…" + words.suffix(limit).joined(separator: " ")
    }

    private func attributedFont(from label: NSTextField) -> NSFont? {
        let text = label.attributedStringValue
        guard text.length > 0 else { return label.font }
        return text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont ?? label.font
    }

    private func lineHeight(for font: NSFont, multiple: CGFloat) -> CGFloat {
        ceil((font.ascender - font.descender + font.leading) * multiple)
    }

    private func styledText(_ text: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineHeightMultiple = 1.06
        return NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont(name: "Iowan Old Style", size: 16) ?? NSFont.systemFont(ofSize: 16, weight: .medium),
                .foregroundColor: NSColor(calibratedWhite: 0.96, alpha: 1),
                .paragraphStyle: paragraph,
            ]
        )
    }
}
