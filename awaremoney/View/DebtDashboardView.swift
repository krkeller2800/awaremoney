//
//  DebtDashboardView.swift
//  awaremoney
//
//  Created by Assistant on 2/1/26
//

import SwiftUI
import SwiftData

struct DebtDashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var liabilities: [Account] = []
    @State private var selection: Account.ID? = nil
    @State private var showIncomeBillsHost = false

    var body: some View {
        Group {
            if isPad {
                iPadBody
            } else {
                iPhoneBody
            }
        }
    }

    private var isPad: Bool {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad
        #else
        return false
        #endif
    }

    @ViewBuilder
    private var iPadBody: some View {
        NavigationSplitView {
            iPadSidebar
        } detail: {
            iPadDetail
        }
        //.safeAreaInset(edge: .top) { TrialBanner() }
        .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 340)
        //.toolbar {
        //    ToolbarItem(placement: .navigationBarLeading) {
        //        Menu("Plan") {
        //            NavigationLink(destination: DebtPlannerView()) {
        //                Text("Planning")
        //            }
        //            NavigationLink(destination: DebtSummaryView()) {
        //                Text("Summary")
        //            }
        //        }
        //    }
        //}
        .task { await load() }
        .fullScreenCover(isPresented: $showIncomeBillsHost) {
            IncomeBillsSplitHostView()
                .environment(\.modelContext, modelContext)
        }
    }

    @ViewBuilder
    private var iPadDetail: some View {
        if let sel = selection, let acct = liabilities.first(where: { $0.id == sel }) {
            HStack {
                Spacer(minLength: 0)
                DebtDetailView(account: acct)
                    .frame(maxWidth: 700)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .safeAreaPadding()
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(acct.name)
                        .font(.largeTitle).bold()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        } else if liabilities.isEmpty {
            ContentUnavailableView("No debts yet", systemImage: "creditcard")
        } else {
            ContentUnavailableView("Select a debt", systemImage: "creditcard")
        }
    }

    @ViewBuilder
    private var iPadSidebar: some View {
        if liabilities.isEmpty {
            ContentUnavailableView("No debts yet", systemImage: "creditcard")
            //.safeAreaInset(edge: .top) { TrialBanner() }
                .navigationTitle("Debt")
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Menu {
                            NavigationLink(destination: DebtPlannerView()) {
                                Text("Planning")
                            }
                            NavigationLink(destination: DebtSummaryView()) {
                                Text("Summary")
                            }
                            Button {
                                showIncomeBillsHost = true
                            } label: {
                                Text("Income & Bills")
                            }
                        } label: {
                            PlanMenuLabel()
                        }
                    }
                }
        } else {
            List(selection: $selection) {
                Section("Institutions") {
                    ForEach(liabilities, id: \.id) { acct in
                        debtRowContent(for: acct)
                            .tag(acct.id)
                    }
                }
            }
            .refreshable { await load() }
            .navigationTitle("Debt")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        NavigationLink(destination: DebtPlannerView()) {
                            Text("Planning")
                        }
                        NavigationLink(destination: DebtSummaryView()) {
                            Text("Summary")
                        }
                        Button {
                            showIncomeBillsHost = true
                        } label: {
                            Text("Income & Bills")
                        }
                    } label: {
                        PlanMenuLabel()
                    }
                }
            }
            //.safeAreaInset(edge: .top) { TrialBanner() }
        }
    }

    @ViewBuilder
    private func debtRowContent(for acct: Account) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(acct.name)
                    .font(.headline)
                Text(acct.type == .loan ? "Loan" : "Credit Card")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(currentBalance(for: acct))
                    .font(.headline)
                    .foregroundStyle(.red)
                if let payoff = payoffDate(for: acct) {
                    Text("Payoff: \(payoff, style: .date)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var iPhoneBody: some View {
        NavigationStack {
            Group {
                if liabilities.isEmpty {
                    ContentUnavailableView("No debts yet", systemImage: "creditcard")
                    //.safeAreaInset(edge: .top) { TrialBanner() }
                } else {
                    List {
                        Section("Institutions") {
                            ForEach(liabilities, id: \.id) { acct in
                                NavigationLink(destination: DebtDetailView(account: acct)) {
                                    debtRowContent(for: acct)
                                }
                            }
                        }
                    }
                    .refreshable { await load() }
                    //.safeAreaInset(edge: .top) { TrialBanner() }
                }
            }
            .navigationTitle("Debt")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        NavigationLink(destination: DebtPlannerView()) {
                            Text("Planning")
                        }
                        NavigationLink(destination: DebtSummaryView()) {
                            Text("Summary")
                        }
                        Button {
                            showIncomeBillsHost = true
                        } label: {
                            Text("Income & Bills")
                        }
                    } label: {
                        PlanMenuLabel()
                    }
                }
            }
        }
        .task { await load() }
        .fullScreenCover(isPresented: $showIncomeBillsHost) {
            IncomeAndBillsView()
                .environment(\.modelContext, modelContext)
        }
    }

    @Sendable private func load() async {
        do {
            let all = try modelContext.fetch(FetchDescriptor<Account>())
            await MainActor.run {
                self.liabilities = all.filter { $0.type == .loan || $0.type == .creditCard }
                if self.selection == nil { self.selection = self.liabilities.first?.id }
            }
        } catch {
            await MainActor.run { self.liabilities = [] }
        }
    }

    private func latestBalance(_ account: Account) -> Decimal {
        let id = account.id
        let pred = #Predicate<BalanceSnapshot> { $0.account?.id == id }
        var desc = FetchDescriptor<BalanceSnapshot>(predicate: pred)
        desc.sortBy = [SortDescriptor(\BalanceSnapshot.asOfDate, order: .reverse)]
        desc.fetchLimit = 1
        let snap = try? modelContext.fetch(desc).first
        return snap?.balance ?? 0
    }

    private func absDecimal(_ d: Decimal) -> Decimal { d < 0 ? -d : d }

    private func latestSnapshotDate(_ account: Account) -> Date? {
        let id = account.id
        let pred = #Predicate<BalanceSnapshot> { $0.account?.id == id }
        var desc = FetchDescriptor<BalanceSnapshot>(predicate: pred)
        desc.sortBy = [SortDescriptor(\BalanceSnapshot.asOfDate, order: .reverse)]
        desc.fetchLimit = 1
        return try? modelContext.fetch(desc).first?.asOfDate
    }

    private func statementDate(onOrBefore date: Date, day: Int) -> Date {
        let cal = Calendar.current
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: date))!
        let range = cal.range(of: .day, in: .month, for: monthStart)!
        let clampedDay = min(max(1, day), range.count)
        var comps = cal.dateComponents([.year, .month], from: monthStart)
        comps.day = clampedDay
        let candidate = cal.date(from: comps)!
        if candidate <= date {
            return candidate
        } else {
            let prevMonth = cal.date(byAdding: DateComponents(month: -1), to: monthStart)!
            let prevRange = cal.range(of: .day, in: .month, for: prevMonth)!
            let prevClamped = min(max(1, day), prevRange.count)
            var prevComps = cal.dateComponents([.year, .month], from: prevMonth)
            prevComps.day = prevClamped
            return cal.date(from: prevComps)!
        }
    }

    private func nextStatementDate(after date: Date, day: Int) -> Date {
        let cal = Calendar.current
        let nextMonth = cal.date(byAdding: DateComponents(month: 1), to: date)!
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: nextMonth))!
        let range = cal.range(of: .day, in: .month, for: monthStart)!
        let clampedDay = min(max(1, day), range.count)
        var comps = cal.dateComponents([.year, .month], from: monthStart)
        comps.day = clampedDay
        return cal.date(from: comps)!
    }

    private func currentBalance(for account: Account) -> String {
        let bal = latestBalance(account)
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = "USD"
        return nf.string(from: NSDecimalNumber(decimal: bal)) ?? "\(bal)"
    }

    private func payoffDate(for account: Account) -> Date? {
        let startingBalance = absDecimal(latestBalance(account))
        guard startingBalance > 0 else { return nil }
        let apr = account.loanTerms?.apr
        let payment = account.loanTerms?.paymentAmount

        if let anchor = latestSnapshotDate(account), let pay = payment, pay > 0 {
            // Use statement-anchored monthly simulation when we have a payment amount.
            // Assume payment happens before the statement date each cycle.
            let sDay = Calendar.current.component(.day, from: anchor)
            var bal = startingBalance
            var stmt = nextStatementDate(after: statementDate(onOrBefore: anchor, day: sDay), day: sDay)
            for _ in 0..<600 { // safety bound ~50 years
                bal -= pay
                if bal <= 0 { return stmt }
                if let apr, apr > 0 {
                    bal += bal * (apr / 12)
                }
                stmt = nextStatementDate(after: stmt, day: sDay)
            }
            return nil
        } else {
            // Fallback to engine projection; map first zero to statement date on-or-before that point
            let apr = account.loanTerms?.apr
            let payment: Decimal? = account.loanTerms?.paymentAmount
            do {
                let kind: DebtKind = (account.type == .loan) ? .loan : .creditCard(account.creditCardPaymentMode ?? .minimum)
                let points = try DebtProjectionEngine.project(kind: kind, startingBalance: startingBalance, apr: apr, payment: payment)
                if let idx = points.firstIndex(where: { $0.balance == 0 }) {
                    let zeroDate = points[idx].date
                    if let anchor = latestSnapshotDate(account) {
                        let sDay = Calendar.current.component(.day, from: anchor)
                        return statementDate(onOrBefore: zeroDate, day: sDay)
                    } else {
                        return zeroDate
                    }
                }
                return nil
            } catch {
                return nil
            }
        }
    }
}

