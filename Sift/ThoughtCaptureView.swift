import AppKit
import SwiftUI

private let capturePrefixGlowOutset: CGFloat = 24
private let captureTodoPrefixColor = NSColor.systemGreen

struct ThoughtCaptureView: View {
    @Binding var text: String

    let textTopInset: CGFloat
    let allowsAutoFocus: Bool
    let onSave: (String) -> Void
    let onCancel: () -> Void
    let onPageDelta: (Int) -> Void

    init(
        text: Binding<String>,
        textTopInset: CGFloat = 0,
        allowsAutoFocus: Bool = true,
        onSave: @escaping (String) -> Void,
        onCancel: @escaping () -> Void,
        onPageDelta: @escaping (Int) -> Void
    ) {
        _text = text
        self.textTopInset = textTopInset
        self.allowsAutoFocus = allowsAutoFocus
        self.onSave = onSave
        self.onCancel = onCancel
        self.onPageDelta = onPageDelta
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            CaptureTextView(
                text: $text,
                textTopInset: textTopInset,
                allowsAutoFocus: allowsAutoFocus,
                placeholder: "What is on your mind?",
                onSave: save,
                onCancel: onCancel,
                onPageDelta: onPageDelta
            )
            .offset(x: -capturePrefixGlowOutset)
            .padding(.trailing, -capturePrefixGlowOutset)
            .frame(height: 86 + textTopInset, alignment: .top)
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
        .frame(height: 144 + textTopInset, alignment: .top)
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

    let textTopInset: CGFloat
    let allowsAutoFocus: Bool
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
        textView.textContainerInset = NSSize(width: capturePrefixGlowOutset, height: 4 + textTopInset)
        textView.textContainer?.lineFragmentPadding = 0
        textView.placeholderString = placeholder
        textView.refreshThemePrefixHighlight()

        let scrollView = CaptureScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
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
        textView.textContainerInset = NSSize(width: capturePrefixGlowOutset, height: 4 + textTopInset)
        (scrollView as? CaptureScrollView)?.onPageDelta = onPageDelta

        DispatchQueue.main.async {
            guard allowsAutoFocus else {
                return
            }

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

private final class CaptureScrollView: NSScrollView {
    var onPageDelta: ((Int) -> Void)?
    private var accumulatedHorizontalScroll: CGFloat = 0
    private var didPageDuringCurrentScrollGesture = false

    override func scrollWheel(with event: NSEvent) {
        if handlePageScroll(event) {
            return
        }

        super.scrollWheel(with: event)
    }

    private func handlePageScroll(_ event: NSEvent) -> Bool {
        let horizontal = event.scrollingDeltaX
        let vertical = event.scrollingDeltaY
        guard abs(horizontal) > abs(vertical) * 1.25, abs(horizontal) > 0.5 else {
            accumulatedHorizontalScroll = 0
            resetEndedScrollGesture(event)
            return false
        }

        if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            resetScrollGestureTracking()
        }

        if !event.momentumPhase.isEmpty {
            resetEndedScrollGesture(event)
            return true
        }

        let isUnphasedWheelEvent = event.phase.isEmpty
        defer {
            if isUnphasedWheelEvent {
                resetScrollGestureTracking()
            } else {
                resetEndedScrollGesture(event)
            }
        }

        if didPageDuringCurrentScrollGesture {
            return true
        }

        accumulatedHorizontalScroll += horizontal

        let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 22 : 2
        guard abs(accumulatedHorizontalScroll) >= threshold else {
            return true
        }

        didPageDuringCurrentScrollGesture = true
        let direction = accumulatedHorizontalScroll > 0 ? 1 : -1
        accumulatedHorizontalScroll = 0
        onPageDelta?(direction)

        return true
    }

    private func resetEndedScrollGesture(_ event: NSEvent) {
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) || event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
            resetScrollGestureTracking()
        }
    }

    private func resetScrollGestureTracking() {
        accumulatedHorizontalScroll = 0
        didPageDuringCurrentScrollGesture = false
    }
}

private final class CommandTextView: NSTextView {
    var onSave: (() -> Void)?
    var onCancel: (() -> Void)?
    var onPageDelta: ((Int) -> Void)?
    var placeholderString: String?
    private let prefixHighlightAttribute = NSAttributedString.Key("SiftThemePrefixHighlight")
    private let todoPrefixHighlightAttribute = NSAttributedString.Key("SiftTodoPrefixHighlight")
    private var isNormalizingTodoPrefixSpacing = false

    func refreshThemePrefixHighlight() {
        guard let layoutManager else {
            return
        }

        let fullRange = NSRange(location: 0, length: (string as NSString).length)
        layoutManager.removeTemporaryAttribute(prefixHighlightAttribute, forCharacterRange: fullRange)
        layoutManager.removeTemporaryAttribute(todoPrefixHighlightAttribute, forCharacterRange: fullRange)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: fullRange)
        layoutManager.removeTemporaryAttribute(.font, forCharacterRange: fullRange)

