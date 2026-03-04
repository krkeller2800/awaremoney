//
//  DebtSummaryView.swift
//  awaremoney
//
//  Created by Assistant on 2/1/26
//

import SwiftUI
import SwiftData
import Foundation
#if canImport(UIKit)
import UIKit
#endif

// Uses DebtPayoffEngine

// Lightweight model used for planning
fileprivate struct Debt: Identifiable, Hashable {
    let id: UUID
    let name: String
    let balance: Decimal
    let apr: Decimal?
    let minPayment: Decimal
}

struct DebtSummaryView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(\.dismiss) private var dismiss
    @State private var accounts: [Account] = []
    @State private var showPlanSheet = false
    @State private var tempPlanDate: Date = {
        Calendar.current.date(byAdding: .month, value: 12, to: Date()) ?? Date()
    }()
    @State private var appliedPlanDate: Date? = nil
    private enum PlanMode: String, CaseIterable {
        case currentInputs = "Current inputs"
        case projectedAtDate = "Projected at date"
    }
    @State private var tempPlanMode: PlanMode = .currentInputs
    @State private var appliedPlanMode: PlanMode = .currentInputs
    
    @State private var tempStrategy: PayoffStrategy = .minimumsOnly
    @State private var tempMonthlyBudget: String = ""
    @State private var appliedStrategy: PayoffStrategy = .minimumsOnly
    @State private var appliedBudget: Decimal? = nil
    @State private var currentPlan: DebtPlanResult? = nil
    @State private var budgetValidationError: String? = nil
    @State private var showPlanErrorAlert = false
    @State private var planErrorMessage: String? = nil
//    @State private var showIncomeBillsHost = false

    @FocusState private var focusedField: FocusField?
    private enum FocusField: Hashable {
        case monthlyBudget
    }
    private var isPhone: Bool {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .phone
        #else
        return false
        #endif
    }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let compact = isCompactLayout(proxy.size)
                let isPortrait = proxy.size.height > proxy.size.width
//                let toolbarCompact = !((hSizeClass == .regular) && proxy.size.width >= 844)
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        if isPortrait && proxy.size.width < 844 {
                            ScrollView(.horizontal, showsIndicators: false) {
                                summaryStack(compact: compact)
                                    .padding(.horizontal, compact ? 6 : 12)
                                    .frame(width: 844, alignment: .topLeading)
                            }
                        } else {
                            summaryStack(compact: compact)
                                .padding(.horizontal, compact ? 6 : 12)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                    .padding(.vertical, 8)
                }
                .navigationTitle("Debt Summary")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        VStack(spacing: 0) {
                            Text("Debt Summary")
                                .font(.headline)
                            Text(planSubtitleText)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                                .layoutPriority(1)
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        PlanToolbarButton("Project",fixedWidth: 70) {
                            showPlanSheet = true
                        }

                        .accessibilityIdentifier("planByDateButton")
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        PlanToolbarButton("Done", fixedWidth: 60) {
                            dismiss()
                        }
                        .accessibilityIdentifier("debtSummaryDoneButton")
                    }
                }
                .task { await load() }
                .sheet(isPresented: $showPlanSheet) {
                    planSheetView()
                }
