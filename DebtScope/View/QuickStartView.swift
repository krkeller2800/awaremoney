import SwiftUI
import Combine
import UniformTypeIdentifiers
import SwiftData

private enum QuickStartTopic: String, CaseIterable, Identifiable {
    case debtPayoff = "Payoff"
    case compareStrategies = "Compare Strategies"
    case netWorth = "Net Worth"
    case cashFlow = "Cash Flow"
    case incomeBills = "Income & Bills"
    case assets = "Assets"
    case statementReview = "Unknown ​Statements"

    var id: String { rawValue }
    var title: String { rawValue }
}

struct QuickStartView: View {
    @StateObject private var vm: ImportViewModel
    @State private var coordinator: StatementImportCoordinator
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var importRouter: ImportOpenRouter

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selection: QuickStartTopic? = .debtPayoff
    @State private var compactPath: [QuickStartTopic] = []
    @State private var showImporter = false
    @State private var showAbout = false
    @State private var showSettings = false
    @State private var showBackupRestore = false
    @State private var showHelp = false
    @State private var showDebug = false
    @State private var quickStartPending: (url: URL, type: StatementType?, institution: String?)? = nil
    @State private var debtPayoffSelectedAccountID: UUID? = nil
    @State private var cashFlowSelectedAccountID: UUID? = nil
    fileprivate enum PlanSheetMode: String, CaseIterable { case incomeBills, summary }
    @State private var planSheetMode: PlanSheetMode = .incomeBills

    init() {
        let vm = ImportViewModel(parsers: ImportViewModel.defaultParsers())
        _vm = StateObject(wrappedValue: vm)
        _coordinator = State(initialValue: StatementImportCoordinator(vm: vm))
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

    private static let importTypes: [UTType] = {
        var types: [UTType] = [.pdf, .commaSeparatedText, .tabSeparatedText, .text, .data]
        let exts = ["qfx", "ofx", "qbo", "qif", "xlsx", "xls", "csv", "tsv", "txt", "zip"]
        types.append(contentsOf: exts.compactMap { UTType(filenameExtension: $0) })
        return types
    }()

    private func deliverPendingImport(
        url: URL,
        type: StatementType?,
        institution: String?,
        to topic: QuickStartTopic
    ) {
        selection = topic
        if isCompactLayout {
            if compactPath.last != topic {
                compactPath.append(topic)
            }
        }
        quickStartPending = nil

        DispatchQueue.main.async {
            quickStartPending = (url: url, type: type, institution: institution)
        }
    }

    private func queueImport(url: URL, type: StatementType?, institution: String?) {
        let stagedURL = ImportFileStaging.stageToCaches(url)
        if let type {
            let topic = topicFor(statementType: type) ?? .statementReview
            deliverPendingImport(url: stagedURL, type: type, institution: institution, to: topic)
        } else {
            Task {
                let classifier = StatementIntakeClassifier()
                let detection = await classifier.classify(url: stagedURL)
                let fallback = await inferStatementFallback(from: stagedURL, preferredType: detection.type)
                await MainActor.run {
                    let resolvedType = detection.type ?? fallback.type
                    let topic = topicFor(statementType: resolvedType) ?? .statementReview
                    deliverPendingImport(
                        url: stagedURL,
                        type: resolvedType,
                        institution: institution ?? detection.institution ?? fallback.institution,
                        to: topic
                    )
                }
            }
        }
    }

    private func queueImportAfterImporterDismissal(url: URL, type: StatementType?, institution: String?) {
        showImporter = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            queueImport(url: url, type: type, institution: institution)
        }
    }

    private var isCompactLayout: Bool {
        horizontalSizeClass == .compact
    }

