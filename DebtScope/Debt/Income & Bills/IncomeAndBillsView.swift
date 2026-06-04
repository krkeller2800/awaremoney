import SwiftUI
import SwiftData
import Charts

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

fileprivate func removeSSAToken(from s: String) -> String {
    if s.isEmpty { return s }
    var parts = s.split(separator: " ").map(String.init)
    parts.removeAll { $0.hasPrefix("[SSA_WED]=") }
    return parts.joined(separator: " ")
}

struct IncomeAndBillsView: View {
    var showsLocalModePicker: Bool = true
    var externalPhoneMode: PhoneMode? = nil
    var embeddedInNavigation: Bool = false

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

    enum PhoneMode: String, CaseIterable { case income = "Income"; case bills = "Bills"; case summary = "Summary" }
    @State private var phoneMode: PhoneMode = .income
    private var effectivePhoneMode: PhoneMode { externalPhoneMode ?? phoneMode }

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

    @State private var didRunSSAMigration = false

    var body: some View {
        Group {
            if isPad {
                iPadBody
                    .onAppear {
                        migrateSSATokensIfNeeded()
                    }
            } else {
                iPhoneBody
                    .onAppear {
                        migrateSSATokensIfNeeded()
                    }
            }
        }
    }

    private func migrateSSATokensIfNeeded() {
        guard !didRunSSAMigration else { return }
        var changed = false
        for item in items {
            if item.ssaWednesday == nil, let n = extractSSAWednesday(from: item.notes) {
                item.ssaWednesday = n
                let cleaned = removeSSAToken(from: (item.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
                item.notes = cleaned.isEmpty ? nil : cleaned
                changed = true
            } else if let notes = item.notes, notes.contains("[SSA_WED]=") {
                let cleaned = removeSSAToken(from: notes.trimmingCharacters(in: .whitespacesAndNewlines))
                if cleaned != notes {
                    item.notes = cleaned.isEmpty ? nil : cleaned
                    changed = true
                }
            }
        }
        if changed { try? modelContext.save() }
        didRunSSAMigration = true
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
                                        let newItem = CashFlowItem(
                                            kind: .bill,
                                            name: "",
                                            amount: 0,
                                            frequency: .monthly,
                                            dayOfMonth: nil,
                                            firstPaymentDate: nil,
                                            notes: nil,
                                            ssaWednesday: nil
                                        )
                                        modelContext.insert(newItem)
                                        try? modelContext.save()
                                        activeSheet = .edit(item: newItem)
                                    } label: {
                                        Image(systemName: "plus")
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
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
                    .font(isPad ? .largeTitle : .headline)
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .add(let kind):
                AddCashFlowItemView(initialKind: kind, dismissAfterAdd: true) { newItem in
                    modelContext.insert(newItem)
                    try? modelContext.save()
                    if newItem.kind == .bill {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            activeSheet = .edit(item: newItem)
                        }
                    }
                }
                .navigationTitle(kind == .income ? "Add Income" : "Add Bill")
                .environmentObject(settings)
            case .edit(let item):
                if item.kind == .bill {
                    BillEditorSheet(item: item)
                        .environmentObject(settings)
                } else {
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
    }

    // MARK: - iPhone
    @ViewBuilder
    private var iPhoneBody: some View {
        Group {
            if embeddedInNavigation {
                iPhoneContent
            } else {
                NavigationStack {
                    iPhoneContent
                }
            }
        }
    }

    private var iPhoneContent: some View {
        List {
            if showsLocalModePicker && externalPhoneMode == nil {
                Section {
                    Picker("View", selection: $phoneMode) {
                        Text("Income").tag(PhoneMode.income)
                        Text("Bills").tag(PhoneMode.bills)
                        Text("Summary").tag(PhoneMode.summary)
                    }
                    .pickerStyle(.segmented)
                }
            }

            switch effectivePhoneMode {
            case .income:
                if incomes.isEmpty {
                    ContentUnavailableView("No income yet", systemImage: "list.bullet", description: Text("Add your income to compute your debt budget."))
                } else {
                    Section("Income") {
                        ForEach(incomes) { item in
                            row(for: item)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    activeSheet = .edit(item: item)
                                }
                        }
                        .onDelete { indexSet in
                            delete(items: indexSet.map { incomes[$0] })
                        }
                        if incomes.isEmpty {
                            Text("No income added yet").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            case .bills:
                if bills.isEmpty {
                    ContentUnavailableView("No bills yet", systemImage: "list.bullet", description: Text("Add your recurring bills to compute your debt budget."))
                } else {
                    Section("Bills") {
                        ForEach(bills) { item in
                            NavigationLink(destination: CashFlowItemEditorView(item: item).environmentObject(settings)) {
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
            case .summary:
                summarySection
            }
        }
        .navigationTitle("Income & Bills")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if effectivePhoneMode != .summary {
                    Button {
                        if effectivePhoneMode == .income {
                            addKind = .income
                            showAddSheet = true
                        } else if effectivePhoneMode == .bills {
                            let newItem = CashFlowItem(
                                kind: .bill,
                                name: "",
                                amount: 0,
                                frequency: .monthly,
                                dayOfMonth: nil,
                                firstPaymentDate: nil,
                                notes: nil,
                                ssaWednesday: nil
                            )
                            modelContext.insert(newItem)
                            try? modelContext.save()
                            activeSheet = .edit(item: newItem)
                        }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddCashFlowItemView(initialKind: addKind) { newItem in
                modelContext.insert(newItem)
                try? modelContext.save()
                if newItem.kind == .bill {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        activeSheet = .edit(item: newItem)
                    }
                }
            }
            .environmentObject(settings)
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .add(let kind):
                AddCashFlowItemView(initialKind: kind, dismissAfterAdd: true) { newItem in
                    modelContext.insert(newItem)
                    try? modelContext.save()
                    if newItem.kind == .bill {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            activeSheet = .edit(item: newItem)
                        }
                    }
                }
                .navigationTitle(kind == .income ? "Add Income" : "Add Bill")
                .environmentObject(settings)
            case .edit(let item):
                if item.kind == .bill {
                    BillEditorSheet(item: item)
                        .environmentObject(settings)
                } else {
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
        .onAppear {
            if let ext = externalPhoneMode, ext != phoneMode {
                phoneMode = ext
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
        if let ssa = ssaWednesday(for: item) {
            parts.append("Social Security")
            parts.append("\(ordinal(ssa)) Wednesday")
        } else if let date = item.firstPaymentDate {
            parts.append(label(for: item.frequency))
            parts.append(date.formatted(date: .abbreviated, time: .omitted))
        } else if let d = item.dayOfMonth {
            parts.append(label(for: item.frequency))
            parts.append("Day \(d)")
        } else {
            parts.append(label(for: item.frequency))
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

    private func ssaWednesday(for item: CashFlowItem) -> Int? {
        if let ssaWednesday = item.ssaWednesday, (2...4).contains(ssaWednesday) {
            return ssaWednesday
        }
        return extractSSAWednesday(from: item.notes)
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
    var dismissAfterAdd: Bool = true

    init(initialKind: CashFlowItem.Kind, dismissAfterAdd: Bool = true, onAdd: @escaping (CashFlowItem) -> Void) {
        self.initialKind = initialKind
        self.dismissAfterAdd = dismissAfterAdd
        self.onAdd = onAdd
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: SettingsStore
    @State private var name: String = ""
    @State private var amountValue: Decimal = 0
    @State private var frequency: PaymentFrequency = .monthly
    @State private var dayOfMonth: Int? = nil
    @State private var firstPaymentDate: Date? = nil
    @State private var notes: String = ""
    @State private var ssaWednesday: Int? = nil

    @State private var oneTimeSpreadMonthsOverride: Int? = nil

    @State private var showFrequencyPicker = false
    @State private var showSSAWednesdayPicker = false
    @State private var showDayOfMonthPicker = false
    @State private var showFirstPaymentDatePicker = false
    
    enum Field: Hashable { case name, amount, notes }
    @State private var amountIsFirstResponder: Bool = false
    @State private var nameIsFirstResponder: Bool = false
    @State private var notesIsFirstResponder: Bool = false
    private let fieldOrder: [Field] = [.name, .amount, .notes]

    @FocusState private var focusedField: Field?
    @State private var isProgrammaticFocusChange: Bool = false

    private var isEditing: Bool { nameIsFirstResponder || amountIsFirstResponder || notesIsFirstResponder || (focusedField != nil) }

    private var canGoPrevious: Bool {
        guard let current = currentField(), let idx = fieldOrder.firstIndex(of: current) else { return false }
        return idx > 0
    }

    private var canGoNext: Bool {
        guard let current = currentField(), let idx = fieldOrder.firstIndex(of: current) else { return false }
        return idx < fieldOrder.count - 1
    }

    private func moveFocus(_ delta: Int) {
        if delta < 0 { goPrev() } else if delta > 0 { goNext() }
    }

    private func focus(_ field: Field) {
        isProgrammaticFocusChange = true
        switch field {
        case .name:
            nameIsFirstResponder = true
        case .amount:
            amountIsFirstResponder = true
        case .notes:
            notesIsFirstResponder = true
        }
        focusedField = field
        DispatchQueue.main.async {
            self.nameIsFirstResponder = (field == .name)
            self.amountIsFirstResponder = (field == .amount)
            self.notesIsFirstResponder = (field == .notes)
            self.isProgrammaticFocusChange = false
        }
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

    // New private helper to dismiss keyboard only without saving or dismissing the sheet
    private func dismissKeyboardOnly() {
        nameIsFirstResponder = false
        amountIsFirstResponder = false
        notesIsFirstResponder = false
        focusedField = nil
        #if canImport(UIKit)
        let keyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        keyWindow?.endEditing(true)
        #endif
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Form {
                    Section("Details") {
                        Label("Enter a name and a valid amount to enable Add.", systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .opacity(isValid ? 0 : 1)
                            .accessibilityHidden(isValid)
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            HStack(spacing: 6) {
                                SelectAllTextField(
                                    text: $name,
                                    placeholder: "Name",
                                    isFirstResponder: $nameIsFirstResponder,
                                    returnKeyType: .next,
                                    onPrev: { moveFocus(-1) },
                                    onNext: { moveFocus(1) },
                                    onDone: { dismissKeyboardOnly() }
                                )
                                .accessibilityLabel("Name")

                                Button(action: { focus(.name) }) {
                                    Image(systemName: "pencil").imageScale(.small)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            HStack(spacing: 6) {
                                CurrencyAmountField(
                                    value: $amountValue,
                                    placeholder: "Amount",
                                    currencyCode: settings.currencyCode,
                                    isFirstResponder: $amountIsFirstResponder,
                                    onPrev: { moveFocus(-1) },
                                    onNext: { moveFocus(1) },
                                    onDone: { dismissKeyboardOnly() }
                                )
                                .accessibilityLabel("Amount")

                                Button(action: { focus(.amount) }) {
                                    Image(systemName: "pencil").imageScale(.small)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                            }
                            .frame(minWidth: 100, idealWidth: 120, maxWidth: 160, alignment: .trailing)
                            .accessibilityLabel("Amount")
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

                            if initialKind != .income {
                                Spacer(minLength: 8)

                                Menu {
                                    Button("Monthly") { frequency = .monthly }
                                    Button("Twice per month") { frequency = .semimonthly }
                                    Button("Every 2 weeks") { frequency = .biweekly }
                                    Button("Weekly") { frequency = .weekly }
                                    Button("Yearly") { frequency = .yearly }
                                    Button("Quarterly") { frequency = .quarterly }
                                    Button("Semiannual") { frequency = .semiAnnual }
                                    Button("One-time") { frequency = .oneTime }
                                } label: {
                                    Image(systemName: "pencil").imageScale(.small)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
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
                        }
                        if ssaWednesday == nil {
                            switch frequency.normalized {
                            case .monthly, .semimonthly, .biweekly, .weekly, .socialSecurity:
                                HStack {
                                    Picker("Day of Month", selection: Binding<Int?>(
                                        get: { dayOfMonth },
                                        set: { dayOfMonth = $0 }
                                    )) {
                                        Text("None").tag(nil as Int?)
                                        ForEach(1...31, id: \.self) { d in Text("\(d)").tag(Optional(d)) }
                                    }

                                    if initialKind != .income {
                                        Spacer(minLength: 8)

                                        Menu {
                                            Button("None") { dayOfMonth = nil }
                                            ForEach(1...31, id: \.self) { d in
                                                Button("\(d)") { dayOfMonth = d }
                                            }
                                        } label: {
                                            Image(systemName: "pencil").imageScale(.small)
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundStyle(.secondary)
                                    }
                                }
                            default:
                                HStack {
                                    DatePicker("First Payment Date", selection: Binding<Date>(
                                        get: { firstPaymentDate ?? Date() },
                                        set: { firstPaymentDate = $0 }
                                    ), displayedComponents: .date)

                                    if initialKind != .income {
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
                                if firstPaymentDate == nil {
                                    Text("Tip: Set the first payment date so spreads can start the month after the pay date. Using an estimated date for now.")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        if initialKind == .income && [.yearly, .semiAnnual, .quarterly, .oneTime].contains(frequency) {
                            Picker("Spread months", selection: Binding<Int?>(
                                get: { oneTimeSpreadMonthsOverride },
                                set: { oneTimeSpreadMonthsOverride = $0 }
                            )) {
                                Text("Use default").tag(nil as Int?)
                                Text("3 months").tag(Optional(3))
                                Text("6 months").tag(Optional(6))
                                Text("12 months").tag(Optional(12))
                            }
                            Text("Non‑monthly income is spread evenly starting the month after the pay date. Choose a duration.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 6) {
                            SelectAllTextField(
                                text: $notes,
                                placeholder: "Notes",
                                isFirstResponder: $notesIsFirstResponder,
                                returnKeyType: .done,
                                onPrev: { moveFocus(-1) },
                                onNext: { moveFocus(1) },
                                onDone: { dismissKeyboardOnly() }
                            )

                            Button(action: { focus(.notes) }) {
                                Image(systemName: "pencil").imageScale(.small)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                #if os(iOS)
                .scrollDismissesKeyboard(UIDevice.current.userInterfaceIdiom == .pad ? .never : .interactively)
                #endif
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
                            let cleanedNotes: String = removeSSAToken(from: notes.trimmingCharacters(in: .whitespacesAndNewlines))
                            let finalNotes: String? = cleanedNotes.isEmpty ? nil : cleanedNotes
                            let item = CashFlowItem(
                                kind: initialKind,
                                name: trimmedName,
                                amount: amountValue,
                                frequency: frequency,
                                dayOfMonth: dayOfMonth,
                                firstPaymentDate: firstPaymentDate,
                                notes: finalNotes,
                                ssaWednesday: ssaWednesday,
                                oneTimeSpreadMonthsOverride: oneTimeSpreadMonthsOverride
                            )
                            onAdd(item)
                            nameIsFirstResponder = false
                            amountIsFirstResponder = false
                            notesIsFirstResponder = false
                            focusedField = nil
                            #if canImport(UIKit)
                            let keyWindow = UIApplication.shared.connectedScenes
                                .compactMap { $0 as? UIWindowScene }
                                .flatMap { $0.windows }
                                .first { $0.isKeyWindow }
                            keyWindow?.endEditing(true)
                            #endif
                            if dismissAfterAdd { dismiss() }
                        }
                    } label: {
                        PlanMenuLabel(title: "Add", titleFont: .callout)
                    }
                    .buttonStyle(.plain)
                    .disabled(!isValid)
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
                            onDone: { dismissKeyboardOnly() }
                        )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else {
                        EmptyView().frame(height: 0)
                    }
                }
                .animation(.snappy, value: isEditing)
            }
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
                        set: { dayOfMonth = $0 }
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
                        set: { firstPaymentDate = $0 }
                    ), displayedComponents: .date)
                }
                .navigationTitle("First Payment Date")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showFirstPaymentDatePicker = false } } }
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
        .onChange(of: focusedField) { _, newValue in
            guard !isProgrammaticFocusChange else { return }
            nameIsFirstResponder = (newValue == .name)
            amountIsFirstResponder = (newValue == .amount)
            notesIsFirstResponder = (newValue == .notes)
            selectAllInFirstResponder()
        }
        .onChange(of: nameIsFirstResponder) { _, isFirst in
            guard !isProgrammaticFocusChange else { return }
            if isFirst { focusedField = .name } else if focusedField == .name && !amountIsFirstResponder && !notesIsFirstResponder { focusedField = nil }
        }
        .onChange(of: amountIsFirstResponder) { _, isFirst in
            guard !isProgrammaticFocusChange else { return }
            if isFirst { focusedField = .amount } else if focusedField == .amount && !nameIsFirstResponder && !notesIsFirstResponder { focusedField = nil }
        }
        .onChange(of: notesIsFirstResponder) { _, isFirst in
            guard !isProgrammaticFocusChange else { return }
            if isFirst { focusedField = .notes } else if focusedField == .notes && !nameIsFirstResponder && !amountIsFirstResponder { focusedField = nil }
        }
    }

    private var isValid: Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedName.isEmpty && amountValue > 0
    }

    private func commitAndDismissKeyboard() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty && amountValue > 0 {
            let cleanedNotes: String = removeSSAToken(from: notes.trimmingCharacters(in: .whitespacesAndNewlines))
            let finalNotes: String? = cleanedNotes.isEmpty ? nil : cleanedNotes
            let item = CashFlowItem(
                kind: initialKind,
                name: trimmedName,
                amount: amountValue,
                frequency: frequency,
                dayOfMonth: dayOfMonth,
                firstPaymentDate: firstPaymentDate,
                notes: finalNotes,
                ssaWednesday: ssaWednesday,
                oneTimeSpreadMonthsOverride: oneTimeSpreadMonthsOverride
            )
            onAdd(item)
            nameIsFirstResponder = false
            amountIsFirstResponder = false
            notesIsFirstResponder = false
            focusedField = nil
            #if canImport(UIKit)
            let keyWindow = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first { $0.isKeyWindow }
            keyWindow?.endEditing(true)
            #endif
            if dismissAfterAdd { dismiss() }
        } else {
            // If invalid, just dismiss the keyboard
            nameIsFirstResponder = false
            amountIsFirstResponder = false
            notesIsFirstResponder = false
            focusedField = nil
            #if canImport(UIKit)
            let keyWindow = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first { $0.isKeyWindow }
            keyWindow?.endEditing(true)
            #endif
        }
    }

    private func removeSSAToken(from s: String) -> String {
        if s.isEmpty { return s }
        var parts = s.split(separator: " ").map(String.init)
        parts.removeAll { $0.hasPrefix("[SSA_WED]=") }
        return parts.joined(separator: " ")
    }

    private func selectAllInFirstResponder(after delay: TimeInterval = 0.05) {
        #if canImport(UIKit)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            UIApplication.shared.sendAction(#selector(UIResponder.selectAll(_:)), to: nil, from: nil, for: nil)
        }
        #endif
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
    
    @State private var oneTimeSpreadMonthsOverride: Int? = nil

    enum Field: Hashable { case name, amount, notes }
    @State private var amountIsFirstResponder: Bool = false
    @State private var nameIsFirstResponder: Bool = false
    @State private var notesIsFirstResponder: Bool = false
    
    @State private var showFrequencyPicker = false
    @State private var showDayOfMonthPicker = false
    @State private var showFirstPaymentDatePicker = false
    
    private let fieldOrder: [Field] = [.name, .amount, .notes]

    @FocusState private var focusedField: Field?
    @State private var isProgrammaticFocusChange: Bool = false

    private var isEditing: Bool { nameIsFirstResponder || amountIsFirstResponder || notesIsFirstResponder || (focusedField != nil) }

    private var canGoPrevious: Bool {
        guard let current = currentField(), let idx = fieldOrder.firstIndex(of: current) else { return false }
        return idx > 0
    }

    private var canGoNext: Bool {
        guard let current = currentField(), let idx = fieldOrder.firstIndex(of: current) else { return false }
        return idx < fieldOrder.count - 1
    }

    private func moveFocus(_ delta: Int) {
        if delta < 0 { goPrev() } else if delta > 0 { goNext() }
    }

    private func focus(_ field: Field) {
        isProgrammaticFocusChange = true
        switch field {
        case .name:
            nameIsFirstResponder = true
        case .amount:
            amountIsFirstResponder = true
        case .notes:
            notesIsFirstResponder = true
        }
        focusedField = field
        DispatchQueue.main.async {
            self.nameIsFirstResponder = (field == .name)
            self.amountIsFirstResponder = (field == .amount)
            self.notesIsFirstResponder = (field == .notes)
            self.isProgrammaticFocusChange = false
        }
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
            ZStack {
                Form {
                    Section("Details") {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            HStack(spacing: 6) {
                                SelectAllTextField(
                                    text: $name,
                                    placeholder: "Name",
                                    isFirstResponder: $nameIsFirstResponder,
                                    returnKeyType: .next,
                                    onPrev: { moveFocus(-1) },
                                    onNext: { moveFocus(1) },
                                    onDone: { commitAndDismissKeyboard() }
                                )
                                .accessibilityLabel("Name")

                                Button(action: { focus(.name) }) {
                                    Image(systemName: "pencil").imageScale(.small)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            HStack(spacing: 6) {
                                CurrencyAmountField(
                                    value: $amountValue,
                                    placeholder: "Amount",
                                    currencyCode: settings.currencyCode,
                                    isFirstResponder: $amountIsFirstResponder,
                                    onPrev: { moveFocus(-1) },
                                    onNext: { moveFocus(1) },
                                    onDone: { commitAndDismissKeyboard() }
                                )
                                .accessibilityLabel("Amount")

                                Button(action: { focus(.amount) }) {
                                    Image(systemName: "pencil").imageScale(.small)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                            }
                            .frame(minWidth: 100, idealWidth: 120, maxWidth: 160, alignment: .trailing)
                            .accessibilityLabel("Amount")
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

                            if !isIncome {
                                Spacer(minLength: 8)
                                Menu {
                                    Button("Monthly") { frequency = .monthly }
                                    Button("Twice per month") { frequency = .semimonthly }
                                    Button("Every 2 weeks") { frequency = .biweekly }
                                    Button("Weekly") { frequency = .weekly }
                                    Button("Yearly") { frequency = .yearly }
                                    Button("Quarterly") { frequency = .quarterly }
                                    Button("Semiannual") { frequency = .semiAnnual }
                                    Button("One-time") { frequency = .oneTime }
                                } label: {
                                    Image(systemName: "pencil").imageScale(.small)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
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
                        }
                        if ssaWednesday == nil {
                            switch frequency.normalized {
                            case .monthly, .semimonthly, .biweekly, .weekly, .socialSecurity:
                                HStack {
                                    Picker("Day of Month", selection: Binding<Int?>(
                                        get: { dayOfMonth },
                                        set: { dayOfMonth = $0 }
                                    )) {
                                        Text("None").tag(nil as Int?)
                                        ForEach(1...31, id: \.self) { d in Text("\(d)").tag(Optional(d)) }
                                    }

                                    if !isIncome {
                                        Spacer(minLength: 8)
                                        Menu {
                                            Button("None") { dayOfMonth = nil }
                                            ForEach(1...31, id: \.self) { d in
                                                Button("\(d)") { dayOfMonth = d }
                                            }
                                        } label: {
                                            Image(systemName: "pencil").imageScale(.small)
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundStyle(.secondary)
                                    }
                                }
                            default:
                                HStack {
                                    DatePicker("First Payment Date", selection: Binding<Date>(
                                        get: { firstPaymentDate ?? Date() },
                                        set: { firstPaymentDate = $0 }
                                    ), displayedComponents: .date)

                                    if !isIncome {
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
                                if firstPaymentDate == nil {
                                    Text("Tip: Set the first payment date so spreads can start the month after the pay date. Using an estimated date for now.")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        if isIncome && [.yearly, .semiAnnual, .quarterly, .oneTime].contains(frequency) {
                            Picker("Spread months", selection: Binding<Int?>(
                                get: { oneTimeSpreadMonthsOverride },
                                set: { oneTimeSpreadMonthsOverride = $0 }
                            )) {
                                Text("Use default").tag(nil as Int?)
                                Text("3 months").tag(Optional(3))
                                Text("6 months").tag(Optional(6))
                                Text("12 months").tag(Optional(12))
                            }
                            Text("Non‑monthly income is spread evenly starting the month after the pay date. Choose a duration.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 6) {
                            SelectAllTextField(
                                text: $notes,
                                placeholder: "Notes",
                                isFirstResponder: $notesIsFirstResponder,
                                returnKeyType: .done,
                                onPrev: { moveFocus(-1) },
                                onNext: { moveFocus(1) },
                                onDone: { commitAndDismissKeyboard() }
                            )

                            Button(action: { focus(.notes) }) {
                                Image(systemName: "pencil").imageScale(.small)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                #if os(iOS)
                .scrollDismissesKeyboard(UIDevice.current.userInterfaceIdiom == .pad ? .never : .interactively)
                #endif
            }
            .navigationTitle(isIncome ? "Edit Income" : "Edit Bill")
            .toolbar {
                if UIDevice.type == "iPad" {
                    ToolbarItem(placement: .cancellationAction) {
                        PlanToolbarButton("Cancel",fixedWidth: 70) { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmedName.isEmpty {
                            let cleanedNotes: String = removeSSAToken(from: notes.trimmingCharacters(in: .whitespacesAndNewlines))
                            let finalNotes: String? = cleanedNotes.isEmpty ? nil : cleanedNotes
                            // Apply edits back to the model
                            item.name = trimmedName
                            item.amount = amountValue
                            item.frequency = frequency
                            item.dayOfMonth = dayOfMonth
                            item.firstPaymentDate = firstPaymentDate
                            item.notes = finalNotes
                            item.ssaWednesday = ssaWednesday
                            item.oneTimeSpreadMonthsOverride = oneTimeSpreadMonthsOverride
                            onSave()
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
                        set: { dayOfMonth = $0 }
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
                        set: { firstPaymentDate = $0 }
                    ), displayedComponents: .date)
                }
                .navigationTitle("First Payment Date")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showFirstPaymentDatePicker = false } } }
            }
        }
        .onAppear {
            // Seed state from the existing item
            name = item.name
            amountValue = item.amount
            frequency = item.frequency
            dayOfMonth = item.dayOfMonth
            firstPaymentDate = item.firstPaymentDate
            notes = item.notes ?? ""
            ssaWednesday = item.ssaWednesday ?? extractSSAWednesday(from: item.notes)
            oneTimeSpreadMonthsOverride = item.oneTimeSpreadMonthsOverride
            if isIncome {
                switch frequency.normalized {
                case .monthly, .semimonthly, .biweekly, .weekly, .socialSecurity:
                    if dayOfMonth == nil { dayOfMonth = 1 }
                default: break
                }
            }
        }
        .onChange(of: focusedField) { _, newValue in
            guard !isProgrammaticFocusChange else { return }
            nameIsFirstResponder = (newValue == .name)
            amountIsFirstResponder = (newValue == .amount)
            notesIsFirstResponder = (newValue == .notes)
            selectAllInFirstResponder()
        }
        .onChange(of: nameIsFirstResponder) { _, isFirst in
            guard !isProgrammaticFocusChange else { return }
            if isFirst { focusedField = .name } else if focusedField == .name && !amountIsFirstResponder && !notesIsFirstResponder { focusedField = nil }
        }
        .onChange(of: amountIsFirstResponder) { _, isFirst in
            guard !isProgrammaticFocusChange else { return }
            if isFirst { focusedField = .amount } else if focusedField == .amount && !nameIsFirstResponder && !notesIsFirstResponder { focusedField = nil }
        }
        .onChange(of: notesIsFirstResponder) { _, isFirst in
            guard !isProgrammaticFocusChange else { return }
            if isFirst { focusedField = .notes } else if focusedField == .notes && !nameIsFirstResponder && !amountIsFirstResponder { focusedField = nil }
        }
    }
    private func dismissKeyboardOnly() {
        nameIsFirstResponder = false
        amountIsFirstResponder = false
        notesIsFirstResponder = false
        focusedField = nil
        #if canImport(UIKit)
        let keyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        keyWindow?.endEditing(true)
        #endif
    }
    
    private func commitAndDismissKeyboard() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            let cleanedNotes: String = removeSSAToken(from: notes.trimmingCharacters(in: .whitespacesAndNewlines))
            let finalNotes: String? = cleanedNotes.isEmpty ? nil : cleanedNotes
            item.name = trimmedName
            item.amount = amountValue
            item.frequency = frequency
            item.dayOfMonth = dayOfMonth
            item.firstPaymentDate = firstPaymentDate
            item.notes = finalNotes
            item.ssaWednesday = ssaWednesday
            item.oneTimeSpreadMonthsOverride = oneTimeSpreadMonthsOverride
            onSave()
            nameIsFirstResponder = false
            amountIsFirstResponder = false
            notesIsFirstResponder = false
            focusedField = nil
            #if canImport(UIKit)
            let keyWindow = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first { $0.isKeyWindow }
            keyWindow?.endEditing(true)
            #endif
            dismiss()
        } else {
            // If invalid, just dismiss the keyboard
            nameIsFirstResponder = false
            amountIsFirstResponder = false
            notesIsFirstResponder = false
            focusedField = nil
            #if canImport(UIKit)
            let keyWindow = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first { $0.isKeyWindow }
            keyWindow?.endEditing(true)
            #endif
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

    private func selectAllInFirstResponder(after delay: TimeInterval = 0.05) {
        #if canImport(UIKit)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            UIApplication.shared.sendAction(#selector(UIResponder.selectAll(_:)), to: nil, from: nil, for: nil)
        }
        #endif
    }
}

private struct BillEditorSheet: View {
    let item: CashFlowItem
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        NavigationStack {
            CashFlowItemEditorView(item: item)
                .environmentObject(settings)
                .navigationTitle("Edit Bill")
                .navigationBarTitleDisplayMode(.inline)
        }
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

        // Removed: keyboard accessory toolbar with Prev/Next/Done

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

        // Removed: keyboard accessory toolbar with Prev/Next/Done

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
