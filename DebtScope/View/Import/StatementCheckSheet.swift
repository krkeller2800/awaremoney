//
//  StatementCheckSheet.swift
//  DebtScope
//

import Foundation
import SwiftUI

struct StatementCheckIssue: Identifiable, Hashable {
    let id: String
    let accountLabel: String
    let transactionCount: Int
    let beginningBalance: Decimal
    let endingBalance: Decimal
    let transactionTotal: Decimal
    let expectedEndingBalance: Decimal
    let difference: Decimal
}

struct StatementCheckWarning: Identifiable, Hashable {
    let id: String
    let accountLabel: String
    let transactionCount: Int
    let balanceCount: Int
    let reason: String
}

struct StatementCheckResult: Identifiable, Hashable {
    let id = UUID()
    let decisionKey: String
    let issues: [StatementCheckIssue]
    let warnings: [StatementCheckWarning]

    var affectedAccountLabels: Set<String> {
        Set(issues.map { StatementCheckService.normalizedLabel($0.accountLabel) })
            .union(warnings.map { StatementCheckService.normalizedLabel($0.accountLabel) })
    }
}

enum StatementCheckStatus: Hashable {
    case notApplicable
    case balanced
    case needsReview(StatementCheckResult)
}

enum StatementCheckService {
    private static let unlabeledAccountKey = "__unlabeled__"
    private static let typicalPaymentKey = "__typical_payment__"

    static func evaluate(staged: StagedImport, tolerance: Decimal = Decimal(string: "0.01") ?? 0.01) -> StatementCheckResult? {
        guard case let .needsReview(result) = status(staged: staged, tolerance: tolerance) else {
            return nil
        }
        return result
    }

    static func status(staged: StagedImport, tolerance: Decimal = Decimal(string: "0.01") ?? 0.01) -> StatementCheckStatus {
        let includedBalances = staged.balances.filter { balance in
            guard balance.include else { return false }
            return normalizedLabel(balance.sourceAccountLabel) != typicalPaymentKey
        }
        let includedTransactions = staged.transactions.filter(\.include)
        guard !includedTransactions.isEmpty else { return .notApplicable }

        let balanceGroups = Dictionary(grouping: includedBalances) { normalizedLabel($0.sourceAccountLabel) }
        let transactionGroups = Dictionary(grouping: includedTransactions) { normalizedLabel($0.sourceAccountLabel) }
        let singleBalanceLabel = balanceGroups.count == 1 ? balanceGroups.keys.first : nil
        let labelsToCheck = Set(balanceGroups.keys).union(transactionGroups.keys)

        func matchingTransactions(for label: String) -> [StagedTransaction] {
            if let direct = transactionGroups[label] {
                return direct
            }
            if label == singleBalanceLabel, let unlabeled = transactionGroups[unlabeledAccountKey] {
                return unlabeled
            }
            if label == unlabeledAccountKey, let onlyBalanceLabel = singleBalanceLabel, Set(transactionGroups.keys) == [unlabeledAccountKey] {
                return transactionGroups[onlyBalanceLabel] ?? transactionGroups[unlabeledAccountKey] ?? []
            }
            return []
        }

        var issues: [StatementCheckIssue] = []
        var warnings: [StatementCheckWarning] = []
        var checkedAccountCount = 0

        for label in labelsToCheck {
            let balances = balanceGroups[label] ?? []
            let transactions = matchingTransactions(for: label)
            guard !transactions.isEmpty else { continue }

            let sortedBalances = balances.sorted { lhs, rhs in
                if lhs.asOfDate == rhs.asOfDate { return lhs.balance < rhs.balance }
                return lhs.asOfDate < rhs.asOfDate
            }

            guard let beginning = sortedBalances.first,
                  let ending = sortedBalances.last,
                  beginning.id != ending.id else {
                warnings.append(
                    StatementCheckWarning(
                        id: label,
                        accountLabel: displayLabel(for: label),
                        transactionCount: transactions.count,
                        balanceCount: balances.count,
                        reason: "Need both a beginning and ending balance to verify the transactions."
                    )
                )
                continue
            }

            let statementAmounts = transactions.map { transaction in
                (
                    transaction: transaction,
                    normalizedAmount: statementAmount(for: transaction, accountLabel: label, beginningBalance: beginning.balance, endingBalance: ending.balance)
                )
            }
            let transactionTotal = statementAmounts.reduce(Decimal.zero) { $0 + $1.normalizedAmount }
            let expectedEnding = beginning.balance + transactionTotal
            let difference = ending.balance - expectedEnding
            checkedAccountCount += 1
            guard absolute(difference) > tolerance else { continue }

            issues.append(
                StatementCheckIssue(
                    id: label,
                    accountLabel: displayLabel(for: label),
                    transactionCount: transactions.count,
                    beginningBalance: beginning.balance,
                    endingBalance: ending.balance,
                    transactionTotal: transactionTotal,
                    expectedEndingBalance: expectedEnding,
                    difference: difference
                )
            )
        }

        if issues.isEmpty && warnings.isEmpty && checkedAccountCount > 0 {
            return .balanced
        }

        guard !issues.isEmpty || !warnings.isEmpty else { return .notApplicable }
        return .needsReview(StatementCheckResult(
            decisionKey: decisionKey(for: staged),
            issues: issues.sorted { $0.accountLabel < $1.accountLabel },
            warnings: warnings.sorted { $0.accountLabel < $1.accountLabel }
        ))
    }

