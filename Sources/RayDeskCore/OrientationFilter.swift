import Foundation
import simd

/// Комплементарный фильтр ориентации головы по данным гироскопа и
/// акселерометра очков (алгоритм Madgwick/Mahony с обучаемым смещением
/// гироскопа).
///
/// Мировая и связанная система координат: X вправо, Y вверх, Z назад
/// (вперёд — это -Z). В покое акселерометр читает +1g вдоль мировой оси Y.
public final class OrientationFilter {
    private let lock = NSLock()
    private var q = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    private var omega = SIMD3<Double>(repeating: 0)
    private var accumulatedTravel = RotationTravel(total: 0, yaw: 0)
    private var bias = SIMD3<Double>(repeating: 0)
    private var integral = SIMD3<Double>(repeating: 0)
    private var initialized = false
    private var stillTime = 0.0
    private var smoothedGyro = SIMD3<Double>(repeating: 0)
    private(set) var sampleCount = 0

    /// `true`, если фильтр инициализирован (выровнен по гравитации) и
    /// накопил достаточно отсчётов для доверенной оценки ориентации.
    public var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return initialized && sampleCount > 200
    }

    /// Компенсация дрейфа «вперёд»: на сколько радиан мир поворачивается вокруг вертикали
    /// против дрейфа на каждый радиан поворота головы. Наклон не затрагивает.
    public var yawDriftPerRadian: Double {
        get {
            lock.lock()
            defer { lock.unlock() }
            return driftCompensation
        }
        set {
            lock.lock()
            driftCompensation = newValue
            lock.unlock()
        }
    }
    private var driftCompensation = 0.0
    public var kp = 0.5
    public var ki = 0.002

    public init() {}

    /// Сбрасывает фильтр к неинициализированному состоянию, обнуляет
    /// накопленную калибровку смещения гироскопа.
    public func reset() {
        lock.lock()
        initialized = false
        integral = .zero
        stillTime = 0
        smoothedGyro = bias
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

        trackBias(gyro: gyro, accel: accel, accelNorm: accelNorm, dt: dt)

        var w = gyro - bias
        omega = w
        let travelStep = length(w) * dt
        accumulatedTravel.total += travelStep
        accumulatedTravel.yaw += q.act(w).y * dt
        if accelNorm > 0.7, accelNorm < 1.3 {
            let measuredUp = accel / accelNorm
            let estimatedUp = q.inverse.act(SIMD3(0, 1, 0))
            let error = cross(measuredUp, estimatedUp)
            integral += ki * error * dt
            w += kp * error + integral
        }
        let angle = length(w) * dt
        if angle > 1e-9 {
            q = simd_normalize(q * simd_quatd(angle: angle, axis: normalize(w)))
        }
        if driftCompensation != 0, travelStep > 0 {
            q = simd_normalize(simd_quatd(angle: -driftCompensation * travelStep, axis: SIMD3(0, 1, 0)) * q)
        }
    }

    private func trackBias(gyro: SIMD3<Double>, accel: SIMD3<Double>, accelNorm: Double, dt: Double) {
        smoothedGyro += (gyro - smoothedGyro) * min(1, dt / BiasTracking.smoothingSeconds)
        let still = length(smoothedGyro - bias) < BiasTracking.stillRate && abs(accelNorm - 1) < 0.02
        stillTime = still ? stillTime + dt : 0
        guard stillTime > BiasTracking.stillSeconds else { return }
        bias += (smoothedGyro - bias) * min(1, dt / BiasTracking.learningSeconds)
    }

    /// Сколько голова повернулась с момента создания фильтра, по гироскопу за вычетом смещения нуля.
    public var travel: RotationTravel {
        lock.lock()
        defer { lock.unlock() }
        return accumulatedTravel
    }

    /// Текущая оценка смещения нуля гироскопа, рад/с, в осях датчика.
    public var gyroBias: SIMD3<Double> {
        lock.lock()
        defer { lock.unlock() }
        return bias
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
        lock.unlock()
    }
}

private enum BiasTracking {
    static let smoothingSeconds = 1.0
    static let stillRate = 0.2 * Double.pi / 180
    static let stillSeconds = 1.5
    static let learningSeconds = 10.0
}

/// Накопленный поворот головы, радианы.
public struct RotationTravel: Equatable {
    /// Сумма модулей поворота по всем осям.
    public var total: Double
    /// Поворот вокруг мировой вертикали со знаком: плюс — влево.
    public var yaw: Double
}
