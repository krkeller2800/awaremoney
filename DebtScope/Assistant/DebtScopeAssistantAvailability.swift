import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum DebtScopeAssistantAvailability: Equatable {
    case available
    case disabledInSettings
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case unavailable

    var title: String {
        switch self {
        case .available:
            return "Assistant Ready"
        case .disabledInSettings:
            return "Assistant Disabled"
        case .deviceNotEligible:
            return "Apple Intelligence Unavailable"
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence Off"
        case .modelNotReady:
            return "Model Not Ready"
        case .unavailable:
            return "Assistant Unavailable"
        }
    }

    var message: String {
        switch self {
        case .available:
            return "DebtScope can use the on-device system language model. Supported questions use scoped read-only summaries from your app data."
        case .disabledInSettings:
            return "Turn on the read-only assistant to check Apple Intelligence availability. Transaction details stay off unless you allow them separately."
        case .deviceNotEligible:
            return "This device does not support Apple Intelligence, so the on-device assistant cannot run here."
        case .appleIntelligenceNotEnabled:
            return "Turn on Apple Intelligence in system settings to use the on-device assistant."
        case .modelNotReady:
            return "Apple Intelligence is enabled, but the model is still downloading or temporarily unavailable. Try again later."
        case .unavailable:
            return "The system language model is unavailable for an unknown reason. DebtScope will keep this feature in a fallback state."
        }
    }

    var systemImage: String {
        switch self {
        case .available:
            return "sparkles"
        case .disabledInSettings:
            return "switch.2"
        case .deviceNotEligible:
            return "iphone.slash"
        case .appleIntelligenceNotEnabled:
            return "gearshape"
        case .modelNotReady:
            return "arrow.down.circle"
        case .unavailable:
            return "exclamationmark.triangle"
        }
    }

    var isAvailable: Bool {
        self == .available
    }

    static func current(assistantEnabled: Bool) -> DebtScopeAssistantAvailability {
        guard assistantEnabled else { return .disabledInSettings }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(.deviceNotEligible):
                return .deviceNotEligible
            case .unavailable(.appleIntelligenceNotEnabled):
                return .appleIntelligenceNotEnabled
            case .unavailable(.modelNotReady):
                return .modelNotReady
            case .unavailable:
                return .unavailable
            }
        } else {
            return .deviceNotEligible
        }
        #else
        return .deviceNotEligible
        #endif
    }
}
