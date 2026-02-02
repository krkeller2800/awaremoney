import Foundation
import PDFKit
import CoreGraphics
import Vision
import Darwin

enum PDFStatementExtractor {
    enum Mode { case summaryOnly, transactions }

    enum AccountKind { case unknown, checking, savings, investment }
    enum FlowKind { case none, deposit, withdrawal }
    enum Section { case unknown, accountSummary, cashFlow, holdings, activity }

    // Toggle OCR-based layout extraction (renders pages and can emit noisy system logs)
    static let enableOCR: Bool = false

    // Silences system logs (stderr/stdout) within the provided block to suppress noisy PDFKit/CoreText messages.
    private static func withSilencedSystemLogs<T>(_ body: () throws -> T) rethrows -> T {
        let stderrCopy = dup(STDERR_FILENO)
        let stdoutCopy = dup(STDOUT_FILENO)
        let nullPath = "/dev/null"
        let nullOut = open(nullPath, O_WRONLY)
        if nullOut != -1 {
            fflush(stderr)
            fflush(stdout)
            dup2(nullOut, STDERR_FILENO)
            dup2(nullOut, STDOUT_FILENO)
            close(nullOut)
        }
        defer {
            fflush(stderr)
            fflush(stdout)
            if stderrCopy != -1 { dup2(stderrCopy, STDERR_FILENO); close(stderrCopy) }
            if stdoutCopy != -1 { dup2(stdoutCopy, STDOUT_FILENO); close(stdoutCopy) }
        }
        return try body()
    }

