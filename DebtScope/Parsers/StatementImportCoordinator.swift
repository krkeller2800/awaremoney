import Foundation
import SwiftUI
import Observation
import SwiftData
import UniformTypeIdentifiers

// Reusable coordinator that encapsulates the import logic used by ImportFlowView
// so other entry points (like QuickStartView) can invoke the same flow and then
// present ReviewImportView directly.
@MainActor
@Observable final class StatementImportCoordinator {
    let vm: ImportViewModel

    init(vm: ImportViewModel) {
        self.vm = vm
    }

    convenience init() {
        self.init(vm: ImportViewModel(parsers: ImportViewModel.defaultParsers()))
    }

    private func accountType(from hint: StatementType) -> Account.AccountType {
        switch hint {
        case .creditCard: return .creditCard
        case .loan:       return .loan
        case .brokerage:  return .brokerage
        case .bank:       return .checking
        }
    }

    // MARK: - API
    private func showImportProgress() async {
        vm.isImporting = true

        // Give SwiftUI one frame to present the overlay before synchronous extractors
        // begin doing PDFKit/XML parsing work on the main actor.
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    // Entry point for importing a picked URL. Provide an optional hint for statement type.
    // This function updates vm.staged or vm.mappingSession and toggles vm.isImporting as needed.
    func importURL(_ url: URL,
                          hint: StatementType?,
                          modelContext: ModelContext,
                          settings: SettingsStore) async {
        await MainActor.run {
            // Seed hint -> account type and credit card flip defaults
            if let h = hint {
                switch h {
                case .creditCard:
                    self.vm.creditCardFlipOverride = settings.creditCardFlipDefault ? true : nil
                    self.vm.newAccountType = accountType(from: h)
                default:
                    self.vm.newAccountType = accountType(from: h)
                }
            }
            self.vm.lastPickedLocalURL = url
        }

        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            await handlePDFSnapshotImport(url: url, hint: hint, settings: settings)
            return
        }

        if ["qfx", "ofx", "qbo"].contains(ext) {
            await handleOFXLikeImport(url: url, hint: hint)
            return
        }

        if ext == "qif" {
            await handleQIFImport(url: url, hint: hint)
            return
        }

        // Fallback: let the ImportViewModel handle other formats (CSV/XLSX/ZIP, etc.)
        await MainActor.run {
            self.vm.lastPickedLocalURL = url
        }

        await MainActor.run {
            self.vm.handlePickedURL(url)
        }
    }

    // MARK: - PDF Snapshot Import
    private func handlePDFSnapshotImport(url: URL,
                                         hint: StatementType?,
                                         settings: SettingsStore) async {
        await MainActor.run {
            self.vm.infoMessage = nil
            self.vm.errorMessage = nil
        }
        await showImportProgress()
        defer { DispatchQueue.main.async { self.vm.isImporting = false } }

        // Start security scoped access in case of Files URLs
        let didStart = url.startAccessingSecurityScopedResource()
        AMLogging.log("StatementImportCoordinator: security scope started=\(didStart) for file=\(url.path)", component: "Import")
        defer {
            if didStart { url.stopAccessingSecurityScopedResource() }
        }

        // Cache a copy into Caches for later preview
        do {
            let fm = FileManager.default
            if let caches = try? fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true) {
                let dest = caches.appendingPathComponent(url.lastPathComponent)
                if dest.standardizedFileURL.path != url.standardizedFileURL.path {
                    try? fm.removeItem(at: dest)
                    if fm.fileExists(atPath: url.path) {
                        do { try fm.copyItem(at: url, to: dest) } catch { AMLogging.error("PDF cache copy failed — \(error.localizedDescription)", component: "Import") }
                    }
                }
                await MainActor.run { self.vm.lastPickedLocalURL = dest }
            }
        }

