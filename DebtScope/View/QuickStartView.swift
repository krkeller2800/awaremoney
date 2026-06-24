import SwiftUI
import Combine
import CoreSpotlight
import UniformTypeIdentifiers
import SwiftData

private enum QuickStartTopic: String, CaseIterable, Identifiable {
    case debtPayoff = "Liability Accounts"
    case debtPayoffPlan = "Payoff Plan"
    case compareStrategies = "Compare Strategies"
    case netWorth = "Net Worth"
    case cashFlow = "Asset Accounts"
    case incomeBills = "Income & Bills"
    case assets = "Physical Assets"
    case statementReview = "Needs Review"
    case assistant = "Assistant"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .debtPayoff: return "Debts"
        case .debtPayoffPlan: return "Payoff Plan"
        case .compareStrategies: return "Debt Summary"
        case .netWorth: return "Net Worth"
        case .cashFlow: return "Cash Accounts"
        case .incomeBills: return "Add Income & Bills"
        case .assets: return "Assets"
        case .statementReview: return "Needs Review"
        case .assistant: return "Assistant"
        }
    }
}

struct QuickStartPendingImport: Equatable {
    let id = UUID()
    let url: URL
    let type: StatementType?
    let institution: String?
}

private struct QuickStartReviewItem: Identifiable, Equatable, Codable {
    let id: UUID
    let url: URL
    var type: StatementType?
    var institution: String?
    let addedAt: Date
    let managedFileName: String?

    init(
        id: UUID = UUID(),
        url: URL,
        type: StatementType?,
        institution: String?,
        addedAt: Date = Date(),
        managedFileName: String? = nil
    ) {
        self.id = id
        self.url = url
        self.type = type
        self.institution = institution
        self.addedAt = addedAt
        self.managedFileName = managedFileName
    }
}

private struct QuickStartReviewState: Codable {
    var items: [QuickStartReviewItem]
    var selectedItemID: UUID?
}

private enum QuickStartReviewStorage {
    static let defaultsKey = "quick_start_review_state"

    static func loadState() -> QuickStartReviewState? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else {
            AMLogging.log(
                "QuickStartReviewStorage load: no defaults key bundle=\(Bundle.main.bundleIdentifier ?? "nil")",
                component: "Import"
            )
            return nil
        }

        do {
            let state = try JSONDecoder().decode(QuickStartReviewState.self, from: data)
            AMLogging.log(
                "QuickStartReviewStorage load: decoded items=\(state.items.count) selected=\(state.selectedItemID?.uuidString ?? "nil") bundle=\(Bundle.main.bundleIdentifier ?? "nil")",
                component: "Import"
            )
            return state
        } catch {
            AMLogging.error(
                "QuickStartReviewStorage load: decode failed bytes=\(data.count) error=\(error.localizedDescription)",
                component: "Import"
            )
            return nil
        }
    }

    static func saveState(_ state: QuickStartReviewState) {
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
            UserDefaults.standard.synchronize()
            AMLogging.log(
                "QuickStartReviewStorage save: items=\(state.items.count) selected=\(state.selectedItemID?.uuidString ?? "nil") bytes=\(data.count) bundle=\(Bundle.main.bundleIdentifier ?? "nil")",
                component: "Import"
            )
        } else {
            AMLogging.error(
                "QuickStartReviewStorage save: encode failed items=\(state.items.count)",
                component: "Import"
            )
        }
    }

    static func stageForReview(_ sourceURL: URL, id: UUID) -> URL {
        guard let directoryURL = reviewDirectoryURL(create: true) else {
            AMLogging.error(
                "QuickStartReviewStorage stage: no review directory source=\(sourceURL.lastPathComponent)",
                component: "Import"
            )
            return sourceURL
        }
        let sourceURL = sourceURL.standardizedFileURL

        if isManagedReviewURL(sourceURL) {
            AMLogging.log(
                "QuickStartReviewStorage stage: already managed file=\(sourceURL.lastPathComponent) readable=\(FileManager.default.isReadableFile(atPath: sourceURL.path)) path=\(sourceURL.path)",
                component: "Import"
            )
            return sourceURL
        }

        let destinationURL = directoryURL
            .appendingPathComponent("\(id.uuidString)-\(sourceURL.lastPathComponent)")
            .standardizedFileURL

        if FileManager.default.isReadableFile(atPath: destinationURL.path) {
            AMLogging.log(
                "QuickStartReviewStorage stage: destination exists file=\(destinationURL.lastPathComponent) readable=true path=\(destinationURL.path)",
                component: "Import"
            )
            return destinationURL
        }

        let didStartSecurityScope = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartSecurityScope {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            AMLogging.log(
                "QuickStartReviewStorage stage: copied source=\(sourceURL.lastPathComponent) destination=\(destinationURL.lastPathComponent) reviewDir=\(directoryURL.path)",
                component: "Import"
            )
            return destinationURL
        } catch {
            do {
                let data = try Data(contentsOf: sourceURL)
                try data.write(to: destinationURL, options: .atomic)
                AMLogging.log(
                    "QuickStartReviewStorage stage: data-wrote source=\(sourceURL.lastPathComponent) destination=\(destinationURL.lastPathComponent) bytes=\(data.count) reviewDir=\(directoryURL.path)",
                    component: "Import"
                )
                return destinationURL
            } catch {
                AMLogging.error(
                    "QuickStartReviewStorage: failed to stage review file=\(sourceURL.lastPathComponent) error=\(error.localizedDescription)",
                    component: "Import"
                )
                return sourceURL
            }
        }
    }

    static func migratedItemIfReadable(_ item: QuickStartReviewItem) -> QuickStartReviewItem? {
        guard let readableURL = readableURL(for: item) else {
            AMLogging.log(
                "QuickStartReviewStorage migrate: dropping unreadable id=\(item.id) managedFile=\(item.managedFileName ?? "nil") oldPath=\(item.url.path)",
                component: "Import"
            )
            return nil
        }
        let durableURL = stageForReview(readableURL, id: item.id)
        let managedFileName = managedFileName(for: durableURL)
        AMLogging.log(
            "QuickStartReviewStorage migrate: id=\(item.id) from=\(readableURL.path) to=\(durableURL.path) managedFile=\(managedFileName ?? "nil") readable=\(FileManager.default.isReadableFile(atPath: durableURL.path))",
            component: "Import"
        )
        return QuickStartReviewItem(
            id: item.id,
            url: durableURL,
            type: item.type,
            institution: item.institution,
            addedAt: item.addedAt,
            managedFileName: managedFileName
        )
    }

    static func managedFileName(for url: URL) -> String? {
        isManagedReviewURL(url.standardizedFileURL) ? url.lastPathComponent : nil
    }

    static func removeManagedFile(_ url: URL) {
        let fileURL = url.standardizedFileURL
        guard isManagedReviewURL(fileURL) else {
            AMLogging.log(
                "QuickStartReviewStorage remove: skipped unmanaged path=\(fileURL.path)",
                component: "Import"
            )
            return
        }
        do {
            try FileManager.default.removeItem(at: fileURL)
            AMLogging.log(
                "QuickStartReviewStorage remove: deleted path=\(fileURL.path)",
                component: "Import"
            )
        } catch {
            AMLogging.error(
                "QuickStartReviewStorage remove: failed path=\(fileURL.path) error=\(error.localizedDescription)",
                component: "Import"
            )
        }
    }

    private static func reviewDirectoryURL(create: Bool) -> URL? {
        do {
            let appSupportURL = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: create
            )
            let directoryURL = appSupportURL
                .appendingPathComponent("NeedsReviewStatements", isDirectory: true)
                .standardizedFileURL
            if create {
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            }
            return directoryURL
        } catch {
            AMLogging.error(
                "QuickStartReviewStorage: failed to resolve review directory error=\(error.localizedDescription)",
                component: "Import"
            )
            return nil
        }
    }

    private static func isManagedReviewURL(_ url: URL) -> Bool {
        guard let directoryURL = reviewDirectoryURL(create: false) else { return false }
        return url.standardizedFileURL.path.hasPrefix(directoryURL.standardizedFileURL.path + "/")
    }

    private static func readableURL(for item: QuickStartReviewItem) -> URL? {
        if let managedFileName = item.managedFileName,
           let currentManagedURL = currentManagedURL(fileName: managedFileName),
           FileManager.default.isReadableFile(atPath: currentManagedURL.path) {
            AMLogging.log(
                "QuickStartReviewStorage readableURL: resolved managedFile=\(managedFileName) path=\(currentManagedURL.path)",
                component: "Import"
            )
            return currentManagedURL
        }

        if FileManager.default.isReadableFile(atPath: item.url.path) {
            AMLogging.log(
                "QuickStartReviewStorage readableURL: old absolute path still readable path=\(item.url.path)",
                component: "Import"
            )
            return item.url
        }

        let legacyFileName = item.url.lastPathComponent
        if let currentManagedURL = currentManagedURL(fileName: legacyFileName),
           FileManager.default.isReadableFile(atPath: currentManagedURL.path) {
            AMLogging.log(
                "QuickStartReviewStorage readableURL: recovered legacy fileName=\(legacyFileName) path=\(currentManagedURL.path)",
                component: "Import"
            )
            return currentManagedURL
        }

        return nil
    }

    private static func currentManagedURL(fileName: String) -> URL? {
        guard !fileName.isEmpty,
              let directoryURL = reviewDirectoryURL(create: false) else { return nil }
        return directoryURL.appendingPathComponent(fileName).standardizedFileURL
    }
}

private enum SampleStatementResource: String, CaseIterable {
    case loanOne = "001-genericLoan.pdf"
    case checkingOne = "002-checking.pdf"
    case creditCardOne = "003-creditCard.pdf"
    case checkingTwo = "004-checking.pdf"
    case checkingThree = "005-checking.pdf"
    case creditCardTwo = "006-creditCard.pdf"
    case creditCardThree = "007-creditCard.pdf"
    case creditCardFour = "008-creditCard.pdf"
    case creditCardFive = "009-creditCard.pdf"
    case loanTwo = "010-genericLoan.pdf"
    case loanThree = "011-genericLoan.pdf"

    static var availableURLs: [URL] {
        allCases.compactMap(\.url)
    }

    static var availableResources: [(resource: SampleStatementResource, url: URL)] {
        allCases.compactMap { resource in
            resource.url.map { (resource, $0) }
        }
    }

    var statementType: StatementType {
        switch self {
        case .loanOne, .loanTwo, .loanThree:
            return .loan
        case .creditCardOne, .creditCardTwo, .creditCardThree, .creditCardFour, .creditCardFive:
            return .creditCard
        case .checkingOne, .checkingTwo, .checkingThree:
            return .bank
        }
    }

    var accountType: Account.AccountType {
        statementType.defaultAccountType
    }

    private var url: URL? {
        let name = URL(fileURLWithPath: rawValue).deletingPathExtension().lastPathComponent
        return Bundle.main.url(forResource: name, withExtension: "pdf", subdirectory: "SampleData")
            ?? Bundle.main.url(forResource: name, withExtension: "pdf", subdirectory: "Resources/SampleData")
            ?? Bundle.main.url(forResource: name, withExtension: "pdf")
    }
}

private struct SampleCashFlowItem {
    let kind: CashFlowItem.Kind
    let name: String
    let amount: Decimal
    let frequency: PaymentFrequency
    let dayOfMonth: Int
    let notes: String

    static let defaults: [SampleCashFlowItem] = [
        SampleCashFlowItem(
            kind: .income,
            name: "Monthly Paycheck",
            amount: Decimal(4850),
            frequency: .monthly,
            dayOfMonth: 1,
            notes: "Sample take-home pay"
        ),
        SampleCashFlowItem(
            kind: .bill,
            name: "Utility Bill",
            amount: Decimal(string: "148.75") ?? 0,
            frequency: .monthly,
            dayOfMonth: 12,
            notes: "Sample electricity and water bill"
        ),
        SampleCashFlowItem(
            kind: .bill,
            name: "Insurance Bill",
            amount: Decimal(string: "186.40") ?? 0,
            frequency: .monthly,
            dayOfMonth: 20,
            notes: "Sample auto and renters insurance"
        )
    ]
}

private enum SampleDataIdentity {
    nonisolated static let dataVersionDefaultsKey = "DebtScope.sampleDataVersion"
    nonisolated static let currentDataVersion = "2026-06-24.sample-payoff-budget-copy"
    nonisolated static let statementFileNames = Set(SampleStatementResource.allCases.map(\.rawValue))
    nonisolated static let institutionNames: Set<String> = Set([
        "Harborview Bank",
        "Summit Trail Finance",
        "Crescent Valley Lending",
        "Northstar Credit Union"
    ].map(normalizedText))

    nonisolated static func isSampleInstitution(_ institution: String?) -> Bool {
        guard let institution else { return false }
        return institutionNames.contains(normalizedText(institution))
    }

    nonisolated static func isSampleReviewItem(_ item: QuickStartReviewItem) -> Bool {
        let fileName = item.url.lastPathComponent
        let managedFileName = item.managedFileName ?? ""

        if statementFileNames.contains(where: { sampleFileName in
            fileName == sampleFileName
                || fileName.hasSuffix("-\(sampleFileName)")
                || managedFileName == sampleFileName
                || managedFileName.hasSuffix("-\(sampleFileName)")
        }) {
            return true
        }

        if let institution = item.institution,
           institutionNames.contains(normalizedText(institution)) {
            return true
        }

        return false
    }

    nonisolated private static func normalizedText(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined()
    }
}

struct QuickStartView: View {
    @StateObject private var vm: ImportViewModel
    @State private var coordinator: StatementImportCoordinator
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var importRouter: ImportOpenRouter
    @EnvironmentObject private var dataModeController: DebtScopeDataModeController

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Query(sort: [SortDescriptor(\Account.name, order: .forward)]) private var accounts: [Account]
    @Query(sort: [SortDescriptor(\CashFlowItem.name, order: .forward)]) private var cashFlowItems: [CashFlowItem]
    @State private var selection: QuickStartTopic? = .debtPayoff
    @State private var compactPath: [QuickStartTopic] = []
    @State private var showImporter = false
    @State private var showAccountSearch = false
    @State private var showAbout = false
    @State private var showSettings = false
    @State private var showBackupRestore = false
    @State private var showHelp = false
    @State private var showDebug = false
    @State private var showPaywall = false
    @State private var paywallSource: PaywallSource = .unknown
    @State private var importReadyWarningMessage: String? = nil
    @State private var importProgressID: UUID? = nil
    @State private var showImportProgress = false
    @State private var importIsTakingLonger = false
    @State private var isLoadingSampleStatements = false
    @State private var quickStartPending: QuickStartPendingImport? = nil
    @State private var reviewItems: [QuickStartReviewItem] = []
    @State private var selectedReviewItemID: UUID? = nil
    @State private var didLoadPersistedReviewState = false
    @State private var debtPayoffSelectedAccountID: UUID? = nil
    @State private var cashFlowSelectedAccountID: UUID? = nil
    private struct RoutedAccountDetail: Identifiable {
        let accountID: UUID
        let focus: AccountDetailInitialFocus?

