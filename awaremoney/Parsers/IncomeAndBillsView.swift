import SwiftUI
import SwiftData

#if os(iOS)
import UIKit
#endif

fileprivate func monthlyEquivalent(amount: Decimal, frequency: PaymentFrequency) -> Decimal {
    switch frequency {
    default:
        return amount * frequency.monthlyEquivalentFactor
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

struct IncomeAndBillsView: View {
    var showsLocalModePicker: Bool = true

    @State private var selectedIncomeID: UUID? = nil
    @State private var selectedBillID: UUID? = nil
    @State private var showAddSheet = false
    @State private var addKind: CashFlowItem.Kind = .income
    @State private var activeSheet: ActiveSheet? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.presentationMode) private var presentationMode
    @EnvironmentObject private var settings: SettingsStore

    private enum IPadMode: String, CaseIterable { case incomeBills, summary }
    @State private var ipadMode: IPadMode = .incomeBills

    private enum PhoneMode: String, CaseIterable { case incomeBills = "Income & Bills"; case summary = "Summary" }
    @State private var phoneMode: PhoneMode = .incomeBills

    @State private var leftTopBarBottomY: CGFloat = 0
    @State private var rightTopBarBottomY: CGFloat = 0
    @Environment(\.sidebarTopBarBottomY) private var sidebarTopBarBottomY
    private var effectiveTopBarBottomY: CGFloat { max(sidebarTopBarBottomY, leftTopBarBottomY, rightTopBarBottomY) }
    private var leftHeaderTopCompensation: CGFloat { max(0, effectiveTopBarBottomY - leftTopBarBottomY) }
    private var rightHeaderTopCompensation: CGFloat { max(0, effectiveTopBarBottomY - rightTopBarBottomY) }

    private enum ActiveSheet: Identifiable {
        case add(kind: CashFlowItem.Kind)
        case edit(item: CashFlowItem)

        var id: String {
            switch self {
            case .add(let kind):
                return kind == .income ? "add-income" : "add-bill"
            case .edit(let item):
                return "edit-\(item.id.uuidString)"
            }
        }
    }

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \CashFlowItem.createdAt, order: .reverse) private var items: [CashFlowItem]

    var body: some View {
        Group {
            if isPad {
                iPadBody
            } else {
                iPhoneBody
            }
        }
    }

    private var isPad: Bool {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad
        #else
        return false
        #endif
    }

    @ViewBuilder
    private var iPadSummaryBody: some View {
        List {
            summarySection
        }
        .listStyle(.insetGrouped)
        .contentMargins(.top, 30)
    }

    // MARK: - iPad
    @ViewBuilder
    private var iPadBody: some View {
        Group {
            if ipadMode == .incomeBills {
                HStack(spacing: 0) {
                    // Left: Income column
                    VStack(alignment: .leading, spacing: 0) {
                        List {
                            if incomes.isEmpty {
                                Section {
                                    HStack(spacing: 8) {
                                        Image(systemName: "list.bullet")
                                            .foregroundStyle(.secondary)
                                        Text("No income yet")
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                    }
                                    .padding(.vertical, 8)
                                    .listRowSeparator(.hidden)
                                }
                            } else {
                                Section {
                                    ForEach(incomes) { item in
                                        row(for: item)
                                            .contentShape(Rectangle())
                                            .onTapGesture { activeSheet = .edit(item: item) }
                                    }
                                    .onDelete { indexSet in
                                        delete(items: indexSet.map { incomes[$0] })
                                    }
                                }
                            }
                        }
                        .listStyle(.insetGrouped)
                        .contentMargins(.top, 30)
                        .safeAreaInset(edge: .top) {
                            ZStack {
                                GeometryReader { proxy in
                                    Color.clear
                                        .preference(key: LeftTopBarBottomYKey.self, value: proxy.frame(in: .global).minY)
                                }
                                .frame(height: 0)
                                HStack {
                                    Spacer()
                                    Text("Income")
                                        .font(.title3)
                                        .bold()
                                    Spacer()
                                    Button {
                                        activeSheet = .add(kind: .income)
                                    } label: {
                                        Image(systemName: "plus")
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal)
                                .padding(.top, leftHeaderTopCompensation)
                                .padding(.vertical, 8)
                                .background(.bar)
                                .overlay(Divider(), alignment: .bottom)
                            }
                        }
                        .onPreferenceChange(LeftTopBarBottomYKey.self) { value in
                            leftTopBarBottomY = value
                        }
                    }
                    .frame(minWidth: 300, idealWidth: 340, maxWidth: 380)

                    Divider()

                    // Right: Bills column
                    VStack(alignment: .leading, spacing: 0) {
                        List {
                            if bills.isEmpty {
                                Section {
                                    HStack(spacing: 8) {
                                        Image(systemName: "list.bullet")
                                            .foregroundStyle(.secondary)
                                        Text("No bills yet")
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                    }
                                    .padding(.vertical, 8)
                                    .listRowSeparator(.hidden)
                                }
                            } else {
                                Section {
                                    ForEach(bills) { item in
                                        row(for: item)
                                            .contentShape(Rectangle())
                                            .onTapGesture { activeSheet = .edit(item: item) }
                                    }
                                    .onDelete { indexSet in
                                        delete(items: indexSet.map { bills[$0] })
                                    }
                                }
                            }
                        }
                        .listStyle(.insetGrouped)
                        .contentMargins(.top, 30)
                        .safeAreaInset(edge: .top) {
                            ZStack {
                                GeometryReader { proxy in
                                    Color.clear
                                        .preference(key: RightTopBarBottomYKey.self, value: proxy.frame(in: .global).minY)
                                }
                                .frame(height: 0)
                                HStack {
                                    Spacer()
                                    Text("Bills")
                                        .font(.title3)
                                        .bold()
                                    Spacer()
                                    Button {
                                        activeSheet = .add(kind: .bill)
                                    } label: {
                                        Image(systemName: "plus")
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal)
                                .padding(.top, rightHeaderTopCompensation)
                                .padding(.vertical, 8)
                                .background(.bar)
                                .overlay(Divider(), alignment: .bottom)
                            }
                        }
                        .onPreferenceChange(RightTopBarBottomYKey.self) { value in
                            rightTopBarBottomY = value
                        }
                    }
                    .frame(minWidth: 300, idealWidth: 340, maxWidth: 380)
                }
                .environment(\.sidebarTopBarBottomY, effectiveTopBarBottomY)
            } else {
                iPadSummaryBody
            }
        }
        .animation(.default, value: ipadMode)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(ipadMode == .incomeBills ? "Income & Bills" : "Monthly Summary")
                    .font(.largeTitle)
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .add(let kind):
                AddCashFlowItemView(initialKind: kind) { newItem in
                    modelContext.insert(newItem)
                    try? modelContext.save()
                    activeSheet = .edit(item: newItem)
                }
                .navigationTitle(kind == .income ? "Add Income" : "Add Bill")
                .environmentObject(settings)
            case .edit(let item):
                EditCashFlowItemView(
                    item: item,
                    onSave: {
                        try? modelContext.save()
                        activeSheet = nil
                    },
                    onDelete: {
                        modelContext.delete(item)
                        try? modelContext.save()
                        activeSheet = nil
                    }
                )
                .environmentObject(settings)
            }
        }
    }

    // MARK: - iPhone
    @ViewBuilder
    private var iPhoneBody: some View {
        NavigationStack {
            List {
                if showsLocalModePicker {
                    Section {
                        Picker("View", selection: $phoneMode) {
                            Text("Income & Bills").tag(PhoneMode.incomeBills)
                            Text("Summary").tag(PhoneMode.summary)
                        }
                        .pickerStyle(.segmented)
                    }

                    if phoneMode == .incomeBills {
                        if incomes.isEmpty && bills.isEmpty {
                            ContentUnavailableView("No income or bills yet", systemImage: "list.bullet", description: Text("Add your income and recurring bills to compute your debt budget."))
                        } else {
                            Section("Income") {
                                ForEach(incomes) { item in
                                    NavigationLink(destination: EditCashFlowItemView(
                                        item: item,
                                        onSave: {
                                            try? modelContext.save()
                                        },
                                        onDelete: {
                                            modelContext.delete(item)
                                            try? modelContext.save()
                                        }
                                    )) {
                                        row(for: item)
                                    }
                                }
                                .onDelete { indexSet in
                                    delete(items: indexSet.map { incomes[$0] })
                                }
                                if incomes.isEmpty {
                                    Text("No income added yet").font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                            Section("Bills") {
                                ForEach(bills) { item in
                                    NavigationLink(destination: EditCashFlowItemView(
                                        item: item,
                                        onSave: {
                                            try? modelContext.save()
                                        },
                                        onDelete: {
                                            modelContext.delete(item)
                                            try? modelContext.save()
                                        }
                                    )) {
                                        row(for: item)
                                    }
                                }
                                .onDelete { indexSet in
                                    delete(items: indexSet.map { bills[$0] })
                                }
                                if bills.isEmpty {
                                    Text("No bills added yet").font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                    } else {
                        summarySection
                    }
                } else {
                    // No local picker: always show Income & Bills content (outer container controls summary)
                    if incomes.isEmpty && bills.isEmpty {
                        ContentUnavailableView("No income or bills yet", systemImage: "list.bullet", description: Text("Add your income and recurring bills to compute your debt budget."))
                    } else {
                        Section("Income") {
                            ForEach(incomes) { item in
                                NavigationLink(destination: EditCashFlowItemView(
                                    item: item,
                                    onSave: {
                                        try? modelContext.save()
                                    },
                                    onDelete: {
                                        modelContext.delete(item)
                                        try? modelContext.save()
                                    }
                                )) {
                                    row(for: item)
                                }
                            }
                            .onDelete { indexSet in
                                delete(items: indexSet.map { incomes[$0] })
                            }
                            if incomes.isEmpty {
                                Text("No income added yet").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        Section("Bills") {
                            ForEach(bills) { item in
                                NavigationLink(destination: EditCashFlowItemView(
                                    item: item,
                                    onSave: {
                                        try? modelContext.save()
                                    },
                                    onDelete: {
                                        modelContext.delete(item)
                                        try? modelContext.save()
                                    }
                                )) {
                                    row(for: item)
                                }
                            }
                            .onDelete { indexSet in
                                delete(items: indexSet.map { bills[$0] })
                            }
                            if bills.isEmpty {
                                Text("No bills added yet").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Income & Bills")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Add Income") {
                            addKind = .income
                            showAddSheet = true
                        }
                        Button("Add Bill") {
                            addKind = .bill
                            showAddSheet = true
                        }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAddSheet) {
                AddCashFlowItemView(initialKind: addKind) { newItem in
                    modelContext.insert(newItem)
                    try? modelContext.save()
                }
                .environmentObject(settings)
            }
        }
    }

    private func selectedItemForDetail() -> CashFlowItem? {
        if let id = selectedIncomeID {
            return incomes.first(where: { $0.id == id })
        }
        if let id = selectedBillID {
            return bills.first(where: { $0.id == id })
        }
        return nil
    }

    // MARK: - Data
    private var incomes: [CashFlowItem] { items.filter { $0.kind == .income } }
    private var bills: [CashFlowItem] { items.filter { $0.kind == .bill } }

    private var monthlyIncomeTotal: Decimal { incomes.reduce(0) { $0 + monthlyEquivalent(amount: $1.amount, frequency: $1.frequency) } }
    private var monthlyBillsTotal: Decimal { bills.reduce(0) { $0 + monthlyEquivalent(amount: $1.amount, frequency: $1.frequency) } }
    private var monthlyNetForDebt: Decimal { monthlyIncomeTotal - monthlyBillsTotal }

    // MARK: - Row & Summary
    @ViewBuilder private func row(for item: CashFlowItem) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.headline)
                Text(subtitle(for: item)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(formatCurrency(item.amount))
        }
    }

    private func subtitle(for item: CashFlowItem) -> String {
        var parts: [String] = []
        parts.append(label(for: item.frequency))
        if let ssa = extractSSAWednesday(from: item.notes) {
            parts.append("\(ordinal(ssa)) Wednesday")
        } else if let date = item.firstPaymentDate {
            parts.append(date.formatted(date: .abbreviated, time: .omitted))
        } else if let d = item.dayOfMonth {
            parts.append("Day \(d)")
        }
        return parts.joined(separator: " • ")
    }

    @ViewBuilder private var summarySection: some View {
        IncomeBillsSummarySections(items: items)
    }

    // MARK: - Utils
    private func delete(items: [CashFlowItem]) {
        let deletedIDs = Set(items.map { $0.id })
        for it in items { modelContext.delete(it) }
        try? modelContext.save()
        if let sel = selectedIncomeID, deletedIDs.contains(sel) || !self.items.contains(where: { $0.id == sel }) {
            selectedIncomeID = nil
        }
        if let sel = selectedBillID, deletedIDs.contains(sel) || !self.items.contains(where: { $0.id == sel }) {
            selectedBillID = nil
        }
    }

    private func formatCurrency(_ amount: Decimal) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = settings.currencyCode
        return nf.string(from: NSDecimalNumber(decimal: amount)) ?? "\(amount)"
    }

    private func label(for f: PaymentFrequency) -> String {
        return f.displayLabel
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

    private func ordinal(_ n: Int) -> String {
        switch n {
        case 1: return "1st"
        case 2: return "2nd"
        case 3: return "3rd"
        default: return "\(n)th"
        }
    }
}

private struct LeftTopBarBottomYKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct RightTopBarBottomYKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct SidebarTopBarBottomYKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

private extension EnvironmentValues {
    var sidebarTopBarBottomY: CGFloat {
        get { self[SidebarTopBarBottomYKey.self] }
        set { self[SidebarTopBarBottomYKey.self] = newValue }
    }
}

private struct AddCashFlowItemView: View {
    let initialKind: CashFlowItem.Kind

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: SettingsStore
    @State private var name: String = ""
    @State private var amountValue: Decimal = 0
    @State private var frequency: PaymentFrequency = .monthly
    @State private var dayOfMonth: Int? = nil
    @State private var firstPaymentDate: Date? = nil
    @State private var notes: String = ""
    @State private var ssaWednesday: Int? = nil

    enum Field: Hashable { case name, amount, notes }
    @State private var amountIsFirstResponder: Bool = false
    @State private var nameIsFirstResponder: Bool = false
    @State private var notesIsFirstResponder: Bool = false
    private let fieldOrder: [Field] = [.name, .amount, .notes]

    // Removed: @FocusState private var focusedField: Field?

    private func focus(_ field: Field) {
        nameIsFirstResponder = (field == .name)
        amountIsFirstResponder = (field == .amount)
        notesIsFirstResponder = (field == .notes)
    }

    private func currentField() -> Field? {
        if nameIsFirstResponder { return .name }
        if amountIsFirstResponder { return .amount }
        if notesIsFirstResponder { return .notes }
        return nil
    }

    private func goPrev() {
        guard let current = currentField(), let idx = fieldOrder.firstIndex(of: current), idx > 0 else { return }
        focus(fieldOrder[idx - 1])
    }

    private func goNext() {
        guard let current = currentField(), let idx = fieldOrder.firstIndex(of: current), idx < fieldOrder.count - 1 else { return }
        focus(fieldOrder[idx + 1])
    }

    let onAdd: (CashFlowItem) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    Label("Enter a name and a valid amount to enable Add.", systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .opacity(isValid ? 0 : 1)
                        .accessibilityHidden(isValid)
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        SelectAllTextField(
                            text: $name,
                            placeholder: "Name",
                            isFirstResponder: $nameIsFirstResponder,
                            returnKeyType: .next,
                            onPrev: { goPrev() },
                            onNext: { focus(.amount) },
                            onDone: { commitAndDismissKeyboard() }
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("Name")

                        CurrencyAmountField(
                            value: $amountValue,
                            placeholder: "Amount",
                            currencyCode: settings.currencyCode,
                            isFirstResponder: $amountIsFirstResponder,
                            onPrev: { focus(.name) },
                            onNext: { focus(.notes) },
                            onDone: { commitAndDismissKeyboard() }
                        )
                        .frame(minWidth: 100, idealWidth: 120, maxWidth: 160, alignment: .trailing)
                        .accessibilityLabel("Amount")
                    }
                    Picker("Frequency", selection: $frequency) {
                        Text("Monthly").tag(PaymentFrequency.monthly)
                        Text("Twice per month").tag(PaymentFrequency.semimonthly)
                        Text("Every 2 weeks").tag(PaymentFrequency.biweekly)
                        Text("Weekly").tag(PaymentFrequency.weekly)
                        Text("Yearly").tag(PaymentFrequency.yearly)
                    }
                    .onChange(of: frequency) { _, newValue in
                        if initialKind == .income {
                            switch newValue.normalized {
                            case .monthly, .semimonthly, .biweekly, .weekly, .socialSecurity:
                                if dayOfMonth == nil { dayOfMonth = 1 }
                                firstPaymentDate = nil
                            default:
                                break
                            }
                        }
                    }
                    if initialKind == .income && frequency == .monthly {
                        Picker("SSA Wednesday", selection: Binding<Int?>(
                            get: { ssaWednesday },
                            set: { ssaWednesday = $0 }
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
                    if ssaWednesday == nil {
                        switch frequency.normalized {
                        case .monthly, .semimonthly, .biweekly, .weekly, .socialSecurity:
                            Picker("Day of Month", selection: Binding<Int?>(
                                get: { dayOfMonth },
                                set: { dayOfMonth = $0 }
                            )) {
                                Text("None").tag(nil as Int?)
                                ForEach(1...31, id: \.self) { d in Text("\(d)").tag(Optional(d)) }
                            }
                        default:
                            DatePicker("First Payment Date", selection: Binding<Date>(
                                get: { firstPaymentDate ?? Date() },
                                set: { firstPaymentDate = $0 }
                            ), displayedComponents: .date)
                        }
                    }
                    SelectAllTextField(
                        text: $notes,
                        placeholder: "Notes",
                        isFirstResponder: $notesIsFirstResponder,
                        returnKeyType: .done,
                        onPrev: { focus(.amount) },
                        onNext: { goNext() },
                        onDone: { commitAndDismissKeyboard() }
                    )
                }
            }
            .navigationTitle(initialKind == .income ? "Add Income" : "Add Bill")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    PlanToolbarButton("Cancel",fixedWidth: 70) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmedName.isEmpty && amountValue > 0 {
                            let finalNotes: String? = {
                                let base = notes
                                let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
                                let cleaned = removeSSAToken(from: trimmed)
                                if let n = ssaWednesday {
                                    let token = "[SSA_WED]=\(n)"
                                    if cleaned.isEmpty { return token }
                                    else { return cleaned + " " + token }
                                } else {
                                    return cleaned.isEmpty ? nil : cleaned
                                }
                            }()
                            let item = CashFlowItem(kind: initialKind, name: trimmedName, amount: amountValue, frequency: frequency, dayOfMonth: dayOfMonth, firstPaymentDate: firstPaymentDate, notes: finalNotes)
                            onAdd(item)
                            nameIsFirstResponder = false
                            amountIsFirstResponder = false
                            notesIsFirstResponder = false
                            dismiss()
                        }
                    } label: {
                        PlanMenuLabel(title: "Add", titleFont: .callout)
                    }
                    .buttonStyle(.plain)
                    .disabled(!isValid)
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Button(action: { goPrev() }) {
                        Image(systemName: "chevron.left")
                    }
                    .disabled({
                        guard let current = currentField(), let idx = fieldOrder.firstIndex(of: current) else { return true }
                        return idx == 0
                    }())

                    Button(action: { goNext() }) {
                        Image(systemName: "chevron.right")
                    }
                    .disabled({
                        guard let current = currentField(), let idx = fieldOrder.firstIndex(of: current) else { return true }
                        return idx >= fieldOrder.count - 1
                    }())

                    Spacer()

                    Button(action: { commitAndDismissKeyboard() }) {
                        Image(systemName: "checkmark.circle.fill")
                    }
                }
            }
        }
        // Removed: .onChange(of: focusedField) { ... }
        // Removed: .onChange(of: nameIsFirstResponder) { ... }
        // Removed: .onChange(of: amountIsFirstResponder) { ... }
        // Removed: .onChange(of: notesIsFirstResponder) { ... }
        .onAppear {
            if initialKind == .income {
                switch frequency.normalized {
                case .monthly, .semimonthly, .biweekly, .weekly, .socialSecurity:
                    if dayOfMonth == nil { dayOfMonth = 1 }
                default: break
                }
            }
        }
    }

    private var isValid: Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedName.isEmpty && amountValue > 0
    }

    private func commitAndDismissKeyboard() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty && amountValue > 0 {
            let finalNotes: String? = {
                let base = notes
                let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
                let cleaned = removeSSAToken(from: trimmed)
                if let n = ssaWednesday {
                    let token = "[SSA_WED]=\(n)"
                    if cleaned.isEmpty { return token } else { return cleaned + " " + token }
                } else {
                    return cleaned.isEmpty ? nil : cleaned
                }
            }()
            let item = CashFlowItem(
                kind: initialKind,
                name: trimmedName,
                amount: amountValue,
                frequency: frequency,
                dayOfMonth: dayOfMonth,
                firstPaymentDate: firstPaymentDate,
                notes: finalNotes
            )
            onAdd(item)
            nameIsFirstResponder = false
            amountIsFirstResponder = false
            notesIsFirstResponder = false
            dismiss()
        } else {
            // If invalid, just dismiss the keyboard
            nameIsFirstResponder = false
            amountIsFirstResponder = false
            notesIsFirstResponder = false
        }
    }

    private func removeSSAToken(from s: String) -> String {
        if s.isEmpty { return s }
        var parts = s.split(separator: " ").map(String.init)
        parts.removeAll { $0.hasPrefix("[SSA_WED]=") }
        return parts.joined(separator: " ")
    }
}

private struct EditCashFlowItemView: View {
    let item: CashFlowItem
    let onSave: () -> Void
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: SettingsStore

    @State private var name: String = ""
    @State private var amountValue: Decimal = 0
    @State private var frequency: PaymentFrequency = .monthly
    @State private var dayOfMonth: Int? = nil
    @State private var firstPaymentDate: Date? = nil
    @State private var notes: String = ""
    @State private var ssaWednesday: Int? = nil

    enum Field: Hashable { case name, amount, notes }
    @State private var amountIsFirstResponder: Bool = false
    @State private var nameIsFirstResponder: Bool = false
    @State private var notesIsFirstResponder: Bool = false
    private let fieldOrder: [Field] = [.name, .amount, .notes]

    // Removed: @FocusState private var focusedField: Field?

    private func focus(_ field: Field) {
        nameIsFirstResponder = (field == .name)
        amountIsFirstResponder = (field == .amount)
        notesIsFirstResponder = (field == .notes)
    }

    private func currentField() -> Field? {
        if nameIsFirstResponder { return .name }
        if amountIsFirstResponder { return .amount }
        if notesIsFirstResponder { return .notes }
        return nil
    }

    private func goPrev() {
        guard let current = currentField(), let idx = fieldOrder.firstIndex(of: current), idx > 0 else { return }
        focus(fieldOrder[idx - 1])
    }

    private func goNext() {
        guard let current = currentField(), let idx = fieldOrder.firstIndex(of: current), idx < fieldOrder.count - 1 else { return }
        focus(fieldOrder[idx + 1])
    }

    private var isIncome: Bool { item.kind == .income }

    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        SelectAllTextField(
                            text: $name,
                            placeholder: "Name",
                            isFirstResponder: $nameIsFirstResponder,
                            returnKeyType: .next,
                            onPrev: { goPrev() },
                            onNext: { focus(.amount) },
                            onDone: { commitAndDismissKeyboard() }
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("Name")

                        CurrencyAmountField(
                            value: $amountValue,
                            placeholder: "Amount",
                            currencyCode: settings.currencyCode,
                            isFirstResponder: $amountIsFirstResponder,
                            onPrev: { focus(.name) },
                            onNext: { focus(.notes) },
                            onDone: { commitAndDismissKeyboard() }
                        )
                        .frame(minWidth: 100, idealWidth: 120, maxWidth: 160, alignment: .trailing)
                        .accessibilityLabel("Amount")
                    }
                    Picker("Frequency", selection: $frequency) {
                        Text("Monthly").tag(PaymentFrequency.monthly)
                        Text("Twice per month").tag(PaymentFrequency.semimonthly)
                        Text("Every 2 weeks").tag(PaymentFrequency.biweekly)
                        Text("Weekly").tag(PaymentFrequency.weekly)
                        Text("Yearly").tag(PaymentFrequency.yearly)
                    }
                    .onChange(of: frequency) { _, newValue in
                        if isIncome {
                            switch newValue.normalized {
                            case .monthly, .semimonthly, .biweekly, .weekly, .socialSecurity:
                                if dayOfMonth == nil { dayOfMonth = 1 }
                                firstPaymentDate = nil
                            default:
                                break
                            }
                        }
                    }
                    if isIncome && frequency == .monthly {
                        Picker("SSA Wednesday", selection: Binding<Int?>(
                            get: { ssaWednesday },
                            set: { ssaWednesday = $0 }
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
                    if ssaWednesday == nil {
                        switch frequency.normalized {
                        case .monthly, .semimonthly, .biweekly, .weekly, .socialSecurity:
                            Picker("Day of Month", selection: Binding<Int?>(
                                get: { dayOfMonth },
                                set: { dayOfMonth = $0 }
                            )) {
                                Text("None").tag(nil as Int?)
                                ForEach(1...31, id: \.self) { d in Text("\(d)").tag(Optional(d)) }
                            }
                        default:
                            DatePicker("First Payment Date", selection: Binding<Date>(
                                get: { firstPaymentDate ?? Date() },
                                set: { firstPaymentDate = $0 }
                            ), displayedComponents: .date)
                        }
                    }
                    SelectAllTextField(
                        text: $notes,
                        placeholder: "Notes",
                        isFirstResponder: $notesIsFirstResponder,
                        returnKeyType: .done,
                        onPrev: { focus(.amount) },
                        onNext: { goNext() },
                        onDone: { commitAndDismissKeyboard() }
                    )
                }
            }
            .navigationTitle(isIncome ? "Edit Income" : "Edit Bill")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    PlanToolbarButton("Cancel",fixedWidth: 70) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmedName.isEmpty {
                            let finalNotes: String? = {
                                let base = notes
                                let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
                                let cleaned = removeSSAToken(from: trimmed)
                                if let n = ssaWednesday {
                                    let token = "[SSA_WED]=\(n)"
                                    if cleaned.isEmpty { return token }
                                    else { return cleaned + " " + token }
                                } else {
                                    return cleaned.isEmpty ? nil : cleaned
                                }
                            }()
                            // Apply edits back to the model
                            item.name = trimmedName
                            item.amount = amountValue
                            item.frequency = frequency
                            item.dayOfMonth = dayOfMonth
                            item.firstPaymentDate = firstPaymentDate
                            item.notes = finalNotes
                            onSave()
                            dismiss()
                        }
                    } label: {
                        PlanMenuLabel(title: "Save", titleFont: .callout)
                    }
                    .buttonStyle(.plain)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .destructive) {
                        onDelete()
                        dismiss()
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Button(action: { goPrev() }) {
                        Image(systemName: "chevron.left")
                    }
                    .disabled({
                        guard let current = currentField(), let idx = fieldOrder.firstIndex(of: current) else { return true }
                        return idx == 0
                    }())

                    Button(action: { goNext() }) {
                        Image(systemName: "chevron.right")
                    }
                    .disabled({
                        guard let current = currentField(), let idx = fieldOrder.firstIndex(of: current) else { return true }
                        return idx >= fieldOrder.count - 1
                    }())

                    Spacer()

                    Button(action: { commitAndDismissKeyboard() }) {
                        Image(systemName: "checkmark.circle.fill")
                    }
                }
            }
        }
        // Removed: .onChange(of: focusedField) { ... }
        // Removed: .onChange(of: nameIsFirstResponder) { ... }
        // Removed: .onChange(of: amountIsFirstResponder) { ... }
        // Removed: .onChange(of: notesIsFirstResponder) { ... }
        .onAppear {
            // Seed state from the existing item
            name = item.name
            amountValue = item.amount
            frequency = item.frequency
            dayOfMonth = item.dayOfMonth
            firstPaymentDate = item.firstPaymentDate
            notes = item.notes ?? ""
            ssaWednesday = extractSSAWednesday(from: item.notes)
            if isIncome {
                switch frequency.normalized {
                case .monthly, .semimonthly, .biweekly, .weekly, .socialSecurity:
                    if dayOfMonth == nil { dayOfMonth = 1 }
                default: break
                }
            }
        }
    }

    private func commitAndDismissKeyboard() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            let finalNotes: String? = {
                let base = notes
                let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
                let cleaned = removeSSAToken(from: trimmed)
                if let n = ssaWednesday {
                    let token = "[SSA_WED]=\(n)"
                    if cleaned.isEmpty { return token } else { return cleaned + " " + token }
                } else {
                    return cleaned.isEmpty ? nil : cleaned
                }
            }()
            item.name = trimmedName
            item.amount = amountValue
            item.frequency = frequency
            item.dayOfMonth = dayOfMonth
            item.firstPaymentDate = firstPaymentDate
            item.notes = finalNotes
            onSave()
            dismiss()
        } else {
            // If invalid, just dismiss the keyboard
        }
    }

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
}

