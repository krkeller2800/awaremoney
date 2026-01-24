//
//  BalanceSnapshot.swift
//  awaremoney
//
//  Created by Karl Keller on 1/23/26.
//

import Foundation
import SwiftData

@Model
final class BalanceSnapshot {
    @Attribute(.unique) var id: UUID
    var asOfDate: Date
    var balance: Decimal

    // Relationships
    var account: Account?
    var importBatch: ImportBatch?

    init(
        id: UUID = UUID(),
        asOfDate: Date,
        balance: Decimal,
        account: Account? = nil,
        importBatch: ImportBatch? = nil
    ) {
        self.id = id
        self.asOfDate = asOfDate
        self.balance = balance
        self.account = account
        self.importBatch = importBatch
    }
}

