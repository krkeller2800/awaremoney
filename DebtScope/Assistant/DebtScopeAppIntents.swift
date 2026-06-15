import AppIntents
import Foundation

enum DebtScopeAppRouteFocus: String, Sendable {
    case apr
    case paymentAmount
}

struct DebtScopeAppRoute: Sendable {
    let section: DebtScopeAppSection
    let accountID: UUID?
    let focus: DebtScopeAppRouteFocus?
}

struct DebtScopeAppSectionRequestStore {
    static let notificationName = Notification.Name("DebtScopeAppSectionRequest")

    private static let pendingSectionKey = "debtScope.pendingAppIntentSection"
    private static let pendingAccountIDKey = "debtScope.pendingAppIntentAccountID"
    private static let notificationSectionKey = "section"
    private static let notificationAccountIDKey = "accountID"
    private static let pendingFocusKey = "debtScope.pendingAppIntentFocus"
    private static let notificationFocusKey = "focus"

    static func request(_ section: DebtScopeAppSection, accountID: UUID? = nil, focus: DebtScopeAppRouteFocus? = nil) {
        UserDefaults.standard.set(section.rawValue, forKey: pendingSectionKey)
        if let accountID {
            UserDefaults.standard.set(accountID.uuidString, forKey: pendingAccountIDKey)
        } else {
            UserDefaults.standard.removeObject(forKey: pendingAccountIDKey)
        }
        if let focus {
            UserDefaults.standard.set(focus.rawValue, forKey: pendingFocusKey)
        } else {
            UserDefaults.standard.removeObject(forKey: pendingFocusKey)
        }

        NotificationCenter.default.post(
            name: notificationName,
            object: [
                notificationSectionKey: section.rawValue,
                notificationAccountIDKey: accountID?.uuidString ?? "",
                notificationFocusKey: focus?.rawValue ?? ""
            ]
        )
    }

    static func route(from notification: Notification) -> DebtScopeAppRoute? {
        if let rawValue = notification.object as? String,
           let section = DebtScopeAppSection(rawValue: rawValue) {
            return DebtScopeAppRoute(section: section, accountID: nil, focus: nil)
        }

        guard let payload = notification.object as? [String: String],
              let rawValue = payload[notificationSectionKey],
              let section = DebtScopeAppSection(rawValue: rawValue) else {
            return nil
        }

        let accountID = payload[notificationAccountIDKey].flatMap(UUID.init(uuidString:))
        let focus = payload[notificationFocusKey].flatMap(DebtScopeAppRouteFocus.init(rawValue:))
        return DebtScopeAppRoute(section: section, accountID: accountID, focus: focus)
    }

    static func consumePendingRoute() -> DebtScopeAppRoute? {
        guard let rawValue = UserDefaults.standard.string(forKey: pendingSectionKey),
              let section = DebtScopeAppSection(rawValue: rawValue) else {
            return nil
        }

        let accountID = UserDefaults.standard.string(forKey: pendingAccountIDKey).flatMap(UUID.init(uuidString:))
        let focus = UserDefaults.standard.string(forKey: pendingFocusKey).flatMap(DebtScopeAppRouteFocus.init(rawValue:))
        UserDefaults.standard.removeObject(forKey: pendingSectionKey)
        UserDefaults.standard.removeObject(forKey: pendingAccountIDKey)
        UserDefaults.standard.removeObject(forKey: pendingFocusKey)
        return DebtScopeAppRoute(section: section, accountID: accountID, focus: focus)
    }

    static func consumePendingSection() -> DebtScopeAppSection? {
        consumePendingRoute()?.section
    }
}

enum DebtScopeAppSection: String, AppEnum, Codable, Sendable {
    case debtSummary
    case upcomingBills
    case assistant
    case debtPayoffPlan
    case liabilityAccounts
    case accountDetail
    case incomeBills
    case statementReview
    case importReview

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "DebtScope Section"

    static var caseDisplayRepresentations: [DebtScopeAppSection: DisplayRepresentation] = [
        .debtSummary: "Debt Summary",
        .upcomingBills: "Upcoming Bills",
        .assistant: "Assistant",
        .debtPayoffPlan: "Debt Payoff Plan",
        .liabilityAccounts: "Liability Accounts",
        .accountDetail: "Account Detail",
        .incomeBills: "Income & Bills",
        .statementReview: "Statement Review",
        .importReview: "Import Review"
    ]
}

struct OpenDebtScopeSectionIntent: AppIntent {
    static var title: LocalizedStringResource = "Open DebtScope Section"
    static var description = IntentDescription("Opens a DebtScope screen without exposing financial details in system surfaces.")
    static var openAppWhenRun = true

    @Parameter(title: "Section")
    var section: DebtScopeAppSection

    init() { }

    init(section: DebtScopeAppSection) {
        self.section = section
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        DebtScopeAppSectionRequestStore.request(section)
        return .result()
    }
}

struct DebtScopeAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenDebtScopeSectionIntent(section: .debtSummary),
            phrases: [
                "Show debt summary in \(.applicationName)",
                "Open debt summary in \(.applicationName)"
            ],
            shortTitle: "Debt Summary",
            systemImageName: "chart.pie"
        )

        AppShortcut(
            intent: OpenDebtScopeSectionIntent(section: .upcomingBills),
            phrases: [
                "Open upcoming bills in \(.applicationName)",
                "Show upcoming bills in \(.applicationName)"
            ],
            shortTitle: "Upcoming Bills",
            systemImageName: "calendar"
        )

        AppShortcut(
            intent: OpenDebtScopeSectionIntent(section: .assistant),
            phrases: [
                "Open assistant in \(.applicationName)",
                "Ask \(.applicationName)"
            ],
            shortTitle: "Assistant",
            systemImageName: "sparkles"
        )

        AppShortcut(
            intent: OpenDebtScopeSectionIntent(section: .debtPayoffPlan),
            phrases: [
                "Open debt payoff plan in \(.applicationName)",
                "Show payoff plan in \(.applicationName)"
            ],
            shortTitle: "Payoff Plan",
            systemImageName: "creditcard"
        )
    }
}
