import Foundation

/// Правило прыжка курсора к цели (панели или экрану Mac), на которой задержался взгляд.
///
/// Курсор прыгает не больше одного раза за каждый переход взгляда на цель:
/// после этого мышь двигается свободно, пока взгляд не перейдёт на другую цель.
public struct CursorWarpPolicy {
    public var dwell: TimeInterval
    private var observedTarget: CursorTarget?
    private var since: TimeInterval = 0
    private var arrivalHandled = false

    public init(dwell: TimeInterval = 0.2) {
        self.dwell = dwell
    }

    /// Фиксирует цель, на которую сейчас смотрит пользователь. Смена цели сбрасывает отсчёт задержки
    /// и разрешает новый прыжок.
    public mutating func observeGaze(target: CursorTarget?, at time: TimeInterval) {
        if target != observedTarget {
            observedTarget = target
            since = time
            arrivalHandled = false
        }
    }

    /// Цель, на которую нужно перенести курсор при текущем движении мыши, либо `nil`.
    ///
    /// Первый вызов после задержки взгляда расходует переход взгляда: даже если курсор уже
    /// на этой цели, следующие вызовы вернут `nil` до смены цели под взглядом.
    /// Вызов с зажатой кнопкой переход не расходует.
    ///
    /// - Parameters:
    ///   - cursor: где сейчас курсор (`nil` — ни на панели, ни на экране Mac).
    ///   - buttonsDown: зажата ли хотя бы одна кнопка мыши.
    ///   - time: текущее время, секунды.
    public mutating func warpTarget(cursor: CursorTarget?, buttonsDown: Bool, at time: TimeInterval) -> CursorTarget? {
        guard !buttonsDown, !arrivalHandled, let observedTarget, time - since >= dwell else { return nil }
        arrivalHandled = true
        return observedTarget == cursor ? nil : observedTarget
    }
}
