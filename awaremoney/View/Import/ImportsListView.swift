//
//  ImportsListView.swift
//  awaremoney
//
//  Created by Assistant on 1/23/26.
//

import SwiftUI
import SwiftData

struct ImportsListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \ImportBatch.createdAt, order: .reverse)
    private var batches: [ImportBatch]

    var body: some View {
        List {
            ForEach(batches) { batch in
                VStack(alignment: .leading, spacing: 4) {
                    Text(batch.label)
                        .font(.headline)
                    HStack(spacing: 8) {
                        Text(batch.createdAt, style: .date)
                        Text(batch.createdAt, style: .time)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .onDelete(perform: delete)
        }
        .navigationTitle("Imports")
    }

    private func delete(at offsets: IndexSet) {
        // Track accounts impacted by the batches we are deleting
        var impactedAccountIDs: Set<UUID> = []

        // Gather impacted accounts before deleting batches
        for index in offsets {
            let batch = batches[index]
            let batchID = batch.id

            let pred = #Predicate<Transaction> { tx in
                tx.importBatch?.id == batchID
            }
            let desc = FetchDescriptor<Transaction>(predicate: pred)
            if let txs = try? context.fetch(desc) {
                for tx in txs {
                    if let acct = tx.account {
                        impactedAccountIDs.insert(acct.id)
                    }
                }
            }

            // Also gather accounts referenced by holdings in this batch (brokerage-only imports may have no transactions)
            let holdPred = #Predicate<HoldingSnapshot> { snap in
                snap.importBatch?.id == batchID
            }
            let holdDesc = FetchDescriptor<HoldingSnapshot>(predicate: holdPred)
            if let holds = try? context.fetch(holdDesc) {
                for snap in holds {
                    if let acct = snap.account {
                        impactedAccountIDs.insert(acct.id)
                    }
                }
            }

            // And accounts referenced by balances in this batch
            let balPred = #Predicate<BalanceSnapshot> { snap in
                snap.importBatch?.id == batchID
            }
            let balDesc = FetchDescriptor<BalanceSnapshot>(predicate: balPred)
            if let bals = try? context.fetch(balDesc) {
                for snap in bals {
                    if let acct = snap.account {
                        impactedAccountIDs.insert(acct.id)
                    }
                }
            }

            context.delete(batch)
        }

        // First save to perform cascade deletes of transactions/holdings/balances
        try? context.save()

        // After cascades, remove any accounts that are now empty
        for id in impactedAccountIDs {
            let acctPred = #Predicate<Account> { acct in acct.id == id }
            var acctDesc = FetchDescriptor<Account>(predicate: acctPred)
            acctDesc.fetchLimit = 1
            if let acct = try? context.fetch(acctDesc).first {
                if acct.transactions.isEmpty && acct.balanceSnapshots.isEmpty && acct.holdingSnapshots.isEmpty {
                    context.delete(acct)
                }
            }
        }

        try? context.save()
    }
}

