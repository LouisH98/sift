import AppKit
import SwiftUI

@main
struct ThoughtNotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            Button("Capture Thought") {
                appDelegate.toggleNotch()
            }

            Button("Library") {
                appDelegate.openLibrary()
            }

            Button("Settings...") {
                appDelegate.openSettings()
            }

            Divider()

            Button("Quit ThoughtNotch") {
                NSApp.terminate(nil)
            }
        } label: {
            Image(systemName: "sparkles")
                .symbolRenderingMode(.monochrome)
                .accessibilityLabel("ThoughtNotch")
        }
    }
}
