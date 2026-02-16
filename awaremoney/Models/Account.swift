//
//  Account.swift
//  awaremoney
//
//  Created by Karl Keller on 1/23/26.
//

import Foundation
import SwiftData

struct LoanTerms: Codable, Hashable {
    var apr: Decimal? // Fraction (e.g., 0.1999 for 19.99%)
    var aprScale: Int? // Number of fraction digits detected in source
    var paymentAmount: Decimal? // Typical periodic payment
    var paymentDayOfMonth: Int? // 1...28/31
    var frequencyRaw: String = PaymentFrequency.monthly.rawValue

    var frequency: PaymentFrequency {
        get { PaymentFrequency(rawValue: frequencyRaw) ?? PaymentFrequency.monthly }
        set { frequencyRaw = newValue.rawValue }
    }
}

enum PaymentFrequency: String, Codable, CaseIterable {
    case monthly
    case biweekly
    case weekly
    case semimonthly
    case socialSecurity
    case yearly
    // Additional cases to support existing usages in other files
    case oneTime
    case biWeekly
    case twiceMonthly
    case quarterly
    case semiAnnual
    case annual
}

enum CreditCardPaymentMode: String, Codable, CaseIterable {
    case payInFull
    case fixedAmount
    case minimum
}

@Model
final class Account {
    enum AccountType: String, Codable, CaseIterable {
        case checking, savings, creditCard, loan, cash, brokerage, other
    }

    @Attribute(.unique) var id: UUID
    var name: String
    var typeRaw: String
    var institutionName: String?
    var currencyCode: String // e.g., "USD"
    var last4: String?
    var createdAt: Date

    var loanTermsJSON: Data?
    var creditCardPaymentModeRaw: String?

    // Relationships
    @Relationship(deleteRule: .cascade) var transactions: [Transaction] = []
    @Relationship(deleteRule: .cascade) var balanceSnapshots: [BalanceSnapshot] = []
    @Relationship(deleteRule: .cascade) var holdingSnapshots: [HoldingSnapshot] = []

    init(
        id: UUID = UUID(),
        name: String,
        type: AccountType,
        institutionName: String? = nil,
        currencyCode: String = "USD",
        last4: String? = nil,
        createdAt: Date = Date.now
    ) {
        self.id = id
        self.name = name
        self.typeRaw = type.rawValue
        self.institutionName = institutionName
        self.currencyCode = currencyCode
        self.last4 = last4
        self.createdAt = createdAt
    }
}

@MainActor
extension Account {
    var isLiability: Bool { type == AccountType.loan || type == AccountType.creditCard }
    var type: AccountType {
        get { AccountType(rawValue: typeRaw) ?? AccountType.other }
        set { typeRaw = newValue.rawValue }
    }
    var creditCardPaymentMode: CreditCardPaymentMode? {
        get {
            guard let raw = creditCardPaymentModeRaw else { return nil }
            return CreditCardPaymentMode(rawValue: raw)
        }
        set {
            creditCardPaymentModeRaw = newValue?.rawValue
        }
    }
    var loanTerms: LoanTerms? {
        get {
            guard let data = loanTermsJSON else { return nil }
            return try? JSONDecoder().decode(LoanTerms.self, from: data)
        }
        set {
            if let value = newValue {
                loanTermsJSON = try? JSONEncoder().encode(value)
            } else {
                loanTermsJSON = nil
            }
        }
    }
}

