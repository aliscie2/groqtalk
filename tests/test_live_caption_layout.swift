import AppKit

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

@main
struct LiveCaptionLayoutTests {
    static func main() {
        let layout = LiveCaptionPanelLayout.calculate(
            textSize: NSSize(width: 520, height: 110),
            textMaxHeight: 42
        )

        expect(layout.panelSize.width <= 360, "Expected caption panel to stay tooltip-sized")
        expect(layout.panelSize.height <= 92, "Expected caption panel to stay compact")
        expect(
            layout.textFrame.maxY <= layout.panelSize.height - 12,
            "Expected caption text to stay inside the panel top padding"
        )
        expect(
            layout.textFrame.minY >= 12,
            "Expected caption text to stay inside the panel bottom padding"
        )

        let short = LiveCaptionPanelLayout.calculate(
            textSize: NSSize(width: 90, height: 18),
            textMaxHeight: 42
        )
        expect(short.panelSize.width == 230, "Expected short captions to use the minimum compact width")
        expect(short.panelSize.height == 48, "Expected short captions to use the minimum compact height")

        print("LiveCaptionLayout tests passed")
    }
}
