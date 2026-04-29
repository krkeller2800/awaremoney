import Foundation
import UniformTypeIdentifiers

#if canImport(PDFKit)
import PDFKit
#endif

public struct IntakeDetection: Sendable {
    public var type: StatementType?
    public var institution: String?
    public var confidence: Double
    public var notes: [String]

    public init(type: StatementType?, institution: String?, confidence: Double, notes: [String] = []) {
        self.type = type
        self.institution = institution
        self.confidence = confidence
        self.notes = notes
    }
}

public protocol StatementIntakeClassifying {
    func classify(url: URL) async -> IntakeDetection
}

/// A lightweight, fast classifier that makes best-effort guesses based on file name and extension.
/// This is a stub; later we can augment with header parsing and OFX/QFX token detection.
public final class StatementIntakeClassifier: StatementIntakeClassifying {
    public init() {}

    public func classify(url: URL) async -> IntakeDetection {
        let file = url.lastPathComponent
        let lower = file.lowercased()
        let ext = url.pathExtension.lowercased()

        // Extension hints
        if ext == "pdf" {
            // Use filename tokens to guess PDF statement type
            var type = guessTypeFromFilename(lower)
            var inst = guessInstitution(from: file)
            var notes: [String] = []
            var pdfHeader: (headerLines: [String], normalizedHeader: String)? = nil

            // Fallback: if institution or type not found from filename, try scanning PDF text
            if inst == nil || type == nil {
                if pdfHeader == nil {
                    #if canImport(PDFKit)
                    pdfHeader = extractPDFHeaderText(at: url)
                    #else
                    pdfHeader = nil
                    #endif
                }
            }
            if inst == nil, let ctx = pdfHeader {
                if let pdfInst = detectInstitutionInPDF(headerLines: ctx.headerLines, normalizedHeader: ctx.normalizedHeader) {
                    inst = pdfInst
                    notes.append("institution-detected-from-pdf-text")
                }
            }
            if type == nil, let ctx = pdfHeader {
                if let pdfType = detectTypeInPDF(headerLines: ctx.headerLines, normalizedHeader: ctx.normalizedHeader) {
                    type = pdfType
                    notes.append("type-detected-from-pdf-text")
                }
            }

            AMLogging.log("IntakeClassifier(pdf): file=\(file) type=\(String(describing: type)) inst=\(inst ?? "nil")", component: "Intake")
            let confidence: Double
            if inst != nil {
                // We found an institution (either from filename or PDF), bump confidence a bit
                confidence = (type == nil) ? 0.5 : 0.75
            } else {
                confidence = (type == nil) ? 0.3 : 0.6
            }
            return IntakeDetection(type: type, institution: inst, confidence: confidence, notes: notes)
        } else if ["qfx","ofx","qbo"].contains(ext) {
            // OFX/QFX/QBO => usually transactions for bank/credit card; prefer bank unless CC tokens present
            let ccBias = containsAny(lower, ["amex","americanexpress","discover","capitalone","citi","chase"]) 
            let type: StatementType = ccBias ? .creditCard : .bank
            let inst = guessInstitution(from: file)
            AMLogging.log("IntakeClassifier(ofx-like): file=\(file) type=\(type) inst=\(inst ?? "nil")", component: "Intake")
            return IntakeDetection(type: type, institution: inst, confidence: 0.7)
        } else if ["csv","tsv","txt","xlsx","xls","qif","zip"].contains(ext) {
            // Generic data; infer from tokens
            let type = guessTypeFromFilename(lower)
            let inst = guessInstitution(from: file)
            AMLogging.log("IntakeClassifier(data): file=\(file) type=\(String(describing: type)) inst=\(inst ?? "nil")", component: "Intake")
            return IntakeDetection(type: type, institution: inst, confidence: type == nil ? 0.35 : 0.6)
        } else {
            let type = guessTypeFromFilename(lower)
            let inst = guessInstitution(from: file)
            AMLogging.log("IntakeClassifier(other): file=\(file) type=\(String(describing: type)) inst=\(inst ?? "nil")", component: "Intake")
            return IntakeDetection(type: type, institution: inst, confidence: type == nil ? 0.25 : 0.5)
        }
    }

