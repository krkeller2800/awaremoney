import SwiftUI

struct AccountRoutingConfirmationSheet: View {
    let analysis: RoutingAnalysis
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Detected Accounts") {
                    ForEach(analysis.clusters) { cluster in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(cluster.label == "__default__" ? "(Default)" : cluster.label.capitalized)
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.secondary.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(targetDescription(for: cluster.candidate))
                                    .font(.subheadline)
                                Text("Confidence: \(formatPercent(cluster.candidate.confidence))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let inst = analysis.institution {
                    Section("Institution") {
                        Text(inst)
                    }
                }
            }
            .navigationTitle("Confirm Accounts")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Confirm") {
                        onConfirm()
                        dismiss()
                    }
                }
            }
        }
    }

    private func targetDescription(for candidate: RoutingCandidate) -> String {
        switch candidate.action {
        case .existing(_, let name):
            return name
        case .createNew(let type):
            if let t = type { return "Create New — \(t.rawValue.capitalized)" }
            else { return "Create New" }
        }
    }

    private func formatPercent(_ v: Double) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .percent
        nf.minimumFractionDigits = 0
        nf.maximumFractionDigits = 0
        return nf.string(from: NSNumber(value: v)) ?? String(format: "%.0f%%", v * 100)
    }
}

#Preview {
    let clusters = [
        RoutingCluster(label: "checking", transactionsCount: 12, balancesCount: 1, candidate: RoutingCandidate(action: .createNew(type: .checking), confidence: 0.6, reason: "create:type")),
        RoutingCluster(label: "savings", transactionsCount: 3, balancesCount: 1, candidate: RoutingCandidate(action: .createNew(type: .savings), confidence: 0.65, reason: "create:type"))
    ]
    let analysis = RoutingAnalysis(institution: "Bank of America", clusters: clusters, needsConfirmation: true)
    return AccountRoutingConfirmationSheet(analysis: analysis, onConfirm: {})
}
