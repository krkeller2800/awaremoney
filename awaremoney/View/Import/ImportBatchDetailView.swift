import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ImportBatchDetailView: View {
    let batchID: UUID

    init(batchID: UUID) {
        self.batchID = batchID
    }

    init(batch: ImportBatch) {
        self.batchID = batch.id
        self._batch = State(initialValue: batch)
    }

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

    @State private var showMappingSheet = false
    @State private var pendingCSVHeaders: [String] = []
    @State private var pendingCSVRows: [[String]] = []

    var body: some View {
        Group {
            if let batch {
                listContent(for: batch)
                    .listStyle(.insetGrouped)
                    .id(batchID)
                    .navigationTitle("Update Transactions")
                    .onAppear { AMLogging.log("ImportBatchDetailView appear batchID=\(batchID)", component: "ImportBatchDetailView") }
                    .task(id: batchID) { await load() }
                    .safeAreaInset(edge: .bottom) { bottomBar() }
                    .fileImporter(
                        isPresented: $isImporterPresented,
                        allowedContentTypes: [UTType.commaSeparatedText, .tabSeparatedText, .text, .plainText, .pdf],
                        allowsMultipleSelection: false
                    ) { result in
                        onFileImportResult(result)
                    }
                    .sheet(isPresented: $showConflictsSheet) {
                        conflictsSheetContent(for: batch)
                    }
                    .sheet(isPresented: $showMappingSheet) {
                        mappingSheetContent(for: batch)
                    }
                    .sheet(isPresented: $showPDFSheet) {
                        pdfSheetContent(for: batch)
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
                    .onReceive(NotificationCenter.default.publisher(for: .transactionsDidChange)) { _ in
                        AMLogging.log("ImportBatchDetailView received transactionsDidChange", component: "ImportBatchDetailView")
                        Task { await load() }
                    }
            } else {
                ProgressView().task { await load() }
            }
        }
    }

    @ViewBuilder private func listContent(for batch: ImportBatch) -> some View {
        List {
            batchSection(batch)
            transactionsSection()
            balancesSection(for: batch)
            holdingsSection()
        }
    }

    @ViewBuilder private func batchSection(_ batch: ImportBatch) -> some View {
        Section("Batch") {
            LabeledContent("Label", value: batch.label)
            if let pid = batch.parserId { LabeledContent("Parser", value: pid) }
            LabeledContent("Imported", value: batch.createdAt.formatted(date: .abbreviated, time: .shortened))
        }
    }

    @ViewBuilder private func transactionsSection() -> some View {
        if !transactions.isEmpty {
            Section("Transactions") {
                ForEach(transactions, id: \.id) { tx in
                    NavigationLink(destination: EditTransactionView(transaction: tx)) {
                        HStack(alignment: .firstTextBaseline) {
                            Toggle("", isOn: Binding(get: {
                                !(tx.isExcluded)
                            }, set: { newVal in
                                tx.isExcluded = !newVal
                                AMLogging.log("Transaction toggle changed id=\(tx.id) excluded=\(tx.isExcluded)", component: "ImportBatchDetailView")
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
    }

    @ViewBuilder private func balancesSection(for batch: ImportBatch) -> some View {
        if !balances.isEmpty {
            Section("Balances") {
                ForEach(balances.indices, id: \.self) { idx in
                    let snap = balances[idx]
                    HStack(alignment: .top) {
                        Toggle("", isOn: Binding(get: {
                            !(snap.isExcluded)
                        }, set: { newVal in
                            balances[idx].isExcluded = !newVal
                            AMLogging.log("BalanceSnapshot toggle changed id=\(balances[idx].id) excluded=\(balances[idx].isExcluded)", component: "ImportBatchDetailView")
                            balances[idx].isUserModified = true
                            try? modelContext.save()
                            NotificationCenter.default.post(name: .transactionsDidChange, object: nil)
                        }))
                        .labelsHidden()

                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 12) {
                                DatePicker("As of", selection: Binding(get: {
                                    balances[idx].asOfDate
                                }, set: { newDate in
                                    balances[idx].asOfDate = newDate
                                    AMLogging.log("BalanceSnapshot date changed id=\(balances[idx].id) newDate=\(newDate)", component: "ImportBatchDetailView")
                                    balances[idx].isUserModified = true
                                    try? modelContext.save()
                                }), displayedComponents: .date)
                                .labelsHidden()
                                Spacer()
                                TextField("0.00", text: Binding(get: {
                                    let nf = NumberFormatter()
                                    nf.numberStyle = .decimal
                                    nf.minimumFractionDigits = 0
                                    nf.maximumFractionDigits = 2
                                    return nf.string(from: NSDecimalNumber(decimal: balances[idx].balance)) ?? "\(balances[idx].balance)"
                                }, set: { newText in
                                    let cleaned = newText.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                                    if let dec = Decimal(string: cleaned) {
                                        balances[idx].balance = dec
                                        AMLogging.log("BalanceSnapshot amount changed id=\(balances[idx].id) newBalance=\(balances[idx].balance)", component: "ImportBatchDetailView")
                                        balances[idx].isUserModified = true
                                        try? modelContext.save()
                                    }
                                }))
                                .multilineTextAlignment(.trailing)
                                .keyboardType(.decimalPad)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            }
                            if let apr = balances[idx].interestRateAPR {
                                Text("APR: \(formatAPR(apr, scale: balances[idx].interestRateScale))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            AMLogging.log("Deleting BalanceSnapshot id=\(balances[idx].id)", component: "ImportBatchDetailView")
                            let toDelete = balances[idx]
                            modelContext.delete(toDelete)
                            balances.remove(at: idx)
                            try? modelContext.save()
                            NotificationCenter.default.post(name: .transactionsDidChange, object: nil)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
                Button {
                    AMLogging.log("Add Balance tapped (non-empty section) batchID=\(batch.id)", component: "ImportBatchDetailView")
                    let targetAccount: Account? = batch.balances.first?.account ?? batch.transactions.first?.account ?? batch.holdings.first?.account
                    if let acct = targetAccount {
                        let bs = BalanceSnapshot(asOfDate: Date(), balance: 0, interestRateAPR: nil, interestRateScale: nil, account: acct, importBatch: batch)
                        modelContext.insert(bs)
                        balances.insert(bs, at: 0)
                        try? modelContext.save()
                        NotificationCenter.default.post(name: .transactionsDidChange, object: nil)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle")
                        Text("Add Balance")
                    }
                }
            }
        } else {
            Section("Balances") {
                Text("No balances in this batch. Add one to anchor the account's value.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button {
                    AMLogging.log("Add Balance tapped (empty section) batchID=\(batch.id)", component: "ImportBatchDetailView")
                    let targetAccount: Account? = batch.transactions.first?.account ?? batch.holdings.first?.account
                    if let acct = targetAccount {
                        let bs = BalanceSnapshot(asOfDate: Date(), balance: 0, interestRateAPR: nil, interestRateScale: nil, account: acct, importBatch: batch)
                        modelContext.insert(bs)
                        balances.insert(bs, at: 0)
                        try? modelContext.save()
                        NotificationCenter.default.post(name: .transactionsDidChange, object: nil)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle")
                        Text("Add Balance")
                    }
                }
            }
        }
    }

    @ViewBuilder private func holdingsSection() -> some View {
        if !holdings.isEmpty {
            Section("Holdings") {
                ForEach(holdings, id: \.id) { hs in
                    HStack {
                        Toggle("", isOn: Binding(get: {
                            !(hs.isExcluded)
                        }, set: { newVal in
                            hs.isExcluded = !newVal
                            AMLogging.log("HoldingSnapshot toggle changed id=\(hs.id) excluded=\(hs.isExcluded)", component: "ImportBatchDetailView")
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

    @ViewBuilder private func bottomBar() -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Button {
                    AMLogging.log("View PDF tapped for batchID=\(batchID)", component: "ImportBatchDetailView")
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
                    AMLogging.log("Replace Batch tapped for batchID=\(batchID)", component: "ImportBatchDetailView")
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
        }
        .background(.regularMaterial)
    }

    @ViewBuilder private func pdfSheetContent(for batch: ImportBatch) -> some View {
        NavigationStack {
            if let url = resolvedPDFURL(for: batch) {
                PDFKitView(url: url)
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
        }
        .navigationTitle("View PDF")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { showPDFSheet = false }
            }
        }
    }

    private func resolvedPDFURL(for batch: ImportBatch) -> URL? {
        if let path = batch.sourceFileLocalPath, !path.isEmpty, FileManager.default.fileExists(atPath: path) {
            AMLogging.log("PDF preview using local path: \(path)", component: "ImportBatchDetailView")
            return URL(fileURLWithPath: path)
        }
        if batch.sourceFileName.lowercased().hasSuffix(".pdf"),
           let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let candidate = caches.appendingPathComponent(batch.sourceFileName)
            if FileManager.default.fileExists(atPath: candidate.path) {
                AMLogging.log("PDF preview using caches candidate: \(candidate.path)", component: "ImportBatchDetailView")
                return candidate
            } else {
                AMLogging.log("PDF preview missing for candidate: \(candidate.path)", component: "ImportBatchDetailView")
            }
        } else {
            AMLogging.log("PDF preview unavailable for file: \(batch.sourceFileName)", component: "ImportBatchDetailView")
        }
        return nil
    }

    @ViewBuilder private func conflictsSheetContent(for batch: ImportBatch) -> some View {
        if let staged = stagedForReplace {
            ConflictsReviewView(
                batchLabel: batch.label,
                conflicts: pendingConflicts,
                onResolve: { forceKeys in
                    AMLogging.log("Conflicts resolve requested with forced keys count=\(forceKeys.count)", component: "ImportBatchDetailView")
                    Task { @MainActor in
                        do {
                            let summary = try ImportViewModel.replaceBatch(
                                batch: batch,
                                with: staged,
                                context: modelContext,
                                forceUpdateTxKeys: forceKeys
                            )
                            AMLogging.log("Replace Batch (resolved) — tx(updated: \(summary.updatedTx), inserted: \(summary.insertedTx), deleted: \(summary.deletedTx))", component: "ImportBatchDetailView")
                            self.stagedForReplace = nil
                            self.pendingConflicts = []
                            await load()
                        } catch {
                            AMLogging.error("Replace after resolve failed: \(error.localizedDescription)", component: "ImportBatchDetailView")
                        }
                    }
                },
                onHardDelete: {
                    AMLogging.log("Hard delete requested from conflicts sheet for batchID=\(batch.id)", component: "ImportBatchDetailView")
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

    @ViewBuilder private func mappingSheetContent(for batch: ImportBatch) -> some View {
        CSVMappingSheet(
            headers: pendingCSVHeaders,
            onSave: { mapping in
                AMLogging.log("MappingSheet onSave invoked — headers=\(pendingCSVHeaders.count), rows=\(pendingCSVRows.count)", component: "ImportBatchDetailView")
                Task { @MainActor in
                    do {
                        modelContext.insert(mapping)
                        AMLogging.log("Using saved CSV mapping label=\(mapping.label ?? "(no label)")", component: "ImportBatchDetailView")
                        try modelContext.save()
                        let parser = GenericCSVParser(mapping: mapping)
                        var staged = try parser.parse(rows: pendingCSVRows, headers: pendingCSVHeaders)
                        AMLogging.log("GenericCSVParser parsed staged — tx=\(staged.transactions.count), balances=\(staged.balances.count), holdings=\(staged.holdings.count)", component: "ImportBatchDetailView")
                        staged.sourceFileName = batch.sourceFileName

                        let summary = try ImportViewModel.replaceBatch(batch: batch, with: staged, context: modelContext)
                        AMLogging.log("Replace Batch summary (mapped CSV) — tx(updated: \(summary.updatedTx), inserted: \(summary.insertedTx), deleted: \(summary.deletedTx)); balances(updated: \(summary.updatedBalances), inserted: \(summary.insertedBalances), deleted: \(summary.deletedBalances)); holdings(updated: \(summary.updatedHoldings), inserted: \(summary.insertedHoldings), deleted: \(summary.deletedHoldings))", component: "ImportBatchDetailView")
                        self.summaryMessage = "Replaced: tx updated \(summary.updatedTx), inserted \(summary.insertedTx), deleted \(summary.deletedTx)."
                        self.showSummaryAlert = true
                        AMLogging.log("Showing summary alert: \(self.summaryMessage)", component: "ImportBatchDetailView")
                        self.showMappingSheet = false
                        await load()
                    } catch {
                        AMLogging.log("CSV mapping parse failed — presenting mapping editor", component: "ImportBatchDetailView")
                        AMLogging.error("CSV mapping parse failed: \(error.localizedDescription)", component: "ImportBatchDetailView")
                        self.summaryMessage = "Failed to parse CSV with mapping: \(error.localizedDescription)"
                        self.showSummaryAlert = true
                        self.showMappingSheet = false
                    }
                }
            },
            onCancel: {
                AMLogging.log("MappingSheet canceled by user", component: "ImportBatchDetailView")
                showMappingSheet = false
            }
        )
    }

    private func onFileImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            AMLogging.log("fileImporter success — urls=\(urls)", component: "ImportBatchDetailView")
            guard let url = urls.first else { return }
            Task { @MainActor in await replaceBatch(from: url) }
        case .failure(let error):
            AMLogging.error("fileImporter failed — \(error.localizedDescription)", component: "ImportBatchDetailView")
        }
    }

    @MainActor private func load() async {
        do {
            let batchDesc = FetchDescriptor<ImportBatch>(predicate: #Predicate { $0.id == batchID })
            let batches = try modelContext.fetch(batchDesc)
            let found = batches.first
            AMLogging.log("ImportBatchDetailView.load: fetch batch found=\(found != nil ? "yes" : "no") for id=\(batchID)", component: "ImportBatchDetailView")
            self.batch = found
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

            AMLogging.log("ImportBatchDetailView.load: tx=\(txs.count) balances=\(bals.count) holdings=\(holds.count)", component: "ImportBatchDetailView")
            self.transactions = txs
            self.balances = bals
            self.holdings = holds
        } catch {
            self.transactions = []
            self.balances = []
            self.holdings = []
        }
    }

    @MainActor
    private func deleteBatch() {
        guard let batch else { return }
        AMLogging.log("Hard delete initiated for batchID=\(batch.id) label=\(batch.label)", component: "ImportBatchDetailView")
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
        AMLogging.log("replaceBatch start — file=\(url.lastPathComponent) ext=\(url.pathExtension.lowercased())", component: "ImportBatchDetailView")
        var parsedRows: [[String]] = []
        var parsedHeaders: [String] = []
        let fileExtension = url.pathExtension.lowercased()
        // Security scoped access for Files app URLs
        let didStart = url.startAccessingSecurityScopedResource()
        AMLogging.log("replaceBatch security scope started=\(didStart) for file=\(url.path)", component: "ImportBatchDetailView")
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        do {
            // Decide parser pathway by extension; we will reuse ImportViewModel's existing parsers best-effort
            let rowsAndHeaders: ([[String]], [String])
            if fileExtension == "pdf" {
                // Prefer Summary mode for PDFs so we can capture balances and APR/interest details from statements
                rowsAndHeaders = try PDFStatementExtractor.parse(url: url)
                AMLogging.log("PDF extractor returned rows=\(rowsAndHeaders.0.count) headers=\(rowsAndHeaders.1)", component: "ImportBatchDetailView")
            } else {
                let data = try Data(contentsOf: url)
                rowsAndHeaders = try CSV.read(data: data)
                AMLogging.log("CSV read returned rows=\(rowsAndHeaders.0.count) headers=\(rowsAndHeaders.1)", component: "ImportBatchDetailView")
            }
            let (rows, headers) = rowsAndHeaders
            AMLogging.log("replaceBatch parsed — rows=\(rows.count) headers=\(headers)", component: "ImportBatchDetailView")

            // Attempt to find parser using default parsers first
            let parsers: [StatementParser] = ImportViewModel.defaultParsers()
            AMLogging.log("defaultParsers count=\(parsers.count)", component: "ImportBatchDetailView")
            
            let matching = parsers.filter { $0.canParse(headers: headers) }
            AMLogging.log("matching parsers: \(matching.map { String(describing: type(of: $0)) })", component: "ImportBatchDetailView")
            
            if let parser = matching.first {
                AMLogging.log("Using default parser: \(type(of: parser))", component: "ImportBatchDetailView")
                do {
                    var staged = try parser.parse(rows: rows, headers: headers)
                    staged.sourceFileName = url.lastPathComponent

                    // Maintain a local copy for PDF preview
                    if fileExtension == "pdf" {
                        let fm = FileManager.default
                        if let caches = try? fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true) {
                            let dest = caches.appendingPathComponent(url.lastPathComponent)
                            AMLogging.log("Caching PDF to: \(dest.path)", component: "ImportBatchDetailView")
                            try? fm.removeItem(at: dest)
                            if fm.fileExists(atPath: url.path) {
                                try? fm.copyItem(at: url, to: dest)
                                batch.sourceFileLocalPath = dest.path
                                AMLogging.log("Cached PDF copied; batch.sourceFileLocalPath updated", component: "ImportBatchDetailView")
                                try? modelContext.save()
                            }
                        }
                    } else {
                        if batch.sourceFileLocalPath != nil {
                            AMLogging.log("Clearing batch.sourceFileLocalPath (non-PDF import)", component: "ImportBatchDetailView")
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
                    AMLogging.log("Conflict check — existing tx map size=\(existingMap.count)", component: "ImportBatchDetailView")
                    for st in staged.transactions {
                        let key = st.hashKey
                        if let ex = existingMap[key], ex.isUserModified {
                            let differs = (ex.amount != st.amount) || (ex.datePosted != st.datePosted) || (ex.payee != st.payee) || (ex.memo ?? "") != (st.memo ?? "")
                            if differs {
                                conflicts.append(TxConflict(id: key, existing: ex, staged: st))
                            }
                        }
                    }
                    AMLogging.log("Conflict check complete — conflicts=\(conflicts.count)", component: "ImportBatchDetailView")
                    if !conflicts.isEmpty {
                        AMLogging.log("Presenting conflicts sheet for \(conflicts.count) transactions", component: "ImportBatchDetailView")
                        self.pendingConflicts = conflicts
                        self.stagedForReplace = staged
                        self.showConflictsSheet = true
                        return // wait for user resolution
                    }

                    // Apply replacement using ImportViewModel helper
                    let summary = try ImportViewModel.replaceBatch(batch: batch, with: staged, context: modelContext)
                    AMLogging.log("Replace Batch summary — tx(updated: \(summary.updatedTx), inserted: \(summary.insertedTx), deleted: \(summary.deletedTx)); balances(updated: \(summary.updatedBalances), inserted: \(summary.insertedBalances), deleted: \(summary.deletedBalances)); holdings(updated: \(summary.updatedHoldings), inserted: \(summary.insertedHoldings), deleted: \(summary.deletedHoldings))", component: "ImportBatchDetailView")
                    self.summaryMessage = "Replaced: tx updated \(summary.updatedTx), inserted \(summary.insertedTx), deleted \(summary.deletedTx)."
                    self.showSummaryAlert = true
                    AMLogging.log("Showing summary alert: \(self.summaryMessage)", component: "ImportBatchDetailView")
                    await load()
                    return
                } catch {
                    // If a CSV parse fails, fall back to mapping editor instead of showing an error
                    if fileExtension != "pdf" {
                        AMLogging.log("Default parser parse failed — presenting mapping editor (non-PDF)", component: "ImportBatchDetailView")
                        self.pendingCSVHeaders = parsedHeaders
                        self.pendingCSVRows = parsedRows
                        self.showMappingSheet = true
                        return
                    } else {
                        AMLogging.log("Default parser parse failed for PDF — will show error alert", component: "ImportBatchDetailView")
                        // For PDFs, keep existing error surfacing
                        AMLogging.error("Replace Batch (PDF) parse failed: \(error.localizedDescription)", component: "ImportBatchDetailView")
                        self.summaryMessage = error.localizedDescription
                        self.showSummaryAlert = true
                        return
                    }
                }
            }

            // No default parser found, try saved CSVColumnMapping
            AMLogging.log("No default parser matched — checking saved CSV mappings", component: "ImportBatchDetailView")
            let mappingsRequest: FetchDescriptor<CSVColumnMapping> = FetchDescriptor<CSVColumnMapping>(predicate: nil)
            let mappings = try modelContext.fetch(mappingsRequest)
            AMLogging.log("Saved mappings found: \(mappings.count)", component: "ImportBatchDetailView")
            if let mapping = mappings.first(where: { $0.matches(headers: headers) }) {
                AMLogging.log("Using saved mapping: \(mapping.label ?? "(no label)")", component: "ImportBatchDetailView")
                let parser = GenericCSVParser(mapping: mapping)
                do {
                    var staged = try parser.parse(rows: rows, headers: headers)
                    staged.sourceFileName = url.lastPathComponent

                    // Maintain a local copy for PDF preview
                    if fileExtension == "pdf" {
                        let fm = FileManager.default
                        if let caches = try? fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true) {
                            let dest = caches.appendingPathComponent(url.lastPathComponent)
                            AMLogging.log("Caching PDF to: \(dest.path)", component: "ImportBatchDetailView")
                            try? fm.removeItem(at: dest)
                            if fm.fileExists(atPath: url.path) {
                                try? fm.copyItem(at: url, to: dest)
                                batch.sourceFileLocalPath = dest.path
                                AMLogging.log("Cached PDF copied; batch.sourceFileLocalPath updated", component: "ImportBatchDetailView")
                                try? modelContext.save()
                            }
                        }
                    } else {
                        if batch.sourceFileLocalPath != nil {
                            AMLogging.log("Clearing batch.sourceFileLocalPath (non-PDF import)", component: "ImportBatchDetailView")
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
                    AMLogging.log("Conflict check — existing tx map size=\(existingMap.count)", component: "ImportBatchDetailView")
                    for st in staged.transactions {
                        let key = st.hashKey
                        if let ex = existingMap[key], ex.isUserModified {
                            let differs = (ex.amount != st.amount) || (ex.datePosted != st.datePosted) || (ex.payee != st.payee) || (ex.memo ?? "") != (st.memo ?? "")
                            if differs {
                                conflicts.append(TxConflict(id: key, existing: ex, staged: st))
                            }
                        }
                    }
                    AMLogging.log("Conflict check complete — conflicts=\(conflicts.count)", component: "ImportBatchDetailView")
                    if !conflicts.isEmpty {
                        AMLogging.log("Presenting conflicts sheet for \(conflicts.count) transactions", component: "ImportBatchDetailView")
                        self.pendingConflicts = conflicts
                        self.stagedForReplace = staged
                        self.showConflictsSheet = true
                        return // wait for user resolution
                    }

                    // Apply replacement using ImportViewModel helper
                    let summary = try ImportViewModel.replaceBatch(batch: batch, with: staged, context: modelContext)
                    AMLogging.log("Replace Batch summary (mapped CSV) — tx(updated: \(summary.updatedTx), inserted: \(summary.insertedTx), deleted: \(summary.deletedTx)); balances(updated: \(summary.updatedBalances), inserted: \(summary.insertedBalances), deleted: \(summary.deletedBalances)); holdings(updated: \(summary.updatedHoldings), inserted: \(summary.insertedHoldings), deleted: \(summary.deletedHoldings))", component: "ImportBatchDetailView")
                    self.summaryMessage = "Replaced: tx updated \(summary.updatedTx), inserted \(summary.insertedTx), deleted \(summary.deletedTx)."
                    self.showSummaryAlert = true
                    AMLogging.log("Showing summary alert: \(self.summaryMessage)", component: "ImportBatchDetailView")
                    await load()
                    return
                } catch {
                    // If a CSV parse fails even with a saved mapping, present the mapping editor for correction
                    if fileExtension != "pdf" {
                        AMLogging.log("Mapped CSV parse failed — presenting mapping editor", component: "ImportBatchDetailView")
                        self.pendingCSVHeaders = parsedHeaders
                        self.pendingCSVRows = parsedRows
                        self.showMappingSheet = true
                        return
                    } else {
                        AMLogging.log("Mapped CSV parse failed for PDF — will show error alert", component: "ImportBatchDetailView")
                        AMLogging.error("Replace Batch (PDF) mapped parse failed: \(error.localizedDescription)", component: "ImportBatchDetailView")
                        self.summaryMessage = error.localizedDescription
                        self.showSummaryAlert = true
                        return
                    }
                }
            }

            // No default parser and no mapping matched - require user mapping
            AMLogging.log("No parser or mapping matched — presenting mapping editor", component: "ImportBatchDetailView")
            self.pendingCSVHeaders = headers
            self.pendingCSVRows = rows
            self.showMappingSheet = true
        } catch {
            AMLogging.error("Replace Batch failed: \(error.localizedDescription)", component: "ImportBatchDetailView")
            if fileExtension != "pdf" && !parsedHeaders.isEmpty {
                AMLogging.log("Replace failed but CSV headers present — presenting mapping editor", component: "ImportBatchDetailView")
                // We have CSV headers/rows — offer mapping editor instead of an error
                self.pendingCSVHeaders = parsedHeaders
                self.pendingCSVRows = parsedRows
                self.showMappingSheet = true
            } else {
                AMLogging.log("Replace failed — showing error alert", component: "ImportBatchDetailView")
                self.summaryMessage = error.localizedDescription
                self.showSummaryAlert = true
            }
        }
    }
}

#Preview {
    Text("Preview requires model data")
}

