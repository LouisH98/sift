import KeyboardShortcuts
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @StateObject private var settings = AISettings.shared
    @StateObject private var todoSettings = TodoSettings.shared
    @StateObject private var appearanceSettings = NotchAppearanceSettings.shared
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

            Section("Notch") {
                Toggle("Glow on hover", isOn: $appearanceSettings.isGlowEnabled)

                ColorPicker("Glow color", selection: glowColorBinding, supportsOpacity: false)
                    .disabled(!appearanceSettings.isGlowEnabled)

                HStack {
                    Text(appearanceSettings.glowColorHex)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button("Reset") {
                        appearanceSettings.resetGlowColor()
                    }
                    .buttonStyle(.borderless)
                    .disabled(!appearanceSettings.isGlowEnabled)
                }
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

            Section("Actions") {
                Toggle("Reminder notifications", isOn: $todoSettings.remindersEnabled)

                Stepper(
                    reminderStepperLabel,
                    value: $todoSettings.reminderLeadTimeMinutes,
                    in: 0...10_080,
                    step: 15
                )
                .disabled(!todoSettings.remindersEnabled)

                Text("Due actions are sorted before unscheduled actions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("AI Processing") {
                Toggle("Enable AI processing", isOn: $settings.isEnabled)

                TextField("API base URL", text: $settings.apiBaseURL)
                    .textFieldStyle(.roundedBorder)

                Picker("API type", selection: $settings.apiEndpoint) {
                    ForEach(AISettings.APIEndpoint.allCases) { endpoint in
                        Text(endpoint.displayName).tag(endpoint)
                    }
                }
                .pickerStyle(.menu)

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
        .onChange(of: todoSettings.remindersEnabled) { _, _ in
            syncActionReminders()
        }
        .onChange(of: todoSettings.reminderLeadTimeMinutes) { _, _ in
            syncActionReminders()
        }
    }

    private var reminderStepperLabel: String {
        if todoSettings.reminderLeadTimeMinutes == 0 {
            return "Remind at the due time"
        }

        return "Remind \(reminderLeadTimeLabel) before due"
    }

    private var reminderLeadTimeLabel: String {
        let minutes = todoSettings.reminderLeadTimeMinutes
        if minutes < 60 {
            return "\(minutes) minutes"
        }

        if minutes.isMultiple(of: 1_440) {
            let days = minutes / 1_440
            return days == 1 ? "1 day" : "\(days) days"
        }

        if minutes.isMultiple(of: 60) {
            let hours = minutes / 60
            return hours == 1 ? "1 hour" : "\(hours) hours"
        }

        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return "\(hours)h \(remainingMinutes)m"
    }

    private var glowColorBinding: Binding<Color> {
        Binding(
            get: { appearanceSettings.glowColor },
            set: { appearanceSettings.setGlowColor($0) }
        )
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

    private func syncActionReminders() {
        ActionReminderScheduler.shared.syncAll(
            actionItems: store.openActionItems,
            settings: todoSettings
        )
    }
}
