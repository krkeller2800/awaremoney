import SwiftUI
import SwiftData
import Foundation
import UIKit

struct ManualAssetSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var settings: SettingsStore

    @State private var name: String = ""
    @State private var valueText: String = ""
    @State private var asOfDate: Date = Date()
    @State private var institution: String = ""
    @State private var wasValueFocused: Bool = false

    // Focus management for keyboard navigation
    @FocusState private var focusedField: FocusedField?
    private enum FocusedField: Hashable { case name, institution, value }

    private var canGoPrevious: Bool {
        switch focusedField {
        case .institution, .value:
            return true
        default:
            return false
        }
    }

    private var canGoNext: Bool {
        switch focusedField {
        case .name, .institution:
            return true
        default:
            return false
        }
    }

    private func previousField() {
        switch focusedField {
        case .institution:
            focusedField = .name
        case .value:
            focusedField = .institution
        default:
            break
        }
    }

    private func nextField() {
        switch focusedField {
        case .name:
            focusedField = .institution
        case .institution:
            focusedField = .value
        default:
            break
        }
    }

    // Liability linking support
    @Query(filter: #Predicate<Account> { $0.typeRaw == "loan" }) private var liabilityAccounts: [Account]
    @State private var selectedLiability: Account? = nil

    var isValid: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard let decimalValue = parseDecimal(from: valueText), decimalValue > 0 else { return false }
        return true
    }

    private var enteredAssetValue: Decimal? { parseDecimal(from: valueText) }

    private func latestBalance(for account: Account) -> Decimal {
        // Use the most recent BalanceSnapshot by asOfDate; if none, return 0
        let snaps = account.balanceSnapshots
        let latest = snaps.max(by: { $0.asOfDate < $1.asOfDate })
        return latest?.balance ?? 0
    }

    private var selectedLiabilityBalance: Decimal {
        guard let acct = selectedLiability else { return 0 }
        return latestBalance(for: acct)
    }

    private var selectedLiabilityDebtMagnitude: Decimal {
        let bal = selectedLiabilityBalance
        return bal < 0 ? -bal : bal
    }

    private var computedEquity: Decimal? {
        guard let assetValue = enteredAssetValue else { return nil }
        return assetValue - selectedLiabilityDebtMagnitude
    }

    private var computedLTV: Decimal? {
        guard let assetValue = enteredAssetValue, assetValue > 0 else { return nil }
        return selectedLiabilityDebtMagnitude / assetValue
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    TextField("Name", text: $name)
                        .focused($focusedField, equals: .name)
                        .selectAllOnFocus()
                    TextField("Description (optional)", text: $institution)
                        .focused($focusedField, equals: .institution)
                        .selectAllOnFocus()
                    Label("Use this to add assets like a home, car, or other property you track manually.", systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .labelStyle(.titleAndIcon)
                }

                Section("Valuation") {
                    LabeledContent("As of") {
                        HStack(spacing: 12) {
                            DatePicker("", selection: $asOfDate, displayedComponents: .date)
                                .labelsHidden()
                                .datePickerStyle(.compact)
                                .fixedSize()
                            TextField("Value", text: $valueText)
                                .focused($focusedField, equals: .value)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(minWidth: 110, idealWidth: 130, maxWidth: 160, alignment: .trailing)
                                .fixedSize(horizontal: true, vertical: false)
                                .selectAllOnFocus()
                        }
                    }

                    Picker("Financing Used (optional)", selection: $selectedLiability) {
                        Text("None").tag(Optional<Account>.none)
                        ForEach(liabilityAccounts, id: \.self) { acct in
                            Text(acct.name).tag(Optional(acct))
                        }
                    }

                    if let equity = computedEquity {
                        LabeledContent("Equity") {
                            Text(equity as NSNumber, formatter: currencyFormatter)
                        }
                    }

                    if let ltv = computedLTV {
                        LabeledContent("LTV") {
                            Text(percentFormatter.string(from: (ltv as NSNumber)) ?? "–")
                        }
                    }
                }

                Section(footer:
                    Text("This will create a Property asset and a single balance snapshot.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                ) { EmptyView() }
            }
            .navigationTitle("Add Property Asset")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    PlanToolbarButton("Cancel",fixedWidth: 70) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                    }
                    .disabled(!isValid)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Button(action: { previousField() }) {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(!canGoPrevious)

                    Button(action: { nextField() }) {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(!canGoNext)

                    Spacer()

                    Button(action: {
                        if isValid {
                            focusedField = nil
                            save()
                        } else {
                            focusedField = nil
                        }
                    }) {
                        Image(systemName: "checkmark.circle.fill")
                    }
                    .disabled(!isValid)
                }
            }
            .onChange(of: focusedField) { newValue in
                if wasValueFocused && newValue != .value {
                    formatValueTextForDisplay()
                }
                wasValueFocused = (newValue == .value)
            }
            .onChange(of: settings.currencyCode) { _ in
                formatValueTextForDisplay()
            }
        }
    }

    // MARK: - Formatters
    private var currencyFormatter: NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = settings.currencyCode
        return f
    }

    private var percentFormatter: NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle = .percent
        f.maximumFractionDigits = 2
        return f
    }

    private func parseDecimal(from string: String) -> Decimal? {
        // First try parsing with a currency-aware formatter using the user's currency code
        let currency = NumberFormatter()
        currency.numberStyle = .currency
        currency.currencyCode = settings.currencyCode
        currency.isLenient = true
        currency.generatesDecimalNumbers = true
        if let number = currency.number(from: string) as? NSDecimalNumber {
            return number.decimalValue
        }

        // Fallback: parse as a plain decimal using the current locale
        let decimal = NumberFormatter()
        decimal.numberStyle = .decimal
        decimal.generatesDecimalNumbers = true
        if let number = decimal.number(from: string) as? NSDecimalNumber {
            return number.decimalValue
        }

        // Last resort: strip common currency symbols and grouping separators
        let separators = CharacterSet(charactersIn: ", .\u{00A0}") // comma, dot, non-breaking space
        let filtered = string
            .components(separatedBy: CharacterSet(charactersIn: "0123456789-" ).inverted)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Decimal(string: filtered)
    }

    private func formatValueTextForDisplay() {
        guard !valueText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let value = parseDecimal(from: valueText) else { return }
        let number = NSDecimalNumber(decimal: value)
        if let formatted = currencyFormatter.string(from: number) {
            valueText = formatted
        }
    }

    private func save() {
        guard let value = parseDecimal(from: valueText) else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedInstitution = institution.trimmingCharacters(in: .whitespacesAndNewlines)
        let acct = Account(
            name: trimmedName,
            type: .property,
            institutionName: trimmedInstitution.isEmpty ? nil : trimmedInstitution,
            currencyCode: settings.currencyCode
        )
        modelContext.insert(acct)

        let snap = BalanceSnapshot(
            asOfDate: asOfDate,
            balance: value,
            account: acct,
            importBatch: nil,
            isUserCreated: true
        )
        modelContext.insert(snap)

        if let liability = selectedLiability {
            let link = AssetLiabilityLink(asset: acct, liability: liability, startDate: asOfDate)
            modelContext.insert(link)
        }

        try? modelContext.save()

        NotificationCenter.default.post(name: .transactionsDidChange, object: nil)
        NotificationCenter.default.post(name: .accountsDidChange, object: nil)

        dismiss()
    }
}

