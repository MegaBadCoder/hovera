import Foundation
import simd

/// Слияние ориентации VIO с гироскопом очков.
///
/// VIO даёт абсолютную ориентацию с привязкой наклона к гравитации, но в темноте
/// и на однородной сцене теряет устойчивость и начинает «плыть». Гироскоп в такие
/// моменты точнее на коротком отрезке: он быстро и без рывков продолжает поворот,
/// пока VIO не восстановится. Поэтому ориентация всегда ведётся гироскопом, а
/// устойчивая поза VIO медленно подтягивает её к себе.
public struct VitureOrientationFusion: Sendable {
    /// Постоянная времени подтягивания к устойчивой позе VIO, секунды.
    public var poseTimeConstant = 1.5
    /// Выше этой угловой скорости поза VIO не подмешивается: на ходу она отстаёт и дрожит.
    public var correctionSpeed = 10 * Double.pi / 180
    /// Ниже этой угловой скорости гироскоп считается стоящим и уточняется его ноль, рад/с.
    public var biasLearnSpeed = 0.05
    /// Постоянная времени обучения нуля гироскопа, секунды.
    public var biasTimeConstant = 4.0
    /// Угол, после которого ориентация берётся от VIO сразу, без плавного перехода, радианы.
    public var snapAngle = 20 * Double.pi / 180

    private var orientation: simd_quatd?
    private var bias = SIMD3<Double>.zero
    private var lastUpdate: Double?

    public init() {}

    /// Текущий выученный ноль гироскопа, рад/с.
    public var gyroBias: SIMD3<Double> { bias }

    /// Сбрасывает состояние; например при переносе опоры мира.
    public mutating func reset() {
        orientation = nil
        lastUpdate = nil
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
        let dt = lastUpdate.map { max(0, min(0.1, time - $0)) } ?? 0
        lastUpdate = time

        if let pose {
            if orientation == nil {
                orientation = pose
            } else if stable {
                let slowEnough = gyro.map { length($0) <= correctionSpeed } ?? true
                if slowEnough, let current = orientation {
                    let angle = 2 * acos(min(1, abs(simd_dot(current.vector, pose.vector))))
                    if angle > snapAngle {
                        orientation = pose
                    } else {
                        let alpha = 1 - exp(-dt / max(0.01, poseTimeConstant))
                        orientation = simd_normalize(simd_slerp(current, pose, alpha))
                    }
                }
            }
        }

        guard var current = orientation else { return nil }

        if let gyro, dt > 0 {
            var rate = gyro
            if (stable || still), length(gyro) < biasLearnSpeed {
                let alpha = 1 - exp(-dt / max(0.01, biasTimeConstant))
                bias += (gyro - bias) * alpha
            }
            rate -= bias
            let angle = length(rate) * dt
            if angle > 1e-9 {
                current = simd_normalize(current * simd_quatd(angle: angle, axis: normalize(rate)))
            }
            orientation = current
        }

        return current
    }
}
