import Foundation
import SwiftData

// MARK: - Routing Models

struct RoutingCandidate: Identifiable, Hashable {
    enum Action: Hashable {
        case existing(accountID: UUID, name: String)
        case createNew(type: Account.AccountType?)
    }
    public let id = UUID()
    public let action: Action
    public let confidence: Double
    public let reason: String
}

struct RoutingCluster: Identifiable, Hashable {
    public let id = UUID()
    public let label: String // normalized label key for this cluster
    public let transactionsCount: Int
    public let balancesCount: Int
    public let candidate: RoutingCandidate
}

struct RoutingAnalysis: Hashable {
    public let institution: String?
    public let clusters: [RoutingCluster]
    public let needsConfirmation: Bool
}

// MARK: - Service

final class ImportRoutingService {
    init() {}

    // MARK: - Tuning (confidence thresholds & heuristics)
    struct Tuning {
        // If any cluster candidate falls below this, require confirmation
        static var lowConfidenceCutoff: Double = 0.75

        // Heuristic confidences (adjust as real-world data is gathered)
        static var typeAndInstitutionSingleMatch: Double = 0.80
        static var ambiguousTypeAtInstitution: Double = 0.55
        static var createWithInferredType: Double = 0.65
        static var institutionOnlyMatch: Double = 0.60
        static var fallbackCreate: Double = 0.45
    }

    // MARK: - Execution Models

    struct RoutedClusterPlan: Identifiable, Hashable {
        var id: String { label }          // <- stable identity
        let label: String
        let candidate: RoutingCandidate
        let transactions: [StagedTransaction]
        let balances: [StagedBalance]
        let holdings: [StagedHolding]
    }

    /// Build executable routing plans from a staged import by clustering on the same
    /// normalized label logic used in `analyze(staged:context:)`.
    /// - Returns: The analysis used plus one plan per cluster label.
    func buildPlans(staged: StagedImport, context: ModelContext) -> (analysis: RoutingAnalysis, plans: [RoutedClusterPlan]) {
        let analysis = analyze(staged: staged, context: context)

        // Prepare grouped items per normalized label
        let defaultKey = "__default__"
        func norm(_ raw: String?) -> String? { AccountImportMapping.normalizedLabel(raw) }

        // Materialize once to avoid repeated normalization work
        let txByLabel: [String: [StagedTransaction]] = {
            var buckets: [String: [StagedTransaction]] = [:]
            for t in staged.transactions {
                let key = norm(t.sourceAccountLabel) ?? defaultKey
                buckets[key, default: []].append(t)
            }
            return buckets
        }()
        let balByLabel: [String: [StagedBalance]] = {
            var buckets: [String: [StagedBalance]] = [:]
            for b in staged.balances {
                let key = norm(b.sourceAccountLabel) ?? defaultKey
                buckets[key, default: []].append(b)
            }
            return buckets
        }()

        // Holdings generally have no per-subaccount label; if there's exactly one cluster,
        // place them with that cluster, otherwise leave unassigned and prefer the default bucket.
        let holdingsAll: [StagedHolding] = staged.holdings
        let singleClusterLabel: String? = (analysis.clusters.count == 1 ? analysis.clusters.first?.label : nil)

        var plans: [RoutedClusterPlan] = []
        for cluster in analysis.clusters {
            let label = cluster.label
            let tx = txByLabel[label] ?? []
            let bal = balByLabel[label] ?? []
            let holds: [StagedHolding] = (singleClusterLabel == label) ? holdingsAll : []
            plans.append(RoutedClusterPlan(label: label, candidate: cluster.candidate, transactions: tx, balances: bal, holdings: holds))
        }

        // If there are holdings and no single cluster captured them, attach them to the default bucket
        if !holdingsAll.isEmpty, singleClusterLabel == nil {
            let defaultLabel = defaultKey
            if !plans.contains(where: { $0.label == defaultLabel }) {
                // create a synthetic plan for default if not present
                let allAccounts: [Account] = (try? context.fetch(FetchDescriptor<Account>())) ?? []
                let candidate = resolveCandidate(institution: analysis.institution, label: defaultLabel, accounts: allAccounts, context: context)
                plans.append(RoutedClusterPlan(label: defaultLabel, candidate: candidate, transactions: txByLabel[defaultLabel] ?? [], balances: balByLabel[defaultLabel] ?? [], holdings: holdingsAll))
            } else {
                // merge holdings into the existing default plan
                if let idx = plans.firstIndex(where: { $0.label == defaultLabel }) {
                    let existing = plans[idx]
                    plans[idx] = RoutedClusterPlan(label: existing.label, candidate: existing.candidate, transactions: existing.transactions, balances: existing.balances, holdings: holdingsAll)
                }
            }
        }

        return (analysis, plans)
    }

