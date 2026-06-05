import SwiftData

enum DebtScopeSchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            Account.self,
            Transaction.self,
            Security.self,
            HoldingSnapshot.self,
            BalanceSnapshot.self,
            ImportBatch.self,
            CSVColumnMapping.self,
            CashFlowItem.self,
            AssetLiabilityLink.self,
            AccountImportMapping.self
        ]
    }
}

enum DebtScopeSchemaV2: VersionedSchema {
    static var versionIdentifier = Schema.Version(2, 0, 0)

    static var models: [any PersistentModel.Type] {
        DebtScopeSchemaV1.models + [BillFundingAllocation.self]
    }
}

enum DebtScopeSchemaV3: VersionedSchema {
    static var versionIdentifier = Schema.Version(3, 0, 0)

    static var models: [any PersistentModel.Type] {
        DebtScopeSchemaV2.models
    }
}

enum DebtScopeMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [DebtScopeSchemaV1.self, DebtScopeSchemaV2.self, DebtScopeSchemaV3.self]
    }

    static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: DebtScopeSchemaV1.self, toVersion: DebtScopeSchemaV2.self),
            .lightweight(fromVersion: DebtScopeSchemaV2.self, toVersion: DebtScopeSchemaV3.self)
        ]
    }
}
