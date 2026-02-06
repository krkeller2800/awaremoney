import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import Combine
import UIKit

struct ImportFlowView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var vm = ImportViewModel(parsers: ImportViewModel.defaultParsers())

    @State private var batches: [ImportBatch] = []
    @State private var isFileImporterPresented = false
    @State private var pickerKind: PickerKind? = nil
    @State private var selectedBatchID: PersistentIdentifier? = nil
    @State private var phoneRoute: BatchRoute? = nil
    @State private var lastKnownBatchIDs: Set<UUID> = []
    @State private var hasLoadedBatchesOnce: Bool = false
    @State private var suppressNextAutoNavigation: Bool = false

    private enum PickerKind { case csv, pdf }

    private var isPad: Bool {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad
        #else
        return false
        #endif
    }

    private func allowedTypesForCurrentPicker() -> [UTType] {
        switch pickerKind {
        case .csv:
            var types: [UTType] = [.commaSeparatedText]
            if let byExt = UTType(filenameExtension: "csv") { types.append(byExt) }
            return types
        case .pdf:
            return [.pdf]
        default:
            // Default to CSV to avoid overly broad file types
            var types: [UTType] = [.commaSeparatedText]
            if let byExt = UTType(filenameExtension: "csv") { types.append(byExt) }
            return types
        }
    }

    private var emptyStateView: some View {
        ContentUnavailableView(
            "No Imports Yet",
            systemImage: "tray",
            description: Text("Import CSV account activity or a PDF statement to get started.")
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
        batches.sorted { lhs, rhs in
            let lNonEmpty = !lhs.transactions.isEmpty || !lhs.balances.isEmpty || !lhs.holdings.isEmpty
            let rNonEmpty = !rhs.transactions.isEmpty || !rhs.balances.isEmpty || !rhs.holdings.isEmpty
            if lNonEmpty == rNonEmpty {
                return lhs.createdAt > rhs.createdAt
            }
            return lNonEmpty && !rNonEmpty
        }
    }
    
    @ViewBuilder
    private func importsSection() -> some View {
        if batches.isEmpty {
            emptyStateView
        } else {
            ForEach(orderedBatches, id: \.id) { batch in
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
            Text("Tip: For best results, import PDFs of current statements and add CSV activity for mid-month updates.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color(.systemGroupedBackground))
    }

    private var hintListFooter: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lightbulb")
                .imageScale(.medium)
                .foregroundStyle(.secondary)
            Text("Tip: For best results, import PDFs of current statements and add CSV activity for mid-month updates.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
        }
    }

    private func autoApplyMappingIfPossible(headers: [String], rows: [[String]]) {
        do {
            let saved = try modelContext.fetch(FetchDescriptor<CSVColumnMapping>())
            AMLogging.always("ImportFlowView: autoApplyMapping — savedMappings=\(saved.count), headers=\(headers), headerSet=\(Set(headers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }))", component: "Import")
            let headerSet = Set(headers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
            for map in saved {
                let values = map.mappings.values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                let isSubset = Set(values).isSubset(of: headerSet)
                AMLogging.always("ImportFlowView: autoApplyMapping — candidate='" + (map.label ?? "(unnamed)") + "' values=\(values) subset=\(isSubset)", component: "Import")
            }
            if let mapping = saved.first(where: { map in
                let values = map.mappings.values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                return Set(values).isSubset(of: headerSet)
            }) {
                do {
                    let parser = GenericCSVParser(mapping: mapping)
                    let staged = try parser.parse(rows: rows, headers: headers)
                    vm.staged = staged
                    vm.mappingSession = nil
                    AMLogging.always("ImportFlowView: auto-applied saved CSV mapping '" + (mapping.label ?? "(unnamed)") + "'", component: "Import")
                } catch {
                    AMLogging.error("ImportFlowView: auto-apply mapping failed: \(error.localizedDescription)", component: "Import")
                }
            } else {
                AMLogging.always("ImportFlowView: autoApplyMapping — no matching saved mapping; presenting editor", component: "Import")
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

        // Try common amount-like tokens first
        var amountHeader: String? = findHeader(containing: ["amount", "amt", "debit", "credit", "withdrawal", "deposit", "charge"])

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
                    return [.date, .payee, .memo, .amount, .category, .account, .balance, .runningBalance, .interestRateAPR]
                case .creditCard:
                    return [.date, .payee, .memo, .amount, .category, .account, .balance, .runningBalance, .interestRateAPR]
                case .brokerage:
                    return [.date, .symbol, .quantity, .price, .marketValue, .balance, .account]
                case .checking:
                    fallthrough
                default:
                    return [.date, .payee, .memo, .amount, .category, .account, .balance, .runningBalance]
                }
            }()

            NavigationStack {
                CSVMappingEditorView(
                    mapping: CSVColumnMapping(label: "New Mapping", mappings: Self.prefillMappings(from: session.headers, sampleRows: session.sampleRows)),
                    headers: session.headers,
                    onSave: { mapping in
                        AMLogging.always("ImportFlowView: CSVMappingEditorView.onSave — label='" + (mapping.label ?? "(unnamed)") + "' mappings=\(mapping.mappings)", component: "Import")
                        AMLogging.always("ImportFlowView: modelContext id=\(ObjectIdentifier(modelContext))", component: "Import")
                        // Persist the mapping
                        modelContext.insert(mapping)
                        do {
                            try modelContext.save()
                            AMLogging.always("ImportFlowView: save succeeded — mapping persistentID=\(String(describing: mapping.persistentModelID))", component: "Import")
                        } catch {
                            AMLogging.error("ImportFlowView: failed to save mapping — \(error.localizedDescription)", component: "Import")
                        }
                        do {
                            let all = try modelContext.fetch(FetchDescriptor<CSVColumnMapping>())
                            AMLogging.always("ImportFlowView: after save — total saved mappings=\(all.count)", component: "Import")
                            for m in all {
                                let vals = m.mappings.values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                                AMLogging.always("ImportFlowView: mapping catalog — label='" + (m.label ?? "(unnamed)") + "' values=\(vals)", component: "Import")
                            }
                        } catch {
                            AMLogging.error("ImportFlowView: fetch after save failed — \(error.localizedDescription)", component: "Import")
                        }
                        // Immediately parse using the session's rows and headers
                        do {
                            let parser = GenericCSVParser(mapping: mapping)
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
                    AMLogging.always("ImportFlowView: CSVMappingEditorView appearing — staged=\(vm.staged != nil), mappingSession=\(vm.mappingSession != nil)", component: "Import")
                }
            }
        } else {
            EmptyView()
        }
    }

    private var phoneBody: some View {
        NavigationStack {
            VStack(spacing: 0) {
                List {
                    Section {
                        importsSection()
                    } header: {
                        Text("Imports")
                    }
                }

                hintBar
            }
            .navigationTitle("Import")
            .onAppear { AMLogging.always("ImportFlowView: modelContext id=\(ObjectIdentifier(modelContext))", component: "Import") }
            .task { await loadBatches() }
            .refreshable { await loadBatches() }
            .onReceive(NotificationCenter.default.publisher(for: .transactionsDidChange)) { _ in
                Task { await loadBatches() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .accountsDidChange)) { _ in
                Task { await loadBatches() }
            }
            .onChange(of: pickerKind) {
                AMLogging.always("ImportFlowView: pickerKind changed to \(String(describing: pickerKind))", component: "Import")
            }
            .onReceive(vm.$staged) { staged in
                if let staged {
                    AMLogging.always("ImportFlowView: staged import ready — parser=\(staged.parserId), balances=\(staged.balances.count), tx=\(staged.transactions.count)", component: "Import")
                } else {
                    AMLogging.always("ImportFlowView: staged import cleared", component: "Import")
                    suppressNextAutoNavigation = true
                }
            }
            .onReceive(vm.$mappingSession) { session in
                if let session {
                    AMLogging.always("ImportFlowView: mapping session started — headers=\(session.headers.count)", component: "Import")
                    AMLogging.always("ImportFlowView: attempting auto-apply mapping from onReceive — headers=\(session.headers), rows=\(session.sampleRows.count)", component: "Import")
                    autoApplyMappingIfPossible(headers: session.headers, rows: session.sampleRows)
                } else {
                    AMLogging.always("ImportFlowView: mapping session cleared", component: "Import")
                }
            }
            .fileImporter(
                isPresented: $isFileImporterPresented,
                allowedContentTypes: allowedTypesForCurrentPicker(),
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        AMLogging.always("ImportFlowView: picked file \(url.lastPathComponent) (ext=\(url.pathExtension))", component: "Import")
                        vm.handlePickedURL(url)
                    }
                case .failure:
                    break
                }
            }
            .sheet(isPresented: .constant(vm.staged != nil || vm.mappingSession != nil)) {
                sheetContent()
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu("Import PDF") {
                        Button("Loan Statement") {
                            pickerKind = .pdf
                            vm.userSelectedDocHint = .loan
                            AMLogging.always("ImportFlowView: presenting PDF picker (Loan Statement)", component: "Import")
                            isFileImporterPresented = true
                        }
                        Button("Bank Statement") {
                            pickerKind = .pdf
                            vm.userSelectedDocHint = .checking
                            AMLogging.always("ImportFlowView: presenting PDF picker (Bank Statement)", component: "Import")
                            isFileImporterPresented = true
                        }
                        Button("Brokerage Statement") {
                            pickerKind = .pdf
                            vm.userSelectedDocHint = .brokerage
                            AMLogging.always("ImportFlowView: presenting PDF picker (Brokerage Statement)", component: "Import")
                            isFileImporterPresented = true
                        }
                        Button("Credit Card Statement") {
                            pickerKind = .pdf
                            vm.userSelectedDocHint = .creditCard
                            vm.newAccountType = .creditCard
                            AMLogging.always("ImportFlowView: presenting PDF picker (Credit Card Statement)", component: "Import")
                            isFileImporterPresented = true
                        }
                        Divider()
                        Button("User-defined…") {
                            vm.startManualImport(kind: .creditCard)
                            AMLogging.always("ImportFlowView: started manual user-defined import (credit card)", component: "Import")
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu("Import CSV") {
                        Button("Loan CSV") {
                            pickerKind = .csv
                            vm.userSelectedDocHint = .loan
                            AMLogging.always("ImportFlowView: presenting CSV picker (Loan CSV)", component: "Import")
                            isFileImporterPresented = true
                        }
                        Button("Bank CSV") {
                            pickerKind = .csv
                            vm.userSelectedDocHint = .checking
                            AMLogging.always("ImportFlowView: presenting CSV picker (Bank CSV)", component: "Import")
                            isFileImporterPresented = true
                        }
                        Button("Brokerage CSV") {
                            pickerKind = .csv
                            vm.userSelectedDocHint = .brokerage
                            AMLogging.always("ImportFlowView: presenting CSV picker (Brokerage CSV)", component: "Import")
                            isFileImporterPresented = true
                        }
                        Button("Credit Card CSV") {
                            pickerKind = .csv
                            vm.userSelectedDocHint = .creditCard
                            AMLogging.always("ImportFlowView: presenting CSV picker (Credit Card CSV)", component: "Import")
                            isFileImporterPresented = true
                        }
                    }
                }
            }
            .navigationDestination(item: $phoneRoute) { route in
                ImportBatchDetailView(batchID: route.id)
            }
        }
    }

    private var ipadBody: some View {
        HStack(spacing: 0) {
            // LEFT: Sidebar NavigationStack with toolbar and title
            NavigationStack {
                List(selection: $selectedBatchID) {
                    Section {
                        if batches.isEmpty {
                            emptyStateView
                        } else {
                            ForEach(orderedBatches, id: \.persistentModelID) { batch in
                                BatchRowContent(batch: batch)
                                    .tag(batch.persistentModelID)
                            }
                        }
                    } header: {
                        Text("Imports")
                    } footer: {
                        hintListFooter
                    }
                }
                .refreshable { await loadBatches() }
                .listStyle(.sidebar)
                .navigationTitle("Import")
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Menu("PDF") {
                            Button("Loan Statement") {
                                pickerKind = .pdf
                                vm.userSelectedDocHint = .loan
                                AMLogging.always("ImportFlowView: presenting PDF picker (Loan Statement)", component: "Import")
                                isFileImporterPresented = true
                            }
                            Button("Bank Statement") {
                                pickerKind = .pdf
                                vm.userSelectedDocHint = .checking
                                AMLogging.always("ImportFlowView: presenting PDF picker (Bank Statement)", component: "Import")
                                isFileImporterPresented = true
                            }
                            Button("Brokerage Statement") {
                                pickerKind = .pdf
                                vm.userSelectedDocHint = .brokerage
                                AMLogging.always("ImportFlowView: presenting PDF picker (Brokerage Statement)", component: "Import")
                                isFileImporterPresented = true
                            }
                            Button("Credit Card Statement") {
                                pickerKind = .pdf
                                vm.userSelectedDocHint = .creditCard
                                vm.newAccountType = .creditCard
                                AMLogging.always("ImportFlowView: presenting PDF picker (Credit Card Statement)", component: "Import")
                                isFileImporterPresented = true
                            }
                            Divider()
                            Button("User-defined…") {
                                vm.startManualImport(kind: .creditCard)
                                AMLogging.always("ImportFlowView: started manual user-defined import (credit card)", component: "Import")
                            }
                        }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Menu("CSV") {
                            Button("Loan CSV") {
                                pickerKind = .csv
                                vm.userSelectedDocHint = .loan
                                AMLogging.always("ImportFlowView: presenting CSV picker (Loan CSV)", component: "Import")
                                isFileImporterPresented = true
                            }
                            Button("Bank CSV") {
                                pickerKind = .csv
                                vm.userSelectedDocHint = .checking
                                AMLogging.always("ImportFlowView: presenting CSV picker (Bank CSV)", component: "Import")
                                isFileImporterPresented = true
                            }
                            Button("Brokerage CSV") {
                                pickerKind = .csv
                                vm.userSelectedDocHint = .brokerage
                                AMLogging.always("ImportFlowView: presenting CSV picker (Brokerage CSV)", component: "Import")
                                isFileImporterPresented = true
                            }
                            Button("Credit Card CSV") {
                                pickerKind = .csv
                                vm.userSelectedDocHint = .creditCard
                                AMLogging.always("ImportFlowView: presenting CSV picker (Credit Card CSV)", component: "Import")
                                isFileImporterPresented = true
                            }
                        }
                    }
                }
            }
            .frame(minWidth: 300, idealWidth: 340, maxWidth: 400)

            Divider()

            // RIGHT: Detail NavigationStack so it has its own title
            NavigationStack {
                Group {
                    if let pid = selectedBatchID, let batch = batches.first(where: { $0.persistentModelID == pid }) {
                        ImportBatchDetailView(batch: batch)
                            .environment(\.modelContext, modelContext)
                            .id(batch.persistentModelID)
                            .onAppear {
                                AMLogging.always("ImportFlowView: presenting detail for label=\(batch.label) id=\(batch.id) pid=\(batch.persistentModelID)", component: "Import")
                            }
                    } else {
                        ContentUnavailableView(
                            "Select an Import",
                            systemImage: "tray",
                            description: Text("Choose an import from the sidebar.")
                        )
                    }
                }
                .navigationTitle(selectedBatchID == nil ? "" : "Update Transactions")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        // Attach shared modifiers to the outer container so behavior remains the same
        .onAppear { AMLogging.always("ImportFlowView: modelContext id=\(ObjectIdentifier(modelContext))", component: "Import") }
        .onReceive(NotificationCenter.default.publisher(for: .transactionsDidChange)) { _ in
            Task { await loadBatches() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .accountsDidChange)) { _ in
            Task { await loadBatches() }
        }
        .onChange(of: pickerKind) {
            AMLogging.always("ImportFlowView: pickerKind changed to \(String(describing: pickerKind))", component: "Import")
        }
        .onReceive(vm.$staged) { staged in
            if let staged {
                AMLogging.always("ImportFlowView: staged import ready — parser=\(staged.parserId), balances=\(staged.balances.count), tx=\(staged.transactions.count)", component: "Import")
            } else {
                AMLogging.always("ImportFlowView: staged import cleared", component: "Import")
                suppressNextAutoNavigation = true
            }
        }
        .onReceive(vm.$mappingSession) { session in
            if let session {
                AMLogging.always("ImportFlowView: mapping session started — headers=\(session.headers.count)", component: "Import")
                AMLogging.always("ImportFlowView: attempting auto-apply mapping from onReceive — headers=\(session.headers), rows=\(session.sampleRows.count)", component: "Import")
                autoApplyMappingIfPossible(headers: session.headers, rows: session.sampleRows)
            } else {
                AMLogging.always("ImportFlowView: mapping session cleared", component: "Import")
            }
        }
        .onChange(of: batches) {
            if isPad {
                let preferred = preferredSelectionID(in: batches)
                // If the current selection disappeared, or is nil, select the preferred batch
                if let sel = selectedBatchID, !batches.contains(where: { $0.persistentModelID == sel }) {
                    selectedBatchID = preferred
                } else if selectedBatchID == nil {
                    selectedBatchID = preferred
                } else if let sel = selectedBatchID,
                          let current = batches.first(where: { $0.persistentModelID == sel }),
                          current.transactions.isEmpty && current.balances.isEmpty && current.holdings.isEmpty,
                          let pref = preferred, pref != sel {
                    // If a non-empty batch exists, prefer it over an empty selection
                    selectedBatchID = pref
                }
            }
        }
        .onChange(of: selectedBatchID) {
            if let pid = selectedBatchID {
                let resolved = batches.first(where: { $0.persistentModelID == pid })
                AMLogging.always("ImportFlowView: selectedBatchID changed pid=\(pid) resolved=\(resolved != nil ? "yes" : "no")", component: "Import")
            } else {
                AMLogging.always("ImportFlowView: selectedBatchID cleared", component: "Import")
            }
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: allowedTypesForCurrentPicker(),
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    AMLogging.always("ImportFlowView: picked file \(url.lastPathComponent) (ext=\(url.pathExtension))", component: "Import")
                    vm.handlePickedURL(url)
                }
            case .failure:
                break
            }
        }
        .sheet(isPresented: .constant(vm.staged != nil || vm.mappingSession != nil)) {
            sheetContent()
        }
        .task { await loadBatches() }
    }

    var body: some View {
        if isPad {
            ipadBody
        } else {
            phoneBody
        }
    }

    @Sendable private func loadBatches() async {
        do {
            var desc = FetchDescriptor<ImportBatch>()
            desc.sortBy = [SortDescriptor(\ImportBatch.createdAt, order: .reverse)]
            let fetched = try modelContext.fetch(desc)
            await MainActor.run {
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
                AMLogging.always("ImportFlowView: loaded batches count=\(fetched.count) details=\(summary)", component: "Import")

                // On phone, if a new non-empty batch was added and we're not in a sheet, navigate to it
                if !isPad && vm.staged == nil && vm.mappingSession == nil && !isInitialLoad && !self.suppressNextAutoNavigation {
                    let newNonEmpty = fetched
                        .filter { newIDs.contains($0.id) && (!($0.transactions.isEmpty) || !($0.balances.isEmpty) || !($0.holdings.isEmpty)) }
                        .sorted { $0.createdAt > $1.createdAt }
                    if let target = newNonEmpty.first {
                        self.phoneRoute = BatchRoute(id: target.id)
                        AMLogging.always("ImportFlowView: auto-navigating to new non-empty batch id=\(target.id)", component: "Import")
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
}