#if os(iOS)
private struct CurrencyAmountField: UIViewRepresentable {
    @Binding var value: Decimal
    var placeholder: String
    var currencyCode: String = "USD"
    @Binding var isFirstResponder: Bool
    var onPrev: (() -> Void)? = nil
    var onNext: (() -> Void)? = nil
    var onDone: (() -> Void)? = nil
    func makeUIView(context: Context) -> UITextField {
        let tf = UITextField(frame: .zero)
        tf.keyboardType = .decimalPad
        tf.textAlignment = .right
        tf.placeholder = placeholder
        tf.delegate = context.coordinator
        tf.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged(_:)), for: .editingChanged)
        // Seed initial formatted text
        let formatted = context.coordinator.formatter.string(from: NSDecimalNumber(decimal: value)) ?? ""
        tf.text = formatted

        // Add keyboard accessory toolbar with Prev/Next/Done
        let toolbar = UIToolbar()
        let prev = UIBarButtonItem(image: UIImage(systemName: "chevron.left"), style: .plain, target: context.coordinator, action: #selector(Coordinator.prevTapped))
        let next = UIBarButtonItem(image: UIImage(systemName: "chevron.right"), style: .plain, target: context.coordinator, action: #selector(Coordinator.nextTapped))
        let flex = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        let done = UIBarButtonItem(image: UIImage(systemName: "checkmark.circle.fill"), style: .done, target: context.coordinator, action: #selector(Coordinator.doneTapped))
        toolbar.items = [prev, next, flex, done]
        toolbar.sizeToFit()
        tf.inputAccessoryView = toolbar

        return tf
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        // Keep alignment and placeholder up-to-date
        uiView.textAlignment = .right
        uiView.placeholder = placeholder
        // Manage first responder state
        if isFirstResponder, !uiView.isFirstResponder {
            uiView.becomeFirstResponder()
        } else if !isFirstResponder, uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
        // If not editing, keep text formatted to the current value
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
            if let dec = parseDecimalAmount(from: text) {
                parent.value = dec
            } else {
                parent.value = 0
            }
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            // Select all text when editing begins for quick replacement
            DispatchQueue.main.async {
                textField.selectAll(nil)
            }
            parent.isFirstResponder = true
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            // Reformat to currency when editing ends
            isFormatting = true
            let formatted = formatter.string(from: NSDecimalNumber(decimal: parent.value)) ?? ""
            textField.text = formatted
            isFormatting = false
            parent.isFirstResponder = false
        }

        @objc func prevTapped() {
            parent.onPrev?()
        }

        @objc func nextTapped() {
            parent.onNext?()
        }

        @objc func doneTapped() {
            parent.onDone?()
        }
    }
}

