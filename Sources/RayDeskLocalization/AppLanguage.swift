import Foundation

/// Язык интерфейса приложения.
public enum AppLanguage: String, CaseIterable, Sendable {
    case ru
    case en

    /// Название языка на нём самом: пункт выбора языка не переводят на другой язык.
    public var nativeName: String {
        switch self {
        case .ru: "Русский"
        case .en: "English"
        }
    }

    /// Язык, выбранный в системе: русский — только если он первый в списке предпочтений.
    public static var systemPreferred: AppLanguage {
        Locale.preferredLanguages.first?.hasPrefix("ru") == true ? .ru : .en
    }
}