        var id: String {
            "\(accountID.uuidString):\(String(describing: focus))"
        }
    }
    @State private var routedAccountDetail: RoutedAccountDetail? = nil
    fileprivate enum PlanSheetMode: String, CaseIterable { case incomeBills, summary }
    @State private var planSheetMode: PlanSheetMode = .incomeBills

    init() {
        let vm = ImportViewModel(parsers: ImportViewModel.defaultParsers())
        _vm = StateObject(wrappedValue: vm)
        _coordinator = State(initialValue: StatementImportCoordinator(vm: vm))
    }

    private var topicGroups: [(title: String, topics: [QuickStartTopic])] {
        var groups: [(title: String, topics: [QuickStartTopic])] = [
            ("Debt", [.debtPayoffPlan, .debtPayoff, .compareStrategies]),
            ("Cash Flow", [.cashFlow, .incomeBills]),
            ("Worth", [.netWorth, .assets])
        ]

        if !reviewItems.isEmpty {
            groups.append(("Review", [.statementReview]))
        }

        groups.append(("Local AI", [.assistant]))

        return groups
    }

    @MainActor
    private var isUsingActiveModelContext: Bool {
        ObjectIdentifier(modelContext) == ObjectIdentifier(dataModeController.activeContainer.mainContext)
    }

    private func topicFor(statementType: StatementType?) -> QuickStartTopic? {
        switch statementType {
        case .creditCard, .loan:
            return .debtPayoff
        case .bank:
            return .cashFlow
        case .brokerage:
            return .netWorth
        default:
            return .statementReview
        }
    }

    private func accountDetailFocus(for routeFocus: DebtScopeAppRouteFocus?) -> AccountDetailInitialFocus? {
        switch routeFocus {
        case .apr:
            return .apr
        case .paymentAmount:
            return .paymentAmount
        case .none:
            return nil
        }
    }

    private func topicFor(appSection: DebtScopeAppSection) -> QuickStartTopic {
        switch appSection {
        case .debtSummary:
            return .compareStrategies
        case .upcomingBills, .incomeBills:
            return .incomeBills
        case .assistant:
            return .assistant
        case .debtPayoffPlan:
            return .debtPayoffPlan
        case .liabilityAccounts, .accountDetail:
            return .debtPayoff
        case .statementReview, .importReview:
            return .statementReview
        }
    }

    private func routeToAppSection(_ section: DebtScopeAppSection, accountID: UUID? = nil, focus: DebtScopeAppRouteFocus? = nil) {
        if section == .accountDetail, let accountID {
            routedAccountDetail = RoutedAccountDetail(accountID: accountID, focus: accountDetailFocus(for: focus))
            return
        }

        let topic = topicFor(appSection: section)

        if section == .upcomingBills || section == .incomeBills {
            planSheetMode = .incomeBills
        }

        if section == .liabilityAccounts, let accountID {
            debtPayoffSelectedAccountID = accountID
        }

        if isCompactLayout {
            compactPath.removeAll()
            compactPath.append(topic)
        } else {
            selection = topic
        }
    }

    private func routeSpotlightActivity(_ userActivity: NSUserActivity) {
        guard userActivity.activityType == CSSearchableItemActionType,
              let identifier = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String else {
            return
        }

        if let section = DebtScopeSpotlightIndexer.section(from: identifier) {
            routeToAppSection(section)
            return
        }

        if let accountID = DebtScopeSpotlightIndexer.accountID(from: identifier) {
            routeToAccount(accountID)
            return
        }

        if DebtScopeSpotlightIndexer.billID(from: identifier) != nil {
            planSheetMode = .incomeBills
            routeToTopic(.incomeBills)
            return
        }

        if let transactionID = DebtScopeSpotlightIndexer.transactionID(from: identifier) {
            routeToTransaction(transactionID)
            return
        }

        if let accountID = DebtScopeSpotlightIndexer.debtPayoffAccountID(from: identifier) {
            debtPayoffSelectedAccountID = accountID
            routeToTopic(.debtPayoff)
        }
    }

    private func routeToAccount(_ accountID: UUID) {
        guard let account = accounts.first(where: { $0.id == accountID }) else { return }

        let topic: QuickStartTopic
        switch account.type {
        case .creditCard, .loan:
            debtPayoffSelectedAccountID = accountID
            topic = .debtPayoff
        case .checking, .savings, .cash:
            cashFlowSelectedAccountID = accountID
            topic = .cashFlow
        case .property:
            topic = .assets
        case .brokerage:
            topic = .netWorth
        case .other:
            topic = account.isManualAsset ? .assets : .cashFlow
        }

        routeToTopic(topic)
    }

    private func routeToTransaction(_ transactionID: UUID) {
        guard let transaction = fetchTransaction(id: transactionID) else {
            routeToTopic(.cashFlow)
            return
        }

        if let accountID = transaction.account?.id ?? transaction.accountID {
            routeToAccount(accountID)
        } else {
            routeToTopic(.cashFlow)
        }
    }

    private func routeToTopic(_ topic: QuickStartTopic) {
        if isCompactLayout {
            compactPath.removeAll()
            compactPath.append(topic)
        } else {
            selection = topic
        }
    }

    private var spotlightIndexFingerprint: String {
        let options = settings.spotlightIndexingOptions
        let accountFingerprint = accounts.map { account in
            [
                account.id.uuidString,
                account.name,
                account.typeRaw,
                account.assetCategoryRaw ?? "",
                account.institutionName ?? ""
            ].joined(separator: "|")
        }
        .joined(separator: "||")

        let billFingerprint = cashFlowItems.map { item in
            [
                item.id.uuidString,
                item.kindRaw,
                item.name
            ].joined(separator: "|")
        }
        .joined(separator: "||")

        return accountFingerprint
            + "|bills:\(billFingerprint)"
            + "|spotlight:\(options.allowsSensitiveFinancialIndexing)"
            + ":\(options.includesAccountNames)"
            + ":\(options.includesBillNames)"
            + ":\(options.includesTransactionPayees)"
            + ":\(options.includesDebtPayoffNames)"
    }

    private func refreshSpotlightIndexWithAccounts() {
        let options = settings.spotlightIndexingOptions
        DebtScopeSpotlightIndexer.refreshIndex(
            options: options,
            accounts: accounts,
            cashFlowItems: options.includesBillNames ? cashFlowItems : [],
            transactions: options.includesTransactionPayees ? fetchTransactions() : []
        )
    }

    private func fetchTransactions() -> [Transaction] {
        do {
            var descriptor = FetchDescriptor<Transaction>()
            descriptor.sortBy = [SortDescriptor(\Transaction.payee, order: .forward)]
            return try modelContext.fetch(descriptor)
        } catch {
            AMLogging.error("Failed to fetch transactions for Spotlight indexing: \(error.localizedDescription)", component: "Spotlight")
            return []
        }
    }

    private func fetchTransaction(id: UUID) -> Transaction? {
        do {
            let predicate = #Predicate<Transaction> { $0.id == id }
            let descriptor = FetchDescriptor<Transaction>(predicate: predicate)
            return try modelContext.fetch(descriptor).first
        } catch {
            AMLogging.error("Failed to fetch Spotlight transaction route target: \(error.localizedDescription)", component: "Spotlight")
            return nil
        }
    }

    private func routeImportedAccount(statementType: StatementType?, accountID: UUID?) {
        guard let statementType else { return }

        switch statementType {
        case .creditCard, .loan:
            debtPayoffSelectedAccountID = accountID
        case .bank:
            cashFlowSelectedAccountID = accountID
        case .brokerage:
            break
        }

        selection = topicFor(statementType: statementType) ?? selection
    }

    private func appendStatementForReview(url: URL, type: StatementType?, institution: String?) {
        AMLogging.log(
            "QuickStartReview append: incoming=\(url.path) type=\(String(describing: type)) institution=\(institution ?? "nil") existingCount=\(reviewItems.count)",
            component: "Import"
        )
        let existingIndex = reviewItems.firstIndex { $0.url.path == url.path }
        if let existingIndex {
            reviewItems[existingIndex].type = type ?? reviewItems[existingIndex].type
            reviewItems[existingIndex].institution = institution ?? reviewItems[existingIndex].institution
            selectedReviewItemID = reviewItems[existingIndex].id
        } else {
            let id = UUID()
            let durableURL = QuickStartReviewStorage.stageForReview(url, id: id)
            let item = QuickStartReviewItem(
                id: id,
                url: durableURL,
                type: type,
                institution: institution,
                managedFileName: QuickStartReviewStorage.managedFileName(for: durableURL)
            )
            reviewItems.append(item)
            selectedReviewItemID = item.id
        }
    }

    private func seedSampleCashFlowItemsIfNeeded() {
        var didInsert = false

        for sample in SampleCashFlowItem.defaults {
            let alreadyExists = cashFlowItems.contains { item in
                item.kind == sample.kind
                    && item.name.localizedCaseInsensitiveCompare(sample.name) == .orderedSame
            }

            guard !alreadyExists else { continue }

            let item = CashFlowItem(
                kind: sample.kind,
                name: sample.name,
                amount: sample.amount,
                frequency: sample.frequency,
                dayOfMonth: sample.dayOfMonth,
                notes: sample.notes,
                dataSetRaw: "sample"
            )
            modelContext.insert(item)
            didInsert = true
        }

        guard didInsert else { return }

        do {
            try modelContext.save()
            NotificationCenter.default.post(name: .accountsDidChange, object: nil)
        } catch {
            AMLogging.error("Failed to seed sample cash flow items: \(error.localizedDescription)", component: "QuickStartView")
        }
    }

    private func configureSamplePayoffBudgetDefaults() {
        let defaults = UserDefaults.standard
        defaults.set("recurringNet", forKey: "baselineBudgetSourceRaw")
        defaults.set(false, forKey: "useFixedDebtBudget")
        defaults.set(0.0, forKey: "debtBudgetOverrideAmount")
        defaults.set(500.0, forKey: "debtDiscretionaryReserveAmount")
        defaults.set(true, forKey: "includeNonMonthlyIncomeSpreads")
        defaults.set(1.0, forKey: "debtPaymentReinvestmentRate")
        defaults.synchronize()
    }

    private func hasImportedSampleStatement(named fileName: String) -> Bool {
        let descriptor = FetchDescriptor<ImportBatch>()
        let batches = (try? modelContext.fetch(descriptor)) ?? []
        return batches.contains { batch in
            batch.sourceFileName == fileName
                || ((batch.parserId?.hasPrefix("sample.") == true) && batch.sourceFileName == fileName)
        }
    }

    private func resetImportedSampleStatements() {
        let sampleFileNames = SampleDataIdentity.statementFileNames
        let batches = (try? modelContext.fetch(FetchDescriptor<ImportBatch>())) ?? []
        let sampleBatches = batches.filter { batch in
            batch.dataSetRaw == "sample"
                || sampleFileNames.contains(batch.sourceFileName)
                || (batch.parserId?.hasPrefix("sample.") == true)
        }

        let accounts = (try? modelContext.fetch(FetchDescriptor<Account>())) ?? []
        let sampleAccounts = accounts.filter { account in
            account.dataSetRaw == "sample"
                || SampleDataIdentity.isSampleInstitution(account.institutionName)
                || SampleDataIdentity.isSampleInstitution(account.name)
        }

        guard !sampleBatches.isEmpty || !sampleAccounts.isEmpty else { return }

        for batch in sampleBatches {
            modelContext.delete(batch)
        }

        for account in sampleAccounts {
            modelContext.delete(account)
        }

        do {
            try modelContext.save()
            NotificationCenter.default.post(name: .accountsDidChange, object: nil)
            AMLogging.log(
                "Reset sample imports before reload batches=\(sampleBatches.count) accounts=\(sampleAccounts.count)",
                component: "QuickStartView"
            )
        } catch {
            AMLogging.error("Failed to reset sample imports: \(error.localizedDescription)", component: "QuickStartView")
        }
    }

    private func removeStagedSampleStatementsFromReview() {
        var currentState = QuickStartReviewStorage.loadState() ?? QuickStartReviewState(
            items: reviewItems,
            selectedItemID: selectedReviewItemID
        )
        let stalePersistedItems = currentState.items.filter(SampleDataIdentity.isSampleReviewItem)

        if !stalePersistedItems.isEmpty {
            for item in stalePersistedItems {
                QuickStartReviewStorage.removeManagedFile(item.url)
            }

            currentState.items.removeAll(where: SampleDataIdentity.isSampleReviewItem)
            if let selectedItemID = currentState.selectedItemID,
               !currentState.items.contains(where: { $0.id == selectedItemID }) {
                currentState.selectedItemID = currentState.items.first?.id
            }
            QuickStartReviewStorage.saveState(currentState)
        }

        let staleLoadedItems = reviewItems.filter(SampleDataIdentity.isSampleReviewItem)
        if !staleLoadedItems.isEmpty {
            for item in staleLoadedItems {
                QuickStartReviewStorage.removeManagedFile(item.url)
            }

            reviewItems.removeAll(where: SampleDataIdentity.isSampleReviewItem)
        }

        if let selectedReviewItemID,
           !reviewItems.contains(where: { $0.id == selectedReviewItemID }) {
            self.selectedReviewItemID = reviewItems.first?.id
        }
    }

