import Foundation
import SwiftUI

internal enum AppFormatters {
    static func currencyCodeFromSettings() -> String? {
        return UserDefaults.standard.string(forKey: "PreferredCurrencyCode")
    }

    static func currencyFormatter(locale: Locale = .current, currencyCode: String? = currencyCodeFromSettings()) -> NumberFormatter {
        let nf = NumberFormatter()
        nf.locale = locale
        nf.numberStyle = .currency
        if let code = currencyCode, !code.isEmpty { nf.currencyCode = code }
        return nf
    }

    static func formatCurrency(_ amount: Decimal, locale: Locale = .current, currencyCode: String? = currencyCodeFromSettings()) -> String {
        let nf = currencyFormatter(locale: locale, currencyCode: currencyCode)
        return nf.string(from: NSDecimalNumber(decimal: amount)) ?? "\(amount)"
    }

    static func formatCurrencyInput(_ text: inout String, locale: Locale = .current, currencyCode: String? = currencyCodeFromSettings()) {
        guard let dec = MoneyParsing.parseDecimalInput(text, locale: locale, currencyCode: currencyCode) else { return }
        let nf = currencyFormatter(locale: locale, currencyCode: currencyCode)
        text = nf.string(from: NSDecimalNumber(decimal: dec)) ?? text
    }

    static func formatPercentInput(_ text: inout String, locale: Locale = .current) {
        guard let dec = MoneyParsing.parseDecimalInput(text, locale: locale) else { return }
        let nf = NumberFormatter()
        nf.locale = locale
        nf.numberStyle = .decimal
        nf.minimumFractionDigits = 2
        nf.maximumFractionDigits = 2
        text = nf.string(from: NSDecimalNumber(decimal: dec)) ?? text
    }
}
