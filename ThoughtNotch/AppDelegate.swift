import AppKit
import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    static let toggleNotch = Self("toggleNotch", default: .init(.space, modifiers: [.option]))
    static let previousNotchPage = Self("previousNotchPage")
    static let nextNotchPage = Self("nextNotchPage")
    static let previousNotchPageControl = Self("previousNotchPageControl")
    static let nextNotchPageControl = Self("nextNotchPageControl")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = ThoughtStore.shared
    private lazy var notchPanelController = NotchPanelController(store: store)
    private var libraryWindowController: NSWindowController?
    private var settingsWindowController: NSWindowController?
    private var shortcutChangeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        PageNavigationShortcut.deactivateRegisteredShortcuts()

        KeyboardShortcuts.onKeyDown(for: .toggleNotch) { [weak self] in
            Task { @MainActor in
                self?.toggleNotch()
            }
        }

        KeyboardShortcuts.onKeyDown(for: .previousNotchPage) { [weak self] in
            Task { @MainActor in
                self?.moveNotchPage(-1)
            }
        }

        KeyboardShortcuts.onKeyDown(for: .nextNotchPage) { [weak self] in
            Task { @MainActor in
                self?.moveNotchPage(1)
            }
        }

        KeyboardShortcuts.onKeyDown(for: .previousNotchPageControl) { [weak self] in
            Task { @MainActor in
                self?.moveNotchPage(-1)
            }
        }

        KeyboardShortcuts.onKeyDown(for: .nextNotchPageControl) { [weak self] in
            Task { @MainActor in
                self?.moveNotchPage(1)
            }
        }

        shortcutChangeObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("KeyboardShortcuts_shortcutByNameDidChange"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let name = notification.userInfo?["name"] as? KeyboardShortcuts.Name,
                name == .toggleNotch
            else {
                return
            }

            Task { @MainActor [weak self] in
                self?.notchPanelController.refreshPageShortcuts()
            }
        }
    }

    func toggleNotch() {
        notchPanelController.toggle()
    }

    func moveNotchPage(_ delta: Int) {
        notchPanelController.movePage(delta)
    }

    func openLibrary() {
        if libraryWindowController == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Thought Library"
            window.center()
            window.contentView = NSHostingView(rootView: LibraryWindow(store: store))
            window.isReleasedWhenClosed = false

            libraryWindowController = NSWindowController(window: window)
        }

        NSApp.activate(ignoringOtherApps: true)
        libraryWindowController?.showWindow(nil)
        libraryWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    func openSettings() {
        if settingsWindowController == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 360),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "ThoughtNotch Settings"
            window.center()
            window.contentView = NSHostingView(rootView: SettingsView())
            window.isReleasedWhenClosed = false

            settingsWindowController = NSWindowController(window: window)
        }

        NSApp.activate(ignoringOtherApps: true)
        guard let window = settingsWindowController?.window else {
            return
        }

        if !window.isVisible {
            settingsWindowController?.showWindow(nil)
        }

        window.deminiaturize(nil)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
    }
}
