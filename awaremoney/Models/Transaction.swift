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
        // System/utility
        case adjustment
    }

    @Attribute(.unique) var id: UUID
    var datePosted: Date
    var amount: Decimal
    var payee: String
    var memo: String?
    var kind: Kind
    var externalId: String? // From statement if available
    var hashKey: String     // For de-duping <= derived from fields
    var linkedTransactionId: UUID?

    // Brokerage fields (optional)
    var symbol: String?
    var quantity: Decimal?
    var price: Decimal?
    var fees: Decimal?

    // Relationships
    @Relationship(inverse: \Account.transactions) var account: Account?

    // Link back to the import batch that created this transaction (optional)
    var importBatch: ImportBatch?

    // Provenance and audit
    var isUserCreated: Bool = false
    var isUserEdited: Bool = false
    var isExcluded: Bool = false
    var isUserModified: Bool = false
    // Immutable key used for de-duplication across re-imports
    var importHashKey: String?
    // Optional originals for audit when edits occur
    var originalAmount: Decimal?
    var originalDate: Date?

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
        account: Account? = nil,
        importBatch: ImportBatch? = nil,
        isUserCreated: Bool = false,
        isUserEdited: Bool = false,
        isExcluded: Bool = false,
        isUserModified: Bool = false,
        importHashKey: String? = nil,
        originalAmount: Decimal? = nil,
        originalDate: Date? = nil
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
        self.importBatch = importBatch
        self.isUserCreated = isUserCreated
        self.isUserEdited = isUserEdited
        self.isExcluded = isExcluded
        self.isUserModified = isUserModified
        self.importHashKey = importHashKey
        self.originalAmount = originalAmount
        self.originalDate = originalDate
    }
}

