import AppKit
import SwiftUI

struct NotchChatView: View {
    @ObservedObject var store: ThoughtStore
    @ObservedObject var chatModel: ThoughtChatModel
    @ObservedObject private var settings = AISettings.shared
    @State private var transcriptScrollCommand: ChatTranscriptScrollCommand?
    @State private var transcriptContentHeight: CGFloat = 0
    @State private var selectedProposedActionID: UUID?
    @State private var selectedProposedActionChoice: ProposedActionChoice = .confirm

    let onCancel: () -> Void
    let onPageDelta: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header

            transcript

            if let errorMessage = chatModel.errorMessage {
                Text(errorMessage)
                    .font(.caption2)
                    .foregroundStyle(.orange.opacity(0.9))
                    .lineLimit(2)
            }

            composer
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .foregroundStyle(.white)
        .onChange(of: pendingProposedActionIDs) { _, _ in
            ensureSelectedProposedAction()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 13, weight: .semibold))

            Text("Chat")
                .font(.headline)

            Spacer()

            if chatModel.isAsking {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.56)
                    .frame(width: 14, height: 14)
            }
        }
        .foregroundStyle(.white.opacity(0.86))
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 7) {
                    if chatModel.messages.isEmpty {
                        emptyState
                    } else {
                        ForEach(chatModel.messages) { message in
                            ChatMessageRow(
                                message: message,
                                isLoading: chatModel.isAsking && message.id == chatModel.messages.last?.id
                            )
                                .id(message.id)
                        }
                    }
                }
                .padding(.trailing, 4)
                .background(
                    GeometryReader { geometry in
                        Color.clear
                            .preference(key: ChatTranscriptContentHeightKey.self, value: geometry.size.height)
                    }
                )
                .background(
                    ChatTranscriptScrollBridge(command: transcriptScrollCommand)
                        .frame(width: 0, height: 0)
                )
                .id(ChatTranscriptAnchor.content)

                Color.clear
                    .frame(height: 1)
                    .id(ChatTranscriptAnchor.bottom)
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: .infinity, alignment: .top)
            .layoutPriority(1)
            .onChange(of: chatModel.messages) { _, messages in
                scrollToBottom(messages: messages, proxy: proxy)
            }
            .onPreferenceChange(ChatTranscriptContentHeightKey.self) { height in
                let didGrow = height > transcriptContentHeight
                transcriptContentHeight = height

                guard didGrow, chatModel.isAsking, !chatModel.messages.isEmpty else {
                    return
                }

                scrollToBottom(proxy: proxy, animated: false)
            }
        }
    }

    @ViewBuilder
    private var composer: some View {
        if let pendingAction = selectedProposedAction {
            ProposedActionComposer(
                action: pendingAction.action,
                currentIndex: selectedProposedActionIndex + 1,
                count: pendingProposedActions.count,
                selectedChoice: selectedProposedActionChoice,
                onConfirm: {
                    chatModel.confirmProposedAction(pendingAction.action.id, in: pendingAction.messageID, store: store)
                },
                onCancel: {
                    chatModel.cancelProposedAction(pendingAction.action.id, in: pendingAction.messageID)
                },
                onMoveAction: moveSelectedProposedAction,
                onMoveChoice: moveSelectedProposedActionChoice
            )
            .frame(minHeight: 42)
        } else {
            HStack(alignment: .center, spacing: 8) {
                ChatInputView(
                    text: $chatModel.draft,
                    placeholder: "Ask about your thoughts",
                    isEnabled: !chatModel.isAsking,
                    onSubmit: ask,
                    onCancel: onCancel,
                    onPageDelta: onPageDelta,
                    onTranscriptScroll: scrollTranscript
                )
                .frame(height: 30)

                Button {
                    ask()
                } label: {
                    Image(systemName: chatModel.isAsking ? "hourglass" : "arrow.up.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                }
                .frame(width: 28, height: 30)
                .contentShape(Rectangle())
                .buttonStyle(.plain)
                .foregroundStyle(chatModel.canSend ? .white.opacity(0.88) : .white.opacity(0.28))
                .disabled(!chatModel.canSend)
                .help("Ask")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 18))

            Text(store.thoughts.isEmpty ? "No thoughts yet" : "Ask what your thoughts say")
                .font(.callout.weight(.medium))
        }
        .frame(maxWidth: .infinity, minHeight: 58)
        .foregroundStyle(.white.opacity(0.44))
    }

    private func ask() {
        chatModel.ask(store: store, settings: settings)
    }

    private func scrollToBottom(messages: [ThoughtChatMessage], proxy: ScrollViewProxy) {
        guard !messages.isEmpty else {
            return
        }

        scrollToBottom(proxy: proxy)
    }

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool = true) {
        DispatchQueue.main.async {
            if animated {
                withAnimation(.smooth(duration: 0.16)) {
                    proxy.scrollTo(ChatTranscriptAnchor.bottom, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(ChatTranscriptAnchor.bottom, anchor: .bottom)
            }
        }
    }

    private func scrollTranscript(_ delta: Int) {
        transcriptScrollCommand = ChatTranscriptScrollCommand(delta: delta)
    }

    private var pendingProposedActions: [PendingProposedChatAction] {
        chatModel.messages.flatMap { message in
            message.proposedActions
                .filter { $0.status == .pending }
                .map { PendingProposedChatAction(messageID: message.id, action: $0) }
        }
    }

    private var pendingProposedActionIDs: [UUID] {
        pendingProposedActions.map(\.id)
    }

    private var selectedProposedAction: PendingProposedChatAction? {
        let actions = pendingProposedActions
        guard !actions.isEmpty else {
            return nil
        }

        if let selectedProposedActionID,
           let action = actions.first(where: { $0.id == selectedProposedActionID }) {
            return action
        }

        return actions[0]
    }

    private var selectedProposedActionIndex: Int {
        guard let selectedProposedAction else {
            return 0
        }

        return pendingProposedActions.firstIndex(where: { $0.id == selectedProposedAction.id }) ?? 0
    }

    private func ensureSelectedProposedAction() {
        let actions = pendingProposedActions
        guard !actions.isEmpty else {
            selectedProposedActionID = nil
            return
        }

        if let selectedProposedActionID,
           actions.contains(where: { $0.id == selectedProposedActionID }) {
            return
        }

        selectedProposedActionID = actions[0].id
        selectedProposedActionChoice = .confirm
    }

    private func moveSelectedProposedAction(_ delta: Int) {
        let actions = pendingProposedActions
        guard !actions.isEmpty else {
            selectedProposedActionID = nil
            return
        }

        let currentIndex = selectedProposedActionID.flatMap { id in
            actions.firstIndex { $0.id == id }
        } ?? 0
        let nextIndex = min(max(currentIndex + delta, 0), actions.count - 1)
        selectedProposedActionID = actions[nextIndex].id
        selectedProposedActionChoice = .confirm
    }

    private func moveSelectedProposedActionChoice(_ delta: Int) {
        selectedProposedActionChoice = selectedProposedActionChoice.moved(delta)
    }
}

private enum ChatTranscriptAnchor {
    static let content = "chat-transcript-content"
    static let bottom = "chat-transcript-bottom"
}

private struct ChatTranscriptContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ChatMessageRow: View {
    let message: ThoughtChatMessage
    let isLoading: Bool

    @State private var shouldKeepStreamingRenderer = false
    @State private var streamingHoldID = UUID()

    private var isUser: Bool {
        message.role == .user
    }

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 5) {
            if !message.sources.isEmpty {
                SourceStrip(sources: message.sources)
            }

            HStack {
                if isUser {
                    Spacer(minLength: 72)
                }

                messageContent
                    .padding(.vertical, 2)

                if !isUser {
                    Spacer(minLength: 72)
                }
            }

        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .onAppear {
            if shouldUseStreamingRenderer {
                holdStreamingRenderer(for: displayText)
            }
        }
        .onChange(of: message.text) { _, newText in
            holdStreamingRenderer(for: newText)
        }
        .onChange(of: isLoading) { _, isLoading in
            if !isLoading {
                holdStreamingRenderer(for: displayText)
            }
        }
    }

    private var displayText: String {
        if isThinkingPlaceholder {
            return "Thinking..."
        }

        return message.text
    }

    private var isThinkingPlaceholder: Bool {
        message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && isLoading
    }

    @ViewBuilder
    private var messageContent: some View {
        if isUser {
            Text(displayText)
                .font(.system(size: isUser ? 12 : 12.5, weight: isUser ? .medium : .regular))
                .foregroundStyle(.white.opacity(0.92))
                .multilineTextAlignment(isUser ? .trailing : .leading)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        } else if isThinkingPlaceholder {
            ThinkingStatusText(text: displayText)
        } else if shouldUseStreamingRenderer {
            StreamingMarkdownChatText(text: displayText)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            MarkdownDocumentView(markdown: displayText, style: .chat)
                .multilineTextAlignment(.leading)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var shouldUseStreamingRenderer: Bool {
        !isUser && !isThinkingPlaceholder && (isLoading || shouldKeepStreamingRenderer)
    }

    private func holdStreamingRenderer(for text: String) {
        guard !isUser, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        let holdID = UUID()
        streamingHoldID = holdID
        shouldKeepStreamingRenderer = true

        DispatchQueue.main.asyncAfter(deadline: .now() + StreamingMarkdownChatText.revealDuration(for: text) + 0.08) {
            guard streamingHoldID == holdID, !isLoading else {
                return
            }

            shouldKeepStreamingRenderer = false
        }
    }
}

private struct ThinkingStatusText: View {
    let text: String

    private let duration: TimeInterval = 1.65

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60)) { timeline in
            let seconds = timeline.date.timeIntervalSinceReferenceDate
            let phase = CGFloat(seconds.truncatingRemainder(dividingBy: duration) / duration)

            textView
                .foregroundStyle(.white.opacity(0.48))
                .overlay(alignment: .leading) {
                    GeometryReader { geometry in
                        let width = geometry.size.width
                        let sheenWidth = max(width * 0.58, 24)
                        let travel = width + sheenWidth * 2
                        let xOffset = -sheenWidth + travel * phase

                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0), location: 0),
                                .init(color: .white.opacity(0.95), location: 0.5),
                                .init(color: .white.opacity(0), location: 1)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: sheenWidth)
                        .offset(x: xOffset)
                        .blur(radius: 0.35)
                        .mask(alignment: .leading) {
                            textView
                                .frame(width: width, height: geometry.size.height, alignment: .leading)
                        }
                    }
                }
                .fixedSize(horizontal: true, vertical: true)
                .accessibilityLabel(text)
        }
    }

    private var textView: some View {
        Text(text)
            .font(.system(size: 12.5, weight: .regular))
            .multilineTextAlignment(.leading)
            .lineLimit(1)
    }
}

