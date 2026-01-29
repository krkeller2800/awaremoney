import Foundation

enum CSVImportError: Error {
    case unreadable
    case empty
    case missingHeader
    case missingRequiredMapping(String)
}

struct CSVMapping {
    // Column header names to map to canonical schema
    var dateColumn: String
    var descriptionColumn: String
    var amountColumn: String
    var balanceColumn: String? // optional
    var accountColumn: String? // optional

    // Optional preferred date format (e.g., "MM/dd/yyyy"). If nil, we'll try common formats.
    var dateFormat: String?
}

enum CSVStatementExtractor {
    // Public entry point. If mapping is nil, we try to auto-map based on fuzzy header names.
    static func parse(url: URL, mapping: CSVMapping? = nil) throws -> (rows: [[String]], headers: [String]) {
        guard let data = try? Data(contentsOf: url), let raw = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
            throw CSVImportError.unreadable
        }

        // Split into lines and drop blank ones
        var lines = raw.components(separatedBy: CharacterSet.newlines).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !lines.isEmpty else { throw CSVImportError.empty }

        // Sniff delimiter from first few lines
        let delimiter = sniffDelimiter(from: Array(lines.prefix(5)))

        // Parse header
        let headerFields = parseCSVLine(lines.removeFirst(), delimiter: delimiter)
        guard !headerFields.isEmpty else { throw CSVImportError.missingHeader }

        // Build column index map
        let columnIndex: (date: Int, description: Int, amount: Int, balance: Int?, account: Int?)
        let preferredDateFormat = mapping?.dateFormat
        if let mapping {
            columnIndex = try resolveColumnIndices(from: headerFields, mapping: mapping)
        } else {
            guard let auto = autoMapColumns(headerFields) else {
                throw CSVImportError.missingRequiredMapping("Unable to infer column mapping from headers: \(headerFields)")
            }
            columnIndex = auto
        }

        // Canonical headers
        let headers = ["date", "description", "amount", "balance", "account"]

        var out: [[String]] = []
        out.reserveCapacity(lines.count)

        for line in lines {
            let fields = parseCSVLine(line, delimiter: delimiter)
            if fields.isEmpty { continue }

            func value(at idx: Int?) -> String {
                guard let idx, idx >= 0, idx < fields.count else { return "" }
                return fields[idx]
            }

            let dateRaw = value(at: columnIndex.date)
            let descRaw = value(at: columnIndex.description)
            let amountRaw = value(at: columnIndex.amount)
            let balanceRaw = value(at: columnIndex.balance)
            let accountRaw = value(at: columnIndex.account)

            let normalizedDate = normalizeDateString(dateRaw, preferredFormat: preferredDateFormat)
            let normalizedDesc = cleanDesc(descRaw)
            let normalizedAmount = sanitizeAmount(amountRaw)
            let normalizedBalance = balanceRaw.isEmpty ? "" : sanitizeAmount(balanceRaw)
            let account = accountRaw.isEmpty ? "unknown" : accountRaw.trimmingCharacters(in: .whitespacesAndNewlines)

            out.append([normalizedDate, normalizedDesc, normalizedAmount, normalizedBalance, account])
        }

