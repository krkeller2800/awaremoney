import Foundation
import SwiftData

struct BillFundingAllocationMigrationService {
    static func migrateLegacyFundingIfNeeded(container: ModelContainer, settings: SettingsStore) {
        guard !settings.didMigrateBillFundingAllocations else { return }

        let context = ModelContext(container)
        do {
            let bills = try context.fetch(FetchDescriptor<CashFlowItem>())
                .filter { $0.kind == .bill && $0.fundingIncomeID != nil && $0.fundingAmount > 0 }
            let existingAllocations = try context.fetch(FetchDescriptor<BillFundingAllocation>())
            let existingPairs = Set(existingAllocations.map { LegacyPair(billID: $0.billID, incomeID: $0.incomeID) })

            var inserted = 0
            for bill in bills {
                guard let incomeID = bill.fundingIncomeID else { continue }
                let pair = LegacyPair(billID: bill.id, incomeID: incomeID)
                guard !existingPairs.contains(pair) else { continue }
                context.insert(BillFundingAllocation(billID: bill.id, incomeID: incomeID, amount: bill.fundingAmount))
                inserted += 1
            }

            if inserted > 0 {
                try context.save()
                AMLogging.log("BillFundingAllocationMigration: inserted \(inserted) allocation(s)", component: "BillFundingAllocationMigration")
            }

            settings.didMigrateBillFundingAllocations = true
        } catch {
            AMLogging.error("BillFundingAllocationMigration failed: \(error.localizedDescription)", component: "BillFundingAllocationMigration")
        }
    }

    private struct LegacyPair: Hashable {
        let billID: UUID
        let incomeID: UUID
    }
}
