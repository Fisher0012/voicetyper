import SwiftUI
import AppKit
import CoreAudio
import ServiceManagement

extension Notification.Name {
    static let showSettingsSection = Notification.Name("showSettingsSection")
}

final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show(appState: AppState, section: SettingsSection? = nil) {
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            if let section {
                NotificationCenter.default.post(name: .showSettingsSection, object: section)
            }
            return
        }

        let view = SettingsView(appState: appState, initialSection: section ?? .general)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 720),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Ghost Pepper Settings"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 900, height: 680)
        window.contentViewController = NSHostingController(rootView: view)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

@MainActor
final class SettingsDictationTestController: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isTranscribing = false
    @Published private(set) var transcript: String?
    @Published private(set) var lastError: String?

    private var recorder: AudioRecorder?
    private let transcriber: SpeechTranscriber

    init(transcriber: SpeechTranscriber) {
        self.transcriber = transcriber
    }

    func start() {
        guard !isRecording else { return }
        let recorder = AudioRecorder()
        recorder.targetDeviceID = AudioDeviceManager.selectedInputDeviceID()
        recorder.prewarm()

        do {
            try recorder.startRecording()
            self.recorder = recorder
            transcript = nil
            lastError = nil
            isRecording = true
        } catch {
            lastError = "Could not start recording."
        }
    }

    func stop() {
        guard isRecording, let recorder else { return }
        isRecording = false
        isTranscribing = true
        self.recorder = nil

        Task { @MainActor in
            let buffer = await recorder.stopRecording()
            let text = await transcriber.transcribe(audioBuffer: buffer)
            self.transcript = text
            self.lastError = text == nil ? "Ghost Pepper could not transcribe that sample." : nil
            self.isTranscribing = false
        }
    }
}

// MARK: - Settings View

enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case cleanup
    case models

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .cleanup: "Cleanup"
        case .models: "Models"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "Startup behavior, shortcuts, microphone input, dictation testing, and sound feedback."
        case .cleanup: "Prompt cleanup, correction hints, and learning behavior."
        case .models: "Speech and cleanup model downloads and runtime status."
        }
    }

    var systemImageName: String {
        switch self {
        case .general: "gearshape"
        case .cleanup: "sparkles"
        case .models: "brain"
        }
    }
}

struct RecordingSpeakerFilteringToggleState {
    let isVisible: Bool
    let isEnabled: Bool

