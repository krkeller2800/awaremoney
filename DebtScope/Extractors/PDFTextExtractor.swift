import Foundation
import PDFKit
import Darwin

enum PDFTextExtractor {
    /// Executes the given closure while silencing stdout/stderr to suppress noisy framework logs (e.g., PDFKit/CoreGraphics).
    /// Use sparingly, as this affects the entire process's standard streams during execution.
    private static func withSilencedConsole<T>(_ body: () -> T) -> T {
        // Flush any pending output
        fflush(stdout)
        fflush(stderr)
        // Open /dev/null for write
        let devNull = open("/dev/null", O_WRONLY)
        // Backup current stdout/stderr
        let savedOut = dup(STDOUT_FILENO)
        let savedErr = dup(STDERR_FILENO)
        // Redirect to /dev/null
        if devNull != -1 {
            dup2(devNull, STDOUT_FILENO)
            dup2(devNull, STDERR_FILENO)
            close(devNull)
        }
        // Execute body
        let result = body()
        // Restore stdout/stderr
        fflush(stdout)
        fflush(stderr)
        if savedOut != -1 { dup2(savedOut, STDOUT_FILENO); close(savedOut) }
        if savedErr != -1 { dup2(savedErr, STDERR_FILENO); close(savedErr) }
        return result
    }