private struct StreamingMarkdownChatText: View {
    let text: String

    @State private var visibleMarkdown = ""
    @State private var targetMarkdown = ""
    @State private var pendingFragments: [String] = []
    @State private var isRevealing = false
    @State private var revealID = UUID()

    var body: some View {
        MarkdownDocumentView(markdown: visibleMarkdown, style: .chat)
            .multilineTextAlignment(.leading)
            .lineLimit(nil)
            .onAppear {
                syncMarkdown(with: text)
            }
            .onChange(of: text) { _, newText in
                syncMarkdown(with: newText)
            }
    }

    private func syncMarkdown(with newText: String) {
        if newText.hasPrefix(targetMarkdown) {
            let delta = String(newText.dropFirst(targetMarkdown.count))
            pendingFragments.append(contentsOf: Self.fragments(from: delta))
        } else {
            revealID = UUID()
            visibleMarkdown = ""
            pendingFragments = Self.fragments(from: newText)
            isRevealing = false
        }

        targetMarkdown = newText
        revealNextIfNeeded()
    }

    private func revealNextIfNeeded() {
        guard !isRevealing else {
            return
        }

        isRevealing = true
        revealNext(revealID)
    }

    private func revealNext(_ id: UUID) {
        guard id == revealID else {
            return
        }

        guard !pendingFragments.isEmpty else {
            isRevealing = false
            return
        }

        let fragment = pendingFragments.removeFirst()
        withAnimation(.linear(duration: Self.fragmentFadeDuration)) {
            visibleMarkdown += fragment
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fragmentRevealInterval) {
            revealNext(id)
        }
    }

