import Foundation
import Security

// 这些类型原本属于已删除的会议笔记 QA 生态(GhostPepper/QA/)。
// 为保留云端 Claude 文本清理后端(CloudLLMCleanupBackend),
// 把它真正依赖的最小类型在此"抢救"保留:
// - ClaudeAPIModel:云端清理使用的模型枚举(model.rawValue / shortDisplayName)
// - KeychainHelper:从 Keychain 读取 API Key
// - AnthropicProvider:仅保留 keychainKey 常量(原 provider 协议链已删除)

enum ClaudeAPIModel: String, CaseIterable, Identifiable {
    case opus = "claude-opus-4-7"
    case sonnet = "claude-sonnet-4-6"
    case haiku = "claude-haiku-4-5"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .opus: return "Claude Opus 4.7 (best quality)"
        case .sonnet: return "Claude Sonnet 4.6 (balanced)"
        case .haiku: return "Claude Haiku 4.5 (fastest)"
        }
    }

    var shortDisplayName: String {
        switch self {
        case .opus: return "Opus 4.7"
        case .sonnet: return "Sonnet 4.6"
        case .haiku: return "Haiku 4.5"
        }
    }
}

/// 仅保留云端清理后端需要的 keychainKey 常量。
/// 原 AnthropicProvider 的网络/协议实现随 QA 生态一并删除。
enum AnthropicProvider {
    static let keychainKey = "claudeAPIKey"
}

enum KeychainHelper {
    static let service = "com.donnie.voicetyper.next"

    static func set(_ value: String, for key: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        SecItemDelete(query as CFDictionary)

        if value.isEmpty {
            return true
        }

        var attributes = query
        attributes[kSecValueData as String] = data

        let status = SecItemAdd(attributes as CFDictionary, nil)
        return status == errSecSuccess
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
