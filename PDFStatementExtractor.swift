import Foundation
import PDFKit

enum PDFStatementExtractor {
    enum Mode { case summaryOnly, transactions }

    static func parse(url: URL, mode: Mode = .summaryOnly) throws -> (rows: [[String]], headers: [String]) {
        guard let doc = PDFDocument(url: url) else {
            throw ImportError.unknownFormat
        }

        // Extract text across all pages
        var text = ""
        for i in 0..<doc.pageCount {
            if let page = doc.page(at: i), let s = page.string {
                text += s + "\n"
            }
        }
        AMLogging.always("PDF pages: \(doc.pageCount)", component: "PDFStatementExtractor")

        // Normalize and split into lines
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        AMLogging.always("PDF extracted lines: \(lines.count)", component: "PDFStatementExtractor")

        // Date patterns: numeric and month-name
        let dateStartPattern = #"^(?:\d{1,2}/\d{1,2}/\d{2,4}|(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec|January|February|March|April|May|June|July|August|September|October|November|December)\s+\d{1,2},?\s*\d{2,4})"#
        let dateStartRegex = try NSRegularExpression(pattern: dateStartPattern)

        // Money patterns: handle leading/trailing minus, parentheses, optional $ and CR/DR markers
        let moneyCore = #"\d{1,3}(?:,\d{3})*(?:\.\d{2})?"#
        let moneyToken = #"\(?-?\s?\$?"# + moneyCore + #"-?\)?(?:\s*(?:CR|DR|CREDIT|DEBIT))?"#
        let dateToken = #"(?:\d{1,2}/\d{1,2}/\d{2,4}|(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec|January|February|March|April|May|June|July|August|September|October|November|December)\s+\d{1,2},?\s*\d{2,4})"#

        // Full single-line row: Date [PostDate] Description Amount [Balance]
        let rowPattern = #"^(\#(dateToken))(?:\s+(\#(dateToken)))?\s+(.*?)\s+(\#(moneyToken))(?:\s+(\#(moneyToken)))?$"#
        let rowRegex = try NSRegularExpression(pattern: rowPattern, options: [.caseInsensitive])

        // Amount-only line for two-line rows
        let amountOnlyRegex = try NSRegularExpression(
            pattern: "^" + moneyToken + "$",
            options: [.caseInsensitive]
        )

        // Amount anywhere (for permissive fallback)
        let amountAnywhereRegex = try NSRegularExpression(
            pattern: moneyToken,
            options: [.caseInsensitive]
        )

        // Date + [PostDate] + Description (no trailing amount)
        let dateAndDescRegex = try NSRegularExpression(
            pattern: #"^((?:\d{1,2}/\d{1,2}/\d{2,4}|(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec|January|February|March|April|May|June|July|August|September|October|November|December)\s+\d{1,2},?\s*\d{2,4}))(?:\s+(?:\d{1,2}/\d{1,2}/\d{2,4}|(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec|January|February|March|April|May|June|July|August|September|October|November|December)\s+\d{1,2},?\s*\d{2,4}))?\s+(.*)$"#,
            options: [.caseInsensitive]
        )

        func normalizeDateString(_ s: String) -> String {
            // Try multiple formats and reformat to MM/dd/yyyy
            let fmts = [
                "MM/dd/yyyy", "M/d/yyyy", "MM/dd/yy", "M/d/yy",
                "yyyy-MM-dd", "yyyy/M/d", "yyyy/MM/dd",
                "dd-MMM-yyyy", "d-MMM-yy", "dd MMM yyyy", "d MMM yy",
                "MMM d, yyyy", "MMMM d, yyyy", "MMM d, yy", "MMMM d, yy",
                "MMM d yyyy", "MMMM d yyyy"
            ]
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone(secondsFromGMT: 0)
            for f in fmts {
                df.dateFormat = f
                if let d = df.date(from: s) {
                    df.dateFormat = "MM/dd/yyyy"
                    return df.string(from: d)
                }
            }
            return s
        }

        // Generic noise detection for header/footer/footnote lines
        let pageLineRegex = try NSRegularExpression(pattern: #"^\s*page\s+\d+(?:\s+of\s+\d+)?\s*$"#, options: [.caseInsensitive])
        func isPageLine(_ s: String) -> Bool {
            pageLineRegex.firstMatch(in: s, options: [], range: NSRange(location: 0, length: s.utf16.count)) != nil
        }
        func isIntentionallyBlank(_ s: String) -> Bool {
            s.range(of: "intentionally left blank", options: [.caseInsensitive]) != nil
        }
        func isHeaderLike(_ s: String) -> Bool {
            // Lines that end with ':' and contain no digits or currency often are section headers
            let hasDigits = s.rangeOfCharacter(from: CharacterSet.decimalDigits) != nil
            let hasCurrency = s.contains("$")
            return s.hasSuffix(":") && !hasDigits && !hasCurrency
        }
        func isFootnoteStar(_ s: String) -> Bool {
            s.trimmingCharacters(in: .whitespaces).hasPrefix("*")
        }
        func isNoiseLine(_ s: String) -> Bool {
            return isPageLine(s) || isIntentionallyBlank(s) || isHeaderLike(s) || isFootnoteStar(s)
        }

        // Additional generic header filters
        let anyDateRegex = try NSRegularExpression(pattern: dateToken, options: [.caseInsensitive])
        let dateRangeRegex = try NSRegularExpression(
            pattern: "^\\s*(" + dateToken + ")(?:\\s*(?:through|to|–|—|-|—)\\s*)(" + dateToken + ")\\s*$",
            options: [.caseInsensitive]
        )
        func hasMoneyToken(_ s: String) -> Bool {
            return amountAnywhereRegex.firstMatch(in: s, options: [], range: NSRange(location: 0, length: s.utf16.count)) != nil
        }
        func isDateRangeLine(_ s: String) -> Bool {
            // Treat only lines that begin with a date range and do not contain any money token as headers
            if hasMoneyToken(s) { return false }
            return dateRangeRegex.firstMatch(in: s, options: [], range: NSRange(location: 0, length: s.utf16.count)) != nil
        }
        func isAccountMetaLine(_ s: String) -> Bool {
            let lower = s.lowercased()
            return lower.contains("account number") || lower.contains("account ending") || lower.contains("primary account")
        }
        func isStatementPeriodLine(_ s: String) -> Bool {
            let lower = s.lowercased()
            if hasMoneyToken(s) { return false }
            if lower.contains("statement period") || lower.contains("statement from") { return true }
            // Heuristic: lines that contain "through" and begin with a date and contain at least two date tokens
            if lower.contains("through") && isDateStart(s) {
                let count = anyDateRegex.numberOfMatches(in: s, options: [], range: NSRange(location: 0, length: s.utf16.count))
                return count >= 2
            }
            return false
        }
        func isThroughContinuationLine(_ s: String) -> Bool {
            let lower = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if s.contains("$") { return false }
            return lower.hasPrefix("through ")
        }

        func collapse(_ s: String) -> String {
            let parts = s.split(whereSeparator: { $0.isNewline || $0.isWhitespace })
            return parts.joined(separator: " ")
        }
        func cleanDesc(_ s: String) -> String {
            var t = collapse(s).trimmingCharacters(in: .whitespacesAndNewlines)
            if t.count > 120 { t = String(t.prefix(120)) }
            return t
        }

        func isDateStart(_ line: String) -> Bool {
            dateStartRegex.firstMatch(in: line, options: [], range: NSRange(location: 0, length: line.utf16.count)) != nil
        }

        func firstMatch(_ regex: NSRegularExpression, in s: String) -> NSTextCheckingResult? {
            regex.firstMatch(in: s, options: [], range: NSRange(location: 0, length: s.utf16.count))
        }

        var rows: [[String]] = []

        var i = 0
        while i < lines.count {
            let line = lines[i]

            // Only consider potential entries that start with a date token
            if !isDateStart(line) {
                i += 1
                continue
            }

            // Skip page/section headers that start with a date but represent a period header (e.g., "Dec 17, 2025 through Jan 20, 2026")
            if isDateRangeLine(line) || isStatementPeriodLine(line) || isAccountMetaLine(line) {
                i += 1
                continue
            }

            // Try full single-line match first
            if let match = firstMatch(rowRegex, in: line) {
                func group(_ idx: Int) -> String {
                    let r = match.range(at: idx)
                    if let range = Range(r, in: line) {
                        return String(line[range]).trimmingCharacters(in: .whitespaces)
                    }
                    return ""
                }
                let dateRaw = group(1)
                let descRaw = group(3)
                let amtRaw = group(4)
                let balRaw = group(5)

                let date = normalizeDateString(dateRaw)
                let desc = cleanDesc(descRaw)
                let amount = sanitizeAmount(amtRaw)
                let balance = balRaw.isEmpty ? "" : sanitizeAmount(balRaw)

                rows.append([date, desc, amount, balance])
                i += 1
                continue
            }

            // Fallback: two-line row where next line is amount-only (no balance)
            if i + 1 < lines.count {
                let next = lines[i + 1]
                if firstMatch(amountOnlyRegex, in: next) != nil,
                   let ddMatch = firstMatch(dateAndDescRegex, in: line) {
                    func groupFrom(_ match: NSTextCheckingResult, in string: String, idx: Int) -> String {
                        let r = match.range(at: idx)
                        if let range = Range(r, in: string) {
                            return String(string[range]).trimmingCharacters(in: .whitespaces)
                        }
                        return ""
                    }
                    let dateRaw = groupFrom(ddMatch, in: line, idx: 1)
                    let descRaw = groupFrom(ddMatch, in: line, idx: 2)
                    let date = normalizeDateString(dateRaw)
                    let desc = cleanDesc(descRaw)
                    let amount = sanitizeAmount(next)
                    rows.append([date, desc, amount, ""]) // no balance captured in this shape
                    i += 2
                    continue
                }
            }

            // Nothing captured from this block; advance
            i += 1
        }

        // Permissive fallback: if the primary pass found no rows, retry with relaxed rules
        if rows.isEmpty {
            AMLogging.always("PDF primary pass found 0 rows — running permissive fallback", component: "PDFStatementExtractor")
            var simple: [[String]] = []
            var createdAny = false
            var k = 0
            while k < lines.count {
                let ln = lines[k]
                if !isDateStart(ln) { k += 1; continue }

                // Try strict single-line row first
                if let match = firstMatch(rowRegex, in: ln) {
                    func group(_ idx: Int) -> String {
                        let r = match.range(at: idx)
                        if let range = Range(r, in: ln) {
                            return String(ln[range]).trimmingCharacters(in: .whitespaces)
                        }
                        return ""
                    }
                    let dateRaw = group(1)
                    let descRaw = group(3)
                    let amtRaw = group(4)
                    let balRaw = group(5)
                    let date = normalizeDateString(dateRaw)
                    let desc = cleanDesc(descRaw)
                    let amount = sanitizeAmount(amtRaw)
                    let balance = balRaw.isEmpty ? "" : sanitizeAmount(balRaw)
                    createdAny = true
                    simple.append([date, desc, amount, balance])
                    k += 1
                    continue
                }

                // Try date + desc + amount on same line (amount anywhere)
                if let dd = firstMatch(dateAndDescRegex, in: ln) {
                    let dr = dd.range(at: 1)
                    let rr = dd.range(at: 2)
                    let dateRaw = (Range(dr, in: ln).map { String(ln[$0]) } ?? "")
                    let rest = (Range(rr, in: ln).map { String(ln[$0]) } ?? "")
                    let date = normalizeDateString(dateRaw)
                    // amount anywhere on same line
                    if let am = amountAnywhereRegex.firstMatch(in: ln, options: [], range: NSRange(location: 0, length: ln.utf16.count)), let ar = Range(am.range, in: ln) {
                        let amount = sanitizeAmount(String(ln[ar]))
                        let desc = cleanDesc(rest.replacingOccurrences(of: String(ln[ar]), with: ""))
                        createdAny = true
                        simple.append([date, desc, amount, ""]) // no balance in permissive mode
                        k += 1
                        continue
                    }
                    // amount-only next line
                    if k + 1 < lines.count {
                        let nxt = lines[k + 1]
                        if amountOnlyRegex.firstMatch(in: nxt, options: [], range: NSRange(location: 0, length: nxt.utf16.count)) != nil {
                            let amount = sanitizeAmount(nxt)
                            let desc = cleanDesc(rest)
                            createdAny = true
                            simple.append([date, desc, amount, ""]) // no balance in permissive mode
                            k += 2
                            continue
                        }
                    }
                }

                k += 1
            }
            if !createdAny {
                // leave rows empty
            } else {
                rows = simple
            }
        }

        // Detect statement summary balances (Beginning/Ending Balance) and synthesize balance rows
        var didAppendSummary = false
        do {
            // Helper to parse normalized dates (we normalized to MM/dd/yyyy earlier)
            func parseNormalizedDate(_ s: String) -> Date? {
                let df = DateFormatter()
                df.locale = Locale(identifier: "en_US_POSIX")
                df.timeZone = TimeZone(secondsFromGMT: 0)
                df.dateFormat = "MM/dd/yyyy"
                return df.date(from: s)
            }

            // Compute earliest/latest dates from already extracted rows
            let dates: [Date] = rows.compactMap { $0.first }.compactMap { parseNormalizedDate($0) }
            let earliestDate = dates.min()
            let latestDate = dates.max()

            // Only proceed if we have at least one dated row
            if let earliestDate, let latestDate {
                // Find lines containing summary labels
                let beginLabel = "beginning balance"
                let endLabel = "ending balance"
                var beginningAmount: String? = nil
                var endingAmount: String? = nil

                func amountNear(lineIndex: Int, label: String) -> String? {
                    guard lineIndex >= 0 && lineIndex < lines.count else { return nil }
                    let current = lines[lineIndex]
                    let lower = current.lowercased()
                    if let range = lower.range(of: label) {
                        let suffixStart = range.upperBound
                        let suffix = String(current[suffixStart...])
                        // Prefer amount on the same line, after the label (take the last token in the suffix)
                        let matches = amountAnywhereRegex.matches(in: suffix, options: [], range: NSRange(location: 0, length: suffix.utf16.count))
                        if let last = matches.last, let r = Range(last.range, in: suffix) {
                            return sanitizeAmount(String(suffix[r]))
                        }
                    }
                    // Fallback: any amount on the same line (take the last token)
                    let sameMatches = amountAnywhereRegex.matches(in: current, options: [], range: NSRange(location: 0, length: current.utf16.count))
                    if let last = sameMatches.last, let r = Range(last.range, in: current) {
                        return sanitizeAmount(String(current[r]))
                    }
                    // Else check the immediate next line for an amount-only token
                    if lineIndex + 1 < lines.count {
                        let next = lines[lineIndex + 1]
                        if amountOnlyRegex.firstMatch(in: next, options: [], range: NSRange(location: 0, length: next.utf16.count)) != nil {
                            return sanitizeAmount(next)
                        }
                        // Or any money token in the next line
                        let nextMatches = amountAnywhereRegex.matches(in: next, options: [], range: NSRange(location: 0, length: next.utf16.count))
                        if let last = nextMatches.last, let r = Range(last.range, in: next) {
                            return sanitizeAmount(String(next[r]))
                        }
                    }
                    return nil
                }

                for (idx, l) in lines.enumerated() {
                    let lower = l.lowercased()
                    if lower.contains(beginLabel), beginningAmount == nil {
                        beginningAmount = amountNear(lineIndex: idx, label: beginLabel)
                    }
                    if lower.contains(endLabel), endingAmount == nil {
                        endingAmount = amountNear(lineIndex: idx, label: endLabel)
                    }
                    if beginningAmount != nil && endingAmount != nil { break }
                }

                // Append synthetic rows if we detected summary balances
                if (beginningAmount != nil || endingAmount != nil) {
                    let df = DateFormatter()
                    df.locale = Locale(identifier: "en_US_POSIX")
                    df.timeZone = TimeZone(secondsFromGMT: 0)
                    df.dateFormat = "MM/dd/yyyy"
                    let cal = Calendar(identifier: .gregorian)
                    let earliestMinusOne = cal.date(byAdding: .day, value: -1, to: earliestDate) ?? earliestDate
                    let earliestStr = df.string(from: earliestMinusOne)
                    let latestStr = df.string(from: latestDate)

                    if let b = beginningAmount {
                        rows.append([earliestStr, "Statement Beginning Balance", "0", b])
                        didAppendSummary = true
                        AMLogging.always("PDF summary: beginning balance detected = \(b) @ \(earliestStr)", component: "PDFStatementExtractor")
                    }
                    if let e = endingAmount {
                        rows.append([latestStr, "Statement Ending Balance", "0", e])
                        didAppendSummary = true
                        AMLogging.always("PDF summary: ending balance detected = \(e) @ \(latestStr)", component: "PDFStatementExtractor")
                    }
                }
            }
        }
        // If we synthesized statement summary balances, discard any other parsed rows to avoid bogus transactions from headers/body text
        if didAppendSummary && mode == .summaryOnly {
            rows = rows.filter { r in
                guard r.count >= 2 else { return false }
                let d = r[1].lowercased()
                return d.contains("statement beginning balance") || d.contains("statement ending balance")
            }
        }

        // In transactions mode, preserve per-row balances for sign inference; only clear in summary-only mode
        if mode == .summaryOnly {
            for idx in 0..<rows.count {
                if rows[idx].count >= 4 && !rows[idx][3].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let descLower = rows[idx][1].lowercased()
                    if !descLower.contains("statement beginning balance") && !descLower.contains("statement ending balance") {
                        rows[idx][3] = ""
                    }
                }
            }
        }

        AMLogging.always("PDF matched rows: \(rows.count)", component: "PDFStatementExtractor")

        guard !rows.isEmpty else {
            throw ImportError.unknownFormat
        }

        // Always include balance column; rows that lack it will contain an empty string
        let headers = ["date", "description", "amount", "balance"]
        return (rows, headers)
    }

