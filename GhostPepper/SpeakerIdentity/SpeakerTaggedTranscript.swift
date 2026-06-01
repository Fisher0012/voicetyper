import Foundation

// 说话人标注转写的核心类型。原先定义在已删除的 Lab/TranscriptionLabRunner.swift 中,
// 但被核心转写流程(ModelManager.transcribeWithSpeakerTagging /
// FluidAudioSpeechSession.speakerTaggedTranscript)和 SpeakerIdentity 流程引用,
// 因此随 Lab 删除一并迁移到此处保留。
struct SpeakerTaggedTranscript: Equatable, Sendable {
    struct Segment: Equatable, Sendable {
        let speakerID: String
        let startTime: TimeInterval
        let endTime: TimeInterval
        let text: String
    }

    let segments: [Segment]
}

struct SpeakerTaggedTranscriptionResult: Equatable, Sendable {
    let filteredTranscript: String?
    let diarizationSummary: DiarizationSummary
    let speakerTaggedTranscript: SpeakerTaggedTranscript?
}