private struct SelectAllTextField: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String
    @Binding var isFirstResponder: Bool
    var returnKeyType: UIReturnKeyType = .default
    var onPrev: (() -> Void)? = nil
    var onNext: (() -> Void)? = nil
    var onDone: (() -> Void)? = nil

    func makeUIView(context: Context) -> UITextField {
        let tf = UITextField(frame: .zero)
        tf.placeholder = placeholder
        tf.text = text
        tf.delegate = context.coordinator
        tf.returnKeyType = returnKeyType
        tf.borderStyle = .none

        // Add keyboard accessory toolbar with Prev/Next/Done
        let toolbar = UIToolbar()
        let prev = UIBarButtonItem(image: UIImage(systemName: "chevron.left"), style: .plain, target: context.coordinator, action: #selector(Coordinator.prevTapped))
        let next = UIBarButtonItem(image: UIImage(systemName: "chevron.right"), style: .plain, target: context.coordinator, action: #selector(Coordinator.nextTapped))
        let flex = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        let done = UIBarButtonItem(image: UIImage(systemName: "checkmark.circle.fill"), style: .done, target: context.coordinator, action: #selector(Coordinator.doneTapped))
        toolbar.items = [prev, next, flex, done]
        toolbar.sizeToFit()
        tf.inputAccessoryView = toolbar

        return tf
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        uiView.placeholder = placeholder
        // Manage first responder state
        if isFirstResponder, !uiView.isFirstResponder {
            uiView.becomeFirstResponder()
        } else if !isFirstResponder, uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
        // Keep text in sync if not editing
        if !uiView.isFirstResponder {
            if uiView.text != text {
                uiView.text = text
            }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, UITextFieldDelegate {
        var parent: SelectAllTextField

        init(_ parent: SelectAllTextField) {
            self.parent = parent
        }

        @objc func prevTapped() { parent.onPrev?() }
        @objc func nextTapped() { parent.onNext?() }
        @objc func doneTapped() { parent.onDone?() }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            DispatchQueue.main.async { textField.selectAll(nil) }
            parent.isFirstResponder = true
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            parent.isFirstResponder = false
        }

        func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            if let current = textField.text as NSString? {
                let newText = current.replacingCharacters(in: range, with: string)
                parent.text = newText
            }
            return true
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
#endif


