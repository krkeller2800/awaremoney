import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import Combine
import UIKit
import StoreKit

struct ImportFlowView: View {
    private let intakeClassifier = StatementIntakeClassifier()

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var purchases: PurchaseManager
    @EnvironmentObject private var importRouter: ImportOpenRouter
    @EnvironmentObject private var backupCoordinator: BackupOpenCoordinator
    @StateObject private var vm: ImportViewModel
    @State private var coordinator: StatementImportCoordinator

    @State private var batches: [ImportBatch] = []
    @State private var pickerKind: PickerKind? = nil
    @State private var selectedBatchID: PersistentIdentifier? = nil
    @State private var phoneRoute: BatchRoute? = nil
    @State private var lastKnownBatchIDs: Set<UUID> = []
    @State private var hasLoadedBatchesOnce: Bool = false
    @State private var suppressNextAutoNavigation: Bool = false
    @State private var showPaywall: Bool = false
    @State private var paywallSource: PaywallSource = .unknown
    @State private var externalImportActive: Bool = false
    @State private var showImportError: Bool = false

    @State private var pendingExternalURL: URL? = nil
    @State private var isActive: Bool = false

    // Additional state for the new fileImporter binding as per instructions
    @State private var isImporterPresented: Bool = false
    @State private var showDocKindSheet: Bool = false

    // New state for backup sheet presentation
    @State private var showBackupSheet: Bool = false

    // New state for help sheet presentation
    @State private var showHelpSheet: Bool = false
    
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    
    private enum PickerKind { case csv, pdf }

    private enum ExternalDocKind: String, CaseIterable, Identifiable {
        case creditCard = "Credit Card Statement"
        case loan = "Loan Statement"
        case checking = "Bank Statement"
        case brokerage = "Brokerage Statement"
        case csv = "CSV/Activity"
        case ofx = "OFX/QFX/QBO"
        case qif = "QIF Transactions"
        case excel = "Excel (XLSX/XLS)"
        case zip = "ZIP Archive"
        var id: String { rawValue }
    }

    init() {
        let vm = ImportViewModel(parsers: ImportViewModel.defaultParsers())
        _vm = StateObject(wrappedValue: vm)
        _coordinator = State(initialValue: StatementImportCoordinator(vm: vm))
    }

    private func presentPaywall(source: PaywallSource) {
        paywallSource = source
        showPaywall = true
    }

    private func handlePendingURLWithIntake(_ url: URL) {
        guard purchases.isPremiumUnlocked else {
            presentPaywall(source: .externalImport)
            importRouter.pendingURL = nil
            return
        }
        let stagedURL = ImportFileStaging.stageToCaches(url)
        externalImportActive = true
        pendingExternalURL = stagedURL
        showPaywall = false
        clearPreviousImportReviewIfNeeded(fileName: stagedURL.lastPathComponent, source: "external-intake")
        Task {
            let runtime = AMRuntimeDiagnostics.executionEnvironmentDescription
            AMLogging.log(
                "ImportFlowView: begin intake file=\(stagedURL.lastPathComponent) runtime=\(runtime)",
                component: "Import"
            )
            let detection = await intakeClassifier.classify(url: stagedURL)
            let mapped: ExternalDocKind? = {
                switch detection.type {
                case .some(.creditCard): return .creditCard
                case .some(.loan):       return .loan
                case .some(.brokerage):  return .brokerage
                case .some(.bank):       return .checking
                case .none:              return nil
                }
            }()
            // Prefill institution from router hint or intake detection so ReviewImportView can default routing intelligently
            let upstreamInstitution = await MainActor.run { self.importRouter.pendingInstitution }
            let chosenInstitution = upstreamInstitution?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? upstreamInstitution : detection.institution
            await MainActor.run {
                if let inst = chosenInstitution?.trimmingCharacters(in: .whitespacesAndNewlines), !inst.isEmpty {
                    self.vm.userInstitutionName = inst
                }
            }
            if let kind = mapped {
                AMLogging.log("ImportFlowView: Intake classified external URL '" + stagedURL.lastPathComponent + "' as \(String(describing: detection.type)) inst=\(detection.institution ?? "nil") conf=\(detection.confidence) runtime=\(runtime)", component: "Import")
                // Proceed directly using the mapped kind
                applyExternal(kind: kind, url: stagedURL)
                importRouter.pendingURL = nil
                pendingExternalURL = nil
                externalImportActive = false
            } else {
                AMLogging.log("ImportFlowView: Intake could not determine statement type for '" + stagedURL.lastPathComponent + "' — presenting doc kind chooser runtime=\(runtime)", component: "Import")
                showDocKindSheet = true
            }
        }
    }

    private func applyExternal(kind: ExternalDocKind, url: URL) {
        guard purchases.isPremiumUnlocked else {
            presentPaywall(source: .externalImport)
            return
        }
        switch kind {
        case .creditCard:
            vm.userSelectedDocHint = .creditCard
            vm.creditCardFlipOverride = settings.creditCardFlipDefault ? true : nil
            vm.newAccountType = .creditCard
        case .loan:
            vm.userSelectedDocHint = .loan
            vm.newAccountType = .loan
        case .checking:
            vm.userSelectedDocHint = .checking
            vm.newAccountType = .checking
        case .brokerage:
            vm.userSelectedDocHint = .brokerage
            vm.newAccountType = .brokerage
        case .csv:
            vm.userSelectedDocHint = nil
        case .ofx, .qif, .excel, .zip:
            vm.userSelectedDocHint = nil
        }
        AMLogging.log("ImportFlowView: applyExternal called with kind=\(kind.rawValue) url=\(url.lastPathComponent)", component: "Import")
        beginCoordinatorImport(url, hint: statementHint(from: vm.newAccountType), source: "external-\(kind.rawValue)")
    }

    private func clearPreviousImportReviewIfNeeded(fileName: String, source: String) {
        guard vm.staged != nil || vm.mappingSession != nil else { return }
        AMLogging.log(
            "ImportFlowView: clearing previous staged review before \(source) file=\(fileName)",
            component: "Import"
        )
        vm.staged = nil
        vm.mappingSession = nil
    }

