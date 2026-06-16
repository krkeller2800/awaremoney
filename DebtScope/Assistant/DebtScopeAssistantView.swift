import SwiftData
import SwiftUI

struct DebtScopeAssistantView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var settings: SettingsStore

    let embeddedInNavigation: Bool

    init(embeddedInNavigation: Bool = false) {
        self.embeddedInNavigation = embeddedInNavigation
    }

    var body: some View {
        DebtScopeAssistantChatView(
            context: modelContext,
            settings: settings,
            embeddedInNavigation: embeddedInNavigation
        )
    }
}

private struct DebtScopeAssistantChatView: View {
    @EnvironmentObject private var settings: SettingsStore
    @StateObject private var viewModel: DebtScopeAssistantViewModel
    @AppStorage("assistant_privacy_notice_dismissed") private var privacyNoticeDismissed = false
    @State private var isAssistantSettingsPresented = false
    @FocusState private var isInputFocused: Bool

    let embeddedInNavigation: Bool

    private let suggestedPrompts = [
        "What should I clean up next?",
        "Compare avalanche and snowball",
        "What changed after my latest import?",
        "What if I add $100 avalanche?"
    ]

    init(context: ModelContext, settings: SettingsStore, embeddedInNavigation: Bool = false) {
        self.embeddedInNavigation = embeddedInNavigation
        _viewModel = StateObject(wrappedValue: DebtScopeAssistantViewModel(context: context, settings: settings))
    }

    var body: some View {
        if embeddedInNavigation {
            assistantContent
        } else {
            NavigationStack {
                assistantContent
            }
        }
    }

    private var assistantContent: some View {
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

                Button {
                    isAssistantSettingsPresented = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Assistant settings")
            }
        }
        .sheet(isPresented: $isAssistantSettingsPresented) {
            NavigationStack {
                AssistantSettingsSheet()
                    .environmentObject(settings)
            }
        }
        .onAppear {
            viewModel.refreshAvailability()
        }
        .onChange(of: settings.assistantEnabled) { _, _ in
            viewModel.refreshAvailability()
        }
        .onChange(of: viewModel.isLoading) { _, isLoading in
            guard !isLoading else { return }
            isInputFocused = false
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

                if viewModel.availability == .disabledInSettings {
                    Button {
                        isAssistantSettingsPresented = true
                    } label: {
                        Label("Turn On Assistant", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(.top, 4)
                }
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

            Text("The assistant uses on-device Apple Intelligence only and receives scoped DebtScope summaries instead of direct database access.")
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
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(minHeight: 44, alignment: .center)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(.secondarySystemBackground))
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color(.separator), lineWidth: 1)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .focused($isInputFocused)
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
        isInputFocused = false
        viewModel.sendPrompt(prompt)
    }

    private func sendCurrentPrompt() {
        guard viewModel.canSendPrompt else { return }
        isInputFocused = false
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
                    .font(messageFont)
                    .lineSpacing(isUserMessage ? 0 : 2)
                    .foregroundStyle(foregroundStyle)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                if !message.actions.isEmpty {
                    FlowLayout(spacing: 8) {
                        ForEach(message.actions) { action in
                            Button {
                                DebtScopeAppSectionRequestStore.request(action.destination, accountID: action.accountID, focus: action.focus)
                            } label: {
                                Label(action.title, systemImage: "arrow.turn.down.right")
                                    .font(.footnote.weight(.medium))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .padding(.top, 4)
                }
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

    private var messageFont: Font {
        switch message.role {
        case .user:
            return .body
        case .assistant, .systemNotice:
            return .callout
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

private struct AssistantSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: SettingsStore

    private var availability: DebtScopeAssistantAvailability {
        DebtScopeAssistantAvailability.current(assistantEnabled: settings.assistantEnabled)
    }

    var body: some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: availability.systemImage)
                        .font(.title3)
                        .foregroundStyle(availability.isAvailable ? .green : .orange)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(availability.title)
                            .font(.subheadline.weight(.semibold))
                        Text(availability.message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                Toggle("DebtScope Assistant", isOn: $settings.assistantEnabled)
                Toggle("Allow transaction details", isOn: $settings.assistantIncludeTransactions)
                    .disabled(!settings.assistantEnabled)
                Toggle("Keep assistant history", isOn: $settings.assistantRetainConversationHistory)
                    .disabled(!settings.assistantEnabled)
            } header: {
                Text("Assistant")
            } footer: {
                Text("The assistant is read-only and uses scoped DebtScope summaries. Transaction-level details stay off unless explicitly allowed.")
            }

            Section("Privacy") {
                Label("Uses on-device Apple Intelligence only", systemImage: "lock.shield")
                Label("Receives scoped DebtScope summaries", systemImage: "doc.text.magnifyingglass")
                Label("No write actions or account changes", systemImage: "checkmark.shield")
            }
        }
        .navigationTitle("Assistant Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    dismiss()
                }
            }
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