    private func repairSampleLiabilityTerms(
        accountID: UUID?,
        staged: StagedImport,
        resource: SampleStatementResource
    ) {
        guard resource.accountType == .loan || resource.accountType == .creditCard else { return }

        let account = sampleAccount(id: accountID, accountType: resource.accountType, staged: staged)
        guard let account else {
            AMLogging.error("Could not find sample liability account to repair for \(staged.sourceFileName)", component: "QuickStartView")
            return
        }

        var terms = account.loanTerms ?? LoanTerms()
        if let balance = preferredSampleLiabilityBalance(from: staged) {
            if let apr = balance.interestRateAPR {
                terms.apr = normalizedSampleAPR(apr)
                terms.aprScale = balance.interestRateScale
            } else if let apr = terms.apr {
                terms.apr = normalizedSampleAPR(apr)
            }

            terms.paymentAmount = sampleAmortizingPayment(
                for: balance.balance,
                apr: balance.interestRateAPR ?? terms.apr,
                proposedPayment: balance.typicalPaymentAmount ?? terms.paymentAmount
            )

            if terms.paymentDayOfMonth == nil {
                let day = Calendar(identifier: .gregorian).component(.day, from: balance.asOfDate)
                terms.paymentDayOfMonth = min(max(day, 1), 28)
            }
        } else if let snapshot = latestSampleSnapshot(for: account) {
            if let apr = snapshot.interestRateAPR {
                terms.apr = normalizedSampleAPR(apr)
                terms.aprScale = snapshot.interestRateScale
            } else if let apr = terms.apr {
                terms.apr = normalizedSampleAPR(apr)
            }

            terms.paymentAmount = sampleAmortizingPayment(
                for: snapshot.balance,
                apr: snapshot.interestRateAPR ?? terms.apr,
                proposedPayment: terms.paymentAmount
            )

            if terms.paymentDayOfMonth == nil {
                let day = Calendar(identifier: .gregorian).component(.day, from: snapshot.asOfDate)
                terms.paymentDayOfMonth = min(max(day, 1), 28)
            }
        }

        account.loanTerms = terms

        do {
            try modelContext.save()
        } catch {
            AMLogging.error("Failed to repair sample liability terms for \(account.name): \(error.localizedDescription)", component: "QuickStartView")
        }
    }

    private func repairExistingSampleLiabilityTerms() {
        let accounts = (try? modelContext.fetch(FetchDescriptor<Account>())) ?? []
        var didUpdate = false

        for account in accounts where account.type == .loan || account.type == .creditCard {
            let isSampleAccount = account.dataSetRaw == "sample"
                || SampleDataIdentity.isSampleInstitution(account.institutionName)
                || SampleDataIdentity.isSampleInstitution(account.name)
            guard isSampleAccount, let latestBalance = latestSampleSnapshot(for: account) else { continue }

            var terms = account.loanTerms ?? LoanTerms()
            if let apr = latestBalance.interestRateAPR {
                let normalizedAPR = normalizedSampleAPR(apr)
                if terms.apr != normalizedAPR {
                    terms.apr = normalizedAPR
                    didUpdate = true
                }
                terms.aprScale = latestBalance.interestRateScale
            } else if let apr = terms.apr {
                let normalizedAPR = normalizedSampleAPR(apr)
                if terms.apr != normalizedAPR {
                    terms.apr = normalizedAPR
                    didUpdate = true
                }
            }

            let repairedPayment = sampleAmortizingPayment(
                for: latestBalance.balance,
                apr: latestBalance.interestRateAPR ?? terms.apr,
                proposedPayment: terms.paymentAmount
            )
            if terms.paymentAmount != repairedPayment {
                terms.paymentAmount = repairedPayment
                didUpdate = true
            }

            if terms.paymentDayOfMonth == nil {
                let day = Calendar(identifier: .gregorian).component(.day, from: latestBalance.asOfDate)
                terms.paymentDayOfMonth = min(max(day, 1), 28)
                didUpdate = true
            }
            account.loanTerms = terms
        }

        guard didUpdate else { return }

        do {
            try modelContext.save()
        } catch {
            AMLogging.error("Failed to repair existing sample liability terms: \(error.localizedDescription)", component: "QuickStartView")
        }
    }

    private func sampleAccount(id: UUID?, accountType: Account.AccountType, staged: StagedImport) -> Account? {
        let accounts = (try? modelContext.fetch(FetchDescriptor<Account>())) ?? []

        if let id, let account = accounts.first(where: { $0.id == id && $0.type == accountType }) {
            return account
        }

        let institution = staged.inferredInstitutionName
        return accounts
            .filter { account in
                account.type == accountType
                    && (account.dataSetRaw == "sample"
                        || SampleDataIdentity.isSampleInstitution(account.institutionName)
                        || SampleDataIdentity.isSampleInstitution(account.name)
                        || normalizedSampleText(account.institutionName ?? account.name) == normalizedSampleText(institution ?? ""))
            }
            .sorted { $0.createdAt > $1.createdAt }
            .first
    }

    private func preferredSampleLiabilityBalance(from staged: StagedImport) -> StagedBalance? {
        let includedBalances = staged.balances.filter(\.include)
        return includedBalances
            .filter { ($0.typicalPaymentAmount ?? 0) > 0 }
            .sorted { $0.asOfDate > $1.asOfDate }
            .first
            ?? includedBalances
                .sorted { $0.asOfDate > $1.asOfDate }
                .first
    }

    private func latestSampleSnapshot(for account: Account) -> BalanceSnapshot? {
        account.balanceSnapshots
            .filter { !$0.isExcluded }
            .sorted { $0.asOfDate > $1.asOfDate }
            .first
    }

    private func roundedCurrency(_ value: Decimal) -> Decimal {
        var value = value
        var result = Decimal()
        NSDecimalRound(&result, &value, 2, .plain)
        return result
    }

    private func fallbackSamplePayment(for balance: Decimal) -> Decimal {
        roundedCurrency(absDecimal(balance) * (Decimal(string: "0.025") ?? Decimal(0.025)))
    }

    private func normalizedSampleAPR(_ apr: Decimal) -> Decimal {
        apr > 1 ? apr / Decimal(100) : apr
    }

    private func sampleAmortizingPayment(
        for balance: Decimal,
        apr: Decimal?,
        proposedPayment: Decimal?
    ) -> Decimal {
        if let proposedPayment, proposedPayment > 0 {
            return proposedPayment
        }

        let absoluteBalance = absDecimal(balance)
        let proposed = fallbackSamplePayment(for: balance)
        let balanceFloor = roundedCurrency(absoluteBalance * (Decimal(string: "0.08") ?? Decimal(0.08)))

        let interestFloor: Decimal = {
            guard let apr, apr > 0 else { return .zero }
            let monthlyInterest = absoluteBalance * apr / Decimal(12)
            return roundedCurrency(monthlyInterest + Decimal(75))
        }()

        return max(proposed, balanceFloor, interestFloor)
    }

    private func absDecimal(_ value: Decimal) -> Decimal {
        value < 0 ? -value : value
    }

    private func normalizedSampleText(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined()
    }

    private func loadPersistedReviewStateIfNeeded() {
        guard !didLoadPersistedReviewState else { return }
        didLoadPersistedReviewState = true

        AMLogging.log(
            "QuickStartReview loadIfNeeded: begin bundle=\(Bundle.main.bundleIdentifier ?? "nil")",
            component: "Import"
        )

        guard let state = QuickStartReviewStorage.loadState() else {
            AMLogging.log(
                "QuickStartReview loadIfNeeded: no state",
                component: "Import"
            )
            return
        }

        let readableItems = state.items.compactMap { item in
            QuickStartReviewStorage.migratedItemIfReadable(item)
        }
        reviewItems = readableItems
        AMLogging.log(
            "QuickStartReview loadIfNeeded: restored readable=\(readableItems.count) original=\(state.items.count) selected=\(selectedReviewItemID?.uuidString ?? "nil")",
            component: "Import"
        )

        if let selectedItemID = state.selectedItemID,
           readableItems.contains(where: { $0.id == selectedItemID }) {
            self.selectedReviewItemID = selectedItemID
        } else {
            self.selectedReviewItemID = readableItems.first?.id
        }
    }

    private func persistReviewState() {
        guard didLoadPersistedReviewState else {
            AMLogging.log(
                "QuickStartReview persist: skipped before load items=\(reviewItems.count)",
                component: "Import"
            )
            return
        }
        let state = QuickStartReviewState(
            items: reviewItems,
            selectedItemID: selectedReviewItemID
        )
        AMLogging.log(
            "QuickStartReview persist: items=\(reviewItems.count) selected=\(selectedReviewItemID?.uuidString ?? "nil")",
            component: "Import"
        )
        QuickStartReviewStorage.saveState(state)
    }

    private static let importTypes: [UTType] = {
        var types: [UTType] = [.pdf, .commaSeparatedText, .tabSeparatedText, .text, .data]
        let exts = ["qfx", "ofx", "qbo", "qif", "xlsx", "xls", "csv", "tsv", "txt", "zip"]
        types.append(contentsOf: exts.compactMap { UTType(filenameExtension: $0) })
        return types
    }()

