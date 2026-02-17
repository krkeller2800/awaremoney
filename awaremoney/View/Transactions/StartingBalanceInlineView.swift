import SwiftUI

struct StartingBalanceInlineView: View {
    let asOfDate: Date
    let onSet: (Decimal, Date) -> Void
    @State private var amountInput: String = ""
    @State private var selectedDate: Date
    var title: String = "Starting Balance"
    var messageOverride: String? = nil

    init(asOfDate: Date, onSet: @escaping (Decimal, Date) -> Void, title: String = "Starting Balance", messageOverride: String? = nil) {
        self.asOfDate = asOfDate
        self.onSet = onSet
        self.title = title
        self.messageOverride = messageOverride
        self._selectedDate = State(initialValue: asOfDate)
    }

    var body: some View {
        Section(title) {
            Text(messageOverride ?? "Enter the account balance and choose the statement date.")
                .foregroundStyle(.secondary)
            DatePicker("As of", selection: $selectedDate, displayedComponents: .date)
            HStack {
                TextField("0.00", text: $amountInput)
                    .keyboardType(.decimalPad)
                Button("Set") {
                    let sanitized = amountInput
                        .replacingOccurrences(of: ",", with: "")
                        .replacingOccurrences(of: "$", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if let dec = Decimal(string: sanitized) {
                        onSet(dec, selectedDate)
                        amountInput = ""
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

#Preview {
    VStack {
        StartingBalanceInlineView(asOfDate: .now, onSet: { _, _ in })
        StartingBalanceInlineView(
            asOfDate: .now,
            onSet: { _, _ in },
            title: "Ending Balance",
            messageOverride: "Enter the ending balance and choose the statement date."
        )
    }
}
