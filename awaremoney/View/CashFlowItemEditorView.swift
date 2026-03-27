import SwiftUI
import SwiftData

public struct CashFlowItemEditorView: View {
    let item: CashFlowItem
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: SettingsStore
    @Query(sort: [SortDescriptor(\Account.name, order: .forward)]) private var accounts: [Account]

    // Editable state
    @State private var name: String = ""
    @State private var amountValue: Decimal = 0
    @State private var frequency: PaymentFrequency = .monthly
    @State private var dayOfMonth: Int? = nil
    @State private var firstPaymentDate: Date? = nil
    @State private var notes: String = ""
    @State private var ssaWednesday: Int? = nil

    @State private var initialized = false

    @FocusState private var focusedField: FocusField?
    @State private var amountIsFirstResponder: Bool = false

    @State private var reserveAmountIsFirstResponder: Bool = false
    @State private var showRebaseConfirm: Bool = false

    @State private var originalSchedule: ScheduleSignature? = nil
    @State private var lastPromptedSchedule: ScheduleSignature? = nil

    // Editing state and keyboard navigation
    private var isEditing: Bool { amountIsFirstResponder || reserveAmountIsFirstResponder || (focusedField != nil) }
    private var showBottomAccessoryBar: Bool {
        return isEditing
    }

    private var currentFocusField: FocusField? {
        if let f = focusedField { return f }
        if amountIsFirstResponder { return .amount }
        if reserveAmountIsFirstResponder { return .reserveAmount }
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
        amountIsFirstResponder = false
        reserveAmountIsFirstResponder = false
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
        amountIsFirstResponder = false
        reserveAmountIsFirstResponder = false
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
        case name, amount, notes, reserveAmount
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
        if isReserveFieldVisible { order.append(.reserveAmount) }
        return order
    }

    private func moveFocus(_ direction: Int) {
        guard !focusOrder.isEmpty else { return }
        func activate(_ field: FocusField) {
            switch field {
            case .name:
                self.focusedField = .name
                DispatchQueue.main.async {
                    self.amountIsFirstResponder = false
                    self.reserveAmountIsFirstResponder = false
                }
            case .amount:
                self.focusedField = .amount
                DispatchQueue.main.async {
                    self.reserveAmountIsFirstResponder = false
                    self.amountIsFirstResponder = true
                }
            case .notes:
                self.focusedField = .notes
                DispatchQueue.main.async {
                    self.amountIsFirstResponder = false
                    self.reserveAmountIsFirstResponder = false
                }
            case .reserveAmount:
                self.focusedField = .reserveAmount
                DispatchQueue.main.async {
                    self.amountIsFirstResponder = false
                    self.reserveAmountIsFirstResponder = true
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
        amountIsFirstResponder = false
        reserveAmountIsFirstResponder = false
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
                Picker("Day of Month", selection: binding) {
                    Text("None").tag(nil as Int?)
                    ForEach(1...31, id: \.self) { d in Text("\(d)").tag(Optional(d)) }
                }
            default:
                let dateBinding = Binding<Date>(
                    get: { firstPaymentDate ?? Date() },
                    set: { firstPaymentDate = $0; applyChanges(); detectScheduleChangeAndPromptIfNeeded() }
                )
                DatePicker("First Payment Date", selection: dateBinding, displayedComponents: .date)
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
            let plan = BillReservePlanner.planReserve(for: working, asOf: Date(), currentReserve: item.reserveBalance)
            if let plan {
                let next = BillReservePlanner.nextDue(for: working, asOf: Date())
                Section("Reserve") {
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
                            Text(formatCurrencyDecimal(plan.monthlyContribution))
                        }
                        LabeledContent("Seed this cycle") {
                            Text(formatCurrencyDecimal(plan.seedAmount))
                        }
                        Text("Applied once per cycle.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    // Informational warning if reserve is behind
                    if plan.seedAmount > 0 {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("Reserve is behind by \(formatCurrencyDecimal(plan.seedAmount)) this cycle.")
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }

                    Button("Mark this year paid…") { showRebaseConfirm = true }
                }
            }
        }
    }

    public var body: some View {
        Form {
            Section("Details") {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    TextField("Name", text: $name)
                        .onChange(of: name) { applyChanges() }
                        .focused($focusedField, equals: .name)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .submitLabel(.next)
                        .onSubmit { moveFocus(1) }
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

                TextField("Notes", text: $notes)
                    .onChange(of: notes) { applyChanges() }
                    .focused($focusedField, equals: .notes)
                    .submitLabel(.done)
                    .onSubmit { commitAndDismissKeyboard() }
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
            ToolbarItem(placement: .destructiveAction) {
                Button(role: .destructive) {
                    modelContext.delete(item)
                    try? modelContext.save()
                    dismiss()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
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
        .onChange(of: amountIsFirstResponder) { _, isFirst in
            if isFirst { focusedField = .amount }
        }
        .onChange(of: reserveAmountIsFirstResponder) { _, isFirst in
            if isFirst { focusedField = .reserveAmount }
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
            ssaWednesday: ssaWednesday
        )
        // Carry over createdAt so date-based logic remains stable
        temp.createdAt = item.createdAt
        return temp
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

#if os(iOS)
import UIKit

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
#endif

#if os(iOS)
import UIKit

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
#endif

#Preview {
    Text("Editor preview requires a CashFlowItem instance")
}

