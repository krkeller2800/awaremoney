import SwiftUI
import SwiftData

struct AccountsListView: View {
    @Query(sort: \Account.name) private var accounts: [Account]

    var body: some View {
        NavigationStack {
            List {
                ForEach(accounts) { account in
                    NavigationLink(destination: AccountDetailView(accountID: account.id)) {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(account.name)
                                Text(account.type.rawValue.capitalized)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle("Accounts")
        }
    }
}

#Preview {
    NavigationStack { AccountsListView() }
}
