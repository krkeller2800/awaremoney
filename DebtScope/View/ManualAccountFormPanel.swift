//
//  ManualAccountFormPanel.swift
//  DebtScope
//
//  Created by Karl Keller on 5/10/26.
//
import SwiftUI
import SwiftData
#if canImport(UIKit)
import UIKit
#endif
import Foundation

struct ManualAccountFormPanel: View {
    @Binding var selectedType: StatementType?
    @Binding var editedInstitution: String
    @Binding var bankSubtype: QuickIngestAccountType?
    @Binding var monthlyPaymentInput: String
    @Binding var aprPercentInput: String
    @Binding var balanceInput: String
    @Binding var balanceDate: Date

    let onSave: () -> Void
    let hasSavedAccount: Bool
    
    @EnvironmentObject private var settings: SettingsStore
    @FocusState private var focusedManualField: ManualField?
    private enum ManualField: Hashable {
        case institution
        case monthlyPayment
        case apr
        case balance
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            accountFormColumn
            bottomButtons
        }
        .padding(24)
        .toolbar {
            manualKeyboardToolbar
        }
        .onAppear {
            formatAllManualInputs()
        }
        .onChange(of: focusedManualField) { oldValue, newValue in
            formatManualField(oldValue)

            guard let newValue else { return }
            selectAllSoon(titleForManualField(newValue))
        }
    }
  
    private var bottomButtons: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if hasSavedAccount {
                Text("This account has been added.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else if let saveDisabledHint {
                Text(saveDisabledHint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            HStack {
                Spacer()

                Button {
                    onSave()
                } label: {
                    Label(
                        hasSavedAccount ? "Account Added" : "Add Account",
                        systemImage: hasSavedAccount ? "checkmark.circle.fill" : "checkmark"
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(hasSavedAccount || !canSaveManualAccount)
            }
        }
        .padding(.top, 8)
    }
 
    private var canSaveManualAccount: Bool {
        selectedType != nil &&
        !editedInstitution.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var saveDisabledHint: String? {
        if selectedType == nil {
            return "Choose an account type to add this account."
        }

        if editedInstitution.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter an institution or account name."
        }

        return nil
    }
    
    private func formatAllManualInputs() {
        formatMoneyInput(&monthlyPaymentInput)
        formatAPRInput()
        formatMoneyInput(&balanceInput)
    }

    private func formatManualField(_ field: ManualField?) {
        switch field {
        case .monthlyPayment:
            formatMoneyInput(&monthlyPaymentInput)
        case .apr:
            formatAPRInput()
        case .balance:
            formatMoneyInput(&balanceInput)
        default:
            break
        }
    }

    private func titleForManualField(_ field: ManualField) -> String {
        switch field {
        case .institution:
            return "Institution"
        case .monthlyPayment:
            return "Monthly payment"
        case .apr:
            return "APR"
        case .balance:
            return "Ending balance"
        }
    }
    
    private var accountFormColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Enter the details for your account.")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            manualPickerRow("Type") {
                Picker("Type", selection: $selectedType) {
                    Text("Choose…").tag(nil as StatementType?)
                    ForEach(StatementType.allCases, id: \.self) { t in
                        Text(displayName(for: t)).tag(StatementType?.some(t))
                    }
                }
                .pickerStyle(.menu)
            }
            
            manualTextFieldRow(
                "Institution",
                placeholder: "Institution",
                text: $editedInstitution,
                field: .institution,
                minWidth: 200
            )
            
            if selectedType == .bank {
                manualPickerRow("Bank Subtype") {
                    Picker("Bank Subtype", selection: $bankSubtype) {
                        Text("Auto").tag(nil as QuickIngestAccountType?)
                        Text("Checking").tag(QuickIngestAccountType.checking as QuickIngestAccountType?)
                        Text("Savings").tag(QuickIngestAccountType.savings as QuickIngestAccountType?)
                    }
                    .pickerStyle(.menu)
                }
            }
            
            Divider().padding(.top, 4)
            
            Text("Optional")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            
            manualTextFieldRow(
                "Monthly payment",
                placeholder: "Amount",
                text: $monthlyPaymentInput,
                field: .monthlyPayment,
                minWidth: 140,
                keyboardType: .numbersAndPunctuation,
                onExit: {
                    formatMoneyInput(&monthlyPaymentInput)
                }
            )
            
            manualTextFieldRow(
                "APR (%)",
                placeholder: "e.g., 19.99",
                text: $aprPercentInput,
                field: .apr,
                minWidth: 140,
                keyboardType: .numbersAndPunctuation,
                onExit: {
                    formatAPRInput()
                }
            )
            
            manualTextFieldRow(
                "Ending balance",
                placeholder: "Amount",
                text: $balanceInput,
                field: .balance,
                minWidth: 140,
                keyboardType: .numbersAndPunctuation,
                onExit: {
                    formatMoneyInput(&balanceInput)
                }
            )
            
            manualPickerRow("As of") {
                DatePicker("", selection: $balanceDate, displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.compact)
            }
        }
    }
    private func manualPickerRow<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            content()
                .font(.caption.monospacedDigit())
                .frame(maxWidth: 200, alignment: .trailing)
        }
    }

    private func manualTextFieldRow(
        _ title: String,
        placeholder: String,
        text: Binding<String>,
        field: ManualField,
        minWidth: CGFloat,
        keyboardType: UIKeyboardType = .default,
        onExit: (() -> Void)? = nil
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                TextField(placeholder, text: text)
                    .multilineTextAlignment(.trailing)
                    .font(.caption.monospacedDigit())

                Image(systemName: "pencil")
                    .font(.caption2)
                    .foregroundStyle(
                        focusedManualField == field
                        ? Color.accentColor
                        : .secondary
                    )
            }
            .frame(minWidth: minWidth, maxWidth: 200, alignment: .trailing)
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.thinMaterial)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        focusedManualField == field
                        ? Color.accentColor
                        : Color.secondary.opacity(0.25),
                        lineWidth: 1
                    )
            }
    #if os(iOS) || os(visionOS)
                .keyboardType(keyboardType)
    #endif
                .focused($focusedManualField, equals: field)
                .simultaneousGesture(
                    TapGesture().onEnded {
                        focusedManualField = field
                    }
                )
        }
    }
    @ToolbarContentBuilder
    private var manualKeyboardToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .keyboard) {
            Button {
                moveManualFocus(-1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(!canMoveManualFocus(-1))

            Button {
                moveManualFocus(1)
            } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(!canMoveManualFocus(1))

            Spacer()

            Button {
                formatActiveManualField()
                focusedManualField = nil
            } label: {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
            }
        }
    }
    private func selectAllSoon(_ label: String) {
#if canImport(UIKit)
        func sendSelectAll(after delay: TimeInterval) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                let sent = UIApplication.shared.sendAction(
                    #selector(UIResponder.selectAll(_:)),
                    to: nil,
                    from: nil,
                    for: nil
                )
                print("\(label) selectAll sent after \(delay):", sent)
            }
        }

        sendSelectAll(after: 0.15)
        sendSelectAll(after: 0.35)
