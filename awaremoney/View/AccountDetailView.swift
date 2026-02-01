import SwiftUI
import SwiftData

struct AccountDetailView: View {
    let accountID: UUID
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    // Query the account live by ID so we never hold a detached instance
    @Query private var fetchedAccounts: [Account]

    @State private var showStartingBalanceSheet = false
    @State private var showRecordedBalanceInfo = false
    @State private var showInstitutionEditSheet = false
    @State private var tempInstitutionName: String = ""
    @State private var showMergeSheet = false
    @State private var mergeTargetID: UUID?
    @State private var cachedDerivedBalance: Decimal? = nil
    @State private var cachedEarliestTransactionDate: Date? = nil

    init(accountID: UUID) {
        self.accountID = accountID
        _fetchedAccounts = Query(filter: #Predicate<Account> { $0.id == accountID }, sort: [])
    }

    private var account: Account? { fetchedAccounts.first }

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
                                if let derived = cachedDerivedBalance {
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
                                        if let apr = last.interestRateAPR {
                                            Text("APR: \(formatAPR(apr, scale: last.interestRateScale))")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
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
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section("Balances") {
                        ForEach(sortedSnapshots(for: account), id: \.id) { snap in
                            HStack {
                                Text(snap.asOfDate, style: .date)
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(format(amount: snap.balance))
                                    if let apr = snap.interestRateAPR {
                                        Text("APR: \(formatAPR(apr, scale: snap.interestRateScale))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
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
                            AccountTransactionsListView(accountID: account.id)
                        } label: {
                            Label("Transactions", systemImage: "list.bullet")
                        }
                        .simultaneousGesture(TapGesture().onEnded {
                            AMLogging.always("Transactions button tapped for accountID=\(account.id)", component: "AccountDetailView")
                        })
                    }
                }
            } else {
                ContentUnavailableView("Account no longer exists", systemImage: "exclamationmark.triangle")
                    .task { dismiss() }
            }
        }
        // If the account disappears (e.g., after batch deletion), dismiss this screen
        .onChange(of: fetchedAccounts.count) { _, newCount in
            AMLogging.always("AccountDetailView fetchedAccounts count changed to \(newCount) for accountID=\(accountID)", component: "AccountDetailView")
            if newCount == 0 { dismiss() }
        }
        .task(id: account?.id) {
            AMLogging.always("AccountDetailView task(id:) fired for accountID=\(accountID)", component: "AccountDetailView")
            if let account = account { await recomputeAccountDerivedData(for: account) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .transactionsDidChange)) { _ in
            AMLogging.always("AccountDetailView received transactionsDidChange for accountID=\(accountID)", component: "AccountDetailView")
            Task { if let account = account { await recomputeAccountDerivedData(for: account) } }
        }
        .onAppear {
            AMLogging.always("AccountDetailView appear accountID=\(accountID)", component: "AccountDetailView")
        }
    }

    private func earliestTransactionDate(for account: Account) -> Date? {
        return cachedEarliestTransactionDate
    }

    private func defaultStartingBalanceDate(for account: Account) -> Date? {
        guard let earliest = cachedEarliestTransactionDate else { return nil }
        if isMissingStartingBalance(for: account) {
            return Calendar.current.date(byAdding: .day, value: -1, to: earliest)
        } else {
            return earliest
        }
    }

    private func isMissingStartingBalance(for account: Account) -> Bool {
        guard let earliest = cachedEarliestTransactionDate else { return false }
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

    private func recomputeAccountDerivedData(for account: Account) async {
        let t0 = Date()
        let container = modelContext.container
        let bg = ModelContext(container)
        bg.autosaveEnabled = false

        // Capture ID and last snapshot data on the main actor
        let id = await MainActor.run { account.id }
        AMLogging.always("recompute start id=\(id)", component: "AccountDetailView")
        let snapshotData: (Decimal?, Date?) = await MainActor.run { () -> (Decimal?, Date?) in
            let last = self.lastBalanceSnapshot(for: account)
            return (last?.balance, last?.asOfDate)
        }
        let baseBalance = snapshotData.0
        let sinceDate = snapshotData.1

        do {
            // Earliest transaction date using an ascending sort and fetch limit 1
            let earliest = try await fetchEarliestTransactionDate(in: bg, accountID: id)
            AMLogging.always("recompute earliest=\(String(describing: earliest)) id=\(id)", component: "AccountDetailView")
            await MainActor.run {
                self.cachedEarliestTransactionDate = earliest
            }

            // Derived balance: if we have a base snapshot, sum deltas since; otherwise sum all
            let delta = try await sumTransactions(in: bg, accountID: id, since: sinceDate)
            AMLogging.always("recompute delta=\(delta) base=\(String(describing: baseBalance)) id=\(id)", component: "AccountDetailView")
            await MainActor.run {
                if let base = baseBalance {
                    self.cachedDerivedBalance = base + delta
                } else {
                    self.cachedDerivedBalance = (delta == 0 ? nil : delta)
                }
            }

            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            AMLogging.always("recompute done id=\(id) in \(ms)ms", component: "AccountDetailView")
        } catch {
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            AMLogging.error("recompute failed id=\(id) after \(ms)ms: \(error.localizedDescription)", component: "AccountDetailView")
            await MainActor.run {
                self.cachedDerivedBalance = nil
            }
            // Leave earliest as-is to avoid UI flicker
        }
    }

    private func fetchEarliestTransactionDate(in context: ModelContext, accountID: UUID) async throws -> Date? {
        let predicate = #Predicate<Transaction> { tx in tx.account?.id == accountID }
        var descriptor = FetchDescriptor<Transaction>(predicate: predicate)
        descriptor.sortBy = [SortDescriptor(\Transaction.datePosted, order: .forward)]
        descriptor.fetchLimit = 1
        let results = try context.fetch(descriptor)
        return results.first?.datePosted
    }

    private func sumTransactions(in context: ModelContext, accountID: UUID, since: Date?) async throws -> Decimal {
        let predicate: Predicate<Transaction>
        if let sinceDate = since {
            predicate = #Predicate<Transaction> { tx in tx.account?.id == accountID && tx.datePosted > sinceDate }
        } else {
            predicate = #Predicate<Transaction> { tx in tx.account?.id == accountID }
        }
        let descriptor = FetchDescriptor<Transaction>(predicate: predicate)
        let results = try context.fetch(descriptor)
        return results.reduce(Decimal.zero) { $0 + $1.amount }
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

    private func formatAPR(_ apr: Decimal, scale: Int? = nil) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .percent
        if let s = scale { nf.minimumFractionDigits = s; nf.maximumFractionDigits = s } else { nf.minimumFractionDigits = 2; nf.maximumFractionDigits = 3 }
        return nf.string(from: NSDecimalNumber(decimal: apr)) ?? "\(apr)"
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

    // Live query of accounts to avoid stashing detached instances
    @Query private var accounts: [Account]

    init(currentAccountID: UUID, selectedTargetID: Binding<UUID?>) {
        self.currentAccountID = currentAccountID
        self._selectedTargetID = selectedTargetID
        _accounts = Query(sort: [SortDescriptor(\Account.name, order: .forward)])
    }

    var body: some View {
        Form {
            Section("Merge into") {
                Picker("Target Account", selection: $selectedTargetID) {
                    ForEach(accounts.filter { $0.id != currentAccountID }, id: \.id) { acct in
                        Text("\(acct.name) — \(acct.type.rawValue.capitalized)").tag(Optional(acct.id))
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
    }

    private var mergeDisabled: Bool {
        guard let id = selectedTargetID else { return true }
        return id == currentAccountID
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

