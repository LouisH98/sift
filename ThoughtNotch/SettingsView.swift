import KeyboardShortcuts
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @StateObject private var settings = AISettings.shared
    @StateObject private var processor = ThoughtProcessor.shared
    @ObservedObject private var store = ThoughtStore.shared
    @State private var availableModels: [String] = []
    @State private var isLoadingModels = false
    @State private var modelLoadError: String?
    @State private var launchAtLoginStatus = SMAppService.mainApp.status
    @State private var launchAtLoginError: String?

    var body: some View {
        Form {
            Section("Capture") {
                KeyboardShortcuts.Recorder("Toggle notch:", name: .toggleNotch)
            }

            Section("Startup") {
                Toggle("Open ThoughtNotch at login", isOn: Binding(
                    get: { launchAtLoginStatus == .enabled },
                    set: setLaunchAtLogin
                ))

                if launchAtLoginStatus == .requiresApproval {
                    Text("Approve ThoughtNotch in System Settings > General > Login Items.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("AI Processing") {
                Toggle("Enable AI processing", isOn: $settings.isEnabled)

                TextField("API base URL", text: $settings.apiBaseURL)
                    .textFieldStyle(.roundedBorder)

                SecureField("API key", text: $settings.apiKey)
                    .textFieldStyle(.roundedBorder)

                modelSelector

                HStack {
                    Button(processor.isBackfilling ? "Processing..." : "Process unprocessed thoughts") {
                        processor.backfillUnprocessedThoughts()
                    }
                    .disabled(!settings.canProcess || store.unprocessedThoughtCount == 0 || processor.isBackfilling)

                    Spacer()

                    Text("\(store.unprocessedThoughtCount) waiting")
                        .foregroundStyle(.secondary)
                }

                if let lastError = processor.lastError {
                    Text(lastError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 460)
        .task {
            settings.loadAPIKeyIfNeeded()
            await loadModelsIfNeeded()
        }
        .onAppear {
            refreshLaunchAtLogin()
        }
    }

    @ViewBuilder
    private var modelSelector: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if availableModels.isEmpty {
                    TextField("Model", text: $settings.modelID)
                        .textFieldStyle(.roundedBorder)
                } else {
                    Picker("Model", selection: $settings.modelID) {
                        if !availableModels.contains(settings.modelID) {
                            Text(settings.modelID).tag(settings.modelID)
                        }

                        ForEach(availableModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Button {
                    Task {
                        await loadModels(force: true)
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(isLoadingModels)
                .help("Refresh available models")
            }

            if isLoadingModels {
                Text("Loading models...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let modelLoadError {
                Text(modelLoadError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func loadModelsIfNeeded() async {
        guard availableModels.isEmpty else {
            return
        }

        await loadModels(force: false)
    }

    private func loadModels(force: Bool) async {
        guard force || availableModels.isEmpty else {
            return
        }

        guard URL(string: settings.apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)) != nil else {
            modelLoadError = "Enter a valid API base URL to load models."
            return
        }

        guard !settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            modelLoadError = "Enter an API key to load models."
            return
        }

        isLoadingModels = true
        modelLoadError = nil

        do {
            let models = try await OpenAIClient(settings: settings).availableModels()
            availableModels = models

            if !models.isEmpty, !models.contains(settings.modelID) {
                settings.modelID = models.first { $0 == AISettings.defaultModelID } ?? models[0]
            }
        } catch {
            modelLoadError = "Could not load models. You can still type a model ID."
        }

        isLoadingModels = false
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }

            launchAtLoginError = nil
        } catch {
            launchAtLoginError = "Could not update login item. Try again after installing the app."
        }

        refreshLaunchAtLogin()
    }

    private func refreshLaunchAtLogin() {
        launchAtLoginStatus = SMAppService.mainApp.status
    }
}