        return (out, headers)
    }

    // MARK: - Delimiter & CSV parsing

    private static func sniffDelimiter(from sampleLines: [String]) -> Character {
        // Count occurrences of common delimiters and pick the most frequent
        let candidates: [Character] = [",", ";", "\t"]
        var scores: [Character: Int] = [:]
        for line in sampleLines {
            for c in candidates {
                let count = line.reduce(0) { $1 == c ? $0 + 1 : $0 }
                scores[c, default: 0] += count
            }
        }
        // Default to comma if tie or nothing
        let best = scores.max { a, b in a.value < b.value }?.key ?? ","
        return best
    }

    private static func parseCSVLine(_ line: String, delimiter: Character) -> [String] {
        // Minimal CSV parser: handles quoted fields and escaped quotes (")
        var result: [String] = []
        var current = ""
        var inQuotes = false
        var iterator = line.makeIterator()
        while let ch = iterator.next() {
            if ch == "\"" { // quote
                if inQuotes {
                    // Lookahead for escaped quote
                    if let next = peek(iterator: &iterator), next == "\"" {
                        current.append("\"")
                        _ = iterator.next() // consume escaped quote
                    } else {
                        inQuotes = false
                    }
                } else {
                    inQuotes = true
                }
            } else if ch == delimiter && !inQuotes {
                result.append(current)
                current.removeAll(keepingCapacity: false)
            } else {
                current.append(ch)
            }
        }
        result.append(current)
        return result.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func peek(iterator: inout String.Iterator) -> Character? {
        var copy = iterator
        return copy.next()
    }

    // MARK: - Column mapping

    private static func resolveColumnIndices(from headers: [String], mapping: CSVMapping) throws -> (date: Int, description: Int, amount: Int, balance: Int?, account: Int?) {
        func find(_ name: String) -> Int? {
            let target = name.lowercased()
            return headers.firstIndex { $0.lowercased() == target }
        }
        guard let d = find(mapping.dateColumn) else { throw CSVImportError.missingRequiredMapping("date column \"\(mapping.dateColumn)\"") }
        guard let desc = find(mapping.descriptionColumn) else { throw CSVImportError.missingRequiredMapping("description column \"\(mapping.descriptionColumn)\"") }
        guard let amt = find(mapping.amountColumn) else { throw CSVImportError.missingRequiredMapping("amount column \"\(mapping.amountColumn)\"") }
        let bal = mapping.balanceColumn.flatMap { find($0) }
        let acct = mapping.accountColumn.flatMap { find($0) }
        return (d, desc, amt, bal, acct)
    }

    private static func autoMapColumns(_ headers: [String]) -> (date: Int, description: Int, amount: Int, balance: Int?, account: Int?)? {
        let lower = headers.map { $0.lowercased() }
        func index(where predicate: (String) -> Bool) -> Int? {
            return lower.firstIndex(where: predicate)
        }

        let dateIdx = index { h in h.contains("date") || h.contains("post") || h.contains("posted") || h.contains("posting") }
        let descIdx = index { h in h.contains("description") || h.contains("memo") || h.contains("payee") || h.contains("details") || h.contains("transaction") }
        let amountIdx = index { h in h == "amount" || h.contains("amount") || h.contains("amt") }
        let balanceIdx = index { h in h.contains("balance") || h.contains("running") }
        let accountIdx = index { h in h.contains("account") || h.contains("acct") }

        guard let d = dateIdx, let desc = descIdx, let amt = amountIdx else {
            return nil
        }
        return (d, desc, amt, balanceIdx, accountIdx)
    }

    // MARK: - Normalization helpers (duplicated here to avoid cross-file private access)

    private static func normalizeDateString(_ s: String, preferredFormat: String?) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return trimmed }

        let fmts: [String]
        if let preferredFormat, !preferredFormat.isEmpty {
            fmts = [preferredFormat]
        } else {
            fmts = [
                "MM/dd/yyyy", "M/d/yyyy", "MM/dd/yy", "M/d/yy",
                "yyyy-MM-dd", "yyyy/M/d", "yyyy/MM/dd",
                "dd-MMM-yyyy", "d-MMM-yy", "dd MMM yyyy", "d MMM yy",
                "MMM d, yyyy", "MMMM d, yyyy", "MMM d, yy", "MMMM d, yy",
                "MMM d yyyy", "MMMM d yyyy"
            ]
        }
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

    private static func cleanDesc(_ s: String) -> String {
        let parts = s.split(whereSeparator: { $0.isNewline || $0.isWhitespace })
        var t = parts.joined(separator: " ")
        if t.count > 120 { t = String(t.prefix(120)) }
        return t
    }

    private static func sanitizeAmount(_ s: String) -> String {
        var raw = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return raw }

        let upper = raw.uppercased()
        var negativeHint = false
        var positiveHint = false

        if raw.hasPrefix("(") && raw.hasSuffix(")") {
            negativeHint = true
            raw.removeFirst()
            raw.removeLast()
        }
        if raw.hasSuffix("-") { negativeHint = true; raw.removeLast() }
        if raw.hasPrefix("-") { negativeHint = true; raw.removeFirst() }
        if raw.hasPrefix("- ") { negativeHint = true; raw.removeFirst() }

        if upper.contains("DR") || upper.contains("DEBIT") { negativeHint = true }
        if upper.contains("CR") || upper.contains("CREDIT") { positiveHint = true }

        var cleaned = raw
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: " ", with: "")

        let markers = ["CR", "DR", "CREDIT", "DEBIT"]
        for m in markers {
            cleaned = cleaned.replacingOccurrences(of: m, with: "", options: [.caseInsensitive])
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        if negativeHint && !positiveHint && !cleaned.hasPrefix("-") {
            cleaned = "-" + cleaned
        }
        return cleaned
    }
}