    private func guessTypeFromFilename(_ lower: String) -> StatementType? {
        // Prefer the most common account types first: credit card > bank > loan > brokerage
        if containsAny(lower, ["creditcard","credit-card","cardmember","visa","mastercard"]) {
            return .creditCard
        }
        if containsAny(lower, ["checking","savings","depositaccount"]) {
            return .bank
        }
        if containsAny(lower, ["loan","mortgage","studentloan","autoloan","homeloan","personalloan"]) {
            return .loan
        }
        if containsAny(lower, ["brokerage","invest","investment"]) {
            return .brokerage
        }
        return nil
    }

    private func containsAny(_ s: String, _ tokens: [String]) -> Bool {
        for t in tokens { if s.contains(t) { return true } }
        return false
    }

    private func normalizedToken(_ s: String) -> String {
        return s.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
    }

    private func guessInstitution(from fileName: String) -> String? {
        // Mirror the app's existing heuristics; keep minimal here and expand later.
        let base = (fileName as NSString).deletingPathExtension
        let lower = base.lowercased()
        let normalized = lower.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
        let known = knownInstitutions()
        return known.first(where: { normalized.contains($0.0) })?.1
    }

    private func knownInstitutions() -> [(String, String)] {
        return [
            ("americanexpress", "American Express"),
            ("amex", "American Express"),
            ("bankofamerica", "Bank of America"),
            ("boa", "Bank of America"),
            ("wellsfargo", "Wells Fargo"),
            ("capitalone", "Capital One"),
            ("capone", "Capital One"),
            ("charlesschwab", "Charles Schwab"),
            ("schwab", "Charles Schwab"),
            ("fidelity", "Fidelity"),
            ("vanguard", "Vanguard"),
            ("robinhood", "Robinhood"),
            ("amazon", "Amazon"),
            ("amazonvisa", "Amazon"),
            ("amazonrewards", "Amazon"),
            ("primevisa", "Amazon"),
            ("synchrony", "Synchrony"),
            ("discover", "Discover"),
            ("citibank", "Citi"),
            ("citi", "Citi"),
            ("chase", "Chase"),
            ("sofi", "SoFi")
        ]
    }

    private func titleTokensNormalized() -> [String] {
        // Tokens that commonly appear in headings/titles on financial statements
        return [
            "statement",
            "monthlystatement",
            "billingstatement",
            "billing",
            "accountsummary",
            "creditcard",
            "cardmember",
            "brokerage",
            "investment",
            "mortgage",
            "loan",
            "checking",
            "savings",
            "visa",
            "mastercard"
        ]
    }

    private func institutionAuxContextTokensNormalized() -> [String] {
        // Additional context tokens that often appear near institution names in headers/contact info
        // (normalized: lowercase, no spaces/dashes/underscores)
        return [
            "bank",
            "memberfdic",
            "n.a.",
            "na",
            "www",
            "com"
        ]
    }

    private func strongInstitutionPhrasesNormalized() -> [(String, String)] {
        // Aggressively normalized (no spaces, dashes, underscores, commas, or periods; lowercase)
        // Use for exact-phrase strong signals in headers/contact blocks
        return [
            ("sofibankna", "SoFi"),
            ("wwwsoficom", "SoFi")
        ]
    }

    private func creditCardSummaryTokensNormalized() -> [String] {
        // Common summary headers on credit card statements (normalized: no spaces/dashes/underscores, lowercase)
        return [
            "availablecredit",
            "minimumpaymentdue",
            "newbalance",
            "paymentduedate",
            "pastdue",
            "previousbalance",
            "statementclosingdate",
            "closingdate"
        ]
    }

    private func isLikelyTransactionLine(_ line: String) -> Bool {
        let raw = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return false }