#Preview {
    Text("ManualAssetSheet requires a model container and environment object for preview.")
}

extension View {
    func selectAllOnFocus() -> some View {
        background(TextFieldSelectAllIntrospector())
    }
}

private struct TextFieldSelectAllIntrospector: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIView { UIView(frame: .zero) }
    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async {
            if let textField = self.findTextField(from: uiView) {
                context.coordinator.attachIfNeeded(to: textField)
            }
        }
    }

    private func findTextField(from view: UIView) -> UITextField? {
        var current: UIView? = view
        // Walk up a few levels and search down for a UITextField
        for _ in 0..<6 {
            if let container = current {
                if let tf = search(in: container) { return tf }
                current = container.superview
            } else { break }
        }
        return nil
    }

    private func search(in view: UIView) -> UITextField? {
        for sub in view.subviews {
            if let tf = sub as? UITextField { return tf }
            if let found = search(in: sub) { return found }
        }
        return nil
    }

    class Coordinator: NSObject {
        weak var attachedTo: UITextField?

        @objc func handleEditingDidBegin(_ sender: UITextField) {
            sender.selectAll(nil)
        }

        func attachIfNeeded(to textField: UITextField) {
            guard attachedTo !== textField else { return }
            attachedTo = textField
            textField.addTarget(self, action: #selector(handleEditingDidBegin(_:)), for: .editingDidBegin)
        }
    }
}

