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
}

