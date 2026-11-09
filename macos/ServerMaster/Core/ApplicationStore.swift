import Foundation

/// Disk-only startup state, shared by the application and isolated first-run
/// tests. A persisted empty profile list is intentional, not a missing file.
nonisolated struct ApplicationStore {
    let directory: URL
    var settingsFile: URL { directory.appendingPathComponent("settings.json") }
    var profilesFile: URL { directory.appendingPathComponent("profiles.json") }
    private var setupFile: URL { directory.appendingPathComponent("first-setup.json") }

    struct Loaded {
        var settings: AppSettings
        var profiles: [ServerProfile]
        var needsFirstSetup: Bool
        var errors: [String]
    }

    func load(starter: () -> [ServerProfile]) -> Loaded {
        let fm = FileManager.default
        let existedSettings = fm.fileExists(atPath: settingsFile.path)
        let existedProfiles = fm.fileExists(atPath: profilesFile.path)
        let fresh = !existedSettings && !existedProfiles
        let completed = (try? Data(contentsOf: setupFile)).flatMap { try? JSONDecoder().decode(Bool.self, from: $0) }
        // Save the pending choice BEFORE starter files, so interruption during
        // the splash does not silently consume the first-run experience.
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var settings = AppSettings()
        var profiles: [ServerProfile] = []
        var errors: [String] = []
        if fresh && completed == nil {
            do { try finishFirstSetup(false) } catch { errors.append(error.localizedDescription) }
        }
        var settingsReadable = !existedSettings
        if existedSettings {
            if let data = try? Data(contentsOf: settingsFile), let value = try? decoder.decode(AppSettings.self, from: data) {
                settings = value; settingsReadable = true
            } else { errors.append(String(localized: "Settings could not be read. The existing file was preserved.")) }
        }
        if existedProfiles {
            if let data = try? Data(contentsOf: profilesFile), let value = try? decoder.decode([ServerProfile].self, from: data) {
                profiles = value
            } else { errors.append(String(localized: "Profiles could not be read. The existing file was preserved.")) }
        } else {
            profiles = starter()
            settings.defaultProfileID = profiles.first?.id
            do { try save(profiles, to: profilesFile) } catch { errors.append(error.localizedDescription) }
        }
        let defaults = AppSettings()
        var migrated = false
        if settings.updateRepository.isEmpty { settings.updateRepository = defaults.updateRepository; migrated = true }
        if settings.updateVersionFile.isEmpty || settings.updateVersionFile == "lastversion.txt" {
            settings.updateVersionFile = defaults.updateVersionFile; migrated = true
        }
        if settingsReadable && (!existedSettings || migrated || !existedProfiles) {
            do { try save(settings, to: settingsFile) } catch { errors.append(error.localizedDescription) }
        }
        return Loaded(settings: settings, profiles: profiles, needsFirstSetup: !(completed ?? !fresh), errors: errors)
    }

    func finishFirstSetup(_ completed: Bool = true) throws { try save(completed, to: setupFile) }

    func save<Value: Codable>(_ value: Value, to file: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        if FileManager.default.fileExists(atPath: file.path) {
            let previous = try Data(contentsOf: file)
            if (try? decoder.decode(Value.self, from: previous)) == nil {
                // Later explicit saves/quit must not erase evidence of a damaged
                // file that was deliberately preserved during startup.
                try previous.write(to: file.appendingPathExtension("unreadable-\(UUID().uuidString).bak"), options: .atomic)
            }
        }
        try encoder.encode(value).write(to: file, options: .atomic)
    }
}
