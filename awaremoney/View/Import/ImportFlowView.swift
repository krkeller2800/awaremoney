import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import Combine
import UIKit
import StoreKit

struct ImportFlowView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var purchases: PurchaseManager
    @EnvironmentObject private var importRouter: ImportOpenRouter
    @EnvironmentObject private var backupCoordinator: BackupOpenCoordinator
    @StateObject private var vm = ImportViewModel(parsers: ImportViewModel.defaultParsers())

    @State private var batches: [ImportBatch] = []
    @State private var pickerKind: PickerKind? = nil
    @State private var selectedBatchID: PersistentIdentifier? = nil
    @State private var phoneRoute: BatchRoute? = nil
    @State private var lastKnownBatchIDs: Set<UUID> = []
    @State private var hasLoadedBatchesOnce: Bool = false
    @State private var suppressNextAutoNavigation: Bool = false
    @State private var showPaywall: Bool = false
    @State private var externalImportActive: Bool = false
    @State private var showImportError: Bool = false

    @State private var pendingExternalURL: URL? = nil
    @State private var isActive: Bool = false

    // Additional state for the new fileImporter binding as per instructions
    @State private var isImporterPresented: Bool = false
    @State private var showDocKindSheet: Bool = false

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    
    private enum PickerKind { case csv, pdf }

    private enum ExternalDocKind: String, CaseIterable, Identifiable {
        case creditCard = "Credit Card Statement"
        case loan = "Loan Statement"
        case checking = "Bank Statement"
        case brokerage = "Brokerage Statement"
        case csv = "CSV/Activity"
        var id: String { rawValue }
    }

    private func applyExternal(kind: ExternalDocKind, url: URL) {
        switch kind {
        case .creditCard:
            vm.userSelectedDocHint = .creditCard
            vm.creditCardFlipOverride = settings.creditCardFlipDefault
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
        }
        let isPDF = url.pathExtension.lowercased() == "pdf"
        DispatchQueue.main.async {
            if isPDF {
                self.handlePDFSnapshotImport(url: url)
            } else {
                self.vm.handlePickedURL(url)
            }
        }
        AMLogging.always("ImportFlowView: applyExternal called with kind=\(kind.rawValue) url=\(url.lastPathComponent)", component: "Import")
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

    private func autoApplyMappingIfPossible(headers: [String], rows: [[String]]) {
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
                    let parser = GenericCSVParser(mapping: mapping)
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

    private func deduplicateStagedBalancesPreferringNonZeroSameDay(_ snaps: [StagedBalance]) -> [StagedBalance] {
        if snaps.isEmpty { return snaps }
        var chosen: [String: StagedBalance] = [:]
        var order: [String] = []
        let cal = Calendar.current
        for snap in snaps {
            let label = (snap.sourceAccountLabel ?? "default").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let dayStart = cal.startOfDay(for: snap.asOfDate).timeIntervalSince1970
            let key = "\(label)|\(Int(dayStart))"
            if let existing = chosen[key] {
                if existing.balance == .zero && snap.balance != .zero {
                    chosen[key] = snap
                } else {
                    // keep existing (either both zero or both non-zero)
                }
            } else {
                chosen[key] = snap
                order.append(key)
            }
        }
        return order.compactMap { chosen[$0] }
    }
    
    private func deduplicateStagedBalancesForCreditCard(_ snaps: [StagedBalance]) -> [StagedBalance] {
        // Credit card tweak: de-duplicate by calendar day only (ignore labels),
        // prefer non-zero over zero, and when both are non-zero with opposite signs,
        // prefer the negative value (liability convention).
        if snaps.isEmpty { return snaps }
        var chosen: [Int: StagedBalance] = [:]
        var order: [Int] = []
        let cal = Calendar.current
        for snap in snaps {
            let dayStart = cal.startOfDay(for: snap.asOfDate).timeIntervalSince1970
            let key = Int(dayStart)
            if let existing = chosen[key] {
                let e = existing.balance
                let s = snap.balance
                if e == .zero && s != .zero {
                    chosen[key] = snap
                } else if e != .zero && s != .zero {
                    // Prefer negative when signs differ
                    if (e >= 0 && s < 0) {
                        chosen[key] = snap
                    } else {
                        // keep existing
                    }
                } else {
                    // keep existing (both zero or new is zero)
                }
            } else {
                chosen[key] = snap
                order.append(key)
            }
        }
        return order.compactMap { chosen[$0] }
    }
    
    private func handlePDFSnapshotImport(url: URL) {
        // Show global importing overlay
        vm.isImporting = true
        Task {
            defer { DispatchQueue.main.async { self.vm.isImporting = false } }

            // Capture the current hint on the main actor
            let hintOpt = await MainActor.run { self.vm.userSelectedDocHint }
            guard let hint = hintOpt else {
                AMLogging.log("ImportFlowView: handlePDFSnapshotImport called without a userSelectedDocHint; falling back to default handler", component: "Import")
                // Fall back to default handler on the main actor
                await MainActor.run { self.vm.handlePickedURL(url) }
                return
            }
            AMLogging.log("ImportFlowView: handlePDFSnapshotImport hint=\(hint) file=\(url.lastPathComponent)", component: "Import")

            do {
                // Start security scoped access
                let didStart = url.startAccessingSecurityScopedResource()
                AMLogging.log("ImportFlowView: security scope started=\(didStart) for file=\(url.path)", component: "Import")
                defer {
                    if didStart {
                        url.stopAccessingSecurityScopedResource()
                        AMLogging.log("ImportFlowView: security scope stopped for file=\(url.path)", component: "Import")
                    }
                }

                // Cache the picked PDF to the app's Caches directory so we can preview it later
                do {
                    let fm = FileManager.default
                    if let caches = try? fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true) {
                        let dest = caches.appendingPathComponent(url.lastPathComponent)
                        AMLogging.log("ImportFlowView: caching picked PDF to: \(dest.path)", component: "Import")
                        // Remove any existing file at the destination to avoid copy errors
                        try? fm.removeItem(at: dest)
                        if fm.fileExists(atPath: url.path) {
                            do {
                                try fm.copyItem(at: url, to: dest)
                                await MainActor.run { self.vm.lastPickedLocalURL = dest }
                                AMLogging.log("ImportFlowView: cached PDF copied; lastPickedLocalURL set", component: "Import")
                            } catch {
                                AMLogging.error("ImportFlowView: failed to cache PDF copy — \(error.localizedDescription)", component: "Import")
                            }
                        } else {
                            AMLogging.log("ImportFlowView: picked PDF path does not exist at \(url.path)", component: "Import")
                        }
                    }
                }

                // Heavy work: extract and parse
                let importer = StatementImporter()
                // Request Summary behavior for bank/loan/brokerage, but fall back to .transactions if summary mode isn't available
                let requestedSummary: Bool = {
                    switch hint {
                    case .creditCard: return false
                    case .loan, .brokerage, .checking: return true
                    default: return true
                    }
                }()
                // Current extractor doesn't expose a .summary case; use .transactions and rely on augmentation + PDFSummaryParser
                let preferMode: PDFStatementExtractor.Mode = .transactions
                let userOverride: StatementImporter.UserOverride? = {
                    switch hint {
                    case .creditCard: return .creditCard
                    case .loan: return .loan
                    case .brokerage: return .brokerage
                    case .checking: return .bank
                    default: return nil
                    }
                }()
                let result = try importer.importStatement(from: url, prefer: preferMode, userOverride: userOverride)
                AMLogging.log("ImportFlowView: StatementImporter invoked with preferMode=\(preferMode) requestedSummary=\(requestedSummary) userOverride=\(String(describing: userOverride))", component: "Import")
                AMLogging.log("ImportFlowView: StatementImporter returned rows=\(result.rows.count) headers=\(result.headers)", component: "Import")

                // Augment extractor output with raw PDF text and synthetic sections (mirrors Replace flow behavior)
                var augmentedRows = result.rows
                let augmentedHeaders = result.headers
                if let fullText = PDFTextExtractor.extractText(from: url) {
                    AMLogging.log("ImportFlowView: PDF raw text length=\(fullText.count)", component: "Import")
                    if let interestSection = PDFTextExtractor.extractInterestChargesSection(from: fullText) {
                        AMLogging.log("ImportFlowView: Interest Charges section found — length=\(interestSection.count)", component: "Import")
                        augmentedRows.append([interestSection])
                    } else {
                        AMLogging.log("ImportFlowView: Interest Charges section not found in raw text", component: "Import")
                    }
                    if let balanceSection = PDFTextExtractor.extractBalanceSummarySection(from: fullText) {
                        AMLogging.log("ImportFlowView: Balance Summary section found — length=\(balanceSection.count)", component: "Import")
                        augmentedRows.append([balanceSection])
                    } else {
                        AMLogging.log("ImportFlowView: Balance Summary section not found in raw text", component: "Import")
                    }
                    AMLogging.log("ImportFlowView: appending full document text as synthetic row", component: "Import")
                    augmentedRows.append([fullText])
                }

                AMLogging.log("ImportFlowView: about to attempt PDFSummaryParser — headers=\(augmentedHeaders.count) rows=\(augmentedRows.count)", component: "Import")
                var staged: StagedImport
                do {
                    let summaryParser = PDFSummaryParser()
                    staged = try summaryParser.parse(rows: augmentedRows, headers: augmentedHeaders)
                    AMLogging.log("ImportFlowView: PDFSummaryParser succeeded — balances=\(staged.balances.count) tx=\(staged.transactions.count)", component: "Import")
                    AMLogging.log("ImportFlowView: finished PDFSummaryParser attempt (success path)", component: "Import")
                } catch {
                    AMLogging.log("ImportFlowView: PDFSummaryParser failed (\(error.localizedDescription)) — attempting default parsers", component: "Import")
                    let parsers = ImportViewModel.defaultParsers()
                    let matching = parsers.filter { $0.canParse(headers: augmentedHeaders) }
                    if let parser = matching.first {
                        staged = try parser.parse(rows: augmentedRows, headers: augmentedHeaders)
                        AMLogging.log("ImportFlowView: fallback parser succeeded — parser=\(type(of: parser)) balances=\(staged.balances.count) tx=\(staged.transactions.count)", component: "Import")
                        AMLogging.log("ImportFlowView: finished PDFSummaryParser attempt (fallback success)", component: "Import")
                    } else {
                        AMLogging.log("ImportFlowView: finished PDFSummaryParser attempt (no parser matched; falling back)", component: "Import")
                        AMLogging.log("ImportFlowView: no parser matched augmented PDF — falling back to default handler", component: "Import")
                        await MainActor.run { self.vm.handlePickedURL(url) }
                        let stagedAfter = await MainActor.run { self.vm.staged }
                        if stagedAfter == nil {
                            await MainActor.run {
                                self.vm.errorMessage = "We couldn’t read this credit card statement. Try importing a CSV activity export instead."
                                self.showImportError = true
                            }
                        }
                        return
                    }
                }

                staged.sourceFileName = url.lastPathComponent

                // In non-liability contexts (bank/brokerage), normalize balances to positive values
                if hint != .creditCard && hint != .loan {
                    var flipped = 0
                    for i in staged.balances.indices {
                        if staged.balances[i].balance < 0 {
                            staged.balances[i].balance = -staged.balances[i].balance
                            flipped += 1
                        }
                    }
                    if flipped > 0 {
                        AMLogging.log("ImportFlowView: normalized \(flipped) negative balances to positive for non-liability context", component: "Import")
                    }
                }

                // If the user hinted this is a loan statement, suppress any document-level CC coercion by relabeling snapshots
                if hint == .loan {
                    var relabeled = 0
                    for i in staged.balances.indices {
                        let lbl = (staged.balances[i].sourceAccountLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        if lbl == "creditcard" {
                            staged.balances[i].sourceAccountLabel = "loan"
                            relabeled += 1
                        }
                    }
                    if relabeled > 0 {
                        AMLogging.log("ImportFlowView: suppressed CC coercion per .loan hint — relabeled \(relabeled) snapshot(s) to 'loan'", component: "Import")
                    }
                }
                // If the user hinted this is a bank/checking statement, suppress any document-level CC coercion by relabeling snapshots
                if hint == .checking {
                    var relabeled = 0
                    for i in staged.balances.indices {
                        let lbl = (staged.balances[i].sourceAccountLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        if lbl == "creditcard" || lbl == "credit card" {
                            staged.balances[i].sourceAccountLabel = "checking"
                            relabeled += 1
                        }
                    }
                    if relabeled > 0 {
                        AMLogging.log("ImportFlowView: suppressed CC coercion per .checking hint — relabeled \(relabeled) snapshot(s) to 'checking'", component: "Import")
                    }
                }

                AMLogging.log("Pre-dedupe balances: " + staged.balances.map { b in
                    let lbl = (b.sourceAccountLabel ?? "nil")
                    return "[date=\(b.asOfDate), amt=\(b.balance), label=\(lbl)]"
                }.joined(separator: ", "), component: "Import")
                // Prefer non-zero snapshots when multiple exist for the same day
                let before = staged.balances.count
                if hint == .creditCard {
                    staged.balances = deduplicateStagedBalancesForCreditCard(staged.balances)
                } else {
                    staged.balances = deduplicateStagedBalancesPreferringNonZeroSameDay(staged.balances)
                }
                AMLogging.log("ImportFlowView: balance de-dup (PDF snapshot) before=\(before) after=\(staged.balances.count)", component: "Import")

                // Surface any importer warnings as an info message
                if !result.warnings.isEmpty {
                    await MainActor.run { self.vm.infoMessage = result.warnings.joined(separator: "\n") }
                }

                // Set the default account type based on the user hint
                await MainActor.run {
                    switch hint {
                    case .loan:
                        self.vm.newAccountType = .loan
                    case .creditCard:
                        self.vm.newAccountType = .creditCard
                    case .brokerage:
                        self.vm.newAccountType = .brokerage
                    case .checking:
                        self.vm.newAccountType = .checking
                    default:
                        break
                    }
                }

                // Apply liability safety net in credit-card context to relabel ambiguous balances
                if hint == .creditCard {
                    await MainActor.run { self.vm.applyLiabilityLabelSafetyNetIfNeeded(to: &staged) }
                }

                // Prefer Purchases APR when available for credit card statements
                if hint == .creditCard {
                    if let fullText = PDFTextExtractor.extractText(from: url),
                       let (apr, scale) = PDFTextExtractor.extractPreferredAPR(from: fullText) {
                        var applied = 0
                        for i in staged.balances.indices {
                            // Only set if missing or if previously set APR is higher (e.g., cash advance); prefer the lower rate as a heuristic
                            if let existing = staged.balances[i].interestRateAPR {
                                if apr < existing {
                                    staged.balances[i].interestRateAPR = apr
                                    staged.balances[i].interestRateScale = scale
                                    let existingLabel = (staged.balances[i].sourceAccountLabel ?? "").trimmingCharacters(in: .whitespaces)
                                    staged.balances[i].sourceAccountLabel = (existingLabel.isEmpty ? "apr:purchases" : existingLabel + " apr:purchases")
                                    applied += 1
                                }
                            } else {
                                staged.balances[i].interestRateAPR = apr
                                staged.balances[i].interestRateScale = scale
                                let existingLabel = (staged.balances[i].sourceAccountLabel ?? "").trimmingCharacters(in: .whitespaces)
                                staged.balances[i].sourceAccountLabel = (existingLabel.isEmpty ? "apr:purchases" : existingLabel + " apr:purchases")
                                applied += 1
                            }
                        }
                        if applied > 0 {
                            AMLogging.log("ImportFlowView: applied preferred APR (likely Purchases) to \(applied) balance snapshot(s)", component: "Import")
                        }
                    }
                }

                // Commit staged import and clear any mapping session on the main actor
                await MainActor.run {
                    self.vm.staged = staged
                    self.vm.mappingSession = nil
                }
                AMLogging.log("ImportFlowView: staged import prepared (PDF snapshot) — balances=\(staged.balances.count), tx=\(staged.transactions.count)", component: "Import")
            } catch {
                AMLogging.error("ImportFlowView: PDF snapshot import failed — \(error.localizedDescription). Falling back to default handler.", component: "Import")
                await MainActor.run { self.vm.handlePickedURL(url) }
                let stagedAfter = await MainActor.run { self.vm.staged }
                if stagedAfter == nil {
                    await MainActor.run {
                        self.vm.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        self.showImportError = true
                    }
                }
            }
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
                            Button("Credit Card Statement") {
                                pickerKind = .pdf
                                vm.userSelectedDocHint = .creditCard
                                vm.creditCardFlipOverride = settings.creditCardFlipDefault
                                vm.newAccountType = .creditCard
                                AMLogging.log("ImportFlowView: presenting PDF picker (Credit Card Statement)", component: "Import")
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
                        } label: {
                            PlanMenuLabel(title: "PDF")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("Loan CSV") {
                                pickerKind = .csv
                                vm.userSelectedDocHint = .loan
                                AMLogging.log("ImportFlowView: presenting CSV picker (Loan CSV)", component: "Import")
                                isImporterPresented = true
                            }
                            Button("Bank CSV") {
                                pickerKind = .csv
                                vm.userSelectedDocHint = .checking
                                AMLogging.log("ImportFlowView: presenting CSV picker (Bank CSV)", component: "Import")
                                isImporterPresented = true
                            }
                            Button("Brokerage CSV") {
                                pickerKind = .csv
                                vm.userSelectedDocHint = .brokerage
                                AMLogging.log("ImportFlowView: presenting CSV picker (Brokerage CSV)", component: "Import")
                                isImporterPresented = true
                            }
                            Button("Credit Card CSV") {
                                pickerKind = .csv
                                vm.userSelectedDocHint = .creditCard
                                vm.creditCardFlipOverride = settings.creditCardFlipDefault
                                AMLogging.log("ImportFlowView: presenting CSV picker (Credit Card CSV)", component: "Import")
                                isImporterPresented = true
                            }
                        } label: {
                            PlanMenuLabel(title: "CSV")
                        }
                    }
                }
                if settings.showHintBars {
                    hintBar
                }
            }
            .onAppear {
                AMLogging.log("ImportFlowView: modelContext id=\(ObjectIdentifier(modelContext))", component: "Import")
                isActive = true
//                showPaywall = (!purchases.isPremiumUnlocked && !purchases.isInTrial)
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
                    AMLogging.log("ImportFlowView: staged import ready — parser=\(staged.parserId), balances=\(staged.balances.count), tx=\(staged.transactions.count)", component: "Import")
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
                  if let url {
                      externalImportActive = true
                      pendingExternalURL = url
                      showPaywall = false
                      AMLogging.always("ImportFlowView: received external URL \(url.lastPathComponent), preparing doc kind chooser", component: "Import")
                      showDocKindSheet = true
                  }
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
                PaywallView()
                    .environmentObject(purchases)
            }
            .sheet(isPresented: $showDocKindSheet) {
                NavigationStack {
                    List {
                        ForEach(ExternalDocKind.allCases) { (kind: ExternalDocKind) in
                            Button(kind.rawValue) {
                                showDocKindSheet = false
                                if let url = pendingExternalURL {
                                    applyExternal(kind: kind, url: url)
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
        }
    }

    @ViewBuilder
    private var ipadDetailContent: some View {
        NavigationStack {
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
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(selectedBatchID == nil ? "" : "Update Transactions")
                        .font(.largeTitle).bold()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .frame(maxWidth: 640, maxHeight: .infinity, alignment: .topLeading)
        }
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
                                  Button("Credit Card Statement") {
                                      pickerKind = .pdf
                                      vm.userSelectedDocHint = .creditCard
                                      vm.creditCardFlipOverride = settings.creditCardFlipDefault
                                      vm.newAccountType = .creditCard
                                      AMLogging.log("ImportFlowView: presenting PDF picker (Credit Card Statement)", component: "Import")
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
                              Section("CSV") {
                                  Button("Loan CSV") {
                                      pickerKind = .csv
                                      vm.userSelectedDocHint = .loan
                                      AMLogging.log("ImportFlowView: presenting CSV picker (Loan CSV)", component: "Import")
                                      isImporterPresented = true
                                  }
                                  Button("Bank CSV") {
                                      pickerKind = .csv
                                      vm.userSelectedDocHint = .checking
                                      AMLogging.log("ImportFlowView: presenting CSV picker (Bank CSV)", component: "Import")
                                      isImporterPresented = true
                                  }
                                  Button("Brokerage CSV") {
                                      pickerKind = .csv
                                      vm.userSelectedDocHint = .brokerage
                                      AMLogging.log("ImportFlowView: presenting CSV picker (Brokerage CSV)", component: "Import")
                                      isImporterPresented = true
                                  }
                                  Button("Credit Card CSV") {
                                      pickerKind = .csv
                                      vm.userSelectedDocHint = .creditCard
                                      vm.creditCardFlipOverride = settings.creditCardFlipDefault
                                      AMLogging.log("ImportFlowView: presenting CSV picker (Credit Card CSV)", component: "Import")
                                      isImporterPresented = true
                                  }
                              }
                          } label: {
                              PlanMenuLabel(title: "Statements",titleFont: .caption)
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
            let shouldShow = (!purchases.isPremiumUnlocked && !purchases.isInTrial)
            if shouldShow && !externalImportActive && importRouter.pendingURL == nil && vm.staged == nil && vm.mappingSession == nil {
                showPaywall = true
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
                AMLogging.log("ImportFlowView: staged import ready — parser=\(staged.parserId), balances=\(staged.balances.count), tx=\(staged.transactions.count)", component: "Import")
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
              if let url {
                  externalImportActive = true
                  pendingExternalURL = url
                  showPaywall = false
                  AMLogging.always("ImportFlowView: received external URL \(url.lastPathComponent), preparing doc kind chooser", component: "Import")
                  showDocKindSheet = true
              }
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
            PaywallView()
                .environmentObject(purchases)
        }
        .sheet(isPresented: $showDocKindSheet) {
            NavigationStack {
                List {
                    ForEach(ExternalDocKind.allCases) { (kind: ExternalDocKind) in
                        Button(kind.rawValue) {
                            showDocKindSheet = false
                            if let url = pendingExternalURL {
                                applyExternal(kind: kind, url: url)
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
                Task { await handleImport(url) }
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
        .alert("Import Backup", isPresented: Binding(get: { backupCoordinator.alertMessage != nil }, set: { if !$0 { backupCoordinator.alertMessage = nil } })) {
            Button("OK", role: .cancel) { backupCoordinator.alertMessage = nil }
        } message: {
            Text(backupCoordinator.alertMessage ?? "")
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

    private func handleImport(_ url: URL) async {
        // Determine if PDF or not; handle accordingly
        if url.pathExtension.lowercased() == "pdf" {
            handlePDFSnapshotImport(url: url)
        } else {
            await MainActor.run {
                vm.isImporting = true
            }
            defer {
                DispatchQueue.main.async {
                    vm.isImporting = false
                }
            }
            await MainActor.run {
                vm.handlePickedURL(url)
            }
        }
    }
}

#Preview {
    ImportFlowView()
        .environmentObject(PurchaseManager.shared)
}

