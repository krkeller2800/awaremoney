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

struct QuickStartPendingImport: Equatable {
    let id = UUID()
    let url: URL
    let type: StatementType?
    let institution: String?
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
    @State private var showPaywall = false
    @State private var quickStartPending: QuickStartPendingImport? = nil
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
        AMLogging.log(
            "QuickStart deliverPendingImport start topic=\(topic.rawValue) compact=\(isCompactLayout)",
            component: "Import"
        )

        quickStartPending = nil

        if isCompactLayout {
            if compactPath.last != topic {
                compactPath.append(topic)
            }
        } else {
            selection = topic
        }

        DispatchQueue.main.async {
            self.quickStartPending = QuickStartPendingImport(
                url: url,
                type: type,
                institution: institution
            )

            AMLogging.log(
                "QuickStart pending set id=\(self.quickStartPending?.id.uuidString ?? "nil") topic=\(topic.rawValue) selection=\(String(describing: self.selection))",
                component: "Import"
            )
        }
    }

    private func queueImport(url: URL, type: StatementType?, institution: String?) {
        AMLogging.log(
            "QuickStart queueImport start file=\(url.lastPathComponent) type=\(String(describing: type)) readable=\(FileManager.default.isReadableFile(atPath: url.path))",
            component: "Import"
        )
        let stagedURL = ImportFileStaging.stageToCaches(url)
        AMLogging.log(
            "QuickStart staged file=\(stagedURL.lastPathComponent) path=\(stagedURL.path) readable=\(FileManager.default.isReadableFile(atPath: stagedURL.path))",
            component: "Import"
        )
        if let type {
            let topic = topicFor(statementType: type) ?? .statementReview
            deliverPendingImport(url: stagedURL, type: type, institution: institution, to: topic)
        } else {
            Task {

                AMLogging.log(
                    "QuickStart classify start file=\(stagedURL.lastPathComponent)",
                    component: "Import"
                )

                let classifier = StatementIntakeClassifier()
                let detection = await classifier.classify(url: stagedURL)

                AMLogging.log(
                    "QuickStart classify result type=\(String(describing: detection.type)) institution=\(detection.institution ?? "nil")",
                    component: "Import"
                )

                let fallback = await inferStatementFallback(
                    from: stagedURL,
                    preferredType: detection.type
                )

                AMLogging.log(
                    "QuickStart fallback result type=\(String(describing: fallback.type)) institution=\(fallback.institution ?? "nil")",
                    component: "Import"
                )

                await MainActor.run {
                    let resolvedType = detection.type ?? fallback.type
                    let topic = topicFor(statementType: resolvedType) ?? .statementReview
                    AMLogging.log(
                        "QuickStart deliver topic=\(topic.rawValue) resolvedType=\(String(describing: resolvedType))",
                        component: "Import"
                    )
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
                pendingExternal: $quickStartPending
            )
        case .compareStrategies:
            DebtSummaryView(embeddedInNavigation: true) {
                routeToIncomeBills(compact: compact)
            }
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

                        TrialBanner(horizontalPadding: 8, textLineLimit: 1) {
                            showPaywall = true
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
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

                            TrialBanner(horizontalPadding: 0, textLineLimit: 1) {
                                showPaywall = true
                            }
                            .padding(.horizontal, 12)
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
        .sheet(isPresented: $showPaywall) {
            PaywallView()
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
        .fileImporter(isPresented: $showImporter, allowedContentTypes: Self.importTypes, allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                AMLogging.log(
                    "QuickStart fileImporter success urls=\(urls.map(\.lastPathComponent))",
                    component: "Import"
                )

                if let url = urls.first {
                    queueImportAfterImporterDismissal(url: url, type: nil, institution: nil)
                }

            case .failure(let error):
                AMLogging.error(
                    "QuickStart fileImporter failed error=\(error.localizedDescription)",
                    component: "Import"
                )
            }
        }
        .onChange(of: importRouter.quickStartPendingImport?.id, initial: true) { _, _ in
            guard let request = importRouter.quickStartPendingImport else { return }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                queueImport(
                    url: request.url,
                    type: request.type,
                    institution: request.institution
                )
                importRouter.quickStartPendingImport = nil
            }
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
    @Binding var pendingExternal: QuickStartPendingImport?
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

    var body: some View {
        VStack(spacing: 16) {
            Text("Review statements that could not be confidently classified.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal)
            
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
                            unknownStatementForm
                                .frame(minWidth: 320, maxWidth: 420, maxHeight: .infinity, alignment: .topLeading)
                                .padding()
                            
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
                        description: Text("Open a statement to review the PDF and import details here.")
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 32)
        .background(.background)
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
        .task(id: pendingExternal?.id) {
            guard let pending = pendingExternal else { return }

            AMLogging.log(
                "StatementReview task received file=\(pending.url.lastPathComponent) type=\(String(describing: pending.type))",
                component: "Import"
            )

            if pending.type == nil {
                await MainActor.run {
                    reviewURL = pending.url
                    vm.lastPickedLocalURL = pending.url
                    saveMessage = nil
                    saveMessageIsError = false
                    savedAccountID = nil
                    selectedExistingAccountID = nil
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
                reviewURL = pending.url
                saveMessage = nil
                saveMessageIsError = false
                savedAccountID = nil
                selectedExistingAccountID = nil
                pendingExternal = nil
            }
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
            let snap = BalanceSnapshot(
                asOfDate: balanceDate,
                balance: bal,
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

#Preview {
    QuickStartView()
}
