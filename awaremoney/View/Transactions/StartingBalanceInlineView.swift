import SwiftUI

struct StartingBalanceInlineView: View {
    let asOfDate: Date
    let onSet: (Decimal) -> Void
    @State private var amountInput: String = ""

    var body: some View {
        Section("Starting Balance") {
            Text("Enter the account balance as of \(asOfDate.formatted(date: .abbreviated, time: .omitted))")
                .foregroundStyle(.secondary)
            HStack {
                TextField("0.00", text: $amountInput)
                    .keyboardType(.decimalPad)
                Button("Set") {
                    let sanitized = amountInput
                        .replacingOccurrences(of: ",", with: "")
                        .replacingOccurrences(of: "$", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if let dec = Decimal(string: sanitized) {
                        onSet(dec)
                        amountInput = ""
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

#Preview {
    StartingBalanceInlineView(asOfDate: .now) { _ in }
}
