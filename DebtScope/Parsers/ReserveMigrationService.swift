import Foundation
import SwiftData

struct ReserveMigrationService {
    /// One-time initialization of reserve cycle anchors for eligible non-monthly bills.
    /// - Parameters:
    ///   - container: The app's SwiftData model container.
    ///   - settings: Settings store used to gate one-time execution.
    ///   - asOf: Reference date for computing the next due date (defaults to today).
    static func initializeReserveAnchorsIfNeeded(container: ModelContainer, settings: SettingsStore, asOf: Date = Date()) {
        // Skip if already done
        if settings.didInitializeReserveAnchors {
            AMLogging.log("ReserveMigration: already initialized; skipping", component: "ReserveMigration")
            return
        }

        AMLogging.log("ReserveMigration: starting initialization", component: "ReserveMigration")
        let context = ModelContext(container)
        do {
            // Fetch bills with no reserveCycleStart yet
            let predicate = #Predicate<CashFlowItem> { item in
                (item.kindRaw != "income") && (item.reserveCycleStart == nil)
            }
            var desc = FetchDescriptor<CashFlowItem>(predicate: predicate)
            desc.sortBy = [SortDescriptor(\CashFlowItem.createdAt, order: .forward)]
            let candidates = try context.fetch(desc)
            AMLogging.log("ReserveMigration: found \(candidates.count) candidate bill(s) with nil reserveCycleStart", component: "ReserveMigration")

            var updated = 0
            let cal = Calendar.current
            for item in candidates {
                // Redundant guard and eligibility check
                if item.kind == .income { continue }
                if !item.frequency.isReserveEligible { continue }

                // Compute previous cycle start as (nextDue - monthsPerCycle)
                let next = BillReservePlanner.nextDue(for: item, asOf: asOf)
                let monthsPer = max(1, item.frequency.monthsPerCycle)
                if let prev = cal.date(byAdding: .month, value: -monthsPer, to: next.nextDueDate) {
                    let start = cal.startOfDay(for: prev)
                    if item.reserveCycleStart == nil {
                        item.reserveCycleStart = start
                        item.reserveLastSeededCycleStart = nil
                        item.reserveBalance = 0
                        updated += 1
                    }
                }
            }

            if updated > 0 {
                try context.save()
                AMLogging.log("ReserveMigration: updated \(updated) bill(s) with reserveCycleStart", component: "ReserveMigration")
            } else {
                AMLogging.log("ReserveMigration: no eligible bills required updates", component: "ReserveMigration")
            }

            // Mark as complete to avoid re-running on subsequent launches
            settings.didInitializeReserveAnchors = true
        } catch {
            AMLogging.error("ReserveMigration: failed — \(error.localizedDescription)", component: "ReserveMigration")
            // Do not set the flag so we can retry on next launch
        }
    }
}
