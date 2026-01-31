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
    @State private var showNetWorthChart = false

    var body: some View {
        NavigationStack {
            List {
                // Consolidated accounts view: single section with one card per account type and its details
                Section("Accounts") {
                    ForEach(accountTypeOrder, id: \.self) { type in
                        let groups = groupsFor(type: type)
                        if !groups.isEmpty {
                            let subtotal = groups.reduce(Decimal.zero) { $0 + $1.value }

                            VStack(alignment: .leading, spacing: 8) {
                                // Header line
                                HStack {
                                    Text(typeDisplayName(type))
                                        .font(.headline)
                                }

                                // Institution sublines
                                ForEach(groups, id: \.institution) { grp in
                                    HStack {
                                        Text(grp.institution)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Text(format(amount: grp.value))
                                            .foregroundStyle(grp.value < .zero ? .red : .secondary)
                                    }
                                    .padding(.leading, 16)
                                }

                                // Sub-total line
                                HStack {
                                    Text("Total")
                                        .font(.subheadline)
                                    Spacer()
                                    Text(format(amount: subtotal))
                                        .font(.headline)
                                        .foregroundStyle(subtotal < .zero ? .red : .primary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                // Overall total
                Section("Total") {
                    Button {
                        showNetWorthChart = true
                    } label: {
                        HStack {
                            Text("Net Worth")
                            Spacer()
                            HStack(spacing: 6) {
                                Text(format(amount: totalNetWorth))
                                    .font(.headline)
                                    .foregroundStyle(totalNetWorth < .zero ? .red : .primary)
                                Image(systemName: "chevron.up")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Net Worth")
            .task { await load() }
            .refreshable { await load() }
            .onReceive(NotificationCenter.default.publisher(for: .transactionsDidChange)) { _ in
                Task { await load() }
            }
            .sheet(isPresented: $showNetWorthChart) {
                NetWorthChartView()
            }
//            .toolbar {
//                ToolbarItem(placement: .navigationBarTrailing) {
//                    NavigationLink(destination: AccountsListView()) {
//                        Label("Accounts", systemImage: "person.crop.circle")
//                    }
//                }
//            }
        }
    }

    @Sendable private func load() async {
        do {
            // Fetch all accounts
            let accounts = try modelContext.fetch(FetchDescriptor<Account>())
            AMLogging.always("NetWorth load — fetched accounts: \(accounts.count)", component: "NetWorthView")
            var perAccount: [AccountValue] = []
            var total: Decimal = 0

            for account in accounts {
                let value: Decimal = try anchoredValue(for: account)
                AMLogging.always("Account \(account.name) — type: \(account.type.rawValue), inst: \(account.institutionName ?? "(nil)"), value: \(value), tx: \(account.transactions.count)", component: "NetWorthView")
                perAccount.append(AccountValue(account: account, value: value))
                total += value
            }

            await MainActor.run {
                self.byAccount = perAccount.sorted { $0.account.name < $1.account.name }
                self.totalNetWorth = total
            }
        } catch {
            // For MVP, ignore errors and keep zeros
        }
    }

    private func anchoredValue(for account: Account) throws -> Decimal {
        func adjustForLiability(_ value: Decimal, for account: Account) -> Decimal {
            switch account.type {
            case .loan, .creditCard:
                return value > 0 ? -value : value
            default:
                return value
            }
        }

        // Find latest snapshot date if any
        let latestSnapDate: Date? = try {
            let id = account.id
            let pred = #Predicate<BalanceSnapshot> { snap in snap.account?.id == id }
            var desc = FetchDescriptor<BalanceSnapshot>(predicate: pred)
            desc.sortBy = [SortDescriptor(\BalanceSnapshot.asOfDate, order: .reverse)]
            desc.fetchLimit = 1
            let snaps = try modelContext.fetch(desc)
            return snaps.first?.asOfDate
        }()

        if let snapDate = latestSnapDate {
            // Get latest snapshot balance
            let id = account.id
            let pred = #Predicate<BalanceSnapshot> { snap in snap.account?.id == id && snap.asOfDate == snapDate }
            var desc = FetchDescriptor<BalanceSnapshot>(predicate: pred)
            desc.fetchLimit = 1
            let snaps = try modelContext.fetch(desc)
            let base = snaps.first?.balance ?? 0
            // Sum transactions strictly after snapshot date
            let txAfter = account.transactions.filter { $0.datePosted > snapDate }
            let delta = txAfter.reduce(Decimal.zero) { $0 + $1.amount }
            return adjustForLiability(base + delta, for: account)
        } else {
            // No snapshots: sum all transactions
            let sum = account.transactions.reduce(Decimal.zero) { $0 + $1.amount }
            return adjustForLiability(sum, for: account)
        }
    }

    private func format(amount: Decimal) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = "USD"
        return nf.string(from: NSDecimalNumber(decimal: amount)) ?? "\(amount)"
    }

    // Preferred order of account types in the UI
    private var accountTypeOrder: [Account.AccountType] {
        [.checking, .savings, .creditCard, .loan, .brokerage, .cash, .other]
    }
    private func typeDisplayName(_ type: Account.AccountType) -> String {
        switch type {
        case .checking: return "Checking"
        case .savings: return "Savings"
        case .creditCard: return "Credit Cards"
        case .loan: return "Loans"
        case .brokerage: return "Stocks"
        case .cash: return "Cash"
        case .other: return "Other"
        }
    }

    // Return institution-grouped totals for a specific account type
    private func groupsFor(type: Account.AccountType) -> [(institution: String, value: Decimal)] {
        // Filter by type
        let rows = byAccount.filter { $0.account.type == type }
        // Group by institution (fallback to Unknown)
        var buckets: [String: Decimal] = [:]
        for row in rows {
            let inst = (row.account.institutionName?.isEmpty == false) ? row.account.institutionName! : "Unknown"
            buckets[inst, default: .zero] += row.value
        }
        // Sort alphabetically by institution name
        return buckets.keys.sorted().map { key in (institution: key, value: buckets[key] ?? .zero) }
    }
}

