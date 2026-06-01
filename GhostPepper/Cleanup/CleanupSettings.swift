import Foundation

enum CleanupBackendOption: String, CaseIterable, Identifiable {
    case localModels
    case claude

    var id: String { rawValue }

    var title: String {
        switch self {
        case .localModels:
            return "Local Models"
        case .claude:
            return "Claude API"
        }
    }
}