        do {
            let importer = StatementImporter()
            // The extractor currently uses .transactions; summary parsing is layered on top
            let preferMode: PDFStatementExtractor.Mode = .transactions
            let userOverride: StatementImporter.UserOverride? = {
                switch hint {
                case .some(.creditCard): return .creditCard
                case .some(.loan):       return .loan
                case .some(.brokerage):  return .brokerage
                case .some(.bank):       return .bank
                case .none:              return nil
                }
            }()

            let result = try importer.importStatement(from: url, prefer: preferMode, userOverride: userOverride)
            AMLogging.log("StatementImportCoordinator: importer returned rows=\(result.rows.count) headers=\(result.headers)", component: "Import")

            var augmentedRows = result.rows
            let augmentedHeaders = result.headers
            if let fullText = PDFTextExtractor.extractText(from: url) {
                if let interest = PDFTextExtractor.extractInterestChargesSection(from: fullText) { augmentedRows.append([interest]) }
                if let balance = PDFTextExtractor.extractBalanceSummarySection(from: fullText) { augmentedRows.append([balance]) }
                augmentedRows.append([fullText])
            }

            let summaryStaged: StagedImport? = {
                do {
                    return try PDFSummaryParser().parse(rows: augmentedRows, headers: augmentedHeaders)
                } catch {
                    AMLogging.log("StatementImportCoordinator: PDF summary parse failed — \(error)", component: "Import")
                    return nil
                }
            }()
            let transactionStaged: StagedImport? = {
                do {
                    return try PDFBankTransactionsParser().parse(rows: augmentedRows, headers: augmentedHeaders)
                } catch {
                    AMLogging.log("StatementImportCoordinator: PDF transaction parse failed — \(error)", component: "Import")
                    return nil
                }
            }()

            var staged: StagedImport
            switch (summaryStaged, transactionStaged) {
            case let (.some(summary), .some(transactions)):
                staged = summary
                staged.parserId = "pdf.summary+transactions"
                staged.transactions = deduplicateStagedTransactions(transactions.transactions)
                AMLogging.log("StatementImportCoordinator: merged PDF summary with transactions — tx=\(staged.transactions.count) balances=\(staged.balances.count)", component: "Import")
            case let (.some(summary), .none):
                staged = summary
                AMLogging.log("StatementImportCoordinator: PDF summary parsed without transactions — balances=\(staged.balances.count)", component: "Import")
            case let (.none, .some(transactions)):
                staged = transactions
                staged.transactions = deduplicateStagedTransactions(staged.transactions)
                AMLogging.log("StatementImportCoordinator: PDF transactions parsed without summary — tx=\(staged.transactions.count)", component: "Import")
            case (.none, .none):
                // Manual fallback: present empty staged so ReviewImportView can be used
                await MainActor.run {
                    if let h = hint {
                        self.vm.newAccountType = accountType(from: h)
                    }
                    self.vm.staged = StagedImport(
                        parserId: "manual.fallback",
                        sourceFileName: url.lastPathComponent,
                        inferredInstitutionName: nil,
                        suggestedAccountType: self.vm.newAccountType,
                        transactions: [], holdings: [], balances: []
                    )
                    self.vm.mappingSession = nil
                    self.vm.errorMessage = nil
                    self.vm.infoMessage = "We couldn’t read this PDF. You can still add the account—fill in the fields below." + (UIDevice.type == "iPhone" ? " Tap 'view PDF' for reference." : "")
                }
                return
            }

            staged.sourceFileName = url.lastPathComponent

            // Normalize snapshot signs by the balance's own label, not only the document hint.
            // Mixed statements can carry both a loan and a real savings/checking balance; liability
            // snapshots should be negative while cash snapshots remain positive.
            for i in staged.balances.indices {
                let label = (staged.balances[i].sourceAccountLabel ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                let isCashLabel = label.contains("checking") || label.contains("savings") || label == "cash"
                let isLiabilityLabel = label.contains("loan") || label.contains("credit")

                switch hint {
                case .some(.creditCard), .some(.loan):
                    if !isCashLabel && (isLiabilityLabel || label.isEmpty), staged.balances[i].balance > 0 {
                        staged.balances[i].balance = -staged.balances[i].balance
                    }
                case .some(.bank):
                    if !isLiabilityLabel && staged.balances[i].balance < 0 {
                        staged.balances[i].balance = -staged.balances[i].balance
                    }
                default:
                    break
                }
            }

            // Suppress CC coercion if hint says otherwise
            if hint == .some(.loan) {
                for i in staged.balances.indices {
                    let lbl = (staged.balances[i].sourceAccountLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if lbl == "creditcard" { staged.balances[i].sourceAccountLabel = "loan" }
                }
            }
            if hint == .some(.bank) {
                for i in staged.balances.indices {
                    let lbl = (staged.balances[i].sourceAccountLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if lbl == "creditcard" || lbl == "credit card" { staged.balances[i].sourceAccountLabel = "checking" }
                }
            }
            if hint == .some(.bank), staged.holdings.isEmpty {
                for i in staged.balances.indices {
                    let lbl = (staged.balances[i].sourceAccountLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if ["brokerage","investment","investments"].contains(lbl) { staged.balances[i].sourceAccountLabel = "checking" }
                }
            }

            // De-duplicate balances per day, preferring non-zero; CC prefers negative when signs differ
            if hint == .some(.creditCard) {
                staged.balances = deduplicateStagedBalancesForCreditCard(staged.balances)
            } else {
                staged.balances = deduplicateStagedBalancesPreferringNonZeroSameDay(staged.balances)
            }

            removeCreditCardPaymentRowsThatMatchBalanceSnapshots(from: &staged)

            // Apply APR preference for CC when available
            if hint == .some(.creditCard) {
                if let fullText = PDFTextExtractor.extractText(from: url), let (apr, scale) = PDFTextExtractor.extractPreferredAPR(from: fullText) {
                    for i in staged.balances.indices {
                        if let existing = staged.balances[i].interestRateAPR { if apr < existing { staged.balances[i].interestRateAPR = apr; staged.balances[i].interestRateScale = scale } }
                        else { staged.balances[i].interestRateAPR = apr; staged.balances[i].interestRateScale = scale }
                    }
                }
            }

            await MainActor.run {
                if let h = hint {
                    self.vm.newAccountType = accountType(from: h)
                }
                if staged.suggestedAccountType == nil {
                    staged.suggestedAccountType = self.vm.newAccountType
                }
                self.vm.staged = staged
                self.vm.mappingSession = nil
            }
        } catch {
            AMLogging.error("StatementImportCoordinator: PDF import failed — \(error.localizedDescription)", component: "Import")
            await MainActor.run {
                if let h = hint {
                    self.vm.newAccountType = accountType(from: h)
                }
                self.vm.staged = StagedImport(
                    parserId: "manual.fallback",
                    sourceFileName: url.lastPathComponent,
                    inferredInstitutionName: nil,
                    suggestedAccountType: self.vm.newAccountType,
                    transactions: [], holdings: [], balances: []
                )
                self.vm.mappingSession = nil
                self.vm.errorMessage = "We couldn’t read this PDF. You can still add the account—fill in the fields below." + (UIDevice.type == "iPhone" ? " Tap 'view PDF' for reference." : "")
                self.vm.infoMessage = nil
            }
        }
    }

    // MARK: - OFX/QFX/QBO
    private func handleOFXLikeImport(url: URL, hint: StatementType?) async {
        await MainActor.run {
            self.vm.lastPickedLocalURL = url
        }
        await showImportProgress()
        defer { DispatchQueue.main.async { self.vm.isImporting = false } }

        @MainActor func setTypeFromHint() {
            if let h = hint { self.vm.newAccountType = accountType(from: h) }
        }

        func handleParsed(rows: [[String]], headers: [String]) async throws {
            let parsers = ImportViewModel.defaultParsers()
            let nonPDF = parsers.filter { !($0 is PDFSummaryParser) }
            if let parser = nonPDF.first(where: { $0.canParse(headers: headers) }) {
                await MainActor.run { setTypeFromHint() }
                var staged = try parser.parse(rows: rows, headers: headers)
                staged.sourceFileName = url.lastPathComponent
                staged.suggestedAccountType = await MainActor.run { self.vm.newAccountType }
                await MainActor.run { self.vm.staged = staged; self.vm.mappingSession = nil }
            } else {
                await MainActor.run {
                    self.vm.mappingSession = .init(kind: .bank, headers: headers, sampleRows: rows)
                    self.vm.staged = nil
                }
            }
        }

        do {
            if url.pathExtension.lowercased() == "qbo" {
                let (rows, headers) = try QBOStatementExtractor.parse(url: url)
                try await handleParsed(rows: rows, headers: headers)
            } else {
                let (rows, headers) = try OFXStatementExtractor.parse(url: url)
                try await handleParsed(rows: rows, headers: headers)
            }
        } catch {
            await MainActor.run {
                self.vm.errorMessage = (url.pathExtension.lowercased() == "qbo") ? "We couldn’t read this QBO file." : "We couldn’t read this OFX/QFX file."
            }
        }
    }

    // MARK: - QIF
    private func handleQIFImport(url: URL, hint: StatementType?) async {
        await MainActor.run {
            self.vm.lastPickedLocalURL = url
        }
        await showImportProgress()
        defer { DispatchQueue.main.async { self.vm.isImporting = false } }

        do {
            let (rows, headers) = try QIFStatementExtractor.parse(url: url)
            let parsers = ImportViewModel.defaultParsers().filter { !($0 is PDFSummaryParser) }
            if let parser = parsers.first(where: { $0.canParse(headers: headers) }) {
                await MainActor.run {
                    if let h = hint { self.vm.newAccountType = accountType(from: h) }
                }
                var staged = try parser.parse(rows: rows, headers: headers)
                staged.sourceFileName = url.lastPathComponent
                staged.suggestedAccountType = await MainActor.run { self.vm.newAccountType }
                await MainActor.run { self.vm.staged = staged; self.vm.mappingSession = nil }
            } else {
                await MainActor.run {
                    self.vm.mappingSession = .init(kind: .bank, headers: headers, sampleRows: rows)
                    self.vm.staged = nil
                }
            }
        } catch {
            await MainActor.run { self.vm.errorMessage = error.localizedDescription.isEmpty ? "We couldn’t process this QIF file." : error.localizedDescription }
        }
    }

    // MARK: - Helpers (de-dup)
    private func deduplicateStagedTransactions(_ transactions: [StagedTransaction]) -> [StagedTransaction] {
        var seen: Set<String> = []
        var deduplicated: [StagedTransaction] = []
        deduplicated.reserveCapacity(transactions.count)

        for transaction in transactions where seen.insert(transaction.hashKey).inserted {
            deduplicated.append(transaction)
        }

        if deduplicated.count != transactions.count {
            AMLogging.log("StatementImportCoordinator: removed duplicate staged PDF transactions — before=\(transactions.count) after=\(deduplicated.count)", component: "Import")
        }

        return deduplicated
    }

    private func removeCreditCardPaymentRowsThatMatchBalanceSnapshots(from staged: inout StagedImport) {
        guard !staged.transactions.isEmpty, !staged.balances.isEmpty else { return }

        let creditBalanceMagnitudes = Set(staged.balances.compactMap { balance -> Decimal? in
            let label = (balance.sourceAccountLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard label.contains("credit") || staged.suggestedAccountType == .creditCard else { return nil }
            return balance.balance.magnitude
        })
        guard !creditBalanceMagnitudes.isEmpty else { return }

        let before = staged.transactions.count
        staged.transactions.removeAll { transaction in
            let label = (transaction.sourceAccountLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let payee = transaction.payee.lowercased()
            guard label.contains("credit") || staged.suggestedAccountType == .creditCard else { return false }
            guard payee.contains("payment") else { return false }
            return creditBalanceMagnitudes.contains(transaction.amount.magnitude)
        }

        let removed = before - staged.transactions.count
        if removed > 0 {
            AMLogging.log(
                "StatementImportCoordinator: removed \(removed) credit-card payment row(s) whose amount matched balance snapshots: \(creditBalanceMagnitudes)",
                component: "Import"
            )
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
                if existing.balance == .zero && snap.balance != .zero { chosen[key] = snap }
            } else {
                chosen[key] = snap
                order.append(key)
            }
        }
        return order.compactMap { chosen[$0] }
    }

    private func deduplicateStagedBalancesForCreditCard(_ snaps: [StagedBalance]) -> [StagedBalance] {
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
                if e == .zero && s != .zero { chosen[key] = snap }
                else if e != .zero && s != .zero {
                    if (e >= 0 && s < 0) { chosen[key] = snap }
                }
            } else {
                chosen[key] = snap
                order.append(key)
            }
        }
        return order.compactMap { chosen[$0] }
    }
}
