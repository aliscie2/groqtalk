import Foundation

enum TextChunker {
    static let maxChunk = 150

    static func split(_ text: String) -> [String] {
        let blocks = extractBlocks(text)
        var chunks: [String] = []
        for block in blocks {
            switch block.kind {
            case .table:
                chunks.append(contentsOf: tableToRowChunks(block.text))
            case .header, .listItem, .codeBlock:
                chunks.append(block.text)
            case .prose:
                chunks.append(contentsOf: splitProse(block.text))
            }
        }
        return chunks.filter { !$0.isEmpty }
    }

    // MARK: - Block types

    private enum BlockKind { case prose, table, header, listItem, codeBlock }

    private struct Block {
        let text: String
        let kind: BlockKind
    }

    // MARK: - Block extraction

    private static func extractBlocks(_ text: String) -> [Block] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [Block] = []
        var prose: [String] = []
        var table: [String] = []
        var codeBlock: [String] = []
        var inCode = false

        func flushProse() {
            let joined = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(Block(text: joined, kind: .prose)) }
            prose.removeAll()
        }
        func flushTable() {
            let joined = table.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(Block(text: joined, kind: .table)) }
            table.removeAll()
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Code fences
            if trimmed.hasPrefix("```") {
                if inCode {
                    codeBlock.append(line)
                    let joined = codeBlock.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !joined.isEmpty { blocks.append(Block(text: joined, kind: .codeBlock)) }
                    codeBlock.removeAll()
                    inCode = false
                } else {
                    if !prose.isEmpty { flushProse() }
                    if !table.isEmpty { flushTable() }
                    codeBlock.append(line)
                    inCode = true
                }
                continue
            }
            if inCode { codeBlock.append(line); continue }

            // Table lines
            if isTableLine(line) {
                if !prose.isEmpty { flushProse() }
                table.append(line)
                continue
            }
            if !table.isEmpty { flushTable() }

            // Headers
            if trimmed.hasPrefix("#") && trimmed.contains(" ") {
                if !prose.isEmpty { flushProse() }
                blocks.append(Block(text: trimmed, kind: .header))
                continue
            }

            // List items (- item, * item, 1. item, 2. item)
            if isListItem(trimmed) {
                if !prose.isEmpty { flushProse() }
                blocks.append(Block(text: trimmed, kind: .listItem))
                continue
            }

            // Blank line = paragraph break
            if trimmed.isEmpty && !prose.isEmpty {
                flushProse()
                continue
            }

            prose.append(line)
        }

        if inCode && !codeBlock.isEmpty {
            let joined = codeBlock.joined(separator: "\n")
            blocks.append(Block(text: joined, kind: .codeBlock))
        }
        if !prose.isEmpty { flushProse() }
        if !table.isEmpty { flushTable() }

        return blocks
    }

    private static func isListItem(_ line: String) -> Bool {
        if line.hasPrefix("- ") || line.hasPrefix("* ") { return true }
        let pattern = try? NSRegularExpression(pattern: "^\\d{1,3}[\\.\\)] ")
        if let p = pattern, p.firstMatch(in: line, range: NSRange(location: 0, length: min(8, line.count))) != nil {
            return true
        }
        return false
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

    // MARK: - Table → row chunks

    private static func tableToRowChunks(_ tableText: String) -> [String] {
        let lines = tableText.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        if lines.first?.unicodeScalars.contains(where: { $0.value >= 0x2500 && $0.value <= 0x257F }) == true {
            return parseBoxTable(lines)
        }
        if lines.first?.hasPrefix("|") == true {
            return parsePipeTable(lines)
        }
        return [tableText]
    }

    private static func parsePipeTable(_ lines: [String]) -> [String] {
        var headers: [String] = []
        var dataRows: [[String]] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "| "))
            if trimmed.allSatisfy({ $0 == "-" || $0 == ":" || $0 == "|" || $0 == " " }) { continue }
            let cells = line.split(separator: "|").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if headers.isEmpty { headers = cells } else { dataRows.append(cells) }
        }
        return rowsToChunks(headers: headers, rows: dataRows)
    }

    private static func parseBoxTable(_ lines: [String]) -> [String] {
        var headers: [String] = []
        var dataRows: [[String]] = []
        for line in lines {
            let hasData = line.contains { c in c.isLetter || c.isNumber }
            guard hasData else { continue }
            let cleaned = line.replacingOccurrences(of: "│", with: "|")
            let cells = cleaned.split(separator: "|").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if headers.isEmpty { headers = cells } else { dataRows.append(cells) }
        }
        return rowsToChunks(headers: headers, rows: dataRows)
    }

    private static func rowsToChunks(headers: [String], rows: [[String]]) -> [String] {
        guard !headers.isEmpty, !rows.isEmpty else { return [] }
        var chunks: [String] = []

        if rows.count > 1 {
            chunks.append(headers.joined(separator: " \u{2502} "))
        }

        for row in rows {
            if rows.count == 1 {
                let kvPairs = headers.enumerated().compactMap { (i, h) in
                    let v = i < row.count ? row[i] : ""
                    return v.isEmpty ? nil : "\(h): \(v)"
                }
                chunks.append(kvPairs.joined(separator: "\n"))
            } else {
                let values = row.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                chunks.append(values.joined(separator: " \u{2192} "))
            }
        }
        return chunks
    }

    // MARK: - Prose splitting

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
