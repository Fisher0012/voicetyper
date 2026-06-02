import Foundation

/// 通用 OpenAI Chat Completions 兼容 backend。
/// 可用于 MiniMax / OpenAI / DeepSeek / OpenRouter / Together AI / 自建 endpoint 等任何兼容 OpenAI 协议的服务。
///
/// 用户配置三项:
///   - base URL(例: `https://api.minimaxi.com/v1` 或 `https://api.openai.com/v1`)
///   - model id(例: `MiniMax-M2.7` 或 `gpt-4o-mini`)
///   - API key(Bearer token,存 Keychain)
///
/// 设计选择:**不硬编码 provider** — 让用户填 endpoint 自行选择。这样:
/// - 永不锁定特定厂商
/// - 用户可换更便宜的服务而不需 app 更新
/// - MiniMax / OpenAI / OpenRouter 等切换零成本
final class OpenAICompatibleCleanupBackend: CleanupBackend {
    /// Keychain 服务名前缀,用于存 API key
    static let keychainKey = "openaiCompatibleAPIKey"

    private let baseURLProvider: () -> String
    private let modelProvider: () -> String
    private let apiKeyProvider: () -> String?
    var debugLogger: ((DebugLogCategory, String) -> Void)?

    init(
        baseURLProvider: @escaping () -> String = {
            UserDefaults.standard.string(forKey: "openaiCompatibleBaseURL") ?? ""
        },
        modelProvider: @escaping () -> String = {
            UserDefaults.standard.string(forKey: "openaiCompatibleModel") ?? ""
        },
        apiKeyProvider: @escaping () -> String? = {
            KeychainHelper.get(OpenAICompatibleCleanupBackend.keychainKey)
        }
    ) {
        self.baseURLProvider = baseURLProvider
        self.modelProvider = modelProvider
        self.apiKeyProvider = apiKeyProvider
    }

    func clean(text: String, prompt: String, modelKind: LocalCleanupModelKind?) async throws -> String {
        let baseURL = baseURLProvider().trimmingCharacters(in: .whitespacesAndNewlines)
        let model = modelProvider().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseURL.isEmpty, !model.isEmpty else {
            debugLogger?(.cleanup, "OpenAI-compatible cleanup skipped: base URL or model not configured.")
            throw CleanupBackendError.unavailable
        }
        guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else {
            debugLogger?(.cleanup, "OpenAI-compatible cleanup skipped: no API key configured.")
            throw CleanupBackendError.unavailable
        }

        // 拼接 endpoint。允许用户填 base URL(末尾可带 /v1 或不带)
        let trimmed = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        let endpoint: String
        if trimmed.hasSuffix("/chat/completions") {
            endpoint = trimmed
        } else if trimmed.hasSuffix("/v1") {
            endpoint = trimmed + "/chat/completions"
        } else {
            // 用户填了根域名,假设需要 /v1/chat/completions
            endpoint = trimmed + "/v1/chat/completions"
        }
        guard let url = URL(string: endpoint) else {
            debugLogger?(.cleanup, "OpenAI-compatible cleanup: invalid base URL \(baseURL).")
            throw CleanupBackendError.unavailable
        }

        let requestBody: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": prompt],
                ["role": "user", "content": text]
            ],
            "max_tokens": 2048,
            "temperature": 0.2,
            "stream": false
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw CleanupBackendError.unavailable
        }

        if http.statusCode != 200 {
            let detail = String(data: data, encoding: .utf8) ?? "<no body>"
            debugLogger?(.cleanup, "OpenAI-compatible cleanup failed status \(http.statusCode): \(detail.prefix(200))")
            throw CleanupBackendError.unavailable
        }

        // OpenAI Chat Completions 标准响应:
        // { "choices": [{ "message": { "content": "..." } }] }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let outputText = message["content"] as? String else {
            debugLogger?(.cleanup, "OpenAI-compatible cleanup returned unparseable response.")
            throw CleanupBackendError.unavailable
        }

        let cleaned = outputText.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty {
            throw CleanupBackendError.unusableOutput(rawOutput: outputText)
        }

        debugLogger?(.cleanup, "OpenAI-compatible cleanup finished using model=\(model).")
        return cleaned
    }
}
