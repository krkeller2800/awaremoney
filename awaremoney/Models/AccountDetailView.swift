import SwiftUI
import SwiftData

struct AccountDetailView: View {
    let accountID: UUID
    @Environment(\.modelContext) private var modelContext

    @State private var account: Account?
    @State private var showStartingBalanceSheet = false
    @State private var showRecordedBalanceInfo = false

    var body: some View {
        Group {
            if let account {
                List {
                    Section("Details") {
                        LabeledContent("Name", value: account.name)
                        LabeledContent("Institution", value: account.institutionName ?? "Unknown")
                        LabeledContent("Type", value: account.type.rawValue.capitalized)
                    }

                    Section("Balance Info") {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("Transactional Balance")
                                Spacer()
                                if let derived = derivedBalance(for: account) {
                                    Text(format(amount: derived))
                                } else {
                                    Text("Unavailable")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if lastBalanceSnapshot(for: account) != nil {
                                Text("Latest recorded balance plus transactions since then.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Sum of transactions.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline) {
                                Text("Latest Recorded Balance")
                                Button {
                                    showRecordedBalanceInfo = true
                                } label: {
                                    Image(systemName: "info.circle")
                                }
                                .buttonStyle(.plain)
                                Spacer()
                                if let last = lastBalanceSnapshot(for: account) {
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text(format(amount: last.balance))
                                        Text(last.asOfDate, style: .date)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                } else {
                                    Text("None")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .alert("Recorded balance", isPresented: $showRecordedBalanceInfo) {
                                Button("OK", role: .cancel) {}
                            } message: {
                                Text("Shows the most recent balance recorded from a statement or import. Manual starting balances are added as adjustments and appear below.")
                            }
                            Text("Latest recorded balance from a statement or import.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)                        }
                    }

                    Section("Balances") {
                        ForEach(sortedSnapshots(for: account), id: \.id) { snap in
                            HStack {
                                Text(snap.asOfDate, style: .date)
                                Spacer()
                                Text(format(amount: snap.balance))
                            }
                        }

                        let adjustmentsList = adjustments(for: account)
                        if !adjustmentsList.isEmpty {
                            ForEach(adjustmentsList, id: \.id) { tx in
                                HStack {
                                    Text(tx.datePosted, style: .date)
                                    Spacer()
                                    Text(format(amount: tx.amount))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        Button {
                            showStartingBalanceSheet = true
                        } label: {
                            if isMissingStartingBalance(for: account) {
                                Label("Set Starting Balance", systemImage: "plus.circle")
                            } else {
                                Label("Add Balance…", systemImage: "plus.circle")
                            }
                        }

                        if !adjustmentsList.isEmpty || !account.balanceSnapshots.isEmpty {
                            Button {
                                showStartingBalanceSheet = true
                            } label: {
                                Label("Edit Starting Balance…", systemImage: "pencil.circle")
                            }
                        }
                    }
                }
                .navigationTitle(account.name)
                .sheet(isPresented: $showStartingBalanceSheet) {
                    StartingBalanceSheet(account: account, defaultDate: defaultStartingBalanceDate(for: account))
                }
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        NavigationLink {
                            AccountTransactionsListView(account: account)
                        } label: {
                            Label("Transactions", systemImage: "list.bullet")
                        }
                    }
                }
            } else {
                ProgressView().task { await load() }
            }
        }
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .transactionsDidChange)) { _ in
            Task { await load() }
        }
    }

    @Sendable private func load() async {
        do {
            let predicate = #Predicate<Account> { $0.id == accountID }
            var descriptor = FetchDescriptor<Account>(predicate: predicate)
            descriptor.fetchLimit = 1
            let fetched = try modelContext.fetch(descriptor).first
            await MainActor.run { self.account = fetched }
        } catch {
            // Ignore errors for now
        }
    }

    private func earliestTransactionDate(for account: Account) -> Date? {
        account.transactions.map(\.datePosted).min()
    }

    private func defaultStartingBalanceDate(for account: Account) -> Date? {
        guard let earliest = earliestTransactionDate(for: account) else { return nil }
        if isMissingStartingBalance(for: account) {
            return Calendar.current.date(byAdding: .day, value: -1, to: earliest)
        } else {
            return earliest
        }
    }

    private func isMissingStartingBalance(for account: Account) -> Bool {
        guard let earliest = earliestTransactionDate(for: account) else { return false }
        let hasSnapshot = account.balanceSnapshots.contains { $0.asOfDate <= earliest }
        let hasAdjustment = account.transactions.contains { $0.kind == .adjustment && $0.datePosted <= earliest }
        return !(hasSnapshot || hasAdjustment)
    }

    private func sortedSnapshots(for account: Account) -> [BalanceSnapshot] {
        account.balanceSnapshots.sorted { $0.asOfDate > $1.asOfDate }
    }

    private func adjustments(for account: Account) -> [Transaction] {
        account.transactions.filter { $0.kind == .adjustment }.sorted { $0.datePosted > $1.datePosted }
    }

    private func lastBalanceSnapshot(for account: Account) -> BalanceSnapshot? {
        sortedSnapshots(for: account).first
    }

    private func derivedBalance(for account: Account) -> Decimal? {
        if let last = lastBalanceSnapshot(for: account) {
            let base = last.balance
            let delta = account.transactions
                .filter { $0.datePosted > last.asOfDate }
                .reduce(Decimal.zero) { $0 + $1.amount }
            return base + delta
        } else {
            let total = account.transactions.reduce(Decimal.zero) { $0 + $1.amount }
            return total == 0 ? nil : total
        }
    }

    private func format(amount: Decimal) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = "USD"
        return nf.string(from: NSDecimalNumber(decimal: amount)) ?? "\(amount)"
    }
}

#Preview {
    Text("Preview requires model data")
}
