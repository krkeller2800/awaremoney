//
//  ReviewImportView.swift
//  DebtScope
//
//  Created by Karl Keller on 1/23/26.
//

import SwiftUI
import SwiftData
import UIKit

struct ReviewImportView: View {
    private struct ImportedBankBalanceSummary: Identifiable {
        let id: String
        let label: String
        let beginningBalance: Decimal?
        let endingBalance: Decimal?
    }

    var staged: StagedImport
    @ObservedObject var vm: ImportViewModel
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dismiss) private var dismiss
    private var isRegularWidth: Bool { horizontalSizeClass == .regular }
    @Query(sort: [SortDescriptor(\Account.createdAt)]) private var accounts: [Account]
    @State private var selectedAccountId: UUID? = nil
    @State private var showPDFSheet = false
    @State private var showHelpSheet = false
    @State private var typicalPaymentInput: String = ""
    @State private var typicalPaymentParsed: Decimal? = nil
    @State private var aprInput: String = ""
    @State private var aprScale: Int? = nil
    @State private var pendingStartingBalance: Decimal? = nil
    @State private var scrollProxy: ScrollViewProxy? = nil
    @State private var highlightTarget: String? = nil
    @State private var routingAnalysis: RoutingAnalysis? = nil
    @State private var showRoutingSheet: Bool = false
    @State private var lastAnalyzedSource: String? = nil
    @State private var routedAccountIDs: [UUID] = []
    @State private var routingOverrides: [String: RoutingCandidate.Action] = [:]
    @State private var routingGlobalTargetMode: Int = 0
    @State private var routingPreviewEffective: [String: RoutingCandidate.Action] = [:]
    @State private var routingPreviewInstitution: String? = nil
    @State private var pendingStatementCheck: StatementCheckResult? = nil
    @State private var statementCheckDetailsResult: StatementCheckResult? = nil
    @State private var acceptedStatementCheckKey: String? = nil
    @State private var isApprovingSave = false
    @State private var importLimitReached = false
    @State private var showImportLimitAlert = false
    @State private var showPaywall = false
    @State private var childIsEditing: Bool = false
    private var isEditing: Bool { focusedField != nil || childIsEditing }
    @FocusState private var focusedField: FocusedField?
    private enum FocusedField: Hashable { case typicalPayment, apr, startingBalance, balance(Int) }
    
    private var isPad: Bool {
#if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad
#else
        return false
#endif
    }
    
    private var isQFXSource: Bool {
        let lower = staged.sourceFileName.lowercased()
        return lower.hasSuffix(".qfx") || lower.hasSuffix(".ofx") || lower.hasSuffix(".ofc") || lower.hasSuffix(".qbo")
    }

    private var isPDFSource: Bool {
        staged.sourceFileName.lowercased().hasSuffix(".pdf")
    }

    private var hasStagedPreviewData: Bool {
        return !staged.transactions.isEmpty || !staged.balances.isEmpty || !staged.holdings.isEmpty
    }

    private var visibleCompletenessIssues: [ImportViewModel.CompletenessIssue] {
        let issues = vm.computeCompletenessIssues()
        if staged.transactions.isEmpty {
            return issues
        }
        return issues.filter { $0.title == "Statement cannot be verified" }
    }

    private var visibleHasBlockingCompletenessIssues: Bool {
        visibleCompletenessIssues.contains { $0.severity == .required }
    }

    private var currentStagedForReview: StagedImport {
        vm.staged ?? staged
    }

    private var currentStatementCheckDecisionKey: String {
        StatementCheckService.decisionKey(for: currentStagedForReview)
    }

    private var statementCheckSuccessMessage: String? {
        guard vm.newAccountType != .loan else { return nil }
        guard case .balanced = StatementCheckService.status(staged: currentStagedForReview) else { return nil }
        return "The imported transactions reconcile to the beginning and ending balances."
    }

    private var currentStatementCheckResult: StatementCheckResult? {
        guard isPDFSource, vm.newAccountType != .loan else { return nil }
        return StatementCheckService.evaluate(staged: currentStagedForReview)
    }

    private var statementCheckSnapshotOnlyMessage: String? {
        guard currentStatementCheckResult != nil else { return nil }
        if currentStagedForReview.balances.contains(where: { $0.include }) {
            return "Balances only will be saved. Import CSV/QIF/etc for transactions."
        }
        return "Import CSV/QIF/etc for transactions."
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                Group {
                    if isRegularWidth {
                        VStack(spacing: 12) {
                            HStack(spacing: 0) {
                                mainList
                                    .containerRelativeFrame(.horizontal, count: 2, spacing: 0)
                                    .frame(maxHeight: .infinity)
                                
                                NavigationStack {
                                    pdfPane
                                }
                                .containerRelativeFrame(.horizontal, count: 2, spacing: 0)
                                .frame(maxHeight: .infinity)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .overlay(alignment: .center) {
                                Rectangle()
                                    .fill(.separator)
                                    .frame(width: 1)
                                    .frame(maxHeight: .infinity)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        mainList
                    }
                }
                if vm.isImporting {
                    Color.black.opacity(0.2)
                        .ignoresSafeArea()
                    ProgressView("Importing…")
                        .progressViewStyle(.circular)
                        .padding(16)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .navigationTitle("Review Import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showHelpSheet = true
                    } label: {
                        Image(systemName: "questionmark.circle")
                    }
                    .accessibilityLabel("What Approve and Save does")
                }
                ToolbarItem(placement: .topBarLeading) {
                    if (staged.sourceFileName.lowercased().hasSuffix(".pdf") || hasStagedPreviewData) {
                        PlanToolbarButton(staged.sourceFileName.lowercased().hasSuffix(".pdf") ? "View PDF" : "View Trans", fixedWidth: 90) {
                            AMLogging.log("ReviewImportView: View Statement tapped — filename=\(staged.sourceFileName)", component: "ReviewImportView")
                            showPDFSheet = true
                        }
//                        label: {
//                            HStack(spacing: 6) {
//                                Text(staged.sourceFileName.lowercased().hasSuffix(".pdf") ? "View PDF" : "View Trans")
//                                Image(systemName: "doc.text.magnifyingglass")
//                            }
//                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .onPreferenceChange(RoutingChildEditingKey.self) { value in
                childIsEditing = value
            }
            .onAppear {
                let hasStaged = (vm.staged != nil)
                let balancesCount = vm.staged?.balances.count ?? 0
                let hasSentinel = vm.staged?.balances.contains(where: { ($0.sourceAccountLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "__typical_payment__" }) ?? false
                AMLogging.log("ReviewImportView: top-level onAppear — hasStaged=\(hasStaged) balances=\(balancesCount) hasSentinel=\(hasSentinel) typicalPaymentInput='\(typicalPaymentInput)' parsed=\(String(describing: typicalPaymentParsed))", component: "ReviewImportView")
                seedTypicalPaymentFromSentinelIfNeeded()
                computeRoutingAnalysisIfNeeded()
                refreshPendingStatementCheckIfNeeded()
            }
            .onChange(of: currentStatementCheckDecisionKey) { _, _ in
                refreshPendingStatementCheckIfNeeded()
            }
            .safeAreaInset(edge: .bottom) {
                Group {
                    if vm.isImporting {
                        EmptyView().frame(height: 0)
                    } else if isEditing {
                        EditingAccessoryBar(
                            canGoPrevious: canGoPrevious,
                            canGoNext: canGoNext,
                            onPrevious: { accessoryPrevious() },
                            onNext: { accessoryNext() },
                            onDone: { commitAndDismissKeyboard() }
                        )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else {
                        bottomBar
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.snappy, value: isEditing)
                .animation(.snappy, value: vm.isImporting)
            }
            .onChange(of: focusedField) { _, newValue in
                switch newValue {
                case .some(.typicalPayment), .some(.apr):
                    selectAllInFirstResponder()
                case .some(.balance(_)):
                    selectAllInFirstResponder()
                case .some(.startingBalance):
                    selectAllInFirstResponder()
                default:
                    break
                }
            }
            .onDisappear {
                // Ensure institution does not carry over to the next import
                vm.userInstitutionName = ""
            }
        }
        .sheet(isPresented: $showPDFSheet) {
            NavigationStack {
                if let url = resolvedPDFURL() {
                    ZStack(alignment: .topTrailing) {
                        PDFKitView(url: url)
                            .ignoresSafeArea()
                        DismissOverlay()
                            .padding(.top, 12)
                            .padding(.trailing, 12)
                    }
                } else if hasStagedPreviewData {
                    ZStack(alignment: .topTrailing) {
                        StatementPreviewView(staged: staged)
                            .ignoresSafeArea()
                        DismissOverlay()
                            .padding(.top, 12)
                            .padding(.trailing, 12)
                    }
                } else {
                    ZStack(alignment: .topTrailing) {
                        Text("File: \(staged.sourceFileName)")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .center)
                        ContentUnavailableView(
                            "Statement Viewer",
                            systemImage: "doc.richtext",
                            description: Text("Original PDF preview isn't available yet.")
                        )
                        DismissOverlay()
                            .padding(.top, 12)
                            .padding(.trailing, 12)
                    }
                    .padding()
                }
            }
            .navigationTitle("View Statement")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showPDFSheet = false }
                }
            }
            .presentationDetents([.large])
            .applySheetSizing()
        }
        .sheet(item: $statementCheckDetailsResult) { result in
            StatementCheckSheet(
                result: result,
                currencyCode: settings.currencyCode,
                isReadOnly: true,
                onImportBalancesOnly: applyStatementCheckBalancesOnly,
                onExcludeProblemTransactions: applyStatementCheckExcludeFlaggedTransactions,
                onContinueAnyway: acceptPendingStatementCheck,
                onCancel: { statementCheckDetailsResult = nil }
            )
            .presentationDetents([.large])
            .applySheetSizing()
        }
//        .sheet(isPresented: $showRoutingSheet) {
//            if let staged = vm.staged {
//                let service = ImportRoutingService()
//                let result = service.buildPlans(staged: staged, context: modelContext)
//                RoutingConfirmationView(
//                    analysis: result.analysis,
//                    plans: result.plans,
//
//                    // NEW: preload with any previously inputted values
//                    initialOverrides: routingOverrides,
//                    initialSelectedInstitution: {
//                        let trimmed = vm.userInstitutionName.trimmingCharacters(in: .whitespacesAndNewlines)
//                        return trimmed.isEmpty ? result.analysis.institution : trimmed
//                    }(),
//                    initialGlobalTargetMode: routingGlobalTargetMode,
//
//                    onConfirm: { overrides, selectedInstitution in
//                        AMLogging.log("ReviewImportView: Routing overrides confirmed — count=\(overrides.count)", component: "ReviewImportView")
//                        AMLogging.log("ReviewImportView: Routing selected institution — value=\(selectedInstitution ?? "nil")", component: "ReviewImportView")
//
//                        // Persist chosen institution into VM so it preloads next time
//                        if let inst = selectedInstitution?.trimmingCharacters(in: .whitespacesAndNewlines), !inst.isEmpty {
//                            self.vm.userInstitutionName = inst
//                            AMLogging.log("ReviewImportView: Persisted selected institution to VM — value=\(inst)", component: "ReviewImportView")
//                        }
//
//                        // NEW: remember the user’s overrides so the sheet preloads next time
//                        self.routingOverrides = overrides
//
//                        // NEW: remember the global target mode based on whether all overrides choose Create New
//                        let allCreateNew = overrides.values.allSatisfy {
//                            if case .createNew = $0 { return true } else { return false }
//                        }
//                        self.routingGlobalTargetMode = allCreateNew ? 1 : 0
//
//                        // Apply user-selected overrides to the routed plans (existing code)
//                        let overriddenPlans = service.applyOverrides(to: result.plans, overrides: overrides)
//
//                        // Resolve institution for account creation/mapping (existing code)
//                        let resolvedInstitution = (selectedInstitution?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
//                        ? selectedInstitution
//                        : result.analysis.institution
//
//                        // Resolve or create accounts for each overridden plan (existing code)
//                        do {
//                            let labelToAccount = try service.resolveAccounts(
//                                for: overriddenPlans,
//                                institution: resolvedInstitution,
//                                currencyCode: settings.currencyCode,
//                                context: modelContext
//                            )
//
//                            AMLogging.log("ReviewImportView: Resolved accounts for routing — mapped \(labelToAccount.count) label(s)", component: "ReviewImportView")
//
//                            // Store routed accounts IDs (existing code)
//                            let uniqueAccounts: Set<UUID> = Set(labelToAccount.values.map { $0.id })
//                            self.routedAccountIDs = Array(uniqueAccounts)
//
//                            if uniqueAccounts.count == 1, let onlyId = uniqueAccounts.first, let anyAccount = labelToAccount.values.first {
//                                self.selectedAccountId = onlyId
//                                self.vm.selectedAccountID = onlyId
//                                self.vm.newAccountType = anyAccount.type
//                                AMLogging.log("ReviewImportView: Auto-selected account from routing — id=\(onlyId) name=\(anyAccount.name)", component: "ReviewImportView")
//                            } else {
//                                AMLogging.log("ReviewImportView: Multiple accounts resolved from routing — leaving selection unset", component: "ReviewImportView")
//                            }
//
//                            // Persist mappings (existing code)
//                            service.persistMappingsAfterSave(
//                                institution: resolvedInstitution,
//                                labelToAccount: labelToAccount,
//                                plans: overriddenPlans,
//                                context: modelContext
//                            )
//                            AMLogging.log("ReviewImportView: Persisted import mappings for routing — labels=\(labelToAccount.keys.count)", component: "ReviewImportView")
//                        } catch {
//                            AMLogging.error("ReviewImportView: Failed to resolve accounts for routing — \(error.localizedDescription)", component: "ReviewImportView")
//                        }
//
//                        // Dismiss the routing sheet (existing code)
//                        showRoutingSheet = false
//                    },
//                    onCancel: {
//                        // User canceled routing; cancel the entire review since routing isn't defined
//                        showRoutingSheet = false
//                        vm.staged = nil
//                        vm.infoMessage = nil
//                        typicalPaymentInput = ""
//                        vm.userInstitutionName = ""
//                        routedAccountIDs = []
//                    }
//                )
//            } else {
//                NavigationStack { ContentUnavailableView("No routing info", systemImage: "questionmark.circle") }
//            }
//        }
        .sheet(isPresented: $showHelpSheet) {
            ReviewImportHelpView()
                .presentationDetents([.medium])
        }
        .alert("Free Imports Used", isPresented: $showImportLimitAlert) {
            Button("Purchase Lifetime") {
                showPaywall = true
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(importLimitMessage)
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView()
                .environmentObject(PurchaseManager.shared)
        }
    }
    
    private var mainList: some View {
        ScrollViewReader { proxy in
            Form {
                if !visibleCompletenessIssues.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Image(systemName: visibleHasBlockingCompletenessIssues ? "exclamationmark.triangle.fill" : "exclamationmark.circle")
                                    .foregroundStyle(visibleHasBlockingCompletenessIssues ? .orange : .yellow)
                                Text("Review required")
                                    .font(.subheadline.weight(.semibold))
                            }
                            Text("We couldn't parse your statement completely. Please verify and complete the fields below." + (UIDevice.type == "iPhone" ? " Tap '\(staged.sourceFileName.lowercased().hasSuffix(".pdf") ? "view PDF" : "view statement")' for reference." : ""))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Text("Tap an item to jump to the field below.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(visibleCompletenessIssues) { issue in
                                    Button {
#if canImport(UIKit)
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
#endif
                                        performChecklistAction(for: issue.title)
                                    } label: {
                                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                                            Image(systemName: issue.severity == .required ? "exclamationmark.triangle" : "exclamationmark.circle")
                                                .foregroundStyle(issue.severity == .required ? .orange : .yellow)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(issue.title)
                                                    .font(.footnote.weight(.semibold))
                                                if let detail = issue.detail { Text(detail).font(.caption2).foregroundStyle(.secondary) }
                                            }
                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .font(.footnote.weight(.semibold))
                                                .foregroundStyle(.tertiary)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(ChecklistRowButtonStyle())
                                    .hoverEffect(.highlight)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowBackground(Color.yellow.opacity(0.08))
                    
                }

                if let duplicateImportWarning {
                    Section {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)

                            Text(duplicateImportWarning)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowBackground(Color.orange.opacity(0.08))
                }

                Section {
                    EmptyView()
                } header: {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("File: \(staged.sourceFileName)")
                            .font(.callout)
                            .padding(.top, 10)
                            .frame(maxWidth: .infinity, alignment: .center)

                        HStack {
                            Text("Transactions: \(staged.transactions.count)")
                            if !staged.holdings.isEmpty {
                                Text("Holdings: \(staged.holdings.count)")
                            }
                            if !staged.balances.isEmpty {
                                Text("Balances: \(staged.balances.count)")
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 10)
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .foregroundStyle(.primary)
                }
                .onAppear(perform: onAccountSectionAppear)

                if let statementCheckSuccessMessage {
                    Section {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Statement totals match")
                                    .font(.footnote.weight(.semibold))
                                Text(statementCheckSuccessMessage)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } else if let message = statementCheckSnapshotOnlyMessage, let result = currentStatementCheckResult {
                    Section {
                        Button {
                            statementCheckDetailsResult = result
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "info.circle.fill")
                                    .foregroundStyle(.orange)
                                Text("\(message) Tap to view reconciliation.")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)
                    }
                    .listRowBackground(Color.orange.opacity(0.08))
                }

                Group {
                    if let currentStaged = vm.staged {
                        Section {
                            let service = ImportRoutingService()
                            let result = service.buildPlans(staged: currentStaged, context: modelContext)

                            RoutingConfirmationView(
                                analysis: result.analysis,
                                plans: result.plans,
                                overrides: $routingOverrides,
                                selectedInstitution: Binding<String?>(
                                    get: {
                                        // Prefer any user-entered value; otherwise analysis
                                        let trimmed = vm.userInstitutionName.trimmingCharacters(in: .whitespacesAndNewlines)
                                        return trimmed.isEmpty ? result.analysis.institution : vm.userInstitutionName
                                    },
                                    set: { newVal in
                                        vm.userInstitutionName = newVal ?? ""
                                    }
                                ),
                                globalTargetMode: $routingGlobalTargetMode,
                                onPreviewUpdate: { effective, selectedInstitution in
                                    // Capture the preview-only effective actions and institution without persisting
                                    routingPreviewEffective = effective
                                    routingPreviewInstitution = selectedInstitution
                                },
                                onCancel: {
                                    // No-op in embedded mode; parent controls dismissal
                                }
                            )
                        } header: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Routing")
                                Text("Verify the institution and account type before saving.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textCase(nil)
                            }
                        }
                    }
                }
                .onPreferenceChange(RoutingChildEditingKey.self) { value in
                    childIsEditing = value
                }
                .id("routingSectionTop")

                if !importedBankBalanceSummaries.isEmpty {
                    Section {
                        ForEach(importedBankBalanceSummaries) { summary in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(summary.label)
                                    .font(.subheadline.weight(.semibold))

                                if let beginningBalance = summary.beginningBalance {
                                    LabeledContent("Beginning balance") {
                                        Text(currencyFormatter.string(from: NSDecimalNumber(decimal: beginningBalance)) ?? "\(beginningBalance)")
                                            .monospacedDigit()
                                    }
                                }

                                if let endingBalance = summary.endingBalance {
                                    LabeledContent("Ending balance") {
                                        Text(currencyFormatter.string(from: NSDecimalNumber(decimal: endingBalance)) ?? "\(endingBalance)")
                                            .monospacedDigit()
                                    }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    } header: {
                        Text("Statement Balances")
                    } footer: {
                        Text("These balances are grouped by account from the imported statement.")
                    }
                }
              
                // Loan Terms — single place to edit Typical Payment and APR
                if vm.newAccountType == .loan || vm.newAccountType == .creditCard {
                    Section("Loan Terms") {
                        VStack {
                            LabeledContent("Typical Payment") {
                                HStack(spacing: 6) {
                                    TextField("0.00", text: $typicalPaymentInput)
                                        .multilineTextAlignment(.trailing)
                                        .keyboardType(.decimalPad)
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()
                                        .onChange(of: typicalPaymentInput, initial: false) { _, newValue in
                                            typicalPaymentParsed = parseCurrencyInput(newValue)
                                        }
                                        .focused($focusedField, equals: .typicalPayment)
                                        .id("typicalPaymentField")
                                        .submitLabel(.next)
                                        .onSubmit { moveFocus(1) }
                                        .onTapGesture { selectAllInFirstResponder() }
                                        .background(highlightTarget == "typicalPaymentField" ? Color.accentColor.opacity(0.12) : .clear)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                    Button {
                                        focusedField = .typicalPayment
                                        selectAllInFirstResponder()
                                    } label: {
                                        Image(systemName: "pencil")
                                            .font(.caption)
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel("Edit typical payment")
                                }
                            }
                            Text("Used for payoff estimates and budget projections.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            
                            LabeledContent("Interest Rate (APR)") {
                                HStack(spacing: 6) {
                                    TextField("0.00", text: $aprInput)
                                        .multilineTextAlignment(.trailing)
                                        .keyboardType(.decimalPad)
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()
                                        .focused($focusedField, equals: .apr)
                                        .id("aprField")
                                        .submitLabel(.done)
                                        .onSubmit { commitAndDismissKeyboard() }
                                        .onTapGesture { selectAllInFirstResponder() }
                                        .background(highlightTarget == "aprField" ? Color.accentColor.opacity(0.12) : .clear)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                    Button {
                                        focusedField = .apr
                                        selectAllInFirstResponder()
                                    } label: {
                                        Image(systemName: "pencil")
                                            .font(.caption)
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel("Edit APR")
                                }
                            }
                            Text("Enter as a percent (e.g., 19.99 for 19.99%).")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                
                // Starting balance prompt
                if (vm.staged?.balances.isEmpty ?? true), let earliestDate = vm.staged?.transactions.map({ $0.datePosted }).min() {
                    StartingBalanceInlineView(
                        asOfDate: earliestDate,
                        onSet: { dec, pickedDate in
                            let sb = StagedBalance(asOfDate: pickedDate, balance: dec)
                            vm.staged?.balances.append(sb)
                        },
                        focusedField: $focusedField,
                        focusedCase: .startingBalance,
                        onNext: { moveFocus(1) },
                        onAmountChange: { dec in
                            pendingStartingBalance = dec
                        }
                    )
                    .id("startingBalancePrompt")
                    .background(highlightTarget == "startingBalancePrompt" ? Color.accentColor.opacity(0.12) : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                
                // Fallback: when there are no transactions and no balances, allow entering an ending balance manually
                if (vm.staged?.transactions.isEmpty ?? true) && (vm.staged?.balances.isEmpty ?? true) {
                    StartingBalanceInlineView(
                        asOfDate: Date(),
                        onSet: { dec, pickedDate in
                            let sb = StagedBalance(asOfDate: pickedDate, balance: dec)
                            vm.staged?.balances.append(sb)
                            AMLogging.log("ReviewImportView: User added ending balance fallback — value=\(dec) date=\(pickedDate)", component: "ReviewImportView")
                        },
                        focusedField: $focusedField,
                        focusedCase: .startingBalance,
                        onNext: { moveFocus(1) },
                        title: "Ending Balance",
                        messageOverride: "Enter the ending balance and choose the statement date.",
                        onAmountChange: { dec in
                            pendingStartingBalance = dec
                        }
                    )
                    .id("startingBalancePrompt")
                    .background(highlightTarget == "startingBalancePrompt" ? Color.accentColor.opacity(0.12) : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                
                if let balances = vm.staged?.balances, !balances.isEmpty {
                    Section("Balances") {
                        VStack {
                            ForEach(balances.indices, id: \.self) { idx in
                                let b = balances[idx]
                                HStack(alignment: .top) {
                                    Toggle("", isOn: balanceIncludeBinding(for: idx))
                                        .labelsHidden()
                                    
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack(spacing: 2) {
                                            DatePicker("As of", selection: balanceDateBinding(for: idx), displayedComponents: .date)
                                                .labelsHidden()
                                                .datePickerStyle(.compact)
                                            //                                            Image(systemName: "pencil")
                                            //                                                .font(.caption)
                                            //                                                .foregroundStyle(.tertiary)
                                            //                                                .accessibilityHidden(true)
                                            Spacer()
                                            TextField("0.00", text: balanceAmountTextBinding(for: idx))
                                                .lineLimit(1)
                                                .minimumScaleFactor(0.75)
                                                .multilineTextAlignment(.trailing)
                                                .keyboardType(.decimalPad)
                                                .textInputAutocapitalization(.never)
                                                .autocorrectionDisabled()
                                                .focused($focusedField, equals: .balance(idx))
                                                .id("balanceField-\(idx)")
                                                .submitLabel(.next)
                                                .onSubmit { moveFocus(1) }
                                                .onTapGesture { selectAllInFirstResponder() }
                                                .background(highlightTarget == "balanceField-\(idx)" ? Color.accentColor.opacity(0.12) : .clear)
                                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                            Button {
                                                focusedField = .balance(idx)
                                                selectAllInFirstResponder()
                                            } label: {
                                                Image(systemName: "pencil")
                                                    .font(.caption)
                                            }
                                            .buttonStyle(.plain)
                                            .foregroundStyle(.secondary)
                                            .accessibilityLabel("Edit balance amount")
                                        }
                                        if let label = b.sourceAccountLabel, !label.isEmpty {
                                            Text(label.capitalized)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.secondary.opacity(0.12))
                                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                        }
                                    }
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        if var staged = vm.staged, idx < staged.balances.count {
                                            staged.balances.remove(at: idx)
                                            vm.staged = staged
                                        }
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                            Button {
                                var staged = vm.staged ?? StagedImport(parserId: "manual.user", sourceFileName: "Manual Entry", suggestedAccountType: vm.newAccountType, transactions: [], holdings: [], balances: [])
                                let newBalance = StagedBalance(asOfDate: Date(), balance: 0, interestRateAPR: nil, interestRateScale: nil, include: true, sourceAccountLabel: nil)
                                staged.balances.append(newBalance)
                                vm.staged = staged
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "plus.circle")
                                    Text("Add Balance")
                                }
                            }
                            .id("addBalanceButton")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }

                // Holdings
                if !staged.holdings.isEmpty {
                    Section("Holdings") {
                        ForEach(staged.holdings.indices, id: \.self) { idx in
                            let h = staged.holdings[idx]
                            HStack {
                                Toggle("", isOn: holdingIncludeBinding(for: idx))
                                    .labelsHidden()
                                Text("\(h.symbol) — \(h.quantity.description)")
                                Spacer()
                                if let mv = h.marketValue {
                                    Text(mv as NSNumber, formatter: currencyFormatter)
                                }
                            }
                        }
                    }
                }

                // Transactions preview
                if !staged.transactions.isEmpty {
                    Section("Transactions") {
                        ForEach(staged.transactions.indices, id: \.self) { idx in
                            let t = staged.transactions[idx]
                            HStack(alignment: .firstTextBaseline) {
                                Toggle("", isOn: transactionIncludeBinding(for: idx))
                                    .labelsHidden()

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(t.payee)
                                    HStack(spacing: 6) {
                                        if let acct = t.sourceAccountLabel, !acct.isEmpty {
                                            Text(acct.capitalized)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.secondary.opacity(0.12))
                                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                        }
                                        Text(t.datePosted, style: .date)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Text(t.amount as NSNumber, formatter: currencyFormatter)
                                    .foregroundStyle(t.amount < 0 ? .red : .primary)
                            }
                        }
                    }
                }
                
                Section() {
                    if importLimitReached {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                                Text("You have used all 4 free imports. Purchase Lifetime to continue importing statements.")
                                    .font(.footnote)
                                    .foregroundStyle(.primary)
                            }
                            Button("Purchase Lifetime") {
                                showPaywall = true
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(.vertical, 2)
                    } else if let err = vm.errorMessage, !err.isEmpty {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.red)
                            Text(err)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    VStack {
                        Text("Notes")
                            .frame(maxWidth: .infinity,alignment: .leading)
                        if let info = vm.infoMessage, !info.isEmpty {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "info.circle")
                                    .foregroundStyle(.blue)
                                Text(info)
                                    .font(.footnote)
                            }
                            .padding(.vertical, 2)
                        }
                        if staged.transactions.isEmpty && (vm.hasBlockingCompletenessIssues || !vm.computeCompletenessIssues().isEmpty) {
                            Text("Verify and correct all fields before saving.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    //                .foregroundStyle(.primary)
                }
            }
            .onAppear { self.scrollProxy = proxy }
            .scrollDismissesKeyboard(.interactively)
            .listRowSpacing(6)
            .listSectionSpacing(.compact)
            .environment(\.defaultMinListRowHeight, 34)
            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
        }
    }
    
    private var duplicateImportWarning: String? {
        guard let balances = vm.staged?.balances.filter(\.include), !balances.isEmpty else {
            return nil
        }

        for balance in balances {
            let candidateBalances = duplicateCandidateBalances(for: balance.balance)
            let balanceDay = Calendar.current.startOfDay(for: balance.asOfDate)

            for account in accounts where account.type == vm.newAccountType {
                let matchingSnapshot = account.balanceSnapshots.first { snapshot in
                    Calendar.current.startOfDay(for: snapshot.asOfDate) == balanceDay
                    && candidateBalances.contains(snapshot.balance)
                }

                if matchingSnapshot != nil {
                    return "This statement appears to have already been imported. The same account type, statement date, and balance already exist."
                }
            }
        }

        return nil
    }

    private func duplicateCandidateBalances(for amount: Decimal) -> Set<Decimal> {
        switch vm.newAccountType {
        case .creditCard, .loan:
            let magnitude = amount < 0 ? -amount : amount
            return [amount, -magnitude]
        default:
            return [amount]
        }
    }

    private var importLimitMessage: String {
        "You have used all 4 free imports. Purchase Lifetime to continue importing statements."
    }

    private func showFreeImportLimitMessage() {
        importLimitReached = true
        vm.errorMessage = nil
        isApprovingSave = false
        showImportLimitAlert = true
    }

    private func applyDefaultStatementCheckRulesIfNeeded(to staged: StagedImport) -> StagedImport {
        guard isPDFSource,
              vm.newAccountType != .loan,
              let result = StatementCheckService.evaluate(staged: staged) else {
            return staged
        }

        let message = staged.balances.contains(where: { $0.include })
            ? "Snapshot saved. Import CSV/QIF for transactions."
            : "Import CSV/QIF for transactions."
        var updated = staged
        for index in updated.transactions.indices {
            updated.transactions[index].include = false
        }

        vm.staged = updated
        vm.infoMessage = message
        pendingStatementCheck = result
        acceptedStatementCheckKey = result.decisionKey
        computeRoutingAnalysisIfNeeded()
        AMLogging.log("ReviewImportView: PDF transactions skipped by default reconciliation rule — issues=\(result.issues.count) warnings=\(result.warnings.count)", component: "ReviewImportView")
        return updated
    }

    private func shouldBlockForFreeImportLimit(_ staged: StagedImport) -> Bool {
        staged.parserId != "manual.user" && !PurchaseManager.shared.isPremiumUnlocked
    }

    private func requestStatementCheckIfNeeded(for staged: StagedImport) -> Bool {
        guard vm.newAccountType != .loan else {
            clearPendingStatementCheck()
            return false
        }
        guard let result = StatementCheckService.evaluate(staged: staged),
              !result.issues.isEmpty,
              acceptedStatementCheckKey != result.decisionKey else {
            clearPendingStatementCheck()
            return false
        }

        pendingStatementCheck = result
        statementCheckDetailsResult = result
        isApprovingSave = false
        AMLogging.log("ReviewImportView: Statement check interrupted save — issues=\(result.issues.count)", component: "ReviewImportView")
        return true
    }

    private func refreshPendingStatementCheckIfNeeded() {
        guard pendingStatementCheck != nil || statementCheckDetailsResult != nil else { return }
        guard vm.newAccountType != .loan,
              let result = StatementCheckService.evaluate(staged: currentStagedForReview),
              !result.issues.isEmpty,
              acceptedStatementCheckKey != result.decisionKey else {
            clearPendingStatementCheck()
            return
        }

        pendingStatementCheck = result
        statementCheckDetailsResult = result
    }

    private func clearPendingStatementCheck() {
        pendingStatementCheck = nil
        statementCheckDetailsResult = nil
    }

    private func acceptPendingStatementCheck() {
        guard let pendingStatementCheck else { return }
        acceptedStatementCheckKey = pendingStatementCheck.decisionKey
        self.pendingStatementCheck = nil
        statementCheckDetailsResult = nil
        isApprovingSave = false
    }

    private func applyStatementCheckBalancesOnly() {
        guard var staged = vm.staged else { return }
        for index in staged.transactions.indices {
            staged.transactions[index].include = false
        }
        vm.staged = staged
        acceptedStatementCheckKey = StatementCheckService.decisionKey(for: staged)
        pendingStatementCheck = nil
        statementCheckDetailsResult = nil
        isApprovingSave = false
        computeRoutingAnalysisIfNeeded()
    }

    private func applyStatementCheckExcludeFlaggedTransactions() {
        guard var staged = vm.staged, let pendingStatementCheck else { return }
        let affectedLabels = pendingStatementCheck.affectedAccountLabels
        for index in staged.transactions.indices {
            let label = StatementCheckService.normalizedLabel(staged.transactions[index].sourceAccountLabel)
            if affectedLabels.contains(label) {
                staged.transactions[index].include = false
            }
        }
        vm.staged = staged
        acceptedStatementCheckKey = StatementCheckService.decisionKey(for: staged)
        self.pendingStatementCheck = nil
        statementCheckDetailsResult = nil
        isApprovingSave = false
        computeRoutingAnalysisIfNeeded()
    }

    private func cancelPendingStatementCheck() {
        pendingStatementCheck = nil
        statementCheckDetailsResult = nil
        isApprovingSave = false
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Button(role: .cancel) {
                    vm.staged = nil
                    vm.infoMessage = nil
                    typicalPaymentInput = ""
                    vm.userInstitutionName = ""
                    routedAccountIDs = []
                    selectedAccountId = nil
                    vm.selectedAccountID = nil
                    pendingStatementCheck = nil
                    statementCheckDetailsResult = nil
                    acceptedStatementCheckKey = nil
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "xmark.circle")
                        Text("Cancel")
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .truncationMode(.tail)
                            .allowsTightening(true)
                    }
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
                
                Button {
                    guard !isApprovingSave else { return }
                    guard let currentStaged = vm.staged else {
                        vm.errorMessage = "There is no reviewed import to save."
                        return
                    }
                    if shouldBlockForFreeImportLimit(currentStaged) {
                        showFreeImportLimitMessage()
                        return
                    }

                    isApprovingSave = true
                    selectedAccountId = nil
                    vm.selectedAccountID = nil
                    importLimitReached = false
                    AMLogging.log("ReviewImportView: Approve tapped — typicalPaymentInput='\(typicalPaymentInput)' parsedField=\(String(describing: parseCurrencyInput(typicalPaymentInput))) typicalPaymentParsed=\(String(describing: typicalPaymentParsed))", component: "ReviewImportView")
                    // Diagnostics: log institution state at approve time
                    let guess = vm.guessInstitutionName(from: staged.sourceFileName)
                    let selected = selectedAccountId.flatMap { id in accounts.first(where: { $0.id == id }) }
                    AMLogging.log("ReviewImportView: Approve tapped — selectedAccount=\(selected?.name ?? "nil"), selectedInst=\(selected?.institutionName ?? "nil"), vm.userInstitutionName='\(vm.userInstitutionName)', filenameGuess=\(guess ?? "nil")", component: "ReviewImportView")
                    vm.applyLiabilityLabelSafetyNetIfNeeded()
                    AMLogging.log("ReviewImportView: Safety net applied (if needed) before save", component: "ReviewImportView")

                    // If the only missing required field was a starting/ending balance and the user has typed it but not tapped Add, append it now
                    if let pending = pendingStartingBalance, (vm.staged?.balances.isEmpty ?? true) {
                        let asOf = (vm.staged?.transactions.map { $0.datePosted }.min()) ?? Date()
                        let sb = StagedBalance(asOfDate: asOf, balance: pending)
                        vm.staged?.balances.append(sb)
                        AMLogging.log("ReviewImportView: Auto-appended pending starting balance before save — value=\(pending) date=\(asOf)", component: "ReviewImportView")
                    }

                    guard let initialStagedForSave = vm.staged else {
                        isApprovingSave = false
                        vm.errorMessage = "There is no reviewed import to save."
                        return
                    }

                    let stagedForSave = applyDefaultStatementCheckRulesIfNeeded(to: initialStagedForSave)

                    // Prepare routing from the edited staged import, not the initial immutable view input.
                    let service = ImportRoutingService()
                    let result = service.buildPlans(staged: stagedForSave, context: modelContext)

                    // Use preview-effective overrides; fallback to current overrides if preview hasn't emitted yet.
                    // Drop stale existing-account choices whose target was deleted after the prior import.
                    let rawOverrides: [String: RoutingCandidate.Action] = routingPreviewEffective.isEmpty ? routingOverrides : routingPreviewEffective
                    let effectiveOverrides = sanitizedRoutingOverrides(rawOverrides, plans: result.plans)
                    let beforeSnap = snapshotAccounts(modelContext)
                    let resolvedInstitution: String? = {
                        let trimmed = routingPreviewInstitution?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        if !trimmed.isEmpty { return trimmed }
                        let typed = vm.userInstitutionName.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !typed.isEmpty { return typed }
                        return result.analysis.institution
                    }()

                    let overriddenPlans = service.applyOverrides(to: result.plans, overrides: effectiveOverrides)

                    var labelToAccount: [String: Account] = [:]

                    do {
                        // Resolve or create accounts as needed based on the preview at approval time
                        labelToAccount = try service.resolveAccounts(
                            for: overriddenPlans,
                            institution: resolvedInstitution,
                            currencyCode: settings.currencyCode,
                            context: modelContext
                        )

                        if let resolvedInstitution {
                            vm.userInstitutionName = resolvedInstitution
                        }

                        // Update routedAccountIDs and auto-select if a single account so approveAndSave attaches content to it.
                        let uniqueIDs = Set(labelToAccount.values.map { $0.id })
                        routedAccountIDs = Array(uniqueIDs)
                        if uniqueIDs.count == 1, let only = uniqueIDs.first, let any = labelToAccount.values.first {
                            selectedAccountId = only
                            vm.selectedAccountID = only
                            vm.newAccountType = any.type
                        } else {
                            selectedAccountId = nil
                            vm.selectedAccountID = nil
                        }

                        // Save the import
                        try vm.approveAndSave(context: modelContext)

                        // Persist mappings after save
                        service.persistMappingsAfterSave(
                            institution: resolvedInstitution,
                            labelToAccount: labelToAccount,
                            plans: overriddenPlans,
                            context: modelContext
                        )
                        AMLogging.log("ReviewImportView: Persisted import mappings for routing — labels=\(labelToAccount.keys.count)", component: "ReviewImportView")

                        let routedTargetAccount: Account? = {
                            let routedLiabilities = labelToAccount.values.filter { $0.type == .creditCard || $0.type == .loan }
                            if routedLiabilities.count == 1 {
                                return routedLiabilities.first
                            }
                            if let selectedAccountId {
                                if let routed = labelToAccount.values.first(where: { $0.id == selectedAccountId }) {
                                    return routed
                                }
                                let descriptor = FetchDescriptor<Account>(predicate: #Predicate { $0.id == selectedAccountId })
                                return try? modelContext.fetch(descriptor).first
                            }
                            return nil
                        }()

                        AMLogging.log("ReviewImportView: post-save, attempting to persist Typical Payment — candidate=\(String(describing: (typicalPaymentParsed ?? parseCurrencyInput(typicalPaymentInput))))", component: "ReviewImportView")
                        // Persist Typical Payment to the routed liability account if available.
                        if let pay = typicalPaymentParsed ?? parseCurrencyInput(typicalPaymentInput), pay > 0 {
                            if let acct = routedTargetAccount {
                                var terms = acct.loanTerms ?? LoanTerms()
                                terms.paymentAmount = pay
                                acct.loanTerms = terms
                                try? modelContext.save()
                                NotificationCenter.default.post(name: .accountsDidChange, object: nil)
                                AMLogging.log("ReviewImportView: Persisted Typical Payment to account id=\(acct.id) amount=\(pay)", component: "ReviewImportView")
                            } else {
                                AMLogging.log("ReviewImportView: Unable to resolve account to persist Typical Payment", component: "ReviewImportView")
                            }
                        } else {
                            AMLogging.log("ReviewImportView: Not persisting Typical Payment — value is nil or non-positive", component: "ReviewImportView")
                        }

                        // Persist APR to the routed liability account if available.
                        if let (aprFraction, scale) = parsePercentInput(aprInput) {
                            if let acct = routedTargetAccount {
                                var terms = acct.loanTerms ?? LoanTerms()
                                terms.apr = aprFraction
                                terms.aprScale = scale
                                acct.loanTerms = terms
                                try? modelContext.save()
                                NotificationCenter.default.post(name: .accountsDidChange, object: nil)
                                AMLogging.log("ReviewImportView: Persisted APR to account id=\(acct.id) apr=\(aprFraction) scale=\(String(describing: scale))", component: "ReviewImportView")
                            } else {
                                AMLogging.log("ReviewImportView: Unable to resolve account to persist APR", component: "ReviewImportView")
                            }
                        } else {
                            AMLogging.log("ReviewImportView: Not persisting APR — input empty or invalid", component: "ReviewImportView")
                        }

                        vm.userInstitutionName = ""
                        vm.mappingSession = nil
                        vm.staged = nil
                        vm.infoMessage = nil
                        let afterSnap = snapshotAccounts(modelContext)
                        let changes = diffAccounts(before: beforeSnap, after: afterSnap)
                        if changes.isEmpty {
                            AMLogging.log("RoutingDebug: No account type/institution changes across Approve & Save", component: "RoutingDebug")
                        } else {
                            AMLogging.log("RoutingDebug: Account changes across Approve & Save — \(changes.joined(separator: " | "))", component: "RoutingDebug")
                        }
                        let routedIDs = Set(labelToAccount.values.map { $0.id })
                        // For each changed id, indicate whether it was routed this run
                        let annotated = changes.map { change in
                            // If you change diffAccounts to return (id, summary) tuples, you can avoid parsing
                            // Otherwise, parse the UUID substring out of `change` or adjust `diffAccounts` to carry the id.
                            change
                        }
                        self.selectedAccountId = nil
                        showRoutingSheet = false
                        dismiss()
                        AMLogging.log("RoutingDebug: Changes across save — routedIDs=\(Array(routedIDs)) details=\(annotated.joined(separator: " | "))", component: "RoutingDebug")
                    } catch {
                        isApprovingSave = false
                        let nsError = error as NSError
                        if nsError.domain == "ImportViewModel" && nsError.code == 402 {
                            showFreeImportLimitMessage()
                        } else {
                            importLimitReached = false
                            vm.errorMessage = error.localizedDescription.isEmpty ? "We couldn't save this import." : error.localizedDescription
                        }
                        AMLogging.error("ReviewImportView: Approve & Save failed — \(vm.errorMessage ?? nsError.localizedDescription)", component: "ReviewImportView")
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Approve & Save")
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .truncationMode(.tail)
                            .allowsTightening(true)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled({
                    if isApprovingSave || duplicateImportWarning != nil {
                        return true
                    }

                    // Allow enabling when the only blocking issue is missing balance, but the user has typed a valid pending amount
                    let issues = vm.computeCompletenessIssues()
                    if issues.contains(where: { $0.severity == .required }) {
                        // If a pending starting balance exists, treat as satisfied
                        if pendingStartingBalance != nil {
                            // Additional guard: if there are multiple required issues in other contexts in the future, keep disabled
                            let requiredCount = issues.filter { $0.severity == .required }.count
                            return requiredCount > 1
                        }
                        return true
                    }
                    return false
                }())
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .padding(.bottom, 8)
            .background(.regularMaterial)
        }
    }
    
    //    private var editingAccessoryBar: some View {
    //        HStack(spacing: 16) {
    //
    //            Button { moveFocus(-1) } label: {
    //                Image(systemName: "chevron.left")
    //                    .font(.title2)
    //                    .frame(width: 44, height: 44)
    //                    .contentShape(Rectangle())
    //            }
    //            .buttonStyle(.plain)
    //            .disabled(!canGoPrevious)
    //            .accessibilityLabel("Previous field")
    //
    //            Button { moveFocus(1) } label: {
    //                Image(systemName: "chevron.right")
    //                    .font(.title2)
    //                    .frame(width: 44, height: 44)
    //                    .contentShape(Rectangle())
    //            }
    //            .buttonStyle(.plain)
    //            .disabled(!canGoNext)
    //            .accessibilityLabel("Next field")
    //
    //            Spacer()
    //
    //            Button { commitAndDismissKeyboard() } label: {
    //                Image(systemName: "checkmark")
    //                    .font(.title2.weight(.semibold))
    //                    .frame(width: 44, height: 44)
    //                    .contentShape(Rectangle())
    //            }
    //            .buttonStyle(.plain)
    //            .accessibilityLabel("Done editing")
    //        }
    //        .padding(.horizontal, 12)
    //        .padding(.vertical, 10)
    //        .background(.bar)
    //        .overlay(Divider(), alignment: .top)
    //    }
    //
    private var creditCardFlipBinding: Binding<Bool> {
        Binding(
            get: { vm.creditCardFlipOverride ?? false },
            set: { vm.creditCardFlipOverride = $0 }
        )
    }
    
    private func transactionIncludeBinding(for index: Int) -> Binding<Bool> {
        Binding(
            get: {
                guard let txs = vm.staged?.transactions, index < txs.count else { return true }
                return txs[index].include
            },
            set: { newValue in
                guard var staged = vm.staged, index < staged.transactions.count else { return }
                staged.transactions[index].include = newValue
                vm.staged = staged
            }
        )
    }
    
    private func holdingIncludeBinding(for index: Int) -> Binding<Bool> {
        Binding(
            get: {
                guard let holds = vm.staged?.holdings, index < holds.count else { return true }
                return holds[index].include
            },
            set: { newValue in
                guard var staged = vm.staged, index < staged.holdings.count else { return }
                staged.holdings[index].include = newValue
                vm.staged = staged
            }
        )
    }
    
    private func balanceIncludeBinding(for index: Int) -> Binding<Bool> {
        Binding(
            get: {
                guard let balances = vm.staged?.balances, index < balances.count else { return true }
                return balances[index].include
            },
            set: { newValue in
                guard var staged = vm.staged, index < staged.balances.count else { return }
                staged.balances[index].include = newValue
                vm.staged = staged
            }
        )
    }
    
    private func onAccountSectionAppear() {
        AMLogging.log("ReviewImportView.onAppear — file=\(staged.sourceFileName), initial userInstitutionName='\(vm.userInstitutionName)'", component: "ReviewImportView")
        if let suggested = staged.suggestedAccountType {
            vm.newAccountType = suggested
        }

        if var currentStaged = vm.staged {
            for index in currentStaged.balances.indices {
                let label = (currentStaged.balances[index].sourceAccountLabel ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                let isCashLabel = label.contains("checking") || label.contains("savings") || label == "cash"
                let isLiabilityLabel = label.contains("loan") || label.contains("credit")

                if vm.newAccountType == .loan || vm.newAccountType == .creditCard {
                    if !isCashLabel && (isLiabilityLabel || label.isEmpty), currentStaged.balances[index].balance > 0 {
                        currentStaged.balances[index].balance = -currentStaged.balances[index].balance
                    }
                } else if vm.newAccountType == .checking || vm.newAccountType == .savings || vm.newAccountType == .cash {
                    if !isLiabilityLabel && currentStaged.balances[index].balance < 0 {
                        currentStaged.balances[index].balance = -currentStaged.balances[index].balance
                    }
                }
            }
            vm.staged = currentStaged
        }
        if vm.newAccountType == .creditCard && vm.creditCardFlipOverride == nil && settings.creditCardFlipDefault {
            vm.creditCardFlipOverride = true
        }
        // Prefer upstream VM institution (from router) over parser-inferred; then fall back to parser
        let upstream = vm.userInstitutionName.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = staged.inferredInstitutionName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if upstream.isEmpty, let inst = parsed, !inst.isEmpty {
            vm.userInstitutionName = inst
            AMLogging.log("ReviewImportView: Prefilled institution — source=parser value=\(inst)", component: "ReviewImportView")
        } else if !upstream.isEmpty {
            AMLogging.log("ReviewImportView: Institution already set upstream — source=router value=\(upstream)", component: "ReviewImportView")
        } else {
            AMLogging.log("ReviewImportView: No institution prefill available", component: "ReviewImportView")
        }

        // Default routing mode from routing plans, not just institution presence.
        // If all clusters resolve to create-new, start in Create New even when the institution
        // already has unrelated accounts.
        let chosenInst = vm.userInstitutionName.trimmingCharacters(in: .whitespacesAndNewlines)
        let routingService = ImportRoutingService()
        let routingResult = routingService.buildPlans(staged: staged, context: modelContext)
        routingOverrides = sanitizedRoutingOverrides(routingOverrides, plans: routingResult.plans)
        routingPreviewEffective = sanitizedRoutingOverrides(routingPreviewEffective, plans: routingResult.plans)
        let allPlansCreateNew = !routingResult.plans.isEmpty && routingResult.plans.allSatisfy { plan in
            if case .createNew = plan.candidate.action { return true }
            return false
        }
        if allPlansCreateNew {
            routingGlobalTargetMode = 1
            AMLogging.log("ReviewImportView: Defaulted routing mode from plans — all clusters create new", component: "ReviewImportView")
        } else if !chosenInst.isEmpty {
            let hasAtInst = accounts.contains { acct in
                (acct.institutionName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(chosenInst) == .orderedSame
            }
            routingGlobalTargetMode = hasAtInst ? 0 : 1
            AMLogging.log("ReviewImportView: Defaulted routing mode — institution='\(chosenInst)' hasExisting=\(hasAtInst) mode=\(routingGlobalTargetMode == 0 ? "Existing" : "Create New")", component: "ReviewImportView")
        }
        if typicalPaymentInput.isEmpty {
            if vm.newAccountType == .loan, let hint = vm.typicalPaymentHint(for: .loan) {
                typicalPaymentInput = formatAmountForInput(hint)
                typicalPaymentParsed = hint
            } else if vm.newAccountType == .creditCard, let hint = vm.typicalPaymentHint(for: .creditCard) {
                typicalPaymentInput = formatAmountForInput(hint)
                typicalPaymentParsed = hint
            }
        }
        
        // Seed Typical Payment from a sentinel balance embedded by PDFSummaryParser (top-level init and fallback here)
        seedTypicalPaymentFromSentinelIfNeeded()
        
        // Seed APR input from any staged balance that carries an APR
        if aprInput.isEmpty {
            if let apr = vm.staged?.balances.compactMap({ $0.interestRateAPR }).first {
                aprInput = formatPercentForInput(apr, scale: vm.staged?.balances.compactMap({ $0.interestRateScale }).first)
                aprScale = vm.staged?.balances.compactMap({ $0.interestRateScale }).first
                AMLogging.log("ReviewImportView: Seeded APR from staged balances — apr=\(apr) scale=\(String(describing: aprScale))", component: "ReviewImportView")
            }
        }
        
        // Run first-pass routing analysis once per source file
        computeRoutingAnalysisIfNeeded()
    }
    
    private func seedTypicalPaymentFromSentinelIfNeeded() {
        AMLogging.log("ReviewImportView: seedTypicalPaymentFromSentinelIfNeeded start — input='\(typicalPaymentInput)' parsed=\(String(describing: typicalPaymentParsed)) hasStaged=\(vm.staged != nil)", component: "ReviewImportView")
        guard typicalPaymentInput.isEmpty || typicalPaymentParsed == nil else {
            AMLogging.log("ReviewImportView: skipping seeding — input already present or parsed value exists", component: "ReviewImportView")
            return
        }
        guard var staged = vm.staged else {
            AMLogging.log("ReviewImportView: no staged import available; cannot seed typical payment", component: "ReviewImportView")
            return
        }
        let sentinelLabel = "__typical_payment__"
        if let idx = staged.balances.firstIndex(where: { ($0.sourceAccountLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == sentinelLabel }) {
            let amt = staged.balances[idx].balance
            AMLogging.log("ReviewImportView: sentinel found at index=\(idx) amount=\(amt)", component: "ReviewImportView")
            // Remove the sentinel so it doesn't show as a balance
            staged.balances.remove(at: idx)
            vm.staged = staged
            // Apply to UI fields
            typicalPaymentInput = formatAmountForInput(amt)
            typicalPaymentParsed = amt
            AMLogging.log("ReviewImportView: Seeded Typical Payment from sentinel — amount=\(amt)", component: "ReviewImportView")
        } else {
            AMLogging.log("ReviewImportView: sentinel not found in staged balances; attempting fallback from snapshot fields", component: "ReviewImportView")
            // Fallback: seed from any snapshot that carries a typicalPaymentAmount
            if let pay = staged.balances.compactMap({ $0.typicalPaymentAmount }).first(where: { $0 > 0 }) {
                typicalPaymentInput = formatAmountForInput(pay)
                typicalPaymentParsed = pay
                AMLogging.log("ReviewImportView: Seeded Typical Payment from snapshot field — amount=\(pay)", component: "ReviewImportView")
            } else {
                AMLogging.log("ReviewImportView: no typicalPaymentAmount found on snapshots; no seeding performed", component: "ReviewImportView")
            }
        }
    }
    
    private func computeRoutingAnalysisIfNeeded() {
        guard let staged = vm.staged else { return }
        let src = staged.sourceFileName
        if lastAnalyzedSource == src { return }
        let service = ImportRoutingService()
        let analysis = service.analyze(staged: staged, context: modelContext)
        routingAnalysis = analysis
        lastAnalyzedSource = src
        AMLogging.log("Routing analysis computed — clusters=\(analysis.clusters.count) needsConfirmation=\(analysis.needsConfirmation)", component: "ReviewImportView")
        showRoutingSheet = true
    }

    private func sanitizedRoutingOverrides(_ overrides: [String: RoutingCandidate.Action], plans: [ImportRoutingService.RoutedClusterPlan]) -> [String: RoutingCandidate.Action] {
        guard !overrides.isEmpty else { return overrides }
        let validAccountIDs = Set(accounts.map(\.id))
        var sanitized: [String: RoutingCandidate.Action] = [:]

        for plan in plans {
            guard let action = overrides[plan.label] else { continue }
            switch action {
            case .existing(let accountID, _):
                if validAccountIDs.contains(accountID) {
                    sanitized[plan.label] = action
                } else {
                    AMLogging.log("ReviewImportView: dropped stale routing override — label=\(plan.label) missingAccountID=\(accountID)", component: "ReviewImportView")
                }
            case .createNew:
                sanitized[plan.label] = action
            }
        }

        return sanitized
    }

    private func resolvedPDFURL() -> URL? {
        // Only use lastPickedLocalURL when it's a PDF
        if let direct = vm.lastPickedLocalURL {
            if direct.pathExtension.lowercased() == "pdf" {
                AMLogging.log("ReviewImportView: PDF preview using lastPickedLocalURL=\(direct.path)", component: "ReviewImportView")
                return direct
            } else {
                AMLogging.log("ReviewImportView: ignoring non-PDF lastPickedLocalURL=\(direct.path)", component: "ReviewImportView")
            }
        }

        // Fallback: look in Caches using the staged file name (only for .pdf)
        let lower = staged.sourceFileName.lowercased()
        if lower.hasSuffix(".pdf"),
           let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let candidate = caches.appendingPathComponent(staged.sourceFileName)
            if FileManager.default.fileExists(atPath: candidate.path) {
                AMLogging.log("ReviewImportView: PDF preview using caches candidate=\(candidate.path)", component: "ReviewImportView")
                return candidate
            } else {
                AMLogging.log("ReviewImportView: PDF preview missing for candidate=\(candidate.path)", component: "ReviewImportView")
            }
        } else {
            AMLogging.log("ReviewImportView: PDF preview unavailable — fileName='\(staged.sourceFileName)'", component: "ReviewImportView")
        }
        return nil
    }
    
    private var pdfPane: some View {
        Group {
            if let url = resolvedPDFURL() {
                PDFKitView(url: url)
                    .ignoresSafeArea()
            } else if hasStagedPreviewData {
                StatementPreviewView(staged: staged)
            } else {
                ContentUnavailableView(
                    "Statement Preview",
                    systemImage: "doc.richtext",
                    description: Text("No preview available")
                )
            }
        }
    }

    private func parseCurrencyInput(_ s: String) -> Decimal? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Keep only digits, minus sign, and separators
        let allowed = CharacterSet(charactersIn: "-0123456789.,")
        let filtered = String(trimmed.unicodeScalars.filter { allowed.contains($0) })
        guard !filtered.isEmpty else { return nil }
        var normalized = filtered
        if filtered.contains(",") && filtered.contains(".") {
            // Assume commas are thousands separators
            normalized = filtered.replacingOccurrences(of: ",", with: "")
        } else if filtered.contains(",") && !filtered.contains(".") {
            // Treat comma as decimal separator
            normalized = filtered.replacingOccurrences(of: ",", with: ".")
        }
        return Decimal(string: normalized)
    }
    
    private func parsePercentInput(_ s: String) -> (Decimal, Int)? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let cleaned = trimmed.replacingOccurrences(of: "%", with: "").replacingOccurrences(of: ",", with: ".")
        guard let dec = Decimal(string: cleaned) else { return nil }
        let scale: Int = {
            if let dot = cleaned.firstIndex(of: ".") { return cleaned.distance(from: cleaned.index(after: dot), to: cleaned.endIndex) }
            return 0
        }()
        var fraction = dec
        if fraction > 1 { fraction /= 100 }
        return (fraction, scale)
    }

    private func formatAmountForInput(_ amount: Decimal) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = settings.currencyCode
        return nf.string(from: NSDecimalNumber(decimal: amount)) ?? "\(amount)"
    }
    
    private func formatPercentForInput(_ apr: Decimal, scale: Int?) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .percent
        if let s = scale { nf.minimumFractionDigits = s; nf.maximumFractionDigits = s } else { nf.minimumFractionDigits = 2; nf.maximumFractionDigits = 3 }
        return nf.string(from: NSDecimalNumber(decimal: apr)) ?? "\(apr * 100)%"
    }
    
    private func displayName(for type: Account.AccountType) -> String {
        switch type {
        case .checking: return "Checking"
        case .savings: return "Savings"
        case .creditCard: return "Credit Card"
        case .loan: return "Loan"
        case .brokerage: return "Brokerage"
        case .cash: return "Cash"
        case .property: return "Property"
        case .other: return "Other"
        }
    }

    private var importedBankBalanceSummaries: [ImportedBankBalanceSummary] {
        guard vm.newAccountType == .checking || vm.newAccountType == .savings else { return [] }
        guard let balances = vm.staged?.balances.filter(\.include), !balances.isEmpty else { return [] }

        let grouped = Dictionary(grouping: balances) { bankSummaryKey(for: $0.sourceAccountLabel) }
        let orderedKeys = grouped.keys.sorted { lhs, rhs in
            bankSummarySortOrder(for: lhs) < bankSummarySortOrder(for: rhs)
        }

        return orderedKeys.compactMap { key in
            guard let groupedBalances = grouped[key], !groupedBalances.isEmpty else { return nil }
            let sortedBalances = groupedBalances.sorted { lhs, rhs in
                if lhs.asOfDate == rhs.asOfDate {
                    return lhs.balance < rhs.balance
                }
                return lhs.asOfDate < rhs.asOfDate
            }

            let beginningBalance: Decimal? = sortedBalances.count > 1 ? sortedBalances.first?.balance : nil
            let endingBalance = sortedBalances.last?.balance

            return ImportedBankBalanceSummary(
                id: key,
                label: bankSummaryLabel(for: key),
                beginningBalance: beginningBalance,
                endingBalance: endingBalance
            )
        }
    }

    private func bankSummaryKey(for rawLabel: String?) -> String {
        let trimmed = rawLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return "default" }

        let lower = trimmed.lowercased()
        if lower.contains("checking") { return "checking" }
        if lower.contains("savings") { return "savings" }
        return lower
    }

    private func bankSummaryLabel(for key: String) -> String {
        switch key {
        case "checking":
            return "Checking"
        case "savings":
            return "Savings"
        case "default":
            return "Account"
        default:
            return key.split(separator: " ").map { $0.capitalized }.joined(separator: " ")
        }
    }

    private func bankSummarySortOrder(for key: String) -> Int {
        switch key {
        case "checking":
            return 0
        case "savings":
            return 1
        case "default":
            return 99
        default:
            return 50
        }
    }
    
    private func disambiguatedName(for account: Account, among all: [Account]) -> String {
        let name = account.name
        // Consider duplicates by case-insensitive name
        let group = all.filter { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        if group.count <= 1 {
            return name
        }

        // Try institution if it actually disambiguates and isn't redundant with the name
        let instRaw = (account.institutionName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let instUsable = !instRaw.isEmpty &&
            instRaw.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame

        if instUsable {
            // Only use institution if not all duplicates share the same institution
            let sameInstAcrossGroup = group.allSatisfy {
                let otherInst = ($0.institutionName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return otherInst.compare(instRaw, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }
            if !sameInstAcrossGroup {
                return "\(name) (\(instRaw))"
            }
            // else fall through to type/ID
        }

        // Try type if types differ within the duplicate-name group
        let sameTypeAcrossGroup = group.allSatisfy { $0.type == account.type }
        if !sameTypeAcrossGroup {
            let typeName = displayName(for: account.type)
            // Avoid “Savings (Savings)” and “Checking (Checking)” when the base name already includes the type
            if name.localizedCaseInsensitiveContains(typeName) {
                return name
            } else {
                return "\(name) (\(typeName))"
            }
        }

        // Last resort: short id suffix to ensure uniqueness in the banner
        let short = account.id.uuidString.prefix(4)
        return "\(name) [\(short)]"
    }
    // Returns true when the user has not resolved routing yet.
    // Existing mode (globalTargetMode == 0) requires the user to explicitly pick an Institution
    // (not "Select"/"Unknown") and for each cluster to resolve to an existing account.
    private func isRoutingUnresolved() -> Bool {
        // Only care in "Existing Account" mode
        if routingGlobalTargetMode != 0 { return false }

        // Effective user-chosen institution from live preview > VM.
        // IMPORTANT: Ignore the analysis default here; we want an explicit user choice.
        let raw = (routingPreviewInstitution ?? vm.userInstitutionName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let userInstitution = raw.isEmpty || raw.lowercased() == "unknown" ? nil : raw

        // If Institution is still on "Select" (nil/"Unknown"), routing is unresolved
        if userInstitution == nil { return true }

        // Must have at least one existing account at the chosen institution
        let hasAccountAtInst = accounts.contains {
            (($0.institutionName ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(userInstitution!) == .orderedSame)
        }
        if !hasAccountAtInst { return true }

        // Evaluate effective actions per cluster
        let service = ImportRoutingService()
        let result = service.buildPlans(staged: staged, context: modelContext)

        // Prefer live-preview overrides over stored overrides
        let effectiveOverrides = routingPreviewEffective.isEmpty ? routingOverrides : routingPreviewEffective

        // In Existing mode, a create-new action is only unresolved when it is a fallback caused
        // by a missing existing selection. If routing itself intentionally proposed create-new
        // (for example, a new loan beside an existing savings account on the same statement),
        // that mixed plan is already resolved.
        for plan in result.plans {
            if let override = effectiveOverrides[plan.label] {
                if case .createNew = override,
                   case .existing = plan.candidate.action {
                    return true
                }
            } else if case .createNew = plan.candidate.action {
                continue
            }
        }

        // If multiple clusters and no explicit overrides, require a pick for safety
        if result.plans.count > 1 && effectiveOverrides.isEmpty {
            return true
        }

        return false
    }
    private var currencyFormatter: NumberFormatter {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = settings.currencyCode
        return nf
    }
    
    private func formatAPR(_ apr: Decimal, scale: Int? = nil) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .percent
        if let s = scale { nf.minimumFractionDigits = s; nf.maximumFractionDigits = s } else { nf.minimumFractionDigits = 2; nf.maximumFractionDigits = 3 }
        return nf.string(from: NSDecimalNumber(decimal: apr)) ?? "\(apr)"
    }
    // Summarize the live routing preview into a single banner string.
    // Uses the effective overrides directly and matches the actual enum cases:
    //
    // enum RoutingCandidate.Action {
    //   case existing(accountID: UUID, name: String)
    //   case createNew(type: Account.AccountType?)
    // }
    private func routingPreviewBannerText() -> String? {
        // Prefer live preview overrides; otherwise fall back to current overrides
        let effective = routingPreviewEffective.isEmpty ? routingOverrides : routingPreviewEffective

        let hasInst = !(routingPreviewInstitution?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        guard !effective.isEmpty || hasInst else { return nil }

        func humanLabel(from raw: String) -> String {
            return raw == "__default__" ? "Default" : raw.capitalized
        }

        var targetNames: [String] = []

        // Iterate label -> action so we can show a sensible name for Create New
        for (label, action) in effective {
            switch action {
            case .createNew(let optType):
                let labelTitle = humanLabel(from: label)
                if let t = optType {
                    let typeName = displayName(for: t)
                    // Avoid “Savings (Savings)” and “Checking (Checking)”
                    if labelTitle.localizedCaseInsensitiveCompare(typeName) == .orderedSame {
                        targetNames.append(labelTitle)
                    } else {
                        targetNames.append("\(labelTitle) (\(typeName))")
                    }
                } else {
                    // No type specified; don’t add a generic “(New Account)” suffix to avoid clutter
                    targetNames.append(labelTitle)
                }

            case .existing(let accountID, let name):
                if let acct = accounts.first(where: { $0.id == accountID }) {
                    targetNames.append(disambiguatedName(for: acct, among: accounts))
                } else {
                    // Fallback to provided name if the account isn't in the current query result
                    targetNames.append(name)
                }
            }
        }

        // Include institution if the user has provided one in the preview
        let inst = routingPreviewInstitution?.trimmingCharacters(in: .whitespacesAndNewlines)
        let instSuffix = (inst?.isEmpty == false) ? " at \(inst!)" : ""

        if targetNames.isEmpty {
            // Only institution changed
            return instSuffix.isEmpty ? nil : "Routing preview updated\(instSuffix)."
        } else if targetNames.count > 1 {
            return "This import will be routed to multiple accounts\(instSuffix): \(targetNames.joined(separator: ", "))."
        } else if let only = targetNames.first {
            let noun = staged.transactions.isEmpty ? "This snapshot" : "These transactions"
            return "\(noun) will be saved to \(only)\(instSuffix)."
        }
        return nil
    }
    private func balanceDateBinding(for index: Int) -> Binding<Date> {
        Binding(
            get: {
                if let balances = vm.staged?.balances, index < balances.count {
                    return balances[index].asOfDate
                }
                return Date()
            },
            set: { newVal in
                if var staged = vm.staged, index < staged.balances.count {
                    staged.balances[index].asOfDate = newVal
                    vm.staged = staged
                }
            }
        )
    }
    private func balanceAmountTextBinding(for index: Int) -> Binding<String> {
        Binding(
            get: {
                guard let balances = vm.staged?.balances, index < balances.count else { return "" }
                let amount = balances[index].balance
                return currencyFormatter.string(from: NSDecimalNumber(decimal: amount)) ?? "\(amount)"
            },
            set: { newText in
                if let dec = parseCurrencyInput(newText) {
                    if var staged = vm.staged, index < staged.balances.count {
                        staged.balances[index].balance = dec
                        vm.staged = staged
                    }
                }
            }
        )
    }
    
    private var focusOrder: [FocusedField] {
        var order: [FocusedField] = []
        if vm.newAccountType == .loan || vm.newAccountType == .creditCard {
            order.append(.typicalPayment)
            order.append(.apr)
        }
        if (vm.staged?.balances.isEmpty ?? true) {
            order.append(.startingBalance)
        }
        if let count = vm.staged?.balances.count, count > 0 {
            for idx in 0..<count {
                order.append(.balance(idx))
            }
        }
        return order
    }

    private var canGoPrevious: Bool {
        if childIsEditing { return !focusOrder.isEmpty }
        guard let focusedField, let i = focusOrder.firstIndex(of: focusedField) else { return false }
        if i == 0 {
            // Enable going “back” into the routing child only when the institution TextField exists (Create New mode)
            return routingGlobalTargetMode != 0
        }
        return i > 0
    }

    private var canGoNext: Bool {
        if childIsEditing { return !focusOrder.isEmpty }
        guard let focusedField, let i = focusOrder.firstIndex(of: focusedField) else { return false }
        return i < focusOrder.count - 1
    }
    private func moveFocus(_ delta: Int) {
        let order = focusOrder
        guard !order.isEmpty else { return }
        if let current = focusedField, let idx = order.firstIndex(of: current) {
            let nextIdx = (idx + delta + order.count) % order.count
            focusedField = order[nextIdx]
        } else {
            focusedField = order.first
        }
    }

    private func scrollAndFocus(to id: AnyHashable?, focus: FocusedField?) {
        // Scroll to the anchor and then focus the field with a slight delay to allow layout to settle
        if let id = id, let proxy = scrollProxy {
            withAnimation(.snappy) {
                proxy.scrollTo(id, anchor: .center)
            }
        }
        if let f = focus {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                focusedField = f
            }
        }
        if let id = id as? String {
            withAnimation(.easeInOut(duration: 0.2)) { highlightTarget = id }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                withAnimation(.easeInOut(duration: 0.25)) { highlightTarget = nil }
            }
        }
    }

    private func performChecklistAction(for title: String) {
        switch title {
        case "Add a statement balance":
            if (vm.staged?.balances.isEmpty ?? true) {
                scrollAndFocus(to: "startingBalancePrompt", focus: .startingBalance)
            } else {
                scrollAndFocus(to: "balanceField-0", focus: .balance(0))
            }
        case "Enter APR":
            scrollAndFocus(to: "aprField", focus: .apr)
        case "Set a typical monthly payment":
            scrollAndFocus(to: "typicalPaymentField", focus: .typicalPayment)
        default:
            break
        }
    }

    private func commitAndDismissKeyboard() {
        // Reformat Typical Payment
        if let dec = parseCurrencyInput(typicalPaymentInput) {
            typicalPaymentInput = formatAmountForInput(dec)
            typicalPaymentParsed = dec
        }
        // Reformat APR
        if let (fraction, scale) = parsePercentInput(aprInput) {
            aprInput = formatPercentForInput(fraction, scale: scale)
            aprScale = scale
        }
        focusedField = nil
        #if canImport(UIKit)
        // Dismiss any active first responder to ensure the keyboard hides for fields not tracked by FocusState
        let keyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        keyWindow?.endEditing(true)
        #endif
    }
    private func dismissAnyKeyboard() {
        #if canImport(UIKit)
        let keyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        keyWindow?.endEditing(true)
        #endif
    }

    private func accessoryPrevious() {
        if childIsEditing {
            // Resign child focus and move to the last field in the parent's order (if any)
            dismissAnyKeyboard()
            childIsEditing = false
            if let last = focusOrder.last {
                focusedField = last
            }
        } else {
            let order = focusOrder
            guard !order.isEmpty else { return }

            if let focused = focusedField, let idx = order.firstIndex(of: focused), idx == 0, routingGlobalTargetMode != 0 {
                // When at the first parent field and the child has an institution TextField, jump back into the child
                focusedField = nil
                dismissAnyKeyboard()
                withAnimation(.snappy) { scrollProxy?.scrollTo("routingSectionTop", anchor: .top) }
                NotificationCenter.default.post(name: .focusRoutingInstitution, object: nil)
                return
            }

            moveFocus(-1)
        }
    }
    private func snapshotAccounts(_ ctx: ModelContext) -> [UUID: (name: String, type: String, inst: String?)] {
        let all = (try? ctx.fetch(FetchDescriptor<Account>())) ?? []
        return Dictionary(uniqueKeysWithValues: all.map { ($0.id, (name: $0.name, type: $0.typeRaw, inst: $0.institutionName)) })
    }

    private func diffAccounts(before: [UUID: (name: String, type: String, inst: String?)],
                              after: [UUID: (name: String, type: String, inst: String?)]) -> [String] {
        var changes: [String] = []
        let ids = Set(before.keys).union(after.keys)
        for id in ids {
            let b = before[id]
            let a = after[id]
            guard let b = b, let a = a else { continue } // created/deleted not interesting for this bug
            if b.type != a.type || (b.inst ?? "") != (a.inst ?? "") {
                changes.append("Account \(id): type \(b.type) → \(a.type); inst '\(b.inst ?? "nil")' → '\(a.inst ?? "nil")'")
            }
        }
        return changes
    }
    private func accessoryNext() {
        if childIsEditing {
            // Resign child focus and move to the first field in the parent's order (if any)
            dismissAnyKeyboard()
            childIsEditing = false
            if let first = focusOrder.first {
                focusedField = first
            }
        } else {
            moveFocus(1)
        }
    }
    private func selectAllInFirstResponder(after delay: TimeInterval = 0.05) {
        #if canImport(UIKit)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            UIApplication.shared.sendAction(#selector(UIResponder.selectAll(_:)), to: nil, from: nil, for: nil)
        }
        #endif
    }
}

private struct ReviewImportHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Approve & Save finishes this import. Until you tap it, nothing on this screen is committed.")
                }

                Section("When you approve") {
                    Label("Transactions, balances, and holdings marked for import are saved.", systemImage: "tray.and.arrow.down")
                    Label("The routing choices on this screen decide which account each item belongs to.", systemImage: "arrow.triangle.branch")
                    Label("If you create a new account, DebtScope saves that account with the selected type and institution.", systemImage: "plus.circle")
                    Label("For loans and credit cards, any payment or APR values you entered are saved to the routed account.", systemImage: "percent")
                }

                Section {
                    Text("If something does not look right yet, change the routing or fields first. Closing this review without approving leaves the import unsaved.")
                }
            }
            .navigationTitle("Approve & Save")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct DismissOverlay: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white)
                .shadow(radius: 2)
        }
        .buttonStyle(.plain)
        .background(.ultraThinMaterial, in: Circle())
        .accessibilityLabel("Close")
    }
}
private extension Notification.Name {
    static let focusRoutingInstitution = Notification.Name("focusRoutingInstitution")
}
private struct ChecklistRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(configuration.isPressed ? Color.yellow.opacity(0.15) : .clear)
            .animation(.easeInOut(duration: 0.12), value: configuration.isPressed)
    }
}
