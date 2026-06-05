//
//  Account.swift
//  DebtScope
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

extension PaymentFrequency {
    /// Number of months in one full billing cycle for reserve planning.
    var monthsPerCycle: Int {
        switch self {
        case .monthly:
            return 1
        case .quarterly:
            return 3
        case .semiAnnual:
            return 6
        case .yearly, .annual:
            return 12
        default:
            // Treat all other non-monthly granular frequencies as monthly for reserve purposes
            return 1
        }
    }

    /// Whether this frequency should use reserve planning (i.e., non-monthly cycles)
    var isReserveEligible: Bool { monthsPerCycle > 1 }
}

enum CreditCardPaymentMode: String, Codable, CaseIterable {
    case payInFull
    case fixedAmount
    case minimum
}

@Model
final class Account {
    enum AccountType: String, Codable, CaseIterable {
        case checking, savings, creditCard, loan, cash, brokerage, property, other
    }

    enum AssetCategory: String, Codable, CaseIterable {
        case property
        case vehicle
        case business
        case collectible
        case crypto
        case retirement
        case hsa
        case other
    }

    @Attribute(.unique) var id: UUID = UUID()
    var name: String
    var typeRaw: String
    var assetCategoryRaw: String?
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
        assetCategory: AssetCategory? = nil,
        institutionName: String? = nil,
        currencyCode: String = "USD",
        last4: String? = nil,
        createdAt: Date = Date.now
    ) {
        self.id = id
        self.name = name
        self.typeRaw = type.rawValue
        self.assetCategoryRaw = assetCategory?.rawValue
        self.institutionName = institutionName
        self.currencyCode = currencyCode
        self.last4 = last4
        self.createdAt = createdAt
    }
}

@MainActor
extension Account {
    var isLiability: Bool { type == AccountType.loan || type == AccountType.creditCard }
    var isManualAsset: Bool {
        type == .property || (type == .other && assetCategoryRaw != nil)
    }
    var supportsLinkedLiability: Bool { isManualAsset }
    var showsLoanToValue: Bool {
        assetCategory == .property || assetCategory == .vehicle
    }
    var type: AccountType {
        get { AccountType(rawValue: typeRaw) ?? AccountType.other }
        set { typeRaw = newValue.rawValue }
    }
    var assetCategory: AssetCategory {
        get {
            if let raw = assetCategoryRaw, let category = AssetCategory(rawValue: raw) {
                return category
            }
            return type == .property ? .property : .other
        }
        set {
            assetCategoryRaw = newValue.rawValue
            type = newValue == .property ? .property : .other
        }
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

extension Account.AssetCategory {
    var displayName: String {
        switch self {
        case .property: return "Property"
        case .vehicle: return "Vehicle"
        case .business: return "Business"
        case .collectible: return "Collectible"
        case .crypto: return "Crypto"
        case .retirement: return "Retirement"
        case .hsa: return "HSA"
        case .other: return "Other"
        }
    }
}

