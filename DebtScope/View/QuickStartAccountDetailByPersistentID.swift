import SwiftUI
import SwiftData

struct QuickStartAccountDetailByPersistentID: View {
    let persistentID: PersistentIdentifier

    @Query(sort: [SortDescriptor(\Account.name, order: .forward)]) private var accounts: [Account]

    private var account: Account? {
        accounts.first { $0.persistentModelID == persistentID }
    }

    var body: some View {
        if let account {
            AccountDetailView(accountID: account.id)
        } else {
            ContentUnavailableView("Asset no longer exists", systemImage: "exclamationmark.triangle")
        }
    }
}