    private func beginImportProgress() {
        let id = UUID()
        importProgressID = id
        showImportProgress = false
        importIsTakingLonger = false

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            guard importProgressID == id else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                showImportProgress = true
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 7) {
            guard importProgressID == id else { return }
            importIsTakingLonger = true
        }
    }

    private func endImportProgress() {
        importProgressID = nil
        importIsTakingLonger = false
        withAnimation(.easeInOut(duration: 0.2)) {
            showImportProgress = false
        }
    }

    private func deliverPendingImport(
        url: URL,
        type: StatementType?,
        institution: String?,
        to topic: QuickStartTopic
    ) {
        AMLogging.log(
            "QuickStart deliverPendingImport start topic=\(topic.rawValue) compact=\(isCompactLayout)",
            component: "Import"
        )

        quickStartPending = nil
        endImportProgress()

        if isCompactLayout {
            if compactPath.last != topic {
                compactPath.append(topic)
            }
        } else {
            selection = topic
        }

        DispatchQueue.main.async {
            if topic == .statementReview {
                appendStatementForReview(url: url, type: type, institution: institution)
                return
            }

            let pending = QuickStartPendingImport(
                url: url,
                type: type,
                institution: institution
            )
            self.quickStartPending = pending

            AMLogging.log(
                "QuickStart pending set id=\(self.quickStartPending?.id.uuidString ?? "nil") topic=\(topic.rawValue) selection=\(String(describing: self.selection))",
                component: "Import"
            )

            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                guard self.quickStartPending?.id == pending.id else { return }
                AMLogging.error(
                    "QuickStart pending import was not consumed id=\(pending.id) file=\(pending.url.lastPathComponent)",
                    component: "Import"
                )
                self.importReadyWarningMessage = "We couldn't open the import review. Please try again."
                self.quickStartPending = nil
            }
        }
    }

    private func queueImport(url: URL, type: StatementType?, institution: String?) {
        AMLogging.log(
            "QuickStart queueImport start file=\(url.lastPathComponent) type=\(String(describing: type)) readable=\(FileManager.default.isReadableFile(atPath: url.path))",
            component: "Import"
        )
        beginImportProgress()
        Task {
            let resolved = await StatementIntakeResolver.resolve(
                url: url,
                providedType: type,
                providedInstitution: institution,
                source: "QuickStart.queueImport"
            )

            await MainActor.run {
                let resolvedType = resolved.detection.type
                let topic = topicFor(statementType: resolvedType) ?? .statementReview
                AMLogging.log(
                    "QuickStart deliver topic=\(topic.rawValue) resolvedType=\(String(describing: resolvedType)) classifierType=\(String(describing: resolved.classifierDetection.type)) fallbackType=\(String(describing: resolved.fallbackType))",
                    component: "Import"
                )
                deliverPendingImport(
                    url: resolved.stagedURL,
                    type: resolvedType,
                    institution: resolved.detection.institution,
                    to: topic
                )
            }
        }
    }

    private func queueImportAfterImporterDismissal(url: URL, type: StatementType?, institution: String?) {
        let stagedURL = ImportFileStaging.stageToCaches(url)
        AMLogging.log(
            "QuickStart staged before importer dismissal file=\(stagedURL.lastPathComponent) path=\(stagedURL.path) readable=\(FileManager.default.isReadableFile(atPath: stagedURL.path))",
            component: "Import"
        )
        showImporter = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            queueImport(url: stagedURL, type: type, institution: institution)
        }
    }

    private func routeStagedImportsThroughUserMode(_ urls: [URL]) {
        let requests = urls.map { url in
            let stagedURL = ImportFileStaging.stageToCaches(url)
            AMLogging.log(
                "QuickStart staged user-mode import file=\(stagedURL.lastPathComponent) path=\(stagedURL.path) readable=\(FileManager.default.isReadableFile(atPath: stagedURL.path))",
                component: "Import"
            )
            return ImportOpenRouter.QuickStartImportRequest(
                url: stagedURL,
                type: nil,
                institution: nil
            )
        }

        guard !requests.isEmpty else { return }

        showImporter = false
        if dataModeController.mode == .sample {
            dataModeController.switchTo(.user)
        }

        for (index, request) in requests.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35 + (Double(index) * 0.35)) {
                importRouter.quickStartPendingImport = request
            }
        }
    }

    private func loadSampleData(autoNavigate: Bool = false) {
        guard dataModeController.mode == .sample else {
            dataModeController.switchTo(.sample)
            return
        }
        guard isUsingActiveModelContext else {
            AMLogging.log(
                "QuickStart deferred sample data load until sample mode context is active",
                component: "Import"
            )
            return
        }

        guard !isLoadingSampleStatements else { return }

        let sampleResources = SampleStatementResource.availableResources
        isLoadingSampleStatements = true
        beginImportProgress()
        seedSampleCashFlowItemsIfNeeded()
        configureSamplePayoffBudgetDefaults()
        removeStagedSampleStatementsFromReview()
        resetImportedSampleStatements()

        guard !sampleResources.isEmpty else {
            isLoadingSampleStatements = false
            endImportProgress()
            if autoNavigate {
                routeToTopic(.incomeBills)
            }
            importReadyWarningMessage = "Sample statements are not available in this build. Sample income and bills were added."
            return
        }

        Task {
            let sampleVM = ImportViewModel(parsers: ImportViewModel.defaultParsers())
            let sampleCoordinator = StatementImportCoordinator(vm: sampleVM)

            for (resource, url) in sampleResources {
                let fileName = url.lastPathComponent
                sampleVM.selectedAccountID = nil
                sampleVM.newAccountType = resource.accountType

                let resolved = await StatementIntakeResolver.resolve(
                    url: url,
                    providedType: resource.statementType,
                    providedInstitution: nil,
                    source: "QuickStart.loadSampleData"
                )

                let statementType = resolved.detection.type ?? resource.statementType

                await sampleCoordinator.importURL(
                    resolved.stagedURL,
                    hint: statementType,
                    modelContext: modelContext,
                    settings: settings
                )

                guard var staged = sampleVM.staged else {
                    AMLogging.error("Sample statement produced no staged import for \(fileName)", component: "QuickStartView")
                    continue
                }

                staged.parserId = "sample.\(staged.parserId)"
                sampleVM.staged = staged
                sampleVM.userInstitutionName = resolved.detection.institution ?? staged.inferredInstitutionName ?? ""

                do {
                    try sampleVM.approveAndSave(context: modelContext)
                    repairSampleLiabilityTerms(
                        accountID: sampleVM.selectedAccountID,
                        staged: staged,
                        resource: resource
                    )
                } catch {
                    AMLogging.error("Failed to save sample statement \(fileName): \(error.localizedDescription)", component: "QuickStartView")
                }
                sampleVM.selectedAccountID = nil
                sampleVM.staged = nil
                sampleVM.mappingSession = nil
            }

            await MainActor.run {
                repairExistingSampleLiabilityTerms()
                markCurrentSampleDataLoaded()
                isLoadingSampleStatements = false
                endImportProgress()
                if autoNavigate {
                    routeToTopic(.compareStrategies)
                }
            }
        }
    }

    private func loadSampleDataIfVersionChanged() {
        guard dataModeController.mode == .sample else { return }
        guard !isLoadingSampleStatements else { return }
        let loadedVersion = UserDefaults.standard.string(forKey: SampleDataIdentity.dataVersionDefaultsKey)
        let isVersionStale = loadedVersion != SampleDataIdentity.currentDataVersion
        if isVersionStale || !hasImportedData {
            loadSampleData(autoNavigate: false)
        }
    }

    private func markCurrentSampleDataLoaded() {
        UserDefaults.standard.set(SampleDataIdentity.currentDataVersion, forKey: SampleDataIdentity.dataVersionDefaultsKey)
    }

    private var isCompactLayout: Bool {
        horizontalSizeClass == .compact
    }

    private func compactNavigationTitle(for topic: QuickStartTopic) -> String {
        switch topic {
        case .cashFlow, .debtPayoff:
            return ""
        default:
            return topic.title
        }
    }

    @ViewBuilder
    private var utilitySection: some View {
        Section("Utility") {
            Button {
                showBackupRestore = true
            } label: {
                Label("Backup & Restore", systemImage: "externaldrive")
            }

            Button {
                showSettings = true
            } label: {
                Label("Settings", systemImage: "gearshape")
            }

            Button {
                showHelp = true
            } label: {
                Label("Help", systemImage: "questionmark.circle")
            }

#if DEBUG
            if settings.showDebugTools {
                Button {
                    showDebug = true
                } label: {
                    Label("Debug", systemImage: "ladybug")
                }
            }
#endif
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        Group {
            if let selection {
                let _ = AMLogging.log(
                    "QuickStart detailContent showing \(selection.rawValue)",
                    component: "Import"
                )

                topicContent(selection, compact: false)
            } else {
                VStack {
                    Text("Select a section")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background)
            }
        }
    }

    private func routeToIncomeBills(compact: Bool) {
        planSheetMode = .incomeBills
        if compact {
            if compactPath.last != .incomeBills {
                compactPath.append(.incomeBills)
            }
        } else {
            selection = .incomeBills
        }
    }

    @ViewBuilder
    private func topicContent(_ topic: QuickStartTopic, compact: Bool) -> some View {
        switch topic {
        case .debtPayoff:
            DebtPayoffDetailView(
                vm: vm,
                coordinator: coordinator,
                externalSelectedAccountID: $debtPayoffSelectedAccountID,
                onRouteImport: routeImportedAccount,
                importAction: { showImporter = true },
                pendingExternal: $quickStartPending
            )
        case .debtPayoffPlan:
            DebtPayoffPlanView {
                if compact {
                    compactPath.append(.debtPayoff)
                } else {
                    selection = .debtPayoff
                }
            }
        case .compareStrategies:
            DebtSummaryView(
                embeddedInNavigation: true,
                onManageIncomeBills: {
                    routeToIncomeBills(compact: compact)
                },
                importAction: { showImporter = true }
            )
        case .netWorth:
            NetWorthView(embeddedInNavigation: compact)
        case .cashFlow:
            CashFlowDetailView(
                vm: vm,
                coordinator: coordinator,
                externalSelectedAccountID: $cashFlowSelectedAccountID,
                onRouteImport: routeImportedAccount,
                importAction: { showImporter = true },
                pendingExternal: $quickStartPending
            )
        case .statementReview:
            StatementReviewDetailView(
                vm: vm,
                coordinator: coordinator,
                pendingExternal: $quickStartPending,
                reviewItems: $reviewItems,
                selectedReviewItemID: $selectedReviewItemID
            )
        case .incomeBills:
            QuickStartIncomeBillsDetailView(planSheetMode: $planSheetMode)
        case .assets:
            QuickStartAssetsDetailView()
        case .assistant:
            DebtScopeAssistantView(embeddedInNavigation: true)
                .environmentObject(settings)
        }
    }
    
    private struct TimelineStepRow: View {
        let step: Int
        let text: String
        let isLast: Bool
        
        var body: some View {
            HStack(alignment: .center, spacing: 16) {
                VStack(spacing: 0) {
                    Text("\(step)")
                        .font(.caption2.weight(.bold))
                        .foregroundColor(.white)
                        .frame(width: 24, height: 24)
                        .background(Color.blue)
                        .clipShape(Circle())
                        
                    if !isLast {
                        Rectangle()
                            .fill(Color(uiColor: .separator).opacity(0.5))
                            .frame(width: 1, height: 24)
                    }
                }
                
                Text(text)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.bottom, isLast ? 0 : 24)
            }
        }
    }

    private struct HowDebtScopeWorksCard: View {
        var body: some View {
            VStack(spacing: 20) {
                Text("How DebtScope Works")
                    .font(.title3.weight(.bold))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, 4)

                VStack(alignment: .leading, spacing: 0) {
                    TimelineStepRow(step: 1, text: "Import a statement", isLast: false)
                    TimelineStepRow(step: 2, text: "Review account details", isLast: false)
                    TimelineStepRow(step: 3, text: "See payoff, cash flow,\nand net worth update", isLast: true)
                }
            }
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(uiColor: .systemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color(uiColor: .separator).opacity(0.5), lineWidth: 1)
            )
        }
    }

    private var hasImportedData: Bool {
        !accounts.isEmpty || !reviewItems.isEmpty
    }

    private var shouldShowFirstLookIntro: Bool {
        !hasImportedData
    }

    private var firstLookIntro: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Build your debt and cash-flow picture")
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)
                Text("Import a credit card, loan, bank, or brokerage statement. DebtScope reads it locally, creates accounts, and helps you track payoff, cash flow, and net worth.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity)

            HowDebtScopeWorksCard()

            VStack(spacing: 12) {
                Button {
                    showImporter = true
                } label: {
                    Text("Import Statement")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.blue)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                
                Button {
                    showHelp = true
                } label: {
                    Text("Watch How to Import")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                
                Button {
                    UserDefaults.standard.set(true, forKey: "pendingSampleDataAutoNavigate")
                    dataModeController.switchTo(.sample)
                } label: {
                    Text(isLoadingSampleStatements ? "Loading Samples" : "See Sample Data")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .controlSize(.large)
                .disabled(isLoadingSampleStatements)
            }
            .padding(.top, 4)
        }
        .padding(.bottom, 20)
    }

    @ToolbarContentBuilder
    private var importToolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            PlanToolbarButton("Import", fixedWidth: 75) { showImporter = true }
        }

        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showAccountSearch = true
            } label: {
                Label("Search Accounts", systemImage: "magnifyingglass")
            }
        }
    }



    private var importProgressOverlay: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(importIsTakingLonger ? "Still preparing import..." : "Preparing import...")
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(importIsTakingLonger ? "Still preparing import" : "Preparing import")
    }

    @ViewBuilder
    private var importStatusOverlay: some View {
        if showImportProgress {
            importProgressOverlay
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    var body: some View {
        Group {
            if isCompactLayout {
                compactQuickStartLayout
            } else {
                regularQuickStartLayout
            }
        }
        .sheet(isPresented: $showAccountSearch) {
            AccountSearchView()
        }
        .sheet(item: $routedAccountDetail) { route in
            NavigationStack {
                AccountDetailView(accountID: route.accountID, initialFocus: route.focus)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { routedAccountDetail = nil }
                        }
                    }
            }
            .environment(\.modelContext, modelContext)
            .environmentObject(settings)
            .applySheetSizing()
        }
        .sheet(isPresented: $showAbout) {
            AboutView()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView(source: paywallSource)
                .environmentObject(PurchaseManager.shared)
        }
        .sheet(isPresented: $showBackupRestore) {
            BackupRestoreView()
                .environmentObject(settings)
        }
        .fullScreenCover(isPresented: $showHelp) {
            NavigationStack { HelpVideosView() }
                .ignoresSafeArea()
        }
#if DEBUG
        .sheet(isPresented: $showDebug) {
            DebugSettingsView()
        }
#endif
        .alert("Import Not Opened", isPresented: Binding(get: { importReadyWarningMessage != nil }, set: { if !$0 { importReadyWarningMessage = nil } })) {
            Button("OK", role: .cancel) { importReadyWarningMessage = nil }
        } message: {
            Text(importReadyWarningMessage ?? "We couldn't open the import review. Please try again.")
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: Self.importTypes, allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                AMLogging.log(
                    "QuickStart fileImporter success urls=\(urls.map(\.lastPathComponent))",
                    component: "Import"
                )

                if let firstURL = urls.first {
                    if dataModeController.mode == .sample {
                        routeStagedImportsThroughUserMode([firstURL])
                    } else {
                        queueImportAfterImporterDismissal(url: firstURL, type: nil, institution: nil)
                    }
                }

            case .failure(let error):
                endImportProgress()
                AMLogging.error(
                    "QuickStart fileImporter failed error=\(error.localizedDescription)",
                    component: "Import"
                )
            }
        }
        .onChange(of: importRouter.quickStartPendingImport?.id, initial: true) { _, _ in
            guard let request = importRouter.quickStartPendingImport else { return }
            guard dataModeController.mode == .user, isUsingActiveModelContext else {
                dataModeController.switchTo(.user)
                AMLogging.log(
                    "QuickStart deferred pending import until user mode context is active",
                    component: "Import"
                )
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                queueImport(
                    url: request.url,
                    type: request.type,
                    institution: request.institution
                )
                importRouter.quickStartPendingImport = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: DebtScopeAppSectionRequestStore.notificationName)) { notification in
            guard let route = DebtScopeAppSectionRequestStore.route(from: notification) else { return }
            routeToAppSection(route.section, accountID: route.accountID, focus: route.focus)
        }
        .onContinueUserActivity(CSSearchableItemActionType) { userActivity in
            routeSpotlightActivity(userActivity)
        }
        .onAppear {
            loadPersistedReviewStateIfNeeded()
            let shouldNavigate = UserDefaults.standard.bool(forKey: "pendingSampleDataAutoNavigate")
            if shouldNavigate {
                UserDefaults.standard.set(false, forKey: "pendingSampleDataAutoNavigate")
                loadSampleData(autoNavigate: true)
            } else {
                loadSampleDataIfVersionChanged()
            }
            if let pendingRoute = DebtScopeAppSectionRequestStore.consumePendingRoute() {
                routeToAppSection(pendingRoute.section, accountID: pendingRoute.accountID, focus: pendingRoute.focus)
            }
        }
        .task(id: spotlightIndexFingerprint) {
            refreshSpotlightIndexWithAccounts()
        }
        .onChange(of: reviewItems) { _, _ in
            persistReviewState()
            if reviewItems.isEmpty {
                if selection == .statementReview {
                    selection = .debtPayoff
                }
                compactPath.removeAll { $0 == .statementReview }
            }
        }
        .onChange(of: selectedReviewItemID) { _, _ in
            persistReviewState()
        }
        .onChange(of: settings.assistantEnabled) { _, isEnabled in
            guard !isEnabled else { return }
            if selection == .assistant {
                selection = .debtPayoff
            }
            compactPath.removeAll { $0 == .assistant }
        }
        .onChange(of: settings.spotlightIndexingOptions) { _, _ in
            refreshSpotlightIndexWithAccounts()
        }
        .onReceive(NotificationCenter.default.publisher(for: .accountsDidChange)) { _ in
            refreshSpotlightIndexWithAccounts()
        }
        .onReceive(NotificationCenter.default.publisher(for: .transactionsDidChange)) { _ in
            refreshSpotlightIndexWithAccounts()
        }
    }

    private var compactQuickStartLayout: some View {
        NavigationStack(path: $compactPath) {
            ScrollView {
                VStack(spacing: 12) {
                    sampleDataModeBanner

                    if shouldShowFirstLookIntro {
                        firstLookIntro
                            .padding(.horizontal, 10)
                        
                        Text("After import, DebtScope routes you to review or the right section automatically.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .multilineTextAlignment(.center)
                            .padding(.top, 4)
                            .padding(.bottom, -4)
                            .padding(.horizontal, 14)
                    }

                    quickStartGroupedTopicCard { topic in
                        selection = topic
                        compactPath.append(topic)
                    }

                    quickStartSidebarCard(
                        title: "Utility",
                        items: utilityItems.map { ($0.title, $0.systemImage, false) },
                        action: { tappedTitle in
                            handleUtilityTap(title: tappedTitle)
                        }
                    )

                    TrialBanner(horizontalPadding: 0, textLineLimit: 1) {
                        paywallSource = .fifthImport
                        showPaywall = true
                    }
                    .padding(.horizontal, 8)
                }
                .padding(10)
            }
            .navigationTitle("DebtScope")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { importToolbarContent }
            .overlay(alignment: .bottom) {
                importStatusOverlay
            }
            .navigationDestination(for: QuickStartTopic.self) { topic in
                VStack(spacing: 0) {
                    sampleDataModeBanner
                    topicContent(topic, compact: true)
                }
                    .onAppear {
                        selection = topic
                    }
                    .navigationTitle(compactNavigationTitle(for: topic))
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    private var regularQuickStartLayout: some View {
        NavigationSplitView {
            ScrollView {
                VStack(spacing: 12) {
                    sampleDataModeBanner

                    if shouldShowFirstLookIntro {
                        firstLookIntro
                            .padding(.horizontal, 12)

                        Text("After import, DebtScope routes you to review or the right section automatically.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .multilineTextAlignment(.center)
                            .padding(.top, 4)
                            .padding(.bottom, -4)
                            .padding(.horizontal, 14)
                    }

                    quickStartGroupedTopicCard { topic in
                        selection = topic
                    }

                    quickStartSidebarCard(
                        title: "Utility",
                        items: utilityItems.map { ($0.title, $0.systemImage, false) },
                        action: { tappedTitle in
                            handleUtilityTap(title: tappedTitle)
                        }
                    )

                    TrialBanner(horizontalPadding: 0, textLineLimit: 1) {
                        paywallSource = .fifthImport
                        showPaywall = true
                    }
                    .padding(.horizontal, 12)
                }
                .padding(10)
            }
            .navigationTitle("DebtScope")
            .toolbar { importToolbarContent }
        } detail: {
            VStack(spacing: 0) {
                sampleDataModeBanner
                detailContent
                    .padding(.horizontal, 10)
            }
                .overlay(alignment: .bottom) {
                    importStatusOverlay
                }
                .navigationTitle(selection == .assets ? "" : (selection?.title ?? "DebtScope"))
                .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private var sampleDataModeBanner: some View {
        if dataModeController.mode == .sample {
            HStack(spacing: 10) {
                Label(hasImportedData ? "Viewing Sample Data" : "No Sample Data Loaded", systemImage: "doc.on.doc")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                if hasImportedData {
                    Button("Use My Data") {
                        dataModeController.switchTo(.user)
                    }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.10), radius: 10, y: 3)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.top, -8)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Viewing Sample Data. Use My Data.")
        }
    }

    private var utilityItems: [(title: String, systemImage: String)] {
        var items: [(title: String, systemImage: String)] = [
            (title: "Backup & Restore", systemImage: "externaldrive"),
            (title: "Settings", systemImage: "gearshape")
        ]
        items.append(contentsOf: [
            (title: "Help", systemImage: "questionmark.circle"),
            (title: "About", systemImage: "info.circle")
        ])
#if DEBUG
        if settings.showDebugTools {
            items.append((title: "Debug", systemImage: "ladybug"))
        }
#endif
        return items
    }

    private func handleUtilityTap(title: String) {
        switch title {
        case "Backup & Restore":
            showBackupRestore = true
        case "Settings":
            showSettings = true
        case "Help":
            showHelp = true
        case "About":
            showAbout = true
        case "Debug":
            showDebug = true
        default:
            break
        }
    }

    private func quickStartGroupedTopicCard(action: @escaping (QuickStartTopic) -> Void) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(topicGroups.enumerated()), id: \.offset) { groupIndex, group in
                if groupIndex > 0 {
                    Divider()
                        .padding(.leading, 16)
                }

                Text(group.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.top, groupIndex == 0 ? 6 : 8)
                    .padding(.bottom, 2)

                ForEach(Array(group.topics.enumerated()), id: \.element.id) { topicIndex, topic in
                    Button {
                        action(topic)
                    } label: {
                        HStack(spacing: 12) {
                            Text(topic.title)
                                .foregroundStyle(.primary)
                                .padding(.leading, 12)
                            Spacer()
                            if topic == .statementReview, !reviewItems.isEmpty {
                                Text("\(reviewItems.count)")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.white)
                                    .monospacedDigit()
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(Color.accentColor))
                                    .accessibilityLabel("\(reviewItems.count) statements need review")
                            }
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(topic == selection ? Color.accentColor.opacity(0.12) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(
                                    topic == selection ? Color.accentColor : Color.clear,
                                    lineWidth: topic == selection ? 2 : 0
                                )
                        )
                    }
                    .buttonStyle(.plain)

                    if topicIndex < group.topics.count - 1 {
                        Divider()
                            .padding(.leading, 16)
                    }
                }
            }
        }
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.background)
        )
        .padding(.horizontal, 8)
    }

    private func quickStartSidebarCard(
        title: String?,
        items: [(title: String, systemImage: String?, isSelected: Bool)],
        action: @escaping (String) -> Void
    ) -> some View {
        VStack(spacing: 0) {
            if let title, !title.isEmpty {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
                    .padding(.bottom, 2)
            }

            ForEach(Array(items.enumerated()), id: \.element.title) { index, item in
                Button {
                    action(item.title)
                } label: {
                    HStack(spacing: 12) {
                        if let systemImage = item.systemImage {
                            Image(systemName: systemImage)
                                .foregroundStyle(.blue)
                                .frame(width: 20)
                        }
                        Text(item.title)
                            .foregroundStyle(.primary)
                        Spacer()
                        if item.systemImage == nil {
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(item.isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(
                                item.isSelected ? Color.accentColor : Color.clear,
                                lineWidth: item.isSelected ? 2 : 0
                            )
                    )
                }
                .buttonStyle(.plain)

                if index < items.count - 1 {
                    Divider()
                        .padding(.leading, item.systemImage == nil ? 16 : 48)
                }
            }
        }
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.background)
        )
        .padding(.horizontal, 8)
    }
}

