import SwiftUI
import SwiftData

/// UI to confirm and edit routing per cluster. Presents one row per cluster label.
/// Selections are pushed up via bindings, and a preview resolve is emitted via `onPreviewUpdate`.
/// This view does not create accounts or persist mappings; persistence should occur later on "Approve & Save".
struct RoutingConfirmationView: View {
    let analysis: RoutingAnalysis
    let plans: [ImportRoutingService.RoutedClusterPlan]

    @Binding var overrides: [String: RoutingCandidate.Action]
    @Binding var selectedInstitution: String?
    
    // Callback with the effective overrides for preview (not final confirm)
    let onPreviewUpdate: (_ effective: [String: RoutingCandidate.Action], _ selectedInstitution: String?) -> Void
    let onCancel: () -> Void
    let onApprove: (() -> Void)?
    
    init(
        analysis: RoutingAnalysis,
        plans: [ImportRoutingService.RoutedClusterPlan],
        overrides: Binding<[String: RoutingCandidate.Action]>,
        selectedInstitution: Binding<String?>,
        globalTargetMode: Binding<Int>,
        onPreviewUpdate: @escaping (_ effective: [String: RoutingCandidate.Action], _ selectedInstitution: String?) -> Void,
        onCancel: @escaping () -> Void,
        onApprove: (() -> Void)? = nil
    ) {
        self.analysis = analysis
        self.plans = plans
        _overrides = overrides
        _selectedInstitution = selectedInstitution
        _globalTargetMode = globalTargetMode
        self.onPreviewUpdate = onPreviewUpdate
        self.onCancel = onCancel
        self.onApprove = onApprove
    }
    @Environment(\.modelContext) private var modelContext

    // Cached accounts for pickers
    @State private var accounts: [Account] = []

    // Track expanded rows for type pickers when creating new
    @State private var expandedCreateRows: Set<String> = []

    @State private var userEditedInstitution: Bool = false

    @Binding var globalTargetMode: Int
    @FocusState private var institutionIsFirstResponder: Bool
    @State private var isVisible: Bool = false

    // Name entered for new accounts, keyed by normalized cluster label
    @State private var newAccountNames: [String: String] = [:]

    @State private var previewDebounce: DispatchWorkItem?
    
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
        guard let t = type else { return ""}
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
    // Helper to describe the enum
    private func describe(_ action: RoutingCandidate.Action) -> String {
        switch action {
        case .existing(let id, let name): return "existing(id=\(id), name=\(name))"
        case .createNew(let t): return "createNew(type=\(String(describing: t)))"
        }
    }

    private func effectiveResolvedActions() -> [String: RoutingCandidate.Action] {
        var result: [String: RoutingCandidate.Action] = [:]
        for p in plans {
            let base: RoutingCandidate.Action = overrides[p.label] ?? p.candidate.action
            if globalTargetMode != 0 {
                switch base {
                case .createNew(let t):
                    result[p.label] = .createNew(type: t)
                case .existing:
                    result[p.label] = .createNew(type: nil)
                }
            } else {
                result[p.label] = base
            }
        }
        return result
    }

    private func notifyPreviewUpdate() {
        onPreviewUpdate(effectiveResolvedActions(), selectedInstitution ?? analysis.institution)
    }

    #if canImport(UIKit)
    private func selectAllInFirstResponder(after delay: TimeInterval = 0.05) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            UIApplication.shared.sendAction(#selector(UIResponder.selectAll(_:)), to: nil, from: nil, for: nil)
        }
    }
    private func selectAllInFirstResponder() {
        selectAllInFirstResponder(after: 0.05)
    }
    #else
    private func selectAllInFirstResponder() { }
    #endif

#if canImport(UIKit)
    private func dismissKeyboardOnly() {
        institutionIsFirstResponder = false
        let keyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        keyWindow?.endEditing(true)
    }
#else
    private func dismissKeyboardOnly() { institutionIsFirstResponder = false }
