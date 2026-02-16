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
    var createdAt: Date

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
        account: Account? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.name = name
        self.amount = amount
        self.frequencyRaw = frequency.rawValue
        self.dayOfMonth = dayOfMonth
        self.firstPaymentDate = firstPaymentDate
        self.notes = notes
        self.account = account
        self.createdAt = createdAt
    }

    // Convenience property for legacy code paths
    var isIncome: Bool { kind == .income }
}

