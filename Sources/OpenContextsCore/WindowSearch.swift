import Foundation

public enum WindowSearch {
    public struct Match {
        public let window: WindowInfo
        public let appRanges: [NSRange]
        public let titleRanges: [NSRange]
        fileprivate let score: Int
    }

    public static func filter(_ windows: [WindowInfo], query: String) -> [Match] {
        var matches: [(match: Match, index: Int)] = []
        for (index, window) in windows.enumerated() {
            if let match = match(window, query: query) {
                matches.append((match, index))
            }
        }
        matches.sort {
            $0.match.score == $1.match.score ? $0.index < $1.index : $0.match.score > $1.match.score
        }
        return matches.map(\.match)
    }

    public static func match(_ window: WindowInfo, query: String) -> Match? {
        var appRanges: [NSRange] = []
        var titleRanges: [NSRange] = []
        var score = 0
        for token in query.split(whereSeparator: \.isWhitespace) {
            let app = matchText(window.appName, token: String(token))
            let title = matchText(window.displayTitle, token: String(token))
            guard app != nil || title != nil else { return nil }
            appRanges += app?.ranges ?? []
            titleRanges += title?.ranges ?? []
            score += max(app?.score ?? Int.min, title?.score ?? Int.min)
        }
        return Match(window: window, appRanges: appRanges, titleRanges: titleRanges, score: score)
    }

    private static func matchText(_ text: String, token: String) -> (score: Int, ranges: [NSRange])? {
        if let range = text.range(of: token, options: [.caseInsensitive, .diacriticInsensitive]) {
            let score = range == text.startIndex..<text.endIndex ? 1_000
                : range.lowerBound == text.startIndex ? 700
                : isWordStart(range.lowerBound, in: text) ? 600 : 500
            return (score, [NSRange(range, in: text)])
        }

        return matchPinyin(text, token: token)
            ?? matchSubsequence(text, token: token)
            ?? matchTypo(text, token: token)
    }

    private static func matchSubsequence(_ text: String, token: String) -> (score: Int, ranges: [NSRange])? {
        let characters = text.indices.map { (index: $0, folded: folded(text[$0])) }
        let tokenCharacters = token.map(folded)
        guard tokenCharacters.count >= 2, !characters.isEmpty else { return nil }

        func score(_ positions: [Int]) -> Int {
            guard let first = positions.first, let last = positions.last else { return Int.min }
            let indices = positions.map { characters[$0].index }
            let span = NSRange(indices[0]..<text.index(after: indices[indices.count - 1]), in: text).length
            let gaps = max(0, span - positions.count)
            let wordStarts = indices.filter { isWordStart($0, in: text) }.count
            return 340 + min(80, positions.count * 8)
                + (wordStarts == positions.count ? 70 : wordStarts * 8)
                - min(140, gaps * 5) - first / 2 - (characters.count - last) / 20
        }

        var paths = characters.indices.filter { characters[$0].folded == tokenCharacters[0] }.map { [$0] }
        for tokenCharacter in tokenCharacters.dropFirst() {
            var extended: [[Int]] = []
            for path in paths {
                guard let last = path.last, last + 1 < characters.count else { continue }
                for position in (last + 1)..<characters.count where characters[position].folded == tokenCharacter {
                    extended.append(path + [position])
                }
            }
            paths = Array(extended.sorted { score($0) > score($1) }.prefix(128))
            if paths.isEmpty { return nil }
        }
        guard let best = paths.max(by: { score($0) < score($1) }) else { return nil }
        let indices = best.map { characters[$0].index }
        return (score(best), highlightRanges(for: indices, in: text))
    }

    private static func matchTypo(_ text: String, token: String) -> (score: Int, ranges: [NSRange])? {
        let tokenCharacters = token.map(folded)
        guard tokenCharacters.count >= 3 else { return nil }
        let maximumDistance = tokenCharacters.count < 8 ? 1 : tokenCharacters.count < 14 ? 2 : 3
        var best: (score: Int, range: Range<String.Index>)?
        for range in wordRanges(in: text) {
            let candidate = text[range].map(folded)
            guard abs(candidate.count - tokenCharacters.count) <= min(1, maximumDistance),
                  let distance = editDistance(tokenCharacters, candidate, limit: maximumDistance),
                  distance > 0 else { continue }
            let score = 300 - distance * 35 - abs(candidate.count - tokenCharacters.count) * 10
                + (range.lowerBound == text.startIndex ? 20 : 0)
            if best == nil || score > best!.score { best = (score, range) }
        }
        guard let best else { return nil }
        return (best.score, [NSRange(best.range, in: text)])
    }

