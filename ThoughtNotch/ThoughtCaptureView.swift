import AppKit
import SwiftUI

struct ThoughtCaptureView: View {
    let onSave: (String) -> Void
    let onCancel: () -> Void
    let onPageDelta: (Int) -> Void

    @State private var text = ""

    var body: some View {
        VStack(spacing: 10) {
            CaptureTextView(
                text: $text,
                placeholder: "What is on your mind?",
                onSave: save,
                onCancel: onCancel,
                onPageDelta: onPageDelta
            )
            .frame(height: 86)

            HStack {
                Text("cmd+enter saves")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.44))

                Spacer()

                Text("esc closes")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.36))
            }
        }
    }

    private func save() {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedText.isEmpty else {
            onCancel()
            return
        }

        onSave(trimmedText)
        text = ""
    }
}

private struct CaptureTextView: NSViewRepresentable {
    @Binding var text: String

    let placeholder: String
    let onSave: () -> Void
    let onCancel: () -> Void
    let onPageDelta: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = CommandTextView()
        textView.delegate = context.coordinator
        textView.font = .systemFont(ofSize: 18, weight: .regular)
        textView.textColor = .white
        textView.insertionPointColor = .white
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = true
        textView.isAutomaticDashSubstitutionEnabled = true
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.textContainer?.lineFragmentPadding = 0
        textView.placeholderString = placeholder

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.documentView = textView

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? CommandTextView else {
            return
        }

        if textView.string != text {
            textView.string = text
        }

        textView.onSave = onSave
        textView.onCancel = onCancel
        textView.onPageDelta = onPageDelta

        DispatchQueue.main.async {
            guard let window = textView.window else {
                return
            }

            if window.firstResponder !== textView {
                window.makeFirstResponder(textView)
            }
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

private final class CommandTextView: NSTextView {
    var onSave: (() -> Void)?
    var onCancel: (() -> Void)?
    var onPageDelta: ((Int) -> Void)?
    var placeholderString: String?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard string.isEmpty, let placeholderString else {
            return
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white.withAlphaComponent(0.34),
            .font: font ?? NSFont.systemFont(ofSize: 18, weight: .regular)
        ]
        let rect = NSRect(x: 0, y: textContainerInset.height + 1, width: bounds.width, height: 24)

        placeholderString.draw(in: rect, withAttributes: attributes)
    }

    override func keyDown(with event: NSEvent) {
        let commandPressed = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)

        if let direction = PageNavigationShortcut.direction(for: event) {
            onPageDelta?(direction)
            return
        }

        if commandPressed && (event.keyCode == 36 || event.keyCode == 76) {
            onSave?()
            return
        }

        if event.keyCode == 53 {
            onCancel?()
            return
        }

        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let direction = PageNavigationShortcut.direction(for: event) {
            onPageDelta?(direction)
            return true
        }

        return super.performKeyEquivalent(with: event)
    }
}
