// DebtPayoffView.swift
// SwiftUI UI that integrates with Account + SwiftData using DebtPayoffViewModel

import SwiftUI
import SwiftData

struct DebtPayoffView: View {
    @StateObject var viewModel: DebtPayoffViewModel

    @State private var aprInput: String = ""
    @State private var typicalPaymentInput: String = ""

    enum Field: Hashable { case apr, typical }
    @FocusState private var focusedField: Field?

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
                            Text(viewModel.currency(abs(last.balance)))
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
                    TextField("0.00", text: Binding(
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
                        Text(viewModel.currency(last.balance))
                    }
                }
            }

            if !viewModel.projection.isEmpty {
                Section("Schedule (Monthly)") {
                    ForEach(viewModel.projection) { p in
                        HStack {
                            Text(p.date, style: .date)
                            Spacer()
                            Text(viewModel.currency(p.balance))
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
        .navigationTitle("Debt Payoff")
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Button(action: { moveFocus(direction: -1) }) {
                    Image(systemName: "chevron.left")
                }
                .labelStyle(.iconOnly)

                Button(action: { moveFocus(direction: +1) }) {
                    Image(systemName: "chevron.right")
                }
                .labelStyle(.iconOnly)

                Spacer()

                Button(action: {
                    applyAPRIfParsable()
                    applyPaymentIfParsable()
                    viewModel.computeVarianceAgainstLatestStatement()
                    focusedField = nil
                }) {
                    Image(systemName: "checkmark.circle.fill")
                }
                .labelStyle(.iconOnly)
            }
        }
        .onAppear {
            // Seed UI fields from model
            aprInput = aprInputForUI()
            typicalPaymentInput = typicalPaymentInputForUI()
            viewModel.computeVarianceAgainstLatestStatement()
        }
    }

    private func moveFocus(direction: Int) {
        let order: [Field] = [.apr, .typical]
        guard let current = focusedField, let idx = order.firstIndex(of: current) else {
            focusedField = .apr
            return
        }
        let nextIndex = max(0, min(order.count - 1, idx + direction))
        focusedField = order[nextIndex]
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
            nf.numberStyle = .decimal
            nf.maximumFractionDigits = 2
            nf.minimumFractionDigits = 0
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
        let cleaned = typicalPaymentInput.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespaces)
        if let val = Decimal(string: cleaned) {
            viewModel.setTypicalPaymentAmount(val)
        }
    }
}

#Preview {
    Text("Preview requires model data")
}

