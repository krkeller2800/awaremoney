@preconcurrency import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

enum DebtScopeSpotlightIndexer {
    private static let sectionDomainIdentifier = "com.debtscope.spotlight.sections"
    private static let sensitiveDomainIdentifier = "com.debtscope.spotlight.sensitive"
    private static let sectionIdentifierPrefix = "debtscope.section."
    private static let accountIdentifierPrefix = "debtscope.account."
    private static let billIdentifierPrefix = "debtscope.bill."
    private static let transactionIdentifierPrefix = "debtscope.transaction."
    private static let debtPayoffIdentifierPrefix = "debtscope.debtPayoff."

    private static var index: CSSearchableIndex {
        CSSearchableIndex(name: "DebtScopeSpotlightIndex")
    }

    @MainActor
    static func refreshIndex(allowsSensitiveFinancialIndexing: Bool) {
        refreshGenericSections()

        if !allowsSensitiveFinancialIndexing {
            removeSensitiveFinancialItems(reason: "sensitive financial indexing disabled")
        }
    }

    @MainActor
    static func refreshIndex(allowsSensitiveFinancialIndexing: Bool, accounts: [Account]) {
        guard CSSearchableIndex.isIndexingAvailable() else {
            AMLogging.log("Spotlight indexing unavailable", component: "Spotlight")
            return
        }

        refreshGenericSections()

        if allowsSensitiveFinancialIndexing {
            indexSensitiveFinancialItems(
                options: DebtScopeSpotlightIndexingOptions(
                    allowsSensitiveFinancialIndexing: true,
                    includesAccountNames: true,
                    includesBillNames: false,
                    includesTransactionPayees: false,
                    includesDebtPayoffNames: false
                ),
                accounts: accounts,
                cashFlowItems: [],
                transactions: []
            )
        } else {
            removeSensitiveFinancialItems(reason: "sensitive financial indexing disabled")
        }
    }

    @MainActor
    static func refreshIndex(
        options: DebtScopeSpotlightIndexingOptions,
        accounts: [Account],
        cashFlowItems: [CashFlowItem],
        transactions: [Transaction]
    ) {
        guard CSSearchableIndex.isIndexingAvailable() else {
            AMLogging.log("Spotlight indexing unavailable", component: "Spotlight")
            return
        }

        refreshGenericSections()

        if options.allowsSensitiveFinancialIndexing {
            indexSensitiveFinancialItems(
                options: options,
                accounts: accounts,
                cashFlowItems: cashFlowItems,
                transactions: transactions
            )
        } else {
            removeSensitiveFinancialItems(reason: "sensitive financial indexing disabled")
        }
    }

    static func section(from searchableItemIdentifier: String) -> DebtScopeAppSection? {
        guard searchableItemIdentifier.hasPrefix(sectionIdentifierPrefix) else { return nil }
        let rawValue = String(searchableItemIdentifier.dropFirst(sectionIdentifierPrefix.count))
        return DebtScopeAppSection(rawValue: rawValue)
    }

    static func accountID(from searchableItemIdentifier: String) -> UUID? {
        guard searchableItemIdentifier.hasPrefix(accountIdentifierPrefix) else { return nil }
        let rawValue = String(searchableItemIdentifier.dropFirst(accountIdentifierPrefix.count))
        return UUID(uuidString: rawValue)
    }

    static func billID(from searchableItemIdentifier: String) -> UUID? {
        guard searchableItemIdentifier.hasPrefix(billIdentifierPrefix) else { return nil }
        let rawValue = String(searchableItemIdentifier.dropFirst(billIdentifierPrefix.count))
        return UUID(uuidString: rawValue)
    }

    static func transactionID(from searchableItemIdentifier: String) -> UUID? {
        guard searchableItemIdentifier.hasPrefix(transactionIdentifierPrefix) else { return nil }
        let rawValue = String(searchableItemIdentifier.dropFirst(transactionIdentifierPrefix.count))
        return UUID(uuidString: rawValue)
    }

    static func debtPayoffAccountID(from searchableItemIdentifier: String) -> UUID? {
        guard searchableItemIdentifier.hasPrefix(debtPayoffIdentifierPrefix) else { return nil }
        let rawValue = String(searchableItemIdentifier.dropFirst(debtPayoffIdentifierPrefix.count))
        return UUID(uuidString: rawValue)
    }

    @MainActor
    private static func refreshGenericSections() {
        guard CSSearchableIndex.isIndexingAvailable() else {
            AMLogging.log("Spotlight indexing unavailable", component: "Spotlight")
            return
        }

        let items = DebtScopeAppSection.spotlightIndexedSections.map(searchableItem)
        let itemCount = items.count
        index.indexSearchableItems(items) { error in
            if let error {
                AMLogging.error("Failed to index generic app sections: \(error.localizedDescription)", component: "Spotlight")
            } else {
                AMLogging.log("Indexed \(itemCount) generic app sections", component: "Spotlight")
            }
        }
    }