    static func revealDuration(for text: String) -> TimeInterval {
        TimeInterval(max(fragments(from: text).count - 1, 0)) * fragmentRevealInterval + fragmentFadeDuration
    }

    private static func fragments(from text: String) -> [String] {
        var fragments: [String] = []
        var current = ""
        var currentIsWhitespace: Bool?

        for character in text {
            let isWhitespace = character.isWhitespace
            if let currentIsWhitespace, currentIsWhitespace != isWhitespace {
                fragments.append(current)
                current = ""
            }

            current.append(character)
            currentIsWhitespace = isWhitespace
        }

        if !current.isEmpty {
            fragments.append(current)
        }

        return fragments
    }

    private static let fragmentRevealInterval: TimeInterval = 0.02
    private static let fragmentFadeDuration: TimeInterval = 0.3
}

private struct PendingProposedChatAction: Identifiable, Equatable {
    let messageID: UUID
    let action: ThoughtChatProposedAction

    var id: UUID {
        action.id
    }
}

private enum ProposedActionChoice {
    case confirm
    case cancel

    func moved(_ delta: Int) -> ProposedActionChoice {
        guard delta != 0 else {
            return self
        }

        switch self {
        case .confirm:
            return delta > 0 ? .cancel : .confirm
        case .cancel:
            return delta < 0 ? .confirm : .cancel
        }
    }
}

