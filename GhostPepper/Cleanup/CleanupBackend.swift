import Foundation

protocol CleanupBackend: AnyObject {
    func clean(text: String, prompt: String, modelKind: LocalCleanupModelKind?) async throws -> String

    /// 流式清理 — 返回增量 token 流。默认实现 fallback 到 non-stream `clean()` 一次性返回。
    /// 支持原生流式的 backend(如 OpenAI Chat Completions stream=true)应重写此方法以获得首 token 200-300ms 体验。
    func cleanStream(
        text: String,
        prompt: String,
        modelKind: LocalCleanupModelKind?
    ) -> AsyncThrowingStream<String, Error>
}

extension CleanupBackend {
    func cleanStream(
        text: String,
        prompt: String,
        modelKind: LocalCleanupModelKind?
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let fullText = try await self.clean(text: text, prompt: prompt, modelKind: modelKind)
                    continuation.yield(fullText)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

enum CleanupBackendError: Error, Equatable {
    case unavailable
    case unusableOutput(rawOutput: String)
}
