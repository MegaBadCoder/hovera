import Foundation
import simd

/// Комплементарный фильтр ориентации головы: гироскоп интегрируется за вычетом нуля,
/// выученного в покое, наклон поправляется по акселерометру, курс — по компасу, если
/// задана его калибровка.
///
/// Мировая и связанная система координат: X вправо, Y вверх, Z назад
/// (вперёд — это -Z). В покое акселерометр читает +1g вдоль мировой оси Y.
public final class OrientationFilter {
    private let lock = NSLock()
    private var q = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    private var omega = SIMD3<Double>(repeating: 0)
    private var accumulatedTravel = RotationTravel(total: 0, yaw: 0)
    private var initialized = false
    private(set) var sampleCount = 0
    private var compass: MagnetometerCalibration?
    private var magneticReference: Double?
    private var localField: (strength: Double, dip: Double)?
    private var referenceField: (strength: Double, dip: Double)?
    private var verticalBiasEstimate = 0.0
    private var biasLearner = StillnessBiasLearner()

    /// `true`, если фильтр инициализирован (выровнен по гравитации) и
    /// накопил достаточно отсчётов для доверенной оценки ориентации.
    public var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return initialized && sampleCount > 200
    }

    public var kp = 0.5

    public init() {}

    /// Калибровка магнитометра. Пока она задана, компас медленно оценивает смещение нуля
    /// гироскопа вокруг мировой вертикали и вычитает его; `nil` выключает компас.
    /// Любая установка сбрасывает опорное направление поля и оценку смещения.
    public var magnetometerCalibration: MagnetometerCalibration? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return compass
        }
        set {
            lock.lock()
            compass = newValue
            magneticReference = nil
            localField = newValue.map { ($0.radius, $0.dip) }
            referenceField = nil
            verticalBiasEstimate = 0
            lock.unlock()
        }
    }

    /// Оценка смещения нуля гироскопа вокруг мировой вертикали по компасу, рад/с.
    public var verticalBias: Double {
        lock.lock()
        defer { lock.unlock() }
        return verticalBiasEstimate
    }

    /// Сбрасывает фильтр к неинициализированному состоянию и обнуляет оценку компаса.
    public func reset() {
        lock.lock()
        initialized = false
        magneticReference = nil
        referenceField = nil
        verticalBiasEstimate = 0
        lock.unlock()
    }

    /// Добавляет один отсчёт IMU в фильтр.
    ///
    /// Первый вызов с валидным (не нулевым) ускорением только
    /// инициализирует ориентацию по направлению гравитации (yaw = 0) и не
    /// меняет `omega`. Последующие вызовы интегрируют угловую скорость и
    /// корректируют её по измеренному "верху" акселерометра.
    ///
    /// - Parameters:
    ///   - gyro: угловая скорость по осям тела, рад/с.
    ///   - accel: ускорение по осям тела, единицы g.
    ///   - dt: время с предыдущего отсчёта, секунды; вызовы с `dt <= 0` или
    ///     `dt >= 0.1` игнорируются.
    public func update(gyro: SIMD3<Double>, accel: SIMD3<Double>, dt: Double) {
        update(gyro: gyro, accel: accel, magnetometer: nil, dt: dt)
    }

    /// То же, что `update(gyro:accel:dt:)`, плюс показание магнитометра по осям тела
    /// (сырые единицы) для компаса; `nil` — в этом отсчёте поля нет.
    public func update(gyro: SIMD3<Double>, accel: SIMD3<Double>, magnetometer: SIMD3<Double>?, dt: Double) {
        guard dt > 0, dt < 0.1 else { return }
        lock.lock()
        defer { lock.unlock() }
        sampleCount &+= 1

        let accelNorm = length(accel)
        if !initialized {
            guard accelNorm > 0.1 else { return }
            q = simd_quatd(from: normalize(accel), to: SIMD3(0, 1, 0))
            let yp = q.yawPitch
            q = simd_quatd(angle: -yp.yaw, axis: SIMD3(0, 1, 0)) * q
            initialized = true
            return
        }

        biasLearner.add(gyro: gyro, accelNorm: accelNorm, magnetometer: magnetometer, dt: dt)
        var w = gyro - biasLearner.bias
        omega = w
        accumulatedTravel.total += length(w) * dt
        accumulatedTravel.yaw += q.act(w).y * dt
        if abs(accelNorm - 1) < TiltCorrection.maxAccelDeviation, length(w) < TiltCorrection.maxTurnRate {
            let measuredUp = accel / accelNorm
            let estimatedUp = q.inverse.act(SIMD3(0, 1, 0))
            let error = cross(measuredUp, estimatedUp)
            w += kp * error
        }
        let angle = length(w) * dt
        if angle > 1e-9 {
            q = simd_normalize(q * simd_quatd(angle: angle, axis: normalize(w)))
        }
        if let compass {
            q = simd_normalize(simd_quatd(angle: -verticalBiasEstimate * dt, axis: SIMD3(0, 1, 0)) * q)
            if let magnetometer {
                observeCompass(magnetometer, calibration: compass, dt: dt)
            }
        }
    }

    private func observeCompass(_ magnetometer: SIMD3<Double>, calibration: MagnetometerCalibration, dt: Double) {
        let field = magnetometer - calibration.center
        let strength = length(field)
        guard strength > 0 else { return }
        let dip = acos(max(-1, min(1, dot(field / strength, q.inverse.act(SIMD3(0, 1, 0))))))

        var local = localField ?? (calibration.radius, calibration.dip)
        let adaptation = min(1, dt / Compass.placeAdaptationSeconds)
        local.strength += (strength - local.strength) * adaptation
        local.dip += (dip - local.dip) * adaptation
        localField = local

        if let reference = referenceField,
           abs(local.strength / reference.strength - 1) > Compass.maxFieldDeviation || abs(local.dip - reference.dip) > Compass.maxDipDeviation {
            magneticReference = nil
        }
        guard abs(strength / local.strength - 1) < Compass.maxFieldDeviation,
              abs(dip - local.dip) < Compass.maxDipDeviation
        else { return }
        let world = q.act(field)
        guard length(SIMD2(world.x, world.z)) > Compass.minHorizontalShare * strength else { return }

        let heading = atan2(world.x, world.z)
        guard let reference = magneticReference else {
            magneticReference = heading
            referenceField = local
            return
        }
        let error = atan2(sin(heading - reference), cos(heading - reference))
        verticalBiasEstimate += Compass.integralGain * error * dt
        q = simd_normalize(simd_quatd(angle: -Compass.proportionalGain * error * dt, axis: SIMD3(0, 1, 0)) * q)
    }

    /// Смещение нуля гироскопа, выученное в моменты покоя, рад/с по осям тела.
    public var gyroBias: SIMD3<Double> {
        lock.lock()
        defer { lock.unlock() }
        return biasLearner.bias
    }

    func configureBiasLearner(_ change: (inout StillnessBiasLearner) -> Void) {
        lock.lock()
        change(&biasLearner)
        lock.unlock()
    }

    /// Ненадолго разрешает учить ноль по любым спокойным моментам — см. `StillnessBiasLearner.trustNextStillness()`.
    public func trustNextStillness() {
        lock.lock()
        biasLearner.trustNextStillness()
        lock.unlock()
    }

    /// Начинает обучение нуля с известного значения, например сохранённого с прошлого запуска.
    ///
    /// - Parameter bias: смещение нуля по осям тела, рад/с.
    public func seedGyroBias(_ bias: SIMD3<Double>) {
        lock.lock()
        biasLearner = StillnessBiasLearner(bias: bias)
        lock.unlock()
    }

    /// Сколько голова повернулась с момента создания фильтра, по гироскопу за вычетом смещения нуля.
    public var travel: RotationTravel {
        lock.lock()
        defer { lock.unlock() }
        return accumulatedTravel
    }

    /// Экстраполирует текущую ориентацию вперёд на заданное время по
    /// последней угловой скорости.
    ///
    /// - Parameter seconds: горизонт прогноза, секунды.
    /// - Returns: предсказанная ориентация.
    public func orientation(predictAhead seconds: Double) -> simd_quatd {
        lock.lock()
        defer { lock.unlock() }
        let angle = length(omega) * seconds
        guard angle > 1e-9 else { return q }
        return simd_normalize(q * simd_quatd(angle: angle, axis: normalize(omega)))
    }

    /// Обнуляет текущий yaw, сохраняя pitch и roll.
    public func alignYawToZero() {
        lock.lock()
        let yp = q.yawPitch
        q = simd_quatd(angle: -yp.yaw, axis: SIMD3(0, 1, 0)) * q
        if let reference = magneticReference {
            magneticReference = atan2(sin(reference - yp.yaw), cos(reference - yp.yaw))
        }
        lock.unlock()
    }
}


/// Накопленный поворот головы, радианы.
public struct RotationTravel: Equatable {
    /// Сумма модулей поворота по всем осям.
    public var total: Double
    /// Поворот вокруг мировой вертикали со знаком: плюс — влево.
    public var yaw: Double
}

private enum TiltCorrection {
    static let maxAccelDeviation = 0.05
    static let maxTurnRate = 30 * Double.pi / 180
}

private enum Compass {
    static let maxFieldDeviation = 0.03
    static let maxDipDeviation = 5 * Double.pi / 180
    static let placeAdaptationSeconds = 30.0
    static let minHorizontalShare = 0.2
    static let proportionalGain = 1.0 / 8
    static let integralGain = proportionalGain * proportionalGain / 4
}
