import SwiftUI
import SwiftData
import UIKit

private struct AccountValue: Identifiable {
    let accountID: UUID
    let displayName: String
    let type: Account.AccountType
    let institutionName: String?
    let value: Decimal
    var id: AnyHashable { AnyHashable(accountID) }
}

struct NetWorthView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @EnvironmentObject private var settings: SettingsStore
    @State private var totalNetWorth: Decimal = 0
    @State private var byAccount: [AccountValue] = []
    @State private var showNetWorthChart = false
    @State private var showAddAssetSheet = false

    var body: some View {
        Group {
            if hSizeClass == .regular {
                NavigationSplitView {
                    primaryList
                        .navigationTitle("Net Worth")
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                PlanToolbarButton("+ Asset", titleFont: .caption, fixedWidth: 70) { showAddAssetSheet = true }
                            }
                        }
                } detail: {
                    dashboardDetail
                }
            } else {
                NavigationStack {
                    primaryList
                        .navigationTitle("Net Worth")
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                PlanToolbarButton("+ Asset", titleFont: .caption, fixedWidth: 70) { showAddAssetSheet = true }
                            }
                        }
                }
//                .sheet(isPresented: $showNetWorthChart) {
//                    PortraitOnlyWrapper(content: NetWorthDashboardSheet())
//                }
                .fullScreenCover(isPresented: $showNetWorthChart) {
                    PortraitOnlyWrapper(content: NetWorthDashboardSheet())
                }
            }
        }
        .sheet(isPresented: $showAddAssetSheet) {
            ManualAssetSheet()
        }
    }

    @ViewBuilder
    private var primaryList: some View {
        List {
            // Consolidated accounts view: single section with one card per account type and its details
            Section("Accounts") {
                ForEach(accountTypeOrder, id: \.self) { type in
                    let groups = groupsFor(type: type)
                    if !groups.isEmpty {
                        let subtotal = groups.reduce(Decimal.zero) { $0 + $1.value }

                        VStack(alignment: .leading, spacing: 8) {
                            // Header line
                            HStack {
                                Text(typeDisplayName(type))
                                    .font(.headline)
                            }

                            // Institution sublines
                            ForEach(groups, id: \.institution) { grp in
                                HStack {
                                    Text(grp.institution)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text(format(amount: grp.value))
                                        .foregroundStyle(grp.value < .zero ? .red : .secondary)
                                }
                                .padding(.leading, 16)
                            }

                            // Sub-total line
                            HStack {
                                Text("Total")
                                    .font(.subheadline)
                                Spacer()
                                Text(format(amount: subtotal))
                                    .font(.headline)
                                    .foregroundStyle(subtotal < .zero ? .red : .primary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            // Overall total
            Section("Total") {
                HStack {
                    Text("Net Worth")
                    Spacer()
                    if hSizeClass == .compact {
                        PlanToolbarButton("Chart",systemImage: "chart.pie") { showNetWorthChart = true }
                    }
                    Spacer()
                    Text(format(amount: totalNetWorth))
                        .font(.headline)
                        .foregroundStyle(totalNetWorth < .zero ? .red : .primary)
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .transactionsDidChange)) { _ in
            Task { await load() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .accountsDidChange)) { _ in
            Task { await load() }
        }
    }

    @ViewBuilder
    private var dashboardDetail: some View {
        GeometryReader { viewport in
            let viewportSize = viewport.size
            ZStack {
                Color.clear
                ScrollView {
                    iPadDashboardHeader(viewport: viewportSize, showsDoneButton: false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Overview")
        }
    }

    private func iPadDashboardHeader(viewport: CGSize, showsDoneButton: Bool) -> some View {
        // Reserve space comparable to external padding and any future header/KPI content.
        let horizontalPadding: CGFloat = 16 * 2
        let topReserved: CGFloat = 32 // matches .padding(.top, 12) below

        // Effective content area inside the detail column (sidebar width already excluded by NavigationSplitView)
        let vw = viewport.width > 0 ? viewport.width : UIScreen.main.bounds.width
        let vh = viewport.height > 0 ? viewport.height : UIScreen.main.bounds.height
        let contentWidth = max(0, vw - horizontalPadding)
        let contentHeight = max(0, vh - topReserved)

        // Use the shortest dimension to drive sizing so the chart looks balanced in both orientations
        let shortest = min(contentWidth, contentHeight)

        // Clamp the final square size to avoid extremes
//        let minSize: CGFloat = 480
//        let maxSize: CGFloat = 680
//        let chartSize = min(max(minSize, shortest * 0.9), maxSize)
        let chartSize = shortest * 0.95
        return VStack(spacing: 16) {
            NetWorthKPIsView()
            HStack {
                Spacer()
                NetWorthChartView(showsDoneButton: showsDoneButton)
                    .frame(width: chartSize, height: chartSize)
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    @Sendable private func load() async {
        do {
            // Fetch all accounts
            let accounts = try modelContext.fetch(FetchDescriptor<Account>())
            AMLogging.log("NetWorth load — fetched accounts: \(accounts.count)", component: "NetWorthView")
            var perAccount: [AccountValue] = []
            var total: Decimal = 0

            for account in accounts {
                let value: Decimal = try anchoredValue(for: account)
                AMLogging.log("Account \(account.name) — type: \(account.type.rawValue), inst: \(account.institutionName ?? "(nil)"), value: \(value), tx: \(account.transactions.count)", component: "NetWorthView")
                perAccount.append(AccountValue(accountID: account.id, displayName: account.name, type: account.type, institutionName: account.institutionName, value: value))
                total += value
            }

            // Removed assignments to totalAssets, totalLiabilities, monthToDateDelta as requested

            await MainActor.run {
                self.byAccount = perAccount.sorted { $0.displayName < $1.displayName }
                self.totalNetWorth = total
            }
        } catch {
            // For MVP, ignore errors and keep zeros
        }
    }

    private func anchoredValue(for account: Account) throws -> Decimal {
        func adjustForLiability(_ value: Decimal, for account: Account) -> Decimal {
            switch account.type {
            case .loan, .creditCard:
                return value > 0 ? -value : value
            default:
                return value
            }
        }

        // Find latest non-excluded snapshot date if any
        let latestSnapDate: Date? = try {
            let id = account.id
            let pred = #Predicate<BalanceSnapshot> { snap in snap.account?.id == id && snap.isExcluded == false }
            var desc = FetchDescriptor<BalanceSnapshot>(predicate: pred)
            desc.sortBy = [SortDescriptor(\BalanceSnapshot.asOfDate, order: .reverse)]
            desc.fetchLimit = 1
            let snaps = try modelContext.fetch(desc)
            return snaps.first?.asOfDate
        }()

        if let snapDate = latestSnapDate {
            // Get latest non-excluded snapshot balance
            let id = account.id
            let pred = #Predicate<BalanceSnapshot> { snap in snap.account?.id == id && snap.asOfDate == snapDate && snap.isExcluded == false }
            var desc = FetchDescriptor<BalanceSnapshot>(predicate: pred)
            desc.fetchLimit = 1
            let snaps = try modelContext.fetch(desc)
            let base = snaps.first?.balance ?? 0
            // Sum non-excluded transactions strictly after snapshot date
            let txAfter = account.transactions.filter { $0.datePosted > snapDate && $0.isExcluded == false }
            let delta = txAfter.reduce(Decimal.zero) { $0 + $1.amount }
            return adjustForLiability(base + delta, for: account)
        } else {
            // No snapshots: sum non-excluded transactions
            let sum = account.transactions.filter { $0.isExcluded == false }.reduce(Decimal.zero) { $0 + $1.amount }
            return adjustForLiability(sum, for: account)
        }
    }

    private func computeMonthToDateDelta(accounts: [Account]) throws -> Decimal {
        let cal = Calendar.current
        guard let startOfMonth = cal.date(from: cal.dateComponents([.year, .month], from: Date())) else {
            return .zero
        }
        var delta: Decimal = .zero
        for account in accounts {
            let tx = account.transactions.filter { $0.datePosted >= startOfMonth && $0.isExcluded == false }
            delta += tx.reduce(.zero) { $0 + $1.amount }
        }
        return delta
    }

    private func format(amount: Decimal) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = settings.currencyCode
        return nf.string(from: NSDecimalNumber(decimal: amount)) ?? "\(amount)"
    }

    // Preferred order of account types in the UI
    private var accountTypeOrder: [Account.AccountType] {
        [.checking, .savings, .creditCard, .loan, .brokerage, .cash, .property, .other]
    }
    private func typeDisplayName(_ type: Account.AccountType) -> String {
        switch type {
        case .checking: return "Checking"
        case .savings: return "Savings"
        case .creditCard: return "Credit Cards"
        case .loan: return "Loans"
        case .brokerage: return "Stocks"
        case .cash: return "Cash"
        case .property: return "Property"
        case .other: return "Other"
        }
    }

    // Return institution-grouped totals for a specific account type
    private func groupsFor(type: Account.AccountType) -> [(institution: String, value: Decimal)] {
        // Filter by type
        let rows = byAccount.filter { $0.type == type }
        // Group label: use property name for properties; institution for others (fallback to Unknown)
        var buckets: [String: Decimal] = [:]
        for row in rows {
            let label: String = {
                if type == .property { return row.displayName }
                let inst = (row.institutionName?.isEmpty == false) ? row.institutionName! : "Unknown"
                return inst
            }()
            buckets[label, default: .zero] += row.value
        }
        // Sort alphabetically by institution name
        return buckets.keys.sorted().map { key in (institution: key, value: buckets[key] ?? .zero) }
    }
}

private struct NetWorthKPICard: View {
    @EnvironmentObject private var settings: SettingsStore
    let title: String
    let amount: Decimal
    var emphasizePositive: Bool = false

    private func formatted(_ value: Decimal) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = settings.currencyCode
        return nf.string(from: NSDecimalNumber(decimal: value)) ?? "\(value)"
    }

    var body: some View {
        VStack(alignment: .center, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text(formatted(amount))
                .font(.headline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(colorForValue(amount))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .allowsTightening(true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .center)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(.separator).opacity(0.15))
        )
    }

    private func colorForValue(_ value: Decimal) -> Color {
        if emphasizePositive {
            return value < 0 ? .red : .green
        } else {
            return value < 0 ? .red : .primary
        }
    }
}

private struct NetWorthKPIsGrid: View {
    let netWorth: Decimal
    let assets: Decimal
    let liabilities: Decimal

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 10), count: 3),
            alignment: .center,
            spacing: 10
        ) {
            NetWorthKPICard(title: "Net Worth", amount: netWorth)
            NetWorthKPICard(title: "Assets", amount: assets)
            NetWorthKPICard(title: "Liabilities", amount: liabilities)
        }
        .padding(.trailing, 16)
    }
}

private struct NetWorthKPIsView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var netWorth: Decimal = .zero
    @State private var assets: Decimal = .zero
    @State private var liabilities: Decimal = .zero

    var body: some View {
        VStack(alignment: .center, spacing: 5) {
            NetWorthKPIsGrid(netWorth: netWorth, assets: assets, liabilities: liabilities)
                .frame(maxWidth: UIDevice.type == "iPhone" ? 360 : 720)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .accountsDidChange)) { _ in Task { await load() } }
        .onReceive(NotificationCenter.default.publisher(for: .transactionsDidChange)) { _ in Task { await load() } }
    }

    @Sendable private func load() async {
        do {
            let accounts = try modelContext.fetch(FetchDescriptor<Account>())

            var totalAssets: Decimal = .zero
            var totalLiabilities: Decimal = .zero

            for acct in accounts {
                let snapshots = acct.balanceSnapshots.filter { !$0.isExcluded }
                let last = snapshots.sorted { $0.asOfDate > $1.asOfDate }.first
                let txs = acct.transactions.filter { !$0.isExcluded }

                let value: Decimal = {
                    if let last = last {
                        let delta = txs.filter { $0.datePosted > last.asOfDate }
                            .reduce(Decimal.zero) { $0 + $1.amount }
                        return last.balance + delta
                    } else {
                        return txs.reduce(Decimal.zero) { $0 + $1.amount }
                    }
                }()

                if value > 0 { totalAssets += value }
                if value < 0 { totalLiabilities += (-value) }
            }

//            let mtd = computeMonthToDateDelta(accounts: accounts)
            let nw = totalAssets - totalLiabilities

            await MainActor.run {
                self.assets = totalAssets
                self.liabilities = totalLiabilities
                self.netWorth = nw
//                self.mtdChange = mtd
            }
        } catch {
            await MainActor.run {
                self.assets = .zero
                self.liabilities = .zero
                self.netWorth = .zero
//                self.mtdChange = .zero
            }
        }
    }

//    private func computeMonthToDateDelta(accounts: [Account]) -> Decimal {
//        let cal = Calendar.current
//        guard let startOfMonth = cal.date(from: cal.dateComponents([.year, .month], from: Date())) else {
//            return .zero
//        }
//        var delta: Decimal = .zero
//        for account in accounts {
//            let tx = account.transactions.filter { $0.datePosted >= startOfMonth && $0.isExcluded == false }
//            delta += tx.reduce(.zero) { $0 + $1.amount }
//        }
//        return delta
//    }
}

private struct NetWorthDashboardSheet: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                GeometryReader { geo in
                    let availableWidth = max(UIScreen.main.bounds.width, geo.size.width) // account for horizontal padding
                    let availableHeight = max(UIScreen.main.bounds.height,geo.size.height)
                    let shortest = min(availableWidth, availableHeight)
                    let minSize: CGFloat = 360 // ensure a readable minimum on iPhone
                    let maxSize: CGFloat = 1500 // allow large charts; ScrollView will handle overflow
                    let chartSize = min(max(minSize, shortest * 1), maxSize)
                    VStack(spacing: 16) {
                        NetWorthKPIsView()
                        HStack {
                            Spacer()
                            NetWorthChartView(showsDoneButton: true)
                                .frame(width: chartSize, height: chartSize)
                            Spacer()
                        }
                        .padding(.trailing, 16)
                    }
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .frame(minHeight: 0) // avoid forcing extra height
            }
            .scrollIndicators(.visible)
            .navigationTitle("Net Worth")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private final class PortraitNavigationController: UINavigationController {
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        if UIDevice.current.userInterfaceIdiom == .phone {
            return .portrait
        } else {
            return .all
        }
    }
    override var shouldAutorotate: Bool {
        if UIDevice.current.userInterfaceIdiom == .phone {
            return false
        } else {
            return true
        }
    }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        return .portrait
    }
}

private struct PortraitOnlyWrapper<Content: View>: UIViewControllerRepresentable {
    let content: Content

    func makeUIViewController(context: Context) -> UIViewController {
        let root = UIHostingController(rootView: content)
        let nav = PortraitNavigationController(rootViewController: root)
        nav.modalPresentationStyle = .fullScreen
        return nav
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        // No-op; content updates are handled by SwiftUI hosting
    }
}

