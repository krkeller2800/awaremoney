import Foundation
import PDFKit
import CoreGraphics
import Vision

enum PDFStatementExtractor {
    enum Mode { case summaryOnly, transactions }

    static func parse(url: URL, mode: Mode = .summaryOnly) throws -> (rows: [[String]], headers: [String]) {
        guard let doc = PDFDocument(url: url) else {
            throw ImportError.unknownFormat
        }

        // Extract text across all pages
        var text = ""
        let pageBreakMarker = "<<<PAGE_BREAK>>>"
        for i in 0..<doc.pageCount {
            if let page = doc.page(at: i), let s = page.string {
                text += s + "\n"
                if i < doc.pageCount - 1 {
                    text += pageBreakMarker + "\n"
                }
            }
        }
        AMLogging.always("PDF pages: \(doc.pageCount)", component: "PDFStatementExtractor")

        // Normalize and split into lines
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        AMLogging.always("PDF extracted lines: \(lines.count)", component: "PDFStatementExtractor")

        // Try to infer a default year from any 4-digit year present in the document
        let inferredYear = detectInferredYear(from: lines)
        if let y = inferredYear {
            AMLogging.always("PDF inferred year: \(y)", component: "PDFStatementExtractor")
        } else {
            AMLogging.always("PDF inferred year: <none>", component: "PDFStatementExtractor")
        }

        struct StatementPeriod { let startMonth: Int; let startYear: Int; let endMonth: Int; let endYear: Int }
        func monthNumber(from token: String) -> Int? {
            let lower = token.lowercased()
            let months = ["january":1,"february":2,"march":3,"april":4,"may":5,"june":6,"july":7,"august":8,"september":9,"october":10,"november":11,"december":12,
                          "jan":1,"feb":2,"mar":3,"apr":4,"jun":6,"jul":7,"aug":8,"sep":9,"sept":9,"oct":10,"nov":11,"dec":12]
            if let m = months.first(where: { lower.hasPrefix($0.key) })?.value { return m }
            // numeric mm/dd
            let comps = token.split(separator: "/")
            if comps.count >= 1, let m = Int(comps[0]) { return max(1, min(12, m)) }
            return nil
        }
        func extractMonthYear(from token: String) -> (month: Int?, year: Int?) {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "")
            let parts = trimmed.split(separator: " ")
            // Try month name first
            if let m = monthNumber(from: trimmed) {
                // Year may be last component if present
                let yearRegex = try! NSRegularExpression(pattern: #"\b(20\d{2}|19\d{2})\b"#)
                if let match = yearRegex.firstMatch(in: trimmed, options: [], range: NSRange(location: 0, length: trimmed.utf16.count)), let r = Range(match.range(at: 1), in: trimmed) {
                    return (m, Int(trimmed[r]))
                }
                return (m, nil)
            }
            // Try numeric mm/dd(/yy)
            let comps = trimmed.split(separator: "/")
            if comps.count >= 2, let m = Int(comps[0]) {
                let y: Int?
                if comps.count >= 3, let yy = Int(comps[2]) {
                    y = (yy < 100 ? (2000 + yy) : yy)
                } else { y = nil }
                return (m, y)
            }
            return (nil, nil)
        }
        func detectStatementPeriod(in lines: [String]) -> StatementPeriod? {
            // Local date token and range regex to avoid capturing outer variables before declaration
            let dateTokenLocal = #"(?:\d{1,2}/\d{1,2}(?:/\d{2,4})?|(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec|January|February|March|April|May|June|July|August|September|October|November|December)\s+\d{1,2}(?:,?\s*\d{2,4})?)"#
            let dateRangeRegexLocal = try! NSRegularExpression(
                pattern: "^\\s*(" + dateTokenLocal + ")(?:\\s*(?:through|to|–|—|-|—)\\s*)(" + dateTokenLocal + ")\\s*$",
                options: [.caseInsensitive]
            )
            for line in lines {
                if let m = dateRangeRegexLocal.firstMatch(in: line, options: [], range: NSRange(location: 0, length: line.utf16.count)) {
                    func group(_ idx: Int) -> String {
                        let r = m.range(at: idx)
                        if let range = Range(r, in: line) { return String(line[range]) }
                        return ""
                    }
                    let a = group(1)
                    let b = group(2)
                    let aComp = extractMonthYear(from: a)
                    let bComp = extractMonthYear(from: b)
                    if let am = aComp.month, let bm = bComp.month {
                        let ay = aComp.year ?? inferredYear ?? Calendar.current.component(.year, from: Date())
                        let by = bComp.year ?? inferredYear ?? Calendar.current.component(.year, from: Date())
                        let period = StatementPeriod(startMonth: am, startYear: ay, endMonth: bm, endYear: by)
                        AMLogging.always("PDF detected statement period: \(a) -> \(b) => start=\(am)/\(ay) end=\(bm)/\(by)", component: "PDFStatementExtractor")
                        return period
                    }
                }
            }
            return nil
        }
        let statementPeriod = detectStatementPeriod(in: lines)

        // Date patterns: numeric and month-name with optional year
        let dateStartPattern = #"^(?:\d{1,2}/\d{1,2}(?:/\d{2,4})?|(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec|January|February|March|April|May|June|July|August|September|October|November|December)\s+\d{1,2}(?:,?\s*\d{2,4})?)"#
        let dateStartRegex = try NSRegularExpression(pattern: dateStartPattern)

        // Money patterns: handle leading/trailing minus, parentheses, optional $ and CR/DR markers
        let moneyCore = #"\d{1,3}(?:,\d{3})*(?:\.\d{2})?"#
        let moneyToken = #"\(?-?\s?\$?"# + moneyCore + #"-?\)?(?:\s*(?:CR|DR|CREDIT|DEBIT))?"#
        let dateToken = #"(?:\d{1,2}/\d{1,2}(?:/\d{2,4})?|(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec|January|February|March|April|May|June|July|August|September|October|November|December)\s+\d{1,2}(?:,?\s*\d{2,4})?)"#

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
            pattern: #"^((?:\d{1,2}/\d{1,2}(?:/\d{2,4})?|(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec|January|February|March|April|May|June|July|August|September|October|November|December)\s+\d{1,2}(?:,?\s*\d{2,4})?))(?:\s+(?:\d{1,2}/\d{1,2}(?:/\d{2,4})?|(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec|January|February|March|April|May|June|July|August|September|October|November|December)\s+\d{1,2}(?:,?\s*\d{2,4})?))?\s+(.*)$"#,
            options: [.caseInsensitive]
        )

