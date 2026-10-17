import Foundation

/// Текущий язык интерфейса и выдача строк каталога на нём.
///
/// Строки спрашивают и с главного потока, и из очереди камерного трекинга, поэтому язык лежит под замком.
public final class Localization: @unchecked Sendable {
    public static let shared = Localization()

    private let lock = NSLock()
    private var stored: AppLanguage

    private init(language: AppLanguage = .systemPreferred) {
        stored = language
    }

    /// Язык интерфейса; смена видна всем последующим запросам строк.
    public var language: AppLanguage {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    /// Строка каталога на текущем языке.
    public func text(_ key: UIString) -> String {
        key.text(language)
    }
}

/// Строка интерфейса на текущем языке.
public func t(_ key: UIString) -> String {
    Localization.shared.text(key)
}