    private func beginCoordinatorImport(_ url: URL, hint: StatementType?, source: String) {
        clearPreviousImportReviewIfNeeded(fileName: url.lastPathComponent, source: source)
        AMLogging.log(
            "ImportFlowView: begin coordinator import source=\(source) file=\(url.lastPathComponent) hint=\(String(describing: hint))",
            component: "Import"
        )
        Task {
            await self.coordinator.importURL(
                url,
                hint: hint,
                modelContext: self.modelContext,
                settings: self.settings
            )
        }
    }

    private func statementHint(from type: Account.AccountType?) -> StatementType? {
        guard let t = type else { return nil }
        switch t {
        case .creditCard: return .creditCard
        case .loan:       return .loan
        case .brokerage:  return .brokerage
        case .checking, .savings: return .bank
        default: return nil
        }
    }

    private func stagedLabelSummary(_ staged: StagedImport) -> String {
        func normalizedLabel(_ raw: String?) -> String {
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? "default" : trimmed.lowercased()
        }
        let transactionLabels = Dictionary(grouping: staged.transactions, by: { normalizedLabel($0.sourceAccountLabel) })
            .mapValues { $0.count }
        let balanceLabels = Dictionary(grouping: staged.balances, by: { normalizedLabel($0.sourceAccountLabel) })
            .mapValues { $0.count }
        return "parser=\(staged.parserId) balances=\(staged.balances.count) tx=\(staged.transactions.count) txLabels=\(transactionLabels) balanceLabels=\(balanceLabels)"
    }

    private func allowedTypesForCurrentPicker() -> [UTType] {
        switch pickerKind {
        case .csv:
            var types: [UTType] = []
            // CSV/TSV/plain text
            types.append(.commaSeparatedText)
            types.append(.tabSeparatedText)
            types.append(.plainText)
            if let tsv = UTType.tsv { types.append(tsv) } // explicit by extension
            if let csvByExt = UTType(filenameExtension: "csv") { types.append(csvByExt) }

            // Financial interchange formats
            if let ofx = UTType.ofx { types.append(ofx) }
            if let qfx = UTType.qfx { types.append(qfx) }
            if let qbo = UTType(filenameExtension: "qbo") { types.append(qbo) }
            if let qif = UTType.qif { types.append(qif) }

            // Excel workbooks
            if let xlsx = UTType.xlsx { types.append(xlsx) }
            if let xls = UTType.xls { types.append(xls) }

            // Archives (some banks deliver zipped statements)
            if let zip = UTType.zip { types.append(zip) }

            // De-duplicate while preserving order
            var seen: Set<String> = []
            let unique = types.filter { t in
                let id = t.identifier
                if seen.contains(id) { return false }
                seen.insert(id)
                return true
            }
            return unique
        case .pdf:
            return [.pdf]
        default:
            // Mirror CSV case for safety
            var types: [UTType] = []
            types.append(.commaSeparatedText)
            types.append(.tabSeparatedText)
            types.append(.plainText)
            if let tsv = UTType.tsv { types.append(tsv) }
            if let csvByExt = UTType(filenameExtension: "csv") { types.append(csvByExt) }
            if let ofx = UTType.ofx { types.append(ofx) }
            if let qfx = UTType.qfx { types.append(qfx) }
            if let qbo = UTType(filenameExtension: "qbo") { types.append(qbo) }
            if let qif = UTType.qif { types.append(qif) }
            if let xlsx = UTType.xlsx { types.append(xlsx) }
            if let xls = UTType.xls { types.append(xls) }
            if let zip = UTType.zip { types.append(zip) }
            var seen: Set<String> = []
            let unique = types.filter { t in
                let id = t.identifier
                if seen.contains(id) { return false }
                seen.insert(id)
                return true
            }
            return unique
        }
    }

    private var emptyStateView: some View {
        ContentUnavailableView(
            "No Imports Yet",
            systemImage: "tray",
            description: Text("Import PDF statements or account transactions to get started.")
        )
        .listRowInsets(EdgeInsets())
    }