private struct ProposedActionComposer: View {
    let action: ThoughtChatProposedAction
    let currentIndex: Int
    let count: Int
    let selectedChoice: ProposedActionChoice
    let onConfirm: () -> Void
    let onCancel: () -> Void
    let onMoveAction: (Int) -> Void
    let onMoveChoice: (Int) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: iconName(for: action))
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title(for: action))
                        .font(.caption2.weight(.semibold))

                    if count > 1 {
                        Text("\(currentIndex)/\(count)")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.white.opacity(0.42))
                    }
                }

                Text(action.text)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button {
                onConfirm()
            } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
            }
            .frame(width: 26, height: 26)
            .buttonStyle(.plain)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selectedChoice == .confirm ? .white.opacity(0.18) : .white.opacity(0.09))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(.white.opacity(selectedChoice == .confirm ? 0.32 : 0), lineWidth: 1)
                    }
            }
            .help("Confirm")

            Button {
                onCancel()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
            }
            .frame(width: 24, height: 26)
            .buttonStyle(.plain)
            .foregroundStyle(selectedChoice == .cancel ? .white.opacity(0.82) : .white.opacity(0.58))
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selectedChoice == .cancel ? .white.opacity(0.1) : .clear)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(.white.opacity(selectedChoice == .cancel ? 0.24 : 0), lineWidth: 1)
                    }
            }
            .help("Cancel")
        }
        .foregroundStyle(.white.opacity(0.82))
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.white.opacity(0.08))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.white.opacity(0.14), lineWidth: 1)
                }
        }
        .background(
            ProposedActionKeyboardBridge(
                onActivate: selectedChoice == .confirm ? onConfirm : onCancel,
                onCancel: onCancel,
                onMoveAction: onMoveAction,
                onMoveChoice: onMoveChoice
            )
        )
    }

    private func title(for action: ThoughtChatProposedAction) -> String {
        switch action.kind {
        case .addThought:
            switch action.status {
            case .pending:
                return "Add thought?"
            case .confirmed:
                return "Thought added"
            case .canceled:
                return "Canceled"
            }
        case .completeAction:
            switch action.status {
            case .pending:
                return "Complete todo?"
            case .confirmed:
                return "Todo completed"
            case .canceled:
                return "Canceled"
            }
        }
    }

    private func iconName(for action: ThoughtChatProposedAction) -> String {
        switch action.kind {
        case .addThought:
            switch action.status {
            case .pending:
                return "plus.circle"
            case .confirmed:
                return "checkmark.circle"
            case .canceled:
                return "xmark.circle"
            }
        case .completeAction:
            switch action.status {
            case .pending:
                return "checkmark.circle"
            case .confirmed:
                return "checkmark.circle.fill"
            case .canceled:
                return "xmark.circle"
            }
        }
    }
}

