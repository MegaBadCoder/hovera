import Foundation
import simd

/// Учит смещение нуля гироскопа в моменты, когда голова неподвижна.
///
/// Покой определяется по разбросу сырых показаний за окно, а не по отличию от текущей
/// оценки, поэтому учитель не может «заблокироваться». С магнитометром окно покоя
/// принимается с задержкой, только если сырое поле в осях очков стояло на месте и до него,
/// и после (всего `fieldHistoryWindows` окон вокруг) — тогда голова точно не вращалась, и
/// принимаются даже большие скачки нуля (после поправки очков), а начало и хвост медленного
/// поворота отбрасываются.
/// Без магнитометра окно принимается сразу, но только в пределах `gate`: медленнее этого
/// повороты головы неотличимы от смещения нуля. Магнитометр калибровать не нужно.
public struct StillnessBiasLearner {
    /// Длина окна усреднения, секунды.
    public static let windowSeconds = 0.5
    /// Наибольший разброс угловой скорости по любой оси внутри окна покоя, рад/с.
    public static let maxRateSpread = 1.2 * Double.pi / 180
    /// Наибольший разброс модуля ускорения внутри окна покоя, g.
    public static let maxAccelSpread = 0.02
    /// Наибольшее изменение нуля за шаг без подтверждения магнитометром, рад/с.
    public static let gate = 1.2 * Double.pi / 180
    /// Наибольшее изменение нуля за шаг, когда магнитометр подтверждает покой, рад/с.
    public static let confirmedGate = 2.0 * Double.pi / 180
    /// Сколько после `trustNextStillness()` окна покоя принимаются без подтверждения полем, секунды.
    public static let trustingSeconds = 30.0
    /// Постоянная времени обучения, секунды.
    public static let learningSeconds = 3.0
    /// Сколько окон вокруг окна покоя (поровну до и после) магнитометр проверяет на неподвижность поля.
    public static let fieldHistoryWindows = 16
    /// Наибольший сдвиг сырого поля в этих окнах, при котором окно считается покоем, сырые единицы.
    public static let maxFieldChange = 0.5

    /// Текущая оценка смещения нуля по осям тела, рад/с.
    public private(set) var bias: SIMD3<Double>

    var fieldWindows = StillnessBiasLearner.fieldHistoryWindows
    var fieldThreshold = StillnessBiasLearner.maxFieldChange
    var uncheckedGate = StillnessBiasLearner.gate
    var usesField = true

    private var trustingLeft = 0.0
    private var elapsed = 0.0
    private var count = 0
    private var gyroSum = SIMD3<Double>(repeating: 0)
    private var gyroSquares = SIMD3<Double>(repeating: 0)
    private var accelSum = 0.0
    private var accelSquares = 0.0
    private var fieldSum = SIMD3<Double>(repeating: 0)
    private var fieldCount = 0
    private var pending: [Window] = []

    /// - Parameter bias: начальная оценка, например сохранённая с прошлого запуска, рад/с.
    public init(bias: SIMD3<Double> = SIMD3(repeating: 0)) {
        self.bias = bias
    }

    /// На `trustingSeconds` принимает любое спокойное окно без подтверждения полем, в пределах
    /// `confirmedGate`. Вызывать, когда пользователь заведомо неподвижен и смотрит в точку
    /// (он только что задал «вперёд» после того, как экраны уехали — обычно после поправки очков).
    public mutating func trustNextStillness() {
        trustingLeft = StillnessBiasLearner.trustingSeconds
    }

    /// Добавляет отсчёт IMU.
    ///
    /// - Parameters:
    ///   - gyro: сырая угловая скорость по осям тела, рад/с.
    ///   - accelNorm: модуль ускорения, g.
    ///   - magnetometer: сырое поле по осям тела или `nil`, если в отсчёте его нет.
    ///   - dt: время с прошлого отсчёта, секунды.
    public mutating func add(gyro: SIMD3<Double>, accelNorm: Double, magnetometer: SIMD3<Double>?, dt: Double) {
        count += 1
        gyroSum += gyro
        gyroSquares += gyro * gyro
        accelSum += accelNorm
        accelSquares += accelNorm * accelNorm
        if let magnetometer {
            fieldSum += magnetometer
            fieldCount += 1
        }
        elapsed += dt
        trustingLeft = max(0, trustingLeft - dt)
        guard elapsed >= StillnessBiasLearner.windowSeconds else { return }
        defer { startWindow() }

        let n = Double(count)
        let mean = gyroSum / n
        let spread = simd_max(gyroSquares / n - mean * mean, SIMD3(repeating: 0)).squareRoot()
        let accelMean = accelSum / n
        let accelSpread = max(0, accelSquares / n - accelMean * accelMean).squareRoot()
        let quiet = spread.max() < StillnessBiasLearner.maxRateSpread && accelSpread < StillnessBiasLearner.maxAccelSpread

        if trustingLeft > 0 {
            pending.removeAll()
            if quiet { learn(mean, gate: StillnessBiasLearner.confirmedGate) }
            return
        }
        guard fieldCount > 0, usesField else {
            pending.removeAll()
            if quiet { learn(mean, gate: uncheckedGate) }
            return
        }
        pending.append(Window(rate: mean, field: fieldSum / Double(fieldCount), quiet: quiet))
        guard pending.count > fieldWindows else { return }
        let candidate = pending[fieldWindows / 2]
        let fieldStood = pending.allSatisfy { length($0.field - candidate.field) < fieldThreshold }
        if candidate.quiet, fieldStood {
            learn(candidate.rate, gate: StillnessBiasLearner.confirmedGate)
        }
        pending.removeFirst()
    }

    private struct Window {
        var rate: SIMD3<Double>
        var field: SIMD3<Double>
        var quiet: Bool
    }

    private mutating func learn(_ rate: SIMD3<Double>, gate: Double) {
        guard abs(rate - bias).max() < gate else { return }
        bias += (rate - bias) * min(1, StillnessBiasLearner.windowSeconds / StillnessBiasLearner.learningSeconds)
    }

    private mutating func startWindow() {
        elapsed = 0
        count = 0
        gyroSum = SIMD3(repeating: 0)
        gyroSquares = SIMD3(repeating: 0)
        accelSum = 0
        accelSquares = 0
        fieldSum = SIMD3(repeating: 0)
        fieldCount = 0
    }
}
