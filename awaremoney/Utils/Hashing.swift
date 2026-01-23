//
//  Hashing.swift
//  awaremoney
//
//  Created by Karl Keller on 1/23/26.
//

import Foundation
import CryptoKit

enum Hashing {
    static func hashKey(
        date: Date,
        amount: Decimal,
        payee: String,
        memo: String?,
        symbol: String?,
        quantity: Decimal?
    ) -> String {
        let df = ISO8601DateFormatter()
        let parts: [String] = [
            df.string(from: date),
            NSDecimalNumber(decimal: amount).stringValue,
            payee,
            memo ?? "",
            symbol ?? "",
            quantity.map { NSDecimalNumber(decimal: $0).stringValue } ?? ""
        ]
        let joined = parts.joined(separator: "|")
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }
}
