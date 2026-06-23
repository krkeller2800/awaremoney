import Foundation

enum StatementKind: String, Codable {
    case checking
    case creditCard
    case autoLoan
    case mortgage
    case genericLoan
}

struct SampleStatementRecipe: Codable {
    let schemaVersion: Int
    let statementKind: StatementKind
    let issuerName: String
    let customerName: String
    let customerAddress: [String]
    let accountName: String
    let accountLast4: String
    let statementStart: String
    let statementEnd: String
    let openingBalance: Double
    let summary: SampleStatementSummary
    let transactions: [SampleStatementTransaction]
}

struct SampleStatementSummary: Codable {
    let endingBalance: Double
    let minimumPayment: Double?
    let paymentDueDate: String?
    let aprPercent: Double?
}

struct SampleStatementTransaction: Codable {
    let date: String
    let description: String
    let amount: Double
    let balance: Double
    let category: String
}

struct BuiltRecipe {
    let fileName: String
    let recipe: SampleStatementRecipe
}

struct SampleRecipeBuildResult {
    let outputDirectory: URL
    let recipes: [BuiltRecipe]
}

enum SampleRecipeBuilderError: LocalizedError {
    case noUsableTransactions

    var errorDescription: String? {
        switch self {
        case .noUsableTransactions:
            return "No usable transactions were found in the backup manifest."
        }
    }
}

struct SampleRecipeBuilder {
    private let calendar: Calendar
    private let dateFormatter: DateFormatter

