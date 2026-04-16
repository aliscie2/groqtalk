import Foundation

enum TextChunker {
    static let maxChunk = 150

    static func split(_ text: String) -> [String] {
        let blocks = extractBlocks(text)
        var chunks: [String] = []
        for block in blocks {
            if block.isTable {
                chunks.append(block.text)
            } else {
                chunks.append(contentsOf: splitProse(block.text))
            }
        }
        return chunks.filter { !$0.isEmpty }
    }

    private struct Block {
        let text: String
        let isTable: Bool
    }

    private static func extractBlocks(_ text: String) -> [Block] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [Block] = []
        var prose: [String] = []
        var table: [String] = []

        func flushProse() {
            let joined = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(Block(text: joined, isTable: false)) }
            prose.removeAll()
        }
        func flushTable() {
            let joined = table.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(Block(text: joined, isTable: true)) }
            table.removeAll()
        }

        for line in lines {
            if isTableLine(line) {
                if !prose.isEmpty { flushProse() }
                table.append(line)
            } else {
                if !table.isEmpty { flushTable() }
                prose.append(line)
            }
        }
        if !prose.isEmpty { flushProse() }
        if !table.isEmpty { flushTable() }

        return blocks
    }

    private static func isTableLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return false }
        for c in trimmed.unicodeScalars {
            if c.value >= 0x2500 && c.value <= 0x257F { return true }
            if c.value >= 0x2550 && c.value <= 0x256C { return true }
        }
        if trimmed.hasPrefix("|") && trimmed.hasSuffix("|") { return true }
        if trimmed.hasPrefix("|") && trimmed.contains("---") { return true }
        return false
    }

    private static func splitProse(_ text: String) -> [String] {
        guard text.count > maxChunk else { return [text] }

        var chunks: [String] = []
        var remaining = text

        while !remaining.isEmpty {
            if remaining.count <= maxChunk {
                chunks.append(remaining)
                break
            }

            let window = String(remaining.prefix(maxChunk))

            if let range = window.range(of: "[.!?]\\s", options: .regularExpression, range: window.startIndex..<window.endIndex) {
                let end = range.upperBound
                chunks.append(String(remaining[remaining.startIndex..<end]).trimmingCharacters(in: .whitespaces))
                remaining = String(remaining[end...])
            }
            else if let idx = window.lastIndex(of: "\n") {
                let end = window.index(after: idx)
                chunks.append(String(remaining[remaining.startIndex..<end]).trimmingCharacters(in: .whitespacesAndNewlines))
                remaining = String(remaining[end...])
            }
            else if let idx = window.lastIndex(of: ",") ?? window.lastIndex(of: " ") {
                let end = window.index(after: idx)
                chunks.append(String(remaining[remaining.startIndex..<end]).trimmingCharacters(in: .whitespaces))
                remaining = String(remaining[end...])
            }
            else {
                chunks.append(window)
                remaining = String(remaining.dropFirst(maxChunk))
            }
        }

        return chunks
    }
}
