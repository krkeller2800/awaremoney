import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct DebtPayoffDetailView: View {
    @ObservedObject var vm: ImportViewModel
    let coordinator: StatementImportCoordinator

    var importAction: () -> Void = {}
    var manualEntryAction: () -> Void = {}
    @Binding var pendingExternal: (url: URL, type: StatementType?, institution: String?)?

    @Query(sort: [SortDescriptor(\Account.name, order: .forward)]) private var accounts: [Account]
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var settings: SettingsStore
    @State private var showImporter = false
    @State private var lastDetection: IntakeDetection?
    @State private var importError: Error?
    @State private var editedInstitution: String = ""
    @State private var selectedType: StatementType? = nil
    @State private var selectedAccountID: UUID? = nil
    @State private var lastImportedURL: URL? = nil
    @State private var detectionSheetModel: DetectionSheetModel? = nil
    @State private var bankSubtype: QuickIngestAccountType? = nil
    @State private var isQuickIngesting: Bool = false
    @State private var quickIngestError: Error? = nil
    @State private var showManualAddSheet = false
    private struct EditingAccount: Identifiable { let id: UUID }
    @State private var editingAccount: EditingAccount? = nil
    @State private var pendingDelete: Account? = nil
    // New state for payoff inputs and results
    @State private var ingestedAccount: Account? = nil          // Optional: use if you set this after ingest
    @State private var monthlyPaymentInput: String = ""
    @State private var aprPercentInput: String = ""             // e.g., "19.99" means 19.99%
    @State private var balanceInput: String = ""                // Current/ending balance
    @State private var computedPayoffDate: Date? = nil
    @State private var nonReducingPayment: Bool = false

    // Should we show payoff for this account?
    private func shouldShowPayoff(for account: Account) -> Bool {
        switch account.type {
        case .creditCard, .loan:
            return true
        default:
            return false
        }
    }

    // Compute payoff using current inputs with account fallbacks
    private func computePayoff(using account: Account) {
        let bal = MoneyParsing.parseDecimalInput(balanceInput) ?? latestBalance(for: account)
        let apr = MoneyParsing.parsePercentInput(aprPercentInput) ?? MoneyParsing.normalizedAPR(from: account.loanTerms?.apr)
        let pmt = MoneyParsing.parseDecimalInput(monthlyPaymentInput) ?? account.loanTerms?.paymentAmount

        guard let bal, let apr, let pmt else {
            computedPayoffDate = nil
            nonReducingPayment = false
            return
        }

        if let date = PayoffCalculator.payoffDate(balance: bal, apr: apr, monthlyPayment: pmt) {
            computedPayoffDate = date
            nonReducingPayment = false
        } else {
            computedPayoffDate = nil
            nonReducingPayment = true
        }
    }
    // Item-based sheet model to avoid timing issues with boolean presentation
    private struct DetectionSheetModel: Identifiable {
        let id = UUID()
        var detection: IntakeDetection
        var url: URL
    }
    @FocusState private var focusedField: FocusedField?
    private enum FocusedField: Hashable {
        case institution
        case monthlyPayment
        case aprPercent
        case endingBalance
    }

    private func selectAll(_ field: FocusedField) {
          focusedField = field
      }
    
    // Break out focus change handling to reduce SwiftUI type-checker load
    private func handleFocusChange(from oldValue: FocusedField?, to newValue: FocusedField?) {
        // Format when leaving a field
        if oldValue == .monthlyPayment && newValue != .monthlyPayment {
            AppFormatters.formatCurrencyInput(&monthlyPaymentInput)
        }
        if oldValue == .endingBalance && newValue != .endingBalance {
            AppFormatters.formatCurrencyInput(&balanceInput)
        }
        if oldValue == .aprPercent && newValue != .aprPercent {
            AppFormatters.formatPercentInput(&aprPercentInput)
        }

        // Select-all when entering a field (covers keyboard navigation, programmatic focus, etc.)
        if newValue == .monthlyPayment {
            selectAll(.monthlyPayment)
        } else if newValue == .endingBalance {
            selectAll(.endingBalance)
        } else if newValue == .aprPercent {
            selectAll(.aprPercent)
        }
    }

    // Resolve the account to use for payoff and prefill logic
    private func currentAccount() -> Account? {
        if let ing = ingestedAccount { return ing }
        if let sel = selectedAccountID { return accounts.first(where: { $0.id == sel }) }
        return nil
    }

    private static let importTypes: [UTType] = {
        var types: [UTType] = [.pdf, .commaSeparatedText, .tabSeparatedText, .text, .data]
        let exts = ["qfx","ofx","qbo","qif","xlsx","xls","csv","tsv","txt","zip"]
        types.append(contentsOf: exts.compactMap { UTType(filenameExtension: $0) })
        return types
    }()

    @ViewBuilder
    private var columnsView: some View {
        HStack(spacing: 0) {
            // Left column: replaced with QAccountsListView
            QAccountsListView(
                accounts: accounts,
                selectedAccountID: $selectedAccountID,
                onEdit: { account in
                    editingAccount = EditingAccount(id: account.id)
                },
                onDeleteConfirmed: { account in
                    deleteAccount(account)
                },
                onSelectionChanged: { id in
                    if let id { self.updateLastImportedURL(for: id) }
                }
            )
            .frame(minWidth: 280, maxWidth: 360, maxHeight: .infinity, alignment: .topLeading)
            .padding([.top, .horizontal])

            Divider()

            // Right column: PDF preview or placeholder
            Group {
                if let url = lastImportedURL {
                    PDFPreview(url:url)
                } else {
                    ContentUnavailableView("No Statement",
                                           systemImage: "doc.text",
                                           description: Text("Import a statement to preview it here."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.quaternary.opacity(0.05))
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }

    // Stages a URL into the app's Caches directory so it remains readable across contexts
    private func stageURLToCaches(_ sourceURL: URL) -> URL {
        let fm = FileManager.default
        do {
            let caches = try fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let dest = caches.appendingPathComponent(sourceURL.lastPathComponent)

            // If the source is already the same as our destination, just return it
            // Avoid removing/copying when paths are identical (prevents accidental deletion)
            let srcStd = sourceURL.standardizedFileURL
            let destStd = dest.standardizedFileURL
            if srcStd.path == destStd.path {
                return destStd
            }

            // Replace any existing file at destination
            try? fm.removeItem(at: destStd)

            // Access the security-scoped resource if needed while we copy/read
            let granted = sourceURL.startAccessingSecurityScopedResource()
            defer { if granted { sourceURL.stopAccessingSecurityScopedResource() } }

            // Try a direct file copy first
            do {
                try fm.copyItem(at: sourceURL, to: destStd)
                return destStd
            } catch {
                // If copy fails (e.g., due to sandbox), fall back to reading/writing data
                do {
                    let data = try Data(contentsOf: sourceURL)
                    try data.write(to: destStd, options: .atomic)
                    return destStd
                } catch {
                    // Fall back to the original URL if all else fails
                    return sourceURL
                }
            }
        } catch {
            // Could not resolve caches directory; fall back to the original URL
            return sourceURL
        }
    }

    private func handleImport(url: URL) {
        Task {
            // Stage the picked file into the app's caches directory first so it remains readable
            let routedURL = stageURLToCaches(url)

            // Classify the statement using the staged URL to avoid security-scope issues
            let classifier = StatementIntakeClassifier()
            let detection = await classifier.classify(url: routedURL)

            await MainActor.run {
                // Pre-fill editable fields
                self.lastDetection = detection
                self.editedInstitution = detection.institution ?? ""
                self.selectedType = detection.type

                // Ensure the file importer is dismissed before presenting another sheet
                self.showImporter = false

                // Present the review sheet after a short delay to avoid presentation collisions
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    self.detectionSheetModel = DetectionSheetModel(detection: detection, url: routedURL)
                }
            }
        }
    }

    private func latestBalance(for account: Account) -> Decimal? {
        return account.balanceSnapshots.sorted { $0.asOfDate > $1.asOfDate }.first?.balance
    }

    @MainActor
    private func deleteAccount(_ account: Account) {
        // If the deleted account is currently selected, clear selection so your onChange handler can pick a new one.
        if selectedAccountID == account.id {
            selectedAccountID = nil
            lastImportedURL = nil
        }

        modelContext.delete(account)
        do {
            try modelContext.save()
        } catch {
            // Reuse your existing error surface if you want
            importError = error
        }
    }

    private func formattedBalance(for account: Account) -> String {
        guard let bal = latestBalance(for: account) else { return "—" }
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        return nf.string(from: NSDecimalNumber(decimal: bal)) ?? "\(bal)"
    }

    private func formattedAPR(for account: Account) -> String? {
        guard let apr = account.loanTerms?.apr else { return nil }
        let nf = NumberFormatter()
        nf.numberStyle = .percent
        if let s = account.loanTerms?.aprScale {
            nf.minimumFractionDigits = s
            nf.maximumFractionDigits = s
        } else {
            nf.minimumFractionDigits = 2
            nf.maximumFractionDigits = 3
        }
        return nf.string(from: NSDecimalNumber(decimal: apr))
    }

    private func formattedPayment(for account: Account) -> String? {
        guard let amt = account.loanTerms?.paymentAmount else { return nil }
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        return nf.string(from: NSDecimalNumber(decimal: amt))
    }

    private func displayInstitution(for account: Account) -> String {
        let inst = (account.institutionName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !inst.isEmpty { return inst }
        let name = account.name
        return name.isEmpty ? "Unnamed" : name
    }

    private func displayName(for type: StatementType) -> String {
        switch type {
        case .creditCard: return "Credit Card"
        case .bank:       return "Bank"
        case .brokerage:  return "Brokerage"
        case .loan:       return "Loan"
        }
    }

    private func displayName(for type: Account.AccountType) -> String {
        switch type {
        case .checking: return "Checking"
        case .savings: return "Savings"
        case .creditCard: return "Credit Card"
        case .loan: return "Loan"
        case .cash: return "Cash"
        case .brokerage: return "Brokerage"
        case .property: return "Property"
        case .other: return "Other"
        }
    }

    // MARK: - Statement preview resolution (mirrors ImportBatchDetailView)
    private func perBatchPreviewDirectory(for batch: ImportBatch) -> URL? {
        let fm = FileManager.default
        guard let appSupport = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else {
            return nil
        }
        let dir = appSupport
            .appendingPathComponent("StatementPreviews", isDirectory: true)
            .appendingPathComponent(batch.id.uuidString, isDirectory: true)

        // Ensure directory exists and is excluded from iCloud backups
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            var dirCopy = dir
            try dirCopy.setResourceValues(resourceValues)
        } catch {
            // Best effort; still return dir
        }

        return dir
    }

    private func resolvedPDFURL(for batch: ImportBatch) -> URL? {
        let fm = FileManager.default
        // 1) Preferred: stored per-batch local path
        if let path = batch.sourceFileLocalPath, !path.isEmpty, fm.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        // 2) Try any file in the per-batch preview directory
        if let dir = perBatchPreviewDirectory(for: batch) {
            if let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil),
               let first = items.first(where: { $0.pathExtension.lowercased() == "pdf" }) {
                return first
            }
        }
        // 3) Legacy fallback: Caches/<sourceFileName>
        if let caches = try? fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true) {
            let legacy = caches.appendingPathComponent(batch.sourceFileName)
            if fm.fileExists(atPath: legacy.path) {
                return legacy
            }
        }
        return nil
    }

    @MainActor
    private func resolveLatestStatementURL(forAccountID targetID: UUID) -> URL? {
        do {
            // 1) Balances by asOfDate desc
            let balPred = #Predicate<BalanceSnapshot> { snap in
                (snap.account?.id == targetID) && (snap.importBatch != nil)
            }
            var balDesc = FetchDescriptor<BalanceSnapshot>(predicate: balPred)
            balDesc.sortBy = [SortDescriptor(\BalanceSnapshot.asOfDate, order: .reverse)]
            balDesc.fetchLimit = 1
            balDesc.includePendingChanges = false
            if let snap = try modelContext.fetch(balDesc).first, let batch = snap.importBatch, let url = resolvedPDFURL(for: batch) {
                return url
            }

            // 2) Transactions by datePosted desc
            let txPred = #Predicate<Transaction> { tx in
                (tx.account?.id == targetID) && (tx.importBatch != nil)
            }
            var txDesc = FetchDescriptor<Transaction>(predicate: txPred)
            txDesc.sortBy = [SortDescriptor(\Transaction.datePosted, order: .reverse)]
            txDesc.fetchLimit = 1
            txDesc.includePendingChanges = false
            if let tx = try modelContext.fetch(txDesc).first, let batch = tx.importBatch, let url = resolvedPDFURL(for: batch) {
                return url
            }

            // 3) Holdings (no natural date; just take first)
            let holdPred = #Predicate<HoldingSnapshot> { hold in
                (hold.account?.id == targetID) && (hold.importBatch != nil)
            }
            var holdDesc = FetchDescriptor<HoldingSnapshot>(predicate: holdPred)
            holdDesc.fetchLimit = 1
            holdDesc.includePendingChanges = false
            let holds = try modelContext.fetch(holdDesc)
            if let batch = holds.first?.importBatch, let url = resolvedPDFURL(for: batch) {
                return url
            }
        } catch {
            // ignore and fall through
        }
        return nil
    }

    @MainActor
    private func updateLastImportedURL(for id: UUID) {
        let url = resolveLatestStatementURL(forAccountID: id)
        if let u = url, FileManager.default.isReadableFile(atPath: u.path) {
            self.lastImportedURL = u
        } else {
            self.lastImportedURL = nil
        }
    }

    // Binding that shows the sheet whenever vm.staged or vm.mappingSession is non-nil and clears state on dismissal
    private var isImportSheetPresented: Binding<Bool> {
        Binding(get: { vm.staged != nil || vm.mappingSession != nil }, set: { presented in
            if !presented {
                // Seed preview with the last picked local URL if available
                if let url = vm.lastPickedLocalURL {
                    self.lastImportedURL = url
                }
                // Clear import state so future presentations start fresh
                vm.staged = nil
                vm.mappingSession = nil
                // Refresh preview for the selected account if possible
                if let id = selectedAccountID {
                    self.updateLastImportedURL(for: id)
                }
            }
        })
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Get started by adding your credit accounts")
                .foregroundStyle(.secondary)

            // Two-column content area
            columnsView

            Divider().padding(.top, 4)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 32)
        .background(.background)
        .onAppear {
            if selectedAccountID == nil {
                selectedAccountID = accounts.first?.id
            }
            if let id = selectedAccountID {
                self.updateLastImportedURL(for: id)
            }
        }
        .onChange(of: accounts) { _, newValue in
            if selectedAccountID == nil {
                selectedAccountID = newValue.first?.id
            } else if let selID = selectedAccountID, !newValue.contains(where: { $0.id == selID }) {
                selectedAccountID = newValue.first?.id
            }
            Task { @MainActor in
                if let id = selectedAccountID {
                    self.updateLastImportedURL(for: id)
                } else {
                    self.lastImportedURL = nil
                }
            }
        }
        .onChange(of: selectedAccountID) { _, id in
            Task { @MainActor in
                if let id {
                    self.updateLastImportedURL(for: id)
                } else {
                    self.lastImportedURL = nil
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Import") { showImporter = true }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add Manually") {
                    // Reset all inputs before presenting the manual add sheet
                    selectedType = nil               // Picker shows "Choose…"
                    editedInstitution = ""           // Clear institution text field
                    bankSubtype = nil                // Auto subtype
                    monthlyPaymentInput = ""         // Clear monthly payment
                    aprPercentInput = ""             // Clear APR (%)
                    balanceInput = ""                // Clear ending/current balance
                    computedPayoffDate = nil
                    nonReducingPayment = false

                    showManualAddSheet = true
                }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: Self.importTypes, allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    handleImport(url: url)
                } else {
                    importError = NSError(domain: "Import", code: -1, userInfo: [NSLocalizedDescriptionKey: "No file selected"]) as Error
                }
            case .failure(let error):
                importError = error
            }
        }
        .alert("Quick Ingest Failed", isPresented: Binding(get: { quickIngestError != nil }, set: { if !$0 { quickIngestError = nil } })) {
            Button("Open Review") {
                if let model = detectionSheetModel {
                    var det = model.detection
                    det.type = selectedType
                    det.institution = editedInstitution.trimmingCharacters(in: .whitespacesAndNewlines)
                    lastDetection = det
                    let routedURL = stageURLToCaches(model.url)
                    Task { @MainActor in
                        await coordinator.importURL(routedURL, hint: det.type, modelContext: modelContext, settings: settings)
                    }
                    detectionSheetModel = nil
                } else {
                    /* no model; no-op */
                }
            }
            Button("Cancel", role: .cancel) { quickIngestError = nil }
        } message: {
            Text(quickIngestError?.localizedDescription ?? "Unknown error")
        }
