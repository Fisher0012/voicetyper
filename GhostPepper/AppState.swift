import SwiftUI
import Combine
import CoreAudio
import ServiceManagement

enum AppStatus: String {
    case ready = "Ready"
    case loading = "Loading model..."
    case recording = "Recording..."
    case transcribing = "Transcribing..."
    case cleaningUp = "Cleaning up..."
    case error = "Error"
}

enum EmptyTranscriptionDisposition: Equatable {
    case cancel
    case showNoSoundDetected
}

@MainActor
class AppState: ObservableObject {
    enum PipelineOwner {
        case liveRecording
    }

    typealias CleanupResult = (
        text: String,
        prompt: String,
        attemptedCleanup: Bool,
        cleanupUsedFallback: Bool
    )
    typealias WindowContextProvider = @MainActor () async -> RecordingOCRPrefetchResult?

    private struct RecordingTranscriptionResult {
        let rawTranscription: String?
        let speakerFilteringRan: Bool
        let diarizationSummary: DiarizationSummary?
    }

    @Published var status: AppStatus = .loading
    @Published var isRecording: Bool = false
    @Published var errorMessage: String?
    @Published var shortcutErrorMessage: String?
    @Published var cleanupBackend: CleanupBackendOption {
        didSet {
            cleanupSettingsDefaults.set(cleanupBackend.rawValue, forKey: Self.cleanupBackendDefaultsKey)
        }
    }
    @Published var frontmostWindowContextEnabled: Bool {
        didSet {
            cleanupSettingsDefaults.set(
                frontmostWindowContextEnabled,
                forKey: Self.frontmostWindowContextEnabledDefaultsKey
            )
        }
    }
    @Published var playSounds: Bool {
        didSet {
            cleanupSettingsDefaults.set(
                playSounds,
                forKey: Self.playSoundsDefaultsKey
            )
        }
    }
    @AppStorage("cleanupEnabled") var cleanupEnabled: Bool = true
    @AppStorage("cleanupPrompt") var cleanupPrompt: String = TextCleaner.defaultPrompt
    @AppStorage("speechModel") var speechModel: String = SpeechModelCatalog.defaultModelID
    @AppStorage("preferredLanguage") var preferredLanguage: String = "auto"
    @AppStorage("pauseMediaWhileRecording") var pauseMediaWhileRecording: Bool = true
    @AppStorage("cleanupBackend") var cleanupBackendOption: String = CleanupBackendOption.localModels.rawValue {
        didSet {
            let option = CleanupBackendOption(rawValue: cleanupBackendOption) ?? .localModels
            textCleaner.selectedBackendOption = option
            textCleaner.useCloudBackend = false  // 弃用,由 selectedBackendOption 接管
        }
    }
    @AppStorage("claudeCleanupModel") var claudeCleanupModel: String = ClaudeAPIModel.haiku.rawValue
    /// OpenAI 兼容 endpoint 配置(用于 MiniMax / OpenAI / DeepSeek / OpenRouter / 自建)
    @AppStorage("openaiCompatibleBaseURL") var openaiCompatibleBaseURL: String = "https://api.minimaxi.com/v1"
    @AppStorage("openaiCompatibleModel") var openaiCompatibleModel: String = "MiniMax-M2.7"
    @Published private(set) var pushToTalkChord: KeyChord
    @Published private(set) var toggleToTalkChord: KeyChord
    @Published var postPasteLearningEnabled: Bool {
        didSet {
            cleanupSettingsDefaults.set(
                postPasteLearningEnabled,
                forKey: Self.postPasteLearningEnabledDefaultsKey
            )
            postPasteLearningCoordinator.learningEnabled = postPasteLearningEnabled
        }
    }
    @Published var ignoreOtherSpeakers: Bool {
        didSet {
            cleanupSettingsDefaults.set(
                ignoreOtherSpeakers,
                forKey: Self.ignoreOtherSpeakersDefaultsKey
            )
        }
    }

    let modelManager = ModelManager()
    let audioRecorder: AudioRecorder
    let transcriber: SpeechTranscriber
    let textPaster: TextPaster
    lazy var soundEffects = SoundEffects(isEnabled: { [weak self] in
        self?.playSounds ?? true
    })
    private lazy var mediaPlaybackController = MediaPlaybackController(enabled: { [weak self] in
        self?.pauseMediaWhileRecording ?? true
    })
    let hotkeyMonitor: HotkeyMonitoring
    let overlay = RecordingOverlayController()
    let textCleanupManager: TextCleanupManager
    let usageStats = UsageStatsStore()
    let frontmostWindowOCRService: FrontmostWindowOCRService
    let cleanupPromptBuilder: CleanupPromptBuilder
    let correctionStore: CorrectionStore
    let cloudCleanupBackend: CloudLLMCleanupBackend
    let openaiCompatibleCleanupBackend: OpenAICompatibleCleanupBackend
    let textCleaner: TextCleaner
    let chordBindingStore: ChordBindingStore
    let postPasteLearningCoordinator: PostPasteLearningCoordinator
    let debugLogStore: DebugLogStore
    let recognizedVoiceStore: RecognizedVoiceStore
    let transcriptionLabSpeakerProfileStore: TranscriptionLabSpeakerProfileStore
    let appRelauncher: AppRelaunching
    var recordingSessionCoordinatorFactory: (() -> RecordingSessionCoordinator?)?
    var recordingTranscriptionSessionFactory: ((SpeechModelDescriptor) -> RecordingTranscriptionSession?)?
    var transcribeAudioBufferOverride: (([Float]) -> String?)?
    var cleanedTranscriptionResultOverride: ((String, OCRContext?) async -> CleanupResult)?
    private(set) var activeRecordingSessionCoordinator: RecordingSessionCoordinator?
    private(set) var activeRecordingTranscriptionSession: RecordingTranscriptionSession?
    /// Task C: VAD 自动停止 — 用户连续静音超过阈值自动停录音
    private let vadMonitor = VADMonitor()

    var isReady: Bool {
        status == .ready
    }

    static func emptyTranscriptionDisposition(forAudioSampleCount sampleCount: Int) -> EmptyTranscriptionDisposition {
        if sampleCount < emptyTranscriptionCancelThresholdSampleCount {
            return .cancel
        }

        return .showNoSoundDetected
    }

    private var cleanupStateObserver: AnyCancellable?
    private var modelStateObserver: AnyCancellable?
    private let recordingOCRPrefetch: RecordingOCRPrefetch
    private let speakerIdentityResolver = SpeakerIdentityResolver()
    private var activePerformanceTrace: PerformanceTrace?
    private var activeCleanupAttempted = false
    private var pipelineOwner: PipelineOwner?
    private let cleanupSettingsDefaults: UserDefaults
    private let inputMonitoringChecker: () -> Bool
    private let inputMonitoringPrompter: () -> Void
    private let selectedInputDeviceIDProvider: () -> AudioDeviceID?
    private let resetAudioRecorder: () -> Void
    private var hotkeyMonitorStarted = false

