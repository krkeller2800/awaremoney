//
//  NetWorthView.swift
//  awaremoney
//
//  Created by Karl Keller on 1/23/26.
//

import SwiftUI
import SwiftData

private struct AccountValue: Identifiable {
    let account: Account
    let value: Decimal
    var id: AnyHashable { AnyHashable(account.id) }
}

struct NetWorthView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var totalNetWorth: Decimal = 0
    @State private var byAccount: [AccountValue] = []

    var body: some View {
        NavigationStack {
            List {
                Section("Accounts") {
                    ForEach(byAccount) { row in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(row.account.name)
                                Text(row.account.type.rawValue).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(format(amount: row.value))
                                .foregroundStyle(row.value < .zero ? .red : .primary)
                        }
                    }
                }

                Section("Total") {
                    HStack {
                        Text("Net Worth")
                        Spacer()
                        Text(format(amount: totalNetWorth))
                            .font(.headline)
                    }
                }
            }
            .navigationTitle("Net Worth")
            .task { await load() }
            .refreshable { await load() }
        }
    }

    @Sendable private func load() async {
        do {
            // Fetch all accounts
            let accounts = try modelContext.fetch(FetchDescriptor<Account>())
            var perAccount: [AccountValue] = []
            var total: Decimal = 0

            for account in accounts {
                let latestBalance = try latestBalance(for: account)
                let derived = try derivedBalanceFromTransactions(for: account)
                let accountValue = latestBalance ?? derived
                perAccount.append(AccountValue(account: account, value: accountValue))
                total += accountValue
            }

            await MainActor.run {
                self.byAccount = perAccount.sorted { $0.account.name < $1.account.name }
                self.totalNetWorth = total
            }
        } catch {
            // For MVP, ignore errors and keep zeros
        }
    }

    private func latestBalance(for account: Account) throws -> Decimal? {
        // Fetch the most recent balance snapshot for this account by comparing IDs (avoid comparing model instances in predicates)
        let accountID = account.id
        let predicate = #Predicate<BalanceSnapshot> { snap in
            snap.account?.id == accountID
        }
        var descriptor = FetchDescriptor<BalanceSnapshot>(predicate: predicate)
        descriptor.sortBy = [SortDescriptor(\BalanceSnapshot.asOfDate, order: .reverse)]
        descriptor.fetchLimit = 1
        let snapshots = try modelContext.fetch(descriptor)
        return snapshots.first?.balance
    }

    private func derivedBalanceFromTransactions(for account: Account) throws -> Decimal {
        return account.transactions.reduce(Decimal.zero) { $0 + $1.amount }
    }

    private func format(amount: Decimal) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = "USD"
        return nf.string(from: NSDecimalNumber(decimal: amount)) ?? "\(amount)"
    }
}

