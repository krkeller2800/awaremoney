//
//  Security.swift
//  awaremoney
//
//  Created by Karl Keller on 1/23/26.
//

import Foundation
import SwiftData

@Model
final class Security {
    @Attribute(.unique) var symbol: String
    var name: String?

    init(symbol: String, name: String? = nil) {
        self.symbol = symbol
        self.name = name
    }
}
