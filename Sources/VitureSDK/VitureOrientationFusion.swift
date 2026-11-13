import Foundation
import simd

/// Ориентация VIO с кратковременным продолжением поворота по гироскопу.
///
/// Устойчивая поза задаёт ориентацию напрямую. При потере устойчивости гироскоп
/// продолжает поворот не дольше `maximumGyroDuration`, затем ориентация сохраняется
/// до следующей устойчивой позы. До первой устойчивой позы интеграция отключена.
public struct VitureOrientationFusion: Sendable {
    /// Максимальная длительность поворота по гироскопу без устойчивой позы, секунды.
    public static let maximumGyroDuration = 0.25
    /// Ниже этой угловой скорости гироскоп считается стоящим и уточняется его ноль, рад/с.
    public var biasLearnSpeed = 0.05
    /// Постоянная времени обучения нуля гироскопа, секунды.
    public var biasTimeConstant = 4.0

    private var orientation: simd_quatd?
    private var bias = SIMD3<Double>.zero
    private var lastUpdate: Double?
    private var lastStableTime: Double?

    public init() {}

    /// Текущий выученный ноль гироскопа, рад/с.
    public var gyroBias: SIMD3<Double> { bias }

    /// Сбрасывает состояние; например при переносе опоры мира.
    public mutating func reset() {
        orientation = nil
        lastUpdate = nil
        lastStableTime = nil
    }

    /// Возвращает оставшийся допустимый горизонт предсказания в секундах.
    /// - Parameter time: монотонное время кадра в той же шкале, что и `update`.
    /// - Returns: время до окончания окна после устойчивой позы; без неё — ноль.
    public func remainingPredictionTime(at time: Double) -> Double {
        guard let lastStableTime else { return 0 }
        return max(0, min(Self.maximumGyroDuration, lastStableTime + Self.maximumGyroDuration - time))
    }

    /// Добавляет отсчёт и возвращает ориентацию для отрисовки.
    ///
    /// - Parameters:
    ///   - pose: ориентация от VIO, если SDK её отдал.
    ///   - stable: статус устойчивости VIO.
    ///   - gyro: угловая скорость по осям тела, рад/с; `nil`, если IMU ещё не пришёл.
    ///   - time: время отсчёта, секунды.
    ///   - still: голова стоит по гироскопу; в темноте это единственный признак покоя,
    ///     потому что VIO там может быть неустойчив постоянно.
    /// - Returns: ориентация для кадра.
    public mutating func update(pose: simd_quatd?, stable: Bool, gyro: SIMD3<Double>?, time: Double,
                                still: Bool = false) -> simd_quatd? {
        let previousTime = lastUpdate ?? time
        let dt = max(0, min(0.1, time - previousTime))
        lastUpdate = time

        if let gyro, dt > 0, (stable || still), length(gyro) < biasLearnSpeed {
            let alpha = 1 - exp(-dt / max(0.01, biasTimeConstant))
            bias += (gyro - bias) * alpha
        }

        if let pose, stable {
            orientation = pose
            lastStableTime = time
            return pose
        }

        if orientation == nil { orientation = pose }
        guard var current = orientation else { return nil }
        guard let lastStableTime else { return current }

        let integrationEnd = min(time, lastStableTime + Self.maximumGyroDuration)
        let integrationTime = max(0, integrationEnd - (time - dt))
        if let gyro, integrationTime > 0 {
            let rate = gyro - bias
            let angle = length(rate) * integrationTime
            if angle > 1e-9 {
                current = simd_normalize(current * simd_quatd(angle: angle, axis: normalize(rate)))
            }
            orientation = current
        }

        return current
    }
}
