import Foundation
import simd

/// Комплементарный фильтр ориентации головы: гироскоп интегрируется, наклон поправляется
/// по акселерометру. Курс держит компас, если задана его калибровка; без компаса из
/// гироскопа вычитается ноль, выученный в моменты покоя.
///
/// Мировая и связанная система координат: X вправо, Y вверх, Z назад
/// (вперёд — это -Z). В покое акселерометр читает +1g вдоль мировой оси Y.
public final class OrientationFilter: @unchecked Sendable {
    private let lock = NSLock()
    private var q = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    private var omega = SIMD3<Double>(repeating: 0)
    private var accumulatedTravel = RotationTravel(total: 0, yaw: 0)
    private var initialized = false
    private(set) var sampleCount = 0
    private var compass: MagnetometerCalibration?
    private var magneticReferences: [SIMD2<Int>: Double] = [:]
    private var localField: (strength: Double, dip: Double)?
    private var referenceField: (strength: Double, dip: Double)?
    private var lastCompassError = 0.0
    private var fieldDiffersFromCalibration = false
    private(set) var magneticOffset = 0.0
    private var headingTrail = HeadingTrail()
    var compassTuning = CompassTuning()
    private(set) var compassTurn = 0.0
    private var biasLearner = StillnessBiasLearner()
    private var history = [(time: Double, orientation: simd_quatd)](repeating: (0, simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)), count: OrientationFilter.historySize)
    private var historyNext = 0
    private var historyCount = 0
    private var trailClock = 0.0
    private var smoothedAccel: SIMD3<Double>?
    private var currentSector: SIMD2<Int>?
    private var tiltIntegral = SIMD3<Double>(repeating: 0)
    var clock: @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }
    private static let historySize = 256

    /// `true`, если фильтр инициализирован (выровнен по гравитации) и
    /// накопил достаточно отсчётов для доверенной оценки ориентации.
    public var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return initialized && sampleCount > 200
    }

    public var kp = 0.5
    private var scale = SIMD3<Double>(1, 1, 1)

    /// Во сколько раз умножать показания гироскопа по каждой оси очков — поправка масштаба
    /// из `GyroScaleCalibration`; по умолчанию единицы.
    public var gyroScale: SIMD3<Double> {
        get { lock.withLock { scale } }
        set { lock.withLock { scale = newValue } }
    }

    public init() {}

    /// Калибровка магнитометра. Пока она задана, курс плавно подтягивается к направлению
    /// поля, запомненному для того же направления взгляда (секторы по 15° по курсу и наклону):
    /// так ошибка компаса, зависящая от поворота головы, не сдвигает мир; `nil` выключает компас.
    /// Любая установка сбрасывает опорное направление поля.
    public var magnetometerCalibration: MagnetometerCalibration? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return compass
        }
        set {
            lock.lock()
            compass = newValue
            magneticReferences = [:]
            localField = newValue.map { ($0.radius, $0.dip) }
            referenceField = nil
            lastCompassError = 0
            fieldDiffersFromCalibration = false
            magneticOffset = 0
            headingTrail = HeadingTrail()
            lock.unlock()
        }
    }

    /// `true`, если поле вокруг очков в среднем за последние полминуты заметно отличается от
    /// калиброванного: сила больше чем на 15 % или наклон больше чем на 10°. Так бывает, когда
    /// рядом с очками появился магнит, например наушники. Сбрасывается, когда поле вернулось
    /// (в пределах 8 % и 6°) или задана новая калибровка.
    public var compassFieldChanged: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fieldDiffersFromCalibration
    }

    /// Насколько курс по гироскопу расходился с компасом в последнем принятом показании, рад;
    /// плюс — курс левее поля.
    public var compassError: Double {
        lock.lock()
        defer { lock.unlock() }
        return lastCompassError
    }

    /// Сбрасывает фильтр к неинициализированному состоянию и забывает опору компаса.
    public func reset() {
        lock.lock()
        initialized = false
        magneticReferences = [:]
        referenceField = nil
        lastCompassError = 0
        magneticOffset = 0
        headingTrail = HeadingTrail()
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
        let gyro = gyro * scale
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

        var w = gyro
        if compass == nil {
            biasLearner.add(gyro: gyro, accelNorm: accelNorm, magnetometer: magnetometer, dt: dt)
            w -= biasLearner.bias
        }
        omega = w
        accumulatedTravel.total += length(w) * dt
        accumulatedTravel.yaw += q.act(w).y * dt
        if abs(accelNorm - 1) < TiltCorrection.maxAccelDeviation, length(w) < TiltCorrection.maxTurnRate {
            let measuredUp = accel / accelNorm
            let estimatedUp = q.inverse.act(SIMD3(0, 1, 0))
            let error = cross(measuredUp, estimatedUp)
            if compassTuning.tiltIntegralGain > 0 {
                tiltIntegral += compassTuning.tiltIntegralGain * error * dt
            }
            w += kp * error
        }
        w += tiltIntegral
        let smoothing = min(1, dt / compassTuning.accelSmoothing)
        smoothedAccel = smoothedAccel.map { $0 + (accel - $0) * smoothing } ?? accel
        let angle = length(w) * dt
        if angle > 1e-9 {
            q = simd_normalize(q * simd_quatd(angle: angle, axis: normalize(w)))
        }
        if let compass, let magnetometer {
            observeCompass(magnetometer, calibration: compass, dt: dt)
        }
        history[historyNext] = (clock(), q)
        historyNext = (historyNext + 1) % Self.historySize
        historyCount = min(historyCount + 1, Self.historySize)
    }

    /// Ориентация в прошлый момент времени — например, когда камера снимала кадр.
    ///
    /// Хранится около полусекунды истории; между отсчётами ориентация интерполируется,
    /// за пределами истории берётся ближайший край.
    ///
    /// - Parameter time: момент в шкале `ProcessInfo.systemUptime` (та же, что у часов хоста), секунды.
    public func orientation(atUptime time: Double) -> simd_quatd {
        lock.lock()
        defer { lock.unlock() }
        guard historyCount > 0 else { return q }
        let newest = (historyNext + Self.historySize - 1) % Self.historySize
        var later = history[newest]
        guard time < later.time else { return later.orientation }
        for step in 1..<historyCount {
            let earlier = history[(newest + Self.historySize - step) % Self.historySize]
            if earlier.time <= time {
                let span = later.time - earlier.time
                let fraction = span > 0 ? (time - earlier.time) / span : 0
                return simd_slerp(earlier.orientation, later.orientation, fraction)
            }
            later = earlier
        }
        return later.orientation
    }

    /// Текущая угловая скорость головы, рад/с.
    public var angularSpeed: Double {
        lock.lock()
        defer { lock.unlock() }
        return length(omega)
    }

    private func observeCompass(_ magnetometer: SIMD3<Double>, calibration: MagnetometerCalibration, dt: Double) {
        var field = magnetometer - calibration.center
        let strength = length(field)
        guard strength > 0 else { return }
        let tuning = compassTuning
        if tuning.tiltGate > 0 || tuning.levelWithAccel || tuning.headingTiltGate > 0, let smoothedAccel {
            let norm = length(smoothedAccel)
            let valid = abs(norm - 1) < tuning.accelGate && length(omega) < 30 * Double.pi / 180
            if valid {
                let measuredUp = smoothedAccel / norm
                let estimatedUp = q.inverse.act(SIMD3(0, 1, 0))
                if tuning.tiltGate > 0, acos(max(-1, min(1, dot(measuredUp, estimatedUp)))) > tuning.tiltGate { return }
                if tuning.headingTiltGate > 0 {
                    let plain = q.act(field)
                    let leveled = q.act(simd_quatd(from: measuredUp, to: estimatedUp).act(field))
                    let difference = atan2(plain.x, plain.z) - atan2(leveled.x, leveled.z)
                    if abs(atan2(sin(difference), cos(difference))) > tuning.headingTiltGate { return }
                }
                if tuning.levelWithAccel { field = simd_quatd(from: measuredUp, to: estimatedUp).act(field) }
            } else if tuning.gateInvalidAccel {
                return
            }
        }
        let dip = acos(max(-1, min(1, dot(field / strength, q.inverse.act(SIMD3(0, 1, 0))))))

        var local = localField ?? (calibration.radius, calibration.dip)
        let adaptation = min(1, dt / Compass.placeAdaptationSeconds)
        local.strength += (strength - local.strength) * adaptation
        local.dip += (dip - local.dip) * adaptation
        localField = local
        let strengthChange = abs(local.strength / calibration.radius - 1)
        let dipChange = abs(local.dip - calibration.dip)
        if strengthChange > Compass.changedFieldStrength || dipChange > Compass.changedFieldDip {
            fieldDiffersFromCalibration = true
        } else if strengthChange < Compass.restoredFieldStrength, dipChange < Compass.restoredFieldDip {
            fieldDiffersFromCalibration = false
        }

        if let reference = referenceField,
           abs(local.strength / reference.strength - 1) > Compass.maxFieldDeviation || abs(local.dip - reference.dip) > Compass.maxDipDeviation {
            magneticReferences = [:]
        }
        guard abs(strength / local.strength - 1) < Compass.maxFieldDeviation,
              abs(dip - local.dip) < Compass.maxDipDeviation
        else { return }
        let world = q.act(field)
        guard length(SIMD2(world.x, world.z)) > Compass.minHorizontalShare * strength else { return }

        let heading = atan2(world.x, world.z)
        if tuning.absorbFastChanges {
            magneticOffset += headingTrail.fastChange(heading: heading, time: trailClock, travel: accumulatedTravel.total, dt: dt, tuning: tuning)
            if tuning.offsetDecaySeconds > 0 { magneticOffset *= 1 - min(1, dt / tuning.offsetDecaySeconds) }
        }
        trailClock += dt
        let look = q.yawPitch
        var sector = SIMD2(Int((look.yaw / tuning.sectorSize).rounded()), Int((look.pitch / tuning.sectorSize).rounded()))
        if tuning.sectorHysteresis > 0, let previous = currentSector, previous != sector {
            let centerYaw = Double(previous.x) * tuning.sectorSize, centerPitch = Double(previous.y) * tuning.sectorSize
            let limit = tuning.sectorSize / 2 + tuning.sectorHysteresis
            if abs(atan2(sin(look.yaw - centerYaw), cos(look.yaw - centerYaw))) < limit, abs(look.pitch - centerPitch) < limit {
                sector = previous
            }
        }
        currentSector = sector
        if magneticReferences.isEmpty { referenceField = local }
        guard let reference = magneticReferences[sector] else {
            magneticReferences[sector] = heading - magneticOffset
            return
        }
        if tuning.snapBack > 0, abs(atan2(sin(heading - reference), cos(heading - reference))) < tuning.snapBack {
            magneticOffset = 0
        }
        magneticOffset = max(-tuning.maxOffset, min(tuning.maxOffset, magneticOffset))
        let error = atan2(sin(heading - reference - magneticOffset), cos(heading - reference - magneticOffset))
        lastCompassError = error
        let cap = tuning.motionRateGain > 0 ? min(tuning.maxCorrectionRate, tuning.stillCorrectionRate + tuning.motionRateGain * length(omega)) : tuning.maxCorrectionRate
        let rate = max(-cap, min(cap, tuning.proportionalGain * error))
        compassTurn += rate * dt
        q = simd_normalize(simd_quatd(angle: -rate * dt, axis: SIMD3(0, 1, 0)) * q)
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

    /// Обнуляет текущий yaw, сохраняя pitch и roll. Компас принимает новое направление
    /// за верное: опора поля берётся заново со следующего принятого показания.
    public func alignYawToZero() {
        lock.lock()
        let yp = q.yawPitch
        q = simd_quatd(angle: -yp.yaw, axis: SIMD3(0, 1, 0)) * q
        magneticReferences = [:]
        lastCompassError = 0
        magneticOffset = 0
        headingTrail = HeadingTrail()
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

struct CompassTuning {
    var proportionalGain = 1.0 / 4
    var maxCorrectionRate = 0.5 * Double.pi / 180
    var sectorSize = 15 * Double.pi / 180
    var absorbFastChanges = false
    var fastWindow = 0.5
    var fastThreshold = 1.5 * Double.pi / 180
    var fastThresholdPerTravel = 0.2
    var smoothing = 0.1
    var offsetDecaySeconds = 0.0
    var maxTravel = 20 * Double.pi / 180
    var snapBack = 0.0
    var maxOffset = 30 * Double.pi / 180
    var tiltGate = 0.0
    var levelWithAccel = false
    var accelSmoothing = 0.5
    var accelGate = 0.03
    var tiltIntegralGain = 0.0
    var gateInvalidAccel = false
    var sectorHysteresis = 0.0
    var headingTiltGate = 0.0
    var motionRateGain = 0.0
    var stillCorrectionRate = 0.05 * Double.pi / 180
}

struct HeadingTrail {
    private var smoothed: Double?
    private var marks: [(time: Double, heading: Double, travel: Double)] = []
    private var absorbedUpTo = -Double.infinity
    private var absorbedHeading = 0.0
    private var lastMark = -Double.infinity

    mutating func fastChange(heading: Double, time: Double, travel: Double, dt: Double, tuning: CompassTuning) -> Double {
        guard var current = smoothed else {
            smoothed = heading
            return 0
        }
        current += atan2(sin(heading - current), cos(heading - current)) * min(1, dt / tuning.smoothing)
        smoothed = current
        if time - lastMark >= 0.01 {
            marks.append((time, current, travel))
            lastMark = time
            let horizon = time - tuning.fastWindow - 0.05
            if let drop = marks.firstIndex(where: { $0.time >= horizon }), drop > 0 { marks.removeFirst(drop) }
        }
        guard let old = marks.first(where: { $0.time >= time - tuning.fastWindow }), time - old.time > tuning.fastWindow * 0.8 else { return 0 }
        let change = atan2(sin(current - old.heading), cos(current - old.heading))
        let turned = travel - old.travel
        guard turned < tuning.maxTravel, abs(change) > tuning.fastThreshold + tuning.fastThresholdPerTravel * turned else { return 0 }
        let base = absorbedUpTo >= old.time ? absorbedHeading : old.heading
        absorbedUpTo = time
        absorbedHeading = current
        return atan2(sin(current - base), cos(current - base))
    }
}

private enum Compass {
    static let maxFieldDeviation = 0.03
    static let maxDipDeviation = 5 * Double.pi / 180
    static let placeAdaptationSeconds = 30.0
    static let minHorizontalShare = 0.2
    static let proportionalGain = 1.0 / 4
    static let sectorSize = 15 * Double.pi / 180
    static let maxCorrectionRate = 0.5 * Double.pi / 180
    static let changedFieldStrength = 0.15
    static let changedFieldDip = 10 * Double.pi / 180
    static let restoredFieldStrength = 0.08
    static let restoredFieldDip = 6 * Double.pi / 180
}
