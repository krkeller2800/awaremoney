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

        AMLogging.log("PDFSummaryParser.parse: rows=\(rows.count) headers=\(headers)", component: LOG_COMPONENT)
        let docProbe = rows.flatMap { $0 }.joined(separator: " ").lowercased()
        let purchasesTokenCount = max(0, docProbe.components(separatedBy: "purchase").count - 1)
        AMLogging.log("PDFSummaryParser.parse: doc length=\(docProbe.count) purchasesTokenCount=\(purchasesTokenCount)", component: LOG_COMPONENT)

        // Helper to parse dates in the normalized format from PDFStatementExtractor (MM/dd/yyyy)
        func parseDate(_ s: String) -> Date? {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone(secondsFromGMT: 0)
            df.dateFormat = "MM/dd/yyyy"
            return df.date(from: s)
        }

        func normalizedLabel(_ raw: String?) -> String? {
            guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !s.isEmpty else { return nil }
            if s.contains("checking") { return "checking" }
            if s.contains("savings") { return "savings" }
            // Recognize brokerage/investment-related labels
            if s.contains("brokerage") || s.contains("investment") || s.contains("ira") || s.contains("roth") || s.contains("401k") || s.contains("stock") || s.contains("options") || s.contains("portfolio") {
                return "brokerage"
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

            let purchaseWords = ["purchase", "purchases", "purchase apr"]
            let demoteWords = ["cash advance", "balance transfer"]
            let priorWords = ["prior to", "previous"]

            let headerWords = ["annual percentage rate", "interest charges", "balance type", "interest rate", "annual interest rate"]

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
                // Treat purchases as a positive context only when not clearly in a rewards paragraph
                let hasPurchaseContext = !hasRewardContext && purchaseWords.contains(where: { ctx.contains($0) })

                let hasBankingContext = bankingWords.contains(where: { ctx.contains($0) })
                let hasLiabilityContext = liabilityWords.contains(where: { ctx.contains($0) })
                let hasAprToken = ctx.contains("apr") || ctx.contains("annual percentage rate")
//                let hasInterestRateToken = ctx.contains("interest rate")

                AMLogging.log(
                    "APR eval: token=\(token) val=\(val) scale=\(scale) source=\(source) hdr=\(hasHeaderContext) purch=\(hasPurchaseContext) rewards=\(hasRewardContext) fx=\(hasFXContext) fee=\(hasFeeContext) bank=\(hasBankingContext) penaltyDoc=\(docHasPenalty) ctx='\(ctxPreview)'",
                    component: LOG_COMPONENT
                )

                // Reject clear banking/deposit contexts unless APR/purchases cues exist,
                // or we have a liability context (loan/mortgage) where 'interest rate' is expected.
                if hasBankingContext && !hasPurchaseContext && !hasAprToken && !hasLiabilityContext {
                    AMLogging.log("extractAPRAndScale: rejecting candidate due to banking context without APR/purchases/liability: token=\(token)", component: LOG_COMPONENT)
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
            let anchorRange = doc.range(of: "interest charges")
            // Take a window after the Interest Charges header; if missing, scan from document start
            let startIdx = anchorRange?.upperBound ?? doc.startIndex

            if anchorRange == nil {
                AMLogging.log("PurchasesAPR: 'interest charges' anchor not found — scanning full document", component: LOG_COMPONENT)
            } else {
                AMLogging.log("PurchasesAPR: found 'interest charges' anchor — scanning from anchor", component: LOG_COMPONENT)
            }

            let windowEnd = doc.index(startIdx, offsetBy: min(1800, doc.distance(from: startIdx, to: doc.endIndex)), limitedBy: doc.endIndex) ?? doc.endIndex
            let window = String(doc[startIdx..<windowEnd])

            let windowPreview = String(window.prefix(320))
            AMLogging.log("PurchasesAPR: window length=\(window.count) preview='" + windowPreview + "'", component: LOG_COMPONENT)

            // Find occurrences of "purchases" and pick the nearest percentage that follows
            // Prefer a row that does NOT include "prior" or "previous"
            let purchaseRegex = try? NSRegularExpression(pattern: #"purchases?"#, options: [.caseInsensitive])
            let percentRegex = try? NSRegularExpression(pattern: #"([0-9]{1,3}(?:\.[0-9]{1,4})?)\s*%"#, options: [.caseInsensitive])

            guard let pRx = purchaseRegex, let pctRx = percentRegex else { return nil }
            let wRange = NSRange(window.startIndex..<window.endIndex, in: window)
            let pMatches = pRx.matches(in: window, options: [], range: wRange)

            AMLogging.log("PurchasesAPR: purchases matches=\(pMatches.count)", component: LOG_COMPONENT)

            struct PCandidate { let value: Decimal; let scale: Int; let score: Int }
            var pcands: [PCandidate] = []

            for pm in pMatches {
                // Build a local context after the purchases token
                let ctxStart = pm.range.location
                let ctxEnd = min(wRange.length, pm.range.location + pm.range.length + 220)
                let ctxRange = NSRange(location: ctxStart, length: ctxEnd - ctxStart)
                guard let swiftRange = Range(ctxRange, in: window) else { continue }
                let ctx = String(window[swiftRange])
                let ctxLower = ctx.lowercased()
                let ctxPreview2 = String(ctxLower.prefix(220))
                AMLogging.log("PurchasesAPR: context around 'purchases' token: '" + ctxPreview2 + "'", component: LOG_COMPONENT)

                // Skip rewards/marketing and FX/fee contexts
                let rewardWords = ["cash back", "cashback", "rewards", "points", "miles", "bonus category", "category", "dining", "drugstore", "groceries", "gas", "travel"]
                let fxWords = ["foreign transaction", "foreign exchange", "international transaction", "currency conversion", "conversion fee"]
                let feeWords = ["transaction fee", "monthly fee", "fee-based", "pay over time"]
                if rewardWords.contains(where: { ctxLower.contains($0) }) { AMLogging.log("PurchasesAPR: skip due to rewards context", component: LOG_COMPONENT); continue }
                if fxWords.contains(where: { ctxLower.contains($0) }) { AMLogging.log("PurchasesAPR: skip due to FX context", component: LOG_COMPONENT); continue }
                if feeWords.contains(where: { ctxLower.contains($0) }) { AMLogging.log("PurchasesAPR: skip due to fee context", component: LOG_COMPONENT); continue }
                if ctxLower.contains("no interest") { AMLogging.log("PurchasesAPR: skip due to 'no interest' context", component: LOG_COMPONENT); continue }

                let ctxNS = ctx as NSString
                let localRange = NSRange(location: 0, length: ctxNS.length)
                let allPctMatches = pctRx.matches(in: ctx, options: [], range: localRange)
                AMLogging.log("PurchasesAPR: % matches in ctx=\(allPctMatches.count)", component: LOG_COMPONENT)

                if let m = pctRx.firstMatch(in: ctx, options: [], range: localRange), m.numberOfRanges >= 2,
                   let r = Range(m.range(at: 1), in: ctx) {
                    let token = String(ctx[r])
                    if var val = Decimal(string: token) {
                        let scale = token.contains(".") ? (token.split(separator: ".").last?.count ?? 0) : 0
                        if val > 1 { val /= 100 }
                        // Score: penalize contexts containing prior/previous; otherwise boost
                        var score = 0
                        if ctxLower.contains("prior") || ctxLower.contains("previous") { score -= 2 } else { score += 3 }
                        AMLogging.log("PurchasesAPR: candidate token=\(token) value=\(val) scale=\(scale) score=\(score)", component: LOG_COMPONENT)
                        pcands.append(PCandidate(value: val, scale: scale, score: score))
                    }
                } else {
                    AMLogging.log("PurchasesAPR: no % following 'purchases' in ctx", component: LOG_COMPONENT)
                }
            }

            if !pcands.isEmpty {
                let sum = pcands.enumerated().map { idx, c in
                    "#\(idx) val=\(c.value) scale=\(c.scale) score=\(c.score)"
                }.joined(separator: "; ")
                AMLogging.log("PurchasesAPR: candidates summary [\(sum)]", component: LOG_COMPONENT)
            } else {
                AMLogging.log("PurchasesAPR: no candidates after filtering", component: LOG_COMPONENT)
            }

            if let best = pcands.max(by: { (l, r) in
                if l.score != r.score { return l.score < r.score }
                return l.value > r.value
            }) {
                AMLogging.log("PurchasesAPR: selected value=\(best.value) scale=\(best.scale)", component: LOG_COMPONENT)
                return (best.value, best.scale)
            }
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
        let asOfForSummaryEnd = latestDateForSummary
        AMLogging.log("BalanceSummary: asOf dates start=\(String(describing: asOfForSummaryStart)) end=\(String(describing: asOfForSummaryEnd))", component: LOG_COMPONENT)

        // Collect only rows whose description clearly indicates statement summary lines
        for row in rows {
            let descRawOriginal = value(row, map, key: "description")
            let desc = descRawOriginal?.lowercased() ?? ""
            let lower = desc
            // Update rolling section/account context from description or account field
            updateContext(from: descRawOriginal, accountField: value(row, map, key: "account"))

            // Detect credit-card style summary lines
            let isCreditCardSummary = lower.contains("new balance")
                || lower.contains("previous balance")
                || lower.contains("minimum payment due")
                || lower.contains("payment due date")
                || lower.contains("credit limit")
                || lower.contains("available credit")
                || lower.contains("card ending")

            let isStatementSummary = lower.contains("statement beginning balance") || lower.contains("statement ending balance")
            let isLoanSummary = lower.contains("beginning balance") || lower.contains("ending balance") || lower.contains("current amount due") || lower.contains("amount due") || lower.contains("payment due") || lower.contains("principal balance") || lower.contains("outstanding principal")
            guard isStatementSummary || isLoanSummary || isCreditCardSummary else { continue }
            guard let dateStr = value(row, map, key: "date"), let date = parseDate(dateStr) else { continue }

            // Prefer the explicit balance column if present; otherwise fall back to amount (should be 0)
            let balStr = value(row, map, key: "balance") ?? value(row, map, key: "amount")
            guard let balRaw = balStr else { continue }
            let cleaned = balRaw.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: "")
            guard let dec = Decimal(string: cleaned) else { continue }

            var sb = StagedBalance(asOfDate: date, balance: dec)
            if let aprInfo = extractAPRAndScale(from: desc) {
                let hasPurchase = lower.contains("purchase") || lower.contains("purchases") || lower.contains("purchase apr")
                let hasPenalty = lower.contains("penalty") || lower.contains("late payment") || lower.contains("late payment warning")
                if hasPenalty || (!hasPurchase && aprInfo.value >= 0.28) {
                    AMLogging.log("Row APR rejected due to context: value=\(aprInfo.value) desc='\(desc)'", component: LOG_COMPONENT)
                } else {
                    sb.interestRateAPR = aprInfo.value
                    sb.interestRateScale = aprInfo.scale
                    AMLogging.log("Row APR extracted from description: apr=\(aprInfo.value) scale=\(aprInfo.scale) date=\(date)", component: LOG_COMPONENT)
                }
            }
            // If we didn't pick up APR from the row description, fall back to global APR detected from the page
            if sb.interestRateAPR == nil, let aprInfo = globalAPR {
                if (aprInfo.value >= 0.28 && docHasPenaltyDoc) || (aprInfo.value >= 0.28 && !docHasPurchaseDoc) {
                    AMLogging.log("Skipping global APR due to penalty-like value without purchases context: value=\(aprInfo.value)", component: LOG_COMPONENT)
                } else {
                    sb.interestRateAPR = aprInfo.value
                    if sb.interestRateScale == nil { sb.interestRateScale = aprInfo.scale }
                    AMLogging.log("Applied global APR to snapshot: apr=\(aprInfo.value) scale=\(aprInfo.scale) date=\(date)", component: LOG_COMPONENT)
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
            let parts = line.split(separator: " ").map { String($0) }
            for token in parts.reversed() {
                let cleaned = token.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: "")
                if let dec = Decimal(string: cleaned) { return dec }
            }
            return nil
        }

        func extractCurrencyValues(from line: String) -> [Decimal] {
            // Match currency/decimal tokens like 1,234.56, ($123.45), 25.00, 0.00
            let pattern = #"\(?\$?\s*[-+]?[0-9]{1,3}(?:,[0-9]{3})*(?:\.[0-9]{1,4})?|\(?\$?\s*[-+]?[0-9]+(?:\.[0-9]{1,4})?\)?"#
            guard let rx = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
            let ns = line as NSString
            let range = NSRange(location: 0, length: ns.length)
            var out: [Decimal] = []
            rx.enumerateMatches(in: line, options: [], range: range) { m, _, _ in
                guard let m, m.range.location != NSNotFound, let r = Range(m.range, in: line) else { return }
                var token = String(line[r])
                // Normalize token: handle parentheses for negatives and strip $ and commas/spaces
                var isNegative = false
                token = token.trimmingCharacters(in: .whitespacesAndNewlines)
                if token.hasPrefix("(") && token.hasSuffix(")") { isNegative = true; token.removeFirst(); token.removeLast() }
                token = token.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "").replacingOccurrences(of: " ", with: "")
                if token.hasSuffix("-") { isNegative = true; token.removeLast() }
                if token.hasPrefix("-") { isNegative = true; token.removeFirst() }
                if let dec = Decimal(string: token) {
                    out.append(isNegative ? -dec : dec)
                }
            }
            return out
        }

        if !summaryTexts.isEmpty {
            AMLogging.log("BalanceSummary: found \(summaryTexts.count) section text(s)", component: LOG_COMPONENT)
        }

        for text in summaryTexts {
            let ls = text.replacingOccurrences(of: "\r", with: "\n").split(separator: "\n").map { String($0) }
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
                    if let startDate = asOfForSummaryStart {
                        var sbBegin = StagedBalance(asOfDate: startDate, balance: begin)
                        sbBegin.sourceAccountLabel = label
                        balances.append(sbBegin)
                        AMLogging.log("BalanceSummary: added BEGIN label=\(label ?? "nil") date=\(startDate) amount=\(begin) line='" + s + "'", component: LOG_COMPONENT)
                    } else {
                        AMLogging.log("BalanceSummary: no start date available; skipping BEGIN for line='" + s + "'", component: LOG_COMPONENT)
                    }
                    if let endDate = asOfForSummaryEnd ?? asOfForSummaryStart {
                        var sbEnd = StagedBalance(asOfDate: endDate, balance: end)
                        sbEnd.sourceAccountLabel = label
                        balances.append(sbEnd)
                        AMLogging.log("BalanceSummary: added END label=\(label ?? "nil") date=\(endDate) amount=\(end) line='" + s + "'", component: LOG_COMPONENT)
                    } else {
                        AMLogging.log("BalanceSummary: no end date available; skipping END for line='" + s + "'", component: LOG_COMPONENT)
                    }
                } else if let amount = parseAmountFromLine(s) {
                    // Fallback: single amount found — treat as an ending balance if we have an end date, else use start
                    let date = asOfForSummaryEnd ?? asOfForSummaryStart ?? Date()
                    var sb = StagedBalance(asOfDate: date, balance: amount)
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
                        AMLogging.log("DeDup: keeping existing for key=\(key) existing=\(existing.balance) incoming=\(b.balance) label=\(b.sourceAccountLabel ?? "nil") date=\(b.asOfDate)", component: LOG_COMPONENT)
                        // keep existing (either both zero or both non-zero)
                    }
                } else {
                    AMLogging.log("DeDup: adding key=\(key) label=\(label) date=\(b.asOfDate) amount=\(b.balance)", component: LOG_COMPONENT)
                    chosen[key] = b
                    order.append(key)
                }
            }
            balances = order.compactMap { chosen[$0] }
            AMLogging.log("PDFSummaryParser: de-duplicated balances by day/label — before=\(before) after=\(balances.count)", component: LOG_COMPONENT)
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

