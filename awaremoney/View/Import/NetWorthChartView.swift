import SwiftUI
import SwiftData
import Charts

struct NetWorthChartView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var slices: [AccountSlice] = []

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading) {
                if slices.isEmpty {
                    emptyState
                } else {
                    chart
                }
            }
            .navigationTitle("Net Worth")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await load() }
            .onReceive(NotificationCenter.default.publisher(for: .accountsDidChange)) { _ in Task { await load() } }
            .onReceive(NotificationCenter.default.publisher(for: .transactionsDidChange)) { _ in Task { await load() } }
        }
    }
    
    private var emptyState: some View {
        ContentUnavailableView(
            "No Net Worth Data",
            systemImage: "chart.line.uptrend.xyaxis",
            description: Text("Import statements with balances to see your net worth over time.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var chart: some View {
        let data = slices
        let total = data.reduce(Decimal.zero) { $0 + $1.value }
        let totalDouble = NSDecimalNumber(decimal: total).doubleValue

        return VStack(alignment: .leading, spacing: 12) {
            Chart {
                ForEach(data) { s in
                    SectorMark(
                        angle: .value("Value", s.doubleValue)
                    )
                    .foregroundStyle(by: .value("Account", s.name))
                    .annotation(position: .overlay) {
                        if totalDouble > 0 {
                            let pct = s.doubleValue / totalDouble
                            if pct >= 0.06 { // avoid clutter: only label slices >= 6%
                                Text(labelText(for: s, percent: pct))
                                    .font(.caption2)
                                    .bold()
                                    .foregroundStyle(.white)
                                    .shadow(radius: 1)
                            }
                        }
                    }
                }
            }
            .chartLegend(.visible)
        }
        .padding()
    }

    private func labelText(for slice: AccountSlice, percent: Double) -> String {
        let pctStr = String(format: "%.0f%%", percent * 100)
        return "\(slice.name) \(pctStr)"
    }

    private func typeDisplayName(_ type: Account.AccountType) -> String {
        switch type {
        case .checking: return "checking"
        case .savings: return "savings"
        case .creditCard: return "credit card"
        case .cash: return "cash"
        case .brokerage: return "brokerage"
        case .other: return "other"
        }
    }

    @Sendable private func load() async {
        do {
            // Fetch all accounts
            let accounts = try modelContext.fetch(FetchDescriptor<Account>())

            var out: [AccountSlice] = []
            for acct in accounts {
                // Use the most recent non-excluded balance snapshot as a base, plus transactions after that date.
                let snapshots = acct.balanceSnapshots.filter { !$0.isExcluded }
                let last = snapshots.sorted { $0.asOfDate > $1.asOfDate }.first
                let txs = acct.transactions.filter { !$0.isExcluded }

                let value: Decimal = {
                    if let last = last {
                        let delta = txs.filter { $0.datePosted > last.asOfDate }
                            .reduce(Decimal.zero) { $0 + $1.amount }
                        return last.balance + delta
                    } else {
                        return txs.reduce(Decimal.zero) { $0 + $1.amount }
                    }
                }()

                // For a pie chart, only include positive balances (assets). Negative values (liabilities) are omitted.
                if value > 0 {
                    let baseName: String = {
                        let inst = (acct.institutionName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        return inst.isEmpty ? acct.name : inst
                    }()
                    let displayName = "\(baseName) \(typeDisplayName(acct.type))"
                    out.append(AccountSlice(id: acct.id.uuidString, name: displayName, value: value, currencyCode: acct.currencyCode, type: acct.type))
                }
            }

            // Sort descending by value for stable legend ordering
            out.sort { $0.doubleValue > $1.doubleValue }

            await MainActor.run { self.slices = out }
        } catch {
            await MainActor.run { self.slices = [] }
        }
    }

    private func format(amount: Decimal) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = "USD"
        return nf.string(from: NSDecimalNumber(decimal: amount)) ?? "\(amount)"
    }
}

private struct AccountSlice: Identifiable {
    let id: String
    let name: String
    let value: Decimal
    let currencyCode: String
    let type: Account.AccountType
    var doubleValue: Double { NSDecimalNumber(decimal: value).doubleValue }
}