    private static let cleanupBackendDefaultsKey = "cleanupBackend"
    private static let frontmostWindowContextEnabledDefaultsKey = "frontmostWindowContextEnabled"
    private static let postPasteLearningEnabledDefaultsKey = "postPasteLearningEnabled"
    private static let ignoreOtherSpeakersDefaultsKey = "ignoreOtherSpeakers"
    private static let playSoundsDefaultsKey = "playSounds"
    private static let archivedRecordingSampleRate = 16_000.0
    // History shows one decimal place, so shorter recordings render as 0.0s noise.
    private static let minimumArchivedRecordingSampleCount = 800
    private static let emptyTranscriptionCancelThresholdSampleCount = 8_000 // ~0.5 seconds — show "no sound" hint for almost all failed recordings
    private static let speechModelErrorPrefix = "Failed to load speech model: "
    static let liveRecordingNoInputErrorMessage = "Failed to start recording: No audio input device available."

    // 按住说话(push-to-talk):单键右 Option。与下面的单键右 Cmd toggle 无前缀冲突(54≠61 互不为子集)。
    nonisolated static let defaultPushToTalkChord = KeyChord(keys: Set([
        PhysicalKey(keyCode: 61)   // Right Option
    ]))!

    // 移植自 voicetyper:单键右 Command 即开即停(按一次开始,再按一次停止)
    nonisolated static let defaultToggleToTalkChord = KeyChord(keys: Set([
        PhysicalKey(keyCode: 54)   // Right Command
    ]))!

    nonisolated static let defaultShortcutBindings: [ChordAction: KeyChord] = [
        .pushToTalk: defaultPushToTalkChord,
        .toggleToTalk: defaultToggleToTalkChord
    ]

