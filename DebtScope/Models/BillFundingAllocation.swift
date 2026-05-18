import Foundation
import SwiftData

@Model
final class BillFundingAllocation {
    @Attribute(.unique) var id: UUID
    var billID: UUID
    var incomeID: UUID
    var amount: Decimal
    var createdAt: Date

    init(
        id: UUID = UUID(),
        billID: UUID,
        incomeID: UUID,
        amount: Decimal,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.billID = billID
        self.incomeID = incomeID
        self.amount = amount
        self.createdAt = createdAt
    }
}
