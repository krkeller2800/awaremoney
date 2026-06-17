import Foundation

enum PaywallSource: String, Codable, CaseIterable, Hashable {
    case fifthImport
    case externalImport
    case settings
    case about
    case backupRestore
    case payoffResult
    case assistant
    case unknown
}