        // If the line looks like a header/title, do not treat it as a transaction
        let norm = normalizedToken(raw)
        for t in titleTokensNormalized() { if norm.contains(t) { return false } }

        // Preserve common credit card summary headers; do not treat them as transactions
        for s in creditCardSummaryTokensNormalized() { if norm.contains(s) { return false } }

        let lower = raw.lowercased()

        // Common transaction keywords
        let keywords = [
            "purchase", "payment", "authorization", "authorized", "posted", "posting",
            "transaction", "activity", "merchant", "reference", "category", "balance",
            "interest", "fee", "charge", "credit", "debit", "withdrawal", "deposit",
            "ach", "check", "pos", "atm", "autopay", "automatic payment", "zelle"
        ]

        let hasCurrencyAmount = lower.range(of: "(\\$|usd|eur|£|€)\\s?\\d{1,3}(,\\d{3})*(\\.\\d{1,2})?", options: .regularExpression) != nil
        let hasPlainAmount = lower.range(of: "\\b-?\\d+\\.\\d{1,2}\\b", options: .regularExpression) != nil
        let hasParenAmount = lower.range(of: "\\(\\$?\\d{1,3}(,\\d{3})*(\\.\\d{1,2})?\\)", options: .regularExpression) != nil

        // Detect lines that contain two amounts (e.g., amount + running balance)
        let hasTwoCurrencyAmounts = lower.range(of: "(\\$|usd|eur|£|€)\\s?\\d{1,3}(,\\d{3})*(\\.\\d{1,2})?.*(\\$|usd|eur|£|€)\\s?\\d{1,3}(,\\d{3})*(\\.\\d{1,2})?", options: .regularExpression) != nil
        let hasTwoPlainAmounts = lower.range(of: "\\d+\\.\\d{1,2}.*\\d+\\.\\d{1,2}", options: .regularExpression) != nil
        let hasTwoAmounts = hasTwoCurrencyAmounts || hasTwoPlainAmounts || (hasCurrencyAmount && hasPlainAmount)
        if hasTwoAmounts { return true }

        // Heuristic: if a line has both a date and an amount, it's very likely a transaction row
        let hasNumericDate = lower.range(of: "\\b(0?[1-9]|1[0-2])[\\/\\-](0?[1-9]|[12][0-9]|3[01])[\\/\\-](\\d{2}|\\d{4})\\b", options: .regularExpression) != nil
        let hasMonthNameDate = lower.range(of: "\\b(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\\s+\\d{1,2}(,\\s*\\d{2,4})?\\b", options: .regularExpression) != nil

        // Lines with a date and a transaction keyword are very likely transaction descriptors
        if (hasNumericDate || hasMonthNameDate) && keywords.contains(where: { lower.contains($0) }) {
            return true
        }

        if (hasCurrencyAmount || hasPlainAmount || hasParenAmount) && keywords.contains(where: { lower.contains($0) }) {
            return true
        }

