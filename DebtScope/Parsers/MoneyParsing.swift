import Foundation

internal enum MoneyParsing {
    static func parseDecimalInput(_ raw: String, locale: Locale = .current, currencyCode: String? = AppFormatters.currencyCodeFromSettings()) -> Decimal? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 1) Try plain decimal
        do {
            let nf = NumberFormatter()
            nf.locale = locale
            nf.numberStyle = .decimal
            if let n = nf.number(from: trimmed) { return n.decimalValue }
        }

        // 2) Try currency with provided currency code
        do {
            let nf = NumberFormatter()
            nf.locale = locale
            nf.numberStyle = .currency
            if let code = currencyCode, !code.isEmpty { nf.currencyCode = code }
            if let n = nf.number(from: trimmed) { return n.decimalValue }
        }

        // 3) Try system currency
        do {
            let nf = NumberFormatter()
            nf.locale = locale
            nf.numberStyle = .currency
            if let n = nf.number(from: trimmed) { return n.decimalValue }
        }

        // 4) Fallback strip and parse
        let decimalSep = locale.decimalSeparator ?? "."
        let groupingSep = locale.groupingSeparator ?? ","

        var s = trimmed
        var isNegative = false
        if s.first == "(", s.last == ")" {
            isNegative = true
            s.removeFirst()
            s.removeLast()
        }

        let allowed = CharacterSet(charactersIn: "-0123456789" + decimalSep)
        let filteredScalars = s.unicodeScalars.filter { allowed.contains($0) }
        var filtered = String(String.UnicodeScalarView(filteredScalars))
        filtered = filtered.replacingOccurrences(of: groupingSep, with: "")

        if var d = Double(filtered) {
            if isNegative { d = -d }
            return Decimal(d)
        }
        return nil
    }

    static func parsePercentInput(_ raw: String, locale: Locale = .current) -> Decimal? {
        guard let pct = parseDecimalInput(raw, locale: locale) else { return nil }
        return pct / 100
    }

    static func normalizedAPR(from storedAPR: Decimal?) -> Decimal? {
        guard let apr = storedAPR else { return nil }
        return apr >= 1 ? (apr / 100) : apr
    }
}
