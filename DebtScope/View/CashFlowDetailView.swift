import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import PDFKit

struct CashFlowDetailView: View {
    @ObservedObject var vm: ImportViewModel
    let coordinator: StatementImportCoordinator
    @Binding var externalSelectedAccountID: UUID?
    let onRouteImport: (StatementType?, UUID?) -> Void

    @Binding var pendingExternal: QuickStartPendingImport?
    
    @Query(sort: [SortDescriptor(\Account.name, order: .forward)]) private var accounts: [Account]
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
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
    @State private var isPreparingDetectionReview = false
    @State private var bankSubtype: QuickIngestAccountType? = nil
    @State private var isQuickIngesting: Bool = false
    @State private var quickIngestError: Error? = nil
    @State private var showManualAddSheet = false
    @State private var importedPreview: ImportedStatementPreview? = nil
    @State private var detectedAccounts: [DetectionReviewSheet.DetectedAccountSelection] = []
    @State private var ingestedAccount: Account? = nil
    @State private var showStatementSheet = false
    @State private var monthlyPaymentInput: String = ""
    @State private var aprPercentInput: String = ""
    @State private var balanceInput: String = ""
    private struct EditingAccount: Identifiable { let id: UUID }
    @State private var editingAccount: EditingAccount? = nil

    private struct DetectionSheetModel: Identifiable {
        let id = UUID()
        var detection: IntakeDetection
        var url: URL
        var preview: ImportedStatementPreview?
        var routeConfirmationText: String? = nil
    }

    private struct ImportedStatementPreview {
        var balance: Decimal?
        var balanceDate: Date?
        var typicalPayment: Decimal?
        var aprFraction: Decimal?
        var aprScale: Int?
        var bankBalanceSummaries: [BankBalanceSummary] = []
        var bankTransactionLabels: Set<String> = []
    }

    private struct BankBalanceSummary: Identifiable {
        let id: String
        let label: String
        let beginningBalance: Decimal?
        let endingBalance: Decimal?
        let endingBalanceDate: Date?
    }

    private static let importTypes: [UTType] = {
        var types: [UTType] = [.pdf, .commaSeparatedText, .tabSeparatedText, .text, .data]
        let exts = ["qfx", "ofx", "qbo", "qif", "xlsx", "xls", "csv", "tsv", "txt", "zip"]
        types.append(contentsOf: exts.compactMap { UTType(filenameExtension: $0) })
        return types
    }()

    private var cashFlowAccounts: [Account] {
        accounts.filter {
            switch $0.type {
            case .checking, .savings, .cash:
                return true
            default:
                return false
            }
        }
    }

    private func statementType(for accountType: Account.AccountType) -> StatementType? {
        switch accountType {
        case .creditCard:
            return .creditCard
        case .loan:
            return .loan
        case .checking, .savings, .cash:
            return .bank
        case .brokerage:
            return .brokerage
        default:
            return nil
        }
    }

    private func routeImportedAccount(_ account: Account?) {
        guard let account else { return }
        onRouteImport(statementType(for: account.type), account.id)
    }

    private func currentAccount() -> Account? {
        if let ingestedAccount { return ingestedAccount }
        if let selectedAccountID { return cashFlowAccounts.first(where: { $0.id == selectedAccountID }) }
        return nil
    }

    private var statementActionTitle: String {
        lastImportedURL == nil ? "Transactions" : "PDF"
    }

    private var statementActionWidth: CGFloat {
        lastImportedURL == nil ? 112 : 55
    }