#if os(iOS) || os(visionOS)
        .sheet(item: $editingAccount) { item in
            NavigationStack {
                AccountDetailView(accountID: item.id)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { editingAccount = nil }
                        }
                    }
            }
            .presentationSizing(.page)
        }
#else
        .sheet(item: $editingAccount) { item in
            NavigationStack {
                AccountDetailView(accountID: item.id)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { editingAccount = nil }
                        }
                    }
            }
        }
#endif
#if os(iOS) || os(visionOS)
        .sheet(item: $detectionSheetModel) { model in
            let acct = currentAccount()
            let latest = acct.flatMap { latestBalance(for: $0) }
            DetectionReviewSheet(
                detection: model.detection,
                url: model.url,
                selectedType: $selectedType,
                editedInstitution: $editedInstitution,
                bankSubtype: $bankSubtype,
                monthlyPaymentInput: $monthlyPaymentInput,
                aprPercentInput: $aprPercentInput,
                balanceInput: $balanceInput,
                account: acct,
                latestBalance: latest,
                isQuickIngesting: $isQuickIngesting,
                onSave: { det, incomingURL in
                    lastDetection = det
                    let routedURL = stageURLToCaches(incomingURL)
                    Task { @MainActor in
                        await coordinator.importURL(routedURL, hint: det.type, modelContext: modelContext, settings: settings)
                    }
                    self.lastImportedURL = routedURL
                    detectionSheetModel = nil
                },
                onDiscard: {
                    detectionSheetModel = nil
                }
            )
            .presentationSizing(.page)
        }
