import SwiftUI
import SwiftData
import Charts

struct NetWorthChartView: View {
    private enum ChartMode: String, CaseIterable, Identifiable {
        case assets = "Assets"
        case liabilities = "Liabilities"
        case debtVsAssets = "Debt vs Assets"
        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var settings: SettingsStore
    var showsDoneButton: Bool = true

    @State private var slices: [AccountSlice] = []
    @State private var totalAssetsValue: Decimal = 0
    @State private var totalLiabilitiesValue: Decimal = 0
    @State private var mode: ChartMode = .assets
    @State private var initializedMode = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading) {
                Picker("View", selection: $mode) {
                    ForEach(ChartMode.allCases) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                if slices.isEmpty {
                    emptyState
                } else {
                    chart
                }
            }
            .navigationTitle("Net Worth")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if showsDoneButton {
                    ToolbarItem(placement: .topBarTrailing) {
                        PlanToolbarButton("Done") { dismiss() }
                    }
                }
            }
            .task { await determineInitialMode(); await load() }
            .onReceive(NotificationCenter.default.publisher(for: .accountsDidChange)) { _ in Task { await load() } }
            .onReceive(NotificationCenter.default.publisher(for: .transactionsDidChange)) { _ in Task { await load() } }
            .onChange(of: mode) { Task { await load() } }
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
            HStack(spacing: 8) {
                Text(titlePrefix(for: mode))
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Text(format(amount: titleAmount(for: mode)))
                    .font(.headline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(titleColor(for: mode))
            }
            .lineLimit(1)
            .minimumScaleFactor(0.75)
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
            .chartLegend(position: .bottom)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartPlotStyle { plot in
                plot
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding()
    }

    private func labelText(for slice: AccountSlice, percent: Double) -> String {
        let pctStr = String(format: "%.0f%%", percent * 100)
        return "\(slice.name) \(pctStr)"
    }

    private func titlePrefix(for mode: ChartMode) -> String {
        switch mode {
        case .assets:
            return "Total Assets ="
        case .liabilities:
            return "Total Liabilities ="
        case .debtVsAssets:
            return "Total Net Worth ="
        }
    }

    private func titleAmount(for mode: ChartMode) -> Decimal {
        switch mode {
        case .assets:
            // Sum of current slices (assets mode only includes positive values)
            return slices.reduce(Decimal.zero) { $0 + $1.value }
        case .liabilities:
            // Sum of current slices (liabilities mode uses magnitudes)
            return slices.reduce(Decimal.zero) { $0 + $1.value }
        case .debtVsAssets:
            // Net worth = assets - liabilities
            return totalAssetsValue - totalLiabilitiesValue
        }
    }

    private func titleColor(for mode: ChartMode) -> Color {
        let amount = titleAmount(for: mode)
        return amount < 0 ? .red : .primary
    }

    private func typeDisplayName(_ type: Account.AccountType) -> String {
        switch type {
        case .checking: return "checking"
        case .savings: return "savings"
        case .creditCard: return "credit card"
        case .loan: return "loan"
        case .cash: return "cash"
        case .brokerage: return "brokerage"
        case .property: return "property"
        case .other: return "other"
        }
    }

    @Sendable private func load() async {
        do {
            // Fetch all accounts
            let accounts = try modelContext.fetch(FetchDescriptor<Account>())

            var out: [AccountSlice] = []
            var totalAssets: Decimal = .zero
            var totalLiabilities: Decimal = .zero

            for acct in accounts {
                // Use the most recent non-excluded balance snapshot as a base, plus non-excluded transactions after that date.
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

                // Tally overall totals for the comparison mode
                if value > 0 { totalAssets += value }
                if value < 0 { totalLiabilities += (-value) }

                // Existing per-account composition behavior for assets and liabilities modes
                switch mode {
                case .assets:
                    if value > 0 {
                        let baseName: String = {
                            if acct.type == .property { return acct.name }
                            let inst = (acct.institutionName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                            return inst.isEmpty ? acct.name : inst
                        }()
                        let displayName = "\(baseName) \(typeDisplayName(acct.type))"
                        out.append(AccountSlice(id: acct.id.uuidString, name: displayName, value: value, currencyCode: acct.currencyCode, type: acct.type))
                    }
                case .liabilities:
                    if value < 0 {
                        let magnitude = -value
                        let baseName: String = {
                            if acct.type == .property { return acct.name }
                            let inst = (acct.institutionName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                            return inst.isEmpty ? acct.name : inst
                        }()
                        let displayName = "\(baseName) \(typeDisplayName(acct.type))"
                        out.append(AccountSlice(id: acct.id.uuidString, name: displayName, value: magnitude, currencyCode: acct.currencyCode, type: acct.type))
                    }
                case .debtVsAssets:
                    // Defer; we'll build the two slices after the loop
                    break
                }
            }

            if mode == .debtVsAssets {
                out = []
                if totalAssets > 0 {
                    out.append(AccountSlice(id: "assets", name: "Assets", value: totalAssets, currencyCode: settings.currencyCode, type: .other))
                }
                if totalLiabilities > 0 {
                    out.append(AccountSlice(id: "liabilities", name: "Debt", value: totalLiabilities, currencyCode: settings.currencyCode, type: .other))
                }
            }

            // Sort descending by value for stable legend ordering
            out.sort { $0.doubleValue > $1.doubleValue }

            await MainActor.run {
                self.slices = out
                self.totalAssetsValue = totalAssets
                self.totalLiabilitiesValue = totalLiabilities
            }
        } catch {
            await MainActor.run { self.slices = [] }
        }
    }
    
    @Sendable private func determineInitialMode() async {
        do {
            let accounts = try modelContext.fetch(FetchDescriptor<Account>())
            var hasAssets = false
            var hasLiabilities = false
            for acct in accounts {
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
                if value > 0 { hasAssets = true }
                if value < 0 { hasLiabilities = true }
                if hasAssets && hasLiabilities { break }
            }
            if !initializedMode {
                await MainActor.run {
                    if !hasAssets && hasLiabilities {
                        self.mode = .liabilities
                    } else if hasAssets && !hasLiabilities {
                        self.mode = .assets
                    }
                    self.initializedMode = true
                }
            }
        } catch {
            await MainActor.run { self.initializedMode = true }
        }
    }

    private func format(amount: Decimal) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = settings.currencyCode
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

