import SwiftUI
import SwiftData

struct AccountDetailView: View {
    let accountID: UUID
    @Environment(\.modelContext) private var modelContext

    @State private var account: Account?
    @State private var showStartingBalanceSheet = false
    @State private var showRecordedBalanceInfo = false
    @State private var showInstitutionEditSheet = false
    @State private var tempInstitutionName: String = ""
    @State private var showMergeSheet = false
    @State private var mergeTargetID: UUID?

    var body: some View {
        Group {
            if let account {
                List {
                    Section("Details") {
                        LabeledContent("Name", value: account.name)
                        if isInvalidInstitutionName(account.institutionName) {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text("Institution")
                                    Spacer()
                                    Button {
                                        tempInstitutionName = ""
                                        showInstitutionEditSheet = true
                                    } label: {
                                        Label("Set Institution…", systemImage: "exclamationmark.triangle.fill")
                                    }
                                    .buttonStyle(.borderedProminent)
                                }
                                Text("Required. We couldn't derive this from your import.")
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                            }
                        } else {
                            Button {
                                tempInstitutionName = account.institutionName ?? ""
                                showInstitutionEditSheet = true
                            } label: {
                                LabeledContent("Institution", value: account.institutionName ?? "")
                            }
                            .buttonStyle(.plain)
                        }
                        LabeledContent("Type", value: account.type.rawValue.capitalized)
                        if account.type == .brokerage && account.balanceSnapshots.isEmpty && account.holdingSnapshots.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .firstTextBaseline) {
                                    Image(systemName: "info.circle")
                                        .foregroundStyle(.blue)
                                    Text("Brokerage activity won't affect Net Worth until you import a statement with balances/holdings or set a starting balance.")
                                }
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            }
                            .padding(.top, 4)
                        }
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

                    Section("Maintenance") {
                        Button(role: .destructive) {
                            mergeTargetID = nil
                            showMergeSheet = true
                        } label: {
                            Label("Merge Into Another Account…", systemImage: "arrow.triangle.merge")
                        }
                    }
                }
                .navigationTitle(account.name)
                .sheet(isPresented: $showStartingBalanceSheet) {
                    StartingBalanceSheet(account: account, defaultDate: defaultStartingBalanceDate(for: account))
                }
                .sheet(isPresented: $showInstitutionEditSheet) {
                    NavigationStack {
                        Form {
                            Section("Institution") {
                                TextField("Institution name", text: $tempInstitutionName)
                            }
                            if isInvalidInstitutionName(tempInstitutionName) {
                                Text("Please enter the bank or institution name (not a generic word like 'statement').")
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                            }
                        }
                        .navigationTitle("Set Institution")
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel") { showInstitutionEditSheet = false }
                            }
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Save") {
                                    let trimmed = tempInstitutionName.trimmingCharacters(in: .whitespacesAndNewlines)
                                    guard !isInvalidInstitutionName(trimmed) else { return }
                                    account.institutionName = trimmed
                                    // Keep account name in sync with institution when edited here
                                    if account.name != trimmed { account.name = trimmed }
                                    do { try modelContext.save() } catch {}
                                    NotificationCenter.default.post(name: .accountsDidChange, object: nil)
                                    Task { await load() }
                                    showInstitutionEditSheet = false
                                }
                                .disabled(isInvalidInstitutionName(tempInstitutionName))
                            }
                        }
                    }
                }
                .sheet(isPresented: $showMergeSheet) {
                    NavigationStack {
                        MergeAccountSheet(currentAccountID: account.id, selectedTargetID: $mergeTargetID)
                            .environment(\.modelContext, modelContext)
                    }
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
        .onReceive(NotificationCenter.default.publisher(for: .accountsDidChange)) { _ in
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
    
    private func isInvalidInstitutionName(_ name: String?) -> Bool {
        guard let raw = name?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return true }
        let lower = raw.lowercased()
        let banned: Set<String> = [
            "statement", "statements", "stmt", "report", "reports", "summary", "summaries",
            "transaction", "transactions", "activity", "history", "export", "exports", "download", "downloads"
        ]
        return banned.contains(lower)
    }
}

#Preview {
    Text("Preview requires model data")
}
struct MergeAccountSheet: View {
    let currentAccountID: UUID
    @Binding var selectedTargetID: UUID?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var accounts: [Account] = []

    var body: some View {
        Form {
            Section("Merge into") {
                Picker("Target Account", selection: Binding(get: {
                    selectedTargetID ?? UUID()
                }, set: { newValue in
                    selectedTargetID = newValue
                })) {
                    ForEach(accounts.filter { $0.id != currentAccountID }, id: \.id) { acct in
                        Text("\(acct.name) — \(acct.type.rawValue.capitalized)").tag(acct.id)
                    }
                }
            }
            Section {
                Button("Merge", role: .destructive) {
                    guard let targetID = selectedTargetID,
                          let source = accounts.first(where: { $0.id == currentAccountID }),
                          let target = accounts.first(where: { $0.id == targetID }) else { return }
                    do {
                        try mergeAccounts(source: source, target: target)
                        dismiss()
                    } catch {
                        // For MVP, ignore errors
                        dismiss()
                    }
                }
                .disabled(mergeDisabled)
            }
        }
        .navigationTitle("Merge Accounts")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        }
        .task { await loadAccounts() }
    }

    private var mergeDisabled: Bool {
        guard let id = selectedTargetID else { return true }
        return id == currentAccountID
    }

    private func loadAccounts() async {
        do {
            let fetched = try modelContext.fetch(FetchDescriptor<Account>())
            await MainActor.run { self.accounts = fetched }
        } catch {
            await MainActor.run { self.accounts = [] }
        }
    }

    private func mergeAccounts(source: Account, target: Account) throws {
        // Move transactions
        for tx in source.transactions {
            tx.account = target
        }
        // Move holdings
        for hs in source.holdingSnapshots {
            hs.account = target
        }
        // Move balances
        for bs in source.balanceSnapshots {
            bs.account = target
        }
        // If source has a more specific institution name, prefer it
        if let srcInst = source.institutionName, !(srcInst.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
            target.institutionName = srcInst
        }
        // Delete the now-empty source account
        modelContext.delete(source)
        try modelContext.save()
        NotificationCenter.default.post(name: .transactionsDidChange, object: nil)
    }
}

