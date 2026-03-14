import Foundation

struct QBOStatementExtractor {
    /// Parse a QBO (OFX) file into simple rows and headers that downstream parsers can consume.
    /// Produced headers are ["Date", "Description", "Amount", "Account"].
    static func parse(url: URL) throws -> ([[String]], [String]) {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw NSError(domain: "QBOStatementExtractor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unknown text encoding"])
        }

        let accountLabel = inferAccountLabelFromOFX(text)
        let blocks = extractBlocks(text, tag: "STMTTRN")
        var rows: [[String]] = []

        for block in blocks {
            let rawDate = valueForTag("DTPOSTED", in: block) ?? valueForTag("DTUSER", in: block) ?? ""
            let date = parseOFXDate(rawDate)
            let amount = valueForTag("TRNAMT", in: block) ?? ""
            let name = valueForTag("NAME", in: block) ?? ""
            let memo = valueForTag("MEMO", in: block)
            let desc: String = {
                let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
                let m = (memo ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !n.isEmpty && !m.isEmpty { return n + " — " + m }
                if !n.isEmpty { return n }
                if !m.isEmpty { return m }
                return "Unknown"
            }()
            let acct = accountLabel ?? ""
            // Row order must match headers order
            rows.append([date, desc, amount, acct])
        }

        let headers = ["Date", "Description", "Amount", "Account"]
        return (rows, headers)
    }

    /// Find segments beginning with <TAG> and ending before the next <TAG> or a </TAG>.
    static func extractBlocks(_ text: String, tag: String) -> [String] {
        let upper = text.uppercased()
        let tagUpper = "<" + tag.uppercased() + ">"
        let endTagUpper = "</" + tag.uppercased() + ">"
        var blocks: [String] = []
        var searchStart = upper.startIndex
        while let startRange = upper.range(of: tagUpper, options: [], range: searchStart..<upper.endIndex) {
            let contentStartUpper = startRange.upperBound
            // Find next occurrence of either the same start tag or the end tag
            let nextStart = upper.range(of: tagUpper, options: [], range: contentStartUpper..<upper.endIndex)?.lowerBound
            let endTag = upper.range(of: endTagUpper, options: [], range: contentStartUpper..<upper.endIndex)?.lowerBound
            let chosenEndUpper = minIndex(nextStart, endTag) ?? upper.endIndex

            // Map indices back to original text using offsets
            let startOffset = upper.distance(from: upper.startIndex, to: contentStartUpper)
            let endOffset = upper.distance(from: upper.startIndex, to: chosenEndUpper)
            let startOrig = text.index(text.startIndex, offsetBy: startOffset)
            let endOrig = text.index(text.startIndex, offsetBy: endOffset)
            let block = String(text[startOrig..<endOrig])
            blocks.append(block)

            searchStart = chosenEndUpper
        }
        return blocks
    }

    /// Find <TAG>value where value runs until the next '<'. Case-insensitive for the tag.
    static func valueForTag(_ tag: String, in block: String) -> String? {
        let blockUpper = block.uppercased()
        let needle = "<" + tag.uppercased() + ">"
        guard let tagRangeUpper = blockUpper.range(of: needle) else { return nil }
        let valueStartUpper = tagRangeUpper.upperBound
        // Find next '<' from valueStart
        let nextLTUpper = blockUpper[valueStartUpper...].firstIndex(of: "<") ?? blockUpper.endIndex

        let startOffset = blockUpper.distance(from: blockUpper.startIndex, to: valueStartUpper)
        let endOffset = blockUpper.distance(from: blockUpper.startIndex, to: nextLTUpper)
        let startOrig = block.index(block.startIndex, offsetBy: startOffset)
        let endOrig = block.index(block.startIndex, offsetBy: endOffset)
        let raw = String(block[startOrig..<endOrig]).trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }

    /// Parse OFX-style date strings and output MM/dd/yyyy. Falls back to empty string on failure.
    static func parseOFXDate(_ s: String) -> String {
        // Extract first 8 digits as yyyyMMdd
        let digits = s.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }
        let compact = String(String.UnicodeScalarView(digits))
        guard compact.count >= 8 else { return s }
        let ymd = String(compact.prefix(8))
        let dfIn = DateFormatter()
        dfIn.locale = Locale(identifier: "en_US_POSIX")
        dfIn.timeZone = TimeZone(secondsFromGMT: 0)
        dfIn.dateFormat = "yyyyMMdd"
        let dfOut = DateFormatter()
        dfOut.locale = Locale(identifier: "en_US_POSIX")
        dfOut.timeZone = TimeZone(secondsFromGMT: 0)
        dfOut.dateFormat = "MM/dd/yyyy"
        if let d = dfIn.date(from: ymd) { return dfOut.string(from: d) }
        return s
    }

    /// Look for <BANKACCTFROM> or <CCACCTFROM> and map to "checking"/"creditcard".
    static func inferAccountLabelFromOFX(_ text: String) -> String? {
        let upper = text.uppercased()
        if upper.contains("<CCACCTFROM>") { return "creditcard" }
        if upper.contains("<BANKACCTFROM>") { return "checking" }
        return nil
    }

    /// Helper: pick the earliest non-nil index
    private static func minIndex(_ a: String.Index?, _ b: String.Index?) -> String.Index? {
        switch (a, b) {
        case let (x?, y?): return x < y ? x : y
        case let (x?, nil): return x
        case let (nil, y?): return y
        default: return nil
        }
    }
}
