#!/usr/bin/env swift
import AppKit
import Foundation

struct PanelRenderer {
    let width: CGFloat = 1280
    let height: CGFloat = 720

    func render(output: URL, fixture: String, expected: String, baseline: String, guided: String) throws {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(width),
            pixelsHigh: Int(height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw NSError(domain: "GroqTalk.STTLab", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create panel bitmap"])
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }

        NSColor(calibratedRed: 0.063, green: 0.078, blue: 0.094, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()

        let shell = NSBezierPath(
            roundedRect: rectFromTop(x: 56, y: 34, width: 1168, height: 652),
            xRadius: 24,
            yRadius: 24
        )
        NSColor(calibratedRed: 0.082, green: 0.106, blue: 0.125, alpha: 1).setFill()
        shell.fill()
        NSColor(calibratedRed: 0.161, green: 0.196, blue: 0.227, alpha: 1).setStroke()
        shell.lineWidth = 2
        shell.stroke()

        draw("GroqTalk Local STT Lab", x: 90, y: 76, width: 1100, size: 36, weight: .heavy, color: .white)
        draw("Fixture: \(fixture)", x: 90, y: 122, width: 1100, size: 20, weight: .semibold, color: color(0.61, 0.66, 0.71))

        drawBlock(label: "Expected Fixture", text: expected, x: 90, y: 180, textWidth: 1040, labelColor: color(0.96, 0.83, 0.43), textSize: 25)

        let waveBox = NSBezierPath(
            roundedRect: rectFromTop(x: 86, y: 300, width: 1108, height: 130),
            xRadius: 16,
            yRadius: 16
        )
        NSColor(calibratedRed: 0.051, green: 0.067, blue: 0.082, alpha: 1).setFill()
        waveBox.fill()
        NSColor(calibratedRed: 0.149, green: 0.196, blue: 0.227, alpha: 1).setStroke()
        waveBox.lineWidth = 2
        waveBox.stroke()
        draw("Audio waveform from the original recording", x: 90, y: 448, width: 1100, size: 17, weight: .regular, color: color(0.56, 0.64, 0.71))

        drawBlock(label: "Baseline", text: baseline, x: 90, y: 498, textWidth: 1040, labelColor: color(0.70, 0.72, 0.77), textSize: 22)
        drawBlock(label: "Local AI", text: guided, x: 90, y: 606, textWidth: 1040, labelColor: color(0.37, 0.91, 0.71), textSize: 27)

        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "GroqTalk.STTLab", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not encode panel PNG"])
        }
        try png.write(to: output)
    }

    private func drawBlock(label: String, text: String, x: CGFloat, y: CGFloat, textWidth: CGFloat, labelColor: NSColor, textSize: CGFloat) {
        draw(label, x: x, y: y, width: textWidth, size: textSize, weight: .bold, color: labelColor)
        draw(text, x: x, y: y + textSize + 13, width: textWidth, size: textSize, weight: .semibold, color: color(0.96, 0.97, 0.98))
    }

    private func draw(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 4

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
        let attributed = NSAttributedString(string: compact(text), attributes: attrs)
        attributed.draw(with: rectFromTop(x: x, y: y, width: width, height: 112), options: [.usesLineFragmentOrigin, .usesFontLeading])
    }

    private func rectFromTop(x: CGFloat, y: CGFloat, width: CGFloat, height rectHeight: CGFloat) -> NSRect {
        NSRect(x: x, y: self.height - y - rectHeight, width: width, height: rectHeight)
    }

    private func compact(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
        NSColor(calibratedRed: red, green: green, blue: blue, alpha: 1)
    }
}

let args = CommandLine.arguments
guard args.count == 6 else {
    fputs("Usage: render-stt-panel.swift <output.png> <fixture> <expected> <baseline> <local-ai>\n", stderr)
    exit(2)
}

do {
    try PanelRenderer().render(
        output: URL(fileURLWithPath: args[1]),
        fixture: args[2],
        expected: args[3],
        baseline: args[4],
        guided: args[5]
    )
} catch {
    fputs("render-stt-panel failed: \(error)\n", stderr)
    exit(1)
}
