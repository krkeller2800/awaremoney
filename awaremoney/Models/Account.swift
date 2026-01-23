//
//  Account.swift
//  awaremoney
//
//  Created by Karl Keller on 1/23/26.
//

import Foundation
import SwiftData

@Model
final class Account {
    enum AccountType: String, Codable, CaseIterable {
        case checking, savings, creditCard, cash, brokerage, other
    }

    @Attribute(.unique) var id: UUID
    var name: String
    var type: AccountType
    var institutionName: String?
    var currencyCode: String // e.g., "USD"
    var last4: String?
    var createdAt: Date

    // Relationships
    @Relationship(deleteRule: .cascade) var transactions: [Transaction]
    @Relationship(deleteRule: .cascade) var balanceSnapshots: [BalanceSnapshot]
    @Relationship(deleteRule: .cascade) var holdingSnapshots: [HoldingSnapshot]

    init(
        id: UUID = UUID(),
        name: String,
        type: AccountType,
        institutionName: String? = nil,
        currencyCode: String = "USD",
        last4: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.institutionName = institutionName
        self.currencyCode = currencyCode
        self.last4 = last4
        self.createdAt = createdAt
        self.transactions = []
        self.balanceSnapshots = []
        self.holdingSnapshots = []
    }
}
