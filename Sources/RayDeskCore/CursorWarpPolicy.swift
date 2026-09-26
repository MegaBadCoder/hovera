import Foundation

/// Правило прыжка курсора к экрану, на который задержался взгляд.
public struct CursorWarpPolicy {
    public var dwell: TimeInterval
    private var observedScreen: Int?
    private var since: TimeInterval = 0

    public init(dwell: TimeInterval = 0.2) {
        self.dwell = dwell
    }

    /// Фиксирует экран, на котором сейчас взгляд. Смена экрана сбрасывает отсчёт задержки.
    public mutating func observeGaze(screen: Int?, at time: TimeInterval) {
        if screen != observedScreen {
            observedScreen = screen
            since = time
        }
    }

    /// Экран, на который нужно перенести курсор, либо `nil`, если переносить не нужно.
    ///
    /// - Parameters:
    ///   - cursorScreen: экран, на котором сейчас находится курсор (`nil`, если курсор не на виртуальном экране).
    ///   - buttonsDown: зажата ли хотя бы одна кнопка мыши.
    ///   - time: текущее время.
    public func warpTarget(cursorScreen: Int?, buttonsDown: Bool, at time: TimeInterval) -> Int? {
        guard !buttonsDown else { return nil }
        guard let observedScreen else { return nil }
        guard time - since >= dwell else { return nil }
        guard observedScreen != cursorScreen else { return nil }
        return observedScreen
    }
}
