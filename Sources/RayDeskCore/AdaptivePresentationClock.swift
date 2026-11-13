/// Измеряет задержку представления отдельно для синхронного и несинхронного вывода.
public final class AdaptivePresentationClock: Sendable {
    private let synchronizedClock = PresentationClock()
    private let immediateClock = PresentationClock()

    public init() {}

    /// Возвращает ожидаемое время представления в монотонных секундах.
    /// - Parameters:
    ///   - now: время получения позы для кадра.
    ///   - displayTarget: заявленное дисплейным линком время представления в той же шкале.
    ///   - synchronized: режим вертикальной синхронизации этого кадра.
    /// - Returns: целевое время с измеренной поправкой соответствующего режима; до измерений — исходная цель.
    public func targetTime(now: Double, displayTarget: Double, synchronized: Bool) -> Double {
        let base = synchronized ? max(now, displayTarget) : now
        return clock(synchronized: synchronized).presentTime(target: base)
    }

    /// Добавляет время представления кадра, не смешивая измерения двух режимов.
    /// - Parameters:
    ///   - now: время получения позы, сохранённое при отправке этого кадра.
    ///   - displayTarget: исходная цель дисплейного линка без измеренной поправки.
    ///   - presented: `MTLDrawable.presentedTime` в монотонных секундах; нулевой или нечисловой отсчёт игнорируется.
    ///   - synchronized: режим, с которым отправлен именно этот кадр.
    public func observe(now: Double, displayTarget: Double, presented: Double, synchronized: Bool) {
        let base = synchronized ? max(now, displayTarget) : now
        clock(synchronized: synchronized).observe(target: base, presented: presented)
    }

    private func clock(synchronized: Bool) -> PresentationClock {
        synchronized ? synchronizedClock : immediateClock
    }
}