    init(
        hotkeyMonitor: HotkeyMonitoring = HotkeyMonitor(bindings: AppState.defaultShortcutBindings),
        chordBindingStore: ChordBindingStore = ChordBindingStore(),
        cleanupSettingsDefaults: UserDefaults = .standard,
        textCleanupManager: TextCleanupManager? = nil,
        frontmostWindowOCRService: FrontmostWindowOCRService = FrontmostWindowOCRService(),
        cleanupPromptBuilder: CleanupPromptBuilder = CleanupPromptBuilder(),
        correctionStore: CorrectionStore? = nil,
        audioRecorder: AudioRecorder = AudioRecorder(),
        textPaster: TextPaster = TextPaster(),
        debugLogStore: DebugLogStore = DebugLogStore(),
        recognizedVoiceStore: RecognizedVoiceStore = RecognizedVoiceStore(),
        transcriptionLabSpeakerProfileStore: TranscriptionLabSpeakerProfileStore = TranscriptionLabSpeakerProfileStore(),
        appRelauncher: AppRelaunching? = nil,
        inputMonitoringChecker: @escaping () -> Bool = PermissionChecker.checkInputMonitoring,
        inputMonitoringPrompter: @escaping () -> Void = PermissionChecker.promptInputMonitoring,
        selectedInputDeviceIDProvider: @escaping () -> AudioDeviceID? = { AudioDeviceManager.selectedInputDeviceID() },
        resetAudioRecorder: (() -> Void)? = nil
    ) {
        self.hotkeyMonitor = hotkeyMonitor
        self.chordBindingStore = chordBindingStore
        self.cleanupSettingsDefaults = cleanupSettingsDefaults
        self.audioRecorder = audioRecorder
        self.textPaster = textPaster
        self.debugLogStore = debugLogStore
        self.recognizedVoiceStore = recognizedVoiceStore
        self.transcriptionLabSpeakerProfileStore = transcriptionLabSpeakerProfileStore
        self.appRelauncher = appRelauncher ?? AppRelauncher()
        self.inputMonitoringChecker = inputMonitoringChecker
        self.inputMonitoringPrompter = inputMonitoringPrompter
        self.selectedInputDeviceIDProvider = selectedInputDeviceIDProvider
        self.resetAudioRecorder = resetAudioRecorder ?? { [audioRecorder] in
            audioRecorder.resetForDeviceChange()
        }
        self.pushToTalkChord = chordBindingStore.binding(for: .pushToTalk) ?? AppState.defaultPushToTalkChord
        self.toggleToTalkChord = chordBindingStore.binding(for: .toggleToTalk) ?? AppState.defaultToggleToTalkChord
        self.textCleanupManager = textCleanupManager ?? TextCleanupManager(defaults: cleanupSettingsDefaults)
        self.frontmostWindowOCRService = frontmostWindowOCRService
        self.recordingOCRPrefetch = RecordingOCRPrefetch { [frontmostWindowOCRService] customWords in
            await frontmostWindowOCRService.captureContext(customWords: customWords)
        }
        self.cleanupPromptBuilder = cleanupPromptBuilder
        self.correctionStore = correctionStore ?? CorrectionStore(defaults: cleanupSettingsDefaults)
        let storedCleanupBackend = CleanupBackendOption(
            rawValue: cleanupSettingsDefaults.string(forKey: Self.cleanupBackendDefaultsKey) ?? ""
        ) ?? .localModels
        let storedFrontmostWindowContextEnabled = cleanupSettingsDefaults.bool(
            forKey: Self.frontmostWindowContextEnabledDefaultsKey
        )
        let storedPostPasteLearningEnabled: Bool
        if cleanupSettingsDefaults.object(forKey: Self.postPasteLearningEnabledDefaultsKey) == nil {
            storedPostPasteLearningEnabled = true
        } else {
            storedPostPasteLearningEnabled = cleanupSettingsDefaults.bool(
                forKey: Self.postPasteLearningEnabledDefaultsKey
            )
        }
        let storedIgnoreOtherSpeakers: Bool
        if cleanupSettingsDefaults.object(forKey: Self.ignoreOtherSpeakersDefaultsKey) == nil {
            storedIgnoreOtherSpeakers = false
        } else {
            storedIgnoreOtherSpeakers = cleanupSettingsDefaults.bool(
                forKey: Self.ignoreOtherSpeakersDefaultsKey
            )
        }
        self.cleanupBackend = storedCleanupBackend
        self.frontmostWindowContextEnabled = storedFrontmostWindowContextEnabled
        self.postPasteLearningEnabled = storedPostPasteLearningEnabled
        self.ignoreOtherSpeakers = storedIgnoreOtherSpeakers
        if cleanupSettingsDefaults.object(forKey: Self.playSoundsDefaultsKey) == nil {
            self.playSounds = true
        } else {
            self.playSounds = cleanupSettingsDefaults.bool(forKey: Self.playSoundsDefaultsKey)
        }
        self.transcriber = SpeechTranscriber(modelManager: modelManager)
        self.cloudCleanupBackend = CloudLLMCleanupBackend(
            model: ClaudeAPIModel(rawValue: cleanupSettingsDefaults.string(forKey: "claudeCleanupModel") ?? "") ?? .haiku
        )
        self.openaiCompatibleCleanupBackend = OpenAICompatibleCleanupBackend()
        self.textCleaner = TextCleaner(
            cleanupManager: self.textCleanupManager,
            cloudBackend: self.cloudCleanupBackend,
            openaiCompatibleBackend: self.openaiCompatibleCleanupBackend,
            correctionStore: self.correctionStore
        )
        // 启动时根据持久化的 cleanupBackend 设置 TextCleaner.selectedBackendOption
        let storedBackend = CleanupBackendOption(
            rawValue: cleanupSettingsDefaults.string(forKey: "cleanupBackend") ?? ""
        ) ?? .localModels
        self.textCleaner.selectedBackendOption = storedBackend
        self.textCleaner.useCloudBackend = false  // 弃用,完全由 selectedBackendOption 接管
        self.postPasteLearningCoordinator = PostPasteLearningCoordinator(
            correctionStore: self.correctionStore,
            learningEnabled: storedPostPasteLearningEnabled,
            revisit: { session in
                await PostPasteLearningObservationProvider.captureObservation(
                    for: session
                )
            }
        )

        // Forward nested model manager state changes so SwiftUI refreshes settings rows in place.
        modelStateObserver = self.modelManager.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                self?.objectWillChange.send()
            }
        }

        // Forward cleanup manager state changes to trigger menu bar icon refresh.
        cleanupStateObserver = self.textCleanupManager.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                self?.objectWillChange.send()
            }
        }

        cleanupSettingsDefaults.set(storedCleanupBackend.rawValue, forKey: Self.cleanupBackendDefaultsKey)
        cleanupSettingsDefaults.set(
            storedFrontmostWindowContextEnabled,
            forKey: Self.frontmostWindowContextEnabledDefaultsKey
        )
        cleanupSettingsDefaults.set(
            storedPostPasteLearningEnabled,
            forKey: Self.postPasteLearningEnabledDefaultsKey
        )
        cleanupSettingsDefaults.set(
            storedIgnoreOtherSpeakers,
            forKey: Self.ignoreOtherSpeakersDefaultsKey
        )
        cleanupSettingsDefaults.set(
            playSounds,
            forKey: Self.playSoundsDefaultsKey
        )
        persistShortcutBindingsIfNeeded()
        hotkeyMonitor.updateBindings(shortcutBindings)
        self.textPaster.onPaste = { [postPasteLearningCoordinator = self.postPasteLearningCoordinator] session in
            postPasteLearningCoordinator.handlePaste(session)
        }
        self.audioRecorder.onRecordingStarted = { [weak self] in
            Task { @MainActor in
                self?.activePerformanceTrace?.micLiveAt = Date()
            }
        }
        self.audioRecorder.onRecordingStopped = { [weak self] in
            Task { @MainActor in
                self?.activePerformanceTrace?.micColdAt = Date()
            }
        }
        self.textPaster.onPasteStart = { [weak self] in
            Task { @MainActor in
                self?.activePerformanceTrace?.pasteStartAt = Date()
            }
        }
        self.textPaster.onPasteEnd = { [weak self] in
            Task { @MainActor in
                self?.completeActivePerformanceTraceIfNeeded()
            }
        }
        self.postPasteLearningCoordinator.onLearnedCorrection = { [weak overlay] replacement in
            Task { @MainActor in
                overlay?.show(message: .learnedCorrection(replacement))
            }
        }
        let componentDebugLogger: (DebugLogCategory, String) -> Void = { [weak debugLogStore] category, message in
            Task { @MainActor in
                debugLogStore?.record(category: category, message: message)
            }
        }
        let sensitiveComponentDebugLogger: (DebugLogCategory, String) -> Void = { [weak debugLogStore] category, message in
            Task { @MainActor in
                debugLogStore?.recordSensitive(category: category, message: message)
            }
        }
        if let hotkeyMonitor = hotkeyMonitor as? HotkeyMonitor {
            hotkeyMonitor.debugLogger = componentDebugLogger
        }
        self.textCleanupManager.debugLogger = componentDebugLogger
        self.frontmostWindowOCRService.debugLogger = componentDebugLogger
        self.frontmostWindowOCRService.sensitiveDebugLogger = sensitiveComponentDebugLogger
        self.textCleaner.debugLogger = componentDebugLogger
        self.textCleaner.sensitiveDebugLogger = sensitiveComponentDebugLogger
        self.cloudCleanupBackend.debugLogger = componentDebugLogger
        self.openaiCompatibleCleanupBackend.debugLogger = componentDebugLogger
        self.postPasteLearningCoordinator.debugLogger = componentDebugLogger
        self.modelManager.debugLogger = componentDebugLogger
    }

    func initialize(skipPermissionPrompts: Bool = false) async {
        // Enable launch at login by default on first run
        if !UserDefaults.standard.bool(forKey: "hasSetLaunchAtLogin") {
            UserDefaults.standard.set(true, forKey: "hasSetLaunchAtLogin")
            try? SMAppService.mainApp.register()
        }

        if !skipPermissionPrompts {
            let hasMic = await PermissionChecker.checkMicrophone()
            if !hasMic {
                errorMessage = "Microphone access required"
                status = .error
                return
            }

            let needsAccessibility = !PermissionChecker.checkAccessibility()
            let needsInputMonitoring = !inputMonitoringChecker()
            if needsAccessibility || needsInputMonitoring {
                showSettings()
            }
        }

        // Wire up "no sound" overlay to open settings
        overlay.onNoSoundSettingsTapped = { [weak self] in
            self?.showSettings()
        }

        // Pre-warm audio engine so first recording starts faster
        audioRecorder.prewarm()
        FocusedElementLocator.startPasteTargetTracking()

        status = .loading
        let showOverlay = UserDefaults.standard.bool(forKey: "onboardingCompleted")
        if showOverlay {
            overlay.show(message: .modelLoading)
        }
        debugLogStore.record(category: .model, message: "App initialization started.")
        if !modelManager.isReady {
            await loadSpeechModel(name: speechModel)
        }
        if showOverlay {
            overlay.dismiss()
        }

        guard modelManager.isReady else {
            return
        }

        await startHotkeyMonitor()

        await refreshCleanupModelState()
    }

    func relaunchApp() {
        do {
            try appRelauncher.relaunch()
        } catch {
            errorMessage = "Failed to relaunch Ghost Pepper: \(error.localizedDescription)"
        }
    }

    func startHotkeyMonitor() async {
        hotkeyMonitor.onRecordingStart = nil
        hotkeyMonitor.onRecordingStop = nil
        hotkeyMonitor.onRecordingRestart = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // Push-to-talk upgraded to toggle — reset buffer only if recording just started
                // (less than 1 second of audio at 16kHz). If they've been talking longer, keep it.
                let sampleCount = self.audioRecorder.audioBuffer.count
                if sampleCount < 16000 {
                    self.audioRecorder.resetBuffer()
                    self.debugLogStore.record(category: .hotkey, message: "Recording restarted (push-to-talk upgraded to toggle, \(sampleCount) samples discarded).")
                } else {
                    self.debugLogStore.record(category: .hotkey, message: "Push-to-talk upgraded to toggle, keeping \(sampleCount) samples of existing audio.")
                }
            }
        }

        hotkeyMonitor.onPushToTalkStart = { [weak self] in
            Task { @MainActor in
                self?.beginPerformanceTrace()
                await self?.startRecording()
            }
        }
        hotkeyMonitor.onPushToTalkStop = { [weak self] in
            Task { @MainActor in
                self?.activePerformanceTrace?.hotkeyLiftedAt = Date()
                await self?.stopRecordingAndTranscribe()
            }
        }
        hotkeyMonitor.onToggleToTalkStart = { [weak self] in
            Task { @MainActor in
                self?.beginPerformanceTrace()
                await self?.startRecording()
            }
        }
        hotkeyMonitor.onToggleToTalkStop = { [weak self] in
            Task { @MainActor in
                self?.activePerformanceTrace?.hotkeyLiftedAt = Date()
                await self?.stopRecordingAndTranscribe()
            }
        }

        hotkeyMonitor.updateBindings(shortcutBindings)

        if hotkeyMonitorStarted {
            debugLogStore.record(category: .hotkey, message: "Hotkey monitor start skipped because it is already active.")
            if status != .error {
                status = .ready
                errorMessage = nil
            }
            return
        }

        if !inputMonitoringChecker() {
            // Try to prompt, but don't block — Accessibility alone may be sufficient
            inputMonitoringPrompter()
            debugLogStore.record(category: .hotkey, message: "Input Monitoring not granted, attempting to start with Accessibility only.")
        }

        if hotkeyMonitor.start() {
            hotkeyMonitorStarted = true
            status = .ready
            errorMessage = nil
            debugLogStore.record(category: .hotkey, message: "Hotkey monitor is ready.")
        } else {
            PermissionChecker.promptAccessibility()
            errorMessage = "Accessibility access required — grant permission then click Retry"
            status = .error
            debugLogStore.record(category: .hotkey, message: errorMessage ?? "Accessibility access required.")
        }
    }

    func prepareRecordingSessionIfNeeded() async {
        audioRecorder.onConvertedAudioChunk = nil
        activeRecordingSessionCoordinator = nil
        activeRecordingTranscriptionSession = nil

        if let speechModelDescriptor = SpeechModelCatalog.model(named: speechModel) {
            if let recordingTranscriptionSessionFactory {
                activeRecordingTranscriptionSession = recordingTranscriptionSessionFactory(
                    speechModelDescriptor
                )
            } else if let recordingTranscriptionSession = modelManager.makeRecordingTranscriptionSession() {
                activeRecordingTranscriptionSession = recordingTranscriptionSession
            } else if speechModelDescriptor.backend == .fluidAudio {
                // fluidAudio chunked(Qwen3-ASR/Parakeet 支持流式)
                activeRecordingTranscriptionSession = ChunkedRecordingTranscriptionSession(
                    transcribeChunk: { [weak self] samples in
                        await self?.transcribeAudioBuffer(samples)
                    }
                )
            }
            // whisperKit backend 不走 chunked(实测每 chunk 启动 overhead 让 transcription 从 500ms 暴增至 9-117 秒)
            // 走 stopRecordingAndTranscribe → transcribedTextForRecording → transcribeAudioBuffer(整段) 的 batch 路径
        }

        // VAD 自动停止默认禁用 — 用户反馈说话带思考停顿(>2s)被误触发,体验差。
        // 录音起止完全由热键控制(按右 Cmd 开始 → 再按右 Cmd 停止 / 或按右 Option push-to-talk)。
        // 保留 VADMonitor 代码 + chunk callback 中的 process 调用,以备未来按需启用。
        vadMonitor.reset()
        vadMonitor.onSilenceDetected = nil

        guard ignoreOtherSpeakers, selectedSpeechModelSupportsSpeakerFiltering else {
            if let activeRecordingTranscriptionSession {
                audioRecorder.onConvertedAudioChunk = { [weak self, weak activeRecordingTranscriptionSession] samples in
                    activeRecordingTranscriptionSession?.appendAudioChunk(samples)
                    self?.vadMonitor.process(samples)
                }
            } else {
                audioRecorder.onConvertedAudioChunk = { [weak self] samples in
                    self?.vadMonitor.process(samples)
                }
            }
            return
        }

        let coordinator: RecordingSessionCoordinator?
        if let recordingSessionCoordinatorFactory {
            coordinator = recordingSessionCoordinatorFactory()
        } else {
            coordinator = await modelManager.makeRecordingSessionCoordinator()
        }

        guard let coordinator else {
            if let activeRecordingTranscriptionSession {
                audioRecorder.onConvertedAudioChunk = { [weak self, weak activeRecordingTranscriptionSession] samples in
                    activeRecordingTranscriptionSession?.appendAudioChunk(samples)
                    self?.vadMonitor.process(samples)
                }
            }
            return
        }

        activeRecordingSessionCoordinator = coordinator
        audioRecorder.onConvertedAudioChunk = {
            [weak self, weak coordinator, weak activeRecordingTranscriptionSession] samples in
            self?.vadMonitor.process(samples)
            coordinator?.appendAudioChunk(samples)
            activeRecordingTranscriptionSession?.appendAudioChunk(samples)
        }
    }

    private func clearRecordingSessionCoordinator() {
        audioRecorder.onConvertedAudioChunk = nil
        activeRecordingSessionCoordinator = nil
        activeRecordingTranscriptionSession = nil
    }

    private var selectedSpeechModelSupportsSpeakerFiltering: Bool {
        SpeechModelCatalog.model(named: speechModel)?.supportsSpeakerFiltering == true
    }

    private func startRecording() async {
        // If the selected speech model isn't ready, show loading message
        guard status == .ready else {
            if status == .loading {
                overlay.show(message: .modelLoading)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.overlay.dismiss()
                }
            }
            return
        }

        if activePerformanceTrace == nil {
            beginPerformanceTrace()
        }

        guard acquirePipeline(for: .liveRecording) else {
            debugLogStore.record(category: .hotkey, message: "Recording start skipped because the transcription pipeline is busy.")
            activePerformanceTrace = nil
            activeCleanupAttempted = false
            return
        }

        do {
            await prepareRecordingSessionIfNeeded()
            if cleanupEnabled && canAttemptCleanup && frontmostWindowContextEnabled {
                recordingOCRPrefetch.start(customWords: ocrCustomWords)
            } else {
                recordingOCRPrefetch.cancel()
            }
            if cleanupEnabled && canAttemptCleanup {
                let promptComponents = activeCleanupPromptComponents(windowContext: nil)
                textCleanupManager.startPromptPrefill(
                    systemPromptPrefix: promptComponents.stablePromptPrefix,
                    modelKind: textCleanupManager.selectedCleanupModelKind
                )
            } else {
                textCleanupManager.cancelPromptPrefill()
            }
            mediaPlaybackController.pauseIfPlaying()
            audioRecorder.targetDeviceID = selectedInputDeviceIDProvider()
            try audioRecorder.startRecording()
            debugLogStore.record(category: .hotkey, message: "Recording started.")
            soundEffects.playStart()
            overlay.show(message: .recording)
            isRecording = true
            status = .recording
        } catch {
            recordingOCRPrefetch.cancel()
            releasePipeline(owner: .liveRecording)
            activePerformanceTrace = nil
            errorMessage = "Failed to start recording: \(error.localizedDescription)"
            status = .error
        }
    }

    private var isTranscribing = false

    private func stopRecordingAndTranscribe() async {
        guard status == .recording, !isTranscribing else { return }
        isTranscribing = true
        defer { isTranscribing = false }

        debugLogStore.record(category: .hotkey, message: "Recording stopped. Starting transcription.")
        let buffer = await audioRecorder.stopRecording()
        let recordingSessionCoordinator = activeRecordingSessionCoordinator
        let recordingTranscriptionSession = activeRecordingTranscriptionSession
        clearRecordingSessionCoordinator()
        soundEffects.playStop()
        mediaPlaybackController.resumeIfPaused()
        isRecording = false
        status = .transcribing
        let transcribeStart = Date()  // 移植自 voicetyper:计转写耗时用于完成反馈
        overlay.show(message: .transcribing)
        activePerformanceTrace?.transcriptionStartAt = Date()
        let windowContextProvider: WindowContextProvider?
        if frontmostWindowContextEnabled {
            windowContextProvider = { [weak self] in
                await self?.recordingOCRPrefetch.resolve()
            }
        } else {
            windowContextProvider = nil
        }

        let didProduceTranscript = await processRecordingResult(
            audioBuffer: buffer,
            recordingSessionCoordinator: recordingSessionCoordinator,
            recordingTranscriptionSession: recordingTranscriptionSession,
            archivedWindowContext: nil,
            windowContextProvider: windowContextProvider,
            shouldPaste: true,
            shouldRecordDebugSnapshot: true
        )

        if didProduceTranscript {
            usageStats.record(.dictation)
            soundEffects.playCompletion()  // 移植自 voicetyper:转写成功并粘贴后的完成音效
            overlay.dismiss(ifShowing: .cleaningUp)
            // 移植自 voicetyper:转写完成后短暂显示耗时("Done X.Xs"),show 会替换 .transcribing 浮层
            overlay.show(message: .completed(seconds: Date().timeIntervalSince(transcribeStart)))
        } else {
            switch Self.emptyTranscriptionDisposition(forAudioSampleCount: buffer.count) {
            case .cancel:
                overlay.dismiss()
                debugLogStore.record(category: .model, message: "Empty transcription cancelled after a short recording.")
            case .showNoSoundDetected:
                overlay.show(message: .noSoundDetected)
                debugLogStore.record(category: .model, message: "No sound detected. Check mic in Settings → Recording.")
            }
            completeActivePerformanceTraceIfNeeded()
        }

        status = .ready
        releasePipeline(owner: .liveRecording)
    }

    func finishRecordingForTesting(
        audioBuffer: [Float],
        recordingSessionCoordinator: RecordingSessionCoordinator?,
        recordingTranscriptionSession: RecordingTranscriptionSession? = nil,
        archivedWindowContext: OCRContext?,
        windowContextProvider: WindowContextProvider? = nil
    ) async {
        _ = await processRecordingResult(
            audioBuffer: audioBuffer,
            recordingSessionCoordinator: recordingSessionCoordinator,
            recordingTranscriptionSession: recordingTranscriptionSession,
            archivedWindowContext: archivedWindowContext,
            windowContextProvider: windowContextProvider,
            shouldPaste: false,
            shouldRecordDebugSnapshot: false
        )
    }

    private func processRecordingResult(
        audioBuffer: [Float],
        recordingSessionCoordinator: RecordingSessionCoordinator?,
        recordingTranscriptionSession: RecordingTranscriptionSession?,
        archivedWindowContext: OCRContext?,
        windowContextProvider: WindowContextProvider?,
        shouldPaste: Bool,
        shouldRecordDebugSnapshot: Bool
    ) async -> Bool {
        let transcriptionResult = await transcribedTextForRecording(
            audioBuffer,
            recordingSessionCoordinator: recordingSessionCoordinator,
            recordingTranscriptionSession: recordingTranscriptionSession
        )

        guard let text = transcriptionResult.rawTranscription else {
            recordingOCRPrefetch.cancel()
            await archiveRecordingForLab(
                audioBuffer: audioBuffer,
                windowContext: archivedWindowContext,
                rawTranscription: nil,
                correctedTranscription: nil,
                cleanupUsedFallback: false,
                speakerFilteringEnabled: ignoreOtherSpeakers && selectedSpeechModelSupportsSpeakerFiltering,
                speakerFilteringRan: transcriptionResult.speakerFilteringRan,
                diarizationSummary: transcriptionResult.diarizationSummary
            )
            activePerformanceTrace?.transcriptionEndAt = Date()
            return false
        }

        activePerformanceTrace?.transcriptionEndAt = Date()
        var windowContext = archivedWindowContext
        if cleanupEnabled && canAttemptCleanup {
            activeCleanupAttempted = true
            if frontmostWindowContextEnabled,
               windowContext == nil,
               let resolvedWindowContext = await windowContextProvider?() {
                windowContext = resolvedWindowContext.context
                activePerformanceTrace?.ocrCaptureDuration = resolvedWindowContext.elapsed
            }
            activePerformanceTrace?.cleanupStartAt = Date()
            status = .cleaningUp
            if shouldPaste {
                overlay.show(message: .cleaningUp)
            }
            if frontmostWindowContextEnabled, windowContext == nil {
                debugLogStore.record(category: .ocr, message: "No frontmost-window OCR context was captured.")
            }
        } else {
            recordingOCRPrefetch.cancel()
        }

        // 流式优化分支:云端 OpenAI-Compatible backend + 需要 paste 时,走"边生成边注入"路径。
        // 首 token 200-300ms 即开始打字,体感接近 Typeless。失败时(网络/API 错)降级到下面的非流式 flow。
        if shouldPaste,
           cleanupEnabled,
           cleanupBackendOption == CleanupBackendOption.openaiCompatible.rawValue {
            activePerformanceTrace?.pasteStartAt = Date()
            if let streamedFinal = await streamCleanedAndPaste(rawText: text, windowContext: windowContext) {
                activePerformanceTrace?.pasteEndAt = Date()
                activePerformanceTrace?.cleanupEndAt = Date()
                TermHistoryStore.shared.record(text: streamedFinal)
                debugLogStore.record(category: .cleanup, message: "Streamed cleanup + progressive paste completed.")
                return true
            }
            // 流式失败 → 降级到下面的非流式 flow(Cmd+V 一次性 paste)
            debugLogStore.record(category: .cleanup, message: "Stream path failed, falling back to non-stream flow.")
        }

        let cleanupResult = await cleanedTranscriptionResult(text, windowContext: windowContext)
        let finalText = cleanupResult.text
        activeCleanupAttempted = cleanupResult.attemptedCleanup
        if cleanupResult.attemptedCleanup {
            activePerformanceTrace?.cleanupEndAt = Date()
        }

        await archiveRecordingForLab(
            audioBuffer: audioBuffer,
            windowContext: windowContext,
            rawTranscription: text,
            correctedTranscription: finalText,
            cleanupUsedFallback: cleanupResult.cleanupUsedFallback,
            speakerFilteringEnabled: ignoreOtherSpeakers && selectedSpeechModelSupportsSpeakerFiltering,
            speakerFilteringRan: transcriptionResult.speakerFilteringRan,
            diarizationSummary: transcriptionResult.diarizationSummary
        )

        if shouldRecordDebugSnapshot {
            recordCleanupDebugSnapshot(
                rawTranscription: text,
                windowContext: windowContext,
                cleanedOutput: finalText,
                attemptedCleanup: cleanupResult.attemptedCleanup
            )
        }

        if shouldPaste {
            // Task B 流式:云端 OpenAI-Compatible backend 走"边生成边 paste"路径,首字延迟接近 Typeless 体感
            // 注意 cleanedTranscriptionResult 已经把 finalText 全部生成完了(非流式),
            // 所以这里的"流式 paste"只是对已生成的文字做渐进式注入(让用户感觉是流式)。
            // 真正的端到端流式见 streamCleanedAndPaste 路径(若 caller 选用)。
            let pasteResult = textPaster.paste(text: finalText)
            if pasteResult == .copiedToClipboard {
                showClipboardFallbackMessage()
            }
            // Task B: 记录到术语历史,让下次 ASR/LLM 越用越准
            TermHistoryStore.shared.record(text: finalText)
        }

        return true
    }

    /// 真·流式 cleanup + paste:LLM 边生成边注入到光标。
    /// 仅在 cleanupBackendOption == .openaiCompatible 且 OpenAI-compatible backend 支持 SSE 时启用。
    /// 失败时 caller 应 fallback 到非流式路径(此函数返回 nil 表示失败)。
    @MainActor
    private func streamCleanedAndPaste(
        rawText: String,
        windowContext: OCRContext?
    ) async -> String? {
        guard cleanupEnabled else { return nil }
        let activeCleanupPrompt: String
        if canAttemptCleanup {
            let promptBuildStart = Date()
            activeCleanupPrompt = activeCleanupPromptComponents(windowContext: windowContext).fullPrompt
            activePerformanceTrace?.promptBuildDuration = Date().timeIntervalSince(promptBuildStart)
        } else {
            activeCleanupPrompt = languageAwareCleanupPrompt
        }

        let streamer = TextStreamer()
        var collected = ""
        let stream = openaiCompatibleCleanupBackend.cleanStream(
            text: rawText,
            prompt: activeCleanupPrompt,
            modelKind: nil
        )
        do {
            for try await chunk in stream {
                streamer.insert(chunk)
                collected += chunk
            }
        } catch {
            debugLogStore.record(category: .cleanup, message: "Stream cleanup failed: \(error.localizedDescription). Will fallback.")
            return nil
        }
        let final = collected.trimmingCharacters(in: .whitespacesAndNewlines)
        // 诊断日志:记录 raw 输入和 final 输出,便于排查"LLM 自由扩写"等行为
        debugLogStore.recordSensitive(category: .cleanup, message: "Stream raw input (\(rawText.count) chars):\n\(rawText)")
        debugLogStore.recordSensitive(category: .cleanup, message: "Stream final output (\(final.count) chars):\n\(final)")
        return final.isEmpty ? nil : final
    }

    private func transcribedTextForRecording(
        _ audioBuffer: [Float],
        recordingSessionCoordinator: RecordingSessionCoordinator?,
        recordingTranscriptionSession: RecordingTranscriptionSession?
    ) async -> RecordingTranscriptionResult {
        let diarizationTask = recordingSessionCoordinator.map { coordinator in
            Task {
                await coordinator.finishResult()
            }
        }
        let concurrentRecordingTranscriptionSession: RecordingTranscriptionSession?
        if let recordingTranscriptionSession,
           recordingTranscriptionSession.supportsConcurrentFinalization {
            concurrentRecordingTranscriptionSession = recordingTranscriptionSession
        } else {
            concurrentRecordingTranscriptionSession = nil
        }

        let streamedTranscriptTask = concurrentRecordingTranscriptionSession.map { session in
            Task<String?, Never> {
                await session.finishTranscription()?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        var diarizationSummary: DiarizationSummary?
        if let diarizationTask {
            let diarizationResult = await diarizationTask.value
            diarizationSummary = diarizationResult.summary

            if diarizationResult.summary.usedFallback == false,
               let filteredTranscript = diarizationResult.filteredTranscript?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               filteredTranscript.isEmpty == false {
                recordingTranscriptionSession?.cancel()
                return RecordingTranscriptionResult(
                    rawTranscription: filteredTranscript,
                    speakerFilteringRan: true,
                    diarizationSummary: diarizationResult.summary
                )
            }
        }

        if let streamedTranscriptTask,
           let streamedTranscript = await streamedTranscriptTask.value,
           streamedTranscript.isEmpty == false {
            return RecordingTranscriptionResult(
                rawTranscription: streamedTranscript,
                speakerFilteringRan: recordingSessionCoordinator != nil,
                diarizationSummary: diarizationSummary
            )
        }

        if concurrentRecordingTranscriptionSession == nil,
           let recordingTranscriptionSession,
           let streamedTranscript = await recordingTranscriptionSession.finishTranscription()?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           streamedTranscript.isEmpty == false {
            return RecordingTranscriptionResult(
                rawTranscription: streamedTranscript,
                speakerFilteringRan: recordingSessionCoordinator != nil,
                diarizationSummary: diarizationSummary
            )
        }

        if let recordingTranscriptionSession,
           recordingTranscriptionSession.allowsBatchFallback == false {
            return RecordingTranscriptionResult(
                rawTranscription: nil,
                speakerFilteringRan: recordingSessionCoordinator != nil,
                diarizationSummary: diarizationSummary
            )
        }

        return RecordingTranscriptionResult(
            rawTranscription: await transcribeAudioBuffer(audioBuffer),
            speakerFilteringRan: recordingSessionCoordinator != nil,
            diarizationSummary: diarizationSummary
        )
    }

    private func transcribeAudioBuffer(_ audioBuffer: [Float]) async -> String? {
        if let transcribeAudioBufferOverride {
            return transcribeAudioBufferOverride(audioBuffer)
        }

        let language = preferredLanguage == "auto" ? nil : preferredLanguage
        return await transcriber.transcribe(audioBuffer: audioBuffer, language: language)
    }

    func cleanedTranscription(_ text: String) async -> String {
        let result = await cleanedTranscriptionResult(text, windowContext: nil)
        return result.text
    }

    private func showClipboardFallbackMessage() {
        overlay.show(message: .clipboardFallback)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.overlay.dismiss(ifShowing: .clipboardFallback)
        }
    }

    private let settingsController = SettingsWindowController()
    private let promptEditorController = PromptEditorController()
    private let debugLogWindowController = DebugLogWindowController()

    var canReloadAudioInput: Bool {
        Self.isLiveRecordingNoInputError(errorMessage)
    }

    func resetAudioEngine() {
        audioRecorder.targetDeviceID = selectedInputDeviceIDProvider()
        resetAudioRecorder()

        if shouldClearLiveRecordingNoInputErrorAfterAudioReset {
            errorMessage = nil
            status = .ready
            debugLogStore.record(category: .model, message: "Audio engine reset cleared stale no-input recording error.")
        }

        debugLogStore.record(category: .model, message: "Audio engine reset for device change.")
    }

    func showSettings(section: SettingsSection? = nil) {
        settingsController.show(appState: self, section: section)
    }

    func showPromptEditor() {
        promptEditorController.show(appState: self)
    }

    func showDebugLog() {
        debugLogWindowController.show(debugLogStore: debugLogStore)
    }

    private var shortcutBindings: [ChordAction: KeyChord] {
        [
            .pushToTalk: pushToTalkChord,
            .toggleToTalk: toggleToTalkChord
        ]
    }

    private func persistShortcutBindingsIfNeeded() {
        try? chordBindingStore.setBinding(pushToTalkChord, for: .pushToTalk)
        try? chordBindingStore.setBinding(toggleToTalkChord, for: .toggleToTalk)
    }

    private var canAttemptCleanup: Bool {
        textCleanupManager.isReady
    }

    var shouldLoadLocalCleanupModels: Bool {
        cleanupEnabled
    }

    private func cleanedTranscriptionResult(
        _ text: String,
        windowContext: OCRContext?
    ) async -> CleanupResult {
        if let cleanedTranscriptionResultOverride {
            return await cleanedTranscriptionResultOverride(text, windowContext)
        }

        guard cleanupEnabled else {
            return (text: text, prompt: cleanupPrompt, attemptedCleanup: false, cleanupUsedFallback: false)
        }

        let activeCleanupPrompt: String
        if canAttemptCleanup {
            let promptBuildStart = Date()
            activeCleanupPrompt = activeCleanupPromptComponents(windowContext: windowContext).fullPrompt
            activePerformanceTrace?.promptBuildDuration = Date().timeIntervalSince(promptBuildStart)
        } else {
            activeCleanupPrompt = languageAwareCleanupPrompt
        }

        let cleanedResult = await textCleaner.cleanWithPerformance(
            text: text,
            prompt: activeCleanupPrompt,
            modelKind: textCleanupManager.selectedCleanupModelKind
        )
        activePerformanceTrace?.modelCallDuration = cleanedResult.performance.modelCallDuration
        activePerformanceTrace?.postProcessDuration = cleanedResult.performance.postProcessDuration
        return (
            text: cleanedResult.text,
            prompt: activeCleanupPrompt,
            attemptedCleanup: canAttemptCleanup,
            cleanupUsedFallback: cleanedResult.usedFallback
        )
    }

    private var languageAwareCleanupPrompt: String {
        if preferredLanguage != "auto" && preferredLanguage != "en" {
            let langName = Locale.current.localizedString(forLanguageCode: preferredLanguage) ?? preferredLanguage
            return cleanupPrompt + "\n\nThe transcription is in \(langName). Preserve the original language — do not translate to English."
        }

        return cleanupPrompt
    }

    private func activeCleanupPromptComponents(windowContext: OCRContext?) -> CleanupPromptComponents {
        cleanupPromptBuilder.buildPromptComponents(
            basePrompt: languageAwareCleanupPrompt,
            windowContext: windowContext,
            preferredTranscriptions: correctionStore.preferredTranscriptions,
            commonlyMisheard: correctionStore.commonlyMisheard,
            includeWindowContext: frontmostWindowContextEnabled
        )
    }

    var ocrCustomWords: [String] {
        correctionStore.preferredOCRCustomWords
    }

    func recordCleanupDebugSnapshot(
        rawTranscription: String,
        windowContext: OCRContext?,
        cleanedOutput: String,
        attemptedCleanup: Bool
    ) {
        debugLogStore.recordSensitive(
            category: .cleanup,
            message: """
            Raw transcription:
            \(rawTranscription)
            """
        )
        debugLogStore.recordSensitive(
            category: .cleanup,
            message: "cleanupEnabled=\(cleanupEnabled) attemptedCleanup=\(attemptedCleanup) backend=\(cleanupBackend.rawValue)"
        )
        let windowContextSummary = windowContext?.windowContents.isEmpty == false ? "captured" : "none"
        debugLogStore.recordSensitive(
            category: .cleanup,
            message: "Cleanup context summary: windowContext=\(windowContextSummary)"
        )
        debugLogStore.recordSensitive(
            category: .cleanup,
            message: "Final cleaned output:\n\(cleanedOutput)"
        )
    }

    private func beginPerformanceTrace() {
        var trace = PerformanceTrace(sessionID: UUID().uuidString)
        trace.hotkeyDetectedAt = Date()
        activePerformanceTrace = trace
        activeCleanupAttempted = false
    }

    private func completeActivePerformanceTraceIfNeeded() {
        guard var trace = activePerformanceTrace else {
            return
        }

        if trace.pasteEndAt == nil {
            trace.pasteEndAt = Date()
        }

        debugLogStore.record(
            category: .performance,
            message: trace.summary(
                speechModelID: speechModel,
                cleanupBackend: cleanupBackend,
                cleanupAttempted: activeCleanupAttempted
            )
        )

        activePerformanceTrace = nil
        activeCleanupAttempted = false
        recordingOCRPrefetch.cancel()
    }

    func archiveRecordingForLab(
        audioBuffer: [Float],
        windowContext: OCRContext?,
        rawTranscription: String?,
        correctedTranscription: String?,
        cleanupUsedFallback: Bool,
        speakerFilteringEnabled: Bool = false,
        speakerFilteringRan: Bool = false,
        diarizationSummary: DiarizationSummary? = nil
    ) async {
        // 转写实验室(History)功能已移除。此方法保留为空实现,仅为保持
        // 核心 processRecordingResult 流程的调用点零改动(铁律 1)。
        _ = (
            audioBuffer,
            windowContext,
            rawTranscription,
            correctedTranscription,
            cleanupUsedFallback,
            speakerFilteringEnabled,
            speakerFilteringRan,
            diarizationSummary
        )
    }

    func loadRecognizedVoiceProfiles() throws -> [RecognizedVoiceProfile] {
        try recognizedVoiceStore.loadProfiles()
    }

    func upsertRecognizedVoiceProfile(_ profile: RecognizedVoiceProfile) throws {
        try recognizedVoiceStore.upsert(profile)
    }

    func loadTranscriptionLabSpeakerProfiles(
        for entryID: UUID
    ) throws -> [TranscriptionLabSpeakerProfile] {
        try transcriptionLabSpeakerProfileStore.loadProfiles(for: entryID)
    }

    func loadAllTranscriptionLabSpeakerProfiles() throws -> [TranscriptionLabSpeakerProfile] {
        try transcriptionLabSpeakerProfileStore.loadAllProfiles()
    }

    func upsertTranscriptionLabSpeakerProfile(_ profile: TranscriptionLabSpeakerProfile) throws {
        try transcriptionLabSpeakerProfileStore.upsert(profile)
    }

    func updateGlobalVoiceProfile(
        from localProfile: TranscriptionLabSpeakerProfile
    ) throws -> RecognizedVoiceProfile? {
        guard let recognizedVoiceID = localProfile.recognizedVoiceID else {
            return nil
        }

        let normalizedName = localProfile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            var recognizedVoice = try recognizedVoiceStore.loadProfiles().first(where: { $0.id == recognizedVoiceID })
        else {
            return nil
        }

        if normalizedName.isEmpty == false {
            recognizedVoice.displayName = normalizedName
        }
        recognizedVoice.isMe = localProfile.isMe
        if localProfile.evidenceTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            recognizedVoice.evidenceTranscript = localProfile.evidenceTranscript
        }
        recognizedVoice.updatedAt = Date()
        try recognizedVoiceStore.upsert(recognizedVoice)
        return recognizedVoice
    }

    func updateShortcut(_ chord: KeyChord, for action: ChordAction) {
        let previousPushChord = pushToTalkChord
        let previousToggleChord = toggleToTalkChord

        do {
            try chordBindingStore.setBinding(chord, for: action)
            shortcutErrorMessage = nil

            switch action {
            case .pushToTalk:
                pushToTalkChord = chord
            case .toggleToTalk:
                toggleToTalkChord = chord
            case .pepperChat:
                // PepperChat ecosystem removed; binding ignored (enum case retained as empty shell).
                break
            }

            hotkeyMonitor.updateBindings(shortcutBindings)
        } catch {
            pushToTalkChord = previousPushChord
            toggleToTalkChord = previousToggleChord
            shortcutErrorMessage = "That shortcut is already in use."
        }
    }

    func setShortcutCaptureActive(_ isActive: Bool) {
        hotkeyMonitor.setSuspended(isActive)
    }

    func setCleanupEnabled(_ enabled: Bool) {
        cleanupEnabled = enabled
        Task {
            await refreshCleanupModelState()
        }
    }

    func updateCleanupBackend(_ backend: CleanupBackendOption) {
        cleanupBackend = backend
        Task {
            await refreshCleanupModelState()
        }
    }

    func prepareForTermination() {
        recordingOCRPrefetch.cancel()
        textCleanupManager.shutdownBackend()
    }

    func acquirePipeline(for owner: PipelineOwner) -> Bool {
        guard pipelineOwner == nil else {
            return false
        }

        pipelineOwner = owner
        return true
    }

    func releasePipeline(owner: PipelineOwner) {
        guard pipelineOwner == owner else {
            return
        }

        pipelineOwner = nil
    }

    private func refreshCleanupModelState() async {
        guard cleanupEnabled else {
            debugLogStore.record(category: .model, message: "Cleanup disabled; unloading local cleanup models.")
            textCleanupManager.unloadModel()
            objectWillChange.send()
            return
        }

        let shouldLoadLocalModels = shouldLoadLocalCleanupModels
        debugLogStore.record(
            category: .model,
            message: "Cleanup backend is \(cleanupBackend.rawValue). shouldLoadLocalModels=\(shouldLoadLocalModels)"
        )

        if shouldLoadLocalModels {
            await textCleanupManager.loadModel()
        } else {
            textCleanupManager.unloadModel()
        }

        objectWillChange.send()
    }

    private func resolveTranscriptionLabSpeakerProfiles(
        entryID: UUID,
        audioBuffer: [Float],
        diarizationSummary: DiarizationSummary,
        speakerTaggedTranscript: SpeakerTaggedTranscript?
    ) async -> [TranscriptionLabSpeakerProfile] {
        do {
            let recognizedVoices = try recognizedVoiceStore.loadProfiles()
            let existingLocalProfiles = try transcriptionLabSpeakerProfileStore.loadProfiles(for: entryID)
            let speakerInputs = await makeSpeakerIdentityInputs(
                audioBuffer: audioBuffer,
                diarizationSummary: diarizationSummary,
                speakerTaggedTranscript: speakerTaggedTranscript
            )
            let resolution = speakerIdentityResolver.resolve(
                entryID: entryID,
                speakers: speakerInputs,
                existingLocalProfiles: existingLocalProfiles,
                recognizedVoices: recognizedVoices
            )

            for profile in resolution.recognizedVoices {
                try recognizedVoiceStore.upsert(profile)
            }
            for profile in resolution.localProfiles {
                try transcriptionLabSpeakerProfileStore.upsert(profile)
            }

            return resolution.localProfiles
        } catch {
            return []
        }
    }

    private func makeSpeakerIdentityInputs(
        audioBuffer: [Float],
        diarizationSummary: DiarizationSummary,
        speakerTaggedTranscript: SpeakerTaggedTranscript?
    ) async -> [SpeakerIdentityInput] {
        let speakerIDs = diarizationSummary.spans.reduce(into: [String]()) { orderedIDs, span in
            if orderedIDs.contains(span.speakerID) == false {
                orderedIDs.append(span.speakerID)
            }
        }

        var inputs: [SpeakerIdentityInput] = []
        inputs.reserveCapacity(speakerIDs.count)

        for speakerID in speakerIDs {
            let speakerSpans = mergedSpeakerSpans(
                from: diarizationSummary.spans.filter { $0.speakerID == speakerID }
            )
            let speakerAudio = extractSpeakerAudio(
                from: audioBuffer,
                spans: speakerSpans
            )
            let evidenceTranscript = speakerTaggedTranscript?.segments
                .filter { $0.speakerID == speakerID }
                .map(\.text)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let audioDuration = speakerSpans.reduce(into: 0.0) { total, span in
                total += span.duration
            }
            let embedding: [Float]?
            if audioDuration >= speakerIdentityResolver.minimumEmbeddingDuration,
               speakerAudio.isEmpty == false {
                embedding = try? await modelManager.extractSpeakerEmbedding(from: speakerAudio)
            } else {
                embedding = nil
            }

            inputs.append(
                SpeakerIdentityInput(
                    speakerID: speakerID,
                    audioDuration: audioDuration,
                    evidenceTranscript: evidenceTranscript,
                    embedding: embedding
                )
            )
        }

        return inputs
    }

    private func mergedSpeakerSpans(
        from spans: [DiarizationSummary.Span]
    ) -> [DiarizationSummary.MergedSpan] {
        let sortedSpans = spans.sorted { lhs, rhs in
            if lhs.startTime == rhs.startTime {
                return lhs.endTime < rhs.endTime
            }
            return lhs.startTime < rhs.startTime
        }

        var mergedSpans: [DiarizationSummary.MergedSpan] = []
        for span in sortedSpans where span.duration > 0 {
            if let lastSpan = mergedSpans.last,
               span.startTime <= lastSpan.endTime {
                mergedSpans[mergedSpans.count - 1] = DiarizationSummary.MergedSpan(
                    startTime: lastSpan.startTime,
                    endTime: max(lastSpan.endTime, span.endTime)
                )
            } else {
                mergedSpans.append(
                    DiarizationSummary.MergedSpan(
                        startTime: span.startTime,
                        endTime: span.endTime
                    )
                )
            }
        }

        return mergedSpans
    }

    private func extractSpeakerAudio(
        from audioBuffer: [Float],
        spans: [DiarizationSummary.MergedSpan],
        sampleRate: Double = 16_000
    ) -> [Float] {
        guard audioBuffer.isEmpty == false else {
            return []
        }

        var extractedAudio: [Float] = []
        for span in spans where span.duration > 0 {
            let startIndex = max(Int((span.startTime * sampleRate).rounded(.down)), 0)
            let endIndex = min(Int((span.endTime * sampleRate).rounded(.up)), audioBuffer.count)
            guard startIndex < endIndex else {
                continue
            }

            extractedAudio.append(contentsOf: audioBuffer[startIndex..<endIndex])
        }

        return extractedAudio
    }

    private func restorePreferredSpeechModelIfNeeded(_ preferredSpeechModelID: String) async {
        guard modelManager.modelName != preferredSpeechModelID || !modelManager.isReady else {
            return
        }

        await loadSpeechModel(name: preferredSpeechModelID)
    }

    func loadSpeechModel(name: String) async {
        await modelManager.loadModel(name: name)
        let nextPresentation = Self.nextSpeechModelPresentation(
            managerState: modelManager.state,
            managerError: modelManager.error,
            currentStatus: status,
            currentErrorMessage: errorMessage
        )
        status = nextPresentation.status
        errorMessage = nextPresentation.errorMessage
    }

    static func nextSpeechModelPresentation(
        managerState: ModelManagerState,
        managerError: Error?,
        currentStatus: AppStatus,
        currentErrorMessage: String?
    ) -> (status: AppStatus, errorMessage: String?) {
        switch managerState {
        case .error:
            let shouldClearSpeechModelError = currentErrorMessage?.hasPrefix(speechModelErrorPrefix) == true
            let preservedErrorMessage = shouldClearSpeechModelError ? nil : currentErrorMessage
            return (
                .error,
                preservedErrorMessage
            )
        case .ready:
            let shouldClearSpeechModelError = currentErrorMessage?.hasPrefix(speechModelErrorPrefix) == true
            let nextStatus: AppStatus = shouldClearSpeechModelError && currentStatus == .error
                ? .ready
                : currentStatus
            return (
                nextStatus,
                shouldClearSpeechModelError ? nil : currentErrorMessage
            )
        case .idle, .loading:
            return (currentStatus, currentErrorMessage)
        }
    }

    private var shouldClearLiveRecordingNoInputErrorAfterAudioReset: Bool {
        status == .error && !isRecording && !isTranscribing && Self.isLiveRecordingNoInputError(errorMessage)
    }

    private static func isLiveRecordingNoInputError(_ message: String?) -> Bool {
        message == liveRecordingNoInputErrorMessage
    }
}
