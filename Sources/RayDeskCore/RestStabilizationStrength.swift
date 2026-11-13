import Foundation

/// Сила сглаживания в покое; не изменяет условия обхода при движении.
public enum RestStabilizationStrength: String, CaseIterable, Sendable {
    case light, medium, strong

    /// Наибольшая поправка ориентации, радианы.
    public var maximumCorrectionRadians: Double {
        switch self {
        case .light: 0.025 * .pi / 180
        case .medium: 0.05 * .pi / 180
        case .strong: 0.10 * .pi / 180
        }
    }

    /// Временная постоянная сглаживания ориентации в покое, секунды.
    public var timeConstant: Double {
        switch self {
        case .light: 0.12
        case .medium: 0.20
        case .strong: 0.30
        }
    }
}

/// Фактическое состояние детектора и фильтра покоя.
public enum RestStabilizationPhase: String, CaseIterable, Sendable {
    case disabled, unavailable, waiting, moving, resting
}
