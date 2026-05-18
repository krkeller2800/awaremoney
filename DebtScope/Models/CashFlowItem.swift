import Foundation
import SwiftData

@Model
final class CashFlowItem {
    enum Kind: String, Codable, CaseIterable {
        case income
        case bill
    }

    @Attribute(.unique) var id: UUID
    var kindRaw: String
    var name: String
    var amount: Decimal
    var frequencyRaw: String
    var dayOfMonth: Int?
    var firstPaymentDate: Date?
    var notes: String?
    var ssaWednesday: Int?
    var oneTimeSpreadMonthsOverride: Int? = nil
    var createdAt: Date

    // Reserve tracking (non-monthly bills)
    var reserveBalance: Decimal = 0
    var reserveCycleStart: Date? = nil
    var reserveLastSeededCycleStart: Date? = nil
    var reserveAutoEnabled: Bool = false

    // Optional direct funding from a non-monthly income source.
    var fundingIncomeID: UUID? = nil
    var fundingAmount: Decimal = 0

    // Optional: link to an account (e.g., paid from or associated account)
    var account: Account?

    // Bridging computed properties
    var kind: Kind {
        get { Kind(rawValue: kindRaw) ?? .bill }
        set { kindRaw = newValue.rawValue }
    }

    var frequency: PaymentFrequency {
        get { PaymentFrequency(rawValue: frequencyRaw) ?? .monthly }
        set { frequencyRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        kind: Kind,
        name: String,
        amount: Decimal,
        frequency: PaymentFrequency,
        dayOfMonth: Int? = nil,
        firstPaymentDate: Date? = nil,
        notes: String? = nil,
        ssaWednesday: Int? = nil,
        oneTimeSpreadMonthsOverride: Int? = nil,
        account: Account? = nil,
        createdAt: Date = Date(),
        reserveBalance: Decimal = 0,
        reserveCycleStart: Date? = nil,
        reserveLastSeededCycleStart: Date? = nil,
        reserveAutoEnabled: Bool = false,
        fundingIncomeID: UUID? = nil,
        fundingAmount: Decimal = 0
    ) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.name = name
        self.amount = amount
        self.frequencyRaw = frequency.rawValue
        self.dayOfMonth = dayOfMonth
        self.firstPaymentDate = firstPaymentDate
        self.notes = notes
        self.ssaWednesday = ssaWednesday
        self.oneTimeSpreadMonthsOverride = oneTimeSpreadMonthsOverride
        self.account = account
        self.createdAt = createdAt
        self.reserveBalance = reserveBalance
        self.reserveCycleStart = reserveCycleStart
        self.reserveLastSeededCycleStart = reserveLastSeededCycleStart
        self.reserveAutoEnabled = reserveAutoEnabled
        self.fundingIncomeID = fundingIncomeID
        self.fundingAmount = fundingAmount
    }

    // Convenience property for legacy code paths
    var isIncome: Bool { kind == .income }
}


