//
//  HoldingSnapshot.swift
//  awaremoney
//
//  Created by Karl Keller on 1/23/26.
//

import Foundation
import SwiftData

@Model
final class HoldingSnapshot {
    @Attribute(.unique) var id: UUID
    var asOfDate: Date
    var quantity: Decimal
    var marketValue: Decimal?

    // Relationships
    var account: Account?
    var security: Security?
    var importBatch: ImportBatch?

    init(
        id: UUID = UUID(),
        asOfDate: Date,
        quantity: Decimal,
        marketValue: Decimal? = nil,
        account: Account? = nil,
        security: Security? = nil,
        importBatch: ImportBatch? = nil
    ) {
        self.id = id
        self.asOfDate = asOfDate
        self.quantity = quantity
        self.marketValue = marketValue
        self.account = account
        self.security = security
        self.importBatch = importBatch
    }
}
