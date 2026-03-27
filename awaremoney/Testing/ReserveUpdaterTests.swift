#if canImport(Testing)
import Foundation
import SwiftData
import Testing
@testable import awaremoney

@Suite("Reserve Updater Tests")
@MainActor
struct ReserveUpdaterTests {
    // MARK: - Helpers
    private func makeInMemoryContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: CashFlowItem.self, Account.self, configurations: config)
        return ModelContext(container)
    }

    private func makeSettings() -> SettingsStore {
        let s = SettingsStore()
        s.useReserveProcessingForBills = true
        s.lastReserveUpdateMonth = nil
        return s
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var comps = DateComponents()
        comps.year = y
        comps.month = m
        comps.day = d
        return Calendar.current.date(from: comps) ?? Date()
    }

    // Build a non-monthly bill eligible for reserve processing
    private func makeBill(name: String, amount: Decimal, frequency: PaymentFrequency, dueDay: Int, createdAt: Date) -> CashFlowItem {
        let item = CashFlowItem(
            kind: .bill,
            name: name,
            amount: amount,
            frequency: frequency,
            dayOfMonth: dueDay,
            firstPaymentDate: nil,
            notes: nil,
            ssaWednesday: nil,
            account: nil,
            createdAt: createdAt
        )
        item.reserveAutoEnabled = true
        return item
    }

    // MARK: - Tests

    @Test("Idempotence within same month: contributions apply once")
    func idempotenceSameMonth() async throws {
        let context = try makeInMemoryContext()
        let settings = makeSettings()
        let service = ReserveUpdateService(context: context, settings: settings)

        // Yearly bill $1200 due on the 15th; created Jan 1
        let bill = makeBill(name: "Insurance", amount: 1200, frequency: .yearly, dueDay: 15, createdAt: date(2024, 1, 1))
        context.insert(bill)
        try context.save()

        // As of Dec 1, 2024: expect seed 1100 and monthly 100, applied once
        let asOf = date(2024, 12, 1)
        service.updateReserves(asOf: asOf)
        let firstBalance = bill.reserveBalance
        #expect(firstBalance == 1200) // 1100 seed + 100 monthly

        // Call again within the same month — no additional contributions
        service.updateReserves(asOf: date(2024, 12, 15))
        #expect(bill.reserveBalance == firstBalance)
    }

    @Test("Seed only once per cycle; monthly once per month")
    func seedOncePerCycleAndMonthlyOncePerMonth() async throws {
        let context = try makeInMemoryContext()
        let settings = makeSettings()
        let service = ReserveUpdateService(context: context, settings: settings)

        let bill = makeBill(name: "Insurance", amount: 1200, frequency: .yearly, dueDay: 15, createdAt: date(2024, 1, 1))
        context.insert(bill)
        try context.save()

        // December run (12/01): seed 1100 + monthly 100
        service.updateReserves(asOf: date(2024, 12, 1))
        #expect(bill.reserveBalance == 1200)
        let seededStart = bill.reserveCycleStart
        #expect(bill.reserveLastSeededCycleStart == seededStart)

        // Another run in December should not add more
        service.updateReserves(asOf: date(2024, 12, 20))
        #expect(bill.reserveBalance == 1200)
        #expect(bill.reserveLastSeededCycleStart == seededStart)

        // January run (01/01): monthly 100, no seed because same cycle
        settings.lastReserveUpdateMonth = nil // simulate new month to allow contributions
        service.updateReserves(asOf: date(2025, 1, 1))
        #expect(bill.reserveBalance == 1300)
        #expect(bill.reserveLastSeededCycleStart == seededStart)
    }

    @Test("Settlement on due date deducts and advances cycle")
    func settlementAndCycleAdvance() async throws {
        let context = try makeInMemoryContext()
        let settings = makeSettings()
        let service = ReserveUpdateService(context: context, settings: settings)

        // Quarterly bill $300 due on 15th; start in Oct, due next Jan 15
        let bill = makeBill(name: "Property Tax", amount: 300, frequency: .quarterly, dueDay: 15, createdAt: date(2024, 10, 1))
        context.insert(bill)
        try context.save()

        // December 1: two months into cycle => seed 200 + monthly 100 => balance 300
        service.updateReserves(asOf: date(2024, 12, 1))
        #expect(bill.reserveBalance == 300)

        // January 1: monthly 100 => balance 400 (no seed; same cycle)
        settings.lastReserveUpdateMonth = nil
        service.updateReserves(asOf: date(2025, 1, 1))
        #expect(bill.reserveBalance == 400)

        // On due date Jan 15: settlement deducts 300 and advances cycle start to Jan 15; seeded marker cleared
        let beforeCycleStart = bill.reserveCycleStart
        service.updateReserves(asOf: date(2025, 1, 15))
        #expect(bill.reserveBalance == 100)
        #expect(bill.reserveCycleStart != beforeCycleStart)
        #expect(bill.reserveLastSeededCycleStart == nil)

        // Calling again same day should be idempotent for settlement
        let balanceAfterSettle = bill.reserveBalance
        service.updateReserves(asOf: date(2025, 1, 15))
        #expect(bill.reserveBalance == balanceAfterSettle)
    }
}
#endif
