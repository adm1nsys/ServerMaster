//
//  TranslationPack.swift
//  ServerMaster
//
//  Translations as a file you can take out, edit and put back.
//
//  The bundled translation is a starting point, not the last word: it is written
//  by whoever built the app, and the person using it usually knows the wording
//  of their own field better. So a pack can be exported, edited in any text
//  editor, and imported again — and an imported pack wins over the bundled one.
//
//  A pack records which version of the app it was made for. Strings are added
//  and reworded between releases, so a pack made for an older one is not wrong
//  exactly — it will simply be missing the new strings, and may translate ones
//  that have since changed meaning. That is worth saying out loud rather than
//  letting someone wonder why half a screen is in English.
//
//  The format is the plain `.strings` one macOS has always used: "key" = "value";
//  It opens in any editor, and there is nothing to learn.
//

import Foundation

nonisolated struct TranslationPack: Sendable {

    /// Locale code: the pack replaces the translation for this language.
    var language: String
    /// The app version this pack was written against.
    var appVersion: String
    /// The pack's own version, so someone can track their edits.
    var packVersion: String
    var strings: [String: String]

    /// Whether this pack was made for the app it is loaded into.
    var matchesApp: Bool { appVersion == AppInfo.version }

    var summary: String {
        String(localized: "\(strings.count) strings · for ServerMaster \(appVersion)")
    }
}

@Observable
final class TranslationStore {

    /// Packs the person has imported, by language code.
    private(set) var installed: [String: TranslationPack] = [:]

    /// Where imported packs live. Beside the rest of the app's data rather than
    /// inside the bundle: the bundle is replaced wholesale on every update.
    static var folder: URL { AppPaths.subdir("Translations") }

    init() { reload() }

    func pack(for language: String) -> TranslationPack? { installed[language] }

    /// A pack for a language the app does not match. Nil when everything lines
    /// up, so the caller can show a warning only when there is one to show.
    var mismatched: TranslationPack? {
        installed.values.first { !$0.matchesApp }
    }

    func reload() {
        var found: [String: TranslationPack] = [:]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Self.folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "strings" {
            guard let pack = Self.read(file) else { continue }
            found[pack.language] = pack
        }
        installed = found
    }

    // MARK: - Reading and writing

    /// The header carries what the strings file itself cannot: which language
    /// the pack is for and which app version it was written against. Kept as
    /// comments so the file stays a valid `.strings` and opens anywhere.
    private static func header(_ pack: TranslationPack) -> String {
        """
        /* ServerMaster translation pack
           Language: \(pack.language)
           App version: \(pack.appVersion)
           Pack version: \(pack.packVersion)

           Edit the right-hand side only. The left-hand side is the key the app
           looks up — change it and the line stops being found.

           Anything left out falls back to the bundled translation, and then to
           English. A partial pack is fine. */

        """
    }

    static func read(_ url: URL) -> TranslationPack? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let data = text.data(using: .utf8) else { return nil }

        // PropertyListSerialization and not NSDictionary(contentsOf:): the second
        // one wants a real plist, while a .strings file is the old-style format
        // — bare "key" = "value"; lines with no enclosing braces. The serializer
        // reads that; the convenience initialiser quietly returns nil.
        guard let table = try? PropertyListSerialization.propertyList(
                from: data, format: nil) as? [String: String],
              !table.isEmpty else { return nil }

        func field(_ name: String) -> String? {
            guard let range = text.range(of: "\(name): ") else { return nil }
            let rest = text[range.upperBound...]
            var value = String(rest.prefix { !$0.isNewline })
            // The last header line ends the comment, so "2.0 */" arrives where
            // "2.0" was meant — and the version then never matches anything.
            if let end = value.range(of: "*/") { value = String(value[..<end.lowerBound]) }
            return value.trimmingCharacters(in: .whitespaces)
        }
        // The language falls back to the file's own name, so a pack someone
        // renamed to uk.strings still lands in the right place.
        let language = field("Language") ?? url.deletingPathExtension().lastPathComponent
        return TranslationPack(language: language,
                               appVersion: field("App version") ?? String(localized: "unknown"),
                               packVersion: field("Pack version") ?? "1",
                               strings: table)
    }

    /// Writes a pack out for editing: every key the app knows, with whatever
    /// translation exists today — so the file is a starting point rather than an
    /// empty form.
    @discardableResult
    static func export(language: String, to url: URL) -> Bool {
        let strings = bundledStrings(for: language)
        let pack = TranslationPack(language: language,
                                   appVersion: AppInfo.version,
                                   packVersion: "1",
                                   strings: strings)

        var text = header(pack)
        for key in strings.keys.sorted() {
            let value = strings[key] ?? key
            text += "\"\(escape(key))\" = \"\(escape(value))\";\n"
        }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    enum ImportResult {
        case installed(TranslationPack)
        case notAStringsFile
        case couldNotSave(String)
    }

    func importPack(from url: URL) -> ImportResult {
        guard let pack = Self.read(url), !pack.strings.isEmpty else {
            return .notAStringsFile
        }
        let destination = Self.folder.appendingPathComponent("\(pack.language).strings")
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: url, to: destination)
            reload()
            return .installed(pack)
        } catch {
            return .couldNotSave(error.localizedDescription)
        }
    }

    func remove(language: String) {
        try? FileManager.default.removeItem(
            at: Self.folder.appendingPathComponent("\(language).strings"))
        reload()
    }

    // MARK: - What the app already has

    /// Every key the app knows, with the bundled translation where there is one.
    static func bundledStrings(for language: String) -> [String: String] {
        guard let path = Bundle.main.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path),
              let file = bundle.path(forResource: "Localizable", ofType: "strings"),
              let table = NSDictionary(contentsOfFile: file) as? [String: String]
        else { return [:] }
        return table
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}

// MARK: - Making an imported pack actually win

/// A Bundle that answers from the imported pack first.
///
/// `String(localized:)` ends up at `Bundle.main.localizedString(forKey:…)`, so
/// the only way to put something in front of the bundled translation is to give
/// `Bundle.main` a class that answers differently. Swapping the class of that
/// one object is the documented way to do it and is what every app offering an
/// in-app language switch does.
private final class OverridingBundle: Bundle, @unchecked Sendable {

    override func localizedString(forKey key: String, value: String?, table: String?) -> String {
        if let translated = TranslationOverride.shared.lookup(key) { return translated }
        return super.localizedString(forKey: key, value: value, table: table)
    }
}

/// The strings an imported pack provides, for the language in use.
nonisolated final class TranslationOverride: @unchecked Sendable {

    static let shared = TranslationOverride()

    private var strings: [String: String] = [:]
    private let lock = NSLock()

    /// Installs the override. Called once, before any view is built.
    static func install() {
        object_setClass(Bundle.main, OverridingBundle.self)
        shared.refresh()
    }

    /// Reloads from disk for whichever language the app is showing.
    func refresh() {
        let code = Bundle.main.preferredLocalizations.first ?? "en"
        let file = TranslationStore.folder.appendingPathComponent("\(code).strings")
        let table = (NSDictionary(contentsOf: file) as? [String: String]) ?? [:]
        lock.lock(); strings = table; lock.unlock()
    }

    func lookup(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        // An empty value means "not translated" rather than "translated to
        // nothing" — an empty line in a hand-edited pack should not blank the
        // interface.
        guard let value = strings[key], !value.isEmpty else { return nil }
        return value
    }
}
