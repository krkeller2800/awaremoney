import AppIntents
import Foundation

struct DebtScopeAppSectionRequestStore {
    static let notificationName = Notification.Name("DebtScopeAppSectionRequest")

    private static let pendingSectionKey = "debtScope.pendingAppIntentSection"

    static func request(_ section: DebtScopeAppSection) {
        UserDefaults.standard.set(section.rawValue, forKey: pendingSectionKey)
        NotificationCenter.default.post(name: notificationName, object: section.rawValue)
    }

    static func consumePendingSection() -> DebtScopeAppSection? {
        guard let rawValue = UserDefaults.standard.string(forKey: pendingSectionKey),
              let section = DebtScopeAppSection(rawValue: rawValue) else {
            return nil
        }

        UserDefaults.standard.removeObject(forKey: pendingSectionKey)
        return section
    }
}

enum DebtScopeAppSection: String, AppEnum {
    case debtSummary
    case upcomingBills
    case assistant
    case debtPayoffPlan

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "DebtScope Section"

    static var caseDisplayRepresentations: [DebtScopeAppSection: DisplayRepresentation] = [
        .debtSummary: "Debt Summary",
        .upcomingBills: "Upcoming Bills",
        .assistant: "Assistant",
        .debtPayoffPlan: "Debt Payoff Plan"
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
