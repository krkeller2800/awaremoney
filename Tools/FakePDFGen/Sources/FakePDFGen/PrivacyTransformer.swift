import Foundation

struct PrivacyTransformer {
    private let seed: String
    private let personas: [SamplePersona] = [
        SamplePersona(
            issuerName: "Northstar Credit Union",
            shortIssuerName: "Northstar",
            customerName: "Jordan Morgan",
            customerAddress: ["1842 Cedar Ridge Ave", "Springfield, OH 45502"]
        ),
        SamplePersona(
            issuerName: "Harborview Bank",
            shortIssuerName: "Harbor",
            customerName: "Taylor Reed",
            customerAddress: ["731 Maple Harbor Dr", "Columbus, OH 43215"]
        ),
        SamplePersona(
            issuerName: "Summit Trail Finance",
            shortIssuerName: "Summit",
            customerName: "Casey Bennett",
            customerAddress: ["5086 Linden Park Way", "Dayton, OH 45402"]
        ),
        SamplePersona(
            issuerName: "Crescent Valley Lending",
            shortIssuerName: "Crescent",
            customerName: "Avery Collins",
            customerAddress: ["269 Willow Creek Ln", "Cincinnati, OH 45202"]
        )
    ]

    private let checkingCreditDescriptions = [
        "Payroll Deposit - Northstar Design Co",
        "Mobile Deposit",
        "Online Transfer Credit",
        "Refund Credit",
        "Courtesy Credit"
    ]

    private let checkingDebitDescriptions = [
        "Grocery Market Purchase",
        "Utility Bill Payment",
        "Pharmacy Purchase",
        "Restaurant Purchase",
        "Fuel Station Purchase",
        "Insurance Payment",
        "Hardware Store Purchase"
    ]

    private let creditCardCreditDescriptions = [
        "Card Payment Received",
        "Online Payment Received",
        "Autopay Payment Received",
        "Customer Payment Received"
    ]

    private let creditCardDebitDescriptions = [
        "Home Supply Purchase",
        "Travel Booking",
        "Subscription Renewal",
        "Dining Purchase",
        "Grocery Purchase",
        "Electronics Purchase",
        "Interest Charge",
        "Online Retail Purchase"
    ]

    private let loanCreditDescriptions = [
        "Scheduled Payment",
        "Additional Principal Payment",
        "Principal Adjustment",
        "Automatic Payment"
    ]

    private let loanDebitDescriptions = [
        "Principal Adjustment",
        "Interest Charge",
        "Escrow Adjustment",
        "Payment Reversal",
        "Servicing Fee"
    ]

    init(seed: String) {
        self.seed = seed
    }

    func persona(for index: Int) -> SamplePersona {
        personas[stableIndex("persona-\(index)", count: personas.count)]
    }

    func accountName(for kind: StatementKind, index: Int) -> String {
        let brand = persona(for: index).shortIssuerName

        switch kind {
        case .checking:
            let role = ["Checking", "Bills", "Reserve"][stableIndex("checking-\(index)", count: 3)]
            return "\(brand) \(role)"
        case .creditCard:
            let role = ["Card", "Travel", "Rewards"][stableIndex("card-\(index)", count: 3)]
            return "\(brand) \(role)"
        case .autoLoan:
            let role = ["Auto", "Vehicle", "Car Loan"][stableIndex("auto-\(index)", count: 3)]
            return "\(brand) \(role)"
        case .mortgage:
            let role = ["Home", "Mortgage", "House Loan"][stableIndex("mortgage-\(index)", count: 3)]
            return "\(brand) \(role)"
        case .genericLoan:
            let role = ["Loan", "Installment", "Personal"][stableIndex("loan-\(index)", count: 3)]
            return "\(brand) \(role)"
        }
    }

    func accountLast4(for index: Int) -> String {
        let value = 1000 + stableIndex("last4-\(index)", count: 9000)
        return String(value)
    }

    func amountScale(for index: Int) -> Double {
        let raw = stableIndex("scale-\(index)", count: 91)
        return 0.35 + (Double(raw) / 100.0)
    }

    func openingBalance(for kind: StatementKind, index: Int) -> Double {
        let offset = Double(stableIndex("opening-\(index)", count: 250_000)) / 100.0
        switch kind {
        case .checking:
            return rounded(750.0 + offset)
        case .creditCard:
            return rounded(900.0 + offset)
        case .autoLoan:
            return rounded(8_000.0 + offset)
        case .mortgage:
            return rounded(165_000.0 + (offset * 20.0))
        case .genericLoan:
            return rounded(2_500.0 + offset)
        }
    }

    func description(for transaction: BackupTransaction, kind: StatementKind, index: Int) -> String {
        let isCredit = transaction.amount.doubleValue >= 0
        let descriptions: [String]
        switch kind {
        case .checking:
            descriptions = isCredit ? checkingCreditDescriptions : checkingDebitDescriptions
        case .creditCard:
            descriptions = isCredit ? creditCardCreditDescriptions : creditCardDebitDescriptions
        case .autoLoan, .mortgage, .genericLoan:
            descriptions = isCredit ? loanCreditDescriptions : loanDebitDescriptions
        }

        let direction = isCredit ? "credit" : "debit"
        let descriptionIndex = stableIndex("description-\(kind.rawValue)-\(direction)-\(index)", count: descriptions.count)
        return descriptions[descriptionIndex]
    }

    private func stableIndex(_ value: String, count: Int) -> Int {
        precondition(count > 0)
        let hash = StableHash.hash("\(seed)-\(value)")
        return Int(hash % UInt64(count))
    }

    private func rounded(_ value: Double) -> Double {
        (value * 100.0).rounded() / 100.0
    }
}

struct SamplePersona {
    let issuerName: String
    let shortIssuerName: String
    let customerName: String
    let customerAddress: [String]
}

private enum StableHash {
    static func hash(_ string: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }
}
