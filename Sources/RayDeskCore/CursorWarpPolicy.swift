import Foundation

/// Правило прыжка курсора к экрану, на который задержался взгляд.
///
/// Курсор прыгает не больше одного раза за каждый переход взгляда на экран:
/// после этого мышь двигается свободно, пока взгляд не перейдёт на другой экран.
public struct CursorWarpPolicy {
    public var dwell: TimeInterval
    private var observedScreen: Int?
    private var since: TimeInterval = 0
    private var arrivalHandled = false

    public init(dwell: TimeInterval = 0.2) {
        self.dwell = dwell
    }

    /// Фиксирует экран, на котором сейчас взгляд. Смена экрана сбрасывает отсчёт задержки
    /// и разрешает новый прыжок.
    public mutating func observeGaze(screen: Int?, at time: TimeInterval) {
        if screen != observedScreen {
            observedScreen = screen
            since = time
            arrivalHandled = false
        }
    }

    /// Экран, на который нужно перенести курсор при текущем движении мыши, либо `nil`.
    ///
    /// Первый вызов после задержки взгляда расходует переход взгляда: даже если курсор уже
    /// на этом экране, следующие вызовы вернут `nil` до смены экрана под взглядом.
    /// Вызов с зажатой кнопкой переход не расходует.
    ///
    /// - Parameters:
    ///   - cursorScreen: экран, на котором сейчас находится курсор (`nil`, если курсор не на виртуальном экране).
    ///   - buttonsDown: зажата ли хотя бы одна кнопка мыши.
    ///   - time: текущее время, секунды.
    public mutating func warpTarget(cursorScreen: Int?, buttonsDown: Bool, at time: TimeInterval) -> Int? {
        guard !buttonsDown, !arrivalHandled, let observedScreen, time - since >= dwell else { return nil }
        arrivalHandled = true
        return observedScreen == cursorScreen ? nil : observedScreen
    }
}
