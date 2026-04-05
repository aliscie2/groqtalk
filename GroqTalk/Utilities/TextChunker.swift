import Foundation

enum TextChunker {
    static let maxChunk = 150

    static func split(_ text: String) -> [String] {
        guard text.count > maxChunk else { return [text] }

        var chunks: [String] = []
        var remaining = text

        while !remaining.isEmpty {
            if remaining.count <= maxChunk {
                chunks.append(remaining)
                break
            }

            let window = String(remaining.prefix(maxChunk))

            // Try splitting at sentence end
            if let range = window.range(of: "[.!?]\\s", options: .regularExpression, range: window.startIndex..<window.endIndex) {
                let end = range.upperBound
                chunks.append(String(remaining[remaining.startIndex..<end]).trimmingCharacters(in: .whitespaces))
                remaining = String(remaining[end...])
            }
            // Try newline
            else if let idx = window.lastIndex(of: "\n") {
                let end = window.index(after: idx)
                chunks.append(String(remaining[remaining.startIndex..<end]).trimmingCharacters(in: .whitespacesAndNewlines))
                remaining = String(remaining[end...])
            }
            // Try comma or space
            else if let idx = window.lastIndex(of: ",") ?? window.lastIndex(of: " ") {
                let end = window.index(after: idx)
                chunks.append(String(remaining[remaining.startIndex..<end]).trimmingCharacters(in: .whitespaces))
                remaining = String(remaining[end...])
            }
            // Force split
            else {
                chunks.append(window)
                remaining = String(remaining.dropFirst(maxChunk))
            }
        }

        return chunks.filter { !$0.isEmpty }
    }
}
