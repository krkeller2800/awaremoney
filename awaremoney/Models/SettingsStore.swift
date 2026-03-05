import SwiftUI
import Combine

final class SettingsStore: ObservableObject {
    // Published currency code stored in UserDefaults; defaults to device locale or USD
    @Published var currencyCode: String {
        didSet {
            UserDefaults.standard.set(currencyCode, forKey: "currency_code")
        }
    }

    // Import behavior
    @Published var importAutoApplyMappings: Bool {
        didSet { UserDefaults.standard.set(importAutoApplyMappings, forKey: "import_auto_apply_mappings") }
    }

    @Published var creditCardFlipDefault: Bool {
        didSet { UserDefaults.standard.set(creditCardFlipDefault, forKey: "credit_card_flip_default") }
    }

    // Debt planning defaults
    @Published var defaultPayoffStrategyRaw: String { // stores PayoffStrategy.rawValue
        didSet { UserDefaults.standard.set(defaultPayoffStrategyRaw, forKey: "default_payoff_strategy") }
    }

    @Published var useNetForDebtBudgetDefault: Bool {
        didSet { UserDefaults.standard.set(useNetForDebtBudgetDefault, forKey: "use_net_for_debt_budget_default") }
    }

    // Appearance & UX
    @Published var showHintBars: Bool {
        didSet { UserDefaults.standard.set(showHintBars, forKey: "show_hint_bars") }
    }

    @Published var hapticsEnabled: Bool {
        didSet { UserDefaults.standard.set(hapticsEnabled, forKey: "haptics_enabled") }
    }

    init() {
        if let stored = UserDefaults.standard.string(forKey: "currency_code"), !stored.isEmpty {
            self.currencyCode = stored
        } else if let id = Locale.current.currency?.identifier, !id.isEmpty {
            self.currencyCode = id
        } else {
            self.currencyCode = "USD"
        }
        // Import behavior
        self.importAutoApplyMappings = UserDefaults.standard.object(forKey: "import_auto_apply_mappings") as? Bool ?? true
        self.creditCardFlipDefault = UserDefaults.standard.object(forKey: "credit_card_flip_default") as? Bool ?? false
        // Debt planning defaults
        self.defaultPayoffStrategyRaw = UserDefaults.standard.string(forKey: "default_payoff_strategy") ?? "minimumsOnly"
        self.useNetForDebtBudgetDefault = UserDefaults.standard.object(forKey: "use_net_for_debt_budget_default") as? Bool ?? false
        // Appearance & UX
        self.showHintBars = UserDefaults.standard.object(forKey: "show_hint_bars") as? Bool ?? true
        self.hapticsEnabled = UserDefaults.standard.object(forKey: "haptics_enabled") as? Bool ?? true
    }
}
