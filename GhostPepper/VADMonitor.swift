import Foundation

/// 语音活动检测器(VAD)。监听音频 chunk 的 RMS,实现"开始说话后连续 N 秒静音自动停止录音"。
/// 不动 AudioRecorder 核心,作为 AppState 的旁路监听器,触发 onSilenceDetected 回调。
///
/// 状态机:
///   INITIAL   — 等用户开口(RMS > speechThreshold 触发转 LISTENING),起步阶段静音不计
///   LISTENING — 已开口,持续 RMS < silenceThreshold 累积静音时长
///   FIRED     — 已触发停止,不再回调
final class VADMonitor {
    enum State {
        case initial
        case listening
        case fired
    }

    private(set) var state: State = .initial
    private var silenceAccumulatedSeconds: Double = 0
    private var samplesPerSecond: Double  // = 16000(AudioRecorder 输出 16kHz 单声道 Float32)
    private let speechThreshold: Float
    private let silenceThreshold: Float
    private let silenceDurationToFire: Double
    /// 一旦进入 LISTENING,再到 fire,期间至少要听到多少秒的"有声"才算真正一次发言
    /// (防止用户开口一下子就长时间停顿被误触发)
    private let minSpeechDurationBeforeFire: Double
    private var speechAccumulatedSeconds: Double = 0
    var onSilenceDetected: (() -> Void)?

    init(
        samplesPerSecond: Double = 16_000,
        speechThreshold: Float = 0.02,        // 经验值,典型说话 RMS 在 0.05-0.3
        silenceThreshold: Float = 0.008,      // 静音/呼吸声通常 < 0.005
        silenceDurationToFire: Double = 2.0,  // 静音连续 2 秒触发停止
        minSpeechDurationBeforeFire: Double = 0.8
    ) {
        self.samplesPerSecond = samplesPerSecond
        self.speechThreshold = speechThreshold
        self.silenceThreshold = silenceThreshold
        self.silenceDurationToFire = silenceDurationToFire
        self.minSpeechDurationBeforeFire = minSpeechDurationBeforeFire
    }

    func reset() {
        state = .initial
        silenceAccumulatedSeconds = 0
        speechAccumulatedSeconds = 0
    }

    /// 处理一个音频 chunk(16kHz 单声道 Float32 PCM)
    func process(_ samples: [Float]) {
        guard state != .fired, !samples.isEmpty else { return }
        let rms = Self.rms(samples)
        let chunkDuration = Double(samples.count) / samplesPerSecond

        switch state {
        case .initial:
            if rms > speechThreshold {
                state = .listening
                speechAccumulatedSeconds = chunkDuration
                silenceAccumulatedSeconds = 0
            }
        case .listening:
            if rms < silenceThreshold {
                silenceAccumulatedSeconds += chunkDuration
                if silenceAccumulatedSeconds >= silenceDurationToFire,
                   speechAccumulatedSeconds >= minSpeechDurationBeforeFire {
                    state = .fired
                    onSilenceDetected?()
                }
            } else {
                // 有声音,清空静音计数,累加发言时长
                silenceAccumulatedSeconds = 0
                if rms > speechThreshold {
                    speechAccumulatedSeconds += chunkDuration
                }
            }
        case .fired:
            break
        }
    }

    private static func rms(_ samples: [Float]) -> Float {
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }
}
