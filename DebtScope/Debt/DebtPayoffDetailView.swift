import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct DebtPayoffDetailView: View {
    @ObservedObject var vm: ImportViewModel
    let coordinator: StatementImportCoordinator
    @Binding var externalSelectedAccountID: UUID?
    let onRouteImport: (StatementType?, UUID?) -> Void

    var importAction: () -> Void = {}
    var manualEntryAction: () -> Void = {}
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
    private struct EditingAccount: Identifiable { let id: UUID }
    @State private var editingAccount: EditingAccount? = nil
    @State private var pendingDelete: Account? = nil
    @State private var importedPreview: ImportedStatementPreview? = nil
    @State private var detectedAccounts: [DetectionReviewSheet.DetectedAccountSelection] = []
    @State private var showStatementSheet = false
    @State private var impactPaymentAmount: Double = 0
    @State private var impactBalanceInput: String = ""
    @State private var impactAPRInput: String = ""
    @State private var impactTypicalPaymentInput: String = ""
    // New state for payoff inputs and results
    @State private var ingestedAccount: Account? = nil          // Optional: use if you set this after ingest
    @State private var monthlyPaymentInput: String = ""
    @State private var aprPercentInput: String = ""             // e.g., "19.99" means 19.99%
    @State private var balanceInput: String = ""                // Current/ending balance
    @State private var computedPayoffDate: Date? = nil
    @State private var nonReducingPayment: Bool = false
    @State private var showCompactPayoffDetail = false

    private enum ImpactField: Hashable {
        case balance
        case apr
        case typicalPayment

        var scrollID: String {
            switch self {
            case .balance: return "impact-balance"
            case .apr: return "impact-apr"
            case .typicalPayment: return "impact-typical-payment"
            }
        }
    }

    @FocusState private var focusedImpactField: ImpactField?
 
    private var isEditing: Bool {
        focusedImpactField != nil
    }

    private var manualAddButtonTitle: String {
        UIDevice.type == "iPhone" ? "Manual" : "Add Manually"
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

    private func focusOrder(for account: Account) -> [ImpactField] {
        let arr: [ImpactField] = [.balance,.apr,.typicalPayment]
        return arr
    }
    
    private func selectAllSoon(_ label: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let sent = UIApplication.shared.sendAction(
                #selector(UIResponder.selectAll(_:)),
                to: nil,
                from: nil,
                for: nil
            )

            print("\(label) selectAll sent:", sent)
        }
    }
    
    private func currentImpactFieldForNavigation() -> ImpactField? {
        focusedImpactField
    }

    private func canGoPrevious(for account: Account) -> Bool {
        guard let current = currentImpactFieldForNavigation() else { return false }
        let order = focusOrder(for: account)
        guard let idx = order.firstIndex(of: current) else { return false }
        return idx > 0
    }

    private func canGoNext(for account: Account) -> Bool {
        guard let current = currentImpactFieldForNavigation() else { return false }
        let order = focusOrder(for: account)
        guard let idx = order.firstIndex(of: current) else { return false }
        return idx < order.count - 1
    }

    private func focusImpactField(_ field: ImpactField, reason: String) {
        print("FOCUS REQUEST \(reason) ->", field)
        focusedImpactField = field
        print("FOCUS APPLIED \(reason) ->", String(describing: focusedImpactField))
    }

    private func moveFocus(_ delta: Int, for account: Account) {
        let order = focusOrder(for: account)

        print("MOVE start focused=", String(describing: focusedImpactField))

        guard let current = focusedImpactField,
              let idx = order.firstIndex(of: current) else {
            print("MOVE failed to resolve current focus")
            if let first = order.first {
                focusImpactField(first, reason: "Move fallback")
            }
            return
        }

        let nextIdx = max(0, min(order.count - 1, idx + delta))
        let next = order[nextIdx]

        print("MOVE current=", current, "next=", next)

        focusImpactField(next, reason: "Move")

        print("MOVE end requested focused=", String(describing: focusedImpactField))
    }
    private func commitAndDismissKeyboard() {
        try? modelContext.save()
        focusedImpactField = nil
        let keyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }

        keyWindow?.endEditing(true)
    }

    @ToolbarContentBuilder
    private func impactKeyboardToolbar() -> some ToolbarContent {
        ToolbarItemGroup(placement: .keyboard) {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    Spacer()
                        .frame(width: geo.size.width * 0.25)

                    HStack(spacing: 20) {
                        Button {
                            if let account = currentAccount() {
                                moveFocus(-1, for: account)
                            }
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .disabled(!canMovePrevious)

                        Button {
                            if let account = currentAccount() {
                                moveFocus(1, for: account)
                            }
                        } label: {
                            Image(systemName: "chevron.right")
                        }
                        .disabled(!canMoveNext)
                    }

                    Spacer()

                    Button {
                        commitAndDismissKeyboard()
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .disabled(!isEditing)
                }
            }
            .frame(height: 44)
        }
    }

    private var canMovePrevious: Bool {
        guard let account = currentAccount() else { return false }
        return canGoPrevious(for: account)
    }

    private var canMoveNext: Bool {
        guard let account = currentAccount() else { return false }
        return canGoNext(for: account)
    }
    
    private func routeImportedAccount(_ account: Account?) {
        guard let account else { return }
        onRouteImport(statementType(for: account.type), account.id)
    }

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
        var routeConfirmationText: String? = nil
    }
    private struct ImportedStatementPreview {
        var institution: String?
        var statementType: StatementType?
        var balance: Decimal?
        var balanceDate: Date?
        var typicalPayment: Decimal?
        var aprFraction: Decimal?
        var aprScale: Int?
        var bankBalanceSummaries: [BankBalanceSummary] = []
        var bankTransactionLabels: Set<String> = []
    }

    private struct BankBalanceSummary: Identifiable, Equatable {
        let id: String
        let label: String
        let beginningBalance: Decimal?
        let endingBalance: Decimal?
        let endingBalanceDate: Date?
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
        if let sel = selectedAccountID { return debtAccounts.first(where: { $0.id == sel }) }
        return nil
    }

    private var debtAccounts: [Account] {
        accounts.filter {
            switch $0.type {
            case .creditCard, .loan:
                return true
            default:
                return false
            }
        }
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
            QAccountsListView(
                accounts: debtAccounts,
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

            payoffImpactPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(.quaternary.opacity(0.05))
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }

    @ViewBuilder
    private var compactDebtView: some View {
        QAccountsListView(
            accounts: debtAccounts,
            selectedAccountID: $selectedAccountID,
            onEdit: { account in
                editingAccount = EditingAccount(id: account.id)
            },
            onDeleteConfirmed: { account in
                deleteAccount(account)
            },
            onSelectionChanged: { id in
                guard let id else { return }
                selectedAccountID = id
                updateLastImportedURL(for: id)
                showCompactPayoffDetail = true
            }
        )
        .frame(maxWidth: .infinity, minHeight: 280, alignment: .topLeading)
        .padding(.horizontal)
        .navigationDestination(isPresented: $showCompactPayoffDetail) {
            VStack(spacing: 0) {
                payoffImpactPanel
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity,
                   maxHeight: .infinity,
                   alignment: .top)
            .navigationTitle("Payment Impact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()

                    Button("Done") {
                        commitAndDismissKeyboard()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var contentArea: some View {
        if horizontalSizeClass == .compact {
            compactDebtView
        } else {
            columnsView
        }
    }

    @ViewBuilder
    private var payoffImpactPanel: some View {
        if let account = currentAccount() {
            let baselinePayment = baselinePaymentAmount(for: account)
            let sliderRange = paymentSliderRange(for: account)
            let baseline = payoffImpactProjection(for: account, monthlyPayment: baselinePayment)
            let adjusted = payoffImpactProjection(for: account, monthlyPayment: Decimal(impactPaymentAmount))
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Payment Impact")
                            .font(.headline.weight(.semibold))
                        Text(account.name.isEmpty ? "Selected account" : account.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Button {
                        editingAccount = EditingAccount(id: account.id)
                    } label: {
                        Label("Edit Account", systemImage: "pencil")
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if let baseline, let adjusted {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Payment")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(formatCurrency(Decimal(impactPaymentAmount)))
                                .font(.headline.monospacedDigit())
                        }
                        Slider(value: $impactPaymentAmount, in: sliderRange, step: 25)
                        HStack {
                            Text(formatCurrency(Decimal(sliderRange.lowerBound)))
                            Spacer()
                            Text(formatCurrency(Decimal(sliderRange.upperBound)))
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 10) {
                        impactMetric(
                            title: "Payoff",
                            value: adjusted.payoffDate?.formatted(date: .abbreviated, time: .omitted) ?? "Never",
                            baseline: baseline.payoffDate?.formatted(date: .abbreviated, time: .omitted) ?? "Never"
                        )
                        impactMetric(
                            title: "Interest",
                            value: adjusted.totalInterest.map(formatCurrency) ?? "—",
                            baseline: baseline.totalInterest.map(formatCurrency) ?? "—"
                        )
                    }

                    if let savingsSummary = savingsSummaryText(
                        baseMonths: baseline.months,
                        adjustedMonths: adjusted.months,
                        baseInterest: baseline.totalInterest,
                        adjustedInterest: adjusted.totalInterest
                    ) {
                        Text(savingsSummary)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    accountInputsSection(for: account)
                } else {
                    ContentUnavailableView(
                        "Payment impact unavailable",
                        systemImage: "slider.horizontal.3",
                        description: Text("Add a balance, APR, and payment amount for this account to compare payoff scenarios.")
                    )
                }
            }
            .padding(18)
        } else {
            ContentUnavailableView(
                "Select an account",
                systemImage: "creditcard",
                description: Text("Choose a liability account to compare payment scenarios.")
            )
            .padding(24)
        }
    }
    
    private func impactMetric(title: String, value: String, baseline: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text("was \(baseline)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func accountInputsSection(for account: Account) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Account Inputs")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            compactInputRow("Balance") {
                HStack(spacing: 6) {
                    TextField("$0.00", text: Binding(
                        get: { impactBalanceInput },
                        set: { value in
                            impactBalanceInput = value
                            saveImpactBalance(for: account, rawValue: value)
                        }
                    ))
                    .focused($focusedImpactField, equals: .balance)
                    .onChange(of: focusedImpactField) { oldValue, newValue in
                        print("FOCUS CHANGE Balance old=\(String(describing: oldValue)) new=\(String(describing: newValue))")
                        guard newValue == .balance else { return }
                        selectAllSoon("Balance")
                    }
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.numbersAndPunctuation)
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            focusedImpactField = .balance
                            selectAllSoon("Balance tap")
                        }
                    )

                    Button {
                        focusImpactField(.balance, reason: "Balance pencil")
                    } label: {
                        Image(systemName: "pencil")
                            .foregroundStyle(.secondary)
                            .imageScale(.small)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.secondary.opacity(0.25), lineWidth: 1)
                }
            }
            .id(ImpactField.balance.scrollID)

            compactInputRow("APR") {
                HStack(spacing: 6) {
                    TextField("0.00", text: Binding(
                        get: { impactAPRInput },
                        set: { value in
                            impactAPRInput = value
                            saveImpactAPR(for: account, rawValue: value)
                        }
                    ))
                    .focused($focusedImpactField, equals: .apr)
                    .onChange(of: focusedImpactField) { oldValue, newValue in
                        print("FOCUS CHANGE APR old=\(String(describing: oldValue)) new=\(String(describing: newValue))")

                        if oldValue == .apr && newValue != .apr {
                            formatImpactAPRInput()
                        }

                        guard newValue == .apr else { return }
                        selectAllSoon("APR")
                    }
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.numbersAndPunctuation)
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            focusedImpactField = .apr
                            selectAllSoon("APR tap")
                        }
                    )
                    Button {
                        focusImpactField(.apr, reason: "APR pencil")
                    } label: {
                        Image(systemName: "pencil")
                            .foregroundStyle(.secondary)
                            .imageScale(.small)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.secondary.opacity(0.25), lineWidth: 1)
                }
            }
            .id(ImpactField.apr.scrollID)

            compactInputRow("Typical payment") {
                HStack(spacing: 6) {
                    TextField("$0.00", text: Binding(
                        get: { impactTypicalPaymentInput },
                        set: { value in
                            impactTypicalPaymentInput = value
                            saveImpactTypicalPayment(for: account, rawValue: value)
                        }
                    ))
                    .focused($focusedImpactField, equals: .typicalPayment)
                    .onChange(of: focusedImpactField) { oldValue, newValue in
                        print("FOCUS CHANGE Typical old=\(String(describing: oldValue)) new=\(String(describing: newValue))")
                        guard newValue == .typicalPayment else { return }
                        selectAllSoon("Typical payment")
                    }
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.numbersAndPunctuation)
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            focusedImpactField = .typicalPayment
                            selectAllSoon("Typical Payment tap")
                        }
                    )
                    Button {
                        focusImpactField(.typicalPayment, reason: "Typical payment pencil")
                    } label: {
                        Image(systemName: "pencil")
                            .foregroundStyle(.secondary)
                            .imageScale(.small)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.secondary.opacity(0.25), lineWidth: 1)
                }
            }
            .id(ImpactField.typicalPayment.scrollID)

            compactInputRow("Due day") {
                Picker("Due day", selection: Binding<Int?>(
                    get: { account.loanTerms?.paymentDayOfMonth },
                    set: { value in saveImpactDueDay(for: account, value: value) }
                )) {
                    Text("None").tag(nil as Int?)
                    ForEach(1...31, id: \.self) { day in
                        Text("\(day)").tag(Optional(day))
                    }
                }
                .labelsHidden()
            }
        }
        .padding(.top, 4)
    }

    private func compactInputRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            content()
                .font(.callout.monospacedDigit())
                .frame(maxWidth: 170, alignment: .trailing)
        }
    }
    private func formatImpactAPRInput() {
        guard let parsed = MoneyParsing.parsePercentInput(impactAPRInput) else { return }

        var percent = parsed
        if percent <= 1 {
            percent *= 100
        }

        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        nf.minimumFractionDigits = 2
        nf.maximumFractionDigits = 2

        let text = nf.string(from: NSDecimalNumber(decimal: percent)) ?? "\(percent)"
        impactAPRInput = "\(text)%"
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

    @ViewBuilder
    private func detectionReviewSheetContent(model: DetectionSheetModel) -> some View {
        let acct = currentAccount()
        let latest = acct.flatMap { latestBalance(for: $0) }
        let importedBankSummaries = (importedPreview?.bankBalanceSummaries ?? []).map { summary in
            DetectionReviewSheet.ImportedBankBalanceSummary(
                id: summary.id,
                label: summary.label,
                beginningBalance: summary.beginningBalance,
                endingBalance: summary.endingBalance,
                endingBalanceDate: summary.endingBalanceDate
            )
        }
        DetectionReviewSheet(
            detection: model.detection,
            url: model.url,
            selectedType: $selectedType,
            editedInstitution: $editedInstitution,
            bankSubtype: $bankSubtype,
            monthlyPaymentInput: $monthlyPaymentInput,
            aprPercentInput: $aprPercentInput,
            balanceInput: $balanceInput,
            importedTypicalPayment: importedPreview?.typicalPayment,
            importedAPRFraction: importedPreview?.aprFraction,
            importedAPRScale: importedPreview?.aprScale,
            importedBalance: importedPreview?.balance,
            importedBalanceDate: importedPreview?.balanceDate,
            importedBankBalanceSummaries: importedBankSummaries,
            routeConfirmationText: model.routeConfirmationText,
            detectedAccounts: $detectedAccounts,
            account: acct,
            latestBalance: latest,
            isQuickIngesting: $isQuickIngesting,
            onSave: { det, incomingURL, selections in
                detectedAccounts = selections
                openFullImportReview(detection: det, url: incomingURL, selectedDetectedAccounts: selections)
            },
            onDiscard: {
                isPreparingDetectionReview = false
                detectionSheetModel = nil
            }
        )
    }

    // Stages a URL into the app's Caches directory so it remains readable across contexts
    private func stageURLToCaches(_ sourceURL: URL) -> URL {
        ImportFileStaging.stageToCaches(sourceURL)
    }

    private func handleImport(url: URL) {
        isPreparingDetectionReview = true
        Task {
            // Stage the picked file into the app's caches directory first so it remains readable
            let routedURL = stageURLToCaches(url)

            // Classify the statement using the staged URL to avoid security-scope issues
            let classifier = StatementIntakeClassifier()
            let detection = await classifier.classify(url: routedURL)
            let preview = await extractImportedPreview(from: routedURL, hint: detection.type)
            await MainActor.run {
                // Pre-fill editable fields
                self.lastDetection = detection
                self.editedInstitution = detection.institution ?? preview?.institution ?? ""
                self.selectedType = resolvedImportedStatementType(
                    detectionType: detection.type,
                    previewType: preview?.statementType
                )
                self.importedPreview = preview
                self.detectedAccounts = buildDetectedAccounts(from: preview)
                self.bankSubtype = nil
                self.applyImportedPreviewToInputs(preview)

                // Ensure the file importer is dismissed before presenting another sheet
                self.showImporter = false

                // Present the review sheet after a short delay to avoid presentation collisions
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    self.detectionSheetModel = DetectionSheetModel(detection: detection, url: routedURL)
                    self.isPreparingDetectionReview = false
                }
            }
        }
    }

    @MainActor
    private func applyImportedPreviewToInputs(_ preview: ImportedStatementPreview?) {
        monthlyPaymentInput = ""
        aprPercentInput = ""
        balanceInput = ""
        computedPayoffDate = nil
        nonReducingPayment = false

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
                let accountSummaries = PDFTextExtractor.extractAccountSummarySections(from: extractedText)
                for section in accountSummaries {
                    augmentedRows.append([section])
                }
                augmentedRows.append([extractedText])
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
            let combinedText = ([fullText] + augmentedRows.flatMap { $0 }.map(Optional.some))
                .compactMap { $0 }
                .joined(separator: "\n")
            let fallbackInstitution = inferredInstitutionFromParsedText(combinedText)
            let fallbackType = inferredStatementTypeFromParsedText(
                combinedText,
                balances: staged.balances
            )
            let stagedBankSummaries = buildBankBalanceSummaries(from: staged.balances)
            var bankBalanceSummaries = mergeBankBalanceSummaries(
                stagedBankSummaries,
                extractConsolidatedBankBalances(from: url) ?? [],
                extractAccountSectionBankBalances(from: url) ?? []
            )
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
                "DebtPayoff preview accounts — balanceLabels=\(Array(existingSummaryLabels).sorted()) transactionLabels=\(Array(transactionAccountLabels).sorted()) displayed=\(bankBalanceSummaries.map { $0.id })",
                component: "DebtPayoffDetailView"
            )

            return ImportedStatementPreview(
                institution: fallbackInstitution,
                statementType: fallbackType,
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

        return grouped.keys.sorted { bankSummarySortOrder(for: $0) < bankSummarySortOrder(for: $1) }
            .compactMap { key in
                guard isSupportedBankPreviewKey(key), let rows = grouped[key], !rows.isEmpty else { return nil }
                let sorted = rows.sorted { lhs, rhs in
                    if lhs.asOfDate == rhs.asOfDate {
                        return lhs.balance < rhs.balance
                    }
                    return lhs.asOfDate < rhs.asOfDate
                }
                return BankBalanceSummary(
                    id: key,
                    label: displayLabel(for: key),
                    beginningBalance: sorted.count > 1 ? sorted.first?.balance.magnitude : nil,
                    endingBalance: sorted.last?.balance.magnitude,
                    endingBalanceDate: sorted.last?.asOfDate
                )
            }
    }

    private func buildDetectedAccounts(from preview: ImportedStatementPreview?) -> [DetectionReviewSheet.DetectedAccountSelection] {
        guard let preview else { return [] }
        return preview.bankBalanceSummaries.map { summary in
            let detectedType: StatementType = summary.id == "loan" ? .loan : .bank
            let endingBalance = summary.endingBalance?.magnitude
            let beginning = summary.beginningBalance?.magnitude ?? .zero
            let ending = endingBalance ?? .zero
            let hasTransactions = preview.bankTransactionLabels.contains(normalizedBankSummaryLabel(summary.id))
            let isInactive = !hasTransactions && beginning == .zero && ending == .zero
            return DetectionReviewSheet.DetectedAccountSelection(
                id: summary.id,
                label: summary.label,
                statementType: detectedType,
                endingBalance: endingBalance,
                isInactive: isInactive,
                shouldImport: !isInactive
            )
        }
    }

    private func mergeBankBalanceSummaries(_ collections: [BankBalanceSummary]...) -> [BankBalanceSummary] {
        var merged: [String: BankBalanceSummary] = [:]
        for collection in collections {
            for summary in collection {
                let key = normalizedBankSummaryLabel(summary.id)
                let existing = merged[key]
                merged[key] = BankBalanceSummary(
                    id: key,
                    label: displayLabel(for: key),
                    beginningBalance: summary.beginningBalance ?? existing?.beginningBalance,
                    endingBalance: existing?.endingBalance ?? summary.endingBalance,
                    endingBalanceDate: existing?.endingBalanceDate ?? summary.endingBalanceDate
                )
            }
        }
        return merged.keys.sorted { bankSummarySortOrder(for: $0) < bankSummarySortOrder(for: $1) }
            .compactMap { merged[$0] }
    }

    private func extractConsolidatedBankBalances(from url: URL) -> [BankBalanceSummary]? {
        guard let rawText = PDFTextExtractor.extractText(from: url), !rawText.isEmpty else { return nil }
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
            summaries.append(BankBalanceSummary(id: key, label: displayLabel(for: key), beginningBalance: nil, endingBalance: endingBalance, endingBalanceDate: nil))
        }
        return summaries.isEmpty ? nil : summaries
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
            } else {
                continue
            }

            let lines = section.components(separatedBy: CharacterSet.newlines)
            var beginningBalance: Decimal?
            var endingBalance: Decimal?

            for (index, line) in lines.enumerated() {
                let lowerLine = line.lowercased()
                if beginningBalance == nil, lowerLine.contains("beginning balance") || lowerLine.contains("balance forward") {
                    beginningBalance = preferredAmount(in: line)
                    if beginningBalance == nil, index + 1 < lines.count {
                        beginningBalance = preferredAmount(in: lines[index + 1])
                    }
                }
                if endingBalance == nil, lowerLine.contains("ending balance") || lowerLine.contains("current balance") {
                    endingBalance = preferredAmount(in: line)
                    if endingBalance == nil, index + 1 < lines.count {
                        endingBalance = preferredAmount(in: lines[index + 1])
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

        let ordered = ["checking", "savings", "loan", "certificate"].compactMap { summaries[$0] }
        return ordered.isEmpty ? nil : ordered
    }

    private func displayLabel(for rawLabel: String) -> String {
        switch rawLabel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "checking": return "Checking"
        case "savings": return "Savings"
        case "loan": return "Loan"
        case "certificate": return "Certificate"
        default:
            return rawLabel.split(separator: " ").map { $0.capitalized }.joined(separator: " ")
        }
    }

    private func normalizedBankSummaryLabel(_ rawLabel: String?) -> String {
        let raw = (rawLabel ?? "default").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if raw.contains("checking") || raw.contains("draft") || raw.contains("dda") { return "checking" }
        if raw.contains("savings") || raw.contains("money market") || raw.contains("mmda") || raw.contains("share") { return "savings" }
        if raw.contains("loan") || raw.contains("mortgage") || raw.contains("flair") { return "loan" }
        if raw.contains("certificate") || raw.contains("cd") { return "certificate" }
        return raw
    }

    private func isSupportedBankPreviewKey(_ rawKey: String) -> Bool {
        switch normalizedBankSummaryLabel(rawKey) {
        case "checking", "savings", "loan", "certificate", "default":
            return true
        default:
            return false
        }
    }

    private func bankSummarySortOrder(for key: String) -> Int {
        switch key {
        case "checking": return 0
        case "savings": return 1
        case "loan": return 2
        case "certificate": return 3
        default: return 99
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
            let lowerLabel = String(text[labelRange]).lowercased()
            guard !ignored.contains(lowerLabel) else { continue }

            counts[lowerLabel, default: 0] += 1
            displayNames[lowerLabel] = lowerLabel
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
        if hasLoanLabel {
            AMLogging.log(
                "DebtPayoff inferredType: returning loan from label labels=\(labels) runtime=\(AMRuntimeDiagnostics.executionEnvironmentDescription)",
                component: "Import"
            )
            return .loan
        }
        if hasCreditCardLabel {
            AMLogging.log(
                "DebtPayoff inferredType: returning creditCard from label labels=\(labels) runtime=\(AMRuntimeDiagnostics.executionEnvironmentDescription)",
                component: "Import"
            )
            return .creditCard
        }
        if hasBankLabel {
            AMLogging.log(
                "DebtPayoff inferredType: returning bank from label labels=\(labels) runtime=\(AMRuntimeDiagnostics.executionEnvironmentDescription)",
                component: "Import"
            )
            return .bank
        }
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
            "DebtPayoff inferredType: labels=\(labels) loanSummary=\(hasLoanSummary) loanTerms=\(hasLoanTerms) runtime=\(AMRuntimeDiagnostics.executionEnvironmentDescription)",
            component: "Import"
        )
        if hasLoanSummary && hasLoanTerms {
            AMLogging.log(
                "DebtPayoff inferredType: returning loan from text heuristic runtime=\(AMRuntimeDiagnostics.executionEnvironmentDescription)",
                component: "Import"
            )
            return .loan
        }
        AMLogging.log(
            "DebtPayoff inferredType: no type inferred runtime=\(AMRuntimeDiagnostics.executionEnvironmentDescription)",
            component: "Import"
        )
        return nil
    }

    private func resolvedImportedStatementType(
        detectionType: StatementType?,
        previewType: StatementType?,
        pendingType: StatementType? = nil
    ) -> StatementType? {
        if detectionType == .bank {
            if pendingType == .loan || pendingType == .creditCard {
                return pendingType
            }
            if previewType == .loan || previewType == .creditCard {
                return previewType
            }
        }
        return detectionType ?? previewType ?? pendingType
    }

    private func latestBalance(for account: Account) -> Decimal? {
        return account.balanceSnapshots.sorted { $0.asOfDate > $1.asOfDate }.first?.balance
    }

    private func latestBalanceSnapshot(for account: Account) -> BalanceSnapshot? {
        account.balanceSnapshots.sorted { $0.asOfDate > $1.asOfDate }.first
    }

    private func ensureLatestBalanceSnapshot(for account: Account) -> BalanceSnapshot {
        if let snapshot = latestBalanceSnapshot(for: account) {
            return snapshot
        }
        let snapshot = BalanceSnapshot(asOfDate: Date(), balance: 0, account: account, isUserCreated: true, isUserModified: true)
        account.balanceSnapshots.append(snapshot)
        modelContext.insert(snapshot)
        return snapshot
    }

    private func syncImpactInputsToSelectedAccount() {
        guard let account = currentAccount() else {
            impactBalanceInput = ""
            impactAPRInput = ""
            impactTypicalPaymentInput = ""
            return
        }
        impactBalanceInput = latestBalance(for: account).map { formatCurrency($0.magnitude) } ?? ""
        if let apr = aprForImpact(for: account) {
            impactAPRInput = formatPercentInputValue(apr, scale: account.loanTerms?.aprScale)
            if !impactAPRInput.isEmpty, !impactAPRInput.contains("%") {
                impactAPRInput += "%"
            }
        } else {
            impactAPRInput = ""
        }
        impactTypicalPaymentInput = account.loanTerms?.paymentAmount.map(formatCurrency) ?? ""
    }

    private func saveImpactBalance(for account: Account, rawValue: String) {
        guard let parsed = MoneyParsing.parseDecimalInput(rawValue) else { return }
        let snapshot = ensureLatestBalanceSnapshot(for: account)
        let sign: Decimal = snapshot.balance < 0 ? -1 : 1
        snapshot.balance = parsed.magnitude * sign
        snapshot.isUserModified = true
        persistImpactAccountChange()
    }

    private func saveImpactAPR(for account: Account, rawValue: String) {
        guard let parsed = MoneyParsing.parsePercentInput(rawValue) else { return }
        let scale = inferredAPRScale(from: rawValue)
        var terms = account.loanTerms ?? LoanTerms()
        terms.apr = parsed
        terms.aprScale = scale
        account.loanTerms = terms

        let snapshot = ensureLatestBalanceSnapshot(for: account)
        snapshot.interestRateAPR = parsed
        snapshot.interestRateScale = scale
        snapshot.isUserModified = true
        persistImpactAccountChange()
    }

    private func saveImpactTypicalPayment(for account: Account, rawValue: String) {
        guard let parsed = MoneyParsing.parseDecimalInput(rawValue) else { return }
        var terms = account.loanTerms ?? LoanTerms()
        terms.paymentAmount = parsed
        account.loanTerms = terms
        impactPaymentAmount = NSDecimalNumber(decimal: parsed).doubleValue
        persistImpactAccountChange()
    }

    private func saveImpactDueDay(for account: Account, value: Int?) {
        var terms = account.loanTerms ?? LoanTerms()
        terms.paymentDayOfMonth = value
        account.loanTerms = terms
        persistImpactAccountChange()
    }

    private func saveImpactPaymentMode(for account: Account, mode: CreditCardPaymentMode) {
        account.creditCardPaymentMode = mode
        persistImpactAccountChange()
    }

    private func persistImpactAccountChange() {
        try? modelContext.save()
        NotificationCenter.default.post(name: .accountsDidChange, object: nil)
    }

    private func formatPercentInputValue(_ apr: Decimal, scale: Int?) -> String {
        var percentage = apr
        if percentage <= 1 { percentage *= 100 }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = min(max(scale ?? 2, 0), 4)
        formatter.maximumFractionDigits = min(max(scale ?? 2, 0), 4)
        return formatter.string(from: NSDecimalNumber(decimal: percentage)) ?? "\(percentage)"
    }

    private func aprForImpact(for account: Account) -> Decimal? {
        if let latestAPR = account.balanceSnapshots
            .sorted(by: { $0.asOfDate > $1.asOfDate })
            .first(where: { $0.interestRateAPR != nil })?
            .interestRateAPR {
            return latestAPR
        }
        return account.loanTerms?.apr
    }

    private func baselinePayment(for account: Account, balance: Decimal) -> Decimal? {
        if let payment = account.loanTerms?.paymentAmount, payment > 0 {
            return payment
        }
        if account.type == .creditCard {
            return max(balance * Decimal(string: "0.02")!, Decimal(25))
        }
        return nil
    }

    private struct PayoffImpactProjection {
        let monthlyPayment: Decimal
        let payoffDate: Date?
        let totalInterest: Decimal?
        let months: Int?
    }

    private func baselinePaymentAmount(for account: Account) -> Decimal? {
        guard let rawBalance = latestBalance(for: account) else { return nil }
        return baselinePayment(for: account, balance: rawBalance.magnitude)
    }

    private func paymentSliderRange(for account: Account) -> ClosedRange<Double> {
        let baseline = baselinePaymentAmount(for: account).map { NSDecimalNumber(decimal: $0).doubleValue } ?? 0
        let lower = max(0, floor((baseline * 0.5) / 25) * 25)
        let upper = max(100, ceil((baseline * 2.0 + 500) / 25) * 25)
        return lower...upper
    }

    private func syncImpactPaymentToSelectedAccount() {
        syncImpactInputsToSelectedAccount()
        guard let account = currentAccount(), let baseline = baselinePaymentAmount(for: account) else {
            impactPaymentAmount = 0
            return
        }
        impactPaymentAmount = NSDecimalNumber(decimal: baseline).doubleValue
    }

    private func payoffImpactProjection(for account: Account, monthlyPayment: Decimal?) -> PayoffImpactProjection? {
        guard let rawBalance = latestBalance(for: account) else { return nil }
        let balance = rawBalance.magnitude
        guard balance > 0,
              let apr = aprForImpact(for: account),
              let payment = monthlyPayment,
              payment > 0 else { return nil }

        return amortizedProjection(balance: balance, apr: apr, monthlyPayment: payment)
    }

    private func amortizedProjection(balance: Decimal, apr: Decimal, monthlyPayment: Decimal) -> PayoffImpactProjection {
        let principal = NSDecimalNumber(decimal: balance).doubleValue
        var annualRate = NSDecimalNumber(decimal: apr).doubleValue
        if annualRate > 1.0 { annualRate /= 100.0 }
        let payment = NSDecimalNumber(decimal: monthlyPayment).doubleValue
        guard principal > 0, payment > 0 else {
            return PayoffImpactProjection(monthlyPayment: monthlyPayment, payoffDate: nil, totalInterest: nil, months: nil)
        }

        let monthlyRate = annualRate / 12.0
        if monthlyRate > 0, payment <= principal * monthlyRate {
            return PayoffImpactProjection(monthlyPayment: monthlyPayment, payoffDate: nil, totalInterest: nil, months: nil)
        }

        var balanceRemaining = principal
        var interestPaid = 0.0
        var monthCount = 0
        while balanceRemaining > 0.005 && monthCount < 600 {
            let interest = max(0, balanceRemaining * monthlyRate)
            let principalPayment = min(payment - interest, balanceRemaining)
            if principalPayment <= 0 { break }
            interestPaid += interest
            balanceRemaining -= principalPayment
            monthCount += 1
        }

        let payoffDate = Calendar.current.date(byAdding: .month, value: monthCount, to: Date())
        return PayoffImpactProjection(
            monthlyPayment: monthlyPayment,
            payoffDate: payoffDate,
            totalInterest: Decimal(interestPaid),
            months: monthCount
        )
    }

    private func monthSavingsText(baseMonths: Int?, adjustedMonths: Int?) -> String? {
        guard let baseMonths, let adjustedMonths else { return nil }
        let saved = max(0, baseMonths - adjustedMonths)
        guard saved > 0 else { return "No time saved yet" }
        if saved < 12 { return "\(saved) mo faster" }
        let years = saved / 12
        let months = saved % 12
        if months == 0 { return "\(years) yr faster" }
        return "\(years) yr \(months) mo faster"
    }

    private func interestSavingsText(baseInterest: Decimal?, adjustedInterest: Decimal?) -> String? {
        guard let baseInterest, let adjustedInterest else { return nil }
        let saved = max(Decimal(0), baseInterest - adjustedInterest)
        return "Save \(formatCurrency(saved)) interest"
    }

    private func savingsSummaryText(
        baseMonths: Int?,
        adjustedMonths: Int?,
        baseInterest: Decimal?,
        adjustedInterest: Decimal?
    ) -> String? {
        let parts = [
            monthSavingsText(baseMonths: baseMonths, adjustedMonths: adjustedMonths),
            interestSavingsText(baseInterest: baseInterest, adjustedInterest: adjustedInterest)
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    private func formatCurrency(_ amount: Decimal) -> String {
        let formatter = AppFormatters.currencyFormatter()
        return formatter.string(from: NSDecimalNumber(decimal: amount)) ?? "\(amount)"
    }

    @MainActor
    private func deleteAccount(_ account: Account) {
        // If the deleted account is currently selected, clear selection so your onChange handler can pick a new one.
        if selectedAccountID == account.id {
            selectedAccountID = nil
            lastImportedURL = nil
        }

        removeImportMappings(for: account.id)
        modelContext.delete(account)
        do {
            try modelContext.save()
        } catch {
            // Reuse your existing error surface if you want
            importError = error
        }
    }

    private func removeImportMappings(for accountID: UUID) {
        let descriptor = FetchDescriptor<AccountImportMapping>(predicate: #Predicate { $0.accountID == accountID })
        guard let mappings = try? modelContext.fetch(descriptor), !mappings.isEmpty else { return }
        for mapping in mappings {
            modelContext.delete(mapping)
        }
        AMLogging.log("Removed \(mappings.count) import mapping(s) for deleted account id=\(accountID)", component: "DebtPayoffDetailView")
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

    @MainActor
    private func openFullImportReview(
        detection: IntakeDetection,
        url: URL,
        selectedDetectedAccounts: [DetectionReviewSheet.DetectedAccountSelection] = []
    ) {
        var det = detection
        det.type = selectedType
        det.institution = editedInstitution.trimmingCharacters(in: .whitespacesAndNewlines)
        lastDetection = det

        let fallbackInstitution = det.institution?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackAccountType = resolvedFallbackAccountType(from: selectedDetectedAccounts)
            ?? det.type?.toQuickIngestAccountType(bankSubtype: bankSubtype)?.toAccountType()
        let fallbackBalance = MoneyParsing.parseDecimalInput(balanceInput)
        let fallbackTypicalPayment = MoneyParsing.parseDecimalInput(monthlyPaymentInput)
        let fallbackAPR = MoneyParsing.parsePercentInput(aprPercentInput)
        let fallbackAPRScale = inferredAPRScale(from: aprPercentInput)

        let routedURL = stageURLToCaches(url)
        self.lastImportedURL = routedURL
        detectionSheetModel = nil
        isPreparingDetectionReview = false
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            if let fallbackAccountType {
                vm.newAccountType = fallbackAccountType
            }
            vm.userInstitutionName = fallbackInstitution ?? ""
            await coordinator.importURL(routedURL, hint: det.type, modelContext: modelContext, settings: settings)
            seedImportReviewFallbacks(
                institution: fallbackInstitution,
                accountType: fallbackAccountType,
                balance: fallbackBalance,
                typicalPayment: fallbackTypicalPayment,
                aprFraction: fallbackAPR,
                aprScale: fallbackAPRScale
            )
            applyDetectedAccountSelections(selectedDetectedAccounts)
        }
    }

    @MainActor
    private func openFullImportReview(for model: DetectionSheetModel) {
        openFullImportReview(detection: model.detection, url: model.url, selectedDetectedAccounts: detectedAccounts)
    }

    private func normalizedDetectedAccountKey(_ raw: String) -> String {
        normalizedBankSummaryLabel(raw)
    }

    private func resolvedFallbackAccountType(
        from selections: [DetectionReviewSheet.DetectedAccountSelection]
    ) -> Account.AccountType? {
        let importedSelections = selections.filter(\.shouldImport)
        guard importedSelections.count == 1, let selection = importedSelections.first else { return nil }
        let key = normalizedDetectedAccountKey(selection.id)
        switch key {
        case "loan":
            return .loan
        case "savings", "certificate":
            return .savings
        case "checking":
            return .checking
        case "cash":
            return .cash
        default:
            switch selection.statementType {
            case .loan: return .loan
            case .creditCard: return .creditCard
            case .bank: return .checking
            case .brokerage: return .brokerage
            }
        }
    }

    @MainActor
    private func applyDetectedAccountSelections(_ selections: [DetectionReviewSheet.DetectedAccountSelection]) {
        guard !selections.isEmpty, var staged = vm.staged else { return }

        let originalBalanceCount = staged.balances.count
        let originalTransactionCount = staged.transactions.count
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
        let soleImportedLabel = labelsToKeep.count == 1 ? labelsToKeep.first : nil
        let summaryByLabel = Dictionary(
            uniqueKeysWithValues: (importedPreview?.bankBalanceSummaries ?? []).map {
                (normalizedDetectedAccountKey($0.id), $0)
            }
        )

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

        for selection in importedSelections {
            let key = normalizedDetectedAccountKey(selection.id)
            guard !existingBalanceLabels.contains(key),
                  let endingBalance = summaryByLabel[key]?.endingBalance ?? selection.endingBalance else {
                continue
            }

            staged.balances.append(
                StagedBalance(
                    asOfDate: referenceDate,
                    balance: endingBalance,
                    interestRateAPR: importedPreview?.aprFraction,
                    interestRateScale: importedPreview?.aprScale,
                    typicalPaymentAmount: importedPreview?.typicalPayment,
                    include: true,
                    sourceAccountLabel: key
                )
            )
        }

        staged.transactions = staged.transactions.filter { transaction in
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

        if let resolvedType = resolvedFallbackAccountType(from: importedSelections) {
            staged.suggestedAccountType = resolvedType
            vm.newAccountType = resolvedType
        }
        

        AMLogging.log(
            "DebtPayoff detected-account filter — selected=\(Array(selectedLabels).sorted()) parserLabels=\(Array(parserLabels).sorted()) kept=\(Array(labelsToKeep).sorted()) balances \(originalBalanceCount)->\(staged.balances.count) transactions \(originalTransactionCount)->\(staged.transactions.count)",
            component: "DebtPayoffDetailView"
        )
        vm.staged = staged
    }

    @MainActor
    private func applyQuickIngestResult(_ result: QuickIngestResult, stagedURL: URL) {
        ingestedAccount = result.account
        selectedAccountID = result.account.id
        externalSelectedAccountID = result.account.id
        lastImportedURL = stagedURL

        if let payment = result.typicalPayment {
            monthlyPaymentInput = AppFormatters.currencyFormatter().string(from: NSDecimalNumber(decimal: payment)) ?? monthlyPaymentInput
        }

        if let apr = result.aprFraction {
            let nf = NumberFormatter()
            nf.numberStyle = .decimal
            nf.minimumFractionDigits = 2
            nf.maximumFractionDigits = max(2, result.aprScale ?? 2)
            let percent = apr * 100
            aprPercentInput = nf.string(from: NSDecimalNumber(decimal: percent)) ?? aprPercentInput
        }

        let absBalance = result.balance.magnitude
        balanceInput = AppFormatters.currencyFormatter().string(from: NSDecimalNumber(decimal: absBalance)) ?? balanceInput

        computePayoff(using: result.account)
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
        case .cash:
            return "default"
        case .brokerage:
            return "brokerage"
        case .property:
            return "default"
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

    // Binding that shows the sheet while an import is running or ready for review.
    private var isImportSheetPresented: Binding<Bool> {
        Binding(get: {
            !isPreparingDetectionReview &&
            detectionSheetModel == nil &&
            (vm.isImporting || vm.staged != nil || vm.mappingSession != nil)
        }, set: { presented in
            if !presented && !vm.isImporting {
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
                if let id = vm.selectedAccountID {
                    externalSelectedAccountID = id
                    let account = accounts.first(where: { $0.id == id })
                    routeImportedAccount(account)
                }
            }
        })
    }

    var body: some View {
        VStack(spacing: 16) {
            if debtAccounts.isEmpty {
                Text("Get started by adding your credit accounts")
                    .foregroundStyle(.secondary)
            }

            contentArea

            Divider().padding(.top, 4)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 32)
        .background(.background)
        .toolbar {
            impactKeyboardToolbar()
        }
        .safeAreaInset(edge: .bottom) {
            if isEditing {
                Color.clear
                    .frame(height: 44)
                    .allowsHitTesting(false)
            }
        }
        .onAppear {
            if let externalSelectedAccountID {
                selectedAccountID = externalSelectedAccountID
            }
            if selectedAccountID == nil {
                selectedAccountID = debtAccounts.first?.id
            }
            if let id = selectedAccountID {
                externalSelectedAccountID = id
                self.updateLastImportedURL(for: id)
            }
            syncImpactPaymentToSelectedAccount()
        }
        .onChange(of: accounts) { _, newValue in
            let updatedDebtAccounts = newValue.filter {
                switch $0.type {
                case .creditCard, .loan:
                    return true
                default:
                    return false
                }
            }
            if let externalSelectedAccountID,
               updatedDebtAccounts.contains(where: { $0.id == externalSelectedAccountID }),
               selectedAccountID != externalSelectedAccountID {
                selectedAccountID = externalSelectedAccountID
            }
            if selectedAccountID == nil {
                selectedAccountID = updatedDebtAccounts.first?.id
            } else if let selID = selectedAccountID, !updatedDebtAccounts.contains(where: { $0.id == selID }) {
                selectedAccountID = updatedDebtAccounts.first?.id
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
            if externalSelectedAccountID != id {
                externalSelectedAccountID = id
            }
            Task { @MainActor in
                if let id {
                    self.updateLastImportedURL(for: id)
                } else {
                    self.lastImportedURL = nil
                }
                syncImpactPaymentToSelectedAccount()
            }
        }
        .onChange(of: externalSelectedAccountID) { _, id in
            guard selectedAccountID != id else { return }
            if let id, accounts.contains(where: { $0.id == id }) {
                selectedAccountID = id
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                PlanToolbarButton("PDF", fixedWidth: 55) {
                    showStatementSheet = true
                }
                .disabled(currentAccount() == nil)
            }
            ToolbarItem(placement: .topBarTrailing) {
                PlanToolbarButton(manualAddButtonTitle) {
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
                    openFullImportReview(for: model)
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
            detectionReviewSheetContent(model: model)
                .applySheetSizing()
        }
#else
        .sheet(item: $detectionSheetModel) { model in
            detectionReviewSheetContent(model: model)
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
                    externalSelectedAccountID = account.id
                    self.updateLastImportedURL(for: account.id)
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
                .interactiveDismissDisabled(vm.isImporting)
        }
        .sheet(isPresented: $showStatementSheet) {
            statementSheetContent
        }
        .onChange(of: pendingExternal?.id, initial: true) { _, _ in
            guard let pending = pendingExternal else { return }
            isPreparingDetectionReview = true
            Task {
                let stagedURL = stageURLToCaches(pending.url)
                let classifier = StatementIntakeClassifier()
                let detection = await classifier.classify(url: stagedURL)
                let preview = await extractImportedPreview(from: stagedURL, hint: detection.type ?? pending.type)
                await MainActor.run {
                    self.lastDetection = detection
                    self.editedInstitution = detection.institution ?? preview?.institution ?? pending.institution ?? ""
                    self.selectedType = resolvedImportedStatementType(
                        detectionType: detection.type,
                        previewType: preview?.statementType,
                        pendingType: pending.type
                    )
                    self.importedPreview = preview
                    self.detectedAccounts = buildDetectedAccounts(from: preview)
                    self.bankSubtype = nil
                    self.applyImportedPreviewToInputs(preview)
                    let seededDetection = IntakeDetection(
                        type: self.selectedType,
                        institution: self.editedInstitution,
                        confidence: detection.confidence
                    )
                    self.detectionSheetModel = DetectionSheetModel(
                        detection: seededDetection,
                        url: stagedURL,
                        routeConfirmationText: "Opened as Liability Accounts"
                    )
                    self.isPreparingDetectionReview = false
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
