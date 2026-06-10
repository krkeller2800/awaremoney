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

    @Published var useReserveProcessingForBills: Bool {
        didSet { UserDefaults.standard.set(useReserveProcessingForBills, forKey: "use_reserve_processing_for_bills") }
    }

    // Assistant
    @Published var assistantEnabled: Bool {
        didSet {
            UserDefaults.standard.set(assistantEnabled, forKey: "assistant_enabled")
            if !assistantEnabled {
                assistantIncludeTransactions = false
                assistantRetainConversationHistory = false
            }
        }
    }

    @Published var assistantIncludeTransactions: Bool {
        didSet { UserDefaults.standard.set(assistantIncludeTransactions, forKey: "assistant_include_transactions") }
    }

    @Published var assistantRetainConversationHistory: Bool {
        didSet { UserDefaults.standard.set(assistantRetainConversationHistory, forKey: "assistant_retain_conversation_history") }
    }

    // Developer
    @Published var showDebugTools: Bool {
        didSet { UserDefaults.standard.set(showDebugTools, forKey: "show_debug_tools") }
    }

    @Published var didInitializeReserveAnchors: Bool {
        didSet { UserDefaults.standard.set(didInitializeReserveAnchors, forKey: "didInitializeReserveAnchors") }
    }

    @Published var didMigrateBillFundingAllocations: Bool {
        didSet { UserDefaults.standard.set(didMigrateBillFundingAllocations, forKey: "didMigrateBillFundingAllocations") }
    }

    @Published var lastReserveUpdateMonth: String? {
        didSet { UserDefaults.standard.set(lastReserveUpdateMonth, forKey: "last_reserve_update_month") }
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
        self.useReserveProcessingForBills = UserDefaults.standard.object(forKey: "use_reserve_processing_for_bills") as? Bool ?? true
        // Assistant
        self.assistantEnabled = UserDefaults.standard.object(forKey: "assistant_enabled") as? Bool ?? false
        self.assistantIncludeTransactions = UserDefaults.standard.object(forKey: "assistant_include_transactions") as? Bool ?? false
        self.assistantRetainConversationHistory = UserDefaults.standard.object(forKey: "assistant_retain_conversation_history") as? Bool ?? false
        
        #if DEBUG
        self.showDebugTools = UserDefaults.standard.object(forKey: "show_debug_tools") as? Bool ?? true
        #else
        self.showDebugTools = UserDefaults.standard.object(forKey: "show_debug_tools") as? Bool ?? false
        #endif

        self.didInitializeReserveAnchors = UserDefaults.standard.object(forKey: "didInitializeReserveAnchors") as? Bool ?? false
        self.didMigrateBillFundingAllocations = UserDefaults.standard.object(forKey: "didMigrateBillFundingAllocations") as? Bool ?? false
        self.lastReserveUpdateMonth = UserDefaults.standard.string(forKey: "last_reserve_update_month")
    }
}