#else
        .sheet(item: $detectionSheetModel) { model in
            let acct = currentAccount()
            let latest = acct.flatMap { latestBalance(for: $0) }
            DetectionReviewSheet(
                detection: model.detection,
                url: model.url,
                selectedType: $selectedType,
                editedInstitution: $editedInstitution,
                bankSubtype: $bankSubtype,
                monthlyPaymentInput: $monthlyPaymentInput,
                aprPercentInput: $aprPercentInput,
                balanceInput: $balanceInput,
                account: acct,
                latestBalance: latest,
                isQuickIngesting: $isQuickIngesting,
                onSave: { det, incomingURL in
                    lastDetection = det
                    let routedURL = stageURLToCaches(incomingURL)
                    Task { @MainActor in
                        await coordinator.importURL(routedURL, hint: det.type, modelContext: modelContext, settings: settings)
                    }
                    self.lastImportedURL = routedURL
                    detectionSheetModel = nil
                },
                onDiscard: {
                    detectionSheetModel = nil
                }
            )
        }
#endif
        .sheet(isPresented: $showManualAddSheet) {
            ManualAddAccountSheet(
                selectedType: $selectedType,
                editedInstitution: $editedInstitution,
                bankSubtype: $bankSubtype,
                monthlyPaymentInput: $monthlyPaymentInput,
                aprPercentInput: $aprPercentInput,
                balanceInput: $balanceInput,
                onCancel: { showManualAddSheet = false },
                onSaved: { account in
                    showManualAddSheet = false
                    selectedAccountID = account.id
                    self.updateLastImportedURL(for: account.id)
                }
            )
            .environment(\.modelContext, modelContext)
            .environmentObject(settings)
            .presentationSizing(.page)
        }
        .sheet(isPresented: isImportSheetPresented) {
            ImportSheetContentView(vm: vm)
                .environment(\.modelContext, modelContext)
        }
        .onChange(of: pendingExternal?.url, initial: false) { _, _ in
            guard let pending = pendingExternal else { return }
            Task {
                let stagedURL = stageURLToCaches(pending.url)
                await MainActor.run {
                    self.editedInstitution = pending.institution ?? ""
                    self.selectedType = pending.type
                    let detection = IntakeDetection(type: self.selectedType, institution: self.editedInstitution, confidence: 0.6)
                    self.detectionSheetModel = DetectionSheetModel(detection: detection, url: stagedURL)
                    self.pendingExternal = nil
                }
            }
        }
        .onAppear {
            // Prefer the ingested account if you set it, otherwise fall back to the current selection
            let acct = currentAccount()
            guard let acct = acct else { return }

            // Prefill monthly payment if empty
            if monthlyPaymentInput.isEmpty {
                if let terms = acct.loanTerms, let p = terms.paymentAmount {
                    let nf = AppFormatters.currencyFormatter()
                    let num = NSDecimalNumber(decimal: p)
                    if let s = nf.string(from: num) {
                        monthlyPaymentInput = s
                    }
                }
            }

            // Prefill APR (%) if empty
            if aprPercentInput.isEmpty {
                let aprNormalized = MoneyParsing.normalizedAPR(from: acct.loanTerms?.apr)
                if let apr = aprNormalized {
                    let nf = NumberFormatter()
                    nf.numberStyle = .decimal
                    nf.minimumFractionDigits = 2
                    nf.maximumFractionDigits = 2
                    let percent = apr * 100
                    let num = NSDecimalNumber(decimal: percent)
                    if let s = nf.string(from: num) {
                        aprPercentInput = s
                    }
                }
            }

            // Prefill balance if empty
            if balanceInput.isEmpty {
                let latest = latestBalance(for: acct)
                if let bal = latest {
                    let nf = AppFormatters.currencyFormatter()
                    // Show a positive amount for liabilities (math already uses magnitude)
                    let absBalDouble = abs(NSDecimalNumber(decimal: bal).doubleValue)
                    let num = NSNumber(value: absBalDouble)
                    if let s = nf.string(from: num) {
                        balanceInput = s
                    }
                }
            }

            // Initial calculation
            computePayoff(using: acct)
        }
    }
}
