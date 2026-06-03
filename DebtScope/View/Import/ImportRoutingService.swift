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
        func norm(_ raw: String?) -> String? {
            AccountImportMapping.normalizedLabel(raw)
        }

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
                let candidate = resolveCandidate(institution: analysis.institution, label: defaultLabel, desiredType: staged.suggestedAccountType, accounts: allAccounts, context: context)
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
    func resolveAccounts(
        for plans: [RoutedClusterPlan],
        institution: String?,
        currencyCode: String,
        context: ModelContext,
        applyInstitutionToExisting: Bool = false
    ) throws -> [String: Account] {
        var result: [String: Account] = [:]

        let trimmed = institution?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedInstitution: String? = trimmed.isEmpty ? nil : trimmed
        // De-dupe newly created accounts within this resolve run.
        // Key by (type, institution) and only reuse when plans look complementary (one has zero tx or zero balances).
        struct CreateKey: Hashable {
            let type: Account.AccountType
            let institution: String? // already trimmed/normalized above
        }
        var createdByKey: [CreateKey: (account: Account, tx: Int, bal: Int)] = [:]

        // Precompute counts per label so we can compare plans when deciding to reuse.
        let planCounts: [String: (tx: Int, bal: Int)] = Dictionary(
            uniqueKeysWithValues: plans.map { ($0.label, ($0.transactions.count, $0.balances.count)) }
        )
        for plan in plans {
            switch plan.candidate.action {
            case .createNew(let optType):
                let type = optType ?? .other
                let baseLabel = (plan.label == "__default__") ? "Account" : plan.label.capitalized
                let typeName: String = {
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
                }()

                // Prefer a human title for this cluster: label title if present, else the type
                let labelTitle = (plan.label == "__default__") ? typeName : baseLabel

                // Reuse previously created account for the same (type, institution)
                // when plans look complementary (one has zero tx or zero balances).
                let key = CreateKey(type: type, institution: normalizedInstitution)
                let currentCounts = planCounts[plan.label] ?? (tx: plan.transactions.count, bal: plan.balances.count)
                if let existing = createdByKey[key] {
                    let prevTx = existing.tx, prevBal = existing.bal
                    let complementary: Bool = (prevTx == 0 || prevBal == 0) && (currentCounts.tx == 0 || currentCounts.bal == 0)
                    if complementary {
                        result[plan.label] = existing.account
                        AMLogging.log("ImportRoutingService: reusing created account '\(existing.account.name)' for label '\(plan.label)' (complementary tx/bal)", component: "ImportRoutingService")
                        break
                    }
                }

                // Build a friendly final name: just the institution when available; otherwise fall back to label/title
                let finalName: String = {
                    if let inst = normalizedInstitution, !inst.isEmpty {
                        return inst
                    } else {
                        return labelTitle
                    }
                }()

                let acct = Account(
                    name: finalName,
                    type: type,
                    institutionName: normalizedInstitution,
                    currencyCode: currencyCode
                )
                context.insert(acct)
                AMLogging.log("RoutingDebug: resolveAccounts.createNew — label=\(plan.label) id=\(acct.id) name='\(acct.name)' type=\(acct.typeRaw) inst='\(acct.institutionName ?? "nil")'", component: "RoutingDebug")
                result[plan.label] = acct
                createdByKey[key] = (acct, currentCounts.tx, currentCounts.bal)
                AMLogging.log("ImportRoutingService: created account '\(acct.name)' inst='\(normalizedInstitution ?? "nil")' type=\(type)", component: "ImportRoutingService")
            case .existing(let accountID, _):
                // Fetch existing account by id
                let predicate = #Predicate<Account> { $0.id == accountID }
                let fd = FetchDescriptor<Account>(predicate: predicate)
                let fetched = try context.fetch(fd)
                guard let acct = fetched.first else {
                    let fallbackType = inferType(from: plan.label) ?? .other
                    let fallbackPlan = RoutedClusterPlan(
                        label: plan.label,
                        candidate: RoutingCandidate(action: .createNew(type: fallbackType), confidence: Tuning.createWithInferredType, reason: "stale-existing-fallback"),
                        transactions: plan.transactions,
                        balances: plan.balances,
                        holdings: plan.holdings
                    )
                    AMLogging.log("ImportRoutingService: stale existing target missing id=\(accountID); creating new account for label='\(plan.label)' instead", component: "ImportRoutingService")
                    let created = try resolveAccounts(
                        for: [fallbackPlan],
                        institution: institution,
                        currencyCode: currencyCode,
                        context: context,
                        applyInstitutionToExisting: applyInstitutionToExisting
                    )
                    if let replacement = created[plan.label] {
                        result[plan.label] = replacement
                        continue
                    }
                    AMLogging.error("ImportRoutingService: resolveAccounts failed — stale existing target could not be replaced id=\(accountID)", component: "ImportRoutingService")
                    struct LocalError: Error {}
                    throw LocalError()
                }
                AMLogging.log("RoutingDebug: resolveAccounts.existing BEFORE — id=\(acct.id) name='\(acct.name)' type=\(acct.typeRaw) inst='\(acct.institutionName ?? "nil")'", component: "RoutingDebug")

                if applyInstitutionToExisting, let inst = normalizedInstitution {
                    let before = (acct.institutionName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if before.isEmpty {
//                        acct.institutionName = inst
                        AMLogging.log("ImportRoutingService: filled empty institution for existing id=\(acct.id) -> '\(inst)'", component: "ImportRoutingService")
                    } else {
                        AMLogging.log("ImportRoutingService: leaving existing institution for id=\(acct.id) '\(before)'", component: "ImportRoutingService")
                    }
                } else {
                    AMLogging.log("ImportRoutingService: using existing account id=\(acct.id) name='\(acct.name)' (no institution overwrite)", component: "ImportRoutingService")
                }
                AMLogging.log("RoutingDebug: resolveAccounts.existing AFTER — id=\(acct.id) type=\(acct.typeRaw) inst='\(acct.institutionName ?? "nil")'", component: "RoutingDebug")

                result[plan.label] = acct
            }
        }
        return result
    }

    /// After saving a batch with routed items, upsert import mappings for each non-default label.
    /// Use the candidate's confidence as the mapping confidence.
    func persistMappingsAfterSave(
        institution: String?,
        labelToAccount: [String: Account],
        plans: [RoutedClusterPlan],
        context: ModelContext
    ) {
        // Normalize institution using the same helper used elsewhere
        guard let inst = AccountImportMapping.normalizedInstitution(institution), !inst.isEmpty else {
            AMLogging.log("ImportRoutingService: persistMappingsAfterSave — no institution; skipping", component: "ImportRoutingService")
            return
        }
        AMLogging.log("RoutingDebug: persistMappingsAfterSave start — inst='\(inst)' labels=\(labelToAccount.keys.count)", component: "RoutingDebug")

        // Build a lookup of normalized label -> candidate confidence from the provided plans
        // so we can persist a meaningful confidence instead of a hardcoded 1.0
        let confidenceByLabel: [String: Double] = {
            var dict: [String: Double] = [:]
            for p in plans {
                if let lab = AccountImportMapping.normalizedLabel(p.label) {
                    dict[lab] = clamp(p.candidate.confidence)
                }
            }
            return dict
        }()

        for (rawLabel, account) in labelToAccount {
            // Normalize the label; skip empty and synthetic default labels
            guard let normalizedLabel = AccountImportMapping.normalizedLabel(rawLabel),
                  !normalizedLabel.isEmpty,
                  normalizedLabel != "__default__" else { continue }

            // Use the plan-derived confidence when available; otherwise a reasonable default
            let conf = confidenceByLabel[normalizedLabel] ?? clamp(0.9)

            do {
                let existing = try context.fetch(
                    FetchDescriptor<AccountImportMapping>(
                        predicate: #Predicate { $0.institutionName == inst && $0.subaccountLabel == normalizedLabel }
                    )
                ).first
                let existed = (existing != nil)
                AMLogging.log("RoutingDebug: upsert mapping — inst='\(inst)' label='\(normalizedLabel)' accountID=\(account.id) conf=\(conf) existed=\(existed)", component: "RoutingDebug")

                if let map = existing {
                    map.accountID = account.id
                    map.confidence = conf
                } else {
                    let map = AccountImportMapping(
                        institutionName: inst,
                        subaccountLabel: normalizedLabel,
                        accountID: account.id,
                        confidence: conf
                    )
                    context.insert(map)
                }
            } catch {
                AMLogging.error("ImportRoutingService: persistMappingsAfterSave fetch failed — \(error.localizedDescription)", component: "ImportRoutingService")
            }
        }

        do {
            try context.save()
            AMLogging.log("RoutingDebug: persistMappingsAfterSave complete", component: "RoutingDebug")
        } catch {
            AMLogging.error("ImportRoutingService: persistMappingsAfterSave save failed — \(error.localizedDescription)", component: "ImportRoutingService")
        }
    }

    // First-pass detection: group by subaccount label, look up mapping, and propose a candidate
    func analyze(staged: StagedImport, context: ModelContext) -> RoutingAnalysis {
        let institution = AccountImportMapping.normalizedInstitution(staged.inferredInstitutionName ?? guessInstitutionName(from: staged.sourceFileName))

        // Collect labels from transactions and balances. Mixed statements can legitimately contain
        // multiple account types (for example, a savings account plus a loan on one PDF), so keep
        // each normalized source label distinct for routing.
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

            let candidate = resolveCandidate(institution: institution, label: label, desiredType: staged.suggestedAccountType, accounts: allAccounts, context: context)
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

    private func resolveCandidate(institution: String?, label: String, desiredType: Account.AccountType?, accounts: [Account], context: ModelContext) -> RoutingCandidate {
        let accountSummary = accounts.map { "\($0.name)[\($0.id.uuidString.prefix(4))]:\($0.type.rawValue):\($0.institutionName ?? "nil")" }.joined(separator: ", ")
        AMLogging.log(
            "ImportRoutingService: resolveCandidate start — inst='\(institution ?? "nil")' label='\(label)' desiredType='\(desiredType?.rawValue ?? "nil")' accounts=[\(accountSummary)]",
            component: "ImportRoutingService"
        )

        // 1) Exact mapping lookup by institution + label.
        // If the remembered target account was deleted, discard the stale memory and fall through
        // to normal heuristics so the next import proposes a fresh account instead of a ghost.
        if let inst = institution, let mapping = try? fetchMapping(inst: inst, label: label, context: context) {
            if let acct = accounts.first(where: { $0.id == mapping.accountID }) {
                if desiredType == nil || acct.type == desiredType {
                    AMLogging.log("ImportRoutingService: resolveCandidate chose existing via mapping — label='\(label)' account='\(acct.name)' id=\(acct.id)", component: "ImportRoutingService")
                    return RoutingCandidate(action: .existing(accountID: acct.id, name: acct.name), confidence: clamp(mapping.confidence), reason: "mapping")
                }
            } else {
                context.delete(mapping)
                try? context.save()
                AMLogging.log("ImportRoutingService: removed stale mapping — inst='\(inst)' label='\(label)' missingAccountID=\(mapping.accountID)", component: "ImportRoutingService")
            }
        }

        // 2) Heuristic: infer type from label and look for matching accounts at the same institution
        let inferredType = inferType(from: label) ?? desiredType
        let matchesAtInstitution: [Account] = {
            guard let instKey = normalizedInstitutionKey(institution), !instKey.isEmpty else { return [] }
            return accounts.filter {
                normalizedInstitutionKey($0.institutionName) == instKey
            }
        }()

        if let t = inferredType {
            let typed = matchesAtInstitution.filter { $0.type == t }
            if typed.count == 1, let acct = typed.first {
                AMLogging.log("ImportRoutingService: resolveCandidate chose existing via type+institution — label='\(label)' account='\(acct.name)' id=\(acct.id)", component: "ImportRoutingService")
                return RoutingCandidate(action: .existing(accountID: acct.id, name: acct.name), confidence: Tuning.typeAndInstitutionSingleMatch, reason: "heuristic:type+institution")
            } else if typed.count > 1 {
                // Ambiguous same-type accounts at the institution
                AMLogging.log("ImportRoutingService: resolveCandidate chose create-new because type+institution is ambiguous — label='\(label)' matches=\(typed.count)", component: "ImportRoutingService")
                return RoutingCandidate(action: .createNew(type: t), confidence: Tuning.ambiguousTypeAtInstitution, reason: "ambiguous:type+institution")
            } else {
                // No existing; propose creating new with inferred type
                AMLogging.log("ImportRoutingService: resolveCandidate chose create-new because no type+institution match exists — label='\(label)' inferredType='\(t.rawValue)'", component: "ImportRoutingService")
                return RoutingCandidate(action: .createNew(type: t), confidence: Tuning.createWithInferredType, reason: "create:type")
            }
        }

        // 3) Fallbacks: use institution-only match, otherwise create new without type
        if let acct = matchesAtInstitution.sorted(by: { $0.createdAt > $1.createdAt }).first {
            AMLogging.log("ImportRoutingService: resolveCandidate chose existing via institution-only — label='\(label)' account='\(acct.name)' id=\(acct.id)", component: "ImportRoutingService")
            return RoutingCandidate(action: .existing(accountID: acct.id, name: acct.name), confidence: Tuning.institutionOnlyMatch, reason: "heuristic:institution-only")
        }

        AMLogging.log("ImportRoutingService: resolveCandidate chose create-new fallback — label='\(label)'", component: "ImportRoutingService")
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
