import Foundation
import simd

/// Адаптивное сглаживание положения (фильтр One Euro): в покое сглаживает сильно и убирает
/// дрожь, при быстром движении ослабевает, чтобы не отставать.
public struct OneEuroPositionFilter: Sendable {
    /// Частота среза в покое по осям, Гц: меньше — сильнее сглаживание.
    public var minCutoff: SIMD3<Double>
    /// Насколько срез растёт со скоростью, Гц на м/с.
    public var beta: SIMD3<Double>
    /// Частота среза для оценки скорости, Гц.
    public var derivativeCutoff: Double
    /// Текущее сглаженное значение; `nil` до первого измерения.
    public private(set) var value: SIMD3<Double>?
    /// Сглаженная скорость, м/с.
    public private(set) var speed = SIMD3<Double>(repeating: 0)

    public init(minCutoff: SIMD3<Double>, beta: SIMD3<Double>, derivativeCutoff: Double = 1) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.derivativeCutoff = derivativeCutoff
    }

    /// Добавляет измерение.
    ///
    /// - Parameters:
    ///   - sample: измерение, метры.
    ///   - dt: время с прошлого измерения, секунды.
    public mutating func add(_ sample: SIMD3<Double>, dt: Double) {
        guard let current = value, dt > 0 else {
            value = sample
            return
        }
        let rawSpeed = (sample - current) / dt
        speed += (rawSpeed - speed) * Self.alpha(cutoff: SIMD3(repeating: derivativeCutoff), dt: dt)
        let cutoff = minCutoff + beta * simd_abs(speed)
        value = current + (sample - current) * Self.alpha(cutoff: cutoff, dt: dt)
    }

    /// Забывает накопленное значение.
    public mutating func reset() {
        value = nil
        speed = .zero
    }

    private static func alpha(cutoff: SIMD3<Double>, dt: Double) -> SIMD3<Double> {
        let tau = 1 / (2 * .pi * cutoff)
        return 1 / (1 + tau / dt)
    }
}

/// Мягкая мёртвая зона: выход не двигается, пока вход отличается меньше чем на `band`, а дальше
/// следует за входом с отставанием ровно на `band`, без скачков.
public struct SoftDeadband: Sendable {
    /// Ширина зоны по осям.
    public var band: SIMD3<Double>
    /// Текущий выход; `nil` до первого значения.
    public private(set) var value: SIMD3<Double>?

    public init(band: SIMD3<Double>) {
        self.band = band
    }

    /// Подтягивает выход к `target` и возвращает его.
    public mutating func follow(_ target: SIMD3<Double>) -> SIMD3<Double> {
        guard var current = value else {
            value = target
            return target
        }
        let difference = target - current
        let excess = simd_max(simd_abs(difference) - band, .zero)
        current += SIMD3(sign(difference.x) * excess.x, sign(difference.y) * excess.y, sign(difference.z) * excess.z)
        value = current
        return current
    }

    /// Забывает выход.
    public mutating func reset() {
        value = nil
    }
}

/// Упреждение положения на задержку измерения: при движении положение сдвигается вперёд
/// на `speed·lead`, в покое упреждения нет, чтобы не усиливать дрожь.
///
/// - Parameters:
///   - value: сглаженное положение, метры.
///   - speed: сглаженная скорость, м/с.
///   - lead: на сколько секунд вперёд экстраполировать.
///   - startSpeed: ниже этой скорости по оси упреждения нет, м/с.
///   - fullSpeed: с этой скорости упреждение полное, м/с.
public func leadCompensated(_ value: SIMD3<Double>, speed: SIMD3<Double>, lead: Double,
                            startSpeed: Double = 0.05, fullSpeed: Double = 0.15) -> SIMD3<Double> {
    let magnitude = simd_abs(speed)
    let share = simd_clamp((magnitude - startSpeed) / (fullSpeed - startSpeed), SIMD3(repeating: 0), SIMD3(repeating: 1))
    return value + speed * lead * share
}

/// Где глаза головы относительно оси поворота в шее, метры в осях головы (X вправо, Y вверх,
/// вперёд — −Z): при повороте головы глаза ходят по дуге вокруг шеи.
public let eyesFromNeck = SIMD3<Double>(0, 0.07, -0.08)

/// Сдвиг глаз из-за поворота головы относительно опорной ориентации, мировые оси, метры.
public func eyeArcOffset(head: simd_quatd, reference: simd_quatd, eyes: SIMD3<Double> = eyesFromNeck) -> SIMD3<Double> {
    head.act(eyes) - reference.act(eyes)
}
