import Foundation

/// Самообучение компенсации дрейфа направления «вперёд» по поправкам пользователя.
///
/// Каждая поправка (⌃⌥R) — замер ошибки направления после того, как голова
/// повернулась на известный суммарный угол. Нажатия, идущие подряд с интервалом
/// не больше `burstGap`, считаются одним прицеливанием. Коэффициент — доля
/// накопленного поворота головы, на которую уплывает направление «вперёд».
public struct DriftLearner {
    /// Интервал между нажатиями, в пределах которого они считаются одним прицеливанием, секунды.
    public static let burstGap: TimeInterval = 4
    /// Минимальный поворот головы между прицеливаниями, при котором замер учитывается, радианы.
    public static let minTravel = 200 * Double.pi / 180
    /// Демпфирование шага обучения: чем больше поворот в замере, тем сильнее он влияет, радианы.
    public static let dampingTravel = 2000 * Double.pi / 180
    /// Предел модуля коэффициента.
    public static let maxCoefficient = 0.02

    /// Текущий коэффициент: на сколько радиан уплывает «вперёд» на радиан поворота головы.
    public private(set) var coefficient: Double

    private var anchorTravel: Double?
    private var burst: (correction: Double, startTravel: Double, lastTravel: Double, lastTime: TimeInterval)?

    public init(coefficient: Double) {
        self.coefficient = coefficient
    }

    /// Регистрирует одно нажатие поправки.
    ///
    /// - Parameters:
    ///   - yaw: на сколько повёрнут мир этой поправкой, радианы.
    ///   - time: момент нажатия, секунды.
    ///   - travel: накопленный поворот головы `RotationTravel.total` в момент нажатия, радианы.
    public mutating func recordCorrection(yaw: Double, at time: TimeInterval, travel: Double) {
        if var current = burst, time - current.lastTime <= DriftLearner.burstGap {
            current.correction += yaw
            current.lastTravel = travel
            current.lastTime = time
            burst = current
        } else {
            _ = finishBurst()
            burst = (yaw, travel, travel, time)
        }
    }

    /// Завершает прицеливание, если после последнего нажатия прошло больше `burstGap`.
    ///
    /// - Returns: `true`, если по завершённому прицеливанию обновлён `coefficient`.
    public mutating func settle(at time: TimeInterval) -> Bool {
        guard let current = burst, time - current.lastTime > DriftLearner.burstGap else { return false }
        return finishBurst()
    }

    private mutating func finishBurst() -> Bool {
        guard let current = burst else { return false }
        burst = nil
        defer { anchorTravel = current.lastTravel }
        guard let anchorTravel else { return false }
        let travelled = current.startTravel - anchorTravel
        guard travelled >= DriftLearner.minTravel else { return false }
        let error = -current.correction
        coefficient += error / (travelled + DriftLearner.dampingTravel)
        coefficient = min(DriftLearner.maxCoefficient, max(-DriftLearner.maxCoefficient, coefficient))
        return true
    }
}
