import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import PDFKit
#if canImport(UIKit)
import UIKit
#endif

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
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var isRegularWidth: Bool { horizontalSizeClass == .regular }
    private var isIPad: Bool {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad
        #else
        return false
        #endif
    }
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
    @State private var inlinePDFURL: URL? = nil

    @State private var showMappingSheet = false
    @State private var pendingCSVHeaders: [String] = []
    @State private var pendingCSVRows: [[String]] = []

    @FocusState private var focusedField: FocusedField?

    private var isEditing: Bool { focusedField != nil }

    private enum FocusedField: Hashable {
        case balanceAmount(UUID)
    }

    // Focus navigation scaffolding (unified editing accessory support)
    private var focusOrder: [FocusedField] {
        // Order balance amount fields top-to-bottom
        balances.map { .balanceAmount($0.id) }
    }

    private var canGoPrevious: Bool {
        guard let focusedField, let i = focusOrder.firstIndex(of: focusedField) else { return false }
        return i > 0
    }

    private var canGoNext: Bool {
        guard let focusedField, let i = focusOrder.firstIndex(of: focusedField) else { return false }
        return i < focusOrder.count - 1
    }

    private func moveFocus(_ delta: Int) {
        let order = focusOrder
        guard !order.isEmpty else { return }
        if let current = focusedField, let idx = order.firstIndex(of: current) {
            let nextIdx = (idx + delta + order.count) % order.count
            focusedField = order[nextIdx]
        } else {
            focusedField = order.first
        }
    }

    var body: some View {
        Group {
            if let batch {
                Group {
                    if isRegularWidth {
                        VStack(spacing: 12) {
                            glanceableHeader(for: batch)

                            HStack(spacing: 0) {
                                // Left column: batch details (Batch/Balances/Holdings)
                                detailsList(for: batch)
                                    .padding(.vertical, 8)
                                    .containerRelativeFrame(.horizontal, count: 2, spacing: 0)
                                    .frame(maxHeight: .infinity)

                                // Right column: show PDF if available, otherwise transactions
                                Group {
                                    if let url = inlinePDFURL {
                                        PDFKitView(url: url)
                                    } else {
                                        transactionsList()
                                    }
                                }
                                .containerRelativeFrame(.horizontal, count: 2, spacing: 0)
                                .frame(maxHeight: .infinity)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .overlay(alignment: .center) {
                                Rectangle()
                                    .fill(.separator)
                                    .frame(width: 1)
                                    .frame(maxHeight: .infinity)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
//                        .contentMargins(.zero)
                    } else {
                        listContent(for: batch)
                            .listStyle(.insetGrouped)
                    }
                }
                .id(batchID)
                .navigationTitle("Update Transactions")
                .navigationBarBackButtonHidden(isIPad)
                .onAppear { AMLogging.log("ImportBatchDetailView appear batchID=\(batchID)", component: "ImportBatchDetailView") }
                .task(id: batchID) { await load() }
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
                #if os(iOS)
                .fullScreenCover(isPresented: $showPDFSheet) {
                    pdfSheetContent(for: batch)
                }
                #else
                .sheet(isPresented: $showPDFSheet) {
                    pdfSheetContent(for: batch)
                }
                #endif
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
        .safeAreaInset(edge: .bottom) {
            Group {
                if isEditing {
                    EditingAccessoryBar(
                        canGoPrevious: canGoPrevious,
                        canGoNext: canGoNext,
                        onPrevious: { moveFocus(-1) },
                        onNext: { moveFocus(1) },
                        onDone: { commitAndDismissKeyboard() }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if batch != nil {
                    bottomBar()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    EmptyView().frame(height: 0)
                }
            }
            .animation(.snappy, value: isEditing)
        }
    }

    @ViewBuilder private func listContent(for batch: ImportBatch) -> some View {
        List {
            batchSection(batch)
            transactionsSection()
            balancesSection(for: batch)
            holdingsSection()
        }
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder private func detailsList(for batch: ImportBatch) -> some View {
        List {
            batchSection(batch)
            balancesSection(for: batch)
            holdingsSection()
        }
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.interactively)
        // Mirror AccountDetailView’s sizing behavior to preserve grouped rounded tiles
        .frame(maxWidth: isRegularWidth ? .infinity : 760, alignment: .center)
        .padding(.horizontal, isRegularWidth ? 0 : 16)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder private func transactionsList() -> some View {
        List {
            transactionsSection()
        }
        .listStyle(.insetGrouped)
//        .contentMargins(.zero, for: .scrollContent)
//        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        .scrollDismissesKeyboard(.interactively)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func glanceableHeader(for batch: ImportBatch) -> some View {
        // Compute simple metrics for quick glance
        let includedTxCount = transactions.filter { !$0.isExcluded }.count
        let balanceCount = balances.filter { !$0.isExcluded }.count
        let holdingCount = holdings.count
        let latestBalance = balances.first
        let latestBalanceText: String = {
            if let b = latestBalance { return format(amount: b.balance) } else { return "None" }
        }()
        let latestBalanceDateText: String? = {
            if let b = latestBalance {
                let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .none
                return df.string(from: b.asOfDate)
            }
            return nil
        }()
        let aprText: String? = {
            if let apr = latestBalance?.interestRateAPR { return formatAPR(apr, scale: latestBalance?.interestRateScale) }
            return nil
        }()

        func cell(title: String, value: String, sub: String? = nil, valueColor: Color? = nil) -> some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(value)
                    .font(.title3).bold().monospacedDigit()
                    .foregroundStyle(valueColor ?? .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(sub ?? " ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }

        return VStack(alignment: .center, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                GridRow {
                    cell(title: "Imported", value: batch.createdAt.formatted(date: .abbreviated, time: .shortened))
                    cell(title: "Transactions", value: "\(includedTxCount)")
                    cell(title: "Balances", value: "\(balanceCount)")
                    if holdingCount > 0 { cell(title: "Holdings", value: "\(holdingCount)") }
                    cell(title: "Latest Balance", value: latestBalanceText, sub: latestBalanceDateText)
                    if let apr = aprText { cell(title: "APR", value: apr) }
                }
            }
            .frame(maxWidth: 640, alignment: .center)
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.separator, lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity, alignment: .center)
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
                ForEach(balances, id: \.id) { snap in
                    HStack(alignment: .top) {
                        Toggle("", isOn: Binding(get: {
                            !(snap.isExcluded)
                        }, set: { newVal in
                            snap.isExcluded = !newVal
                            AMLogging.log("BalanceSnapshot toggle changed id=\(snap.id) excluded=\(snap.isExcluded)", component: "ImportBatchDetailView")
                            snap.isUserModified = true
                            try? modelContext.save()
                            NotificationCenter.default.post(name: .transactionsDidChange, object: nil)
                        }))
                        .labelsHidden()

                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 2) {
                                DatePicker("As of", selection: Binding(get: {
                                    snap.asOfDate
                                }, set: { newDate in
                                    snap.asOfDate = newDate
                                    AMLogging.log("BalanceSnapshot date changed id=\(snap.id) newDate=\(newDate)", component: "ImportBatchDetailView")
                                    snap.isUserModified = true
                                    try? modelContext.save()
                                }), displayedComponents: .date)
                                .labelsHidden()
                                Spacer()
                                TextField("0.00", text: Binding(get: {
                                    let nf = NumberFormatter()
                                    nf.numberStyle = .currency
                                    nf.currencyCode = settings.currencyCode
                                    return nf.string(from: NSDecimalNumber(decimal: snap.balance)) ?? "\(snap.balance)"
                                }, set: { newText in
                                    let cleaned = newText.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                                    if let dec = Decimal(string: cleaned) {
                                        snap.balance = dec
                                        AMLogging.log("BalanceSnapshot amount changed id=\(snap.id) newBalance=\(snap.balance)", component: "ImportBatchDetailView")
                                        snap.isUserModified = true
                                        try? modelContext.save()
                                    }
                                }))
                                .multilineTextAlignment(.trailing)
                                .keyboardType(.decimalPad)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($focusedField, equals: .balanceAmount(snap.id))
                                .submitLabel(.done)
                                .onSubmit {
                                    commitAndDismissKeyboard()
                                }
                            #if canImport(UIKit)
                                .selectAllOnFocus()
                                .onTapGesture {
                                    // Ensure select-all even if already focused
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                        UIApplication.shared.sendAction(#selector(UIResponder.selectAll(_:)), to: nil, from: nil, for: nil)
                                    }
                                }
                            #endif

                                // Add this tappable pencil to focus the amount field
                                Button {
                                    focusedField = .balanceAmount(snap.id)
                                    // Optional: select-all shortly after focusing to match your tap behavior
                                    #if canImport(UIKit)
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                        UIApplication.shared.sendAction(#selector(UIResponder.selectAll(_:)), to: nil, from: nil, for: nil)
                                    }
                                    #endif
                                } label: {
                                    Image(systemName: "pencil")
                                        .imageScale(.small)
                                        .foregroundStyle(.secondary)
                                        .padding(.leading, 6)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Edit amount")
                            }
                            if let apr = snap.interestRateAPR {
                                Text("APR: \(formatAPR(apr, scale: snap.interestRateScale))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            AMLogging.log("Deleting BalanceSnapshot id=\(snap.id)", component: "ImportBatchDetailView")
                            let toDelete = snap
                            modelContext.delete(toDelete)
                            balances.removeAll { $0.id == toDelete.id }
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
//            Divider()
            HStack {
                if !isIPad {
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
                }

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
//        .background(.regularMaterial)
    }

    // MARK: - PDF caching helpers
    private func perBatchPreviewDirectory(for batch: ImportBatch) -> URL? {
        let fm = FileManager.default
        if let caches = try? fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true) {
            return caches.appendingPathComponent("StatementPreviews", isDirectory: true)
                .appendingPathComponent(batch.id.uuidString, isDirectory: true)
        }
        return nil
    }

    private func cachePDF(for batch: ImportBatch, from originalURL: URL) -> URL? {
        guard let dir = perBatchPreviewDirectory(for: batch) else { return nil }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent(originalURL.lastPathComponent)
            // Remove any existing file at the destination to avoid stale previews
            try? fm.removeItem(at: dest)
            if fm.fileExists(atPath: originalURL.path) {
                try fm.copyItem(at: originalURL, to: dest)
                AMLogging.log("Cached PDF copied to per-batch path: \(dest.path)", component: "ImportBatchDetailView")
                return dest
            } else {
                AMLogging.log("Original picked PDF path does not exist at \(originalURL.path)", component: "ImportBatchDetailView")
            }
        } catch {
            AMLogging.error("Failed to prepare per-batch cache directory or copy PDF: \(error.localizedDescription)", component: "ImportBatchDetailView")
        }
        return nil
    }

    private func migrateLegacyPDFCacheIfNeeded(for batch: ImportBatch) {
        // If we already have a valid per-batch path, nothing to do
        if let path = batch.sourceFileLocalPath, !path.isEmpty, FileManager.default.fileExists(atPath: path) {
            return
        }
        // Only attempt migration for .pdf source filenames
        let lower = batch.sourceFileName.lowercased()
        guard lower.hasSuffix(".pdf") else { return }
        // Legacy fallback location was Caches/<sourceFileName>
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let legacy = caches.appendingPathComponent(batch.sourceFileName)
            if FileManager.default.fileExists(atPath: legacy.path) {
                AMLogging.log("Migrating legacy cached PDF for batchID=\(batch.id) from legacy=\(legacy.path)", component: "ImportBatchDetailView")
                if let newURL = cachePDF(for: batch, from: legacy) {
                    batch.sourceFileLocalPath = newURL.path
                    try? modelContext.save()
                    // Best-effort cleanup of legacy file to prevent future confusion
                    try? FileManager.default.removeItem(at: legacy)
                    AMLogging.log("Migration complete; updated sourceFileLocalPath and removed legacy file", component: "ImportBatchDetailView")
                }
            }
        }
    }

    private func resolvedPDFURL(for batch: ImportBatch) -> URL? {
        let fm = FileManager.default
        // 1) Preferred: stored per-batch local path
        if let path = batch.sourceFileLocalPath, !path.isEmpty, fm.fileExists(atPath: path) {
            AMLogging.log("PDF preview using per-batch local path: \(path)", component: "ImportBatchDetailView")
            return URL(fileURLWithPath: path)
        }
        // 2) Try any file in the per-batch preview directory
        if let dir = perBatchPreviewDirectory(for: batch) {
            if let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil), let first = items.first {
                AMLogging.log("PDF preview discovered per-batch file: \(first.path)", component: "ImportBatchDetailView")
                batch.sourceFileLocalPath = first.path
                try? modelContext.save()
                return first
            }
        }
        // 3) Legacy fallback: Caches/<sourceFileName>
        if let caches = try? fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true) {
            let legacy = caches.appendingPathComponent(batch.sourceFileName)
            if fm.fileExists(atPath: legacy.path) {
                AMLogging.log("PDF preview using legacy cached file: \(legacy.path)", component: "ImportBatchDetailView")
                // Attempt to migrate into per-batch cache for future reliability
                if let newURL = cachePDF(for: batch, from: legacy) {
                    batch.sourceFileLocalPath = newURL.path
                    try? modelContext.save()
                    return newURL
                } else {
                    return legacy
                }
            }
        }
        AMLogging.log("PDF preview unavailable — missing or invalid local path and no legacy cache found for: \(batch.sourceFileName)", component: "ImportBatchDetailView")
        return nil
    }

    @ViewBuilder private func pdfSheetContent(for batch: ImportBatch) -> some View {
        NavigationStack {
            if let url = resolvedPDFURL(for: batch) {
                ZStack(alignment: .topTrailing) {
                    PDFKitView(url: url)
                        .ignoresSafeArea()
                    DismissOverlay()
                        .padding(.top, 12)
                        .padding(.trailing, 12)
                }
            } else {
                ZStack(alignment: .topTrailing) {
                    Text("File: \(batch.sourceFileName)")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .center)
                    ContentUnavailableView(
                        "PDF Viewer",
                        systemImage: "doc.richtext",
                        description: Text("Original PDF preview isn't available yet.")
                    )
                    .ignoresSafeArea()
                    DismissOverlay()
                        .padding(.top, 12)
                        .padding(.trailing, 12)
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
        NavigationStack {
            CSVMappingEditorView(
                mapping: CSVColumnMapping(label: "New Mapping", mappings: [:]),
                headers: pendingCSVHeaders,
                sampleRows: pendingCSVRows,
                onSaveWithOptions: { mapping, opts in
                    AMLogging.log("MappingEditor onSaveWithOptions — headers=\(pendingCSVHeaders.count), rows=\(pendingCSVRows.count) opts(delim=\(opts.delimiter), header=\(opts.hasHeaderRow), skipEmpty=\(opts.skipEmptyLines))", component: "ImportBatchDetailView")
                    Task { @MainActor in
                        do {
                            // Persist mapping
                            modelContext.insert(mapping)
                            try modelContext.save()

                            // Re-read original CSV using selected options if possible.
                            // We only have the parsed rows/headers here; attempt best-effort by using the batch's source file name if present in Caches.
                            var effectiveRows = pendingCSVRows
                            var effectiveHeaders = pendingCSVHeaders
                            if batch.sourceFileName.lowercased().hasSuffix(".csv"), let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
                                let candidate = caches.appendingPathComponent(batch.sourceFileName)
                                if FileManager.default.fileExists(atPath: candidate.path) {
                                    AMLogging.log("Re-reading CSV from caches with options at: \(candidate.path)", component: "ImportBatchDetailView")
                                    let data = try Data(contentsOf: candidate)
                                    let read = try CSV.read(data: data, encoding: .utf8, options: CSV.ReadOptions(delimiter: opts.delimiter, hasHeaderRow: opts.hasHeaderRow, skipEmptyLines: opts.skipEmptyLines))
                                    effectiveRows = read.rows
                                    effectiveHeaders = read.headers
                                } else {
                                    AMLogging.log("Cached CSV not found; using in-memory rows/headers", component: "ImportBatchDetailView")
                                }
                            }

                            let parser = GenericCSVParser(mapping: mapping)
                            var staged = try parser.parse(rows: effectiveRows, headers: effectiveHeaders)
                            staged.sourceFileName = batch.sourceFileName

                            let summary = try ImportViewModel.replaceBatch(batch: batch, with: staged, context: modelContext)
                            AMLogging.log("Replace Batch summary (mapped CSV via editor) — tx(updated: \(summary.updatedTx), inserted: \(summary.insertedTx), deleted: \(summary.deletedTx)); balances(updated: \(summary.updatedBalances), inserted: \(summary.insertedBalances), deleted: \(summary.deletedBalances)); holdings(updated: \(summary.updatedHoldings), inserted: \(summary.insertedHoldings), deleted: \(summary.deletedHoldings))", component: "ImportBatchDetailView")
                            self.summaryMessage = "Replaced: tx updated \(summary.updatedTx), inserted \(summary.insertedTx), deleted \(summary.deletedTx)."
                            self.showSummaryAlert = true
                            self.showMappingSheet = false
                            await load()
                        } catch {
                            AMLogging.error("CSV mapping parse failed (editor flow): \(error.localizedDescription)", component: "ImportBatchDetailView")
                            self.summaryMessage = "Failed to parse CSV with mapping: \(error.localizedDescription)"
                            self.showSummaryAlert = true
                            self.showMappingSheet = false
                        }
                    }
                },
                onCancel: {
                    AMLogging.log("MappingEditor canceled by user", component: "ImportBatchDetailView")
                    showMappingSheet = false
                },
                visibleFields: nil,
                autoSaveWhenReady: false
            )
        }
    }

    // When multiple BalanceSnapshot entries exist for the same account and calendar day,
    // prefer a non-zero balance over a zero value. This helps avoid persisting spurious $0
    // balances that sometimes appear alongside the real statement balance in parsed PDFs.
    private func deduplicateBalancesPreferringNonZeroSameDay(_ snaps: [BalanceSnapshot]) -> [BalanceSnapshot] {
        if snaps.isEmpty { return snaps }
        var chosen: [String: BalanceSnapshot] = [:]
        var order: [String] = []
        let cal = Calendar.current
        for snap in snaps {
            let accountKey = snap.account?.id.uuidString ?? "nil"
            let dayStart = cal.startOfDay(for: snap.asOfDate).timeIntervalSince1970
            let key = "\(accountKey)|\(Int(dayStart))"
            if let existing = chosen[key] {
                if existing.balance == .zero && snap.balance != .zero {
                    // Replace a zero-valued pick with a non-zero one
                    chosen[key] = snap
                } else {
                    // Keep the existing choice (either both zero or both non-zero)
                }
            } else {
                chosen[key] = snap
                order.append(key)
            }
        }
        // Preserve the first-seen order of keys
        return order.compactMap { chosen[$0] }
    }

    // When multiple staged balance entries exist for the same calendar day,
    // prefer a non-zero balance over a zero value. We dedupe by day only here
    // because staged balances may not yet be tied to a persisted Account.
    private func deduplicateStagedBalancesPreferringNonZeroSameDay(_ snaps: [StagedBalance]) -> [StagedBalance] {
        if snaps.isEmpty { return snaps }
        var chosen: [Int: StagedBalance] = [:]
        var order: [Int] = []
        let cal = Calendar.current
        for snap in snaps {
            let dayStart = cal.startOfDay(for: snap.asOfDate).timeIntervalSince1970
            let key = Int(dayStart)
            if let existing = chosen[key] {
                if existing.balance == .zero && snap.balance != .zero {
                    chosen[key] = snap
                } else {
                    // keep existing
                }
            } else {
                chosen[key] = snap
                order.append(key)
            }
        }
        return order.compactMap { chosen[$0] }
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

                // Long-term APR reliability: also extract raw text and append the Interest Charges section as a synthetic row
                if let fullText = PDFTextExtractor.extractText(from: url) {
                    AMLogging.log("PDF raw text length=\(fullText.count)", component: "ImportBatchDetailView")
                    var augmentedRows = rowsAndHeaders.0

                    if let interestSection = PDFTextExtractor.extractInterestChargesSection(from: fullText) {
                        AMLogging.log("Interest Charges section found — length=\(interestSection.count)", component: "ImportBatchDetailView")
                        augmentedRows.append([interestSection])
                    } else {
                        AMLogging.log("Interest Charges section not found in raw text", component: "ImportBatchDetailView")
                    }

                    if let balanceSection = PDFTextExtractor.extractBalanceSummarySection(from: fullText) {
                        AMLogging.log("Balance Summary section found — length=\(balanceSection.count)", component: "ImportBatchDetailView")
                        augmentedRows.append([balanceSection])
                    } else {
                        AMLogging.log("Balance Summary section not found in raw text", component: "ImportBatchDetailView")
                    }

                    AMLogging.log("ImportBatchDetailView: appending full document text as synthetic row", component: "ImportBatchDetailView")
                    augmentedRows.append([fullText])

                    parsedRows = augmentedRows
                    parsedHeaders = rowsAndHeaders.1
                } else {
                    AMLogging.log("PDF raw text unavailable — proceeding without synthetic sections", component: "ImportBatchDetailView")
                    parsedRows = rowsAndHeaders.0
                    parsedHeaders = rowsAndHeaders.1
                }
            } else {
                let data = try Data(contentsOf: url)
                rowsAndHeaders = try CSV.read(data: data)
                AMLogging.log("CSV read returned rows=\(rowsAndHeaders.0.count) headers=\(rowsAndHeaders.1)", component: "ImportBatchDetailView")
                parsedRows = rowsAndHeaders.0
                parsedHeaders = rowsAndHeaders.1
            }

            AMLogging.log("replaceBatch parsed — rows=\(parsedRows.count) headers=\(parsedHeaders)", component: "ImportBatchDetailView")

            let rows = parsedRows
            let headers = parsedHeaders
            AMLogging.log("replaceBatch using augmented inputs — rows=\(rows.count) headers=\(headers)", component: "ImportBatchDetailView")

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

                    // Safety net: if this is a bank/checking context, relabel any misclassified 'creditcard' snapshots to 'checking'
                    if fileExtension == "pdf" {
                        // Try to infer bank/checking context from existing batch content or label; fallback to treating non-liability as bank
                        let isBankContext: Bool = {
                            if let acctType = batch.transactions.first?.account?.type { return acctType != .creditCard && acctType != .loan }
                            if let acctType = batch.balances.first?.account?.type { return acctType != .creditCard && acctType != .loan }
                            if let acctType = batch.holdings.first?.account?.type { return acctType != .creditCard && acctType != .loan }
                            // Heuristic: if parserId suggests bank or batch label contains checking/savings
                            let pid = (batch.parserId ?? "").lowercased()
                            let lbl = batch.label.lowercased()
                            if pid.contains("bank") || pid.contains("checking") || pid.contains("savings") { return true }
                            if lbl.contains("checking") || lbl.contains("savings") { return true }
                            return true // default to bank-safe behavior when ambiguous in replace flow
                        }()
                        if isBankContext {
                            var relabeled = 0
                            for i in staged.balances.indices {
                                let lbl = (staged.balances[i].sourceAccountLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                                if lbl == "creditcard" || lbl == "credit card" {
                                    staged.balances[i].sourceAccountLabel = "checking"
                                    relabeled += 1
                                }
                            }
                            if relabeled > 0 {
                                AMLogging.log("ImportBatchDetailView: suppressed CC coercion in replace flow — relabeled \(relabeled) snapshot(s) to 'checking'", component: "ImportBatchDetailView")
                            }
                        }
                    }

                    // Prefer Purchases APR when available for credit card contexts during replace
                    if fileExtension == "pdf" {
                        // Infer credit card context from existing batch content
                        let isCreditCardContext: Bool = {
                            if let t = batch.transactions.first?.account?.type { return t == .creditCard }
                            if let t = batch.balances.first?.account?.type { return t == .creditCard }
                            if let t = batch.holdings.first?.account?.type { return t == .creditCard }
                            // Heuristic: favor CC if label mentions credit card
                            let lbl = batch.label.lowercased()
                            if lbl.contains("credit") && lbl.contains("card") { return true }
                            return false
                        }()
                        if isCreditCardContext {
                            if let urlForAPR = resolvedPDFURL(for: batch), let fullText = PDFTextExtractor.extractText(from: urlForAPR), let (apr, scale) = PDFTextExtractor.extractPreferredAPR(from: fullText) {
                                var applied = 0
                                for i in staged.balances.indices {
                                    if let existing = staged.balances[i].interestRateAPR {
                                        if apr < existing {
                                            staged.balances[i].interestRateAPR = apr
                                            staged.balances[i].interestRateScale = scale
                                            staged.balances[i].sourceAccountLabel = (staged.balances[i].sourceAccountLabel ?? "") + " apr:purchases"
                                            applied += 1
                                        }
                                    } else {
                                        staged.balances[i].interestRateAPR = apr
                                        staged.balances[i].interestRateScale = scale
                                        staged.balances[i].sourceAccountLabel = (staged.balances[i].sourceAccountLabel ?? "") + " apr:purchases"
                                        applied += 1
                                    }
                                }
                                if applied > 0 {
                                    AMLogging.log("ImportBatchDetailView: applied preferred APR (likely Purchases) to \(applied) staged balance(s) in replace flow", component: "ImportBatchDetailView")
                                }
                            }
                        }
                    }

                    // Maintain a local copy for PDF preview
                    if fileExtension == "pdf" {
                        if let cachedURL = cachePDF(for: batch, from: url) {
                            batch.sourceFileLocalPath = cachedURL.path
                            AMLogging.log("Cached PDF copied; batch.sourceFileLocalPath updated to per-batch path", component: "ImportBatchDetailView")
                            try? modelContext.save()
                        }
                    } else {
                        if batch.sourceFileLocalPath != nil {
                            AMLogging.log("Clearing batch.sourceFileLocalPath (non-PDF import)", component: "ImportBatchDetailView")
                            batch.sourceFileLocalPath = nil
                            try? modelContext.save()
                        }
                    }

                    // Normalize balances: if multiple snapshots exist for the same account and day,
                    // prefer the non-zero balance over a zero-valued duplicate.
                    let beforeBalanceCount = staged.balances.count
                    staged.balances = deduplicateStagedBalancesPreferringNonZeroSameDay(staged.balances)
                    AMLogging.log("Balance de-duplication (default parser): before=\(beforeBalanceCount) after=\(staged.balances.count)", component: "ImportBatchDetailView")

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

                    // Safety net: if this is a bank/checking context, relabel any misclassified 'creditcard' snapshots to 'checking'
                    if fileExtension == "pdf" {
                        // Try to infer bank/checking context from existing batch content or label; fallback to treating non-liability as bank
                        let isBankContext: Bool = {
                            if let acctType = batch.transactions.first?.account?.type { return acctType != .creditCard && acctType != .loan }
                            if let acctType = batch.balances.first?.account?.type { return acctType != .creditCard && acctType != .loan }
                            if let acctType = batch.holdings.first?.account?.type { return acctType != .creditCard && acctType != .loan }
                            // Heuristic: if parserId suggests bank or batch label contains checking/savings
                            let pid = (batch.parserId ?? "").lowercased()
                            let lbl = batch.label.lowercased()
                            if pid.contains("bank") || pid.contains("checking") || pid.contains("savings") { return true }
                            if lbl.contains("checking") || lbl.contains("savings") { return true }
                            return true // default to bank-safe behavior when ambiguous in replace flow
                        }()
                        if isBankContext {
                            var relabeled = 0
                            for i in staged.balances.indices {
                                let lbl = (staged.balances[i].sourceAccountLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                                if lbl == "creditcard" || lbl == "credit card" {
                                    staged.balances[i].sourceAccountLabel = "checking"
                                    relabeled += 1
                                }
                            }
                            if relabeled > 0 {
                                AMLogging.log("ImportBatchDetailView: suppressed CC coercion in replace flow — relabeled \(relabeled) snapshot(s) to 'checking'", component: "ImportBatchDetailView")
                            }
                        }
                    }

                    // Prefer Purchases APR when available for credit card contexts during replace
                    if fileExtension == "pdf" {
                        // Infer credit card context from existing batch content
                        let isCreditCardContext: Bool = {
                            if let t = batch.transactions.first?.account?.type { return t == .creditCard }
                            if let t = batch.balances.first?.account?.type { return t == .creditCard }
                            if let t = batch.holdings.first?.account?.type { return t == .creditCard }
                            // Heuristic: favor CC if label mentions credit card
                            let lbl = batch.label.lowercased()
                            if lbl.contains("credit") && lbl.contains("card") { return true }
                            return false
                        }()
                        if isCreditCardContext {
                            if let urlForAPR = resolvedPDFURL(for: batch), let fullText = PDFTextExtractor.extractText(from: urlForAPR), let (apr, scale) = PDFTextExtractor.extractPreferredAPR(from: fullText) {
                                var applied = 0
                                for i in staged.balances.indices {
                                    if let existing = staged.balances[i].interestRateAPR {
                                        if apr < existing {
                                            staged.balances[i].interestRateAPR = apr
                                            staged.balances[i].interestRateScale = scale
                                            staged.balances[i].sourceAccountLabel = (staged.balances[i].sourceAccountLabel ?? "") + " apr:purchases"
                                            applied += 1
                                        }
                                    } else {
                                        staged.balances[i].interestRateAPR = apr
                                        staged.balances[i].interestRateScale = scale
                                        staged.balances[i].sourceAccountLabel = (staged.balances[i].sourceAccountLabel ?? "") + " apr:purchases"
                                        applied += 1
                                    }
                                }
                                if applied > 0 {
                                    AMLogging.log("ImportBatchDetailView: applied preferred APR (likely Purchases) to \(applied) staged balance(s) in replace flow", component: "ImportBatchDetailView")
                                }
                            }
                        }
                    }

                    // Maintain a local copy for PDF preview
                    if fileExtension == "pdf" {
                        if let cachedURL = cachePDF(for: batch, from: url) {
                            batch.sourceFileLocalPath = cachedURL.path
                            AMLogging.log("Cached PDF copied; batch.sourceFileLocalPath updated to per-batch path", component: "ImportBatchDetailView")
                            try? modelContext.save()
                        }
                    } else {
                        if batch.sourceFileLocalPath != nil {
                            AMLogging.log("Clearing batch.sourceFileLocalPath (non-PDF import)", component: "ImportBatchDetailView")
                            batch.sourceFileLocalPath = nil
                            try? modelContext.save()
                        }
                    }

                    // Normalize balances: if multiple snapshots exist for the same account and day,
                    // prefer the non-zero balance over a zero-valued duplicate.
                    let beforeBalanceCount = staged.balances.count
                    staged.balances = deduplicateStagedBalancesPreferringNonZeroSameDay(staged.balances)
                    AMLogging.log("Balance de-duplication (mapped CSV): before=\(beforeBalanceCount) after=\(staged.balances.count)", component: "ImportBatchDetailView")

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
            self.pendingCSVHeaders = parsedHeaders
            self.pendingCSVRows = parsedRows
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

    private func orderedBalanceFieldIDs() -> [UUID] {
        return balances.map { $0.id }
    }

    private func focusPreviousField() {
        let ids = orderedBalanceFieldIDs()
        guard !ids.isEmpty else { return }
        if case let .balanceAmount(currentID) = focusedField, let idx = ids.firstIndex(of: currentID) {
            let prev = idx > 0 ? ids[idx - 1] : ids.last!
            focusedField = .balanceAmount(prev)
        } else {
            focusedField = .balanceAmount(ids.last!)
        }
    }

    private func focusNextField() {
        let ids = orderedBalanceFieldIDs()
        guard !ids.isEmpty else { return }
        if case let .balanceAmount(currentID) = focusedField, let idx = ids.firstIndex(of: currentID) {
            let next = idx < ids.count - 1 ? ids[idx + 1] : ids.first!
            focusedField = .balanceAmount(next)
        } else {
            focusedField = .balanceAmount(ids.first!)
        }
    }

    private func commitAndDismissKeyboard() {
        try? modelContext.save()
        NotificationCenter.default.post(name: .transactionsDidChange, object: nil)
        focusedField = nil
    }

    @MainActor
    private func load() async {
        do {
            let batchDesc = FetchDescriptor<ImportBatch>(predicate: #Predicate { $0.id == batchID })
            let batches = try modelContext.fetch(batchDesc)
            let found = batches.first
            AMLogging.log("ImportBatchDetailView.load: fetch batch found=\(found != nil ? "yes" : "no") for id=\(batchID)", component: "ImportBatchDetailView")
            self.batch = found
            if let b = found {
                migrateLegacyPDFCacheIfNeeded(for: b)
                // Resolve and cache any available PDF URL for inline preview
                self.inlinePDFURL = resolvedPDFURL(for: b)
            } else {
                self.inlinePDFURL = nil
            }

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

        // Remove any cached PDF preview for this batch
        if let path = batch.sourceFileLocalPath, !path.isEmpty {
            let fm = FileManager.default
            do {
                let fileURL = URL(fileURLWithPath: path)
                try? fm.removeItem(at: fileURL)
                // Attempt to remove the per-batch directory if empty
                let dirURL = fileURL.deletingLastPathComponent()
                try? fm.removeItem(at: dirURL)
                AMLogging.log("Removed cached PDF and per-batch directory at \(dirURL.path)", component: "ImportBatchDetailView")
            }
        }

        do {
            // Clear lists immediately to prevent the UI from touching deleted objects
            self.transactions = []
            self.balances = []
            self.holdings = []
            self.batch = nil

            try ImportViewModel.hardDelete(batch: batch, context: modelContext)

            #if os(iOS)
            if UIDevice.current.userInterfaceIdiom == .phone {
                dismiss()
            }
            #else
            dismiss()
            #endif
        } catch {
            AMLogging.error("Hard delete failed: \(error.localizedDescription)", component: "ImportBatchDetailView")
        }
    }

    private func format(amount: Decimal) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = settings.currencyCode
        return nf.string(from: NSDecimalNumber(decimal: amount)) ?? "\(amount)"
    }

    private func formatAPR(_ apr: Decimal, scale: Int? = nil) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .percent
        if let s = scale { nf.minimumFractionDigits = s; nf.maximumFractionDigits = s }
        else { nf.minimumFractionDigits = 2; nf.maximumFractionDigits = 3 }
        return nf.string(from: NSDecimalNumber(decimal: apr)) ?? "\(apr)"
    }
}

private struct DismissOverlay: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white)
                .shadow(radius: 2)
        }
        .buttonStyle(.plain)
        .background(.ultraThinMaterial, in: Circle())
        .accessibilityLabel("Close")
    }
}
private struct FrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

private extension View {
    func logFrame(_ label: String, in space: CoordinateSpace = .global) -> some View {
        self
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .preference(key: FrameKey.self, value: proxy.frame(in: space))
                }
            )
            .onPreferenceChange(FrameKey.self) { rect in
                print("[\(label)] frame in \(space): origin=(\(Int(rect.minX)), \(Int(rect.minY))) size=(\(Int(rect.width)) x \(Int(rect.height)))")
            }
    }

    func debugBorder(_ color: Color) -> some View {
        self.overlay(Rectangle().stroke(color, lineWidth: 2))
    }
}
#Preview {
    Text("Preview requires model data")
}

