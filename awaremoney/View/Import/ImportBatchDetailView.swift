import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ImportBatchDetailView: View {
    let batchID: UUID
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteAlert = false

    @State private var batch: ImportBatch?
    @State private var transactions: [Transaction] = []
    @State private var balances: [BalanceSnapshot] = []
    @State private var holdings: [HoldingSnapshot] = []
    @State private var showReplaceAlert = false
    @State private var isImporterPresented = false
    @State private var stagedForReplace: StagedImport?
    @State private var showConflictsSheet = false
    @State private var pendingConflicts: [TxConflict] = []
    @State private var showSummaryAlert = false
    @State private var summaryMessage: String = ""
    @State private var showPDFSheet = false

    var body: some View {
        Group {
            if let batch {
                List {
                    Section("Batch") {
                        LabeledContent("Label", value: batch.label)
                        if let pid = batch.parserId { LabeledContent("Parser", value: pid) }
                        LabeledContent("Imported", value: batch.createdAt.formatted(date: .abbreviated, time: .shortened))
                    }

                    if !transactions.isEmpty {
                        Section("Transactions") {
                            ForEach(transactions, id: \.id) { tx in
                                NavigationLink(destination: EditTransactionView(transaction: tx)) {
                                    HStack(alignment: .firstTextBaseline) {
                                        Toggle("", isOn: Binding(get: {
                                            !(tx.isExcluded)
                                        }, set: { newVal in
                                            tx.isExcluded = !newVal
                                            tx.isUserModified = true
                                            try? modelContext.save()
                                            NotificationCenter.default.post(name: .transactionsDidChange, object: nil)
                                        }))
                                        .labelsHidden()

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(tx.payee)
                                            HStack(spacing: 6) {
                                                if let acct = tx.account { Text(acct.name).font(.caption).foregroundStyle(.secondary) }
                                                Text(tx.datePosted, style: .date).font(.caption).foregroundStyle(.secondary)
                                            }
                                        }
                                        Spacer()
                                        Text(format(amount: tx.amount)).foregroundStyle(tx.amount < 0 ? .red : .primary)
                                    }
                                }
                            }
                        }
                    }

                    if !balances.isEmpty {
                        Section("Balances") {
                            ForEach(balances, id: \.id) { snap in
                                HStack {
                                    Toggle("", isOn: Binding(get: {
                                        !(snap.isExcluded)
                                    }, set: { newVal in
                                        snap.isExcluded = !newVal
                                        snap.isUserModified = true
                                        try? modelContext.save()
                                        NotificationCenter.default.post(name: .transactionsDidChange, object: nil)
                                    }))
                                    .labelsHidden()
                                    Text(snap.asOfDate, style: .date)
                                    Spacer()
                                    if let apr = snap.interestRateAPR {
                                        Text("APR: \(formatAPR(apr, scale: snap.interestRateScale))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(format(amount: snap.balance))
                                }
                            }
                        }
                    }

                    if !holdings.isEmpty {
                        Section("Holdings") {
                            ForEach(holdings, id: \.id) { hs in
                                HStack {
                                    Toggle("", isOn: Binding(get: {
                                        !(hs.isExcluded)
                                    }, set: { newVal in
                                        hs.isExcluded = !newVal
                                        hs.isUserModified = true
                                        try? modelContext.save()
                                    }))
                                    .labelsHidden()
                                    Text(hs.security?.symbol ?? "(Symbol)")
                                    Spacer()
                                    if let mv = hs.marketValue { Text(format(amount: mv)) }
                                }
                            }
                        }
                    }
                }
                .navigationTitle("Update Transactions")
                .task { await load() }
                .safeAreaInset(edge: .bottom) {
                    VStack(spacing: 0) {
                        Divider()
                        HStack {
                            Button {
                                showPDFSheet = true
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: "doc.text.magnifyingglass")
                                    Text("View PDF").lineLimit(1).minimumScaleFactor(0.85).truncationMode(.tail).allowsTightening(true)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .frame(maxWidth: .infinity)

                            Button {
                                isImporterPresented = true
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                    Text("Replace Batch…").lineLimit(1).minimumScaleFactor(0.85).truncationMode(.tail).allowsTightening(true)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .frame(maxWidth: .infinity)
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 12)
                        .background(.regularMaterial)
                    }
                }
                .fileImporter(
                    isPresented: $isImporterPresented,
                    allowedContentTypes: [UTType.commaSeparatedText, .tabSeparatedText, .text, .plainText, .pdf],
                    allowsMultipleSelection: false
                ) { result in
                    switch result {
                    case .success(let urls):
                        guard let url = urls.first else { return }
                        Task { @MainActor in await replaceBatch(from: url) }
                    case .failure:
                        break
                    }
                }
                .sheet(isPresented: $showConflictsSheet) {
                    if let staged = stagedForReplace {
                        ConflictsReviewView(
                            batchLabel: batch.label,
                            conflicts: pendingConflicts,
                            onResolve: { forceKeys in
                                Task { @MainActor in
                                    do {
                                        let summary = try ImportViewModel.replaceBatch(
                                            batch: batch,
                                            with: staged,
                                            context: modelContext,
                                            forceUpdateTxKeys: forceKeys
                                        )
                                        AMLogging.always("Replace Batch (resolved) — tx(updated: \(summary.updatedTx), inserted: \(summary.insertedTx), deleted: \(summary.deletedTx))", component: "ImportBatchDetailView")
                                        self.stagedForReplace = nil
                                        self.pendingConflicts = []
                                        await load()
                                    } catch {
                                        AMLogging.error("Replace after resolve failed: \(error.localizedDescription)", component: "ImportBatchDetailView")
                                    }
                                }
                            },
                            onHardDelete: {
                                Task { @MainActor in
                                    do {
                                        try ImportViewModel.hardDelete(batch: batch, context: modelContext)
                                        self.showConflictsSheet = false
                                    } catch {
                                        AMLogging.error("Hard delete failed: \(error.localizedDescription)", component: "ImportBatchDetailView")
                                    }
                                }
                            }
                        )
                    } else {
                        NavigationStack { Text("Preparing conflicts…") }
                    }
                }
                .sheet(isPresented: $showPDFSheet) {
                    NavigationStack {
                        Group {
                            if let path = batch.sourceFileLocalPath, !path.isEmpty, FileManager.default.fileExists(atPath: path) {
                                PDFKitView(url: URL(fileURLWithPath: path))
                                    .ignoresSafeArea()
                            } else if batch.sourceFileName.lowercased().hasSuffix(".pdf"),
                                      let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
                                let candidate = caches.appendingPathComponent(batch.sourceFileName)
                                if FileManager.default.fileExists(atPath: candidate.path) {
                                    PDFKitView(url: candidate)
                                        .ignoresSafeArea()
                                } else {
                                    VStack {
                                        Text("File: \(batch.sourceFileName)")
                                            .font(.subheadline)
                                        ContentUnavailableView(
                                            "PDF Viewer",
                                            systemImage: "doc.richtext",
                                            description: Text("Original PDF preview isn't available yet.")
                                        )
                                    }
                                    .padding()
                                }
                            } else {
                                VStack {
                                    Text("File: \(batch.sourceFileName)")
                                        .font(.subheadline)
                                    ContentUnavailableView(
                                        "PDF Viewer",
                                        systemImage: "doc.richtext",
                                        description: Text("Original PDF preview isn't available yet.")
                                    )
                                }
                                .padding()
                            }
                        }
                    }
                    .navigationTitle("View PDF")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showPDFSheet = false }
                        }
                    }
                }
                .alert("Replace Batch", isPresented: $showSummaryAlert) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(summaryMessage)
                }
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(role: .destructive) {
                            showDeleteAlert = true
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
                .alert("Delete Batch?", isPresented: $showDeleteAlert) {
                    Button("Delete", role: .destructive) {
                        deleteBatch()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This will permanently delete this batch and all associated transactions, balances, and holdings.")
                }
                .onReceive(NotificationCenter.default.publisher(for: .transactionsDidChange)) { _ in Task { await load() } }
            } else {
                ProgressView().task { await load() }
            }
        }
    }

    @Sendable private func load() async {
        do {
            let batchDesc = FetchDescriptor<ImportBatch>(predicate: #Predicate { $0.id == batchID })
            let batches = try modelContext.fetch(batchDesc)
            let found = batches.first
            await MainActor.run { self.batch = found }
            guard found != nil else { return }

            // Fetch related items
            let txPred = #Predicate<Transaction> { $0.importBatch?.id == batchID }
            var txDesc = FetchDescriptor<Transaction>(predicate: txPred)
            txDesc.sortBy = [SortDescriptor(\Transaction.datePosted, order: .reverse)]
            let txs = try modelContext.fetch(txDesc)

            let balPred = #Predicate<BalanceSnapshot> { $0.importBatch?.id == batchID }
            var balDesc = FetchDescriptor<BalanceSnapshot>(predicate: balPred)
            balDesc.sortBy = [SortDescriptor(\BalanceSnapshot.asOfDate, order: .reverse)]
            let bals = try modelContext.fetch(balDesc)

            let holdPred = #Predicate<HoldingSnapshot> { $0.importBatch?.id == batchID }
            let holdDesc = FetchDescriptor<HoldingSnapshot>(predicate: holdPred)
            let holds = try modelContext.fetch(holdDesc)

            await MainActor.run {
                self.transactions = txs
                self.balances = bals
                self.holdings = holds
            }
        } catch {
            await MainActor.run {
                self.transactions = []
                self.balances = []
                self.holdings = []
            }
        }
    }

    @MainActor
    private func deleteBatch() {
        guard let batch else { return }
        do {
            // Clear lists immediately to prevent the UI from touching deleted objects
            self.transactions = []
            self.balances = []
            self.holdings = []
            self.batch = nil

            try ImportViewModel.hardDelete(batch: batch, context: modelContext)
            dismiss()
        } catch {
            AMLogging.error("Hard delete failed: \(error.localizedDescription)", component: "ImportBatchDetailView")
        }
    }

    private func format(amount: Decimal) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = "USD"
        return nf.string(from: NSDecimalNumber(decimal: amount)) ?? "\(amount)"
    }

    private func formatAPR(_ apr: Decimal, scale: Int? = nil) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .percent
        if let s = scale { nf.minimumFractionDigits = s; nf.maximumFractionDigits = s }
        else { nf.minimumFractionDigits = 2; nf.maximumFractionDigits = 3 }
        return nf.string(from: NSDecimalNumber(decimal: apr)) ?? "\(apr)"
    }

    @MainActor
    private func replaceBatch(from url: URL) async {
        guard let batch else { return }
        // Security scoped access for Files app URLs
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        do {
            // Decide parser pathway by extension; we will reuse ImportViewModel's existing parsers best-effort
            let ext = url.pathExtension.lowercased()
            let rowsAndHeaders: ([[String]], [String])
            if ext == "pdf" {
                rowsAndHeaders = try PDFStatementExtractor.parse(url: url)
            } else {
                let data = try Data(contentsOf: url)
                rowsAndHeaders = try CSV.read(data: data)
            }
            let (rows, headers) = rowsAndHeaders

            // Build a lightweight parser list reusing the same types used in ImportFlow
            let parsers: [StatementParser] = ImportViewModel.defaultParsers()

            guard let parser = parsers.first(where: { $0.canParse(headers: headers) }) else {
                self.summaryMessage = "We couldn't recognize this file's format. Try exporting a CSV or PDF statement."
                self.showSummaryAlert = true
                return
            }
            var staged = try parser.parse(rows: rows, headers: headers)
            staged.sourceFileName = url.lastPathComponent

            // Maintain a local copy for PDF preview
            if ext == "pdf" {
                let fm = FileManager.default
                if let caches = try? fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true) {
                    let dest = caches.appendingPathComponent(url.lastPathComponent)
                    try? fm.removeItem(at: dest)
                    if fm.fileExists(atPath: url.path) {
                        try? fm.copyItem(at: url, to: dest)
                        batch.sourceFileLocalPath = dest.path
                        try? modelContext.save()
                    }
                }
            } else {
                if batch.sourceFileLocalPath != nil {
                    batch.sourceFileLocalPath = nil
                    try? modelContext.save()
                }
            }

            // Conflict detection (transactions): user-modified items whose staged values differ
            var conflicts: [TxConflict] = []
            let existingMap: [String: Transaction] = (self.batch?.transactions ?? []).reduce(into: [:]) { acc, tx in
                let key = tx.importHashKey ?? tx.hashKey
                acc[key] = tx
            }
            for st in staged.transactions {
                let key = st.hashKey
                if let ex = existingMap[key], ex.isUserModified {
                    let differs = (ex.amount != st.amount) || (ex.datePosted != st.datePosted) || (ex.payee != st.payee) || (ex.memo ?? "") != (st.memo ?? "")
                    if differs {
                        conflicts.append(TxConflict(id: key, existing: ex, staged: st))
                    }
                }
            }
            if !conflicts.isEmpty {
                self.pendingConflicts = conflicts
                self.stagedForReplace = staged
                self.showConflictsSheet = true
                return // wait for user resolution
            }

            // Apply replacement using ImportViewModel helper
            let summary = try ImportViewModel.replaceBatch(batch: batch, with: staged, context: modelContext)
            AMLogging.always("Replace Batch summary — tx(updated: \(summary.updatedTx), inserted: \(summary.insertedTx), deleted: \(summary.deletedTx)); balances(updated: \(summary.updatedBalances), inserted: \(summary.insertedBalances), deleted: \(summary.deletedBalances)); holdings(updated: \(summary.updatedHoldings), inserted: \(summary.insertedHoldings), deleted: \(summary.deletedHoldings))", component: "ImportBatchDetailView")
            self.summaryMessage = "Replaced: tx updated \(summary.updatedTx), inserted \(summary.insertedTx), deleted \(summary.deletedTx)."
            self.showSummaryAlert = true
            await load()
        } catch {
            AMLogging.error("Replace Batch failed: \(error.localizedDescription)", component: "ImportBatchDetailView")
            self.summaryMessage = error.localizedDescription
            self.showSummaryAlert = true
        }
    }
}

#Preview {
    Text("Preview requires model data")
}

