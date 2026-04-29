import AppKit
import SwiftUI

struct NotchChatView: View {
    @ObservedObject var store: ThoughtStore
    @ObservedObject var chatModel: ThoughtChatModel
    @ObservedObject private var settings = AISettings.shared
    @State private var transcriptScrollCommand: ChatTranscriptScrollCommand?

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
        .frame(maxHeight: .infinity, alignment: .top)
        .foregroundStyle(.white)
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
                                isLoading: chatModel.isAsking && message.id == chatModel.messages.last?.id,
                                onConfirmAction: { actionID in
                                    chatModel.confirmProposedAction(actionID, in: message.id, store: store)
                                },
                                onCancelAction: { actionID in
                                    chatModel.cancelProposedAction(actionID, in: message.id)
                                }
                            )
                                .id(message.id)
                        }
                    }
                }
                .padding(.trailing, 4)
                .background(
                    ChatTranscriptScrollBridge(command: transcriptScrollCommand)
                        .frame(width: 0, height: 0)
                )
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: .infinity, alignment: .top)
            .layoutPriority(1)
            .onChange(of: chatModel.messages) { _, messages in
                scrollToBottom(messages: messages, proxy: proxy)
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
        guard let id = messages.last?.id else {
            return
        }

        DispatchQueue.main.async {
            withAnimation(.smooth(duration: 0.16)) {
                proxy.scrollTo(id, anchor: .bottom)
            }
        }
    }

    private func scrollTranscript(_ delta: Int) {
        transcriptScrollCommand = ChatTranscriptScrollCommand(delta: delta)
    }
}

private struct ChatMessageRow: View {
    let message: ThoughtChatMessage
    let isLoading: Bool
    let onConfirmAction: (UUID) -> Void
    let onCancelAction: (UUID) -> Void

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

                Text(displayText)
                    .font(.system(size: isUser ? 12 : 12.5, weight: isUser ? .medium : .regular))
                    .foregroundStyle(isUser ? .white.opacity(0.92) : .white.opacity(0.86))
                    .multilineTextAlignment(isUser ? .trailing : .leading)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isUser ? .white.opacity(0.12) : .white.opacity(0.06))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(.white.opacity(isUser ? 0.14 : 0.08), lineWidth: 1)
                            }
                    }

                if !isUser {
                    Spacer(minLength: 72)
                }
            }

            if !message.proposedActions.isEmpty {
                ProposedActionList(
                    actions: message.proposedActions,
                    onConfirm: onConfirmAction,
                    onCancel: onCancelAction
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    private var displayText: String {
        if message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, isLoading {
            return "Thinking..."
        }

        return message.text
    }
}

private struct ProposedActionList: View {
    let actions: [ThoughtChatProposedAction]
    let onConfirm: (UUID) -> Void
    let onCancel: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(actions) { action in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 5) {
                        Image(systemName: iconName(for: action))
                            .font(.system(size: 10, weight: .semibold))

                        Text(title(for: action))
                            .font(.caption2.weight(.semibold))

                        Spacer(minLength: 8)
                    }

                    Text(action.text)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(3)

                    if !action.reason.isEmpty {
                        Text(action.reason)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.42))
                            .lineLimit(2)
                    }

                    if action.status == .pending {
                        HStack(spacing: 6) {
                            Button {
                                onConfirm(action.id)
                            } label: {
                                Label("Confirm", systemImage: "checkmark")
                                    .font(.caption2.weight(.semibold))
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 4)
                            .padding(.horizontal, 7)
                            .background {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(.white.opacity(0.13))
                            }

                            Button {
                                onCancel(action.id)
                            } label: {
                                Label("Cancel", systemImage: "xmark")
                                    .font(.caption2.weight(.semibold))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.white.opacity(0.58))
                        }
                    }
                }
                .foregroundStyle(.white.opacity(0.82))
                .frame(maxWidth: 230, alignment: .leading)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.white.opacity(0.07))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(.white.opacity(0.1), lineWidth: 1)
                        }
                }
            }
        }
    }

    private func title(for action: ThoughtChatProposedAction) -> String {
        switch action.status {
        case .pending:
            return "Add thought?"
        case .confirmed:
            return "Thought added"
        case .canceled:
            return "Canceled"
        }
    }

    private func iconName(for action: ThoughtChatProposedAction) -> String {
        switch action.status {
        case .pending:
            return "plus.circle"
        case .confirmed:
            return "checkmark.circle"
        case .canceled:
            return "xmark.circle"
        }
    }
}

private struct SourceStrip: View {
    let sources: [ThoughtChatSource]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(sources.prefix(6)) { source in
                    sourceCard(source)
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private func sourceCard(_ source: ThoughtChatSource) -> some View {
        let card = SourceCard(source: source)
        if let url = source.url {
            Link(destination: url) {
                card
            }
            .buttonStyle(.plain)
        } else {
            card
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
        .frame(width: 138, alignment: .leading)
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
