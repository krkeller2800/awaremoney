// DebtProjectionView.swift
// SwiftUI UI for choosing assumptions and viewing the projection summary (adapted to DebtPayoffViewModel)

import SwiftUI
import Combine

struct DebtProjectionView: View {
    @StateObject var viewModel: DebtPayoffViewModel

    // Local input state
    @State private var aprInput: String = ""
    @State private var paymentInput: String = ""
    @State private var ccMode: CreditCardPaymentMode = .minimum

    var body: some View {
        List {
            Section("Account") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(viewModel.account.name).font(.headline)
                    Text(viewModel.account.type.rawValue.capitalized)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("APR") { Text(formatAPR(viewModel.account.loanTerms?.apr, scale: viewModel.account.loanTerms?.aprScale)) }
                if let day = viewModel.account.loanTerms?.paymentDayOfMonth {
                    LabeledContent("Due day") { Text("\(day)") }
                }
            }

            Section("Assumptions") {
                if viewModel.account.type == .creditCard {
                    Picker("Payment behavior", selection: $ccMode) {
                        ForEach(CreditCardPaymentMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue.capitalized).tag(mode)
                        }
                    }
                }

                LabeledContent("Typical payment") {
                    TextField("0.00", text: $paymentInput)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }

                LabeledContent("APR (%)") {
                    TextField("0.00", text: $aprInput)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }

                if let next = viewModel.payoffDate {
                    LabeledContent("Estimated payoff") { Text(next, style: .date) }
                } else {
                    Text("No payoff within horizon under current assumptions.")
                        .foregroundStyle(.secondary)
                }

                ProgressView(value: viewModel.confidence) {
                    Text("Projection confidence")
                } currentValueLabel: {
                    Text(String(format: "%.0f%%", viewModel.confidence * 100))
                }
            }

            Section("Summary") {
                LabeledContent("Current projected balance") {
                    let bal = viewModel.projection.last?.balance ?? 0
                    Text(viewModel.currency(bal))
                }
                if let message = viewModel.varianceMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button("Recompute variance vs latest statement") {
                    viewModel.computeVarianceAgainstLatestStatement()
                }
            }

            Section("Disclaimers") {
                Text("Estimates only. Actual payoff depends on lender calculations, fees, and APR changes. Update with statements to improve accuracy.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Debt Projection")
        .onAppear { seedFromModel() }
        .onChange(of: ccMode) { _, newVal in viewModel.setCreditCardMode(newVal) }
        .onChange(of: aprInput) { _, _ in handleAPRChange() }
        .onChange(of: paymentInput) { _, _ in handlePaymentChange() }
    }

    // MARK: - Seed & Input Handlers

    private func seedFromModel() {
        // Initialize UI controls from the model
        ccMode = viewModel.account.creditCardPaymentMode ?? .minimum
        if let pay = viewModel.account.loanTerms?.paymentAmount { paymentInput = formatAmountForInput(pay) } else { paymentInput = "" }
        if let apr = viewModel.account.loanTerms?.apr { aprInput = formatPercentForInput(apr, scale: viewModel.account.loanTerms?.aprScale) } else { aprInput = "" }
    }

    private func handleAPRChange() {
        if let (fraction, _) = parsePercentInput(aprInput) {
            viewModel.setAPR(fraction)
        } else {
            viewModel.setAPR(nil)
        }
    }

    private func handlePaymentChange() {
        if let dec = parseCurrencyInput(paymentInput) {
            viewModel.setTypicalPaymentAmount(dec)
        } else {
            viewModel.setTypicalPaymentAmount(nil)
        }
    }

    // MARK: - Formatting & Parsing Helpers

    private func formatAPR(_ apr: Decimal?, scale: Int? = nil) -> String {
        guard let apr else { return "—" }
        let nf = NumberFormatter()
        nf.numberStyle = .percent
        if let s = scale { nf.minimumFractionDigits = s; nf.maximumFractionDigits = s }
        else { nf.minimumFractionDigits = 2; nf.maximumFractionDigits = 3 }
        return nf.string(from: NSDecimalNumber(decimal: apr)) ?? "\(apr)"
    }

    private func parseCurrencyInput(_ s: String) -> Decimal? {
        let cleaned = s.replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "$", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Decimal(string: cleaned)
    }

    private func parsePercentInput(_ s: String) -> (Decimal, Int)? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let cleaned = trimmed.replacingOccurrences(of: "%", with: "").replacingOccurrences(of: ",", with: ".")
        guard let dec = Decimal(string: cleaned) else { return nil }
        let scale: Int = {
            if let dot = cleaned.firstIndex(of: ".") { return cleaned.distance(from: cleaned.index(after: dot), to: cleaned.endIndex) }
            return 0
        }()
        var fraction = dec
        if fraction > 1 { fraction /= 100 }
        return (fraction, scale)
    }

    private func formatAmountForInput(_ amount: Decimal) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        nf.minimumFractionDigits = 0
        nf.maximumFractionDigits = 2
        return nf.string(from: NSDecimalNumber(decimal: amount)) ?? "\(amount)"
    }

    private func formatPercentForInput(_ apr: Decimal, scale: Int?) -> String {
        let percent = apr * 100
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        if let s = scale { nf.minimumFractionDigits = s; nf.maximumFractionDigits = s } else { nf.minimumFractionDigits = 2; nf.maximumFractionDigits = 3 }
        return nf.string(from: NSDecimalNumber(decimal: percent)) ?? "\(percent)"
    }
}

#Preview {
    Text("Preview requires model data")
}