    @ViewBuilder
    private var columnsView: some View {
        if horizontalSizeClass == .compact {
            accountsList
                .frame(maxWidth: .infinity, minHeight: 280, alignment: .topLeading)
                .padding(.horizontal)
        } else {
            HStack(spacing: 0) {
                accountsList
                    .frame(minWidth: 280, maxWidth: 360, maxHeight: .infinity, alignment: .topLeading)
                    .padding([.top, .horizontal])

                Divider()

                inlineStatementPreview
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary.opacity(0.05))
            }
            .frame(maxWidth: .infinity, minHeight: 300)
        }
    }

    @ViewBuilder
    private var inlineStatementPreview: some View {
        if let url = lastImportedURL {
            PDFPreview(url: url)
        } else if let account = currentAccount() {
            NavigationStack {
                AccountTransactionsListView(account: account)
                    .navigationBarTitleDisplayMode(.inline)
            }
        } else {
            ContentUnavailableView(
                "No Account Selected",
                systemImage: "doc.text",
                description: Text("Select an asset account to preview its statement or activity.")
            )
        }
    }

    @ViewBuilder
    private var statementSheetContent: some View {
        if let url = lastImportedURL {
            NavigationStack {
                PDFPreview(url: url)
                    .navigationTitle("View PDF")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showStatementSheet = false }
                        }
                    }
            }
        } else if let account = currentAccount() {
            NavigationStack {
                AccountTransactionsListView(account: account)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showStatementSheet = false }
                        }
                    }
            }
        }
    }

    private var accountsList: some View {
        QAccountsListView(
            accounts: cashFlowAccounts,
            title: "Asset Accounts",
            showsDebtTools: false,
            selectedAccountID: $selectedAccountID,
            onEdit: { account in
                editingAccount = EditingAccount(id: account.id)
            },
            onDeleteConfirmed: { account in
                deleteAccount(account)
            },
            onSelectionChanged: { id in
                if let id {
                    updateLastImportedURL(for: id)
                }
            }
        )
    }

    private func stageURLToCaches(_ sourceURL: URL) -> URL {
        let fm = FileManager.default
        do {
            let caches = try fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let dest = caches.appendingPathComponent(sourceURL.lastPathComponent)

            let srcStd = sourceURL.standardizedFileURL
            let destStd = dest.standardizedFileURL
            if srcStd.path == destStd.path {
                return destStd
            }

            try? fm.removeItem(at: destStd)

            let granted = sourceURL.startAccessingSecurityScopedResource()
            defer { if granted { sourceURL.stopAccessingSecurityScopedResource() } }

            do {
                try fm.copyItem(at: sourceURL, to: destStd)
                return destStd
            } catch {
                do {
                    let data = try Data(contentsOf: sourceURL)
                    try data.write(to: destStd, options: .atomic)
                    return destStd
                } catch {
                    return sourceURL
                }
            }
        } catch {
            return sourceURL
        }
    }

    private func handleImport(url: URL) {
        isPreparingDetectionReview = true
        Task {
            let resolved = await StatementIntakeResolver.resolve(
                url: url,
                source: "CashFlow.handleImport"
            )
            let detection = resolved.detection
            let preview = await extractImportedPreview(from: resolved.stagedURL, hint: detection.type)

            await MainActor.run {
                lastDetection = detection
                editedInstitution = detection.institution ?? ""
                selectedType = detection.type
                importedPreview = preview
                detectedAccounts = buildDetectedAccounts(from: preview)
                bankSubtype = nil
                applyImportedPreviewToInputs(preview)
                showImporter = false

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    detectionSheetModel = DetectionSheetModel(detection: detection, url: resolved.stagedURL, preview: preview)
                    isPreparingDetectionReview = false
                }
            }
        }
    }

    @MainActor
    private func applyImportedPreviewToInputs(_ preview: ImportedStatementPreview?) {
        monthlyPaymentInput = ""
        aprPercentInput = ""
        balanceInput = ""

        guard let preview else { return }

        if let typicalPayment = preview.typicalPayment {
            monthlyPaymentInput = AppFormatters.currencyFormatter().string(from: NSDecimalNumber(decimal: typicalPayment)) ?? ""
        }

        if let apr = preview.aprFraction {
            let nf = NumberFormatter()
            nf.numberStyle = .decimal
            nf.minimumFractionDigits = 2
            nf.maximumFractionDigits = max(2, preview.aprScale ?? 2)
            let percent = apr * 100
            aprPercentInput = nf.string(from: NSDecimalNumber(decimal: percent)) ?? ""
        }

        if let balance = preview.balance {
            balanceInput = AppFormatters.currencyFormatter().string(from: NSDecimalNumber(decimal: balance.magnitude)) ?? ""
        }
    }

    private func effectiveImportedStatementType(for detectedType: StatementType?, url: URL) -> StatementType? {
        if let previewOverride = bankSummaryDrivenTypeOverride(from: url) {
            return previewOverride
        }
        return detectedType
    }

    private func bankSummaryDrivenTypeOverride(from url: URL) -> StatementType? {
        let consolidated = extractConsolidatedBankBalances(from: url) ?? []
        let keys = Set(consolidated.map { normalizedBankSummaryLabel($0.id) })
        let hasDepositAccountSummary = keys.contains("checking")
            || keys.contains("savings")
            || keys.contains("certificate")

        guard hasDepositAccountSummary else { return nil }

        AMLogging.log(
            "CashFlow effective type override: consolidated=\(consolidated.map(\.id)) keys=\(Array(keys).sorted()) forcing=bank",
            component: "Import"
        )
        return .bank
    }

    private func buildDetectedAccounts(from preview: ImportedStatementPreview?) -> [DetectionReviewSheet.DetectedAccountSelection] {
        guard let preview else { return [] }

        let selections = preview.bankBalanceSummaries.map { summary in
            let detectedType = detectedStatementType(for: summary.id, label: summary.label)
            let endingBalance = summary.endingBalance?.magnitude
            let hasTransactions = preview.bankTransactionLabels.contains(normalizedDetectedAccountKey(summary.id))
            let isInactive = !hasTransactions && isInactiveDetectedAccount(summary)
            return DetectionReviewSheet.DetectedAccountSelection(
                id: normalizedDetectedAccountKey(summary.id),
                label: summary.label,
                statementType: detectedType,
                endingBalance: endingBalance,
                isInactive: isInactive,
                shouldImport: !isInactive
            )
        }

        AMLogging.log(
            "CashFlow detectedAccounts: summaries=\(preview.bankBalanceSummaries.map { "\($0.id)=\($0.endingBalance.map { NSDecimalNumber(decimal: $0).stringValue } ?? "nil")" }) selections=\(selections.map { "\($0.id):\($0.statementType.rawValue):\($0.endingBalance.map { NSDecimalNumber(decimal: $0).stringValue } ?? "nil")" })",
            component: "Import"
        )

        return selections
    }

    private func normalizedDetectedAccountKey(_ raw: String) -> String {
        normalizedBankSummaryLabel(raw)
    }

    private func detectedStatementType(for id: String, label: String) -> StatementType {
        let key = normalizedDetectedAccountKey(id.isEmpty ? label : id)
        if key.contains("loan") || key.contains("mortgage") {
            return .loan
        }
        if key.contains("credit") || key.contains("card") {
            return .creditCard
        }
        return .bank
    }

    private func isInactiveDetectedAccount(_ summary: BankBalanceSummary) -> Bool {
        let beginning = summary.beginningBalance?.magnitude ?? .zero
        let ending = summary.endingBalance?.magnitude ?? .zero
        return beginning == .zero && ending == .zero
    }

    @MainActor
    private func importedPreview(from staged: StagedImport?) -> ImportedStatementPreview? {
        guard let staged else { return nil }

        let includedBalances = staged.balances.filter(\.include)
        let latestBalance = includedBalances.sorted { $0.asOfDate > $1.asOfDate }.first
        let typicalPayment = includedBalances.compactMap(\.typicalPaymentAmount).first(where: { $0 > 0 })
        let aprFraction = latestBalance?.interestRateAPR ?? includedBalances.compactMap(\.interestRateAPR).first
        let aprScale = latestBalance?.interestRateScale ?? includedBalances.compactMap(\.interestRateScale).first

        return ImportedStatementPreview(
            balance: latestBalance?.balance.magnitude,
            balanceDate: latestBalance?.asOfDate,
            typicalPayment: typicalPayment,
            aprFraction: aprFraction,
            aprScale: aprScale,
            bankBalanceSummaries: buildBankBalanceSummaries(from: includedBalances)
        )
    }

    private func extractImportedPreview(from url: URL, hint: StatementType?) async -> ImportedStatementPreview? {
        let userOverride: StatementImporter.UserOverride? = {
            switch hint {
            case .some(.creditCard): return .creditCard
            case .some(.loan): return .loan
            case .some(.brokerage): return .brokerage
            case .some(.bank): return .bank
            case .none: return nil
            }
        }()

        do {
            let importer = StatementImporter()
            let result = try importer.importStatement(from: url, prefer: .transactions, userOverride: userOverride)
            var augmentedRows = result.rows

            if url.pathExtension.lowercased() == "pdf",
               let fullText = PDFTextExtractor.extractText(from: url) {
                if let interestSection = PDFTextExtractor.extractInterestChargesSection(from: fullText) {
                    augmentedRows.append([interestSection])
                }
                if let balanceSection = PDFTextExtractor.extractBalanceSummarySection(from: fullText) {
                    augmentedRows.append([balanceSection])
                }
                let accountSummaries = PDFTextExtractor.extractAccountSummarySections(from: fullText)
                for section in accountSummaries {
                    augmentedRows.append([section])
                }
                augmentedRows.append([fullText])
            }

            var staged: StagedImport
            do {
                staged = try PDFSummaryParser().parse(rows: augmentedRows, headers: result.headers)
            } catch {
                let parser = await MainActor.run {
                    ImportViewModel.defaultParsers().first { $0.canParse(headers: result.headers) }
                }
                guard let parser else { throw error }
                staged = try parser.parse(rows: augmentedRows, headers: result.headers)
            }

            let transactionPreview = try? PDFBankTransactionsParser().parse(rows: augmentedRows, headers: result.headers)
            let transactionAccountLabels = Set(
                (transactionPreview?.transactions ?? [])
                    .compactMap { $0.sourceAccountLabel }
                    .map { normalizedBankSummaryLabel($0) }
                    .filter { isSupportedBankPreviewKey($0) && $0 != "default" }
            )

            if hint == .some(.creditCard) {
                staged.balances = deduplicateStagedBalancesForCreditCardPreview(staged.balances)
            } else {
                staged.balances = deduplicateStagedBalancesPreferringNonZeroSameDayPreview(staged.balances)
            }

            if hint != .some(.creditCard) && hint != .some(.loan) {
                for index in staged.balances.indices where staged.balances[index].balance < 0 {
                    staged.balances[index].balance = -staged.balances[index].balance
                }
            }

            if hint == .some(.creditCard),
               let fullText = PDFTextExtractor.extractText(from: url),
               let (apr, scale) = PDFTextExtractor.extractPreferredAPR(from: fullText) {
                for index in staged.balances.indices where staged.balances[index].interestRateAPR == nil || apr < (staged.balances[index].interestRateAPR ?? apr) {
                    staged.balances[index].interestRateAPR = apr
                    staged.balances[index].interestRateScale = scale
                }
            }

            let latestBalance = staged.balances.sorted { $0.asOfDate > $1.asOfDate }.first
            let typicalPayment = staged.balances.compactMap(\.typicalPaymentAmount).first(where: { $0 > 0 })
            let aprFraction = latestBalance?.interestRateAPR ?? staged.balances.compactMap(\.interestRateAPR).first
            let aprScale = latestBalance?.interestRateScale ?? staged.balances.compactMap(\.interestRateScale).first
            var bankBalanceSummaries = buildBankBalanceSummaries(from: staged.balances)
                .filter { isSupportedBankPreviewKey($0.id) }
            if hint == .some(.bank) {
                let consolidated = extractConsolidatedBankBalances(from: url) ?? []
                let accountSections = extractAccountSectionBankBalances(from: url) ?? []
                let sectioned = extractSectionedBankBalances(from: url) ?? []
                let merged = mergeBankBalanceSummaries(bankBalanceSummaries, consolidated, accountSections, sectioned)
                    .filter { isSupportedBankPreviewKey($0.id) }
                AMLogging.log(
                    "CashFlow preview bank summaries: staged=\(bankBalanceSummaries.map { "\($0.id)=begin:\($0.beginningBalance.map { NSDecimalNumber(decimal: $0).stringValue } ?? "nil"),end:\($0.endingBalance.map { NSDecimalNumber(decimal: $0).stringValue } ?? "nil")" }) consolidated=\(consolidated.map { "\($0.id)=begin:\($0.beginningBalance.map { NSDecimalNumber(decimal: $0).stringValue } ?? "nil"),end:\($0.endingBalance.map { NSDecimalNumber(decimal: $0).stringValue } ?? "nil")" }) accountSections=\(accountSections.map { "\($0.id)=begin:\($0.beginningBalance.map { NSDecimalNumber(decimal: $0).stringValue } ?? "nil"),end:\($0.endingBalance.map { NSDecimalNumber(decimal: $0).stringValue } ?? "nil")" }) sectioned=\(sectioned.map { "\($0.id)=begin:\($0.beginningBalance.map { NSDecimalNumber(decimal: $0).stringValue } ?? "nil"),end:\($0.endingBalance.map { NSDecimalNumber(decimal: $0).stringValue } ?? "nil")" }) merged=\(merged.map { "\($0.id)=begin:\($0.beginningBalance.map { NSDecimalNumber(decimal: $0).stringValue } ?? "nil"),end:\($0.endingBalance.map { NSDecimalNumber(decimal: $0).stringValue } ?? "nil")" })",
                    component: "Import"
                )
                if !merged.isEmpty {
                    bankBalanceSummaries = merged
                }
            }

            let existingSummaryLabels = Set(bankBalanceSummaries.map { normalizedBankSummaryLabel($0.id) })
            let missingTransactionLabels = transactionAccountLabels.subtracting(existingSummaryLabels)
            if !missingTransactionLabels.isEmpty {
                let transactionOnlySummaries = missingTransactionLabels
                    .sorted { bankSummarySortOrder(for: $0) < bankSummarySortOrder(for: $1) }
                    .map { label in
                        BankBalanceSummary(
                            id: label,
                            label: displayLabel(for: label),
                            beginningBalance: nil,
                            endingBalance: nil,
                            endingBalanceDate: nil
                        )
                    }
                bankBalanceSummaries = mergeBankBalanceSummaries(bankBalanceSummaries, transactionOnlySummaries)
            }
            AMLogging.log(
                "CashFlow preview accounts — balanceLabels=\(Array(existingSummaryLabels).sorted()) transactionLabels=\(Array(transactionAccountLabels).sorted()) displayed=\(bankBalanceSummaries.map { $0.id })",
                component: "Import"
            )

            return ImportedStatementPreview(
                balance: latestBalance?.balance.magnitude,
                balanceDate: latestBalance?.asOfDate,
                typicalPayment: typicalPayment,
                aprFraction: aprFraction,
                aprScale: aprScale,
                bankBalanceSummaries: bankBalanceSummaries,
                bankTransactionLabels: transactionAccountLabels
            )
        } catch {
            return nil
        }
    }

    private func buildBankBalanceSummaries(from balances: [StagedBalance]) -> [BankBalanceSummary] {
        let includedBalances = balances.filter(\.include)
        guard !includedBalances.isEmpty else { return [] }

        let grouped = Dictionary(grouping: includedBalances) { balance in
            normalizedBankSummaryLabel(balance.sourceAccountLabel)
        }

        return grouped.keys.sorted { lhs, rhs in
            bankSummarySortOrder(for: lhs) < bankSummarySortOrder(for: rhs)
        }.compactMap { key in
            guard let rows = grouped[key], !rows.isEmpty else { return nil }
            let sorted = rows.sorted { lhs, rhs in
                if lhs.asOfDate == rhs.asOfDate {
                    return lhs.balance < rhs.balance
                }
                return lhs.asOfDate < rhs.asOfDate
            }
            return BankBalanceSummary(
                id: key.lowercased(),
                label: displayLabel(for: key),
                beginningBalance: sorted.count > 1 ? sorted.first?.balance.magnitude : nil,
                endingBalance: sorted.last?.balance.magnitude,
                endingBalanceDate: sorted.last?.asOfDate
            )
        }
    }

    private func mergeBankBalanceSummaries(_ collections: [BankBalanceSummary]...) -> [BankBalanceSummary] {
        var merged: [String: BankBalanceSummary] = [:]

        for collection in collections {
            for summary in collection {
                let key = normalizedBankSummaryLabel(summary.id.isEmpty ? summary.label : summary.id)
                let existing = merged[key]
                merged[key] = BankBalanceSummary(
                    id: key,
                    label: displayLabel(for: key),
                    // Let stronger PDF-derived summary passes replace staged beginning balances.
                    beginningBalance: summary.beginningBalance ?? existing?.beginningBalance,
                    // Keep the first discovered ending balance authoritative. Later section parsers
                    // can still enrich missing fields, but should not overwrite summary totals.
                    endingBalance: existing?.endingBalance ?? summary.endingBalance,
                    endingBalanceDate: existing?.endingBalanceDate ?? summary.endingBalanceDate
                )
            }
        }

        return merged.keys
            .sorted { bankSummarySortOrder(for: $0) < bankSummarySortOrder(for: $1) }
            .compactMap { merged[$0] }
    }

    private func extractAccountSectionBankBalances(from url: URL) -> [BankBalanceSummary]? {
        guard let fullText = PDFTextExtractor.extractText(from: url) else { return nil }

        let sections = PDFTextExtractor.extractAccountSummarySections(from: fullText)
        guard !sections.isEmpty else { return nil }

        let amountToken = #"(\\$?\\s*[\\-−]?\\s*[0-9]{1,3}(?:,[0-9]{3})*\\.[0-9]{2}|\\$?\\s*[\\-−]?\\s*[0-9]+\\.[0-9]{2})"#
        let amountRegex = try? NSRegularExpression(pattern: amountToken, options: [])

        func parseAmount(_ value: String) -> Decimal? {
            var cleaned = value
                .replacingOccurrences(of: ",", with: "")
                .replacingOccurrences(of: "$", with: "")
                .replacingOccurrences(of: "﹩", with: "")
                .replacingOccurrences(of: "＄", with: "")
                .replacingOccurrences(of: "−", with: "-")
                .replacingOccurrences(of: "\u{00A0}", with: "")
                .replacingOccurrences(of: "\u{202F}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var isParenNegative = false
            if cleaned.hasPrefix("("), cleaned.hasSuffix(")") {
                isParenNegative = true
                cleaned = String(cleaned.dropFirst().dropLast())
            }
            guard var amount = Decimal(string: cleaned) else { return nil }
            if isParenNegative { amount *= -1 }
            return amount.magnitude
        }

        func firstAmount(in line: String) -> Decimal? {
            guard let amountRegex else { return nil }
            let ns = line as NSString
            let range = NSRange(location: 0, length: ns.length)
            guard let match = amountRegex.firstMatch(in: line, options: [], range: range),
                  match.numberOfRanges >= 2 else {
                return nil
            }
            let amountRange = match.range(at: 1)
            guard amountRange.location != NSNotFound else { return nil }
            return parseAmount(ns.substring(with: amountRange))
        }

        var summaries: [String: BankBalanceSummary] = [:]

        for section in sections {
            let lowerSection = section.lowercased()
            let key: String
            if lowerSection.contains("checking") {
                key = "checking"
            } else if lowerSection.contains("savings") || lowerSection.contains("money market") || lowerSection.contains("mmda") {
                key = "savings"
            } else if lowerSection.contains("loan") || lowerSection.contains("annual percentage rate") || lowerSection.contains("payment due") || lowerSection.contains("principal") {
                key = "loan"
            } else if lowerSection.contains("cash") {
                key = "cash"
            } else {
                continue
            }

            let lines = section.components(separatedBy: CharacterSet.newlines)
            var beginningBalance: Decimal?
            var endingBalance: Decimal?

            for (index, line) in lines.enumerated() {
                let lowerLine = line.lowercased()
                if beginningBalance == nil, lowerLine.contains("beginning balance") || lowerLine.contains("balance forward") {
                    beginningBalance = firstAmount(in: line)
                    if beginningBalance == nil, index + 1 < lines.count {
                        beginningBalance = firstAmount(in: lines[index + 1])
                    }
                }
                if endingBalance == nil, lowerLine.contains("ending balance") || lowerLine.contains("current balance") {
                    endingBalance = firstAmount(in: line)
                    if endingBalance == nil, index + 1 < lines.count {
                        endingBalance = firstAmount(in: lines[index + 1])
                    }
                }
            }

            if beginningBalance != nil || endingBalance != nil {
                summaries[key] = BankBalanceSummary(
                    id: key,
                    label: displayLabel(for: key),
                    beginningBalance: beginningBalance,
                    endingBalance: endingBalance,
                    endingBalanceDate: nil
                )
            }
        }

        let ordered = ["checking", "savings", "loan", "cash"].compactMap { summaries[$0] }
        AMLogging.log(
            "CashFlow accountSection summaries=\(ordered.map { "\($0.id)=begin:\($0.beginningBalance.map { NSDecimalNumber(decimal: $0).stringValue } ?? "nil"),end:\($0.endingBalance.map { NSDecimalNumber(decimal: $0).stringValue } ?? "nil")" })",
            component: "Import"
        )
        return ordered.isEmpty ? nil : ordered
    }

    private func extractSectionedBankBalances(from url: URL) -> [BankBalanceSummary]? {
        guard let doc = PDFDocument(url: url) else { return nil }

        var combined = ""
        for index in 0..<min(3, doc.pageCount) {
            if let page = doc.page(at: index), let text = page.string {
                combined.append("\n")
                combined.append(text)
            }
        }

        let text = combined
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "﹩", with: "$")
            .replacingOccurrences(of: "＄", with: "$")
        let lines = text.components(separatedBy: CharacterSet.newlines)
        let lowerLines = lines.map { $0.lowercased() }

        let amountToken = #"(\$?\s*[\-−]?\s*[0-9]{1,3}(?:,[0-9]{3})*\.[0-9]{2}|\$?\s*[\-−]?\s*[0-9]+\.[0-9]{2})"#
        let amountRegex = try? NSRegularExpression(pattern: amountToken, options: [])

        func parseAmount(_ value: String) -> Decimal? {
            var cleaned = value
                .replacingOccurrences(of: ",", with: "")
                .replacingOccurrences(of: "$", with: "")
                .replacingOccurrences(of: "﹩", with: "")
                .replacingOccurrences(of: "＄", with: "")
                .replacingOccurrences(of: "−", with: "-")
                .replacingOccurrences(of: "\u{00A0}", with: "")
                .replacingOccurrences(of: "\u{202F}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var isParenNegative = false
            if cleaned.hasPrefix("("), cleaned.hasSuffix(")") {
                isParenNegative = true
                cleaned = String(cleaned.dropFirst().dropLast())
            }
            guard var amount = Decimal(string: cleaned) else { return nil }
            if isParenNegative { amount *= -1 }
            return amount.magnitude
        }

        func preferredAmount(in line: String) -> Decimal? {
            guard let amountRegex else { return nil }
            let ns = line as NSString
            let range = NSRange(location: 0, length: ns.length)
            let matches = amountRegex.matches(in: line, options: [], range: range)
            guard !matches.isEmpty else { return nil }

            let currencyLike = matches.compactMap { match -> Decimal? in
                guard match.numberOfRanges >= 2 else { return nil }
                let amountRange = match.range(at: 1)
                guard amountRange.location != NSNotFound else { return nil }
                let token = ns.substring(with: amountRange)
                guard token.contains("$") || token.contains(",") || token.contains(".") else { return nil }
                return parseAmount(token)
            }
            if let amount = currencyLike.last {
                return amount
            }

            for match in matches.reversed() {
                guard match.numberOfRanges >= 2 else { continue }
                let amountRange = match.range(at: 1)
                guard amountRange.location != NSNotFound,
                      let amount = parseAmount(ns.substring(with: amountRange)) else {
                    continue
                }
                return amount
            }
            return nil
        }

        func firstAmount(near lineIndex: Int) -> Decimal? {
            let searchEnd = min(lines.count, lineIndex + 2)
            for idx in lineIndex..<searchEnd {
                if let amount = preferredAmount(in: lines[idx]) {
                    return amount
                }
            }
            return nil
        }

        func preferredStartIndex(for label: String) -> Int? {
            let strongHeaders: [String]
            switch label {
            case "checking":
                strongHeaders = [
                    "checking summary",
                    "chase total checking"
                ]
            case "savings":
                strongHeaders = [
                    "savings summary",
                    "chase savings"
                ]
            default:
                strongHeaders = []
            }

            for header in strongHeaders {
                if let index = lowerLines.firstIndex(where: { $0.contains(header) }) {
                    AMLogging.log(
                        "CashFlow sectioned anchor label=\(label) mode=strong index=\(index) line=\(lines[index])",
                        component: "Import"
                    )
                    return index
                }
            }

            if let fallbackIndex = lowerLines.firstIndex(where: { $0.contains(label) }) {
                AMLogging.log(
                    "CashFlow sectioned anchor label=\(label) mode=fallback index=\(fallbackIndex) line=\(lines[fallbackIndex])",
                    component: "Import"
                )
                return fallbackIndex
            }
            return nil
        }

        var summaries: [BankBalanceSummary] = []
        for label in ["checking", "savings"] {
            guard let startIndex = preferredStartIndex(for: label) else { continue }
            let searchEnd = min(lines.count, startIndex + 40)
            var beginningBalance: Decimal?
            var endingBalance: Decimal?

            for index in startIndex..<searchEnd {
                let line = lowerLines[index]
                if beginningBalance == nil, line.contains("beginning balance") {
                    beginningBalance = firstAmount(near: index)
                }
                if endingBalance == nil, line.contains("ending balance") || line.contains("current balance") {
                    endingBalance = firstAmount(near: index)
                }
            }

            if beginningBalance != nil || endingBalance != nil {
                summaries.append(
                    BankBalanceSummary(
                        id: label,
                        label: displayLabel(for: label),
                        beginningBalance: beginningBalance,
                        endingBalance: endingBalance,
                        endingBalanceDate: nil
                    )
                )
            }
        }

        AMLogging.log(
            "CashFlow sectioned summaries=\(summaries.map { "\($0.id)=begin:\($0.beginningBalance.map { NSDecimalNumber(decimal: $0).stringValue } ?? "nil"),end:\($0.endingBalance.map { NSDecimalNumber(decimal: $0).stringValue } ?? "nil")" })",
            component: "Import"
        )

        return summaries.isEmpty ? nil : summaries
    }

    private func extractConsolidatedBankBalances(from url: URL) -> [BankBalanceSummary]? {
        let rawText: String? = {
            if let extracted = PDFTextExtractor.extractText(from: url), !extracted.isEmpty {
                return extracted
            }
            guard let doc = PDFDocument(url: url) else { return nil }
            var combined = ""
            for index in 0..<min(3, doc.pageCount) {
                if let page = doc.page(at: index), let text = page.string {
                    combined.append("\n")
                    combined.append(text)
                }
            }
            return combined
        }()

        guard let rawText, !rawText.isEmpty else { return nil }

        let text = rawText
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "﹩", with: "$")
            .replacingOccurrences(of: "＄", with: "$")

        func parseAmount(_ value: String) -> Decimal? {
            let cleaned = value
                .replacingOccurrences(of: ",", with: "")
                .replacingOccurrences(of: "$", with: "")
                .replacingOccurrences(of: "﹩", with: "")
                .replacingOccurrences(of: "＄", with: "")
                .replacingOccurrences(of: "−", with: "-")
                .replacingOccurrences(of: "\u{00A0}", with: "")
                .replacingOccurrences(of: "\u{202F}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Decimal(string: cleaned)?.magnitude
        }

        var summaries: [BankBalanceSummary] = []
        for (needle, key) in [("savings", "savings"), ("checking", "checking"), ("loans", "loan"), ("loan", "loan"), ("certificates", "certificate")] {
            let pattern = #"(?im)total\s+\#(needle)\s*:\s*(\$?\s*[-−]?\s*[0-9]{1,3}(?:,[0-9]{3})*\.[0-9]{2}|\$?\s*[-−]?\s*[0-9]+\.[0-9]{2})"#
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
                  match.numberOfRanges >= 2,
                  let amountRange = Range(match.range(at: 1), in: text),
                  let endingBalance = parseAmount(String(text[amountRange])) else {
                continue
            }

            summaries.append(
                BankBalanceSummary(
                    id: key,
                    label: displayLabel(for: key),
                    beginningBalance: nil,
                    endingBalance: endingBalance,
                    endingBalanceDate: nil
                )
            )
        }

        AMLogging.log(
            "CashFlow consolidated summaries=\(summaries.map { "\($0.id)=\($0.endingBalance.map { NSDecimalNumber(decimal: $0).stringValue } ?? "nil")" })",
            component: "Import"
        )
        return summaries.isEmpty ? nil : summaries
    }

    private func displayLabel(for rawLabel: String) -> String {
        switch rawLabel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "checking":
            return "Checking"
        case "savings":
            return "Savings"
        case "cash":
            return "Cash"
        case "loan":
            return "Loan"
        case "certificate":
            return "Certificate"
        case "default":
            return "Account"
        default:
            return rawLabel
                .split(separator: " ")
                .map { $0.capitalized }
                .joined(separator: " ")
        }
    }

    private func normalizedBankSummaryLabel(_ rawLabel: String?) -> String {
        let raw = (rawLabel ?? "default").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if raw.isEmpty { return "default" }
        if raw.contains("checking") || raw.contains("draft") || raw.contains("dda") {
            return "checking"
        }
        if raw.contains("savings") || raw.contains("money market") || raw.contains("mmda") || raw.contains("share") {
            return "savings"
        }
        if raw.contains("loan") || raw.contains("mortgage") || raw.contains("flair") {
            return "loan"
        }
        if raw.contains("certificate") || raw.contains("cd") {
            return "certificate"
        }
        if raw.contains("cash") { return "cash" }
        return raw
    }

    private func bankSummarySortOrder(for key: String) -> Int {
        switch key {
        case "checking":
            return 0
        case "savings":
            return 1
        case "cash":
            return 2
        case "loan":
            return 3
        case "certificate":
            return 4
        case "default":
            return 99
        default:
            return 50
        }
    }

    private func isSupportedBankPreviewKey(_ rawKey: String) -> Bool {
        let key = normalizedBankSummaryLabel(rawKey)
        switch key {
        case "checking", "savings", "cash", "loan", "certificate", "default":
            return true
        default:
            return false
        }
    }

    private func deduplicateStagedBalancesPreferringNonZeroSameDayPreview(_ snaps: [StagedBalance]) -> [StagedBalance] {
        if snaps.isEmpty { return snaps }
        var chosen: [String: StagedBalance] = [:]
        var order: [String] = []
        let calendar = Calendar.current
        for snap in snaps {
            let label = (snap.sourceAccountLabel ?? "default").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let dayStart = calendar.startOfDay(for: snap.asOfDate).timeIntervalSince1970
            let key = "\(label)|\(Int(dayStart))"
            if let existing = chosen[key] {
                if existing.balance == .zero && snap.balance != .zero {
                    chosen[key] = snap
                }
            } else {
                chosen[key] = snap
                order.append(key)
            }
        }
        return order.compactMap { chosen[$0] }
    }

    private func deduplicateStagedBalancesForCreditCardPreview(_ snaps: [StagedBalance]) -> [StagedBalance] {
        if snaps.isEmpty { return snaps }
        var chosen: [Int: StagedBalance] = [:]
        var order: [Int] = []
        let calendar = Calendar.current
        for snap in snaps {
            let dayStart = calendar.startOfDay(for: snap.asOfDate).timeIntervalSince1970
            let key = Int(dayStart)
            if let existing = chosen[key] {
                if existing.balance == .zero && snap.balance != .zero {
                    chosen[key] = snap
                } else if existing.balance != .zero && snap.balance != .zero && existing.balance >= 0 && snap.balance < 0 {
                    chosen[key] = snap
                }
            } else {
                chosen[key] = snap
                order.append(key)
            }
        }
        return order.compactMap { chosen[$0] }
    }

    private func latestBalance(for account: Account) -> Decimal? {
        account.balanceSnapshots.sorted { $0.asOfDate > $1.asOfDate }.first?.balance
    }

    @MainActor
    private func deleteAccount(_ account: Account) {
        if selectedAccountID == account.id {
            selectedAccountID = nil
            externalSelectedAccountID = nil
            lastImportedURL = nil
        }

        modelContext.delete(account)
        do {
            try modelContext.save()
        } catch {
            importError = error
        }
    }

    private func perBatchPreviewDirectory(for batch: ImportBatch) -> URL? {
        let fm = FileManager.default
        guard let appSupport = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else {
            return nil
        }
        let dir = appSupport
            .appendingPathComponent("StatementPreviews", isDirectory: true)
            .appendingPathComponent(batch.id.uuidString, isDirectory: true)

        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            var dirCopy = dir
            try dirCopy.setResourceValues(resourceValues)
        } catch {
        }

        return dir
    }

    private func resolvedPDFURL(for batch: ImportBatch) -> URL? {
        let fm = FileManager.default
        if let path = batch.sourceFileLocalPath, !path.isEmpty, fm.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        if let dir = perBatchPreviewDirectory(for: batch),
           let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil),
           let first = items.first(where: { $0.pathExtension.lowercased() == "pdf" }) {
            return first
        }
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
            let balPred = #Predicate<BalanceSnapshot> { snap in
                (snap.account?.id == targetID) && (snap.importBatch != nil)
            }
            var balDesc = FetchDescriptor<BalanceSnapshot>(predicate: balPred)
            balDesc.sortBy = [SortDescriptor(\BalanceSnapshot.asOfDate, order: .reverse)]
            balDesc.fetchLimit = 1
            balDesc.includePendingChanges = false
            if let snap = try modelContext.fetch(balDesc).first,
               let batch = snap.importBatch,
               let url = resolvedPDFURL(for: batch) {
                return url
            }

            let txPred = #Predicate<Transaction> { tx in
                (tx.account?.id == targetID) && (tx.importBatch != nil)
            }
            var txDesc = FetchDescriptor<Transaction>(predicate: txPred)
            txDesc.sortBy = [SortDescriptor(\Transaction.datePosted, order: .reverse)]
            txDesc.fetchLimit = 1
            txDesc.includePendingChanges = false
            if let tx = try modelContext.fetch(txDesc).first,
               let batch = tx.importBatch,
               let url = resolvedPDFURL(for: batch) {
                return url
            }
        } catch {
        }
        return nil
    }

    @MainActor
    private func updateLastImportedURL(for id: UUID) {
        let url = resolveLatestStatementURL(forAccountID: id)
        if let url, FileManager.default.isReadableFile(atPath: url.path) {
            lastImportedURL = url
        } else {
            lastImportedURL = nil
        }
    }

    @MainActor
    private func openFullImportReview(
        detection: IntakeDetection,
        url: URL,
        selectedDetectedAccounts: [DetectionReviewSheet.DetectedAccountSelection] = []
    ) {
        var detection = detection
        detection.type = selectedType
        detection.institution = editedInstitution.trimmingCharacters(in: .whitespacesAndNewlines)
        lastDetection = detection

        let fallbackInstitution = detection.institution?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackAccountType = detection.type?.toQuickIngestAccountType(bankSubtype: bankSubtype)?.toAccountType()
        let fallbackBalance = MoneyParsing.parseDecimalInput(balanceInput)
        let fallbackTypicalPayment = MoneyParsing.parseDecimalInput(monthlyPaymentInput)
        let fallbackAPR = MoneyParsing.parsePercentInput(aprPercentInput)
        let fallbackAPRScale = inferredAPRScale(from: aprPercentInput)

        let routedURL = stageURLToCaches(url)
        Task { @MainActor in
            if let fallbackAccountType {
                vm.newAccountType = fallbackAccountType
            }
            vm.userInstitutionName = fallbackInstitution ?? ""
            await coordinator.importURL(routedURL, hint: detection.type, modelContext: modelContext, settings: settings)
            applyDetectedAccountSelections(selectedDetectedAccounts)
            seedImportReviewFallbacks(
                institution: fallbackInstitution,
                accountType: fallbackAccountType,
                balance: fallbackBalance,
                typicalPayment: fallbackTypicalPayment,
                aprFraction: fallbackAPR,
                aprScale: fallbackAPRScale
            )
            detectionSheetModel = nil
        }
    }

    @MainActor
    private func openFullImportReview(for model: DetectionSheetModel) {
        openFullImportReview(detection: model.detection, url: model.url, selectedDetectedAccounts: detectedAccounts)
    }

    @MainActor
    private func applyDetectedAccountSelections(_ selections: [DetectionReviewSheet.DetectedAccountSelection]) {
        guard !selections.isEmpty, var staged = vm.staged else { return }

        let importedSelections = selections.filter(\.shouldImport)
        guard !importedSelections.isEmpty else {
            vm.staged = staged
            return
        }
        let selectedLabels = Set(importedSelections.map { normalizedDetectedAccountKey($0.id) })
        let parserLabels = Set(
            (staged.balances.map { $0.sourceAccountLabel } + staged.transactions.map { $0.sourceAccountLabel })
                .map { normalizedDetectedAccountKey(normalizedBankSummaryLabel($0)) }
                .filter { $0 != "default" && isSupportedBankPreviewKey($0) }
        )
        let labelsToKeep = selectedLabels.union(parserLabels)
        let soleImportedLabel = importedSelections.count == 1 ? importedSelections[0].id : nil
        let summaryByLabel = Dictionary(
            uniqueKeysWithValues: (importedPreview?.bankBalanceSummaries ?? []).map {
                (normalizedDetectedAccountKey($0.id), $0)
            }
        )

        let originalBalanceCount = staged.balances.count
        let originalTransactionCount = staged.transactions.count
        staged.balances = staged.balances.filter { balance in
            let key = normalizedDetectedAccountKey(normalizedBankSummaryLabel(balance.sourceAccountLabel))
            return labelsToKeep.contains(key)
        }.map { balance in
            var updated = balance
            updated.include = true
            if let soleImportedLabel,
               normalizedDetectedAccountKey(normalizedBankSummaryLabel(updated.sourceAccountLabel)) == "default" {
                updated.sourceAccountLabel = soleImportedLabel
            }
            return updated
        }

        let existingBalanceLabels = Set(
            staged.balances.map { normalizedDetectedAccountKey(normalizedBankSummaryLabel($0.sourceAccountLabel)) }
        )
        let referenceDate = staged.balances.map(\.asOfDate).max() ?? Date()

        for selection in importedSelections where !existingBalanceLabels.contains(selection.id) {
            let summary = summaryByLabel[selection.id]
            guard let endingBalance = summary?.endingBalance ?? selection.endingBalance else { continue }
            staged.balances.append(
                StagedBalance(
                    asOfDate: referenceDate,
                    balance: endingBalance,
                    interestRateAPR: nil,
                    interestRateScale: nil,
                    typicalPaymentAmount: nil,
                    include: true,
                    sourceAccountLabel: selection.id
                )
            )
        }

        let originalTransactions = staged.transactions
        var filteredTransactions = staged.transactions.filter { transaction in
            let key = normalizedDetectedAccountKey(normalizedBankSummaryLabel(transaction.sourceAccountLabel))
            return labelsToKeep.contains(key)
        }.map { transaction in
            var updated = transaction
            updated.include = true
            if let soleImportedLabel,
               normalizedDetectedAccountKey(normalizedBankSummaryLabel(updated.sourceAccountLabel)) == "default" {
                updated.sourceAccountLabel = soleImportedLabel
            }
            return updated
        }
        if filteredTransactions.isEmpty && !originalTransactions.isEmpty {
            AMLogging.log(
                "CashFlow detected-account filter preserved transactions after label mismatch — selected=\(Array(selectedLabels).sorted()) rawTransactionLabels=\(Array(Set(originalTransactions.map { normalizedBankSummaryLabel($0.sourceAccountLabel) })).sorted())",
                component: "Import"
            )
            filteredTransactions = originalTransactions.map { transaction in
                var updated = transaction
                updated.include = true
                if let soleImportedLabel {
                    updated.sourceAccountLabel = soleImportedLabel
                }
                return updated
            }
        }
        staged.transactions = filteredTransactions

        AMLogging.log(
            "CashFlow detected-account filter — selected=\(Array(selectedLabels).sorted()) parserLabels=\(Array(parserLabels).sorted()) kept=\(Array(labelsToKeep).sorted()) balances \(originalBalanceCount)->\(staged.balances.count) transactions \(originalTransactionCount)->\(staged.transactions.count)",
            component: "Import"
        )

        if let resolvedType = resolvedAccountType(from: importedSelections) {
            staged.suggestedAccountType = resolvedType
            vm.newAccountType = resolvedType
        }

        vm.staged = staged
    }

    private func resolvedAccountType(from selections: [DetectionReviewSheet.DetectedAccountSelection]) -> Account.AccountType? {
        let imported = selections.filter(\.shouldImport)
        guard !imported.isEmpty else { return nil }

        let uniqueTypes = Set(imported.map(\.statementType))
        if uniqueTypes.count == 1, let onlyType = uniqueTypes.first {
            switch onlyType {
            case .loan:
                return .loan
            case .creditCard:
                return .creditCard
            case .brokerage:
                return .brokerage
            case .bank:
                if imported.count == 1 {
                    switch imported[0].id {
                    case "savings":
                        return .savings
                    case "cash":
                        return .cash
                    default:
                        return .checking
                    }
                }
                return .checking
            }
        }

        if imported.count == 1 {
            switch imported[0].id {
            case "loan":
                return .loan
            case "savings":
                return .savings
            case "cash":
                return .cash
            case "brokerage":
                return .brokerage
            default:
                return .checking
            }
        }

        return nil
    }

    @MainActor
    private func applyQuickIngestResult(_ result: QuickIngestResult, stagedURL: URL) {
        ingestedAccount = result.account
        selectedAccountID = result.account.id
        externalSelectedAccountID = result.account.id
        lastImportedURL = stagedURL
        balanceInput = AppFormatters.currencyFormatter().string(from: NSDecimalNumber(decimal: result.balance.magnitude)) ?? balanceInput
        routeImportedAccount(result.account)
    }

    @MainActor
    private func seedImportReviewFallbacks(
        institution: String?,
        accountType: Account.AccountType?,
        balance: Decimal?,
        typicalPayment: Decimal?,
        aprFraction: Decimal?,
        aprScale: Int?
    ) {
        guard var staged = vm.staged else { return }

        let normalizedInstitution = institution?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedInstitution, !normalizedInstitution.isEmpty {
            vm.userInstitutionName = normalizedInstitution
            if staged.inferredInstitutionName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                staged.inferredInstitutionName = normalizedInstitution
            }
        }

        if let accountType {
            staged.suggestedAccountType = accountType
            vm.newAccountType = accountType
        }

        let hasSeedableBalance = balance.map { $0 != .zero } ?? false
        let targetIndex: Int?
        if let existingIndex = staged.balances.indices.max(by: { staged.balances[$0].asOfDate < staged.balances[$1].asOfDate }) {
            targetIndex = existingIndex
        } else if hasSeedableBalance {
            let label = normalizedSourceLabel(for: accountType)
            staged.balances.append(
                StagedBalance(
                    asOfDate: Date(),
                    balance: balance ?? .zero,
                    interestRateAPR: aprFraction,
                    interestRateScale: aprScale,
                    typicalPaymentAmount: typicalPayment,
                    include: true,
                    sourceAccountLabel: label
                )
            )
            targetIndex = staged.balances.indices.last
        } else {
            targetIndex = nil
        }

        if let targetIndex {
            if hasSeedableBalance, staged.balances[targetIndex].balance == .zero {
                staged.balances[targetIndex].balance = balance ?? .zero
            }
            if staged.balances[targetIndex].interestRateAPR == nil, let aprFraction {
                staged.balances[targetIndex].interestRateAPR = aprFraction
                staged.balances[targetIndex].interestRateScale = aprScale
            }
            if staged.balances[targetIndex].typicalPaymentAmount == nil, let typicalPayment, typicalPayment > 0 {
                staged.balances[targetIndex].typicalPaymentAmount = typicalPayment
            }
            if staged.balances[targetIndex].sourceAccountLabel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
               let label = normalizedSourceLabel(for: accountType) {
                staged.balances[targetIndex].sourceAccountLabel = label
            }
        }

        vm.staged = staged
    }

    private func normalizedSourceLabel(for accountType: Account.AccountType?) -> String? {
        guard let accountType else { return nil }

        switch accountType {
        case .creditCard:
            return "creditCard"
        case .loan:
            return "loan"
        case .checking:
            return "checking"
        case .savings:
            return "savings"
        case .cash, .property:
            return "default"
        case .brokerage:
            return "brokerage"
        case .other:
            return nil
        }
    }

    private func inferredAPRScale(from raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let separator = Locale.current.decimalSeparator,
              let range = trimmed.range(of: separator) else {
            return nil
        }

        let suffix = trimmed[range.upperBound...]
        let digits = suffix.filter(\.isNumber)
        return digits.isEmpty ? 0 : digits.count
    }

    private func performQuickIngest(using detection: IntakeDetection, url: URL) {
        let stagedURL = stageURLToCaches(url)
        let hints = QuickIngestHints(
            institution: detection.institution?.trimmingCharacters(in: .whitespacesAndNewlines),
            accountType: detection.type?.toQuickIngestAccountType(bankSubtype: bankSubtype)
        )

        isQuickIngesting = true
        quickIngestError = nil

        Task {
            do {
                let result = try await QuickIngestor().ingest(url: stagedURL, hints: hints, context: modelContext)
                await MainActor.run {
                    isQuickIngesting = false
                    applyQuickIngestResult(result, stagedURL: stagedURL)
                    detectionSheetModel = nil
                }
            } catch {
                await MainActor.run {
                    isQuickIngesting = false
                    quickIngestError = error
                }
            }
        }
    }

    private var isImportSheetPresented: Binding<Bool> {
        Binding(
            get: {
                !isPreparingDetectionReview &&
                detectionSheetModel == nil &&
                (vm.staged != nil || vm.mappingSession != nil)
            },
            set: { presented in
                if !presented {
                    vm.staged = nil
                    vm.mappingSession = nil

                    // Keep the detail pane tied to persisted account data only. A cancelled review
                    // should not leave the just-picked file visible as though it had been saved.
                    if let id = selectedAccountID {
                        updateLastImportedURL(for: id)
                    } else {
                        lastImportedURL = nil
                    }

                    if let id = vm.selectedAccountID {
                        externalSelectedAccountID = id
                        let account = accounts.first(where: { $0.id == id })
                        routeImportedAccount(account)
                    }
                }
            }
        )
    }

    var body: some View {
        VStack(spacing: 16) {
            if cashFlowAccounts.isEmpty {
                Text("Get started by adding your cash flow accounts")
                    .foregroundStyle(.secondary)
            }

            columnsView

            Divider().padding(.top, 4)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 32)
        .background(.background)
        .onAppear {
            if let externalSelectedAccountID {
                selectedAccountID = externalSelectedAccountID
            }
            if selectedAccountID == nil {
                selectedAccountID = cashFlowAccounts.first?.id
            }
            if let id = selectedAccountID {
                externalSelectedAccountID = id
                updateLastImportedURL(for: id)
            }
        }
        .onChange(of: accounts) { _, newValue in
            let availableIDs = Set(newValue.filter {
                switch $0.type {
                case .checking, .savings, .cash:
                    return true
                default:
                    return false
                }
            }.map(\.id))

            if let externalSelectedAccountID, availableIDs.contains(externalSelectedAccountID), selectedAccountID != externalSelectedAccountID {
                selectedAccountID = externalSelectedAccountID
            }

            if selectedAccountID == nil {
                selectedAccountID = cashFlowAccounts.first?.id
            } else if let selectedAccountID, !availableIDs.contains(selectedAccountID) {
                self.selectedAccountID = cashFlowAccounts.first?.id
            }

            Task { @MainActor in
                if let id = selectedAccountID {
                    updateLastImportedURL(for: id)
                } else {
                    lastImportedURL = nil
                }
            }
        }
        .onChange(of: selectedAccountID) { _, id in
            if externalSelectedAccountID != id {
                externalSelectedAccountID = id
            }
            Task { @MainActor in
                if let id {
                    updateLastImportedURL(for: id)
                } else {
                    lastImportedURL = nil
                }
            }
        }
        .onChange(of: externalSelectedAccountID) { _, id in
            guard selectedAccountID != id else { return }
            if let id, cashFlowAccounts.contains(where: { $0.id == id }) {
                selectedAccountID = id
            }
        }
        .toolbar {
            if horizontalSizeClass == .compact {
                ToolbarItem(placement: .topBarLeading) {
                    PlanToolbarButton(statementActionTitle, fixedWidth: statementActionWidth) {
                        showStatementSheet = true
                    }
                    .disabled(currentAccount() == nil)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add Manually") {
                    selectedType = .bank
                    editedInstitution = ""
                    bankSubtype = nil
                    monthlyPaymentInput = ""
                    aprPercentInput = ""
                    balanceInput = ""
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
                    importError = NSError(domain: "Import", code: -1, userInfo: [NSLocalizedDescriptionKey: "No file selected"])
                }
            case .failure(let error):
                importError = error
            }
        }
        .alert("Import Failed", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError?.localizedDescription ?? "Unknown error")
        }
        .alert("Quick Ingest Failed", isPresented: Binding(get: { quickIngestError != nil }, set: { if !$0 { quickIngestError = nil } })) {
            Button("Open Review") {
                if let model = detectionSheetModel {
                    openFullImportReview(for: model)
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
            .applySheetSizing()
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
            let account = currentAccount()
            DetectionReviewSheet(
                detection: model.detection,
                url: model.url,
                selectedType: $selectedType,
                editedInstitution: $editedInstitution,
                bankSubtype: $bankSubtype,
                monthlyPaymentInput: $monthlyPaymentInput,
                aprPercentInput: $aprPercentInput,
                balanceInput: $balanceInput,
                importedTypicalPayment: model.preview?.typicalPayment,
                importedAPRFraction: model.preview?.aprFraction,
                importedAPRScale: model.preview?.aprScale,
                importedBalance: model.preview?.balance,
                importedBalanceDate: model.preview?.balanceDate,
                importedBankBalanceSummaries: model.preview?.bankBalanceSummaries.map {
                    DetectionReviewSheet.ImportedBankBalanceSummary(
                        id: $0.id,
                        label: $0.label,
                        beginningBalance: $0.beginningBalance,
                        endingBalance: $0.endingBalance,
                        endingBalanceDate: $0.endingBalanceDate
                    )
                } ?? [],
                routeConfirmationText: model.routeConfirmationText,
                detectedAccounts: $detectedAccounts,
                account: account,
                latestBalance: account.flatMap { latestBalance(for: $0) },
                isQuickIngesting: $isQuickIngesting,
                onSave: { detection, incomingURL, selections in
                    detectedAccounts = selections
                    openFullImportReview(detection: detection, url: incomingURL, selectedDetectedAccounts: selections)
                },
                onDiscard: {
                    isPreparingDetectionReview = false
                    detectionSheetModel = nil
                }
            )
            .applySheetSizing()
        }
#else
        .sheet(item: $detectionSheetModel) { model in
            let account = currentAccount()
            DetectionReviewSheet(
                detection: model.detection,
                url: model.url,
                selectedType: $selectedType,
                editedInstitution: $editedInstitution,
                bankSubtype: $bankSubtype,
                monthlyPaymentInput: $monthlyPaymentInput,
                aprPercentInput: $aprPercentInput,
                balanceInput: $balanceInput,
                importedTypicalPayment: model.preview?.typicalPayment,
                importedAPRFraction: model.preview?.aprFraction,
                importedAPRScale: model.preview?.aprScale,
                importedBalance: model.preview?.balance,
                importedBalanceDate: model.preview?.balanceDate,
                importedBankBalanceSummaries: model.preview?.bankBalanceSummaries.map {
                    DetectionReviewSheet.ImportedBankBalanceSummary(
                        id: $0.id,
                        label: $0.label,
                        beginningBalance: $0.beginningBalance,
                        endingBalance: $0.endingBalance,
                        endingBalanceDate: $0.endingBalanceDate
                    )
                } ?? [],
                routeConfirmationText: model.routeConfirmationText,
                detectedAccounts: $detectedAccounts,
                account: account,
                latestBalance: account.flatMap { latestBalance(for: $0) },
                isQuickIngesting: $isQuickIngesting,
                onSave: { detection, incomingURL, selections in
                    detectedAccounts = selections
                    openFullImportReview(detection: detection, url: incomingURL, selectedDetectedAccounts: selections)
                },
                onDiscard: {
                    isPreparingDetectionReview = false
                    detectionSheetModel = nil
                }
            )
        }
#endif
        .sheet(isPresented: $showStatementSheet) {
            statementSheetContent
        }
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
                    externalSelectedAccountID = account.id
                    updateLastImportedURL(for: account.id)
                    routeImportedAccount(account)
                }
            )
            .environment(\.modelContext, modelContext)
            .environmentObject(settings)
            .applySheetSizing()
        }
        .sheet(isPresented: isImportSheetPresented) {
            ImportSheetContentView(vm: vm)
                .environment(\.modelContext, modelContext)
        }
        .onChange(of: pendingExternal?.id, initial: true) { _, _ in
            guard let pending = pendingExternal else { return }
            isPreparingDetectionReview = true
            Task {
                let stagedURL = stageURLToCaches(pending.url)
                let effectiveType = effectiveImportedStatementType(for: pending.type, url: stagedURL)
                let preview = await extractImportedPreview(from: stagedURL, hint: effectiveType)
                await MainActor.run {
                    editedInstitution = pending.institution ?? ""
                    selectedType = effectiveType
                    importedPreview = preview
                    detectedAccounts = buildDetectedAccounts(from: preview)
                    bankSubtype = nil
                    applyImportedPreviewToInputs(preview)
                    let detection = IntakeDetection(type: selectedType, institution: editedInstitution, confidence: 0.6)
                    detectionSheetModel = DetectionSheetModel(
                        detection: detection,
                        url: stagedURL,
                        preview: preview,
                        routeConfirmationText: "Opened as Cash Flow"
                    )
                    isPreparingDetectionReview = false
                    pendingExternal = nil
                }
            }
        }
    }
}
