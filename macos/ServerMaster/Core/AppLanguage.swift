//
//  AppLanguage.swift
//  ServerMaster
//
//  The language registry. This is the only place where the supported languages
//  are listed; the translations themselves live in separate <code>.lproj/Localizable.strings files.
//
//  The source language is English: the strings in the code are written in English,
//  so it has no .lproj of its own and does not need one.
//  The translation key is the English text from the code.
//
//  To add a language:
//    1. Append it to `supported` here.
//    2. Drop in ServerMaster/<code>.lproj/Localizable.strings.
//    3. Add the code to knownRegions in project.pbxproj.
//

import Foundation

nonisolated struct LanguageEntry: Identifiable, Sendable, Hashable {
    /// The locale code: en, de, fr, da, ja.
    var code: String
    /// The name in the language itself — clearer for the user.
    var nativeName: String
    /// The English name, for internal lists.
    var englishName: String
    /// The application's source language: the translation keys are written in it.
    var isSource: Bool = false

    var id: String { code }

    /// Whether a translation file is present in the bundle. The source language has
    /// no file: the strings in the code are already written in it.
    var isBundled: Bool {
        isSource || Bundle.main.path(forResource: code, ofType: "lproj") != nil
    }
}

nonisolated enum AppLanguage {

    /// The languages the application offers to the user.
    ///
    /// English is the source language, so it has no translation file of its own;
    /// every other entry needs its `.lproj` present in the bundle to show up.
    static let supported: [LanguageEntry] = [
        LanguageEntry(code: "en", nativeName: "English", englishName: "English", isSource: true),
        LanguageEntry(code: "de", nativeName: "Deutsch", englishName: "German"),
        LanguageEntry(code: "fr", nativeName: "Français", englishName: "French"),
        LanguageEntry(code: "da", nativeName: "Dansk", englishName: "Danish"),
        LanguageEntry(code: "ja", nativeName: "日本語", englishName: "Japanese")
    ]

    /// Only those whose translation is actually present in the bundle.
    static var available: [LanguageEntry] {
        supported.filter(\.isBundled)
    }

    static func entry(for code: String) -> LanguageEntry? {
        supported.first { $0.code == code }
    }

    /// The “match the system” value in the settings list.
    static let systemCode = ""

    /// What will actually be applied: the language the system picks from those available.
    static var effective: LanguageEntry? {
        guard let code = Bundle.main.preferredLocalizations.first else { return nil }
        return entry(for: code)
    }

    /// The name for the list: “English”, “Deutsch” and so on.
    static func title(for code: String) -> String {
        guard let entry = entry(for: code) else {
            return String(localized: "Match the system")
        }
        return entry.nativeName == entry.englishName
            ? entry.nativeName
            : "\(entry.nativeName) — \(entry.englishName)"
    }

    /// The language override lives in UserDefaults and is picked up at launch.
    static func apply(_ code: String) {
        let defaults = UserDefaults.standard
        if code.isEmpty {
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set([code], forKey: "AppleLanguages")
        }
        defaults.synchronize()
    }
}
