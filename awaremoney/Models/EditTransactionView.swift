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

    // Correction sheet for imported transactions
    @State private var showCorrectionSheet: Bool = false
    @State private var correctionAmountInput: String = ""
    @State private var correctionDate: Date = .now

    init(transaction: Transaction) {
        self.transaction = transaction
        _payee = State(initialValue: transaction.payee)
        _memo = State(initialValue: transaction.memo ?? "")
        _amountInput = State(initialValue: EditTransactionView.formatAmountForInput(transaction.amount))
        _date = State(initialValue: transaction.datePosted)
        _correctionDate = State(initialValue: transaction.datePosted)
        // For correction sheet, prefill amount with display convention for credit cards
        let displayAmount: Decimal
        if let acct = transaction.account, acct.type == .creditCard {
            displayAmount = (transaction.amount < 0) ? (transaction.amount * -1) : transaction.amount
        } else {
            displayAmount = transaction.amount
        }
        _correctionAmountInput = State(initialValue: EditTransactionView.formatAmountForInput(displayAmount))
    }

    private var isImported: Bool {
        (transaction.importBatch != nil) || (transaction.externalId != nil) || (transaction.importHashKey != nil)
    }
    
    private var isDeletableAdjustment: Bool {
        transaction.kind == .adjustment && transaction.importBatch == nil
    }

    var body: some View {
        Form {
            Section("Details") {
                TextField("Payee", text: $payee)
                TextField("Memo", text: $memo)
            }

            Section("Amount & Date") {
                if isImported {
                    // Read-only for imported transactions
                    LabeledContent("Amount") {
                        Text(formatCurrency(transaction.amount))
                            .foregroundStyle(transaction.amount < 0 ? .red : .primary)
                    }
                    LabeledContent("Date") {
                        Text(transaction.datePosted, style: .date)
                    }
                    Button {
                        showCorrectionSheet = true
                    } label: {
                        Label("Correct with adjustment…", systemImage: "plus.slash.minus")
                    }
                    .buttonStyle(.bordered)
                } else {
                    TextField("0.00", text: $amountInput)
                        .keyboardType(.decimalPad)
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                }
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
        .sheet(isPresented: $showCorrectionSheet) {
            CorrectionSheet()
        }
    }

    // MARK: - Save logic

    private var hasPayeeOrMemoChanges: Bool {
        payee != transaction.payee || (memo != (transaction.memo ?? ""))
    }

    private var hasManualAmountOrDateChanges: Bool {
        guard !isImported else { return false }
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

    // MARK: - Correction Sheet

    @ViewBuilder
    private func CorrectionSheet() -> some View {
        NavigationStack {
            Form {
                Section("Correction") {
                    TextField("Corrected amount", text: $correctionAmountInput)
                        .keyboardType(.decimalPad)
                    DatePicker("As of", selection: $correctionDate, displayedComponents: .date)
                    Text("We'll add an adjustment on this date to correct your balance without changing the imported transaction.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Adjustment")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showCorrectionSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { addCorrection() }
                        .disabled(Decimal(string: sanitizedAmount(correctionAmountInput)) == nil)
                }
            }
        }
    }

    private func addCorrection() {
        guard let account = transaction.account else { return }
        guard let input = Decimal(string: sanitizedAmount(correctionAmountInput)) else { return }

        // Desired ledger amount: for credit cards, positive input means liability increase (store negative)
        var desired = input
        if account.type == .creditCard && desired > 0 {
            desired = -desired
        }

        let current = transaction.amount
        let delta = desired - current
        if delta == .zero { showCorrectionSheet = false; return }

        let payee = "Correction Adjustment"
        let memo = "Correct '\(transaction.payee)' to \(NSDecimalNumber(decimal: desired)) on \(correctionDate.formatted(date: .abbreviated, time: .omitted))"
        let hash = Hashing.hashKey(
            date: correctionDate,
            amount: delta,
            payee: payee,
            memo: memo,
            symbol: nil,
            quantity: nil
        )
        let adj = Transaction(
            datePosted: correctionDate,
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
            importBatch: nil,
            isUserCreated: true
        )
        modelContext.insert(adj)

        do {
            try modelContext.save()
            NotificationCenter.default.post(name: .transactionsDidChange, object: nil)
            showCorrectionSheet = false
            dismiss()
        } catch {
            // Optionally present an alert
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
