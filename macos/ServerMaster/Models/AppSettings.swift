//
//  AppSettings.swift
//  ServerMaster
//

import Foundation

nonisolated enum KillSignal: String, Codable, CaseIterable, Identifiable, Sendable {
    case term = "TERM"
    case int  = "INT"
    case kill = "KILL"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .term: return String(localized: "SIGTERM (graceful)")
        case .int:  return "SIGINT (Ctrl-C)"
        case .kill: return String(localized: "SIGKILL (forceful)")
        }
    }
    var number: Int32 {
        switch self {
        case .term: return SIGTERM
        case .int:  return SIGINT
        case .kill: return SIGKILL
        }
    }
}

nonisolated enum TerminalApp: String, Codable, CaseIterable, Identifiable, Sendable {
    case terminal = "Terminal"
    case iterm    = "iTerm"
    case warp     = "Warp"
    case ghostty  = "Ghostty"

    var id: String { rawValue }
    var bundleName: String { rawValue }
}

nonisolated struct AppSettings: Codable, Sendable, Equatable {

    // Profiles
    var defaultProfileID: UUID? = nil
    var autostartDefaultProfile: Bool = false
    var restoreLastSection: Bool = true
    var lastSection: String = "control"
    var lastSelectedProfileID: UUID? = nil

    // Server behaviour
    var openBrowserOnStart: Bool = false
    var stopServerOnQuit: Bool = true
    var confirmBeforeStop: Bool = false
    var restartOnCrash: Bool = false
    var checkPortBeforeStart: Bool = true
    var killPortOccupantOnStart: Bool = false

    // Console
    var consoleBufferLines: Int = 5000
    var consoleFontSize: Double = 12
    var autoScrollConsole: Bool = true
    var writeLogsToFile: Bool = true
    /// How many days to keep log files. 0 — do not clean up automatically.
    var logRetentionDays: Int = 7
    var terminalApp: TerminalApp = .terminal
    var shellPath: String = "/bin/zsh"

    // Ports
    var portsAutoRefresh: Bool = true
    var portsRefreshInterval: Double = 5
    var portsIncludeUDP: Bool = false
    var portsShowSystemProcesses: Bool = true
    var confirmBeforeKill: Bool = true
    var defaultKillSignal: KillSignal = .term
    var portReservationsEnabled: Bool = false

    // Environment
    var extraPATHEntries: [String] = ["/opt/homebrew/bin", "/usr/local/bin"]

    // Dependencies
    var checkDependenciesOnLaunch: Bool = true

    // Interface
    /// The interface language code. Empty — match the system.
    var language: String = ""

    // Updates
    var updateRepository: String = "adm1nsys/ServerMaster"
    var updateVersionFile: String = "updates/maclastversion.txt"
    var updateBuildsFolder: String = "mac"
    var checkUpdatesOnLaunch: Bool = false
    var lastUpdateCheck: Date? = nil
    /// The version whose banner the user dismissed. For a newer one we show it again.
    var dismissedUpdateVersion: String = ""

    // Certificates
    var certificateDefaultDays: Int = 825
    var certificateDefaultDomains: String = "localhost,127.0.0.1,::1"

    // MARK: - Tolerant decoding
    //
    // The synthesized Decodable fails on any missing key, even when the field has
    // a default value. Because of that, a file written by an earlier version of
    // the application stopped being readable as a whole and the settings reset.
    // So every field is read separately, falling back to its default.

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        defaultProfileID = container.value(.defaultProfileID, default: defaults.defaultProfileID)
        autostartDefaultProfile = container.value(.autostartDefaultProfile, default: defaults.autostartDefaultProfile)
        restoreLastSection = container.value(.restoreLastSection, default: defaults.restoreLastSection)
        lastSection = container.value(.lastSection, default: defaults.lastSection)
        lastSelectedProfileID = container.value(.lastSelectedProfileID, default: defaults.lastSelectedProfileID)
        openBrowserOnStart = container.value(.openBrowserOnStart, default: defaults.openBrowserOnStart)
        stopServerOnQuit = container.value(.stopServerOnQuit, default: defaults.stopServerOnQuit)
        confirmBeforeStop = container.value(.confirmBeforeStop, default: defaults.confirmBeforeStop)
        restartOnCrash = container.value(.restartOnCrash, default: defaults.restartOnCrash)
        checkPortBeforeStart = container.value(.checkPortBeforeStart, default: defaults.checkPortBeforeStart)
        killPortOccupantOnStart = container.value(.killPortOccupantOnStart, default: defaults.killPortOccupantOnStart)
        consoleBufferLines = container.value(.consoleBufferLines, default: defaults.consoleBufferLines)
        consoleFontSize = container.value(.consoleFontSize, default: defaults.consoleFontSize)
        autoScrollConsole = container.value(.autoScrollConsole, default: defaults.autoScrollConsole)
        writeLogsToFile = container.value(.writeLogsToFile, default: defaults.writeLogsToFile)
        logRetentionDays = container.value(.logRetentionDays, default: defaults.logRetentionDays)
        terminalApp = container.value(.terminalApp, default: defaults.terminalApp)
        shellPath = container.value(.shellPath, default: defaults.shellPath)
        portsAutoRefresh = container.value(.portsAutoRefresh, default: defaults.portsAutoRefresh)
        portsRefreshInterval = container.value(.portsRefreshInterval, default: defaults.portsRefreshInterval)
        portsIncludeUDP = container.value(.portsIncludeUDP, default: defaults.portsIncludeUDP)
        portsShowSystemProcesses = container.value(.portsShowSystemProcesses, default: defaults.portsShowSystemProcesses)
        confirmBeforeKill = container.value(.confirmBeforeKill, default: defaults.confirmBeforeKill)
        defaultKillSignal = container.value(.defaultKillSignal, default: defaults.defaultKillSignal)
        portReservationsEnabled = container.value(.portReservationsEnabled, default: defaults.portReservationsEnabled)
        extraPATHEntries = container.value(.extraPATHEntries, default: defaults.extraPATHEntries)
        checkDependenciesOnLaunch = container.value(.checkDependenciesOnLaunch, default: defaults.checkDependenciesOnLaunch)
        language = container.value(.language, default: defaults.language)
        updateRepository = container.value(.updateRepository, default: defaults.updateRepository)
        updateVersionFile = container.value(.updateVersionFile, default: defaults.updateVersionFile)
        updateBuildsFolder = container.value(.updateBuildsFolder, default: defaults.updateBuildsFolder)
        checkUpdatesOnLaunch = container.value(.checkUpdatesOnLaunch, default: defaults.checkUpdatesOnLaunch)
        lastUpdateCheck = container.value(.lastUpdateCheck, default: defaults.lastUpdateCheck)
        dismissedUpdateVersion = container.value(.dismissedUpdateVersion, default: defaults.dismissedUpdateVersion)
        certificateDefaultDays = container.value(.certificateDefaultDays, default: defaults.certificateDefaultDays)
        certificateDefaultDomains = container.value(.certificateDefaultDomains, default: defaults.certificateDefaultDomains)
    }
}
