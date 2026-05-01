import AppKit
import KeyboardShortcuts
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @StateObject private var settings = AISettings.shared
    @StateObject private var todoSettings = TodoSettings.shared
    @StateObject private var appearanceSettings = NotchAppearanceSettings.shared
    @StateObject private var processor = ThoughtProcessor.shared
    @StateObject private var embeddingIndex = ThoughtEmbeddingIndex.shared
    @ObservedObject private var store = ThoughtStore.shared
    @State private var availableModels: [String] = []
    @State private var isLoadingModels = false
    @State private var modelLoadError: String?
    @State private var foundationModelsTestOutput: String?
    @State private var foundationModelsTestError: String?
    @State private var isTestingFoundationModels = false
    @State private var launchAtLoginStatus = SMAppService.mainApp.status
    @State private var launchAtLoginError: String?
    @State private var isExportingData = false
    @State private var dataExportMessage: String?
    @State private var dataExportError: String?

    var body: some View {
        Form {
            Section("Capture") {
                KeyboardShortcuts.Recorder("Toggle notch:", name: .toggleNotch)
            }

            Section("Notch") {
                Toggle("Notch effects", isOn: $appearanceSettings.isGlowEnabled)

                ColorPicker("Effect color", selection: glowColorBinding, supportsOpacity: false)
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

            #if DEBUG
            Section("Debug") {
                Toggle(
                    "Simulate notchless display notch",
                    isOn: $appearanceSettings.debugSimulateNotchlessOnNotchedDisplays
                )

                Text("On notched displays, renders the notchless display effect left of the hardware notch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            #endif

            Section("Startup") {
                Toggle("Open Sift at login", isOn: Binding(
                    get: { launchAtLoginStatus == .enabled },
                    set: setLaunchAtLogin
                ))

                if launchAtLoginStatus == .requiresApproval {
                    Text("Approve Sift in System Settings > General > Login Items.")
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

            Section("Data") {
                HStack {
                    Button(isExportingData ? "Exporting..." : "Export data...") {
                        exportDataWithPicker()
                    }
                    .disabled(isExportingData)

                    Spacer()
                }

                if let dataExportMessage {
                    Text(dataExportMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else if let dataExportError {
                    Text(dataExportError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("AI Processing") {
                Toggle("Enable AI processing", isOn: $settings.isEnabled)

                Picker("Provider", selection: $settings.providerKind) {
                    ForEach(ThoughtAIProviderKind.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.menu)

                switch settings.providerKind {
                case .openAICompatible:
                    openAICompatibleSettings
                case .appleFoundationModels:
                    appleFoundationModelsSettings
                }

                Toggle("Allow chat web search", isOn: $settings.isChatWebSearchEnabled)

                Text("When off, chat uses only your local Sift notebook tools.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

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

            Section("Semantic Search") {
                semanticSearchSettings
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 460)
        .task {
            settings.loadAPIKeyIfNeeded()
            await settings.loadEnvironmentAPIKeyFromShellIfNeeded()
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
        .onChange(of: settings.providerKind) { _, newValue in
            availableModels = []
            modelLoadError = nil
            foundationModelsTestOutput = nil
            foundationModelsTestError = nil
            if newValue == .openAICompatible {
                Task {
                    await loadModelsIfNeeded()
                }
            }
        }
        .onChange(of: settings.apiKeySource) { _, _ in
            Task {
                await settings.loadEnvironmentAPIKeyFromShellIfNeeded(force: true)
            }
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
    private var semanticSearchSettings: some View {
        let status = embeddingIndex.status(store: store)

        VStack(alignment: .leading, spacing: 8) {
            Label(
                status.isAvailable ? "Apple sentence embeddings available" : "Apple sentence embeddings unavailable",
                systemImage: status.isAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
            .foregroundStyle(status.isAvailable ? .green : .orange)

            Text("Semantic search compares each query against a local persisted index of thoughts, pages, and todos.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Text("\(status.recordCount) of \(status.expectedRecordCount) indexed")
                    .foregroundStyle(.secondary)

                Spacer()

                if status.missingRecordCount > 0, !status.isRebuilding {
                    Text("\(status.missingRecordCount) missing")
                        .foregroundStyle(.orange)
                }
            }

            if status.isRebuilding {
                ProgressView(
                    value: Double(status.rebuiltCount),
                    total: Double(max(status.rebuildTotal, 1))
                )

                Text("Rebuilding \(status.rebuiltCount) of \(status.rebuildTotal)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button(status.isRebuilding ? "Rebuilding..." : "Rebuild semantic index") {
                    Task {
                        await embeddingIndex.rebuildAll(store: store)
                    }
                }
                .disabled(!status.isAvailable || status.isRebuilding)

                Spacer()

                if let lastRebuiltAt = status.lastRebuiltAt {
                    Text("Last rebuilt \(DateFormatter.semanticIndexStatus.string(from: lastRebuiltAt))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let lastError = status.lastError {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func exportDataWithPicker() {
        dataExportMessage = nil
        dataExportError = nil

        let panel = NSOpenPanel()
        panel.title = "Choose Export Folder"
        panel.message = "Choose where Sift should create the export folder."
        panel.prompt = "Export"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let destinationDirectory = panel.url else {
            return
        }

        isExportingData = true
        defer {
            isExportingData = false
        }

        let didStartAccess = destinationDirectory.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                destinationDirectory.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let bundle = SiftDataExportBundle(
                schemaVersion: 1,
                exportedAt: Date(),
                thoughts: store.thoughts,
                themes: store.themes,
                pages: store.pages,
                dailyDigests: store.dailyDigests,
                actionItems: store.actionItems
            )
            let result = try DataExportService.shared.export(bundle: bundle, to: destinationDirectory)
            dataExportMessage = "Exported to \(result.folderURL.path)"
            NSWorkspace.shared.activateFileViewerSelecting([result.folderURL])
        } catch {
            dataExportError = "Export failed: \(error.localizedDescription)"
        }
    }

    @ViewBuilder
    private var openAICompatibleSettings: some View {
        TextField("API base URL", text: $settings.apiBaseURL)
            .textFieldStyle(.roundedBorder)

        Picker("API type", selection: $settings.apiEndpoint) {
            ForEach(AISettings.APIEndpoint.allCases) { endpoint in
                Text(endpoint.displayName).tag(endpoint)
            }
        }
        .pickerStyle(.menu)

        Picker("API key source", selection: $settings.apiKeySource) {
            ForEach(AISettings.APIKeySource.allCases) { source in
                Text(source.displayName).tag(source)
            }
        }
        .pickerStyle(.segmented)

        switch settings.apiKeySource {
        case .manual:
            SecureField("API key", text: $settings.apiKey)
                .textFieldStyle(.roundedBorder)
        case .environmentVariable:
            VStack(alignment: .leading, spacing: 6) {
                Text("Environment variable")

                TextField("Environment variable", text: $settings.apiKeyEnvironmentVariableName)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
            }

            Text("Env mode reads the app environment first. At startup, Sift also asks your login shell for this variable and keeps the value in memory.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if settings.isLoadingShellEnvironmentAPIKey {
            Text("Loading API key from shell...")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let shellEnvironmentAPIKeyMessage = settings.shellEnvironmentAPIKeyMessage {
            Text(shellEnvironmentAPIKeyMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let shellEnvironmentAPIKeyError = settings.shellEnvironmentAPIKeyError {
            Text(shellEnvironmentAPIKeyError)
                .font(.caption)
                .foregroundStyle(.red)
        }

        modelSelector
    }

    @ViewBuilder
    private var appleFoundationModelsSettings: some View {
        let status = ThoughtAIProviderFactory.status(for: .appleFoundationModels)

        VStack(alignment: .leading, spacing: 8) {
            Label(status.title, systemImage: status.isAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(status.isAvailable ? .green : .orange)

            Text(status.message)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Uses SystemLanguageModel.default. Apple updates model behavior through OS releases; custom model selection is not available.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Prewarm") {
                    ThoughtAIProviderFactory.provider(settings: settings, store: store).prewarm()
                    foundationModelsTestOutput = "Prewarm requested."
                    foundationModelsTestError = nil
                }
                .disabled(!status.isAvailable)

                Button(isTestingFoundationModels ? "Testing..." : "Test local generation") {
                    Task {
                        await testFoundationModels()
                    }
                }
                .disabled(!status.isAvailable || isTestingFoundationModels)
            }

            if let foundationModelsTestOutput {
                Text(foundationModelsTestOutput)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else if let foundationModelsTestError {
                Text(foundationModelsTestError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
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
        guard settings.providerKind == .openAICompatible else {
            return
        }

        guard availableModels.isEmpty else {
            return
        }

        await loadModels(force: false)
    }

    private func loadModels(force: Bool) async {
        guard settings.providerKind == .openAICompatible else {
            return
        }

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

    private func testFoundationModels() async {
        isTestingFoundationModels = true
        foundationModelsTestOutput = nil
        foundationModelsTestError = nil

        do {
            let output = try await ThoughtAIProviderFactory.provider(settings: settings, store: store).generateRawText(
                instructions: "You write brief app status labels.",
                prompt: "Return exactly this word: Ready"
            )
            foundationModelsTestOutput = output
        } catch {
            foundationModelsTestError = error.localizedDescription
        }

        isTestingFoundationModels = false
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

private extension DateFormatter {
    static let semanticIndexStatus: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}