    init() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        self.calendar = calendar

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        self.dateFormatter = formatter
    }

    func buildRecipes(from manifest: BackupManifest, seed: String) throws -> [BuiltRecipe] {
        let accountsByID = Dictionary(uniqueKeysWithValues: manifest.accounts.map { ($0.id, $0) })
        let includedTransactions = manifest.transactions.filter { !$0.isExcluded }
        let groups = groupedTransactions(includedTransactions)

        guard !groups.isEmpty else {
            throw SampleRecipeBuilderError.noUsableTransactions
        }

        let transformer = PrivacyTransformer(seed: seed)
        var recipes: [BuiltRecipe] = []

        for (index, group) in groups.enumerated() {
            let account = group.accountID.flatMap { accountsByID[$0] }
            let kind = statementKind(for: account)
            let sortedTransactions = group.transactions.sorted {
                if $0.datePosted == $1.datePosted {
                    return $0.id.uuidString < $1.id.uuidString
                }
                return $0.datePosted < $1.datePosted
            }

            let recipe = buildRecipe(
                transactions: sortedTransactions,
                account: account,
                kind: kind,
                index: index,
                transformer: transformer
            )
            let fileName = String(format: "%03d-%@.json", index + 1, kind.rawValue)
            recipes.append(BuiltRecipe(fileName: fileName, recipe: recipe))
        }

        return recipes
    }

    func writeRecipes(_ recipes: [BuiltRecipe], to outputDirectory: URL) throws -> SampleRecipeBuildResult {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        for recipe in recipes {
            let data = try encoder.encode(recipe.recipe)
            let outputURL = outputDirectory.appendingPathComponent(recipe.fileName, isDirectory: false)
            try data.write(to: outputURL, options: [.atomic])
        }

        return SampleRecipeBuildResult(outputDirectory: outputDirectory, recipes: recipes)
    }

    private func groupedTransactions(_ transactions: [BackupTransaction]) -> [TransactionGroup] {
        let grouped = Dictionary(grouping: transactions) { transaction in
            TransactionGroupKey(
                batchID: transaction.importBatchID,
                accountID: transaction.accountID
            )
        }

        return grouped.map { key, transactions in
            TransactionGroup(key: key, transactions: transactions)
        }
        .sorted {
            let lhsDate = $0.transactions.map(\.datePosted).min() ?? .distantFuture
            let rhsDate = $1.transactions.map(\.datePosted).min() ?? .distantFuture

            if lhsDate == rhsDate {
                return $0.sortKey < $1.sortKey
            }

            return lhsDate < rhsDate
        }
    }

    private func buildRecipe(
        transactions: [BackupTransaction],
        account: BackupAccount?,
        kind: StatementKind,
        index: Int,
        transformer: PrivacyTransformer
    ) -> SampleStatementRecipe {
        let persona = transformer.persona(for: index)
        let sourceStart = transactions.map(\.datePosted).min() ?? Date()
        let sourceEnd = transactions.map(\.datePosted).max() ?? sourceStart
        let fictionalStart = fictionalStatementStart(for: index)
        let sourceSpan = calendar.dateComponents([.day], from: startOfDay(sourceStart), to: startOfDay(sourceEnd)).day ?? 0
        let fictionalEnd = calendar.date(byAdding: .day, value: max(sourceSpan, 0), to: fictionalStart) ?? fictionalStart
        let amountScale = transformer.amountScale(for: index)
        let generatedTransactions = transactions.enumerated().map { offset, transaction in
            let dayOffset = calendar.dateComponents(
                [.day],
                from: startOfDay(sourceStart),
                to: startOfDay(transaction.datePosted)
            ).day ?? 0
            let shiftedDate = calendar.date(byAdding: .day, value: max(dayOffset, 0), to: fictionalStart) ?? fictionalStart
            let amount = statementAmount(for: transaction, kind: kind, scale: amountScale)

            return GeneratedTransactionSeed(
                date: dateFormatter.string(from: shiftedDate),
                description: transformer.description(for: transaction, kind: kind, index: index + offset),
                amount: amount,
                category: category(for: transaction, kind: kind)
            )
        }
        let openingBalance = adjustedOpeningBalance(
            transformer.openingBalance(for: kind, index: index),
            for: kind,
            seeds: generatedTransactions
        )
        let recipeTransactions = buildDeduplicatedTransactions(
            from: generatedTransactions,
            openingBalance: openingBalance
        )
        let endingBalance = recipeTransactions.last?.balance ?? openingBalance

        let summary = buildSummary(
            kind: kind,
            account: account,
            endingBalance: endingBalance,
            statementEnd: fictionalEnd
        )

        return SampleStatementRecipe(
            schemaVersion: 1,
            statementKind: kind,
            issuerName: persona.issuerName,
            customerName: persona.customerName,
            customerAddress: persona.customerAddress,
            accountName: transformer.accountName(for: kind, index: index),
            accountLast4: transformer.accountLast4(for: index),
            statementStart: dateFormatter.string(from: fictionalStart),
            statementEnd: dateFormatter.string(from: fictionalEnd),
            openingBalance: openingBalance,
            summary: summary,
            transactions: recipeTransactions
        )
    }

    private func buildSummary(
        kind: StatementKind,
        account: BackupAccount?,
        endingBalance: Double,
        statementEnd: Date
    ) -> SampleStatementSummary {
        let dueDate = calendar.date(byAdding: .day, value: 21, to: statementEnd) ?? statementEnd
        let aprPercent = aprPercent(for: account)

        switch kind {
        case .checking:
            return SampleStatementSummary(
                endingBalance: endingBalance,
                minimumPayment: nil,
                paymentDueDate: nil,
                aprPercent: nil
            )
        case .creditCard:
            return SampleStatementSummary(
                endingBalance: endingBalance,
                minimumPayment: rounded(max(abs(endingBalance) * 0.025, 35.0)),
                paymentDueDate: dateFormatter.string(from: dueDate),
                aprPercent: aprPercent ?? 19.24
            )
        case .autoLoan, .mortgage, .genericLoan:
            return SampleStatementSummary(
                endingBalance: endingBalance,
                minimumPayment: account?.loanTerms?.paymentAmount.map { rounded($0.doubleValue) } ?? rounded(max(abs(endingBalance) * 0.015, 125.0)),
                paymentDueDate: dateFormatter.string(from: dueDate),
                aprPercent: aprPercent ?? 7.5
            )
        }
    }

    private func buildDeduplicatedTransactions(
        from seeds: [GeneratedTransactionSeed],
        openingBalance: Double
    ) -> [SampleStatementTransaction] {
        var identityCounts: [TransactionIdentity: Int] = [:]
        var dateDescriptionCounts: [DateDescriptionIdentity: Int] = [:]
        var runningBalance = openingBalance
        var output: [SampleStatementTransaction] = []

        for seed in seeds {
            let baseIdentity = TransactionIdentity(
                date: seed.date,
                amount: seed.amount,
                description: seed.description
            )
            let seenCount = identityCounts[baseIdentity, default: 0]
            identityCounts[baseIdentity] = seenCount + 1
            let dateDescriptionIdentity = DateDescriptionIdentity(
                date: seed.date,
                description: seed.description
            )
            let dateDescriptionSeenCount = dateDescriptionCounts[dateDescriptionIdentity, default: 0]
            dateDescriptionCounts[dateDescriptionIdentity] = dateDescriptionSeenCount + 1

            let duplicateOrdinal = max(seenCount, dateDescriptionSeenCount)
            let description = duplicateOrdinal == 0
                ? seed.description
                : "\(seed.description) - Entry \(duplicateOrdinal + 1)"
            runningBalance = rounded(runningBalance + seed.amount)

            output.append(SampleStatementTransaction(
                date: seed.date,
                description: description,
                amount: seed.amount,
                balance: runningBalance,
                category: seed.category
            ))
        }

        return output
    }

    private func adjustedOpeningBalance(
        _ openingBalance: Double,
        for kind: StatementKind,
        seeds: [GeneratedTransactionSeed]
    ) -> Double {
        guard kind == .checking else {
            return openingBalance
        }

        let minimumAllowedBalance = 25.0
        var runningDelta = 0.0
        var lowestDelta = 0.0

        for seed in seeds {
            runningDelta = rounded(runningDelta + seed.amount)
            lowestDelta = min(lowestDelta, runningDelta)
        }

        let lowestBalance = rounded(openingBalance + lowestDelta)
        guard lowestBalance < minimumAllowedBalance else {
            return openingBalance
        }

        return rounded(openingBalance + minimumAllowedBalance - lowestBalance)
    }

    private func statementKind(for account: BackupAccount?) -> StatementKind {
        guard let account else {
            return .checking
        }

        switch account.typeRaw {
        case "creditCard":
            return .creditCard
        case "loan":
            if account.assetCategoryRaw == "vehicle" || account.name.localizedCaseInsensitiveContains("auto") || account.name.localizedCaseInsensitiveContains("vehicle") {
                return .autoLoan
            }

            if account.assetCategoryRaw == "property" || account.name.localizedCaseInsensitiveContains("mortgage") || account.name.localizedCaseInsensitiveContains("home") {
                return .mortgage
            }

            return .genericLoan
        default:
            return .checking
        }
    }

    private func category(for transaction: BackupTransaction, kind: StatementKind) -> String {
        if let kindRaw = transaction.kindRaw, !kindRaw.isEmpty {
            switch kindRaw {
            case "income", "deposit", "payment":
                return "income"
            case "fee", "interest":
                return "fees"
            default:
                break
            }
        }

        if transaction.amount.doubleValue >= 0 {
            return kind == .checking ? "income" : "payment"
        }

        switch kind {
        case .checking:
            return "spending"
        case .creditCard:
            return "purchase"
        case .autoLoan, .mortgage, .genericLoan:
            return "loan"
        }
    }

    private func statementAmount(for transaction: BackupTransaction, kind: StatementKind, scale: Double) -> Double {
        let scaledMagnitude = rounded(abs(transaction.amount.doubleValue) * scale)
        let appSignedAmount = rounded(transaction.amount.doubleValue * scale)

        switch kind {
        case .checking:
            return appSignedAmount
        case .creditCard:
            return liabilityStatementAmount(
                for: transaction,
                paymentIsNegative: true,
                chargeIsPositive: true,
                scaledMagnitude: scaledMagnitude
            )
        case .autoLoan, .mortgage, .genericLoan:
            return liabilityStatementAmount(
                for: transaction,
                paymentIsNegative: true,
                chargeIsPositive: true,
                scaledMagnitude: scaledMagnitude
            )
        }
    }

    private func liabilityStatementAmount(
        for transaction: BackupTransaction,
        paymentIsNegative: Bool,
        chargeIsPositive: Bool,
        scaledMagnitude: Double
    ) -> Double {
        if let kindRaw = transaction.kindRaw?.lowercased(), !kindRaw.isEmpty {
            switch kindRaw {
            case "income", "deposit", "payment":
                return paymentIsNegative ? -scaledMagnitude : scaledMagnitude
            case "fee", "fees", "interest", "purchase", "spending", "withdrawal", "charge":
                return chargeIsPositive ? scaledMagnitude : -scaledMagnitude
            default:
                break
            }
        }

        return transaction.amount.doubleValue >= 0 ? -scaledMagnitude : scaledMagnitude
    }

    private func aprPercent(for account: BackupAccount?) -> Double? {
        guard let terms = account?.loanTerms, let apr = terms.apr else {
            return nil
        }

        let value = apr.doubleValue
        if value <= 1.0 {
            return rounded(value * 100.0)
        }

        return rounded(value)
    }

    private func fictionalStatementStart(for index: Int) -> Date {
        let baseComponents = DateComponents(calendar: calendar, timeZone: calendar.timeZone, year: 2026, month: 2, day: 1)
        let baseDate = calendar.date(from: baseComponents) ?? Date(timeIntervalSince1970: 1_769_904_000)
        return calendar.date(byAdding: .month, value: index, to: baseDate) ?? baseDate
    }

    private func startOfDay(_ date: Date) -> Date {
        calendar.startOfDay(for: date)
    }

    private func rounded(_ value: Double) -> Double {
        (value * 100.0).rounded() / 100.0
    }
}

private struct TransactionGroupKey: Hashable {
    let batchID: UUID?
    let accountID: UUID?
}

private struct TransactionGroup {
    let key: TransactionGroupKey
    let transactions: [BackupTransaction]

    var accountID: UUID? {
        key.accountID
    }

    var sortKey: String {
        "\(key.batchID?.uuidString ?? "no-batch")-\(key.accountID?.uuidString ?? "no-account")"
    }
}

private struct GeneratedTransactionSeed {
    let date: String
    let description: String
    let amount: Double
    let category: String
}

private struct TransactionIdentity: Hashable {
    let date: String
    let amountCents: Int
    let description: String

    init(date: String, amount: Double, description: String) {
        self.date = date
        self.amountCents = Int((amount * 100.0).rounded())
        self.description = description
    }
}

private struct DateDescriptionIdentity: Hashable {
    let date: String
    let description: String
}
