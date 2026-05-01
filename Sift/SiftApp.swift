import AppKit
import SwiftUI

@main
struct SiftApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = ThoughtStore.shared
    @StateObject private var processor = ThoughtProcessor.shared

    init() {
        Task { @MainActor in
            AISettings.shared.loadAPIKeyIfNeeded()
            await AISettings.shared.loadEnvironmentAPIKeyFromShellIfNeeded()
        }
    }

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

            Button("Quit Sift") {
                NSApp.terminate(nil)
            }
        } label: {
            MenuBarStatusLabel(
                isProcessing: processor.isProcessing,
                hasError: processor.lastError != nil,
                todoCount: store.openActionItems.count
            )
        }
    }
}

private struct MenuBarStatusLabel: View {
    let isProcessing: Bool
    let hasError: Bool
    let todoCount: Int

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "sparkles")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(statusColor)

            if hasError {
                Text("!")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
            } else if isProcessing {
                Text("...")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
            }

            if todoCount > 0 {
                Image(systemName: "checklist")
                    .font(.system(size: 10, weight: .medium))

                Text(compactTodoCount)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .help(accessibilitySummary)
    }

    private var statusColor: Color {
        if hasError {
            return .red
        }

        if isProcessing {
            return .yellow
        }

        return .primary
    }

    private var compactTodoCount: String {
        todoCount > 99 ? "99+" : "\(todoCount)"
    }

    private var accessibilitySummary: String {
        let status: String
        if hasError {
            status = "OpenAI API connection error"
        } else if isProcessing {
            status = "Processing thoughts"
        } else {
            status = "Sift idle"
        }

        return "\(status). \(todoCount) todos."
    }
}
