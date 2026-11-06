import Foundation
import simd

/// Поправка к горизонту предсказания по фактической ошибке прошлых кадров.
///
/// Каждый показанный кадр сравнивается с тем, что фильтр восстановил для момента показа
/// по истории ориентаций. Если предсказание не долетело до фактического движения, горизонт
/// надо увеличить; если перелетело — уменьшить. Ошибка переводится во время через угловую
/// скорость, поэтому поправка не зависит от того, насколько быстро поворачивалась голова.
public struct PredictionTuner: Sendable {
    /// Наибольшая поправка к горизонту, секунды.
    public var maxBias = 0.010
    /// Доля нового измерения в сглаженной поправке.
    public var smoothing = 0.1
    /// Ниже этой угловой скорости ошибку во времени не считаем, рад/с: деление на шум.
    public static let minSpeed = 0.2

    private var bias = 0.0
    private var samples = 0

    public init() {}

    /// Текущая поправка к горизонту, секунды; плюс — предсказывать дальше.
    public var value: Double { bias }

    /// Сколько измерений принято.
    public var sampleCount: Int { samples }

    /// Добавляет ошибку предсказания одного показанного кадра.
    ///
    /// - Parameters:
    ///   - predicted: ориентация, с которой кадр отрисован, голова→мир.
    ///   - actual: ориентация на тот же момент, восстановленная по истории, голова→мир.
    ///   - angularVelocity: угловая скорость головы на момент кадра, по осям тела, рад/с.
    public mutating func observe(predicted: simd_quatd, actual: simd_quatd, angularVelocity: SIMD3<Double>) {
        let speed = length(angularVelocity)
        guard speed > Self.minSpeed, speed.isFinite else { return }
        var error = actual * predicted.inverse
        if error.real < 0 {
            error = simd_quatd(vector: -error.vector)
        }
        let angle = 2 * acos(min(1, abs(error.real)))
        guard angle > 1e-9 else { return }
        let direction = normalize(actual.act(angularVelocity))
        let timeError = dot(error.axis, direction) * angle / speed
        bias += (timeError - bias) * smoothing
        bias = min(maxBias, max(-maxBias, bias))
        samples += 1
    }
}
