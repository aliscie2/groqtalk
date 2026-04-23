import AppKit
import Carbon
import CoreGraphics

struct RecentTextPickerItem {
    let text: String
    let title: String
    let subtitle: String
}

final class RecentTextPickerPanel {
    static let shared = RecentTextPickerPanel()

    var onSelect: ((String) -> Void)?
    var onDismiss: (() -> Void)?

    var isVisible: Bool { panel?.isVisible == true }

    private let panelWidth: CGFloat = 440
    private let rowHeight: CGFloat = 62
    private let rowSpacing: CGFloat = 8
    private let maxVisibleItems = 5
    private let topPadding: CGFloat = 16
    private let headerHeight: CGFloat = 22
    private let headerBottomGap: CGFloat = 10
    private let dividerHeight: CGFloat = 1
    private let dividerBottomGap: CGFloat = 12
    private let rowsBottomGap: CGFloat = 12
    private let hintHeight: CGFloat = 16
    private let bottomPadding: CGFloat = 16

    private var panel: NSPanel?
    private var effectView: NSVisualEffectView?
    private var stackView: NSStackView?
    private var titleLabel: NSTextField?
    private var shortcutLabel: NSTextField?
    private var dividerBox: NSBox?
    private var hintLabel: NSTextField?
    private var items: [RecentTextPickerItem] = []
    private var rowViews: [RecentTextPickerRowView] = []
    private var selectedIndex = 0
    private var mouseMonitor: Any?

    private init() {}

    func show(items: [RecentTextPickerItem]) {
        DispatchQueue.main.async { [weak self] in
            self?.showOnMain(items: Array(items.prefix(self?.maxVisibleItems ?? 5)))
        }
    }

    func hide() {
        DispatchQueue.main.async { [weak self] in
            self?.hideOnMain()
        }
    }

    @discardableResult
    func handleKey(type: CGEventType, keyCode: CGKeyCode) -> Bool {
        guard isVisible, type == .keyDown else { return false }

        if let directIndex = Self.directSelectionIndex(for: keyCode), items.indices.contains(directIndex) {
            selectedIndex = directIndex
            refreshSelection()
            insertSelected()
            return true
        }

        switch Int(keyCode) {
        case Int(kVK_UpArrow):
            moveSelection(delta: -1)
            return true
        case Int(kVK_DownArrow):
            moveSelection(delta: 1)
            return true
        case Int(kVK_Return), Int(kVK_ANSI_KeypadEnter):
            insertSelected()
            return true
        case Int(kVK_Escape):
            hide()
            return true
        default:
            return false
        }
    }