    static func parse(url: URL, mode: Mode = .summaryOnly) throws -> (rows: [[String]], headers: [String]) {
        let doc: PDFDocument = try withSilencedSystemLogs {
            guard let d = PDFDocument(url: url) else {
                throw ImportError.parseFailure("Unable to open PDF. If the file is stored in iCloud, make sure it has finished downloading. If the PDF is password-protected, please remove the password and try again.")
            }
            return d
        }
        // Extract text across all pages
        var text = ""
        let pageBreakMarker = "<<<PAGE_BREAK>>>"
        withSilencedSystemLogs {
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i), let s = page.string {
                    text += s + "\n"
                    if i < doc.pageCount - 1 {
                        text += pageBreakMarker + "\n"
                    }
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

        struct StatementPeriod { let startMonth: Int; let startYear: Int; let startDay: Int?; let endMonth: Int; let endYear: Int; let endDay: Int? }
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
        func extractMonthYear(from token: String) -> (month: Int?, day: Int?, year: Int?) {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "")
            // Try numeric mm/dd(/yy)
            let comps = trimmed.split(separator: "/")
            if comps.count >= 2, let m = Int(comps[0]), let d = Int(comps[1]) {
                let y: Int?
                if comps.count >= 3, let yy = Int(comps[2]) {
                    y = (yy < 100 ? (2000 + yy) : yy)
                } else { y = nil }
                return (max(1, min(12, m)), max(1, min(31, d)), y)
            }
            // Try month name with day and optional year (e.g., "Dec 31, 2025" or "December 31 2025")
            let nameRegex = try! NSRegularExpression(pattern: "^(?i)(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec|January|February|March|April|May|June|July|August|September|October|November|December)\\s+(\\d{1,2})(?:,?\\s*(\\d{2,4}))?$")
            let range = NSRange(location: 0, length: trimmed.utf16.count)
            if let m = nameRegex.firstMatch(in: trimmed, options: [], range: range) {
                func group(_ idx: Int) -> String? {
                    let r = m.range(at: idx)
                    if let rr = Range(r, in: trimmed) { return String(trimmed[rr]) }
                    return nil
                }
                let monthStr = group(1) ?? ""
                let dayStr = group(2)
                let yearStr = group(3)
                let monthVal = monthNumber(from: monthStr)
                let dayVal = dayStr.flatMap { Int($0) }
                let yearVal: Int? = {
                    guard let ys = yearStr else { return nil }
                    if let v = Int(ys) { return v < 100 ? (2000 + v) : v }
                    return nil
                }()
                return (monthVal, dayVal, yearVal)
            }
            // Fallback: month name without explicit day/year
            if let m = monthNumber(from: trimmed) {
                return (m, nil, nil)
            }
            return (nil, nil, nil)
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
                        let currentYear = Calendar.current.component(.year, from: Date())
                        let ay = aComp.year ?? inferredYear ?? currentYear
                        let by = bComp.year ?? inferredYear ?? currentYear
                        let period = StatementPeriod(startMonth: am, startYear: ay, startDay: aComp.day, endMonth: bm, endYear: by, endDay: bComp.day)
                        AMLogging.always("PDF detected statement period: \(a) -> \(b) => start=\(am)/\(ay) d=\(aComp.day ?? -1) end=\(bm)/\(by) d=\(bComp.day ?? -1)", component: "PDFStatementExtractor")
                        return period
                    }
                }
            }
            return nil
        }
        let statementPeriod = detectStatementPeriod(in: lines)
        let headers = ["Date", "Description", "Amount", "Balance", "Account"]

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

        // MARK: - Layout-based OCR scaffold (tokens/rows/columns)
        struct LayoutRecognizedToken {
            let text: String
            let rect: CGRect   // Vision normalized boundingBox (0..1), origin bottom-left
            let pageIndex: Int
        }

        struct LayoutColumnBands {
            var date: ClosedRange<CGFloat>?
            var description: ClosedRange<CGFloat>
            var amount: ClosedRange<CGFloat>?
            var balance: ClosedRange<CGFloat>?
        }

        func layoutIsDateLikeToken(_ s: String) -> Bool {
            let r = NSRange(location: 0, length: s.utf16.count)
            return dateStartRegex.firstMatch(in: s, options: [], range: r) != nil
        }
        func layoutIsMoneyLikeToken(_ s: String) -> Bool {
            let r = NSRange(location: 0, length: s.utf16.count)
            return amountAnywhereRegex.firstMatch(in: s, options: [], range: r) != nil
        }

        // Render each page and OCR with bounding boxes (normalized)
        func layoutOCRTokensWithPositions(from doc: PDFDocument, scale: CGFloat) -> [LayoutRecognizedToken] {
            var out: [LayoutRecognizedToken] = []
            for pageIndex in 0..<doc.pageCount {
                guard let page = doc.page(at: pageIndex) else { continue }
                let box = page.bounds(for: .mediaBox)
                let width = Int(box.width * scale)
                let height = Int(box.height * scale)
                guard width > 0 && height > 0 else { continue }
                let colorSpace = CGColorSpaceCreateDeviceRGB()
                let bytesPerPixel = 4
                let bytesPerRow = bytesPerPixel * width
                let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue))
                guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: bitmapInfo.rawValue) else { continue }
                ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
                ctx.saveGState()
                ctx.scaleBy(x: scale, y: scale)
                page.draw(with: .mediaBox, to: ctx)
                ctx.restoreGState()
                guard let cgImage = ctx.makeImage() else { continue }

                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.recognitionLanguages = ["en-US"]
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                do { try handler.perform([request]) } catch { continue }
                guard let observations = request.results else { continue }
                for obs in observations {
                    if let top = obs.topCandidates(1).first {
                        let s = top.string.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !s.isEmpty {
                            out.append(LayoutRecognizedToken(text: s, rect: obs.boundingBox, pageIndex: pageIndex))
                        }
                    }
                }
            }
            return out
        }

        func layoutGroupIntoRowsPerPage(_ tokens: [LayoutRecognizedToken]) -> [[LayoutRecognizedToken]] {
            var allRows: [[LayoutRecognizedToken]] = []
            let groupedByPage = Dictionary(grouping: tokens, by: { $0.pageIndex })
            for (_, pageTokens) in groupedByPage.sorted(by: { $0.key < $1.key }) {
                let sorted = pageTokens.sorted { $0.rect.midY > $1.rect.midY }
                var rows: [[LayoutRecognizedToken]] = []
                let yThreshold: CGFloat = 0.01 // normalized units
                for t in sorted {
                    if var last = rows.last, let y = last.first?.rect.midY, abs(t.rect.midY - y) < yThreshold {
                        last.append(t)
                        rows[rows.count - 1] = last
                    } else {
                        rows.append([t])
                    }
                }
                rows = rows.map { $0.sorted { $0.rect.minX < $1.rect.minX } }
                allRows.append(contentsOf: rows)
            }
            return allRows
        }
        
        func ocrExtractLines(from doc: PDFDocument, scale: CGFloat) -> [String] {
            // Use the same OCR tokenization and row grouping to reconstruct lines, inserting page breaks
            let tokens = layoutOCRTokensWithPositions(from: doc, scale: scale)
            if tokens.isEmpty { return [] }
            let rows = layoutGroupIntoRowsPerPage(tokens)
            var out: [String] = []
            var lastPageIndex: Int = -1
            for row in rows {
                guard let first = row.first else { continue }
                if lastPageIndex != -1 && first.pageIndex != lastPageIndex {
                    out.append(pageBreakMarker)
                }
                lastPageIndex = first.pageIndex
                let line = row.map { $0.text }.joined(separator: " ")
                let cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty { out.append(cleaned) }
            }
            return out
        }

        func layoutInferColumnBands(from rows: [[LayoutRecognizedToken]]) -> LayoutColumnBands {
            var dateXs: [CGFloat] = []
            var moneyXs: [CGFloat] = []
            for row in rows {
                for t in row {
                    let x = t.rect.midX
                    if layoutIsDateLikeToken(t.text) { dateXs.append(x) }
                    if layoutIsMoneyLikeToken(t.text) { moneyXs.append(x) }
                }
            }
            func clamp(_ v: CGFloat) -> CGFloat { max(0, min(1, v)) }
            func band(around x: CGFloat, radius: CGFloat) -> ClosedRange<CGFloat> { let a = clamp(x - radius); let b = clamp(x + radius); return a...b }

            let dateBand: ClosedRange<CGFloat>? = {
                guard !dateXs.isEmpty else { return nil }
                let sorted = dateXs.sorted()
                let median = sorted[sorted.count/2]
                return band(around: median, radius: 0.06)
            }()

            var amountBand: ClosedRange<CGFloat>? = nil
            var balanceBand: ClosedRange<CGFloat>? = nil
            if !moneyXs.isEmpty {
                let minX = moneyXs.min() ?? 0
                let maxX = moneyXs.max() ?? 1
                if (maxX - minX) > 0.12 {
                    amountBand = band(around: minX, radius: 0.05)
                    balanceBand = band(around: maxX, radius: 0.05)
                } else {
                    amountBand = band(around: maxX, radius: 0.06)
                    balanceBand = nil
                }
            }

            let leftNumeric = min(amountBand?.lowerBound ?? 1, balanceBand?.lowerBound ?? 1)
            let leftEdge = dateBand?.upperBound ?? 0
            let rightEdge = leftNumeric
            let descBand = clamp(leftEdge)...clamp(max(leftEdge + 0.05, min(rightEdge, 0.98)))

            return LayoutColumnBands(date: dateBand, description: descBand, amount: amountBand, balance: balanceBand)
        }

        func layoutBuildRowsFromTokens(_ rows: [[LayoutRecognizedToken]], bands: LayoutColumnBands, inferredYear: Int?) -> [[String]] {
            var out: [[String]] = []
            for row in rows {
                let dateText: String? = {
                    guard let dBand = bands.date else { return nil }
                    return row.first(where: { dBand.contains($0.rect.midX) && layoutIsDateLikeToken($0.text) })?.text
                }()
                guard let dateRaw = dateText else { continue }
                let date = normalizeDateString(dateRaw, inferredYear: inferredYear)

                let amountText: String? = {
                    guard let aBand = bands.amount else { return nil }
                    let cands = row.filter { aBand.contains($0.rect.midX) && layoutIsMoneyLikeToken($0.text) }
                    return cands.max(by: { $0.rect.maxX < $1.rect.maxX })?.text
                }()
                guard let amountRaw = amountText else { continue }
                let amount = Self.sanitizeAmount(amountRaw)

                let balanceText: String? = {
                    guard let bBand = bands.balance else { return nil }
                    let cands = row.filter { bBand.contains($0.rect.midX) && layoutIsMoneyLikeToken($0.text) }
                    return cands.max(by: { $0.rect.maxX < $1.rect.maxX })?.text
                }()
                let balance = balanceText.map { Self.sanitizeAmount($0) } ?? ""

                let descParts = row.filter { bands.description.contains($0.rect.midX) && !layoutIsMoneyLikeToken($0.text) }.map { $0.text }
                let desc = cleanDesc(descParts.joined(separator: " "))

                out.append([date, desc, amount, balance, "unknown"]) // account unknown in layout mode
            }
            return out
        }

        func layoutTryExtraction(doc: PDFDocument, inferredYear: Int?) -> (rows: [[String]], confidence: Double) {
            let tokens = layoutOCRTokensWithPositions(from: doc, scale: 2.0)
            if tokens.isEmpty { return ([], 0.0) }
            let rowTokens = layoutGroupIntoRowsPerPage(tokens)
            if rowTokens.isEmpty { return ([], 0.0) }
            let bands = layoutInferColumnBands(from: rowTokens)
            let built = layoutBuildRowsFromTokens(rowTokens, bands: bands, inferredYear: inferredYear)
            let total = rowTokens.count
            let matched = built.count
            let conf = total == 0 ? 0.0 : min(1.0, Double(matched) / Double(max(1, total)))
            return (built, conf)
        }

        func detectInferredYear(from lines: [String]) -> Int? {
            let yearRegex = try! NSRegularExpression(pattern: #"\b(19\d{2}|20\d{2})\b"#)
            let currentYear = Calendar.current.component(.year, from: Date())
            var candidates: [Int] = []
            for line in lines {
                let ns = line as NSString
                let matches = yearRegex.matches(in: line, options: [], range: NSRange(location: 0, length: ns.length))
                for m in matches {
                    if let r = Range(m.range(at: 1), in: line), let y = Int(line[r]) {
                        candidates.append(y)
                    }
                }
            }
            let valid = candidates.filter { $0 >= 1900 && $0 <= currentYear + 1 }
            if let best = valid.min(by: { abs($0 - currentYear) < abs($1 - currentYear) }) {
                return best
            }
            return candidates.first
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

        var currentAccount: AccountKind = .unknown
        var currentFlow: FlowKind = .none
        var currentSection: Section = .unknown

        func currentAccountLabel() -> String {
            switch currentAccount {
            case .checking: return "checking"
            case .savings: return "savings"
            case .investment: return "brokerage"
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
                    else if isInvestmentHeader(l) { pageDefaults[pageIdx] = .investment }
                }
            }
        }

        // Pre-scan to label each line with a coarse section (Account Summary, Cash Flow, Holdings, Activity)
        var sectionByLine: [Int: Section] = [:]
        do {
            var sec: Section = .unknown
            var pageIdx = 0
            for (idx, l) in lines.enumerated() {
                if isPageBreak(l) {
                    pageIdx += 1
                    sec = .unknown
                    sectionByLine[idx] = .unknown
                    continue
                }
                if isAccountSummaryHeader(l) { sec = .accountSummary }
                else if isCashFlowHeader(l) { sec = .cashFlow }
                else if isHoldingsHeader(l) { sec = .holdings }
                else if isActivityHeader(l) { sec = .activity }
                sectionByLine[idx] = sec
            }
        }

        // Track current page during parsing
        var currentPageIndex = 0
        func accountLabelForRow() -> String {
            switch currentAccount {
            case .checking: return "checking"
            case .savings: return "savings"
            case .investment: return "brokerage"
            case .unknown:
                if let def = pageDefaults[currentPageIndex] {
                    switch def {
                    case .checking: return "checking"
                    case .savings: return "savings"
                    case .investment: return "brokerage"
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
                if lower.contains("checking summary") { return true }
                let hasDigits = raw.rangeOfCharacter(from: .decimalDigits) != nil
                let hasLowercase = raw.rangeOfCharacter(from: .lowercaseLetters) != nil
                return lower.contains("checking") && !lower.contains("savings") && !hasDigits && (!hasLowercase || raw.count <= 24)
            }
        }
        func contextIndicatesInvestment() -> Bool {
            return recentContext.contains { line in
                let raw = line
                let lower = raw.lowercased()
                if lower.contains("from a checking") || lower.contains("from checking") { return false }
                // Strong investment signals only; avoid generic "options" (e.g., repayment options)
                if lower.contains("brokerage") || lower.contains("investment account") || lower.contains("fidelity investments") || lower.contains("ira") || lower.contains("portfolio") || lower.contains("stock") || lower.contains("securities") {
                    let hasDigits = raw.rangeOfCharacter(from: .decimalDigits) != nil
                    let hasLowercase = raw.rangeOfCharacter(from: .lowercaseLetters) != nil
                    return !lower.contains("savings") && !lower.contains("checking") && (!hasDigits || raw.count <= 24) && (!hasLowercase || raw.count <= 28)
                }
                return false
            }
        }
        func isSavingsHeader(_ s: String) -> Bool {
            let raw = s.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = raw.lowercased()
            // Ignore incidental mentions like "from a checking account" that appear on savings pages
            if lower.contains("from a checking") || lower.contains("from checking") || lower.contains("transfer") || lower.contains("automatic") { return false }
            // Strong savings signals
            if lower.contains("savings summary") { return true }
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
        func isInvestmentHeader(_ s: String) -> Bool {
            let raw = s.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = raw.lowercased()
            // Ignore incidental mentions
            if lower.contains("from a checking") || lower.contains("from checking") || lower.contains("transfer") || lower.contains("automatic") { return false }
            // Strong investment/brokerage signals
            if lower.contains("brokerage account") { return true }
            if lower.contains("fidelity investments") { return true }
            if lower.contains("fidelity") && (lower.contains("brokerage") || lower.contains("investment") || lower.contains("portfolio")) { return true }
            if lower.contains("ira") { return true } // Roth/Traditional IRA
            // Treat common section headers like "Stock" and "Options" as investment headers
            if lower.contains("stock") || lower.contains("options") {
                let hasDigits = raw.rangeOfCharacter(from: .decimalDigits) != nil
                let hasLowercase = raw.rangeOfCharacter(from: .lowercaseLetters) != nil
                if !lower.contains("savings") && !lower.contains("checking") && (!hasDigits || raw.count <= 24) && (!hasLowercase || raw.count <= 28) {
                    return true
                }
            }
            // Generic header-like: contains brokerage/investment, no digits, and mostly uppercase or short
            let hasDigits = raw.rangeOfCharacter(from: .decimalDigits) != nil
            let hasLowercase = raw.rangeOfCharacter(from: .lowercaseLetters) != nil
            if (lower.contains("brokerage") || lower.contains("investment") || lower.contains("stock") || lower.contains("options")) && !lower.contains("savings") && !lower.contains("checking") && !hasDigits && (!hasLowercase || raw.count <= 28) {
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
        func isAccountSummaryHeader(_ s: String) -> Bool {
            let l = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if l.contains("account summary") { return true }
            if l.contains("account value") { return true }
            if l.contains("balance summary") { return true }
            if l.contains("consolidated balance") { return true }
            return false
        }
        func isCashFlowHeader(_ s: String) -> Bool {
            let l = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if l.contains("cash flow") && (l.contains("core account") || l.contains("credit balance")) { return true }
            return false
        }
        func isHoldingsHeader(_ s: String) -> Bool {
            let l = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return l.hasPrefix("holdings")
        }
        func isActivityHeader(_ s: String) -> Bool {
            let l = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if l.contains("activity") { return true }
            if l.contains("securities bought") || l.contains("securities sold") { return true }
            if l.contains("dividends") || l.contains("interest & other income") || l.contains("interest and other income") { return true }
            if l.contains("core fund activity") { return true }
            return false
        }
        func isActivityBoughtHeader(_ s: String) -> Bool {
            let l = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return l.contains("securities bought") || l.contains("you bought")
        }
        func isActivitySoldHeader(_ s: String) -> Bool {
            let l = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return l.contains("securities sold") || l.contains("you sold")
        }
        func isActivityDivIntHeader(_ s: String) -> Bool {
            let l = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return l.contains("dividends") || l.contains("interest & other income") || l.contains("interest and other income")
        }
        func isCoreFundActivityHeader(_ s: String) -> Bool {
            let l = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return l.contains("core fund activity")
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
            let balanceStr: String? = nil

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
            else if isInvestmentHeader(desc) { currentAccount = .investment }
            return ([date, desc, amt, balanceStr ?? ""], max(1, j - start))
        }

        var rows: [[String]] = []
        var usedLayout: Bool = false
        if enableOCR {
            do {
                let layout = layoutTryExtraction(doc: doc, inferredYear: inferredYear)
                AMLogging.always("PDF layout-based attempt — rows: \(layout.rows.count), conf: \(String(format: "%.2f", layout.confidence))", component: "PDFStatementExtractor")
                if layout.rows.count >= 5 && layout.confidence >= 0.6 {
                    rows = layout.rows
                    usedLayout = true
                    AMLogging.always("PDF layout-based extraction accepted (using layout rows)", component: "PDFStatementExtractor")
                }
            }
        }

        if !usedLayout {
            var i = 0
            while i < lines.count {
                let line = lines[i]

                if !isDateStart(line) {
                    // Page break reset
                    if isPageBreak(line) {
                        AMLogging.always("PDF page break — resetting section/account state", component: "PDFStatementExtractor")
                        currentAccount = .unknown
                        currentFlow = .none
                        currentSection = .unknown
                        recentContext.removeAll()
                        currentPageIndex += 1
                        i += 1
                        continue
                    }

                    pushContext(line)
                    // Update section/account state on non-date lines
                    if isSavingsHeader(line) { currentAccount = .savings; AMLogging.always("PDF section: SAVINGS detected at line \(i)", component: "PDFStatementExtractor") }
                    else if isCheckingHeader(line) { currentAccount = .checking; AMLogging.always("PDF section: CHECKING detected at line \(i)", component: "PDFStatementExtractor") }
                    else if isInvestmentHeader(line) { currentAccount = .investment; AMLogging.always("PDF section: INVESTMENT detected at line \(i)", component: "PDFStatementExtractor") }
                    do {
                        let lowerKW = line.lowercased()
                        if (lowerKW.contains("stock") || lowerKW.contains("options")) && currentAccount != .investment && !isInvestmentHeader(line) {
                            AMLogging.always("PDF INVESTMENT keywords present but not recognized as header at line \(i): \(line)", component: "PDFStatementExtractor")
                        }
                    }
                    // Account meta lines like "Primary Account: ..." can also indicate checking/savings/investment
                    if isAccountMetaLine(line) {
                        let lower = line.lowercased()
                        if lower.contains("savings") { currentAccount = .savings; AMLogging.always("PDF account meta => SAVINGS at line \(i)", component: "PDFStatementExtractor") }
                        else if lower.contains("checking") { currentAccount = .checking; AMLogging.always("PDF account meta => CHECKING at line \(i)", component: "PDFStatementExtractor") }
                        else if lower.contains("brokerage") || lower.contains("investment") || lower.contains("fidelity") || lower.contains("ira") {
                            currentAccount = .investment
                            AMLogging.always("PDF account meta => INVESTMENT at line \(i)", component: "PDFStatementExtractor")
                        }
                    }

                    // Section header detection for brokerage statements
                    if isAccountSummaryHeader(line) { currentSection = .accountSummary }
                    else if isCashFlowHeader(line) { currentSection = .cashFlow }
                    else if isHoldingsHeader(line) { currentSection = .holdings }
                    else if isActivityHeader(line) {
                        currentSection = .activity
                        if currentAccount == .unknown { currentAccount = .investment }
                    }

                    // Within Activity, set flow hints for sign normalization
                    if currentSection == .activity {
                        if isActivityBoughtHeader(line) { currentFlow = .withdrawal }
                        else if isActivitySoldHeader(line) { currentFlow = .deposit }
                        else if isActivityDivIntHeader(line) { currentFlow = .deposit }
                        // Core Fund Activity stays neutral unless specific keywords dictate otherwise
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

                // For brokerage statements (investment accounts), only parse transactions inside Activity sections
                if currentAccount == .investment && currentSection != .activity {
                    i += 1
                    continue
                }

                // If account not yet determined, infer from recent context buffer
                if currentAccount == .unknown {
                    if contextIndicatesSavings() { currentAccount = .savings; AMLogging.always("PDF context => SAVINGS at line \(i)", component: "PDFStatementExtractor") }
                    else if contextIndicatesChecking() { currentAccount = .checking; AMLogging.always("PDF context => CHECKING at line \(i)", component: "PDFStatementExtractor") }
                    else if contextIndicatesInvestment() { currentAccount = .investment; AMLogging.always("PDF context => INVESTMENT at line \(i)", component: "PDFStatementExtractor") }
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
                    // If the description itself indicates account type, update context
                    if isSavingsHeader(desc) { currentAccount = .savings }
                    else if isInvestmentHeader(desc) { currentAccount = .investment }
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
        }

        

        // Attempt summary synthesis (decoupled from transactions) and OCR-based summary fallback
        do {
            var periodForSummary: StatementPeriod? = statementPeriod

            // Detect a single statement end date (e.g., "Statement Date", "Billing Date", "Closing Date", or lines like "... as of Jan 31, 2026")
            func detectSingleStatementEndDate(in src: [String]) -> (month: Int, day: Int?, year: Int?)? {
                for line in src {
                    let lower = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    // Require a relevant keyword to avoid false positives
                    let looksLikeSingleDateHeader = lower.contains("statement date") || lower.contains("billing date") || lower.contains("closing date") || (lower.contains("period ending")) || (lower.contains("as of") && (lower.contains("balance") || lower.contains("principal") || lower.contains("loan")))
                    if !looksLikeSingleDateHeader { continue }
                    // Find first date token on this line
                    if let m = anyDateRegex.firstMatch(in: line, options: [], range: NSRange(location: 0, length: line.utf16.count)) {
                        let r = m.range(at: 0)
                        if let rr = Range(r, in: line) {
                            let token = String(line[rr])
                            let comp = extractMonthYear(from: token)
                            if let mm = comp.month {
                                return (month: mm, day: comp.day, year: comp.year)
                            }
                        }
                    }
                }
                return nil
            }

            if periodForSummary == nil {
                if let single = detectSingleStatementEndDate(in: lines) {
                    let y = single.year ?? inferredYear ?? Calendar.current.component(.year, from: Date())
                    let sp = StatementPeriod(startMonth: single.month, startYear: y, startDay: 1, endMonth: single.month, endYear: y, endDay: single.day)
                    periodForSummary = sp
                    AMLogging.always("PDF detected single-date period => month=\(single.month) day=\(single.day ?? -1) year=\(y)", component: "PDFStatementExtractor")
                }
            }

            // Date formatter for summary dates
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone(secondsFromGMT: 0)
            df.dateFormat = "MM/dd/yyyy"

            // Convert StatementPeriod to concrete Date range using inferred year logic
            func summaryDates(from sp: StatementPeriod) -> (Date, Date)? {
                var cal = Calendar(identifier: .gregorian)
                cal.timeZone = TimeZone(secondsFromGMT: 0)!
                var comps = DateComponents()
                comps.calendar = cal
                comps.year = sp.startYear
                comps.month = sp.startMonth
                comps.day = sp.startDay ?? 1
                guard let start = cal.date(from: comps) else { return nil }
                var ecomps = DateComponents()
                ecomps.calendar = cal
                ecomps.year = sp.endYear
                ecomps.month = sp.endMonth
                ecomps.day = sp.endDay ?? {
                    // Default to last day of month if endDay absent
                    var last = DateComponents()
                    last.year = sp.endYear
                    last.month = sp.endMonth
                    // Ask calendar for range of days in month
                    let range = cal.range(of: .day, in: .month, for: cal.date(from: DateComponents(year: sp.endYear, month: sp.endMonth, day: 1))!)
                    return range?.count ?? 28
                }()
                guard let end = cal.date(from: ecomps) else { return nil }
                return (start, end)
            }

            // Helper to parse normalized date "MM/dd/yyyy"
            func parseNormalizedDate(_ s: String) -> Date? {
                let df = DateFormatter()
                df.locale = Locale(identifier: "en_US_POSIX")
                df.timeZone = TimeZone(secondsFromGMT: 0)
                df.dateFormat = "MM/dd/yyyy"
                return df.date(from: s)
            }

            // Infer account context by scanning nearby lines for strong signals
            func inferAccountContext(around index: Int, in lines: [String]) -> AccountKind {
                let window = 20
                // Scan backward first for stronger locality
                var i = index
                while i >= max(0, index - window) {
                    let l = lines[i]
                    if isSavingsHeader(l) { return .savings }
                    if isCheckingHeader(l) { return .checking }
                    if lowerContainsInvestmentStrongSignals(l) { return .investment }
                    let lower = l.lowercased()
                    if lower.contains("savings account") || lower.contains("savings summary") || lower.contains("savings") {
                        if !lower.contains("from a checking") && !lower.contains("from checking") { return .savings }
                    }
                    if lower.contains("checking account") || lower.contains("checking summary") || lower.contains("checking") {
                        if !lower.contains("from a checking") && !lower.contains("from checking") { return .checking }
                    }
                    if isPageBreak(l) { break }
                    i -= 1
                }
                // Scan forward a short distance in case header follows label
                i = index + 1
                while i <= min(lines.count - 1, index + window) {
                    let l = lines[i]
                    if isPageBreak(l) { break }
                    if isSavingsHeader(l) { return .savings }
                    if isCheckingHeader(l) { return .checking }
                    let lower = l.lowercased()
                    if lower.contains("savings account") || lower.contains("savings summary") || lower.contains("savings") {
                        if !lower.contains("from a checking") && !lower.contains("from checking") { return .savings }
                    }
                    if lower.contains("checking account") || lower.contains("checking summary") || lower.contains("checking") {
                        if !lower.contains("from a checking") && !lower.contains("from checking") { return .checking }
                    }
                    if isPageBreak(l) { break }
                    i += 1
                }
                return .unknown
            }
            func lowerContainsInvestmentStrongSignals(_ s: String) -> Bool {
                let lower = s.lowercased()
                return lower.contains("brokerage") || lower.contains("investment account") || lower.contains("fidelity investments") || lower.contains("ira") || lower.contains("stock") || lower.contains("securities") || lower.contains("portfolio")
            }
            func isPeriodHeaderLine(_ s: String) -> Bool {
                let lower = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if hasMoneyToken(s) { return false }
                // Key on the word "period" to keep generic; also accept common synonyms
                if lower.contains("period") { return true }
                if lower.contains("year-to-date") || lower.contains("year to date") || lower.contains("ytd") { return true }
                return false
            }

            func isWithinPeriodTable(_ index: Int, in lines: [String]) -> Bool {
                // Look up a short window for a header that mentions period/YTD; stop at page breaks
                let window = 6
                var i = index
                while i >= max(0, index - window) {
                    let l = lines[i]
                    if isPageBreak(l) { break }
                    if isPeriodHeaderLine(l) { return true }
                    i -= 1
                }
                return false
            }

            // Inserted helper function to detect loan payment amount
            func detectLoanPaymentAmount(in src: [String]) -> String? {
                // Prefer Amount Due; fall back to Regular/Scheduled/Monthly Payment
                let dueLabels = [
                    "current amount due", "total amount due", "amount due", "payment due", "amount due now", "due now"
                ]
                let typicalLabels = [
                    "regular monthly payment amount", "regular payment amount", "scheduled payment", "monthly payment", "installment amount", "payment amount"
                ]

                func amountNearLabel(lineIndex: Int, labels: [String]) -> String? {
                    guard lineIndex >= 0 && lineIndex < src.count else { return nil }
                    let line = src[lineIndex]
                    let lower = line.lowercased()
                    // If label is on this line, prefer the rightmost amount on the same line; otherwise, check the next line
                    for lbl in labels {
                        if let r = lower.range(of: lbl) {
                            let suffix = String(line[r.upperBound...])
                            let matches = amountAnywhereRegex.matches(in: suffix, options: [], range: NSRange(location: 0, length: suffix.utf16.count))
                            if let chosen = matches.last, let rr = Range(chosen.range, in: suffix) {
                                return sanitizeAmount(String(suffix[rr]))
                            }
                            // Try same line anywhere if suffix failed
                            let sameMatches = amountAnywhereRegex.matches(in: line, options: [], range: NSRange(location: 0, length: line.utf16.count))
                            if let chosen2 = sameMatches.last, let rr2 = Range(chosen2.range, in: line) {
                                return sanitizeAmount(String(line[rr2]))
                            }
                            // Try next line
                            if lineIndex + 1 < src.count {
                                let next = src[lineIndex + 1]
                                if amountOnlyRegex.firstMatch(in: next, options: [], range: NSRange(location: 0, length: next.utf16.count)) != nil {
                                    return sanitizeAmount(next)
                                }
                                let nextMatches = amountAnywhereRegex.matches(in: next, options: [], range: NSRange(location: 0, length: next.utf16.count))
                                if let chosen3 = nextMatches.last, let rr3 = Range(chosen3.range, in: next) {
                                    return sanitizeAmount(String(next[rr3]))
                                }
                            }
                        }
                    }
                    return nil
                }

                // 1) Try Amount Due first
                for (idx, raw) in src.enumerated() {
                    let lower = raw.lowercased()
                    if dueLabels.contains(where: { lower.contains($0) }) {
                        if let amt = amountNearLabel(lineIndex: idx, labels: dueLabels) { return amt }
                    }
                }
                // 2) Fall back to typical/regular payment labels
                for (idx, raw) in src.enumerated() {
                    let lower = raw.lowercased()
                    if typicalLabels.contains(where: { lower.contains($0) }) {
                        if let amt = amountNearLabel(lineIndex: idx, labels: typicalLabels) { return amt }
                    }
                }
                return nil
            }

            func findBalancesPerAccount(in src: [String], useSectionFilter: Bool) -> [AccountKind: (begin: String?, end: String?)] {
                let beginLabels = [
                    "beginning balance", "opening balance",
                    "beginning account value", "beginning value", "beginning account balance",
                    "previous balance", "prior balance", "starting balance",
                    "balance at beginning", "starting account value"
                ]
                let endLabels = [
                    // Generic ending balance phrases
                    "ending balance", "current balance", "closing balance",
                    "ending account value", "ending value", "ending account balance",
                    "new balance", "closing value", "balance at end", "balance as of",
                    // Loan/principal-specific phrases
                    "principal balance", "outstanding principal", "current principal balance", "principal outstanding",
                    "unpaid principal balance", "remaining principal", "principal remaining",
                    "loan balance", "current loan balance",
                    "balance remaining", "remaining balance",
                    "upb"
                ]

                var result: [AccountKind: (begin: String?, end: String?)] = [:]

                func rangeOfAnyLabel(_ labels: [String], in lower: String) -> Range<String.Index>? {
                    for lbl in labels { if let r = lower.range(of: lbl) { return r } }
                    return nil
                }

                func amountNear(lineIndex: Int, labels: [String], in lines: [String]) -> String? {
                    guard lineIndex >= 0 && lineIndex < lines.count else { return nil }
                    let current = lines[lineIndex]
                    let lower = current.lowercased()
                    let preferLeftmost = isWithinPeriodTable(lineIndex, in: lines)
                    if let range = rangeOfAnyLabel(labels, in: lower) {
                        let suffixStart = range.upperBound
                        let suffix = String(current[suffixStart...])
                        let matches = amountAnywhereRegex.matches(in: suffix, options: [], range: NSRange(location: 0, length: suffix.utf16.count))
                        if let chosen = (preferLeftmost ? matches.first : matches.last), let r = Range(chosen.range, in: suffix) {
                            if preferLeftmost { AMLogging.always("PDF summary: period table context — preferring leftmost amount after label at line \(lineIndex)", component: "PDFStatementExtractor") }
                            return sanitizeAmount(String(suffix[r]))
                        }
                    }
                    let sameMatches = amountAnywhereRegex.matches(in: current, options: [], range: NSRange(location: 0, length: current.utf16.count))
                    if let chosen = (preferLeftmost ? sameMatches.first : sameMatches.last), let r = Range(chosen.range, in: current) {
                        if preferLeftmost { AMLogging.always("PDF summary: period table context — preferring leftmost amount on same line at line \(lineIndex)", component: "PDFStatementExtractor") }
                        return sanitizeAmount(String(current[r]))
                    }
                    if lineIndex + 1 < lines.count {
                        let next = lines[lineIndex + 1]
                        if amountOnlyRegex.firstMatch(in: next, options: [], range: NSRange(location: 0, length: next.utf16.count)) != nil {
                            return sanitizeAmount(next)
                        }
                        let nextMatches = amountAnywhereRegex.matches(in: next, options: [], range: NSRange(location: 0, length: next.utf16.count))
                        if let chosen = (preferLeftmost ? nextMatches.first : nextMatches.last), let r = Range(chosen.range, in: next) {
                            if preferLeftmost { AMLogging.always("PDF summary: period table context — preferring leftmost amount on next line at line \(lineIndex + 1)", component: "PDFStatementExtractor") }
                            return sanitizeAmount(String(next[r]))
                        }
                    }
                    return nil
                }

                for (idx, l) in src.enumerated() {
                    if useSectionFilter {
                        guard let sec = sectionByLine[idx], sec == .accountSummary else { continue }
                    }
                    let lower = l.lowercased()
                    if rangeOfAnyLabel(beginLabels, in: lower) != nil {
                        let amt = amountNear(lineIndex: idx, labels: beginLabels, in: src)
                        let acct = inferAccountContext(around: idx, in: src)
                        var tuple = result[acct] ?? (begin: nil, end: nil)
                        if tuple.begin == nil { tuple.begin = amt }
                        result[acct] = tuple
                    }
                    if rangeOfAnyLabel(endLabels, in: lower) != nil {
                        let amt = amountNear(lineIndex: idx, labels: endLabels, in: src)
                        let acct = inferAccountContext(around: idx, in: src)
                        var tuple = result[acct] ?? (begin: nil, end: nil)
                        if tuple.end == nil { tuple.end = amt }
                        result[acct] = tuple
                    }
                }
                return result
            }

            // Debug helpers for logging
            func kindName(_ k: AccountKind) -> String {
                switch k { case .checking: return "checking"; case .savings: return "savings"; case .investment: return "brokerage"; default: return "unknown" }
            }
            func debugBalances(_ dict: [AccountKind: (begin: String?, end: String?)]) -> String {
                return dict.map { (k, v) in
                    "\(kindName(k)): begin=\(v.begin ?? "nil"), end=\(v.end ?? "nil")"
                }.sorted().joined(separator: "; ")
            }

            // Ensure balances are negative for liabilities like loans/mortgages
            func forceNegative(_ amount: String) -> String {
                var a = amount.trimmingCharacters(in: .whitespacesAndNewlines)
                if a.isEmpty { return a }
                if a.hasPrefix("-") { return a }
                if a.hasPrefix("+") { a.removeFirst() }
                if let v = Double(a), v == 0 { return "0" }
                return "-" + a
            }

            // Compute earliest/latest dates from any already-extracted rows
            var earliestDate: Date? = nil
            var latestDate: Date? = nil
            do {
                let dates: [Date] = rows.compactMap { $0.first }.compactMap { parseNormalizedDate($0) }
                earliestDate = dates.min()
                latestDate = dates.max()
            }
            var balancesByAccount: [AccountKind: (begin: String?, end: String?)] = findBalancesPerAccount(in: lines, useSectionFilter: true)

            // Fallback: if no balances found with section filter, retry without it
            do {
                let hasAny = balancesByAccount.values.contains { $0.begin != nil || $0.end != nil }
                if !hasAny {
                    let fallback = findBalancesPerAccount(in: lines, useSectionFilter: false)
                    let hasFallback = fallback.values.contains { $0.begin != nil || $0.end != nil }
                    if hasFallback {
                        balancesByAccount = fallback
                        AMLogging.always("PDF summary: using fallback (no section filter) = \(debugBalances(balancesByAccount))", component: "PDFStatementExtractor")
                    }
                }
            }

            var balancesFromOCR = false
            var ocrLinesLocal: [String] = []

            // If none found, try OCR lines for summary amounts and period
            let hasAnyTextBalances = balancesByAccount.values.contains { $0.begin != nil || $0.end != nil }
            if !hasAnyTextBalances && enableOCR {
                let ocrLines = ocrExtractLines(from: doc, scale: 2.0)
                var ocrBalances = findBalancesPerAccount(in: ocrLines, useSectionFilter: true)
                if !ocrBalances.values.contains(where: { $0.begin != nil || $0.end != nil }) {
                    ocrBalances = findBalancesPerAccount(in: ocrLines, useSectionFilter: false)
                }
                if ocrBalances.values.contains(where: { $0.begin != nil || $0.end != nil }) {
                    balancesByAccount = ocrBalances
                    balancesFromOCR = true
                    ocrLinesLocal = ocrLines
                    if periodForSummary == nil {
                        periodForSummary = detectStatementPeriod(in: ocrLines)
                    }
                    AMLogging.always("PDF summary: using OCR balances = \(debugBalances(ocrBalances))", component: "PDFStatementExtractor")
                }
            }

            // Fallback: if balances are under .unknown, try to assign based on document-wide hints
            if let unknownPair = balancesByAccount[.unknown], (unknownPair.begin != nil || unknownPair.end != nil) {
                let sourceLinesAll = balancesFromOCR ? ocrLinesLocal : lines
                let docHasSavings = sourceLinesAll.contains { $0.lowercased().contains("savings") }
                let docHasChecking = sourceLinesAll.contains { $0.lowercased().contains("checking") }
                let docHasInvestment = sourceLinesAll.contains { let l = $0.lowercased(); return l.contains("brokerage") || l.contains("investment account") || l.contains("fidelity") || l.contains("ira") || l.contains("stock") || l.contains("securities") || l.contains("portfolio") }
                if balancesByAccount[.investment] == nil && docHasInvestment {
                    balancesByAccount[.investment] = unknownPair
                    balancesByAccount.removeValue(forKey: .unknown)
                    AMLogging.always("PDF summary: mapped unknown balances to investment based on document hints", component: "PDFStatementExtractor")
                } else if balancesByAccount[.savings] == nil && docHasSavings && !docHasChecking {
                    balancesByAccount[.savings] = unknownPair
                    balancesByAccount.removeValue(forKey: .unknown)
                    AMLogging.always("PDF summary: mapped unknown balances to savings based on document hints", component: "PDFStatementExtractor")
                } else if balancesByAccount[.checking] == nil && docHasChecking && !docHasSavings {
                    balancesByAccount[.checking] = unknownPair
                    balancesByAccount.removeValue(forKey: .unknown)
                    AMLogging.always("PDF summary: mapped unknown balances to checking based on document hints", component: "PDFStatementExtractor")
                }
            }

            // Loan-specific fallback scan: detect amounts near loan phrases when generic summary scan found nothing
            func scanLoanBalances(in src: [String]) -> (begin: String?, end: String?) {
                let endLabels = [
                    // Prefer explicit balance terms for loans
                    "current balance", "ending balance", "closing balance", "balance as of",
                    "principal balance", "outstanding principal", "current principal balance", "principal outstanding",
                    "unpaid principal balance", "remaining principal", "principal remaining",
                    "loan balance", "current loan balance",
                    "balance remaining", "remaining balance",
                    "upb"
                ]
                let beginLabels = ["beginning balance", "opening balance", "original balance"]

                func extractAmountNear(lineIndex: Int, labels: [String]) -> String? {
                    guard lineIndex >= 0 && lineIndex < src.count else { return nil }
                    let current = src[lineIndex]
                    let lower = current.lowercased()
                    func rangeOfAnyLabel(_ labels: [String], in lower: String) -> Range<String.Index>? {
                        for lbl in labels { if let r = lower.range(of: lbl) { return r } }
                        return nil
                    }
                    if let range = rangeOfAnyLabel(labels, in: lower) {
                        let suffixStart = range.upperBound
                        let suffix = String(current[suffixStart...])
                        let matches = amountAnywhereRegex.matches(in: suffix, options: [], range: NSRange(location: 0, length: suffix.utf16.count))
                        if let chosen = matches.last, let r = Range(chosen.range, in: suffix) {
                            return sanitizeAmount(String(suffix[r]))
                        }
                    }
                    let sameMatches = amountAnywhereRegex.matches(in: current, options: [], range: NSRange(location: 0, length: current.utf16.count))
                    if let chosen = sameMatches.last, let r = Range(chosen.range, in: current) {
                        return sanitizeAmount(String(current[r]))
                    }
                    if lineIndex + 1 < src.count {
                        let next = src[lineIndex + 1]
                        if amountOnlyRegex.firstMatch(in: next, options: [], range: NSRange(location: 0, length: next.utf16.count)) != nil {
                            return sanitizeAmount(next)
                        }
                        let nextMatches = amountAnywhereRegex.matches(in: next, options: [], range: NSRange(location: 0, length: next.utf16.count))
                        if let chosen = nextMatches.last, let r = Range(chosen.range, in: next) {
                            return sanitizeAmount(String(next[r]))
                        }
                    }
                    return nil
                }

                var begin: String? = nil
                var end: String? = nil
                for (idx, line) in src.enumerated() {
                    let lower = line.lowercased()
                    if begin == nil && beginLabels.contains(where: { lower.contains($0) }) {
                        begin = extractAmountNear(lineIndex: idx, labels: beginLabels)
                    }
                    if end == nil && endLabels.contains(where: { lower.contains($0) }) {
                        end = extractAmountNear(lineIndex: idx, labels: endLabels)
                    }
                    if begin != nil && end != nil { break }
                }
                return (begin, end)
            }

            let hasAnyBalances2 = balancesByAccount.values.contains { $0.begin != nil || $0.end != nil }
            
            // Inserted code to detect loan payment and append suggested payment row
            // Detect a loan/mortgage context and suggest a monthly payment from the statement
            let docLooksLoan: Bool = {
                let lc = lines.map { $0.lowercased() }
                return lc.contains(where: { $0.contains("loan") || $0.contains("mortgage") })
            }()

            var suggestedPayment: String? = nil
            if docLooksLoan {
                suggestedPayment = detectLoanPaymentAmount(in: lines)
                if suggestedPayment == nil && enableOCR {
                    let ocrLines = ocrExtractLines(from: doc, scale: 2.0)
                    suggestedPayment = detectLoanPaymentAmount(in: ocrLines)
                }
            }

            // Choose a date for the suggested payment row (use statement end date if available)
            var paymentDateStr: String? = nil
            if let sp = periodForSummary, let (_, endDate) = summaryDates(from: sp) {
                paymentDateStr = df.string(from: endDate)
            } else if let latest = latestDate {
                paymentDateStr = df.string(from: latest)
            }

            if let pay = suggestedPayment, let pDate = paymentDateStr {
                rows.append([pDate, "Estimated Monthly Payment (Loan)", pay, "", "loan"])
                AMLogging.always("PDF summary: appended typical payment row amount=\(pay) date=\(pDate)", component: "PDFStatementExtractor")
            }
            // End inserted code

            if !hasAnyBalances2 {
                let source = balancesFromOCR ? ocrLinesLocal : lines
                let loan = scanLoanBalances(in: source)
                if loan.begin != nil || loan.end != nil {
                    balancesByAccount[.unknown] = (begin: loan.begin, end: loan.end)
                    let beginStr = loan.begin ?? "nil"
                    let endStr = loan.end ?? "nil"
                    AMLogging.always("PDF summary: loan-specific scan found begin=\(beginStr), end=\(endStr)", component: "PDFStatementExtractor")
                }
            }

            var didAppendSummary = false
            // Compute shared dates once
            var beginDateStr: String? = nil
            var endDateStr: String? = nil
            if let sp = periodForSummary, let (beginDate, endDate) = summaryDates(from: sp) {
                beginDateStr = df.string(from: beginDate)
                endDateStr = df.string(from: endDate)
            } else if let e = earliestDate, let l = latestDate {
                var cal = Calendar(identifier: .gregorian)
                cal.timeZone = TimeZone(secondsFromGMT: 0)!
                let begin = cal.date(byAdding: .day, value: -1, to: e) ?? e
                beginDateStr = df.string(from: begin)
                endDateStr = df.string(from: l)
            }

            // Append summaries per-account when available
            for (acct, pair) in balancesByAccount {
                let sourceLines = balancesFromOCR ? ocrLinesLocal : lines
                let accountLabelDisplay = Self.accountDisplayLabel(for: acct, using: sourceLines)
                let accountKey = Self.accountTypeKey(for: acct)
                AMLogging.always("PDF summary: account label resolved for \(kindName(acct)) => \(accountLabelDisplay)", component: "PDFStatementExtractor")
                let lowerLabel = accountLabelDisplay.lowercased()
                let isLoanContext = lowerLabel.contains("loan") || lowerLabel.contains("mortgage")
                let isCreditCardContext = lowerLabel.contains("credit card") || lowerLabel.contains("visa") || lowerLabel.contains("mastercard") || lowerLabel.contains("amex") || lowerLabel.contains("american express") || lowerLabel.contains("discover")
                let accountKeyOut: String = {
                    if isLoanContext { return "loan" }
                    if isCreditCardContext { return "creditCard" }
                    return accountKey
                }()
                if let bAmt = pair.begin, let bDate = beginDateStr {
                    let beginBalanceForAccount = (isLoanContext || isCreditCardContext) ? forceNegative(bAmt) : bAmt
                    rows.append([bDate, "Statement Beginning Balance (\(accountLabelDisplay))", "0", beginBalanceForAccount, accountKeyOut])
                    AMLogging.always("PDF summary: appended beginning row accountKey=\(accountKeyOut)", component: "PDFStatementExtractor")
                    didAppendSummary = true
                    AMLogging.always("PDF summary (decoupled): beginning balance detected = \(bAmt) @ \(bDate) [\(accountLabelDisplay)]", component: "PDFStatementExtractor")
                }
                if let eAmt = pair.end, let eDate = endDateStr {
                    let endBalanceForAccount = (isLoanContext || isCreditCardContext) ? forceNegative(eAmt) : eAmt
                    rows.append([eDate, "Statement Ending Balance (\(accountLabelDisplay))", "0", endBalanceForAccount, accountKeyOut])
                    AMLogging.always("PDF summary: appended ending row accountKey=\(accountKeyOut)", component: "PDFStatementExtractor")
                    didAppendSummary = true
                    AMLogging.always("PDF summary (decoupled): ending balance detected = \(eAmt) @ \(eDate) [\(accountLabelDisplay)]", component: "PDFStatementExtractor")
                }
            }

            // If we synthesized statement summary balances and we're in summary-only mode, discard other rows
            if didAppendSummary && mode == .summaryOnly {
                rows = rows.filter { r in
                    guard r.count >= 2 else { return false }
                    let d = r[1].lowercased()
                    return d.contains("statement beginning balance") || d.contains("statement ending balance") || d.contains("typical payment (loan)") || d.contains("estimated monthly payment (loan)")
                }
            }

            // In summary-only mode, clear balances for non-summary rows
            if mode == .summaryOnly {
                for idx in 0..<rows.count {
                    if rows[idx].count >= 5 {
                        var key = rows[idx][4].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        if key.isEmpty || key == "unknown" || key.contains("•") || key.contains("account") {
                            let descLower = rows[idx][1].lowercased()
                            if descLower.contains("savings") { key = "savings" }
                            else if descLower.contains("checking") { key = "checking" }
                            else if descLower.contains("loan") || descLower.contains("mortgage") { key = "loan" }
                            else if descLower.contains("investment") || descLower.contains("brokerage") || descLower.contains("fidelity") { key = "brokerage" }
                            else if descLower.contains("stock") || descLower.contains("options") { key = "brokerage" }
                        }
                        rows[idx][4] = key.isEmpty ? "unknown" : key
                    }
                }
            }
        }

        // Final normalization: ensure Account column uses canonical keys for summary-only rows
        if mode == .summaryOnly {
            for idx in 0..<rows.count {
                if rows[idx].count >= 5 {
                    var key = rows[idx][4].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if key.isEmpty || key == "unknown" || key.contains("•") || key.contains("account") {
                        let descLower = rows[idx][1].lowercased()
                        if descLower.contains("savings") { key = "savings" }
                        else if descLower.contains("checking") { key = "checking" }
                        else if descLower.contains("loan") || descLower.contains("mortgage") { key = "loan" }
                        else if descLower.contains("investment") || descLower.contains("brokerage") || descLower.contains("fidelity") { key = "brokerage" }
                        else if descLower.contains("stock") || descLower.contains("options") { key = "brokerage" }
                    }
                    rows[idx][4] = key.isEmpty ? "unknown" : key
                }
            }
        }

        // Post-processing: ensure loan/mortgage summary balances are negative and keyed as 'loan'
        func forceNegativeIfNeeded(_ amount: String) -> String {
            var a = amount.trimmingCharacters(in: .whitespacesAndNewlines)
            if a.isEmpty { return a }
            if a.hasPrefix("-") { return a }
            if a.hasPrefix("+") { a.removeFirst() }
            if let v = Double(a), v == 0 { return "0" }
            return "-" + a
        }
        for idx in 0..<rows.count {
            guard rows[idx].count >= 5 else { continue }
            let descLower = rows[idx][1].lowercased()
            let isSummaryRow = descLower.contains("statement beginning balance") || descLower.contains("statement ending balance")
            if !isSummaryRow { continue }
            let keyLower = rows[idx][4].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let looksLoan = keyLower == "loan" || descLower.contains("loan") || descLower.contains("mortgage")
            let looksCC = keyLower == "creditcard" || keyLower == "credit_card" || keyLower == "credit card" || descLower.contains("credit card") || descLower.contains("visa") || descLower.contains("mastercard") || descLower.contains("amex") || descLower.contains("american express") || descLower.contains("discover")
            if looksLoan || looksCC {
                rows[idx][3] = forceNegativeIfNeeded(rows[idx][3])
                if keyLower.isEmpty || keyLower == "unknown" {
                    rows[idx][4] = looksLoan ? "loan" : "creditCard"
                }
            }
        }

        // Debug: list unique account keys present in the extracted rows
        let uniqueAccounts = Set(rows.compactMap { $0.count >= 5 ? $0[4] : nil })
        AMLogging.always("PDF rows account keys: \(Array(uniqueAccounts))", component: "PDFStatementExtractor")

        AMLogging.always("PDF matched rows: \(rows.count)", component: "PDFStatementExtractor")

        guard !rows.isEmpty else {
            let message = userFacingFailureMessage(for: url, mode: mode)
            AMLogging.always("PDF parse failed — returning user-facing message: \(message)", component: "PDFStatementExtractor")
            throw ImportError.parseFailure(message)
        }
        return (rows, headers)
    }

    // MARK: - Helper: Account labels/keys
    private static func accountTypeKey(for kind: AccountKind) -> String {
        switch kind {
        case .checking: return "checking"
        case .savings: return "savings"
        case .investment: return "brokerage"
        case .unknown: return "unknown"
        }
    }

    private static func accountDisplayLabel(for kind: AccountKind, using lines: [String]) -> String {
        switch kind {
        case .checking:
            return "Checking"
        case .savings:
            return "Savings"
        case .investment:
            // Try to refine brokerage label based on hints in nearby text
            let hasFidelity = lines.contains { $0.lowercased().contains("fidelity") }
            let hasIRA = lines.contains { $0.lowercased().contains("ira") }
            if hasIRA { return "Brokerage (IRA)" }
            if hasFidelity { return "Brokerage (Fidelity)" }
            return "Brokerage"
        case .unknown:
            // If unknown, try to infer a friendlier label from the document-wide hints
            let lowercased = lines.map { $0.lowercased() }
            if lowercased.contains(where: { $0.contains("loan") || $0.contains("mortgage") }) { return "Loan" }
            if lowercased.contains(where: { $0.contains("checking") }) { return "Checking" }
            if lowercased.contains(where: { $0.contains("savings") }) { return "Savings" }
            if lowercased.contains(where: { $0.contains("brokerage") || $0.contains("investment") || $0.contains("fidelity") }) {
                return "Brokerage"
            }
            return "Account"
        }
    }

    private static func userFacingFailureMessage(for url: URL, mode: Mode) -> String {
        let base = "We couldn't parse this PDF statement. If the file is stored in iCloud, make sure it has finished downloading. If the PDF is password-protected or a scanned image, please remove the password or export a text-based PDF and try again."
        switch mode {
        case .summaryOnly:
            return base + " You can also try switching to the full transactions mode and re-importing."
        case .transactions:
            return base
        }
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

