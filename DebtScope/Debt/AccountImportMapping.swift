import Foundation
import SwiftData

@Model final class AccountImportMapping {
    @Attribute(.unique) var id: UUID
    var institutionName: String
    var subaccountLabel: String
    var accountID: UUID
    var createdAt: Date
    var confidence: Double

    init(id: UUID = UUID(), institutionName: String, subaccountLabel: String, accountID: UUID, createdAt: Date = Date(), confidence: Double = 1.0) {
        self.id = id
        self.institutionName = institutionName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.subaccountLabel = subaccountLabel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.accountID = accountID
        self.createdAt = createdAt
        self.confidence = confidence
    }
}

extension AccountImportMapping {
    static func normalizedInstitution(_ raw: String?) -> String? {
        guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    static func normalizedLabel(_ raw: String?) -> String? {
        guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s.lowercased()
    }
}
