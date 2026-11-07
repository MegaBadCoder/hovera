import Foundation
import simd

/// Считает увод мира по позе и угловой скорости: сколько градусов в минуту
/// набегает, пока голова стоит.
///
/// Увод не виден в отдельном отсчёте позы — он проявляется только на отрезке
/// времени, когда угловая скорость тела близка к нулю. Поэтому метры копят
/// измерение лишь в такие отрезки, а в движении сбрасывают окно.
public struct PoseDriftMeter: Sendable {
    /// Угловая скорость, ниже которой отсчёт считается покоем, рад/с.
    public var stillSpeed = 3 * Double.pi / 180
    /// Сколько нужно стоять неподвижно, чтобы увод считался измеренным, секунды.
    public var settleTime = 3.0
    /// Длина окна измерения, секунды.
    public var window = 30.0

    private var stillSince: Double?
    private var first: (time: Double, yaw: Double, pitch: Double, roll: Double)?
    private var last: (time: Double, yaw: Double, pitch: Double, roll: Double)?

    public init() {}

    /// Добавляет отсчёт.
    ///
    /// - Parameters:
    ///   - time: время отсчёта, секунды, монотонная шкала.
    ///   - yaw: курс в градусах.
    ///   - pitch: наклон в градусах.
    ///   - roll: крен в градусах.
    ///   - angularSpeed: угловая скорость головы, рад/с.
    public mutating func add(time: Double, yaw: Double, pitch: Double, roll: Double, angularSpeed: Double) {
        guard angularSpeed.isFinite, angularSpeed < stillSpeed else {
            stillSince = nil
            first = nil
            last = nil
            return
        }
        if stillSince == nil { stillSince = time }
        guard let since = stillSince, time - since >= settleTime else { return }
        if let first, let last, time - first.time <= window {
            self.last = (time, yaw, pitch, roll)
            _ = last
        } else {
            first = (time, yaw, pitch, roll)
            last = (time, yaw, pitch, roll)
        }
    }

    /// Увод в градусах в минуту по осям; `nil`, пока не накопилось окно измерения.
    public var driftPerMinute: (yaw: Double, pitch: Double, roll: Double)? {
        guard let first, let last else { return nil }
        let span = last.time - first.time
        guard span >= 5 else { return nil }
        let scale = 60 / span
        return ((last.yaw - first.yaw) * scale, (last.pitch - first.pitch) * scale, (last.roll - first.roll) * scale)
    }

    /// Длительность текущего окна измерения, секунды.
    public var measuredSpan: Double {
        guard let first, let last else { return 0 }
        return last.time - first.time
    }
}