        if let hint = ThoughtPrefixParser.themeHint(in: string) {
            let categoryColor = NSColor.thoughtCategoryColor(hex: ThoughtCategoryColor.hex(for: hint.title))
            let range = NSRange(location: 0, length: hint.prefixLength)

            layoutManager.addTemporaryAttributes(
                [
                    prefixHighlightAttribute: true,
                    .foregroundColor: categoryColor,
                    .font: NSFont.systemFont(ofSize: 18, weight: .bold)
                ],
                forCharacterRange: range
            )
        }

        guard let todoHint = ThoughtPrefixParser.todoHint(in: string) else {
            return
        }

        let todoColor = captureTodoPrefixColor
        let todoRange = NSRange(location: 0, length: todoHint.prefixLength)
        layoutManager.addTemporaryAttributes(
            [
                todoPrefixHighlightAttribute: true,
                .foregroundColor: todoColor,
                .font: NSFont.systemFont(ofSize: 18, weight: .bold)
            ],
            forCharacterRange: todoRange
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        drawPrefixGlow()
        super.draw(dirtyRect)

        guard string.isEmpty, let placeholderString else {
            return
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white.withAlphaComponent(0.34),
            .font: font ?? NSFont.systemFont(ofSize: 18, weight: .regular)
        ]
        let rect = NSRect(
            x: textContainerInset.width,
            y: textContainerInset.height + 1,
            width: bounds.width - textContainerInset.width,
            height: 24
        )

        placeholderString.draw(in: rect, withAttributes: attributes)
    }

    private func drawPrefixGlow() {
        guard let layoutManager, let textContainer, !string.isEmpty else {
            return
        }

        layoutManager.ensureLayout(for: textContainer)

        for run in prefixGlowRuns() {
            drawGlow(for: run, layoutManager: layoutManager, textContainer: textContainer)
        }
    }

    private func prefixGlowRuns() -> [PrefixGlowRun] {
        let textLength = (string as NSString).length
        guard textLength > 0 else {
            return []
        }

        var runs: [PrefixGlowRun] = []

        if let hint = ThoughtPrefixParser.themeHint(in: string) {
            runs.append(
                PrefixGlowRun(
                    characterRange: NSRange(location: 0, length: min(hint.prefixLength, textLength)),
                    color: NSColor.thoughtCategoryColor(hex: ThoughtCategoryColor.hex(for: hint.title)).withAlphaComponent(0.95),
                    blurRadius: 22
                )
            )
        }

        if let todoHint = ThoughtPrefixParser.todoHint(in: string) {
            runs.append(
                PrefixGlowRun(
                    characterRange: NSRange(location: 0, length: min(todoHint.prefixLength, textLength)),
                    color: captureTodoPrefixColor.withAlphaComponent(1.0),
                    blurRadius: 24
                )
            )
        }

        return runs
    }

    private func drawGlow(for run: PrefixGlowRun, layoutManager: NSLayoutManager, textContainer: NSTextContainer) {
        guard run.characterRange.length > 0 else {
            return
        }

        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: run.characterRange,
            actualCharacterRange: nil
        )

        guard glyphRange.length > 0, let context = NSGraphicsContext.current?.cgContext else {
            return
        }

        NSGraphicsContext.saveGraphicsState()
        context.setShadow(
            offset: .zero,
            blur: run.blurRadius,
            color: run.color.cgColor
        )
        layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: textContainerOrigin)
        NSGraphicsContext.restoreGraphicsState()
    }

    private struct PrefixGlowRun {
        let characterRange: NSRange
        let color: NSColor
        let blurRadius: CGFloat
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

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        super.insertText(insertString, replacementRange: replacementRange)
        normalizeTodoPrefixSpacing()
    }

    private func normalizeTodoPrefixSpacing() {
        guard !isNormalizingTodoPrefixSpacing else {
            return
        }

        let nsString = string as NSString
        guard nsString.length > 0, nsString.substring(to: 1) == "!" else {
            return
        }

        if nsString.length > 1 {
            let characterAfterPrefix = nsString.substring(with: NSRange(location: 1, length: 1))
            guard characterAfterPrefix.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
                return
            }
        }

        let insertionRange = NSRange(location: 1, length: 0)
        guard shouldChangeText(in: insertionRange, replacementString: " ") else {
            return
        }

        isNormalizingTodoPrefixSpacing = true
        textStorage?.replaceCharacters(in: insertionRange, with: " ")
        didChangeText()
        isNormalizingTodoPrefixSpacing = false
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
