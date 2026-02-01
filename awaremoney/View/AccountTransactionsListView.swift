import SwiftUI
import SwiftData

struct AccountTransactionsListView: View {
    let accountID: UUID
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var rows: [TxRow] = []
    struct TxRow: Identifiable { let id: UUID; let payee: String; let date: Date; let amount: Decimal }

    init(accountID: UUID) {
        self.accountID = accountID
        AMLogging.always("AccountTransactionsListView init accountID=\(accountID)", component: "AccountTransactionsListView")
    }

    // Convenience for existing call sites that pass an Account
    init(account: Account) {
        self.init(accountID: account.id)
    }

    var body: some View {
        List {
            ForEach(rows) { row in
                NavigationLink(value: row.id) {
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
        .navigationTitle("Transactions")
        .onAppear {
            AMLogging.always("AccountTransactionsListView appear accountID=\(accountID)", component: "AccountTransactionsListView")
            DispatchQueue.main.async {
                AMLogging.always("AccountTransactionsListView post-appear tick (0ms) accountID=\(accountID)", component: "AccountTransactionsListView")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                AMLogging.always("AccountTransactionsListView post-appear tick (100ms) accountID=\(accountID)", component: "AccountTransactionsListView")
            }
        }
        .navigationDestination(for: UUID.self) { txID in
            EditTransactionContainer(transactionID: txID)
        }
        .task {
            AMLogging.always("AccountTransactionsListView task loadRows accountID=\(accountID)", component: "AccountTransactionsListView")
            await loadRows()
        }
        .onReceive(NotificationCenter.default.publisher(for: .transactionsDidChange)) { _ in
            AMLogging.always("AccountTransactionsListView received transactionsDidChange accountID=\(accountID)", component: "AccountTransactionsListView")
            Task { await loadRows() }
        }
    }

    private func format(amount: Decimal) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = "USD"
        return nf.string(from: NSDecimalNumber(decimal: amount)) ?? "\(amount)"
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
            AMLogging.always("loadRows fetched=\(fetched.count) mapped=\(mapped.count) in \(ms)ms for accountID=\(id)", component: "AccountTransactionsListView")
            await MainActor.run { self.rows = mapped }
        } catch {
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            AMLogging.error("loadRows failed after \(ms)ms for accountID=\(accountID): \(error.localizedDescription)", component: "AccountTransactionsListView")
            await MainActor.run { self.rows = [] }
        }
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

