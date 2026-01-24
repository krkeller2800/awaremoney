//
//  Transaction.swift
//  awaremoney
//
//  Created by Karl Keller on 1/23/26.
//

import Foundation
import SwiftData

@Model
final class Transaction {
    enum Kind: String, Codable {
        // Bank-like
        case bank, fee, interest, transfer
        // Brokerage-like
        case buy, sell, dividend, deposit, withdrawal
    }

    @Attribute(.unique) var id: UUID
    var datePosted: Date
    var amount: Decimal
    var payee: String
    var memo: String?
    var kind: Kind
    var externalId: String? // From statement if available
    var hashKey: String     // For de-duping <= derived from fields

    // Brokerage fields (optional)
    var symbol: String?
    var quantity: Decimal?
    var price: Decimal?
    var fees: Decimal?

    // Relationships
    @Relationship(inverse: \Account.transactions) var account: Account?

    init(
        id: UUID = UUID(),
        datePosted: Date,
        amount: Decimal,
        payee: String,
        memo: String? = nil,
        kind: Kind = .bank,
        externalId: String? = nil,
        hashKey: String,
        symbol: String? = nil,
        quantity: Decimal? = nil,
        price: Decimal? = nil,
        fees: Decimal? = nil,
        account: Account? = nil
    ) {
        self.id = id
        self.datePosted = datePosted
        self.amount = amount
        self.payee = payee
        self.memo = memo
        self.kind = kind
        self.externalId = externalId
        self.hashKey = hashKey
        self.symbol = symbol
        self.quantity = quantity
        self.price = price
        self.fees = fees
        self.account = account
    }
}

