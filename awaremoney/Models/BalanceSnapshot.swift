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
    var interestRateAPR: Decimal?
    var interestRateScale: Int?

    // Provenance
    var isUserCreated: Bool = false
    var isExcluded: Bool = false
    var isUserModified: Bool = false

    // Relationships
    @Relationship(inverse: \Account.balanceSnapshots) var account: Account?
    var importBatch: ImportBatch?

    init(
        id: UUID = UUID(),
        asOfDate: Date,
        balance: Decimal,
        interestRateAPR: Decimal? = nil,
        interestRateScale: Int? = nil,
        account: Account? = nil,
        importBatch: ImportBatch? = nil,
        isUserCreated: Bool = false,
        isExcluded: Bool = false,
        isUserModified: Bool = false
    ) {
        self.id = id
        self.asOfDate = asOfDate
        self.balance = balance
        self.interestRateAPR = interestRateAPR
        self.interestRateScale = interestRateScale
        self.account = account
        self.importBatch = importBatch
        self.isUserCreated = isUserCreated
        self.isExcluded = isExcluded
        self.isUserModified = isUserModified
    }
}

