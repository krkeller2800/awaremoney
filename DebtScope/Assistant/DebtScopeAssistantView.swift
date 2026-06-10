import SwiftData
import SwiftUI

struct DebtScopeAssistantView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        DebtScopeAssistantChatView(context: modelContext, settings: settings)
    }
}

private struct DebtScopeAssistantChatView: View {
    @EnvironmentObject private var settings: SettingsStore
    @StateObject private var viewModel: DebtScopeAssistantViewModel
    @AppStorage("assistant_privacy_notice_dismissed") private var privacyNoticeDismissed = false

    private let suggestedPrompts = [
        "Summarize my debts",
        "What bills are due soon?",
        "Can I pay extra this month?",
        "Explain my payoff plan"
    ]

    init(context: ModelContext, settings: SettingsStore) {
        _viewModel = StateObject(wrappedValue: DebtScopeAssistantViewModel(context: context, settings: settings))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                messagesContent
                inputBar
            }
            .navigationTitle("Assistant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if viewModel.isLoading {
                        Button {
                            viewModel.cancelResponse()
                        } label: {
                            Image(systemName: "stop.circle")
                        }
                        .accessibilityLabel("Stop response")
                    }

                    Button {
                        viewModel.resetSession()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .accessibilityLabel("Reset assistant")
                    .disabled(viewModel.messages.isEmpty && !viewModel.isLoading)
                }
            }
            .onAppear {
                viewModel.refreshAvailability()
            }
            .onChange(of: settings.assistantEnabled) { _, _ in
                viewModel.refreshAvailability()
            }
        }
    }

    private var messagesContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    availabilityBanner

                    if !privacyNoticeDismissed {
                        privacyNotice
                    }

                    if viewModel.messages.isEmpty {
                        emptyState
                    } else {
                        ForEach(viewModel.messages) { message in
                            AssistantMessageRow(message: message)
                                .id(message.id)
                        }
                    }

                    if viewModel.isLoading {
                        loadingRow
                            .id("assistant-loading")
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
            }
            .background(Color(.systemGroupedBackground))
            .onChange(of: viewModel.messages) { _, messages in
                guard let lastMessage = messages.last else { return }
                withAnimation(.snappy) {
                    proxy.scrollTo(lastMessage.id, anchor: .bottom)
                }
            }
            .onChange(of: viewModel.isLoading) { _, isLoading in
                guard isLoading else { return }
                withAnimation(.snappy) {
                    proxy.scrollTo("assistant-loading", anchor: .bottom)
                }
            }
        }
    }

    private var availabilityBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: viewModel.availability.systemImage)
                .font(.title3)
                .foregroundStyle(viewModel.availability.isAvailable ? .green : .orange)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(viewModel.availability.title)
                    .font(.subheadline.weight(.semibold))
                Text(viewModel.availability.message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var privacyNotice: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label("Privacy", systemImage: "lock.shield")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    privacyNoticeDismissed = true
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Dismiss privacy notice")
            }

            Text("The assistant uses on-device Apple Intelligence when available and receives scoped DebtScope summaries instead of direct database access.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ask a question about your debts, bills, cash flow, or payoff plan.")
                .font(.callout)
                .foregroundStyle(.secondary)

            FlowLayout(spacing: 8) {
                ForEach(suggestedPrompts, id: \.self) { prompt in
                    Button {
                        sendSuggestedPrompt(prompt)
                    } label: {
                        Text(prompt)
                            .font(.footnote.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .disabled(!viewModel.availability.isAvailable || viewModel.isLoading)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var loadingRow: some View {
        HStack(spacing: 8) {
            ProgressView()
            Text("Working on it")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var inputBar: some View {
        VStack(spacing: 8) {
            if let errorMessage = viewModel.errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask DebtScope", text: $viewModel.currentInput, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .disabled(!viewModel.availability.isAvailable || viewModel.isLoading)
                    .submitLabel(.send)
                    .onSubmit(sendCurrentPrompt)

                Button(action: sendCurrentPrompt) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.canSendPrompt)
                .accessibilityLabel("Send message")
            }
        }
        .padding(12)
        .background(.bar)
    }

    private func sendSuggestedPrompt(_ prompt: String) {
        viewModel.sendPrompt(prompt)
    }

    private func sendCurrentPrompt() {
        guard viewModel.canSendPrompt else { return }
        viewModel.sendCurrentPrompt()
    }
}

private struct AssistantMessageRow: View {
    let message: AssistantMessage

    private var isUserMessage: Bool {
        message.role == .user
    }

    var body: some View {
        HStack(alignment: .bottom) {
            if isUserMessage {
                Spacer(minLength: 36)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(message.text)
                    .font(.body)
                    .foregroundStyle(foregroundStyle)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(backgroundStyle, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            if !isUserMessage {
                Spacer(minLength: 36)
            }
        }
        .frame(maxWidth: .infinity, alignment: isUserMessage ? .trailing : .leading)
    }

    private var label: String {
        switch message.role {
        case .user:
            return "You"
        case .assistant:
            return "DebtScope"
        case .systemNotice:
            return "Notice"
        }
    }

    private var foregroundStyle: Color {
        switch message.role {
        case .user:
            return .white
        case .assistant, .systemNotice:
            return .primary
        }
    }

    private var backgroundStyle: Color {
        switch message.role {
        case .user:
            return .accentColor
        case .assistant:
            return Color(.secondarySystemGroupedBackground)
        case .systemNotice:
            return Color.orange.opacity(0.16)
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        let rows = rows(in: width, subviews: subviews)
        return CGSize(width: width, height: rows.last?.maxY ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = rows(in: bounds.width, subviews: subviews)

        for row in rows {
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: bounds.minX + item.frame.minX, y: bounds.minY + item.frame.minY),
                    proposal: ProposedViewSize(item.frame.size)
                )
            }
        }
    }

    private func rows(in width: CGFloat, subviews: Subviews) -> [FlowRow] {
        var rows: [FlowRow] = []
        var currentItems: [FlowItem] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var rowHeight: CGFloat = 0
        let availableWidth = max(width, 1)

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let itemWidth = min(size.width, availableWidth)
            let proposedX = currentItems.isEmpty ? 0 : currentX + spacing

            if proposedX + itemWidth > availableWidth, !currentItems.isEmpty {
                rows.append(FlowRow(items: currentItems, maxY: currentY + rowHeight))
                currentY += rowHeight + spacing
                currentItems = []
                currentX = 0
                rowHeight = 0
            }

            let itemX = currentItems.isEmpty ? 0 : currentX + spacing
            let frame = CGRect(x: itemX, y: currentY, width: itemWidth, height: size.height)
            currentItems.append(FlowItem(index: index, frame: frame))
            currentX = frame.maxX
            rowHeight = max(rowHeight, size.height)
        }

        if !currentItems.isEmpty {
            rows.append(FlowRow(items: currentItems, maxY: currentY + rowHeight))
        }

        return rows
    }

    private struct FlowRow {
        let items: [FlowItem]
        let maxY: CGFloat
    }

    private struct FlowItem {
        let index: Int
        let frame: CGRect
    }
}

#Preview {
    let container = try! ModelContainer(
        for: Account.self,
        BalanceSnapshot.self,
        CashFlowItem.self,
        Transaction.self,
        ImportBatch.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )

    DebtScopeAssistantView()
        .modelContainer(container)
        .environmentObject(SettingsStore())
}
