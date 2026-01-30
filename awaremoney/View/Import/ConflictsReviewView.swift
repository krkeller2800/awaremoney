import SwiftUI
import SwiftData

struct TxConflict: Identifiable {
    let id: String // import identity key (importHashKey or hashKey)
    let existing: Transaction
    let staged: StagedTransaction
}

struct ConflictsReviewView: View {
    let batchLabel: String
    let conflicts: [TxConflict]
    let onResolve: (Set<String>) -> Void
    let onHardDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selections: [String: Bool] = [:] // true => Accept new

    var body: some View {
        NavigationStack {
            List {
                Section("Conflicts in \(batchLabel)") {
                    if conflicts.isEmpty {
                        Text("No conflicts detected.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(conflicts) { item in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(item.existing.payee)
                                    Spacer()
                                    Text(item.existing.datePosted, style: .date)
                                }
                                .font(.subheadline)
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading) {
                                        Text("Mine")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text(format(amount: item.existing.amount))
                                    }
                                    VStack(alignment: .leading) {
                                        Text("New")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text(format(amount: item.staged.amount))
                                    }
                                }
                                Picker("Resolution", selection: Binding(get: {
                                    selections[item.id] ?? false
                                }, set: { selections[item.id] = $0 })) {
                                    Text("Keep mine").tag(false)
                                    Text("Accept new").tag(true)
                                }
                                .pickerStyle(.segmented)
                            }
                            .padding(.vertical, 6)
                        }
                    }
                }
            }
            .navigationTitle("Resolve Conflicts")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(role: .destructive) {
                        onHardDelete()
                    } label: {
                        Label("Delete Batch", systemImage: "trash")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        let force = Set(selections.filter { $0.value }.map { $0.key })
                        onResolve(force)
                        dismiss()
                    }
                    .disabled(conflicts.isEmpty)
                }
            }
        }
        .onAppear {
            var initial: [String: Bool] = [:]
            for c in conflicts { initial[c.id] = false }
            selections = initial
        }
    }

    private func format(amount: Decimal) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = "USD"
        return nf.string(from: NSDecimalNumber(decimal: amount)) ?? "\(amount)"
    }
}

#Preview {
    Text("Preview requires model data")
}
