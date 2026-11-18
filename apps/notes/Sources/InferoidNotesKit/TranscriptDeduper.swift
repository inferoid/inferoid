import Foundation

/// Removes words that the microphone captured from the call speakers.
///
/// This deliberately only edits `Me` lines. Call audio is the source of truth for
/// the other side, so `Them` or named call-audio lines are never removed or changed.
enum TranscriptDeduper {
    private struct Token {
        let original: String
        let normalized: String
    }

    private struct AlignmentCell {
        var score = 0
        var matches = 0
    }

    /// Returns the transcript with overlapping echo spans removed from `Me` lines.
    /// Matching is local, word-based, and tolerant of one-character ASR differences.
    static func deduplicated(_ lines: [Line], window: TimeInterval = 15) -> [Line] {
        var result = lines
        for index in lines.indices where lines[index].speaker == "Me" {
            let meTokens = tokens(lines[index].text)
            guard !meTokens.isEmpty else { continue }

            var removed = Set<Int>()
            for callLine in lines where callLine.speaker != "Me" && withinWindow(lines[index], callLine, window: window) {
                let callTokens = tokens(callLine.text)
                removed.formUnion(matchedMeIndices(meTokens, callTokens))
            }

            let remaining = meTokens.enumerated().compactMap { removed.contains($0.offset) ? nil : $0.element.original }
            result[index].text = remaining.joined(separator: " ")
        }
        return result.filter { $0.speaker != "Me" || !tokens($0.text).isEmpty }
    }

    private static func withinWindow(_ a: Line, _ b: Line, window: TimeInterval) -> Bool {
        let gap = max(0, max(a.start, b.start) - min(a.end, b.end))
        return gap <= window
    }

    private static func tokens(_ text: String) -> [Token] {
        text.split { !$0.isLetter && !$0.isNumber && $0 != "'" }.compactMap { word in
            let original = String(word)
            let normalized = original.lowercased().filter { $0.isLetter || $0.isNumber }
            return normalized.isEmpty ? nil : Token(original: original, normalized: normalized)
        }
    }

    /// Finds the strongest local alignment and returns the positions it matched in the Me line.
    private static func matchedMeIndices(_ me: [Token], _ them: [Token]) -> Set<Int> {
        guard me.count >= 3, them.count >= 3 else { return [] }
        var cells = Array(repeating: Array(repeating: AlignmentCell(), count: them.count + 1), count: me.count + 1)
        var best = (i: 0, j: 0, cell: AlignmentCell())

        for i in 1...me.count {
            for j in 1...them.count {
                let similarity = wordSimilarity(me[i - 1].normalized, them[j - 1].normalized)
                let diagonal = AlignmentCell(score: cells[i - 1][j - 1].score + similarity.score,
                                              matches: cells[i - 1][j - 1].matches + (similarity.isMatch ? 1 : 0))
                let up = AlignmentCell(score: cells[i - 1][j].score - 2, matches: cells[i - 1][j].matches)
                let left = AlignmentCell(score: cells[i][j - 1].score - 2, matches: cells[i][j - 1].matches)
                let chosen = [AlignmentCell(), diagonal, up, left].max(by: isWorse)!
                cells[i][j] = chosen
                if isWorse(best.cell, chosen) { best = (i, j, chosen) }
            }
        }

        let isShortPureEcho = best.cell.matches == 2 && best.cell.score >= 6 && me.count <= 3
        guard (best.cell.matches >= 3 && best.cell.score >= 6) || isShortPureEcho else { return [] }
        var i = best.i
        var j = best.j
        var matched = Set<Int>()
        while i > 0, j > 0, cells[i][j].score > 0 {
            let current = cells[i][j]
            let similarity = wordSimilarity(me[i - 1].normalized, them[j - 1].normalized)
            let diagonal = AlignmentCell(score: cells[i - 1][j - 1].score + similarity.score,
                                          matches: cells[i - 1][j - 1].matches + (similarity.isMatch ? 1 : 0))
            if current.score == diagonal.score && current.matches == diagonal.matches {
                if similarity.isMatch { matched.insert(i - 1) }
                i -= 1; j -= 1
            } else if current.score == cells[i - 1][j].score - 2 && current.matches == cells[i - 1][j].matches {
                i -= 1
            } else {
                j -= 1
            }
        }
        return matched
    }

    private static func isWorse(_ lhs: AlignmentCell, _ rhs: AlignmentCell) -> Bool {
        if lhs.score != rhs.score { return lhs.score < rhs.score }
        return lhs.matches < rhs.matches
    }

    private static func wordSimilarity(_ lhs: String, _ rhs: String) -> (score: Int, isMatch: Bool) {
        if lhs == rhs { return (3, true) }
        guard min(lhs.count, rhs.count) >= 4 else { return (-3, false) }
        let distance = levenshtein(lhs, rhs)
        return (distance <= 1 ? 2 : -3, distance <= 1)
    }

    private static func levenshtein(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs), b = Array(rhs)
        var previous = Array(0...b.count)
        for (i, left) in a.enumerated() {
            var current = [i + 1]
            for (j, right) in b.enumerated() {
                current.append(min(previous[j + 1] + 1, current[j] + 1,
                                   previous[j] + (left == right ? 0 : 1)))
            }
            previous = current
        }
        return previous[b.count]
    }
}