    private struct BatchRowContent: View {
        let batch: ImportBatch
        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(batch.label)
                    .font(.body)
                HStack(spacing: 8) {
                    if let pid = batch.parserId, !pid.isEmpty {
                        Text(pid)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(batch.createdAt, style: .date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(batch.createdAt, style: .time)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // Wrapper to navigate by batch ID on phone
    private struct BatchRoute: Identifiable, Hashable {
        let id: UUID
    }

    // Prefer selecting a non-empty batch (has transactions, balances, or holdings); fall back to the first batch
    private func preferredSelectionID(in list: [ImportBatch]) -> PersistentIdentifier? {
        if let nonEmpty = list.first(where: { !$0.transactions.isEmpty || !$0.balances.isEmpty || !$0.holdings.isEmpty }) {
            return nonEmpty.persistentModelID
        }
        return list.first?.persistentModelID
    }

    private var orderedBatches: [ImportBatch] {
        batches.sorted(by: { (lhs: ImportBatch, rhs: ImportBatch) -> Bool in
            let lNonEmpty = !lhs.transactions.isEmpty || !lhs.balances.isEmpty || !lhs.holdings.isEmpty
            let rNonEmpty = !rhs.transactions.isEmpty || !rhs.balances.isEmpty || !rhs.holdings.isEmpty
            if lNonEmpty == rNonEmpty {
                return lhs.createdAt > rhs.createdAt
            }
            return lNonEmpty && !rNonEmpty
        })
    }
    
    @ViewBuilder
    private func importsSection() -> some View {
        if batches.isEmpty {
            emptyStateView
        } else {
            ForEach(orderedBatches, id: \.id) { (batch: ImportBatch) in
                NavigationLink(destination: ImportBatchDetailView(batchID: batch.id)) {
                    BatchRowContent(batch: batch)
                }
            }
        }
    }

    private var hintBar: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lightbulb")
                .imageScale(.medium)
                .foregroundStyle(.secondary)
            Text("Tip: For best results, import PDFs of current statements and add CSV/QFX activity for mid-month updates.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color(.systemGroupedBackground))
    }

    private var backupSection: some View {
        PlanToolbarButton("Backup & Restore…", systemImage: "externaldrive") { showBackupSheet = true }
            .padding(.horizontal)
            .padding(.vertical, 10)
//        Button {
//            showBackupSheet = true
//        } label: {
//            HStack(spacing: 8) {
//                Image(systemName: "externaldrive")
//                Text("Backup & Restore…")
//            }
//        }
//        .buttonStyle(.bordered)
//        .frame(maxWidth: .infinity, alignment: .center)
//        .padding(.horizontal)
//        .padding(.vertical, 10)
    }

    private func autoApplyMappingIfPossible(headers: [String], rows: [[String]]) {
        // Quick guard: skip CSV auto-apply for OFX/QFX preamble headers
        let lowerHeaders = headers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        if lowerHeaders.count == 1 {
            let h = lowerHeaders[0]
            if h.hasPrefix("ofxheader") {
                AMLogging.log("ImportFlowView: autoApplyMapping — skipping auto-apply for OFX/QFX-like content (header '\(headers[0])'); awaiting dedicated OFX parser", component: "Import")
                return
            }
        }
        do {
            let saved = try modelContext.fetch(FetchDescriptor<CSVColumnMapping>())
            AMLogging.log("ImportFlowView: autoApplyMapping — savedMappings=\(saved.count), headers=\(headers), headerSet=\(Set(headers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }))", component: "Import")
            let headerSet = Set(headers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
            for map in saved {
                let values = map.mappings.values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                let isSubset = Set(values).isSubset(of: headerSet)
                AMLogging.log("ImportFlowView: autoApplyMapping — candidate='" + (map.label ?? "(unnamed)") + "' values=\(values) subset=\(isSubset)", component: "Import")
            }
            if let mapping = saved.first(where: { map in
                let values = map.mappings.values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                return Set(values).isSubset(of: headerSet)
            }) {
                do {
                    let parser = GenericCSVParser(mapping: mapping, sourceFileName: vm.lastPickedLocalURL?.lastPathComponent ?? "Mapped CSV")
                    let staged = try parser.parse(rows: rows, headers: headers)
                    vm.staged = staged
                    vm.mappingSession = nil
                    AMLogging.log("ImportFlowView: auto-applied saved CSV mapping '" + (mapping.label ?? "(unnamed)") + "'", component: "Import")
                } catch {
                    AMLogging.error("ImportFlowView: auto-apply mapping failed: \(error.localizedDescription)", component: "Import")
                }
            } else {
                AMLogging.log("ImportFlowView: autoApplyMapping — no matching saved mapping; presenting editor", component: "Import")
            }
        } catch {
            AMLogging.error("ImportFlowView: fetch saved mappings failed: \(error.localizedDescription)", component: "Import")
        }
    }

    private static func prefillMappings(from rawHeaders: [String], sampleRows: [[String]]) -> [CSVColumnMapping.Field: String] {
        let normalized = rawHeaders.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

        func findHeader(where predicate: (String) -> Bool) -> String? {
            for (i, l) in normalized.enumerated() {
                if predicate(l) { return rawHeaders[i] }
            }
            return nil
        }

        func findHeader(containing tokens: [String]) -> String? {
            return findHeader { lower in tokens.contains(where: { lower.contains($0) }) }
        }

        // Prefer "Transaction Date", then "Post Date", then any header containing "Date"
        let dateHeader = findHeader(containing: ["transaction date"]) ??
                         findHeader(containing: ["post date"]) ??
                         findHeader(containing: ["date"])

        // Prefer clear description/payee fields; avoid matching headers that also contain "date" (e.g., "Transaction Date")
        let payeeHeader = findHeader { l in
            (l.contains("description") || l.contains("payee") || l.contains("memo") || l.contains("details")) && !l.contains("date")
        }

        // Try common amount-like tokens first. Keep debit/credit split columns distinct when both exist.
        var amountHeader: String? = findHeader(containing: ["amount", "amt", "charge"])
        let debitHeader = findHeader(containing: ["debit", "withdrawal"])
        let creditHeader = findHeader(containing: ["credit", "deposit"])

        // Fallback to guess amount column by scanning sample rows for numeric-looking data
        if amountHeader == nil {
            // Guess amount column by scanning sample rows for numeric-looking data
            let excludeTokens = ["date", "description", "payee", "memo", "details", "category", "account", "acct", "balance", "running", "type", "kind", "apr", "interest"]
            let excludedIndices: Set<Int> = Set(rawHeaders.enumerated().compactMap { idx, h in
                let lower = h.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return excludeTokens.contains(where: { lower.contains($0) }) ? idx : nil
            })
            func sanitize(_ s: String) -> String { s.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespacesAndNewlines) }
            var numericCounts: [Int: Int] = [:]
            for row in sampleRows {
                for (idx, cell) in row.enumerated() {
                    if excludedIndices.contains(idx) { continue }
                    let cleaned = sanitize(idx < row.count ? cell : "")
                    if cleaned.isEmpty { continue }
                    if Decimal(string: cleaned) != nil {
                        numericCounts[idx, default: 0] += 1
                    }
                }
            }
            if let bestIdx = numericCounts.max(by: { $0.value < $1.value })?.key, bestIdx < rawHeaders.count {
                amountHeader = rawHeaders[bestIdx]
            }
        }

        // Optional supporting fields
        let kindHeader = findHeader(containing: ["type", "kind"]) // e.g., "Type"
        let categoryHeader = findHeader(containing: ["category"]) // e.g., "Category"
        let accountHeader = findHeader(containing: ["account", "acct"]) // e.g., "Account"
        let balanceHeader = findHeader(containing: ["balance"]) // e.g., running balance

        var prefilled: [CSVColumnMapping.Field: String] = [:]
        if let h = dateHeader { prefilled[.date] = h }
        if let h = payeeHeader { prefilled[.payee] = h }
        if let h = amountHeader { prefilled[.amount] = h }
        if amountHeader == nil, let h = debitHeader { prefilled[.debit] = h }
        if amountHeader == nil, let h = creditHeader { prefilled[.credit] = h }
        if let h = kindHeader { prefilled[.kind] = h }
        if let h = categoryHeader { prefilled[.category] = h }
        if let h = accountHeader { prefilled[.account] = h }
        if let h = balanceHeader { prefilled[.balance] = h }

        return prefilled
    }

    @ViewBuilder
    private func sheetContent() -> some View {
        if let staged = vm.staged {
            ReviewImportView(staged: staged, vm: vm)
                .environment(\.modelContext, modelContext)
        } else if let session = vm.mappingSession {
            let fieldsForHint: [CSVColumnMapping.Field]? = {
                switch vm.userSelectedDocHint {
                case .loan:
                    return [.date, .payee, .memo, .amount, .debit, .credit, .category, .account, .balance, .runningBalance, .interestRateAPR]
                case .creditCard:
                    return [.date, .payee, .memo, .amount, .debit, .credit, .category, .account, .balance, .runningBalance, .interestRateAPR]
                case .brokerage:
                    return [.date, .symbol, .quantity, .price, .marketValue, .balance, .account]
                case .checking:
                    fallthrough
                default:
                    return [.date, .payee, .memo, .amount, .debit, .credit, .category, .account, .balance, .runningBalance]
                }
            }()

            NavigationStack {
                CSVMappingEditorView(
                    mapping: CSVColumnMapping(label: "New Mapping", mappings: Self.prefillMappings(from: session.headers, sampleRows: session.sampleRows)),
                    headers: session.headers,
                    sampleRows: session.sampleRows,
                    onSaveWithOptions: { mapping, options in
                        AMLogging.log("ImportFlowView: CSVMappingEditorView.onSaveWithOptions — label='" + (mapping.label ?? "(unnamed)") + "' mappings=\(mapping.mappings) options(delim=\(options.delimiter), header=\(options.hasHeaderRow), skipEmpty=\(options.skipEmptyLines))", component: "Import")
                        AMLogging.log("ImportFlowView: modelContext id=\(ObjectIdentifier(modelContext))", component: "Import")
                        // Persist the mapping
                        modelContext.insert(mapping)
                        do {
                            try modelContext.save()
                            AMLogging.log("ImportFlowView: save succeeded — mapping persistentID=\(String(describing: mapping.persistentModelID))", component: "Import")
                        } catch {
                            AMLogging.error("ImportFlowView: failed to save mapping — \(error.localizedDescription)", component: "Import")
                        }
                        do {
                            let all = try modelContext.fetch(FetchDescriptor<CSVColumnMapping>())
                            AMLogging.log("ImportFlowView: after save — total saved mappings=\(all.count)", component: "Import")
                            for m in all {
                                let vals = m.mappings.values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                                AMLogging.log("ImportFlowView: mapping catalog — label='" + (m.label ?? "(unnamed)") + "' values=\(vals)", component: "Import")
                            }
                        } catch {
                            AMLogging.error("ImportFlowView: fetch after save failed — \(error.localizedDescription)", component: "Import")
                        }
                        // Immediately parse using the session's rows and headers
                        do {
                            let parser = GenericCSVParser(mapping: mapping, sourceFileName: vm.lastPickedLocalURL?.lastPathComponent ?? "Mapped CSV")
                            let staged = try parser.parse(rows: session.sampleRows, headers: session.headers)
                            vm.staged = staged
                            vm.mappingSession = nil
                        } catch {
                            // If parsing fails, keep the mapping session open for correction
                            AMLogging.error("CSV mapping parse failed: \(error.localizedDescription)", component: "ImportFlowView")
                        }
                    },
                    onCancel: {
                        // Simply close the mapping session
                        vm.mappingSession = nil
                    },
                    visibleFields: fieldsForHint,
                    autoSaveWhenReady: false
                )
                .onAppear {
                    AMLogging.log("ImportFlowView: CSVMappingEditorView appearing — staged=\(vm.staged != nil), mappingSession=\(vm.mappingSession != nil)", component: "Import")
                }
            }
        } else {
            EmptyView()
        }
    }

    // Proper binding for sheet presentation so it can be dismissed cleanly
    private var isSheetPresentedBinding: Binding<Bool> {
        Binding<Bool>(
            get: { vm.staged != nil || vm.mappingSession != nil },
            set: { presented in
                if !presented {
                    // When the sheet is dismissed (swipe down or programmatically),
                    // clear both states to avoid falling back to another screen.
                    vm.staged = nil
                    vm.mappingSession = nil
                }
            }
        )
    }

    private var phoneBody: some View {
        NavigationStack {
            VStack(spacing: 0) {
                List {
                    Section {
                        importsSection()
                    } header: {
                        Text("Already Imported")
                    }
                }
                .navigationTitle("Import")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Section("PDF") {
                                Button("Credit Card Statement") {
                                    pickerKind = .pdf
                                    vm.userSelectedDocHint = .creditCard
                                    vm.creditCardFlipOverride = settings.creditCardFlipDefault
                                    vm.newAccountType = .creditCard
                                    AMLogging.log("ImportFlowView: presenting PDF picker (Credit Card Statement)", component: "Import")
                                    isImporterPresented = true
                                }
                                Button("Loan Statement") {
                                    pickerKind = .pdf
                                    vm.userSelectedDocHint = .loan
                                    vm.newAccountType = .loan
                                    AMLogging.log("ImportFlowView: presenting PDF picker (Loan Statement)", component: "Import")
                                    isImporterPresented = true
                                }
                                Button("Bank Statement") {
                                    pickerKind = .pdf
                                    vm.userSelectedDocHint = .checking
                                    vm.newAccountType = .checking
                                    AMLogging.log("ImportFlowView: presenting PDF picker (Bank Statement)", component: "Import")
                                    isImporterPresented = true
                                }
                                Button("Brokerage Statement") {
                                    pickerKind = .pdf
                                    vm.userSelectedDocHint = .brokerage
                                    vm.newAccountType = .brokerage
                                    AMLogging.log("ImportFlowView: presenting PDF picker (Brokerage Statement)", component: "Import")
                                    isImporterPresented = true
                                }
                                Divider()
                                Button("User-defined…") {
                                    // Present a manual staged import so the user can add a balance immediately
                                    vm.userSelectedDocHint = .creditCard
                                    vm.creditCardFlipOverride = settings.creditCardFlipDefault
                                    vm.newAccountType = .creditCard
                                    let manual = StagedImport(
                                        parserId: "manual.user",
                                        sourceFileName: "Manual Entry",
                                        inferredInstitutionName: nil,
                                        suggestedAccountType: vm.newAccountType,
                                        transactions: [],
                                        holdings: [],
                                        balances: []
                                    )
                                    vm.staged = manual
                                    vm.mappingSession = nil
                                    AMLogging.log("ImportFlowView: started manual user-defined import (credit card) — presenting ReviewImportView with empty staged import to add a balance", component: "Import")
                                }
                            }
                        } label: {
                            PlanMenuLabel(title: "Stmt")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Section("CSV, OFX, QFX, QIF, XLSX, & ZIP") {
                                Button("Credit Card Trans") {
                                    pickerKind = .csv
                                    vm.userSelectedDocHint = .creditCard
                                    vm.creditCardFlipOverride = settings.creditCardFlipDefault
                                    vm.newAccountType = .creditCard // ADD THIS
                                    AMLogging.log("ImportFlowView: presenting CSV picker (Credit Card CSV)", component: "Import")
                                    isImporterPresented = true
                                }
                                Button("Loan Transactions") {
                                    pickerKind = .csv
                                    vm.userSelectedDocHint = .loan
                                    vm.newAccountType = .loan // ADD THIS
                                    AMLogging.log("ImportFlowView: presenting CSV picker (Loan CSV)", component: "Import")
                                    isImporterPresented = true
                                }
                                Button("Checking Transactions") {
                                    pickerKind = .csv
                                    vm.userSelectedDocHint = .checking
                                    vm.newAccountType = .checking // ADD THIS
                                    AMLogging.log("ImportFlowView: presenting CSV picker (Bank CSV)", component: "Import")
                                    isImporterPresented = true
                                }
                                Button("Savings Transactions") {
                                    pickerKind = .csv
                                    vm.userSelectedDocHint = .checking
                                    vm.newAccountType = .savings
                                    AMLogging.log("ImportFlowView: presenting CSV picker (Savings CSV)", component: "Import")
                                    isImporterPresented = true
                                }
                                Button("Brokerage Transactions") {
                                    pickerKind = .csv
                                    vm.userSelectedDocHint = .brokerage
                                    vm.newAccountType = .brokerage // ADD THIS
                                    AMLogging.log("ImportFlowView: presenting CSV picker (Brokerage CSV)", component: "Import")
                                    isImporterPresented = true
                                }
                            }
                        } label: {
                            PlanMenuLabel(title: "Trans")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showHelpSheet = true
                        } label: {
                            Image(systemName: "questionmark.circle")
                        }
                    }
                }
                if settings.showHintBars {
                    hintBar
                }
                backupSection
            }
            .onAppear {
                AMLogging.log("ImportFlowView: modelContext id=\(ObjectIdentifier(modelContext))", component: "Import")
                isActive = true
                if !purchases.isPremiumUnlocked {
                    presentPaywall(source: .fifthImport)
                }
            }
            .onDisappear {
                isActive = false
            }
            .task { await loadBatches() }
            .refreshable { await loadBatches() }
            .onReceive(NotificationCenter.default.publisher(for: .transactionsDidChange)) { (_: Notification) in
                Task { await loadBatches() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .accountsDidChange)) { (_: Notification) in
                Task { await loadBatches() }
            }
            .onChange(of: pickerKind) {
                AMLogging.log("ImportFlowView: pickerKind changed to \(String(describing: pickerKind))", component: "Import")
            }
            .onReceive(vm.$staged) { (staged: StagedImport?) in
                if let staged {
                    AMLogging.log("ImportFlowView: staged import ready — \(stagedLabelSummary(staged))", component: "Import")
                    externalImportActive = false
                } else {
                    AMLogging.log("ImportFlowView: staged import cleared", component: "Import")
                    // Ensure mapping session is also cleared so the sheet dismisses
                    vm.mappingSession = nil
                    suppressNextAutoNavigation = true
                }
            }
            .onReceive(vm.$mappingSession) { session in
                if let session {
                    AMLogging.log("ImportFlowView: mapping session started — headers=\(session.headers.count)", component: "Import")
                    AMLogging.log("ImportFlowView: attempting auto-apply mapping from onReceive — headers=\(session.headers), rows=\(session.sampleRows.count)", component: "Import")
                    if settings.importAutoApplyMappings {
                        autoApplyMappingIfPossible(headers: session.headers, rows: session.sampleRows)
                    }
                    externalImportActive = false
                } else {
                    AMLogging.log("ImportFlowView: mapping session cleared", component: "Import")
                }
            }
            .onReceive(importRouter.$pendingURL) { (url: URL?) in
                  if let url { handlePendingURLWithIntake(url) }
            }
            .sheet(isPresented: isSheetPresentedBinding) {
                sheetContent()
            }
            .sheet(
                isPresented: Binding(
                    get: { showPaywall && !externalImportActive && vm.staged == nil && vm.mappingSession == nil },
                    set: { showPaywall = $0 }
                )
            ) {
                PaywallView(source: paywallSource)
                    .environmentObject(purchases)
            }
            .sheet(isPresented: $showDocKindSheet) {
                NavigationStack {
                    List {
                        Section("PDF Statements") {
                            Button("Credit Card") {
                                showDocKindSheet = false
                                if let url = pendingExternalURL {
                                    applyExternal(kind: .creditCard, url: url)
                                }
                                importRouter.pendingURL = nil
                                pendingExternalURL = nil
                                externalImportActive = false
                            }
                            Button("Loan") {
                                showDocKindSheet = false
                                if let url = pendingExternalURL {
                                    applyExternal(kind: .loan, url: url)
                                }
                                importRouter.pendingURL = nil
                                pendingExternalURL = nil
                                externalImportActive = false
                            }
                            Button("Bank") {
                                showDocKindSheet = false
                                if let url = pendingExternalURL {
                                    applyExternal(kind: .checking, url: url)
                                }
                                importRouter.pendingURL = nil
                                pendingExternalURL = nil
                                externalImportActive = false
                            }
                            Button("Brokerage") {
                                showDocKindSheet = false
                                if let url = pendingExternalURL {
                                    applyExternal(kind: .brokerage, url: url)
                                }
                                importRouter.pendingURL = nil
                                pendingExternalURL = nil
                                externalImportActive = false
                            }
                        }
                        Section("Transactions") {
                            Button("CSV") {
                                showDocKindSheet = false
                                if let url = pendingExternalURL {
                                    applyExternal(kind: .csv, url: url)
                                }
                                importRouter.pendingURL = nil
                                pendingExternalURL = nil
                                externalImportActive = false
                            }
                            Button("OFX/QFX/QBO") {
                                showDocKindSheet = false
                                if let url = pendingExternalURL {
                                    applyExternal(kind: .ofx, url: url)
                                }
                                importRouter.pendingURL = nil
                                pendingExternalURL = nil
                                externalImportActive = false
                            }
                            Button("QIF") {
                                showDocKindSheet = false
                                if let url = pendingExternalURL {
                                    applyExternal(kind: .qif, url: url)
                                }
                                importRouter.pendingURL = nil
                                pendingExternalURL = nil
                                externalImportActive = false
                            }
                            Button("Excel (XLSX/XLS)") {
                                showDocKindSheet = false
                                if let url = pendingExternalURL {
                                    applyExternal(kind: .excel, url: url)
                                }
                                importRouter.pendingURL = nil
                                pendingExternalURL = nil
                                externalImportActive = false
                            }
                            Button("ZIP Archive") {
                                showDocKindSheet = false
                                if let url = pendingExternalURL {
                                    applyExternal(kind: .zip, url: url)
                                }
                                importRouter.pendingURL = nil
                                pendingExternalURL = nil
                                externalImportActive = false
                            }
                        }
                        Button("Cancel", role: .cancel) {
                            importRouter.pendingURL = nil
                            pendingExternalURL = nil
                            externalImportActive = false
                            showDocKindSheet = false
                        }
                    }
                    .navigationTitle("Statement Type")
                    .navigationBarTitleDisplayMode(.inline)
                }
            }
            .fullScreenCover(isPresented: $showHelpSheet) {
                NavigationStack { HelpVideosView() }
                    .ignoresSafeArea()
            }
        }
        .navigationDestination(item: $phoneRoute) { (route: BatchRoute) in
            ImportBatchDetailView(batchID: route.id)
        }
    }