struct DebtDetailView: View {
    let account: Account
    @Environment(\.modelContext) private var modelContext

    @State private var aprInput: String = ""
    @State private var aprScale: Int? = nil
    @State private var paymentInput: String = ""
    @State private var paymentDay: Int? = nil
    @State private var ccMode: CreditCardPaymentMode = .minimum
    @FocusState private var focusedField: Field?
    private enum Field: Hashable { case apr, payment }
    @State private var showProjection: Bool = false

    var body: some View {
        Form {
            Section("Overview") {
                LabeledContent("Institution", value: account.institutionName ?? "")
                LabeledContent("Type", value: account.type.rawValue.capitalized)
            }
            Section("Payment Plan") {
                if account.type == .creditCard {
                    Picker("Mode", selection: $ccMode) {
                        ForEach(CreditCardPaymentMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue.capitalized).tag(mode)
                        }
                    }
                }

                // Payment amount (shown for loans and credit cards)
                if account.type == .loan || account.type == .creditCard {
                    LabeledContent("Typical Payment") {
                        TextField("0.00", text: $paymentInput)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.decimalPad)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .focused($focusedField, equals: .payment)
                    }
                }

                // Due day of month (optional)
                Picker("Due Day", selection: Binding<Int?>(
                    get: { paymentDay },
                    set: { paymentDay = $0 }
                )) {
                    Text("None").tag(nil as Int?)
                    ForEach(1...31, id: \.self) { d in
                        Text("\(d)").tag(Optional(d))
                    }
                }
            }
            Section("Interest Rate") {
                LabeledContent("APR") {
                    TextField("0.00", text: $aprInput)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.decimalPad)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .focused($focusedField, equals: .apr)
                }
                Text("Enter as a percent (e.g., 19.99 for 19.99%).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Projection") {
                Button("Project Payoff") { showProjection = true }
                    .disabled(absDecimal(latestBalance(account)) <= 0)
            }
        }
        .navigationTitle(account.name)
        .task(id: account.id) {
            AMLogging.log("DebtDetailView: account changed to \(account.id) — reinitializing state", component: "DebtDetailView")
            initializeState()
            // Reset transient UI state when switching accounts
            focusedField = nil
            showProjection = false
        }
        .onAppear { initializeState() }
        .onChange(of: aprInput) { saveTerms() }
        .onChange(of: paymentInput) { saveTerms() }
        .onChange(of: paymentDay) { saveTerms() }
        .onChange(of: ccMode) { saveTerms() }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focusedField = nil }
            }
        }
        .sheet(isPresented: $showProjection) {
            NavigationStack {
                List {
                    Section("Inputs") {
                        LabeledContent("Starting Balance", value: formatAmount(latestBalance(account)))
                        if let apr = account.loanTerms?.apr {
                            LabeledContent("APR", value: formatAPR(apr, scale: account.loanTerms?.aprScale))
                        } else {
                            LabeledContent("APR", value: "—")
                        }
                        if account.type == .creditCard {
                            LabeledContent("Mode", value: (account.creditCardPaymentMode ?? .minimum).rawValue.capitalized)
                            if let pay = account.loanTerms?.paymentAmount {
                                LabeledContent("Typical Payment", value: formatAmount(pay))
                            }
                        } else {
                            if let pay = account.loanTerms?.paymentAmount {
                                LabeledContent("Typical Payment", value: formatAmount(pay))
                            }
                        }
                    }
                    Section("Result") {
                        if let payoff = payoffDate(for: account) {
                            LabeledContent("Estimated Payoff", value: payoff.formatted(date: .abbreviated, time: .omitted))
                        } else {
                            Text("Unable to project a payoff date with the current inputs.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .navigationTitle("Payoff Projection")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { showProjection = false }
                    }
                }
            }
        }
    }

    private func payoffDate(for account: Account) -> Date? {
        let startingBalance = absDecimal(latestBalance(account))
        guard startingBalance > 0 else { return nil }
        AMLogging.log("DebtDetailView: payoffDate start — balance=\(startingBalance), apr=\(String(describing: account.loanTerms?.apr)), payment=\(String(describing: account.loanTerms?.paymentAmount))", component: "DebtDetailView")
        let apr = account.loanTerms?.apr
        let payment = account.loanTerms?.paymentAmount

        if let anchor = latestSnapshotDate(account), let pay = payment, pay > 0 {
            AMLogging.log("DebtDetailView: payoffDate using statement-anchored simulation — pay=\(pay)", component: "DebtDetailView")
            let sDay = Calendar.current.component(.day, from: anchor)
            var bal = startingBalance
            var stmt = nextStatementDate(after: statementDate(onOrBefore: anchor, day: sDay), day: sDay)
            for _ in 0..<600 {
                bal -= pay
                if bal <= 0 { return stmt }
                if let apr, apr > 0 {
                    bal += bal * (apr / 12)
                }
                stmt = nextStatementDate(after: stmt, day: sDay)
            }
            return nil
        } else {
            AMLogging.log("DebtDetailView: payoffDate using engine projection — apr=\(String(describing: apr)) payment=\(String(describing: payment))", component: "DebtDetailView")
            // Fallback
            do {
                let kind: DebtKind = (account.type == .loan) ? .loan : .creditCard(account.creditCardPaymentMode ?? .minimum)
                let points = try DebtProjectionEngine.project(kind: kind, startingBalance: startingBalance, apr: apr, payment: payment)
                if let idx = points.firstIndex(where: { $0.balance == 0 }) {
                    let zeroDate = points[idx].date
                    if let anchor = latestSnapshotDate(account) {
                        let sDay = Calendar.current.component(.day, from: anchor)
                        return statementDate(onOrBefore: zeroDate, day: sDay)
                    } else {
                        return zeroDate
                    }
                }
                return nil
            } catch { return nil }
        }
    }

    private func latestBalance(_ account: Account) -> Decimal {
        let id = account.id
        let pred = #Predicate<BalanceSnapshot> { $0.account?.id == id }
        var desc = FetchDescriptor<BalanceSnapshot>(predicate: pred)
        desc.sortBy = [SortDescriptor(\BalanceSnapshot.asOfDate, order: .reverse)]
        desc.fetchLimit = 1
        let snap = try? modelContext.fetch(desc).first
        return snap?.balance ?? 0
    }

    private func latestSnapshotDate(_ account: Account) -> Date? {
        let id = account.id
        let pred = #Predicate<BalanceSnapshot> { $0.account?.id == id }
        var desc = FetchDescriptor<BalanceSnapshot>(predicate: pred)
        desc.sortBy = [SortDescriptor(\BalanceSnapshot.asOfDate, order: .reverse)]
        desc.fetchLimit = 1
        return try? modelContext.fetch(desc).first?.asOfDate
    }

    private func statementDate(onOrBefore date: Date, day: Int) -> Date {
        let cal = Calendar.current
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: date))!
        let range = cal.range(of: .day, in: .month, for: monthStart)!
        let clampedDay = min(max(1, day), range.count)
        var comps = cal.dateComponents([.year, .month], from: monthStart)
        comps.day = clampedDay
        let candidate = cal.date(from: comps)!
        if candidate <= date {
            return candidate
        } else {
            let prevMonth = cal.date(byAdding: DateComponents(month: -1), to: monthStart)!
            let prevRange = cal.range(of: .day, in: .month, for: prevMonth)!
            let prevClamped = min(max(1, day), prevRange.count)
            var prevComps = cal.dateComponents([.year, .month], from: prevMonth)
            prevComps.day = prevClamped
            return cal.date(from: prevComps)!
        }
    }

    private func nextStatementDate(after date: Date, day: Int) -> Date {
        let cal = Calendar.current
        let nextMonth = cal.date(byAdding: DateComponents(month: 1), to: date)!
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: nextMonth))!
        let range = cal.range(of: .day, in: .month, for: monthStart)!
        let clampedDay = min(max(1, day), range.count)
        var comps = cal.dateComponents([.year, .month], from: monthStart)
        comps.day = clampedDay
        return cal.date(from: comps)!
    }

    private func formatAmount(_ amount: Decimal?) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = "USD"
        guard let amount else { return "—" }
        return nf.string(from: NSDecimalNumber(decimal: amount)) ?? "\(amount)"
    }

    private func formatAPR(_ apr: Decimal, scale: Int? = nil) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .percent
        if let s = scale { nf.minimumFractionDigits = s; nf.maximumFractionDigits = s }
        else { nf.minimumFractionDigits = 2; nf.maximumFractionDigits = 3 }
        return nf.string(from: NSDecimalNumber(decimal: apr)) ?? "\(apr)"
    }

    private func initializeState() {
        // Seed UI from current model values
        if let terms = account.loanTerms {
            if let apr = terms.apr {
                self.aprInput = formatPercentForInput(apr, scale: terms.aprScale)
                self.aprScale = terms.aprScale
            } else {
                self.aprInput = ""
                self.aprScale = nil
            }
            if let p = terms.paymentAmount { self.paymentInput = formatAmountForInput(p) } else { self.paymentInput = "" }
            self.paymentDay = terms.paymentDayOfMonth
        } else {
            self.aprInput = ""
            self.aprScale = nil
            self.paymentInput = ""
            self.paymentDay = nil
        }
        if account.type == .creditCard { self.ccMode = account.creditCardPaymentMode ?? .minimum }
        AMLogging.log("DebtDetailView: initializeState — paymentInput=\(paymentInput), terms.paymentAmount=\(String(describing: account.loanTerms?.paymentAmount)), apr=\(String(describing: account.loanTerms?.apr))", component: "DebtDetailView")
    }

    private func saveTerms() {
        AMLogging.log("DebtDetailView: saveTerms start — aprInput=\(aprInput), paymentInput=\(paymentInput), paymentDay=\(String(describing: paymentDay)), ccMode=\(ccMode.rawValue)", component: "DebtDetailView")
        var terms = account.loanTerms ?? LoanTerms()

        // APR parsing: interpret input as percent (e.g., 19.99 -> 0.1999)
        if let (fraction, scale) = parsePercentInput(aprInput) {
            terms.apr = fraction
            terms.aprScale = scale
        } else {
            terms.apr = nil
            terms.aprScale = nil
        }
        AMLogging.log("DebtDetailView: parsed APR — fraction=\(String(describing: terms.apr)) scale=\(String(describing: terms.aprScale))", component: "DebtDetailView")

        // Payment amount parsing (currency/decimal)
        if let pay = parseCurrencyInput(paymentInput) {
            terms.paymentAmount = pay
        } else {
            terms.paymentAmount = nil
        }
        AMLogging.log("DebtDetailView: parsed paymentAmount=\(String(describing: terms.paymentAmount))", component: "DebtDetailView")
        terms.paymentDayOfMonth = paymentDay

        // Persist terms and mode
        account.loanTerms = terms
        if account.type == .creditCard { account.creditCardPaymentMode = ccMode }
        AMLogging.log("DebtDetailView: saving terms — apr=\(String(describing: terms.apr)), scale=\(String(describing: terms.aprScale)), payment=\(String(describing: terms.paymentAmount)), day=\(String(describing: terms.paymentDayOfMonth))", component: "DebtDetailView")

        do {
            try modelContext.save()
            AMLogging.log("DebtDetailView: saveTerms persisted — account.loanTerms.paymentAmount=\(String(describing: account.loanTerms?.paymentAmount))", component: "DebtDetailView")
            NotificationCenter.default.post(name: .accountsDidChange, object: nil)
        } catch {
            AMLogging.log("DebtDetailView: saveTerms failed to persist — error=\(error.localizedDescription)", component: "DebtDetailView")
            // Silently ignore for now; UI can surface errors later
        }
    }

    private func absDecimal(_ d: Decimal) -> Decimal { d < 0 ? -d : d }

    private func parseCurrencyInput(_ s: String) -> Decimal? {
        let cleaned = s.replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "$", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Decimal(string: cleaned)
    }

    private func parsePercentInput(_ s: String) -> (Decimal, Int)? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let cleaned = trimmed.replacingOccurrences(of: "%", with: "").replacingOccurrences(of: ",", with: ".")
        guard let dec = Decimal(string: cleaned) else { return nil }
        let scale: Int = {
            if let dot = cleaned.firstIndex(of: ".") { return cleaned.distance(from: cleaned.index(after: dot), to: cleaned.endIndex) }
            return 0
        }()
        var fraction = dec
        if fraction > 1 { fraction /= 100 }
        return (fraction, scale)
    }

    private func formatAmountForInput(_ amount: Decimal) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        nf.minimumFractionDigits = 0
        nf.maximumFractionDigits = 2
        return nf.string(from: NSDecimalNumber(decimal: amount)) ?? "\(amount)"
    }

    private func formatPercentForInput(_ apr: Decimal, scale: Int?) -> String {
        // Convert fraction to percent for input field
        let percent = apr * 100
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        if let s = scale { nf.minimumFractionDigits = s; nf.maximumFractionDigits = s } else { nf.minimumFractionDigits = 2; nf.maximumFractionDigits = 3 }
        return nf.string(from: NSDecimalNumber(decimal: percent)) ?? "\(percent)"
    }

    private func monthlyPayment(for account: Account, balance: Decimal) -> Decimal {
        // Use user's typical payment if provided; otherwise estimate at 2% of balance
        let configured = account.loanTerms?.paymentAmount
        let twoPercent = Decimal(string: "0.02") ?? 0.02
        // Round to 2 fraction digits explicitly (bankers rounding)
        let intermediate = balance * twoPercent
        var result = intermediate
        var original = intermediate
        NSDecimalRound(&result, &original, 2, .plain)
        let estimate = result
        let chosen = (configured != nil && configured! > 0) ? configured! : estimate
        AMLogging.log("DebtDetailView: monthlyPayment — account=\(account.name) configured=\(String(describing: configured)) balance=\(balance) chosen=\(chosen)", component: "DebtDetailView")
        return chosen
    }
}

#Preview {
    Text("Preview requires model data")
}

