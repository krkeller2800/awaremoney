// DebtPayoffView.swift
// SwiftUI UI that integrates with Account + SwiftData using DebtPayoffViewModel

import SwiftUI
import SwiftData
import UIKit

struct DebtPayoffView: View {
    @StateObject var viewModel: DebtPayoffViewModel
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.locale) private var locale
    @Environment(\.modelContext) private var modelContext

    // Plan-driven state for this account
    @State private var plannedPayment: Decimal? = nil
    @State private var plannedPayoffDate: Date? = nil
    @State private var planComputeError: String? = nil
    @State private var currentPlan: DebtPlanResult? = nil

    // Settings that drive the global plan
    @AppStorage("debtPlanStartModeRaw") private var debtPlanStartModeRaw: String = "currentInputs"
    @AppStorage("debtPlanStartDate") private var debtPlanStartDateEpoch: Double = 0
    @AppStorage("useFixedDebtBudget") private var useFixedDebtBudget: Bool = false
    @AppStorage("debtBudgetOverrideAmount") private var debtBudgetOverrideAmount: Double = 0
    @AppStorage("baselineBudgetSourceRaw") private var baselineBudgetSourceRaw: String = "recurringNet"
    @AppStorage("includeNonMonthlyIncomeSpreads") private var includeNonMonthlyIncomeSpreads: Bool = true
    @AppStorage("oneTimeIncomeDefaultSpreadMonths") private var oneTimeIncomeDefaultSpreadMonths: Int = 12

    @State private var aprInput: String = ""
    @State private var typicalPaymentInput: String = ""

    enum Field: Hashable { case apr, typical }
    @FocusState private var focusedField: Field?

    private var isEditing: Bool { focusedField != nil }

    private var focusOrder: [Field] { [.apr, .typical] }

    private var canGoPrevious: Bool {
        guard let focusedField, let idx = focusOrder.firstIndex(of: focusedField) else { return false }
        return idx > 0
    }

    private var canGoNext: Bool {
        guard let focusedField, let idx = focusOrder.firstIndex(of: focusedField) else { return false }
        return idx < focusOrder.count - 1
    }

    private func focusField(_ field: Field) {
        focusedField = field
        // Ensure selection happens after focus
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            selectAllInFirstResponder()
        }
    }

    var body: some View {
        List {
            if UIDevice.type == "iPhone" {
                Section("Account") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(viewModel.account.name).font(.headline)
                        Text(viewModel.account.institutionName ?? "").font(.subheadline).foregroundStyle(.secondary)
                        Text(viewModel.account.type.rawValue.capitalized).font(.subheadline).foregroundStyle(.secondary)
                    }
                    if let last = viewModel.account.balanceSnapshots.sorted(by: { $0.asOfDate > $1.asOfDate }).first {
                        LabeledContent("Baseline") {
                            VStack(alignment: .trailing) {
                                Text(last.asOfDate, style: .date)
                                Text(formatCurrency(abs(last.balance)))
                            }
                        }
                    }
                }
            }

            Section("Plan") {
                if let err = planComputeError {
                    Text(err)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.red)
                }
                if let pp = plannedPayment {
                    LabeledContent("Payment (plan for this month)") {
                        Text(formatCurrency(pp))
                    }
                }
                if let pd = plannedPayoffDate {
                    LabeledContent("Payoff (plan)") {
                        Text(pd, style: .date)
                    }
                }
                if plannedPayment == nil && plannedPayoffDate == nil && planComputeError == nil {
                    Text("No plan results available.")
                        .foregroundStyle(.secondary)
                }
            }

            let cutoff = plannedPayoffDate ?? Date()
            let calendar = Calendar.current
            Section("Schedule (Monthly)") {
                if let plan = currentPlan {
                    // Use the plan’s per‑month data (which already includes variable budget from Income & Bills)
                    let rows = Array(plan.months.enumerated()).filter { (_, month) in
                        let monthDate = calendar.startOfDay(for: month.date)
                        let cutoffDate = calendar.startOfDay(for: cutoff)
                        return monthDate <= cutoffDate
                    }

                    if rows.isEmpty {
                        Text("No schedule available.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(rows, id: \.0) { index, month in
                            let id = viewModel.account.id
                            let afterBal = month.balances[id] ?? 0
                            let payment = month.payments[id] ?? 0
                            let interest = month.interest[id] ?? 0

                            // Prior month balance is the starting point for this month.
                            // For the first plan month, reconstruct the starting balance using:
                            // start = after + payment - interest
                            let priorBal: Decimal = {
                                if index > 0 {
                                    let prevMonth = rows[index - 1].1
                                    return prevMonth.balances[id] ?? 0
                                } else {
                                    return afterBal + payment - interest
                                }
                            }()

                            DisclosureGroup {
                                VStack(alignment: .trailing, spacing: 6) {
                                    HStack {
                                        Text("Prior month balance")
                                        Spacer()
                                        Text(formatCurrency(priorBal)).monospacedDigit()
                                    }
                                    HStack {
                                        Text("Payment (this month)")
                                        Spacer()
                                        Text("− " + formatCurrency(payment)).monospacedDigit()
                                            .foregroundStyle(.secondary)
                                    }
                                    HStack {
                                        Text("Interest (this month)")
                                        Spacer()
                                        Text("+ " + formatCurrency(interest)).monospacedDigit()
                                            .foregroundStyle(.secondary)
                                    }
                                    Divider()
                                    HStack {
                                        Text("Ending balance")
                                        Spacer()
                                        Text(formatCurrency(afterBal)).monospacedDigit().bold()
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .padding(.top, 2)
                            } label: {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(month.date, style: .date)
                                    Spacer()
                                    Text(formatCurrency(afterBal)).monospacedDigit()
                                }
                            }
                        }
                    }
                } else {
                    // If no plan is available, you can keep your existing projection fallback,
                    // or encourage the user to set a plan so schedule reflects actual payments.
                    Text("No plan available for this account.")
                        .foregroundStyle(.secondary)
                }
            }
        

            Section("Disclaimers") {
                Text("Estimates only. Actual payoff depends on lender calculations, fees, and APR changes. Update with statements to improve accuracy.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Debt Payoff")
        .onAppear {
            // Seed UI fields from model
            aprInput = aprInputForUI()
            typicalPaymentInput = typicalPaymentInputForUI()
            viewModel.computeVarianceAgainstLatestStatement()
            // Compute plan results for this account
            recomputePlanForPayoffView()
        }
        .onReceive(NotificationCenter.default.publisher(for: .planSettingsDidChange)) { _ in
            recomputePlanForPayoffView()
        }
        .onReceive(NotificationCenter.default.publisher(for: .accountsDidChange)) { _ in
            recomputePlanForPayoffView()
        }
        .onChange(of: focusedField) { _, newValue in
            guard let newValue = newValue else { return }
            switch newValue {
            case .apr, .typical:
                selectAllInFirstResponder()
            }
        }
        .safeAreaInset(edge: .bottom) {
            Group {
                if isEditing {
                    EditingAccessoryBar(
                        canGoPrevious: canGoPrevious,
                        canGoNext: canGoNext,
                        onPrevious: { moveFocus(-1) },
                        onNext: { moveFocus(1) },
                        onDone: { commitAndDismissKeyboard() }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    EmptyView().frame(height: 0)
                }
            }
            .animation(.snappy, value: isEditing)
        }
    }

    private func moveFocus(_ delta: Int) {
        let order = focusOrder
        guard !order.isEmpty else { return }
        if let current = focusedField, let idx = order.firstIndex(of: current) {
            let nextIdx = max(0, min(order.count - 1, idx + delta))
            focusedField = order[nextIdx]
        } else {
            focusedField = order.first
        }
    }

    private func recomputePlanForPayoffView() {
        // Determine start date
        let startDate: Date = {
            if debtPlanStartModeRaw == "projectedAtDate", debtPlanStartDateEpoch > 0 {
                return Date(timeIntervalSince1970: debtPlanStartDateEpoch)
            } else {
                return Date()
            }
        }()
        let normalizedStart = normalizeToMonth(startDate)

        // Build debts from all liabilities using base or projected balances for the start month
        let allAccounts = (try? modelContext.fetch(FetchDescriptor<Account>())) ?? []
        let liabilities = allAccounts.filter { $0.type == .loan || $0.type == .creditCard }

        let debts: [DebtInput] = liabilities.compactMap { acct in
            let base = latestBalance(acct)
            let magBase = base < 0 ? -base : base
            let bal: Decimal = (debtPlanStartModeRaw == "projectedAtDate")
                ? absProjectedOrBase(for: acct, planDate: normalizedStart, base: magBase)
                : magBase
            guard bal > 0 else { return nil }
            let minPay = monthlyPayment(for: acct, balance: bal)
            return DebtInput(id: acct.id, name: acct.name, apr: acct.loanTerms?.apr, balance: bal, minPayment: minPay)
        }

        guard !debts.isEmpty else {
            self.plannedPayment = nil
            self.plannedPayoffDate = nil
            self.planComputeError = nil
            return
        }

        do {
            let strategy = currentStrategy()
            let plan: DebtPlanResult

            // Use monthly schedule when using recurring net or spreads; otherwise fixed budget
            if includeNonMonthlyIncomeSpreads || baselineBudgetSourceRaw == "recurringNet" {
                let items = (try? modelContext.fetch(FetchDescriptor<CashFlowItem>())) ?? []
                let schedule = IncomeScheduler.budgetByMonth(
                    items: items,
                    start: normalizedStart,
                    months: 60,
                    includeSpreads: includeNonMonthlyIncomeSpreads,
                    oneTimeDefaultSpreadMonths: sanitizedDefaultSpread(oneTimeIncomeDefaultSpreadMonths),
                    baselineSource: baselineSource()
                )
                plan = try DebtPayoffEngine.plan(
                    debts: debts,
                    budgetByMonth: schedule,
                    strategy: strategy,
                    startDate: normalizedStart
                )
            } else {
                let fixedBudget: Decimal = {
                    if useFixedDebtBudget, debtBudgetOverrideAmount > 0 {
                        return Decimal(debtBudgetOverrideAmount)
                    } else {
                        // Ensure at least minimums when not using Recurring Net
                        return debts.reduce(0) { $0 + $1.minPayment }
                    }
                }()
                plan = try DebtPayoffEngine.plan(
                    debts: debts,
                    monthlyBudget: fixedBudget,
                    strategy: strategy,
                    startDate: normalizedStart
                )
            }

            // Apply this account’s values to the UI
            self.currentPlan = plan
            self.plannedPayment = plan.months.first?.payments[viewModel.account.id]
            self.plannedPayoffDate = plan.payoffDates[viewModel.account.id]
            self.planComputeError = nil
        } catch DebtPlanError.infeasibleBudget(let requiredMin) {
            self.plannedPayment = nil
            self.plannedPayoffDate = nil
            self.currentPlan = nil
            self.planComputeError = "Budget too low to cover minimums (\(formatCurrency(requiredMin)))."
        } catch {
            self.plannedPayment = nil
            self.plannedPayoffDate = nil
            self.planComputeError = nil
            self.currentPlan = nil
        }
    }

    private func normalizeToMonth(_ date: Date) -> Date {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: date)
        return cal.date(from: comps) ?? date
    }

    private func currentStrategy() -> PayoffStrategy {
        switch settings.defaultPayoffStrategyRaw {
        case "snowball":  return .snowball
        case "avalanche": return .avalanche
        default:          return .minimumsOnly
        }
    }

    private func baselineSource() -> IncomeScheduler.BaselineSource {
        if baselineBudgetSourceRaw == "fixed", useFixedDebtBudget, debtBudgetOverrideAmount > 0 {
            return .fixedAmount(Decimal(debtBudgetOverrideAmount))
        } else {
            return .recurringNet
        }
    }

    private func sanitizedDefaultSpread(_ v: Int) -> Int { [3, 6, 12].contains(v) ? v : 12 }

    // Fallback monthly payment when a typical payment isn't set (2% of balance)
    private func monthlyPayment(for account: Account, balance: Decimal) -> Decimal {
        if let configured = account.loanTerms?.paymentAmount, configured > 0 { return configured }
        let twoPercent = Decimal(string: "0.02") ?? 0.02
        return (balance * twoPercent).rounded(scale: 2)
    }

    private func projectedBalance(for account: Account, on targetDate: Date) throws -> Decimal? {
        let targetMonth = normalizeToMonth(targetDate)
        let result = try PayoffCalculator.project(for: account, asOf: targetMonth)
        let cal = Calendar.current
        let sorted = result.points.sorted { $0.date < $1.date }
        if let exact = sorted.first(where: { cal.isDate($0.date, equalTo: targetMonth, toGranularity: .month) }) {
            return exact.balance
        }
        return sorted.last(where: { $0.date <= targetMonth })?.balance ?? sorted.first?.balance
    }

    private func absProjectedOrBase(for account: Account, planDate: Date, base: Decimal) -> Decimal {
        let magBase = base < 0 ? -base : base
        do {
            if let p = try projectedBalance(for: account, on: planDate) {
                return p < 0 ? -p : p
            }
        } catch { }
        return magBase
    }

    private func latestBalance(_ account: Account) -> Decimal {
        let id = account.id
        let pred = #Predicate<BalanceSnapshot> { $0.account?.id == id }
        var desc = FetchDescriptor<BalanceSnapshot>(predicate: pred)
        desc.sortBy = [SortDescriptor(\BalanceSnapshot.asOfDate, order: .reverse)]
        desc.fetchLimit = 1
        let snap = try? modelContext.fetch(desc).first
        return snap?.balance ?? 0
    }
    private func commitAndDismissKeyboard() {
        applyAPRIfParsable()
        applyPaymentIfParsable()
        viewModel.computeVarianceAgainstLatestStatement()
        focusedField = nil
        #if canImport(UIKit)
        let keyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        keyWindow?.endEditing(true)
        #endif
    }

    private func formatCurrency(_ amount: Decimal) -> String {
        let nf = NumberFormatter()
        nf.locale = locale
        nf.numberStyle = .currency
        nf.currencyCode = settings.currencyCode
        return nf.string(from: NSDecimalNumber(decimal: amount)) ?? "\(amount)"
    }

    private func label(for mode: CreditCardPaymentMode) -> String {
        switch mode {
        case .payInFull: return "Pay in full"
        case .fixedAmount: return "Fixed amount"
        case .minimum: return "Minimum"
        }
    }

    private func aprInputForUI() -> String {
        if let apr = viewModel.account.loanTerms?.apr {
            let nf = NumberFormatter()
            nf.numberStyle = .percent
            nf.minimumFractionDigits = 2
            nf.maximumFractionDigits = 3
            return nf.string(from: NSDecimalNumber(decimal: apr)) ?? ""
        }
        return aprInput
    }

    private func typicalPaymentInputForUI() -> String {
        if let amt = viewModel.account.loanTerms?.paymentAmount, amt > 0 {
            let nf = NumberFormatter()
            nf.locale = locale
            nf.numberStyle = .currency
            nf.currencyCode = settings.currencyCode
            return nf.string(from: NSDecimalNumber(decimal: amt)) ?? ""
        }
        return typicalPaymentInput
    }

    private func applyAPRIfParsable() {
        // Accept either % or raw fraction input
        let cleaned = aprInput.replacingOccurrences(of: "%", with: "").replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        if let val = Decimal(string: cleaned) {
            let aprFraction = val > 1 ? (val / 100) : val
            viewModel.setAPR(aprFraction)
        }
    }

    private func applyPaymentIfParsable() {
        // Prefer parsing with currency formatter respecting locale and settings
        let currencyFormatter = NumberFormatter()
        currencyFormatter.locale = locale
        currencyFormatter.numberStyle = .currency
        currencyFormatter.currencyCode = settings.currencyCode

        if let number = currencyFormatter.number(from: typicalPaymentInput) {
            let value = number.decimalValue
            viewModel.setTypicalPaymentAmount(value)
            if let formatted = currencyFormatter.string(from: number), formatted != typicalPaymentInput {
                typicalPaymentInput = formatted
            }
            return
        }

        // Fallback to decimal formatter
        let decimalFormatter = NumberFormatter()
        decimalFormatter.locale = locale
        decimalFormatter.numberStyle = .decimal
        if let number = decimalFormatter.number(from: typicalPaymentInput) {
            let value = number.decimalValue
            viewModel.setTypicalPaymentAmount(value)
            if let formatted = currencyFormatter.string(from: number) {
                typicalPaymentInput = formatted
            }
            return
        }

        // Last resort: sanitize input by keeping digits and decimal separator
        let decimalSeparator = locale.decimalSeparator ?? "."
        let allowedChars = Set("0123456789" + decimalSeparator)
        let sanitized = typicalPaymentInput.filter { allowedChars.contains($0) }
            .replacingOccurrences(of: decimalSeparator, with: ".")
            .trimmingCharacters(in: .whitespaces)

        if let val = Decimal(string: sanitized) {
            viewModel.setTypicalPaymentAmount(val)
            if let formatted = currencyFormatter.string(from: NSDecimalNumber(decimal: val)) {
                typicalPaymentInput = formatted
            }
        }
    }

    // Select-all helpers for UIKit-backed TextFields
    private func selectAllInFirstResponder() {
        DispatchQueue.main.async {
            let keyWindow = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first(where: { $0.isKeyWindow })

            guard let window = keyWindow, let responder = window.findFirstResponder() else { return }

            if let tf = responder as? UITextField {
                tf.selectAll(nil)
            } else if let tv = responder as? UITextView {
                tv.selectAll(nil)
            }
        }
    }
}

#Preview {
    Text("Preview requires model data")
}

