//
//  ImportBatch.swift
//  awaremoney
//
//  Created by Assistant on 1/23/26.
//

import Foundation
import SwiftData

@Model
final class ImportBatch {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var label: String
    var sourceFileName: String

    // Relationships (cascade delete will remove related records when a batch is deleted)
    @Relationship(deleteRule: .cascade, inverse: \HoldingSnapshot.importBatch)
    var holdings: [HoldingSnapshot] = []

    @Relationship(deleteRule: .cascade, inverse: \BalanceSnapshot.importBatch)
    var balances: [BalanceSnapshot] = []

    init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        label: String,
        sourceFileName: String
    ) {
        self.id = id
        self.createdAt = createdAt
        self.label = label
        self.sourceFileName = sourceFileName
    }
}
