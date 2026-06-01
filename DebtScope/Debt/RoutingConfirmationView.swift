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
    
    // Verification state and explicit user selections
    @State private var verificationIssues: [String] = []
    @State private var userSelectedTypes: [String: Account.AccountType?] = [:]

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
        // In Existing mode, show all accounts until the user explicitly chooses an institution.
        // This avoids hiding valid matches due to an incorrect default guess and reduces false-positive verification issues.
        let rawInstitution = (selectedInstitution?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        let hasChosenInstitution = !rawInstitution.isEmpty && rawInstitution.lowercased() != "unknown"
        if globalTargetMode == 0 && !hasChosenInstitution {
            // Return all accounts (optionally sorted) so the user can pick the correct existing account first.
            return accounts
        }
        
        let target = (institutionName ?? analysis.institution)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let lowered = target.lowercased()
        let filtered = accounts.filter { acct in
            let raw = (acct.institutionName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let key = raw.isEmpty ? "Unknown" : raw
            if lowered.isEmpty { return true }
            return key.lowercased() == lowered
        }
        // Deduplicate by id just in case the fetch produced duplicates
        let deduped = Dictionary(grouping: filtered, by: { $0.id }).compactMap { $0.value.first }
        // Sort for stable presentation
        return deduped.sorted { lhs, rhs in
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
            AMLogging.log("Loaded accounts=\(self.accounts.count)", component: "RoutingConfirmationView")
        } catch {
            self.accounts = []
            AMLogging.log("Failed to load accounts; defaulting to empty list", component: "RoutingConfirmationView")
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

    private func routingTitle(for action: RoutingCandidate.Action) -> String {
        switch action {
        case .existing:
            return "Existing Account"
        case .createNew:
            return "Create New Account"
        }
    }

    // Helper to describe the enum
    private func describe(_ action: RoutingCandidate.Action) -> String {
        switch action {
        case .existing(let id, let name): return "existing(id=\(id), name=\(name))"
        case .createNew(let t): return "createNew(type=\(String(describing: t)))"
        }
    }
    private func shortDescribe(_ action: RoutingCandidate.Action) -> String {
        switch action {
        case .existing(_, let name):
            return name.isEmpty ? "existing" : "existing(\(name))"
        case .createNew(let t):
            if let t = t {
                return "createNew(\(displayName(for: t)))"
            } else {
                return "createNew(unspecified)"
            }
        }
    }

    private func effectiveResolvedActions() -> [String: RoutingCandidate.Action] {
        var result: [String: RoutingCandidate.Action] = [:]
        let instAccounts = accounts(at: selectedInstitution)
        for p in plans {
            if globalTargetMode == 0 {
                // Existing mode: only accept .existing that belongs to the selected institution
                if let override = overrides[p.label], case .existing(let id, _) = override,
                   instAccounts.contains(where: { $0.id == id }) {
                    result[p.label] = override
                } else if case .existing(let id, _) = p.candidate.action,
                          instAccounts.contains(where: { $0.id == id }) {
                    result[p.label] = p.candidate.action
                } else if case .createNew = p.candidate.action {
                    // Mixed statements can legitimately contain an existing savings account plus
                    // a brand-new loan on the same PDF. Preserve an intentional create-new candidate
                    // instead of treating it as an unresolved existing-account failure.
                    result[p.label] = p.candidate.action
                } else {
                    // No valid existing selection at the chosen institution; mark unresolved
                    result[p.label] = .createNew(type: nil)
                }
            } else {
                // Create New mode: force create-new for all clusters, preserving type when available.
                let base: RoutingCandidate.Action = overrides[p.label] ?? p.candidate.action
                switch base {
                case .createNew(let t):
                    result[p.label] = .createNew(type: t)
                case .existing:
                    result[p.label] = .createNew(type: nil)
                }
            }
        }
        return result
    }

    private func effectiveAction(for plan: ImportRoutingService.RoutedClusterPlan) -> RoutingCandidate.Action {
        if globalTargetMode == 0 {
            // Existing mode: only accept .existing that belongs to the selected institution
            let instAccounts = accounts(at: selectedInstitution)
            if let override = overrides[plan.label], case .existing(let id, _) = override,
               instAccounts.contains(where: { $0.id == id }) {
                return override
            }
            if case .existing(let id, _) = plan.candidate.action,
               instAccounts.contains(where: { $0.id == id }) {
                return plan.candidate.action
            }
            if case .createNew = plan.candidate.action {
                return plan.candidate.action
            }
            // Unresolved in Existing mode
            return .createNew(type: nil)
        } else {
            // Create New mode: force create-new, preserving type if base is createNew
            let base = overrides[plan.label] ?? plan.candidate.action
            switch base {
            case .createNew(let t):
                return .createNew(type: t)
            case .existing:
                return .createNew(type: nil)
            }
        }
    }

    private func effectiveAction(for plan: ImportRoutingService.RoutedClusterPlan, newMode: Int) -> RoutingCandidate.Action {
        // Compute effective action given a prospective new global mode, with simple control flow to aid type-checker.
        if newMode == 0 {
            // Existing mode: only accept .existing that belongs to the selected institution
            let instAccounts = accounts(at: selectedInstitution)
            if let override = overrides[plan.label], case .existing = override {
                if case .existing(let id, _) = override,
                   instAccounts.contains(where: { $0.id == id }) {
                    return override
                }
            }
            if case .existing(let id, _) = plan.candidate.action,
               instAccounts.contains(where: { $0.id == id }) {
                return plan.candidate.action
            }
            if case .createNew = plan.candidate.action {
                return plan.candidate.action
            }
            return RoutingCandidate.Action.createNew(type: nil)
        } else {
            // Create New mode: force create-new, preserving type if base is createNew
            let base: RoutingCandidate.Action = overrides[plan.label] ?? plan.candidate.action
            switch base {
            case .createNew(let t):
                return RoutingCandidate.Action.createNew(type: t)
            case .existing:
                return RoutingCandidate.Action.createNew(type: nil)
            }
        }
    }

    // Compute user-facing verification issues based on the current mode and effective actions.
    private func computeVerificationIssues(effective: [String: RoutingCandidate.Action]) -> [String] {
        var issues: [String] = []
        if globalTargetMode == 0 {
            // Existing mode: flag when the effective resolution is not an account at the chosen institution
            let instAccounts = accounts(at: selectedInstitution)
            for p in plans {
                guard let eff = effective[p.label] else {
                    issues.append("\(p.label): no account selected at the chosen institution")
                    continue
                }
                switch eff {
                case .existing(let id, _):
                    if !instAccounts.contains(where: { $0.id == id }) {
                        issues.append("\(p.label): selected account isn’t at the chosen institution")
                    }
                case .createNew:
                    issues.append("\(p.label): no account selected at the chosen institution")
                }
            }
        } else {
            // Create New mode: only flag when the user explicitly selected a type and the effective resolution disagrees.
            for p in plans {
                let eff = effective[p.label]
                if let intended = userSelectedTypes[p.label] {
                    switch eff {
                    case .createNew(let t):
                        if intended != t {
                            let effName = t.map { displayName(for: $0) } ?? "Unspecified"
                            let inName = intended.map { displayName(for: $0) } ?? "Unspecified"
                            issues.append("\(p.label): will be saved as \(effName), but you selected \(inName)")
                        }
                    default:
                        issues.append("\(p.label): will be saved differently than you selected")
                    }
                }
            }
        }
        return issues
    }

    private func notifyPreviewUpdate() {
        let eff = effectiveResolvedActions()
        // Update verification issues before emitting
        verificationIssues = computeVerificationIssues(effective: eff)

        let inst = selectedInstitution ?? analysis.institution
        let summary = plans.map { p -> String in
            let act = eff[p.label] ?? p.candidate.action
            return "\(p.label)=\(shortDescribe(act))"
        }.joined(separator: ", ")
        AMLogging.log("PreviewUpdate institution=\(inst ?? "nil") actions=[\(summary)]", component: "RoutingConfirmationView")
        onPreviewUpdate(eff, inst)
    }
    private func logOverrideDiff(old: [String: RoutingCandidate.Action], new: [String: RoutingCandidate.Action]) {
        var changes: [String] = []
        let keys = Set(old.keys).union(new.keys)
        for k in keys.sorted() {
            let ov = old[k]
            let nv = new[k]
            if ov == nv { continue }
            let od = ov.map { describe($0) } ?? "nil"
            let nd = nv.map { describe($0) } ?? "nil"
            changes.append("\(k): \(od) -> \(nd)")
        }
        if !changes.isEmpty {
            AMLogging.log("overrides changed (\(changes.count)): \(changes.joined(separator: ", "))", component: "RoutingConfirmationView")
        } else {
            AMLogging.log("overrides changed (no-op)", component: "RoutingConfirmationView")
        }
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
        // Verification banner
        if !verificationIssues.isEmpty {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text("Please review your selections")
                            .font(.subheadline.weight(.semibold))
                    }
                    ForEach(Array(verificationIssues.prefix(4)), id: \.self) { issue in
                        Text("• \(issue)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if verificationIssues.count > 4 {
                        Text("…and \(verificationIssues.count - 4) more")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(8)
                .background(Color.red.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.red.opacity(0.6), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Verification issues present")
            }
        }

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
                        .textInputAutocapitalization(.words)
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
//                    let showExistingUI: Bool = (globalTargetMode == 0)

                    let eff = effectiveAction(for: plan)

                    // Header + confidence
                    HStack(alignment: .firstTextBaseline) {
                        Text(routingTitle(for: eff))
                            .font(.headline)
                        Spacer()
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
                                userSelectedTypes: $userSelectedTypes,
                                overrides: $overrides,
                                onChange: { notifyPreviewUpdate() }
                            )
                            .id("create-\(plan.id)")
                        }
                    }
                    // Force a fresh subtree when mode or institution changes (prevents stale branch reuse)
                    .id("routing-\(plan.label)-mode-\(globalTargetMode)-inst-\(selectedInstitution ?? "nil")")
                }
                // Key the row so SwiftUI tears it down/rebuilds when the mode flips
                .id("row-\(plan.label)-mode-\(globalTargetMode)")
                // Attach onChange to the VStack (a View), not to the `let` above
                .onChange(of: globalTargetMode) { _, newVal in
                    let currentBase: RoutingCandidate.Action = overrides[plan.label] ?? plan.candidate.action
                    let currentEff: RoutingCandidate.Action = effectiveAction(for: plan, newMode: newVal)
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
            .onChange(of: selectedInstitution) { _, newValue in
                // Compute once and reuse
                let instAccounts = accounts(at: newValue)
                let count = instAccounts.count

                // Prune overrides that no longer belong to the chosen institution
                for (label, action) in overrides {
                    if case .existing(let id, _) = action,
                       !instAccounts.contains(where: { $0.id == id }) {
                        overrides[label] = nil
                    }
                }

                AMLogging.log("Institution changed -> \(newValue ?? "nil"), accountsAtInst=\(count)", component: "RoutingConfirmationView")

                // Preselect per cluster by intended account type (Existing mode only)
                if globalTargetMode == 0 {
                    for p in plans {
                        // Skip if already explicitly selected
                        if case .existing = overrides[p.label] { continue }

                        // Infer intended type from candidate or label
                        let intendedType: Account.AccountType? = {
                            if case .createNew(let t) = p.candidate.action, let t { return t }
                            switch p.label.lowercased() {
                            case "checking": return .checking
                            case "savings": return .savings
                            case "credit card", "creditcard", "card": return .creditCard
                            case "loan": return .loan
                            case "brokerage": return .brokerage
                            case "cash": return .cash
                            case "property": return .property
                            default: return nil
                            }
                        }()

                        if let t = intendedType {
                            let matches = instAccounts.filter { $0.type == t } // adjust property name if needed
                            if matches.count == 1, let only = matches.first {
                                overrides[p.label] = .existing(accountID: only.id, name: only.name)
                            }
                        }
                    }
                }

                previewDebounce?.cancel()
                let work = DispatchWorkItem { notifyPreviewUpdate() }
                previewDebounce = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
            }
            .onChange(of: overrides) { old, new in
                logOverrideDiff(old: old, new: new)
                notifyPreviewUpdate()
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
                
                let currentInst = selectedInstitution ?? analysis.institution
                let count = accounts(at: currentInst).count
                AMLogging.log("onAppear institution=\(currentInst ?? "nil"), accountsAtInst=\(count)", component: "RoutingConfirmationView")
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

    // Replace the entire function with this version
    private func currentSelectedID() -> UUID? {
        let intended = intendedType()

        // 1) User override wins, but only if valid for the current institution and intended type
        if let override = overrides[plan.label], case .existing(let id, _) = override {
            if let acct = accountsAtInst.first(where: { $0.id == id }) {
                if let intended, acct.type != intended { // adjust property if not `acct.type`
                    return nil // override mismatches the cluster type
                }
                return id
            } else {
                return nil // override not visible at current institution
            }
        }

        // 2) Candidate selection: only accept if it’s visible and matches intended type (if any)
        if case .existing(let id, _) = baseAction {
            if let acct = accountsAtInst.first(where: { $0.id == id }) {
                if let intended, acct.type != intended { // adjust property if not `acct.type`
                    return nil // candidate mismatches the cluster type
                }
                return id
            }
        }

        // 3) No valid selection
        return nil
    }

    private func applySelection(_ newID: UUID?) {
        if let id = newID, let acct = accountsAtInst.first(where: { $0.id == id }) {
            overrides[plan.label] = .existing(accountID: id, name: acct.name)
        } else {
            overrides[plan.label] = nil
        }
    }
    // Disambiguation helpers moved out of the ViewBuilder
    private var nameCounts: [String: Int] {
        Dictionary(
            grouping: accountsAtInst,
            by: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
        )
        .mapValues { $0.count }
    }

    private func typeDisplay(_ type: Account.AccountType?) -> String {
        guard let t = type else { return "Unspecified" }
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

    private func titleForAccount(_ acct: Account) -> String {
        let baseName = acct.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let needsType = (nameCounts[baseName] ?? 0) > 1
        return needsType ? "\(baseName) — \(typeDisplay(acct.type))" : baseName // adjust acct.type if needed
    }
    private func intendedType() -> Account.AccountType? {
        if case .createNew(let t) = baseAction, let t { return t }
        switch plan.label.lowercased() {
        case "checking": return .checking
        case "savings": return .savings
        case "credit card", "creditcard", "card": return .creditCard
        case "loan": return .loan
        case "brokerage": return .brokerage
        case "cash": return .cash
        case "property": return .property
        default: return nil
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Existing Account", selection: Binding<UUID?>(
                get: { currentSelectedID() },
                set: { newID in
                    applySelection(newID)
                    onChange()
                }
            )) {
                // Provide a placeholder for the nil selection to avoid 'invalid tag' warnings
                if accountsAtInst.isEmpty {
                      Text("No accounts").tag(nil as UUID?)
                  } else {
                      Text("Select an account").tag(nil as UUID?)
                  }

                ForEach(accountsAtInst, id: \.id) { acct in
                    Text(titleForAccount(acct)).tag(Optional(acct.id))
                }
            }
            .pickerStyle(.menu)

            if !accountsAtInst.isEmpty && currentSelectedID() == nil {
                Text("Select an account")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if accountsAtInst.isEmpty {
                Text("No existing accounts at this institution.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            guard currentSelectedID() == nil else { return }

            // Try to infer desired account type from baseAction or cluster label
            let intendedType: Account.AccountType? = {
                if case .createNew(let t) = baseAction, let t { return t }
                switch plan.label.lowercased() {
                case "checking": return .checking
                case "savings": return .savings
                case "credit card", "creditcard", "card": return .creditCard
                case "loan": return .loan
                case "brokerage": return .brokerage
                case "cash": return .cash
                case "property": return .property
                default: return nil
                }
            }()

            if let t = intendedType {
                let matches = accountsAtInst.filter { $0.type == t } // adjust property name if needed
                if matches.count == 1, let only = matches.first {
                    applySelection(only.id)
                    onChange()
                    return
                }
            }

            // Fallback: if exactly one account is visible, select it
            if accountsAtInst.count == 1, let only = accountsAtInst.first {
                applySelection(only.id)
                onChange()
            }
        }
    }
}

private struct CreateNewSelectionRow: View {
    let plan: ImportRoutingService.RoutedClusterPlan
    let baseAction: RoutingCandidate.Action
    @Binding var newAccountNames: [String: String]
    @Binding var userSelectedTypes: [String: Account.AccountType?]
    @Binding var overrides: [String: RoutingCandidate.Action]
    let onChange: () -> Void

    private var seedType: Account.AccountType? {
        if case .createNew(let t) = baseAction { return t }
        return nil
    }
    private func applyTypeSelection(_ newType: Account.AccountType?) {
        userSelectedTypes[plan.label] = newType
        overrides[plan.label] = .createNew(type: newType)
        let desc = newType.map { displayName(for: $0) } ?? "Unspecified"
        AMLogging.log("Override[\(plan.label)] -> createNew(\(desc))", component: "RoutingConfirmationView")
        onChange()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let allTypes: [Account.AccountType] = [.checking, .savings, .creditCard, .loan, .brokerage, .cash, .property, .other]

            Picker("Account Type", selection: Binding<Account.AccountType?>(
                get: { seedType },
                set: { applyTypeSelection($0) }
            )) {
                Text("Unspecified").tag(nil as Account.AccountType?)
                ForEach(allTypes, id: \.self) { t in
                    Text(displayName(for: t)).tag(Optional<Account.AccountType>(t))
                }
            }
            .pickerStyle(.menu)

            if seedType == nil && userSelectedTypes[plan.label] == nil {
                Text("Choose a type")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

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

struct RoutingChildEditingKey: PreferenceKey {
    static var defaultValue: Bool = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = nextValue()
    }
}

#Preview {
    Text("Preview requires model data")
}
