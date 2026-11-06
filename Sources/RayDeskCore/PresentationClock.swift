import Foundation

/// Поправка между заявленным временем кадра и моментом, когда кадр показан.
///
/// Дисплейному линку известен только заявленный момент (`CADisplayLink.targetTimestamp`):
/// когда система собирается показать кадр. Фактическое время показа сообщает Metal в
/// `MTLDrawable.presentedHandler`. Разница между ними — та задержка, которую надо
/// предсказывать в ориентации, чтобы картинка совпала с головой.
///
/// Измерения приходят с фонового потока Metal, поэтому класс потокобезопасен.
public final class PresentationClock: @unchecked Sendable {
    /// Наибольшая поправка, которая принимается в расчёт, секунды.
    public let maxOffset: Double
    /// Доля нового измерения в сглаженной поправке.
    public let smoothing: Double

    private let lock = NSLock()
    private var measured: Double?

    /// - Parameters:
    ///   - maxOffset: потолок поправки, секунды.
    ///   - smoothing: доля нового измерения в сглаженной поправке, 0…1.
    public init(maxOffset: Double = 0.030, smoothing: Double = 0.1) {
        self.maxOffset = maxOffset
        self.smoothing = smoothing
    }

    /// Сглаженная поправка, секунды; `nil`, пока не пришло ни одного измерения.
    public var offset: Double? {
        lock.lock()
        defer { lock.unlock() }
        return measured
    }

    /// Добавляет измерение.
    ///
    /// - Parameters:
    ///   - target: время, на которое кадр заявлял дисплейный линк, секунды.
    ///   - presented: время, в которое кадр фактически показан, секунды.
    public func observe(target: Double, presented: Double) {
        guard target.isFinite, presented.isFinite else { return }
        let sample = min(maxOffset, max(0, presented - target))
        lock.lock()
        measured = measured.map { $0 + (sample - $0) * smoothing } ?? sample
        lock.unlock()
    }

    /// Время, к которому кадр будет показан, если его начать рисовать на `target`.
    ///
    /// Пока измерений не было, возвращает `target`: поведение без измерения.
    public func presentTime(target: Double) -> Double {
        target + (offset ?? 0)
    }
}
