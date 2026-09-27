import Foundation
import simd

/// Сила стабилизации картинки.
public enum StabilizationLevel: String, CaseIterable, Codable, Sendable {
    case off, weak, medium, strong

    fileprivate var minCutoff: Double {
        switch self {
        case .off: .infinity
        case .weak: 0.4
        case .medium: 0.15
        case .strong: 0.08
        }
    }

    fileprivate var speedGain: Double {
        switch self {
        case .off: 0
        case .weak: 5
        case .medium: 6
        case .strong: 8
        }
    }
}

/// Сглаживает ориентацию головы для отрисовки фильтром One Euro: частота среза растёт
/// со скоростью поворота, поэтому микродвижения (пульс, дрожь) гасятся, а быстрые
/// повороты проходят почти без задержки. Рывок больше `snapAngle` не сглаживается.
public struct OrientationStabilizer {
    /// Частота среза для оценки скорости поворота, Гц.
    public static let speedCutoff = 1.0
    /// Рывок ориентации, после которого сглаживание начинается заново, радианы.
    public static let snapAngle = 10 * Double.pi / 180

    public var level: StabilizationLevel
    private var filtered: simd_quatd?
    private var previous: simd_quatd?
    private var speed = 0.0

    public init(level: StabilizationLevel) {
        self.level = level
    }

    /// Возвращает сглаженную ориентацию.
    ///
    /// - Parameters:
    ///   - orientation: ориентация голова→мир этого кадра.
    ///   - dt: время с прошлого кадра, секунды.
    public mutating func filter(_ orientation: simd_quatd, dt: Double) -> simd_quatd {
        guard level != .off, dt > 0, let filtered, let previous,
              angle(between: filtered, and: orientation) < OrientationStabilizer.snapAngle
        else {
            self.filtered = orientation
            self.previous = orientation
            speed = 0
            return orientation
        }
        let rawSpeed = angle(between: previous, and: orientation) / dt
        speed += (rawSpeed - speed) * smoothing(cutoff: OrientationStabilizer.speedCutoff, dt: dt)
        let cutoff = level.minCutoff + level.speedGain * speed
        let result = simd_slerp(filtered, orientation, smoothing(cutoff: cutoff, dt: dt))
        self.filtered = result
        self.previous = orientation
        return result
    }

    private func smoothing(cutoff: Double, dt: Double) -> Double {
        let tau = 1 / (2 * .pi * cutoff)
        return 1 / (1 + tau / dt)
    }

    private func angle(between a: simd_quatd, and b: simd_quatd) -> Double {
        2 * acos(min(1, abs(simd_dot(a.vector, b.vector))))
    }
}
