import Foundation

enum AssistantAccountType: String, Codable, Sendable {
    case checking
    case savings
    case creditCard
    case loan
    case cash
    case brokerage
    case property
    case other
}

enum AssistantPaymentFrequency: String, Codable, Sendable {
    case weekly
    case biweekly
    case semimonthly
    case monthly
    case quarterly
    case semiAnnual
    case annual
    case oneTime
    case socialSecurity
    case other
}

enum AssistantPayoffStrategy: String, Codable, Sendable {
    case minimumsOnly
    case snowball
    case avalanche
}

struct AssistantDebtSummary: Codable, Sendable {
    let generatedAt: Date
    let currencyCode: String
    let debtCount: Int
    let totalDebt: Decimal
    let totalMinimumPayment: Decimal
    let highestAPRDebtName: String?
    let highestAPR: Decimal?
    let accounts: [AssistantDebtAccountSummary]
    let missingDataNotes: [String]
}

struct AssistantDebtAccountSummary: Codable, Sendable {
    let name: String
    let accountType: AssistantAccountType
    let institutionName: String?
    let latestBalance: Decimal
    let latestBalanceDate: Date?
    let apr: Decimal?
    let minimumPayment: Decimal?
    let paymentFrequency: AssistantPaymentFrequency?
    let payoffDate: Date?
    let missingAPR: Bool
    let missingMinimumPayment: Bool
}

struct AssistantCashFlowSummary: Codable, Sendable {
    let generatedAt: Date
    let currencyCode: String
    let monthsCovered: Int
    let incomeItemCount: Int
    let billItemCount: Int
    let monthlyIncome: Decimal
    let monthlyBills: Decimal
    let recurringNet: Decimal
    let nonMonthlyIncomeMonthlyAverage: Decimal
    let reserveAdjustedAvailableForDebt: Decimal?
    let upcomingBills: [AssistantUpcomingBillSummary]
    let missingDataNotes: [String]
}

struct AssistantUpcomingBillSummary: Codable, Sendable {
    let name: String
    let amount: Decimal
    let dueDate: Date?
    let frequency: AssistantPaymentFrequency
    let accountName: String?
    let reserveBalance: Decimal?
    let fundingSourceName: String?
}

struct AssistantPayoffPlanSummary: Codable, Sendable {
    let generatedAt: Date
    let currencyCode: String
    let strategy: AssistantPayoffStrategy
    let startDate: Date
    let debtCount: Int
    let totalStartingDebt: Decimal
    let totalMinimumPayment: Decimal
    let monthlyBudget: Decimal?
    let totalInterest: Decimal
    let projectedDebtFreeDate: Date?
    let payoffOrder: [AssistantPayoffDebtSummary]
    let sourceNote: String
}

struct AssistantPayoffDebtSummary: Codable, Sendable {
    let name: String
    let accountType: AssistantAccountType
    let startingBalance: Decimal
    let apr: Decimal?
    let minimumPayment: Decimal
    let payoffDate: Date?
    let orderIndex: Int
}

struct AssistantNetWorthSummary: Codable, Sendable {
    let generatedAt: Date
    let currencyCode: String
    let accountCount: Int
    let totalAssets: Decimal
    let totalLiabilities: Decimal
    let totalNetWorth: Decimal
    let accounts: [AssistantNetWorthAccountSummary]
}

struct AssistantNetWorthAccountSummary: Codable, Sendable {
    let name: String
    let accountType: AssistantAccountType
    let institutionName: String?
    let value: Decimal
    let latestBalanceDate: Date?
}

struct AssistantImportSummary: Codable, Sendable {
    let generatedAt: Date
    let importCount: Int
    let latestImportDate: Date?
    let latestImportLabel: String?
    let latestParserName: String?
    let importedAccountCount: Int
    let importedBalanceCount: Int
    let importedTransactionCount: Int
    let importedHoldingCount: Int
    let userEditedTransactionCount: Int
    let excludedTransactionCount: Int
}

struct AssistantTransactionPatternSummary: Codable, Sendable {
    let generatedAt: Date
    let currencyCode: String
    let daysCovered: Int
    let transactionCount: Int
    let totalIncome: Decimal
    let totalSpending: Decimal
    let topMerchantsBySpend: [AssistantMerchantSpendSummary]
    let spendingByMonth: [AssistantMonthlyAmountSummary]
    let largeTransactions: [AssistantLargeTransactionSummary]
    let repeatedCharges: [AssistantRepeatedChargeSummary]
    let includesIndividualTransactions: Bool
}

struct AssistantMerchantSpendSummary: Codable, Sendable {
    let merchantName: String
    let transactionCount: Int
    let totalSpend: Decimal
}

struct AssistantMonthlyAmountSummary: Codable, Sendable {
    let monthStartDate: Date
    let amount: Decimal
}

struct AssistantLargeTransactionSummary: Codable, Sendable {
    let date: Date
    let payee: String
    let amount: Decimal
    let accountName: String?
}

struct AssistantRepeatedChargeSummary: Codable, Sendable {
    let payee: String
    let amount: Decimal
    let transactionCount: Int
    let mostRecentDate: Date
}
