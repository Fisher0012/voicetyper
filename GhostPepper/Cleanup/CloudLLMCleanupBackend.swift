import Foundation

/// CleanupBackend 的云端实现，通过 Anthropic Claude API 进行文本清理。
/// 相比本地小模型，Claude 的理解能力更强，清理质量更高。
final class CloudLLMCleanupBackend: CleanupBackend {
    static let keychainKey = AnthropicProvider.keychainKey

    private let model: ClaudeAPIModel
    private let apiKeyProvider: () -> String?
    var debugLogger: ((DebugLogCategory, String) -> Void)?

    init(
        model: ClaudeAPIModel = .haiku,
        apiKeyProvider: @escaping () -> String? = {
            KeychainHelper.get(AnthropicProvider.keychainKey)
        }
    ) {
        self.model = model
        self.apiKeyProvider = apiKeyProvider
    }

    func clean(text: String, prompt: String, modelKind: LocalCleanupModelKind?) async throws -> String {
        guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else {
            debugLogger?(.cleanup, "Cloud cleanup skipped: no Claude API key configured.")
            throw CleanupBackendError.unavailable
        }

        let requestBody = buildRequestBody(systemPrompt: prompt, userText: text)
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 15
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw CleanupBackendError.unavailable
        }

        if http.statusCode != 200 {
            let detail = String(data: data, encoding: .utf8) ?? "<no body>"
            debugLogger?(.cleanup, "Cloud cleanup failed with status \(http.statusCode): \(detail)")
            throw CleanupBackendError.unavailable
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let firstBlock = content.first,
              let outputText = firstBlock["text"] as? String else {
            debugLogger?(.cleanup, "Cloud cleanup returned unparseable response.")
            throw CleanupBackendError.unavailable
        }

        let cleaned = outputText.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty {
            throw CleanupBackendError.unusableOutput(rawOutput: outputText)
        }

        debugLogger?(.cleanup, "Cloud cleanup finished using \(model.shortDisplayName).")
        return cleaned
    }

    private func buildRequestBody(systemPrompt: String, userText: String) -> [String: Any] {
        [
            "model": model.rawValue,
            "max_tokens": 2048,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": userText]
            ]
        ]
    }
}
