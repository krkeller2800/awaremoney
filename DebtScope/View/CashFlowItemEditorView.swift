import SwiftUI
import SwiftData
#if os(iOS)
import UIKit
#endif

public struct CashFlowItemEditorView: View {
    let item: CashFlowItem
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: SettingsStore
    @Query(sort: [SortDescriptor(\Account.name, order: .forward)]) private var accounts: [Account]
    @Query(sort: [SortDescriptor(\CashFlowItem.name, order: .forward)]) private var cashFlowItems: [CashFlowItem]
    @Query private var fundingAllocations: [BillFundingAllocation]

    // Editable state
    @State private var name: String = ""
    @State private var amountValue: Decimal = 0
    @State private var frequency: PaymentFrequency = .monthly
    @State private var dayOfMonth: Int? = nil
    @State private var firstPaymentDate: Date? = nil
    @State private var notes: String = ""
    @State private var ssaWednesday: Int? = nil
    @State private var oneTimeSpreadMonthsOverride: Int? = nil

    @State private var initialized = false

    @FocusState private var focusedField: FocusField?
    @State private var nameIsFirstResponder: Bool = false
    @State private var amountIsFirstResponder: Bool = false
    @State private var notesIsFirstResponder: Bool = false
    @State private var reserveAmountIsFirstResponder: Bool = false
    @State private var allocationAmountFirstResponderID: UUID? = nil
    @State private var showRebaseConfirm: Bool = false
    @State private var showFrequencyPicker: Bool = false
    @State private var showDayOfMonthPicker: Bool = false
    @State private var showFirstPaymentDatePicker: Bool = false

    @State private var originalSchedule: ScheduleSignature? = nil
    @State private var lastPromptedSchedule: ScheduleSignature? = nil

    // Editing state and keyboard navigation
    private var isEditing: Bool {
        nameIsFirstResponder || amountIsFirstResponder || notesIsFirstResponder || reserveAmountIsFirstResponder || allocationAmountFirstResponderID != nil || (focusedField != nil)
    }
    private var showBottomAccessoryBar: Bool {
        return isEditing
    }

    private var currentFocusField: FocusField? {
        if nameIsFirstResponder { return .name }
        if amountIsFirstResponder { return .amount }
        if notesIsFirstResponder { return .notes }
        if reserveAmountIsFirstResponder { return .reserveAmount }
        if let allocationAmountFirstResponderID { return .allocationAmount(allocationAmountFirstResponderID) }
        if let f = focusedField { return f }
        return nil
    }

    private var canGoPrevious: Bool {
        guard let current = currentFocusField, let idx = focusOrder.firstIndex(of: current) else { return false }
        return idx > 0
    }

    private var canGoNext: Bool {
        guard let current = currentFocusField, let idx = focusOrder.firstIndex(of: current) else { return false }
        return idx < focusOrder.count - 1
    }

    private func commitAndDismissKeyboard() {
        applyChanges()
        // Clear focus and dismiss keyboard
        nameIsFirstResponder = false
        amountIsFirstResponder = false
        notesIsFirstResponder = false
        reserveAmountIsFirstResponder = false
        allocationAmountFirstResponderID = nil
        focusedField = nil
        #if canImport(UIKit)
        let keyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        keyWindow?.endEditing(true)
        #endif
//        dismiss()
    }

    private func dismissKeyboardOnly() {
        nameIsFirstResponder = false
        amountIsFirstResponder = false
        notesIsFirstResponder = false
        reserveAmountIsFirstResponder = false
        allocationAmountFirstResponderID = nil
        focusedField = nil
        #if canImport(UIKit)
        let keyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        keyWindow?.endEditing(true)
        #endif
    }

