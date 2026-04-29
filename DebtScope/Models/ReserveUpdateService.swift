import Foundation
import SwiftData

@MainActor
final class ReserveUpdateService {
    private let context: ModelContext
    private let settings: SettingsStore
    private let calendar = Calendar.current

    init(context: ModelContext, settings: SettingsStore) {
        self.context = context
        self.settings = settings
    }

    /// Runs the monthly reserve update with two distinct phases:
    /// - Contributions (seed and monthly) run once per calendar month.
    /// - Settlement runs every time, idempotently, and can advance multiple cycles if overdue.
    /// - Settlement never deducts below zero; balance deductions only occur if sufficient reserve.
    /// - Advancing cycle clears the seeded marker allowing seed on next cycle.
    /// - Parameter today: The date to treat as "now" (defaults to current date).
    func updateReserves(asOf today: Date = Date()) {
        // Global kill-switch for reserve processing
        guard settings.useReserveProcessingForBills else { return }

        let monthKey = Self.monthKey(for: today)
        let shouldRunContribution = (settings.lastReserveUpdateMonth != monthKey)

        do {
            var anyChanges = false
            // Fetch all items and filter eligible bills in-memory for clarity
            let items = try context.fetch(FetchDescriptor<CashFlowItem>())
            let eligibleBills = items.filter { item in
                item.kind == .bill && (item.reserveAutoEnabled) && item.frequency.normalized.isReserveEligible
            }

            for bill in eligibleBills {
                // Resolve cycle start (persist if not set)
                let resolvedStart = resolveCurrentCycleStart(for: bill, asOf: today)
                if bill.reserveCycleStart == nil { bill.reserveCycleStart = resolvedStart }

                let plan = planReserve(for: bill, asOf: today, currentReserve: bill.reserveBalance, currentCycleStart: resolvedStart)

                if shouldRunContribution {
                    // Apply seed once per cycle
                    if bill.reserveLastSeededCycleStart != resolvedStart {
                        let seed = plan.seedAmount
                        if seed > 0 {
                            bill.reserveBalance = (bill.reserveBalance + seed).rounded(2)
                            anyChanges = true
                        }
                        bill.reserveLastSeededCycleStart = resolvedStart
                    }

                    // Apply monthly contribution once per calendar month
                    if plan.monthlyContribution > 0 {
                        bill.reserveBalance = (bill.reserveBalance + plan.monthlyContribution).rounded(2)
                        anyChanges = true
                    }
                }

                // Settlement phase always runs and is idempotent, can advance multiple cycles if overdue
                let freqMonths = plan.frequencyMonths
                let dueDay = dueDay(for: bill)
                var currentStart = bill.reserveCycleStart ?? resolvedStart
                var nextDueDate = Self.addMonthsClamped(currentStart, months: freqMonths, day: dueDay)
                for _ in 0..<24 {
                    if today < nextDueDate || currentStart >= nextDueDate {
                        break
                    }
                    if bill.reserveBalance >= bill.amount {
                        bill.reserveBalance = (bill.reserveBalance - bill.amount).rounded(2)
                        anyChanges = true
                        AMLogging.log("ReserveUpdate: settled \(bill.name) on due date \(nextDueDate)", component: "ReserveUpdate")
                    } else {
                        AMLogging.log("ReserveUpdate: shortfall for \(bill.name) on due date \(nextDueDate) — reserve=\(bill.reserveBalance) amount=\(bill.amount)", component: "ReserveUpdate")
                    }
                    bill.reserveCycleStart = nextDueDate
                    bill.reserveLastSeededCycleStart = nil
                    anyChanges = true

                    currentStart = nextDueDate
                    nextDueDate = Self.addMonthsClamped(currentStart, months: freqMonths, day: dueDay)
                }
            }

            if anyChanges {
                try context.save()
            }
            if shouldRunContribution {
                settings.lastReserveUpdateMonth = monthKey
            }
        } catch {
            // For now, swallow errors to avoid interrupting app flow.
            // Consider logging via any existing logging utility if available.
        }
    }

    // MARK: - Planning

    struct ReservePlan {
        let monthlyContribution: Decimal
        let seedAmount: Decimal
        let nextDueDate: Date
        let frequencyMonths: Int
    }

    private func planReserve(for bill: CashFlowItem, asOf today: Date, currentReserve: Decimal, currentCycleStart: Date) -> ReservePlan {
        let freqMonths = max(1, bill.frequency.normalized.monthsPerCycle)
        let monthlyContribution = (bill.amount / Decimal(freqMonths)).rounded(2)

        // Seed logic: catch up to what should have been saved by the start of the current calendar month
        let startOfThisMonth = Self.startOfMonth(today)
        let monthsElapsedInCycle = max(0, Self.monthsBetween(currentCycleStart, startOfThisMonth))
        let expectedByStartOfThisMonth = (monthlyContribution * Decimal(monthsElapsedInCycle)).rounded(2)
        let seedAmount = max(0, (expectedByStartOfThisMonth - currentReserve)).rounded(2)

        let nextDueReal = Self.addMonthsClamped(currentCycleStart, months: freqMonths, day: dueDay(for: bill))

        return ReservePlan(
            monthlyContribution: monthlyContribution,
            seedAmount: seedAmount,
            nextDueDate: nextDueReal,
            frequencyMonths: freqMonths
        )
    }

