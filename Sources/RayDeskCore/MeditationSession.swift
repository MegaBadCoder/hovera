import Foundation

/// Плавный переход между работой с экранами и режимом медитации.
public struct MeditationTransition: Sendable {
    /// Длительность полного перехода в одну сторону, секунды.
    public static let seconds = 3.0

    /// `true`, если режим медитации включён (переход может ещё идти).
    public private(set) var isActive = false
    /// Линейная доля перехода: 0 — экраны, 1 — только космос.
    public private(set) var progress = 0.0

    public init() {}

    /// Доля перехода со сглаживанием на концах (smoothstep), 0…1: сколько неба видно
    /// и насколько погасли экраны.
    public var eased: Double {
        progress * progress * (3 - 2 * progress)
    }

    /// Включает или выключает режим; переход продолжается с текущего места.
    public mutating func toggle() {
        isActive.toggle()
    }

    /// Продвигает переход на прошедшее время.
    ///
    /// - Parameter seconds: время с прошлого вызова, секунды.
    public mutating func advance(by seconds: Double) {
        let step = seconds / Self.seconds
        progress = isActive ? min(1, progress + step) : max(0, progress - step)
    }
}

/// Ритм дыхания для светящегося кольца: вдох 4 с, выдох 6 с.
public enum Breathing {
    /// Длительность вдоха, секунды.
    public static let inhaleSeconds = 4.0
    /// Длительность выдоха, секунды.
    public static let exhaleSeconds = 6.0

    /// Насколько раскрыто кольцо в момент времени: 0 — выдохнуто, 1 — вдохнуто.
    /// Внутри вдоха и выдоха меняется по полуволне косинуса, без рывков на стыках.
    ///
    /// - Parameter time: время с начала дыхания, секунды.
    public static func openness(at time: Double) -> Double {
        let period = inhaleSeconds + exhaleSeconds
        let phase = time.truncatingRemainder(dividingBy: period)
        let wrapped = phase < 0 ? phase + period : phase
        if wrapped < inhaleSeconds {
            return 0.5 - 0.5 * cos(.pi * wrapped / inhaleSeconds)
        }
        return 0.5 + 0.5 * cos(.pi * (wrapped - inhaleSeconds) / exhaleSeconds)
    }
}
