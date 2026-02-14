import Foundation
import PDFKit
import CoreGraphics
import Vision
import Darwin
import PDFKit

enum PDFStatementExtractor {
    enum Mode { case summaryOnly, transactions }

    enum AccountKind { case unknown, checking, savings, investment, loan }
    enum FlowKind { case none, deposit, withdrawal }
    enum Section { case unknown, accountSummary, cashFlow, holdings, activity }

    // Toggle OCR-based layout extraction (renders pages and can emit noisy system logs)
    static let enableOCR: Bool = false
    static var enableAPRDebugLogs: Bool = true

    // Optional user-selected account kind override (e.g., force Loan)
    static var userSelectedAccountOverride: AccountKind? = nil
    static func setUserSelectedAccountOverride(_ kind: AccountKind?) {
        self.userSelectedAccountOverride = kind
    }

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

    static func parse(url: URL, mode: Mode = .summaryOnly, userOverride: AccountKind? = nil) throws -> (rows: [[String]], headers: [String]) {
        let doc: PDFDocument = try withSilencedSystemLogs {
            guard let d = PDFDocument(url: url) else {
                throw ImportError.parseFailure("Unable to open PDF. If the file is stored in iCloud, make sure it has finished downloading. If the PDF is password-protected, please remove the password and try again.")
            }
            return d
        }

        // Respect a user-selected account override if provided (parameter takes precedence over global)
        let accountOverride: AccountKind? = userOverride ?? Self.userSelectedAccountOverride

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
        AMLogging.log("PDF pages: \(doc.pageCount)", component: "PDFStatementExtractor")

        // Normalize and split into lines
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // Inserted line: detect loan/mortgage context in document-wide lines
        let docLooksLoan: Bool = lines.contains { let l = $0.lowercased(); return l.contains("loan") || l.contains("mortgage") }

        // APR detection (always run); logs gated by enableAPRDebugLogs
        var detectedAPR: Decimal? = nil
        var detectedAPRScale: Int? = nil
        do {
            let t0 = Date()
            let (aprFound, scaleFound) = Self.extractAPRFromPDF(at: url)
            detectedAPR = aprFound
            detectedAPRScale = scaleFound
            if Self.enableAPRDebugLogs {
                AMLogging.log("APR probe: invoking extractAPRFromPDF early", component: "PDFStatementExtractor")
                if let a = detectedAPR {
                    AMLogging.log("APR probe: detected aprFraction=\(a) scale=\(detectedAPRScale ?? -1)", component: "PDFStatementExtractor")
                } else {
                    AMLogging.log("APR probe: no APR found", component: "PDFStatementExtractor")
                }
                let dt = Date().timeIntervalSince(t0)
                AMLogging.log(String(format: "APR probe: duration=%.3fs", dt), component: "PDFStatementExtractor")
            }
        }

        // Try to infer a default year from any 4-digit year present in the document
        let inferredYear = detectInferredYear(from: lines)
        if let y = inferredYear {
            AMLogging.log("PDF inferred year: \(y)", component: "PDFStatementExtractor")
        } else {
            AMLogging.log("PDF inferred year: <none>", component: "PDFStatementExtractor")
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
                        AMLogging.log("PDF detected statement period: \(a) -> \(b) => start=\(am)/\(ay) d=\(aComp.day ?? -1) end=\(bm)/\(by) d=\(bComp.day ?? -1)", component: "PDFStatementExtractor")
                        return period
                    }
                }
            }
            return nil
        }
        var statementPeriod = detectStatementPeriod(in: lines)
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
            if lower.contains("account number") || lower.contains("account ending") || lower.contains("primary account") || lower.contains("primary accountant") {
                return true
            }
            // Include loan/mortgage meta phrases commonly found in headers
            if lower.contains("loan number") || lower.contains("loan account") || lower.contains("mortgage account") || lower.contains("mortgage loan") || lower.contains("lender") {
                return true
            }
            return false
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

        var currentAccount: AccountKind = accountOverride ?? .unknown
        var currentFlow: FlowKind = .none
        var currentSection: Section = .unknown

        func currentAccountLabel() -> String {
            switch currentAccount {
            case .checking: return "checking"
            case .savings: return "savings"
            case .investment: return "brokerage"
            case .loan: return "loan"
            case .unknown: return "unknown"
            }
        }

        // Pre-scan pages to infer a default account label per page (checking/savings) from headers
        var pageDefaults: [Int: AccountKind] = [:]
        if accountOverride == nil {
            do {
                var pageIdx = 0
                for l in lines {
                    if isPageBreak(l) { pageIdx += 1; continue }
                    if pageDefaults[pageIdx] == nil {
                        if isSavingsHeader(l) { pageDefaults[pageIdx] = .savings }
                        else if isCheckingHeader(l) { pageDefaults[pageIdx] = .checking }
                        else if isInvestmentHeader(l) && !docLooksLoan { pageDefaults[pageIdx] = .investment }
                    }
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
                else if isActivityHeader(l) {
                    sec = .activity
                    if currentAccount == .unknown && accountOverride == nil && !docLooksLoan { currentAccount = .investment }
                }
                sectionByLine[idx] = sec
            }
        }

        // Track current page during parsing
        var currentPageIndex = 0
        func accountLabelForRow() -> String {
            if let ov = accountOverride {
                switch ov {
                case .checking: return "checking"
                case .savings: return "savings"
                case .investment: return "brokerage"
                case .loan: return "loan"
                case .unknown: break
                }
            }
            switch currentAccount {
            case .checking: return "checking"
            case .savings: return "savings"
            case .investment: return "brokerage"
            case .loan: return "loan"
            case .unknown: return "unknown"
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
            // Treat common section headers like "Stock" or explicit Options Activity as investment headers.
            // Avoid generic phrases like "payment options", "repayment options", etc.
            let optionsNegative = lower.contains("payment options") || lower.contains("repayment options") || lower.contains("loan options") || lower.contains("mortgage options") || lower.contains("options for") || lower.contains("options include") || lower.contains("service options") || lower.contains("billing options") || lower.contains("delivery options")
            let optionsLike = (lower.contains("options activity") || lower.contains("option activity") || lower.contains("options transactions") || lower.contains("option transactions") || lower.contains("calls") || lower.contains("puts")) && !optionsNegative
            let stockLike = lower.contains("stock") && !lower.contains("out of stock")
            if (stockLike || optionsLike) {
                // Header-like constraints: no digits and mostly uppercase or short
                let hasDigits = raw.rangeOfCharacter(from: .decimalDigits) != nil
                let hasLowercase = raw.rangeOfCharacter(from: .lowercaseLetters) != nil
                if !hasDigits && (!hasLowercase || raw.count <= 28) {
                    // If the whole document looks like a loan/mortgage, avoid classifying as investment on weak signals
                    if docLooksLoan {
                        AMLogging.log("PDF: suppressing INVESTMENT header due to loan/mortgage context for line: \(raw)", component: "PDFStatementExtractor")
                        return false
                    }
                    return true
                }
            }
            // Generic header-like: contains brokerage/investment (not options), no digits, and mostly uppercase or short
            let hasDigits = raw.rangeOfCharacter(from: .decimalDigits) != nil
            let hasLowercase = raw.rangeOfCharacter(from: .lowercaseLetters) != nil
            if (lower.contains("brokerage") || lower.contains("investment") || lower.contains("stock")) && !lower.contains("savings") && !lower.contains("checking") && !hasDigits && (!hasLowercase || raw.count <= 28) {
                if docLooksLoan && !lower.contains("brokerage") && !lower.contains("fidelity") && !lower.contains("ira") {
                    // Only suppress when it's a weak/ambiguous signal
                    return false
                }
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
            if accountOverride == nil {
                if isSavingsHeader(desc) { currentAccount = .savings }
                else if isInvestmentHeader(desc) && !docLooksLoan { currentAccount = .investment }
            }
            return ([date, desc, amt, balanceStr ?? ""], max(1, j - start))
        }

        var rows: [[String]] = []
        var usedLayout: Bool = false
        if enableOCR {
            do {
                let layout = layoutTryExtraction(doc: doc, inferredYear: inferredYear)
                AMLogging.log("PDF layout-based attempt — rows: \(layout.rows.count), conf: \(String(format: "%.2f", layout.confidence))", component: "PDFStatementExtractor")
                if layout.rows.count >= 5 && layout.confidence >= 0.6 {
                    rows = layout.rows
                    usedLayout = true
                    AMLogging.log("PDF layout-based extraction accepted (using layout rows)", component: "PDFStatementExtractor")
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
                        AMLogging.log("PDF page break — resetting section/account state", component: "PDFStatementExtractor")
                        currentAccount = accountOverride ?? .unknown
                        currentFlow = .none
                        currentSection = .unknown
                        recentContext.removeAll()
                        currentPageIndex += 1
                        i += 1
                        continue
                    }

                    pushContext(line)
                    // Update section/account state on non-date lines if no override
                    if accountOverride == nil {
                        if isSavingsHeader(line) { currentAccount = .savings; AMLogging.log("PDF section: SAVINGS detected at line \(i)", component: "PDFStatementExtractor") }
                        else if isCheckingHeader(line) { currentAccount = .checking; AMLogging.log("PDF section: CHECKING detected at line \(i)", component: "PDFStatementExtractor") }
                        else if isInvestmentHeader(line) && !docLooksLoan { currentAccount = .investment; AMLogging.log("PDF section: INVESTMENT detected at line \(i)", component: "PDFStatementExtractor") }
                    }
                    do {
                        let lowerKW = line.lowercased()
                        if (lowerKW.contains("stock") || lowerKW.contains("options")) && currentAccount != .investment && !isInvestmentHeader(line) {
                            AMLogging.log("PDF INVESTMENT keywords present but not recognized as header at line \(i): \(line)", component: "PDFStatementExtractor")
                        }
                    }
                    // Account meta lines like "Primary Account: ..." can also indicate checking/savings/investment
                    if accountOverride == nil && isAccountMetaLine(line) {
                        let lower = line.lowercased()
                        if lower.contains("loan") || lower.contains("mortgage") {
                            currentAccount = .loan
                            AMLogging.log("PDF account meta => LOAN at line \(i)", component: "PDFStatementExtractor")
                        } else if lower.contains("savings") {
                            currentAccount = .savings
                            AMLogging.log("PDF account meta => SAVINGS at line \(i)", component: "PDFStatementExtractor")
                        } else if lower.contains("checking") {
                            currentAccount = .checking
                            AMLogging.log("PDF account meta => CHECKING at line \(i)", component: "PDFStatementExtractor")
                        } else if lower.contains("brokerage") || lower.contains("investment") || lower.contains("fidelity") || lower.contains("ira") {
                            currentAccount = .investment
                            AMLogging.log("PDF account meta => INVESTMENT at line \(i)", component: "PDFStatementExtractor")
                        }
                    }

                    // Section header detection for brokerage statements
                    if isAccountSummaryHeader(line) { currentSection = .accountSummary }
                    else if isCashFlowHeader(line) { currentSection = .cashFlow }
                    else if isHoldingsHeader(line) { currentSection = .holdings }
                    else if isActivityHeader(line) {
                        currentSection = .activity
                        if currentAccount == .unknown && accountOverride == nil && !docLooksLoan { currentAccount = .investment }
                    }

                    // Within Activity, set flow hints for sign normalization
                    if currentSection == .activity {
                        if isActivityBoughtHeader(line) { currentFlow = .withdrawal }
                        else if isActivitySoldHeader(line) { currentFlow = .deposit }
                        else if isActivityDivIntHeader(line) { currentFlow = .deposit }
                        // Core Fund Activity stays neutral unless specific keywords dictate otherwise
                    }

                    if isDepositsHeader(line) { currentFlow = .deposit; AMLogging.log("PDF flow: DEPOSITS detected at line \(i)", component: "PDFStatementExtractor") }
                    else if isWithdrawalsHeader(line) { currentFlow = .withdrawal; AMLogging.log("PDF flow: WITHDRAWALS detected at line \(i)", component: "PDFStatementExtractor") }
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
                if currentAccount == .unknown && accountOverride == nil {
                    // Updated per instruction 1: include documentLooksCreditCardLoose in condition
                    if documentLooksCreditCard(lines) || documentLooksCreditCardLoose(lines) { 
                        currentAccount = .unknown
                    } else {
                        if contextIndicatesSavings() { currentAccount = .savings; AMLogging.log("PDF context => SAVINGS at line \(i)", component: "PDFStatementExtractor") }
                        else if contextIndicatesChecking() { currentAccount = .checking; AMLogging.log("PDF context => CHECKING at line \(i)", component: "PDFStatementExtractor") }
                        else if contextIndicatesInvestment() && !docLooksLoan { currentAccount = .investment; AMLogging.log("PDF context => INVESTMENT at line \(i)", component: "PDFStatementExtractor") }
                    }
                }

                // Try multi-line reconstruction before strict single-line match
                if let multi = attemptMultiLineRow(in: lines, start: i) {
                    var row = multi.row
                    if row.count >= 3 { row[2] = applySectionSign(amount: row[2]) }
                    row.append(accountLabelForRow())
                    rows.append(row)
                    AMLogging.log("PDF multi-line row matched (\(accountLabelForRow())) at line \(i) consuming \(multi.consumed) lines", component: "PDFStatementExtractor")
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
                    // If the description itself indicates account type, update context if no override
                    if accountOverride == nil {
                        if isSavingsHeader(desc) { currentAccount = .savings }
                        else if isInvestmentHeader(desc) && !docLooksLoan { currentAccount = .investment }
                    }
                    let amount = applySectionSign(amount: sanitizeAmount(amtRaw))
                    let balance = balRaw.isEmpty ? "" : sanitizeAmount(balRaw)
                    rows.append([date, desc, amount, balance, accountLabelForRow()])
                    AMLogging.log("PDF single-line row matched (\(accountLabelForRow())) at line \(i)", component: "PDFStatementExtractor")
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
                        if accountOverride == nil && isSavingsHeader(desc) { currentAccount = .savings }
                        let amount = applySectionSign(amount: sanitizeAmount(next))
                        rows.append([date, desc, amount, "", accountLabelForRow()]) // no balance captured in this shape
                        AMLogging.log("PDF two-line row matched (\(accountLabelForRow())) at line \(i)", component: "PDFStatementExtractor")
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

            // Date helper functions used by summary synthesis
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
                    let firstOfMonth = cal.date(from: DateComponents(year: sp.endYear, month: sp.endMonth, day: 1))!
                    let range = cal.range(of: .day, in: .month, for: firstOfMonth)
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

            // Document-level credit card detector
            func documentLooksCreditCard(_ lines: [String]) -> Bool {
                let lc = lines.map {
                    $0
                        .replacingOccurrences(of: "\u{00A0}", with: " ") // NBSP
                        .replacingOccurrences(of: "\u{2007}", with: " ") // Figure space
                        .replacingOccurrences(of: "\u{202F}", with: " ") // Narrow no-break space
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                }
                // Strong indicators typically present on credit card statements
                let strongKeywords = [
                    "credit card", "minimum payment", "payment due", "payment due date",
                    "previous balance", "new balance", "statement balance",
                    "credit limit", "available credit",
                    "interest charge", "finance charge",
                    "purchases apr", "purchase apr", "cash advance apr", "penalty apr", "intro apr",
                    "billing cycle", "closing date"
                ]
                if lc.contains(where: { line in strongKeywords.contains(where: { line.contains($0) }) }) {
                    return true
                }
                // Network/brand names commonly present
                let brands = ["visa", "mastercard", "american express", "amex", "discover"]
                if lc.contains(where: { line in brands.contains(where: { line.contains($0) }) }) {
                    return true
                }
                return false
            }

            // Narrow helper to catch statements that only say "New Balance as of ..."
            func documentLooksCreditCardLoose(_ lines: [String]) -> Bool {
                let lc = lines.map {
                    $0
                        .replacingOccurrences(of: "\u{00A0}", with: " ") // NBSP
                        .replacingOccurrences(of: "\u{2007}", with: " ") // Figure space
                        .replacingOccurrences(of: "\u{202F}", with: " ") // Narrow no-break space
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                }
                // Be conservative: require the stronger pattern "new balance as of" to avoid false positives
                return lc.contains { $0.contains("new balance as of") }
            }

            // Infer account context near a given line index (uses outer-scope helpers and state)
            func inferAccountContext(around index: Int, in lines: [String]) -> AccountKind {
                if let ov = accountOverride { return ov }
                // Updated per instruction 1: add documentLooksCreditCardLoose condition here
                if documentLooksCreditCard(lines) || documentLooksCreditCardLoose(lines) { return .unknown }

                let window = 20
                // Scan backward first for stronger locality
                var i = index
                while i >= max(0, index - window) {
                    let l = lines[i]
                    if isPageBreak(l) { break }
                    if isSavingsHeader(l) { return .savings }
                    if isCheckingHeader(l) { return .checking }
                    let lower = l.lowercased()
                    if lower.contains("loan") || lower.contains("mortgage") { return .loan }
                    if lower.contains("brokerage") || lower.contains("investment account") || lower.contains("fidelity investments") || lower.contains("ira") || lower.contains("stock") || lower.contains("securities") || lower.contains("portfolio") {
                        return .investment
                    }
                    if lower.contains("savings account") || lower.contains("savings summary") || lower.contains("savings") {
                        if !lower.contains("from a checking") && !lower.contains("from checking") { return .savings }
                    }
                    if lower.contains("checking account") || lower.contains("checking summary") || lower.contains("checking") {
                        if !lower.contains("from a checking") && !lower.contains("from checking") { return .checking }
                    }
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
                    if lower.contains("loan") || lower.contains("mortgage") { return .loan }
                    if lower.contains("brokerage") || lower.contains("investment account") || lower.contains("fidelity investments") || lower.contains("ira") || lower.contains("stock") || lower.contains("securities") || lower.contains("portfolio") {
                        return .investment
                    }
                    if lower.contains("savings account") || lower.contains("savings summary") || lower.contains("savings") {
                        if !lower.contains("from a checking") && !lower.contains("from checking") { return .savings }
                    }
                    if lower.contains("checking account") || lower.contains("checking summary") || lower.contains("checking") {
                        if !lower.contains("from a checking") && !lower.contains("from checking") { return .checking }
                    }
                    i += 1
                }
                return .unknown
            }

            // Period/YTD header detector used by balance extraction to bias amount selection
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

            // Function to find balances by account, with updated regex-based label matching
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

                // Build regexes for labels with flexible whitespace (including NBSP variants)
                let whitespaceClass = "[\\s\\u00A0\\u2007\\u202F]+"
                func buildLabelRegex(_ phrase: String) -> NSRegularExpression {
                    let parts = phrase.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
                    let pattern = parts.joined(separator: whitespaceClass)
                    return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
                }
                let beginLabelRegexes: [NSRegularExpression] = beginLabels.map(buildLabelRegex)
                let endLabelRegexes: [NSRegularExpression] = endLabels.map(buildLabelRegex)

                // Find the first match range of any label regex on a line
                func firstRangeOfAnyLabelRegex(_ regexes: [NSRegularExpression], in s: String) -> Range<String.Index>? {
                    let ns = s as NSString
                    let full = NSRange(location: 0, length: ns.length)
                    for rx in regexes {
                        if let m = rx.firstMatch(in: s, options: [], range: full), let r = Range(m.range, in: s) {
                            return r
                        }
                    }
                    return nil
                }

                func rangeOfAnyLabel(_ labels: [String], in lower: String) -> Range<String.Index>? {
                    for lbl in labels { if let r = lower.range(of: lbl) { return r } }
                    return nil
                }

                func amountNear(lineIndex: Int, labels: [String], labelRegexes: [NSRegularExpression], in lines: [String]) -> String? {
                    guard lineIndex >= 0 && lineIndex < lines.count else { return nil }
                    let current = lines[lineIndex]
                    let lower = current.lowercased()
                    let preferLeftmost = isWithinPeriodTable(lineIndex, in: lines)

                    // Determine suffix start using regex first (flexible whitespace), fallback to literal label search
                    var suffixStartIndex: String.Index? = nil
                    if let r = firstRangeOfAnyLabelRegex(labelRegexes, in: current) {
                        suffixStartIndex = r.upperBound
                    } else if let r2 = rangeOfAnyLabel(labels, in: lower) {
                        // Map the range from the lowercased string back to the original string by searching the substring
                        let labelSubstring = String(lower[r2])
                        if let rangeInOriginal = current.lowercased().range(of: labelSubstring) {
                            suffixStartIndex = rangeInOriginal.upperBound
                        }
                    }

                    // If we couldn't find a label, bail out
                    guard let suffixStart = suffixStartIndex else { return nil }

                    // Prefer amount tokens after the label on the same line
                    let suffix = String(current[suffixStart...])
                    let suffixMatches = amountAnywhereRegex.matches(in: suffix, options: [], range: NSRange(location: 0, length: suffix.utf16.count))
                    if let chosen = (preferLeftmost ? suffixMatches.first : suffixMatches.last), let r = Range(chosen.range, in: suffix) {
                        if preferLeftmost { AMLogging.log("PDF summary: period table context — preferring leftmost amount after label at line \(lineIndex)", component: "PDFStatementExtractor") }
                        return sanitizeAmount(String(suffix[r]))
                    }

                    // Fallback: any amount on the same line
                    let sameMatches = amountAnywhereRegex.matches(in: current, options: [], range: NSRange(location: 0, length: current.utf16.count))
                    if let chosen = (preferLeftmost ? sameMatches.first : sameMatches.last), let r = Range(chosen.range, in: current) {
                        if preferLeftmost { AMLogging.log("PDF summary: period table context — preferring leftmost amount on same line at line \(lineIndex)", component: "PDFStatementExtractor") }
                        return sanitizeAmount(String(current[r]))
                    }

                    // Next-line checks
                    if lineIndex + 1 < lines.count {
                        let next = lines[lineIndex + 1]
                        if amountOnlyRegex.firstMatch(in: next, options: [], range: NSRange(location: 0, length: next.utf16.count)) != nil {
                            return sanitizeAmount(next)
                        }
                        let nextMatches = amountAnywhereRegex.matches(in: next, options: [], range: NSRange(location: 0, length: next.utf16.count))
                        if let chosen = (preferLeftmost ? nextMatches.first : nextMatches.last), let r = Range(chosen.range, in: next) {
                            if preferLeftmost { AMLogging.log("PDF summary: period table context — preferring leftmost amount on next line at line \(lineIndex + 1)", component: "PDFStatementExtractor") }
                            return sanitizeAmount(String(next[r]))
                        }
                    }
                    return nil
                }

                var result: [AccountKind: (begin: String?, end: String?)] = [:]

                for (idx, l) in src.enumerated() {
                    if useSectionFilter {
                        guard let sec = sectionByLine[idx], sec == .accountSummary else { continue }
                    }
//                    let lower = l.lowercased()
                    if firstRangeOfAnyLabelRegex(beginLabelRegexes, in: l) != nil {
                        let amt = amountNear(lineIndex: idx, labels: beginLabels, labelRegexes: beginLabelRegexes, in: src)
                        let acct = inferAccountContext(around: idx, in: src)
                        var tuple = result[acct] ?? (begin: nil, end: nil)
                        if tuple.begin == nil { tuple.begin = amt }
                        result[acct] = tuple
                    }
                    if firstRangeOfAnyLabelRegex(endLabelRegexes, in: l) != nil {
                        let amt = amountNear(lineIndex: idx, labels: endLabels, labelRegexes: endLabelRegexes, in: src)
                        let acct = inferAccountContext(around: idx, in: src)
                        var tuple = result[acct] ?? (begin: nil, end: nil)
                        if tuple.end == nil { tuple.end = amt }
                        result[acct] = tuple
                    }
                }
                return result
            }

            AMLogging.log("Doc CC strong? \(documentLooksCreditCard(lines))", component: "PDFStatementExtractor")
            AMLogging.log("Doc CC loose? \(documentLooksCreditCardLoose(lines))", component: "PDFStatementExtractor")

            // Inserted line: cache document credit card status for kindName below
            // Updated per instruction 3: include documentLooksCreditCardLoose
            let docIsCC = documentLooksCreditCard(lines) || documentLooksCreditCardLoose(lines)

            // Debug helpers for logging
            func kindName(_ k: AccountKind) -> String {
                switch k {
                case .checking: return "checking"
                case .savings: return "savings"
                case .investment: return "brokerage"
                case .loan: return "loan"
                case .unknown:
                    return docIsCC ? "creditCard" : "unknown"
                }
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

            // Merge a second pass without section filter to fill any missing begin/end values
            do {
                let unfiltered = findBalancesPerAccount(in: lines, useSectionFilter: false)
                var merged: [AccountKind: (begin: String?, end: String?)] = [:]
                let keys = Set(balancesByAccount.keys).union(unfiltered.keys)
                for k in keys {
                    let a = balancesByAccount[k] ?? (begin: nil, end: nil)
                    let b = unfiltered[k] ?? (begin: nil, end: nil)
                    let beginOut = a.begin ?? b.begin
                    let endOut = a.end ?? b.end
                    merged[k] = (begin: beginOut, end: endOut)
                    if (a.begin == nil && b.begin != nil) || (a.end == nil && b.end != nil) {
                        AMLogging.log("PDF summary: merged unfiltered pass for \(kindName(k)) fill begin=\(a.begin == nil && b.begin != nil ? (b.begin ?? "nil") : "no") end=\(a.end == nil && b.end != nil ? (b.end ?? "nil") : "no")", component: "PDFStatementExtractor")
                    }
                }
                balancesByAccount = merged
                AMLogging.log("PDF summary: merged section-filtered + unfiltered = \(debugBalances(balancesByAccount))", component: "PDFStatementExtractor")
            }

            // If this looks like a credit card statement, prefer the unknown bucket (to be labeled as Credit Card)
            // and drop misclassified deposit/investment accounts that are likely noise.
            do {
                if documentLooksCreditCard(lines) {
                    if let unk = balancesByAccount[.unknown], (unk.begin != nil || unk.end != nil) {
                        let before = debugBalances(balancesByAccount)
                        balancesByAccount.removeValue(forKey: .savings)
                        balancesByAccount.removeValue(forKey: .checking)
                        balancesByAccount.removeValue(forKey: .investment)
                        AMLogging.log("PDF summary: credit card doc — pruned non-credit accounts; before=\(before) after=\(debugBalances(balancesByAccount))", component: "PDFStatementExtractor")
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
                    if statementPeriod == nil {
                        statementPeriod = detectStatementPeriod(in: ocrLines)
                    }
                    AMLogging.log("PDF summary: using OCR balances = \(debugBalances(ocrBalances))", component: "PDFStatementExtractor")
                }
            }

            // Fallback: if balances are under .unknown, try to assign based on document-wide hints or override
            if let unknownPair = balancesByAccount[.unknown], (unknownPair.begin != nil || unknownPair.end != nil) {
                if accountOverride == .loan {
                    balancesByAccount[.loan] = unknownPair
                    balancesByAccount.removeValue(forKey: .unknown)
                    AMLogging.log("PDF summary: mapped unknown balances to loan based on user override", component: "PDFStatementExtractor")
                } else {
                    let sourceLinesAll = balancesFromOCR ? ocrLinesLocal : lines
                    let docHasSavings = sourceLinesAll.contains { $0.lowercased().contains("savings") }
                    let docHasChecking = sourceLinesAll.contains { $0.lowercased().contains("checking") }
                    let docHasInvestment = sourceLinesAll.contains { let l = $0.lowercased(); return l.contains("brokerage") || l.contains("investment account") || l.contains("fidelity") || l.contains("ira") || l.contains("stock") || l.contains("securities") || l.contains("portfolio") }
                    if balancesByAccount[.investment] == nil && docHasInvestment {
                        balancesByAccount[.investment] = unknownPair
                        balancesByAccount.removeValue(forKey: .unknown)
                        AMLogging.log("PDF summary: mapped unknown balances to investment based on document hints", component: "PDFStatementExtractor")
                    } else if balancesByAccount[.savings] == nil && docHasSavings && !docHasChecking {
                        balancesByAccount[.savings] = unknownPair
                        balancesByAccount.removeValue(forKey: .unknown)
                        AMLogging.log("PDF summary: mapped unknown balances to savings based on document hints", component: "PDFStatementExtractor")
                    } else if balancesByAccount[.checking] == nil && docHasChecking && !docHasSavings {
                        balancesByAccount[.checking] = unknownPair
                        balancesByAccount.removeValue(forKey: .unknown)
                        AMLogging.log("PDF summary: mapped unknown balances to checking based on document hints", component: "PDFStatementExtractor")
                    }
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
            var suggestedPayment: String? = nil
            if docLooksLoan && !docIsCC {
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
                suggestedPayment = detectLoanPaymentAmount(in: lines)
                if suggestedPayment == nil && enableOCR {
                    let ocrLines = ocrExtractLines(from: doc, scale: 2.0)
                    suggestedPayment = detectLoanPaymentAmount(in: ocrLines)
                }
            }
            else if docLooksLoan && docIsCC {
                AMLogging.log("PDF summary: skipping loan payment synthesis because document detected as credit card", component: "PDFStatementExtractor")
            }

            // Choose a date for the suggested payment row (use statement end date if available)
            var paymentDateStr: String? = nil
            if let sp = statementPeriod, let (_, endDate) = summaryDates(from: sp) {
                let df = DateFormatter()
                df.locale = Locale(identifier: "en_US_POSIX")
                df.timeZone = TimeZone(secondsFromGMT: 0)
                df.dateFormat = "MM/dd/yyyy"
                paymentDateStr = df.string(from: endDate)
            } else if let latest = latestDate {
                let df = DateFormatter()
                df.locale = Locale(identifier: "en_US_POSIX")
                df.timeZone = TimeZone(secondsFromGMT: 0)
                df.dateFormat = "MM/dd/yyyy"
                paymentDateStr = df.string(from: latest)
            }

            if let pay = suggestedPayment, let pDate = paymentDateStr {
                // Duplication guard: avoid appending a second loan payment row if one already exists
                let hasExistingLoanPayment = rows.contains { r in
                    guard r.count >= 5 else { return false }
                    let descLower = r[1].replacingOccurrences(of: "\u{00A0}", with: " ")
                                        .replacingOccurrences(of: "\u{2007}", with: " ")
                                        .replacingOccurrences(of: "\u{202F}", with: " ")
                                        .lowercased()
                    let acctLower = r[4].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    return acctLower == "loan" && descLower.contains("payment")
                }
                if hasExistingLoanPayment {
                    AMLogging.log("PDF summary: skipping typical payment row (duplicate) amount=\(pay) date=\(pDate)", component: "PDFStatementExtractor")
                } else {
                    rows.append([pDate, "Estimated Monthly Payment (Loan)", pay, "", "loan"])
                    AMLogging.log("PDF summary: appended typical payment row amount=\(pay) date=\(pDate)", component: "PDFStatementExtractor")
                }
            }
            // End inserted code

            if !hasAnyBalances2 {
                let source = balancesFromOCR ? ocrLinesLocal : lines
                let loan = scanLoanBalances(in: source)
                if loan.begin != nil || loan.end != nil {
                    balancesByAccount[.unknown] = (begin: loan.begin, end: loan.end)
                    let beginStr = loan.begin ?? "nil"
                    let endStr = loan.end ?? "nil"
                    AMLogging.log("PDF summary: loan-specific scan found begin=\(beginStr), end=\(endStr)", component: "PDFStatementExtractor")
                }
            }

            // Generic end-date override: capture date next to ending balance labels with amount on same line
            var endDateOverrideByAccount: [AccountKind: String] = [:]
            do {
                let source = balancesFromOCR ? ocrLinesLocal : lines
                // Keywords that imply an ending/closing/new balance. Keep generic and reusable across statement types.
                let endLabelKeywords: [String] = [
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

                for (idx, raw) in source.enumerated() {
                    let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if line.isEmpty { continue }
                    let lower = line.lowercased()
                    guard endLabelKeywords.contains(where: { lower.contains($0) }) else { continue }

                    // Determine the end of the last matching label on this line (case-insensitive)
                    var labelEndUTF16: Int = 0
                    for lbl in endLabelKeywords where lower.contains(lbl) {
                        if let r = line.range(of: lbl, options: [.caseInsensitive]) {
                            let nsr = NSRange(r, in: line)
                            labelEndUTF16 = max(labelEndUTF16, nsr.location + nsr.length)
                        }
                    }

                    let full = NSRange(location: 0, length: (line as NSString).length)
                    let dateMatches = anyDateRegex.matches(in: line, options: [], range: full)
                    let amountMatches = amountAnywhereRegex.matches(in: line, options: [], range: full)
                    guard !dateMatches.isEmpty, !amountMatches.isEmpty else { continue }

                    // Prefer tokens that appear after the label; fallback to first/last on the line
                    let dateMatch: NSTextCheckingResult? = dateMatches.first(where: { $0.range.location >= labelEndUTF16 }) ?? dateMatches.first
                    let amountMatch: NSTextCheckingResult? = amountMatches.last(where: { $0.range.location >= labelEndUTF16 }) ?? amountMatches.last
                    guard let dm = dateMatch, let am = amountMatch,
                          let dRange = Range(dm.range, in: line),
                          let aRange = Range(am.range, in: line) else { continue }

                    let dateRaw = String(line[dRange])
                    let amtRaw  = String(line[aRange])
                    let normDate = normalizeDateString(dateRaw, inferredYear: inferredYear)
                    let normAmt  = sanitizeAmount(amtRaw)

                    // Infer which account this line belongs to and record an override for its end date
                    let acct = inferAccountContext(around: idx, in: source)
                    endDateOverrideByAccount[acct] = normDate

                    // Prefer the amount found on a labeled line with an explicit date (e.g., "... as of <date> <amount>")
                    var tuple = balancesByAccount[acct] ?? (begin: nil, end: nil)
                    let preferOverride = lower.contains("as of") || lower.contains("new balance") || lower.contains("statement balance")
                    if tuple.end == nil || preferOverride {
                        tuple.end = normAmt
                    }
                    balancesByAccount[acct] = tuple

                    AMLogging.log("PDF summary: end-date override detected acct=\(kindName(acct)) date=\(normDate) amount=\(normAmt)", component: "PDFStatementExtractor")
                }
            }

            var didAppendSummary = false
            // Compute shared dates once
            var beginDateStr: String? = nil
            var endDateStr: String? = nil
            if let sp = statementPeriod, let (beginDate, endDate) = summaryDates(from: sp) {
                let df = DateFormatter()
                df.locale = Locale(identifier: "en_US_POSIX")
                df.timeZone = TimeZone(secondsFromGMT: 0)
                df.dateFormat = "MM/dd/yyyy"
                beginDateStr = df.string(from: beginDate)
                endDateStr = df.string(from: endDate)
            } else if let e = earliestDate, let l = latestDate {
                var cal = Calendar(identifier: .gregorian)
                cal.timeZone = TimeZone(secondsFromGMT: 0)!
                let begin = cal.date(byAdding: .day, value: -1, to: e) ?? e
                let df = DateFormatter()
                df.locale = Locale(identifier: "en_US_POSIX")
                df.timeZone = TimeZone(secondsFromGMT: 0)
                df.dateFormat = "MM/dd/yyyy"
                beginDateStr = df.string(from: begin)
                endDateStr = df.string(from: l)
            }

            // Append summaries per-account when available
            for (acct, pair) in balancesByAccount {
                let sourceLines = balancesFromOCR ? ocrLinesLocal : lines
                let accountLabelDisplay = Self.accountDisplayLabel(for: acct, using: sourceLines)
                let accountKey = Self.accountTypeKey(for: acct)
                AMLogging.log("PDF summary: account label resolved for \(kindName(acct)) => \(accountLabelDisplay)", component: "PDFStatementExtractor")
                let lowerLabel = accountLabelDisplay.lowercased()
                let isLoanContext = lowerLabel.contains("loan") || lowerLabel.contains("mortgage")
                let isCreditCardContext = lowerLabel.contains("credit card") || lowerLabel.contains("visa") || lowerLabel.contains("mastercard") || lowerLabel.contains("amex") || lowerLabel.contains("american express") || lowerLabel.contains("discover")
                let accountKeyOut: String = {
                    if accountOverride == .loan { return "loan" }
                    if isLoanContext { return "loan" }
                    // Force credit card labeling for documents that look like credit card statements
                    if documentLooksCreditCard(sourceLines) || documentLooksCreditCardLoose(sourceLines) { return "creditCard" }
                    if isCreditCardContext { return "creditCard" }
                    return accountKey
                }()
                if let bAmt = pair.begin, let bDate = beginDateStr {
                    let beginBalanceForAccount = (isLoanContext || isCreditCardContext) ? forceNegative(bAmt) : bAmt
                    rows.append([bDate, "Statement Beginning Balance (\(accountLabelDisplay))", "0", beginBalanceForAccount, accountKeyOut])
                    AMLogging.log("PDF summary: appended beginning row accountKey=\(accountKeyOut)", component: "PDFStatementExtractor")
                    didAppendSummary = true
                    AMLogging.log("PDF summary (decoupled): beginning balance detected = \(bAmt) @ \(bDate) [\(accountLabelDisplay)]", component: "PDFStatementExtractor")
                }
                if let eAmt = pair.end, let eDate = (endDateOverrideByAccount[acct] ?? endDateStr) {
                    let endBalanceForAccount = (isLoanContext || isCreditCardContext) ? forceNegative(eAmt) : eAmt
                    var endingDesc = "Statement Ending Balance (\(accountLabelDisplay))"
                    if let aprVal = detectedAPR {
                        let nf = NumberFormatter()
                        nf.numberStyle = .percent
                        if let s = detectedAPRScale { nf.minimumFractionDigits = s; nf.maximumFractionDigits = s } else { nf.minimumFractionDigits = 2; nf.maximumFractionDigits = 3 }
                        let aprText = nf.string(from: NSDecimalNumber(decimal: aprVal)) ?? ""
                        if !aprText.isEmpty {
                            endingDesc += " — Interest Rate \(aprText)"
                        }
                    }
                    rows.append([eDate, endingDesc, "0", endBalanceForAccount, accountKeyOut])
                    AMLogging.log("PDF summary: appended ending row accountKey=\(accountKeyOut)", component: "PDFStatementExtractor")
                    didAppendSummary = true
                    AMLogging.log("PDF summary (decoupled): ending balance detected = \(eAmt) @ \(eDate) [\(accountLabelDisplay)]", component: "PDFStatementExtractor")
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
                            let descLower = rows[idx][1]
                                  .replacingOccurrences(of: "\u{00A0}", with: " ") // NBSP
                                  .replacingOccurrences(of: "\u{2007}", with: " ") // Figure space
                                  .replacingOccurrences(of: "\u{202F}", with: " ") // Narrow no-break space
                                  .lowercased()
                            if descLower.contains("credit card") || descLower.contains("statement balance") || descLower.contains("new balance") {
                                key = "creditCard"
                            }
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
                        let descLower = rows[idx][1]
                              .replacingOccurrences(of: "\u{00A0}", with: " ") // NBSP
                              .replacingOccurrences(of: "\u{2007}", with: " ") // Figure space
                              .replacingOccurrences(of: "\u{202F}", with: " ") // Narrow no-break space
                              .lowercased()
                        if descLower.contains("credit card") || descLower.contains("statement balance") || descLower.contains("new balance") {
                            key = "creditCard"
                        }
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
            let descLower = rows[idx][1]
                  .replacingOccurrences(of: "\u{00A0}", with: " ") // NBSP
                  .replacingOccurrences(of: "\u{2007}", with: " ") // Figure space
                  .replacingOccurrences(of: "\u{202F}", with: " ") // Narrow no-break space
                  .lowercased()
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

        // Enforce user-selected Loan override on output rows
        if let ov = accountOverride, ov == .loan {
            for idx in 0..<rows.count {
                if rows[idx].count >= 5 {
                    rows[idx][4] = "loan"
                }
            }
            AMLogging.log("PDF: enforced user-selected LOAN account override across rows", component: "PDFStatementExtractor")
        }

        // Debug: list unique account keys present in the extracted rows
        let uniqueAccounts = Set(rows.compactMap { $0.count >= 5 ? $0[4] : nil })
        AMLogging.log("PDF rows account keys: \(Array(uniqueAccounts))", component: "PDFStatementExtractor")

        AMLogging.log("PDF matched rows: \(rows.count)", component: "PDFStatementExtractor")

        guard !rows.isEmpty else {
            let message = userFacingFailureMessage(for: url, mode: mode)
            AMLogging.log("PDF parse failed — returning user-facing message: \(message)", component: "PDFStatementExtractor")
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
        case .loan: return "loan"
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
        case .loan:
            return "Loan"
        case .unknown:
            // If unknown, try to infer a friendlier label from the document-wide hints
            let lowercased = lines.map {
                $0
                    .replacingOccurrences(of: "\u{00A0}", with: " ") // NBSP
                    .replacingOccurrences(of: "\u{2007}", with: " ") // Figure space
                    .replacingOccurrences(of: "\u{202F}", with: " ") // Narrow no-break space
                    .lowercased()
            }

            // Credit card detection first
            let looksCreditCard = lowercased.contains(where: { line in
                line.contains("credit card") || line.contains("minimum payment") || line.contains("payment due") ||
                line.contains("credit limit") || line.contains("available credit") ||
                line.contains("visa") || line.contains("mastercard") || line.contains("american express") || line.contains("amex") || line.contains("discover") ||
                line.contains("purchases apr") || line.contains("cash advance apr") ||
                line.contains("new balance") || line.contains("previous balance") || line.contains("statement balance")
            })
            if looksCreditCard { return "Credit Card" }

            if lowercased.contains(where: { $0.contains("loan") || $0.contains("mortgage") }) { return "Loan" }
            if lowercased.contains(where: { $0.contains("checking") }) { return "Checking" }
            if lowercased.contains(where: { $0.contains("savings") }) { return "Savings" }
            if lowercased.contains(where: { $0.contains("brokerage") || $0.contains("investment") || $0.contains("fidelity") }) {
                return "Brokerage"
            }
            return "Account"
        }
    }

    // MARK: - Helper: Document-level credit card detectors
    private static func documentLooksCreditCard(_ lines: [String]) -> Bool {
        let lc = lines.map {
            $0
                .replacingOccurrences(of: "\u{00A0}", with: " ") // NBSP
                .replacingOccurrences(of: "\u{2007}", with: " ") // Figure space
                .replacingOccurrences(of: "\u{202F}", with: " ") // Narrow no-break space
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        }
        // Strong indicators typically present on credit card statements
        let strongKeywords = [
            "credit card", "minimum payment", "payment due", "payment due date",
            "previous balance", "new balance", "statement balance",
            "credit limit", "available credit",
            "interest charge", "finance charge",
            "purchases apr", "purchase apr", "cash advance apr", "penalty apr", "intro apr",
            "billing cycle", "closing date"
        ]
        if lc.contains(where: { line in strongKeywords.contains(where: { line.contains($0) }) }) {
            return true
        }
        // Network/brand names commonly present
        let brands = ["visa", "mastercard", "american express", "amex", "discover"]
        if lc.contains(where: { line in brands.contains(where: { line.contains($0) }) }) {
            return true
        }
        return false
    }

    // Narrow helper to catch statements that only say "New Balance as of ..."
    private static func documentLooksCreditCardLoose(_ lines: [String]) -> Bool {
        let lc = lines.map {
            $0
                .replacingOccurrences(of: "\u{00A0}", with: " ") // NBSP
                .replacingOccurrences(of: "\u{2007}", with: " ") // Figure space
                .replacingOccurrences(of: "\u{202F}", with: " ") // Narrow no-break space
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        }
        // Be conservative: require the stronger pattern "new balance as of" to avoid false positives
        return lc.contains { $0.contains("new balance as of") }
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

    static func extractAPRFromPDF(at url: URL) -> (apr: Decimal?, scale: Int?) {
        // Set to true to enable verbose APR/interest scanning logs
        let aprDebugLogging = Self.enableAPRDebugLogs
        guard let doc = PDFDocument(url: url) else {
            if aprDebugLogging { AMLogging.log("APR: Failed to open PDF at \(url.path)", component: "PDFStatementExtractor") }
            return (nil, nil)
        }

        // Collect all lines from all pages (preserving order)
        var lines: [String] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i), let pageText = page.string else { continue }
            let pageLines = pageText.components(separatedBy: .newlines)
            lines.append(contentsOf: pageLines.map { $0.trimmingCharacters(in: .whitespaces) })
        }

        // Normalize NBSP-like whitespace to plain spaces for robust regex matching
        lines = lines.map { $0.replacingOccurrences(of: "\u{00A0}", with: " ")
                                    .replacingOccurrences(of: "\u{2007}", with: " ")
                                    .replacingOccurrences(of: "\u{202F}", with: " ") }

        if aprDebugLogging {
            AMLogging.log("APR: Scanning \(lines.count) lines from PDF", component: "PDFStatementExtractor")

            // Helper: decide whether a line is a candidate for APR/interest based on keywords
            func isAPRInterestCandidate(_ lower: String) -> Bool {
                // Strong acceptance: explicit APR mention
                if lower.contains("apr") { return true }

                // Accept lines that clearly talk about a rate
                let hasExplicitRate = lower.contains("interest rate")
                    || lower.contains("note rate")
                    || lower.contains("annual rate")
                    || lower.contains("current rate")
                    || lower.contains("percentage rate")
                    || (lower.contains(" rate ") && (lower.contains("annual") || lower.contains("note") || lower.contains("current") || lower.contains("percentage")))
                if hasExplicitRate { return true }

                // Exclude charge/amount summaries (these often include monetary values and aren't rates)
                if lower.contains("interest charged") || lower.contains("interest charge") || lower.contains("total interest") || lower.contains("interest paid") {
                    return false
                }

                // Generic 'interest' alone is too broad and leads to false positives
                return false
            }

            // Helper: detect percent-like lines (exclude currency) for debugging
            func isPercentLikeLine(_ s: String) -> Bool {
                if s.contains("$") { return false }
                let r = NSRange(location: 0, length: s.utf16.count)
                return percentTokenRegex.firstMatch(in: s, options: [], range: r) != nil
            }

            // Regex patterns capturing percent values on the same line as APR/interest hints.
            // Examples:
            //  - "APR: 19.99%"
            //  - "Annual Percentage Rate 19.99 %"
            //  - "Interest Rate (purchases) 29.24%"
            let sameLinePatterns: [NSRegularExpression] = [
                // APR variants
                try! NSRegularExpression(pattern: #"(?i)\bAPR\b[^0-9%]*([0-9]+(?:\.[0-9]+)?)\s*%"#),
                try! NSRegularExpression(pattern: #"(?i)\bAnnual\s+Percentage\s+Rate\b[^0-9%]*([0-9]+(?:\.[0-9]+)?)\s*%"#),
                try! NSRegularExpression(pattern: #"(?i)\bPurchases?\s+APR\b[^0-9%]*([0-9]+(?:\.[0-9]+)?)\s*%"#),
                try! NSRegularExpression(pattern: #"(?i)\bStandard\s+APR\b[^0-9%]*([0-9]+(?:\.[0-9]+)?)\s*%"#),
                try! NSRegularExpression(pattern: #"(?i)\bVariable\s+APR\b[^0-9%]*([0-9]+(?:\.[0-9]+)?)\s*%"#),

                // Interest rate variants (loan statements often use these)
                try! NSRegularExpression(pattern: #"(?i)\bInterest\s+Rate\b[^0-9%]*([0-9]+(?:\.[0-9]+)?)\s*%"#),
                try! NSRegularExpression(pattern: #"(?i)\bCurrent\s+Interest\s+Rate\b[^0-9%]*([0-9]+(?:\.[0-9]+)?)\s*%"#),
                try! NSRegularExpression(pattern: #"(?i)\bInterest\s+Rate\s+as\s+of\b[^0-9%]*([0-9]+(?:\.[0-9]+)?)\s*%"#),
                try! NSRegularExpression(pattern: #"(?i)\bNote\s+Rate\b[^0-9%]*([0-9]+(?:\.[0-9]+)?)\s*%"#),
                try! NSRegularExpression(pattern: #"(?i)\bNote\s+Interest\s+Rate\b[^0-9%]*([0-9]+(?:\.[0-9]+)?)\s*%"#),
                try! NSRegularExpression(pattern: #"(?i)\bAnnual\s+Interest\s+Rate\b[^0-9%]*([0-9]+(?:\.[0-9]+)?)\s*%"#),
                // Generic "Interest:" with percent on same line
                try! NSRegularExpression(pattern: #"(?i)\bInterest\b[^0-9%]*([0-9]+(?:\.[0-9]+)?)\s*%"#)
            ]

            // Generic percent token used for fallback matching on the same line or the next line
            let percentTokenRegex = try! NSRegularExpression(pattern: #"([0-9]+(?:\.[0-9]+)?)\s*%"#, options: [.caseInsensitive])

            // Looser number token (no commas/$, optional %, bounded to avoid dates); used only when line mentions apr/interest
            let looseNumberTokenRegex = try! NSRegularExpression(pattern: #"(?<![\d\$])([0-9]{1,2}(?:\.[0-9]{1,4})?)%?(?![\d])"#, options: [.caseInsensitive])

            func parsePercentString(_ s: String) -> (Decimal, Int)? {
                let trimmed = s.trimmingCharacters(in: .whitespaces)
                guard let dec = Decimal(string: trimmed) else { return nil }
                let parts = trimmed.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
                let scale = parts.count == 2 ? parts[1].count : 0
                let fraction = dec / 100 // Convert percent to fraction
                return (fraction, scale)
            }

            func firstMatch(in text: String, using regex: NSRegularExpression) -> String? {
                let range = NSRange(text.startIndex..<text.endIndex, in: text)
                guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
                guard match.numberOfRanges >= 2 else { return nil }
                let r = match.range(at: 1)
                guard let swiftRange = Range(r, in: text) else { return nil }
                return String(text[swiftRange])
            }

            // Pass 1: look for explicit same-line matches with APR/interest hints
            for (idx, rawLine) in lines.enumerated() {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                let lower = line.lowercased()

                // Gated logging for candidates containing apr/interest words
                if aprDebugLogging, isAPRInterestCandidate(lower) {
                    AMLogging.log("APR candidate [\(idx)]: \(line)", component: "PDFStatementExtractor")
                }

                for regex in sameLinePatterns {
                    if let num = firstMatch(in: line, using: regex),
                       let (fraction, scale) = parsePercentString(num) {
                        if aprDebugLogging {
                            AMLogging.log("APR match (same-line) at [\(idx)]: \(num) -> \(fraction) scale=\(scale)", component: "PDFStatementExtractor")
                        }
                        return (fraction, scale)
                    }
                }
            }

            // Pass 2: fallback — for lines that mention apr/interest but didn't match above,
            // try a generic percent on the same line, then on the next line.
            for (idx, rawLine) in lines.enumerated() {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                let lower = line.lowercased()
                guard isAPRInterestCandidate(lower) else { continue }

                if aprDebugLogging {
                    AMLogging.log("APR fallback candidate [\(idx)]: \(line)", component: "PDFStatementExtractor")
                }

                // Same-line generic percent
                if let num = firstMatch(in: line, using: percentTokenRegex),
                   let (fraction, scale) = parsePercentString(num) {
                    if aprDebugLogging {
                        AMLogging.log("APR match (fallback same-line) at [\(idx)]: \(num) -> \(fraction) scale=\(scale)", component: "PDFStatementExtractor")
                    }
                    return (fraction, scale)
                }

                // Same-line loose number (treat as percent if reasonable) — only if strong rate keywords are present
                let hasStrongRateKeyword = lower.contains("apr") || lower.contains("interest rate") || lower.contains(" note rate") || lower.contains(" annual rate") || lower.contains(" percentage rate") || lower.contains(" rate ")
                if hasStrongRateKeyword,
                   let num = firstMatch(in: line, using: looseNumberTokenRegex),
                   let (fraction, scale) = parsePercentString(num),
                   (fraction >= 0 && fraction <= 1.0) {
                    if aprDebugLogging {
                        AMLogging.log("APR match (fallback same-line loose) at [\(idx)]: \(num) -> \(fraction) scale=\(scale)", component: "PDFStatementExtractor")
                    }
                    return (fraction, scale)
                }

                // Next-line generic percent
                if idx + 1 < lines.count {
                    let next = lines[idx + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                    if aprDebugLogging {
                        AMLogging.log("APR checking next line [\(idx + 1)]: \(next)", component: "PDFStatementExtractor")
                    }
                    if let num = firstMatch(in: next, using: percentTokenRegex),
                       let (fraction, scale) = parsePercentString(num) {
                        if aprDebugLogging {
                            AMLogging.log("APR match (fallback next-line) at [\(idx + 1)]: \(num) -> \(fraction) scale=\(scale)", component: "PDFStatementExtractor")
                        }
                        return (fraction, scale)
                    }
                    // Next-line loose number (treat as percent if reasonable) — only if strong rate keywords are present on the current line
                    if hasStrongRateKeyword,
                       let num = firstMatch(in: next, using: looseNumberTokenRegex),
                       let (fraction, scale) = parsePercentString(num),
                       (fraction >= 0 && fraction <= 1.0) {
                        if aprDebugLogging {
                            AMLogging.log("APR match (fallback next-line loose) at [\(idx + 1)]: \(num) -> \(fraction) scale=\(scale)", component: "PDFStatementExtractor")
                        }
                        return (fraction, scale)
                    }
                }
            }

            // Pass 3: Anchor near the APR header/table and scan the following lines for a percent token
            let aprAnchors: [Int] = lines.enumerated().compactMap { (idx, raw) in
                let l = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return (l.contains("interest charge calculation") || l.contains("annual percentage rate")) ? idx : nil
            }
            for anchor in aprAnchors {
                let window = 15
                var j = anchor
                while j <= min(lines.count - 1, anchor + window) {
                    let candidate = lines[j].trimmingCharacters(in: .whitespacesAndNewlines)
                    // Skip obvious money lines to avoid amounts like 226.92 being treated as 92%
                    if candidate.contains("$") { j += 1; continue }
                    if let num = firstMatch(in: candidate, using: percentTokenRegex),
                       let (fraction, scale) = parsePercentString(num) {
                        if aprDebugLogging {
                            AMLogging.log("APR match (anchor scan) at [\(j)] after header [\(anchor)]: \(num) -> \(fraction) scale=\(scale)", component: "PDFStatementExtractor")
                        }
                        return (fraction, scale)
                    }
                    j += 1
                }
            }

            // Additional debug: summarize candidate and percent-like lines to aid tuning
            let cand = lines.enumerated().filter { isAPRInterestCandidate($0.element.lowercased()) }
            AMLogging.log("APR: candidate lines (apr/interest/rate combos) count=\(cand.count)", component: "PDFStatementExtractor")
            for (idx, l) in cand.prefix(10) {
                AMLogging.log("APR candidate sample [\(idx)]: \(l)", component: "PDFStatementExtractor")
            }
            let pctLike = lines.enumerated().filter { isPercentLikeLine($0.element) }
            AMLogging.log("APR: percent-like lines (no $) count=\(pctLike.count)", component: "PDFStatementExtractor")
            for (idx, l) in pctLike.prefix(10) {
                AMLogging.log("APR % sample [\(idx)]: \(l)", component: "PDFStatementExtractor")
            }
        }

        if aprDebugLogging {
            AMLogging.log("APR: No APR/interest percentage found", component: "PDFStatementExtractor")
        }
        return (nil, nil)
    }
}

