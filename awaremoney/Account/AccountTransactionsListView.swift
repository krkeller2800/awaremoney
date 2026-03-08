import SwiftUI
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

struct AccountTransactionsListView: View {
    let accountID: UUID
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var account: Account? = nil

    @State private var rows: [TxRow] = []
    struct TxRow: Identifiable { let id: UUID; let payee: String; let date: Date; let amount: Decimal }

    init(accountID: UUID) {
        self.accountID = accountID
        AMLogging.log("AccountTransactionsListView init accountID=\(accountID)", component: "AccountTransactionsListView")
    }

    // Convenience for existing call sites that pass an Account
    init(account: Account) {
        self.init(accountID: account.id)
        _account = State(initialValue: account)
    }

    private var isIPad: Bool {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad
        #else
        return false
        #endif
    }

    var body: some View {
        List {
            Section(header: GroupedSectionHeader("Balances")) {
                if let account = account {
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
                        NotificationCenter.default.post(name: .init("showStartingBalanceFromRightColumn"), object: account.id)
                    } label: {
                        Label("Add Balance…", systemImage: "plus.circle")
                    }

                    if !adjustmentsList.isEmpty || !account.balanceSnapshots.isEmpty {
                        Button {
                            NotificationCenter.default.post(name: .init("showStartingBalanceFromRightColumn"), object: account.id)
                        } label: {
                            Label("Edit Starting Balance…", systemImage: "pencil.circle")
                        }
                    }
                }
            }

            Section(header: Text("Transactions")) {
                ForEach(rows) { row in
                    NavigationLink(destination: EditTransactionContainer(transactionID: row.id)) {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(row.payee).font(.body)
                                HStack(spacing: 8) {
                                    Text(row.date, style: .date)
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(format(amount: row.amount))
                                .foregroundStyle(row.amount < 0 ? .red : .primary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Transactions")
        .navigationBarBackButtonHidden(!isIPad)
        .toolbar {
            if !isIPad {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                }
            }
        }
        .onAppear {
            AMLogging.log("AccountTransactionsListView appear accountID=\(accountID)", component: "AccountTransactionsListView")
            DispatchQueue.main.async {
                AMLogging.log("AccountTransactionsListView post-appear tick (0ms) accountID=\(accountID)", component: "AccountTransactionsListView")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                AMLogging.log("AccountTransactionsListView post-appear tick (100ms) accountID=\(accountID)", component: "AccountTransactionsListView")
            }
        }
        .task(id: accountID) {
            AMLogging.log("AccountTransactionsListView task loadRows accountID=\(accountID)", component: "AccountTransactionsListView")
            await loadAccount()
            await loadRows()
        }
        .onReceive(NotificationCenter.default.publisher(for: .transactionsDidChange)) { _ in
            AMLogging.log("AccountTransactionsListView received transactionsDidChange accountID=\(accountID)", component: "AccountTransactionsListView")
            Task { await loadRows() }
        }
    }

    private func format(amount: Decimal) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = "USD"
        return nf.string(from: NSDecimalNumber(decimal: amount)) ?? "\(amount)"
    }
    
    private func loadAccount() async {
        let t0 = Date()
        let container = modelContext.container
        let bg = ModelContext(container)
        bg.autosaveEnabled = false

        do {
            let id = accountID
            let predicate = #Predicate<Account> { acct in acct.id == id }
            let descriptor = FetchDescriptor<Account>(predicate: predicate)
            let fetched = try bg.fetch(descriptor)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            AMLogging.log("loadAccount fetched=\(fetched.count) in \(ms)ms for accountID=\(id)", component: "AccountTransactionsListView")
            await MainActor.run { self.account = fetched.first }
        } catch {
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            AMLogging.error("loadAccount failed after \(ms)ms for accountID=\(accountID): \(error.localizedDescription)", component: "AccountTransactionsListView")
            await MainActor.run { self.account = nil }
        }
    }

    private func loadRows() async {
        let t0 = Date()
        let container = modelContext.container
        let bg = ModelContext(container)
        bg.autosaveEnabled = false

        do {
            let id = accountID
            let predicate = #Predicate<Transaction> { tx in tx.account?.id == id }
            var descriptor = FetchDescriptor<Transaction>(predicate: predicate)
            descriptor.sortBy = [SortDescriptor(\Transaction.datePosted, order: .reverse)]
            let fetched = try bg.fetch(descriptor)
            let mapped = fetched.map { TxRow(id: $0.id, payee: $0.payee, date: $0.datePosted, amount: $0.amount) }
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            AMLogging.log("loadRows fetched=\(fetched.count) mapped=\(mapped.count) in \(ms)ms for accountID=\(id)", component: "AccountTransactionsListView")
            await MainActor.run { self.rows = mapped }
        } catch {
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            AMLogging.error("loadRows failed after \(ms)ms for accountID=\(accountID): \(error.localizedDescription)", component: "AccountTransactionsListView")
            await MainActor.run { self.rows = [] }
        }
    }

    private func sortedSnapshots(for account: Account) -> [BalanceSnapshot] {
        account.balanceSnapshots.sorted { $0.asOfDate > $1.asOfDate }
    }

    private func adjustments(for account: Account) -> [Transaction] {
        account.transactions.filter { $0.kind == .adjustment }.sorted { $0.datePosted > $1.datePosted }
    }

    private func formatAPR(_ apr: Decimal, scale: Int? = nil) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .percent
        if let s = scale { nf.minimumFractionDigits = s; nf.maximumFractionDigits = s } else { nf.minimumFractionDigits = 2; nf.maximumFractionDigits = 3 }
        return nf.string(from: NSDecimalNumber(decimal: apr)) ?? "\(apr)"
    }
}
private struct EditTransactionContainer: View {
    let transactionID: UUID
    @Query private var txs: [Transaction]

    init(transactionID: UUID) {
        self.transactionID = transactionID
        _txs = Query(filter: #Predicate<Transaction> { $0.id == transactionID }, sort: [])
    }

    var body: some View {
        if let tx = txs.first {
            EditTransactionView(transaction: tx)
        } else {
            ContentUnavailableView("Transaction not found", systemImage: "exclamationmark.triangle")
        }
    }
}