    // MARK: - Cycle start / due helpers

    private func resolveCurrentCycleStart(for bill: CashFlowItem, asOf today: Date) -> Date {
        if let s = bill.reserveCycleStart { return s }
        // Fallback to inferred previous due date if not set
        let anchorMonth = anchorMonthForSchedule(of: bill)
        let day = dueDay(for: bill)
        return Self.previousDueDate(anchorMonth: anchorMonth, day: day, frequencyMonths: max(1, bill.frequency.normalized.monthsPerCycle), asOf: today)
    }

    private func dueDay(for bill: CashFlowItem) -> Int {
        if let d = bill.dayOfMonth, (1...31).contains(d) { return d }
        if let first = bill.firstPaymentDate { return calendar.component(.day, from: first) }
        return calendar.component(.day, from: bill.createdAt)
    }

    private func anchorMonthForSchedule(of bill: CashFlowItem) -> Int {
        // Month of firstPaymentDate if available; else createdAt's month; clamp 1...12
        if let first = bill.firstPaymentDate { return calendar.component(.month, from: first) }
        return calendar.component(.month, from: bill.createdAt)
    }

    static func previousDueDate(anchorMonth: Int, day: Int, frequencyMonths: Int, asOf: Date) -> Date {
        // Use month-index math to align to the schedule anchored at (anchorMonth, day)
        let asOfIndex = Self.monthIndex(for: asOf)
        // Construct an anchor index in the same year as asOf to compute offset safely
        let anchorYear = Calendar.current.component(.year, from: asOf)
        let anchorIndex = anchorYear * 12 + max(1, min(12, anchorMonth))
        var offset = (asOfIndex - anchorIndex) % frequencyMonths
        if offset < 0 { offset += frequencyMonths }
        var dueIndex = asOfIndex - offset
        // If the computed due date in this month is actually after 'asOf' (because day is later), step back one cycle
        let dueYear = dueIndex / 12
        let dueMonth = dueIndex % 12
        let candidate = Self.dateFrom(year: dueYear, month: max(1, dueMonth), day: day)
        if candidate > asOf {
            dueIndex -= frequencyMonths
        }
        let finalYear = dueIndex / 12
        let finalMonth = dueIndex % 12
        return Self.dateFrom(year: finalYear, month: max(1, finalMonth), day: day)
    }

    /// Public helper to compute the previous due date under a given schedule.
    /// - Parameters:
    ///   - anchorMonth: Anchor month for the schedule (1...12), typically the month of firstPaymentDate or createdAt.
    ///   - day: Due day within the month (1...31; clamped to valid days for the target month).
    ///   - frequencyMonths: Months per cycle (e.g., 3 for quarterly, 12 for yearly).
    ///   - asOf: Reference date.
    /// - Returns: The previous due date (cycle start) at or before `asOf` according to the schedule.
    static func previousDueDateForSchedule(anchorMonth: Int, day: Int, frequencyMonths: Int, asOf: Date) -> Date {
        return Self.previousDueDate(anchorMonth: anchorMonth, day: day, frequencyMonths: frequencyMonths, asOf: asOf)
    }

    private static func addMonthsClamped(_ date: Date, months: Int, day: Int) -> Date {
        guard months != 0 else { return date }
        let comps = Calendar.current.dateComponents([.year, .month], from: date)
        let base = Calendar.current.date(from: comps) ?? date
        guard let advanced = Calendar.current.date(byAdding: .month, value: months, to: base) else { return date }
        let y = Calendar.current.component(.year, from: advanced)
        let m = Calendar.current.component(.month, from: advanced)
        return Self.dateFrom(year: y, month: m, day: day)
    }

    // MARK: - Date math helpers

    private static func startOfMonth(_ date: Date) -> Date {
        let comps = Calendar.current.dateComponents([.year, .month], from: date)
        return Calendar.current.date(from: comps) ?? date
    }

    private static func monthKey(for date: Date) -> String {
        let cal = Calendar.current
        let y = cal.component(.year, from: date)
        let m = cal.component(.month, from: date)
        return String(format: "%04d-%02d", y, m)
    }

    private static func monthIndex(for date: Date) -> Int {
        let y = Calendar.current.component(.year, from: date)
        let m = Calendar.current.component(.month, from: date)
        return y * 12 + m
    }

    private static func monthsBetween(_ start: Date, _ end: Date) -> Int {
        let s = Self.monthIndex(for: start)
        let e = Self.monthIndex(for: end)
        return e - s
    }

    private static func dateFrom(year: Int, month: Int, day: Int) -> Date {
        let clampedMonth = max(1, min(12, month))
        var comps = DateComponents()
        comps.year = year
        comps.month = clampedMonth
        // Clamp day to actual number of days in month
        let firstOfMonth = Calendar.current.date(from: comps) ?? Date()
        let range = Calendar.current.range(of: .day, in: .month, for: firstOfMonth) ?? 1..<29
        let clampedDay = max(1, min(range.count, day))
        comps.day = clampedDay
        return Calendar.current.date(from: comps) ?? firstOfMonth
    }
}

private extension Decimal {
    func rounded(_ scale: Int, mode: NSDecimalNumber.RoundingMode = .bankers) -> Decimal {
        var value = self
        var result = Decimal()
        NSDecimalRound(&result, &value, scale, mode)
        return result
    }
}
