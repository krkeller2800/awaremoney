import Foundation

struct BackupManifest: Decodable {
    let version: Int
    let generatedAt: Date
    let accounts: [BackupAccount]
    let transactions: [BackupTransaction]
    let balanceSnapshots: [BackupBalanceSnapshot]
    let importBatches: [BackupImportBatch]

    var transactionCountsByAccountID: [UUID: Int] {
        Dictionary(grouping: transactions.compactMap(\.accountID), by: { $0 }).mapValues(\.count)
    }

    var balanceCountsByAccountID: [UUID: Int] {
        Dictionary(grouping: balanceSnapshots.compactMap(\.accountID), by: { $0 }).mapValues(\.count)
    }

    var transactionCountsByBatchID: [UUID: Int] {
        Dictionary(grouping: transactions.compactMap(\.importBatchID), by: { $0 }).mapValues(\.count)
    }

    var balanceCountsByBatchID: [UUID: Int] {
        Dictionary(grouping: balanceSnapshots.compactMap(\.importBatchID), by: { $0 }).mapValues(\.count)
    }
}

struct BackupAccount: Decodable {
    let id: UUID
    let name: String
    let typeRaw: String
    let assetCategoryRaw: String?
    let institutionName: String?
    let currencyCode: String
    let last4: String?
    let createdAt: Date
    let loanTerms: BackupLoanTerms?
    let creditCardPaymentModeRaw: String?
}

struct BackupLoanTerms: Decodable {
    let apr: Decimal?
    let aprScale: Int?
    let paymentAmount: Decimal?
    let paymentDayOfMonth: Int?
    let frequencyRaw: String
}

struct BackupTransaction: Decodable {
    let id: UUID
    let accountID: UUID?
    let importBatchID: UUID?
    let datePosted: Date
    let amount: Decimal
    let payee: String
    let memo: String?
    let kindRaw: String?
    let isExcluded: Bool
    let isUserEdited: Bool?
    let isUserModified: Bool
    let originalAmount: Decimal?
    let originalDate: Date?
    let hashKey: String
    let importHashKey: String?
    let symbol: String?
    let quantity: Decimal?
}

struct BackupBalanceSnapshot: Decodable {
    let id: UUID
    let accountID: UUID?
    let importBatchID: UUID?
    let asOfDate: Date
    let balance: Decimal
    let interestRateAPR: Decimal?
    let interestRateScale: Int?
    let isExcluded: Bool
    let isUserModified: Bool
}

struct BackupImportBatch: Decodable {
    let id: UUID
    let createdAt: Date
    let label: String
    let sourceFileName: String
    let parserId: String?
}
