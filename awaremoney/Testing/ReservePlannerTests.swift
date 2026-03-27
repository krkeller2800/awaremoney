#if canImport(Testing)
import Foundation
import Testing
@testable import awaremoney

@Suite("Reserve Planner Tests")
struct ReservePlannerTests {
    // Helper to build deterministic dates
    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        let cal = Calendar.current
        return cal.date(from: comps) ?? Date()
    }

    @Test("Yearly bill: seed and monthly contribution math")
    func yearlySeedMath() throws {
        // Yearly bill $1200 due on the 15th; as of Dec 1 => 1 month until due
        let item = CashFlowItem(
            kind: .bill,
            name: "Insurance",
            amount: 1200,
            frequency: .yearly,
            dayOfMonth: 15,
            firstPaymentDate: nil,
            notes: nil,
            ssaWednesday: nil,
            account: nil,
            createdAt: date(2024, 1, 1)
        )
        let asOf = date(2024, 12, 1)
        let plan = BillReservePlanner.planReserve(for: item, asOf: asOf, currentReserve: 0)
        #expect(plan != nil)
        #expect(plan?.monthlyContribution == 100)   // 1200 / 12
        #expect(plan?.seedAmount == 1100)          // missing 11 months
    }

    @Test("Quarterly bill: no seed when full cycle remains")
    func quarterlyNoSeedWhenFullCycleRemains() throws {
        // Quarterly $600 due on the 15th; as of Oct 16 => next due Jan 15 (3 months away)
        // Expect monthly = 600/3 = 200; seed = 0
        let item = CashFlowItem(
            kind: .bill,
            name: "Property Tax",
            amount: 600,
            frequency: .quarterly,
            dayOfMonth: 15,
            firstPaymentDate: nil,
            notes: nil,
            ssaWednesday: nil,
            account: nil,
            createdAt: date(2024, 1, 1)
        )
        let asOf = date(2024, 10, 16)
        let plan = BillReservePlanner.planReserve(for: item, asOf: asOf, currentReserve: 0)
        #expect(plan != nil)
        #expect(plan?.monthlyContribution == 200)
        #expect(plan?.seedAmount == 0)
    }
}
#endif
