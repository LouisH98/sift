import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    @StateObject private var settings = AISettings.shared
    @StateObject private var processor = ThoughtProcessor.shared
    @ObservedObject private var store = ThoughtStore.shared
    @State private var availableModels: [String] = []
    @State private var isLoadingModels = false
    @State private var modelLoadError: String?

    var body: some View {
        Form {
            Section("Capture") {
                KeyboardShortcuts.Recorder("Toggle notch:", name: .toggleNotch)
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
            await loadModelsIfNeeded()
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
}
