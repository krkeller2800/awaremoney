// DebtPayoffView.swift
// SwiftUI UI that integrates with Account + SwiftData using DebtPayoffViewModel

import SwiftUI
import SwiftData
import UIKit

struct DebtPayoffView: View {
    @StateObject var viewModel: DebtPayoffViewModel
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.locale) private var locale

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

    var body: some View {
        List {
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

            Section("Assumptions") {
                if viewModel.account.type == .creditCard {
                    Picker("Payment mode", selection: Binding(
                        get: { viewModel.account.creditCardPaymentMode ?? .minimum },
                        set: { viewModel.setCreditCardMode($0) }
                    )) {
                        ForEach(CreditCardPaymentMode.allCases, id: \.self) { mode in
                            Text(label(for: mode)).tag(mode)
                        }
                    }
                }

                HStack {
                    Text("APR")
                    TextField("0.00%", text: Binding(
                        get: { aprInputForUI() },
                        set: { new in aprInput = new; applyAPRIfParsable() }
                    ))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .focused($focusedField, equals: .apr)
                }

                HStack {
                    Text("Typical payment")
                    TextField(formatCurrency(0), text: Binding(
                        get: { typicalPaymentInputForUI() },
                        set: { new in typicalPaymentInput = new; applyPaymentIfParsable() }
                    ))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .focused($focusedField, equals: .typical)
                }

                ProgressView(value: viewModel.confidence) {
                    Text("Projection confidence")
                } currentValueLabel: {
                    Text(String(format: "%.0f%%", viewModel.confidence * 100))
                }
                .padding(.vertical, 4)

                if let msg = viewModel.varianceMessage {
                    Text(msg).font(.footnote).foregroundStyle(.secondary)
                }
            }

            Section("Summary") {
                if let payoff = viewModel.payoffDate {
                    LabeledContent("Estimated payoff") { Text(payoff, style: .date) }
                } else {
                    Text("No payoff within horizon under current assumptions.")
                        .foregroundStyle(.secondary)
                }
                if let last = viewModel.projection.last {
                    LabeledContent("Projected balance") {
                        Text(formatCurrency(last.balance))
                    }
                }
            }

            if !viewModel.projection.isEmpty {
                Section("Schedule (Monthly)") {
                    ForEach(viewModel.projection) { p in
                        HStack {
                            Text(p.date, style: .date)
                            Spacer()
                            Text(formatCurrency(p.balance))
                        }
                    }
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

