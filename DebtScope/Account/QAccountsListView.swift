import SwiftUI
import SwiftData

struct QAccountsListView: View {
    @Environment(\.modelContext) private var modelContext

    let accounts: [Account]
    var title: String = "Liability Accounts"
    var showsDebtTools: Bool = true
    @Binding var selectedAccountID: UUID?
    var onEdit: (Account) -> Void
    var onDeleteConfirmed: (Account) -> Void
    var onSelectionChanged: (UUID?) -> Void

    @State private var pendingDelete: Account? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)
            List {
                ForEach(accounts) { account in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(account.name.isEmpty ? "Unnamed" : account.name)
                                .fontWeight(selectedAccountID == account.id ? .semibold : .regular)
                            Spacer()
                            Text(self.formattedBalance(for: account))
                                .monospacedDigit()
                        }

                        HStack(spacing: 6) {
                            Text(self.displayName(for: account.type))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Text(self.formattedAPR(for: account).map { "APR \($0)" } ?? "")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .frame(maxWidth: .infinity, alignment: .center)

                            Text(self.formattedPayment(for: account).map { "Payment \($0)" } ?? "")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }

                        Text(self.formattedBalanceDate(for: account))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .padding(.trailing, UIDevice.type == "iPhone" ? 40 : 25) // reserve space for navigation cue and trailing button
                    .overlay(alignment: .trailing) {
                        HStack(spacing: 2) {
                            Menu {
                                Button {
                                    onEdit(account)
                                } label: {
                                    Label("Edit Account…", systemImage: "pencil")
                                }
                                Button(role: .destructive) {
                                    pendingDelete = account
                                } label: {
                                    Label("Delete Account", systemImage: "trash")
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .imageScale(.medium)
                                    .foregroundStyle(.secondary)
                                    .padding(.vertical, 8) // larger tap target
                                    .accessibilityLabel("More actions")
                            }
                            .menuStyle(.button)
                            if UIDevice.type == "iPhone" {
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                                    .padding(.trailing, 4)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .background(selectedAccountID == account.id ? Color.accentColor.opacity(0.08) : Color.clear)
                    .contentShape(Rectangle())
                    .simultaneousGesture(TapGesture().onEnded {
                        selectedAccountID = account.id
                        onSelectionChanged(selectedAccountID)
                    })
                    // Context menu (all platforms)
                    .contextMenu {
                        Button {
                            onEdit(account)
                        } label: {
                            Label("Edit Account…", systemImage: "pencil")
                        }

                        Button(role: .destructive) {
                            pendingDelete = account
                        } label: {
                            Label("Delete Account", systemImage: "trash")
                        }
                    }
#if os(iOS)
                    // Swipe action (iOS)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button {
                            onEdit(account)
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(.blue)

                        Button(role: .destructive) {
                            pendingDelete = account
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
#endif
                }
            }
            .listStyle(.inset)
        }
        .alert("Delete Account?", isPresented: Binding(get: { pendingDelete != nil },
                                                      set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let acct = pendingDelete {
                    onDeleteConfirmed(acct)
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDelete = nil
            }
        } message: {
            Text("This removes the account and any imported data associated with it.")
        }
    }
}

// MARK: - Helpers
private extension QAccountsListView {
    func latestBalanceSnapshot(for account: Account) -> BalanceSnapshot? {
        account.balanceSnapshots.sorted { $0.asOfDate > $1.asOfDate }.first
    }

    func latestBalance(for account: Account) -> Decimal? {
        latestBalanceSnapshot(for: account)?.balance
    }

    func formattedBalance(for account: Account) -> String {
        guard let bal = latestBalance(for: account) else { return "—" }
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        return nf.string(from: NSDecimalNumber(decimal: bal)) ?? "\(bal)"
    }

    func formattedBalanceDate(for account: Account) -> String {
        guard let date = latestBalanceSnapshot(for: account)?.asOfDate else { return "No balance date" }
        return "As of \(date.formatted(date: .abbreviated, time: .omitted))"
    }

    func formattedAPR(for account: Account) -> String? {
        guard let apr = account.loanTerms?.apr else { return nil }
        let nf = NumberFormatter()
        nf.numberStyle = .percent
        if let s = account.loanTerms?.aprScale {
            nf.minimumFractionDigits = s
            nf.maximumFractionDigits = s
        } else {
            nf.minimumFractionDigits = 2
            nf.maximumFractionDigits = 3
        }
        return nf.string(from: NSDecimalNumber(decimal: apr))
    }

    func formattedPayment(for account: Account) -> String? {
        guard let amt = account.loanTerms?.paymentAmount else { return nil }
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        return nf.string(from: NSDecimalNumber(decimal: amt))
    }

    func displayName(for type: Account.AccountType) -> String {
        switch type {
        case .checking: return "Checking"
        case .savings: return "Savings"
        case .creditCard: return "Credit Card"
        case .loan: return "Loan"
        case .cash: return "Cash"
        case .brokerage: return "Brokerage"
        case .property: return "Property"
        case .other: return "Other"
        }
    }

}
