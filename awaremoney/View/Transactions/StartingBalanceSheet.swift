import SwiftUI
import SwiftData

struct StartingBalanceSheet: View {
    let account: Account
    let defaultDate: Date?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var amountInput: String = ""
    @State private var date: Date = .now

    var body: some View {
        NavigationStack {
            Form {
                Section("Balance") {
                    DatePicker("As of", selection: $date, displayedComponents: .date)
                        .onAppear {
                            if let d = defaultDate {
                                // If default date matches earliest transaction date and no prior anchor exists, shift to previous day
                                if let earliest = account.transactions.map(\.datePosted).min(), Calendar.current.isDate(d, inSameDayAs: earliest) {
                                    // Only shift for starting baseline
                                    let hasPriorAnchor = account.balanceSnapshots.contains { $0.asOfDate <= earliest } || account.transactions.contains { $0.kind == .adjustment && $0.datePosted <= earliest }
                                    if !hasPriorAnchor {
                                        date = Calendar.current.date(byAdding: .day, value: -1, to: d) ?? d
                                    } else {
                                        date = d
                                    }
                                } else {
                                    date = d
                                }
                            }
                            // Prefill amount with current as-of balance so editing shows the existing target
                            if amountInput.isEmpty {
                                let snapshotsBefore = account.balanceSnapshots.filter { $0.asOfDate <= date }
                                let baseSnapshot = snapshotsBefore.sorted { $0.asOfDate > $1.asOfDate }.first
                                let current: Decimal = {
                                    if let snap = baseSnapshot {
                                        let txAfter = account.transactions.filter { $0.datePosted > snap.asOfDate && $0.datePosted <= date }
                                        let delta = txAfter.reduce(Decimal.zero) { $0 + $1.amount }
                                        return snap.balance + delta
                                    } else {
                                        let txUpTo = account.transactions.filter { $0.datePosted <= date }
                                        return txUpTo.reduce(Decimal.zero) { $0 + $1.amount }
                                    }
                                }()

                                let prefill: Decimal
                                if account.type == .creditCard || account.type == .loan {
                                    prefill = (current < 0) ? (current * -1) : current
                                } else {
                                    prefill = current
                                }
                                amountInput = formatAmountForInput(prefill)
                            }
                        }
                    TextField("0.00", text: $amountInput)
                        .keyboardType(.decimalPad)

                    if account.type == .creditCard || account.type == .loan {
                        Text("Enter the amount you owe; we’ll store it as a negative balance for liabilities.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    let hasPriorAnchor = account.balanceSnapshots.contains { $0.asOfDate <= date } || account.transactions.contains { $0.kind == .adjustment && $0.datePosted <= date }
                    if !hasPriorAnchor {
                        Text("If this is the first balance, we’ll create an adjustment to set your starting point.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    // Hint about same-day transactions
                    if let earliest = account.transactions.map(\.datePosted).min() {
                        if Calendar.current.isDate(earliest, inSameDayAs: date) {
                            Text("Tip: Starting balance is before any of these transactions. Consider choosing the day before your first imported transaction.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Add Balance")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(Decimal(string: sanitizedAmount()) == nil)
                }
            }
        }
    }

    private func sanitizedAmount() -> String {
        amountInput
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "$", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func formatAmountForInput(_ amount: Decimal) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        nf.minimumFractionDigits = 0
        nf.maximumFractionDigits = 2
        return nf.string(from: NSDecimalNumber(decimal: amount)) ?? "\(amount)"
    }

    private func save() {
        guard let input = Decimal(string: sanitizedAmount()) else { return }
        var desired = input
        if (account.type == .creditCard || account.type == .loan) && desired > 0 {
            desired = -desired
        }

        // Compute current calculated balance as of the selected date
        let snapshotsBefore = account.balanceSnapshots.filter { $0.asOfDate <= date }
        let baseSnapshot = snapshotsBefore.sorted { $0.asOfDate > $1.asOfDate }.first
        let current: Decimal = {
            if let snap = baseSnapshot {
                let txAfter = account.transactions.filter { $0.datePosted > snap.asOfDate && $0.datePosted <= date }
                let delta = txAfter.reduce(Decimal.zero) { $0 + $1.amount }
                return snap.balance + delta
            } else {
                let txUpTo = account.transactions.filter { $0.datePosted <= date }
                return txUpTo.reduce(Decimal.zero) { $0 + $1.amount }
            }
        }()

        let delta = desired - current
        if delta == .zero {
            dismiss()
            return
        }

        let payee = "Balance Adjustment"
        let memo = "Adjust to \(NSDecimalNumber(decimal: desired)) as of \(date.formatted(date: .abbreviated, time: .omitted))"
        let hash = Hashing.hashKey(
            date: date,
            amount: delta,
            payee: payee,
            memo: memo,
            symbol: nil,
            quantity: nil
        )
        let adj = Transaction(
            datePosted: date,
            amount: delta,
            payee: payee,
            memo: memo,
            kind: .adjustment,
            externalId: nil,
            hashKey: hash,
            symbol: nil,
            quantity: nil,
            price: nil,
            fees: nil,
            account: account,
            importBatch: nil
        )
        modelContext.insert(adj)
        do {
            try modelContext.save()
            NotificationCenter.default.post(name: .transactionsDidChange, object: nil)
            dismiss()
        } catch {
            // Optionally present an alert
        }
    }
}

#Preview {
    // Preview requires a dummy account; using a placeholder struct wrapper for preview only
    Text("Preview not available without model container")
}

