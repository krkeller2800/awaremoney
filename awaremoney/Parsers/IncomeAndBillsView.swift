import SwiftUI
import SwiftData

fileprivate func monthlyEquivalent(amount: Decimal, frequency: PaymentFrequency) -> Decimal {
    switch frequency {
    default:
        return amount * frequency.monthlyEquivalentFactor
    }
}

struct IncomeAndBillsView: View {
    @State private var selectedIncomeID: UUID? = nil
    @State private var selectedBillID: UUID? = nil
    @State private var showAddSheet = false
    @State private var addKind: CashFlowItem.Kind = .income
    @State private var activeSheet: ActiveSheet? = nil

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
            }
        }
    }

    // MARK: - iPhone
    @ViewBuilder
    private var iPhoneBody: some View {
        NavigationStack {
            List {
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
                                NavigationLink(destination: CashFlowItemEditorView(item: item)) {
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
                                NavigationLink(destination: CashFlowItemEditorView(item: item)) {
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
        Section("Monthly Summary") {
            LabeledContent("Income") { Text(formatCurrency(monthlyIncomeTotal)) }
            LabeledContent("Bills") { Text(formatCurrency(monthlyBillsTotal)) }
            LabeledContent("Net for Debt") { Text(formatCurrency(monthlyNetForDebt)) }
                .foregroundStyle(monthlyNetForDebt < 0 ? .red : .primary)
        }
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
        nf.currencyCode = "USD"
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
    @State private var name: String = ""
    @State private var amountText: String = ""
    @State private var frequency: PaymentFrequency = .monthly
    @State private var dayOfMonth: Int? = nil
    @State private var firstPaymentDate: Date? = nil
    @State private var notes: String = ""
    @State private var ssaWednesday: Int? = nil

    enum Field: Hashable { case name, amount, notes }
    @FocusState private var focusedField: Field?
    private let fieldOrder: [Field] = [.name, .amount, .notes]

    private func goPrev() {
        guard let current = focusedField, let idx = fieldOrder.firstIndex(of: current), idx > 0 else { return }
        focusedField = fieldOrder[idx - 1]
    }

    private func goNext() {
        guard let current = focusedField, let idx = fieldOrder.firstIndex(of: current), idx < fieldOrder.count - 1 else { return }
        focusedField = fieldOrder[idx + 1]
    }

    let onAdd: (CashFlowItem) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    TextField("Name", text: $name)
                        .focused($focusedField, equals: .name)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .amount }
                    TextField("Amount", text: $amountText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .focused($focusedField, equals: .amount)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .notes }
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
                    TextField("Notes", text: $notes)
                        .focused($focusedField, equals: .notes)
                        .submitLabel(.done)
                        .onSubmit { commitAndDismissKeyboard() }
                }
            }
            .navigationTitle(initialKind == .income ? "Add Income" : "Add Bill")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        if let amt = Decimal(string: amountText.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespacesAndNewlines)), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
                            let item = CashFlowItem(kind: initialKind, name: name, amount: amt, frequency: frequency, dayOfMonth: dayOfMonth, firstPaymentDate: firstPaymentDate, notes: finalNotes)
                            onAdd(item)
                            dismiss()
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Button(action: { goPrev() }) {
                        Image(systemName: "chevron.left")
                    }
                    .disabled({
                        guard let current = focusedField, let idx = fieldOrder.firstIndex(of: current) else { return true }
                        return idx == 0
                    }())

                    Button(action: { goNext() }) {
                        Image(systemName: "chevron.right")
                    }
                    .disabled({
                        guard let current = focusedField, let idx = fieldOrder.firstIndex(of: current) else { return true }
                        return idx >= fieldOrder.count - 1
                    }())

                    Spacer()

                    Button(action: { commitAndDismissKeyboard() }) {
                        Image(systemName: "checkmark.circle.fill")
                    }
                }
            }
        }
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

    private func commitAndDismissKeyboard() {
        let cleanedAmount = amountText
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "$", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let amt = Decimal(string: cleanedAmount), !trimmedName.isEmpty {
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
                amount: amt,
                frequency: frequency,
                dayOfMonth: dayOfMonth,
                firstPaymentDate: firstPaymentDate,
                notes: finalNotes
            )
            onAdd(item)
            focusedField = nil
            dismiss()
        } else {
            // If invalid, just dismiss the keyboard
            focusedField = nil
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

    @State private var name: String = ""
    @State private var amountText: String = ""
    @State private var frequency: PaymentFrequency = .monthly
    @State private var dayOfMonth: Int? = nil
    @State private var firstPaymentDate: Date? = nil
    @State private var notes: String = ""
    @State private var ssaWednesday: Int? = nil

    enum Field: Hashable { case name, amount, notes }
    @FocusState private var focusedField: Field?
    private let fieldOrder: [Field] = [.name, .amount, .notes]

    private func goPrev() {
        guard let current = focusedField, let idx = fieldOrder.firstIndex(of: current), idx > 0 else { return }
        focusedField = fieldOrder[idx - 1]
    }

    private func goNext() {
        guard let current = focusedField, let idx = fieldOrder.firstIndex(of: current), idx < fieldOrder.count - 1 else { return }
        focusedField = fieldOrder[idx + 1]
    }

    private var isIncome: Bool { item.kind == .income }

    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    TextField("Name", text: $name)
                        .focused($focusedField, equals: .name)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .amount }
                    TextField("Amount", text: $amountText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .focused($focusedField, equals: .amount)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .notes }
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
                    TextField("Notes", text: $notes)
                        .focused($focusedField, equals: .notes)
                        .submitLabel(.done)
                        .onSubmit { commitAndDismissKeyboard() }
                }
            }
            .navigationTitle(isIncome ? "Edit Income" : "Edit Bill")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let amt = Decimal(string: amountText.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespacesAndNewlines)), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
                            item.name = name
                            item.amount = amt
                            item.frequency = frequency
                            item.dayOfMonth = dayOfMonth
                            item.firstPaymentDate = firstPaymentDate
                            item.notes = finalNotes
                            onSave()
                            dismiss()
                        }
                    }
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
                        guard let current = focusedField, let idx = fieldOrder.firstIndex(of: current) else { return true }
                        return idx == 0
                    }())

                    Button(action: { goNext() }) {
                        Image(systemName: "chevron.right")
                    }
                    .disabled({
                        guard let current = focusedField, let idx = fieldOrder.firstIndex(of: current) else { return true }
                        return idx >= fieldOrder.count - 1
                    }())

                    Spacer()

                    Button(action: { commitAndDismissKeyboard() }) {
                        Image(systemName: "checkmark.circle.fill")
                    }
                }
            }
        }
        .onAppear {
            // Seed state from the existing item
            name = item.name
            amountText = NSDecimalNumber(decimal: item.amount).stringValue
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
        let cleanedAmount = amountText
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "$", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let amt = Decimal(string: cleanedAmount), !trimmedName.isEmpty {
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
            item.amount = amt
            item.frequency = frequency
            item.dayOfMonth = dayOfMonth
            item.firstPaymentDate = firstPaymentDate
            item.notes = finalNotes
            onSave()
            focusedField = nil
            dismiss()
        } else {
            // If invalid, just dismiss the keyboard
            focusedField = nil
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