private struct ProposedActionKeyboardBridge: NSViewRepresentable {
    let onActivate: () -> Void
    let onCancel: () -> Void
    let onMoveAction: (Int) -> Void
    let onMoveChoice: (Int) -> Void

    func makeNSView(context: Context) -> ProposedActionKeyView {
        let view = ProposedActionKeyView()
        view.onActivate = onActivate
        view.onCancel = onCancel
        view.onMoveAction = onMoveAction
        view.onMoveChoice = onMoveChoice
        return view
    }

    func updateNSView(_ view: ProposedActionKeyView, context: Context) {
        view.onActivate = onActivate
        view.onCancel = onCancel
        view.onMoveAction = onMoveAction
        view.onMoveChoice = onMoveChoice

        DispatchQueue.main.async {
            guard let window = view.window, window.firstResponder !== view else {
                return
            }

            window.makeFirstResponder(view)
        }
    }
}

private final class ProposedActionKeyView: NSView {
    var onActivate: (() -> Void)?
    var onCancel: (() -> Void)?
    var onMoveAction: ((Int) -> Void)?
    var onMoveChoice: ((Int) -> Void)?

    override var acceptsFirstResponder: Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])

        if modifiers.isEmpty {
            switch event.keyCode {
            case 36, 76:
                onActivate?()
                return
            case 53:
                onCancel?()
                return
            case 123:
                onMoveChoice?(-1)
                return
            case 124:
                onMoveChoice?(1)
                return
            case 126:
                onMoveAction?(-1)
                return
            case 125:
                onMoveAction?(1)
                return
            default:
                break
            }
        }

        super.keyDown(with: event)
    }
}

private struct SourceStrip: View {
    let sources: [ThoughtChatSource]

    @State private var visibleSourceIDs: Set<UUID> = []

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(Array(displayedSources.enumerated()), id: \.element.id) { index, source in
                    sourceCard(source, at: index)
                }
            }
        }
        .scrollIndicators(.hidden)
        .onAppear {
            revealDisplayedSources()
        }
        .onChange(of: displayedSourceIDs) { _, _ in
            visibleSourceIDs.formIntersection(displayedSourceIDs)
            revealDisplayedSources()
        }
    }

    private var displayedSources: [ThoughtChatSource] {
        Array(sources.prefix(6))
    }

    private var displayedSourceIDs: Set<UUID> {
        Set(displayedSources.map(\.id))
    }

    @ViewBuilder
    private func sourceCard(_ source: ThoughtChatSource, at index: Int) -> some View {
        let card = SourceCard(source: source)
            .sourceCardEntrance(isVisible: visibleSourceIDs.contains(source.id), index: index)

        if let url = source.url {
            Link(destination: url) {
                card
            }
            .buttonStyle(.plain)
        } else {
            card
        }
    }

    private func revealDisplayedSources() {
        for source in displayedSources where !visibleSourceIDs.contains(source.id) {
            visibleSourceIDs.insert(source.id)
        }
    }
}

private struct SourceCard: View {
    let source: ThoughtChatSource

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: iconName)
                    .font(.system(size: 9, weight: .semibold))

                Text(source.displayTitle)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
            }

            Text(source.snippet)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.42))
                .lineLimit(2)
        }
        .foregroundStyle(.white.opacity(0.58))
        .frame(width: 138, height: 46, alignment: .leading)
        .padding(.vertical, 5)
        .padding(.horizontal, 7)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.white.opacity(0.055))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                }
        }
    }

    private var iconName: String {
        switch source.kind {
        case .thought:
            return "text.bubble"
        case .page:
            return "doc.text"
        case .actionItem:
            return "checklist"
        case .web:
            return "globe"
        }
    }
}

private struct SourceCardEntranceModifier: ViewModifier {
    let isVisible: Bool
    let index: Int

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .blur(radius: isVisible ? 0 : 8)
            .offset(x: isVisible ? 0 : 24)
            .animation(
                .smooth(duration: 0.28).delay(Double(index) * 0.045),
                value: isVisible
            )
    }
}

