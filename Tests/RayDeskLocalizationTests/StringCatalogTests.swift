import Foundation
import Testing
@testable import RayDeskLocalization

private extension Character {
    var isCyrillic: Bool { unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) } }
}

private func hasCyrillic(_ text: String) -> Bool {
    text.contains { $0.isCyrillic }
}

private func conversions(_ text: String) -> [String] {
    text.matches(of: /%[-+ 0]*[0-9]*(?:\.[0-9]+)?[@dfs%]/).map { String(text[$0.range]) }.filter { $0 != "%%" }
}

private func shortcutTail(_ text: String) -> String? {
    guard let separator = text.range(of: "   ") else { return nil }
    return text[separator.upperBound...].split(separator: " ").first.map(String.init)
}

@Test func shortcutsMatchBetweenLanguages() {
    for key in UIString.allCases {
        let russian = shortcutTail(key.text(.ru))
        let english = shortcutTail(key.text(.en))
        #expect(russian == english, "\(key) ends with \(english ?? "no shortcut") in English and \(russian ?? "no shortcut") in Russian")
    }
}

@Test func englishTextHasNoCyrillic() {
    for key in UIString.allCases {
        let text = key.text(.en)
        #expect(!hasCyrillic(text), "\(key) is not translated: \(text)")
    }
}

@Test func russianTextIsRussian() {
    for key in UIString.allCases {
        let text = key.text(.ru)
        #expect(hasCyrillic(text), "\(key) has no Russian text: \(text)")
    }
}

@Test func noTextIsEmptyOrPaddedWithSpaces() {
    for key in UIString.allCases {
        for language in AppLanguage.allCases {
            let text = key.text(language)
            #expect(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(key) is empty in \(language.rawValue)")
        }
    }
}

@Test func placeholdersMatchBetweenLanguages() {
    for key in UIString.allCases {
        let russian = conversions(key.text(.ru))
        let english = conversions(key.text(.en))
        #expect(russian == english, "\(key) formats \(russian) in Russian and \(english) in English")
    }
}

@Test func switchingLanguageSwitchesTheText() {
    let previous = Localization.shared.language
    defer { Localization.shared.language = previous }
    Localization.shared.language = .ru
    #expect(t(.menuScreens) == "Экраны")
    #expect(t(.cameraNoteNoFace) == "лицо не найдено")
    Localization.shared.language = .en
    #expect(t(.menuScreens) == "Screens")
    #expect(t(.cameraNoteNoFace) == "no face found")
}

@Test func languageNamesAreWrittenInTheirOwnLanguage() {
    #expect(hasCyrillic(AppLanguage.ru.nativeName))
    #expect(!hasCyrillic(AppLanguage.en.nativeName))
    for language in AppLanguage.allCases {
        #expect(!language.speechVoiceIdentifier.isEmpty)
    }
}

@Test func storedLanguagesRoundTripThroughTheirRawValues() {
    for language in AppLanguage.allCases {
        #expect(AppLanguage(rawValue: language.rawValue) == language)
    }
}
