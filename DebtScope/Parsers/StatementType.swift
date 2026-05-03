import Foundation

/// High-level statement categories used during intake.
public enum StatementType: String, Codable, CaseIterable {
    case creditCard
    case bank
    case brokerage
    case loan
}

#if canImport(SwiftData)
import SwiftData
#endif

// MARK: - Convenience mapping to Account.AccountType (if Account is available)
#if canImport(SwiftUI)
import SwiftUI
#endif

extension StatementType {
    /// Best-effort mapping to an Account.AccountType used by UI flows.
    var defaultAccountType: Account.AccountType {
        switch self {
        case .creditCard: return .creditCard
        case .bank:       return .checking
        case .brokerage:  return .brokerage
        case .loan:       return .loan
        }
    }
}