    private static func wordRanges(in text: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var start: String.Index?
        for index in text.indices {
            if text[index].isLetter || text[index].isNumber {
                if start == nil { start = index }
            } else if start != nil {
                result.append(start!..<index)
                start = nil
            }
        }
        if let start { result.append(start..<text.endIndex) }
        return result
    }

    private static func editDistance(_ lhs: [String], _ rhs: [String], limit: Int) -> Int? {
        guard abs(lhs.count - rhs.count) <= limit else { return nil }
        var distances = Array(repeating: Array(repeating: 0, count: rhs.count + 1), count: lhs.count + 1)
        for index in 0...lhs.count { distances[index][0] = index }
        for index in 0...rhs.count { distances[0][index] = index }
        for left in 1...lhs.count {
            for right in 1...rhs.count {
                let substitution = distances[left - 1][right - 1] + (lhs[left - 1] == rhs[right - 1] ? 0 : 1)
                distances[left][right] = min(distances[left - 1][right] + 1,
                                             distances[left][right - 1] + 1,
                                             substitution)
                if left > 1, right > 1,
                   lhs[left - 1] == rhs[right - 2], lhs[left - 2] == rhs[right - 1] {
                    distances[left][right] = min(distances[left][right], distances[left - 2][right - 2] + 1)
                }
            }
        }
        let distance = distances[lhs.count][rhs.count]
        return distance <= limit ? distance : nil
    }

    private static func highlightRanges(for indices: [String.Index], in text: String) -> [NSRange] {
        var ranges: [Range<String.Index>] = []
        for index in indices {
            let range = index..<text.index(after: index)
            if let last = ranges.last, last.upperBound == index {
                ranges[ranges.count - 1] = last.lowerBound..<range.upperBound
            } else {
                ranges.append(range)
            }
        }
        return ranges.map { NSRange($0, in: text) }
    }

    private static func folded(_ character: Character) -> String {
        String(character).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    private static func isWordStart(_ index: String.Index, in text: String) -> Bool {
        guard index != text.startIndex else { return true }
        let previous = text[text.index(before: index)]
        return !previous.isLetter && !previous.isNumber
            || previous.isLowercase && text[index].isUppercase
    }

    /// Matches an ASCII token against the toneless pinyin of Chinese characters, e.g. "weixin" or "weix" for 微信.
    /// The match starts at a character and may end inside the last syllable; highlights cover whole characters.
    private static func matchPinyin(_ text: String, token: String) -> (score: Int, ranges: [NSRange])? {
        guard token.unicodeScalars.allSatisfy(\.isASCII),
              text.unicodeScalars.contains(where: isHan) else { return nil }
        let token = token.lowercased()
        let indices = Array(text.indices)
        let syllables = indices.map { pinyin(for: text[$0]) }

        for start in indices.indices where syllables[start].first.map({ token.hasPrefix(String($0)) }) == true {
            var remaining = Substring(token)
            var end = start
            var endsMidSyllable = false
            while end < indices.count, !remaining.isEmpty {
                let syllable = syllables[end]
                if remaining.hasPrefix(syllable) {
                    remaining = remaining.dropFirst(syllable.count)
                } else if syllable.hasPrefix(remaining) {
                    remaining = ""
                    endsMidSyllable = true
                } else {
                    break
                }
                end += 1
            }
            guard remaining.isEmpty else { continue }
            let range = indices[start]..<(end < indices.count ? indices[end] : text.endIndex)
            // Pinyin matches rank just below the equivalent literal match.
            let score = !endsMidSyllable && range == text.startIndex..<text.endIndex ? 950
                : start == 0 ? 650
                : isHan(text[indices[start]].unicodeScalars.first!) || !text[indices[start - 1]].isLetter ? 550 : 450
            return (score, [NSRange(range, in: text)])
        }
        return nil
    }

    private static let pinyinCache = NSCache<NSString, NSString>()

    private static func pinyin(for character: Character) -> String {
        guard let scalar = character.unicodeScalars.first, isHan(scalar) else { return character.lowercased() }
        let key = String(character) as NSString
        if let cached = pinyinCache.object(forKey: key) { return cached as String }
        let latin = String(character).applyingTransform(.mandarinToLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false)?
            .lowercased().filter { !$0.isWhitespace } ?? ""
        let value = latin.isEmpty ? character.lowercased() : latin
        pinyinCache.setObject(value as NSString, forKey: key)
        return value
    }

    private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2EBEF: true
        default: false
        }
    }
}
