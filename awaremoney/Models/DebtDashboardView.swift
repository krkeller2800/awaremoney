//
//  DebtDashboardView.swift
//  awaremoney
//
//  Created by Assistant on 2/1/26
//

import SwiftUI
import SwiftData

struct DebtDashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var liabilities: [Account] = []

    var body: some View {
        NavigationStack {
            List {
                if liabilities.isEmpty {
                    ContentUnavailableView("No debts yet", systemImage: "creditcard")
                } else {
                    Section("Debts") {
                        ForEach(liabilities, id: \.id) { acct in
                            NavigationLink(destination: DebtDetailView(account: acct)) {
                                HStack(alignment: .firstTextBaseline) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(acct.name)
                                            .font(.headline)
                                        Text(acct.type == .loan ? "Loan" : "Credit Card")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 4) {
                                        Text(currentBalance(for: acct))
                                            .font(.headline)
                                            .foregroundStyle(.red)
                                        if let payoff = payoffDate(for: acct) {
                                            Text("Payoff: \(payoff, style: .date)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Debt")
            .task { await load() }
            .refreshable { await load() }
        }
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

    private func latestBalance(_ account: Account) -> Decimal {
        let id = account.id
        let pred = #Predicate<BalanceSnapshot> { $0.account?.id == id }
        var desc = FetchDescriptor<BalanceSnapshot>(predicate: pred)
        desc.sortBy = [SortDescriptor(\BalanceSnapshot.asOfDate, order: .reverse)]
        desc.fetchLimit = 1
        let snap = try? modelContext.fetch(desc).first
        return snap?.balance ?? 0
    }

    private func currentBalance(for account: Account) -> String {
        let bal = latestBalance(account)
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = "USD"
        return nf.string(from: NSDecimalNumber(decimal: bal)) ?? "\(bal)"
    }

    private func payoffDate(for account: Account) -> Date? {
        let bal = latestBalance(account)
        guard bal > 0 else { return nil }
        let apr = account.loanTerms?.apr
        let payment: Decimal? = account.loanTerms?.paymentAmount
        do {
            let kind: DebtKind = (account.type == .loan) ? .loan : .creditCard(account.creditCardPaymentMode ?? .minimum)
            let points = try DebtProjectionEngine.project(kind: kind, startingBalance: bal, apr: apr, payment: payment)
            // Find first point with balance 0
            if let terminal = points.last, terminal.balance == 0 {
                return terminal.date
            }
            return nil
        } catch {
            return nil
        }
    }
}

struct DebtDetailView: View {
    let account: Account
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        List {
            Section("Overview") {
                LabeledContent("Institution", value: account.institutionName ?? "")
                LabeledContent("Type", value: account.type.rawValue.capitalized)
                if let apr = account.loanTerms?.apr {
                    Text("APR: \(formatAPR(apr, scale: account.loanTerms?.aprScale))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Payment Plan") {
                if account.type == .creditCard {
                    LabeledContent("Mode", value: (account.creditCardPaymentMode ?? .minimum).rawValue.capitalized)
                }
                LabeledContent("Typical Payment", value: formatAmount(account.loanTerms?.paymentAmount))
                if let day = account.loanTerms?.paymentDayOfMonth { LabeledContent("Due Day", value: "\(day)") }
            }
            Section("Projection") {
                if let payoff = payoffDate(for: account) {
                    LabeledContent("Estimated Payoff", value: payoff.formatted(date: .abbreviated, time: .omitted))
                } else {
                    Text("Enter APR and a payment amount to see a payoff estimate.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(account.name)
    }

    private func payoffDate(for account: Account) -> Date? {
        let bal = latestBalance(account)
        guard bal > 0 else { return nil }
        let apr = account.loanTerms?.apr
        let payment: Decimal? = account.loanTerms?.paymentAmount
        do {
            let kind: DebtKind = (account.type == .loan) ? .loan : .creditCard(account.creditCardPaymentMode ?? .minimum)
            let points = try DebtProjectionEngine.project(kind: kind, startingBalance: bal, apr: apr, payment: payment)
            if let terminal = points.last, terminal.balance == 0 { return terminal.date }
            return nil
        } catch { return nil }
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

    private func formatAmount(_ amount: Decimal?) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = "USD"
        guard let amount else { return "—" }
        return nf.string(from: NSDecimalNumber(decimal: amount)) ?? "\(amount)"
    }

    private func formatAPR(_ apr: Decimal, scale: Int? = nil) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .percent
        if let s = scale { nf.minimumFractionDigits = s; nf.maximumFractionDigits = s }
        else { nf.minimumFractionDigits = 2; nf.maximumFractionDigits = 3 }
        return nf.string(from: NSDecimalNumber(decimal: apr)) ?? "\(apr)"
    }
}

#Preview {
    Text("Preview requires model data")
}