        func detectInferredYear(from lines: [String]) -> Int? {
            let yearRegex = try! NSRegularExpression(pattern: #"\b(20\d{2}|19\d{2})\b"#)
            for line in lines {
                if let m = yearRegex.firstMatch(in: line, options: [], range: NSRange(location: 0, length: line.utf16.count)) {
                    if let r = Range(m.range(at: 1), in: line) {
                        return Int(line[r])
                    }
                }
            }
            return nil
        }

        func normalizeDateString(_ s: String, inferredYear: Int?) -> String {
            // If numeric M/d without year, append inferred year or period-derived year
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            let numericNoYear = try! NSRegularExpression(pattern: #"^\d{1,2}/\d{1,2}$"#)
            let monthNoYear = try! NSRegularExpression(pattern: #"^(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec|January|February|March|April|May|June|July|August|September|October|November|December)\s+\d{1,2},?$"#, options: [.caseInsensitive])

            func pickYear(for month: Int) -> Int? {
                if let sp = statementPeriod {
                    if sp.startYear == sp.endYear { return sp.startYear }
                    // Crossing year boundary: months >= startMonth belong to startYear, else endYear
                    if month >= sp.startMonth { return sp.startYear } else { return sp.endYear }
                }
                return inferredYear
            }

            if numericNoYear.firstMatch(in: trimmed, options: [], range: NSRange(location: 0, length: trimmed.utf16.count)) != nil {
                if let compsMonth = Int(trimmed.split(separator: "/")[0]), let y = pickYear(for: compsMonth) {
                    return trimmed + "/" + String(y)
                }
            }
            if monthNoYear.firstMatch(in: trimmed, options: [], range: NSRange(location: 0, length: trimmed.utf16.count)) != nil {
                if let m = monthNumber(from: trimmed), let y = pickYear(for: m) {
                    return trimmed.replacingOccurrences(of: ",", with: "") + ", " + String(y)
                }
            }

            // Try multiple formats and reformat to MM/dd/yyyy
            let fmts = [
                "MM/dd/yyyy", "M/d/yyyy", "MM/dd/yy", "M/d/yy",
                "yyyy-MM-dd", "yyyy/M/d", "yyyy/MM/dd",
                "dd-MMM-yyyy", "d-MMM-yy", "dd MMM yyyy", "d MMM yy",
                "MMM d, yyyy", "MMMM d, yyyy", "MMM d, yy", "MMMM d, yy",
                "MMM d yyyy", "MMMM d yyyy",
            ]
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone(secondsFromGMT: 0)
            for f in fmts {
                df.dateFormat = f
                if let d = df.date(from: trimmed) {
                    df.dateFormat = "MM/dd/yyyy"
                    return df.string(from: d)
                }
            }
            return trimmed
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

        func isPageBreak(_ s: String) -> Bool { s == "<<<PAGE_BREAK>>>" }

        // Additional generic header filters
        let anyDateRegex = try NSRegularExpression(pattern: dateToken, options: [.caseInsensitive])
        let dateRangeRegex = try NSRegularExpression(
            pattern: "^\\s*(" + dateToken + ")(?:\\s*(?:through|to|–|—|-|—)\\s*)(" + dateToken + ")\\s*$",
            options: [.caseInsensitive]
        )
        func isDateRangeLine(_ s: String) -> Bool {
            return dateRangeRegex.firstMatch(in: s, options: [], range: NSRange(location: 0, length: s.utf16.count)) != nil
        }

        func hasMoneyToken(_ s: String) -> Bool {
            return amountAnywhereRegex.firstMatch(in: s, options: [], range: NSRange(location: 0, length: s.utf16.count)) != nil
        }

        // Updated isAccountMetaLine to catch OCR typos and looser meta lines
        func isAccountMetaLine(_ s: String) -> Bool {
            let lower = s.lowercased()
            // Treat both "primary account" and common OCR typo "primary accountant" as meta
            return lower.contains("account number") || lower.contains("account ending") || lower.contains("primary account") || lower.contains("primary accountant")
        }

        // Updated isStatementPeriodLine to catch looser period headers
        func isStatementPeriodLine(_ s: String) -> Bool {
            let lower = s.lowercased()
            if hasMoneyToken(s) { return false }
            if lower.contains("statement period") || lower.contains("statement from") { return true }
            // Heuristic A: lines that contain "through" and begin with a date and contain at least two date tokens
            if lower.contains("through") && isDateStart(s) {
                let count = anyDateRegex.numberOfMatches(in: s, options: [], range: NSRange(location: 0, length: s.utf16.count))
                return count >= 2
            }
            // Heuristic B: lines that contain "through" anywhere and contain at least one date token (to catch variants like "through Jan 20, 2026 ...")
            if lower.contains("through") {
                let count = anyDateRegex.numberOfMatches(in: s, options: [], range: NSRange(location: 0, length: s.utf16.count))
                return count >= 1
            }
            return false
        }
        func isThroughContinuationLine(_ s: String) -> Bool {
            let lower = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if s.contains("$") { return false }
            return lower.hasPrefix("through ")
        }

        func isTotalsOrSectionLine(_ s: String) -> Bool {
            let lower = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if lower.hasPrefix("total ") { return true }
            if lower.contains("total deposits") || lower.contains("total withdrawals") || lower.contains("total electronic withdrawals") || lower.contains("total checks") || lower.contains("total fees") { return true }
            // Also treat lines that are clearly section headers as non-amount sources
            if isDepositsHeader(s) || isWithdrawalsHeader(s) { return true }
            return false
        }

        enum AccountKind { case unknown, checking, savings }
        enum FlowKind { case none, deposit, withdrawal }
        var currentAccount: AccountKind = .unknown
        var currentFlow: FlowKind = .none

        func currentAccountLabel() -> String {
            switch currentAccount {
            case .checking: return "checking"
            case .savings: return "savings"
            case .unknown: return "unknown"
            }
        }

        // Pre-scan pages to infer a default account label per page (checking/savings) from headers
        var pageDefaults: [Int: AccountKind] = [:]
        do {
            var pageIdx = 0
            for l in lines {
                if isPageBreak(l) { pageIdx += 1; continue }
                if pageDefaults[pageIdx] == nil {
                    if isSavingsHeader(l) { pageDefaults[pageIdx] = .savings }
                    else if isCheckingHeader(l) { pageDefaults[pageIdx] = .checking }
                }
            }
        }
        // Track current page during parsing
        var currentPageIndex = 0
        func accountLabelForRow() -> String {
            switch currentAccount {
            case .checking: return "checking"
            case .savings: return "savings"
            case .unknown:
                if let def = pageDefaults[currentPageIndex] {
                    switch def {
                    case .checking: return "checking"
                    case .savings: return "savings"
                    default: break
                    }
                }
                return "unknown"
            }
        }

        // Keep a small buffer of recent non-date lines to infer account context
        var recentContext: [String] = []
        func pushContext(_ s: String) {
            let lower = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !lower.isEmpty else { return }
            recentContext.append(lower)
            if recentContext.count > 12 {
                recentContext.removeFirst(recentContext.count - 12)
            }
        }
        func contextIndicatesSavings() -> Bool {
            let hasSavings = recentContext.contains { $0.contains("savings") }
            let hasChecking = recentContext.contains { $0.contains("checking") }
            return hasSavings && !hasChecking
        }
        func contextIndicatesChecking() -> Bool {
            return recentContext.contains { line in
                let raw = line
                let lower = raw.lowercased()
                if lower.contains("from a checking") || lower.contains("from checking") || lower.contains("transfer") || lower.contains("automatic") {
                    return false
                }
                if lower.contains("checking summary") || lower.hasPrefix("chase checking") { return true }
                let hasDigits = raw.rangeOfCharacter(from: .decimalDigits) != nil
                let hasLowercase = raw.rangeOfCharacter(from: .lowercaseLetters) != nil
                return lower.contains("checking") && !lower.contains("savings") && !hasDigits && (!hasLowercase || raw.count <= 24)
            }
        }

        func isSavingsHeader(_ s: String) -> Bool {
            let raw = s.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = raw.lowercased()
            // Ignore incidental mentions like "from a checking account" that appear on savings pages
            if lower.contains("from a checking") || lower.contains("from checking") || lower.contains("transfer") || lower.contains("automatic") { return false }
            // Strong savings signals
            if lower.contains("savings summary") { return true }
            if lower.hasPrefix("chase savings") { return true }
            if lower.contains("savings account") { return true }
            // Generic header-like: contains 'savings', no digits, and mostly uppercase or short
            let hasDigits = raw.rangeOfCharacter(from: .decimalDigits) != nil
            let hasLowercase = raw.rangeOfCharacter(from: .lowercaseLetters) != nil
            if lower.contains("savings") && !lower.contains("checking") && !hasDigits && (!hasLowercase || raw.count <= 24) {
                return true
            }
            return false
        }
        func isCheckingHeader(_ s: String) -> Bool {
            let raw = s.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = raw.lowercased()
            // Ignore incidental mentions like "from a checking account"
            if lower.contains("from a checking") || lower.contains("from checking") || lower.contains("transfer") || lower.contains("automatic") { return false }
            // Strong checking signals
            if lower.contains("checking summary") { return true }
            if lower.hasPrefix("chase checking") { return true }
            if lower.contains("checking account") {
                if lower.contains("from a checking account") || lower.contains("from checking account") { return false }
                return true
            }
            // Generic header-like: contains 'checking', no digits, and mostly uppercase or short
            let hasDigits = raw.rangeOfCharacter(from: .decimalDigits) != nil
            let hasLowercase = raw.rangeOfCharacter(from: .lowercaseLetters) != nil
            if lower.contains("checking") && !lower.contains("savings") && !hasDigits && (!hasLowercase || raw.count <= 24) {
                return true
            }
            return false
        }
        func isDepositsHeader(_ s: String) -> Bool {
            let lower = s.lowercased()
            return lower.contains("deposits and additions") || lower.contains("deposits") || lower.contains("additions") || lower.contains("credits")
        }
        func isWithdrawalsHeader(_ s: String) -> Bool {
            let lower = s.lowercased()
            return lower.contains("withdrawals") || lower.contains("electronic withdrawals") || lower.contains("checks") || lower.contains("fees") || lower.contains("debits")
        }
        func applySectionSign(amount: String) -> String {
            // Apply sign convention from section headers if present
            var a = amount
            if currentFlow == .withdrawal {
                if !a.hasPrefix("-") { a = "-" + a }
            } else if currentFlow == .deposit {
                if a.hasPrefix("-") { a.removeFirst() }
            }
            return a
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

        // Attempt to reconstruct a multi-line row starting at index `start`.
        // Pattern: first line starts with date and description; subsequent lines that do not start with a date
        // are appended to description until an amount token is found (either on a continuation line or as amount-only line).
        func attemptMultiLineRow(in srcLines: [String], start: Int) -> (row: [String], consumed: Int)? {
            guard start < srcLines.count else { return nil }
            let first = srcLines[start]
            guard let ddMatch = firstMatch(dateAndDescRegex, in: first) else { return nil }

            func groupFrom(_ match: NSTextCheckingResult, in string: String, idx: Int) -> String {
                let r = match.range(at: idx)
                if let range = Range(r, in: string) {
                    return String(string[range]).trimmingCharacters(in: .whitespaces)
                }
                return ""
            }

            let dateRaw = groupFrom(ddMatch, in: first, idx: 1)
            var descParts: [String] = []
            let rest = groupFrom(ddMatch, in: first, idx: 2)
            if !rest.isEmpty { descParts.append(rest) }

            var j = start + 1
            var amountStr: String? = nil
            var balanceStr: String? = nil

            while j < srcLines.count {
                let ln = srcLines[j]
                if isDateStart(ln) { break }

                if isTotalsOrSectionLine(ln) {
                    // Do not use totals/section lines as amount sources; stop multiline reconstruction here
                    break
                }

                // Stop at statement period or account meta lines to avoid absorbing headers into descriptions
                if isStatementPeriodLine(ln) || isThroughContinuationLine(ln) || isAccountMetaLine(ln) {
                    break
                }

                // Amount-only continuation line
                if amountOnlyRegex.firstMatch(in: ln, options: [], range: NSRange(location: 0, length: ln.utf16.count)) != nil {
                    amountStr = sanitizeAmount(ln)
                    j += 1
                    break
                }

                // Amount present anywhere on the line (use the rightmost as amount; the rest contributes to description)
                if let am = amountAnywhereRegex.firstMatch(in: ln, options: [], range: NSRange(location: 0, length: ln.utf16.count)), let ar = Range(am.range, in: ln) {
                    let beforeAmount = String(ln[..<ar.lowerBound])
                    let hasLetters = beforeAmount.rangeOfCharacter(from: .letters) != nil
                    let lowerBefore = beforeAmount.lowercased()
                    // Only accept as amount if the line has no leading words (e.g., just alignment dots/spaces) and is not a totals line
                    if !hasLetters && !lowerBefore.contains("total") {
                        amountStr = sanitizeAmount(String(ln[ar]))
                        let cont = cleanDesc(beforeAmount)
                        if !cont.isEmpty { descParts.append(cont) }
                        j += 1
                        break
                    } else {
                        // Likely a totals or header line; stop multiline reconstruction
                        break
                    }
                }

                // No amount; treat as pure description continuation
                let cont = cleanDesc(ln)
                if !cont.isEmpty { descParts.append(cont) }
                j += 1
            }

            guard let amt = amountStr else { return nil }
            let date = normalizeDateString(dateRaw, inferredYear: inferredYear)
            let desc = cleanDesc(descParts.joined(separator: " "))
            if isSavingsHeader(desc) { currentAccount = .savings }
            return ([date, desc, amt, balanceStr ?? ""], max(1, j - start))
        }

        var rows: [[String]] = []

        var i = 0
        while i < lines.count {
            let line = lines[i]

            if !isDateStart(line) {
                // Page break reset
                if isPageBreak(line) {
                    AMLogging.always("PDF page break — resetting section/account state", component: "PDFStatementExtractor")
                    currentAccount = .unknown
                    currentFlow = .none
                    recentContext.removeAll()
                    currentPageIndex += 1
                    i += 1
                    continue
                }

                pushContext(line)
                // Update section/account state on non-date lines
                if isSavingsHeader(line) { currentAccount = .savings; AMLogging.always("PDF section: SAVINGS detected at line \(i)", component: "PDFStatementExtractor") }
                else if isCheckingHeader(line) { currentAccount = .checking; AMLogging.always("PDF section: CHECKING detected at line \(i)", component: "PDFStatementExtractor") }
                // Account meta lines like "Primary Account: ..." can also indicate checking/savings
                if isAccountMetaLine(line) {
                    let lower = line.lowercased()
                    if lower.contains("savings") { currentAccount = .savings; AMLogging.always("PDF account meta => SAVINGS at line \(i)", component: "PDFStatementExtractor") }
                    else if lower.contains("checking") { currentAccount = .checking; AMLogging.always("PDF account meta => CHECKING at line \(i)", component: "PDFStatementExtractor") }
                }
                if isDepositsHeader(line) { currentFlow = .deposit; AMLogging.always("PDF flow: DEPOSITS detected at line \(i)", component: "PDFStatementExtractor") }
                else if isWithdrawalsHeader(line) { currentFlow = .withdrawal; AMLogging.always("PDF flow: WITHDRAWALS detected at line \(i)", component: "PDFStatementExtractor") }
                i += 1
                continue
            }

            // Skip page/section headers that start with a date but represent a period header (e.g., "Dec 17, 2025 through Jan 20, 2026")
            if isDateRangeLine(line) || isStatementPeriodLine(line) || isAccountMetaLine(line) {
                i += 1
                continue
            }

            // If account not yet determined, infer from recent context buffer
            if currentAccount == .unknown {
                if contextIndicatesSavings() { currentAccount = .savings; AMLogging.always("PDF context => SAVINGS at line \(i)", component: "PDFStatementExtractor") }
                else if contextIndicatesChecking() { currentAccount = .checking; AMLogging.always("PDF context => CHECKING at line \(i)", component: "PDFStatementExtractor") }
            }

            // Try multi-line reconstruction before strict single-line match
            if let multi = attemptMultiLineRow(in: lines, start: i) {
                var row = multi.row
                if row.count >= 3 { row[2] = applySectionSign(amount: row[2]) }
                row.append(accountLabelForRow())
                rows.append(row)
                AMLogging.always("PDF multi-line row matched (\(accountLabelForRow())) at line \(i) consuming \(multi.consumed) lines", component: "PDFStatementExtractor")
                i += multi.consumed
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

                // Prefer second date (post date) if present
                let dateTokenChoice = { () -> String in
                    if let r = Range(match.range(at: 2), in: line), !String(line[r]).trimmingCharacters(in: .whitespaces).isEmpty {
                        return String(line[r])
                    }
                    return dateRaw
                }()
                let date = normalizeDateString(dateTokenChoice, inferredYear: inferredYear)
                let desc = cleanDesc(descRaw)
                // If the description itself indicates Savings in a date-start line, treat it as savings
                if isSavingsHeader(desc) { currentAccount = .savings }
                let amount = applySectionSign(amount: sanitizeAmount(amtRaw))
                let balance = balRaw.isEmpty ? "" : sanitizeAmount(balRaw)
                rows.append([date, desc, amount, balance, accountLabelForRow()])
                AMLogging.always("PDF single-line row matched (\(accountLabelForRow())) at line \(i)", component: "PDFStatementExtractor")
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
                    let date = normalizeDateString(dateRaw, inferredYear: inferredYear)
                    let desc = cleanDesc(descRaw)
                    if isSavingsHeader(desc) { currentAccount = .savings }
                    let amount = applySectionSign(amount: sanitizeAmount(next))
                    rows.append([date, desc, amount, "", accountLabelForRow()]) // no balance captured in this shape
                    AMLogging.always("PDF two-line row matched (\(accountLabelForRow())) at line \(i)", component: "PDFStatementExtractor")
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
                    let date = normalizeDateString(dateRaw, inferredYear: inferredYear)
                    let desc = cleanDesc(descRaw)
                    if isSavingsHeader(desc) { currentAccount = .savings }
                    let amount = applySectionSign(amount: sanitizeAmount(amtRaw))
                    let balance = balRaw.isEmpty ? "" : sanitizeAmount(balRaw)
                    createdAny = true
                    simple.append([date, desc, amount, balance, accountLabelForRow()])
                    AMLogging.always("PDF permissive row matched (\(accountLabelForRow())) at line \(k)", component: "PDFStatementExtractor")
                    k += 1
                    continue
                }

                // Try date + desc + amount on same line (amount anywhere)
                if let dd = firstMatch(dateAndDescRegex, in: ln) {
                    let dr = dd.range(at: 1)
                    let rr = dd.range(at: 2)
                    let dateRaw = (Range(dr, in: ln).map { String(ln[$0]) } ?? "")
                    let rest = (Range(rr, in: ln).map { String(ln[$0]) } ?? "")
                    let date = normalizeDateString(dateRaw, inferredYear: inferredYear)
                    // amount anywhere on same line
                    if let am = amountAnywhereRegex.firstMatch(in: ln, options: [], range: NSRange(location: 0, length: ln.utf16.count)), let ar = Range(am.range, in: ln) {
                        let amount = applySectionSign(amount: sanitizeAmount(String(ln[ar])))
                        let desc = cleanDesc(rest.replacingOccurrences(of: String(ln[ar]), with: ""))
                        if isSavingsHeader(desc) { currentAccount = .savings }
                        createdAny = true
                        simple.append([date, desc, amount, "", accountLabelForRow()]) // no balance in permissive mode
                        AMLogging.always("PDF permissive row matched (\(accountLabelForRow())) at line \(k)", component: "PDFStatementExtractor")
                        k += 1
                        continue
                    }
                    // amount-only next line
                    if k + 1 < lines.count {
                        let nxt = lines[k + 1]
                        if amountOnlyRegex.firstMatch(in: nxt, options: [], range: NSRange(location: 0, length: nxt.utf16.count)) != nil {
                            let amount = applySectionSign(amount: sanitizeAmount(nxt))
                            let desc = cleanDesc(rest)
                            if isSavingsHeader(desc) { currentAccount = .savings }
                            createdAny = true
                            simple.append([date, desc, amount, "", accountLabelForRow()]) // no balance in permissive mode
                            AMLogging.always("PDF permissive row matched (\(accountLabelForRow())) at line \(k)", component: "PDFStatementExtractor")
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

        // OCR fallback: if still too few rows, render pages and use Vision text recognition
        if rows.count < 5 {
            AMLogging.always("PDF rows still low (\(rows.count)) — attempting OCR fallback", component: "PDFStatementExtractor")
            let ocrLines = ocrExtractLines(from: doc, scale: 2.0)
            AMLogging.always("OCR extracted lines: \(ocrLines.count)", component: "PDFStatementExtractor")
            let sample = ocrLines.prefix(10).joined(separator: " | ")
            AMLogging.always("OCR sample: \(sample)", component: "PDFStatementExtractor")
            let ocrRows = parseOCRLines(ocrLines, inferredYear: inferredYear)
            AMLogging.always("OCR matched rows: \(ocrRows.count)", component: "PDFStatementExtractor")
            if !ocrRows.isEmpty {
                rows = ocrRows
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
                        rows.append([earliestStr, "Statement Beginning Balance", "0", b, "unknown"])
                        didAppendSummary = true
                        AMLogging.always("PDF summary: beginning balance detected = \(b) @ \(earliestStr)", component: "PDFStatementExtractor")
                    }
                    if let e = endingAmount {
                        rows.append([latestStr, "Statement Ending Balance", "0", e, "unknown"])
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
        let headers = ["date", "description", "amount", "balance", "account"]

        func renderPageToCGImage(page: PDFPage, scale: CGFloat) -> CGImage? {
            let box = page.bounds(for: .mediaBox)
            let width = Int(box.width * scale)
            let height = Int(box.height * scale)
            guard width > 0 && height > 0 else { return nil }
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let bytesPerPixel = 4
            let bytesPerRow = bytesPerPixel * width
            let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue))
            guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: bitmapInfo.rawValue) else { return nil }
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.saveGState()
            ctx.scaleBy(x: scale, y: scale)
            page.draw(with: .mediaBox, to: ctx)
            ctx.restoreGState()
            return ctx.makeImage()
        }

        func ocrExtractLines(from doc: PDFDocument, scale: CGFloat) -> [String] {
            var results: [String] = []
            for pageIndex in 0..<doc.pageCount {
                guard let page = doc.page(at: pageIndex), let cgImage = renderPageToCGImage(page: page, scale: scale) else { continue }
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.recognitionLanguages = ["en-US"]
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    AMLogging.always("OCR error on page \(pageIndex): \(error)", component: "PDFStatementExtractor")
                    continue
                }
                guard let observations = request.results as? [VNRecognizedTextObservation] else { continue }
                for obs in observations {
                    if let top = obs.topCandidates(1).first {
                        let s = top.string.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !s.isEmpty { results.append(s) }
                    }
                }
                // Insert page break marker between pages
                if pageIndex < doc.pageCount - 1 { results.append("<<<PAGE_BREAK>>>") }
            }
            return results
        }

        func parseOCRLines(_ lines: [String], inferredYear: Int?) -> [[String]] {
            var out: [[String]] = []
            var idx = 0

            // Pre-scan pages for default account labels in OCR lines
            var pageDefaultsOCR: [Int: AccountKind] = [:]
            do {
                var p = 0
                for l in lines {
                    if isPageBreak(l) { p += 1; continue }
                    if pageDefaultsOCR[p] == nil {
                        if isSavingsHeader(l) { pageDefaultsOCR[p] = .savings }
                        else if isCheckingHeader(l) { pageDefaultsOCR[p] = .checking }
                    }
                }
            }
            var currentPageOCR = 0
            func accountLabelForRowOCR() -> String {
                switch currentAccount {
                case .checking: return "checking"
                case .savings: return "savings"
                case .unknown:
                    if let def = pageDefaultsOCR[currentPageOCR] {
                        switch def {
                        case .checking: return "checking"
                        case .savings: return "savings"
                        default: break
                        }
                    }
                    return "unknown"
                }
            }

            while idx < lines.count {
                let ln = lines[idx]

                if isPageBreak(ln) {
                    AMLogging.always("PDF (OCR) page break — resetting section/account state", component: "PDFStatementExtractor")
                    currentAccount = .unknown
                    currentFlow = .none
                    recentContext.removeAll()
                    currentPageOCR += 1
                    idx += 1
                    continue
                }

                if !isDateStart(ln) {
                    pushContext(ln)
                    // Update section/account state for OCR lines on non-date rows
                    if isSavingsHeader(ln) { currentAccount = .savings; AMLogging.always("PDF (OCR) section: SAVINGS detected at line \(idx)", component: "PDFStatementExtractor") }
                    else if isCheckingHeader(ln) { currentAccount = .checking; AMLogging.always("PDF (OCR) section: CHECKING detected at line \(idx)", component: "PDFStatementExtractor") }
                    if isAccountMetaLine(ln) {
                        let lower = ln.lowercased()
                        if lower.contains("savings") { currentAccount = .savings; AMLogging.always("PDF (OCR) account meta => SAVINGS at line \(idx)", component: "PDFStatementExtractor") }
                        else if lower.contains("checking") { currentAccount = .checking; AMLogging.always("PDF (OCR) account meta => CHECKING at line \(idx)", component: "PDFStatementExtractor") }
                    }
                    if isDepositsHeader(ln) { currentFlow = .deposit; AMLogging.always("PDF (OCR) flow: DEPOSITS detected at line \(idx)", component: "PDFStatementExtractor") }
                    else if isWithdrawalsHeader(ln) { currentFlow = .withdrawal; AMLogging.always("PDF (OCR) flow: WITHDRAWALS detected at line \(idx)", component: "PDFStatementExtractor") }
                    idx += 1
                    continue
                }

                // Skip page/section headers that start with a date but represent a period header
                if isDateRangeLine(ln) || isStatementPeriodLine(ln) || isAccountMetaLine(ln) {
                    idx += 1
                    continue
                }

                // Infer account from recent context if unknown
                if currentAccount == .unknown {
                    if contextIndicatesSavings() { currentAccount = .savings; AMLogging.always("PDF (OCR) context => SAVINGS at line \(idx)", component: "PDFStatementExtractor") }
                    else if contextIndicatesChecking() { currentAccount = .checking; AMLogging.always("PDF (OCR) context => CHECKING at line \(idx)", component: "PDFStatementExtractor") }
                }

                // Prefer multi-line reconstruction in OCR too
                if let multi = attemptMultiLineRow(in: lines, start: idx) {
                    var r = multi.row
                    if r.count >= 3 { r[2] = applySectionSign(amount: r[2]) }
                    r.append(accountLabelForRowOCR())
                    out.append(r)
                    idx += multi.consumed
                    continue
                }

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

                    // Prefer second date (post date) if present
                    let dateTokenChoice = { () -> String in
                        if let r = Range(match.range(at: 2), in: ln), !String(ln[r]).trimmingCharacters(in: .whitespaces).isEmpty {
                            return String(ln[r])
                        }
                        return dateRaw
                    }()
                    let date = normalizeDateString(dateTokenChoice, inferredYear: inferredYear)
                    let desc = cleanDesc(descRaw)
                    if isSavingsHeader(desc) { currentAccount = .savings }
                    let amount = applySectionSign(amount: sanitizeAmount(amtRaw))
                    let balance = balRaw.isEmpty ? "" : sanitizeAmount(balRaw)
                    out.append([date, desc, amount, balance, accountLabelForRowOCR()])
                    idx += 1
                    continue
                }

                // Fallback: date+desc with amount anywhere on line or next line amount-only
                if let dd = firstMatch(dateAndDescRegex, in: ln) {
                    let dr = dd.range(at: 1)
                    let rr = dd.range(at: 2)
                    let dateRaw = (Range(dr, in: ln).map { String(ln[$0]) } ?? "")
                    let rest = (Range(rr, in: ln).map { String(ln[$0]) } ?? "")
                    let date = normalizeDateString(dateRaw, inferredYear: inferredYear)
                    if let am = amountAnywhereRegex.firstMatch(in: ln, options: [], range: NSRange(location: 0, length: ln.utf16.count)), let ar = Range(am.range, in: ln) {
                        let amount = applySectionSign(amount: sanitizeAmount(String(ln[ar])))
                        let desc = cleanDesc(rest.replacingOccurrences(of: String(ln[ar]), with: ""))
                        if isSavingsHeader(desc) { currentAccount = .savings }
                        out.append([date, desc, amount, "", accountLabelForRowOCR()]) ; idx += 1 ; continue
                    }
                    if idx + 1 < lines.count {
                        let nxt = lines[idx + 1]
                        if amountOnlyRegex.firstMatch(in: nxt, options: [], range: NSRange(location: 0, length: nxt.utf16.count)) != nil {
                            let amount = applySectionSign(amount: sanitizeAmount(nxt))
                            let desc = cleanDesc(rest)
                            if isSavingsHeader(desc) { currentAccount = .savings }
                            out.append([date, desc, amount, "", accountLabelForRowOCR()]) ; idx += 2 ; continue
                        }
                    }
                }

                idx += 1
            }
            return out
        }

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

