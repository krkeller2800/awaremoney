// DebtPlannerView.swift
// Entry point for selecting an account and opening the payoff planner

import SwiftUI
import SwiftData

struct DebtPlannerView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var liabilities: [Account] = []

    var body: some View {
        List {
            if liabilities.isEmpty {
                ContentUnavailableView("No debts yet", systemImage: "creditcard")
            } else {
                Section("Choose an account to plan") {
                    ForEach(liabilities, id: \.id) { acct in
                        NavigationLink {
                            DebtPayoffView(viewModel: DebtPayoffViewModel(account: acct, context: modelContext))
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
        .task { await load() }
        .refreshable { await load() }
    }

    @Sendable private func load() async {
        do {
            let all = try modelContext.fetch(FetchDescriptor<Account>())
            await MainActor.run {
                self.liabilities = all.filter { $0.type == .loan || $0.type == .creditCard }
            }
        } catch {
            await MainActor.run { self.liabilities = [] }
        }
    }

    private func currentBalance(for account: Account) -> String {
        let bal = latestBalance(account)
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = "USD"
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
