import AppKit
import SwiftUI

struct ThoughtCaptureView: View {
    let onSave: (String) -> Void
    let onCancel: () -> Void
    let onPageDelta: (Int) -> Void

    @State private var text = ""

    var body: some View {
        ZStack(alignment: .bottom) {
            CaptureTextView(
                text: $text,
                placeholder: "What is on your mind?",
                onSave: save,
                onCancel: onCancel,
                onPageDelta: onPageDelta
            )
            .frame(height: 86)
            .frame(maxHeight: .infinity, alignment: .top)

            HStack {
                ShortcutKeyGroup(
                    icons: ["command", "return"],
                    label: "Save",
                    accessibilityLabel: "Command Return saves"
                )

                Spacer()

                ShortcutKeyGroup(
                    icons: ["escape"],
                    label: "Close",
                    accessibilityLabel: "Escape closes"
                )
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
        }
        .frame(height: 144, alignment: .top)
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

private struct ShortcutKeyGroup: View {
    let icons: [String]
    let label: String
    let accessibilityLabel: String

    var body: some View {
        HStack(spacing: 7) {
            ForEach(icons, id: \.self) { icon in
                ShortcutKeyIcon(systemName: icon)
            }

            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.42))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct ShortcutKeyIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 10, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.white.opacity(0.58))
            .frame(width: 22, height: 18)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(.white.opacity(0.08))
                    .overlay {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(.white.opacity(0.12), lineWidth: 0.75)
                    }
            }
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
        textView.refreshThemePrefixHighlight()

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

        textView.refreshThemePrefixHighlight()
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
            (textView as? CommandTextView)?.refreshThemePrefixHighlight()
            textView.needsDisplay = true
        }
    }
}

private final class CommandTextView: NSTextView {
    var onSave: (() -> Void)?
    var onCancel: (() -> Void)?
    var onPageDelta: ((Int) -> Void)?
    var placeholderString: String?
    private let prefixHighlightAttribute = NSAttributedString.Key("ThoughtNotchThemePrefixHighlight")

    func refreshThemePrefixHighlight() {
        guard let layoutManager else {
            return
        }

        let fullRange = NSRange(location: 0, length: (string as NSString).length)
        layoutManager.removeTemporaryAttribute(prefixHighlightAttribute, forCharacterRange: fullRange)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: fullRange)
        layoutManager.removeTemporaryAttribute(.font, forCharacterRange: fullRange)
        layoutManager.removeTemporaryAttribute(.shadow, forCharacterRange: fullRange)

        guard let hint = ThoughtPrefixParser.themeHint(in: string) else {
            return
        }

        let categoryColor = NSColor.thoughtCategoryColor(hex: ThoughtCategoryColor.hex(for: hint.title))
        let range = NSRange(location: 0, length: hint.prefixLength)
        let shadow = NSShadow()
        shadow.shadowColor = categoryColor.withAlphaComponent(0.75)
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = .zero

        layoutManager.addTemporaryAttributes(
            [
                prefixHighlightAttribute: true,
                .foregroundColor: categoryColor,
                .font: NSFont.systemFont(ofSize: 18, weight: .semibold),
                .shadow: shadow
            ],
            forCharacterRange: range
        )
    }

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

private extension NSColor {
    static func thoughtCategoryColor(hex: String) -> NSColor {
        let trimmed = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard trimmed.count == 6, let value = Int(trimmed, radix: 16) else {
            return .controlAccentColor
        }

        let red = CGFloat((value >> 16) & 0xFF) / 255
        let green = CGFloat((value >> 8) & 0xFF) / 255
        let blue = CGFloat(value & 0xFF) / 255

        return NSColor(red: red, green: green, blue: blue, alpha: 1)
    }
}