        return false
    }

    private func containsAnyAmount(_ s: String) -> Bool {
        let lower = s.lowercased()
        let currency = "(\\$|usd|eur|£|€)\\s?\\d{1,3}(,\\d{3})*(\\.\\d{1,2})?"
        let plain = "\\b-?\\d+\\.\\d{1,2}\\b"
        let paren = "\\(\\$?\\d{1,3}(,\\d{3})*(\\.\\d{1,2})?\\)"
        return lower.range(of: currency, options: .regularExpression) != nil ||
               lower.range(of: plain, options: .regularExpression) != nil ||
               lower.range(of: paren, options: .regularExpression) != nil
    }

    private func isAmountOnlyLine(_ line: String) -> Bool {
        let raw = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return false }
        // No letters but contains an amount pattern => likely a transaction amount/balance line
        let hasLetters = raw.range(of: "[A-Za-z]", options: .regularExpression) != nil
        return !hasLetters && containsAnyAmount(raw)
    }

    private func hasTransactionKeyword(_ lower: String) -> Bool {
        let keywords = [
            "purchase", "payment", "authorization", "authorized", "posted", "posting",
            "transaction", "activity", "merchant", "reference", "category", "balance",
            "interest", "fee", "charge", "credit", "debit", "withdrawal", "deposit",
            "ach", "check", "pos", "atm", "autopay", "automatic payment", "zelle"
        ]
        return keywords.contains(where: { lower.contains($0) })
    }

    private func isInstitutionContextPresent(needle: String, lines: [String], normalizedText: String) -> Bool {
        let titles = titleTokensNormalized()
        let aux = institutionAuxContextTokensNormalized()
        let maxHeaderLines = 120

        // Check first N lines for a line containing the institution along with a title token
        let limit = min(lines.count, maxHeaderLines)
        if limit > 0 {
            for i in 0..<limit {
                let lnNorm = normalizedToken(lines[i])
                if lnNorm.contains(needle) {
                    // Same line contains a title or auxiliary context token
                    for token in titles { if lnNorm.contains(token) { return true } }
                    for token in aux { if lnNorm.contains(token) { return true } }
                    // Or one of the next two lines contains a title or auxiliary context token
                    if i + 1 < lines.count {
                        let next1 = normalizedToken(lines[i+1])
                        for token in titles { if next1.contains(token) { return true } }
                        for token in aux { if next1.contains(token) { return true } }
                    }
                    if i + 2 < lines.count {
                        let next2 = normalizedToken(lines[i+2])
                        for token in titles { if next2.contains(token) { return true } }
                        for token in aux { if next2.contains(token) { return true } }
                    }
                }
            }
        }

        // Proximity window anywhere in the text: institution near a title token within +/- 120 chars
        if let r = normalizedText.range(of: needle) {
            let windowRadius = 120
            let start = normalizedText.index(r.lowerBound, offsetBy: -windowRadius, limitedBy: normalizedText.startIndex) ?? normalizedText.startIndex
            let end = normalizedText.index(r.upperBound, offsetBy: windowRadius, limitedBy: normalizedText.endIndex) ?? normalizedText.endIndex
            let window = String(normalizedText[start..<end])
            for token in titles { if window.contains(token) { return true } }
            for token in aux { if window.contains(token) { return true } }
        }

        return false
    }

    private func isTypeContextPresent(needle: String, lines: [String]) -> Bool {
        let titles = titleTokensNormalized()
        let maxHeaderLines = 120
        let limit = min(lines.count, maxHeaderLines)
        if limit > 0 {
            for i in 0..<limit {
                let lnNorm = normalizedToken(lines[i])
                if lnNorm.contains(needle) {
                    // Same line contains a title token
                    for token in titles { if lnNorm.contains(token) { return true } }
                    // Or one of the next two lines contains a title token
                    if i + 1 < lines.count {
                        let next1 = normalizedToken(lines[i+1])
                        for token in titles { if next1.contains(token) { return true } }
                    }
                    if i + 2 < lines.count {
                        let next2 = normalizedToken(lines[i+2])
                        for token in titles { if next2.contains(token) { return true } }
                    }
                }
            }
        }
        return false
    }

    private func isCCSummaryContextPresent(lines: [String]) -> Bool {
        let titles = titleTokensNormalized()
        let summaries = creditCardSummaryTokensNormalized()
        let maxHeaderLines = 120
        let limit = min(lines.count, maxHeaderLines)
        if limit > 0 {
            for i in 0..<limit {
                let lnNorm = normalizedToken(lines[i])
                // Also check concatenation with next lines to handle split phrases across lines
                var combined1 = lnNorm
                if i + 1 < lines.count { combined1 = normalizedToken(lines[i] + lines[i+1]) }
                var combined2 = combined1
                if i + 2 < lines.count { combined2 = normalizedToken(lines[i] + lines[i+1] + lines[i+2]) }

                // If a line contains a summary token, require a title token on same or nearby lines
                if summaries.contains(where: { lnNorm.contains($0) || combined1.contains($0) || combined2.contains($0) }) {
                    // Same line contains a title token
                    for token in titles { if lnNorm.contains(token) { return true } }
                    // Or one of the next two lines contains a title token
                    if i + 1 < lines.count {
                        let next1 = normalizedToken(lines[i+1])
                        for token in titles { if next1.contains(token) { return true } }
                    }
                    if i + 2 < lines.count {
                        let next2 = normalizedToken(lines[i+2])
                        for token in titles { if next2.contains(token) { return true } }
                    }
                }
            }
        }
        return false
    }

    private func countOccurrences(in text: String, of needle: String) -> Int {
        if needle.isEmpty { return 0 }
        var count = 0
        var searchRange: Range<String.Index>? = text.startIndex..<text.endIndex
        while let range = text.range(of: needle, options: [], range: searchRange) {
            count += 1
            searchRange = range.upperBound..<text.endIndex
        }
        return count
    }

    private func hasLineWithAuxContext(needle: String, lines: [String]) -> Bool {
        let aux = institutionAuxContextTokensNormalized()
        for line in lines {
            let lnNorm = normalizedToken(line)
            if lnNorm.contains(needle) {
                for token in aux { if lnNorm.contains(token) { return true } }
            }
        }
        return false
    }

    #if canImport(PDFKit)
    private func detectInstitutionInPDF(at url: URL) -> String? {
        guard let ctx = extractPDFHeaderText(at: url) else { return nil }
        return detectInstitutionInPDF(headerLines: ctx.headerLines, normalizedHeader: ctx.normalizedHeader)
    }

    private func extractPDFHeaderText(at url: URL) -> (headerLines: [String], normalizedHeader: String)? {
        guard let doc = PDFDocument(url: url) else { return nil }
        let pageCount = min(doc.pageCount, 3)
        var aggregated = ""
        for i in 0..<pageCount {
            guard let page = doc.page(at: i) else { continue }
            if let s = page.attributedString?.string, !s.isEmpty {
                aggregated += s + "\n"
            } else if let s = page.string {
                aggregated += s + "\n"
            }
            if aggregated.count > 20_000 { break }
        }
        if aggregated.isEmpty { return nil }
        let lines = aggregated.components(separatedBy: .newlines)
        var txnFlags = lines.map { isLikelyTransactionLine($0) }
        // Propagate transaction flag to neighboring amount-only lines (e.g., amount on its own line)
        if !txnFlags.isEmpty {
            for i in 0..<txnFlags.count {
                if !txnFlags[i] && isAmountOnlyLine(lines[i]) {
                    let prevIsTxn = (i > 0) ? txnFlags[i-1] : false
                    let nextIsTxn = (i + 1 < txnFlags.count) ? txnFlags[i+1] : false
                    if prevIsTxn || nextIsTxn { txnFlags[i] = true }
                }
            }
        }

        // Propagate transaction flag to descriptor lines that contain transaction keywords when adjacent to amount lines or existing txn lines
        if !txnFlags.isEmpty {
            for i in 0..<txnFlags.count {
                if !txnFlags[i] {
                    let lower = lines[i].lowercased()
                    if hasTransactionKeyword(lower) {
                        let prevHasAmount = (i > 0) ? containsAnyAmount(lines[i-1]) : false
                        let nextHasAmount = (i + 1 < lines.count) ? containsAnyAmount(lines[i+1]) : false
                        let prevIsTxn = (i > 0) ? txnFlags[i-1] : false
                        let nextIsTxn = (i + 1 < txnFlags.count) ? txnFlags[i+1] : false
                        if prevHasAmount || nextHasAmount || prevIsTxn || nextIsTxn {
                            txnFlags[i] = true
                        }
                    }
                }
            }
        }

        // Preserve lines that contribute to credit card summary phrases split across adjacent lines
        let summaries = creditCardSummaryTokensNormalized()
        if !lines.isEmpty {
            for i in 0..<lines.count {
                var combined1 = normalizedToken(lines[i])
                if i + 1 < lines.count { combined1 = normalizedToken(lines[i] + lines[i+1]) }
                var combined2 = combined1
                if i + 2 < lines.count { combined2 = normalizedToken(lines[i] + lines[i+1] + lines[i+2]) }
                if summaries.contains(where: { combined1.contains($0) || combined2.contains($0) }) {
                    // Unflag current and adjacent lines to keep them in header region
                    txnFlags[i] = false
                    if i + 1 < txnFlags.count { txnFlags[i+1] = false }
                    if i + 2 < txnFlags.count { txnFlags[i+2] = false }
                }
            }
        }

        let headerLines = (0..<lines.count).compactMap { txnFlags[$0] ? nil : lines[$0] }
        let normalizedHeader = normalizedToken(headerLines.joined(separator: "\n"))
        return (headerLines, normalizedHeader)
    }

    private func detectInstitutionInPDF(headerLines: [String], normalizedHeader: String) -> String? {
        // Strong phrase check (aggressive normalization): exact phrases that strongly indicate an institution
        let normalizedAggressive = normalizedHeader
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: ",", with: "")
        for (needle, display) in strongInstitutionPhrasesNormalized() {
            if normalizedAggressive.contains(needle) {
                return display
            }
        }

        var bestDisplay: String? = nil
        var bestScore = Int.min

        // Aggressively normalized text to detect phrases like 'division of <bank>' or 'issued by <bank>'
        let normalizedAggressive2 = normalizedHeader
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")

        for (needle, display) in knownInstitutions() {
            if normalizedHeader.contains(needle) && isInstitutionContextPresent(needle: needle, lines: headerLines, normalizedText: normalizedHeader) {
                var score = 0
                // Base on frequency
                score += countOccurrences(in: normalizedHeader, of: needle) * 10
                // Bonus if appears on a line with aux header/contact context
                if hasLineWithAuxContext(needle: needle, lines: headerLines) { score += 5 }

                // Special-case Discover: require the registered trademark symbol and boost when present
                if needle == "discover" {
                    if normalizedHeader.contains("discover®") {
                        score += 30
                    } else {
                        continue
                    }
                }

                // Penalize negative contexts for other institutions (e.g., 'a division of Capital One')
                if normalizedAggressive2.contains("divisionof" + needle) { score -= 20 }
                if normalizedAggressive2.contains("affiliateof" + needle) { score -= 12 }
                // Boost when the institution appears in 'issued by <institution>' context
                if normalizedAggressive2.contains("issuedby" + needle) { score += 8 }

                if score > bestScore {
                    bestScore = score
                    bestDisplay = display
                }
            }
        }
        return bestDisplay
    }

    private func knownTypeTokens() -> [(String, StatementType)] {
        return [
            // Credit card (generic/network/role terms only) — highest priority
            ("creditcard", .creditCard),
            ("credit-card", .creditCard),
            ("cardmember", .creditCard),
            ("cardaccount", .creditCard),
            ("visa", .creditCard),
            ("mastercard", .creditCard),

            // Bank/deposit accounts (generic)
            ("checking", .bank),
            ("savings", .bank),
            ("depositaccount", .bank),

            // Loans (generic)
            ("loan", .loan),
            ("mortgage", .loan),
            ("studentloan", .loan),
            ("autoloan", .loan),
            ("homeloan", .loan),
            ("personalloan", .loan),

            // Brokerage/investment (generic) — lowest priority
            ("brokerage", .brokerage),
            ("investment", .brokerage),
            ("investmentaccount", .brokerage)
        ]
    }

    private func detectTypeInPDF(headerLines: [String], normalizedHeader: String) -> StatementType? {
        for (needle, t) in knownTypeTokens() {
            if normalizedHeader.contains(needle) && isTypeContextPresent(needle: needle, lines: headerLines) {
                return t
            }
        }
        // Weak CC signal: summary headers near titles in the header region
        if isCCSummaryContextPresent(lines: headerLines) {
            return .creditCard
        }
        return nil
    }
    #else
    private func detectInstitutionInPDF(at url: URL) -> String? { nil }
    #endif
}
