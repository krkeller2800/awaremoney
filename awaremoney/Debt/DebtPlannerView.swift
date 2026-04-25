// DebtPlannerView.swift
// Entry point for selecting an account and opening the payoff planner

import SwiftUI
import SwiftData

struct DebtPlannerView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var settings: SettingsStore
    @Query private var liabilities: [Account]
    
    init() {
        _liabilities = Query(filter: #Predicate<Account> { $0.typeRaw == "loan" || $0.typeRaw == "creditCard" })
    }

    var body: some View {
        List {
            if liabilities.isEmpty {
                ContentUnavailableView("No debts yet", systemImage: "creditcard")
            } else {
                Section("Choose an account to plan") {
                    ForEach(liabilities, id: \.id) { acct in
                        NavigationLink {
                            DebtPayoffContainer(accountID: acct.id)
                        } label: {
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(acct.name).font(.headline)
                                    Text(acct.type == .loan ? "Loan" : "Credit Card")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(currentBalance(for: acct))
                                    .font(.headline)
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Debt Planner")
    }

    private func currentBalance(for account: Account) -> String {
        let bal = latestBalance(account)
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = settings.currencyCode
        return nf.string(from: NSDecimalNumber(decimal: bal)) ?? "\(bal)"
    }

    private func latestBalance(_ account: Account) -> Decimal {
        let id = account.id
        let pred = #Predicate<BalanceSnapshot> { $0.account?.id == id }
        var desc = FetchDescriptor<BalanceSnapshot>(predicate: pred)
        desc.sortBy = [SortDescriptor(\BalanceSnapshot.asOfDate, order: .reverse)]
        desc.fetchLimit = 1
        let snap = try? modelContext.fetch(desc).first
        return snap?.balance ?? 0
    }
}

#Preview {
    Text("Preview requires model data")
}
