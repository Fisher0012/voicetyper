import Foundation

enum CleanupBackendOption: String, CaseIterable, Identifiable {
    case localModels
    case claude
    case openaiCompatible

    var id: String { rawValue }

    var title: String {
        switch self {
        case .localModels:
            return "Local Models"
        case .claude:
            return "Claude API"
        case .openaiCompatible:
            return "OpenAI-Compatible (MiniMax/OpenAI/DeepSeek/OpenRouter)"
        }
    }

    var subtitle: String {
        switch self {
        case .localModels:
            return "100% local · Qwen 4B · 默认,无网络无 API key"
        case .claude:
            return "Anthropic API · 顶级质量 · 需 Claude API key,付费"
        case .openaiCompatible:
            return "任何 OpenAI 兼容 endpoint · 推荐 MiniMax(便宜约 1/20 Claude)"
        }
    }
}
