//
//  ImportTypes.swift
//  awaremoney
//
//  Created by Karl Keller on 1/23/26.
//


import Foundation

struct StagedTransaction: Identifiable, Hashable {
    let id = UUID()
    var datePosted: Date
    var amount: Decimal
    var payee: String
    var memo: String?
    var kind: Transaction.Kind
    var externalId: String?
    var symbol: String?
    var quantity: Decimal?
    var price: Decimal?
    var fees: Decimal?
    var hashKey: String
    var sourceAccountLabel: String? = nil
    var include: Bool = true
}

struct StagedHolding: Identifiable, Hashable {
    let id = UUID()
    var asOfDate: Date
    var symbol: String
    var quantity: Decimal
    var marketValue: Decimal?
    var include: Bool = true
}

struct StagedBalance: Identifiable, Hashable {
    let id = UUID()
    var asOfDate: Date
    var balance: Decimal
    var include: Bool = true
}

struct StagedImport {
    var parserId: String
    var sourceFileName: String
    var suggestedAccountType: Account.AccountType?
    var transactions: [StagedTransaction]
    var holdings: [StagedHolding]
    var balances: [StagedBalance]
}

protocol StatementParser {
    static var id: String { get }
    func canParse(headers: [String]) -> Bool
    func parse(rows: [[String]], headers: [String]) throws -> StagedImport
}

enum ImportError: Error, LocalizedError {
    case unknownFormat
    case invalidCSV
    case parseFailure(String)

    var errorDescription: String? {
        switch self {
        case .unknownFormat: return "Unknown file format."
        case .invalidCSV: return "Invalid or unreadable CSV."
        case .parseFailure(let msg): return msg
        }
    }
}

