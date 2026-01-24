//
//  TransactionsListView.swift
//  awaremoney
//
//  Created by Karl Keller on 1/23/26.
//

import SwiftUI
import SwiftData

struct TransactionsListView: View {
    @Query(sort: \Transaction.datePosted, order: .reverse)
    private var transactions: [Transaction]

    @State private var refreshTick: Int = 0

    var body: some View {
        NavigationStack {
            List {
                ForEach(transactions) { tx in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(tx.payee).font(.body)
                            HStack(spacing: 8) {
                                Text(tx.datePosted, style: .date)
                                if let acct = tx.account {
                                    Text(acct.name).foregroundStyle(.secondary)
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(format(amount: tx.amount))
                            .foregroundStyle(tx.amount < 0 ? .red : .primary)
                    }
                }
            }
            .navigationTitle("Transactions")
        }
        .id(refreshTick)
        .onReceive(NotificationCenter.default.publisher(for: .transactionsDidChange)) { _ in
            refreshTick &+= 1
            AMLogging.log("TransactionsListView refresh tick: \(refreshTick), visible count: \(transactions.count)", component: "TransactionsListView")  // DEBUG LOG
        }
        .task {
            AMLogging.log("TransactionsListView initial count: \(transactions.count)", component: "TransactionsListView")  // DEBUG LOG
        }
    }

    private func format(amount: Decimal) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = "USD"
        return nf.string(from: NSDecimalNumber(decimal: amount)) ?? "\(amount)"
    }
}