    static func decisionKey(for staged: StagedImport) -> String {
        let transactionParts = staged.transactions
            .filter(\.include)
            .map { transaction in
                [
                    normalizedLabel(transaction.sourceAccountLabel),
                    dateKey(transaction.datePosted),
                    decimalKey(transaction.amount),
                    transaction.payee
                ].joined(separator: ":")
            }
            .sorted()
            .joined(separator: "|")

        let balanceParts = staged.balances
            .filter { $0.include && normalizedLabel($0.sourceAccountLabel) != typicalPaymentKey }
            .map { balance in
                [
                    normalizedLabel(balance.sourceAccountLabel),
                    dateKey(balance.asOfDate),
                    decimalKey(balance.balance)
                ].joined(separator: ":")
            }
            .sorted()
            .joined(separator: "|")

        return [staged.sourceFileName, transactionParts, balanceParts].joined(separator: "#")
    }

    static func normalizedLabel(_ label: String?) -> String {
        let trimmed = (label ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? unlabeledAccountKey : trimmed
    }

    static func displayLabel(for normalizedLabel: String) -> String {
        switch normalizedLabel {
        case unlabeledAccountKey:
            return "Unlabeled account"
        default:
            return normalizedLabel
                .split(separator: " ")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }

    private static func statementAmount(for transaction: StagedTransaction, accountLabel: String, beginningBalance: Decimal, endingBalance: Decimal) -> Decimal {
        guard accountLabel.contains("credit"), beginningBalance < 0 || endingBalance < 0 else {
            return transaction.amount
        }

        let lowerPayee = transaction.payee.lowercased()
        let normalizedDescription = lowerPayee
            .split(whereSeparator: { !$0.isLetter })
            .joined(separator: " ")
        let words = Set(normalizedDescription.split(separator: " ").map(String.init))
        let fusedPaymentRowCarriesDifferentAmount = embeddedPaymentAmountMagnitude(in: lowerPayee).map { $0 != transaction.amount.magnitude } ?? false
        let isPayment = !fusedPaymentRowCarriesDifferentAmount && (
            words.contains("payment")
            || words.contains("pymt")
            || words.contains("pmt")
            || words.contains("autopay")
            || (words.contains("auto") && words.contains("pay"))
        )
        let creditPhrases = [
            "refund", "return", "returned merchandise", "payment reversal",
            "statement credit", "account credit", "merchant credit", "credit adjustment"
        ]
        let isCredit = creditPhrases.contains { normalizedDescription.contains($0) }

        if isPayment || isCredit {
            return transaction.amount.magnitude
        }

        return -transaction.amount.magnitude
    }

    private static func embeddedPaymentAmountMagnitude(in lowerDescription: String) -> Decimal? {
        let amountPattern = #"(-\s*\$?\s*(?:[0-9]{1,3}(?:,[0-9]{3})*|[0-9]+)(?:\.[0-9]{2}))"#
        let pattern = #"payment\s*-\s*thank\s+you\b.{0,160}?"# + amountPattern
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(lowerDescription.startIndex..<lowerDescription.endIndex, in: lowerDescription)
        guard let match = regex.firstMatch(in: lowerDescription, options: [], range: range),
              match.numberOfRanges >= 2,
              let amountRange = Range(match.range(at: 1), in: lowerDescription) else {
            return nil
        }

        let token = String(lowerDescription[amountRange])
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: " ", with: "")
        return Decimal(string: token)?.magnitude
    }

    private static func absolute(_ value: Decimal) -> Decimal {
        value < 0 ? -value : value
    }

    private static func dateKey(_ date: Date) -> String {
        String(Int(date.timeIntervalSince1970))
    }

    private static func decimalKey(_ decimal: Decimal) -> String {
        NSDecimalNumber(decimal: decimal).stringValue
    }
}

struct StatementCheckSheet: View {
    let result: StatementCheckResult
    let currencyCode: String
    var isReadOnly: Bool = false
    let onImportBalancesOnly: () -> Void
    let onExcludeProblemTransactions: () -> Void
    let onContinueAnyway: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(titleText, systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    Text(messageText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if !result.issues.isEmpty {
                    Section(isReadOnly ? "Reconciliation Details" : "Accounts That Do Not Match") {
                        ForEach(result.issues) { issue in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text(issue.accountLabel)
                                        .font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Text("\(issue.transactionCount) transactions")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                VStack(spacing: 6) {
                                    checkRow("Beginning", money(issue.beginningBalance))
                                    checkRow("Transactions", money(issue.transactionTotal))
                                    checkRow("Expected ending", money(issue.expectedEndingBalance))
                                    checkRow("Statement ending", money(issue.endingBalance))
                                    checkRow("Difference", money(issue.difference), emphasized: true)
                                }
                                .font(.caption)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                if !result.warnings.isEmpty {
                    Section("Accounts That Could Not Be Verified") {
                        ForEach(result.warnings) { warning in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(warning.accountLabel)
                                        .font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Text("\(warning.transactionCount) transactions")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Text(warning.reason)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                Text("Detected balances: \(warning.balanceCount)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                if !isReadOnly {
                    Section {
                        Button("Import Balances Only", role: .destructive, action: onImportBalancesOnly)
                        Button("Exclude Flagged Transactions", role: .destructive, action: onExcludeProblemTransactions)
                        Button("Continue Anyway", action: onContinueAnyway)
                    } footer: {
                        Text("These choices apply before account routing. You can also cancel and edit the import review manually.")
                    }
                }
            }
            .navigationTitle(isReadOnly ? "Reconciliation" : "Check Import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isReadOnly ? "Done" : "Cancel", action: onCancel)
                }
            }
        }
    }

    private var titleText: String {
        if result.issues.isEmpty {
            return "Transactions not verified"
        }
        return "Statement totals do not match"
    }

    private var messageText: String {
        if isReadOnly {
            let importHelp = " To import transaction history, use CSV, OFX/QFX/QBO, QIF, Excel (XLSX/XLS), or ZIP."
            if result.issues.isEmpty {
                return "DebtScope saved the snapshot only because the statement did not include enough balance data to verify transactions." + importHelp
            }
            return "DebtScope saved the snapshot only because the transactions did not match the statement balances." + importHelp
        }

        if result.issues.isEmpty {
            return "The import includes transactions, but the statement did not provide enough balance information to verify them."
        }
        return "The imported transactions do not reconcile to the beginning and ending balances for one or more accounts."
    }

    private func checkRow(_ label: String, _ value: String, emphasized: Bool = false) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .fontWeight(emphasized ? .semibold : .regular)
                .foregroundStyle(emphasized ? .orange : .primary)
        }
    }

    private func money(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currencyCode
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? NSDecimalNumber(decimal: value).stringValue
    }
}