#endif
    }
    private func formattedCurrency(_ value: Decimal?) -> String {
        guard let value else { return "—" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = settings.currencyCode
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? "—"
    }

    private func formattedAPR(_ value: Decimal?, scale: Int?) -> String {
        guard let value else { return "—" }
        let percent = NSDecimalNumber(decimal: value * 100)
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = max(scale ?? 2, 2)
        formatter.minimumFractionDigits = min(scale ?? 2, 2)
        return (formatter.string(from: percent) ?? "—") + "%"
    }

    private func formattedMonths(_ months: Int) -> String {
        if months < 12 {
            return "\(months) mo"
        }

        let years = months / 12
        let rem = months % 12
        if rem == 0 {
            return "\(years) yr"
        }
        return "\(years) yr \(rem) mo"
    }

    private var manualFieldOrder: [ManualField] {
        [.institution, .monthlyPayment, .apr, .balance]
    }

    private func canMoveManualFocus(_ direction: Int) -> Bool {
        guard
            let current = focusedManualField,
            let index = manualFieldOrder.firstIndex(of: current)
        else {
            return false
        }

        let nextIndex = index + direction
        return manualFieldOrder.indices.contains(nextIndex)
    }

    private func moveManualFocus(_ direction: Int) {
        guard
            let current = focusedManualField,
            let index = manualFieldOrder.firstIndex(of: current)
        else {
            focusedManualField = manualFieldOrder.first
            return
        }

        let nextIndex = index + direction
        guard manualFieldOrder.indices.contains(nextIndex) else { return }

        formatActiveManualField()
        focusedManualField = manualFieldOrder[nextIndex]
    }

    private func formatActiveManualField() {
        switch focusedManualField {
        case .monthlyPayment:
            formatMoneyInput(&monthlyPaymentInput)

        case .apr:
            formatAPRInput()

        case .balance:
            formatMoneyInput(&balanceInput)

        default:
            break
        }
    }
    private func formatMoneyInput(_ input: inout String) {
        guard let value = parseDecimal(input) else { return }
        input = formattedCurrency(value)
    }

    private func formatAPRInput() {
        guard let parsed = parseAPRPercent(aprPercentInput) else { return }
        aprPercentInput = formattedAPR(parsed.0, scale: parsed.1)
    }
    private func displayName(for t: StatementType) -> String {
        switch t {
        case .creditCard: return "Credit Card"
        case .bank: return "Bank"
        case .loan: return "Loan"
        case .brokerage: return "Brokerage"
        }
    }

    private func toAccountType(_ t: StatementType?, bankSubtype: QuickIngestAccountType?) -> Account.AccountType {
        guard let t else { return .other }
        switch t {
        case .creditCard: return .creditCard
        case .loan:       return .loan
        case .brokerage:  return .brokerage
        case .bank:
            switch bankSubtype {
            case .some(.savings): return .savings
            default: return .checking
            }
        }
    }

    private func parseDecimal(_ s: String) -> Decimal? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let allowed = CharacterSet(charactersIn: "-0123456789.,")
        let filtered = String(trimmed.unicodeScalars.filter { allowed.contains($0) })
        var normalized = filtered
        if filtered.contains(",") && filtered.contains(".") {
            normalized = filtered.replacingOccurrences(of: ",", with: "")
        } else if filtered.contains(",") && !filtered.contains(".") {
            normalized = filtered.replacingOccurrences(of: ",", with: ".")
        }
        return Decimal(string: normalized)
    }

    private func parseAPRPercent(_ s: String) -> (Decimal, Int)? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let cleaned = trimmed.replacingOccurrences(of: "%", with: "").replacingOccurrences(of: ",", with: ".")
        guard let dec = Decimal(string: cleaned) else { return nil }
        let scale: Int = cleaned.split(separator: ".").last.map { $0.count } ?? 0
        var fraction = dec
        if fraction > 1 { fraction /= 100 }
        return (fraction, scale)
    }
}