    @ViewBuilder
    private var ipadSidebar: some View {
        VStack(spacing: 0) {
            if batches.isEmpty {
                emptyStateView
            } else {
                List(selection: $selectedBatchID) {
                    Section {
                        ForEach(orderedBatches, id: \.persistentModelID) { (batch: ImportBatch) in
                            BatchRowContent(batch: batch)
                                .tag(batch.persistentModelID)
                        }
                    } header: {
                        Text("Already Imported")
                    }
                }
                .refreshable { await loadBatches() }
                .listStyle(.sidebar)
            }
            if settings.showHintBars {
                hintBar
            }
            backupSection
        }
    }

    @ViewBuilder
    private var ipadDetailContent: some View {
        NavigationStack {
            HStack(alignment: .top, spacing: 0) {
                Spacer(minLength: 0)
                Group {
                    if let pid = selectedBatchID, let batch = batches.first(where: { $0.persistentModelID == pid }) {
                        ImportBatchDetailView(batch: batch)
                            .environment(\.modelContext, modelContext)
                            .id(batch.persistentModelID)
                            .onAppear {
                                AMLogging.log("ImportFlowView: presenting detail for label=\(batch.label) id=\(batch.id) pid=\(batch.persistentModelID)", component: "ImportFlowView")
                            }
                    } else {
                        ContentUnavailableView(
                            "Select an Import",
                            systemImage: "tray",
                            description: Text("Choose an import from the sidebar.")
                        )
                    }
                }
                .frame(maxWidth: 640) // constrain inner content width
                .padding(.horizontal, 16)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top) // fill detail column, keep top aligned
           
            .navigationBarTitleDisplayMode(.inline)
//            .listStyle(.insetGrouped)
//            .contentMargins(.horizontal, 0, for: .scrollContent)
        }
//        .toolbar {
//            ToolbarItem(placement: .topBarLeading) {
//                Text(selectedBatchID == nil ? "" : "Update Transactions")
//                    .font(.largeTitle).bold()
//            }
//        }
    }