#endif

    @ViewBuilder
    private var routingSections: some View {
        // 1) Global institution + single New/Existing picker
        Section() {
            if globalTargetMode == 0 {
                // Treat nil/empty/"Unknown" as unselected
                let needsInstitution: Bool = {
                    let raw = (selectedInstitution ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    return raw.isEmpty || raw.lowercased() == "unknown"
                }()

                HStack(spacing: 8) {
                    Image(systemName: "building.columns")
                        .foregroundStyle(.secondary)
                    Text("Institution")
                    Spacer()
                    Picker("Institution", selection: Binding<String>(
                        get: { selectedInstitution ?? "Unknown" },
                        set: { selectedInstitution = $0 }
                    )) {
                        Text("Select").tag("Unknown")
                        ForEach(uniqueInstitutionsIncludingAnalysis(), id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .accessibilityLabel("Institution")
//
//                    Spacer(minLength: 8)
//
                    if needsInstitution {
                        Text("Required")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.orange.opacity(0.15))
                            .foregroundStyle(.orange)
                            .clipShape(Capsule())
                            .accessibilityLabel("Institution required")
                            .accessibilityHint("Select an institution to continue")
                    }
                }
                .padding(8)
                .background(needsInstitution ? Color.orange.opacity(0.10) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(needsInstitution ? Color.orange : Color.clear, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                let needsInstitution: Bool = {
                    let raw = (selectedInstitution ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    return raw.isEmpty
                }()

                HStack(spacing: 8) {
                    Text("Institution")

                    Spacer()

                    HStack(spacing: 6) {
                        TextField(
                            "",
                            text: Binding(
                                get: { selectedInstitution ?? (analysis.institution ?? "") },
                                set: { newVal in
                                    selectedInstitution = newVal.isEmpty ? nil : newVal
                                    userEditedInstitution = true
                                }
                            ),
                            prompt: Text("Account")
                        )
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                        .submitLabel(.done)
                        .onSubmit { dismissKeyboardOnly() }
                        .focused($institutionIsFirstResponder)
                        .onChange(of: institutionIsFirstResponder) { _, isFocused in
                            if isFocused { selectAllInFirstResponder() }
                        }
                        .accessibilityLabel("Institution")
                        .accessibilityHint("Enter an institution to continue")

                        Button {
                            institutionIsFirstResponder = true
                            selectAllInFirstResponder()
                        } label: {
                            Image(systemName: "pencil").font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Edit institution")
                    }
                    .frame(maxWidth: 220)

                    if needsInstitution {
                        Text("Required")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.orange.opacity(0.15))
                            .foregroundStyle(.orange)
                            .clipShape(Capsule())
                            .accessibilityLabel("Institution required")
                    }
                }
                .padding(8)
                .background(needsInstitution ? Color.orange.opacity(0.10) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(needsInstitution ? Color.orange : Color.clear, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // Single global target selection (applies to all clusters)
            Picker("Target", selection: Binding<Int>(
                get: { globalTargetMode },
                set: { idx in
                    globalTargetMode = idx

                    // Clear all user-entered per‑cluster fields when switching modes
                    newAccountNames.removeAll()
                    expandedCreateRows.removeAll()
                    institutionIsFirstResponder = false

                    // Clear institution typed in the other mode so it doesn't leak across
                    userEditedInstitution = false
                    selectedInstitution = nil

                    // Reset overrides before applying the new mode
                    overrides.removeAll()

                    // Update overrides for all plans based on the new global selection.
                    // Existing: let candidates drive (user must pick explicit accounts).
                    // Create New: force create for all clusters (seed with candidate type if present).
                    switch idx {
                    case 0: // Existing
                        for p in plans { overrides[p.label] = nil }
                    default: // Create New
                        for p in plans {
                            switch p.candidate.action {
                            case .createNew(let t): overrides[p.label] = .createNew(type: t)
                            case .existing(_, _):   overrides[p.label] = .createNew(type: nil)
                            }
                        }
                    }
                    notifyPreviewUpdate()
                }
            )) {
                Text("Existing Account").tag(0)
                Text("Create New").tag(1)
            }
            .pickerStyle(.segmented)
        }

        // 2) Per-cluster rows: header reflects current action; show Type picker only when Create New
        Section() {
            ForEach(plans, id: \.id) { plan in
                VStack(alignment: .leading, spacing: 8) {
                    // Current action for this cluster (override wins, otherwise candidate)
                    let baseAction: RoutingCandidate.Action = overrides[plan.label] ?? plan.candidate.action

                    // Decide which UI to show based on the global target mode
                    let showExistingUI: Bool = (globalTargetMode == 0)

                    // Header title that reflects the forced UI mode + type/account when available
                    let headerTitle: String = {
                        let base = (plan.label == "__default__") ? "Default" : plan.label.capitalized
                        if showExistingUI {
                            // Prefer the selected account name from overrides; otherwise just say Existing
                            if case .some(.existing(_, let name)) = overrides[plan.label], !name.isEmpty {
                                return "\(base) — Existing (\(name))"
                            } else if case .existing(_, let name) = plan.candidate.action, !name.isEmpty {
                                // Fall back to candidate's existing name if present
                                return "\(base) — Existing (\(name))"
                            } else {
                                return "\(base) — Existing"
                            }
                        } else {
                            // Create New mode: reflect type if available from the (override or) candidate
                            switch baseAction {
                            case .createNew(let optType):
                                if let t = optType {
                                    return "\(base) — Create New (\(displayName(for: t)))"
                                } else {
                                    return "\(base) — Create New"
                                }
                            case .existing(_, let name):
                                return name.isEmpty ? "\(base) — Existing" : "\(base) — Existing (\(name))"
                            }
                        }
                    }()

                    // Header + confidence
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(headerTitle)
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

                    // Institution line (derived from the global picker)
                    if let inst = selectedInstitution ?? analysis.institution {
                        HStack(spacing: 6) {
                            Image(systemName: "building.columns")
                                .foregroundStyle(.secondary)
                            Text(inst)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Existing vs. Create New UI — strictly follow globalTargetMode
                    Group {
                        if globalTargetMode == 0 {
                            ExistingAccountSelectionRow(
                                plan: plan,
                                baseAction: baseAction,
                                accountsAtInst: accounts(at: selectedInstitution),
                                overrides: $overrides,
                                onChange: { notifyPreviewUpdate() }
                            )
                            .id("existing-\(plan.id)")
                        } else {
                            CreateNewSelectionRow(
                                plan: plan,
                                baseAction: baseAction,
                                newAccountNames: $newAccountNames,
                                overrides: $overrides,
                                onChange: { notifyPreviewUpdate() }
                            )
                            .id("create-\(plan.id)")
                        }
                    }
                    // Force a fresh subtree when mode or institution changes (prevents stale branch reuse)
                    .id("routing-\(plan.label)-mode-\(globalTargetMode)")
                }
                // Key the row so SwiftUI tears it down/rebuilds when the mode flips
                .id("row-\(plan.label)-mode-\(globalTargetMode)")
                // Attach onChange to the VStack (a View), not to the `let` above
                .onChange(of: globalTargetMode) { _, newVal in
                    // Recompute base and effective for logging at the moment of change
                    let currentBase: RoutingCandidate.Action = overrides[plan.label] ?? plan.candidate.action
                    let currentEff: RoutingCandidate.Action = {
                        if newVal != 0 {
                            if case .createNew(let t) = currentBase {
                                return RoutingCandidate.Action.createNew(type: t) // fully qualified
                            }
                            return RoutingCandidate.Action.createNew(type: nil)    // fully qualified
                        } else {
                            return currentBase
                        }
                    }()
                    AMLogging.log(
                        "Row mode -> \(newVal) label=\(plan.label) base=\(describe(currentBase)) eff=\(describe(currentEff))",
                        component: "RoutingConfirmationView"
                    )
                }
            }
        }
        .id("routing-section-mode-\(globalTargetMode)")
    }
    
    var body: some View {
        routingSections
            .preference(key: RoutingChildEditingKey.self, value: institutionIsFirstResponder && isVisible)
            .onChange(of: globalTargetMode) { _, newValue in
                AMLogging.log("Global mode changed -> \(newValue)", component: "RoutingConfirmationView")
                notifyPreviewUpdate()
            }
            .onChange(of: selectedInstitution) { _, _ in
                previewDebounce?.cancel()
                let work = DispatchWorkItem { notifyPreviewUpdate() }
                previewDebounce = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
            }
            .onChange(of: institutionIsFirstResponder) { _, isFocused in
                AMLogging.log("RCV editing changed -> \(isFocused), isVisible=\(isVisible)", component: "RoutingConfirmationView")
            }
            .onChange(of: isVisible) { _, vis in
                AMLogging.log("RCV visibility -> \(vis), editing=\(institutionIsFirstResponder)", component: "RoutingConfirmationView")
            }
            .onAppear {
                isVisible = true
                AMLogging.log(
                    "RoutingConfirmationView appear: plans=\(plans.map { $0.id }) initialMode=\(globalTargetMode)",
                    component: "RoutingConfirmationView"
                )
            }
            .onAppear {
                loadAccounts()

                if globalTargetMode != 0 && !userEditedInstitution {
                    selectedInstitution = nil
                }
                notifyPreviewUpdate()
            }
            .onDisappear {
                isVisible = false
                institutionIsFirstResponder = false
                dismissKeyboardOnly()
                previewDebounce?.cancel()
            }
            .onReceive(NotificationCenter.default.publisher(for: .focusRoutingInstitution)) { _ in
                // Only meaningful when the TextField exists (Create New mode)
                if globalTargetMode != 0 {
                    institutionIsFirstResponder = true
                    selectAllInFirstResponder()
                }
            }
    }
}
private extension Notification.Name {
    static let focusRoutingInstitution = Notification.Name("focusRoutingInstitution")
}
private struct ExistingAccountSelectionRow: View {
    let plan: ImportRoutingService.RoutedClusterPlan
    let baseAction: RoutingCandidate.Action
    let accountsAtInst: [Account]
    @Binding var overrides: [String: RoutingCandidate.Action]
    let onChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
//            Picker("Existing Account", selection: Binding<UUID?>(
//                get: {
//                    if case .existing(let id, _) = baseAction { return id }
//                    return nil
//                },
//                set: { newID in
//                    if let id = newID, let acct = accountsAtInst.first(where: { $0.id == id }) {
//                        overrides[plan.label] = .existing(accountID: id, name: acct.name)
//                    } else {
//                        overrides[plan.label] = nil
//                    }
//                }
//            )) {
//                ForEach(accountsAtInst, id: \.id) { acct in
//                    Text(acct.name).tag(Optional(acct.id))
//                }
//            }
//            .pickerStyle(.menu)

            if accountsAtInst.isEmpty {
                Text("No existing accounts at this institution.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct CreateNewSelectionRow: View {
    let plan: ImportRoutingService.RoutedClusterPlan
    let baseAction: RoutingCandidate.Action
    @Binding var newAccountNames: [String: String]
    @Binding var overrides: [String: RoutingCandidate.Action]
    let onChange: () -> Void

    private var seedType: Account.AccountType? {
        if case .createNew(let t) = baseAction { return t }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let allTypes: [Account.AccountType] = [.checking, .savings, .creditCard, .loan, .brokerage, .cash, .property, .other]

            Picker("New Account Type", selection: Binding<Account.AccountType?>(
                get: { seedType },
                set: { newType in
                    overrides[plan.label] = .createNew(type: newType)
                    onChange()
                }
            )) {
                Text("Unspecified").tag(nil as Account.AccountType?)
                ForEach(allTypes, id: \.self) { t in
                    Text(displayName(for: t)).tag(Optional(t))
                }
            }
            .pickerStyle(.menu)

//            TextField("Account Name", text: Binding(
//                get: { newAccountNames[plan.label] ?? "" },
//                set: { newAccountNames[plan.label] = $0 }
//            ))
//            .textInputAutocapitalization(.words)
//            .disableAutocorrection(true)
//            .textFieldStyle(.roundedBorder)
        }
    }

    private func displayName(for type: Account.AccountType) -> String {
        switch type {
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

struct RoutingChildEditingKey: PreferenceKey {
    static var defaultValue: Bool = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = nextValue()
    }
}

#Preview {
    Text("Preview requires model data")
}
