import Foundation

enum SpeechBackendKind: Equatable {
    case whisperKit
    case fluidAudio
}

enum FluidAudioModelVariant: Equatable {
    case parakeetV3
    case qwen3AsrInt8
}

struct SpeechModelDescriptor: Identifiable, Equatable {
    let name: String
    let pickerTitle: String
    let variantName: String
    let sizeDescription: String
    let backend: SpeechBackendKind
    let cachePathComponents: [String]
    let fluidAudioVariant: FluidAudioModelVariant?

    var id: String { name }

    var pickerLabel: String {
        "\(pickerTitle) (\(variantName) — \(sizeDescription))"
    }

    var statusName: String {
        switch backend {
        case .whisperKit:
            "Whisper \(variantName) (\(pickerTitle.lowercased()))"
        case .fluidAudio:
            "\(pickerTitle) (\(variantName.lowercased()))"
        }
    }

    var supportsSpeakerFiltering: Bool {
        // Speaker filtering uses a separate diarization pipeline, so any
        // FluidAudio-backed ASR model can participate in filtering.
        backend == .fluidAudio
    }
}

enum SpeechModelCatalog {
    static let whisperTiny = SpeechModelDescriptor(
        name: "openai_whisper-tiny.en",
        pickerTitle: "Speed",
        variantName: "tiny.en",
        sizeDescription: "~75 MB",
        backend: .whisperKit,
        cachePathComponents: ["openai", "whisper-tiny.en"],
        fluidAudioVariant: nil
    )

    static let whisperSmallEnglish = SpeechModelDescriptor(
        name: "openai_whisper-small.en",
        pickerTitle: "Accuracy",
        variantName: "small.en",
        sizeDescription: "~466 MB",
        backend: .whisperKit,
        cachePathComponents: ["openai", "whisper-small.en"],
        fluidAudioVariant: nil
    )

    static let whisperSmallMultilingual = SpeechModelDescriptor(
        name: "openai_whisper-small",
        pickerTitle: "Multilingual",
        variantName: "small",
        sizeDescription: "~466 MB",
        backend: .whisperKit,
        cachePathComponents: ["openai", "whisper-small"],
        fluidAudioVariant: nil
    )

    /// Whisper Large v3 Turbo:精度接近 large-v3,速度比 large 快 ~8x。argmaxinc/whisperkit-coreml 提供 CoreML 优化版。
    /// 对中英混说、专有名词、短促音识别质量提升约 30-40%,是当前本地 ASR 性价比最优。
    static let whisperLargeV3Turbo = SpeechModelDescriptor(
        name: "openai_whisper-large-v3-v20240930_turbo",
        pickerTitle: "Large v3 Turbo",
        variantName: "large-v3-turbo",
        sizeDescription: "~810 MB",
        backend: .whisperKit,
        cachePathComponents: ["openai", "whisper-large-v3-v20240930_turbo"],
        fluidAudioVariant: nil
    )

    static let parakeetV3 = SpeechModelDescriptor(
        name: "fluid_parakeet-v3",
        pickerTitle: "Parakeet v3",
        variantName: "25 languages",
        sizeDescription: "~1.4 GB",
        backend: .fluidAudio,
        cachePathComponents: ["FluidInference", "parakeet-tdt-0.6b-v3-coreml"],
        fluidAudioVariant: .parakeetV3
    )

    static let qwen3AsrInt8 = SpeechModelDescriptor(
        name: "fluid_qwen3-asr-0.6b-int8",
        pickerTitle: "Qwen3-ASR 0.6B",
        variantName: "int8, 50+ languages",
        sizeDescription: "~900 MB",
        backend: .fluidAudio,
        cachePathComponents: [],
        fluidAudioVariant: .qwen3AsrInt8
    )

    /// Models that are always selectable on the current OS.
    private static let baseModels: [SpeechModelDescriptor] = [
        whisperTiny,
        whisperSmallEnglish,
        whisperSmallMultilingual,
        whisperLargeV3Turbo,
        parakeetV3,
    ]

    static var availableModels: [SpeechModelDescriptor] {
        if #available(macOS 15, iOS 18, *) {
            return baseModels + [qwen3AsrInt8]
        }
        return baseModels
    }

    // Systemic 升级:默认 whisper-large-v3-turbo。精度比 small 提升约 30-40%,处理速度因 turbo 优化只比 small 慢 ~2x。
    // 与 Qwen 4B cleanup 配合,从模型层根治"短促音 / 英文专有名词 / 中英混说"识别质量问题,
    // 不再靠 prompt 补丁修单点错误。代价:首次下载 ~810MB。
    static let defaultModelID = whisperLargeV3Turbo.id

    static var whisperModels: [SpeechModelDescriptor] {
        availableModels.filter { $0.backend == .whisperKit }
    }

    static func model(named name: String) -> SpeechModelDescriptor? {
        availableModels.first { $0.name == name }
    }
}