    private var ipadBody: some View {
        NavigationSplitView {
            ipadSidebar
                .navigationTitle("Import")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                      ToolbarItem(placement: .topBarLeading) {
                          Menu {
                              Section("PDF") {
                                  Button("Credit Card Statement") {
                                      pickerKind = .pdf
                                      vm.userSelectedDocHint = .creditCard
                                      vm.creditCardFlipOverride = settings.creditCardFlipDefault
                                      vm.newAccountType = .creditCard
                                      AMLogging.log("ImportFlowView: presenting PDF picker (Credit Card Statement)", component: "Import")
                                      isImporterPresented = true
                                  }
                                  Button("Loan Statement") {
                                      pickerKind = .pdf
                                      vm.userSelectedDocHint = .loan
                                      vm.newAccountType = .loan
                                      AMLogging.log("ImportFlowView: presenting PDF picker (Loan Statement)", component: "Import")
                                      isImporterPresented = true
                                  }
                                  Button("Bank Statement") {
                                      pickerKind = .pdf
                                      vm.userSelectedDocHint = .checking
                                      vm.newAccountType = .checking
                                      AMLogging.log("ImportFlowView: presenting PDF picker (Bank Statement)", component: "Import")
                                      isImporterPresented = true
                                  }
                                  Button("Brokerage Statement") {
                                      pickerKind = .pdf
                                      vm.userSelectedDocHint = .brokerage
                                      vm.newAccountType = .brokerage
                                      AMLogging.log("ImportFlowView: presenting PDF picker (Brokerage Statement)", component: "Import")
                                      isImporterPresented = true
                                  }
                                  Divider()
                                  Button("User-defined…") {
                                      vm.userSelectedDocHint = .creditCard
                                      vm.creditCardFlipOverride = settings.creditCardFlipDefault
                                      vm.newAccountType = .creditCard
                                      let manual = StagedImport(
                                          parserId: "manual.user",
                                          sourceFileName: "Manual Entry",
                                          inferredInstitutionName: nil,
                                          suggestedAccountType: vm.newAccountType,
                                          transactions: [],
                                          holdings: [],
                                          balances: []
                                      )
                                      vm.staged = manual
                                      vm.mappingSession = nil
                                      AMLogging.log("ImportFlowView: started manual user-defined import (credit card) — presenting ReviewImportView with empty staged import to add a balance", component: "Import")
                                  }
                              }
                              Section("CSV, OFX, QFX, QIF, XLSX, & ZIP") {
                                  Button("Credit Card Transactions") {
                                      pickerKind = .csv
                                      vm.userSelectedDocHint = .creditCard
                                      vm.creditCardFlipOverride = settings.creditCardFlipDefault
                                      vm.newAccountType = .creditCard // ADD THIS
                                      AMLogging.log("ImportFlowView: presenting CSV picker (Credit Card CSV)", component: "Import")
                                      isImporterPresented = true
                                  }
                                  Button("Loan Transactions") {
                                      pickerKind = .csv
                                      vm.userSelectedDocHint = .loan
                                      vm.newAccountType = .loan // ADD THIS
                                      AMLogging.log("ImportFlowView: presenting CSV picker (Loan CSV)", component: "Import")
                                      isImporterPresented = true
                                  }
                                  Button("Checking Transactions") {
                                      pickerKind = .csv
                                      vm.userSelectedDocHint = .checking
                                      vm.newAccountType = .checking // ADD THIS
                                      AMLogging.log("ImportFlowView: presenting CSV picker (Bank CSV)", component: "Import")
                                      isImporterPresented = true
                                  }
                                  Button("Savings Transactions") {
                                      pickerKind = .csv
                                      vm.userSelectedDocHint = .checking
                                      vm.newAccountType = .savings
                                      AMLogging.log("ImportFlowView: presenting CSV picker (Savings CSV)", component: "Import")
                                      isImporterPresented = true
                                  }
                                  Button("Brokerage Transactions") {
                                      pickerKind = .csv
                                      vm.userSelectedDocHint = .brokerage
                                      vm.newAccountType = .brokerage // ADD THIS
                                      AMLogging.log("ImportFlowView: presenting CSV picker (Brokerage CSV)", component: "Import")
                                      isImporterPresented = true
                                  }
                              }
                          } label: {
                              PlanMenuLabel(title: "Statements",titleFont: .caption)
                          }
                      }
                      ToolbarItem(placement: .topBarTrailing) {
                          Button {
                              showHelpSheet = true
                          } label: {
                              Image(systemName: "questionmark.circle")
                          }
                      }
                }
                .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 400)
        } detail: {
            ipadDetailContent
        }
        // Shared modifiers remain attached to the container so behavior remains the same
        .onAppear {
            AMLogging.log("ImportFlowView: modelContext id=\(ObjectIdentifier(modelContext))", component: "Import")
            let shouldShow = !purchases.isPremiumUnlocked
            if shouldShow && !externalImportActive && importRouter.pendingURL == nil && vm.staged == nil && vm.mappingSession == nil {
                presentPaywall(source: .fifthImport)
            }
            isActive = true
        }
        .onDisappear {
            isActive = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .transactionsDidChange)) { (_: Notification) in
            Task { await loadBatches() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .accountsDidChange)) { (_: Notification) in
            Task { await loadBatches() }
        }
        .onChange(of: pickerKind) {
            AMLogging.log("ImportFlowView: pickerKind changed to \(String(describing: pickerKind))", component: "Import")
        }
        .onReceive(vm.$staged) { (staged: StagedImport?) in
            if let staged {
                AMLogging.log("ImportFlowView: staged import ready — \(stagedLabelSummary(staged))", component: "Import")
                externalImportActive = false
            } else {
                AMLogging.log("ImportFlowView: staged import cleared", component: "Import")
                vm.mappingSession = nil
                suppressNextAutoNavigation = true
            }
        }
        .onReceive(vm.$mappingSession) { session in
            if let session {
                AMLogging.log("ImportFlowView: mapping session started — headers=\(session.headers.count)", component: "Import")
                AMLogging.log("ImportFlowView: attempting auto-apply mapping from onReceive — headers=\(session.headers), rows=\(session.sampleRows.count)", component: "Import")
                if settings.importAutoApplyMappings {
                    autoApplyMappingIfPossible(headers: session.headers, rows: session.sampleRows)
                }
                externalImportActive = false
            } else {
                AMLogging.log("ImportFlowView: mapping session cleared", component: "Import")
            }
        }
        .onChange(of: batches) {
            if isPad {
                let preferred = preferredSelectionID(in: batches)
                if let sel = selectedBatchID, !batches.contains(where: { $0.persistentModelID == sel }) {
                    selectedBatchID = preferred
                } else if selectedBatchID == nil {
                    selectedBatchID = preferred
                } else if let sel = selectedBatchID,
                          let current = batches.first(where: { $0.persistentModelID == sel }),
                          current.transactions.isEmpty && current.balances.isEmpty && current.holdings.isEmpty,
                          let pref = preferred, pref != sel {
                    selectedBatchID = pref
                }
            }
        }
        .onChange(of: selectedBatchID) {
            if let pid = selectedBatchID {
                let resolved = batches.first(where: { $0.persistentModelID == pid })
                AMLogging.log("ImportFlowView: selectedBatchID changed pid=\(pid) resolved=\(resolved != nil ? "yes" : "no")", component: "Import")
            } else {
                AMLogging.log("ImportFlowView: selectedBatchID cleared", component: "Import")
            }
        }
        .onChange(of: purchases.isPremiumUnlocked) { _, newValue in
            if newValue {
                showPaywall = false
            }
        }
        .onReceive(importRouter.$pendingURL) { (url: URL?) in
              if let url { handlePendingURLWithIntake(url) }
        }
        .sheet(isPresented: isSheetPresentedBinding) {
            sheetContent()
        }
        .sheet(
            isPresented: Binding(
                get: { showPaywall && !externalImportActive && vm.staged == nil && vm.mappingSession == nil },
                set: { showPaywall = $0 }
            )
        ) {
            PaywallView(source: paywallSource)
                .environmentObject(purchases)
        }
        .sheet(isPresented: $showDocKindSheet) {
            NavigationStack {
                List {
                    Section("PDF Statements") {
                        Button("Credit Card") {
                            showDocKindSheet = false
                            if let url = pendingExternalURL {
                                applyExternal(kind: .creditCard, url: url)
                            }
                            importRouter.pendingURL = nil
                            pendingExternalURL = nil
                            externalImportActive = false
                        }
                        Button("Loan") {
                            showDocKindSheet = false
                            if let url = pendingExternalURL {
                                applyExternal(kind: .loan, url: url)
                            }
                            importRouter.pendingURL = nil
                            pendingExternalURL = nil
                            externalImportActive = false
                        }
                        Button("Bank") {
                            showDocKindSheet = false
                            if let url = pendingExternalURL {
                                applyExternal(kind: .checking, url: url)
                            }
                            importRouter.pendingURL = nil
                            pendingExternalURL = nil
                            externalImportActive = false
                        }
                        Button("Brokerage") {
                            showDocKindSheet = false
                            if let url = pendingExternalURL {
                                applyExternal(kind: .brokerage, url: url)
                            }
                            importRouter.pendingURL = nil
                            pendingExternalURL = nil
                            externalImportActive = false
                        }
                    }
                    Section("Transactions") {
                        Button("CSV") {
                            showDocKindSheet = false
                            if let url = pendingExternalURL {
                                applyExternal(kind: .csv, url: url)
                            }
                            importRouter.pendingURL = nil
                            pendingExternalURL = nil
                            externalImportActive = false
                        }
                        Button("OFX/QFX/QBO") {
                            showDocKindSheet = false
                            if let url = pendingExternalURL {
                                applyExternal(kind: .ofx, url: url)
                            }
                            importRouter.pendingURL = nil
                            pendingExternalURL = nil
                            externalImportActive = false
                        }
                        Button("QIF") {
                            showDocKindSheet = false
                            if let url = pendingExternalURL {
                                applyExternal(kind: .qif, url: url)
                            }
                            importRouter.pendingURL = nil
                            pendingExternalURL = nil
                            externalImportActive = false
                        }
                        Button("Excel (XLSX/XLS)") {
                            showDocKindSheet = false
                            if let url = pendingExternalURL {
                                applyExternal(kind: .excel, url: url)
                            }
                            importRouter.pendingURL = nil
                            pendingExternalURL = nil
                            externalImportActive = false
                        }
                        Button("ZIP Archive") {
                            showDocKindSheet = false
                            if let url = pendingExternalURL {
                                applyExternal(kind: .zip, url: url)
                            }
                            importRouter.pendingURL = nil
                            pendingExternalURL = nil
                            externalImportActive = false
                        }
                    }
                    Button("Cancel", role: .cancel) {
                        importRouter.pendingURL = nil
                        pendingExternalURL = nil
                        externalImportActive = false
                        showDocKindSheet = false
                    }
                }
                .navigationTitle("Statement Type")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .sheet(isPresented: $showBackupSheet) {
            BackupRestoreView()
                .environmentObject(settings)
        }
        .fullScreenCover(isPresented: $showHelpSheet) {
            NavigationStack { HelpVideosView() }
                .ignoresSafeArea()
        }
        .task { await loadBatches() }
    }

    var body: some View {
        ZStack {
            if isPad {
                ipadBody
            } else {
                phoneBody
            }
            if vm.isImporting {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()

                VStack(spacing: 12) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.large)
                        .tint(.primary) // uses white on dark material, black on light material

                    Text("Importing…")
                        .font(.headline)
                        .foregroundStyle(.primary)
                }
                .padding(20)
                .background(.ultraThickMaterial) // or .regularMaterial
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(radius: 12)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Importing")
                .accessibilityAddTraits(.isModal)
            }
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: allowedTypesForCurrentPicker(),
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                guard purchases.isPremiumUnlocked else {
                    presentPaywall(source: .fifthImport)
                    return
                }
                beginCoordinatorImport(url, hint: statementHint(from: vm.newAccountType), source: "fileImporter")
            case .failure(let error):
                AMLogging.error("ImportFlowView: fileImporter failed — \(error.localizedDescription)", component: "Import")
                vm.errorMessage = error.localizedDescription
            }
        }
        .alert("Import Failed", isPresented: $showImportError) {
            Button("OK", role: .cancel) { vm.errorMessage = nil }
        } message: {
            Text(vm.errorMessage ?? "Unknown error")
        }
        .sheet(isPresented: $showBackupSheet) {
            BackupRestoreView()
                .environmentObject(settings)
        }
    }

    @Sendable private func loadBatches() async {
        do {
            var desc = FetchDescriptor<ImportBatch>()
            desc.sortBy = [SortDescriptor(\ImportBatch.createdAt, order: .reverse)]
            let fetched = try modelContext.fetch(desc)
            await MainActor.run {
                let completedImportCount = fetched.filter { batch in
                    batch.dataSetRaw != "sample"
                        && (!batch.transactions.isEmpty || !batch.balances.isEmpty || !batch.holdings.isEmpty)
                }.count
                purchases.synchronizeInitialFreeImportUsage(existingImportCount: completedImportCount)
                // Track previous IDs across loads to detect newly created batches; avoid auto-nav on initial load
                let previousIDs = self.lastKnownBatchIDs
                self.batches = fetched
                let currentIDs = Set(fetched.map { $0.id })
                let newIDs = currentIDs.subtracting(previousIDs)
                self.lastKnownBatchIDs = currentIDs
                let isInitialLoad = !self.hasLoadedBatchesOnce
                self.hasLoadedBatchesOnce = true

                let summary = fetched.map { batch in
                    "[label=\(batch.label), id=\(batch.id), pid=\(batch.persistentModelID)]"
                }.joined(separator: ", ")
                AMLogging.log("ImportFlowView: loaded batches count=\(fetched.count) details=\(summary)", component: "Import")

                // On phone, if a new non-empty batch was added and we're not in a sheet, navigate to it
                if !isPad && vm.staged == nil && vm.mappingSession == nil && !isInitialLoad && !self.suppressNextAutoNavigation {
                    let newNonEmpty = fetched
                        .filter { newIDs.contains($0.id) && (!($0.transactions.isEmpty) || !($0.balances.isEmpty) || !($0.holdings.isEmpty)) }
                        .sorted { $0.createdAt > $1.createdAt }
                    if let target = newNonEmpty.first {
                        self.phoneRoute = BatchRoute(id: target.id)
                        AMLogging.log("ImportFlowView: auto-navigating to new non-empty batch id=\(target.id)", component: "Import")
                    }
                }
                self.suppressNextAutoNavigation = false
            }
        } catch {
            await MainActor.run { self.batches = [] }
        }
    }
}
#Preview {
    ImportFlowView()
        .environmentObject(PurchaseManager.shared)
}
