import Foundation

struct PrivacyValidationResult {
    let reportURL: URL
    let denylistCount: Int
    let scannedFileCount: Int
    let findings: [PrivacyValidationFinding]

    var hasFailures: Bool {
        !findings.isEmpty
    }
}

struct PrivacyValidationFinding: Codable {
    let fileName: String
    let fieldPath: String
    let matchedSourceKind: String
    let matchedValue: String
}

enum PrivacyValidationError: LocalizedError {
    case recipeFileMissing(String)
    case jsonInvalid(String)
    case validationFailed(reportURL: URL)

    var errorDescription: String? {
        switch self {
        case .recipeFileMissing(let fileName):
            return "Generated recipe file is missing before privacy validation: \(fileName)"
        case .jsonInvalid(let fileName):
            return "Generated recipe JSON could not be scanned for privacy validation: \(fileName)"
        case .validationFailed(let reportURL):
            return "Privacy validation failed. Review \(reportURL.path), then fix the recipe builder or rerun with --allow-risky-output only for local inspection."
        }
    }
}

struct PrivacyValidator {
    private let reportFileName = "privacy-validation-report.json"
    private let genericTerms: Set<String> = [
        "account",
        "ach",
        "atm",
        "bank",
        "card",
        "check",
        "checking",
        "credit",
        "debit",
        "deposit",
        "fee",
        "fees",
        "interest",
        "loan",
        "memo",
        "mobile",
        "online",
        "payment",
        "purchase",
        "savings",
        "statement",
        "transfer",
        "withdrawal"
    ]

    func validateRecipes(
        _ recipes: [BuiltRecipe],
        in recipesDirectory: URL,
        against manifest: BackupManifest
    ) throws -> PrivacyValidationResult {
        let denylist = buildDenylist(from: manifest)
        var findings: [PrivacyValidationFinding] = []

        for recipe in recipes {
            let recipeURL = recipesDirectory.appendingPathComponent(recipe.fileName, isDirectory: false)
            guard FileManager.default.fileExists(atPath: recipeURL.path) else {
                throw PrivacyValidationError.recipeFileMissing(recipe.fileName)
            }

            let data = try Data(contentsOf: recipeURL)
            let object: Any
            do {
                object = try JSONSerialization.jsonObject(with: data)
            } catch {
                throw PrivacyValidationError.jsonInvalid(recipe.fileName)
            }

            findings.append(contentsOf: scan(
                object,
                fileName: recipe.fileName,
                path: "$",
                denylist: denylist
            ))
        }

        let reportURL = recipesDirectory.appendingPathComponent(reportFileName, isDirectory: false)
        let report = PrivacyValidationReport(
            status: findings.isEmpty ? "passed" : "failed",
            scannedFiles: recipes.map(\.fileName).sorted(),
            denylistCount: denylist.count,
            findings: findings.sorted {
                if $0.fileName == $1.fileName {
                    return $0.fieldPath < $1.fieldPath
                }

                return $0.fileName < $1.fileName
            }
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let reportData = try encoder.encode(report)
        try reportData.write(to: reportURL, options: [.atomic])

        return PrivacyValidationResult(
            reportURL: reportURL,
            denylistCount: denylist.count,
            scannedFileCount: recipes.count,
            findings: report.findings
        )
    }

    private func buildDenylist(from manifest: BackupManifest) -> [DenylistEntry] {
        var entries: [DenylistEntry] = []

        for account in manifest.accounts {
            append(account.name, kind: "accountName", to: &entries)
            append(account.institutionName, kind: "institutionName", to: &entries)
            append(account.last4, kind: "accountLast4", to: &entries)
        }

        for batch in manifest.importBatches {
            append(batch.label, kind: "importLabel", to: &entries)
            append(batch.sourceFileName, kind: "sourceFileName", to: &entries)
        }

        for transaction in manifest.transactions {
            append(transaction.payee, kind: "payee", to: &entries)
            append(transaction.memo, kind: "memo", to: &entries)
        }

        var seen: Set<String> = []
        return entries.filter { entry in
            guard !seen.contains(entry.normalizedValue) else {
                return false
            }

            seen.insert(entry.normalizedValue)
            return true
        }
    }

    private func append(_ value: String?, kind: String, to entries: inout [DenylistEntry]) {
        guard let rawValue = value?.trimmingCharacters(in: .whitespacesAndNewlines), !rawValue.isEmpty else {
            return
        }

        let normalized = normalized(rawValue)
        guard shouldInclude(normalized) else {
            return
        }

        entries.append(DenylistEntry(sourceKind: kind, originalValue: rawValue, normalizedValue: normalized))
    }

    private func shouldInclude(_ normalizedValue: String) -> Bool {
        if normalizedValue.count < 4 {
            return false
        }

        if genericTerms.contains(normalizedValue) {
            return false
        }

        let scalars = normalizedValue.unicodeScalars
        let hasLetter = scalars.contains { CharacterSet.letters.contains($0) }
        let hasNumber = scalars.contains { CharacterSet.decimalDigits.contains($0) }

        if !hasLetter && !hasNumber {
            return false
        }

        if !hasLetter && normalizedValue.count < 4 {
            return false
        }

        return true
    }

    private func scan(
        _ object: Any,
        fileName: String,
        path: String,
        denylist: [DenylistEntry]
    ) -> [PrivacyValidationFinding] {
        if let dictionary = object as? [String: Any] {
            return dictionary.keys.sorted().flatMap { key in
                scan(dictionary[key] as Any, fileName: fileName, path: "\(path).\(key)", denylist: denylist)
            }
        }

        if let array = object as? [Any] {
            return array.enumerated().flatMap { index, value in
                scan(value, fileName: fileName, path: "\(path)[\(index)]", denylist: denylist)
            }
        }

        guard let value = object as? String else {
            return []
        }

        let normalizedValue = normalized(value)
        guard !normalizedValue.isEmpty else {
            return []
        }

        return denylist.compactMap { entry in
            guard containsDenylistedValue(entry.normalizedValue, in: normalizedValue) else {
                return nil
            }

            return PrivacyValidationFinding(
                fileName: fileName,
                fieldPath: path,
                matchedSourceKind: entry.sourceKind,
                matchedValue: entry.originalValue
            )
        }
    }

    private func containsDenylistedValue(_ needle: String, in haystack: String) -> Bool {
        var searchStart = haystack.startIndex

        while let range = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            if hasTokenBoundary(before: range.lowerBound, in: haystack)
                && hasTokenBoundary(after: range.upperBound, in: haystack) {
                return true
            }

            searchStart = range.upperBound
        }

        return false
    }

    private func hasTokenBoundary(before index: String.Index, in value: String) -> Bool {
        guard index > value.startIndex else {
            return true
        }

        return isBoundaryCharacter(value[value.index(before: index)])
    }

    private func hasTokenBoundary(after index: String.Index, in value: String) -> Bool {
        guard index < value.endIndex else {
            return true
        }

        return isBoundaryCharacter(value[index])
    }

    private func isBoundaryCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy {
            !CharacterSet.alphanumerics.contains($0)
        }
    }

    private func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct DenylistEntry {
    let sourceKind: String
    let originalValue: String
    let normalizedValue: String
}

private struct PrivacyValidationReport: Codable {
    let status: String
    let scannedFiles: [String]
    let denylistCount: Int
    let findings: [PrivacyValidationFinding]
}