    @MainActor
    private static func searchableItem(for section: DebtScopeAppSection) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .item)
        attributes.title = section.displayTitle
        attributes.displayName = section.displayTitle
        attributes.contentDescription = section.spotlightDescription
        attributes.keywords = section.spotlightKeywords

        let item = CSSearchableItem(
            uniqueIdentifier: spotlightIdentifier(for: section),
            domainIdentifier: sectionDomainIdentifier,
            attributeSet: attributes
        )
        item.expirationDate = .distantFuture
        return item
    }

    @MainActor
    private static func searchableItem(for account: Account) -> CSSearchableItem? {
        let displayName = account.spotlightDisplayName
        guard !displayName.isEmpty else { return nil }

        let attributes = CSSearchableItemAttributeSet(contentType: .item)
        attributes.title = displayName
        attributes.displayName = displayName
        attributes.contentDescription = account.spotlightDescription
        attributes.keywords = account.spotlightKeywords

        let item = CSSearchableItem(
            uniqueIdentifier: spotlightIdentifier(for: account),
            domainIdentifier: sensitiveDomainIdentifier,
            attributeSet: attributes
        )
        item.expirationDate = .distantFuture
        return item
    }

    @MainActor
    private static func searchableItem(for bill: CashFlowItem) -> CSSearchableItem? {
        let displayName = bill.spotlightDisplayName
        guard !displayName.isEmpty else { return nil }

        let attributes = CSSearchableItemAttributeSet(contentType: .item)
        attributes.title = displayName
        attributes.displayName = displayName
        attributes.contentDescription = "Bill in DebtScope."
        attributes.keywords = ["bill", "bills", "upcoming", "DebtScope"]

        let item = CSSearchableItem(
            uniqueIdentifier: billIdentifierPrefix + bill.id.uuidString,
            domainIdentifier: sensitiveDomainIdentifier,
            attributeSet: attributes
        )
        item.expirationDate = .distantFuture
        return item
    }

    @MainActor
    private static func searchableItem(for transaction: Transaction) -> CSSearchableItem? {
        let displayName = transaction.spotlightPayeeName
        guard !displayName.isEmpty else { return nil }

        let attributes = CSSearchableItemAttributeSet(contentType: .item)
        attributes.title = displayName
        attributes.displayName = displayName
        attributes.contentDescription = "Transaction payee in DebtScope."
        attributes.keywords = ["transaction", "payee", transaction.kind.rawValue, "DebtScope"]

        let item = CSSearchableItem(
            uniqueIdentifier: transactionIdentifierPrefix + transaction.id.uuidString,
            domainIdentifier: sensitiveDomainIdentifier,
            attributeSet: attributes
        )
        item.expirationDate = .distantFuture
        return item
    }

    @MainActor
    private static func debtPayoffSearchableItem(for account: Account) -> CSSearchableItem? {
        let displayName = account.spotlightDisplayName
        guard !displayName.isEmpty, account.isLiability else { return nil }

        let attributes = CSSearchableItemAttributeSet(contentType: .item)
        attributes.title = displayName
        attributes.displayName = displayName
        attributes.contentDescription = "Debt payoff item in DebtScope."
        attributes.keywords = ["debt", "payoff", "liability", account.typeRaw, "DebtScope"]

        let item = CSSearchableItem(
            uniqueIdentifier: debtPayoffIdentifierPrefix + account.id.uuidString,
            domainIdentifier: sensitiveDomainIdentifier,
            attributeSet: attributes
        )
        item.expirationDate = .distantFuture
        return item
    }

    private static func spotlightIdentifier(for section: DebtScopeAppSection) -> String {
        sectionIdentifierPrefix + section.rawValue
    }

    private static func spotlightIdentifier(for account: Account) -> String {
        accountIdentifierPrefix + account.id.uuidString
    }

    @MainActor
    private static func indexSensitiveFinancialItems(
        options: DebtScopeSpotlightIndexingOptions,
        accounts: [Account],
        cashFlowItems: [CashFlowItem],
        transactions: [Transaction]
    ) {
        var items: [CSSearchableItem] = []

        if options.includesAccountNames {
            items.append(contentsOf: accounts.compactMap(searchableItem))
        }

        if options.includesBillNames {
            let bills = cashFlowItems.filter { $0.kindRaw == CashFlowItem.Kind.bill.rawValue }
            items.append(contentsOf: bills.compactMap(searchableItem))
        }

        if options.includesTransactionPayees {
            items.append(contentsOf: deduplicatedTransactionsByPayee(transactions).compactMap(searchableItem))
        }

        if options.includesDebtPayoffNames {
            items.append(contentsOf: accounts.compactMap(debtPayoffSearchableItem))
        }

        let itemCount = items.count
        index.deleteSearchableItems(withDomainIdentifiers: [sensitiveDomainIdentifier]) { deleteError in
            if let deleteError {
                AMLogging.error("Failed to clear sensitive Spotlight items before reindexing: \(deleteError.localizedDescription)", component: "Spotlight")
                return
            }

            guard !items.isEmpty else {
                AMLogging.log("Sensitive Spotlight domain cleared: no selected financial labels to index", component: "Spotlight")
                return
            }

            index.indexSearchableItems(items) { indexError in
                if let indexError {
                    AMLogging.error("Failed to index financial label Spotlight items: \(indexError.localizedDescription)", component: "Spotlight")
                } else {
                    AMLogging.log("Indexed \(itemCount) financial label Spotlight items", component: "Spotlight")
                }
            }
        }
    }

    @MainActor
    private static func deduplicatedTransactionsByPayee(_ transactions: [Transaction]) -> [Transaction] {
        var seenPayees: Set<String> = []
        var deduplicated: [Transaction] = []

        for transaction in transactions {
            let normalizedPayee = transaction.spotlightPayeeName.lowercased()
            guard !normalizedPayee.isEmpty, !seenPayees.contains(normalizedPayee) else { continue }
            seenPayees.insert(normalizedPayee)
            deduplicated.append(transaction)
        }

        return deduplicated
    }

    private static func removeSensitiveFinancialItems(reason: String) {
        index.deleteSearchableItems(withDomainIdentifiers: [sensitiveDomainIdentifier]) { error in
            if let error {
                AMLogging.error("Failed to remove sensitive Spotlight items: \(error.localizedDescription)", component: "Spotlight")
            } else {
                AMLogging.log("Sensitive Spotlight domain cleared: \(reason)", component: "Spotlight")
            }
        }
    }
}

