import SwiftUI
import SwiftData

struct EditTransactionView: View {
    let transaction: Transaction

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var payee: String
    @State private var memo: String

    // For manual transactions only (imported transactions lock amount/date)
    @State private var amountInput: String
    @State private var date: Date

    init(transaction: Transaction) {
        self.transaction = transaction
        _payee = State(initialValue: transaction.payee)
        _memo = State(initialValue: transaction.memo ?? "")
        _amountInput = State(initialValue: EditTransactionView.formatAmountForInput(transaction.amount))
        _date = State(initialValue: transaction.datePosted)
    }
    
    private var isDeletableAdjustment: Bool {
        transaction.kind == .adjustment && transaction.importBatch == nil
    }

    var body: some View {
        Form {
            Section("Details") {
                TextField("Payee", text: $payee)
                TextField("Memo", text: $memo)
                Toggle(isOn: Binding(get: {
                    !(transaction.isExcluded)
                }, set: { newVal in
                    transaction.isExcluded = !newVal
                    transaction.isUserModified = true
                })) {
                    Text("Include in totals")
                }
            }

            Section("Amount & Date") {
                TextField("0.00", text: $amountInput)
                    .keyboardType(.decimalPad)
                DatePicker("Date", selection: $date, displayedComponents: .date)
                Text("Editing amount/date will be preserved across batch replacement unless you choose 'Accept new' during conflict resolution.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Edit Transaction")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(!canSave)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                if isDeletableAdjustment {
                    Button(role: .destructive) {
                        deleteTransaction()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
    }

    // MARK: - Save logic

    private var hasPayeeOrMemoChanges: Bool {
        payee != transaction.payee || (memo != (transaction.memo ?? ""))
    }

    private var hasManualAmountOrDateChanges: Bool {
        let sanitized = sanitizedAmount(amountInput)
        let newAmount = Decimal(string: sanitized)
        let amountChanged = (newAmount != nil) && (newAmount! != transaction.amount)
        let dateChanged = date != transaction.datePosted
        return amountChanged || dateChanged
    }

    private var canSave: Bool { hasPayeeOrMemoChanges || hasManualAmountOrDateChanges }

    private func save() {
        // Always allow payee/memo edits
        if hasPayeeOrMemoChanges {
            transaction.payee = payee
            transaction.memo = memo.isEmpty ? nil : memo
            transaction.isUserEdited = true
            transaction.isUserModified = true
        }

        if hasManualAmountOrDateChanges {
            // Preserve originals once
            if transaction.originalAmount == nil { transaction.originalAmount = transaction.amount }
            if transaction.originalDate == nil { transaction.originalDate = transaction.datePosted }

            // Update fields
            if let newAmount = Decimal(string: sanitizedAmount(amountInput)) {
                transaction.amount = newAmount
            }
            transaction.datePosted = date
            transaction.isUserEdited = true
            transaction.isUserModified = true
        }

        // Recompute mutable hashKey to reflect current visible fields (importHashKey remains the original)
        transaction.hashKey = Hashing.hashKey(
            date: transaction.datePosted,
            amount: transaction.amount,
            payee: transaction.payee,
            memo: transaction.memo,
            symbol: transaction.symbol,
            quantity: transaction.quantity
        )

        do {
            try modelContext.save()
            NotificationCenter.default.post(name: .transactionsDidChange, object: nil)
            dismiss()
        } catch {
            // Could present an alert in the future
        }
    }
    
    private func deleteTransaction() {
        modelContext.delete(transaction)
        do {
            try modelContext.save()
            NotificationCenter.default.post(name: .transactionsDidChange, object: nil)
            dismiss()
        } catch {
            // Optionally present an alert in the future
        }
    }

    // MARK: - Helpers

    private func sanitizedAmount(_ s: String) -> String {
        s.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func formatCurrency(_ amount: Decimal) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = "USD"
        return nf.string(from: NSDecimalNumber(decimal: amount)) ?? "\(amount)"
    }

    private static func formatAmountForInput(_ amount: Decimal) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        nf.minimumFractionDigits = 0
        nf.maximumFractionDigits = 2
        return nf.string(from: NSDecimalNumber(decimal: amount)) ?? "\(amount)"
    }
}

#Preview {
    Text("Preview requires model data")
}
