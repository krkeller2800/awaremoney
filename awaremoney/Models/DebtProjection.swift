//
//  DebtProjection.swift
//  awaremoney
//
//  Created by Assistant on 2/1/26
//

import Foundation

struct DebtProjectionPoint: Identifiable, Hashable {
    let id = UUID()
    let date: Date
    let balance: Decimal
    let principalPaid: Decimal
    let interestPaid: Decimal
}

enum DebtKind {
    case loan
    case creditCard(CreditCardPaymentMode)
}

enum DebtProjectionError: Error {
    case missingAPR
    case missingPayment
}

struct DebtProjectionEngine {
    // Simple monthly projection for liabilities
    static func project(
        kind: DebtKind,
        startingBalance: Decimal,
        apr: Decimal?, // fraction (0.1999 for 19.99%)
        payment: Decimal?,
        startDate: Date = Date(),
        maxMonths: Int = 600
    ) throws -> [DebtProjectionPoint] {
        switch kind {
        case .loan:
            guard let apr = apr else { throw DebtProjectionError.missingAPR }
            guard let payment = payment else { throw DebtProjectionError.missingPayment }
            return amortize(
                startingBalance: startingBalance,
                monthlyRate: apr / 12,
                monthlyPayment: payment,
                startDate: startDate,
                maxMonths: maxMonths
            )
        case .creditCard(let mode):
            guard let apr = apr else { throw DebtProjectionError.missingAPR }
            let r = apr / 12
            switch mode {
            case .payInFull:
                // Pay to zero next cycle
                let interest = (startingBalance * r)
                let next = DebtProjectionPoint(date: startDate, balance: startingBalance, principalPaid: 0, interestPaid: 0)
                let payoff = DebtProjectionPoint(date: Calendar.current.date(byAdding: .month, value: 1, to: startDate) ?? startDate, balance: 0, principalPaid: startingBalance, interestPaid: interest)
                return [next, payoff]
            case .fixedAmount:
                guard let payment = payment else { throw DebtProjectionError.missingPayment }
                return amortize(
                    startingBalance: startingBalance,
                    monthlyRate: r,
                    monthlyPayment: payment,
                    startDate: startDate,
                    maxMonths: maxMonths
                )
            case .minimum:
                // Assume 2% minimum or $25, whichever greater, if payment unspecified
                let assumedMin: Decimal = 0.02
                let floor: Decimal = 25
                let minPay = max((startingBalance * assumedMin), floor)
                return amortize(
                    startingBalance: startingBalance,
                    monthlyRate: r,
                    monthlyPayment: payment ?? minPay,
                    startDate: startDate,
                    maxMonths: maxMonths
                )
            }
        }
    }

    private static func amortize(
        startingBalance: Decimal,
        monthlyRate: Decimal,
        monthlyPayment: Decimal,
        startDate: Date,
        maxMonths: Int
    ) -> [DebtProjectionPoint] {
        var points: [DebtProjectionPoint] = []
        var bal = startingBalance
        var date = startDate
        let cal = Calendar.current
        var months = 0
        while bal > 0 && months < maxMonths {
            let interest = (bal * monthlyRate)
            let principal = max(monthlyPayment - interest, 0)
            let nextBal = max(bal - principal, 0)
            points.append(DebtProjectionPoint(date: date, balance: bal, principalPaid: principal, interestPaid: interest))
            bal = nextBal
            date = cal.date(byAdding: .month, value: 1, to: date) ?? date
            months += 1
            if principal == 0 { break } // prevent infinite loop if payment <= interest
        }
        // Append terminal point at payoff
        if let last = points.last, last.balance > 0 {
            points.append(DebtProjectionPoint(date: date, balance: bal, principalPaid: 0, interestPaid: 0))
        }
        return points
    }
}