    /// Resolve or create Accounts for each routed plan.
    /// - Parameters:
    ///   - plans: Plans built by `buildPlans`.
    ///   - institution: Optional normalized institution name to assign to newly created accounts.
    ///   - currencyCode: Currency code for new accounts.
    /// - Returns: A dictionary mapping normalized label -> Account.
    func resolveAccounts(for plans: [RoutedClusterPlan], institution: String?, currencyCode: String, context: ModelContext) throws -> [String: Account] {
        var result: [String: Account] = [:]
        let allAccounts: [Account] = (try? context.fetch(FetchDescriptor<Account>())) ?? []

        func displayName(for type: Account.AccountType?) -> String {
            guard let t = type else { return "Account" }
            switch t {
            case .checking: return "Checking"
            case .savings: return "Savings"
            case .creditCard: return "Credit Card"
            case .loan: return "Loan"
            case .brokerage: return "Brokerage"
            case .cash: return "Cash"
            default: return t.rawValue.capitalized
            }
        }

        for plan in plans {
            // Prefer existing account when candidate points to one
            switch plan.candidate.action {
            case .existing(let accountID, _):
                if let acct = allAccounts.first(where: { $0.id == accountID }) {
                    result[plan.label] = acct
                    continue
                }

                // If the referenced account isn't found, try to prefer an existing match before creating
                let desiredType: Account.AccountType? = inferType(from: plan.label)
                if let preferred = preferExistingAccount(allAccounts: allAccounts, institution: institution, sourceLabel: plan.label, desiredType: desiredType) {
                    result[plan.label] = preferred
                    continue
                }

                // No suitable existing account found; create a new one
                let inferred = desiredType ?? .other
                let inst = AccountImportMapping.normalizedInstitution(institution)

                // Build a reasonable default name and ensure it doesn't collide
                let baseName: String = {
                    if let i = inst, !i.isEmpty { return "\(i) \(displayName(for: inferred))" }
                    return "Imported \(displayName(for: inferred))"
                }()
                var name = baseName
                var suffix = 2
                while allAccounts.contains(where: { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
                    name = "\(baseName) \(suffix)"
                    suffix += 1
                }

                let acct = Account(name: name, type: inferred, institutionName: inst, currencyCode: currencyCode)
                context.insert(acct)
                result[plan.label] = acct

            case .createNew(let optType):
                // Determine a type for the new account and try to prefer an existing match first
                let desiredType = optType ?? inferType(from: plan.label)
                if let preferred = preferExistingAccount(allAccounts: allAccounts, institution: institution, sourceLabel: plan.label, desiredType: desiredType) {
                    result[plan.label] = preferred
                    continue
                }

                // No suitable existing account found; create a new one
                let inferred = desiredType ?? .other
                let inst = AccountImportMapping.normalizedInstitution(institution)

                // Build a reasonable default name and ensure it doesn't collide
                let baseName: String = {
                    if let i = inst, !i.isEmpty { return "\(i) \(displayName(for: inferred))" }
                    return "Imported \(displayName(for: inferred))"
                }()
                var name = baseName
                var suffix = 2
                while allAccounts.contains(where: { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
                    name = "\(baseName) \(suffix)"
                    suffix += 1
                }

                let acct = Account(name: name, type: inferred, institutionName: inst, currencyCode: currencyCode)
                context.insert(acct)
                result[plan.label] = acct
            }
        }

        try? context.save()
        return result
    }

    /// After saving a batch with routed items, upsert import mappings for each non-default label.
    /// Use the candidate's confidence as the mapping confidence.
    func persistMappingsAfterSave(institution: String?, labelToAccount: [String: Account], plans: [RoutedClusterPlan], context: ModelContext) {
        let defaultKey = "__default__"
        for plan in plans {
            guard plan.label != defaultKey, let acct = labelToAccount[plan.label] else { continue }
            upsertMapping(institution: institution, label: plan.label, accountID: acct.id, confidence: plan.candidate.confidence, context: context)
        }
    }

    // First-pass detection: group by subaccount label, look up mapping, and propose a candidate
    func analyze(staged: StagedImport, context: ModelContext) -> RoutingAnalysis {
        let institution = AccountImportMapping.normalizedInstitution(staged.inferredInstitutionName ?? guessInstitutionName(from: staged.sourceFileName))

        // Collect labels from transactions and balances
        let txLabels = Set(staged.transactions.compactMap { AccountImportMapping.normalizedLabel($0.sourceAccountLabel) })
        let balLabels = Set(staged.balances.compactMap { AccountImportMapping.normalizedLabel($0.sourceAccountLabel) })
        var labels = Array(txLabels.union(balLabels))
        labels.sort()

        // Fallback: if no labels found, use a single synthetic label so the flow still works
        if labels.isEmpty {
            labels = ["__default__"]
        }

        // Fetch accounts once for heuristics
        let allAccounts: [Account] = (try? context.fetch(FetchDescriptor<Account>())) ?? []

        var clusters: [RoutingCluster] = []
        for label in labels {
            let txCount = staged.transactions.filter { AccountImportMapping.normalizedLabel($0.sourceAccountLabel) == label }.count
            let balCount = staged.balances.filter { AccountImportMapping.normalizedLabel($0.sourceAccountLabel) == label }.count

            let candidate = resolveCandidate(institution: institution, label: label, accounts: allAccounts, context: context)
            clusters.append(RoutingCluster(label: label, transactionsCount: txCount, balancesCount: balCount, candidate: candidate))
        }

        // Decide if we need confirmation: multiple clusters or any low confidence
        let needsConfirmation: Bool = {
            if clusters.count > 1 { return true }
            let low = clusters.contains { $0.candidate.confidence < Tuning.lowConfidenceCutoff }
            return low
        }()

        return RoutingAnalysis(institution: institution, clusters: clusters, needsConfirmation: needsConfirmation)
    }

    // Upsert a mapping after a successful import routing
    func upsertMapping(institution: String?, label: String, accountID: UUID, confidence: Double, context: ModelContext) {
        guard let inst = AccountImportMapping.normalizedInstitution(institution), let lab = AccountImportMapping.normalizedLabel(label) else { return }
        do {
            let existing = try fetchMapping(inst: inst, label: lab, context: context)
            if let m = existing {
                m.accountID = accountID
                m.confidence = clamp(confidence)
            } else {
                let m = AccountImportMapping(institutionName: inst, subaccountLabel: lab, accountID: accountID, confidence: clamp(confidence))
                context.insert(m)
            }
            try? context.save()
        } catch {
            // Ignore errors for first pass
        }
    }

    /// Apply user-selected overrides to routed plans by replacing the candidate action per label.
    /// Any labels not present in overrides keep their original candidate.
    func applyOverrides(to plans: [RoutedClusterPlan], overrides: [String: RoutingCandidate.Action]) -> [RoutedClusterPlan] {
        return plans.map { plan in
            if let action = overrides[plan.label] {
                let newCandidate = RoutingCandidate(action: action, confidence: plan.candidate.confidence, reason: "user-override")
                return RoutedClusterPlan(label: plan.label, candidate: newCandidate, transactions: plan.transactions, balances: plan.balances, holdings: plan.holdings)
            }
            return plan
        }
    }

    // MARK: - Private Helpers
    /// Case-insensitive, punctuation-agnostic normalization suitable for matching.
    private func normalizedInstitutionKey(_ raw: String?) -> String? {
        guard let raw = raw, !raw.isEmpty else { return nil }
        let folded = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let filteredScalars = folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        let joined = String(String.UnicodeScalarView(filteredScalars))
        return joined.isEmpty ? nil : joined
    }

    /// Prefer an existing account using a series of heuristics:
    /// 1) Exact normalized institution + type match (single result)
    /// 2) Looser contains match on normalized institution within the given type (single result)
    /// 3) Label keyword hints against account name/institution within desired type, otherwise any (single best)
    /// 4) Single-type fallback if there's only one account of the desired type
    private func preferExistingAccount(allAccounts: [Account], institution: String?, sourceLabel: String, desiredType: Account.AccountType?) -> Account? {
        let instKey = normalizedInstitutionKey(institution)

        // 1) Exact normalized institution + type
        if let t = desiredType, let key = instKey {
            let typedAtInst = allAccounts.filter { $0.type == t && normalizedInstitutionKey($0.institutionName) == key }
            if typedAtInst.count == 1 { return typedAtInst[0] }
        }

        // 2) Looser contains match on normalized institution within the given type
        if let t = desiredType, let key = instKey {
            let looseTyped = allAccounts.filter { acct in
                guard acct.type == t, let acctKey = normalizedInstitutionKey(acct.institutionName) else { return false }
                return acctKey.contains(key) || key.contains(acctKey)
            }
            if looseTyped.count == 1 { return looseTyped[0] }
        }

        // 3) Label keyword hints against account name/institution
        let tokens: [String] = sourceLabel
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 3 }

        func matchesTokens(_ acct: Account) -> Int {
            let name = acct.name.lowercased()
            let inst = (acct.institutionName ?? "").lowercased()
            var score = 0
            for t in tokens {
                if name.contains(t) || inst.contains(t) { score += 1 }
            }
            return score
        }

        if !tokens.isEmpty {
            let candidates: [Account] = {
                if let t = desiredType { return allAccounts.filter { $0.type == t } }
                return allAccounts
            }()

            let scored = candidates.map { (acct: $0, score: matchesTokens($0)) }
            let maxScore = scored.map { $0.score }.max() ?? 0
            if maxScore > 0 {
                let top = scored.filter { $0.score == maxScore }.map { $0.acct }
                if top.count == 1 { return top[0] }
            }
        }

        // 4) Single-type fallback
        if let t = desiredType {
            let typed = allAccounts.filter { $0.type == t }
            if typed.count == 1 { return typed[0] }
        }

        return nil
    }

    // MARK: - Internals

    private func resolveCandidate(institution: String?, label: String, accounts: [Account], context: ModelContext) -> RoutingCandidate {
        // 1) Exact mapping lookup by institution + label
        if let inst = institution, let mapping = try? fetchMapping(inst: inst, label: label, context: context),
           let acct = accounts.first(where: { $0.id == mapping.accountID }) {
            return RoutingCandidate(action: .existing(accountID: acct.id, name: acct.name), confidence: clamp(mapping.confidence), reason: "mapping")
        }

        // 2) Heuristic: infer type from label and look for matching accounts at the same institution
        let inferredType = inferType(from: label)
        let matchesAtInstitution: [Account] = {
            guard let instKey = normalizedInstitutionKey(institution), !instKey.isEmpty else { return [] }
            return accounts.filter {
                normalizedInstitutionKey($0.institutionName) == instKey
            }
        }()

        if let t = inferredType {
            let typed = matchesAtInstitution.filter { $0.type == t }
            if typed.count == 1, let acct = typed.first {
                return RoutingCandidate(action: .existing(accountID: acct.id, name: acct.name), confidence: Tuning.typeAndInstitutionSingleMatch, reason: "heuristic:type+institution")
            } else if typed.count > 1 {
                // Ambiguous same-type accounts at the institution
                return RoutingCandidate(action: .createNew(type: t), confidence: Tuning.ambiguousTypeAtInstitution, reason: "ambiguous:type+institution")
            } else {
                // No existing; propose creating new with inferred type
                return RoutingCandidate(action: .createNew(type: t), confidence: Tuning.createWithInferredType, reason: "create:type")
            }
        }

        // 3) Fallbacks: use institution-only match, otherwise create new without type
        if let acct = matchesAtInstitution.sorted(by: { $0.createdAt > $1.createdAt }).first {
            return RoutingCandidate(action: .existing(accountID: acct.id, name: acct.name), confidence: Tuning.institutionOnlyMatch, reason: "heuristic:institution-only")
        }

        return RoutingCandidate(action: .createNew(type: nil), confidence: Tuning.fallbackCreate, reason: "fallback:create")
    }

    private func inferType(from label: String) -> Account.AccountType? {
        let lower = label.lowercased()
        if lower.contains("checking") || lower.contains("chkg") || lower.contains("chk") { return .checking }
        if lower.contains("savings") || lower.contains("save") || lower.contains("sav") || lower.contains("money market") || lower.contains("mm") { return .savings }
        if lower.contains("credit") || lower.contains("cc") { return .creditCard }
        if lower.contains("hsa") { return .other }
        if lower.contains("cd") { return .savings }
        if lower.contains("loan") || lower.contains("mortgage") || lower.contains("heloc") { return .loan }
        if lower.contains("brokerage") || lower.contains("investment") || lower.contains("ira") || lower.contains("roth") { return .brokerage }
        if lower.contains("cash") { return .cash }
        return nil
    }

    private func fetchMapping(inst: String, label: String, context: ModelContext) throws -> AccountImportMapping? {
        let pred = #Predicate<AccountImportMapping> { m in
            m.institutionName == inst && m.subaccountLabel == label
        }
        var desc = FetchDescriptor<AccountImportMapping>(predicate: pred)
        desc.fetchLimit = 1
        return try context.fetch(desc).first
    }

    private func clamp(_ v: Double) -> Double { max(0.0, min(1.0, v)) }

    // Minimal duplication of the app-level guessInstitutionName for first pass
    private func guessInstitutionName(from fileName: String) -> String? {
        let base = (fileName as NSString).deletingPathExtension
        let lower = base.lowercased()
        let normalized = lower
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")

        let known: [(pattern: String, display: String)] = [
            ("americanexpress", "American Express"),
            ("amex", "American Express"),
            ("bankofamerica", "Bank of America"),
            ("boa", "Bank of America"),
            ("wellsfargo", "Wells Fargo"),
            ("capitalone", "Capital One"),
            ("capone", "Capital One"),
            ("charlesschwab", "Charles Schwab"),
            ("schwab", "Charles Schwab"),
            ("fidelity", "Fidelity"),
            ("vanguard", "Vanguard"),
            ("robinhood", "Robinhood"),
            ("discover", "Discover"),
            ("citibank", "Citi"),
            ("citi", "Citi"),
            ("chase", "Chase"),
            ("sofi", "SoFi")
        ]
        if let match = known.first(where: { normalized.contains($0.pattern) }) {
            return match.display
        }
        return nil
    }
}