    /// Extracts the full, cleaned text of a PDF using PDFKit
    static func extractText(from url: URL) -> String? {
        return withSilencedConsole {
            guard let doc = PDFDocument(url: url) else { return nil }
            var all = ""
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i), let s = page.string else { continue }
                all.append(s)
                all.append("\n")
            }
            let cleaned = all
                .replacingOccurrences(of: "\r", with: "\n")
                .replacingOccurrences(of: "\u{00A0}", with: " ") // non-breaking spaces
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? nil : cleaned
        }
    }

    /// Attempts to extract the "Interest Charges" section from raw PDF text.
    /// It anchors on the first occurrence of "Interest Charges" (case-insensitive),
    /// then returns a window of text that typically contains the APR table and footnotes.
    /// The window is bounded to avoid pulling unrelated sections.
    static func extractInterestChargesSection(from fullText: String) -> String? {
        let text = fullText
        let lower = text.lowercased()
        let anchors = ["interest charges", "interest charge calculation", "interest charge", "annual percentage rate"]
        var foundRanges: [(String, Range<String.Index>)] = []
        for anchor in anchors {
            if let range = lower.range(of: anchor) {
                foundRanges.append((anchor, range))
            }
        }
        guard !foundRanges.isEmpty else { return nil }
        // Find the earliest occurrence among all anchors
        let earliest = foundRanges.min { $0.1.lowerBound < $1.1.lowerBound }!
        let start = earliest.1.lowerBound

        // Take a window after the anchor; 2500 chars is usually enough to include table + footnotes
        let end = lower.index(start, offsetBy: min(2500, lower.distance(from: start, to: lower.endIndex)), limitedBy: lower.endIndex) ?? lower.endIndex
        let startOffset = lower.distance(from: lower.startIndex, to: start)
        let endOffset = lower.distance(from: lower.startIndex, to: end)
        let textStart = text.index(text.startIndex, offsetBy: startOffset)
        let textEnd = text.index(text.startIndex, offsetBy: endOffset)
        let windowOrig = text[textStart..<textEnd]

        // Optional: try to cut off at a subsequent all-caps section header (e.g., next page section)
        // Heuristic: a line with 2+ words in ALL CAPS.
        let lines = windowOrig.split(separator: "\n", omittingEmptySubsequences: false)
        var collected: [Substring] = []
        var hitNextHeader = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let ltrim = trimmed.lowercased()
            if isAllCapsHeader(trimmed) && !(ltrim.contains("interest charges") || ltrim.contains("interest charge") || ltrim.contains("interest charge calculation") || ltrim.contains("annual percentage rate") || ltrim.contains("apr")) {
                hitNextHeader = true
                break
            }
            collected.append(line)
        }
        let candidateSource: String = hitNextHeader ? collected.map(String.init).joined(separator: "\n") : String(windowOrig)
        let candidate = candidateSource.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        // Require that the section contains APR-ish signals to avoid false positives
        let hasAPRSignals = candidate.lowercased().contains("annual percentage rate") || candidate.lowercased().contains("apr") || candidate.lowercased().contains("interest rate")
        let hasPurchasesOrPercents = candidate.lowercased().contains("purchase") || candidate.contains("%")
        return (hasAPRSignals && hasPurchasesOrPercents) ? candidate : nil
    }

    private static func isAllCapsHeader(_ s: String) -> Bool {
        // Consider a header if it has at least two words and 90%+ letters are uppercase
        let words = s.split(separator: " ")
        guard words.count >= 2 else { return false }
        let letters = s.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return false }
        let upperCount = letters.filter { CharacterSet.uppercaseLetters.contains($0) }.count
        return Double(upperCount) / Double(letters.count) >= 0.9
    }

    /// Attempts to extract a generic balance summary section from raw PDF text.
    /// This is bank-agnostic: it looks for an all-caps style header that contains both
    /// "balance" and "summary" (in any order), then returns text until the next header.
    static func extractBalanceSummarySection(from fullText: String) -> String? {
        let text = fullText.replacingOccurrences(of: "\r", with: "\n")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
        func isAllCapsHeader(_ s: String) -> Bool {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            let words = trimmed.split(separator: " ")
            guard words.count >= 2 else { return false }
            let scalars = trimmed.unicodeScalars.filter { CharacterSet.letters.contains($0) }
            guard !scalars.isEmpty else { return false }
            let uppers = scalars.filter { CharacterSet.uppercaseLetters.contains($0) }
            return Double(uppers.count) / Double(scalars.count) >= 0.85
        }
        // Find the first header that looks like a balance summary
        var startIndex: Int? = nil
        for (i, raw) in lines.enumerated() {
            let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = s.lowercased()
            if isAllCapsHeader(s) && lower.contains("balance") && lower.contains("summary") {
                startIndex = i
                break
            }
            // Also allow non-all-caps variants that clearly include both tokens
            if lower.contains("balance") && lower.contains("summary") && s.count <= 64 {
                startIndex = i
                break
            }
        }
        guard let start = startIndex else { return nil }

        // Collect until the next header or a generous line cap
        var collected: [String] = []
        for j in start..<min(lines.count, start + 120) { // cap to avoid pulling entire document
            let s = lines[j]
            if j > start {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if isAllCapsHeader(trimmed) && !trimmed.lowercased().contains("balance") {
                    break
                }
            }
            collected.append(s)
        }
        let joined = collected.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    /// Extracts account-specific summary sections (e.g., "CHECKING SUMMARY", "SAVINGS SUMMARY")
    /// and returns each section's text as a separate string. This helps downstream parsers
    /// capture multiple account balances from a single statement.
    static func extractAccountSummarySections(from fullText: String) -> [String] {
        // Normalize line endings
        let text = fullText.replacingOccurrences(of: "\r", with: "\n")
        let rawLines = text.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
        func isAllCapsHeader(_ s: String) -> Bool {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            let scalars = trimmed.unicodeScalars.filter { CharacterSet.letters.contains($0) }
            guard !scalars.isEmpty else { return false }
            let uppers = scalars.filter { CharacterSet.uppercaseLetters.contains($0) }
            return Double(uppers.count) / Double(scalars.count) >= 0.85
        }

        let accountTokens: [String] = [
            "checking",
            "savings",
            "money market",
            "mmda"
        ]

        var sections: [String] = []
        var i = 0
        while i < rawLines.count {
            let header = rawLines[i].trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = header.lowercased()
            let looksLikeSummaryHeader = (lower.contains("summary") && accountTokens.contains(where: { lower.contains($0) }))
            let headerish = isAllCapsHeader(header) || header.count <= 64
            if looksLikeSummaryHeader && headerish {
                // Collect lines until the next header that appears to start a new section
                var collected: [String] = []
                var j = i
                let cap = min(rawLines.count, i + 200) // generous cap to avoid runaway
                while j < cap {
                    let line = rawLines[j]
                    if j > i {
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        let l = trimmed.lowercased()
                        // Stop at the next all-caps header that is a different section
                        if isAllCapsHeader(trimmed) {
                            // If it looks like another SUMMARY header, definitely stop
                            if l.contains("summary") && !l.contains("amount") {
                                break
                            }
                            // Also stop for unrelated major headers (avoid cutting on sub-headers like AMOUNT)
                            if !(l.contains("amount") || l.contains("deposits") || l.contains("withdrawals") || l.contains("interest") || l.contains("balance")) {
                                break
                            }
                        }
                    }
                    collected.append(String(line))
                    j += 1
                }
                let joined = collected.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                // Require a strong signal that this is an account summary: must contain an Ending Balance
                let hasEndingBalance = joined.lowercased().contains("ending balance")
                if !joined.isEmpty && hasEndingBalance {
                    sections.append(joined)
                }
                i = j
                continue
            }
            i += 1
        }

        // Deduplicate exact duplicates while preserving order
        var seen: Set<String> = []
        var unique: [String] = []
        for s in sections {
            if !seen.contains(s) {
                unique.append(s)
                seen.insert(s)
            }
        }
        return unique
    }
    
    /// Removes rewards/points summary sections (e.g., "REWARDS SUMMARY") to avoid misinterpreting
    /// points earning percentages (like 1.5% Pts/$1) as APR values.
    private static func stripRewardsSections(from fullText: String) -> String {
        let text = fullText.replacingOccurrences(of: "\r", with: "\n")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        func isHeader(_ s: String) -> Bool {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return isAllCapsHeader(trimmed)
        }
        func isRewardsHeaderLine(_ s: String) -> Bool {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = trimmed.lowercased()
            guard !lower.isEmpty else { return false }
            // Look for a header-like line that mentions rewards and summary
            let mentionsRewards = lower.contains("reward")
            let mentionsSummary = lower.contains("summary")
            let headerish = isHeader(trimmed) || trimmed.count <= 64
            return headerish && mentionsRewards && (mentionsSummary || headerish)
        }

        var toRemove = Set<Int>()
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if isRewardsHeaderLine(line) {
                // Remove from this header until the next all-caps header (exclusive)
                var j = i
                let cap = min(lines.count, i + 200) // safety cap to avoid runaway
                while j < cap {
                    if j > i {
                        let next = lines[j]
                        let trimmed = next.trimmingCharacters(in: .whitespacesAndNewlines)
                        if isHeader(trimmed) {
                            break
                        }
                    }
                    toRemove.insert(j)
                    j += 1
                }
                // Also remove the header line itself
                toRemove.insert(i)
                i = j
                continue
            }
            i += 1
        }

        if toRemove.isEmpty { return text }
        var kept: [String] = []
        kept.reserveCapacity(lines.count - toRemove.count)
        for (idx, line) in lines.enumerated() {
            if !toRemove.contains(idx) { kept.append(line) }
        }
        return kept.joined(separator: "\n")
    }

    /// Extracts a preferred APR (fraction, e.g., 0.1999) and its display scale from the PDF's text.
    /// Preference order: Purchases > Balance Transfers > Cash Advances > lowest unlabeled.
    /// Returns nil if no APR-like value is found.
    static func extractPreferredAPR(from fullText: String) -> (Decimal, Int)? {
        // Prefer to work within the Interest Charges section if available, then strip Rewards sections
        let base = extractInterestChargesSection(from: fullText) ?? fullText
        let cleaned = stripRewardsSections(from: base)
        return extractPreferredAPRFromInterestSection(cleaned)
    }

    /// Parses an Interest Charges section and chooses the preferred APR by category.
    /// Lines containing "purchase" (or plural) win, followed by balance transfers, then cash advances.
    private static func extractPreferredAPRFromInterestSection(_ interestSection: String) -> (Decimal, Int)? {
        let text = interestSection.replacingOccurrences(of: "\r", with: "\n")
        let lines = text.components(separatedBy: .newlines)
        var purchases: (Decimal, Int)? = nil
        var balanceTransfers: (Decimal, Int)? = nil
        var cashAdvances: (Decimal, Int)? = nil
        var unlabeled: [(Decimal, Int)] = []

        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if isRewardsRateLine(line) { continue }
            let lower = line.lowercased()
            guard let (apr, scale) = firstPercent(in: line) else { continue }

            if lower.contains("purchase") {
                if purchases == nil { purchases = (apr, scale) }
            } else if lower.contains("balance transfer") {
                if balanceTransfers == nil { balanceTransfers = (apr, scale) }
            } else if lower.contains("cash advance") {
                if cashAdvances == nil { cashAdvances = (apr, scale) }
            } else {
                unlabeled.append((apr, scale))
            }
        }

        if let p = purchases { return p }
        if let bt = balanceTransfers { return bt }
        if let ca = cashAdvances { return ca }
        if let best = unlabeled.sorted(by: { $0.0 < $1.0 }).first { return best }
        return nil
    }

    /// Heuristic to detect rewards/points earning lines (e.g., "1.5% (1.5 Pts)/$1 earned on all purchases").
    private static func isRewardsRateLine(_ s: String) -> Bool {
        let lower = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.isEmpty { return false }
        let hasRewardsTokens = lower.contains("reward") || lower.contains("points") || lower.contains("pts") || lower.contains("cash back") || lower.contains("cashback")
        let hasPerDollar = lower.contains("/$") || lower.contains("per $") || lower.contains("per$") || lower.contains("$1")
        let hasEarningVerbs = lower.contains("earned") || lower.contains("earn") || lower.contains("addl") || lower.contains("additional")
        return (hasRewardsTokens || hasPerDollar || hasEarningVerbs)
    }

    /// Finds the first percentage value in a string and returns it as a fraction (e.g., 19.99% -> 0.1999)
    /// along with the number of fraction digits (scale) detected in the source.
    private static func firstPercent(in s: String) -> (Decimal, Int)? {
        // Normalize thousands separators but leave the decimal separator intact
        let cleaned = s.replacingOccurrences(of: ",", with: "")
        // Match numbers like 19%, 19.9%, 19.99%, up to three fraction digits
        let pattern = #"\b(\d{1,2}(?:\.\d{1,3})?)\s*%"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
        guard let match = regex.firstMatch(in: cleaned, options: [], range: range),
              let r = Range(match.range(at: 1), in: cleaned) else { return nil }
        let numberString = String(cleaned[r])
        guard let dec = Decimal(string: numberString) else { return nil }
        let scale: Int = {
            if let dot = numberString.firstIndex(of: ".") {
                return numberString.distance(from: numberString.index(after: dot), to: numberString.endIndex)
            }
            return 0
        }()
        var fraction = dec
        if fraction > 1 { fraction /= 100 }
        return (fraction, scale)
    }
}