    private static func sanitizeAmount(_ s: String) -> String {
        // Normalize spacing and case for sign markers
        var raw = s.trimmingCharacters(in: .whitespacesAndNewlines)

        // Detect sign hints
        let upper = raw.uppercased()
        var negativeHint = false
        var positiveHint = false

        // Parentheses denote negatives
        if raw.hasPrefix("(") && raw.hasSuffix(")") {
            negativeHint = true
            raw.removeFirst()
            raw.removeLast()
        }

        // Trailing minus (e.g., 123.45-)
        if raw.hasSuffix("-") { negativeHint = true; raw.removeLast() }

        // Leading minus (e.g., - 123.45)
        if raw.hasPrefix("-") { negativeHint = true; raw.removeFirst() }
        if raw.hasPrefix("- ") { negativeHint = true; raw.removeFirst() }

        // CR/DR markers
        if upper.contains("DR") || upper.contains("DEBIT") { negativeHint = true }
        if upper.contains("CR") || upper.contains("CREDIT") { positiveHint = true }

        // Strip currency symbols, commas, spaces, and CR/DR tokens
        var cleaned = raw
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: " ", with: "")

        // Remove textual markers that may remain inside the token
        let markers = ["CR", "DR", "CREDIT", "DEBIT"]
        for m in markers {
            cleaned = cleaned.replacingOccurrences(of: m, with: "", options: [.caseInsensitive])
        }

        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        // Prefix negative sign if indicated (unless explicitly positive hinted)
        if negativeHint && !positiveHint && !cleaned.hasPrefix("-") {
            cleaned = "-" + cleaned
        }

        return cleaned
    }
}

