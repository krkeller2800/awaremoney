#if canImport(XCTest)
import Foundation
import XCTest
@testable import DebtScope

final class BillReservePlannerTests: XCTestCase {
    private func makeBill(amount: Decimal, freq: PaymentFrequency, day: Int? = nil, first: Date? = nil) -> CashFlowItem {
        CashFlowItem(kind: .bill, name: "Test Bill", amount: amount, frequency: freq, dayOfMonth: day, firstPaymentDate: first)
    }

    func testMonthsPerCycle() throws {
        XCTAssertEqual(PaymentFrequency.quarterly.monthsPerCycle, 3)
        XCTAssertEqual(PaymentFrequency.semiAnnual.monthsPerCycle, 6)
        XCTAssertEqual(PaymentFrequency.yearly.monthsPerCycle, 12)
        XCTAssertEqual(PaymentFrequency.annual.monthsPerCycle, 12)
        XCTAssertEqual(PaymentFrequency.monthly.monthsPerCycle, 1)
    }

    func testNextDueBasic() throws {
        // asOf Jan 15, 2026; quarterly bill due on day 10
        var comps = DateComponents(); comps.year = 2026; comps.month = 1; comps.day = 15
        let asOf = Calendar.current.date(from: comps)!
        let item = makeBill(amount: 120, freq: .quarterly, day: 10)
        let res = BillReservePlanner.nextDue(for: item, asOf: asOf)
        XCTAssertTrue(res.nextDueDate > asOf)
        XCTAssertGreaterThanOrEqual(res.monthsUntilDue, 1)
    }

    func testPlanReserveYearly() throws {
        // asOf Jan 1, 2026; firstPaymentDate May 1, 2026 (4 months ahead)
        var asOfC = DateComponents(); asOfC.year = 2026; asOfC.month = 1; asOfC.day = 1
        let asOf = Calendar.current.date(from: asOfC)!
        var dueC = DateComponents(); dueC.year = 2026; dueC.month = 5; dueC.day = 1
        let due = Calendar.current.date(from: dueC)!
        let item = makeBill(amount: 600, freq: .yearly, first: due)
        let plan = BillReservePlanner.planReserve(for: item, asOf: asOf, currentReserve: 0)
        let expectedMonthly: Decimal = 50
        let expectedSeed: Decimal = 400 // missing months = 12 - 4 = 8; 8 * 50 = 400
        XCTAssertNotNil(plan)
        XCTAssertEqual(plan?.monthlyContribution, expectedMonthly)
        XCTAssertEqual(plan?.seedAmount, expectedSeed)
    }

    func testPlanReserveQuarterly() throws {
        // asOf Jan 1, 2026; next due Feb 1, 2026
        var asOfC = DateComponents(); asOfC.year = 2026; asOfC.month = 1; asOfC.day = 1
        let asOf = Calendar.current.date(from: asOfC)!
        var dueC = DateComponents(); dueC.year = 2026; dueC.month = 2; dueC.day = 1
        let due = Calendar.current.date(from: dueC)!
        let item = makeBill(amount: 120, freq: .quarterly, first: due)
        let plan = BillReservePlanner.planReserve(for: item, asOf: asOf, currentReserve: 30)
        let expectedMonthly: Decimal = (120 - 30) / 3 // 30
        let expectedSeed: Decimal = expectedMonthly * 2 // missing months = 3 - 1 = 2
        XCTAssertNotNil(plan)
        XCTAssertEqual(plan?.monthlyContribution, expectedMonthly)
        XCTAssertEqual(plan?.seedAmount, expectedSeed)
    }

    func testPlanReserveFullyFunded() throws {
        let item = makeBill(amount: 100, freq: .yearly, day: 15)
        let plan = BillReservePlanner.planReserve(for: item, asOf: Date(), currentReserve: 100)
        XCTAssertEqual(plan?.monthlyContribution, 0)
        XCTAssertEqual(plan?.seedAmount, 0)
    }
}
#endif