//                .onChange(of: showPlanSheet) { _, newValue in
//                    AMLogging.log("showPlanSheet changed: \(newValue)", component: "DebtSummaryView")
//                }
            }
        }
        #if canImport(UIKit)
        .landscapeOnlyOnPhone()
        #endif
    }


    // MARK: - View Builders

    private func payoffOrderString() -> String? {
        guard let plan = currentPlan, !plan.payoffOrder.isEmpty else { return nil }
        let names = plan.payoffOrder.compactMap { id in accounts.first(where: { $0.id == id })?.name }
        let order = names.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "  •  ")
        return "Payoff order: " + order
    }

    private func summaryStack(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 8) {
            // Removed planHeader(compact: compact) as per instructions
            if let s = payoffOrderString() {
                Text(s)
                    .font(compact ? .caption2 : .caption)
                    .foregroundStyle(.secondary)
            }
            headerRow(compact: compact)
            Divider()
            ForEach(accounts, id: \.id) { acct in
                row(for: acct, compact: compact)
                Divider()
            }
            totalRow(compact: compact)
        }
    }

    private func planSheetView() -> some View {
        NavigationStack {
            List {
                Section {
                    DatePicker("Target date", selection: $tempPlanDate, displayedComponents: .date)
                        .datePickerStyle(.compact)
                        .onChange(of: tempPlanDate) { _, newValue in
                            let isToday = Calendar.current.isDate(newValue, inSameDayAs: Date())
                            tempPlanMode = isToday ? .currentInputs : .projectedAtDate
                        }
                } footer: {
                    Text("Choose a target date to plan against. The selected date will appear above the summary headers.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Mode") {
                    Picker("Summary mode", selection: $tempPlanMode) {
                        Text("Current inputs").tag(PlanMode.currentInputs)
                        Text("Projected at date").tag(PlanMode.projectedAtDate)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: tempPlanMode) { _, newValue in
                        if newValue == .currentInputs {
                            tempPlanDate = Date()
                        }
                    }
                }
                Section {
                    LabeledContent("Monthly budget") {
                        TextField(
                            "$0.00",
                            text: Binding<String>(
                                get: {
                                    let trimmed = tempMonthlyBudget.trimmingCharacters(in: .whitespacesAndNewlines)
                                    if trimmed.isEmpty { return "" }
                                    if let value = parseCurrencyInput(trimmed) {
                                        return formatAmount(value)
                                    } else {
                                        return trimmed
                                    }
                                },
                                set: { newValue in
                                    // Always store a cleaned numeric string so parsing stays stable
                                    let filtered = newValue
                                        .trimmingCharacters(in: .whitespacesAndNewlines)
                                        .replacingOccurrences(of: "$", with: "")
                                        .replacingOccurrences(of: ",", with: "")
                                    tempMonthlyBudget = filtered
                                }
                            )
                        )
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.decimalPad)
                        .focused($focusedField, equals: .monthlyBudget)
                        .submitLabel(.done)
                        .onSubmit {
                            commitAndDismissKeyboard()
                        }
                        .highPriorityGesture(
                            TapGesture().onEnded {
                                focusedField = .monthlyBudget
                                selectAllInFirstResponder()
                            }
                        )
                        .onChange(of: tempMonthlyBudget) { _, newValue in
                            // Normalize to a valid numeric string or empty
                            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                            if trimmed.isEmpty { return }
                            if parseCurrencyInput(trimmed) == nil {
                                // If not parsable, keep as-is to allow user to correct
                            }
                        }
                    }
                } header: {
                    Text("Payoff Plan")
                } footer: {
                    Group {
                        Text("Enter your total monthly budget for debt payments. Leave empty if Minimums Only strategy.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if let error = budgetValidationError {
                            Text(error)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                }
                
                Section("Income & Bills") {
                    NavigationLink("Manage Income & Bills") {
                        IncomeAndBillsView()
                    }
                    LabeledContent("Monthly Income") {
                        Text(formatAmount(computedMonthlyIncome))
                    }
                    LabeledContent("Monthly Bills") {
                        Text(formatAmount(computedMonthlyBills))
                    }
                    LabeledContent("Net for Debt") {
                        Text(formatAmount(computedMonthlyNet))
                    }
                    Button("Use Net as Budget") {
                        if computedMonthlyNet > 0 {
                            tempMonthlyBudget = formatAmount(computedMonthlyNet)
                        }
                    }
                    .disabled(computedMonthlyNet <= 0)
                }
                
                Section("Strategy") {
                    Picker("Strategy", selection: $tempStrategy) {
                        Text("Minimums Only").tag(PayoffStrategy.minimumsOnly)
                        Text("Snowball").tag(PayoffStrategy.snowball)
                        Text("Avalanche").tag(PayoffStrategy.avalanche)
                    }
                    .pickerStyle(.segmented)
                }
                Section("Current Plan") {
                    if tempPlanMode == .projectedAtDate {
                        HStack(spacing: 4) {
                            Text("Plan as of \(tempPlanDate.formatted(date: .abbreviated, time: .omitted))")
                            Text("• \(tempStrategyDisplay)\(tempBudgetText)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        HStack(spacing: 4) {
                            Text("Current inputs")
                            Text("• \(tempStrategyDisplay)\(tempBudgetText)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Projection plan")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                // Prefill strategy
                switch settings.defaultPayoffStrategyRaw {
                case "snowball": tempStrategy = .snowball
                case "avalanche": tempStrategy = .avalanche
                default: tempStrategy = .minimumsOnly
                }
                // Prefill budget with Net for Debt if enabled
                if settings.useNetForDebtBudgetDefault {
                    let net = computedMonthlyNet
                    if net > 0 { tempMonthlyBudget = formatAmount(net) }
                }
                // Ensure any prefilled numeric budget is formatted to the user's currency
                let trimmed = tempMonthlyBudget.trimmingCharacters(in: .whitespacesAndNewlines)
                if let d = parseCurrencyInput(trimmed) {
                    tempMonthlyBudget = formatAmount(d)
                }
            }
            .onChange(of: focusedField) { _, newValue in
                if newValue == .monthlyBudget {
                    selectAllInFirstResponder()
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    PlanToolbarButton("Set Plan") {
                        budgetValidationError = nil
                        let parsedBudget: Decimal? = {
                            if tempMonthlyBudget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                return nil
                            } else {
                                return parseCurrencyInput(tempMonthlyBudget)
                            }
                        }()
                        if tempStrategy != .minimumsOnly && parsedBudget == nil {
                            budgetValidationError = "Please enter a valid budget amount or select the Minimums Only strategy."
                            planErrorMessage = "Please enter a valid budget amount or select the Minimums Only strategy."
                            showPlanErrorAlert = true
                            return
                        }
                        appliedPlanMode = tempPlanMode
                        appliedPlanDate = (tempPlanMode == .projectedAtDate) ? tempPlanDate : nil
                        appliedStrategy = tempStrategy
                        appliedBudget = parsedBudget
                        
                        let filteredAccounts = accounts.filter { acct in
                            let baseBal = absDecimal(latestBalance(acct))
                            let bal: Decimal = {
                                if let plan = appliedPlanDate, appliedPlanMode == .projectedAtDate {
                                    return absProjectedOrBase(for: acct, planDate: plan, base: baseBal)
                                } else {
                                    return baseBal
                                }
                            }()
                            return bal > 0
                        }
                        
                        let debts: [Debt] = filteredAccounts.map { acct in
                            let baseBal = absDecimal(latestBalance(acct))
                            let bal: Decimal = {
                                if let plan = appliedPlanDate, appliedPlanMode == .projectedAtDate {
                                    return absProjectedOrBase(for: acct, planDate: plan, base: baseBal)
                                } else {
                                    return baseBal
                                }
                            }()
                            let minPayment = monthlyPayment(for: acct, balance: bal)
                            return Debt(
                                id: acct.id,
                                name: acct.name,
                                balance: bal,
                                apr: acct.loanTerms?.apr,
                                minPayment: minPayment
                            )
                        }

                        let budgetToUse: Decimal
                        if appliedStrategy == .minimumsOnly {
                            budgetToUse = debts.reduce(0) { $0 + $1.minPayment }
                        } else {
                            budgetToUse = appliedBudget ?? 0
                        }

                        let debtInputs: [DebtInput] = debts.map { d in
                            DebtInput(
                                id: d.id,
                                name: d.name,
                                apr: d.apr,
                                balance: d.balance,
                                minPayment: d.minPayment
                            )
                        }
                        let startDateForPlan = normalizeToMonth(
                            appliedPlanMode == .projectedAtDate ? (appliedPlanDate ?? Date()) : Date()
                        )
                        do {
                            let planResult = try DebtPayoffEngine.plan(
                                debts: debtInputs,
                                monthlyBudget: budgetToUse,
                                strategy: appliedStrategy,
                                startDate: startDateForPlan
                            )
                            currentPlan = planResult
                            showPlanSheet = false
                        } catch DebtPlanError.infeasibleBudget {
                            budgetValidationError = "The budget is too low to cover minimum payments. Please increase your budget or choose Minimums Only strategy."
                            planErrorMessage = "The budget is too low to cover minimum payments. Please increase your budget or choose Minimums Only strategy."
                            showPlanErrorAlert = true
                        } catch {
                            budgetValidationError = "An unexpected error occurred."
                            planErrorMessage = "An unexpected error occurred."
                            showPlanErrorAlert = true
                        }
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    PlanToolbarButton("Cancel",fixedWidth: 70) {
                        appliedPlanDate = nil
                        appliedPlanMode = .currentInputs
                        appliedStrategy = .minimumsOnly
                        appliedBudget = nil
                        tempPlanDate = Date()
                        tempPlanMode = .currentInputs
                        tempStrategy = .minimumsOnly
                        tempMonthlyBudget = ""
                        budgetValidationError = nil
                        currentPlan = nil
                        showPlanSheet = false
                        showPlanErrorAlert = false
                        planErrorMessage = nil
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Button { focusPrevious() } label: { Image(systemName: "chevron.left") }
                    Button { focusNext() } label: { Image(systemName: "chevron.right") }
                    Spacer()
                    Button { commitAndDismissKeyboard() } label: { Image(systemName: "checkmark") }
                }
                #if os(iOS)
                if isPhone, focusedField == .monthlyBudget {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            commitAndDismissKeyboard()
                        } label: {
                            Image(systemName: "keyboard.chevron.compact.down")
                        }
                        .accessibilityIdentifier("dismissKeyboardButton")
                        .help("Dismiss Keyboard")
                    }
                }
                #endif
            }
            .alert("Can't set plan", isPresented: $showPlanErrorAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(planErrorMessage ?? "")
            }
        }
    }

    // MARK: - Keyboard handling

    private var focusOrder: [FocusField] { [.monthlyBudget] }

    private func focusPrevious() {
        guard !focusOrder.isEmpty else { return }
        if let current = focusedField, let idx = focusOrder.firstIndex(of: current) {
            let newIdx = (idx - 1 + focusOrder.count) % focusOrder.count
            focusedField = focusOrder[newIdx]
        } else {
            focusedField = focusOrder.last
        }
    }

    private func focusNext() {
        guard !focusOrder.isEmpty else { return }
        if let current = focusedField, let idx = focusOrder.firstIndex(of: current) {
            let newIdx = (idx + 1) % focusOrder.count
            focusedField = focusOrder[newIdx]
        } else {
            focusedField = focusOrder.first
        }
    }

    private func commitAndDismissKeyboard() {
        let trimmed = tempMonthlyBudget.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = parseCurrencyInput(trimmed) {
            tempMonthlyBudget = formatAmount(d)
        }
        focusedField = nil
        #if canImport(UIKit)
        let keyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        keyWindow?.endEditing(true)
        #endif
    }
    private func selectAllInFirstResponder(after delay: TimeInterval = 0.05) {
        #if canImport(UIKit)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            UIApplication.shared.sendAction(#selector(UIResponder.selectAll(_:)), to: nil, from: nil, for: nil)
        }
        #endif
    }
    // MARK: - Rows

    private func planHeader(compact: Bool) -> some View {
        HStack {
            Spacer()
            if appliedPlanMode == .projectedAtDate, let date = appliedPlanDate {
                HStack(spacing: 4) {
                    Text("Plan as of \(date.formatted(date: .abbreviated, time: .omitted))")
                        .font(compact ? .caption2 : .caption)
                        .foregroundStyle(.secondary)
                    Text("• \(appliedStrategyDisplay)\(appliedBudgetText)")
                        .font(compact ? .caption2 : .caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 4) {
                    Text("Current inputs")
                        .font(compact ? .caption2 : .caption)
                        .foregroundStyle(.secondary)
                    Text("• \(appliedStrategyDisplay)\(appliedBudgetText)")
                        .font(compact ? .caption2 : .caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
    
    private var appliedStrategyDisplay: String {
        switch appliedStrategy {
        case .minimumsOnly: return "Minimums"
        case .snowball: return "Snowball"
        case .avalanche: return "Avalanche"
        }
    }
    private var appliedBudgetText: String {
        guard let b = appliedBudget, appliedStrategy != .minimumsOnly else { return "" }
        return " • Budget: \(formatAmount(b))"
    }
    
    private var planSubtitleText: String {
        if appliedPlanMode == .projectedAtDate, let date = appliedPlanDate {
            return "Plan as of \(date.formatted(date: .abbreviated, time: .omitted)) • \(appliedStrategyDisplay)\(appliedBudgetText)"
        } else {
            return "Current inputs • \(appliedStrategyDisplay)\(appliedBudgetText)"
        }
    }

    private var tempStrategyDisplay: String {
        switch tempStrategy {
        case .minimumsOnly: return "Minimums"
        case .snowball: return "Snowball"
        case .avalanche: return "Avalanche"
        }
    }

    private var tempBudgetText: String {
        guard tempStrategy != .minimumsOnly else { return "" }
        let trimmed = tempMonthlyBudget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let d = parseCurrencyInput(trimmed) {
            return " • Budget: \(formatAmount(d))"
        } else {
            return " • Budget: —"
        }
    }

    private func headerRow(compact: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: compact ? 2 : 12) {
            Text("Account")
                .frame(width: compact ? 100 : 150, alignment: .leading)
                .font(compact ? .caption2 : .caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text("APR")
                .frame(width: compact ? 60 : 80, alignment: .trailing)
                .font(compact ? .caption2 : .caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text("Balance")
                .frame(width: compact ? 100 : 110, alignment: .trailing)
                .font(compact ? .caption2 : .caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text("Payment/mo")
                .frame(width: compact ? 100 : 110, alignment: .trailing)
                .font(compact ? .caption2 : .caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text("Interest/mo")
                .frame(width: compact ? 100 : 110, alignment: .trailing)
                .font(compact ? .caption2 : .caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text("After Payment")
                .frame(width: compact ? 110 : 130, alignment: .trailing)
                .font(compact ? .caption2 : .caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text("Payoff")
                .frame(width: compact ? 110 : 120, alignment: .trailing)
                .font(compact ? .caption2 : .caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    private func row(for account: Account, compact: Bool) -> some View {
        let baseBal = absDecimal(latestBalance(account))
        let usedBal: Decimal = {
            if let plan = appliedPlanDate, appliedPlanMode == .projectedAtDate {
                return absProjectedOrBase(for: account, planDate: plan, base: baseBal)
            } else {
                return baseBal
            }
        }()
        let apr = account.loanTerms?.apr
        let planMonth = currentPlan?.months.first
        let payment = planMonth?.payments[account.id] ?? monthlyPayment(for: account, balance: usedBal)
        let step: (interest: Decimal, afterPaymentBalance: Decimal) = {
            if let m = planMonth, let i = m.interest[account.id], let after = m.balances[account.id] {
                return (i, after)
            } else {
                return monthStep(for: account, balance: usedBal, payment: payment)
            }
        }()

        let payoff: Date? = {
            // If a plan is applied, prefer its payoff date for this account
            if let planDate = currentPlan?.payoffDates[account.id] {
                return planDate
            }
            // Fallback: compute per-account payoff using current inputs as of the selected date
            let asOfDate = (appliedPlanMode == .projectedAtDate) ? (appliedPlanDate ?? Date()) : Date()
            return PayoffCalculator.payoffDate(for: account, asOf: asOfDate)
        }()

        return HStack(alignment: .firstTextBaseline, spacing: compact ? 2 : 12) {
            VStack(alignment: .leading, spacing: compact ? 1 : 2) {
                Text(account.name)
                    .font(compact ? .subheadline : .headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .truncationMode(.tail)
                Text(account.type == .loan ? "Loan" : "Credit Card")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: compact ? 100 : 150, alignment: .leading)

            Text(formatAPR(apr, scale: account.loanTerms?.aprScale, compact: compact))
                .font(compact ? .footnote : .body)
                .frame(width: compact ? 60 : 80, alignment: .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text(formatAmount(usedBal))
                .font(compact ? .footnote : .body)
                .frame(width: compact ? 100 : 110, alignment: .trailing)
                .foregroundStyle(.red)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text(formatAmount(payment))
                .font(compact ? .footnote : .body)
                .frame(width: compact ? 100 : 110, alignment: .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text(formatAmount(step.interest))
                .font(compact ? .footnote : .body)
                .frame(width: compact ? 100 : 110, alignment: .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text(formatAmount(step.afterPaymentBalance))
                .font(compact ? .footnote : .body)
                .frame(width: compact ? 110 : 130, alignment: .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Group {
                if let payoff = payoff {
                    Text(payoff.formatted(date: .abbreviated, time: .omitted))
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            .font(compact ? .footnote : .body)
            .frame(width: compact ? 110 : 120, alignment: .trailing)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
        }
    }

    private func totalRow(compact: Bool) -> some View {
        let totals = totalsForAccounts(accounts)
        return HStack(alignment: .firstTextBaseline, spacing: compact ? 2 : 12) {
            Text("Total")
                .font(compact ? .subheadline : .headline)
                .frame(width: compact ? 100 : 150, alignment: .leading)
            Text("")
                .frame(width: compact ? 60 : 80)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(formatAmount(totals.balance))
                .font(compact ? .footnote : .body)
                .frame(width: compact ? 100 : 110, alignment: .trailing)
                .foregroundStyle(.red)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(formatAmount(totals.payment))
                .font(compact ? .footnote : .body)
                .frame(width: compact ? 100 : 110, alignment: .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(formatAmount(totals.interest))
                .font(compact ? .footnote : .body)
                .frame(width: compact ? 100 : 110, alignment: .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(formatAmount(totals.afterPayment))
                .font(compact ? .footnote : .body)
                .frame(width: compact ? 110 : 130, alignment: .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text("")
                .frame(width: compact ? 110 : 120)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    // MARK: - Data loading

    @Sendable private func load() async {
        do {
            let all = try modelContext.fetch(FetchDescriptor<Account>())
            await MainActor.run {
                self.accounts = all.filter { $0.type == .loan || $0.type == .creditCard }
            }
        } catch {
            await MainActor.run { self.accounts = [] }
        }
    }

    // MARK: - Calculations

    private func latestBalance(_ account: Account) -> Decimal {
        let id = account.id
        let pred = #Predicate<BalanceSnapshot> { $0.account?.id == id }
        var desc = FetchDescriptor<BalanceSnapshot>(predicate: pred)
        desc.sortBy = [SortDescriptor(\BalanceSnapshot.asOfDate, order: .reverse)]
        desc.fetchLimit = 1
        let snap = try? modelContext.fetch(desc).first
        return snap?.balance ?? 0
    }

    private func latestSnapshotDate(_ account: Account) -> Date? {
        let id = account.id
        let pred = #Predicate<BalanceSnapshot> { $0.account?.id == id }
        var desc = FetchDescriptor<BalanceSnapshot>(predicate: pred)
        desc.sortBy = [SortDescriptor(\BalanceSnapshot.asOfDate, order: .reverse)]
        desc.fetchLimit = 1
        return try? modelContext.fetch(desc).first?.asOfDate
    }

    private func monthlyPayment(for account: Account, balance: Decimal) -> Decimal {
        // Use user's typical payment if provided; otherwise estimate at 2% of balance
        if let configured = account.loanTerms?.paymentAmount, configured > 0 {
            return configured
        }
        let twoPercent = Decimal(string: "0.02") ?? 0.02
        return (balance * twoPercent).rounded(2)
    }

    private func monthStep(for account: Account, balance: Decimal) -> (interest: Decimal, afterPaymentBalance: Decimal) {
        let apr = account.loanTerms?.apr ?? 0
        let payment = monthlyPayment(for: account, balance: balance)
        let effectivePayment = min(payment, balance)
        let interestBase = balance - effectivePayment
        let interest = (apr * interestBase / 12).rounded(2)
        let after = (interestBase + interest).rounded(2)
        return (interest, after)
    }
    
    private func monthStep(for account: Account, balance: Decimal, payment: Decimal) -> (interest: Decimal, afterPaymentBalance: Decimal) {
        let apr = account.loanTerms?.apr ?? 0
        let effectivePayment = min(payment, balance)
        let interestBase = balance - effectivePayment
        let interest = (apr * interestBase / 12).rounded(2)
        let after = (interestBase + interest).rounded(2)
        return (interest, after)
    }

    private func isCompactLayout(_ size: CGSize) -> Bool {
        return size.width < 1000
    }

    // MARK: - Formatting and helpers

    private func formatAmount(_ amount: Decimal?) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = settings.currencyCode
        guard let amount = amount else { return "—" }
        return nf.string(from: NSDecimalNumber(decimal: amount)) ?? "\(amount)"
    }

    private func formatAPR(_ apr: Decimal?, scale: Int? = nil, compact: Bool = false) -> String {
        guard let apr else { return "—" }
        let nf = NumberFormatter()
        nf.numberStyle = .percent
        if compact {
            nf.minimumFractionDigits = 0
            nf.maximumFractionDigits = 2
        } else if let s = scale {
            nf.minimumFractionDigits = s
            nf.maximumFractionDigits = s
        } else {
            nf.minimumFractionDigits = 3
            nf.maximumFractionDigits = 4
        }
        return nf.string(from: NSDecimalNumber(decimal: apr)) ?? "\(apr)"
    }

    private func dateInSameMonth(_ date: Date, withDay targetDay: Int) -> Date {
        let cal = Calendar.current
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: date))!
        let range = cal.range(of: .day, in: .month, for: monthStart)!
        let clampedDay = min(max(1, targetDay), range.count)
        var comps = cal.dateComponents([.year, .month], from: monthStart)
        comps.day = clampedDay
        return cal.date(from: comps) ?? date
    }

    private func normalizeToMonth(_ date: Date) -> Date {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: date)
        return cal.date(from: comps) ?? date
    }

    private func projectionPoint(_ points: [DebtProjectionPoint], closestTo date: Date) -> DebtProjectionPoint? {
        let cal = Calendar.current
        let sorted = points.sorted { $0.date < $1.date }
        if let exact = sorted.first(where: { cal.isDate($0.date, equalTo: date, toGranularity: .month) }) {
            return exact
        }
        return sorted.last(where: { $0.date <= date }) ?? sorted.first
    }

    private func projectedBalance(for account: Account, on targetDate: Date) throws -> Decimal? {
        let targetMonth = normalizeToMonth(targetDate)
        let result = try PayoffCalculator.project(for: account, asOf: targetMonth)
        if let point = projectionPoint(result.points, closestTo: targetMonth) {
            return point.balance
        }
        return nil
    }

    private func absDecimal(_ d: Decimal) -> Decimal { d < 0 ? -d : d }

    private func absProjectedOrBase(for account: Account, planDate: Date, base: Decimal) -> Decimal {
        do {
            if let projected = try projectedBalance(for: account, on: planDate) {
                return absDecimal(projected)
            }
        } catch {
            // If projection fails, fall back to base
        }
        return base
    }

    private func totalsForAccounts(_ accts: [Account]) -> (balance: Decimal, payment: Decimal, interest: Decimal, afterPayment: Decimal) {
        var totalBalance: Decimal = 0
        var totalPayment: Decimal = 0
        var totalInterest: Decimal = 0
        var totalAfter: Decimal = 0
        
        let planMonth = currentPlan?.months.first

        for acct in accts {
            let base = absDecimal(latestBalance(acct))
            let bal: Decimal = {
                if let plan = appliedPlanDate, appliedPlanMode == .projectedAtDate {
                    return absProjectedOrBase(for: acct, planDate: plan, base: base)
                } else {
                    return base
                }
            }()
            totalBalance += bal
            
            let pay: Decimal = planMonth?.payments[acct.id] ?? monthlyPayment(for: acct, balance: bal)
            totalPayment += pay
            
            if let m = planMonth, let i = m.interest[acct.id], let after = m.balances[acct.id] {
                totalInterest += i
                totalAfter += after
            } else {
                let step = monthStep(for: acct, balance: bal, payment: pay)
                totalInterest += step.interest
                totalAfter += step.afterPaymentBalance
            }
        }
        return (totalBalance, totalPayment, totalInterest, totalAfter)
    }
    
    private func parseCurrencyInput(_ input: String) -> Decimal? {
        let filtered = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
        return Decimal(string: filtered)
    }
    
    // MARK: - Income & Bills helpers
    
    private func allCashFlowItems() -> [CashFlowItem] {
        do {
            return try modelContext.fetch(FetchDescriptor<CashFlowItem>())
        } catch {
            return []
        }
    }
    
    private func monthlyEquivalent(amount: Decimal, frequency: PaymentFrequency) -> Decimal {
        return amount * frequency.monthlyEquivalentFactor
    }
    
    private var computedMonthlyIncome: Decimal {
        let items = allCashFlowItems().filter { $0.isIncome }
        return items.reduce(0) { acc, item in
            acc + monthlyEquivalent(amount: item.amount, frequency: item.frequency)
        }
    }
    
    private var computedMonthlyBills: Decimal {
        let items = allCashFlowItems().filter { !$0.isIncome }
        return items.reduce(0) { acc, item in
            acc + monthlyEquivalent(amount: item.amount, frequency: item.frequency)
        }
    }
    
    private var computedMonthlyNet: Decimal {
        computedMonthlyIncome - computedMonthlyBills
    }
}

#if canImport(UIKit)
import UIKit

// A hosting controller that restricts orientation to landscape on iPhone and logs diagnostics.
final class LandscapeOnlyHostingController<Content: View>: UIHostingController<Content> {
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        if UIDevice.current.userInterfaceIdiom == .phone {
            return [.landscapeLeft, .landscapeRight]
        } else {
            // Do not restrict iPad
            return super.supportedInterfaceOrientations
        }
    }

    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        // Choose a preferred initial orientation
        return .landscapeRight
    }

    private func maskDescription(_ mask: UIInterfaceOrientationMask) -> String {
        var parts: [String] = []
        if mask.contains(.portrait) { parts.append("portrait") }
        if mask.contains(.portraitUpsideDown) { parts.append("portraitUpsideDown") }
        if mask.contains(.landscapeLeft) { parts.append("landscapeLeft") }
        if mask.contains(.landscapeRight) { parts.append("landscapeRight") }
        if mask.isEmpty { parts.append("(empty)") }
        return parts.joined(separator: ", ")
    }

    private func logOrientationDiagnostics(tag: String) {
        // Empty implementation after logging removal
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        logOrientationDiagnostics(tag: "willAppear")
        setNeedsUpdateOfSupportedInterfaceOrientations()
        // Proactively request a landscape geometry update on iPhone
        if UIDevice.current.userInterfaceIdiom == .phone {
            if #available(iOS 16.0, *) {
                if let scene = view.window?.windowScene {
                    scene.requestGeometryUpdate(.iOS(interfaceOrientations: [.landscapeLeft, .landscapeRight]))
                }
            }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        logOrientationDiagnostics(tag: "didAppear")
        setNeedsUpdateOfSupportedInterfaceOrientations()
        // Request landscape again after presentation to nudge rotation if needed
        if UIDevice.current.userInterfaceIdiom == .phone {
            if #available(iOS 16.0, *) {
                if let scene = view.window?.windowScene {
                    scene.requestGeometryUpdate(.iOS(interfaceOrientations: [.landscapeLeft, .landscapeRight]))
                }
            }
        }
    }
}

/// A SwiftUI wrapper that hosts its content in a controller that only supports landscape on iPhone.
struct LandscapeOnly<Content: View>: UIViewControllerRepresentable {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeUIViewController(context: Context) -> LandscapeOnlyHostingController<Content> {
        let vc = LandscapeOnlyHostingController(rootView: content)
        return vc
    }

    func updateUIViewController(_ vc: LandscapeOnlyHostingController<Content>, context: Context) {
        vc.rootView = content
        vc.setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}

/// Convenience wrapper for presenting the Debt Summary in landscape-only on iPhone.
struct DebtSummaryLandscapeHost: View {
    var body: some View {
        LandscapeOnly {
            DebtSummaryView()
                .ignoresSafeArea() // Use the full screen in landscape
        }
    }
}

/// Convenience modifier so callers can do `DebtSummaryView().landscapeOnlyOnPhone()` if desired.
extension View {
    func landscapeOnlyOnPhone() -> some View {
        LandscapeOnly { self }
    }
}
#endif

private extension Decimal {
    func rounded(_ scale: Int) -> Decimal {
        var value = self
        var result = Decimal()
        NSDecimalRound(&result, &value, scale, .bankers)
        return result
    }
}

#if canImport(UIKit)
extension UIView {
    func findFirstResponder() -> UIResponder? {
        if self.isFirstResponder { return self }
        for sub in subviews {
            if let responder = sub.findFirstResponder() {
                return responder
            }
        }
        return nil
    }
}
#endif