private extension View {
    func sourceCardEntrance(isVisible: Bool, index: Int) -> some View {
        modifier(SourceCardEntranceModifier(isVisible: isVisible, index: index))
    }
}

private struct ChatInputView: NSViewRepresentable {
    @Binding var text: String

    let placeholder: String
    let isEnabled: Bool
    let onSubmit: () -> Void
    let onCancel: () -> Void
    let onPageDelta: (Int) -> Void
    let onTranscriptScroll: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ChatCommandTextView()
        textView.delegate = context.coordinator
        textView.font = .systemFont(ofSize: 13, weight: .regular)
        textView.textColor = .white
        textView.insertionPointColor = .white
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = true
        textView.isAutomaticDashSubstitutionEnabled = true
        textView.textContainerInset = NSSize(width: 8, height: 7)
        textView.textContainer?.lineFragmentPadding = 0
        textView.placeholderString = placeholder

        let scrollView = NSScrollView()
        scrollView.identifier = .siftChatInput
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.documentView = textView
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 8
        scrollView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.07).cgColor
        scrollView.layer?.borderColor = NSColor.white.withAlphaComponent(0.11).cgColor
        scrollView.layer?.borderWidth = 1

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ChatCommandTextView else {
            return
        }

        if textView.string != text {
            textView.string = text
        }

        textView.isEditable = isEnabled
        textView.placeholderString = placeholder
        textView.onSubmit = onSubmit
        textView.onCancel = onCancel
        textView.onPageDelta = onPageDelta
        textView.onTranscriptScroll = onTranscriptScroll
        textView.needsDisplay = true

        DispatchQueue.main.async {
            guard let window = textView.window, window.firstResponder !== textView else {
                return
            }

            window.makeFirstResponder(textView)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else {
                return
            }

            text = textView.string
            textView.needsDisplay = true
        }
    }
}

private final class ChatCommandTextView: NSTextView {
    var placeholderString: String?
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?
    var onPageDelta: ((Int) -> Void)?
    var onTranscriptScroll: ((Int) -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard string.isEmpty, let placeholderString else {
            return
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white.withAlphaComponent(0.34),
            .font: font ?? NSFont.systemFont(ofSize: 13, weight: .regular)
        ]
        let rect = NSRect(
            x: textContainerInset.width,
            y: textContainerInset.height,
            width: bounds.width - textContainerInset.width * 2,
            height: 18
        )

        placeholderString.draw(in: rect, withAttributes: attributes)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])

        if let direction = PageNavigationShortcut.direction(for: event) {
            onPageDelta?(direction)
            return
        }

        if (event.keyCode == 36 || event.keyCode == 76), modifiers.isEmpty || modifiers == .command {
            onSubmit?()
            return
        }

        if modifiers.isEmpty {
            switch event.keyCode {
            case 126:
                onTranscriptScroll?(-1)
                return
            case 125:
                onTranscriptScroll?(1)
                return
            default:
                break
            }
        }

        if event.keyCode == 53 {
            onCancel?()
            return
        }

        super.keyDown(with: event)
    }
}

extension NSUserInterfaceItemIdentifier {
    static let siftChatInput = Self("SiftChatInput")
}

private struct ChatTranscriptScrollCommand: Equatable {
    let id = UUID()
    let delta: Int
}

private struct ChatTranscriptScrollBridge: NSViewRepresentable {
    let command: ChatTranscriptScrollCommand?

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let command else {
            return
        }

        DispatchQueue.main.async {
            guard let scrollView = view.enclosingScrollView else {
                return
            }

            let clipView = scrollView.contentView
            let documentHeight = scrollView.documentView?.bounds.height ?? 0
            let visibleHeight = clipView.bounds.height
            let currentY = clipView.bounds.origin.y
            let nextY = min(max(currentY + CGFloat(command.delta) * 34, 0), max(0, documentHeight - visibleHeight))

            clipView.animator().setBoundsOrigin(NSPoint(x: clipView.bounds.origin.x, y: nextY))
            scrollView.reflectScrolledClipView(clipView)
        }
    }
}
