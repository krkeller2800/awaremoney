//
//  ImportViewModel.swift
//  awaremoney
//
//  Created by Karl Keller on 1/23/26.
//

import Foundation
import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import Combine
import PDFKit

@MainActor
final class ImportViewModel: ObservableObject {
    @Published var staged: StagedImport?
    @Published var errorMessage: String?
    @Published var selectedAccountID: UUID?
    @Published var newAccountName: String = ""
    @Published var newAccountType: Account.AccountType = .checking
    @Published var userInstitutionName: String = ""
    @Published var mappingSession: MappingSession? // non-nil when user needs to map columns
    @Published var infoMessage: String?
    @Published var isImporting: Bool = false
    @Published var userSelectedDocHint: Account.AccountType? = nil
    @Published var creditCardFlipOverride: Bool? = nil
    @Published var lastPickedLocalURL: URL? = nil

    // Captured from pre-parse scan of statement rows: normalized label -> typical payment amount
    private var detectedTypicalPaymentByLabel: [String: Decimal] = [:]

    private let importer = StatementImporter()

    private let parsers: [StatementParser]

    static func defaultParsers() -> [StatementParser] {
        return [
            PDFSummaryParser(),
            PDFBankTransactionsParser(),
            BankCSVParser(),
            BrokerageCSVParser(),
            FidelityStatementCSVParser(),
            GenericHoldingsStatementCSVParser()
        ]
    }

    private static func extractAPRFromPDF(at url: URL) -> (Decimal, Int)? {
        AMLogging.always("ImportViewModel: extractAPRFromPDF start url=\(url.lastPathComponent)", component: "ImportViewModel")
        guard let doc = PDFDocument(url: url) else { return nil }
        let pageCount = doc.pageCount
        AMLogging.always("ImportViewModel: PDF pageCount=\(pageCount)", component: "ImportViewModel")

        // Combine first few pages to avoid early false positives and allow context filtering
        let pagesToScan = pageCount
        var combined = ""
        for i in 0..<pagesToScan {
            if let page = doc.page(at: i), let s = page.string { combined.append("\n"); combined.append(s) }
        }
        let lowerText = combined.lowercased()

        func computeScale(_ token: String) -> Int {
            if let dot = token.firstIndex(of: ".") {
                return token.distance(from: token.index(after: dot), to: token.endIndex)
            }
            return 0
        }

        // Require a percent sign to avoid matching dollar amounts
        let aprNumber = "([0-9]{1,2}(?:\\.[0-9]{1,4})?)\\s*%"

        // Helper to get the first percentage number in a string as a fraction APR (0.2324) with scale
        func firstPercent(in s: String) -> (Decimal, Int)? {
            guard let re = try? NSRegularExpression(pattern: aprNumber, options: []) else { return nil }
            let ns = s as NSString
            let range = NSRange(location: 0, length: ns.length)
            guard let m = re.firstMatch(in: s, options: [], range: range), m.numberOfRanges >= 2 else { return nil }
            let r = m.range(at: 1)
            guard r.location != NSNotFound, let swift = Range(r, in: s) else { return nil }
            let token = String(s[swift])
            if var val = Decimal(string: token) {
                let scale = computeScale(token)
                if val > 1 { val /= 100 }
                AMLogging.always("ImportViewModel: APR percent line match token=\(token) fraction=\(val) scale=\(scale)", component: "ImportViewModel")
                return (val, scale)
            }
            return nil
        }

        // 0) Table-aware pass: detect an APR table header (e.g., "Type of Balance" + "APR" or the "Interest Charge Calculation" section)
        let lines = lowerText.components(separatedBy: CharacterSet.newlines)
        var headerIndex: Int? = nil
        for (i, line) in lines.enumerated() {
            if line.contains("type of balance") && line.contains("apr") { headerIndex = i; break }
            if headerIndex == nil && line.contains("interest charge calculation") { headerIndex = i }
        }
        if let idx = headerIndex {
            AMLogging.always("ImportViewModel: APR table header detected at line \(idx)", component: "ImportViewModel")
            let end = min(lines.count, idx + 120)
            // Prefer purchases row; allow percent to be on adjacent lines/columns
            for j in (idx+1)..<end {
                let line = lines[j]
                if line.contains("purchases") {
                    if let hit = firstPercent(in: line) { return hit }
                    // look ahead a few lines for the percent token (table column)
                    let lookaheadEnd = min(end, j + 8)
                    for k in (j+1)..<lookaheadEnd {
                        if let hit = firstPercent(in: lines[k]) { return hit }
                    }
                }
            }
            // Fallback: cash advances row with adjacent percent
            for j in (idx+1)..<end {
                let line = lines[j]
                if line.contains("cash advance") {
                    if let hit = firstPercent(in: line) { return hit }
                    let lookaheadEnd = min(end, j + 8)
                    for k in (j+1)..<lookaheadEnd {
                        if let hit = firstPercent(in: lines[k]) { return hit }
                    }
                }
            }
        }

        // 1) Non-table direct line: any line containing "purchases" with a percent
        for line in lines {
            if line.contains("purchases"), let hit = firstPercent(in: line) { return hit }
        }

        // 2) Prefer Purchases APR where the token "apr" appears near the number (some layouts)
        func firstAPRMatch(pattern: String) -> (Decimal, Int)? {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            let range = NSRange(location: 0, length: (lowerText as NSString).length)
            guard let m = re.firstMatch(in: lowerText, options: [], range: range) else { return nil }
            guard m.numberOfRanges >= 2 else { return nil }
            let r = m.range(at: 1)
            guard r.location != NSNotFound, let swiftRange = Range(r, in: lowerText) else { return nil }
            let token = String(lowerText[swiftRange]).replacingOccurrences(of: "%", with: "")
            if var val = Decimal(string: token) {
                let scale = computeScale(token)
                if val > 1 { val /= 100 }
                AMLogging.always("ImportViewModel: APR match (pattern) token=\(token) fraction=\(val) scale=\(scale)", component: "ImportViewModel")
                return (val, scale)
            }
            return nil
        }

        let purchasesPatterns = [
            "(?:standard\\s+)?purchases?\\s*apr[^0-9%]{0,32}" + aprNumber,
            "purchases?[^\\n\\r]{0,40}?apr[^0-9%]{0,32}" + aprNumber
        ]
        for pat in purchasesPatterns { if let hit = firstAPRMatch(pattern: pat) { return hit } }

        // Looser cross-line match: a 'purchases' token followed by a percentage within ~80 chars (across line breaks)
        let purchasesLoosePattern = "(?:purchases?|purchase)[\\s\\S]{0,80}?" + aprNumber
        if let hit = firstAPRMatch(pattern: purchasesLoosePattern) { return hit }

        // 3) Consider labeled APRs (Purchases or Cash Advances); choose Purchases if both present
        let labeledPattern = "(?:purchases?|cash\\s+advances?)\\s*apr[^0-9%]{0,32}" + aprNumber
        if let re = try? NSRegularExpression(pattern: labeledPattern, options: [.caseInsensitive]) {
            let ns = lowerText as NSString
            let range = NSRange(location: 0, length: ns.length)
            let matches = re.matches(in: lowerText, options: [], range: range)
            var best: (val: Decimal, scale: Int, labelScore: Int)? = nil
            for m in matches {
                guard m.numberOfRanges >= 2 else { continue }
                let numRange = m.range(at: 1)
                guard numRange.location != NSNotFound, let swiftRange = Range(numRange, in: lowerText) else { continue }
                let token = String(lowerText[swiftRange]).replacingOccurrences(of: "%", with: "")
                guard var v = Decimal(string: token) else { continue }
                let scale = computeScale(token)
                if v > 1 { v /= 100 }
                let fullRange = Range(m.range, in: lowerText)!
                let lineRange = (lowerText as NSString).lineRange(for: NSRange(fullRange, in: lowerText))
                let line = (lowerText as NSString).substring(with: lineRange)
                let score: Int = line.contains("purchases") ? 2 : (line.contains("cash advance") ? 1 : 0)
                if best == nil || score > best!.labelScore { best = (v, scale, score) }
            }
            if let b = best { return (b.val, b.scale) }
        }

        // 4) Generic APR mention with required percent sign; filter out disclaimers like "will not exceed"
        let genericAPRPattern = "(?:(?:annual\\s+percentage\\s+rate\\s*\\(apr\\))|apr)[^0-9%]{0,64}" + aprNumber
        if let re = try? NSRegularExpression(pattern: genericAPRPattern, options: [.caseInsensitive]) {
            let ns = lowerText as NSString
            let range = NSRange(location: 0, length: ns.length)
            let matches = re.matches(in: lowerText, options: [], range: range)
            for m in matches {
                let fullRange = Range(m.range, in: lowerText)!
                let lineRange = ns.lineRange(for: NSRange(fullRange, in: lowerText))
                let line = ns.substring(with: lineRange)
                let isDisclaimer = line.contains("will not exceed") || line.contains("maximum") || line.contains("not exceed")
                if isDisclaimer { continue }
                let numRange = m.range(at: 1)
                guard numRange.location != NSNotFound, let nSwift = Range(numRange, in: lowerText) else { continue }
                let token = String(lowerText[nSwift]).replacingOccurrences(of: "%", with: "")
                if var v = Decimal(string: token) {
                    let scale = computeScale(token)
                    if v > 1 { v /= 100 }
                    AMLogging.always("ImportViewModel: APR generic match token=\(token) fraction=\(v) scale=\(scale)", component: "ImportViewModel")
                    return (v, scale)
                }
            }
        }

        AMLogging.always("ImportViewModel: extractAPRFromPDF no APR found", component: "ImportViewModel")
        return nil
    }
    
    private static func extractCardSummaryFromPDF(at url: URL) -> (newBalance: Decimal, minimumPayment: Decimal?, dueDate: Date?)? {
        AMLogging.always("ImportViewModel: extractCardSummaryFromPDF start url=\(url.lastPathComponent)", component: "ImportViewModel")
        guard let doc = PDFDocument(url: url) else { return nil }
        let pageCount = doc.pageCount
        let pagesToScan = min(3, pageCount) // summary is usually on the first page or two
        var combined = ""
        for i in 0..<pagesToScan {
            if let page = doc.page(at: i), let s = page.string {
                combined.append("\n")
                combined.append(s)
            }
        }
        let text = combined
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "﹩", with: "$")
            .replacingOccurrences(of: "＄", with: "$")

        func firstMatch(_ pattern: String, group: Int = 1, options: NSRegularExpression.Options = [.caseInsensitive]) -> String? {
            guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
            let ns = text as NSString
            let range = NSRange(location: 0, length: ns.length)
            guard let m = re.firstMatch(in: text, options: [], range: range) else { return nil }
            guard m.numberOfRanges > group else { return nil }
            let r = m.range(at: group)
            if r.location != NSNotFound { return ns.substring(with: r) }
            return nil
        }

