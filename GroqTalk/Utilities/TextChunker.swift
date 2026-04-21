import Foundation
import NaturalLanguage

enum TextChunker {
    /// Target char range for a single TTS chunk. Short sentences are merged
    /// upward while `len(buf) < mergeUpTo`; any single sentence longer than
    /// `maxChunk` is soft-split at clause boundaries (see softSplit).
    static let mergeUpTo = 120
    static let maxChunk  = 250

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

    // MARK: - Prose splitting (NLTagger-based)

    /// Split prose into breath-group chunks using Apple's sentence
    /// segmenter. NLTagger's `.sentence` unit already handles abbreviations
    /// (Mr., Dr., U.S., e.g., decimals, version numbers) so we get far
    /// fewer mid-sentence splits than the old regex-on-punctuation approach.
    ///
    /// Pipeline:
    ///   1. Sentence-split via NLTagger
    ///   2. Merge each sentence with the next if the running buffer is still
    ///      under `mergeUpTo` and merged length stays under `maxChunk`
    ///   3. If a single sentence is longer than `maxChunk`, soft-split it at
    ///      clause boundaries that don't fall inside an atomic span (URLs,
    ///      quoted text, paired brackets, versions, decimals — found via
    ///      NSDataDetector + regex)
    private static func splitProse(_ text: String) -> [String] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        // Collapse internal newlines to spaces BEFORE sentence segmentation.
        // NLTagger treats `\n` as a hard sentence boundary, which produces
        // bad splits when text has been word-wrapped (e.g. the user copies
        // a paragraph that was visually wrapped to 80 columns — every wrap
        // would become a chunk boundary). Preserve paragraph breaks as
        // spaces; real paragraph boundaries already split at the block
        // extraction layer via the blank-line rule.
        let flat = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        let sentences = sentenceSegment(flat)
        let atoms = atomicSpans(flat)