    private func inferStatementFallback(from url: URL, preferredType: StatementType?) async -> (type: StatementType?, institution: String?) {
        let runtime = AMRuntimeDiagnostics.executionEnvironmentDescription
        let userOverride: StatementImporter.UserOverride? = {
            switch preferredType {
            case .some(.creditCard): return .creditCard
            case .some(.loan): return .loan
            case .some(.brokerage): return .brokerage
            case .some(.bank): return .bank
            case .none: return nil
            }
        }()

        do {
            AMLogging.log(
                "QuickStart fallback: start file=\(url.lastPathComponent) preferredType=\(String(describing: preferredType)) runtime=\(runtime)",
                component: "Import"
            )
            let importer = StatementImporter()
            let result = try importer.importStatement(from: url, prefer: .transactions, userOverride: userOverride)
            var augmentedRows = result.rows
            var fullText: String? = nil

            if url.pathExtension.lowercased() == "pdf",
               let extractedText = PDFTextExtractor.extractText(from: url) {
                fullText = extractedText
                if let interestSection = PDFTextExtractor.extractInterestChargesSection(from: extractedText) {
                    augmentedRows.append([interestSection])
                }
                if let balanceSection = PDFTextExtractor.extractBalanceSummarySection(from: extractedText) {
                    augmentedRows.append([balanceSection])
                }
                for section in PDFTextExtractor.extractAccountSummarySections(from: extractedText) {
                    augmentedRows.append([section])
                }
                augmentedRows.append([extractedText])
                AMLogging.log(
                    "QuickStart fallback: extracted pdfText chars=\(extractedText.count) rows=\(augmentedRows.count) runtime=\(runtime)",
                    component: "Import"
                )
            }

            let staged: StagedImport
            do {
                staged = try PDFSummaryParser().parse(rows: augmentedRows, headers: result.headers)
            } catch {
                let parser = await MainActor.run {
                    ImportViewModel.defaultParsers().first { $0.canParse(headers: result.headers) }
                }
                guard let parser else { throw error }
                staged = try parser.parse(rows: augmentedRows, headers: result.headers)
            }

            let combinedText = ([fullText] + augmentedRows.flatMap { $0 }.map(Optional.some))
                .compactMap { $0 }
                .joined(separator: "\n")
            let inferredType = inferredStatementTypeFromParsedText(combinedText, balances: staged.balances)
            let inferredInstitution = inferredInstitutionFromParsedText(combinedText)
            AMLogging.log(
                "QuickStart fallback: balances=\(staged.balances.count) headers=\(result.headers.count) combinedChars=\(combinedText.count) inferredType=\(String(describing: inferredType)) inferredInstitution=\(inferredInstitution ?? "nil") runtime=\(runtime)",
                component: "Import"
            )
            return (
                type: inferredType,
                institution: inferredInstitution
            )
        } catch {
            AMLogging.error(
                "QuickStart fallback: failed file=\(url.lastPathComponent) error=\(error.localizedDescription) runtime=\(runtime)",
                component: "Import"
            )
            return (nil, nil)
        }
    }

    private func inferredInstitutionFromParsedText(_ text: String) -> String? {
        let lower = text.lowercased()
        if lower.contains("communitychoice.com") || lower.contains("community choice") {
            return "Community Choice"
        }
        if lower.contains("sloanservicing.com") || lower.contains("sloan servicing") {
            return "Sloan Servicing"
        }
        guard let regex = try? NSRegularExpression(
            pattern: "(?i)\\b(?:https?://)?(?:www\\d*\\.)?([a-z0-9-]{3,})\\.(com|net|org|bank|loan|mortgage|finance|financial|credit)\\b"
        ) else {
            return nil
        }
        var counts: [String: Int] = [:]
        var displayNames: [String: String] = [:]
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: range)
        guard !matches.isEmpty else {
            return nil
        }
        let ignored = Set([
            "account", "accounts", "app", "consumer", "customerservice", "ebill",
            "help", "home", "login", "mail", "my", "online", "payment", "portal",
            "secure", "service", "support", "web", "www", "www2"
        ])
        for match in matches {
            guard let labelRange = Range(match.range(at: 1), in: text) else { continue }
            let label = String(text[labelRange]).lowercased()
            guard !ignored.contains(label) else { continue }

            counts[label, default: 0] += 1
            displayNames[label] = label
                .split(separator: "-")
                .map { part in
                    let token = String(part)
                    guard let first = token.first else { return "" }
                    return String(first).uppercased() + token.dropFirst()
                }
                .joined(separator: " ")
        }

        guard let best = counts.max(by: { lhs, rhs in
            if lhs.value == rhs.value {
                return lhs.key > rhs.key
            }
            return lhs.value < rhs.value
        }) else {
            return nil
        }