    init(speechModel: SpeechModelDescriptor?) {
        isVisible = true
        isEnabled = speechModel?.supportsSpeakerFiltering ?? false
    }
}

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @State private var inputDevices: [AudioInputDevice] = []
    @State private var selectedDeviceID: AudioDeviceID = 0
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var hasScreenRecordingPermission = PermissionChecker.hasScreenRecordingPermission()
    @State private var hasAccessibilityPermission = PermissionChecker.checkAccessibility()
    @State private var hasInputMonitoringPermission = PermissionChecker.checkInputMonitoring()
    @State private var permissionPollTimer: Timer?
    @State private var selectedSection: SettingsSection
    @StateObject private var dictationTestController: SettingsDictationTestController

    init(appState: AppState, initialSection: SettingsSection = .general) {
        self.appState = appState
        _selectedSection = State(initialValue: initialSection)
        _dictationTestController = StateObject(
            wrappedValue: SettingsDictationTestController(transcriber: appState.transcriber)
        )
    }

    private var modelRows: [RuntimeModelRow] {
        RuntimeModelInventory.rows(
            selectedSpeechModelName: appState.speechModel,
            activeSpeechModelName: appState.modelManager.modelName,
            speechModelState: appState.modelManager.state,
            speechDownloadProgress: appState.modelManager.downloadProgress,
            cachedSpeechModelNames: appState.modelManager.cachedModelNames,
            cleanupState: appState.textCleanupManager.state,
            selectedCleanupModelKind: appState.textCleanupManager.selectedCleanupModelKind,
            cachedCleanupKinds: appState.textCleanupManager.cachedModelKinds
        )
    }


    private var speakerFilteringToggleState: RecordingSpeakerFilteringToggleState {
        RecordingSpeakerFilteringToggleState(
            speechModel: SpeechModelCatalog.model(named: appState.speechModel)
        )
    }


    var body: some View {
        HSplitView {
            ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(SettingsSection.allCases) { section in
                    Button {
                        selectedSection = section
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: section.systemImageName)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(section.title)
                                    .font(.body.weight(.medium))
                                Text(section.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // Make the full row (icon + text + surrounding padding + trailing
                        // whitespace) hit-testable. Without this, SwiftUI hit-tests a plain
                        // Button against the opaque pixels of its label — so clicks landed only
                        // on the visible text/icon, not the empty space in the row. (Fixes #74.)
                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(selectedSection == section ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.22) : .clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(
                                    selectedSection == section
                                        ? Color(nsColor: .separatorColor)
                                        : Color.clear,
                                    lineWidth: 1
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 0)
            }
            }
            .frame(minWidth: 250, idealWidth: 270, maxWidth: 270, maxHeight: .infinity, alignment: .topLeading)
            .padding(20)
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 1)
            }

            ScrollView {
                detailContent
                    .padding(.horizontal, 40)
                    .padding(.vertical, 32)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 900, minHeight: 680)
        .onAppear {
            inputDevices = AudioDeviceManager.listInputDevices()
            selectedDeviceID = AudioDeviceManager.selectedInputDeviceID() ?? AudioDeviceManager.defaultInputDeviceID() ?? 0
            refreshScreenRecordingPermission()
            refreshRequiredPermissions()
            startPermissionPollingIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshScreenRecordingPermission()
            refreshRequiredPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: .showSettingsSection)) { note in
            if let section = note.object as? SettingsSection {
                selectedSection = section
            }
        }
        .onDisappear {
            if dictationTestController.isRecording {
                dictationTestController.stop()
            }
            permissionPollTimer?.invalidate()
            permissionPollTimer = nil
        }
    }

    private func refreshScreenRecordingPermission() {
        hasScreenRecordingPermission = PermissionChecker.hasScreenRecordingPermission()
    }

    private func downloadModel(_ row: RuntimeModelRow) {
        if row.id.hasPrefix("cleanup-") {
            if let kind = TextCleanupManager.cleanupModels.first(where: { "cleanup-\($0.fileName)" == row.id })?.kind {
                Task { await appState.textCleanupManager.loadModel(kind: kind) }
            }
        } else {
            // Select and load the requested model (triggers download if not cached)
            appState.speechModel = row.id
            Task { await appState.loadSpeechModel(name: row.id) }
        }
    }

    private func offloadModel(_ row: RuntimeModelRow) {
        if row.id.hasPrefix("cleanup-") {
            // Cleanup model
            if let kind = TextCleanupManager.cleanupModels.first(where: { "cleanup-\($0.fileName)" == row.id })?.kind {
                appState.textCleanupManager.deleteCachedModel(kind: kind)
            }
        } else {
            // Speech model
            if let model = SpeechModelCatalog.model(named: row.id) {
                appState.modelManager.deleteCachedModel(model)
            }
        }
    }

    private func refreshRequiredPermissions() {
        hasAccessibilityPermission = PermissionChecker.checkAccessibility()
        hasInputMonitoringPermission = PermissionChecker.checkInputMonitoring()
        if hasAccessibilityPermission && hasInputMonitoringPermission {
            permissionPollTimer?.invalidate()
            permissionPollTimer = nil
        }
    }

    private func startPermissionPollingIfNeeded() {
        guard !hasAccessibilityPermission || !hasInputMonitoringPermission else { return }
        guard permissionPollTimer == nil else { return }
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            refreshRequiredPermissions()
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 8) {
                Text(selectedSection.title)
                    .font(.system(size: 28, weight: .semibold))
                Text(selectedSection.subtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            switch selectedSection {
            case .general:
                generalSection
            case .cleanup:
                cleanupSection
            case .models:
                modelsSection
            }

            Spacer(minLength: 0)
        }
    }

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            if !hasAccessibilityPermission || !hasInputMonitoringPermission {
                SettingsCard("Permissions") {
                    VStack(alignment: .leading, spacing: 12) {
                        PermissionStatusRow(
                            title: "Accessibility",
                            isGranted: hasAccessibilityPermission,
                            action: { PermissionChecker.promptAccessibility() }
                        )
                        PermissionStatusRow(
                            title: "Input Monitoring",
                            isGranted: hasInputMonitoringPermission,
                            action: {
                                PermissionChecker.promptInputMonitoring()
                                PermissionChecker.openInputMonitoringSettings()
                            }
                        )

                        Text("Both permissions are required for hotkeys and pasting to work reliably. If Ghost Pepper doesn't appear in Input Monitoring, click + and select it from Applications.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            SettingsCard("Shortcuts") {
                VStack(alignment: .leading, spacing: 16) {
                    ShortcutRecorderView(
                        title: "Hold to Record",
                        chord: appState.pushToTalkChord,
                        onRecordingStateChange: appState.setShortcutCaptureActive
                    ) { chord in
                        appState.updateShortcut(chord, for: .pushToTalk)
                    }

                    ShortcutRecorderView(
                        title: "Toggle Recording",
                        chord: appState.toggleToTalkChord,
                        onRecordingStateChange: appState.setShortcutCaptureActive
                    ) { chord in
                        appState.updateShortcut(chord, for: .toggleToTalk)
                    }

                    if let shortcutErrorMessage = appState.shortcutErrorMessage {
                        Text(shortcutErrorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    Text("Push to talk records while the hold chord stays down. Toggle recording starts and stops when you press the full toggle chord.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            SettingsCard("Input") {
                VStack(alignment: .leading, spacing: 18) {
                    SettingsField("Microphone") {
                        Picker("Microphone", selection: $selectedDeviceID) {
                            ForEach(inputDevices) { device in
                                Text(device.name).tag(device.id)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 320, alignment: .leading)
                        .onChange(of: selectedDeviceID) { _, newValue in
                            AudioDeviceManager.setSelectedInputDevice(newValue)
                            appState.resetAudioEngine()
                        }
                    }

                    Toggle(
                        "Play sounds",
                        isOn: Binding(
                            get: { appState.playSounds },
                            set: { appState.playSounds = $0 }
                        )
                    )

                    Toggle(
                        "Pause media while recording",
                        isOn: $appState.pauseMediaWhileRecording
                    )

                    if speakerFilteringToggleState.isVisible {
                        Toggle(
                            "Ignore other speakers",
                            isOn: Binding(
                                get: { appState.ignoreOtherSpeakers },
                                set: { appState.ignoreOtherSpeakers = $0 }
                            )
                        )
                        .disabled(!speakerFilteringToggleState.isEnabled)
                    }
                }
            }

            SettingsCard("Test dictation") {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Record a short sample with your current microphone and speech model without leaving Settings.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 12) {
                        Button(dictationTestController.isRecording ? "Stop test dictation" : "Start test dictation") {
                            if dictationTestController.isRecording {
                                dictationTestController.stop()
                            } else {
                                dictationTestController.start()
                            }
                        }
                        .buttonStyle(.borderedProminent)

                        if dictationTestController.isRecording {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(.red)
                                    .frame(width: 10, height: 10)
                                Text("Recording…")
                                    .foregroundStyle(.secondary)
                            }
                        } else if dictationTestController.isTranscribing {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Transcribing…")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if let transcript = dictationTestController.transcript {
                        Text(transcript)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                            )
                    } else if let lastError = dictationTestController.lastError {
                        Text(lastError)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
            }

            SettingsCard("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchAtLogin = !enabled
                        }
                    }
            }
        }
    }

    private var cleanupSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsCard("Cleanup") {
                VStack(alignment: .leading, spacing: 16) {
                    Toggle(
                        "Enable cleanup",
                        isOn: Binding(
                            get: { appState.cleanupEnabled },
                            set: { appState.setCleanupEnabled($0) }
                        )
                    )

                    if appState.cleanupEnabled {
                        if appState.textCleanupManager.state == .error {
                            Text(appState.textCleanupManager.errorMessage ?? "Error loading model")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }

                    // Cleanup Backend 选择
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Cleanup backend")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)

                        Picker("", selection: $appState.cleanupBackendOption) {
                            ForEach(CleanupBackendOption.allCases) { option in
                                Text(option.title).tag(option.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    if appState.cleanupBackendOption == CleanupBackendOption.claude.rawValue {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Claude cleanup model")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)

                            Picker("", selection: $appState.claudeCleanupModel) {
                                ForEach(ClaudeAPIModel.allCases) { model in
                                    Text(model.shortDisplayName).tag(model.rawValue)
                                }
                            }
                            .labelsHidden()

                            Text("Claude API key")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)

                            HStack(spacing: 8) {
                                SecureField("sk-ant-...", text: $claudeAPIKeyInput)
                                    .textFieldStyle(.roundedBorder)
                                    .onChange(of: claudeAPIKeyInput) { _, _ in
                                        claudeAPIKeySaved = false
                                    }
                                Button(claudeAPIKeySaved ? "Saved" : "Save") {
                                    _ = KeychainHelper.set(claudeAPIKeyInput, for: AnthropicProvider.keychainKey)
                                    claudeAPIKeySaved = true
                                }
                                .disabled(claudeAPIKeyInput.isEmpty)
                                Button("Clear") {
                                    KeychainHelper.delete(AnthropicProvider.keychainKey)
                                    claudeAPIKeyInput = ""
                                    claudeAPIKeySaved = false
                                }
                                .disabled(claudeAPIKeyInput.isEmpty && !claudeAPIKeySaved)
                            }

                            if !claudeAPIKeySaved {
                                Text("Claude API key not configured. Add it above to enable cloud cleanup.")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }

                        Text("Uses Claude API for higher quality cleanup. Requires a Claude API key (stored in your macOS Keychain) and internet connection. Falls back to local models if unavailable. Get a key at [console.anthropic.com](https://console.anthropic.com/settings/keys).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if appState.cleanupBackendOption == CleanupBackendOption.openaiCompatible.rawValue {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("OpenAI-Compatible Endpoint")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Text("Base URL")
                                .font(.caption)
                            TextField("https://api.minimaxi.com/v1", text: $appState.openaiCompatibleBaseURL)
                                .textFieldStyle(.roundedBorder)

                            Text("Model")
                                .font(.caption)
                            TextField("MiniMax-M2.7", text: $appState.openaiCompatibleModel)
                                .textFieldStyle(.roundedBorder)

                            Text("API Key")
                                .font(.caption)
                            HStack {
                                SecureField("sk-...", text: $openaiAPIKeyInput)
                                    .textFieldStyle(.roundedBorder)
                                    .onChange(of: openaiAPIKeyInput) { _, _ in
                                        openaiAPIKeySaved = false
                                    }
                                Button(openaiAPIKeySaved ? "Saved" : "Save") {
                                    _ = KeychainHelper.set(openaiAPIKeyInput, for: OpenAICompatibleCleanupBackend.keychainKey)
                                    openaiAPIKeySaved = true
                                }
                                .disabled(openaiAPIKeyInput.isEmpty)
                                Button("Clear") {
                                    KeychainHelper.delete(OpenAICompatibleCleanupBackend.keychainKey)
                                    openaiAPIKeyInput = ""
                                    openaiAPIKeySaved = false
                                }
                                .disabled(openaiAPIKeyInput.isEmpty && !openaiAPIKeySaved)
                            }

                            if !openaiAPIKeySaved {
                                Text("API key not configured. Add it above to enable cloud cleanup.")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }

                        Text("任何 OpenAI Chat Completions 兼容 endpoint。**推荐 MiniMax**(便宜约 1/20 Claude,中文能力强):base URL `https://api.minimaxi.com/v1`,model 填 `MiniMax-M2.7` 或 `MiniMax-M2.5`,在 [platform.minimax.io](https://platform.minimax.io/) 获取 API key。也可用 OpenAI / DeepSeek / OpenRouter / Together AI / 自建 endpoint。失败时自动 fallback 本地模型。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("When enabled, Ghost Pepper runs local cleanup with the selected cleanup model from the Models section.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            SettingsCard("Cleanup prompt") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Ghost Pepper uses this prompt before adding OCR context and correction hints.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    BorderedTextEditor(
                        text: $appState.cleanupPrompt,
                        minimumHeight: 140,
                        maximumHeight: 260,
                        monospaced: false
                    )

                    HStack {
                        Spacer()

                        Button("Reset to Default") {
                            appState.cleanupPrompt = TextCleaner.defaultPrompt
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            SettingsCard("Correction hints") {
                VStack(alignment: .leading, spacing: 20) {
                    CorrectionsEditor(
                        title: "Preferred transcriptions",
                        text: Binding(
                            get: { appState.correctionStore.preferredTranscriptionsText },
                            set: { appState.correctionStore.preferredTranscriptionsText = $0 }
                        ),
                        prompt: "One preferred word or phrase per line"
                    )

                    Divider()

                    CorrectionsEditor(
                        title: "Commonly misheard",
                        text: Binding(
                            get: { appState.correctionStore.commonlyMisheardText },
                            set: { appState.correctionStore.commonlyMisheardText = $0 }
                        ),
                        prompt: "One likely phrase pair per line using probably wrong -> probably right"
                    )

                    Text("Correction hints are added to the cleanup prompt; they are not applied as regexes or deterministic substitutions. Preferred transcriptions are also forwarded into OCR custom words.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            SettingsCard("Context") {
                VStack(alignment: .leading, spacing: 16) {
                    Toggle(
                        "Learn from manual corrections after paste",
                        isOn: Binding(
                            get: { appState.postPasteLearningEnabled },
                            set: { appState.postPasteLearningEnabled = $0 }
                        )
                    )

                    if appState.postPasteLearningEnabled && !hasScreenRecordingPermission {
                        ScreenRecordingRecoveryView {
                            _ = PermissionChecker.requestScreenRecordingPermission()
                            PermissionChecker.openScreenRecordingSettings()
                            refreshScreenRecordingPermission()
                        }
                    }

                    Text("When learning is enabled, Ghost Pepper does a high-quality OCR check about 15 seconds after paste and only keeps narrow, high-confidence corrections.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsCard("Speech model") {
                SettingsField("Active speech model") {
                    Picker("Speech Model", selection: $appState.speechModel) {
                        ForEach(ModelManager.availableModels) { model in
                            Text(model.pickerLabel).tag(model.name)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 320, alignment: .leading)
                    .onChange(of: appState.speechModel) { _, newModel in
                        Task {
                            await appState.loadSpeechModel(name: newModel)
                        }
                    }
                }

                Text("Ghost Pepper uses this model for speech recognition everywhere in the app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                SettingsField("Language") {
                    Picker("Language", selection: $appState.preferredLanguage) {
                        Text("Auto-detect").tag("auto")
                        Text("English").tag("en")
                        Text("Spanish").tag("es")
                        Text("French").tag("fr")
                        Text("German").tag("de")
                        Text("Portuguese").tag("pt")
                        Text("Italian").tag("it")
                        Text("Dutch").tag("nl")
                        Text("Chinese").tag("zh")
                        Text("Japanese").tag("ja")
                        Text("Korean").tag("ko")
                        Text("Russian").tag("ru")
                        Text("Arabic").tag("ar")
                        Text("Hindi").tag("hi")
                    }
                    .labelsHidden()
                    .frame(maxWidth: 320, alignment: .leading)
                }

                if appState.preferredLanguage != "auto" && appState.preferredLanguage != "en" && appState.speechModel.hasSuffix(".en") {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                        Text("You've selected a non-English language but are using an English-only model. Switch to **Multilingual** or **Parakeet v3** above for best results.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            SettingsCard("Cleanup model") {
                SettingsField("Active cleanup model") {
                    Picker(
                        "Cleanup model",
                        selection: Binding(
                            get: { appState.textCleanupManager.selectedCleanupModelKind },
                            set: { appState.textCleanupManager.selectedCleanupModelKind = $0 }
                        )
                    ) {
                        ForEach(TextCleanupManager.cleanupModels, id: \.kind) { model in
                            Text(model.displayName).tag(model.kind)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 360, alignment: .leading)
                    .onChange(of: appState.textCleanupManager.selectedCleanupModelKind) { _, _ in
                        Task {
                            await appState.textCleanupManager.loadModel()
                        }
                    }
                }

                Text("Recommended cleanup models are marked Very fast, Fast, and Full.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsCard("Runtime models") {
                VStack(alignment: .leading, spacing: 16) {
                    ModelInventoryCard(rows: modelRows, onDelete: offloadModel, onDownload: downloadModel)

                    if let activeDownloadText = RuntimeModelInventory.activeDownloadText(rows: modelRows) {
                        Text(activeDownloadText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }


    @State private var claudeAPIKeyInput: String = KeychainHelper.get(AnthropicProvider.keychainKey) ?? ""
    @State private var claudeAPIKeySaved: Bool = (KeychainHelper.get(AnthropicProvider.keychainKey) ?? "").isEmpty == false
    @State private var openaiAPIKeyInput: String = KeychainHelper.get(OpenAICompatibleCleanupBackend.keychainKey) ?? ""
    @State private var openaiAPIKeySaved: Bool = (KeychainHelper.get(OpenAICompatibleCleanupBackend.keychainKey) ?? "").isEmpty == false

}


private struct ScreenRecordingRecoveryView: View {
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ghost Pepper needs Screen Recording access. Grant it in System Settings, then return to Ghost Pepper.")
                .font(.caption)
                .foregroundStyle(.red)

            Button("Open Screen Recording Settings", action: onOpenSettings)
            .controlSize(.small)
        }
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title3.weight(.semibold))

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsField<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.medium))
            content
        }
    }
}

private struct PermissionStatusRow: View {
    let title: String
    let isGranted: Bool
    let action: () -> Void

    var body: some View {
        HStack {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(isGranted ? .green : .red)
            Text(title)
                .font(.callout)
            Spacer()
            if !isGranted {
                Button("Grant") { action() }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .controlSize(.small)
            }
        }
    }
}

private struct CorrectionsEditor: View {
    let title: String
    let text: Binding<String>
    let prompt: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.medium))

            BorderedTextEditor(text: text, minimumHeight: 96, maximumHeight: 160, monospaced: false)

            Text(prompt)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct BorderedTextEditor: View {
    let text: Binding<String>
    let minimumHeight: CGFloat
    let maximumHeight: CGFloat
    let monospaced: Bool

    var body: some View {
        TextEditor(text: text)
            .font(monospaced ? .system(.body, design: .monospaced) : .body)
            .scrollContentBackground(.hidden)
            .frame(height: textPaneHeight(for: text.wrappedValue, minimumHeight: minimumHeight, maximumHeight: maximumHeight))
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )
    }
}

private func textPaneHeight(
    for text: String,
    minimumHeight: CGFloat,
    maximumHeight: CGFloat
) -> CGFloat {
    let lineCount = max(text.components(separatedBy: "\n").count, 1)
    let estimatedHeight = CGFloat(lineCount) * 20 + 28
    return min(max(estimatedHeight, minimumHeight), maximumHeight)
}