    @MainActor private func selectAllInFirstResponder(after delay: TimeInterval = 0.05) {
        #if canImport(UIKit)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            UIApplication.shared.sendAction(#selector(UIResponder.selectAll(_:)), to: nil, from: nil, for: nil)
        }
        #endif
    }

    private struct ScheduleSignature: Equatable {
        let anchorMonth: Int
        let dueDay: Int
        let freqMonths: Int
    }

    private enum FocusField: Hashable {
        case name, amount, notes, reserveAmount, allocationAmount(UUID)
    }

    private var isReserveFieldVisible: Bool {
        if item.kind == .bill {
            let working = buildWorkingItem()
            return BillReservePlanner.planReserve(for: working, asOf: Date(), currentReserve: item.reserveBalance) != nil
        } else {
            return false
        }
    }

    private var focusOrder: [FocusField] {
        var order: [FocusField] = [.name, .amount, .notes]
        order.append(contentsOf: eligibleFundingIncomes.map { .allocationAmount($0.id) })
        if isReserveFieldVisible { order.append(.reserveAmount) }
        return order
    }

    private func moveFocus(_ direction: Int) {
        guard !focusOrder.isEmpty else { return }
        func activate(_ field: FocusField) {
            switch field {
            case .name:
                DispatchQueue.main.async {
                    self.nameIsFirstResponder = true
                    self.amountIsFirstResponder = false
                    self.notesIsFirstResponder = false
                    self.reserveAmountIsFirstResponder = false
                    self.allocationAmountFirstResponderID = nil
                    self.focusedField = .name
                }
            case .amount:
                DispatchQueue.main.async {
                    self.nameIsFirstResponder = false
                    self.amountIsFirstResponder = true
                    self.notesIsFirstResponder = false
                    self.reserveAmountIsFirstResponder = false
                    self.allocationAmountFirstResponderID = nil
                    self.focusedField = .amount
                }
            case .notes:
                DispatchQueue.main.async {
                    self.nameIsFirstResponder = false
                    self.amountIsFirstResponder = false
                    self.notesIsFirstResponder = true
                    self.reserveAmountIsFirstResponder = false
                    self.allocationAmountFirstResponderID = nil
                    self.focusedField = .notes
                }
            case .reserveAmount:
                DispatchQueue.main.async {
                    self.nameIsFirstResponder = false
                    self.amountIsFirstResponder = false
                    self.notesIsFirstResponder = false
                    self.reserveAmountIsFirstResponder = true
                    self.allocationAmountFirstResponderID = nil
                    self.focusedField = .reserveAmount
                }
            case .allocationAmount(let incomeID):
                DispatchQueue.main.async {
                    self.nameIsFirstResponder = false
                    self.amountIsFirstResponder = false
                    self.notesIsFirstResponder = false
                    self.reserveAmountIsFirstResponder = false
                    self.allocationAmountFirstResponderID = incomeID
                    self.focusedField = .allocationAmount(incomeID)
                }
            }
        }
        guard let current = currentFocusField else {
            activate(focusOrder.first!)
            return
        }
        if let idx = focusOrder.firstIndex(of: current) {
            let newIdx = max(focusOrder.startIndex, min(focusOrder.index(before: focusOrder.endIndex), idx + direction))
            activate(focusOrder[newIdx])
        }
    }

    private func commitAndDismiss() {
        applyChanges()
        nameIsFirstResponder = false
        amountIsFirstResponder = false
        notesIsFirstResponder = false
        reserveAmountIsFirstResponder = false
        allocationAmountFirstResponderID = nil
        focusedField = nil
        #if canImport(UIKit)
        let keyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        keyWindow?.endEditing(true)
        #endif
        dismiss()
    }

    private func currentScheduleSignature() -> ScheduleSignature {
        let cal = Calendar.current
        // Determine anchor month and due day from current editor state
        let anchorMonth: Int
        if let first = firstPaymentDate {
            anchorMonth = cal.component(.month, from: first)
        } else {
            anchorMonth = cal.component(.month, from: item.createdAt)
        }
        let dueDay: Int
        if let d = dayOfMonth, (1...31).contains(d) {
            dueDay = d
        } else if let first = firstPaymentDate {
            dueDay = cal.component(.day, from: first)
        } else {
            dueDay = cal.component(.day, from: item.createdAt)
        }
        let freqMonths = max(1, frequency.normalized.monthsPerCycle)
        return ScheduleSignature(anchorMonth: anchorMonth, dueDay: dueDay, freqMonths: freqMonths)
    }

    private func detectScheduleChangeAndPromptIfNeeded() {
        guard item.kind == .bill else { return }
        guard item.frequency.isReserveEligible else { return }
        guard item.reserveCycleStart != nil else { return }
        let sig = currentScheduleSignature()
        if originalSchedule == nil { originalSchedule = sig }
        guard let original = originalSchedule, original != sig else { return }
        if lastPromptedSchedule != sig {
            lastPromptedSchedule = sig
            showRebaseConfirm = true
        }
    }

    @ViewBuilder
    private func IncomeSSASection() -> some View {
        if item.kind == .income && frequency == .monthly {
            Picker("SSA Wednesday", selection: Binding<Int?>(
                get: { ssaWednesday },
                set: { ssaWednesday = $0; applyChanges() }
            )) {
                Text("None").tag(nil as Int?)
                Text("2nd Wednesday").tag(Optional(2))
                Text("3rd Wednesday").tag(Optional(3))
                Text("4th Wednesday").tag(Optional(4))
            }
            Text("For Social Security income paid on a specific Wednesday of the month.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func SchedulePickersSection() -> some View {
        if ssaWednesday == nil {
            switch frequency.normalized {
            case .monthly, .semimonthly, .biweekly, .weekly, .socialSecurity:
                let binding = Binding<Int?>(
                    get: { dayOfMonth },
                    set: { dayOfMonth = $0; applyChanges(); detectScheduleChangeAndPromptIfNeeded() }
                )
                HStack {
                    Picker("Day of Month", selection: binding) {
                        Text("None").tag(nil as Int?)
                        ForEach(1...31, id: \.self) { d in Text("\(d)").tag(Optional(d)) }
                    }
                    Spacer(minLength: 8)
                    Button(action: {
                        dismissKeyboardOnly()
                        showDayOfMonthPicker = true
                    }) {
                        Image(systemName: "pencil").imageScale(.small)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            default:
                let dateBinding = Binding<Date>(
                    get: { firstPaymentDate ?? Date() },
                    set: { firstPaymentDate = $0; applyChanges(); detectScheduleChangeAndPromptIfNeeded() }
                )
                HStack {
                    DatePicker("First Payment Date", selection: dateBinding, displayedComponents: .date)
                    Spacer(minLength: 8)
                    Button(action: {
                        dismissKeyboardOnly()
                        showFirstPaymentDatePicker = true
                    }) {
                        Image(systemName: "pencil").imageScale(.small)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func ReserveSummarySectionInline() -> some View {
        if item.kind == .bill {
            let working = buildWorkingItem()
            let plan = BillReservePlanner.planReserve(for: working, asOf: Date(), currentReserve: item.reserveBalance)
            if plan == nil {
                Section("Reserve") {
                    Text("Reserve planning not applicable for this frequency.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func ReserveAutomationSection() -> some View {
        if item.kind == .bill {
            let working = buildWorkingItem()
            // Only show automation UI for reserve-eligible (non-monthly) bills
            if working.frequency.normalized.isReserveEligible {
                let now = Date()
                let cal = Calendar.current

                // Compute schedule signature and cycle start (prefer persisted start if available)
                let sig = currentScheduleSignature()
                let inferredStart = ReserveUpdateService.previousDueDateForSchedule(
                    anchorMonth: sig.anchorMonth,
                    day: sig.dueDay,
                    frequencyMonths: sig.freqMonths,
                    asOf: now
                )
                let cycleStart = item.reserveCycleStart ?? inferredStart

                let reserveTarget = max(0, working.amount - totalFundingForCurrentBill)

                // Fixed-monthly model: monthly = uncovered amount / monthsPerCycle
                let fixedMonthly = (reserveTarget / Decimal(sig.freqMonths))

                // Expected by the start of the current month
                let startOfThisMonth = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now
                let sIndex = cal.component(.year, from: cycleStart) * 12 + cal.component(.month, from: cycleStart)
                let eIndex = cal.component(.year, from: startOfThisMonth) * 12 + cal.component(.month, from: startOfThisMonth)
                let monthsElapsed = max(0, eIndex - sIndex)
                let expectedByStartOfThisMonth = fixedMonthly * Decimal(monthsElapsed)
                let fixedSeed = max(0, (expectedByStartOfThisMonth - item.reserveBalance))

                // Next due date (keep existing planner's computation for the date itself)
                let next = BillReservePlanner.nextDue(for: working, asOf: now)

                Section("Funding") {
                    LabeledContent("Bill amount") {
                        Text(formatCurrencyDecimal(amountValue))
                    }
                    LabeledContent("Income applied") {
                        Text(formatCurrencyDecimal(totalFundingForCurrentBill))
                    }
                    LabeledContent("Left to cover") {
                        Text(formatCurrencyDecimal(max(0, amountValue - totalFundingForCurrentBill)))
                    }
                }

                if !eligibleFundingIncomes.isEmpty {
                    Section("Pay from non-monthly income") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(eligibleFundingIncomes, id: \.id) { income in
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(income.name)
                                        Text("\(formatCurrencyDecimal(availableFunding(for: income, excludingBill: item))) available")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer(minLength: 8)

                                    HStack(spacing: 6) {
                                    #if os(iOS)
                                    CurrencyAmountField(
                                        value: Binding<Decimal>(
                                            get: { allocationAmount(for: income) },
                                            set: { updateAllocationAmount($0, for: income) }
                                        ),
                                        placeholder: "0.00",
                                        currencyCode: settings.currencyCode,
                                        isFirstResponder: allocationResponderBinding(for: income),
                                        onBeginEditing: { focusedField = .allocationAmount(income.id) },
                                        onEndEditing: { try? modelContext.save() },
                                        onPrevious: { moveFocus(-1) },
                                        onNext: { moveFocus(1) },
                                        onDone: { commitAndDismissKeyboard() }
                                    )
                                    .frame(minWidth: 100, idealWidth: 120, maxWidth: 160, alignment: .trailing)
                                    Button(action: {
                                        focusedField = .allocationAmount(income.id)
                                        allocationAmountFirstResponderID = income.id
                                        selectAllInFirstResponder()
                                    }) {
                                        Image(systemName: "pencil")
                                            .imageScale(.small)
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel("Edit amount from \(income.name)")
                                    #else
                                    TextField(
                                        "0.00",
                                        value: Binding(
                                            get: { NSDecimalNumber(decimal: allocationAmount(for: income)) },
                                            set: { updateAllocationAmount($0.decimalValue, for: income) }
                                        ),
                                        formatter: {
                                            let nf = NumberFormatter(); nf.numberStyle = .currency; nf.currencyCode = settings.currencyCode; return nf
                                        }()
                                    )
                                    .multilineTextAlignment(.trailing)
                                    .frame(minWidth: 100, idealWidth: 120, maxWidth: 160, alignment: .trailing)
                                    #endif
                                    }
                                }
                                .padding(.leading, 16)
                                .padding(.vertical, 1)
                            }
                        }
                    }
                }

                Section("Reserve") {
                    if reserveTarget == 0 {
                        Text("No reserve needed — this bill is fully covered by selected non-monthly income.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        // Linked Account picker (show name and kind)
                        Picker("Linked Account", selection: Binding<UUID?>(
                            get: { item.account?.id },
                            set: { newID in
                                if let id = newID {
                                    item.account = accounts.first(where: { $0.id == id })
                                } else {
                                    item.account = nil
                                }
                                try? modelContext.save()
                            }
                        )) {
                            Text("None").tag(nil as UUID?)
                            ForEach(accounts, id: \.id) { acct in
                                Text("\(acct.name) — \(acct.type.rawValue.capitalized)").tag(Optional(acct.id))
                            }
                        }

                        LabeledContent("Still save") {
                            Text(formatCurrencyDecimal(reserveTarget))
                        }

                    // Inline reserve balance editor
                    LabeledContent("Reserve balance") {
                        #if os(iOS)
                        HStack(spacing: 6) {
                            CurrencyAmountField(
                                value: Binding<Decimal>(
                                    get: { item.reserveBalance },
                                    set: { item.reserveBalance = $0 }
                                ),
                                placeholder: "0.00",
                                currencyCode: settings.currencyCode,
                                isFirstResponder: $reserveAmountIsFirstResponder,
                                onBeginEditing: { focusedField = .reserveAmount },
                                onEndEditing: { try? modelContext.save() },
                                onPrevious: { moveFocus(-1) },
                                onNext: { moveFocus(1) },
                                onDone: { commitAndDismissKeyboard() }
                            )
                            .frame(minWidth: 100, idealWidth: 120, maxWidth: 160, alignment: .trailing)
                            Button(action: {
                                focusedField = .reserveAmount
                                reserveAmountIsFirstResponder = true
                            }) {
                                Image(systemName: "pencil")
                                    .imageScale(.small)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Edit reserve balance")
                        }
                        #else
                        HStack(spacing: 6) {
                            TextField(
                                "0.00",
                                value: Binding(get: { NSDecimalNumber(decimal: item.reserveBalance) }, set: { item.reserveBalance = $0.decimalValue; try? modelContext.save() }),
                                formatter: {
                                    let nf = NumberFormatter(); nf.numberStyle = .currency; nf.currencyCode = settings.currencyCode; return nf
                                }()
                            )
                            .multilineTextAlignment(.trailing)
                            .frame(minWidth: 100, idealWidth: 120, maxWidth: 160, alignment: .trailing)
                            Image(systemName: "pencil")
                                .imageScale(.small)
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                        #endif
                    }

                    Toggle("Enable reserve automation for this bill", isOn: Binding(get: { item.reserveAutoEnabled }, set: { item.reserveAutoEnabled = $0; try? modelContext.save() }))

                    if item.reserveAutoEnabled {
                        LabeledContent("Next due") {
                            Text(next.nextDueDate, style: .date)
                        }
                        LabeledContent("Monthly reserve") {
                            Text(formatCurrencyDecimal(fixedMonthly))
                        }
                        LabeledContent("Seed this cycle") {
                            Text(formatCurrencyDecimal(fixedSeed))
                        }
                        Text("Applied once per cycle.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    // Informational warning if reserve is behind
                    if fixedSeed > 0 {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("The calculated reserve is behind by \(formatCurrencyDecimal(fixedSeed)) this cycle. Make sure the actual reserve account has enough funds.")
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }

                    if let acct = item.account,
                       [.checking, .savings, .cash].contains(acct.type) {
                        let accountBal = transactionalBalance(for: acct)
                        let (totalReserved, linkedCount) = totalReserves(for: acct)
                        if accountBal < totalReserved {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Text("Linked account balance is below total reserves for \(linkedCount) bill\(linkedCount == 1 ? "" : "s"): \(formatCurrencyDecimal(totalReserved)) available \(formatCurrencyDecimal(accountBal)).")
                            }
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }
                    }

                    Button("Mark this year paid…") { showRebaseConfirm = true }
                    }
                }
            }
        }
    }

    public var body: some View {
        Form {
            Section("Details") {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    HStack(spacing: 6) {
                        BillSelectAllTextField(
                            text: $name,
                            placeholder: "Name",
                            isFirstResponder: $nameIsFirstResponder,
                            returnKeyType: .next,
                            onPrev: { moveFocus(-1) },
                            onNext: { moveFocus(1) },
                            onDone: { commitAndDismissKeyboard() },
                            onTextChange: { applyChanges() }
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Button(action: {
                            focusedField = .name
                            nameIsFirstResponder = true
                        }) {
                            Image(systemName: "pencil")
                                .imageScale(.small)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Edit name")
                    }
                    #if os(iOS)
                    HStack(spacing: 6) {
                        CurrencyAmountField(
                            value: $amountValue,
                            placeholder: "Amount",
                            currencyCode: settings.currencyCode,
                            isFirstResponder: $amountIsFirstResponder,
                            onBeginEditing: { focusedField = .amount },
                            onEndEditing: { applyChanges() },
                            onPrevious: { moveFocus(-1) },
                            onNext: { moveFocus(1) },
                            onDone: { commitAndDismissKeyboard() }
                        )
                        .frame(minWidth: 100, idealWidth: 120, maxWidth: 160, alignment: .trailing)
                        Button(action: {
                            focusedField = .amount
                            amountIsFirstResponder = true
                        }) {
                            Image(systemName: "pencil")
                                .imageScale(.small)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Edit amount")
                    }
                    #else
                    HStack(spacing: 6) {
                        TextField(
                            "Amount",
                            value: Binding(get: { NSDecimalNumber(decimal: amountValue) }, set: { amountValue = $0.decimalValue; applyChanges() }),
                            formatter: {
                                let nf = NumberFormatter(); nf.numberStyle = .currency; nf.currencyCode = settings.currencyCode; return nf
                            }()
                        )
                        .multilineTextAlignment(.trailing)
                        .frame(minWidth: 100, idealWidth: 120, maxWidth: 160, alignment: .trailing)
                        Image(systemName: "pencil")
                            .imageScale(.small)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    #endif
                }
                HStack {
                    Picker("Frequency", selection: $frequency) {
                        Text("Monthly").tag(PaymentFrequency.monthly)
                        Text("Twice per month").tag(PaymentFrequency.semimonthly)
                        Text("Every 2 weeks").tag(PaymentFrequency.biweekly)
                        Text("Weekly").tag(PaymentFrequency.weekly)
                        Text("Yearly").tag(PaymentFrequency.yearly)
                        Text("Quarterly").tag(PaymentFrequency.quarterly)
                        Text("Semiannual").tag(PaymentFrequency.semiAnnual)
                        Text("One-time").tag(PaymentFrequency.oneTime)
                    }
                    Spacer(minLength: 8)
                    Button(action: {
                        dismissKeyboardOnly()
                        showFrequencyPicker = true
                    }) {
                        Image(systemName: "pencil").imageScale(.small)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .onChange(of: frequency) { _, newValue in
                    if item.kind == .income {
                        switch newValue.normalized {
                        case .monthly, .semimonthly, .biweekly, .weekly, .socialSecurity:
                            if dayOfMonth == nil { dayOfMonth = 1 }
                            firstPaymentDate = nil
                        default:
                            break
                        }
                    }
                    applyChanges()
                    detectScheduleChangeAndPromptIfNeeded()
                }

                IncomeSSASection()
                SchedulePickersSection()

                if item.kind == .income && [.yearly, .semiAnnual, .quarterly, .oneTime].contains(frequency.normalized) {
                    Picker("Spread months", selection: Binding<Int?>(
                        get: { oneTimeSpreadMonthsOverride },
                        set: { newVal in
                            // Sanitize to allowed values 3, 6, 12 or nil
                            if let v = newVal, [3,6,12].contains(v) { oneTimeSpreadMonthsOverride = v } else { oneTimeSpreadMonthsOverride = nil }
                            applyChanges()
                        }
                    )) {
                        Text("Use default").tag(nil as Int?)
                        Text("3 months").tag(Optional(3))
                        Text("6 months").tag(Optional(6))
                        Text("12 months").tag(Optional(12))
                    }
                    Text("Non‑monthly income is spread evenly starting the month after the pay date.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 6) {
                    BillSelectAllTextField(
                        text: $notes,
                        placeholder: "Notes",
                        isFirstResponder: $notesIsFirstResponder,
                        returnKeyType: .done,
                        onPrev: { moveFocus(-1) },
                        onNext: { moveFocus(1) },
                        onDone: { commitAndDismissKeyboard() },
                        onTextChange: { applyChanges() }
                    )
                    Button(action: {
                        focusedField = .notes
                        notesIsFirstResponder = true
                    }) {
                        Image(systemName: "pencil")
                            .imageScale(.small)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Edit notes")
                }
            }
            ReserveSummarySectionInline()
            ReserveAutomationSection()
        }
        .navigationTitle("Edit \(item.kind == .income ? "Income" : "Bill")")
        .onAppear {
            initializeFromItemIfNeeded()
            if item.ssaWednesday == nil, let n = extractSSAWednesday(from: item.notes) {
                item.ssaWednesday = n
                let cleaned = removeSSAToken(from: (item.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
                item.notes = cleaned.isEmpty ? nil : cleaned
                try? modelContext.save()
            }
            self.originalSchedule = self.currentScheduleSignature()
        }
        .toolbar {
            #if os(iOS)
            if UIDevice.current.userInterfaceIdiom == .pad {
                ToolbarItem(placement: .cancellationAction) {
                    PlanToolbarButton("Cancel", fixedWidth: 70) { dismiss() }
                }
            }
            #endif
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    applyChanges()
                    dismissKeyboardOnly()
                    dismiss()
                } label: {
                    PlanMenuLabel(title: "Save", titleFont: .callout)
                }
                .buttonStyle(.plain)
            }
            ToolbarItem(placement: .topBarLeading) {
                Button(role: .destructive) {
                    modelContext.delete(item)
                    try? modelContext.save()
                    dismiss()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
            }
        }
        .alert("Mark this year paid?", isPresented: $showRebaseConfirm) {
            Button("Mark Paid & Start Next Year", role: .destructive) { rebaseReserveCycle() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("We'll mark this year's bill as paid and start a reserve for next year. This sets the reserve cycle start to the last due date and allows seeding again.")
        }
        #if os(iOS)
        .scrollDismissesKeyboard(UIDevice.current.userInterfaceIdiom == .pad ? .never : .interactively)
        #endif
        .safeAreaInset(edge: .bottom) {
            Group {
                if showBottomAccessoryBar {
                    EditingAccessoryBar(
                        canGoPrevious: canGoPrevious,
                        canGoNext: canGoNext,
                        onPrevious: { moveFocus(-1) },
                        onNext: { moveFocus(1) },
                        onDone: { applyChanges(); dismissKeyboardOnly() }
                    )
                } else {
                    EmptyView().frame(height: 0)
                }
            }
        }
        .onChange(of: focusedField) { _, _ in
            selectAllInFirstResponder()
        }
        .onChange(of: nameIsFirstResponder) { _, isFirst in
            if isFirst { focusedField = .name }
        }
        .onChange(of: amountIsFirstResponder) { _, isFirst in
            if isFirst { focusedField = .amount }
        }
        .onChange(of: notesIsFirstResponder) { _, isFirst in
            if isFirst { focusedField = .notes }
        }
        .onChange(of: reserveAmountIsFirstResponder) { _, isFirst in
            if isFirst { focusedField = .reserveAmount }
        }
        .sheet(isPresented: $showFrequencyPicker) {
            NavigationStack {
                Form {
                    Picker("Frequency", selection: $frequency) {
                        Text("Monthly").tag(PaymentFrequency.monthly)
                        Text("Twice per month").tag(PaymentFrequency.semimonthly)
                        Text("Every 2 weeks").tag(PaymentFrequency.biweekly)
                        Text("Weekly").tag(PaymentFrequency.weekly)
                        Text("Yearly").tag(PaymentFrequency.yearly)
                        Text("Quarterly").tag(PaymentFrequency.quarterly)
                        Text("Semiannual").tag(PaymentFrequency.semiAnnual)
                        Text("One-time").tag(PaymentFrequency.oneTime)
                    }
                }
                .navigationTitle("Frequency")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showFrequencyPicker = false } } }
            }
        }
        .sheet(isPresented: $showDayOfMonthPicker) {
            NavigationStack {
                Form {
                    Picker("Day of Month", selection: Binding<Int?>(
                        get: { dayOfMonth },
                        set: { dayOfMonth = $0; applyChanges(); detectScheduleChangeAndPromptIfNeeded() }
                    )) {
                        Text("None").tag(nil as Int?)
                        ForEach(1...31, id: \.self) { d in Text("\(d)").tag(Optional(d)) }
                    }
                }
                .navigationTitle("Day of Month")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showDayOfMonthPicker = false } } }
            }
        }
        .sheet(isPresented: $showFirstPaymentDatePicker) {
            NavigationStack {
                Form {
                    DatePicker("First Payment Date", selection: Binding<Date>(
                        get: { firstPaymentDate ?? Date() },
                        set: { firstPaymentDate = $0; applyChanges(); detectScheduleChangeAndPromptIfNeeded() }
                    ), displayedComponents: .date)
                }
                .navigationTitle("First Payment Date")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showFirstPaymentDatePicker = false } } }
            }
        }
    }

    private func initializeFromItemIfNeeded() {
        guard !initialized else { return }
        self.name = item.name
        self.amountValue = item.amount
        self.frequency = item.frequency
        self.dayOfMonth = item.dayOfMonth
        self.firstPaymentDate = item.firstPaymentDate
        self.notes = item.notes ?? ""
        self.ssaWednesday = item.ssaWednesday ?? extractSSAWednesday(from: item.notes)
        self.oneTimeSpreadMonthsOverride = item.oneTimeSpreadMonthsOverride
        self.initialized = true
    }

    private func applyChanges() {
        // item.kind = kind  // Removed as per instructions
        item.name = name
        item.amount = amountValue
        item.frequency = frequency
        item.dayOfMonth = dayOfMonth
        item.firstPaymentDate = firstPaymentDate
        let cleanedNotes = removeSSAToken(from: notes)
        item.notes = cleanedNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : cleanedNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        item.ssaWednesday = ssaWednesday
        item.oneTimeSpreadMonthsOverride = oneTimeSpreadMonthsOverride
        normalizeCurrentBillAllocations()
        syncLegacyFundingCache()
        try? modelContext.save()
    }

    // MARK: - Helpers

    private func removeSSAToken(from s: String) -> String {
        if s.isEmpty { return s }
        var parts = s.split(separator: " ").map(String.init)
        parts.removeAll { $0.hasPrefix("[SSA_WED]=") }
        return parts.joined(separator: " ")
    }

    private func extractSSAWednesday(from notes: String?) -> Int? {
        guard let notes = notes, !notes.isEmpty else { return nil }
        for tok in notes.split(separator: " ") {
            if tok.hasPrefix("[SSA_WED]=") {
                let val = tok.replacingOccurrences(of: "[SSA_WED]=", with: "")
                if let n = Int(val), (2...4).contains(n) { return n }
            }
        }
        return nil
    }

    private func buildWorkingItem() -> CashFlowItem {
        // Build a transient copy of the item using current editor state so calculations react live
        let parsedAmount = amountValue
        let temp = CashFlowItem(
            kind: item.kind,
            name: name.isEmpty ? item.name : name,
            amount: parsedAmount,
            frequency: frequency,
            dayOfMonth: dayOfMonth,
            firstPaymentDate: firstPaymentDate,
            notes: item.notes,
            ssaWednesday: ssaWednesday,
            fundingIncomeID: item.fundingIncomeID,
            fundingAmount: item.fundingAmount
        )
        // Carry over createdAt so date-based logic remains stable
        temp.createdAt = item.createdAt
        return temp
    }

    private var eligibleFundingIncomes: [CashFlowItem] {
        cashFlowItems.filter {
            $0.kind == .income &&
            [.yearly, .semiAnnual, .quarterly, .oneTime].contains($0.frequency) &&
            isIncomeEligibleForCurrentBill($0)
        }
    }

    private var currentBillAllocations: [BillFundingAllocation] {
        fundingAllocations.filter { $0.billID == item.id }
    }

    private var totalFundingForCurrentBill: Decimal {
        currentBillAllocations.reduce(Decimal.zero) { $0 + $1.amount }
    }

    private func allocation(for income: CashFlowItem) -> BillFundingAllocation? {
        currentBillAllocations.first(where: { $0.incomeID == income.id })
    }

    private func allocatedFunding(for income: CashFlowItem, excludingBill: CashFlowItem? = nil) -> Decimal {
        fundingAllocations
            .filter { allocation in
                allocation.incomeID == income.id && allocation.billID != excludingBill?.id
            }
            .reduce(Decimal.zero) { $0 + $1.amount }
    }

    private func availableFunding(for income: CashFlowItem, excludingBill: CashFlowItem? = nil) -> Decimal {
        max(0, income.amount - allocatedFunding(for: income, excludingBill: excludingBill))
    }

    private func allocationAmount(for income: CashFlowItem) -> Decimal {
        allocation(for: income)?.amount ?? 0
    }

    private func allocationResponderBinding(for income: CashFlowItem) -> Binding<Bool> {
        Binding(
            get: { allocationAmountFirstResponderID == income.id },
            set: { isFirstResponder in
                allocationAmountFirstResponderID = isFirstResponder ? income.id : nil
            }
        )
    }

    private func maxAllocatableAmount(for income: CashFlowItem) -> Decimal {
        guard isIncomeEligibleForCurrentBill(income) else { return 0 }
        let otherFundingForBill = max(0, totalFundingForCurrentBill - allocationAmount(for: income))
        let remainingBillNeed = max(0, amountValue - otherFundingForBill)
        return min(availableFunding(for: income, excludingBill: item), remainingBillNeed)
    }

    private func updateAllocationAmount(_ newValue: Decimal, for income: CashFlowItem) {
        let capped = min(max(0, newValue), maxAllocatableAmount(for: income))
        let previousAmount = allocationAmount(for: income)
        if let allocation = allocation(for: income) {
            if capped == 0 {
                modelContext.delete(allocation)
            } else {
                allocation.amount = capped
            }
        } else if capped > 0 {
            modelContext.insert(BillFundingAllocation(billID: item.id, incomeID: income.id, amount: capped))
        }
        item.fundingAmount = max(0, totalFundingForCurrentBill - previousAmount + capped)
        item.fundingIncomeID = item.fundingAmount > 0 ? income.id : currentBillAllocations.first?.incomeID
        try? modelContext.save()
    }

    private func normalizeCurrentBillAllocations() {
        var remaining = max(0, amountValue)
        for allocation in currentBillAllocations.sorted(by: { $0.createdAt < $1.createdAt }) {
            guard let income = cashFlowItems.first(where: { $0.id == allocation.incomeID }),
                  isIncomeEligibleForCurrentBill(income) else {
                modelContext.delete(allocation)
                continue
            }
            let capped = min(allocation.amount, remaining)
            allocation.amount = capped
            remaining -= capped
        }
    }

    private func isIncomeEligibleForCurrentBill(_ income: CashFlowItem) -> Bool {
        guard let billDueDate = resolvedDueDate(for: buildWorkingItem()),
              let incomePayDate = eligibleOccurrenceDate(for: income, onOrBefore: billDueDate) else {
            return false
        }

        let calendar = Calendar.current
        return calendar.component(.year, from: incomePayDate) == calendar.component(.year, from: billDueDate) &&
            incomePayDate <= billDueDate
    }

    private func resolvedDueDate(for bill: CashFlowItem) -> Date? {
        if let first = bill.firstPaymentDate {
            return first
        }
        if let day = bill.dayOfMonth {
            return clampedDate(inYearOf: Date(), monthOf: Date(), day: day)
        }
        return bill.createdAt
    }

    private func resolvedPayDate(for income: CashFlowItem) -> Date? {
        if let first = income.firstPaymentDate {
            return first
        }
        if let day = income.dayOfMonth {
            return clampedDate(inYearOf: Date(), monthOf: Date(), day: day)
        }
        return income.createdAt
    }

    private func eligibleOccurrenceDate(for income: CashFlowItem, onOrBefore dueDate: Date) -> Date? {
        guard let anchor = resolvedPayDate(for: income) else { return nil }
        let calendar = Calendar.current
        let dueYear = calendar.component(.year, from: dueDate)

        switch income.frequency {
        case .oneTime:
            return calendar.component(.year, from: anchor) == dueYear && anchor <= dueDate ? anchor : nil
        case .yearly, .semiAnnual, .quarterly:
            let monthsPerCycle = income.frequency.monthsPerCycle
            var occurrence = anchor
            while occurrence < dueDate,
                  let next = calendar.date(byAdding: .month, value: monthsPerCycle, to: occurrence),
                  next <= dueDate {
                occurrence = next
            }
            return calendar.component(.year, from: occurrence) == dueYear && occurrence <= dueDate ? occurrence : nil
        default:
            return nil
        }
    }

    private func clampedDate(inYearOf yearSource: Date, monthOf monthSource: Date, day: Int) -> Date? {
        let calendar = Calendar.current
        var comps = DateComponents()
        comps.year = calendar.component(.year, from: yearSource)
        comps.month = calendar.component(.month, from: monthSource)
        let firstOfMonth = calendar.date(from: comps) ?? monthSource
        let maxDay = calendar.range(of: .day, in: .month, for: firstOfMonth)?.count ?? day
        comps.day = min(max(day, 1), maxDay)
        return calendar.date(from: comps)
    }

    private func syncLegacyFundingCache(
        pendingAdditionalAmount: Decimal = 0,
        preferredIncomeID: UUID? = nil,
        removingIncomeID: UUID? = nil
    ) {
        let persistedTotal = currentBillAllocations
            .filter { $0.incomeID != removingIncomeID }
            .reduce(Decimal.zero) { $0 + $1.amount }
        let total = persistedTotal + pendingAdditionalAmount
        item.fundingAmount = total
        item.fundingIncomeID = preferredIncomeID ?? currentBillAllocations.first(where: { $0.incomeID != removingIncomeID })?.incomeID
    }

    @MainActor
    private func transactionalBalance(for account: Account) -> Decimal {
        // Use in-memory relationships to avoid predicate compilation issues
        // Latest recorded balance snapshot (if any)
        let last = account.balanceSnapshots.sorted { $0.asOfDate > $1.asOfDate }.first
        if let last {
            let delta = account.transactions.filter { $0.datePosted > last.asOfDate }.reduce(Decimal.zero) { $0 + $1.amount }
            return last.balance + delta
        } else {
            // No snapshot: sum all transactions for the account
            let sum = account.transactions.reduce(Decimal.zero) { $0 + $1.amount }
            return sum
        }
    }

    @MainActor
    private func totalReserves(for account: Account) -> (Decimal, Int) {
        // Fetch all cash flow items and filter in-memory by linked account id
        let items = (try? modelContext.fetch(FetchDescriptor<CashFlowItem>())) ?? []
        let linkedBills = items.filter { $0.account?.id == account.id && $0.kind == .bill }
        let total = linkedBills.reduce(Decimal.zero) { $0 + $1.reserveBalance }
        return (total, linkedBills.count)
    }

    private func formatCurrencyDecimal(_ value: Decimal) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = settings.currencyCode
        nf.maximumFractionDigits = 2
        return nf.string(from: NSDecimalNumber(decimal: value)) ?? "\(value)"
    }

    private func rebaseReserveCycle() {
        let cal = Calendar.current
        let sig = currentScheduleSignature()
        let asOf = Date()
        let prev = ReserveUpdateService.previousDueDateForSchedule(anchorMonth: sig.anchorMonth, day: sig.dueDay, frequencyMonths: sig.freqMonths, asOf: asOf)
        item.reserveCycleStart = cal.startOfDay(for: prev)
        item.reserveLastSeededCycleStart = nil
        try? modelContext.save()
        // Update the baseline so we don't keep prompting for the same change
        originalSchedule = sig
    }
}

fileprivate func parseDecimalAmount(from text: String) -> Decimal? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    // Try parsing with current locale as currency and decimal first
    let styles: [NumberFormatter.Style] = [.currency, .decimal]
    for style in styles {
        let nf = NumberFormatter()
        nf.numberStyle = style
        nf.locale = .current
        if let number = nf.number(from: trimmed) {
            return number.decimalValue
        }
    }

    // Fallback: keep digits and separators; normalize comma decimal to dot
    let allowed = CharacterSet(charactersIn: "0123456789.,")
    let filtered = String(trimmed.unicodeScalars.filter { allowed.contains($0) })
    guard !filtered.isEmpty else { return nil }

    var normalized = filtered
    if filtered.contains(",") && filtered.contains(".") {
        normalized = filtered.replacingOccurrences(of: ",", with: "")
    } else if filtered.contains(",") && !filtered.contains(".") {
        normalized = filtered.replacingOccurrences(of: ",", with: ".")
    }

    return Decimal(string: normalized)
}

private struct BillSelectAllTextField: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String
    @Binding var isFirstResponder: Bool
    var returnKeyType: UIReturnKeyType = .default
    var onPrev: (() -> Void)? = nil
    var onNext: (() -> Void)? = nil
    var onDone: (() -> Void)? = nil
    var onTextChange: (() -> Void)? = nil

    func makeUIView(context: Context) -> UITextField {
        let tf = UITextField(frame: .zero)
        tf.placeholder = placeholder
        tf.text = text
        tf.returnKeyType = returnKeyType
        tf.delegate = context.coordinator
        tf.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged(_:)), for: .editingChanged)
        tf.borderStyle = .none
        return tf
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        uiView.placeholder = placeholder
        uiView.returnKeyType = returnKeyType
        if uiView.text != text && !uiView.isFirstResponder {
            uiView.text = text
        }
        if isFirstResponder && !uiView.isFirstResponder {
            uiView.becomeFirstResponder()
        } else if !isFirstResponder && uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: BillSelectAllTextField

        init(_ parent: BillSelectAllTextField) {
            self.parent = parent
        }

        @objc func editingChanged(_ textField: UITextField) {
            parent.text = textField.text ?? ""
            parent.onTextChange?()
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            DispatchQueue.main.async { textField.selectAll(nil) }
            parent.isFirstResponder = true
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            parent.isFirstResponder = false
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            switch parent.returnKeyType {
            case .next:
                parent.onNext?()
            default:
                parent.onDone?()
            }
            return false
        }
    }
}

private struct SelectAllAmountField: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String
    @Binding var isFirstResponder: Bool
    var onBeginEditing: (() -> Void)? = nil
    var onEndEditing: (() -> Void)? = nil

    func makeUIView(context: Context) -> UITextField {
        let tf = UITextField(frame: .zero)
        tf.keyboardType = .decimalPad
        tf.textAlignment = .right
        tf.placeholder = placeholder
        tf.delegate = context.coordinator
        tf.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged(_:)), for: .editingChanged)
        tf.text = text
        return tf
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        uiView.placeholder = placeholder
        uiView.textAlignment = .right
        uiView.keyboardType = .decimalPad
        if uiView.text != text && !uiView.isFirstResponder {
            uiView.text = text
        }
        if isFirstResponder && !uiView.isFirstResponder {
            uiView.becomeFirstResponder()
        } else if !isFirstResponder && uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, UITextFieldDelegate {
        var parent: SelectAllAmountField
        init(_ parent: SelectAllAmountField) { self.parent = parent }

        @objc func editingChanged(_ textField: UITextField) {
            parent.text = textField.text ?? ""
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            DispatchQueue.main.async { textField.selectAll(nil) }
            parent.isFirstResponder = true
            parent.onBeginEditing?()
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            parent.isFirstResponder = false
            parent.onEndEditing?()
        }
    }
}

private struct CurrencyAmountField: UIViewRepresentable {
    @Binding var value: Decimal
    var placeholder: String
    var currencyCode: String
    @Binding var isFirstResponder: Bool
    var onBeginEditing: (() -> Void)? = nil
    var onEndEditing: (() -> Void)? = nil
    var onPrevious: (() -> Void)? = nil
    var onNext: (() -> Void)? = nil
    var onDone: (() -> Void)? = nil

    func makeUIView(context: Context) -> UITextField {
        let tf = UITextField(frame: .zero)
        tf.keyboardType = .numbersAndPunctuation
        tf.textAlignment = .right
        tf.placeholder = placeholder
        tf.delegate = context.coordinator
        tf.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged(_:)), for: .editingChanged)
        // Seed initial formatted text
        let formatted = context.coordinator.formatter.string(from: NSDecimalNumber(decimal: value)) ?? ""
        tf.text = formatted

        return tf
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        uiView.textAlignment = .right
        uiView.placeholder = placeholder
        context.coordinator.formatter.currencyCode = currencyCode
        uiView.keyboardType = .numbersAndPunctuation

        // Keep track of the current text field for coordinator actions
        context.coordinator.textField = uiView

        if isFirstResponder, !uiView.isFirstResponder {
            uiView.becomeFirstResponder()
        } else if !isFirstResponder, uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
        if !uiView.isFirstResponder && !context.coordinator.isFormatting {
            let formatted = context.coordinator.formatter.string(from: NSDecimalNumber(decimal: value)) ?? ""
            if uiView.text != formatted {
                context.coordinator.isFormatting = true
                uiView.text = formatted
                context.coordinator.isFormatting = false
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, UITextFieldDelegate {
        var parent: CurrencyAmountField
        let formatter: NumberFormatter
        var isFormatting = false

        // References for input accessory and text field
        weak var textField: UITextField?

        init(_ parent: CurrencyAmountField) {
            self.parent = parent
            let nf = NumberFormatter()
            nf.numberStyle = .currency
            nf.currencyCode = parent.currencyCode
            nf.locale = .current
            self.formatter = nf
        }

        @objc func editingChanged(_ textField: UITextField) {
            guard !isFormatting else { return }
            let text = textField.text ?? ""
            // Parse using a permissive approach similar to Add flow
            if let dec = parseDecimalAmount(from: text) {
                parent.value = dec
            } else {
                parent.value = 0
            }
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            DispatchQueue.main.async { textField.selectAll(nil) }
            parent.isFirstResponder = true
            parent.onBeginEditing?()
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            isFormatting = true
            let formatted = formatter.string(from: NSDecimalNumber(decimal: parent.value)) ?? ""
            textField.text = formatted
            isFormatting = false
            parent.isFirstResponder = false
            parent.onEndEditing?()
        }

        @objc func prevTapped() {
            parent.onPrevious?()
        }
        @objc func nextTapped() {
            parent.onNext?()
        }
        @objc func doneTapped() {
            // Ensure the latest text is parsed and value updated
            if let tf = textField {
                if let text = tf.text, let number = parseDecimalAmount(from: text) {
                    parent.value = number
                }
                tf.resignFirstResponder()
            }
            parent.onEndEditing?()
            parent.onDone?()
        }
    }
}

#Preview {
    Text("Editor preview requires a CashFlowItem instance")
}