        return displayNames[best.key]
    }

    private func inferredStatementTypeFromParsedText(_ text: String, balances: [StagedBalance]) -> StatementType? {
        let labels = balances.compactMap { $0.sourceAccountLabel?.lowercased() }
        let hasLoanLabel = labels.contains(where: { $0.contains("loan") })
        let hasCreditCardLabel = labels.contains(where: { $0.contains("credit") || $0.contains("card") })
        let hasBankLabel = labels.contains(where: { $0.contains("checking") || $0.contains("savings") })
        let normalized = text
            .lowercased()
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
        let hasLoanSummary = normalized.contains("totalloans")
            || normalized.contains("paymentof")
            || normalized.contains("paymentdue")
            || normalized.contains("endingbalance")
        let hasLoanTerms = normalized.contains("annualpercentagerate")
            || normalized.contains("interestrate")
            || normalized.contains("principal")
            || normalized.contains("interestpaidytd")
        AMLogging.log(
            "QuickStart inferredType: labels=\(labels) loanSummary=\(hasLoanSummary) loanTerms=\(hasLoanTerms) runtime=\(AMRuntimeDiagnostics.executionEnvironmentDescription)",
            component: "Import"
        )
        if hasLoanLabel {
            AMLogging.log(
                "QuickStart inferredType: returning loan from label runtime=\(AMRuntimeDiagnostics.executionEnvironmentDescription)",
                component: "Import"
            )
            return .loan
        }
        if hasCreditCardLabel {
            AMLogging.log(
                "QuickStart inferredType: returning creditCard from label runtime=\(AMRuntimeDiagnostics.executionEnvironmentDescription)",
                component: "Import"
            )
            return .creditCard
        }
        if hasBankLabel {
            AMLogging.log(
                "QuickStart inferredType: returning bank from label runtime=\(AMRuntimeDiagnostics.executionEnvironmentDescription)",
                component: "Import"
            )
            return .bank
        }
        if hasLoanSummary && hasLoanTerms {
            AMLogging.log(
                "QuickStart inferredType: returning loan from text heuristic runtime=\(AMRuntimeDiagnostics.executionEnvironmentDescription)",
                component: "Import"
            )
            return .loan
        }
        AMLogging.log(
            "QuickStart inferredType: no type inferred runtime=\(AMRuntimeDiagnostics.executionEnvironmentDescription)",
            component: "Import"
        )
        return nil
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

    @ViewBuilder
    private func topicContent(_ topic: QuickStartTopic, compact: Bool) -> some View {
        switch topic {
        case .debtPayoff:
            DebtPayoffDetailView(
                vm: vm,
                coordinator: coordinator,
                externalSelectedAccountID: $debtPayoffSelectedAccountID,
                onRouteImport: routeImportedAccount,
                pendingExternal: $quickStartPending
            )
        case .compareStrategies:
            DebtSummaryView(embeddedInNavigation: true)
        case .netWorth:
            NetWorthView(embeddedInNavigation: compact)
        case .cashFlow:
            CashFlowDetailView(
                vm: vm,
                coordinator: coordinator,
                externalSelectedAccountID: $cashFlowSelectedAccountID,
                onRouteImport: routeImportedAccount,
                pendingExternal: $quickStartPending
            )
        case .statementReview:
            StatementReviewDetailView(
                vm: vm,
                coordinator: coordinator,
                pendingExternal: $quickStartPending
            )
        case .incomeBills:
            QuickStartIncomeBillsDetailView(planSheetMode: $planSheetMode)
        case .assets:
            QuickStartAssetsDetailView()
        }
    }
    @ToolbarContentBuilder
    private var importToolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            PlanToolbarButton("Import", fixedWidth: 75) { showImporter = true }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showAbout = true
            } label: {
                Label("About", systemImage: "info.circle")
            }
        }
    }

    var body: some View {
        Group {
            if isCompactLayout {
                NavigationStack(path: $compactPath) {
                    List {
                        Section {
                            ForEach(QuickStartTopic.allCases) { topic in
                                NavigationLink(value: topic) {
                                    Text(topic.title)
                                }
                            }
                        }

                        utilitySection
                    }
                    .navigationTitle("DebtScope")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { importToolbarContent }
                    .navigationDestination(for: QuickStartTopic.self) { topic in
                        topicContent(topic, compact: true)
                            .onAppear {
                                selection = topic
                            }
                            .navigationTitle(topic.title)
                            .navigationBarTitleDisplayMode(.inline)
                    }
                }
            } else {
                NavigationSplitView {
                    ScrollView {
                        VStack(spacing: 20) {
                            quickStartSidebarCard(
                                title: nil,
                                items: QuickStartTopic.allCases.map { ($0.title, nil, $0 == selection) },
                                action: { tappedTitle in
                                    if let topic = QuickStartTopic.allCases.first(where: { $0.title == tappedTitle }) {
                                        selection = topic
                                    }
                                }
                            )

                            quickStartSidebarCard(
                                title: "Utility",
                                items: utilityItems.map { ($0.title, $0.systemImage, false) },
                                action: { tappedTitle in
                                    handleUtilityTap(title: tappedTitle)
                                }
                            )
                        }
                        .padding(16)
                    }
                    .navigationTitle("DebtScope")
                    .toolbar { importToolbarContent }
                } detail: {
                    detailContent
                        .navigationTitle(selection == .assets ? "" : (selection?.title ?? "DebtScope"))
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
        }
        .sheet(isPresented: $showAbout) {
            AboutView()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
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
        .fileImporter(isPresented: $showImporter, allowedContentTypes: Self.importTypes, allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    queueImportAfterImporterDismissal(url: url, type: nil, institution: nil)
                }
            case .failure:
                break
            }
        }
        .onChange(of: importRouter.quickStartPendingImport?.url, initial: false) { _, _ in
            guard let request = importRouter.quickStartPendingImport else { return }
            queueImport(url: request.url, type: request.type, institution: request.institution)
            importRouter.quickStartPendingImport = nil
        }
    }

    private var utilityItems: [(title: String, systemImage: String)] {
        var items: [(title: String, systemImage: String)] = [
            ("Backup & Restore", "externaldrive"),
            ("Settings", "gearshape"),
            ("Help", "questionmark.circle")
        ]
#if DEBUG
        if settings.showDebugTools {
            items.append(("Debug", "ladybug"))
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
        case "Debug":
            showDebug = true
        default:
            break
        }
    }

    private func quickStartSidebarCard(
        title: String?,
        items: [(title: String, systemImage: String?, isSelected: Bool)],
        action: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title, !title.isEmpty {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(spacing: 0) {
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
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
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
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.background)
            )
        }
        .padding(.horizontal, 12)
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
    @Query private var links: [AssetLiabilityLink]
    @Query(filter: #Predicate<Account> { $0.typeRaw == "loan" }, sort: [SortDescriptor(\Account.name, order: .forward)]) private var loanAccounts: [Account]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject private var settings: SettingsStore

    @State private var selectedAssetID: UUID? = nil
    @State private var showAddAssetSheet = false

    private var assetAccounts: [Account] {
        accounts.filter { $0.type == .property || $0.type == .other }
    }

    private var selectedAsset: Account? {
        guard let selectedAssetID else { return nil }
        return assetAccounts.first(where: { $0.id == selectedAssetID })
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
        }
        .sheet(isPresented: $showAddAssetSheet) {
            ManualAssetSheet()
        }
        .onAppear {
            if selectedAssetID == nil {
                selectedAssetID = assetAccounts.first?.id
            }
        }
        .onChange(of: assetAccounts.map(\.id), initial: false) { _, ids in
            if !ids.contains(where: { $0 == selectedAssetID }) {
                selectedAssetID = ids.first
            }
        }
        .task(id: assetAccounts.map(\.id)) {
            if selectedAssetID == nil {
                selectedAssetID = assetAccounts.first?.id
            }
        }
    }

    private var compactBody: some View {
        Group {
            if assetAccounts.isEmpty {
                ContentUnavailableView(
                    "No Assets Yet",
                    systemImage: "building.columns",
                    description: Text("Add a property or other tracked asset to see it here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 14) {
                        ForEach(assetAccounts, id: \.id) { account in
                            NavigationLink {
                                assetDetailContent(for: account, title: "Details")
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
                Text("Property")
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 16)
                    .padding(.bottom, 12)

                Group {
                    if assetAccounts.isEmpty {
                        ContentUnavailableView(
                            "No Assets Yet",
                            systemImage: "building.columns",
                            description: Text("Add a property or other tracked asset to see it here.")
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            VStack(spacing: 14) {
                                ForEach(assetAccounts, id: \.id) { account in
                                    Button {
                                        selectedAssetID = account.id
                                    } label: {
                                        assetCard(for: account, isSelected: selectedAssetID == account.id)
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
                    ContentUnavailableView(
                        "No Assets Yet",
                        systemImage: "building.columns",
                        description: Text("Add a property or other tracked asset to see it here.")
                    )
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
                Text(linkedLiability(for: account)?.name ?? "No loan linked")
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
                    editableTextRow("Name", text: binding(for: asset, keyPath: \.name))
                    editableTextRow(
                        "Description",
                        text: Binding(
                            get: { asset.institutionName ?? "" },
                            set: { newValue in
                                asset.institutionName = normalizedOptionalText(newValue)
                                saveModelContext()
                            }
                        ),
                        placeholder: "Description (optional)"
                    )
                    detailRow("Type", value: asset.type == .property ? "Property" : "Other Asset")
                }

                detailSection("Balance Info") {
                    editableTextRow(
                        "Value",
                        text: balanceTextBinding(for: asset),
                        placeholder: "0.00",
                        keyboardType: .decimalPad
                    )
                    if let snapshot = latestSnapshot(for: asset) {
                        editableTextRow(
                            "Balance",
                            text: balanceTextBinding(for: asset),
                            placeholder: "0.00",
                            keyboardType: .decimalPad
                        )
                        detailRow(
                            "As Of",
                            value: snapshot.asOfDate.formatted(date: .abbreviated, time: .omitted)
                        )
                    } else {
                        editableTextRow(
                            "Balance",
                            text: balanceTextBinding(for: asset),
                            placeholder: "0.00",
                            keyboardType: .decimalPad
                        )
                    }
                }

                detailSection("Financing") {
                    if asset.type == .property {
                        loanPickerRow(for: asset)
                    } else {
                        detailRow("Loan Account", value: "Not applicable")
                    }
                    if let loan = linkedLiability(for: asset) {
                        detailRow("Loan Balance", value: format(amount: liabilityMagnitude(for: loan)))
                        detailRow("Equity", value: format(amount: equity(for: asset, liability: loan)))
                        if let ltv = ltv(for: asset, liability: loan) {
                            detailRow("LTV", value: formatPercent(ltv))
                        }
                    } else {
                        Text("Link a loan to track equity and LTV.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                detailSection("Status") {
                    detailRow("Linked Loan", value: linkedLiability(for: asset)?.name ?? "Unlinked")
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
                Text("Linked loan: \(liability.name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Equity: \(format(amount: equity))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if assetBalance > .zero {
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

    private func balanceTextBinding(for account: Account) -> Binding<String> {
        Binding(
            get: {
                if let balance = latestBalance(for: account) {
                    return formatDecimalForInput(balance)
                }
                return ""
            },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let parsed = parseDecimalInput(trimmed) else {
                    if trimmed.isEmpty, let snapshot = latestSnapshot(for: account) {
                        snapshot.balance = .zero
                        snapshot.isUserModified = true
                        saveModelContext()
                    }
                    return
                }

                if let snapshot = latestSnapshot(for: account) {
                    snapshot.balance = parsed
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

    private func editableTextRow(
        _ label: String,
        text: Binding<String>,
        placeholder: String = "",
        keyboardType: UIKeyboardType = .default
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundStyle(.primary)
            Spacer()
            TextField(placeholder, text: text)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.secondary)
                .keyboardType(keyboardType)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.background)
    }

    private func linkedLiability(for asset: Account) -> Account? {
        guard asset.type == .property else { return nil }
        return links.first(where: { $0.asset.id == asset.id && $0.endDate == nil })?.liability
    }

    private func loanBinding(for asset: Account) -> Binding<UUID?> {
        Binding(
            get: { linkedLiability(for: asset)?.id },
            set: { newValue in
                updateLoanLink(for: asset, loanID: newValue)
            }
        )
    }

    private func updateLoanLink(for asset: Account, loanID: UUID?) {
        guard asset.type == .property else { return }

        if let existing = links.first(where: { $0.asset.id == asset.id && $0.endDate == nil }) {
            if let loanID, let loan = loanAccounts.first(where: { $0.id == loanID }) {
                existing.liability = loan
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
            Text("Loan Account")
                .foregroundStyle(.primary)
            Spacer()
            Picker("Loan Account", selection: loanBinding(for: asset)) {
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
    @Binding var pendingExternal: (url: URL, type: StatementType?, institution: String?)?

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var settings: SettingsStore
    @State private var lastImportedURL: URL? = nil

    private var isImportSheetPresented: Binding<Bool> {
        Binding(
            get: { vm.staged != nil || vm.mappingSession != nil },
            set: { presented in
                if !presented {
                    if let url = vm.lastPickedLocalURL {
                        lastImportedURL = url
                    }
                    vm.staged = nil
                    vm.mappingSession = nil
                }
            }
        )
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Review statements that could not be confidently classified.")
                .foregroundStyle(.secondary)

            Group {
                if let url = lastImportedURL ?? vm.lastPickedLocalURL {
                    PDFPreview(url: url)
                } else {
                    ContentUnavailableView(
                        "No Statement",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("Open a statement to review the PDF and import details here.")
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.quaternary.opacity(0.05))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 32)
        .background(.background)
        .sheet(isPresented: isImportSheetPresented) {
            ImportSheetContentView(vm: vm)
                .environment(\.modelContext, modelContext)
        }
        .onChange(of: pendingExternal?.url, initial: false) { _, _ in
            guard let pending = pendingExternal else { return }
            Task {
                await coordinator.importURL(
                    pending.url,
                    hint: pending.type,
                    modelContext: modelContext,
                    settings: settings
                )
                await MainActor.run {
                    if let url = vm.lastPickedLocalURL {
                        lastImportedURL = url
                    }
                    pendingExternal = nil
                }
            }
        }
    }
}

#Preview {
    QuickStartView()
}