@MainActor
private extension Account {
    var spotlightDisplayName: String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            return trimmedName
        }

        return institutionName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var spotlightDescription: String {
        let typeName = typeRaw.capitalized
        guard let institutionName = institutionName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !institutionName.isEmpty,
              institutionName != spotlightDisplayName else {
            return "\(typeName) account in DebtScope."
        }

        return "\(typeName) account at \(institutionName) in DebtScope."
    }

    var spotlightKeywords: [String] {
        var keywords = ["account", typeRaw, typeRaw.capitalized, "DebtScope"]
        if let institutionName = institutionName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !institutionName.isEmpty {
            keywords.append(institutionName)
        }
        return keywords
    }
}

@MainActor
private extension CashFlowItem {
    var spotlightDisplayName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
private extension Transaction {
    var spotlightPayeeName: String {
        payee.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension DebtScopeAppSection {
    static let spotlightIndexedSections: [DebtScopeAppSection] = [
        .debtSummary,
        .upcomingBills,
        .assistant,
        .debtPayoffPlan
    ]

    var displayTitle: String {
        switch self {
        case .debtSummary:
            return "Debt Summary"
        case .upcomingBills:
            return "Upcoming Bills"
        case .assistant:
            return "Assistant"
        case .debtPayoffPlan:
            return "Debt Payoff Plan"
        case .liabilityAccounts:
            return "Liability Accounts"
        case .accountDetail:
            return "Account Detail"
        case .incomeBills:
            return "Income & Bills"
        case .statementReview:
            return "Statement Review"
        case .importReview:
            return "Import Review"
        }
    }

    var spotlightDescription: String {
        switch self {
        case .debtSummary:
            return "Open the DebtScope debt summary screen."
        case .upcomingBills:
            return "Open the DebtScope income and bills screen."
        case .assistant:
            return "Open the DebtScope assistant screen."
        case .debtPayoffPlan:
            return "Open the DebtScope payoff plan screen."
        case .liabilityAccounts:
            return "Open the DebtScope liability accounts screen."
        case .accountDetail:
            return "Open a DebtScope account detail screen."
        case .incomeBills:
            return "Open the DebtScope income and bills screen."
        case .statementReview:
            return "Open the DebtScope statement review screen."
        case .importReview:
            return "Open the DebtScope import review screen."
        }
    }

    var spotlightKeywords: [String] {
        switch self {
        case .debtSummary:
            return ["debt", "summary", "strategy", "DebtScope"]
        case .upcomingBills:
            return ["bills", "income", "upcoming", "DebtScope"]
        case .assistant:
            return ["assistant", "help", "DebtScope"]
        case .debtPayoffPlan:
            return ["payoff", "plan", "debt", "DebtScope"]
        case .liabilityAccounts:
            return ["liability", "accounts", "debt", "DebtScope"]
        case .accountDetail:
            return ["account", "detail", "DebtScope"]
        case .incomeBills:
            return ["income", "bills", "cash flow", "DebtScope"]
        case .statementReview:
            return ["statement", "review", "import", "DebtScope"]
        case .importReview:
            return ["import", "review", "statement", "DebtScope"]
        }
    }
}