        var chunks: [String] = []
        var buf = ""
        for s in sentences {
            let sentence = s.trimmingCharacters(in: .whitespaces)
            guard !sentence.isEmpty else { continue }
            if buf.isEmpty {
                buf = sentence
            } else if buf.count < mergeUpTo && buf.count + 1 + sentence.count <= maxChunk {
                buf += " " + sentence
            } else {
                chunks.append(buf)
                buf = sentence
            }
            if buf.count > maxChunk {
                chunks.append(contentsOf: softSplit(buf, atoms: atoms))
                buf = ""
            }
        }
        if !buf.isEmpty { chunks.append(buf) }
        return chunks
    }

    private static func sentenceSegment(_ text: String) -> [String] {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        var out: [String] = []
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .sentence, scheme: .lexicalClass
        ) { _, range in
            let s = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { out.append(s) }
            return true
        }
        return out.isEmpty ? [text] : out
    }

    /// Build the "never split inside" mask. Returns UTF-16 ranges because
    /// NSDataDetector and NSRegularExpression both speak UTF-16 offsets.
    private static func atomicSpans(_ text: String) -> [NSRange] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var ranges: [NSRange] = []

        // URLs, emails, phone numbers
        let detector = try? NSDataDetector(types:
            NSTextCheckingResult.CheckingType.link.rawValue
            | NSTextCheckingResult.CheckingType.phoneNumber.rawValue)
        detector?.enumerateMatches(in: text, range: full) { m, _, _ in
            if let r = m?.range { ranges.append(r) }
        }

        // Regex-based atoms: version numbers, decimals, thousands separators,
        // markdown links, inline code, file paths with common extensions.
        let patterns = [
            #"\d+(?:\.\d+){2,}"#,                                // 1.2.3, IPs
            #"\d+\.\d+"#,                                        // 3.14
            #"\d{1,3}(?:,\d{3})+"#,                              // 1,000,000
            #"`[^`\n]+`"#,                                       // `inline code`
            #"!?\[[^\]]+\]\([^)]+\)"#,                           // [text](url) and images
            #"\b[\w./-]+\.(?:md|swift|py|js|ts|json|yaml|toml|sh|txt|rs|go|html|css)\b"#,
            #"\*\*[^*\n]{1,80}\*\*"#,                            // **bold** — never split mid-emphasis
            #"(?<!\*)\*(?!\s)[^*\n]{1,80}\*(?!\*)"#,             // *italic* (avoid matching **)
        ]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p) else { continue }
            re.enumerateMatches(in: text, range: full) { m, _, _ in
                if let r = m?.range { ranges.append(r) }
            }
        }

        // Paired delimiters. Scan linearly; depth-aware for (), [], {}.
        addPairRanges(text, open: "\"", close: "\"", ranges: &ranges)
        addPairRanges(text, open: "“", close: "”", ranges: &ranges)
        addPairRanges(text, open: "‘", close: "’", ranges: &ranges)
        addNestedPairs(text, openChar: "(", closeChar: ")", ranges: &ranges)
        addNestedPairs(text, openChar: "[", closeChar: "]", ranges: &ranges)

        return ranges
    }

    private static func addPairRanges(_ text: String, open: String, close: String, ranges: inout [NSRange]) {
        let ns = text as NSString
        var searchFrom = 0
        while searchFrom < ns.length {
            let openR = ns.range(of: open, range: NSRange(location: searchFrom, length: ns.length - searchFrom))
            if openR.location == NSNotFound { break }
            let afterOpen = openR.location + openR.length
            let closeR = ns.range(of: close, range: NSRange(location: afterOpen, length: ns.length - afterOpen))
            if closeR.location == NSNotFound { break }
            ranges.append(NSRange(location: openR.location, length: closeR.location + closeR.length - openR.location))
            searchFrom = closeR.location + closeR.length
        }
    }

    private static func addNestedPairs(_ text: String, openChar: Character, closeChar: Character, ranges: inout [NSRange]) {
        var stack: [String.Index] = []
        for idx in text.indices {
            let c = text[idx]
            if c == openChar { stack.append(idx) }
            else if c == closeChar, let start = stack.popLast() {
                let endPlus = text.index(after: idx)
                let utf16Start = start.utf16Offset(in: text)
                let utf16End = endPlus.utf16Offset(in: text)
                ranges.append(NSRange(location: utf16Start, length: utf16End - utf16Start))
            }
        }
    }

    /// True when `utf16Position` falls strictly inside any atomic span.
    private static func insideAtom(_ pos: Int, atoms: [NSRange]) -> Bool {
        for r in atoms where pos > r.location && pos < r.location + r.length {
            return true
        }
        return false
    }

    /// Split a single over-long sentence at clause boundaries. Preference
    /// order: `;`/`:` → `",`/`")`/`"]` → ` — `/` -- ` → ` and/but/because…` →
    /// last space before 230. Never splits inside an atomic span.
    private static func softSplit(_ sentence: String, atoms: [NSRange]) -> [String] {
        if sentence.count <= maxChunk { return [sentence] }
        var out: [String] = []
        var remaining = sentence

        while remaining.count > maxChunk {
            let window = String(remaining.prefix(maxChunk))
            let ns = window as NSString
            let hardStart = 60  // don't emit chunks shorter than this

            // Candidate split patterns in quality order.
            let candidates: [String] = [
                #"[;:]\s"#,
                #"["')\]]\s"#,
                #"\s—\s|\s--\s"#,
                #"\s(?:and|but|because|which|so|then|however)\s"#,
            ]
            var splitUtf16: Int? = nil
            for p in candidates {
                guard let re = try? NSRegularExpression(pattern: p) else { continue }
                // Walk all matches, pick the last one that's >= hardStart and not inside an atom.
                let matches = re.matches(in: window, range: NSRange(location: 0, length: ns.length))
                for m in matches.reversed() {
                    let end = m.range.location + m.range.length
                    if end >= hardStart && !insideAtom(end, atoms: atoms) {
                        splitUtf16 = end; break
                    }
                }
                if splitUtf16 != nil { break }
            }
            if splitUtf16 == nil {
                // Fallback: last space before end, not inside atom.
                let lastSpace = ns.range(of: " ", options: .backwards)
                if lastSpace.location != NSNotFound && lastSpace.location >= hardStart &&
                   !insideAtom(lastSpace.location + 1, atoms: atoms) {
                    splitUtf16 = lastSpace.location + 1
                } else {
                    // Give up — emit the whole window. Acceptable: no natural break.
                    splitUtf16 = ns.length
                }
            }
            let head = String(ns.substring(to: splitUtf16!)).trimmingCharacters(in: .whitespaces)
            let tail = String(ns.substring(from: splitUtf16!)) + String(remaining.dropFirst(window.count))
            if !head.isEmpty { out.append(head) }
            remaining = tail.trimmingCharacters(in: .whitespaces)
        }
        if !remaining.isEmpty { out.append(remaining) }
        return out
    }
}
