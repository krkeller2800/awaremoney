import SwiftUI
import SwiftData

struct DebtPayoffPlanView: View {
    var onManageDebtSetup: (() -> Void)? = nil

    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject private var settings: SettingsStore
    @AppStorage("debtPlanStartModeRaw") private var debtPlanStartModeRaw: String = "currentInputs"
    @AppStorage("debtPlanStartDate") private var debtPlanStartDateEpoch: Double = 0

    @State private var planSummary: AssistantPayoffPlanSummary?
    @State private var debtSummary: AssistantDebtSummary?
    @State private var errorMessage: String?

    private let currentPlanColumnWidth: CGFloat = 360
    private let compactCurrentPlanColumnWidth: CGFloat = 300
    private let payoffOrderMinimumWidth: CGFloat = 320
    private let twoColumnSpacingAndPadding: CGFloat = 48
    private let twoColumnWidthThreshold: CGFloat = 660

    var body: some View {
        payoffPlanContent
            .navigationTitle("Payoff Plan")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear(perform: refresh)
            .onChange(of: settings.defaultPayoffStrategyRaw) { _, _ in refresh() }
            .onChange(of: debtPlanStartModeRaw) { _, _ in refresh() }
            .onChange(of: debtPlanStartDateEpoch) { _, _ in refresh() }
    }

    @ViewBuilder
    private var payoffPlanContent: some View {
        if let errorMessage {
            List {
                ContentUnavailableView(
                    "Payoff Plan Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            }
        } else if let planSummary {
            GeometryReader { proxy in
                let usesTwoColumns = usesTwoColumnLayout(for: proxy.size)
                let leftColumnWidth = currentPlanColumnWidth(for: proxy.size)
                if usesTwoColumns {
                    twoColumnPlanContent(planSummary, leftColumnWidth: leftColumnWidth)
                } else {
                    singleColumnPlanContent(planSummary)
                }
            }
        } else {
            List {
                ProgressView("Loading payoff plan...")
            }
        }
    }

    private func currentPlanColumnWidth(for size: CGSize) -> CGFloat {
        size.width < 760 ? compactCurrentPlanColumnWidth : currentPlanColumnWidth
    }

    private func usesTwoColumnLayout(for size: CGSize) -> Bool {
        horizontalSizeClass == .regular && size.width >= twoColumnWidthThreshold
    }

    private func singleColumnPlanContent(_ planSummary: AssistantPayoffPlanSummary) -> some View {
        List {
            planOverviewSection(planSummary)
            payoffOrderSection(planSummary)
            missingDataSection
            sourceSection(planSummary)
            manageLiabilityAccountsSection
        }
    }

    private func twoColumnPlanContent(_ planSummary: AssistantPayoffPlanSummary, leftColumnWidth: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 16) {
            List {
                planOverviewSection(planSummary)
                missingDataSection
                sourceSection(planSummary)
                manageLiabilityAccountsSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .frame(width: leftColumnWidth, alignment: .top)

            List {
                payoffOrderSection(planSummary)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 16)
        .background(Color(.systemGroupedBackground))
    }

    private func planOverviewSection(_ summary: AssistantPayoffPlanSummary) -> some View {
        Section("Current Plan") {
            LabeledContent("Strategy", value: strategyDisplayName(summary.strategy))
            LabeledContent("Start", value: formatMonth(summary.startDate))
            LabeledContent("Debt accounts", value: "\(summary.debtCount)")
            LabeledContent("Starting debt", value: formatCurrency(summary.totalStartingDebt, code: summary.currencyCode))
            LabeledContent("Minimum payments", value: formatCurrency(summary.totalMinimumPayment, code: summary.currencyCode))
            LabeledContent("Monthly budget", value: formatCurrency(summary.monthlyBudget, code: summary.currencyCode))
            LabeledContent("Projected interest", value: formatCurrency(summary.totalInterest, code: summary.currencyCode))
            LabeledContent("Debt-free date", value: formatMonth(summary.projectedDebtFreeDate))
        }
    }

    private func payoffOrderSection(_ summary: AssistantPayoffPlanSummary) -> some View {
        Section("Payoff Order") {
            if summary.payoffOrder.isEmpty {
                Text("No active debt accounts are included in the current plan.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(summary.payoffOrder, id: \.orderIndex) { debt in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(debt.orderIndex). \(debt.name)")
                                .font(.headline)
                            Spacer(minLength: 12)
                            Text(formatMonth(debt.payoffDate))
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                        }

                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 12) {
                                Text(formatCurrency(debt.startingBalance, code: summary.currencyCode))
                                Text("APR \(formatAPR(debt.apr))")
                                Text("Min \(formatCurrency(debt.minimumPayment, code: summary.currencyCode))")
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(formatCurrency(debt.startingBalance, code: summary.currencyCode))
                                Text("APR \(formatAPR(debt.apr))")
                                Text("Min \(formatCurrency(debt.minimumPayment, code: summary.currencyCode))")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    @ViewBuilder
    private var missingDataSection: some View {
        let notes = debtSummary?.missingDataNotes ?? []
        if !notes.isEmpty {
            Section("Needs Attention") {
                ForEach(notes, id: \.self) { note in
                    Label(note, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func sourceSection(_ summary: AssistantPayoffPlanSummary) -> some View {
        Section("Source") {
            Text(summary.sourceNote)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var manageLiabilityAccountsSection: some View {
        if let onManageDebtSetup {
            Section {
                Button {
                    onManageDebtSetup()
                } label: {
                    Label("Manage Liability Accounts", systemImage: "slider.horizontal.3")
                }
            }
        }
    }

    private func refresh() {
        let service = DebtScopeAssistantService(context: modelContext, settings: settings)
        let startDate = savedPlanStartDate()

        do {
            planSummary = try service.payoffPlanSummary(startDate: startDate)
            debtSummary = try service.debtSummary()
            errorMessage = planSummary == nil
                ? "No active credit-card or loan debts with current balances are available."
                : nil
        } catch DebtPlanError.infeasibleBudget(let requiredMinimum) {
            planSummary = nil
            debtSummary = try? service.debtSummary()
            errorMessage = "The current payoff budget is below the required minimum payments of \(formatCurrency(requiredMinimum, code: settings.currencyCode))."
        } catch {
            planSummary = nil
            debtSummary = nil
            errorMessage = error.localizedDescription
        }
    }

    private func savedPlanStartDate() -> Date {
        guard debtPlanStartModeRaw == "projectedAtDate", debtPlanStartDateEpoch > 0 else {
            return Date()
        }
        return Date(timeIntervalSince1970: debtPlanStartDateEpoch)
    }

    private func strategyDisplayName(_ strategy: AssistantPayoffStrategy) -> String {
        switch strategy {
        case .minimumsOnly:
            return "Minimums"
        case .snowball:
            return "Snowball"
        case .avalanche:
            return "Avalanche"
        }
    }

    private func formatCurrency(_ amount: Decimal?, code: String) -> String {
        guard let amount else { return "Unavailable" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        return formatter.string(from: NSDecimalNumber(decimal: amount)) ?? "\(amount)"
    }

    private func formatAPR(_ apr: Decimal?) -> String {
        guard let apr else { return "Unavailable" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(decimal: apr)) ?? "\(apr)"
    }

    private func formatMonth(_ date: Date?) -> String {
        guard let date else { return "Unavailable" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yyyy"
        return formatter.string(from: date)
    }
}

#Preview {
    NavigationStack {
        DebtPayoffPlanView()
            .environmentObject(SettingsStore())
    }
    .modelContainer(for: DebtScopeSchemaV5.models, inMemory: true)
}
