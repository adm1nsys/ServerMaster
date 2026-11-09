import Foundation
import CoreFoundation

/// Portable data only. Import never starts a server or rewrites foreign paths.
nonisolated enum ProfileTransfer {
    enum Failure: LocalizedError {
        case invalid, tooLarge, unsupportedEngine(String)
        var errorDescription: String? {
            switch self {
            case .invalid: return String(localized: "This file does not contain valid ServerMaster profiles. Nothing was imported.")
            case .tooLarge: return String(localized: "The profile file is too large.")
            case .unsupportedEngine(let engine): return String(localized: "The profile uses an unsupported server engine: \(engine). Nothing was imported.")
            }
        }
    }

    static func read(_ url: URL) throws -> [ServerProfile] {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 8 * 1024 * 1024 else { throw Failure.tooLarge }
        return try decode(Data(contentsOf: url))
    }

    static func decode(_ data: Data) throws -> [ServerProfile] {
        guard data.count <= 8 * 1024 * 1024 else { throw Failure.tooLarge }
        let object = try JSONSerialization.jsonObject(with: data)
        let rows: [[String: Any]]
        if let array = object as? [[String: Any]] { rows = array }
        else if let single = object as? [String: Any] { rows = [single] }
        else { throw Failure.invalid }
        guard !rows.isEmpty else { throw Failure.invalid }
        let strings = ["name", "rootPath", "workingDirectory", "configPath", "databaseName", "templateId", "profileColor",
                       "certificatePath", "privateKeyPath", "basicAuthUser", "basicAuthPassword", "indexFile", "nodeEntryFile",
                       "configPreset", "customCommand", "customArguments", "extraArguments", "phpVersion", "phpMemoryLimit",
                       "phpUploadMaxFilesize", "errorPageAccent", "errorPageFooter", "notes", "host"]
        let bools = ["needsDatabase", "httpsEnabled", "enableCors", "enableCORS", "enableGzip", "directoryListing", "spaFallback",
                     "basicAuthEnabled", "runAsAdministrator", "hideDotfiles", "securityHeaders", "hstsEnabled", "customErrorPages",
                     "phpDisplayErrors", "openBrowserOnStart"]
        for row in rows {
            guard let name = row["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let engine = row["engine"] as? String else { throw Failure.invalid }
            guard ServerEngine(rawValue: engine) != nil else { throw Failure.unsupportedEngine(engine) }
            for key in strings where row[key] != nil { guard row[key] is String else { throw Failure.invalid } }
            for key in bools where row[key] != nil {
                guard let number = row[key] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw Failure.invalid }
            }
            for key in ["port", "cacheSeconds", "phpMaxExecutionTime"] where row[key] != nil {
                guard let number = row[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
                      number.doubleValue >= Double(Int32.min), number.doubleValue <= Double(Int32.max) else { throw Failure.invalid }
                if key == "port", !(1...65535).contains(number.intValue) { throw Failure.invalid }
            }
            if let id = row["id"] { guard let text = id as? String, UUID(uuidString: text) != nil else { throw Failure.invalid } }
            if let raw = row["environment"] {
                guard let entries = raw as? [[String: Any]] else { throw Failure.invalid }
                for entry in entries {
                    guard entry["key"] is String, entry["value"] is String else { throw Failure.invalid }
                    if let id = entry["id"] { guard let text = id as? String, UUID(uuidString: text) != nil else { throw Failure.invalid } }
                }
            }
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        do { return try decoder.decode([ServerProfile].self, from: JSONSerialization.data(withJSONObject: rows)) }
        catch { throw Failure.invalid }
    }

    static func data(_ profiles: [ServerProfile]) throws -> Data {
        guard !profiles.isEmpty else { throw Failure.invalid }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(profiles)
    }

    static func appending(_ incoming: [ServerProfile], to existing: [ServerProfile]) -> [ServerProfile] {
        var ids = Set(existing.map(\.id))
        return incoming.map { original in
            var profile = original
            while !ids.insert(profile.id).inserted { profile.id = UUID() }
            return profile
        }
    }
}
