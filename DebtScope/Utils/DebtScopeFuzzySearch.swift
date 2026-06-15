import Foundation

enum DebtScopeFuzzySearch {
    static func matches(query: String, values: [String]) -> Bool {
        let normalizedQuery = normalize(query)
        guard !normalizedQuery.isEmpty else { return false }

        let queryTokens = tokens(in: normalizedQuery)
        guard !queryTokens.isEmpty else { return false }

        for value in values {
            let normalizedValue = normalize(value)
            guard !normalizedValue.isEmpty else { continue }

            if normalizedValue.contains(normalizedQuery) {
                return true
            }

            let compactValue = normalizedValue.replacingOccurrences(of: " ", with: "")
            let compactQuery = normalizedQuery.replacingOccurrences(of: " ", with: "")
            if compactQuery.count >= 3, compactValue.contains(compactQuery) {
                return true
            }

            let valueTokens = tokens(in: normalizedValue)
            if queryTokens.allSatisfy({ queryToken in valueTokens.contains { valueToken in tokenMatches(queryToken, valueToken: valueToken) } }) {
                return true
            }
        }

        return false
    }

    private static func normalize(_ value: String) -> String {
        let folded = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let scalars = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }

        return String(scalars)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func tokens(in value: String) -> [String] {
        value.split(separator: " ").map(String.init)
    }

    private static func tokenMatches(_ queryToken: String, valueToken: String) -> Bool {
        if valueToken.contains(queryToken) || valueToken.hasPrefix(queryToken) {
            return true
        }

        guard queryToken.count >= 3 else {
            return false
        }

        if isSubsequence(queryToken, of: valueToken), queryToken.count >= 4 {
            return true
        }

        let threshold: Int
        switch queryToken.count {
        case 0...4:
            threshold = 1
        case 5...8:
            threshold = 2
        default:
            threshold = 3
        }

        return levenshteinDistance(queryToken, valueToken, maximumDistance: threshold) <= threshold
    }

    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var currentIndex = haystack.startIndex

        for character in needle {
            guard let matchIndex = haystack[currentIndex...].firstIndex(of: character) else {
                return false
            }
            currentIndex = haystack.index(after: matchIndex)
        }

        return true
    }

    private static func levenshteinDistance(_ lhs: String, _ rhs: String, maximumDistance: Int) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)

        if abs(left.count - right.count) > maximumDistance {
            return maximumDistance + 1
        }

        var previousRow = Array(0...right.count)
        var currentRow = Array(repeating: 0, count: right.count + 1)

        for leftIndex in 1...left.count {
            currentRow[0] = leftIndex
            var rowMinimum = currentRow[0]

            for rightIndex in 1...right.count {
                let substitutionCost = left[leftIndex - 1] == right[rightIndex - 1] ? 0 : 1
                currentRow[rightIndex] = min(
                    previousRow[rightIndex] + 1,
                    currentRow[rightIndex - 1] + 1,
                    previousRow[rightIndex - 1] + substitutionCost
                )
                rowMinimum = min(rowMinimum, currentRow[rightIndex])
            }

            if rowMinimum > maximumDistance {
                return maximumDistance + 1
            }

            swap(&previousRow, &currentRow)
        }

        return previousRow[right.count]
    }
}
