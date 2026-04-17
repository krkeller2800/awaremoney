import SwiftUI
import SwiftData

/// UI to confirm and edit routing per cluster. Presents one row per cluster label.
/// For each cluster, user may pick an existing account or choose "Create New" and select a type.
struct RoutingConfirmationView: View {
    let analysis: RoutingAnalysis
    let plans: [ImportRoutingService.RoutedClusterPlan]

    // Callback with the final overrides when user taps Continue
    let onConfirm: (_ overrides: [String: RoutingCandidate.Action], _ selectedInstitution: String?) -> Void
    let onCancel: () -> Void

    @Environment(\.modelContext) private var modelContext

    // Local state of user selections keyed by normalized label
    @State private var overrides: [String: RoutingCandidate.Action] = [:]

    // Cached accounts for pickers
    @State private var accounts: [Account] = []

    // Track expanded rows for type pickers when creating new
    @State private var expandedCreateRows: Set<String> = []

    @State private var selectedInstitution: String? = nil
    @State private var globalTargetMode: Int = 0

    // Unique institution names including the analyzed institution
    private func uniqueInstitutionsIncludingAnalysis() -> [String] {
        var set: Set<String> = []
        // Include institutions from existing accounts
        for acct in accounts {
            let raw = (acct.institutionName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let key = raw.isEmpty ? "Unknown" : raw
            set.insert(key)
        }
        // Include the analyzed institution if present
        if let inst = analysis.institution?.trimmingCharacters(in: .whitespacesAndNewlines), !inst.isEmpty {
            set.insert(inst)
        }
        let sorted = set.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return sorted
    }

    // Accounts filtered to a given institution name (case-insensitive). If name is nil, use analysis.institution.
    private func accounts(at institutionName: String?) -> [Account] {
        let target = (institutionName ?? analysis.institution)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let lowered = target.lowercased()
        let filtered = accounts.filter { acct in
            let raw = (acct.institutionName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let key = raw.isEmpty ? "Unknown" : raw
            if lowered.isEmpty { return true }
            return key.lowercased() == lowered
        }
        // Sort for stable presentation
        return filtered.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func initialAction(for plan: ImportRoutingService.RoutedClusterPlan) -> RoutingCandidate.Action {
        if let action = overrides[plan.label] { return action }
        return plan.candidate.action
    }

    private func loadAccounts() {
        do {
            let fetched = try modelContext.fetch(FetchDescriptor<Account>())
            self.accounts = fetched.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            self.accounts = []
        }
    }

    private func displayName(for type: Account.AccountType?) -> String {
        guard let t = type else { return "Account" }
        switch t {
        case .checking: return "Checking"
        case .savings: return "Savings"
        case .creditCard: return "Credit Card"
        case .loan: return "Loan"
        case .brokerage: return "Brokerage"
        case .cash: return "Cash"
        case .property: return "Property"
        case .other: return "Other"
        }
    }

    var body: some View {
        NavigationStack {
            List {
                // Single institution picker applied to all clusters
                Section("Institution") {
                    Picker("Institution", selection: Binding<String>(
                        get: {
                            selectedInstitution ?? (analysis.institution ?? uniqueInstitutionsIncludingAnalysis().first ?? "Unknown")
                        },
                        set: { newVal in
                            selectedInstitution = newVal
                        }
                    )) {
                        ForEach(uniqueInstitutionsIncludingAnalysis(), id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)

                    // Global target selection (applies to all clusters)
                    Picker("Target", selection: Binding<Int>(
                        get: { globalTargetMode },
                        set: { idx in
                            globalTargetMode = idx
                            // Update overrides for all plans based on global selection
                            switch idx {
                            case 0: // Existing Account
                                // Clear overrides to let candidates drive (prefer existing when available)
                                for p in plans { overrides[p.label] = nil }
                            default: // Create New
                                for p in plans {
                                    switch p.candidate.action {
                                    case .createNew(let t): overrides[p.label] = .createNew(type: t)
                                    case .existing(_, _): overrides[p.label] = .createNew(type: nil)
                                    }
                                }
                            }
                        }
                    )) {
                        Text("Existing Account").tag(0)
                        Text("Create New").tag(1)
                    }
                    .pickerStyle(.segmented)
                }

                Section(header: Text(selectedInstitution ?? (analysis.institution ?? "Unknown Institution"))) {
                    ForEach(plans, id: \.id) { plan in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(plan.label == "__default__" ? "Default" : plan.label.capitalized)
                                        .font(.headline)
                                    HStack(spacing: 6) {
                                        if plan.transactions.count > 0 { Text("Tx: \(plan.transactions.count)").font(.caption).foregroundStyle(.secondary) }
                                        if plan.balances.count > 0 { Text("Balances: \(plan.balances.count)").font(.caption).foregroundStyle(.secondary) }
                                        if plan.holdings.count > 0 { Text("Holdings: \(plan.holdings.count)").font(.caption).foregroundStyle(.secondary) }
                                    }
                                }
                                Spacer()
                                ConfidenceBadge(confidence: plan.candidate.confidence)
                            }

                            // Show institution label derived from the Institution section
                            if let inst = selectedInstitution ?? analysis.institution {
                                HStack(spacing: 6) {
                                    Image(systemName: "building.columns")
                                        .foregroundStyle(.secondary)
                                    Text(inst)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
            .navigationTitle("Confirm Routing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    PlanToolbarButton("Cancel", fixedWidth: 70) { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") {
                        let finalOverrides = overrides
                        for p in plans {
                            if let action = finalOverrides[p.label] {
                                switch action {
                                case .existing(_, _):
                                    // handle existing case
                                    break
                                case .createNew(_):
                                    // handle create new case
                                    break
                                }
                            }
                        }
                        onConfirm(overrides, selectedInstitution ?? analysis.institution)
                    }
                }
            }
            .onAppear {
                loadAccounts()
                if selectedInstitution == nil {
                    selectedInstitution = analysis.institution ?? uniqueInstitutionsIncludingAnalysis().first
                }
                // Default to Existing Account globally
                globalTargetMode = 0
                for p in plans { overrides[p.label] = nil }
            }
        }
    }
}

private struct ConfidenceBadge: View {
    let confidence: Double
    var body: some View {
        let pct = Int((max(0, min(1, confidence)) * 100).rounded())
        Text("\(pct)%")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(badgeColor)
            .foregroundStyle(.white)
            .clipShape(Capsule())
            .accessibilityLabel("Confidence \(pct) percent")
    }
    private var badgeColor: Color {
        switch confidence {
        case let c where c >= 0.85: return .green
        case let c where c >= 0.65: return .orange
        default: return .red
        }
    }
}

#Preview {
    Text("Preview requires model data")
}
