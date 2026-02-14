import Foundation

private let LOG_COMPONENT = "PDFSummaryParser"

struct PDFSummaryParser: StatementParser {
    static var id: String { "pdf.summary" }

    func canParse(headers: [String]) -> Bool {
        // Expect normalized headers from PDFStatementExtractor: date, description, amount, balance
        let lower = headers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard lower.contains("date"), lower.contains("description"), lower.contains("amount"), lower.contains(where: { $0.contains("balance") }) else {
            return false
        }
        // Heuristic: look for summary description tokens in the first few rows if available
        // The ImportViewModel passes all rows, but we can't see them here; canParse is headers-only.
        // We'll be permissive here and rely on parse() to validate rows strictly.
        return true
    }

    func parse(rows: [[String]], headers: [String]) throws -> StagedImport {
        // Build a header map for robust access
        let map = headerMap(headers)
        var balances: [StagedBalance] = []
        var typicalPaymentSentinelInserted = false

        func normalizeSpaces(_ s: String) -> String {
            if s.isEmpty { return s }
            var out = String()
            out.reserveCapacity(s.count)
            var lastWasSpace = false
            for scalar in s.unicodeScalars {
                let isWS = CharacterSet.whitespacesAndNewlines.contains(scalar) || scalar == "\u{00A0}" // NBSP
                if isWS {
                    if !lastWasSpace { out.append(" ") }
                    lastWasSpace = true
                } else {
                    out.unicodeScalars.append(scalar)
                    lastWasSpace = false
                }
            }
            return out.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        AMLogging.log("PDFSummaryParser.parse: rows=\(rows.count) headers=\(headers)", component: LOG_COMPONENT)
        let docProbe = normalizeSpaces(rows.flatMap { $0 }.joined(separator: " ")).lowercased()
        AMLogging.log("PDFSummaryParser.parse: doc length=\(docProbe.count) purchasesTokenCount=\(max(0, docProbe.components(separatedBy: "purchase").count - 1))", component: LOG_COMPONENT)

        // Helper to parse dates in the normalized format from PDFStatementExtractor (MM/dd/yyyy)
        func parseDate(_ s: String) -> Date? {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone(secondsFromGMT: 0)
            for fmt in [
                "MM/dd/yyyy", "M/d/yy", "MM/dd/yy", "M/d/yyyy",
                "MMMM d, yyyy", "MMM d, yyyy", "MMMM dd, yyyy", "MMM dd, yyyy",
                "MMMM d yyyy", "MMM d yyyy"
            ] {
                df.dateFormat = fmt
                if let d = df.date(from: s) { return d }
            }
            return nil
        }

        func extractStatementClosingDate(from rows: [[String]]) -> Date? {
            let doc = normalizeSpaces(rows.flatMap { $0 }.joined(separator: " "))

            // Pattern 1: explicit range like "12/21/2025 - 01/20/2026" or with en dash or "to"
            let rangePattern = #"\b(\d{1,2}/\d{1,2}/\d{2,4})\s*(?:–|-|to)\s*(\d{1,2}/\d{1,2}/\d{2,4})\b"#
            if let rx = try? NSRegularExpression(pattern: rangePattern, options: []),
               let m = rx.firstMatch(in: doc, options: [], range: NSRange(doc.startIndex..<doc.endIndex, in: doc)),
               m.numberOfRanges >= 3,
               let r2 = Range(m.range(at: 2), in: doc) {
                let endStr = String(doc[r2])
                if let d = parseDate(endStr) { return d }
            }

            // Pattern 2: labeled closing date
            let labelPattern = #"(?:statement\s+closing\s+date|closing\s+date|cycle\s+ending|period\s+ending)\s*[:\-]?\s*(\d{1,2}/\d{1,2}/\d{2,4})"#
            if let rx = try? NSRegularExpression(pattern: labelPattern, options: [.caseInsensitive]),
               let m = rx.firstMatch(in: doc, options: [], range: NSRange(doc.startIndex..<doc.endIndex, in: doc)),
               m.numberOfRanges >= 2,
               let r1 = Range(m.range(at: 1), in: doc) {
                let endStr = String(doc[r1])
                if let d = parseDate(endStr) { return d }
            }

            // Pattern 2b: labeled closing date with spelled-out month (e.g., "Closing Date January 13, 2026")
            let labelPatternWords = #"(?:statement\s+closing\s+date|closing\s+date|cycle\s+ending|period\s+ending)\s*[:\-]?\s*([A-Za-z]{3,9}\s+\d{1,2}(?:,\s*\d{4})?)"#
            if let rx = try? NSRegularExpression(pattern: labelPatternWords, options: [.caseInsensitive]),
               let m = rx.firstMatch(in: doc, options: [], range: NSRange(doc.startIndex..<doc.endIndex, in: doc)),
               m.numberOfRanges >= 2,
               let r1 = Range(m.range(at: 1), in: doc) {
                let endStr = String(doc[r1])
                if let d = parseDate(endStr) { return d }
            }

            // Pattern 2c: "New Balance as of <Month DD, YYYY>"
            let newBalWords = #"(?:new\s+balance)\s+(?:as\s+of)\s*([A-Za-z]{3,9}\s+\d{1,2}(?:,\s*\d{4})?)"#
            if let rx = try? NSRegularExpression(pattern: newBalWords, options: [.caseInsensitive]),
               let m = rx.firstMatch(in: doc, options: [], range: NSRange(doc.startIndex..<doc.endIndex, in: doc)),
               m.numberOfRanges >= 2,
               let r1 = Range(m.range(at: 1), in: doc) {
                let endStr = String(doc[r1])
                if let d = parseDate(endStr) { return d }
            }

            // Pattern 3: Payment Due Date fallback — subtract one month
            let duePattern = #"(?:payment\s+due\s+date)\s*[:\-]?\s*(\d{1,2}/\d{1,2}/\d{2,4})"#
            if let rx = try? NSRegularExpression(pattern: duePattern, options: [.caseInsensitive]),
               let m = rx.firstMatch(in: doc, options: [], range: NSRange(doc.startIndex..<doc.endIndex, in: doc)),
               m.numberOfRanges >= 2,
               let r1 = Range(m.range(at: 1), in: doc) {
                let dueStr = String(doc[r1])
                if let due = parseDate(dueStr),
                   let approx = Calendar.current.date(byAdding: DateComponents(month: -1), to: due) {
                    return approx
                }
            }
            
            // Pattern 3b: Payment Due Date fallback with spelled-out month — subtract one month
            let dueWords = #"(?:payment\s+due\s+date)\s*[:\-]?\s*([A-Za-z]{3,9}\s+\d{1,2}(?:,\s*\d{4})?)"#
            if let rx = try? NSRegularExpression(pattern: dueWords, options: [.caseInsensitive]),
               let m = rx.firstMatch(in: doc, options: [], range: NSRange(doc.startIndex..<doc.endIndex, in: doc)),
               m.numberOfRanges >= 2,
               let r1 = Range(m.range(at: 1), in: doc) {
                let dueStr = String(doc[r1])
                if let due = parseDate(dueStr),
                   let approx = Calendar.current.date(byAdding: DateComponents(month: -1), to: due) {
                    return approx
                }
            }
            
            return nil
        }
        func normalizedLabel(_ raw: String?) -> String? {
            guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !s.isEmpty else { return nil }
            if s.contains("checking") { return "checking" }
            if s.contains("savings") { return "savings" }
            // Recognize brokerage/investment-related labels
            if s.contains("brokerage") || s.contains("investment") || s.contains("ira") || s.contains("roth") || s.contains("401k") || s.contains("stock") || s.contains("options") || s.contains("portfolio") {
                return "brokerage"
            }
            // Recognize loan-related labels
            if s.contains("loan") || s.contains("mortgage") || s.contains("home equity") || s.contains("principal balance") || s.contains("outstanding principal") {
                return "loan"
            }
            return nil
        }

        func decimalPlaces(in token: String) -> Int {
            if let dot = token.firstIndex(of: ".") {
                return token.distance(from: token.index(after: dot), to: token.endIndex)
            }
            return 0
        }

        func extractAPRAndScale(from text: String) -> (value: Decimal, scale: Int)? {
            let lower = text.lowercased()
            let fullRange = NSRange(lower.startIndex..<lower.endIndex, in: lower)

            // Pattern 1: labeled numbers (APR or Interest Rate preceding the value)
            let labelPattern = #"(?:(?:interest\s*rate)|apr)[^0-9%]{0,64}([0-9]{1,3}(?:\.[0-9]{1,4})?)\s*%?"#
            // Pattern 2: bare percentage numbers (table cells like "26.99%" under an APR column)
            let barePattern = #"([0-9]{1,3}(?:\.[0-9]{1,4})?)\s*%"#

            guard let labelRegex = try? NSRegularExpression(pattern: labelPattern, options: [.caseInsensitive]),
                  let bareRegex = try? NSRegularExpression(pattern: barePattern, options: [.caseInsensitive]) else {
                return nil
            }

            // Context words that usually indicate fees or warnings rather than purchase APRs
            let badWords = [
                "fee", "minimum", "min", "of the new balance", "transaction fee",
                "foreign", "balance transfer fee", "cash advance fee", "late fee", "overlimit",
                "penalty", "penalty apr", "late payment", "late payment warning"
            ]
            let promoWords = ["promo", "promotional", "intro", "introductory", "offer"]

            // Removed purchaseWords line here as per instructions
            // let purchaseWords = ["purchase", "purchases", "purchase apr"]
            let demoteWords = ["cash advance", "balance transfer"]
            let priorWords = ["prior to", "previous"]

            let headerWords = ["annual percentage rate", "interest charges", "balance type", "interest rate", "annual interest rate", "interest charge calculation", "interest charge"]

            // Banking/deposit contexts that should not be treated as credit-card APRs
            let bankingWords = [
                "savings", "checking", "statement ending balance", "statement beginning balance",
                "annual percentage yield", "apy", "money market", "certificate of deposit", "cd"
            ]
            let liabilityWords = [
                "loan", "mortgage", "home equity", "principal balance", "outstanding principal", "current amount due", "amount due", "payment due", "estimated monthly payment"
            ]

            // Additional disqualifying contexts for rewards and FX/fees
            let rewardWords = [
                "cash back", "cashback", "rewards", "points", "miles", "bonus", "bonus category",
                "category", "dining", "drugstore", "groceries", "gas", "travel"
            ]
            let fxWords = [
                "foreign transaction", "foreign exchange", "international transaction", "currency conversion", "conversion fee"
            ]
            let feeWords = [
                "transaction fee", "monthly fee", "fee-based", "pay over time"
            ]

            // Regex to detect ranges like "24.24% – 29.99%" or "24.24%-29.99%" or "24.24 to 29.99%"
            let rangePattern = #"([0-9]{1,3}(?:\.[0-9]{1,4})?)\s*%?\s*(?:–|-|to)\s*([0-9]{1,3}(?:\.[0-9]{1,4})?)\s*%?"#
            let rangeRegex = try? NSRegularExpression(pattern: rangePattern, options: [.caseInsensitive])

            // Document-level penalty indicator within the provided text scope
            let docHasPenalty = lower.contains("penalty apr") || lower.contains("late payment warning") || lower.contains("penalty")

            struct Candidate { let value: Decimal; let scale: Int; let score: Int; let isRange: Bool; let isUpper: Bool; let source: String }
            var candidates: [Candidate] = []

            func evaluateMatch(token: String, matchRange: NSRange, source: String) {
                guard var val = Decimal(string: token) else { return }
                let scale = decimalPlaces(in: token)
                if val > 1 { val /= 100 } // convert percent to fraction when given as percent number

                // Build a context window around the match to filter out non-APR matches
                let contextStart = max(0, matchRange.location - 260)
                let contextEnd = min(fullRange.length, matchRange.location + matchRange.length + 300)
                let ctxRange = NSRange(location: contextStart, length: contextEnd - contextStart)
                let ctx: String
                if let swiftRange = Range(ctxRange, in: lower) {
                    ctx = String(lower[swiftRange])
                } else {
                    ctx = lower
                }
                let ctxPreview = String(ctx.prefix(220))

                let hasHeaderContext = headerWords.contains(where: { ctx.contains($0) })
                let hasRewardContext = rewardWords.contains(where: { ctx.contains($0) })
                let hasFXContext = fxWords.contains(where: { ctx.contains($0) })
                let hasFeeContext = feeWords.contains(where: { ctx.contains($0) })
                // Replace hasPurchaseContext logic with updated version
                let purchasesStandalone = (ctx.range(of: #"\bpurchases\b(?!\s*(?:before|prior|previous))"#, options: [.regularExpression]) != nil) || ctx.contains("purchase apr")
                let hasPurchaseContext = !hasRewardContext && purchasesStandalone

                let hasBankingContext = bankingWords.contains(where: { ctx.contains($0) })
                let hasLiabilityContext = liabilityWords.contains(where: { ctx.contains($0) })
                let hasAprToken = ctx.contains("apr") || ctx.contains("annual percentage rate")

                AMLogging.log(
                    "APR eval: token=\(token) val=\(val) scale=\(scale) source=\(source) hdr=\(hasHeaderContext) purch=\(hasPurchaseContext) rewards=\(hasRewardContext) fx=\(hasFXContext) fee=\(hasFeeContext) bank=\(hasBankingContext) penaltyDoc=\(docHasPenalty) ctx='\(ctxPreview)'",
                    component: LOG_COMPONENT
                )

                // Reject clear banking/deposit contexts unless APR/purchases cues exist,
                // or we have a liability context (loan/mortgage) where 'interest rate' is expected.
                // Modified per instructions to allow header context to exempt rejection
                if hasBankingContext && !hasPurchaseContext && !hasAprToken && !hasLiabilityContext && !hasHeaderContext {
                    AMLogging.log("extractAPRAndScale: rejecting candidate due to banking context without APR/purchases/liability/header: token=\(token)", component: LOG_COMPONENT)
                    return
                }

                // Reject rewards/FX/fee contexts and explicit "no interest" marketing copy
                if hasRewardContext || hasFXContext || hasFeeContext || ctx.contains("no interest") {
                    AMLogging.log("extractAPRAndScale: rejecting candidate due to rewards/FX/fee context: token=\(token) ctx='\(ctxPreview)'", component: LOG_COMPONENT)
                    return
                }

                // Require meaningful APR context for both labeled and bare percentages
                if source == "bare" {
                    if !(hasHeaderContext || hasPurchaseContext) {
                        AMLogging.log("extractAPRAndScale: skipping bare % without APR header/purchase context: token=\(token)", component: LOG_COMPONENT)
                        return
                    }
                } else if source == "label" {
                    // For labeled matches, still require non-trivial APR context (not just the word "apr")
                    if !(hasHeaderContext || hasPurchaseContext) {
                        AMLogging.log("extractAPRAndScale: skipping labeled APR without APR header/purchase context: token=\(token)", component: LOG_COMPONENT)
                        return
                    }
                }

                if badWords.contains(where: { ctx.contains($0) }) {
                    AMLogging.log("extractAPRAndScale: rejecting candidate due to penalty/fee/minimum context: token=\(token), ctx=\(ctx)", component: LOG_COMPONENT)
                    return
                }

                // If the document mentions penalty APR and this candidate is extremely high (>= 28%),
                // reject unless it's clearly in a purchases context
                if docHasPenalty && val >= 0.28 && !hasPurchaseContext {
                    AMLogging.log("extractAPRAndScale: rejecting high APR due to penalty mention without purchases context: value=\(val)", component: LOG_COMPONENT)
                    return
                }

                if val == 0 {
                    // Accept 0% only if promo/intro context exists anywhere in this text scope
                    if !promoWords.contains(where: { lower.contains($0) }) {
                        AMLogging.log("extractAPRAndScale: rejecting 0% APR without promo context", component: LOG_COMPONENT)
                        return
                    }
                } else if val < 0.005 || val > 0.6 {
                    AMLogging.log("extractAPRAndScale: rejecting implausible APR value=\(val)", component: LOG_COMPONENT)
                    return
                }

                // Detect if this token is part of an APR range like 24.24%-29.99%
                var isRangeBound = false
                var isUpperBound = false
                if let rr = rangeRegex {
                    let rMatches = rr.matches(in: ctx, options: [], range: NSRange(ctx.startIndex..<ctx.endIndex, in: ctx))
                    for rm in rMatches {
                        if rm.numberOfRanges >= 3,
                           let r1 = Range(rm.range(at: 1), in: ctx),
                           let r2 = Range(rm.range(at: 2), in: ctx) {
                            let a = String(ctx[r1])
                            let b = String(ctx[r2])
                            if a == token || b == token {
                                isRangeBound = true
                                isUpperBound = (b == token)
                                break
                            }
                        }
                    }
                }

                AMLogging.log("APR eval: range detection token=\(token) isRange=\(isRangeBound) isUpper=\(isUpperBound)", component: LOG_COMPONENT)

                // Scoring: prefer current purchases; demote prior/previous and range upper bounds; boost labeled/header proximity
                var score = 0
                if hasPurchaseContext { score += 7 }
                if priorWords.contains(where: { ctx.contains($0) }) { score -= 3 }
                if demoteWords.contains(where: { ctx.contains($0) }) { score -= 3 }
                if isRangeBound { score -= 4 }
                if isUpperBound { score -= 3 }
                if source == "label" { score += 1 }
                if hasHeaderContext { score += 2 }

                AMLogging.log("APR eval: ACCEPT token=\(token) value=\(val) scale=\(scale) score=\(score) source=\(source)", component: LOG_COMPONENT)

                candidates.append(Candidate(value: val, scale: scale, score: score, isRange: isRangeBound, isUpper: isUpperBound, source: source))
            }

            // Collect labeled matches
            let labelMatches = labelRegex.matches(in: lower, options: [], range: fullRange)
            AMLogging.log("APR labelMatches=\(labelMatches.count)", component: LOG_COMPONENT)
            for m in labelMatches {
                if m.numberOfRanges >= 2, let r = Range(m.range(at: 1), in: lower) {
                    let token = String(lower[r])
                    evaluateMatch(token: token, matchRange: m.range, source: "label")
                }
            }

            // Collect bare percent matches
            let bareMatches = bareRegex.matches(in: lower, options: [], range: fullRange)
            AMLogging.log("APR bareMatches=\(bareMatches.count)", component: LOG_COMPONENT)
            for m in bareMatches {
                if m.numberOfRanges >= 2, let r = Range(m.range(at: 1), in: lower) {
                    let token = String(lower[r])
                    evaluateMatch(token: token, matchRange: m.range, source: "bare")
                }
            }

            if !candidates.isEmpty {
                let summary = candidates.map { c in
                    "val=\(c.value) scale=\(c.scale) score=\(c.score) src=\(c.source) range=\(c.isRange) upper=\(c.isUpper)"
                }.joined(separator: "; ")
                AMLogging.log("APR candidates summary: [\(summary)]", component: LOG_COMPONENT)
            } else {
                AMLogging.log("APR candidates summary: []", component: LOG_COMPONENT)
            }

            // Choose best candidate: highest score; tie -> prefer non-range; then prefer lower value (avoid penalty/cash-advance extremes)
            if let best = candidates.max(by: { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score < rhs.score }
                if lhs.isRange != rhs.isRange { return lhs.isRange && !rhs.isRange }
                return lhs.value > rhs.value
            }) {
                return (best.value, best.scale)
            }

            AMLogging.log("APR extract: no candidates after full evaluation", component: LOG_COMPONENT)
            return nil
        }

        func extractPurchasesAPRFromDocument(_ rows: [[String]]) -> (value: Decimal, scale: Int)? {
            // Build a single lowercase document string
            let doc = rows.flatMap { $0 }.joined(separator: " ").lowercased()

            // Prefer stronger anchors first; keep generic last
            let anchorTokensInPriority = [
                "interest charges",
                "interest charge calculation",
                "annual percentage rate",
                "apr",
                "interest rate"
            ]

            // Helper: scan a window for Purchases APR
            func bestPurchasesAPR(in window: String) -> (value: Decimal, scale: Int, score: Int)? {
                let purchaseRegex = try? NSRegularExpression(pattern: #"purchases?"#, options: [.caseInsensitive])
                let percentRegex = try? NSRegularExpression(pattern: #"([0-9]{1,3}(?:\.[0-9]{1,4})?)\s*%"#, options: [.caseInsensitive])
                guard let pRx = purchaseRegex, let pctRx = percentRegex else { return nil }
                let wRange = NSRange(window.startIndex..<window.endIndex, in: window)
                let pMatches = pRx.matches(in: window, options: [], range: wRange)
                AMLogging.log("PurchasesAPR: purchases matches=\(pMatches.count)", component: LOG_COMPONENT)

                struct PCandidate { let value: Decimal; let scale: Int; let score: Int }
                var pcands: [PCandidate] = []

                for pm in pMatches {
                    // Ensure this match is exactly 'purchases' and not followed by 'before/prior/previous'
                    guard let pr = Range(pm.range, in: window) else { continue }
                    let matchedWord = String(window[pr]).lowercased()
                    if matchedWord != "purchases" { AMLogging.log("PurchasesAPR: skipping non-plural 'purchase' token", component: LOG_COMPONENT); continue }
                    let afterIndex = window.index(pr.upperBound, offsetBy: 0, limitedBy: window.endIndex) ?? pr.upperBound
                    let tail = String(window[afterIndex..<window.endIndex]).lowercased()
                    if let wMatch = tail.range(of: #"^\s*([a-z]+)"#, options: .regularExpression) {
                        let nextWord = String(tail[wMatch]).trimmingCharacters(in: .whitespacesAndNewlines)
                            .replacingOccurrences(of: ":", with: "")
                        if nextWord == "before" || nextWord == "prior" || nextWord == "previous" {
                            AMLogging.log("PurchasesAPR: skipping due to disqualifying next word after 'purchases'", component: LOG_COMPONENT)
                            continue
                        }
                    }

            // Isolate the single line containing the 'purchases' token
            let ns = window as NSString
            let startSearch = NSRange(location: 0, length: pm.range.location)
            let endSearch = NSRange(location: pm.range.location + pm.range.length, length: ns.length - (pm.range.location + pm.range.length))
            let prevNL = ns.range(of: "\n", options: [.backwards], range: startSearch)
            let nextNL = ns.range(of: "\n", options: [], range: endSearch)
            let lineStart = prevNL.location == NSNotFound ? 0 : (prevNL.location + prevNL.length)
            let lineEnd = nextNL.location == NSNotFound ? ns.length : nextNL.location
            let lineRange = NSRange(location: lineStart, length: max(0, lineEnd - lineStart))
            let line = ns.substring(with: lineRange)
            let lineLower = line.lowercased()
            AMLogging.log("PurchasesAPR: line around 'purchases': '" + String(lineLower.prefix(220)) + "'", component: LOG_COMPONENT)

            // Disqualify lines that mention penalty or disqualifying contexts
            if lineLower.contains("penalty") {
                AMLogging.log("PurchasesAPR: skip due to penalty on line", component: LOG_COMPONENT)
                continue
            }
            let rewardWords = ["cash back", "cashback", "rewards", "points", "bonus category", "category", "dining", "drugstore", "groceries", "gas", "travel"]
            let fxWords = ["foreign transaction", "foreign exchange", "international transaction", "currency conversion", "conversion fee"]
            let feeWords = ["transaction fee", "monthly fee", "fee-based", "pay over time"]
            if rewardWords.contains(where: { lineLower.contains($0) }) {
                AMLogging.log("PurchasesAPR: skip due to rewards context on line", component: LOG_COMPONENT)
                continue
            }
            if fxWords.contains(where: { lineLower.contains($0) }) {
                AMLogging.log("PurchasesAPR: skip due to FX context on line", component: LOG_COMPONENT)
                continue
            }
            if feeWords.contains(where: { lineLower.contains($0) }) {
                AMLogging.log("PurchasesAPR: skip due to fee context on line", component: LOG_COMPONENT)
                continue
            }
            if lineLower.contains("no interest") {
                AMLogging.log("PurchasesAPR: skip due to 'no interest' context on line", component: LOG_COMPONENT)
                continue
            }
            // Disallow 'before/prior/previous' anywhere on the same line
            if lineLower.contains("before") || lineLower.contains("prior") || lineLower.contains("previous") {
                AMLogging.log("PurchasesAPR: skipping due to disqualifying word on same line", component: LOG_COMPONENT)
                continue
            }

            // Find percentage tokens on this line only, prefer the one closest to 'purchases'
            let purchaseOffset = pm.range.location - lineStart
            let lns = line as NSString
            let lRange = NSRange(location: 0, length: lns.length)
            let pctMatches = pctRx.matches(in: line, options: [], range: lRange)
            AMLogging.log("PurchasesAPR: % matches on line=\(pctMatches.count)", component: LOG_COMPONENT)

            var bestLocal: (token: String, dist: Int)? = nil
            for m in pctMatches {
                guard m.numberOfRanges >= 2, let rTok = Range(m.range(at: 1), in: line) else { continue }
                let token = String(line[rTok])
                let dist = abs(m.range.location - purchaseOffset)
                if bestLocal == nil || dist < bestLocal!.dist {
                    bestLocal = (token, dist)
                }
            }

            if let bestLocal = bestLocal, var val = Decimal(string: bestLocal.token) {
                let scale = bestLocal.token.contains(".") ? (bestLocal.token.split(separator: ".").last?.count ?? 0) : 0
                if val > 1 { val /= 100 }
                // Score: strong boost for exact line match; light penalty if line hints at prior/previous (already filtered above)
                var score = 5
                AMLogging.log("PurchasesAPR: candidate token=\(bestLocal.token) value=\(val) scale=\(scale) score=\(score) (line-based)", component: LOG_COMPONENT)
                pcands.append(PCandidate(value: val, scale: scale, score: score))
            } else {
                AMLogging.log("PurchasesAPR: no % found on same line as 'purchases'", component: LOG_COMPONENT)
            }
                }

                if let best = pcands.max(by: { (l, r) in
                    if l.score != r.score { return l.score < r.score }
                    return l.value > r.value
                }) {
                    return (best.value, best.scale, best.score)
                }
                return nil
            }

            // Try each anchor in priority order; for each, try all occurrences in the doc
            var triedAnyAnchor = false
            for token in anchorTokensInPriority {
                var searchStart = doc.startIndex
                while let range = doc.range(of: token, range: searchStart..<doc.endIndex) {
                    triedAnyAnchor = true
                    // Build a window that includes some text before and after the anchor
                    let pre = 500
                    let post = 3000
                    let startIdx = doc.index(range.lowerBound, offsetBy: -min(pre, doc.distance(from: doc.startIndex, to: range.lowerBound)), limitedBy: doc.startIndex) ?? doc.startIndex
                    let endIdx = doc.index(range.upperBound, offsetBy: min(post, doc.distance(from: range.upperBound, to: doc.endIndex)), limitedBy: doc.endIndex) ?? doc.endIndex
                    let window = String(doc[startIdx..<endIdx])
                    let preview = String(window.prefix(320))
                    AMLogging.log("PurchasesAPR: trying anchor '\(token)' — scanning around anchor; window length=\(window.count) preview='" + preview + "'", component: LOG_COMPONENT)

                    if let best = bestPurchasesAPR(in: window) {
                        AMLogging.log("PurchasesAPR: selected value=\(best.value) scale=\(best.scale) from anchor '\(token)'", component: LOG_COMPONENT)
                        return (best.value, best.scale)
                    }

                    // Advance search start to find subsequent occurrences
                    searchStart = range.upperBound
                }
            }

            // Fallback: if anchors were unhelpful (or none found), scan the full document once
            if !triedAnyAnchor {
                AMLogging.log("PurchasesAPR: no anchor found — scanning full document", component: LOG_COMPONENT)
            } else {
                AMLogging.log("PurchasesAPR: anchors yielded no candidates — scanning full document as fallback", component: LOG_COMPONENT)
            }
            if let best = bestPurchasesAPR(in: doc) {
                AMLogging.log("PurchasesAPR: selected value=\(best.value) scale=\(best.scale) from full document fallback", component: LOG_COMPONENT)
                return (best.value, best.scale)
            }

            AMLogging.log("PurchasesAPR: no candidates after filtering", component: LOG_COMPONENT)
            return nil
        }

        // Pre-scan all rows for a global APR/interest rate token present in summary blocks
        let globalAPR: (value: Decimal, scale: Int)? = {
            // First, attempt a targeted extraction of the Purchases APR from the Interest Charges table
            if let purchasesAPR = extractPurchasesAPRFromDocument(rows) {
                AMLogging.log("PDFSummaryParser: selected Purchases APR from Interest Charges table value=\(purchasesAPR.value)", component: LOG_COMPONENT)
                return purchasesAPR
            }

            // Fall back to labeled/bare APR candidates aggregated across rows
            var candidates: [(Decimal, Int)] = []
            for row in rows {
                let joined = row.joined(separator: " ")
                if let found = extractAPRAndScale(from: joined) {
                    candidates.append((found.value, found.scale))
                }
            }
            if !candidates.isEmpty {
                // Pick the most frequent candidate across rows; tie-breaker prefers the lower value
                var counts: [String: (value: Decimal, scale: Int, count: Int)] = [:]
                func keyFor(_ v: Decimal) -> String {
                    let dbl = (v as NSDecimalNumber).doubleValue
                    return String(format: "%.4f", dbl)
                }
                for (v, s) in candidates {
                    let key = keyFor(v)
                    if var entry = counts[key] {
                        entry.count += 1
                        counts[key] = entry
                    } else {
                        counts[key] = (v, s, 1)
                    }
                }
                let best = counts.values.max { lhs, rhs in
                    if lhs.count != rhs.count { return lhs.count < rhs.count }
                    return lhs.value > rhs.value // for equal counts, prefer lower value
                }
                if let best = best {
                    AMLogging.log("PDFSummaryParser: selected row-level APR candidate (by frequency) value=\(best.value)", component: LOG_COMPONENT)
                    return (best.value, best.scale)
                }
            }

            // Fallback: scan entire document text once
            let docText = rows.flatMap { $0 }.joined(separator: " ")
            if let found = extractAPRAndScale(from: docText) {
                AMLogging.log("PDFSummaryParser: selected doc-level APR candidate value=\(found.value)", component: LOG_COMPONENT)
                return found
            }
            return nil
        }()
        AMLogging.log("PDFSummaryParser: globalAPR=\(String(describing: globalAPR))", component: LOG_COMPONENT)

        // Pre-scan all rows for credit card context indicators
        let hasCreditCardIndicators: Bool = {
            let tokens = [
                "new balance",
                "previous balance",
                "minimum payment due",
                "payment due date",
                "credit limit",
                "available credit",
                "card ending",
                // Interest Charges table indicators
                "interest charges",
                "annual percentage rate",
                "balance type"
            ]
            for row in rows {
                let joined = row.joined(separator: " ").lowercased()
                if tokens.contains(where: { joined.contains($0) }) {
                    return true
                }
            }
            // Secondary check across full document text
            let docTextLower = rows.flatMap { $0 }.joined(separator: " ").lowercased()
            if docTextLower.contains("interest charges") || docTextLower.contains("annual percentage rate") {
                return true
            }
            return false
        }()
        AMLogging.log("PDFSummaryParser: ccIndicators=\(hasCreditCardIndicators)", component: LOG_COMPONENT)

        // Document-level context flags
        let docTextLower = rows.flatMap { $0 }.joined(separator: " ").lowercased()
        let docHasPenaltyDoc = docTextLower.contains("penalty apr") || docTextLower.contains("late payment warning") || docTextLower.contains("penalty")
        let docHasPurchaseDoc = docTextLower.contains("purchase") || docTextLower.contains("purchases") || docTextLower.contains("purchase apr")

        // Diagnostics for document-level flags and APR header tokens
        let aprHeaderTokens = [
            "annual percentage rate", "interest charges", "balance type", "interest rate"
        ]
        let aprHeaderPresence = aprHeaderTokens.map { token in (token, docTextLower.contains(token)) }
        let headerSummary = aprHeaderPresence.map { "\($0.0)=\($0.1)" }.joined(separator: ", ")
        AMLogging.log("PDFSummaryParser: docFlags penalty=\(docHasPenaltyDoc) purchases=\(docHasPurchaseDoc) headers=[\(headerSummary)]", component: LOG_COMPONENT)

        let statementClosingDate = extractStatementClosingDate(from: rows)
        AMLogging.log("PDFSummaryParser: statementClosingDate=\(String(describing: statementClosingDate))", component: LOG_COMPONENT)
        
        // Rolling account context inferred from section headers or explicit account field
        var currentAccountContext: String? = nil

        // Heuristic: treat lines that are mostly uppercase letters and contain 2+ words as headers
        func isAllCapsHeader(_ s: String) -> Bool {
            let words = s.split(separator: " ")
            guard words.count >= 2 else { return false }
            let letters = s.unicodeScalars.filter { CharacterSet.letters.contains($0) }
            guard !letters.isEmpty else { return false }
            let upperCount = letters.filter { CharacterSet.uppercaseLetters.contains($0) }.count
            return Double(upperCount) / Double(letters.count) >= 0.9
        }

        // Map free-text to a generic account context label without bank-specific tokens
        func detectAccountContext(in s: String?) -> String? {
            guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
            let lower = s.lowercased()
            if lower.contains("checking") { return "checking" }
            if lower.contains("savings") || lower.contains("money market") { return "savings" }
            if lower.contains("credit card") || lower.contains("card ending") { return "creditcard" }
            if lower.contains("brokerage") || lower.contains("investment") || lower.contains("ira") || lower.contains("roth") || lower.contains("401k") || lower.contains("portfolio") { return "brokerage" }
            if lower.contains("loan") || lower.contains("mortgage") || lower.contains("home equity") { return "loan" }
            return nil
        }

        // Update the rolling context using either an explicit account field or a section-like description
        func updateContext(from desc: String?, accountField: String?) {
            // Prefer explicit account column when present
            if let ctx = detectAccountContext(in: accountField) {
                currentAccountContext = ctx
                return
            }
            guard let desc = desc, !desc.isEmpty else { return }
            let looksLikeHeader = isAllCapsHeader(desc) || desc.lowercased().contains("summary")
            if looksLikeHeader, let ctx = detectAccountContext(in: desc) {
                currentAccountContext = ctx
            }
        }

        // Determine as-of dates for summary-derived balances: earliest and latest dates present in rows
        var earliestDateForSummary: Date? = nil
        var latestDateForSummary: Date? = nil
        for row in rows {
            if let ds = value(row, map, key: "date"), let d = parseDate(ds) {
                if let curMin = earliestDateForSummary {
                    if d < curMin { earliestDateForSummary = d }
                } else {
                    earliestDateForSummary = d
                }
                if let curMax = latestDateForSummary {
                    if d > curMax { latestDateForSummary = d }
                } else {
                    latestDateForSummary = d
                }
            }
        }
        let asOfForSummaryStart = earliestDateForSummary
        let asOfForSummaryEnd = statementClosingDate ?? latestDateForSummary
        AMLogging.log("BalanceSummary: asOf dates start=\(String(describing: asOfForSummaryStart)) end=\(String(describing: asOfForSummaryEnd))", component: LOG_COMPONENT)

        // Collect only rows whose description clearly indicates statement summary lines
        for row in rows {
            let descRawOriginal = value(row, map, key: "description")
            let desc = descRawOriginal?.lowercased() ?? ""
            let lower = desc
            let rowCombinedNorm = normalizeSpaces(row.joined(separator: " ")).lowercased()

            // Update rolling section/account context from description or account field
            updateContext(from: descRawOriginal, accountField: value(row, map, key: "account"))

            // Detect credit-card style summary lines
            let isCCNewBalance = rowCombinedNorm.contains("new balance")
            let isCreditCardSummary = rowCombinedNorm.contains("new balance")
                || rowCombinedNorm.contains("previous balance")
                || rowCombinedNorm.contains("minimum payment due")
                || rowCombinedNorm.contains("payment due date")
                || rowCombinedNorm.contains("credit limit")
                || rowCombinedNorm.contains("available credit")
                || rowCombinedNorm.contains("card ending")

            let isStatementSummary = lower.contains("statement ending balance") || (!hasCreditCardIndicators && lower.contains("statement beginning balance"))
            let isLoanSummary = lower.contains("beginning balance") || lower.contains("ending balance") || lower.contains("current amount due") || lower.contains("amount due") || lower.contains("payment due") || lower.contains("principal balance") || lower.contains("outstanding principal")

            // Only accept CC "New Balance" (avoid multiple snapshots); keep other statement/loan summaries as before
            // In credit card documents, ignore generic loan-like summaries (beginning/ending/current due) to avoid picking the wrong balance
            let isRelevant = isStatementSummary || isCCNewBalance || (!hasCreditCardIndicators && isLoanSummary)
            guard isRelevant else { continue }

            // Date selection: prefer the statement closing date for CC "New Balance"
            let rowDateStr = value(row, map, key: "date")
            let rowDate = rowDateStr.flatMap(parseDate)
            let date: Date
            if isCCNewBalance, let cd = statementClosingDate {
                date = cd
            } else if let d = rowDate {
                date = d
            } else if isCCNewBalance, let fallback = (statementClosingDate ?? asOfForSummaryEnd ?? asOfForSummaryStart) {
                date = fallback
            } else {
                continue
            }

            // If this is a CC summary line but not "New Balance", skip it
            if hasCreditCardIndicators && isCreditCardSummary && !isCCNewBalance {
                AMLogging.log("RowSummary: skipping non-New Balance CC summary '\(descRawOriginal ?? "")'", component: LOG_COMPONENT)
                continue
            }

            // If this summary row describes an amount due or auto debit, capture it as a typical payment
            let balStr = value(row, map, key: "balance") ?? value(row, map, key: "amount")
            guard let balRaw = balStr else { continue }
            let cleaned = balRaw.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: "")
            guard let dec = Decimal(string: cleaned) else { continue }
            // For credit card contexts, store balances as negative liabilities
            var amount = dec
            if isCreditCardSummary || hasCreditCardIndicators {
                if amount > 0 { amount = -amount }
            }
            var sb = StagedBalance(asOfDate: date, balance: amount)
            if sb.typicalPaymentAmount == nil {
                let descForPayment = descRawOriginal ?? ""
                if let p = extractTypicalPayment(from: descForPayment) {
                    sb.typicalPaymentAmount = p
                    AMLogging.log("RowSummary: captured typical payment=\(p) from description '" + descForPayment + "'", component: LOG_COMPONENT)
                    if !typicalPaymentSentinelInserted {
                        var sentinel = StagedBalance(asOfDate: date, balance: p)
                        sentinel.sourceAccountLabel = "__typical_payment__"
                        balances.append(sentinel)
                        typicalPaymentSentinelInserted = true
                        AMLogging.log("RowSummary: inserted typical payment sentinel — amount=\(p) date=\(date)", component: LOG_COMPONENT)
                    }
                }
            }
            // Prefer the explicit balance column if present; otherwise fall back to amount (should be 0)

            if let aprInfo = extractAPRAndScale(from: desc) {
                let hasPurchase = lower.contains("purchase") || lower.contains("purchases") || lower.contains("purchase apr")
                let hasPenalty = lower.contains("penalty") || lower.contains("late payment") || lower.contains("late payment warning")
                // Consider this row in a credit card context if the row itself looks like a CC summary
                // OR if the document has CC indicators OR if the rolling section context indicates creditcard.
                let rowIsCreditCardContext = isCreditCardSummary || hasCreditCardIndicators || (currentAccountContext == "creditcard")

                let hasLoanLikeContext = lower.contains("loan") || lower.contains("mortgage") || lower.contains("principal balance") || lower.contains("outstanding principal") || lower.contains("statement ending balance") || lower.contains("statement beginning balance")
                let hasGenericInterestOnly = lower.contains("interest rate")

                // In credit card documents, ignore APRs coming from generic interest/loan/summary lines unless they explicitly mention purchases
                if rowIsCreditCardContext && !hasPurchase && (hasLoanLikeContext || hasGenericInterestOnly) {
                    AMLogging.log("Row APR rejected due to non-purchases generic/loan summary context in credit card document: value=\(aprInfo.value) desc='\(descRawOriginal ?? "")'", component: LOG_COMPONENT)
                    // Do not set APR here; allow global Purchases APR to apply later
                }
                else if hasPenalty {
                    AMLogging.log("Row APR rejected due to penalty context: value=\(aprInfo.value) desc='\(desc)'", component: LOG_COMPONENT)
                } else if rowIsCreditCardContext && aprInfo.value >= 0.28 && !hasPurchase {
                    // Enforce purchases context for high APRs (>= 28%) in credit-card context
                    AMLogging.log("Row APR rejected due to high APR (>= 28%) without purchases context in credit card row: value=\(aprInfo.value) desc='\(descRawOriginal ?? "")'", component: LOG_COMPONENT)
                } else if aprInfo.value >= 0.28 && !hasPurchase && !rowIsCreditCardContext {
                    // Keep the high-APR guard for non-CC contexts unless explicitly tied to purchases
                    AMLogging.log("Row APR rejected due to high APR without purchases/CC context: value=\(aprInfo.value) desc='\(desc)'", component: LOG_COMPONENT)
                } else {
                    var sbApr = aprInfo.value
                    var sbScale = aprInfo.scale
                    // Sanity clamp for mis-OCR (e.g., '37' where '3.7' was intended) — only when not CC context
                    if !rowIsCreditCardContext && sbApr > 0.6 {
                        AMLogging.log("Row APR clamped/rejected due to implausible value outside CC context: value=\(sbApr)", component: LOG_COMPONENT)
                    } else {
                        sb.interestRateAPR = sbApr
                        sb.interestRateScale = sbScale
                        AMLogging.log("Row APR extracted from description: apr=\(sbApr) scale=\(sbScale) date=\(date)", component: LOG_COMPONENT)
                    }
                }
            }
            // If we didn't pick up APR from the row description, fall back to global APR detected from the page
            if sb.interestRateAPR == nil, let aprInfo = globalAPR {
                let highAPR = aprInfo.value >= 0.28
                let highAPR30 = aprInfo.value >= 0.30
                let rowIsCreditCardContext = isCreditCardSummary || hasCreditCardIndicators || (currentAccountContext == "creditcard")
                let hasPurchaseRow = lower.contains("purchase") || lower.contains("purchases") || lower.contains("purchase apr")

                if rowIsCreditCardContext {
                    // Enforce purchases context for high APRs (>= 30%) in credit-card rows
                    if highAPR30 && !hasPurchaseRow {
                        AMLogging.log("Skipping global APR (>= 30%) without purchases context in credit card row: value=\(aprInfo.value)", component: LOG_COMPONENT)
                    } else if docHasPenaltyDoc && highAPR {
                        AMLogging.log("Skipping global APR due to penalty-like value in penalty document context: value=\(aprInfo.value)", component: LOG_COMPONENT)
                    } else {
                        sb.interestRateAPR = aprInfo.value
                        if sb.interestRateScale == nil { sb.interestRateScale = aprInfo.scale }
                        AMLogging.log("Applied global APR to snapshot (CC context): apr=\(aprInfo.value) scale=\(aprInfo.scale) date=\(date)", component: LOG_COMPONENT)
                    }
                } else {
                    // Preserve previous strict behavior for non-CC contexts
                    if (highAPR && docHasPenaltyDoc) || (highAPR && !docHasPurchaseDoc) {
                        AMLogging.log("Skipping global APR due to penalty-like value without purchases context: value=\(aprInfo.value)", component: LOG_COMPONENT)
                    } else {
                        sb.interestRateAPR = aprInfo.value
                        if sb.interestRateScale == nil { sb.interestRateScale = aprInfo.scale }
                        AMLogging.log("Applied global APR to snapshot: apr=\(aprInfo.value) scale=\(aprInfo.scale) date=\(date)", component: LOG_COMPONENT)
                    }
                }
            }
            // Prefer explicit Account column, fallback to description text; bias to credit card when CC context is present anywhere in the document
            if isCreditCardSummary || hasCreditCardIndicators {
                sb.sourceAccountLabel = "creditcard"
            } else {
                var accountKey = normalizedLabel(value(row, map, key: "account")) ?? normalizedLabel(desc)
                // Fallback to rolling section context when explicit labels are absent
                if accountKey == nil, let ctx = currentAccountContext { accountKey = ctx }
                // Bias to loan when loan phrases are present
                let loanPhrases = ["loan", "mortgage", "principal balance", "outstanding principal", "amount due", "payment due"]
                if accountKey == nil {
                    if loanPhrases.contains(where: { lower.contains($0) }) {
                        accountKey = "loan"
                    }
                }
                sb.sourceAccountLabel = accountKey
            }
            balances.append(sb)
            AMLogging.log("RowSummary: added snapshot date=\(date) amount=\(dec) label=\(sb.sourceAccountLabel ?? "nil") desc='" + (descRawOriginal ?? "") + "'", component: LOG_COMPONENT)
        }
        // Detect typical/regular monthly payment amount from free-form summary lines
        func extractTypicalPayment(from text: String) -> Decimal? {
            let lower = text.lowercased()

            // Find trigger occurrences
            let triggers = [
                "current amount due",
                "next auto debit",
                "regular monthly payment amount",
                "regular monthly payment",
                "monthly payment",
                "payment due",
            ]

            var triggerRanges: [NSRange] = []
            let ns = lower as NSString
            let fullRange = NSRange(location: 0, length: ns.length)

            for t in triggers {
                var searchRange = fullRange
                while true {
                    let r = ns.range(of: t, options: [.caseInsensitive], range: searchRange)
                    if r.location == NSNotFound { break }
                    triggerRanges.append(r)
                    let nextLoc = r.location + r.length
                    if nextLoc >= ns.length { break }
                    searchRange = NSRange(location: nextLoc, length: ns.length - nextLoc)
                }
            }

            // If we didn’t find any trigger at all, bail early.
            guard !triggerRanges.isEmpty else { return nil }

            // Currency regex (keeps your handling of parentheses/negatives)
            let pattern = #"\(\s*\$\s*[-+]?(?:[0-9]{1,3}(?:,[0-9]{3})*|[0-9]+)(?:\.[0-9]{1,4})?\s*\)|[-+]?\s*\$\s*[-+]?(?:[0-9]{1,3}(?:,[0-9]{3})*|[0-9]+)(?:\.[0-9]{1,4})?(?:-)?"#
            guard let rx = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }

            struct Candidate {
                let value: Decimal
                let score: Int
            }
            var candidates: [Candidate] = []

            // Search a small window around each trigger
            for tr in triggerRanges {
                // Window: a little before and after the trigger; bias after the trigger
                let pre = 80
                let post = 160
                let start = max(0, tr.location - pre)
                let end = min(ns.length, tr.location + tr.length + post)
                let window = NSRange(location: start, length: end - start)

                rx.enumerateMatches(in: lower, options: [], range: window) { m, _, _ in
                    guard let m, m.range.location != NSNotFound else { return }

                    // Normalize token to Decimal (respecting parentheses/minus)
                    if let r = Range(m.range, in: lower) {
                        var token = String(lower[r]).trimmingCharacters(in: .whitespacesAndNewlines)
                        var isNegative = false
                        if token.hasPrefix("(") && token.hasSuffix(")") { isNegative = true; token.removeFirst(); token.removeLast() }
                        token = token.replacingOccurrences(of: "$", with: "")
                                     .replacingOccurrences(of: ",", with: "")
                                     .replacingOccurrences(of: " ", with: "")
                        if token.hasSuffix("-") { isNegative = true; token.removeLast() }
                        if token.hasPrefix("-") { isNegative = true; token.removeFirst() }
                        guard let dec = Decimal(string: token) else { return }

                        // Score by proximity to trigger and positivity
                        // Distance measured from end of trigger to start of amount
                        let amountStart = m.range.location
                        let triggerEnd = tr.location + tr.length
                        let distance = abs(amountStart - triggerEnd)

                        var score = 100 - min(distance, 100) // clamp contribution
                        if isNegative { score -= 25 }        // prefer positive amounts for "payment due"
                        if amountStart < triggerEnd { score -= 10 } // prefer amounts that come after the trigger phrase

                        // Light penalty if the local window contains "balance" (helps avoid grabbing balances)
                        let localStr = ns.substring(with: window).lowercased()
                        if localStr.contains("balance") { score -= 8 }

                        candidates.append(Candidate(value: isNegative ? -dec : dec, score: score))
                    }
                }
            }

            // If we collected nothing (should be rare), fall back to original behavior on the same line/window
            guard !candidates.isEmpty else { return nil }

            // Prefer the highest score; if tied, prefer positive and then smaller absolute value
            let best = candidates.max { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score < rhs.score }
                let lPos = (lhs.value as NSDecimalNumber).doubleValue >= 0
                let rPos = (rhs.value as NSDecimalNumber).doubleValue >= 0
                if lPos != rPos { return !lPos && rPos } // prefer positive
                let lAbs = abs((lhs.value as NSDecimalNumber).doubleValue)
                let rAbs = abs((rhs.value as NSDecimalNumber).doubleValue)
                return lAbs > rAbs
            }

            return best?.value
        }

        // Augment balances from any embedded Balance Summary section text (synthetic rows)
        // Gather candidate section texts (rows with a single cell containing 'balance' and 'summary')
        var summaryTexts: [String] = []
        for row in rows {
            if row.count == 1 {
                let t = row[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let l = t.lowercased()
                if l.contains("balance") && l.contains("summary") {
                    summaryTexts.append(t)
                }
            }
        }

        func parseAmountFromLine(_ line: String) -> Decimal? {
            let values = extractCurrencyValues(from: line)
            return values.last
        }

        func extractCurrencyValues(from line: String) -> [Decimal] {
            // Match currency/decimal tokens like 1,234.56, ($123.45), 25.00, 0.00
            let pattern = #"\(?\$?\s*[-+]?[0-9]+(?:\.[0-9]{1,4})?\)?|\(?\$?\s*[-+]?[0-9]{1,3}(?:,[0-9]{3})*(?:\.[0-9]{1,4})?"#
            guard let rx = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
            let ns = line as NSString
            let fullRange = NSRange(location: 0, length: ns.length)

            // Precompute phone/time/vanity-phone/address contexts to filter out false positives
            let phonePattern = #"(?:\(\d{3}\)\s*|\b\d{3}[-.\s]?)\d{3}[-.\s]?\d{4}\b"#
            // Vanity phone like "833-59-SLOAN" or "59-SLOAN" (digits + letters with hyphens)
            let vanityPhonePattern = #"\b(?:\d{3}[-.\s]?)?\d{2,4}[-.\s]?[A-Za-z]{3,}\b"#
            let timePattern = #"\b(?:[0-1]?\d|2[0-3])(?::[0-5]\d)?\s?(?:am|pm)\b"#
            // Address patterns: PO Box / P.O. Box and ZIP codes
            let poBoxPattern = #"\b(?:p\.?\s*o\.\?\s*)?box\s+\d+\b"#
            let zipPattern = #"\b\d{5}(?:-\d{4})?\b"#
            
            // Date patterns: spelled-out month with day and year, month with year, and slash-separated dates
            let dateMonthDayYearPattern = #"\b(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\s+\d{1,2}(?:,\s*|\s+)\d{4}\b"#
            let dateMonthYearPattern = #"\b(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\s+\d{4}\b"#
            let dateSlashPattern = #"\b\d{1,2}/\d{1,2}/\d{2,4}\b"#
            
            let phoneRx = try? NSRegularExpression(pattern: phonePattern, options: [.caseInsensitive])
            let vanityRx = try? NSRegularExpression(pattern: vanityPhonePattern, options: [.caseInsensitive])
            let timeRx = try? NSRegularExpression(pattern: timePattern, options: [.caseInsensitive])
            let poBoxRx = try? NSRegularExpression(pattern: poBoxPattern, options: [.caseInsensitive])
            let zipRx = try? NSRegularExpression(pattern: zipPattern, options: [.caseInsensitive])

            let dateMonthDayYearRx = try? NSRegularExpression(pattern: dateMonthDayYearPattern, options: [.caseInsensitive])
            let dateMonthYearRx = try? NSRegularExpression(pattern: dateMonthYearPattern, options: [.caseInsensitive])
            let dateSlashRx = try? NSRegularExpression(pattern: dateSlashPattern, options: [.caseInsensitive])
            
            let phoneMatches = phoneRx?.matches(in: line, options: [], range: fullRange) ?? []
            let vanityMatches = vanityRx?.matches(in: line, options: [], range: fullRange) ?? []
            let timeMatches = timeRx?.matches(in: line, options: [], range: fullRange) ?? []
            let poBoxMatches = poBoxRx?.matches(in: line, options: [], range: fullRange) ?? []
            let zipMatches = zipRx?.matches(in: line, options: [], range: fullRange) ?? []

            let dateMonthDayYearMatches = dateMonthDayYearRx?.matches(in: line, options: [], range: fullRange) ?? []
            let dateMonthYearMatches = dateMonthYearRx?.matches(in: line, options: [], range: fullRange) ?? []
            let dateSlashMatches = dateSlashRx?.matches(in: line, options: [], range: fullRange) ?? []
            
            func intersects(_ r: NSRange, with matches: [NSTextCheckingResult]) -> Bool {
                for m in matches {
                    let a = r
                    let b = m.range
                    if NSIntersectionRange(a, b).length > 0 { return true }
                }
                return false
            }

            // Determine the non-whitespace token that contains a given range, and whether it has both letters and digits
            func tokenRange(containing r: NSRange) -> NSRange {
                var start = 0
                if r.location > 0 {
                    let prevWS = ns.rangeOfCharacter(from: .whitespacesAndNewlines, options: [.backwards], range: NSRange(location: 0, length: r.location))
                    if prevWS.location != NSNotFound {
                        start = prevWS.location + prevWS.length
                    } else {
                        start = 0
                    }
                } else {
                    start = 0
                }
                let endSearchLoc = r.location + r.length
                var end = ns.length
                if endSearchLoc < ns.length {
                    let nextWS = ns.rangeOfCharacter(from: .whitespacesAndNewlines, options: [], range: NSRange(location: endSearchLoc, length: ns.length - endSearchLoc))
                    if nextWS.location != NSNotFound {
                        end = nextWS.location
                    }
                }
                return NSRange(location: start, length: max(0, end - start))
            }

            func tokenHasLettersAndDigits(_ tokenRange: NSRange) -> Bool {
                guard tokenRange.length > 0 else { return false }
                let token = ns.substring(with: tokenRange)
                let hasLetter = token.range(of: "[A-Za-z]", options: .regularExpression) != nil
                let hasDigit = token.range(of: "[0-9]", options: .regularExpression) != nil
                return hasLetter && hasDigit
            }

            var out: [Decimal] = []
            rx.enumerateMatches(in: line, options: [], range: fullRange) { m, _, _ in
                guard let m, m.range.location != NSNotFound, let r = Range(m.range, in: line) else { return }

                // Skip numbers that are part of phone numbers, vanity phone strings, times, PO Boxes, or ZIP codes
                if intersects(m.range, with: phoneMatches) { return }
                if intersects(m.range, with: vanityMatches) { return }
                if intersects(m.range, with: timeMatches) { return }
                if intersects(m.range, with: poBoxMatches) { return }
                if intersects(m.range, with: zipMatches) { return }
                
                if intersects(m.range, with: dateMonthDayYearMatches) { return }
                if intersects(m.range, with: dateMonthYearMatches) { return }
                if intersects(m.range, with: dateSlashMatches) { return }

                // Skip numbers embedded within a single non-whitespace token that mixes letters and digits (e.g., "(833-59-SLOAN)")
                let tokRange = tokenRange(containing: m.range)
                if tokenHasLettersAndDigits(tokRange) { return }

                var token = String(line[r])

                // Skip if this match sits inside a contiguous 4-digit year (e.g., parts of "2025")
                do {
                    var runStart = m.range.location
                    var runEnd = m.range.location + m.range.length
                    // Expand left over digits
                    while runStart > 0 {
                        let ch = ns.character(at: runStart - 1)
                        if ch >= 48 && ch <= 57 { // '0'...'9'
                            runStart -= 1
                        } else {
                            break
                        }
                    }
                    // Expand right over digits
                    while runEnd < ns.length {
                        let ch = ns.character(at: runEnd)
                        if ch >= 48 && ch <= 57 { // '0'...'9'
                            runEnd += 1
                        } else {
                            break
                        }
                    }
                    if runEnd > runStart {
                        let runRange = NSRange(location: runStart, length: runEnd - runStart)
                        let runStr = ns.substring(with: runRange)
                        if runStr.range(of: #"^\d{4}$"#, options: .regularExpression) != nil,
                           let year = Int(runStr), year >= 1900 && year <= 2099 {
                            return
                        }
                    }
                }

                // Skip standalone four-digit years (e.g., "2025") as non-balance context
                let rawTrim = token.trimmingCharacters(in: .whitespacesAndNewlines)
                if rawTrim.range(of: #"^\d{4}$"#, options: .regularExpression) != nil {
                    if let year = Int(rawTrim), year >= 1900 && year <= 2099 {
                        return
                    }
                }
                
                // Normalize token: handle parentheses for negatives and strip $ and commas/spaces
                var isNegative = false
                token = token.trimmingCharacters(in: .whitespacesAndNewlines)
                if token.hasPrefix("(") && token.hasSuffix(")") { isNegative = true; token.removeFirst(); token.removeLast() }
                token = token.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "").replacingOccurrences(of: " ", with: "")
                if token.hasSuffix("-") { isNegative = true; token.removeLast() }
                if token.hasPrefix("-") { isNegative = true; token.removeFirst() }
                if let dec = Decimal(string: token) {
                    // Skip zero balances (e.g., 0.00)
                    if dec == .zero { return }
                    out.append(isNegative ? -dec : dec)
                }
            }
            return out
        }

        if !summaryTexts.isEmpty {
            AMLogging.log("BalanceSummary: found \(summaryTexts.count) section text(s)", component: LOG_COMPONENT)
        }
        if hasCreditCardIndicators { summaryTexts.removeAll() }
        for text in summaryTexts {
            let ls = text.replacingOccurrences(of: "\r", with: "\n").split(separator: "\n").map { String($0) }
            // Try to capture a typical payment from the entire section header/text once
            let sectionPayment: Decimal? = extractTypicalPayment(from: text)
            if let p = sectionPayment, !typicalPaymentSentinelInserted {
                let dateForSentinel = asOfForSummaryEnd ?? asOfForSummaryStart ?? Date()
                var sentinel = StagedBalance(asOfDate: dateForSentinel, balance: p)
                sentinel.sourceAccountLabel = "__typical_payment__"
                balances.append(sentinel)
                typicalPaymentSentinelInserted = true
                AMLogging.log("BalanceSummary: inserted typical payment sentinel — amount=\(p) date=\(dateForSentinel)", component: LOG_COMPONENT)
            }
            for raw in ls {
                let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if s.isEmpty { continue }
                let lower = s.lowercased()
                // Skip headers and rollups; keep product lines
                if lower.contains("summary") || lower.contains("assets") || lower.contains("account") || lower.hasPrefix("total") {
                    AMLogging.log("BalanceSummary: skipping non-product line '" + s + "'", component: LOG_COMPONENT)
                    continue
                }
                // Detect a generic label (checking/savings/brokerage/loan/creditcard) if present
                let label = normalizedLabel(s)
                // Extract all currency-like values on the line; many balance summary tables have both beginning and ending columns
                let values = extractCurrencyValues(from: s)
                AMLogging.log("BalanceSummary: line values=\(values.map { $0.description }.joined(separator: ", ")) label=\(label ?? "nil")", component: LOG_COMPONENT)
                if values.count >= 2 {
                    // Heuristic: first numeric token is Beginning Balance, last is Ending Balance
                    let begin = values.first!
                    let end = values.last!

                    if hasCreditCardIndicators {
                        if let endDate = asOfForSummaryEnd ?? asOfForSummaryStart {
                            var sbEnd = StagedBalance(asOfDate: endDate, balance: end)
                            if let p = sectionPayment { sbEnd.typicalPaymentAmount = p }
                            sbEnd.sourceAccountLabel = label
                            balances.append(sbEnd)
                            AMLogging.log("BalanceSummary: (CC) added END label=\(label ?? "nil") date=\(endDate) amount=\(end) line='" + s + "'", component: LOG_COMPONENT)
                        }
                    } else {
                        if let startDate = asOfForSummaryStart {
                            var sbBegin = StagedBalance(asOfDate: startDate, balance: begin)
                            if let p = sectionPayment { sbBegin.typicalPaymentAmount = p }
                            sbBegin.sourceAccountLabel = label
                            balances.append(sbBegin)
                            AMLogging.log("BalanceSummary: added BEGIN label=\(label ?? "nil") date=\(startDate) amount=\(begin) line='" + s + "'", component: LOG_COMPONENT)
                        } else {
                            AMLogging.log("BalanceSummary: no start date available; skipping BEGIN for line='" + s + "'", component: LOG_COMPONENT)
                        }
                        if let endDate = asOfForSummaryEnd ?? asOfForSummaryStart {
                            var sbEnd = StagedBalance(asOfDate: endDate, balance: end)
                            if let p = sectionPayment { sbEnd.typicalPaymentAmount = p }
                            sbEnd.sourceAccountLabel = label
                            balances.append(sbEnd)
                            AMLogging.log("BalanceSummary: added END label=\(label ?? "nil") date=\(endDate) amount=\(end) line='" + s + "'", component: LOG_COMPONENT)
                        } else {
                            AMLogging.log("BalanceSummary: no end date available; skipping END for line='" + s + "'", component: LOG_COMPONENT)
                        }
                    }
                } else if let amount = parseAmountFromLine(s) {
                    // Fallback: single amount found — treat as an ending balance if we have an end date, else use start
                    let date = asOfForSummaryEnd ?? asOfForSummaryStart ?? Date()
                    var sb = StagedBalance(asOfDate: date, balance: amount)
                    if let p = sectionPayment { sb.typicalPaymentAmount = p }
                    sb.sourceAccountLabel = label
                    balances.append(sb)
                    AMLogging.log("BalanceSummary: added SINGLE label=\(label ?? "nil") date=\(date) amount=\(amount) line='" + s + "'", component: LOG_COMPONENT)
                } else {
                    AMLogging.log("BalanceSummary: no currency values found in product line '" + s + "'", component: LOG_COMPONENT)
                }
            }
        }

        AMLogging.log("PDFSummaryParser — parsed balances: \(balances.count)", component: LOG_COMPONENT)

        // Final coercion: if the document contains clear credit card indicators, treat all summary balances as credit card snapshots
        if hasCreditCardIndicators && !balances.isEmpty {
            AMLogging.log("PDFSummaryParser: coercing \(balances.count) snapshot label(s) to creditcard due to document-level CC indicators", component: LOG_COMPONENT)
            for i in balances.indices {
                let lbl = (balances[i].sourceAccountLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if lbl == "__typical_payment__" { continue }
                balances[i].sourceAccountLabel = "creditcard"
            }
        }

        // De-duplicate balances by calendar day and source label, preferring non-zero values.
        // This avoids persisting spurious $0 snapshots that sometimes appear alongside the true balance.
        do {
            let before = balances.count
            var chosen: [String: StagedBalance] = [:]
            var order: [String] = []
            let cal = Calendar.current
            for b in balances {
                let label = (b.sourceAccountLabel ?? "default").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let dayStart = cal.startOfDay(for: b.asOfDate).timeIntervalSince1970
                let key = "\(label)|\(Int(dayStart))"
                if let existing = chosen[key] {
                    if existing.balance == .zero && b.balance != .zero {
                        AMLogging.log("DeDup: replacing zero with non-zero for key=\(key) old=\(existing.balance) new=\(b.balance) label=\(b.sourceAccountLabel ?? "nil") date=\(b.asOfDate)", component: LOG_COMPONENT)
                        chosen[key] = b
                    } else {
                        // Special-case: same day, same label, opposite sign and same magnitude (within epsilon)
                        // Prefer the snapshot with APR; if tie/no APR, prefer negative value for loans.
                        let eps = 0.005
                        let existingVal = (existing.balance as NSDecimalNumber).doubleValue
                        let incomingVal = (b.balance as NSDecimalNumber).doubleValue
                        let sameMagnitude = abs(abs(existingVal) - abs(incomingVal)) <= eps
                        let oppositeSign = (existingVal < 0 && incomingVal > 0) || (existingVal > 0 && incomingVal < 0)

                        if sameMagnitude && oppositeSign {
                            let existingHasAPR = (existing.interestRateAPR != nil)
                            let incomingHasAPR = (b.interestRateAPR != nil)

                            // Decide winner
                            var keepIncoming = false
                            if existingHasAPR != incomingHasAPR {
                                // Prefer the one with APR
                                keepIncoming = incomingHasAPR
                            } else if label == "loan" {
                                // For loans, prefer negative value
                                keepIncoming = (incomingVal < 0)
                            } else {
                                // Default: keep existing
                                keepIncoming = false
                            }

                            if keepIncoming {
                                // Carry over typicalPaymentAmount if incoming lacks it
                                var incomingUpdated = b
                                if incomingUpdated.typicalPaymentAmount == nil, let pay = existing.typicalPaymentAmount {
                                    incomingUpdated.typicalPaymentAmount = pay
                                    AMLogging.log("DeDup: (opp-sign) carried typicalPaymentAmount=\(pay) to incoming for key=\(key) label=\(b.sourceAccountLabel ?? "nil") date=\(b.asOfDate)", component: LOG_COMPONENT)
                                }
                                AMLogging.log("DeDup: (opp-sign) replacing existing=\(existing.balance) with incoming=\(incomingUpdated.balance) key=\(key) label=\(label) date=\(b.asOfDate)", component: LOG_COMPONENT)
                                chosen[key] = incomingUpdated
                            } else {
                                // Merge typicalPaymentAmount into existing if needed
                                var updated = existing
                                if updated.typicalPaymentAmount == nil, let pay = b.typicalPaymentAmount {
                                    updated.typicalPaymentAmount = pay
                                    AMLogging.log("DeDup: (opp-sign) merged typicalPaymentAmount=\(pay) into existing for key=\(key) label=\(label) date=\(b.asOfDate)", component: LOG_COMPONENT)
                                }
                                AMLogging.log("DeDup: (opp-sign) keeping existing=\(updated.balance) and discarding incoming=\(b.balance) key=\(key) label=\(label) date=\(b.asOfDate)", component: LOG_COMPONENT)
                                chosen[key] = updated
                            }
                            continue
                        }

                                // Default behavior: only merge typicalPaymentAmount; otherwise keep existing
                                var updated = existing
                                var didMerge = false
                                if updated.typicalPaymentAmount == nil, let incomingPayment = b.typicalPaymentAmount {
                                    updated.typicalPaymentAmount = incomingPayment
                                    didMerge = true
                                    AMLogging.log("DeDup: merged typicalPaymentAmount=\(incomingPayment) into existing for key=\(key) label=\(b.sourceAccountLabel ?? "nil") date=\(b.asOfDate)", component: LOG_COMPONENT)
                                }
                                if didMerge {
                                    chosen[key] = updated
                                } else {
                                    AMLogging.log("DeDup: keeping existing for key=\(key) existing=\(existing.balance) incoming=\(b.balance) label=\(b.sourceAccountLabel ?? "nil") date=\(b.asOfDate)", component: LOG_COMPONENT)
                                    // keep existing (either both zero or both non-zero)
                                }
                            }
                } else {
                    // Cross-label special-case: look for an existing snapshot on the same day with a different label
                    // that has opposite sign and same magnitude. Prefer APR; if tie/no APR, prefer negative for loans.
                    let eps = 0.005
                    let incomingVal = (b.balance as NSDecimalNumber).doubleValue
                    var handledCross = false

                    for (ekey, ebal) in chosen {
                        let parts = ekey.split(separator: "|")
                        guard parts.count == 2, let eDay = Int(parts[1]), eDay == Int(dayStart) else { continue }

                        let existingVal = (ebal.balance as NSDecimalNumber).doubleValue
                        let sameMagnitude = abs(abs(existingVal) - abs(incomingVal)) <= eps
                        let oppositeSign = (existingVal < 0 && incomingVal > 0) || (existingVal > 0 && incomingVal < 0)
                        if !(sameMagnitude && oppositeSign) { continue }

                        let existingHasAPR = (ebal.interestRateAPR != nil)
                        let incomingHasAPR = (b.interestRateAPR != nil)
                        let existingLabelFromKey = String(parts[0])

                        var keepIncoming = false
                        // Never let an unlabeled snapshot replace a labeled one; allow labeled to replace unlabeled
                        if existingLabelFromKey != "default" && label == "default" {
                            keepIncoming = false
                        } else if existingLabelFromKey == "default" && label != "default" {
                            keepIncoming = true
                        } else if existingHasAPR != incomingHasAPR {
                            // Prefer the one with APR
                            keepIncoming = incomingHasAPR
                        } else if existingLabelFromKey == "loan" || label == "loan" {
                            // For loans, prefer negative value
                            keepIncoming = (incomingVal < 0)
                        } else {
                            // Default: keep existing
                            keepIncoming = false
                        }

                        if keepIncoming {
                            var incomingUpdated = b
                            if incomingUpdated.typicalPaymentAmount == nil, let pay = ebal.typicalPaymentAmount {
                                incomingUpdated.typicalPaymentAmount = pay
                                AMLogging.log("DeDup: (cross-label opp-sign) carried typicalPaymentAmount=\(pay) to incoming for key=\(ekey) day=\(Int(dayStart))", component: LOG_COMPONENT)
                            }
                            AMLogging.log("DeDup: (cross-label opp-sign) replacing existing=\(ebal.balance) label=\(existingLabelFromKey) with incoming=\(incomingUpdated.balance) label=\(label) day=\(Int(dayStart))", component: LOG_COMPONENT)
                            // Replace the existing entry in-place to preserve insertion order
                            chosen[ekey] = incomingUpdated
                        } else {
                            var updated = ebal
                            if updated.typicalPaymentAmount == nil, let pay = b.typicalPaymentAmount {
                                updated.typicalPaymentAmount = pay
                                AMLogging.log("DeDup: (cross-label opp-sign) merged typicalPaymentAmount=\(pay) into existing key=\(ekey)", component: LOG_COMPONENT)
                            }
                            AMLogging.log("DeDup: (cross-label opp-sign) keeping existing=\(updated.balance) and discarding incoming=\(b.balance) day=\(Int(dayStart))", component: LOG_COMPONENT)
                            chosen[ekey] = updated
                        }

                        handledCross = true
                        break
                    }

                    if handledCross { continue }

                    // If unlabeled ("default"), drop it when any snapshot already exists for this day
                    if label == "default" {
                        var anyForDay = false
                        for k in chosen.keys {
                            let parts = k.split(separator: "|")
                            if parts.count == 2, let eDay = Int(parts[1]), eDay == Int(dayStart) {
                                anyForDay = true
                                break
                            }
                        }
                        if anyForDay {
                            AMLogging.log("DeDup: dropping unlabeled snapshot for day=\(Int(dayStart)) amount=\(b.balance) because another snapshot exists for the same day", component: LOG_COMPONENT)
                            continue
                        }
                    }

                    AMLogging.log("DeDup: adding key=\(key) label=\(label) date=\(b.asOfDate) amount=\(b.balance)", component: LOG_COMPONENT)
                    chosen[key] = b
                    order.append(key)
                }
            }
            balances = order.compactMap { chosen[$0] }
            AMLogging.log("PDFSummaryParser: de-duplicated balances by day/label — before=\(before) after=\(balances.count)", component: LOG_COMPONENT)
        }
        
        if hasCreditCardIndicators, let cd = statementClosingDate {
            // Force all credit card snapshots to the closing date and backfill APR if missing
            for i in balances.indices {
                let lbl = (balances[i].sourceAccountLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if lbl == "__typical_payment__" { continue }
                if lbl == "creditcard" {
                    balances[i].asOfDate = cd
                    if balances[i].interestRateAPR == nil, let apr = globalAPR {
                        balances[i].interestRateAPR = apr.value
                        if balances[i].interestRateScale == nil { balances[i].interestRateScale = apr.scale }
                    }
                }
            }
            // Collapse duplicates after coercion (keep one per label/day)
            var seen: Set<String> = []
            let cal = Calendar.current
            balances = balances.filter { b in
                let lbl = (b.sourceAccountLabel ?? "default").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if lbl == "__typical_payment__" { return true }
                let key = "\(lbl)|\(Int(cal.startOfDay(for: b.asOfDate).timeIntervalSince1970))"
                if seen.contains(key) { return false }
                seen.insert(key)
                return true
            }
            AMLogging.log("PostFilter: coerced CC snapshot date to closing date and backfilled APR; count=\(balances.count)", component: LOG_COMPONENT)
        }
        
        // Final fallback: if no sentinel and no snapshot carries a typicalPaymentAmount,
        // try extracting Typical Payment from the full document text and attach it.
        do {
            let hasSentinel = balances.contains { ($0.sourceAccountLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "__typical_payment__" }
            let hasPaymentOnAny = balances.contains { $0.typicalPaymentAmount != nil }
            if !hasSentinel && !hasPaymentOnAny {
                let docAll = rows.flatMap { $0 }.joined(separator: " ")
                if let p = extractTypicalPayment(from: docAll), p > 0 {
                    if let idx = balances.firstIndex(where: { ($0.sourceAccountLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "__typical_payment__" }) {
                        balances[idx].typicalPaymentAmount = p
                        AMLogging.log("DocFallback: attached Typical Payment to snapshot — amount=\(p) index=\(idx)", component: LOG_COMPONENT)
                    } else {
                        let dateForSentinel = asOfForSummaryEnd ?? asOfForSummaryStart ?? Date()
                        var sentinel = StagedBalance(asOfDate: dateForSentinel, balance: p)
                        sentinel.sourceAccountLabel = "__typical_payment__"
                        balances.append(sentinel)
                        AMLogging.log("DocFallback: appended Typical Payment sentinel — amount=\(p) date=\(dateForSentinel)", component: LOG_COMPONENT)
                    }
                } else {
                    AMLogging.log("DocFallback: no Typical Payment found in full document scan", component: LOG_COMPONENT)
                }
            }
        }
        
        // If we didn't find any summary rows, surface a helpful message
        if balances.isEmpty {
            throw ImportError.parseFailure("We couldn't detect statement balances in this PDF. Try Transactions mode to import activity, or export a CSV for best results.")
        }

        return StagedImport(
            parserId: Self.id,
            sourceFileName: "Unknown.pdf",
            suggestedAccountType: nil,
            transactions: [],
            holdings: [],
            balances: balances
        )
    }

    // MARK: - Helpers

    private func headerMap(_ headers: [String]) -> [String: Int] {
        var map: [String: Int] = [:]
        for (idx, h) in headers.enumerated() {
            let key = h.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            map[key] = idx
        }
        return map
    }

    private func value(_ row: [String], _ map: [String: Int], key: String) -> String? {
        if let idx = map.first(where: { $0.key.contains(key) })?.value, idx < row.count {
            let v = row[idx].trimmingCharacters(in: .whitespacesAndNewlines)
            return v.isEmpty ? nil : v
        }
        return nil
    }
}

private extension NSRange {
    func toOptional() -> NSRange? {
        return self.location == NSNotFound ? nil : self
    }
}

