import SwiftUI
import SwiftData

struct DebtPayoffContainer: View {
    let accountID: UUID
    @Environment(\.modelContext) private var modelContext
    @Query private var accounts: [Account]

    init(accountID: UUID) {
        self.accountID = accountID
        _accounts = Query(filter: #Predicate<Account> { $0.id == accountID })
    }

    var body: some View {
        if let account = accounts.first {
            DebtPayoffView(viewModel: DebtPayoffViewModel(account: account, context: modelContext))
        } else {
            ContentUnavailableView(
                "Account deleted",
                systemImage: "exclamationmark.triangle",
                description: Text("This account is no longer available.")
            )
        }
    }
}