    private func showOnMain(items: [RecentTextPickerItem]) {
        guard !items.isEmpty else { return }
        if panel == nil { buildPanel() }
        guard let panel, let stackView else { return }

        self.items = items
        selectedIndex = 0
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews.removeAll()

        for (index, item) in items.enumerated() {
            let row = RecentTextPickerRowView(index: index + 1, item: item)
            row.onClick = { [weak self] in
                self?.selectedIndex = index
                self?.refreshSelection()
                self?.insertSelected()
            }
            row.translatesAutoresizingMaskIntoConstraints = false
            row.heightAnchor.constraint(equalToConstant: rowHeight).isActive = true
            rowViews.append(row)
            stackView.addArrangedSubview(row)
        }

        refreshSelection()
        resizePanel()
        installOutsideClickMonitor()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    private func hideOnMain() {
        guard let panel, panel.isVisible else { return }
        removeOutsideClickMonitor()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            panel.orderOut(nil)
            self?.onDismiss?()
        })
    }

    private func moveSelection(delta: Int) {
        guard !items.isEmpty else { return }
        let next = selectedIndex + delta
        if next < 0 {
            selectedIndex = items.count - 1
        } else if next >= items.count {
            selectedIndex = 0
        } else {
            selectedIndex = next
        }
        refreshSelection()
    }

    private func insertSelected() {
        guard items.indices.contains(selectedIndex) else {
            hide()
            return
        }
        let text = items[selectedIndex].text
        hide()
        onSelect?(text)
    }

    private func refreshSelection() {
        for (index, row) in rowViews.enumerated() {
            row.isHighlighted = index == selectedIndex
        }
        hintLabel?.stringValue = "1-\(items.count) insert  •  ↑ ↓ navigate  •  Esc close"
    }

    private func resizePanel() {
        guard let panel else { return }
        let rowsHeight = CGFloat(rowViews.count) * rowHeight
        let gapsHeight = CGFloat(max(0, rowViews.count - 1)) * rowSpacing
        let height = topPadding + headerHeight + headerBottomGap + dividerHeight + dividerBottomGap
            + rowsHeight + gapsHeight + rowsBottomGap + hintHeight + bottomPadding
        panel.setContentSize(NSSize(width: panelWidth, height: height))
        layoutContents()
        updatePosition()
    }

    private func updatePosition() {
        guard let panel else { return }
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let bottomOffset = max(72.0, min(124.0, visible.height * 0.11))
        let origin = NSPoint(
            x: visible.midX - panel.frame.width / 2,
            y: visible.minY + bottomOffset
        )
        panel.setFrameOrigin(origin)
    }

    private func buildPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 300),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.animationBehavior = .utilityWindow

        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: 300))
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 18
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 1
        effect.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        effect.autoresizingMask = [.width, .height]

        let titleLabel = NSTextField(labelWithString: "Recent Texts")
        titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = NSColor.labelColor
        effect.addSubview(titleLabel)

        let shortcutLabel = NSTextField(labelWithString: "Fn+Ctrl")
        shortcutLabel.alignment = .center
        shortcutLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
        shortcutLabel.textColor = NSColor.controlAccentColor
        shortcutLabel.wantsLayer = true
        shortcutLabel.layer?.cornerRadius = 8
        shortcutLabel.layer?.masksToBounds = true
        shortcutLabel.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
        effect.addSubview(shortcutLabel)

        let divider = NSBox(frame: .zero)
        divider.boxType = .separator
        effect.addSubview(divider)

        let stackView = NSStackView(frame: .zero)
        stackView.orientation = .vertical
        stackView.spacing = rowSpacing
        stackView.alignment = .leading
        stackView.distribution = .fill
        effect.addSubview(stackView)

        let hintLabel = NSTextField(labelWithString: "")
        hintLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        hintLabel.textColor = NSColor.secondaryLabelColor
        hintLabel.alignment = .center
        effect.addSubview(hintLabel)

        panel.contentView = effect
        self.panel = panel
        self.effectView = effect
        self.stackView = stackView
        self.titleLabel = titleLabel
        self.shortcutLabel = shortcutLabel
        self.dividerBox = divider
        self.hintLabel = hintLabel
        layoutContents()
    }

    private func layoutContents() {
        guard let panel, let effectView, let titleLabel, let shortcutLabel,
              let dividerBox, let stackView, let hintLabel else { return }

        let width = panel.contentRect(forFrameRect: panel.frame).width
        let height = panel.contentRect(forFrameRect: panel.frame).height
        effectView.frame = NSRect(x: 0, y: 0, width: width, height: height)

        titleLabel.frame = NSRect(x: 18, y: height - topPadding - headerHeight + 2, width: 180, height: 18)
        shortcutLabel.frame = NSRect(x: width - 76, y: height - topPadding - headerHeight, width: 58, height: 22)

        let dividerY = height - topPadding - headerHeight - headerBottomGap
        dividerBox.frame = NSRect(x: 18, y: dividerY, width: width - 36, height: dividerHeight)

        let rowsHeight = CGFloat(rowViews.count) * rowHeight
        let gapsHeight = CGFloat(max(0, rowViews.count - 1)) * rowSpacing
        let totalRowsHeight = rowsHeight + gapsHeight
        let stackY = bottomPadding + hintHeight + rowsBottomGap
        stackView.frame = NSRect(x: 16, y: stackY, width: width - 32, height: totalRowsHeight)
        hintLabel.frame = NSRect(x: 16, y: bottomPadding, width: width - 32, height: hintHeight)
    }

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, let panel, panel.isVisible else { return }
            if !panel.frame.contains(NSEvent.mouseLocation) {
                self.hide()
            }
        }
    }

    private func removeOutsideClickMonitor() {
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
    }

    private static func directSelectionIndex(for keyCode: CGKeyCode) -> Int? {
        switch Int(keyCode) {
        case Int(kVK_ANSI_1), Int(kVK_ANSI_Keypad1): return 0
        case Int(kVK_ANSI_2), Int(kVK_ANSI_Keypad2): return 1
        case Int(kVK_ANSI_3), Int(kVK_ANSI_Keypad3): return 2
        case Int(kVK_ANSI_4), Int(kVK_ANSI_Keypad4): return 3
        case Int(kVK_ANSI_5), Int(kVK_ANSI_Keypad5): return 4
        default: return nil
        }
    }
}

private final class RecentTextPickerRowView: NSView {
    var onClick: (() -> Void)?

    var isHighlighted = false {
        didSet { updateAppearance() }
    }

    private let badgeLabel = NSTextField(labelWithString: "")
    private let titleLabel: NSTextField
    private let subtitleLabel = NSTextField(labelWithString: "")

    init(index: Int, item: RecentTextPickerItem) {
        titleLabel = NSTextField(wrappingLabelWithString: item.title)
        super.init(frame: NSRect(x: 0, y: 0, width: 408, height: 62))
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true

        badgeLabel.stringValue = "\(index)"
        badgeLabel.alignment = .center
        badgeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        badgeLabel.frame = NSRect(x: 12, y: 18, width: 28, height: 28)
        badgeLabel.wantsLayer = true
        badgeLabel.layer?.cornerRadius = 8
        badgeLabel.layer?.masksToBounds = true
        addSubview(badgeLabel)

        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = NSColor.labelColor
        titleLabel.maximumNumberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.frame = NSRect(x: 52, y: 24, width: 334, height: 28)
        addSubview(titleLabel)

        subtitleLabel.stringValue = item.subtitle
        subtitleLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        subtitleLabel.textColor = NSColor.secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.frame = NSRect(x: 52, y: 10, width: 334, height: 14)
        addSubview(subtitleLabel)

        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    private func updateAppearance() {
        layer?.backgroundColor = isHighlighted
            ? NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor
            : NSColor.windowBackgroundColor.withAlphaComponent(0.62).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = (isHighlighted
            ? NSColor.controlAccentColor.withAlphaComponent(0.34)
            : NSColor.separatorColor.withAlphaComponent(0.18)).cgColor

        badgeLabel.textColor = isHighlighted ? NSColor.white : NSColor.controlAccentColor
        badgeLabel.layer?.backgroundColor = (isHighlighted
            ? NSColor.controlAccentColor
            : NSColor.controlAccentColor.withAlphaComponent(0.1)).cgColor
    }
}