        func parseAmount(_ s: String) -> Decimal? {
            let cleaned = s
                .replacingOccurrences(of: ",", with: "")
                .replacingOccurrences(of: "$", with: "")
                .replacingOccurrences(of: "﹩", with: "")
                .replacingOccurrences(of: "＄", with: "")
                .replacingOccurrences(of: "\u{00A0}", with: "")
                .replacingOccurrences(of: "\u{202F}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Decimal(string: cleaned)
        }

        func parseDate(_ s: String) -> Date? {
            let candidates = [
                "MM/dd/yyyy", "M/d/yyyy", "MM/dd/yy", "M/d/yy",
                "MMMM d, yyyy", "MMM d, yyyy"
            ]
            for fmt in candidates {
                let df = DateFormatter()
                df.locale = Locale(identifier: "en_US_POSIX")
                df.timeZone = TimeZone(secondsFromGMT: 0)
                df.dateFormat = fmt
                if let d = df.date(from: s.trimmingCharacters(in: .whitespacesAndNewlines)) { return d }
            }
            return nil
        }

        // Patterns resilient to extra spaces/formatting
        let amountToken = #"(\$?\s*[0-9]{1,3}(?:,[0-9]{3})*(?:\.[0-9]{2})|\$?\s*[0-9]+(?:\.[0-9]{2})?)"#
        let currencyToken = #"(\$\s*[0-9]{1,3}(?:,[0-9]{3})*(?:\.[0-9]{2})|\$\s*[0-9]+(?:\.[0-9]{2})?)"#
        let newBalancePattern = "(?:new\\s*balance)\\s*[:\\-]?\\s*" + amountToken

        // Cross-line tolerant minimum payment extraction
        let minPaymentPattern = "(?:total\\s+minimum\\s+payment\\s+due|min(?:imum)?\\s+payment(?:\\s+due)?)\\s*[:\\-]?\\s*" + currencyToken
        var minPayStr = firstMatch(minPaymentPattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
        if minPayStr == nil {
            // Allow newline or colon/hyphen between label and amount
            let minPaymentCross = "(?:total\\s+minimum\\s+payment\\s+due|min(?:imum)?\\s+payment(?:\\s+due)?)\\s*[:\\-\\n\\r]*" + currencyToken
            minPayStr = firstMatch(minPaymentCross, options: [.caseInsensitive, .dotMatchesLineSeparators])
        }
        // Fallback: accept amounts without a currency symbol (some PDFs drop the glyph)
        if minPayStr == nil {
            let minPaymentPatternAny = "(?:total\\s+minimum\\s+payment\\s+due|min(?:imum)?\\s+payment(?:\\s+due)?)\\s*[:\\-]?\\s*" + amountToken
            minPayStr = firstMatch(minPaymentPatternAny, options: [.caseInsensitive, .dotMatchesLineSeparators])
        }
        if minPayStr == nil {
            let minPaymentCrossAny = "(?:total\\s+minimum\\s+payment\\s+due|min(?:imum)?\\s+payment(?:\\s+due)?)\\s*[:\\-\\n\\r]*" + amountToken
            minPayStr = firstMatch(minPaymentCrossAny, options: [.caseInsensitive, .dotMatchesLineSeparators])
        }

        let dueDatePattern = #"(?:payment\s+due\s+date)\s*[:\-]?\s*([A-Za-z]{3,9}\s+[0-9]{1,2},\s*[0-9]{2,4}|[0-9]{1,2}/[0-9]{1,2}/[0-9]{2,4})"#
        let dueStr = firstMatch(dueDatePattern)

        var minPay = minPayStr.flatMap(parseAmount)
        if minPay == nil {
            // Targeted fallback: anchor within the Payment Information section and avoid advisory text
            let lines = text.components(separatedBy: CharacterSet.newlines)
            let lowerLines = lines.map { $0.lowercased() }
            let ignoreLineKeywords = ["if you", "only", "additional", "add ", "pay off", "years", "months"]

            // Prefer searching within the Payment Information section if present
            let paymentInfoIdx = lowerLines.firstIndex(where: { $0.contains("payment information") })
            let startIdx = paymentInfoIdx ?? lowerLines.firstIndex(where: { $0.contains("minimum payment") })

            if let start = startIdx {
                let windowEnd = min(lines.count, start + 40)
                // Find a clean label line that mentions Minimum Payment but not advisory text
                var minLabelIdx: Int? = nil
                for i in start..<windowEnd {
                    let l = lowerLines[i]
                    if l.contains("minimum payment") && !ignoreLineKeywords.contains(where: { l.contains($0) }) {
                        minLabelIdx = i
                        break
                    }
                }

                if let labelIdx = minLabelIdx {
                    let amtReCurrency = try? NSRegularExpression(pattern: currencyToken, options: [])
                    let amtReAny = try? NSRegularExpression(pattern: amountToken, options: [])

                    // 1) Same line as label — try currency first, then any amount
                    do {
                        let s = lines[labelIdx] as NSString
                        let r = NSRange(location: 0, length: s.length)
                        if let re = amtReCurrency, let m = re.firstMatch(in: lines[labelIdx], options: [], range: r), m.numberOfRanges >= 2 {
                            let gr = m.range(at: 1)
                            if gr.location != NSNotFound {
                                let token = s.substring(with: gr)
                                if let val = parseAmount(token) {
                                    minPay = val
                                    AMLogging.always("ImportViewModel: extractCardSummaryFromPDF — Minimum Payment (same-line) = \(val)", component: "ImportViewModel")
                                }
                            }
                        }
                        if minPay == nil, let re = amtReAny, let m = re.firstMatch(in: lines[labelIdx], options: [], range: r), m.numberOfRanges >= 2 {
                            let gr = m.range(at: 1)
                            if gr.location != NSNotFound {
                                let token = s.substring(with: gr)
                                if let val = parseAmount(token) {
                                    minPay = val
                                    AMLogging.always("ImportViewModel: extractCardSummaryFromPDF — Minimum Payment (same-line any) = \(val)", component: "ImportViewModel")
                                }
                            }
                        }
                    }

                    // 2) If not on the same line, look ahead a couple lines for the amount, skipping advisory text
                    if minPay == nil {
                        let lookaheadEnd = min(lines.count, labelIdx + 3)
                        outer: for j in (labelIdx+1)..<lookaheadEnd {
                            let l = lowerLines[j]
                            if ignoreLineKeywords.contains(where: { l.contains($0) }) { continue }
                            let s = lines[j] as NSString
                            let r = NSRange(location: 0, length: s.length)

                            // Try currency amount first
                            if let re = amtReCurrency {
                                let matches = re.matches(in: lines[j], options: [], range: r)
                                for m in matches {
                                    guard m.numberOfRanges >= 2 else { continue }
                                    let gr = m.range(at: 1)
                                    if gr.location != NSNotFound {
                                        let token = s.substring(with: gr)
                                        if let val = parseAmount(token) {
                                            minPay = val
                                            AMLogging.always("ImportViewModel: extractCardSummaryFromPDF — Minimum Payment (lookahead) = \(val)", component: "ImportViewModel")
                                            break outer
                                        }
                                    }
                                }
                            }
                            // Fallback: any amount without currency symbol
                            if minPay == nil, let re = amtReAny {
                                let matches = re.matches(in: lines[j], options: [], range: r)
                                for m in matches {
                                    guard m.numberOfRanges >= 2 else { continue }
                                    let gr = m.range(at: 1)
                                    if gr.location != NSNotFound {
                                        let token = s.substring(with: gr)
                                        if let val = parseAmount(token) {
                                            minPay = val
                                            AMLogging.always("ImportViewModel: extractCardSummaryFromPDF — Minimum Payment (lookahead any) = \(val)", component: "ImportViewModel")
                                            break outer
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        let due = dueStr.flatMap(parseDate)

        guard let newBalStr = firstMatch(newBalancePattern) else {
            AMLogging.always("ImportViewModel: extractCardSummaryFromPDF — no New Balance match", component: "ImportViewModel")
            return nil
        }

        guard let newBal = parseAmount(newBalStr) else {
            AMLogging.always("ImportViewModel: extractCardSummaryFromPDF — New Balance parse failed: \(newBalStr)", component: "ImportViewModel")
            return nil
        }

        // Secondary plausibility filter for Minimum Payment: prefer whole-dollar >= $25 and 1.0%–10% of New Balance
        if newBal > 0 {
            func isWholeDollar(_ amount: Decimal) -> Bool {
                let cents = ((amount as NSDecimalNumber).multiplying(byPowerOf10: 2)).intValue % 100
                return cents == 0
            }
            func fraction(of amount: Decimal, relativeTo total: Decimal) -> Double? {
                let totalDouble = (total as NSDecimalNumber).doubleValue
                guard totalDouble > 0 else { return nil }
                return (amount as NSDecimalNumber).doubleValue / totalDouble
            }

            // Only refine if the currently found minPay is missing or implausible
            let existingIsPlausible: Bool = {
                guard let mp = minPay, let f = fraction(of: mp, relativeTo: newBal) else { return false }
                return isWholeDollar(mp) && mp >= 25 && f >= 0.01 && f <= 0.10
            }()

            if !existingIsPlausible {
                var candidates: [Decimal] = []
                let lines = text.components(separatedBy: CharacterSet.newlines)
                let lowerLines = lines.map { $0.lowercased() }
                let ignoreLineKeywords = ["if you", "only", "additional", "add ", "pay off", "years", "months"]

                let paymentInfoIdx = lowerLines.firstIndex(where: { $0.contains("payment information") })
                let startIdx = paymentInfoIdx ?? lowerLines.firstIndex(where: { $0.contains("minimum payment") })

                if let start = startIdx {
                    let windowEnd = min(lines.count, start + 40)
                    var minLabelIdx: Int? = nil
                    for i in start..<windowEnd {
                        let l = lowerLines[i]
                        if l.contains("minimum payment") && !ignoreLineKeywords.contains(where: { l.contains($0) }) {
                            minLabelIdx = i
                            break
                        }
                    }
                    if let labelIdx = minLabelIdx {
                        let amtReCurrency = try? NSRegularExpression(pattern: currencyToken, options: [])
                        let amtReAny = try? NSRegularExpression(pattern: amountToken, options: [])

                        // Same line candidates (currency, then any)
                        do {
                            let s = lines[labelIdx] as NSString
                            let r = NSRange(location: 0, length: s.length)
                            if let re = amtReCurrency {
                                let ms = re.matches(in: lines[labelIdx], options: [], range: r)
                                for m in ms {
                                    if m.numberOfRanges >= 2 {
                                        let gr = m.range(at: 1)
                                        if gr.location != NSNotFound {
                                            let token = s.substring(with: gr)
                                            if let val = parseAmount(token) {
                                                if !candidates.contains(where: { $0 == val }) { candidates.append(val) }
                                            }
                                        }
                                    }
                                }
                            }
                            if let re = amtReAny {
                                let ms = re.matches(in: lines[labelIdx], options: [], range: r)
                                for m in ms {
                                    if m.numberOfRanges >= 2 {
                                        let gr = m.range(at: 1)
                                        if gr.location != NSNotFound {
                                            let token = s.substring(with: gr)
                                            if let val = parseAmount(token) {
                                                if !candidates.contains(where: { $0 == val }) { candidates.append(val) }
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // Lookahead candidates (skip advisory lines, limit to next 3 lines)
                        let lookaheadEnd = min(lines.count, labelIdx + 3)
                        for j in (labelIdx+1)..<lookaheadEnd {
                            let l = lowerLines[j]
                            if ignoreLineKeywords.contains(where: { l.contains($0) }) { continue }
                            let s2 = lines[j] as NSString
                            let r2 = NSRange(location: 0, length: s2.length)
                            if let re = amtReCurrency {
                                let ms2 = re.matches(in: lines[j], options: [], range: r2)
                                for m in ms2 {
                                    if m.numberOfRanges >= 2 {
                                        let gr = m.range(at: 1)
                                        if gr.location != NSNotFound {
                                            let token = s2.substring(with: gr)
                                            if let val = parseAmount(token) {
                                                if !candidates.contains(where: { $0 == val }) { candidates.append(val) }
                                            }
                                        }
                                    }
                                }
                            }
                            if let re = amtReAny {
                                let ms2 = re.matches(in: lines[j], options: [], range: r2)
                                for m in ms2 {
                                    if m.numberOfRanges >= 2 {
                                        let gr = m.range(at: 1)
                                        if gr.location != NSNotFound {
                                            let token = s2.substring(with: gr)
                                            if let val = parseAmount(token) {
                                                if !candidates.contains(where: { $0 == val }) { candidates.append(val) }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // Apply plausibility preferences
                let plausible = candidates.compactMap { amt -> (Decimal, Double)? in
                    guard let f = fraction(of: amt, relativeTo: newBal) else { return nil }
                    if isWholeDollar(amt) && amt >= 25 && f >= 0.01 && f <= 0.10 {
                        return (amt, f)
                    }
                    return nil
                }

                if let best = plausible.sorted(by: { abs($0.1 - 0.02) < abs($1.1 - 0.02) }).first {
                    minPay = best.0
                    AMLogging.always("ImportViewModel: extractCardSummaryFromPDF — refined Minimum Payment selected = \(best.0) (ratio=\(best.1))", component: "ImportViewModel")
                }
            }
            // Enforce plausibility: if still implausible after refinement, discard it
            let finalIsPlausible: Bool = {
                guard let mp = minPay, let f = fraction(of: mp, relativeTo: newBal) else { return false }
                return isWholeDollar(mp) && mp >= 25 && f >= 0.01 && f <= 0.10
            }()
            if !finalIsPlausible {
                AMLogging.always("ImportViewModel: extractCardSummaryFromPDF — discarding implausible Minimum Payment=\(String(describing: minPay)) for newBalance=\(newBal)", component: "ImportViewModel")
                minPay = nil
            }
        }

        AMLogging.always("ImportViewModel: extractCardSummaryFromPDF — newBalance=\(newBal), minPayment=\(String(describing: minPay)), dueDate=\(String(describing: due))", component: "ImportViewModel")
        return (newBalance: newBal, minimumPayment: minPay, dueDate: due)
    }

    init(parsers: [StatementParser]) {
        self.parsers = parsers
    }

    // Resolve the currently selected account ID into a live Account in the provided context
    func resolveSelectedAccount(in context: ModelContext) throws -> Account? {
        guard let id = selectedAccountID else { return nil }
        let predicate = #Predicate<Account> { $0.id == id }
        var descriptor = FetchDescriptor<Account>(predicate: predicate)
        descriptor.fetchLimit = 1
        let account = try context.fetch(descriptor).first
        if let acct = account {
            let current = self.userInstitutionName.trimmingCharacters(in: .whitespacesAndNewlines)
            if current.isEmpty, let inst = acct.institutionName, !inst.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.userInstitutionName = inst
                AMLogging.always("Prefilled institution from selected account: \(inst)", component: "ImportViewModel")
            }
        }
        return account
    }

    func handlePickedURL(_ url: URL) {
        AMLogging.log("Picked URL: \(url.absoluteString)", component: "ImportViewModel")  // DEBUG LOG

        // Show spinner immediately
        self.isImporting = true

        Task.detached { [weak self] in
            guard let self else { return }
            // Begin security-scoped access for files picked from the Files app
            let didStart = url.startAccessingSecurityScopedResource()
            defer {
                if didStart { url.stopAccessingSecurityScopedResource() }
            }

            do {
                // Persist a local copy so we can preview PDFs reliably
                let fm = FileManager.default
                let caches = try fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                let dest = caches.appendingPathComponent(url.lastPathComponent)
                // Overwrite if exists
                try? fm.removeItem(at: dest)
                if fm.fileExists(atPath: url.path) {
                    try? fm.copyItem(at: url, to: dest)
                }
                await MainActor.run { self.lastPickedLocalURL = dest }

                // If the file is in iCloud, trigger a download if needed
                if let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey]),
                   values.isUbiquitousItem == true {
                    try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                }

                // Run the coordinator on main actor to get confidence/warnings (method is @MainActor)
                var coordinatorResult: StatementImportResult? = nil
                do {
                    coordinatorResult = try await MainActor.run {
                        try self.importer.importStatement(from: url, prefer: .summaryOnly)
                    }
                } catch {
                    // Ignore coordinator errors here; continue with legacy path
                }

                // Extract rows/headers (heavy work)
                let ext = url.pathExtension.lowercased()
                let rowsAndHeaders: ([[String]], [String])
                if ext == "pdf" {
                    // Try summary-only first; if it fails, retry transactions mode to salvage activity/summary
                    do {
                        let primary = try await MainActor.run {
                            try PDFStatementExtractor.parse(url: url, mode: .summaryOnly)
                        }
                        rowsAndHeaders = primary
                    } catch {
                        await AMLogging.always("ImportViewModel: PDF summary-only failed (\(error.localizedDescription)); retrying transactions mode", component: "ImportViewModel")
                        let fallback = try await MainActor.run {
                            try PDFStatementExtractor.parse(url: url, mode: .transactions)
                        }
                        rowsAndHeaders = fallback
                    }
                } else {
                    let data = try Data(contentsOf: url)
                    rowsAndHeaders = try await MainActor.run {
                        try CSV.read(data: data)
                    }
                }
                let (rows, headers) = rowsAndHeaders

                await MainActor.run { [coordinatorResult] in
                    self.detectedTypicalPaymentByLabel = [:]
                    guard !headers.isEmpty else {
                        self.errorMessage = ImportError.invalidCSV.localizedDescription
                        self.infoMessage = nil
                        self.staged = nil
                        self.isImporting = false
                        return
                    }
                    AMLogging.always("Import picked — ext: \(ext), rows: \(rows.count), headers: \(headers)", component: "ImportViewModel")

                    do {
                        let descIdx = headers.firstIndex(where: { $0.caseInsensitiveCompare("Description") == .orderedSame }) ?? 1
                        let amountIdx = headers.firstIndex(where: { $0.caseInsensitiveCompare("Amount") == .orderedSame }) ?? 2
                        let balanceIdx = headers.firstIndex(where: { $0.caseInsensitiveCompare("Balance") == .orderedSame })
                        let paymentRows = rows.filter { row in
                            guard row.indices.contains(descIdx) else { return false }
                            let d = row[descIdx].lowercased()
                            let keywords = [
                                "estimated monthly payment (loan)",
                                "typical payment (loan)",
                                "minimum payment",
                                "minimum payment due",
                                "minimum payment due (mpd)",
                                "minimum amount due",
                                "min payment",
                                "min. payment",
                                "payment due",
                                "amount due",
                                "current amount due",
                                "past due amount"
                            ]
                            return keywords.contains { d.contains($0) }
                        }
                        if paymentRows.isEmpty {
                            AMLogging.always("ImportViewModel: no payment rows detected pre-parse", component: "ImportViewModel")
                        } else {
                            for r in paymentRows {
                                let desc = r[safe: descIdx] ?? ""
                                let amtStr: String = {
                                    let a = r[safe: amountIdx] ?? ""
                                    if !a.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return a }
                                    let b = balanceIdx.flatMap { idx in (idx < r.count ? r[idx] : nil) } ?? ""
                                    return b
                                }()
                                let dec = Decimal(string: amtStr.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: ""))
                                AMLogging.always("ImportViewModel: payment row pre-parse — desc='\(desc)', amountStr='\(amtStr)', parsed=\(String(describing: dec))", component: "ImportViewModel")
                                if let amount = dec {
                                    // Try to get a label from an Account column if present, else infer from description
                                    let accountIdx = headers.firstIndex(where: { $0.caseInsensitiveCompare("Account") == .orderedSame })
                                    let accountRaw = accountIdx.flatMap { idx in (idx < r.count ? r[idx] : nil) }
                                    let inferredLabel: String? = self.normalizeSourceLabel(accountRaw) ?? self.normalizeSourceLabel(desc)
                                    let key = inferredLabel ?? "default"
                                    self.detectedTypicalPaymentByLabel[key] = amount
                                    AMLogging.always("ImportViewModel: captured typical payment hint — label=\(key), amount=\(amount)", component: "ImportViewModel")
                                }
                            }
                        }
                    }

                    let matchingParsers = self.parsers.compactMap { $0.canParse(headers: headers) ? String(describing: type(of: $0)) : nil }
                    AMLogging.always("Parsers matching headers: \(matchingParsers)", component: "ImportViewModel")
                    if let parser = self.parsers.first(where: { $0.canParse(headers: headers) }) {
                        AMLogging.log("Using parser: \(String(describing: type(of: parser)))", component: "ImportViewModel")  // DEBUG LOG
                        do {
                            var stagedImport = try parser.parse(rows: rows, headers: headers)
                            stagedImport.sourceFileName = url.lastPathComponent

                            // Fallback: If this is a PDF and we didn't get a usable balance snapshot, try extracting the header summary (New Balance / Minimum Payment / Due Date)
                            if ext == "pdf" {
                                let needBalanceFallback: Bool = {
                                    if stagedImport.balances.isEmpty { return true }
                                    if stagedImport.balances.count == 1 && stagedImport.balances[0].balance == 0 { return true }
                                    return false
                                }()
                                let labels = stagedImport.balances.map { self.normalizeSourceLabel($0.sourceAccountLabel) ?? "default" }
                                let allNonLiability = !labels.isEmpty && labels.allSatisfy { $0 == "checking" || $0 == "savings" }
                                if needBalanceFallback || allNonLiability {
                                    let probeURL = self.lastPickedLocalURL ?? url
                                    if let summary = Self.extractCardSummaryFromPDF(at: probeURL) {
                                        let asOf = summary.dueDate ?? stagedImport.balances.first?.asOfDate ?? Date()
                                        let newSnap = StagedBalance(
                                            asOfDate: asOf,
                                            balance: summary.newBalance,
                                            interestRateAPR: nil,
                                            interestRateScale: nil,
                                            include: true,
                                            sourceAccountLabel: "creditCard"
                                        )
                                        if stagedImport.balances.isEmpty {
                                            stagedImport.balances = [newSnap]
                                        } else {
                                            stagedImport.balances[0] = newSnap
                                        }
                                        if let mp = summary.minimumPayment, mp > 0 {
                                            self.detectedTypicalPaymentByLabel["creditCard"] = mp
                                            self.detectedTypicalPaymentByLabel["default"] = mp
                                        }
                                        if stagedImport.suggestedAccountType == nil { stagedImport.suggestedAccountType = .creditCard }
                                        AMLogging.always("ImportViewModel: Applied PDF summary fallback — newBalance=\(summary.newBalance), minPayment=\(String(describing: summary.minimumPayment)), dueDate=\(String(describing: summary.dueDate))", component: "ImportViewModel")
                                    } else {
                                        AMLogging.always("ImportViewModel: PDF summary fallback did not find header fields", component: "ImportViewModel")
                                    }
                                }
                            }

                            // Try to capture minimum payment from PDF header even if parser guessed a non-card type.
                            // This is safe: we only keep it if a plausible minimum payment is found.
                            if ext == "pdf", self.detectedTypicalPaymentByLabel["creditCard"] == nil {
                                let probeURL = self.lastPickedLocalURL ?? url
                                if let summary = Self.extractCardSummaryFromPDF(at: probeURL),
                                   let mp = summary.minimumPayment, mp > 0 {
                                    self.detectedTypicalPaymentByLabel["creditCard"] = mp
                                    self.detectedTypicalPaymentByLabel["default"] = mp
                                    AMLogging.always("ImportViewModel: Captured minimum payment from PDF summary — amount=\(mp)", component: "ImportViewModel")

                                    // If no suggestion yet, nudge toward credit card. Don’t override an explicit brokerage/loan suggestion.
                                    if stagedImport.suggestedAccountType == nil {
                                        stagedImport.suggestedAccountType = .creditCard
                                    }
                                }
                            }

                            // After summary fallback, attempt APR extraction if still missing
                            if ext == "pdf" {
                                let allMissingAPR = stagedImport.balances.allSatisfy { $0.interestRateAPR == nil }
                                AMLogging.always("ImportViewModel: allMissingAPR=\(allMissingAPR)", component: "ImportViewModel")
                                if allMissingAPR {
                                    if let localURL = self.lastPickedLocalURL, let (apr, scale) = Self.extractAPRFromPDF(at: localURL) {
                                        for idx in stagedImport.balances.indices {
                                            if stagedImport.balances[idx].interestRateAPR == nil {
                                                stagedImport.balances[idx].interestRateAPR = apr
                                                stagedImport.balances[idx].interestRateScale = scale
                                            }
                                        }
                                        AMLogging.always("ImportViewModel: applied APR=\(apr) scale=\(scale) to \(stagedImport.balances.count) snapshots (local)", component: "ImportViewModel")
                                    } else if let (apr, scale) = Self.extractAPRFromPDF(at: url) {
                                        for idx in stagedImport.balances.indices {
                                            if stagedImport.balances[idx].interestRateAPR == nil {
                                                stagedImport.balances[idx].interestRateAPR = apr
                                                stagedImport.balances[idx].interestRateScale = scale
                                            }
                                        }
                                        AMLogging.always("ImportViewModel: applied APR=\(apr) scale=\(scale) to \(stagedImport.balances.count) snapshots (original)", component: "ImportViewModel")
                                    }
                                }
                            }

                            AMLogging.always("Parser '\(String(describing: type(of: parser)))' produced — tx: \(stagedImport.transactions.count), holdings: \(stagedImport.holdings.count), balances: \(stagedImport.balances.count)", component: "ImportViewModel")

                            if !stagedImport.balances.isEmpty {
                                AMLogging.always("Staged balances detail (pre-save):", component: "ImportViewModel")
                                for b in stagedImport.balances {
                                    let raw = b.sourceAccountLabel ?? "(nil)"
                                    let norm = self.normalizeSourceLabel(b.sourceAccountLabel) ?? "default"
                                    AMLogging.always("• asOf: \(b.asOfDate), balance: \(b.balance), rawLabel: \(raw), normalized: \(norm), apr: \(String(describing: b.interestRateAPR))", component: "ImportViewModel")
                                }
                            }

                             do {
                                 let paymentLike = stagedImport.transactions.filter {
                                     let p = $0.payee.lowercased()
                                     let m = ($0.memo ?? "").lowercased()
                                     let keywords = [
                                         "estimated monthly payment (loan)",
                                         "typical payment (loan)",
                                         "minimum payment",
                                         "minimum payment due",
                                         "minimum amount due",
                                         "min payment",
                                         "min. payment",
                                         "payment due",
                                         "amount due",
                                         "current amount due"
                                     ]
                                     return keywords.contains { k in p.contains(k) || m.contains(k) }
                                 }
                                 if paymentLike.isEmpty {
                                     AMLogging.always("ImportViewModel: no payment-like transactions found post-parse", component: "ImportViewModel")
                                 } else {
                                     for t in paymentLike {
                                         AMLogging.always("ImportViewModel: payment-like transaction post-parse — date: \(t.datePosted), amount: \(t.amount), payee: \(t.payee), memo: \(t.memo ?? "")", component: "ImportViewModel")
                                     }
                                 }
                             }

                            if stagedImport.transactions.isEmpty && (!stagedImport.holdings.isEmpty || !stagedImport.balances.isEmpty) {
                                AMLogging.always("Note: Parser produced no transactions but did produce holdings/balances. This is expected for statement-summary files.", component: "ImportViewModel")
                            }

                            // Guess account type
                            let sampleForGuess = Array(rows.prefix(50))
                            AMLogging.always("Guessing account type — file: \(stagedImport.sourceFileName), headers: \(headers)", component: "ImportViewModel")
                            let guessedType = self.guessAccountType(from: stagedImport.sourceFileName, headers: headers, sampleRows: sampleForGuess)
                            AMLogging.always("Guess result: \(String(describing: guessedType?.rawValue))", component: "ImportViewModel")
                            if stagedImport.suggestedAccountType == nil, let guessedType = guessedType {
                                stagedImport.suggestedAccountType = guessedType
                            }
                            if let suggested = stagedImport.suggestedAccountType {
                                self.newAccountType = suggested
                                AMLogging.always("Applied suggested account type: \(self.newAccountType.rawValue)", component: "ImportViewModel")
    AMLogging.always("ImportViewModel: invoking safety net before staging filter (local staged)", component: "ImportViewModel")
    self.applyLiabilityLabelSafetyNetIfNeeded(to: &stagedImport)
                            } else {
                                AMLogging.always("No suggested account type from parser/guess", component: "ImportViewModel")
                            }
                            
                            // Ensure safety net has a chance to run even if suggestion was nil
                            if stagedImport.suggestedAccountType == nil {
                                AMLogging.always("ImportViewModel: invoking safety net before staging filter (no suggestion)", component: "ImportViewModel")
                                self.applyLiabilityLabelSafetyNetIfNeeded(to: &stagedImport)
                            }

                            // Filter out non-liability balances at staging time for liability imports
                            let importTypeForStaging = stagedImport.suggestedAccountType ?? self.newAccountType
                            if importTypeForStaging == .loan || importTypeForStaging == .creditCard {
                                let before = stagedImport.balances.count
                                let filtered = stagedImport.balances.filter { b in
                                    let norm = self.normalizeSourceLabel(b.sourceAccountLabel) ?? "default"
                                    return norm == "loan" || norm == "creditCard" || norm == "default"
                                }
                                let dropped = before - filtered.count
                                if dropped > 0 {
                                    let keptLabels = filtered.map { self.normalizeSourceLabel($0.sourceAccountLabel) ?? "default" }
                                    AMLogging.always("Staging filter: liability import — dropped \(dropped) of \(before) non-liability balances. Kept labels: \(keptLabels)", component: "ImportViewModel")
                                } else {
                                    AMLogging.always("Staging filter: liability import — no non-liability balances to drop", component: "ImportViewModel")
                                }
                                stagedImport.balances = filtered
                                if !stagedImport.balances.isEmpty {
                                    AMLogging.always("Staged balances detail (post-filter):", component: "ImportViewModel")
                                    for b in stagedImport.balances {
                                        let raw = b.sourceAccountLabel ?? "(nil)"
                                        let norm = self.normalizeSourceLabel(b.sourceAccountLabel) ?? "default"
                                        AMLogging.always("• asOf: \(b.asOfDate), balance: \(b.balance), rawLabel: \(raw), normalized: \(norm), apr: \(String(describing: b.interestRateAPR))", component: "ImportViewModel")
                                    }
                                }
                            }

                            self.staged = stagedImport

                            // Prefill institution name for import screen if empty, using filename guess
                            if self.userInstitutionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                               let guessedInst = self.guessInstitutionName(from: stagedImport.sourceFileName) {
                                self.userInstitutionName = guessedInst
                                AMLogging.always("Prefilled institution guess for import screen: \(guessedInst)", component: "ImportViewModel")
                            }

                            // Build info messages
                            var messages: [String] = []
                            if let res = coordinatorResult {
                                for w in res.warnings { if !messages.contains(w) { messages.append(w) } }
                                if res.source == .pdf && res.confidence <= .low {
                                    let warn = "Low confidence parsing PDF. Consider importing a CSV for best results."
                                    if !messages.contains(warn) { messages.append(warn) }
                                }
                            }
                            if (stagedImport.suggestedAccountType == .brokerage || self.newAccountType == .brokerage),
                               stagedImport.balances.isEmpty,
                               stagedImport.holdings.isEmpty,
                               !stagedImport.transactions.isEmpty {
                                let hint = "Brokerage activity won't affect Net Worth until you import a statement with balances/holdings or set a starting balance."
                                if !messages.contains(hint) { messages.append(hint) }
                            }
                            self.infoMessage = messages.isEmpty ? nil : messages.joined(separator: "\n")
                        } catch {
                            self.errorMessage = error.localizedDescription
                            self.infoMessage = nil
                            self.staged = nil
                        }
                    } else {
                        AMLogging.always("No parser matched headers. Starting mapping session. Headers: \(headers)", component: "ImportViewModel")
                        let sample = Array(rows.prefix(10))
                        self.mappingSession = MappingSession(kind: .bank, headers: headers, sampleRows: sample, dateIndex: nil, descriptionIndex: nil, amountIndex: nil, debitIndex: nil, creditIndex: nil, balanceIndex: nil, dateFormat: nil)

                        // Prefill institution name for import screen (mapping fallback) if empty, using filename guess
                        if self.userInstitutionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           let guessedInst = self.guessInstitutionName(from: url.lastPathComponent) {
                            self.userInstitutionName = guessedInst
                            AMLogging.always("Prefilled institution guess for import screen (mapping): \(guessedInst)", component: "ImportViewModel")
                        }

                        if let res = coordinatorResult, (!res.warnings.isEmpty || res.confidence <= .low) {
                            var msgs: [String] = []
                            for w in res.warnings { if !msgs.contains(w) { msgs.append(w) } }
                            if res.source == .pdf && res.confidence <= .low {
                                let warn = "Low confidence parsing PDF. Consider importing a CSV for best results."
                                if !msgs.contains(warn) { msgs.append(warn) }
                            }
                            self.infoMessage = msgs.joined(separator: "\n")
                        } else {
                            self.infoMessage = nil
                        }
                    }

                    self.userSelectedDocHint = nil
                    self.isImporting = false
                }
            } catch {
                await MainActor.run {
                    let userMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    AMLogging.always("Importer error (user-facing): \(userMessage)", component: "ImportViewModel")
                    self.errorMessage = userMessage
                    self.infoMessage = nil
                    self.staged = nil
                    self.userSelectedDocHint = nil
                    self.isImporting = false
                }
            }
        }
    }

    // Normalize a raw source account label or description into a canonical key used in import grouping
     func normalizeSourceLabel(_ raw: String?) -> String? {
        guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !s.isEmpty else { return nil }
        if s.contains("checking") { return "checking" }
        if s.contains("savings") { return "savings" }
        if s.contains("credit card") || s.contains("visa") || s.contains("mastercard") || s.contains("amex") || s.contains("american express") || s.contains("discover") {
            return "creditCard"
        }
        if s.contains("loan") || s.contains("mortgage") { return "loan" }
        if s.contains("brokerage") || s.contains("investment") || s.contains("stock") || s.contains("options") {
            return "brokerage" }
        return nil
    }

    // Expose a best-effort typical payment hint for a given account type (liabilities only)
    func typicalPaymentHint(for type: Account.AccountType) -> Decimal? {
        let key: String
        switch type {
        case .loan: key = "loan"
        case .creditCard: key = "creditCard"
        default: return nil
        }
        return detectedTypicalPaymentByLabel[key] ?? detectedTypicalPaymentByLabel["default"]
    }

    func approveAndSave(context: ModelContext) throws {
        guard let staged else { return }
        AMLogging.log("Approve & Save started", component: "ImportViewModel")  // DEBUG LOG
        AMLogging.log("Staged counts — tx: \(staged.transactions.count), holdings: \(staged.holdings.count), balances: \(staged.balances.count)", component: "ImportViewModel")  // DEBUG LOG

        let batch = ImportBatch(
            label: staged.sourceFileName,
            sourceFileName: staged.sourceFileName,
            parserId: staged.parserId
        )
        context.insert(batch)
        
        if let localURL = lastPickedLocalURL {
            batch.sourceFileLocalPath = localURL.path
        }
        
        let providedInst = userInstitutionName.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosenInst = providedInst.isEmpty ? guessInstitutionName(from: staged.sourceFileName) : providedInst
        AMLogging.always("Approve: chosen institution: \(chosenInst ?? "(nil)") from file '\(staged.sourceFileName)'", component: "ImportViewModel")

        // Helper to normalize PDF/CSV labels to canonical strings
        func normalizedLabel(_ raw: String?) -> String? {
            guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !s.isEmpty else { return nil }
            if s.contains("checking") { return "checking" }
            if s.contains("savings") { return "savings" }
            // Recognize credit card labels/issuers
            if s.contains("credit card") || s.contains("visa") || s.contains("mastercard") || s.contains("amex") || s.contains("american express") || s.contains("discover") {
                return "creditCard"
            }
            // Recognize loan/mortgage labels
            if s.contains("loan") || s.contains("mortgage") { return "loan" }
            // Recognize brokerage/investment-related labels
            if s.contains("brokerage") || s.contains("investment") || s.contains("stock") || s.contains("options") {
                return "brokerage"
            }
            return nil
        }

        // Group balances by source account label
        let includedBalances = staged.balances.filter { $0.include }
        if includedBalances.isEmpty {
            AMLogging.always("Approve: no included balances in staged import", component: "ImportViewModel")
        } else {
            AMLogging.always("Approve: included balances detail (\(includedBalances.count)):", component: "ImportViewModel")
            for b in includedBalances {
                let raw = b.sourceAccountLabel ?? "(nil)"
                let norm = normalizedLabel(b.sourceAccountLabel) ?? "default"
                AMLogging.always("• asOf: \(b.asOfDate), balance: \(b.balance), rawLabel: \(raw), normalized: \(norm)", component: "ImportViewModel")
            }
        }
        var balanceGroups: [String: [StagedBalance]] = [:]
        for b in includedBalances {
            if let key = normalizedLabel(b.sourceAccountLabel) {
                balanceGroups[key, default: []].append(b)
            } else {
                balanceGroups["default", default: []].append(b)
            }
        }

        // Group transactions by source account label (checking/savings). Unlabeled will be handled separately.
        let includedTransactions = staged.transactions.filter { ($0.include) }
        let excludedCount = staged.transactions.count - includedTransactions.count
        
        var labeledGroups: [String: [StagedTransaction]] = [:]
        var unlabeled: [StagedTransaction] = []
        for t in includedTransactions {
            if let key = normalizedLabel(t.sourceAccountLabel) {
                labeledGroups[key, default: []].append(t)
            } else {
                unlabeled.append(t)
            }
        }
        AMLogging.always("Approve: label groups (tx) => \(labeledGroups.map { "\($0.key): \($0.value.count)" }.joined(separator: ", ")), unlabeled: \(unlabeled.count)", component: "ImportViewModel")
        AMLogging.always("Approve: label groups (balances) => \(balanceGroups.map { "\($0.key): \($0.value.count)" }.joined(separator: ", "))", component: "ImportViewModel")

        // Function to resolve or create an account for a given type/institution
        func resolveAccount(ofType resolvedType: Account.AccountType, institutionName: String?, preferExisting existing: Account?) -> Account {
            switch normalizedLabel(existing?.name) {
            case .some(let label):
                if label != "checking" && label != "savings" {
                    // fallback to normal logic below
                    break
                }
            case .none:
                break
            }
            // If an existing account was provided and matches the type and institution (or institution empty), reuse it
            if let existing {
                if existing.type == resolvedType {
                    if let inst = institutionName, !inst.isEmpty {
                        // If institution provided differs, update or switch to a matching account
                        if let current = existing.institutionName, !current.isEmpty, normalizeInstitutionName(current) != normalizeInstitutionName(inst) {
                            if let found = findAccount(ofType: resolvedType, institutionName: inst, context: context) {
                                AMLogging.always("Switching to existing account for institution: \(inst) and type: \(resolvedType.rawValue)", component: "ImportViewModel")
                                return found
                            } else {
                                AMLogging.always("Creating new account for institution: \(inst) and type: \(resolvedType.rawValue)", component: "ImportViewModel")
                                let acct = Account(
                                    name: inst,
                                    type: resolvedType,
                                    institutionName: inst,
                                    currencyCode: "USD"
                                )
                                context.insert(acct)
                                return acct
                            }
                        } else {
                            // Ensure institution name is set
                            if existing.institutionName == nil || existing.institutionName?.isEmpty == true {
                                existing.institutionName = inst
                            }
                        }
                    }
                    return existing
                }
            }
            // No suitable existing: find by institution, else create
            if let inst = institutionName, let found = findAccount(ofType: resolvedType, institutionName: inst, context: context) {
                AMLogging.always("Reusing existing account for institution: \(inst) and type: \(resolvedType.rawValue)", component: "ImportViewModel")
                return found
            } else {
                let name = institutionName ?? ""
                let acct = Account(
                    name: name,
                    type: resolvedType,
                    institutionName: institutionName,
                    currencyCode: "USD"
                )
                AMLogging.always("Creating new account with institution: \(institutionName ?? "(nil)") and type: \(resolvedType.rawValue)", component: "ImportViewModel")
                context.insert(acct)
                return acct
            }
        }

        // Resolve selected account if any (used as anchor for matching label/type)
        var selectedAccount: Account? = nil
        if let selectedID = selectedAccountID, let fetched = try? {
            let predicate = #Predicate<Account> { $0.id == selectedID }
            var descriptor = FetchDescriptor<Account>(predicate: predicate)
            descriptor.fetchLimit = 1
            return try context.fetch(descriptor).first
        }() {
            let target = fetched
            AMLogging.always("Selected account before resolution — name: \(target.name), type: \(target.type.rawValue), inst: \(target.institutionName ?? "(nil)")", component: "ImportViewModel")

            // Apply user-selected account type override so it always carries through
            if target.type != self.newAccountType {
                AMLogging.always("Applying user-selected account type override: \(target.type.rawValue) -> \(self.newAccountType.rawValue)", component: "ImportViewModel")
                target.type = self.newAccountType
            }

            if !providedInst.isEmpty {
                AMLogging.always("Applying user-provided institution to selected account: '\(providedInst)'", component: "ImportViewModel")
                target.institutionName = providedInst
            } else if (target.institutionName == nil) || (target.institutionName?.isEmpty == true) {
                AMLogging.always("Filling missing institution on selected account with: \(chosenInst ?? "(nil)")", component: "ImportViewModel")
                if let chosenInst { target.institutionName = chosenInst }
            } else if let chosenInst, let current = target.institutionName, !current.isEmpty, normalizeInstitutionName(current) != normalizeInstitutionName(chosenInst) {
                AMLogging.always("Institution mismatch — selected: \(current), chosen: \(chosenInst).", component: "ImportViewModel")
                // We'll allow per-label account resolution below to create/find matching accounts for other labels
            }
            selectedAccount = target
        }

        // Build accounts per label (checking/savings) using both tx and balances labels.
        // For liability/report types (credit card, loan, brokerage), do NOT split by label — treat as a single account.
        let importType = staged.suggestedAccountType ?? self.newAccountType
        let allowSplitByLabel: Bool = {
            switch importType {
            case .checking, .savings:
                return true
            default:
                return false
            }
        }()

        AMLogging.always("Approve: importType=\(importType.rawValue), allowSplitByLabel=\(allowSplitByLabel)", component: "ImportViewModel")
        if !allowSplitByLabel && !includedBalances.isEmpty {
            let labels = includedBalances.map { normalizedLabel($0.sourceAccountLabel) ?? "default" }
            AMLogging.always("Approve: non-split path will assign all balances to a single account. Staged balance labels: \(labels)", component: "ImportViewModel")
        }

        // Filter out non-liability balances for liability imports (e.g., Chase statements listing checking/savings)
        var effectiveIncludedBalances = includedBalances
        var effectiveBalanceGroups = balanceGroups
        if importType == .loan || importType == .creditCard {
            let before = effectiveIncludedBalances.count
            let filtered = effectiveIncludedBalances.filter { b in
                let norm = normalizedLabel(b.sourceAccountLabel) ?? "default"
                return norm == "loan" || norm == "creditCard" || norm == "default"
            }
            let dropped = before - filtered.count
            if dropped > 0 {
                let keptLabels = filtered.map { normalizedLabel($0.sourceAccountLabel) ?? "default" }
                AMLogging.always("Approve: filtered non-liability balances for liability import — dropped \(dropped) of \(before). Kept labels: \(keptLabels)", component: "ImportViewModel")
            } else {
                AMLogging.always("Approve: no non-liability balances to filter for liability import", component: "ImportViewModel")
            }
            effectiveIncludedBalances = filtered
            // Rebuild balance groups after filtering
            effectiveBalanceGroups = [:]
            for b in filtered {
                if let key = normalizedLabel(b.sourceAccountLabel) {
                    effectiveBalanceGroups[key, default: []].append(b)
                } else {
                    effectiveBalanceGroups["default", default: []].append(b)
                }
            }
            AMLogging.always("Approve: effective label groups (balances) after filter => \(effectiveBalanceGroups.map { "\($0.key): \($0.value.count)" }.joined(separator: ", "))", component: "ImportViewModel")
        } else {
            // For non-liability imports, use original groups
            effectiveIncludedBalances = includedBalances
            effectiveBalanceGroups = balanceGroups
        }

        let allLabels: Set<String> = Set(labeledGroups.keys).union(Set(effectiveBalanceGroups.keys))

        if !allowSplitByLabel && !includedBalances.isEmpty {
            let labels = includedBalances.map { normalizedLabel($0.sourceAccountLabel) ?? "default" }
            AMLogging.always("Approve: non-split path will assign all balances to a single account. Staged balance labels: \(labels)", component: "ImportViewModel")
        }

        var accountsByLabel: [String: Account] = [:]
        if !allowSplitByLabel {
            // Force single-account path to avoid misclassification (e.g., credit card statement labeled as savings)
            let resolvedType = self.newAccountType
            let account = resolveAccount(ofType: resolvedType, institutionName: chosenInst, preferExisting: selectedAccount)
            AMLogging.always("Using single account (no label split) — id: \(account.id), name: \(account.name), type: \(account.type.rawValue)", component: "ImportViewModel")
            self.selectedAccountID = account.id
            accountsByLabel["default"] = account
        } else if allLabels.isEmpty {
            // Single-account path (original behavior)
            let resolvedType = self.newAccountType
            let account = resolveAccount(ofType: resolvedType, institutionName: chosenInst, preferExisting: selectedAccount)
            AMLogging.log("Resolved account — id: \(account.id), name: \(account.name), type: \(account.type.rawValue), existing tx count: \(account.transactions.count)", component: "ImportViewModel")  // DEBUG LOG
            AMLogging.always("Using account — id: \(account.id), name: \(account.name), type: \(account.type.rawValue), inst: \(account.institutionName ?? "(nil)")", component: "ImportViewModel")
            self.selectedAccountID = account.id
            accountsByLabel["default"] = account
        } else {
            for label in allLabels where label != "default" {
                let resolvedType = typeForLabel(label) ?? self.newAccountType
                let preferExisting: Account? = {
                    if let sel = selectedAccount, sel.type == resolvedType { return sel }
                    return nil
                }()
                let acct = resolveAccount(ofType: resolvedType, institutionName: chosenInst, preferExisting: preferExisting)
                accountsByLabel[label] = acct
                AMLogging.always("Label '\(label)' -> account id: \(acct.id), name: \(acct.name), type: \(acct.type.rawValue)", component: "ImportViewModel")
                AMLogging.always("Group counts — label: \(label), tx: \(labeledGroups[label]?.count ?? 0), balances: \(effectiveBalanceGroups[label]?.count ?? 0)", component: "ImportViewModel")
            }
            // Handle default label (no label present)
            if accountsByLabel.isEmpty, let firstLabel = allLabels.first {
                accountsByLabel[firstLabel] = resolveAccount(ofType: self.newAccountType, institutionName: chosenInst, preferExisting: selectedAccount)
            }
            if let first = accountsByLabel.values.first { self.selectedAccountID = first.id }
        }

        // Prefill typical payment and due day on resolved accounts before inserts
        for (label, account) in accountsByLabel {
            guard account.type == .loan || account.type == .creditCard else { continue }
            let typeKey = (account.type == .loan) ? "loan" : "creditCard"
            let typical = self.detectedTypicalPaymentByLabel[typeKey] ?? self.detectedTypicalPaymentByLabel["default"]

            var terms = account.loanTerms ?? LoanTerms()
            if let typical, typical > 0, (terms.paymentAmount ?? 0) == 0 {
                terms.paymentAmount = typical
                AMLogging.always("Prefill (pre-insert): typical payment — amount: \(typical), typeKey: \(typeKey), account: \(account.name)", component: "ImportViewModel")
            }
            if terms.paymentDayOfMonth == nil, let asOf = effectiveIncludedBalances.first?.asOfDate {
                let cal = Calendar(identifier: .gregorian)
                let day = cal.component(.day, from: asOf)
                terms.paymentDayOfMonth = day
                AMLogging.always("Prefill (pre-insert): due day — day: \(day) from asOf: \(asOf) account: \(account.name)", component: "ImportViewModel")
            }
            account.loanTerms = terms
        }

        // Helper for credit card sign decision per account
        func shouldFlipCreditCardAmounts(for account: Account, transactions: [StagedTransaction]) -> Bool {
            guard account.type == .creditCard else { return false }
            if let override = self.creditCardFlipOverride {
                return override
            }
            let includedTransactions = transactions
            func isPaymentLike(_ payee: String?, _ memo: String?) -> Bool {
                let text = ((payee ?? "") + " " + (memo ?? "")).lowercased()
                let keywords = [
                    "payment","auto pay","autopay","online payment","thank you","pmt","cardmember serv","card member serv","ach credit","ach payment","directpay","direct pay","bill pay","billpay"
                ]
                return keywords.contains { text.contains($0) }
            }
            let paymentRows = includedTransactions.filter { isPaymentLike($0.payee, $0.memo) }
            let purchaseRows = includedTransactions.filter { !isPaymentLike($0.payee, $0.memo) }
            let paymentPos = paymentRows.filter { $0.amount > 0 }.count
            let paymentNeg = paymentRows.filter { $0.amount < 0 }.count
            if paymentPos != paymentNeg && (paymentPos + paymentNeg) > 0 { return paymentNeg > paymentPos }
            let purchasePos = purchaseRows.filter { $0.amount > 0 }.count
            let purchaseNeg = purchaseRows.filter { $0.amount < 0 }.count
            if purchasePos != purchaseNeg && (purchasePos + purchaseNeg) > 0 { return purchasePos > purchaseNeg }
            let positives = includedTransactions.filter { $0.amount > 0 }.count
            let negatives = includedTransactions.filter { $0.amount < 0 }.count
            if positives == negatives {
                let total = includedTransactions.reduce(Decimal.zero) { $0 + $1.amount }
                return total > 0
            } else {
                return positives > negatives
            }
        }

        // Insert transactions per account group
        var insertedTxCount = 0
        var newlyInserted: [Transaction] = []

        // Build a map of label -> transactions array to iterate (include unlabeled and default paths)
        var groupsToProcess: [(label: String, transactions: [StagedTransaction]) ] = []
        if !allowSplitByLabel {
            groupsToProcess.append((label: "default", transactions: includedTransactions))
        } else if labeledGroups.isEmpty {
            let all = labeledGroups["default"] != nil ? [] : includedTransactions
            groupsToProcess.append((label: "default", transactions: all))
        } else {
            for (label, list) in labeledGroups { groupsToProcess.append((label: label, transactions: list)) }
            if !unlabeled.isEmpty { groupsToProcess.append((label: "unlabeled", transactions: unlabeled)) }
        }

        for entry in groupsToProcess {
            guard let account = accountsByLabel[entry.label] else { continue }
            AMLogging.always("Processing group '\(entry.label)' for account: \(account.name) — tx: \(entry.transactions.count)", component: "ImportViewModel")
            let shouldFlip = shouldFlipCreditCardAmounts(for: account, transactions: entry.transactions)
            AMLogging.always("Credit card sign decision (data-driven) — flip: \(shouldFlip) for account: \(account.name)", component: "ImportViewModel")

            // De-dupe set per account
            let existingHashes = try existingTransactionHashes(for: account, context: context)

            // Compute new transactions for this account
            let newTransactions = entry.transactions.filter { t in
                let adjustedAmount = (account.type == .creditCard && shouldFlip) ? -t.amount : t.amount
                let saveKey = Hashing.hashKey(
                    date: t.datePosted,
                    amount: adjustedAmount,
                    payee: t.payee,
                    memo: t.memo,
                    symbol: t.symbol,
                    quantity: t.quantity
                )
                return !existingHashes.contains(saveKey)
            }

            for t in newTransactions {
                let adjustedAmount = (account.type == .creditCard && shouldFlip) ? -t.amount : t.amount
                let saveKey = Hashing.hashKey(
                    date: t.datePosted,
                    amount: adjustedAmount,
                    payee: t.payee,
                    memo: t.memo,
                    symbol: t.symbol,
                    quantity: t.quantity
                )

                let tx = Transaction(
                    datePosted: t.datePosted,
                    amount: adjustedAmount,
                    payee: t.payee,
                    memo: t.memo,
                    kind: t.kind,
                    externalId: t.externalId,
                    hashKey: saveKey,
                    symbol: t.symbol,
                    quantity: t.quantity,
                    price: t.price,
                    fees: t.fees,
                    account: account,
                    importBatch: batch,
                    importHashKey: saveKey
                )
                context.insert(tx)
                insertedTxCount += 1
                AMLogging.log("Inserted tx — date: \(t.datePosted), amount: \(adjustedAmount), payee: \(t.payee), hash: \(saveKey))", component: "ImportViewModel")  // DEBUG LOG
                newlyInserted.append(tx)
                batch.transactions.append(tx)
            }
        }

        AMLogging.always("Inserted transactions this batch: \(insertedTxCount) of included: \(includedTransactions.count), excluded: \(excludedCount)", component: "ImportViewModel")

        // Attempt to reconcile transfers across accounts for newly inserted transactions (±3 days)
        do {
            try reconcileTransfers(for: newlyInserted, context: context)
            AMLogging.log("ReconcileTransfers completed for \(newlyInserted.count) inserted transactions", component: "ImportViewModel")  // DEBUG LOG
        } catch {
            AMLogging.log("ReconcileTransfers failed: \(error)", component: "ImportViewModel")  // DEBUG LOG
        }

        // Save holdings (create Security as needed) — attach to the first resolved account if multiple
        var insertedHoldingsCount = 0
        let firstAccountForAssets: Account? = accountsByLabel.values.first
        for h in staged.holdings where (h.include) {
            let accountForHolding = firstAccountForAssets ?? accountsByLabel.values.first
            guard let targetAccount = accountForHolding else { continue }
            let security = fetchOrCreateSecurity(symbol: h.symbol, context: context)
            let hs = HoldingSnapshot(
                asOfDate: h.asOfDate,
                quantity: h.quantity,
                marketValue: h.marketValue,
                account: targetAccount,
                security: security,
                importBatch: batch
            )
            context.insert(hs)
            batch.holdings.append(hs)
            insertedHoldingsCount += 1
            AMLogging.log("Inserted holding — symbol: \(h.symbol), qty: \(h.quantity), mv: \(String(describing: h.marketValue))", component: "ImportViewModel")  // DEBUG LOG
        }

        // Inject brokerage equity snapshots as BalanceSnapshot if not present
        if let firstAccountForAssets, firstAccountForAssets.type == .brokerage {
            let groupedByDate = Dictionary(grouping: staged.holdings.filter { $0.include && $0.marketValue != nil }) { $0.asOfDate }
            for (date, items) in groupedByDate {
                let equity = items.reduce(Decimal.zero) { $0 + ($1.marketValue ?? 0) }
                // Skip zero-equity snapshots
                if equity == .zero { continue }
                // Check if a snapshot already exists for this account/date
                let acctID = firstAccountForAssets.id
                let pred = #Predicate<BalanceSnapshot> { snap in
                    snap.account?.id == acctID && snap.asOfDate == date
                }
                var desc = FetchDescriptor<BalanceSnapshot>(predicate: pred)
                desc.fetchLimit = 1
                let existing = try? context.fetch(desc).first
                if existing == nil {
                    let bs = BalanceSnapshot(
                        asOfDate: date,
                        balance: equity,
                        account: firstAccountForAssets,
                        importBatch: batch
                    )
                    context.insert(bs)
                    batch.balances.append(bs)
                    AMLogging.always("Inserted brokerage equity snapshot — asOf: \(date), value: \(equity), account: \(firstAccountForAssets.name)", component: "ImportViewModel")
                }
            }
        }

        // Save balances — attach to the resolved account per label if available
        var insertedBalancesCount = 0
        let balancesForSave = effectiveIncludedBalances
        for b in balancesForSave {
            let key = allowSplitByLabel ? (normalizedLabel(b.sourceAccountLabel) ?? "default") : "default"
            let targetAccount = accountsByLabel[key] ?? accountsByLabel.values.first
            guard let account = targetAccount else { continue }
            // Skip duplicate snapshot for the same account/date within this batch
            if batch.balances.contains(where: { $0.account?.id == account.id && $0.asOfDate == b.asOfDate }) {
                AMLogging.always("Skipping duplicate balance for account: \(account.name) on \(b.asOfDate)", component: "ImportViewModel")
                continue
            }
            let rawBalance = b.balance
            let coercedBalance: Decimal = {
                if account.type == .loan || account.type == .creditCard {
                    return rawBalance <= 0 ? rawBalance : -rawBalance
                } else {
                    return rawBalance
                }
            }()

            let bs = BalanceSnapshot(
                asOfDate: b.asOfDate,
                balance: coercedBalance,
                interestRateAPR: b.interestRateAPR,
                interestRateScale: b.interestRateScale,
                account: account,
                importBatch: batch
            )
            // Promote APR to account terms if provided on staged balance (loan/credit card only)
            if (account.type == .loan || account.type == .creditCard), let apr = b.interestRateAPR {
                var terms = account.loanTerms ?? LoanTerms()
                terms.apr = apr
                terms.aprScale = b.interestRateScale
                account.loanTerms = terms
                AMLogging.always("Promoted APR to account terms — apr: \(apr) scale: \(String(describing: b.interestRateScale)) account: \(account.name)", component: "ImportViewModel")
            }
            // Prefill due day-of-month from snapshot date (for liabilities) if not set
            if account.type == .loan || account.type == .creditCard {
                var terms = account.loanTerms ?? LoanTerms()
                if terms.paymentDayOfMonth == nil {
                    let cal = Calendar(identifier: .gregorian)
                    let day = cal.component(.day, from: b.asOfDate)
                    terms.paymentDayOfMonth = day
                    AMLogging.always("Applied due day prefill — day: \(day) from asOf: \(b.asOfDate) account: \(account.name)", component: "ImportViewModel")
                    account.loanTerms = terms
                }
            }
            context.insert(bs)
            batch.balances.append(bs)
            insertedBalancesCount += 1
            AMLogging.always("Inserted balance — asOf: \(b.asOfDate), balance: \(coercedBalance), label: \(key), rawLabel: \(b.sourceAccountLabel ?? "(nil)"), allowSplitByLabel: \(allowSplitByLabel), account: \(account.name)", component: "ImportViewModel")
        }

        AMLogging.log("Insert summary — tx: \(insertedTxCount), holdings: \(insertedHoldingsCount), balances: \(insertedBalancesCount)", component: "ImportViewModel")  // DEBUG LOG

        // Only surface an error if nothing at all was saved (no transactions, holdings, or balances)
        if insertedTxCount == 0 && insertedHoldingsCount == 0 && insertedBalancesCount == 0 {
            self.errorMessage = "No new items to save (all duplicates or excluded)."
        } else {
            self.errorMessage = nil
        }

        do {
            try context.save()
            AMLogging.log("Context save succeeded", component: "ImportViewModel")  // DEBUG LOG

            // Debug: post-save counts
            do {
                let totalTx = try context.fetchCount(FetchDescriptor<Transaction>())
                AMLogging.log("Post-save counts — total transactions: \(totalTx)", component: "ImportViewModel")  // DEBUG LOG

                // Additional diagnostics: counts of other models
                let accountCount = try context.fetchCount(FetchDescriptor<Account>())
                let balanceCount = try context.fetchCount(FetchDescriptor<BalanceSnapshot>())
                let holdingCount = try context.fetchCount(FetchDescriptor<HoldingSnapshot>())
                AMLogging.log("Post-save counts — accounts: \(accountCount), balances: \(balanceCount), holdings: \(holdingCount)", component: "ImportViewModel")  // DEBUG LOG

                // Sample a few transactions to verify visibility
                var sampleDesc = FetchDescriptor<Transaction>(
                    sortBy: [SortDescriptor(\Transaction.datePosted, order: .reverse)]
                )
                sampleDesc.fetchLimit = 3
                let samples = try context.fetch(sampleDesc)
                if samples.isEmpty {
                    AMLogging.log("Post-save sample fetch: no transactions returned", component: "ImportViewModel")  // DEBUG LOG
                } else {
                    for (idx, s) in samples.enumerated() {
                        let acctLabel = s.account?.name ?? "(no account)"
                        AMLogging.log("Sample[\(idx)] — date: \(s.datePosted), amount: \(s.amount), payee: \(s.payee), account: \(acctLabel)", component: "ImportViewModel")  // DEBUG LOG
                    }
                }
            } catch {
                AMLogging.log("Post-save diagnostics failed: \(error)", component: "ImportViewModel")  // DEBUG LOG
            }

            // Additional: per-account snapshot of values for debugging Net Worth grouping
            do {
                let accounts = try context.fetch(FetchDescriptor<Account>())
                AMLogging.always("Accounts snapshot (\(accounts.count)):", component: "ImportViewModel")
                for acct in accounts {
                    let latest = try latestBalance(for: acct, context: context)
                    let derived = acct.transactions.reduce(Decimal.zero) { $0 + $1.amount }
                    let value = latest ?? derived
                    AMLogging.always("• \(acct.name) — type: \(acct.type.rawValue), inst: \(acct.institutionName ?? "(nil)"), value: \(value), tx: \(acct.transactions.count), balances: \(acct.balanceSnapshots.count)", component: "ImportViewModel")
                    let payAmt = acct.loanTerms?.paymentAmount
                    AMLogging.always("  loanTerms — paymentAmount=\(String(describing: payAmt)) apr=\(String(describing: acct.loanTerms?.apr))", component: "ImportViewModel")
                }
            } catch {
                AMLogging.always("Accounts snapshot failed: \(error)", component: "ImportViewModel")
            }

            // Notify UI that transactions changed (helps tabs refresh if needed)
            NotificationCenter.default.post(name: .transactionsDidChange, object: nil)
            NotificationCenter.default.post(name: .accountsDidChange, object: nil)
            self.creditCardFlipOverride = nil

            self.detectedTypicalPaymentByLabel = [:]
            self.staged = nil
            self.userInstitutionName = ""
            self.infoMessage = nil
        } catch {
            AMLogging.log("Context save failed: \(error)", component: "ImportViewModel")  // DEBUG LOG
            self.errorMessage = error.localizedDescription
            throw error
        }
    }

    func applyBankMapping() {
        guard let session = mappingSession else { return }
        // Require at least date and (amount or debit/credit)
        guard let dateIdx = session.dateIndex else { return }
        let descIdx = session.descriptionIndex
        let amountIdx = session.amountIndex
        let debitIdx = session.debitIndex
        let creditIdx = session.creditIndex

        // Build rows using the full set of available rows (not only sample)
        // Re-read the last picked file is complex here; for MVP we'll reuse sampleRows as the body and headers as header
        let rows = session.sampleRows
        _ = session.headers

        // Convert to StagedTransactions
        var stagedTx: [StagedTransaction] = []
        let dateFormats = [session.dateFormat].compactMap { $0 } + ["MM/dd/yyyy", "yyyy-MM-dd", "M/d/yyyy"]

        func parseDate(_ s: String) -> Date? {
            for fmt in dateFormats {
                let df = DateFormatter()
                df.locale = Locale(identifier: "en_US_POSIX")
                df.timeZone = TimeZone(secondsFromGMT: 0)
                df.dateFormat = fmt
                if let d = df.date(from: s) { return d }
            }
            return nil
        }

        func sanitize(_ s: String) -> String {
            s.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: "")
        }

        for row in rows {
            let dateStr = row[safe: dateIdx] ?? ""
            guard let date = parseDate(dateStr) else { continue }
            let payee = descIdx.flatMap { row[safe: $0] } ?? "Unknown"

            var amount: Decimal = 0
            if let aIdx = amountIdx, let a = Decimal(string: sanitize(row[safe: aIdx] ?? "")) {
                amount = a
            } else if let dIdx = debitIdx, let dec = Decimal(string: sanitize(row[safe: dIdx] ?? "")) {
                amount = -dec
            } else if let cIdx = creditIdx, let dec = Decimal(string: sanitize(row[safe: cIdx] ?? "")) {
                amount = dec
            } else {
                continue
            }

            let hashKey = Hashing.hashKey(date: date, amount: amount, payee: payee, memo: nil, symbol: nil, quantity: nil)
            let tx = StagedTransaction(
                datePosted: date,
                amount: amount,
                payee: payee,
                memo: nil,
                kind: .bank,
                externalId: nil,
                symbol: nil,
                quantity: nil,
                price: nil,
                fees: nil,
                hashKey: hashKey
            )
            stagedTx.append(tx)
        }

        let stagedImport = StagedImport(
            parserId: "mapping.bank",
            sourceFileName: "Mapped.csv",
            suggestedAccountType: .checking,
            transactions: stagedTx,
            holdings: [],
            balances: []
        )
        self.staged = stagedImport
        self.mappingSession = nil
    }

    private func existingTransactionHashes(for account: Account, context: ModelContext) throws -> Set<String> {
        let keys = account.transactions.map { $0.importHashKey ?? $0.hashKey }
        return Set(keys)
    }

    private func fetchOrCreateSecurity(symbol: String, context: ModelContext) -> Security {
        if let s = try? context.fetch(FetchDescriptor<Security>()).first(where: { $0.symbol == symbol }) {
            return s
        }
        let sec = Security(symbol: symbol)
        context.insert(sec)
        return sec
    }

    // Normalize institution names for matching (e.g., "Fidelity" vs "Fidelity Investments")
    private func normalizeInstitutionName(_ raw: String?) -> String {
        guard let raw = raw else { return "" }
        let lower = raw.lowercased()
        // Replace punctuation with spaces, collapse multiple spaces, and split into tokens
        let separators = CharacterSet(charactersIn: ",./-_&()[]{}:")
        let spaced = lower.components(separatedBy: separators).joined(separator: " ")
        let tokens = spaced
            .split(separator: " ")
            .map { String($0) }
        // Remove common suffix/generic tokens that shouldn't affect identity
        let banned: Set<String> = [
            "investment", "investments", "inc", "corp", "co", "company", "llc", "l.l.c", "na", "n.a", "services", "financial", "fsb"
        ]
        let filtered = tokens.filter { !banned.contains($0) }
        // Join without spaces for robust comparison
        return filtered.joined()
    }

    // Find an existing account by type and institution name (case-insensitive)
    private func findAccount(ofType type: Account.AccountType, institutionName: String, context: ModelContext) -> Account? {
        let needle = normalizeInstitutionName(institutionName)
        if let accounts = try? context.fetch(FetchDescriptor<Account>()) {
            return accounts.first { acct in
                guard acct.type == type else { return false }
                let hay = normalizeInstitutionName(acct.institutionName)
                return hay == needle && !hay.isEmpty
            }
        }
        return nil
    }

    // Infer an institution name from a downloaded file name (best-effort)
    func guessInstitutionName(from fileName: String) -> String? {
        let base = (fileName as NSString).deletingPathExtension
        let lower = base.lowercased()
        let normalized = lower
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")

        let known: [(pattern: String, display: String)] = [
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
            ("discover", "Discover"),
            ("citibank", "Citi"),
            ("citi", "Citi"),
            ("chase", "Chase"),
            ("sofi", "SoFi")
        ]
        if let match = known.first(where: { normalized.contains($0.pattern) }) {
            return match.display
        }

        // No fallback to tokens from filename — require explicit user input if no known match
        return nil
    }

    // Best-effort account type inference from filename/headers and sample row content
    private func guessAccountType(from fileName: String, headers: [String], sampleRows: [[String]]) -> Account.AccountType? {
        AMLogging.always("GuessAccountType: start — file: \(fileName), headers: \(headers)", component: "ImportViewModel")

        let normalizedFile = fileName
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")

        let lowerHeaders = headers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

        // 1) Brokerage signals in headers
        let brokerageHeaderSignals = [
            "symbol", "ticker", "cusip", "qty", "quantity", "shares", "share", "price", "security",
            "securities", "stock", "stocks", "equity", "equities", "option", "options", "portfolio", "market value", "cost basis"
        ]
        let hasBrokerageHeader = lowerHeaders.contains { h in
            brokerageHeaderSignals.contains { sig in h == sig || h.contains(sig) }
        }
        AMLogging.always("GuessAccountType: hasBrokerageHeader=\(hasBrokerageHeader)", component: "ImportViewModel")
        if hasBrokerageHeader {
            AMLogging.always("GuessAccountType: returning .brokerage due to header", component: "ImportViewModel")
            return .brokerage
        }

        // 2) Brokerage signals in row descriptions (buy/sell/dividend/options, etc.)
        // Try to find a likely description column
        func probableDescriptionIndex() -> Int? {
            let keys = ["description", "activity", "action", "details", "detail", "type", "transaction type"]
            for (idx, h) in lowerHeaders.enumerated() {
                if keys.contains(where: { h == $0 || h.contains($0) }) { return idx }
            }
            return nil
        }
        let descIdx = probableDescriptionIndex()
        AMLogging.always("GuessAccountType: probable description index=\(String(describing: descIdx))", component: "ImportViewModel")
        let brokerageKeywords = [
            "buy", "bought", "sell", "sold", "dividend", "reinvest", "reinvestment", "interest", "cap gain", "capital gain",
            "distribution", "split", "spinoff", "spin-off", "option", "call", "put", "exercise", "assign", "assignment", "expiration",
            "short", "cover"
        ]
        var brokerageHits = 0
        for row in sampleRows {
            let text: String = {
                if let i = descIdx, row.indices.contains(i) { return row[i] } else { return row.joined(separator: " ") }
            }().lowercased()
            if brokerageKeywords.contains(where: { text.contains($0) }) {
                brokerageHits += 1
                if brokerageHits >= 2 { break }
            }
        }
        AMLogging.always("GuessAccountType: brokerage keyword hits=\(brokerageHits)", component: "ImportViewModel")
        if brokerageHits >= 2 || (brokerageHits == 1 && sampleRows.count <= 5) {
            AMLogging.always("GuessAccountType: returning .brokerage due to keyword hits", component: "ImportViewModel")
            return .brokerage
        }

        // 3) Credit card heuristics (applied only if no brokerage signals)
        // 3a) Credit card heuristics (common phrases on card statements)
        let ccHeaderSignals = [
            "credit card", "card number", "new balance", "minimum payment", "payment due", "credit limit", "late fee", "interest charge"
        ]
        let hasCCHeader = lowerHeaders.contains { h in
            ccHeaderSignals.contains { sig in h == sig || h.contains(sig) }
        }

        let ccRowSignals = [
            "minimum payment", "payment due", "new balance", "previous balance", "late payment warning", "payment due date",
            "credit limit", "interest charge", "purchases", "fees charged", "cash advances"
        ]
        var ccHits = 0
        for row in sampleRows {
            let text = row.joined(separator: " ").lowercased()
            if ccRowSignals.contains(where: { text.contains($0) }) {
                ccHits += 1
                if ccHits >= 2 { break }
            }
        }
        if hasCCHeader || ccHits >= 2 {
            AMLogging.always("GuessAccountType: returning .creditCard due to credit card signals (headers=\(hasCCHeader), hits=\(ccHits))", component: "ImportViewModel")
            return .creditCard
        }

        // 3b) Loan heuristics (detect loan/mortgage statements that contain 'amount due' or 'past due' style phrases)
        let loanHeaderSignals = [
            "loan", "mortgage", "auto loan", "student loan", "home equity", "heloc", "installment"
        ]
        let hasLoanHeader = lowerHeaders.contains { h in
            loanHeaderSignals.contains { sig in h == sig || h.contains(sig) }
        }

        // Scan sample rows for phrases indicating amount due or past due (common on loan statements)
        let loanRowSignals = [
            "current amount due", "amount due", "minimum amount due", "total amount due",
            "past due amount", "past-due amount", "payment due", "due date",
            "principal balance", "outstanding principal", "original balance", "escrow", "late fee"
        ]
        var loanHits = 0
        for row in sampleRows {
            let text = row.joined(separator: " ").lowercased()
            if loanRowSignals.contains(where: { text.contains($0) }) {
                loanHits += 1
                if loanHits >= 2 { break }
            }
        }

        if hasLoanHeader || loanHits >= 2 {
            AMLogging.always("GuessAccountType: returning .loan due to loan signals (headers=\(hasLoanHeader), hits=\(loanHits))", component: "ImportViewModel")
            return .loan
        }

        // 4) Filename-based hints (fallback only)
        if normalizedFile.contains("creditcard") || (normalizedFile.contains("credit") && normalizedFile.contains("card")) || normalizedFile.contains("cc") {
            AMLogging.always("GuessAccountType: returning .creditCard due to filename heuristic", component: "ImportViewModel")
            return .creditCard
        }

        if normalizedFile.contains("ira") || normalizedFile.contains("roth") || normalizedFile.contains("401k") || normalizedFile.contains("brokerage") || normalizedFile.contains("investment") || normalizedFile.contains("retirement") {
            AMLogging.always("GuessAccountType: returning .brokerage due to filename heuristic", component: "ImportViewModel")
            return .brokerage
        }

        // 5) Fallback to user hint if nothing else matched
        if let hint = self.userSelectedDocHint {
            AMLogging.always("GuessAccountType: falling back to user hint -> \(hint.rawValue)", component: "ImportViewModel")
            return hint
        }
        AMLogging.always("GuessAccountType: no match — returning nil", component: "ImportViewModel")
        return nil
    }

    // Map a normalized source account label to an Account.AccountType
    // Currently recognizes common bank labels we emit from PDF/CSV (e.g., "checking", "savings").
    private func typeForLabel(_ label: String) -> Account.AccountType? {
        let lower = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch lower {
        case "checking":
            return .checking
        case "savings":
            return .savings
        case "brokerage":
            return .brokerage
        case "loan", "mortgage":
            return .loan
        case "creditcard", "credit card":
            return .creditCard
        default:
            return nil
        }
    }
    // Helpers for diagnostics
    private func latestBalance(for account: Account, context: ModelContext) throws -> Decimal? {
        let accountID = account.id
        let predicate = #Predicate<BalanceSnapshot> { snap in
            snap.account?.id == accountID
        }
        var descriptor = FetchDescriptor<BalanceSnapshot>(predicate: predicate)
        descriptor.sortBy = [SortDescriptor(\BalanceSnapshot.asOfDate, order: .reverse)]
        descriptor.fetchLimit = 1
        let snapshots = try context.fetch(descriptor)
        return snapshots.first?.balance
    }

    private func derivedBalanceFromTransactions(for account: Account) -> Decimal {
        return account.transactions.reduce(Decimal.zero) { $0 + $1.amount }
    }

    // MARK: - Transfer reconciliation
    private func reconcileTransfers(for insertedTransactions: [Transaction], context: ModelContext) throws {
        // Link likely transfer pairs across different accounts within a ±3 day window
        let dayWindow: TimeInterval = 3 * 24 * 60 * 60

        // Fetch all transactions once and filter in-memory for simplicity and reliability
        var descriptor = FetchDescriptor<Transaction>()
        descriptor.sortBy = [SortDescriptor(\Transaction.datePosted)]
        let allTx = try context.fetch(descriptor)

        for tx in insertedTransactions {
            // Skip if already linked or not a bank-like transaction
            guard tx.linkedTransactionId == nil, tx.kind == .bank else { continue }

            let thisAccountID = tx.account?.id
            let absAmount = (tx.amount as NSDecimalNumber).decimalValue.magnitude
            let startDate = tx.datePosted.addingTimeInterval(-dayWindow)
            let endDate = tx.datePosted.addingTimeInterval(dayWindow)

            // Candidates in other accounts with opposite sign, same magnitude, and within window
            let candidates = allTx.filter { cand in
                guard cand.id != tx.id,
                      cand.account?.id != thisAccountID,
                      cand.linkedTransactionId == nil,
                      cand.kind == .bank else { return false }

                let oppositeSign = (cand.amount < 0) != (tx.amount < 0)
                let sameMagnitude = ((cand.amount as NSDecimalNumber).decimalValue.magnitude == absAmount)
                let withinWindow = (cand.datePosted >= startDate && cand.datePosted <= endDate)
                return oppositeSign && sameMagnitude && withinWindow
            }

            // Choose the closest by date
            let best = candidates.min { a, b in
                abs(a.datePosted.timeIntervalSince(tx.datePosted)) < abs(b.datePosted.timeIntervalSince(tx.datePosted))
            }

            if let match = best {
                tx.kind = .transfer
                match.kind = .transfer
                tx.linkedTransactionId = match.id
                match.linkedTransactionId = tx.id

                // Optional memo annotation to aid UI/debugging
                if let aName = tx.account?.name, let bName = match.account?.name {
                    let note = "Linked transfer: \(aName) ⇄ \(bName)"
                    if (tx.memo ?? "").isEmpty { tx.memo = note }
                    if (match.memo ?? "").isEmpty { match.memo = note }
                }
            }
        }
    }

    // MARK: - Hard delete of import batches
    static func hardDelete(batch: ImportBatch, context: ModelContext) throws {
        // Capture candidate accounts referenced by this batch so we can clean them up if they become empty after deletion
        let candidateAccountIDs: Set<UUID> = {
            var ids = Set<UUID>()
            for tx in batch.transactions { if let id = tx.account?.id { ids.insert(id) } }
            for h in batch.holdings { if let id = h.account?.id { ids.insert(id) } }
            for b in batch.balances { if let id = b.account?.id { ids.insert(id) } }
            return ids
        }()

        // Delete child objects first to avoid dangling relationships
        for tx in batch.transactions {
            context.delete(tx)
        }
        for h in batch.holdings {
            context.delete(h)
        }
        for b in batch.balances {
            context.delete(b)
        }
        // Delete the batch itself
        context.delete(batch)

        try context.save()

        // Removed notification calls here as per instructions

        // After deleting the batch, remove any now-empty accounts that were associated with it
        var deletedAccounts = 0
        for acctID in candidateAccountIDs {
            let predicate = #Predicate<Account> { $0.id == acctID }
            var descriptor = FetchDescriptor<Account>(predicate: predicate)
            descriptor.fetchLimit = 1
            if let account = try? context.fetch(descriptor).first {
                let isEmpty = account.transactions.isEmpty && account.holdingSnapshots.isEmpty && account.balanceSnapshots.isEmpty
                if isEmpty {
                    AMLogging.always("Deleting empty account after batch deletion — id: \(account.id), name: \(account.name)", component: "ImportViewModel")
                    context.delete(account)
                    deletedAccounts += 1
                }
            }
        }
        if deletedAccounts > 0 {
            try context.save()
        }

        // Notify UI layers once, after all deletions are finalized
        NotificationCenter.default.post(name: .transactionsDidChange, object: nil)
        NotificationCenter.default.post(name: .accountsDidChange, object: nil)
    }

    static func hardDeleteAllBatches(context: ModelContext) throws {
        let batches = try context.fetch(FetchDescriptor<ImportBatch>())
        for batch in batches {
            for tx in batch.transactions { context.delete(tx) }
            for h in batch.holdings { context.delete(h) }
            for b in batch.balances { context.delete(b) }
            context.delete(batch)
        }
        try context.save()

        NotificationCenter.default.post(name: .transactionsDidChange, object: nil)
        NotificationCenter.default.post(name: .accountsDidChange, object: nil)
    }

    /*
     What comes next:
     - Replace Batch: Add a flow to pick a new file, parse to staged import, then match/update existing items in the batch by importHashKey. Non-matching old items will be removed; matching items will be updated unless user-modified.
     - Edit Screens: Add transaction/balance/holding edit sheets with an exclude toggle and user-modified flag so manual changes are preserved across re-imports.
     - Batch Tools: Provide per-batch actions (flip signs, reassign account, delete/undo) from a Batch Detail screen.
    */

    // MARK: - Replace existing batch with staged import (preserving user edits)
    /// Replaces the content of an existing ImportBatch with a newly parsed staged import.
    /// Matching is by immutable importHashKey for transactions, by asOfDate for balances,
    /// and by (symbol, asOfDate) for holdings. Items marked `isUserModified` are left untouched.
    /// Returns counts of updates/inserts/deletes for summary display.
    static func replaceBatch(
        batch: ImportBatch,
        with staged: StagedImport,
        context: ModelContext,
        forceUpdateTxKeys: Set<String> = [],
        forceUpdateBalanceDates: Set<Date> = [],
        forceUpdateHoldingKeys: Set<String> = []
    ) throws -> (
        updatedTx: Int, insertedTx: Int, deletedTx: Int,
        updatedBalances: Int, insertedBalances: Int, deletedBalances: Int,
        updatedHoldings: Int, insertedHoldings: Int, deletedHoldings: Int
    ) {
        // TRANSACTIONS
        var updatedTx = 0, insertedTx = 0, deletedTx = 0
        let existingTx = batch.transactions
        let existingTxMap: [String: Transaction] = existingTx.reduce(into: [:]) { acc, tx in
            let key = tx.importHashKey ?? tx.hashKey
            acc[key] = tx
        }
        let stagedTxMap: [String: StagedTransaction] = staged.transactions.reduce(into: [:]) { acc, t in
            acc[t.hashKey] = t
        }

        // Update or insert
        for (key, st) in stagedTxMap {
            if let ex = existingTxMap[key] {
                // Update only if not user-modified or forced update present
                if !ex.isUserModified || forceUpdateTxKeys.contains(key) {
                    ex.datePosted = st.datePosted
                    ex.amount = st.amount
                    ex.payee = st.payee
                    ex.memo = st.memo
                    ex.kind = st.kind
                    ex.externalId = st.externalId
                    ex.symbol = st.symbol
                    ex.quantity = st.quantity
                    ex.price = st.price
                    ex.fees = st.fees
                    // Recompute visible hashKey to match new values; keep importHashKey stable
                    ex.hashKey = Hashing.hashKey(
                        date: ex.datePosted,
                        amount: ex.amount,
                        payee: ex.payee,
                        memo: ex.memo,
                        symbol: ex.symbol,
                        quantity: ex.quantity
                    )
                    if forceUpdateTxKeys.contains(key) {
                        ex.isUserModified = false
                        ex.isUserEdited = false
                    }
                    updatedTx &+= 1
                }
            } else {
                // Insert: choose an account from existing batch context (prefer first tx account, else any from balances/holdings)
                let account: Account? = {
                    if let a = batch.transactions.first?.account { return a }
                    if let a = batch.balances.first?.account { return a }
                    if let a = batch.holdings.first?.account { return a }
                    return nil
                }()
                guard let targetAccount = account else { continue }
                let saveKey = Hashing.hashKey(
                    date: st.datePosted,
                    amount: st.amount,
                    payee: st.payee,
                    memo: st.memo,
                    symbol: st.symbol,
                    quantity: st.quantity
                )
                let tx = Transaction(
                    datePosted: st.datePosted,
                    amount: st.amount,
                    payee: st.payee,
                    memo: st.memo,
                    kind: st.kind,
                    externalId: st.externalId,
                    hashKey: saveKey,
                    symbol: st.symbol,
                    quantity: st.quantity,
                    price: st.price,
                    fees: st.fees,
                    account: targetAccount,
                    importBatch: batch,
                    isUserCreated: false,
                    isUserEdited: false,
                    isExcluded: false,
                    isUserModified: false,
                    importHashKey: key
                )
                context.insert(tx)
                batch.transactions.append(tx)
                insertedTx &+= 1
            }
        }

        // Delete existing that are not in staged (and not user-modified)
        for ex in existingTx {
            let key = ex.importHashKey ?? ex.hashKey
            if stagedTxMap[key] == nil && !ex.isUserModified {
                context.delete(ex)
                deletedTx &+= 1
            }
        }

        // BALANCES — match by asOfDate
        var updatedBalances = 0, insertedBalances = 0, deletedBalances = 0
        let existingBalances = batch.balances
        let existingBalMap: [Date: BalanceSnapshot] = existingBalances.reduce(into: [:]) { acc, b in acc[b.asOfDate] = b }
        let stagedBalMap: [Date: StagedBalance] = staged.balances.reduce(into: [:]) { acc, b in acc[b.asOfDate] = b }

        for (date, sb) in stagedBalMap {
            if let ex = existingBalMap[date] {
                if !ex.isUserModified || forceUpdateBalanceDates.contains(date) {
                    ex.balance = sb.balance
                    ex.interestRateAPR = sb.interestRateAPR
                    ex.interestRateScale = sb.interestRateScale
                    // Promote APR to account.loanTerms when updating an existing snapshot for liabilities
                    if let acct = ex.account,
                       (acct.type == .loan || acct.type == .creditCard),
                       let apr = sb.interestRateAPR {
                        var terms = acct.loanTerms ?? LoanTerms()
                        terms.apr = apr
                        terms.aprScale = sb.interestRateScale
                        acct.loanTerms = terms
                    }
                    if forceUpdateBalanceDates.contains(date) {
                        ex.isUserModified = false
                    }
                    updatedBalances &+= 1
                }
            } else {
                let account: Account? = {
                    if let a = batch.balances.first?.account { return a }
                    if let a = batch.transactions.first?.account { return a }
                    if let a = batch.holdings.first?.account { return a }
                    return nil
                }()
                if let acct = account {
                    let bs = BalanceSnapshot(
                        asOfDate: date,
                        balance: sb.balance,
                        interestRateAPR: sb.interestRateAPR,
                        interestRateScale: sb.interestRateScale,
                        account: acct,
                        importBatch: batch
                    )
                    // Promote APR to account.loanTerms when inserting a new snapshot for liabilities
                    if (acct.type == .loan || acct.type == .creditCard),
                       let apr = sb.interestRateAPR {
                        var terms = acct.loanTerms ?? LoanTerms()
                        terms.apr = apr
                        terms.aprScale = sb.interestRateScale
                        acct.loanTerms = terms
                    }
                    context.insert(bs)
                    batch.balances.append(bs)
                    insertedBalances &+= 1
                }
            }
        }
        for ex in existingBalances {
            if stagedBalMap[ex.asOfDate] == nil && !ex.isUserModified {
                context.delete(ex)
                deletedBalances &+= 1
            }
        }

        // HOLDINGS — match by (symbol, asOfDate)
        var updatedHoldings = 0, insertedHoldings = 0, deletedHoldings = 0
        func holdingKey(_ h: HoldingSnapshot) -> String { "\(h.security?.symbol ?? "")@\(h.asOfDate.timeIntervalSince1970)" }
        func stagedHoldingKey(_ h: StagedHolding) -> String { "\(h.symbol)@\(h.asOfDate.timeIntervalSince1970)" }

        let existingHoldMap: [String: HoldingSnapshot] = batch.holdings.reduce(into: [:]) { acc, h in acc[holdingKey(h)] = h }
        let stagedHoldMap: [String: StagedHolding] = staged.holdings.reduce(into: [:]) { acc, h in acc[stagedHoldingKey(h)] = h }

        for (key, sh) in stagedHoldMap {
            let hKey = key
            if let ex = existingHoldMap[key] {
                if !ex.isUserModified || forceUpdateHoldingKeys.contains(hKey) {
                    ex.quantity = sh.quantity
                    ex.marketValue = sh.marketValue
                    if forceUpdateHoldingKeys.contains(hKey) {
                        ex.isUserModified = false
                    }
                    updatedHoldings &+= 1
                }
            } else {
                let account: Account? = {
                    if let a = batch.holdings.first?.account { return a }
                    if let a = batch.transactions.first?.account { return a }
                    if let a = batch.balances.first?.account { return a }
                    return nil
                }()
                if let acct = account {
                    let sec = Security(symbol: sh.symbol)
                    context.insert(sec)
                    let hs = HoldingSnapshot(asOfDate: sh.asOfDate, quantity: sh.quantity, marketValue: sh.marketValue, account: acct, security: sec, importBatch: batch)
                    context.insert(hs)
                    batch.holdings.append(hs)
                    insertedHoldings &+= 1
                }
            }
        }
        for ex in batch.holdings {
            if stagedHoldMap[holdingKey(ex)] == nil && !ex.isUserModified {
                context.delete(ex)
                deletedHoldings &+= 1
            }
        }

        try context.save()
        NotificationCenter.default.post(name: .transactionsDidChange, object: nil)
        NotificationCenter.default.post(name: .accountsDidChange, object: nil)

        return (
            updatedTx, insertedTx, deletedTx,
            updatedBalances, insertedBalances, deletedBalances,
            updatedHoldings, insertedHoldings, deletedHoldings
        )
    }
}

struct MappingSession {
    enum Kind { case bank }
    var kind: Kind
    var headers: [String]
    var sampleRows: [[String]]
    // User-selected column indices
    var dateIndex: Int?
    var descriptionIndex: Int?
    var amountIndex: Int?
    var debitIndex: Int?
    var creditIndex: Int?
    var balanceIndex: Int?
    var dateFormat: String? // optional override
}
extension Notification.Name {
    static let transactionsDidChange = Notification.Name("TransactionsDidChange")
    static let accountsDidChange = Notification.Name("AccountsDidChange")
}
private extension Array {
    subscript(safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}

