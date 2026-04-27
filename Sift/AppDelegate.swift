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
    private var windowCloseObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        PageNavigationShortcut.deactivateRegisteredShortcuts()
        ActionReminderScheduler.shared.syncAll(actionItems: store.openActionItems, settings: TodoSettings.shared)
        notchPanelController.installMouseActivationPanels()

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

        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let closingWindow = notification.object as? NSWindow else {
                return
            }

            Task { @MainActor [weak self] in
                guard self?.isManagedDockWindow(closingWindow) == true else {
                    return
                }

                self?.updateDockVisibility(excluding: closingWindow)
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
            window.title = "Sift"
            window.toolbarStyle = .unifiedCompact
            window.appearance = NSAppearance(named: .darkAqua)
            window.center()
            window.contentView = NSHostingView(rootView: LibraryWindow(store: store))
            window.isReleasedWhenClosed = false

            libraryWindowController = NSWindowController(window: window)
        }

        showDockIcon()
        NSApp.activate(ignoringOtherApps: true)
        libraryWindowController?.showWindow(nil)
        libraryWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    func openSettings() {
        if settingsWindowController == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 430),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Sift Settings"
            window.center()
            window.contentView = NSHostingView(rootView: SettingsView())
            window.isReleasedWhenClosed = false

            settingsWindowController = NSWindowController(window: window)
        }

        showDockIcon()
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

    private func showDockIcon() {
        NSApp.setActivationPolicy(.regular)
    }

    private func updateDockVisibility(excluding closingWindow: NSWindow) {
        if hasOpenManagedDockWindow(excluding: closingWindow) {
            showDockIcon()
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func hasOpenManagedDockWindow(excluding closingWindow: NSWindow) -> Bool {
        managedDockWindows.contains { window in
            window !== closingWindow && (window.isVisible || window.isMiniaturized)
        }
    }

    private func isManagedDockWindow(_ window: NSWindow) -> Bool {
        managedDockWindows.contains { $0 === window }
    }

    private var managedDockWindows: [NSWindow] {
        [libraryWindowController?.window, settingsWindowController?.window].compactMap { $0 }
    }
}