private struct QuickStartIncomeBillsDetailView: View {
    @Binding var planSheetMode: QuickStartView.PlanSheetMode
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var isCompactLayout: Bool {
        horizontalSizeClass == .compact
    }

    var body: some View {
        Group {
            if isCompactLayout {
                IncomeAndBillsView(embeddedInNavigation: true)
            } else {
                VStack(spacing: 0) {
                    Picker("Plan Mode", selection: $planSheetMode) {
                        Text("Income & Bills").tag(QuickStartView.PlanSheetMode.incomeBills)
                        Text("Summary").tag(QuickStartView.PlanSheetMode.summary)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .padding(.bottom, 12)

                    Group {
                        switch planSheetMode {
                        case .incomeBills:
                            IncomeAndBillsView()
                        case .summary:
                            QuickStartIncomeBillsSummaryView()
                        }
                    }
                }
            }
        }
    }
}

private struct QuickStartIncomeBillsSummaryView: View {
    @Query(sort: \CashFlowItem.createdAt, order: .reverse) private var items: [CashFlowItem]

    var body: some View {
        List {
            IncomeBillsSummarySections(items: items)
        }
        .listStyle(.insetGrouped)
    }
}

private struct QuickStartAssetsDetailView: View {
    @Query(sort: [SortDescriptor(\Account.name, order: .forward)]) private var accounts: [Account]
    @Query(filter: #Predicate<Account> { $0.typeRaw == "loan" }, sort: [SortDescriptor(\Account.name, order: .forward)]) private var loanAccounts: [Account]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject private var settings: SettingsStore

    @State private var selectedAssetPersistentID: PersistentIdentifier? = nil
    @State private var showAddAssetSheet = false
    @State private var assetBalanceDraft: String = ""
    @State private var assetBalanceDraftAccountID: UUID? = nil
    @State private var assetBalanceDraftField: AssetEditField? = nil
    @FocusState private var focusedAssetField: AssetEditField?

    private enum AssetEditField: Hashable {
        case name
        case description
        case value
        case balance
    }

    private let assetEditFieldOrder: [AssetEditField] = [.name, .description, .value, .balance]

    private var assetAccounts: [Account] {
        accounts.filter(\.isManualAsset)
    }

    private var selectedAsset: Account? {
        guard let selectedAssetPersistentID else { return nil }
        return assetAccounts.first(where: { $0.persistentModelID == selectedAssetPersistentID })
    }

    private var isCompactLayout: Bool {
        horizontalSizeClass == .compact
    }

    var body: some View {
        Group {
            if isCompactLayout {
                compactBody
            } else {
                regularBody
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                PlanToolbarButton("+ Asset", titleFont: .caption, fixedWidth: 78) {
                    showAddAssetSheet = true
                }
            }

            ToolbarItemGroup(placement: .keyboard) {
                if focusedAssetField != nil {
                    Button {
                        focusPreviousAssetField()
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .disabled(isFirstAssetEditFieldFocused)

                    Button {
                        focusNextAssetField()
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .disabled(isLastAssetEditFieldFocused)

                    Spacer()

                    Button {
                        focusedAssetField = nil
                    } label: {
                        Image(systemName: "checkmark")
                    }
                }
            }
        }
        .sheet(isPresented: $showAddAssetSheet) {
            ManualAssetSheet()
        }
        .onAppear {
            if selectedAssetPersistentID == nil {
                selectedAssetPersistentID = assetAccounts.first?.persistentModelID
            }
        }
        .onChange(of: assetAccounts.map(\.persistentModelID), initial: false) { _, ids in
            if !ids.contains(where: { $0 == selectedAssetPersistentID }) {
                selectedAssetPersistentID = ids.first
            }
        }
        .onChange(of: focusedAssetField) { _, newValue in
            guard let newValue else { return }
            if (newValue == .value || newValue == .balance), let selectedAsset {
                prepareAssetBalanceDraft(for: selectedAsset, field: newValue)
            }
            selectFocusedAssetText()
        }
        .task(id: assetAccounts.map(\.persistentModelID)) {
            if selectedAssetPersistentID == nil {
                selectedAssetPersistentID = assetAccounts.first?.persistentModelID
            }
        }
    }

    private var compactBody: some View {
        Group {
            if assetAccounts.isEmpty {
                ContentUnavailableView {
                    Label("No Assets Yet", systemImage: "building.columns")
                } description: {
                    Text("Add a property or other tracked asset to see it here.")
                } actions: {
                    Button("Add Asset") {
                        showAddAssetSheet = true
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 14) {
                        ForEach(assetAccounts, id: \.persistentModelID) { account in
                            let persistentID = account.persistentModelID
                            NavigationLink {
                                QuickStartAccountDetailByPersistentID(persistentID: persistentID)
                                    .navigationBarTitleDisplayMode(.inline)
                            } label: {
                                assetCard(for: account, isSelected: false)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .background(.quaternary.opacity(0.05))
    }

    private var regularBody: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                Text("Assets")
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 16)
                    .padding(.bottom, 12)

                Group {
                    if assetAccounts.isEmpty {
                        ContentUnavailableView {
                            Label("No Assets Yet", systemImage: "building.columns")
                        } description: {
                            Text("Add a property or other tracked asset to see it here.")
                        } actions: {
                            Button("Add Asset") {
                                showAddAssetSheet = true
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            VStack(spacing: 14) {
                                ForEach(assetAccounts, id: \.persistentModelID) { account in
                                    let persistentID = account.persistentModelID
                                    Button {
                                        selectedAssetPersistentID = persistentID
                                    } label: {
                                        assetCard(for: account, isSelected: selectedAssetPersistentID == persistentID)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 16)
                        }
                    }
                }
            }
            .frame(minWidth: 280, maxWidth: 360)
            .background(.quaternary.opacity(0.05))

            Divider()

            Group {
                if let asset = selectedAsset {
                    assetDetailContent(for: asset, title: "Details")
                } else if assetAccounts.isEmpty {
                    ContentUnavailableView {
                        Label("No Assets Yet", systemImage: "building.columns")
                    } description: {
                        Text("Add a property or other tracked asset to see it here.")
                    } actions: {
                        Button("Add Asset") {
                            showAddAssetSheet = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    ContentUnavailableView("Select an asset", systemImage: "building.columns")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.quaternary.opacity(0.05))
        }
    }

    private func assetCard(for account: Account, isSelected: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(account.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(account.assetCategory.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(format(amount: latestBalance(for: account) ?? .zero))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if let asOf = latestSnapshot(for: account)?.asOfDate {
                    Text(asOf.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(
                    isSelected ? Color.accentColor : Color(uiColor: .quaternaryLabel),
                    lineWidth: isSelected ? 2 : 1
                )
        )
    }

    private func assetDetailContent(for asset: Account, title: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(title)
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity, alignment: .center)

                VStack(alignment: .leading, spacing: 8) {
                    Text(asset.name)
                        .font(.largeTitle.bold())
                    if let institution = asset.institutionName, !institution.isEmpty {
                        Text(institution)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                }

                detailSection("Details") {
                    editableTextRow(
                        "Name",
                        text: binding(for: asset, keyPath: \.name),
                        field: .name
                    )
                    editableTextRow(
                        "Description",
                        text: Binding(
                            get: { asset.institutionName ?? "" },
                            set: { newValue in
                                asset.institutionName = normalizedOptionalText(newValue)
                                saveModelContext()
                            }
                        ),
                        placeholder: "Description (optional)",
                        field: .description
                    )
                    categoryPickerRow(for: asset)
                }

                detailSection("Balance Info") {
                    editableTextRow(
                        "Value",
                        text: balanceTextBinding(for: asset, field: .value),
                        placeholder: "0.00",
                        keyboardType: .numbersAndPunctuation,
                        field: .value
                    )
//                    if let snapshot = latestSnapshot(for: asset) {
//                        editableTextRow(
//                            "Balance",
//                            text: balanceTextBinding(for: asset, field: .balance),
//                            placeholder: "0.00",
//                            keyboardType: .decimalPad,
//                            field: .balance
//                        )
//                        detailRow(
//                            "As Of",
//                            value: snapshot.asOfDate.formatted(date: .abbreviated, time: .omitted)
//                        )
//                    } else {
//                        editableTextRow(
//                            "Balance",
//                            text: balanceTextBinding(for: asset, field: .balance),
//                            placeholder: "0.00",
//                            keyboardType: .decimalPad,
//                            field: .balance
//                        )
//                    }
                }

                detailSection("Financing") {
                    loanPickerRow(for: asset)
                    if let loan = linkedLiability(for: asset) {
                        detailRow("Liability Balance", value: format(amount: liabilityMagnitude(for: loan)))
                        detailRow("Net Equity", value: format(amount: equity(for: asset, liability: loan)))
                        if asset.showsLoanToValue, let ltv = ltv(for: asset, liability: loan) {
                            detailRow("LTV", value: formatPercent(ltv))
                        }
                    } else {
                        Text("Link a liability to track net equity. LTV is shown for property and vehicle assets.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                detailSection("Status") {
                    detailRow("Linked Liability", value: linkedLiability(for: asset)?.name ?? "Unlinked")
                    detailRow("Asset Count", value: "\(assetAccounts.count)")
                }
            }
            .padding(24)
            .frame(maxWidth: 980, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private func assetMetaView(for account: Account) -> some View {
        let liability = linkedLiability(for: account)
        let assetBalance = latestBalance(for: account) ?? .zero
        let liabilityBalance = liability.flatMap { latestBalance(for: $0) } ?? .zero
        let debtMagnitude = liabilityBalance < .zero ? -liabilityBalance : liabilityBalance
        let equity = assetBalance - debtMagnitude

        VStack(alignment: .leading, spacing: 4) {
            if let liability {
                Text("Linked liability: \(liability.name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Net equity: \(format(amount: equity))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if account.showsLoanToValue, assetBalance > .zero {
                    Text("LTV: \(formatPercent(debtMagnitude / assetBalance))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let asOf = latestSnapshot(for: account)?.asOfDate {
                Text("As of \(asOf.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func latestSnapshot(for account: Account) -> BalanceSnapshot? {
        account.balanceSnapshots
            .filter { !$0.isExcluded }
            .sorted { $0.asOfDate > $1.asOfDate }
            .first
    }

    private func latestBalance(for account: Account) -> Decimal? {
        latestSnapshot(for: account)?.balance
    }

    private func binding(for account: Account, keyPath: ReferenceWritableKeyPath<Account, String>) -> Binding<String> {
        Binding(
            get: { account[keyPath: keyPath] },
            set: { newValue in
                account[keyPath: keyPath] = newValue
                saveModelContext()
            }
        )
    }

    private func balanceTextBinding(for account: Account, field: AssetEditField) -> Binding<String> {
        Binding(
            get: {
                if focusedAssetField == field,
                   assetBalanceDraftAccountID == account.id,
                   assetBalanceDraftField == field {
                    return assetBalanceDraft
                }
                guard let balance = latestBalance(for: account) else { return "" }
                return format(amount: balance)
            },
            set: { newValue in
                assetBalanceDraft = newValue
                assetBalanceDraftAccountID = account.id
                assetBalanceDraftField = field

                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let parsed = parseDecimalInput(trimmed) else {
                    if trimmed.isEmpty, let snapshot = latestSnapshot(for: account) {
                        snapshot.balance = .zero
                        snapshot.accountID = account.id
                        snapshot.isUserModified = true
                        saveModelContext()
                    }
                    return
                }

                if let snapshot = latestSnapshot(for: account) {
                    snapshot.balance = parsed
                    snapshot.accountID = account.id
                    snapshot.isUserModified = true
                } else {
                    let snapshot = BalanceSnapshot(
                        asOfDate: .now,
                        balance: parsed,
                        account: account,
                        isUserCreated: true,
                        isUserModified: true
                    )
                    modelContext.insert(snapshot)
                    account.balanceSnapshots.append(snapshot)
                }
                saveModelContext()
            }
        )
    }

    private func prepareAssetBalanceDraft(for account: Account, field: AssetEditField) {
        guard assetBalanceDraftAccountID != account.id || assetBalanceDraftField != field else { return }
        assetBalanceDraft = latestBalance(for: account).map { formatDecimalForInput($0) } ?? ""
        assetBalanceDraftAccountID = account.id
        assetBalanceDraftField = field
    }

    private func liabilityMagnitude(for liability: Account) -> Decimal {
        let balance = latestBalance(for: liability) ?? .zero
        return balance < .zero ? -balance : balance
    }

    private func equity(for asset: Account, liability: Account) -> Decimal {
        (latestBalance(for: asset) ?? .zero) - liabilityMagnitude(for: liability)
    }

    private func ltv(for asset: Account, liability: Account) -> Decimal? {
        let assetBalance = latestBalance(for: asset) ?? .zero
        guard assetBalance > .zero else { return nil }
        return liabilityMagnitude(for: liability) / assetBalance
    }

    private func detailSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                content()
            }
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.quaternary, lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detailRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundStyle(.primary)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.background)
    }

    private func categoryPickerRow(for asset: Account) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Bucket")
                .foregroundStyle(.primary)
            Spacer()
            Picker("Bucket", selection: assetCategoryBinding(for: asset)) {
                ForEach(Account.AssetCategory.allCases, id: \.self) { category in
                    Text(category.displayName).tag(category)
                }
            }
            .labelsHidden()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.background)
    }

    private func editableTextRow(
        _ label: String,
        text: Binding<String>,
        placeholder: String = "",
        keyboardType: UIKeyboardType = .default,
        field: AssetEditField
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundStyle(.primary)
            Spacer()
            TextField(placeholder, text: text)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.primary)
                .keyboardType(keyboardType)
                .textInputAutocapitalization(keyboardType == .default ? .words : .never)
                .autocorrectionDisabled()
                .focused($focusedAssetField, equals: field)
                .onTapGesture {
                    focusedAssetField = field
                    selectFocusedAssetText()
                }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.background)
    }

    private var focusedAssetFieldIndex: Int? {
        guard let focusedAssetField else { return nil }
        return assetEditFieldOrder.firstIndex(of: focusedAssetField)
    }

    private var isFirstAssetEditFieldFocused: Bool {
        focusedAssetFieldIndex == assetEditFieldOrder.startIndex
    }

    private var isLastAssetEditFieldFocused: Bool {
        focusedAssetFieldIndex == assetEditFieldOrder.index(before: assetEditFieldOrder.endIndex)
    }

    private func focusPreviousAssetField() {
        guard let index = focusedAssetFieldIndex, index > assetEditFieldOrder.startIndex else { return }
        focusedAssetField = assetEditFieldOrder[index - 1]
    }

    private func focusNextAssetField() {
        guard let index = focusedAssetFieldIndex, index < assetEditFieldOrder.index(before: assetEditFieldOrder.endIndex) else { return }
        focusedAssetField = assetEditFieldOrder[index + 1]
    }

    private func selectFocusedAssetText() {
        DispatchQueue.main.async {
            UIApplication.shared.sendAction(
                #selector(UIResponderStandardEditActions.selectAll(_:)),
                to: nil,
                from: nil,
                for: nil
            )
        }
    }

    private func assetCategoryBinding(for asset: Account) -> Binding<Account.AssetCategory> {
        Binding(
            get: { asset.assetCategory },
            set: { newValue in
                asset.assetCategory = newValue
                saveModelContext()
            }
        )
    }

    private func activeLink(for asset: Account) -> AssetLiabilityLink? {
        guard asset.supportsLinkedLiability else { return nil }
        let assetID = asset.id
        let predicate = #Predicate<AssetLiabilityLink> { link in
            link.assetID == assetID && link.endDate == nil
        }
        let descriptor = FetchDescriptor<AssetLiabilityLink>(predicate: predicate)
        return try? modelContext.fetch(descriptor).first
    }

    private func linkedLiability(for asset: Account) -> Account? {
        guard let liabilityID = activeLink(for: asset)?.liabilityID else { return nil }
        return loanAccounts.first { $0.id == liabilityID }
    }

    private func loanBinding(for asset: Account) -> Binding<UUID?> {
        Binding(
            get: { activeLink(for: asset)?.liabilityID },
            set: { newValue in
                updateLoanLink(for: asset, loanID: newValue)
            }
        )
    }

    private func updateLoanLink(for asset: Account, loanID: UUID?) {
        guard asset.supportsLinkedLiability else { return }

        if let existing = activeLink(for: asset) {
            if let loanID, let loan = loanAccounts.first(where: { $0.id == loanID }) {
                existing.liability = loan
                existing.liabilityID = loan.id
                existing.assetID = asset.id
                existing.endDate = nil
            } else {
                existing.endDate = Date.now
            }
        } else if let loanID, let loan = loanAccounts.first(where: { $0.id == loanID }) {
            let link = AssetLiabilityLink(asset: asset, liability: loan, startDate: .now, endDate: nil)
            modelContext.insert(link)
        }

        saveModelContext()
    }

    private func loanPickerRow(for asset: Account) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Linked Liability")
                .foregroundStyle(.primary)
            Spacer()
            Picker("Linked Liability", selection: loanBinding(for: asset)) {
                Text("None").tag(nil as UUID?)
                ForEach(loanAccounts.filter { $0.id != asset.id }, id: \.id) { loan in
                    Text(loan.name).tag(Optional(loan.id))
                }
            }
            .labelsHidden()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.background)
    }

    private func format(amount: Decimal) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = settings.currencyCode
        return nf.string(from: NSDecimalNumber(decimal: amount)) ?? "\(amount)"
    }

    private func formatPercent(_ value: Decimal) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .percent
        nf.maximumFractionDigits = 2
        return nf.string(from: NSDecimalNumber(decimal: value)) ?? "–"
    }

    private func formatDecimalForInput(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? "\(value)"
    }

    private func parseDecimalInput(_ value: String) -> Decimal? {
        guard !value.isEmpty else { return nil }
        let cleaned = value
            .replacingOccurrences(of: settings.currencyCode, with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
        return Decimal(string: cleaned)
    }

    private func normalizedOptionalText(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func saveModelContext() {
        do {
            try modelContext.save()
        } catch {
            AMLogging.log("QuickStartAssetsDetailView save failed: \(error)", component: "QuickStartView")
        }
    }
}

private struct StatementReviewDetailView: View {
    @ObservedObject var vm: ImportViewModel
    let coordinator: StatementImportCoordinator
    @Binding var pendingExternal: QuickStartPendingImport?
    @Binding var reviewItems: [QuickStartReviewItem]
    @Binding var selectedReviewItemID: UUID?
    @Query(sort: [SortDescriptor(\Account.name, order: .forward)]) private var accounts: [Account]
    
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var reviewURL: URL? = nil
    @State private var selectedType: StatementType? = nil
    @State private var editedInstitution = ""
    @State private var bankSubtype: QuickIngestAccountType? = nil
    @State private var monthlyPaymentInput = ""
    @State private var aprPercentInput = ""
    @State private var balanceInput = ""
    @State private var balanceDate = Date()
    @State private var saveMessage: String? = nil
    @State private var saveMessageIsError = false
    @State private var savedAccountID: UUID? = nil
    @State private var selectedExistingAccountID: UUID? = nil
    @State private var showPDFPreview = false
    @State private var showImportReviewSheet = false
    @State private var showTransactionPreview = false
    @State private var showDiscardConfirmation = false
    @State private var parsedReviewItemID: UUID? = nil
    
    private var isImportSheetPresented: Binding<Bool> {
        Binding(
            get: { showImportReviewSheet && (vm.staged != nil || vm.mappingSession != nil) },
            set: { presented in
                if !presented {
                    showImportReviewSheet = false

                    if let url = vm.lastPickedLocalURL {
                        reviewURL = url
                    }

                    vm.staged = nil
                    vm.mappingSession = nil
                }
            }
        )
    }

    private var isCompactLayout: Bool {
        horizontalSizeClass == .compact
    }

    private var unknownStatementForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            quickStartTypeBar

            ManualAccountFormPanel(
                selectedType: $selectedType,
                editedInstitution: $editedInstitution,
                bankSubtype: $bankSubtype,
                monthlyPaymentInput: $monthlyPaymentInput,
                aprPercentInput: $aprPercentInput,
                balanceInput: $balanceInput,
                balanceDate: $balanceDate,
                onSave: {
                    handleUnknownStatementSave()
                },
                hasSavedAccount: savedAccountID != nil,
                saveButtonTitle: unknownStatementSaveButtonTitle,
                savedButtonTitle: isTransactionImportFile ? "Import Ready" : "Account Added",
                showsSaveButton: !isTransactionImportFile,
                showsExistingAccountPicker: isTransactionImportFile,
                existingAccounts: existingAccountsForUnknownTransactionImport,
                selectedExistingAccountID: $selectedExistingAccountID
             )
        }
    }

    private var quickStartTypeBar: some View {
        HStack(spacing: 8) {
            ForEach(StatementType.allCases, id: \.self) { type in
                Button {
                    selectedType = type
                    if type != .bank {
                        bankSubtype = nil
                    }
                    updateSelectedReviewItem(type: type, institution: enteredInstitutionName)
                } label: {
                    Text(shortDisplayName(for: type))
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                }
                .buttonStyle(.plain)
                .foregroundStyle(selectedType == type ? .white : .primary)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(selectedType == type ? Color.accentColor : Color.secondary.opacity(0.12))
                )
                .accessibilityLabel("\(displayName(for: type)) statement")
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Review statements needing attention.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal)

            if !reviewItems.isEmpty {
                reviewSelectionBar
                    .padding(.horizontal)
            }
            
            if let saveMessage {
                Label(
                    saveMessage,
                    systemImage: saveMessageIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(saveMessageIsError ? .orange : .green)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
            }
            
            Group {
                if let url = reviewURL {
                    if isCompactLayout {
                        VStack(spacing: 12) {
                            unknownStatementForm
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .padding()
                            
                            Button {
                                if isTransactionImportFile {
                                    importUnknownTransactionFile()
                                } else {
                                    showPDFPreview = true
                                }
                            } label: {
                                Label(
                                    isTransactionImportFile ? "View Transactions" : "View PDF",
                                    systemImage: isTransactionImportFile ? "list.bullet.rectangle" : "doc.richtext"
                                )
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isTransactionImportFile && (selectedType == nil || enteredInstitutionName.isEmpty))
                            .padding(.horizontal)
                            .padding(.bottom)
                        }
                    } else {
                        HStack(spacing: 0) {
                            VStack {
                                unknownStatementForm
                                    .frame(minWidth: 320, maxWidth: 420, maxHeight: .infinity, alignment: .topLeading)
                                    .padding()
                            }
                            Divider()
                            
                            PDFPreview(url: url)
                                .id(url.path)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(.quaternary.opacity(0.05))
                                
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "No Statement",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text(reviewItems.isEmpty ? "Open a statement to review the PDF and import details here." : "Select a statement from the review list.")
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 32)
        .background(.background)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    showDiscardConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(reviewURL == nil)
                .accessibilityLabel("Discard Statement")
            }
        }
        .sheet(isPresented: isImportSheetPresented) {
            ImportSheetContentView(vm: vm)
                .environment(\.modelContext, modelContext)
        }
        .sheet(isPresented: $showTransactionPreview) {
            NavigationStack {
                Group {
                    if let staged = vm.staged {
                        StatementPreviewView(staged: staged)
                    } else {
                        ContentUnavailableView(
                            "No Transactions",
                            systemImage: "list.bullet.rectangle",
                            description: Text("No parsed transactions are available yet.")
                        )
                    }
                }
                .navigationTitle("Transactions")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") {
                            showTransactionPreview = false
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Approve") {
                            showTransactionPreview = false
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                showImportReviewSheet = true
                            }
                        }
                    }
                }
            }
            .applySheetSizing()
        }
        .sheet(isPresented: $showPDFPreview) {
            NavigationStack {
                Group {
                    if let url = reviewURL {
                        PDFPreview(url: url)
                            .id(url.path)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ContentUnavailableView("No Statement", systemImage: "doc.text.magnifyingglass")
                    }
                }
                .navigationTitle("Statement PDF")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            showPDFPreview = false
                        }
                    }
                }
            }
        }
        .confirmationDialog(
            "Discard this statement?",
            isPresented: $showDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("Discard Statement", role: .destructive) {
                discardSelectedReviewItem()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes the statement from Needs Review.")
        }
        .task(id: pendingExternal?.id) {
            guard let pending = pendingExternal else { return }

            AMLogging.log(
                "StatementReview task received file=\(pending.url.lastPathComponent) type=\(String(describing: pending.type))",
                component: "Import"
            )

            if pending.type == nil {
                await MainActor.run {
                    addOrSelectReviewItem(
                        url: pending.url,
                        type: pending.type,
                        institution: pending.institution
                    )
                    pendingExternal = nil
                }

                AMLogging.log(
                    "StatementReview task set reviewURL=\(pending.url.path)",
                    component: "Import"
                )

                return
            }

            await coordinator.importURL(
                pending.url,
                hint: pending.type,
                modelContext: modelContext,
                settings: settings
            )

            await MainActor.run {
                addOrSelectReviewItem(
                    url: pending.url,
                    type: pending.type,
                    institution: pending.institution
                )
                pendingExternal = nil
            }
        }
        .onChange(of: selectedReviewItemID, initial: true) { _, id in
            loadSelectedReviewItem(id)
        }
        .onChange(of: selectedExistingAccountID) { _, newValue in
            applySelectedExistingAccount(newValue)
        }
        .onChange(of: selectedType) { _, _ in
            clearSelectedExistingAccountIfNeeded()
        }
        .onChange(of: bankSubtype) { _, _ in
            clearSelectedExistingAccountIfNeeded()
        }
        .onChange(of: editedInstitution) { _, newValue in
            updateSelectedReviewItem(type: selectedType, institution: newValue)
        }
    }

    private var reviewSelectionBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(reviewItems) { item in
                    Button {
                        selectedReviewItemID = item.id
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                Image(systemName: selectedReviewItemID == item.id ? "doc.text.fill" : "doc.text")
                                    .foregroundStyle(selectedReviewItemID == item.id ? .white : .blue)
                                Text(item.url.deletingPathExtension().lastPathComponent)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                            }

                            Text(accountSummary(for: item))
                                .font(.caption2)
                                .foregroundStyle(selectedReviewItemID == item.id ? .white.opacity(0.85) : .secondary)
                                .lineLimit(1)

                            HStack(spacing: 5) {
                                ForEach(StatementType.allCases, id: \.self) { type in
                                    Text(shortDisplayName(for: type))
                                        .font(.caption2.weight(.bold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .foregroundStyle(item.type == type ? .white : .secondary)
                                        .background(
                                            Capsule()
                                                .fill(item.type == type ? Color.accentColor : Color.secondary.opacity(0.14))
                                        )
                                }
                            }
                        }
                        .frame(width: 220, alignment: .leading)
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(selectedReviewItemID == item.id ? Color.accentColor : Color.secondary.opacity(0.08))
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(item.url.lastPathComponent), \(accountSummary(for: item))")
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func addOrSelectReviewItem(url: URL, type: StatementType?, institution: String?) {
        if let index = reviewItems.firstIndex(where: { $0.url.path == url.path }) {
            reviewItems[index].type = type ?? reviewItems[index].type
            reviewItems[index].institution = institution ?? reviewItems[index].institution
            selectedReviewItemID = reviewItems[index].id
        } else {
            let id = UUID()
            let durableURL = QuickStartReviewStorage.stageForReview(url, id: id)
            let item = QuickStartReviewItem(
                id: id,
                url: durableURL,
                type: type,
                institution: institution,
                managedFileName: QuickStartReviewStorage.managedFileName(for: durableURL)
            )
            reviewItems.append(item)
            selectedReviewItemID = item.id
        }

        loadSelectedReviewItem(selectedReviewItemID)
    }

    private func loadSelectedReviewItem(_ id: UUID?) {
        let selectedItem = id.flatMap { selectedID in
            reviewItems.first { $0.id == selectedID }
        } ?? reviewItems.first

        guard let selectedItem else {
            reviewURL = nil
            return
        }

        if selectedReviewItemID != selectedItem.id {
            selectedReviewItemID = selectedItem.id
        }

        reviewURL = selectedItem.url
        vm.lastPickedLocalURL = selectedItem.url
        selectedType = selectedItem.type
        editedInstitution = selectedItem.institution ?? ""
        bankSubtype = nil
        monthlyPaymentInput = ""
        aprPercentInput = ""
        balanceInput = ""
        balanceDate = Date()
        saveMessage = nil
        saveMessageIsError = false
        savedAccountID = nil
        selectedExistingAccountID = nil
        prefillSelectedReviewItemIfNeeded(selectedItem)
    }

    private func prefillSelectedReviewItemIfNeeded(_ item: QuickStartReviewItem) {
        guard reviewFileExtension == "pdf", let type = item.type else { return }
        guard parsedReviewItemID != item.id else { return }
        parsedReviewItemID = item.id

        Task {
            await coordinator.importURL(
                item.url,
                hint: type,
                modelContext: modelContext,
                settings: settings
            )

            await MainActor.run {
                guard selectedReviewItemID == item.id else { return }
                prefillManualFields(from: vm.staged, statementType: type)
            }
        }
    }

    private func prefillManualFields(from staged: StagedImport?, statementType: StatementType) {
        guard let staged else { return }

        if editedInstitution.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let inferredInstitution = staged.inferredInstitutionName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !inferredInstitution.isEmpty {
            editedInstitution = inferredInstitution
        }

        guard let balance = preferredBalance(from: staged, statementType: statementType) else { return }

        if balanceInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            balanceInput = formatMoneyForManualInput(balance.balance.magnitude)
            balanceDate = balance.asOfDate
        }

        if monthlyPaymentInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let payment = balance.typicalPaymentAmount,
           payment != .zero {
            monthlyPaymentInput = formatMoneyForManualInput(payment.magnitude)
        }

        if aprPercentInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let apr = balance.interestRateAPR {
            aprPercentInput = formatAPRForManualInput(apr, scale: balance.interestRateScale)
        }
    }

    private func preferredBalance(from staged: StagedImport, statementType: StatementType) -> StagedBalance? {
        let included = staged.balances.filter(\.include)
        let candidates = included.isEmpty ? staged.balances : included
        guard !candidates.isEmpty else { return nil }

        let accountType = toAccountType(statementType, bankSubtype: bankSubtype)
        let matching = candidates.filter { balance in
            let label = (balance.sourceAccountLabel ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()

            switch accountType {
            case .creditCard:
                return label.contains("credit") || label.isEmpty
            case .loan:
                return label.contains("loan") || label.isEmpty
            case .checking:
                return label.contains("checking") || label.isEmpty
            case .savings:
                return label.contains("savings") || label.isEmpty
            default:
                return true
            }
        }

        return (matching.isEmpty ? candidates : matching).max { lhs, rhs in
            lhs.asOfDate < rhs.asOfDate
        }
    }

    private func formatMoneyForManualInput(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = settings.currencyCode
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? "\(value)"
    }

    private func formatAPRForManualInput(_ value: Decimal, scale: Int?) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = max(scale ?? 2, 2)
        formatter.minimumFractionDigits = min(scale ?? 2, 2)
        let percent = value * 100
        return (formatter.string(from: NSDecimalNumber(decimal: percent)) ?? "\(percent)") + "%"
    }

    private func updateSelectedReviewItem(type: StatementType?, institution: String?) {
        guard let selectedReviewItemID,
              let index = reviewItems.firstIndex(where: { $0.id == selectedReviewItemID })
        else { return }

        reviewItems[index].type = type
        reviewItems[index].institution = institution?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? institution
            : nil
    }

    private func discardSelectedReviewItem() {
        guard let selectedReviewItemID,
              let index = reviewItems.firstIndex(where: { $0.id == selectedReviewItemID })
        else { return }

        let removed = reviewItems.remove(at: index)
        QuickStartReviewStorage.removeManagedFile(removed.url)

        let nextIndex = min(index, reviewItems.count - 1)
        if reviewItems.indices.contains(nextIndex) {
            self.selectedReviewItemID = reviewItems[nextIndex].id
            loadSelectedReviewItem(reviewItems[nextIndex].id)
        } else {
            self.selectedReviewItemID = nil
            clearCurrentReviewState()
        }

        saveMessage = "Statement discarded."
        saveMessageIsError = false
    }

    private func clearCurrentReviewState() {
        reviewURL = nil
        vm.lastPickedLocalURL = nil
        selectedType = nil
        editedInstitution = ""
        bankSubtype = nil
        monthlyPaymentInput = ""
        aprPercentInput = ""
        balanceInput = ""
        balanceDate = Date()
        savedAccountID = nil
        selectedExistingAccountID = nil
        showPDFPreview = false
        showTransactionPreview = false
        showImportReviewSheet = false
    }

    private func accountSummary(for item: QuickStartReviewItem) -> String {
        let institution = item.institution?.trimmingCharacters(in: .whitespacesAndNewlines)
        let type = item.type.map { displayName(for: $0) } ?? "Needs type"

        if let statementType = item.type,
           let institution,
           !institution.isEmpty,
           let match = matchingExistingAccount(type: toAccountType(statementType, bankSubtype: nil), institution: institution) {
            return "\(match.name) - \(type)"
        }

        if let institution, !institution.isEmpty {
            return "\(institution) - \(type)"
        }

        return "Account not selected - \(type)"
    }

    private func displayName(for type: StatementType) -> String {
        switch type {
        case .creditCard: return "Credit Card"
        case .bank: return "Bank"
        case .brokerage: return "Brokerage"
        case .loan: return "Loan"
        }
    }

    private func shortDisplayName(for type: StatementType) -> String {
        switch type {
        case .creditCard: return "Card"
        case .bank: return "Bank"
        case .brokerage: return "Broker"
        case .loan: return "Loan"
        }
    }
    
    private var enteredInstitutionName: String {
        editedInstitution.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var selectedUnknownAccountType: Account.AccountType? {
        guard selectedType != nil else { return nil }
        return toAccountType(selectedType, bankSubtype: bankSubtype)
    }

    private var matchingAccountForUnknownTransactionImport: Account? {
        guard isTransactionImportFile else { return nil }
        if let selectedExistingAccountID,
           let selected = accounts.first(where: { $0.id == selectedExistingAccountID }) {
            return selected
        }
        guard let accountType = selectedUnknownAccountType else { return nil }
        guard !enteredInstitutionName.isEmpty else { return nil }

        return matchingExistingAccount(
            type: accountType,
            institution: enteredInstitutionName
        )
    }

    private var existingAccountsForUnknownTransactionImport: [Account] {
        guard isTransactionImportFile else { return [] }
        guard let accountType = selectedUnknownAccountType else { return [] }
        return accounts
            .filter { $0.type == accountType }
            .sorted { lhs, rhs in
                let lhsInst = lhs.institutionName ?? ""
                let rhsInst = rhs.institutionName ?? ""
                if lhsInst.localizedCaseInsensitiveCompare(rhsInst) != .orderedSame {
                    return lhsInst.localizedCaseInsensitiveCompare(rhsInst) == .orderedAscending
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    private func applySelectedExistingAccount(_ accountID: UUID?) {
        guard let accountID,
              let account = accounts.first(where: { $0.id == accountID })
        else { return }

        switch account.type {
        case .checking:
            selectedType = .bank
            bankSubtype = .checking
        case .savings:
            selectedType = .bank
            bankSubtype = .savings
        case .creditCard:
            selectedType = .creditCard
            bankSubtype = nil
        case .loan:
            selectedType = .loan
            bankSubtype = nil
        case .brokerage:
            selectedType = .brokerage
            bankSubtype = nil
        default:
            break
        }

        editedInstitution = account.institutionName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? account.institutionName ?? account.name
            : account.name
    }

    private func clearSelectedExistingAccountIfNeeded() {
        guard let selectedExistingAccountID else { return }
        guard let accountType = selectedUnknownAccountType else {
            self.selectedExistingAccountID = nil
            return
        }
        if let account = accounts.first(where: { $0.id == selectedExistingAccountID }),
           account.type == accountType {
            return
        }
        self.selectedExistingAccountID = nil
    }

    private var unknownStatementSaveButtonTitle: String {
        guard isTransactionImportFile else {
            return "Add Account"
        }

        if matchingAccountForUnknownTransactionImport != nil {
            return "Import Transactions"
        } else {
            return "Create & Import"
        }
    }
    
    private var reviewFileExtension: String {
        reviewURL?.pathExtension.lowercased() ?? ""
    }

    private var isTransactionImportFile: Bool {
        ["csv", "tsv", "txt", "qfx", "ofx", "qbo", "qif"].contains(reviewFileExtension)
    }

    private func handleUnknownStatementSave() {
        if isTransactionImportFile {
            importUnknownTransactionFile()
        } else {
            saveUnknownStatementAccount()
        }
    }

    private func importUnknownTransactionFile() {
        guard let url = reviewURL else { return }
        guard let selectedType else { return }

        let accountType = toAccountType(selectedType, bankSubtype: bankSubtype)
        let inst = enteredInstitutionName
        guard !inst.isEmpty else { return }

        let existingAccount = matchingAccountForUnknownTransactionImport
        let importAccountType = existingAccount?.type ?? accountType

        vm.selectedAccountID = existingAccount?.id
        vm.newAccountType = importAccountType
        vm.userSelectedDocHint = importAccountType
        vm.userInstitutionName = existingAccount?.institutionName ?? inst
        vm.lastPickedLocalURL = url
        vm.staged = nil
        vm.mappingSession = nil
        vm.errorMessage = nil
        vm.infoMessage = nil
        saveMessage = nil
        saveMessageIsError = false

        AMLogging.log(
            "StatementReview importing unknown transaction file=\(url.lastPathComponent) ext=\(reviewFileExtension) type=\(selectedType) accountType=\(accountType.rawValue) accountMatch=\(existingAccount?.name ?? "nil") selectedAccountID=\(String(describing: vm.selectedAccountID)) institution=\(inst)",
            component: "Import"
        )

        Task {
            await coordinator.importURL(
                url,
                hint: selectedType,
                modelContext: modelContext,
                settings: settings
            )
            await waitForUnknownTransactionImportResult()

            await MainActor.run {
                vm.newAccountType = importAccountType
                vm.userSelectedDocHint = importAccountType
                if var staged = vm.staged {
                    staged.suggestedAccountType = importAccountType
                    vm.staged = staged
                }

                AMLogging.log(
                    "StatementReview transaction import returned staged=\(vm.staged != nil) mapping=\(vm.mappingSession != nil) error=\(vm.errorMessage ?? "nil")",
                    component: "Import"
                )

                if vm.staged != nil || vm.mappingSession != nil {
                    saveMessage = existingAccount == nil
                        ? "Ready to review. A new \(accountType.rawValue) account will be created when you approve the import."
                        : "Ready to review. Transactions will be imported into \(existingAccount?.name ?? inst)."
                    saveMessageIsError = false
                    if vm.staged?.transactions.isEmpty == false {
                        showTransactionPreview = true
                    } else {
                        showImportReviewSheet = true
                    }
                } else {
                    showImportReviewSheet = false
                    saveMessageIsError = true
                    saveMessage = vm.errorMessage ?? "No transactions were found to review. Check the file type and account details."
                }
            }
        }
    }

    private func waitForUnknownTransactionImportResult() async {
        for _ in 0..<80 {
            let hasResult = await MainActor.run {
                vm.staged != nil || vm.mappingSession != nil || vm.errorMessage != nil
            }
            if hasResult { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func matchingExistingAccount(type: Account.AccountType, institution: String) -> Account? {
        let wanted = normalizedAccountMatchText(institution)
        guard !wanted.isEmpty else { return nil }

        return accounts.first { account in
            guard account.type == type else { return false }

            let candidates = [
                account.institutionName,
                account.name
            ]
            .compactMap { $0 }
            .map(normalizedAccountMatchText)

            return candidates.contains(wanted)
        }
    }

    private func normalizedAccountMatchText(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "&", with: "and")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined()
    }

    private func toAccountType(_ t: StatementType?, bankSubtype: QuickIngestAccountType?) -> Account.AccountType {
        guard let t else { return .other }
        switch t {
        case .creditCard: return .creditCard
        case .loan:       return .loan
        case .brokerage:  return .brokerage
        case .bank:
            switch bankSubtype {
            case .some(.savings): return .savings
            default: return .checking
            }
        }
    }
    
    private func parseDecimal(_ s: String) -> Decimal? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let allowed = CharacterSet(charactersIn: "-0123456789.,")
        let filtered = String(trimmed.unicodeScalars.filter { allowed.contains($0) })
        var normalized = filtered
        if filtered.contains(",") && filtered.contains(".") {
            normalized = filtered.replacingOccurrences(of: ",", with: "")
        } else if filtered.contains(",") && !filtered.contains(".") {
            normalized = filtered.replacingOccurrences(of: ",", with: ".")
        }
        return Decimal(string: normalized)
    }
    
    private func parseAPRPercent(_ s: String) -> (Decimal, Int)? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let cleaned = trimmed.replacingOccurrences(of: "%", with: "").replacingOccurrences(of: ",", with: ".")
        guard let dec = Decimal(string: cleaned) else { return nil }
        let scale: Int = cleaned.split(separator: ".").last.map { $0.count } ?? 0
        var fraction = dec
        if fraction > 1 { fraction /= 100 }
        return (fraction, scale)
    }

    private func normalizedManualBalance(_ balance: Decimal, for type: Account.AccountType) -> Decimal {
        switch type {
        case .creditCard, .loan:
            return balance > .zero ? -balance : balance
        default:
            return balance < .zero ? -balance : balance
        }
    }
    
    private func saveUnknownStatementAccount() {
        let type = toAccountType(selectedType, bankSubtype: bankSubtype)
        let inst = editedInstitution.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !inst.isEmpty else { return }

        let acct = Account(
            name: inst,
            type: type,
            institutionName: inst,
            currencyCode: settings.currencyCode
        )

        modelContext.insert(acct)

        if let pmt = parseDecimal(monthlyPaymentInput), pmt > 0 || !aprPercentInput.isEmpty {
            var terms = acct.loanTerms ?? LoanTerms()
            if let p = parseDecimal(monthlyPaymentInput), p > 0 {
                terms.paymentAmount = p
            }
            if let (apr, scale) = parseAPRPercent(aprPercentInput) {
                terms.apr = apr
                terms.aprScale = scale
            }
            acct.loanTerms = terms
        }

        if let bal = parseDecimal(balanceInput) {
            let normalizedBalance = normalizedManualBalance(bal, for: type)
            let snap = BalanceSnapshot(
                asOfDate: balanceDate,
                balance: normalizedBalance,
                interestRateAPR: acct.loanTerms?.apr,
                interestRateScale: acct.loanTerms?.aprScale,
                account: acct,
                importBatch: nil
            )
            modelContext.insert(snap)
        }

        do {
            try modelContext.save()
            NotificationCenter.default.post(name: .accountsDidChange, object: nil)
            savedAccountID = acct.id

            saveMessage = "Saved \(inst). You can continue reviewing this PDF or navigate to the new account."
            saveMessageIsError = false
            AMLogging.log(
                "StatementReview manual account saved id=\(acct.id) type=\(acct.typeRaw) institution=\(inst)",
                component: "Import"
            )
        } catch {
            AMLogging.error(
                "StatementReview manual account save failed error=\(error.localizedDescription)",
                component: "Import"
            )
        }
    }
}

private struct AccountSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: [SortDescriptor(\Account.name, order: .forward)]) private var accounts: [Account]
    @Query(sort: [SortDescriptor(\Transaction.datePosted, order: .reverse)]) private var transactions: [Transaction]
    @Query(sort: [SortDescriptor(\BalanceSnapshot.asOfDate, order: .reverse)]) private var balanceSnapshots: [BalanceSnapshot]
    @State private var searchText = ""
    @FocusState private var isSearchFieldFocused: Bool

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredAccounts: [Account] {
        guard !trimmedSearchText.isEmpty else { return [] }

        return accounts.filter { account in
            DebtScopeFuzzySearch.matches(query: trimmedSearchText, values: searchableValues(for: account))
        }
    }

    private var filteredTransactions: [Transaction] {
        guard !trimmedSearchText.isEmpty else { return [] }

        return transactions.filter { transaction in
            DebtScopeFuzzySearch.matches(query: trimmedSearchText, values: searchableValues(for: transaction))
        }
    }

    private var filteredBalances: [BalanceSnapshot] {
        guard !trimmedSearchText.isEmpty else { return [] }

        return balanceSnapshots.filter { snapshot in
            DebtScopeFuzzySearch.matches(query: trimmedSearchText, values: searchableValues(for: snapshot))
        }
    }

    private var hasResults: Bool {
        !filteredAccounts.isEmpty || !filteredTransactions.isEmpty || !filteredBalances.isEmpty
    }

    var body: some View {
        NavigationStack {
            Group {
                if accounts.isEmpty && transactions.isEmpty && balanceSnapshots.isEmpty {
                    ContentUnavailableView(
                        "Nothing to search yet",
                        systemImage: "magnifyingglass",
                        description: Text("Import a statement or add an account to make financial data searchable inside DebtScope.")
                    )
                } else if trimmedSearchText.isEmpty {
                    ContentUnavailableView(
                        "Search DebtScope",
                        systemImage: "magnifyingglass",
                        description: Text("Find accounts, transactions, balances, payees, memos, dates, and amounts.")
                    )
                } else if !hasResults {
                    ContentUnavailableView.search(text: trimmedSearchText)
                } else {
                    List {
                        if !filteredAccounts.isEmpty {
                            Section("Accounts") {
                                ForEach(filteredAccounts.prefix(20)) { account in
                                    NavigationLink {
                                        AccountDetailView(accountID: account.id)
                                            .navigationBarTitleDisplayMode(.inline)
                                    } label: {
                                        AccountSearchResultRow(account: account)
                                    }
                                }
                            }
                        }

                        if !filteredTransactions.isEmpty {
                            Section("Transactions") {
                                ForEach(filteredTransactions.prefix(50)) { transaction in
                                    NavigationLink {
                                        EditTransactionView(transaction: transaction)
                                            .navigationBarTitleDisplayMode(.inline)
                                    } label: {
                                        TransactionSearchResultRow(transaction: transaction)
                                    }
                                }
                            }
                        }

                        if !filteredBalances.isEmpty {
                            Section("Balances") {
                                ForEach(filteredBalances.prefix(30)) { snapshot in
                                    if let accountID = snapshot.account?.id ?? snapshot.accountID {
                                        NavigationLink {
                                            AccountTransactionsListView(accountID: accountID)
                                                .navigationBarTitleDisplayMode(.inline)
                                        } label: {
                                            BalanceSearchResultRow(snapshot: snapshot)
                                        }
                                    } else {
                                        BalanceSearchResultRow(snapshot: snapshot)
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Transaction, payee, amount, account")
            .focused($isSearchFieldFocused)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .task {
                isSearchFieldFocused = true
            }
        }
    }

    private func searchableValues(for account: Account) -> [String] {
        let latestBalance = account.balanceSnapshots.sorted { $0.asOfDate > $1.asOfDate }.first?.balance
        return [
            displayName(for: account),
            account.institutionName ?? "",
            accountTypeDisplayName(for: account),
            latestBalance.map(formatAmountForSearch) ?? ""
        ]
    }

    private func searchableValues(for transaction: Transaction) -> [String] {
        [
            transaction.payee,
            transaction.memo ?? "",
            transaction.kind.rawValue,
            transaction.symbol ?? "",
            transaction.account.map(displayName) ?? "",
            formatAmountForSearch(transaction.amount),
            plainAmountString(transaction.amount),
            formatSearchDate(transaction.datePosted)
        ]
    }

    private func searchableValues(for snapshot: BalanceSnapshot) -> [String] {
        [
            "balance",
            snapshot.account.map(displayName) ?? "",
            formatAmountForSearch(snapshot.balance),
            plainAmountString(snapshot.balance),
            formatSearchDate(snapshot.asOfDate),
            snapshot.interestRateAPR.map { "APR \(plainAmountString($0))" } ?? ""
        ]
    }

    private func displayName(for account: Account) -> String {
        let trimmedName = account.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty { return trimmedName }

        let trimmedInstitution = (account.institutionName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedInstitution.isEmpty { return trimmedInstitution }

        return "Unnamed"
    }

    private func accountTypeDisplayName(for account: Account) -> String {
        AccountSearchFormatting.accountTypeDisplayName(for: account)
    }

    private func formatAmountForSearch(_ amount: Decimal) -> String {
        AccountSearchFormatting.currency(amount)
    }

    private func plainAmountString(_ amount: Decimal) -> String {
        NSDecimalNumber(decimal: amount).stringValue
    }

    private func formatSearchDate(_ date: Date) -> String {
        AccountSearchFormatting.date(date)
    }
}

private struct AccountSearchResultRow: View {
    let account: Account

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(displayName)
                    .font(.body)
                    .foregroundStyle(.primary)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            if let latestBalance {
                Text(AccountSearchFormatting.currency(latestBalance.balance))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(latestBalance.balance < 0 ? .red : .secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var displayName: String {
        AccountSearchFormatting.displayName(for: account)
    }

    private var subtitle: String {
        let type = AccountSearchFormatting.accountTypeDisplayName(for: account)
        let trimmedInstitution = (account.institutionName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedInstitution.isEmpty, trimmedInstitution != displayName else {
            return type
        }

        return "\(type) · \(trimmedInstitution)"
    }

    private var latestBalance: BalanceSnapshot? {
        account.balanceSnapshots.sorted { $0.asOfDate > $1.asOfDate }.first
    }
}

private struct TransactionSearchResultRow: View {
    let transaction: Transaction

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(transaction.payee.isEmpty ? transaction.kind.rawValue.capitalized : transaction.payee)
                    .font(.body)
                    .foregroundStyle(.primary)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Text(AccountSearchFormatting.currency(transaction.amount))
                .font(.caption.weight(.semibold))
                .foregroundStyle(transaction.amount < 0 ? .red : .secondary)
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        var parts = [AccountSearchFormatting.date(transaction.datePosted)]

        if let account = transaction.account {
            parts.append(AccountSearchFormatting.accountDescription(for: account))
        }

        if let memo = transaction.memo?.trimmingCharacters(in: .whitespacesAndNewlines), !memo.isEmpty {
            parts.append(memo)
        } else if let symbol = transaction.symbol?.trimmingCharacters(in: .whitespacesAndNewlines), !symbol.isEmpty {
            parts.append(symbol)
        }

        return parts.joined(separator: " · ")
    }
}

private struct BalanceSearchResultRow: View {
    let snapshot: BalanceSnapshot

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(accountName)
                    .font(.body)
                    .foregroundStyle(.primary)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Text(AccountSearchFormatting.currency(snapshot.balance))
                .font(.caption.weight(.semibold))
                .foregroundStyle(snapshot.balance < 0 ? .red : .secondary)
        }
        .padding(.vertical, 2)
    }

    private var accountName: String {
        guard let account = snapshot.account else { return "Balance" }
        return AccountSearchFormatting.displayName(for: account)
    }

    private var subtitle: String {
        var parts = ["Balance", AccountSearchFormatting.date(snapshot.asOfDate)]
        if let account = snapshot.account {
            parts.append(AccountSearchFormatting.accountTypeDisplayName(for: account))
        }
        if let apr = snapshot.interestRateAPR {
            parts.append("APR \(AccountSearchFormatting.percent(apr, scale: snapshot.interestRateScale))")
        }
        return parts.joined(separator: " · ")
    }
}

private enum AccountSearchFormatting {
    static func displayName(for account: Account) -> String {
        let trimmedName = account.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty { return trimmedName }

        let trimmedInstitution = (account.institutionName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedInstitution.isEmpty { return trimmedInstitution }

        return "Unnamed"
    }

    static func accountDescription(for account: Account) -> String {
        "\(displayName(for: account)) · \(accountTypeDisplayName(for: account))"
    }

    static func accountTypeDisplayName(for account: Account) -> String {
        switch account.type {
        case .checking:
            return "Checking"
        case .savings:
            return "Savings"
        case .creditCard:
            return "Credit Card"
        case .loan:
            return "Loan"
        case .cash:
            return "Cash"
        case .brokerage:
            return "Brokerage"
        case .property:
            return "Property"
        case .other:
            return "Other"
        }
    }

    static func currency(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        return formatter.string(from: NSDecimalNumber(decimal: amount)) ?? NSDecimalNumber(decimal: amount).stringValue
    }

    static func percent(_ amount: Decimal, scale: Int?) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        if let scale {
            formatter.minimumFractionDigits = scale
            formatter.maximumFractionDigits = scale
        } else {
            formatter.minimumFractionDigits = 2
            formatter.maximumFractionDigits = 3
        }
        return formatter.string(from: NSDecimalNumber(decimal: amount)) ?? NSDecimalNumber(decimal: amount).stringValue
    }

    static func date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

#Preview {
    QuickStartView()
}
