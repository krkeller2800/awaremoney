@preconcurrency import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

enum DebtScopeSpotlightIndexer {
    private static let sectionDomainIdentifier = "com.debtscope.spotlight.sections"
    private static let sensitiveDomainIdentifier = "com.debtscope.spotlight.sensitive"
    private static let sectionIdentifierPrefix = "debtscope.section."

    private static var index: CSSearchableIndex {
        CSSearchableIndex(name: "DebtScopeSpotlightIndex")
    }

    @MainActor
    static func refreshIndex(allowsSensitiveFinancialIndexing: Bool) {
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

        if allowsSensitiveFinancialIndexing {
            removeSensitiveFinancialItems(reason: "no reviewed sensitive financial indexer is implemented")
        } else {
            removeSensitiveFinancialItems(reason: "sensitive financial indexing disabled")
        }
    }

    static func section(from searchableItemIdentifier: String) -> DebtScopeAppSection? {
        guard searchableItemIdentifier.hasPrefix(sectionIdentifierPrefix) else { return nil }
        let rawValue = String(searchableItemIdentifier.dropFirst(sectionIdentifierPrefix.count))
        return DebtScopeAppSection(rawValue: rawValue)
    }

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

    private static func spotlightIdentifier(for section: DebtScopeAppSection) -> String {
        sectionIdentifierPrefix + section.rawValue
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
        }
    }
}
