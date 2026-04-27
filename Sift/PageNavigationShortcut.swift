import AppKit
import KeyboardShortcuts

enum PageNavigationShortcut {
    private static let modifierMask = NSEvent.ModifierFlags([.command, .option, .control, .shift])

    static func activateRegisteredShortcuts() {
        let modifiers = currentModifiers()
        KeyboardShortcuts.setShortcut(
            .init(.leftBracket, modifiers: modifiers),
            for: .previousNotchPage
        )
        KeyboardShortcuts.setShortcut(
            .init(.rightBracket, modifiers: modifiers),
            for: .nextNotchPage
        )
        KeyboardShortcuts.setShortcut(
            .init(.leftArrow, modifiers: [.control]),
            for: .previousNotchPageControl
        )
        KeyboardShortcuts.setShortcut(
            .init(.rightArrow, modifiers: [.control]),
            for: .nextNotchPageControl
        )
    }

    static func deactivateRegisteredShortcuts() {
        KeyboardShortcuts.setShortcut(nil, for: .previousNotchPage)
        KeyboardShortcuts.setShortcut(nil, for: .nextNotchPage)
        KeyboardShortcuts.setShortcut(nil, for: .previousNotchPageControl)
        KeyboardShortcuts.setShortcut(nil, for: .nextNotchPageControl)
    }

    static func direction(for event: NSEvent) -> Int? {
        guard event.keyCode == 33 || event.keyCode == 30 || event.keyCode == 123 || event.keyCode == 124 else {
            return nil
        }

        let eventModifiers = event.modifierFlags.intersection(modifierMask)

        if eventModifiers == .control {
            if event.keyCode == 123 {
                return -1
            }

            if event.keyCode == 124 {
                return 1
            }
        }

        guard event.keyCode == 33 || event.keyCode == 30 else {
            return nil
        }

        if eventModifiers == currentModifiers() {
            return event.keyCode == 33 ? -1 : 1
        }

        return nil
    }

    private static func currentModifiers() -> NSEvent.ModifierFlags {
        let configuredModifiers = KeyboardShortcuts.getShortcut(for: .toggleNotch)?
            .modifiers
            .intersection(modifierMask)

        if let configuredModifiers, !configuredModifiers.isEmpty {
            return configuredModifiers
        }

        return .option
    }
}
