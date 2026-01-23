//
//  ImportBatch.swift
//  awaremoney
//
//  Created by Karl Keller on 1/23/26.
//

import Foundation
import SwiftData

@Model
final class ImportBatch {
    enum Status: String, Codable {
        case draft, committed
    }

    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var sourceFileName: String
    var parserId: String
    var status: Status
    var notes: String?

    // Optional backrefs for provenance
    @Relationship(deleteRule: .nullify) var transactions: [Transaction]
    @Relationship(deleteRule: .nullify) var holdingSnapshots: [HoldingSnapshot]
    @Relationship(deleteRule: .nullify) var balanceSnapshots: [BalanceSnapshot]

    init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        sourceFileName: String,
        parserId: String,
        status: Status = .draft,
        notes: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.sourceFileName = sourceFileName
        self.parserId = parserId
        self.status = status
        self.notes = notes
        self.transactions = []
        self.holdingSnapshots = []
        self.balanceSnapshots = []
    }
}
