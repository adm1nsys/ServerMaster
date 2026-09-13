//
//  Diagnostics.swift
//  ServerMaster
//
//  What is wrong when everything looks installed.
//
//  The dependency screen answers one question — is it there. That is not the
//  question people actually arrive with. A binary can be present and refuse to
//  run because it was built for another architecture; a data directory can exist
//  and be half-written; a port can be free and the folder behind it unreadable;
//  a disk can be full enough that a database will not start but not full enough
//  to be obvious.
//
//  So each check here runs the thing rather than looking for it, and every
//  failure carries what to do about it. A diagnosis nobody can act on is just a
//  more polite way of saying no.
//

import Foundation

nonisolated struct Finding: Identifiable, Sendable, Equatable {

    enum Level: Int, Sendable, Comparable {
        case fine, note, warning, broken
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }

        var symbol: String {
            switch self {
            case .fine:    "checkmark.circle"
            case .note:    "info.circle"
            case .warning: "exclamationmark.triangle"
            case .broken:  "xmark.octagon"
            }
        }
    }

    var id: String
    var group: String
    var title: String
    var detail: String
    var level: Level
    /// What to do about it. Empty when there is nothing to do.
    var remedy: String = ""
    /// A command worth offering to copy, when one exists.
    var command: String?
}

@Observable
final class Diagnostics {

    private(set) var findings: [Finding] = []
    private(set) var isRunning = false
    private(set) var lastRun: Date?

    var problems: [Finding] { findings.filter { $0.level >= .warning } }

    func run(profiles: [ServerProfile], database: DatabaseService) async {
        isRunning = true
        defer { isRunning = false; lastRun = Date() }

        var found: [Finding] = []
        found += await machine()
        found += await hardware()
        found += await systemIntegrity()
        found += await disks(profiles: profiles)
        found += await diskTest()
        found += await networkStack()
        found += await binaries()
        found += await databaseHealth(database)
        found += folders(profiles: profiles)
        found += appData()

        findings = found.sorted { ($0.level, $0.group) > ($1.level, $1.group) }
    }

    // MARK: - The machine

    private func machine() async -> [Finding] {
        var out: [Finding] = []
        let info = ProcessInfo.processInfo

        out.append(Finding(id: "os", group: "System",
                           title: String(localized: "macOS \(info.operatingSystemVersionString)"),
                           detail: Self.hardware(),
                           level: .fine))

        let memory = Double(info.physicalMemory) / 1_073_741_824
        let pressure = await Self.memoryPressure()
        out.append(Finding(id: "memory", group: "System",
                           title: String(localized: "\(String(format: "%.0f", memory)) GB of memory"),
                           detail: pressure.detail,
                           level: pressure.level,
                           remedy: pressure.level >= .warning
                            ? String(localized: "Something is using most of the memory. Servers will start slowly or be killed.")
                            : ""))

        // Rosetta only matters here because a Homebrew installed under the wrong
        // architecture is the most common way a working tool stops working.
        let native = Self.isAppleSilicon
        out.append(Finding(id: "arch", group: "System",
                           title: native ? String(localized: "Apple silicon") : String(localized: "Intel"),
                           detail: String(localized: "The app itself is running as \(Self.processArchitecture())."),
                           level: .fine))
        return out
    }

    private static func hardware() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &bytes, &size, nil, 0)
        return String(cString: bytes)
    }

    private static var isAppleSilicon: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }

    private static func processArchitecture() -> String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }

    private static func memoryPressure() async -> (detail: String, level: Finding.Level) {
        let result = await ProcessRunner.run("/usr/sbin/sysctl", ["-n", "kern.memorystatus_vm_pressure_level"])
        // 1 normal, 2 warning, 4 critical.
        switch result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "4": return (String(localized: "Memory pressure is critical."), .broken)
        case "2": return (String(localized: "Memory pressure is raised."), .warning)
        default:  return (String(localized: "Memory pressure is normal."), .fine)
        }
    }

    // MARK: - The hardware underneath

    /// The checks that answer “is this machine itself in trouble”. Everything
    /// here is read from what macOS already knows — none of it needs a password,
    /// and none of it writes anything.
    private func hardware() async -> [Finding] {
        var out: [Finding] = []

        // SMART is the disk telling the truth about itself. “Verified” is not a
        // promise, but anything else is a disk to copy off today.
        let smart = await ProcessRunner.run("/usr/sbin/diskutil", ["info", "/"], timeout: 20)
        if let line = smart.stdout.split(separator: "\n").first(where: { $0.contains("SMART Status") }) {
            let status = line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "?"
            let good = status.lowercased().contains("verified") || status.lowercased().contains("not supported")
            out.append(Finding(id: "smart", group: "Hardware",
                               title: String(localized: "Disk SMART status"),
                               detail: status,
                               level: good ? .fine : .broken,
                               remedy: good ? "" : String(localized: "The drive is reporting failures. Copy what matters off it now — this does not get better.")))
        }

        // Swap. A machine that is swapping hard will start a server eventually,
        // and everything will feel broken while it does.
        let swap = await ProcessRunner.run("/usr/sbin/sysctl", ["-n", "vm.swapusage"], timeout: 10)
        if !swap.stdout.isEmpty {
            let text = swap.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let used = Self.number(after: "used = ", in: text)
            out.append(Finding(id: "swap", group: "Hardware",
                               title: String(localized: "Swap in use"),
                               detail: text,
                               level: used > 8192 ? .warning : .fine,
                               remedy: used > 8192
                                ? String(localized: "Several gigabytes are on disk instead of in memory. Everything will be slow until something is closed.")
                                : ""))
        }

        // Thermal throttling: the answer to “it was fast yesterday”.
        let thermal = await ProcessRunner.run("/usr/bin/pmset", ["-g", "therm"], timeout: 10)
        if let line = thermal.stdout.split(separator: "\n").first(where: { $0.contains("CPU_Speed_Limit") }) {
            let limit = Int(line.split(separator: "=").last?.trimmingCharacters(in: .whitespaces) ?? "100") ?? 100
            out.append(Finding(id: "thermal", group: "Hardware",
                               title: String(localized: "CPU speed limit"),
                               detail: String(localized: "\(String(limit))% of full speed."),
                               level: limit < 60 ? .warning : (limit < 100 ? .note : .fine),
                               remedy: limit < 60
                                ? String(localized: "The machine is throttling — heat, or a power adapter that cannot keep up.")
                                : ""))
        }

        // Battery condition is a hardware fact worth surfacing on a laptop that
        // shuts down mid-build.
        let power = await ProcessRunner.run("/usr/sbin/system_profiler", ["SPPowerDataType"], timeout: 25)
        if let condition = Self.value(of: "Condition", in: power.stdout) {
            let cycles = Self.value(of: "Cycle Count", in: power.stdout) ?? "?"
            let healthy = condition.lowercased() == "normal"
            out.append(Finding(id: "battery", group: "Hardware",
                               title: String(localized: "Battery"),
                               detail: String(localized: "\(condition) · \(cycles) cycles"),
                               level: healthy ? .fine : .warning,
                               remedy: healthy ? "" : String(localized: "The battery is reporting a fault. Expect sudden shutdowns under load.")))
        }

        // A panic is the machine saying something is genuinely wrong, and the
        // reports sit in a folder nobody opens.
        let reports = (try? FileManager.default.contentsOfDirectory(
            atPath: NSHomeDirectory() + "/Library/Logs/DiagnosticReports")) ?? []
        let panics = reports.filter { $0.hasSuffix(".panic") }
        let systemPanics = ((try? FileManager.default.contentsOfDirectory(
            atPath: "/Library/Logs/DiagnosticReports")) ?? []).filter { $0.hasSuffix(".panic") }
        let total = panics.count + systemPanics.count
        out.append(Finding(id: "panics", group: "Hardware",
                           title: String(localized: "Kernel panics"),
                           detail: total == 0
                            ? String(localized: "None recorded.")
                            : String(localized: "\(String(total)) recorded, most recent \((panics + systemPanics).sorted().last ?? "")"),
                           level: total == 0 ? .fine : .warning,
                           remedy: total == 0 ? "" : String(localized: "Repeated panics are hardware or a kernel extension, not this app.")))

        return out
    }

    // MARK: - Is the system itself intact

    private func systemIntegrity() async -> [Finding] {
        var out: [Finding] = []

        // SIP off is a legitimate choice and a real explanation for odd
        // behaviour, so it is reported rather than judged.
        let sip = await ProcessRunner.run("/usr/bin/csrutil", ["status"], timeout: 10)
        // Only the first line is the verdict. Searching the whole output for
        // “enabled” reports a machine in a custom configuration as fully
        // protected, because the breakdown underneath lists every part that is
        // still on.
        let verdict = (sip.stdout.split(separator: "\n").first.map(String.init) ?? "")
            .replacingOccurrences(of: "System Integrity Protection status:", with: "")
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let sipLevel: Finding.Level = verdict.hasPrefix("enabled") ? .fine : .note
        out.append(Finding(id: "sip", group: "System",
                           title: String(localized: "System Integrity Protection"),
                           detail: verdict.isEmpty ? String(localized: "Could not be read.") : verdict,
                           level: sipLevel,
                           remedy: sipLevel == .fine ? "" : String(localized: "Not fully on. That is a normal state on a machine set up for development; worth knowing if you did not do it.")))

        // The signed system volume. A broken seal means the system volume was
        // modified — the machine still boots, and stops being trustworthy.
        let seal = await ProcessRunner.run("/usr/sbin/diskutil", ["apfs", "list"], timeout: 25)
        // “Snapshot Sealed”, not “Sealed”. Every modern Mac boots from a sealed
        // *snapshot* of the system volume, and the live read-write volume
        // underneath it reports “Sealed: Broken” as a matter of course — that
        // is not damage, it is how the signed system volume works. Reading the
        // wrong line calls a perfectly healthy Mac modified.
        let sealLine = seal.stdout.split(separator: "\n")
            .first(where: { $0.contains("Snapshot Sealed:") })
            ?? seal.stdout.split(separator: "\n").first(where: { $0.contains("Sealed:") })
        if let sealLine {
            // The column width of diskutil's output is not a contract, so the
            // value is read rather than matched against a spacing.
            let value = sealLine.split(separator: ":").last?
                .trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            let broken = !(value.contains("yes") || value.contains("sealed"))
            out.append(Finding(id: "seal", group: "System",
                               title: String(localized: "Signed system volume"),
                               detail: broken
                                ? String(localized: "The seal is broken.")
                                : String(localized: "Sealed and unmodified."),
                               level: broken ? .warning : .fine,
                               remedy: broken
                                ? String(localized: "The system volume has been modified — usual on a machine running a beta or with SIP relaxed. Nothing here needs it; a reinstall of macOS restores the seal.")
                                : ""))
        }

        // Disk I/O errors in the log are what a failing disk looks like before
        // SMART admits anything.
        // Only the kernel, and only its own words for a failing device.
        //
        // The first version of this asked for any message containing “I/O
        // error”, which matched the log tool's own record of being run with
        // that phrase in its arguments. Every check counted its own previous
        // runs and reported a healthy disk as failing.
        let errors = await ProcessRunner.run(
            "/usr/bin/log",
            ["show", "--last", "24h", "--style", "compact",
             "--predicate", #"process == "kernel" AND (eventMessage CONTAINS "I/O error" OR eventMessage CONTAINS "media is not present" OR eventMessage CONTAINS "Failed to read" OR eventMessage CONTAINS "disk write failed")"#],
            timeout: 60)
        let count = errors.stdout.split(separator: "\n")
            .dropFirst()          // the header line
            .filter { !$0.isEmpty }
            .count
        out.append(Finding(id: "io", group: "System",
                           title: String(localized: "Disk errors in the last day"),
                           detail: count == 0 ? String(localized: "None.") : String(localized: "\(String(count)) mentioned in the system log."),
                           level: count == 0 ? .fine : (count > 20 ? .broken : .warning),
                           remedy: count == 0 ? "" : String(localized: "The disk is reporting read or write failures. Back up before doing anything else.")))

        return out
    }

    // MARK: - Actually using the disk

    /// Writes, flushes, reads back and compares. Free space and SMART both look
    /// fine on a volume that has silently gone read-only, or where the app's own
    /// folder has lost its permissions — and that is the failure that makes
    /// every save quietly do nothing.
    private func diskTest() async -> [Finding] {
        let file = AppPaths.support.appendingPathComponent(".servermaster-write-test")
        let payload = Data((0..<(1024 * 512)).map { UInt8($0 % 251) })   // 512 KB
        let started = Date()

        do {
            try payload.write(to: file, options: .atomic)
            let readBack = try Data(contentsOf: file)
            try FileManager.default.removeItem(at: file)
            let elapsed = Date().timeIntervalSince(started)

            guard readBack == payload else {
                return [Finding(id: "write", group: "Disk",
                                title: String(localized: "Write test"),
                                detail: String(localized: "What was read back does not match what was written."),
                                level: .broken,
                                remedy: String(localized: "This is data corruption, not a configuration problem. Stop and back up."))]
            }
            let speed = Double(payload.count) / max(elapsed, 0.0001) / 1_048_576
            return [Finding(id: "write", group: "Disk",
                            title: String(localized: "Write test"),
                            detail: String(localized: "512 KB written and read back in \(Int(elapsed * 1000)) ms — \(Int(speed)) MB/s"),
                            level: elapsed > 2 ? .warning : .fine,
                            remedy: elapsed > 2
                                ? String(localized: "That is very slow for half a megabyte. The disk is struggling, or something is scanning every write.")
                                : "")]
        } catch {
            return [Finding(id: "write", group: "Disk",
                            title: String(localized: "Write test"),
                            detail: error.localizedDescription,
                            level: .broken,
                            remedy: String(localized: "The app cannot write its own folder. Nothing will be saved until this is fixed."))]
        }
    }

    // MARK: - The network side

    private func networkStack() async -> [Finding] {
        var out: [Finding] = []

        // A system proxy is the quiet reason localhost stops answering, and
        // nothing in a browser points at it.
        let proxy = await ProcessRunner.run("/usr/sbin/scutil", ["--proxy"], timeout: 10)
        let enabled = ["HTTPEnable : 1", "HTTPSEnable : 1", "SOCKSEnable : 1"]
            .filter { proxy.stdout.contains($0) }
        let bypass = proxy.stdout.contains("localhost") || proxy.stdout.contains("127.0.0.1")
        out.append(Finding(id: "proxy", group: "Network",
                           title: String(localized: "System proxy"),
                           detail: enabled.isEmpty
                            ? String(localized: "None configured.")
                            : String(localized: "\(String(enabled.count)) enabled\(bypass ? ", localhost bypassed" : ", localhost not bypassed")"),
                           level: enabled.isEmpty ? .fine : (bypass ? .note : .warning),
                           remedy: enabled.isEmpty || bypass ? ""
                            : String(localized: "A proxy is on and localhost is not in its bypass list. Requests to your own servers will be sent to the proxy.")))

        // The firewall blocking incoming connections is invisible until a phone
        // on the same network cannot open the site.
        let firewall = await ProcessRunner.run(
            "/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"], timeout: 10)
        let on = firewall.stdout.lowercased().contains("enabled")
        out.append(Finding(id: "firewall", group: "Network",
                           title: String(localized: "Firewall"),
                           detail: firewall.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                           level: on ? .note : .fine,
                           remedy: on ? String(localized: "On. Localhost still works; another device on the network may be refused.") : ""))

        return out
    }

    // MARK: - Reading text output

    private static func value(of key: String, in text: String) -> String? {
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(key + ":") else { continue }
            return trimmed.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// The megabytes in a string like “used = 9216.00M”.
    private static func number(after marker: String, in text: String) -> Double {
        guard let range = text.range(of: marker) else { return 0 }
        let rest = text[range.upperBound...]
        let digits = rest.prefix { $0.isNumber || $0 == "." }
        let value = Double(digits) ?? 0
        let unit = rest.dropFirst(digits.count).first
        switch unit {
        case "G": return value * 1024
        case "K": return value / 1024
        default:  return value
        }
    }

    // MARK: - Space


    private func disks(profiles: [ServerProfile]) async -> [Finding] {
        var out: [Finding] = []
        var seen: Set<String> = []

        // The volume the app's own data is on, plus any volume a site sits on:
        // an external disk with a site on it fills up on its own schedule.
        var places = [AppPaths.support.path]
        places += profiles.map { AppPaths.expand($0.rootPath) }

        for path in places {
            guard let values = try? URL(fileURLWithPath: path).resourceValues(
                    forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                              .volumeTotalCapacityKey, .volumeNameKey]),
                  let free = values.volumeAvailableCapacityForImportantUsage,
                  let total = values.volumeTotalCapacity else { continue }

            let name = values.volumeName ?? path
            guard seen.insert(name).inserted else { continue }

            let freeGB = Double(free) / 1_073_741_824
            let share = Double(free) / Double(total)
            let level: Finding.Level = freeGB < 2 ? .broken : (freeGB < 10 || share < 0.05 ? .warning : .fine)

            out.append(Finding(
                id: "disk-\(name)", group: "Disk",
                title: String(localized: "\(name): \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free"),
                detail: String(localized: "\(Int(share * 100))% of \(ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file))"),
                level: level,
                remedy: level >= .warning
                    ? String(localized: "MariaDB refuses to start on a nearly full disk, and a dump can fail halfway and leave a broken file.")
                    : ""))
        }
        return out
    }

    // MARK: - The tools themselves

    /// Runs each one. Presence is not health: a Homebrew binary left behind by a
    /// half-finished upgrade is still a file, and still on the PATH.
    private func binaries() async -> [Finding] {
        var out: [Finding] = []

        for dependency in Dependency.catalog {
            guard let path = ShellEnvironment.shared.which(dependency.command) else {
                out.append(Finding(id: "bin-\(dependency.command)", group: "Tools",
                                   title: dependency.title,
                                   detail: String(localized: "Not installed."),
                                   level: dependency.required ? .warning : .note,
                                   remedy: dependency.required
                                    ? String(localized: "Install it from the Dependencies screen.")
                                    : "",
                                   command: dependency.installCommand))
                continue
            }

            // A dangling symlink is the classic leftover of `brew uninstall`
            // followed by nothing.
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            guard FileManager.default.fileExists(atPath: resolved) else {
                out.append(Finding(id: "bin-\(dependency.command)", group: "Tools",
                                   title: dependency.title,
                                   detail: String(localized: "\(path) points at \(resolved), which is gone."),
                                   level: .broken,
                                   remedy: String(localized: "A leftover link from an uninstall. Reinstall it, or delete the link."),
                                   command: dependency.installCommand))
                continue
            }

            let architecture = await Self.architecture(of: resolved)
            let usable = await ProcessRunner.run(resolved, dependency.versionArguments, timeout: 15)

            if !usable.succeeded && usable.stdout.isEmpty {
                out.append(Finding(id: "bin-\(dependency.command)", group: "Tools",
                                   title: dependency.title,
                                   detail: String(localized: "Present at \(path) but will not run: \(usable.stderr.prefix(160))"),
                                   level: .broken,
                                   remedy: architecture.contains("x86_64") && Self.isAppleSilicon
                                    ? String(localized: "Built for Intel on an Apple silicon Mac — this is an Intel Homebrew under /usr/local. Reinstall it with the Homebrew in /opt/homebrew.")
                                    : String(localized: "Reinstall it."),
                                   command: dependency.installCommand))
            } else {
                out.append(Finding(id: "bin-\(dependency.command)", group: "Tools",
                                   title: dependency.title,
                                   detail: "\(AppPaths.abbreviate(path))  ·  \(architecture)",
                                   level: .fine))
            }
        }
        return out
    }

    private static func architecture(of path: String) async -> String {
        let result = await ProcessRunner.run("/usr/bin/file", ["-b", path], timeout: 10)
        let text = result.stdout.lowercased()
        if text.contains("universal") { return "universal" }
        if text.contains("arm64") { return "arm64" }
        if text.contains("x86_64") { return "x86_64" }
        if text.contains("script") || text.contains("text") { return "script" }
        return "—"
    }

    // MARK: - The database

    private func databaseHealth(_ database: DatabaseService) async -> [Finding] {
        var out: [Finding] = []
        let dataDirectory = database.dataDirectory

        guard database.isInstalled else {
            return [Finding(id: "db-missing", group: "Database",
                            title: String(localized: "MariaDB is not installed"),
                            detail: String(localized: "Nothing that needs a database will work."),
                            level: .note,
                            remedy: String(localized: "Install it from the Dependencies screen."),
                            command: "brew install mariadb")]
        }

        // A data directory that exists but has no mysql schema in it is the state
        // an interrupted first run leaves behind, and it produces an error at
        // startup that says nothing about the real cause.
        let exists = FileManager.default.fileExists(atPath: dataDirectory)
        if exists && !database.isInitialized {
            out.append(Finding(id: "db-data", group: "Database",
                               title: String(localized: "The data directory is incomplete"),
                               detail: String(localized: "\(AppPaths.abbreviate(dataDirectory)) exists but has no system tables."),
                               level: .broken,
                               remedy: String(localized: "A first run that was interrupted. Move the folder aside and let the app prepare it again."),
                               command: "mv \(dataDirectory) \(dataDirectory).broken"))
        } else if !exists {
            out.append(Finding(id: "db-data", group: "Database",
                               title: String(localized: "Not prepared yet"),
                               detail: String(localized: "The data directory will be made the first time the database starts."),
                               level: .note))
        } else {
            let size = Self.folderSize(dataDirectory)
            out.append(Finding(id: "db-data", group: "Database",
                               title: String(localized: "Data directory is in order"),
                               detail: "\(AppPaths.abbreviate(dataDirectory))  ·  \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))",
                               level: .fine))
        }

        // The error log is where a database that will not start says why, and it
        // is the last place anyone looks.
        if let text = try? String(contentsOfFile: database.errorLogPath, encoding: .utf8) {
            let bad = text.split(separator: "\n")
                .filter { $0.contains("[ERROR]") }
                .suffix(3)
            if !bad.isEmpty {
                // How old the errors are decides what can honestly be said. Not
                // how old the *file* is: MariaDB appends ordinary startup lines
                // to the same log, so a file touched a minute ago can hold
                // nothing but failures from last week. The timestamp that
                // matters is the one on the error line itself.
                let written = Self.timestamp(ofLogLine: bad.last.map(String.init) ?? "")
                let age = written.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
                let recent = age < 600      // ten minutes

                let level: Finding.Level
                let remedy: String
                if database.state == .running {
                    level = .note
                    remedy = String(localized: "It is running now, so these are from an earlier start.")
                } else if recent {
                    level = .warning
                    remedy = String(localized: "Written in the last few minutes, with the database not running — this is very likely why.")
                } else {
                    level = .note
                    let when = written.map { SnapshotStore.readable.string(from: $0) }
                        ?? String(localized: "at an unknown time")
                    remedy = String(localized: "These are from \(when), not from a start attempt just now. The database is not running, but nothing says this is why — most likely it has simply not been started.")
                }

                out.append(Finding(id: "db-log", group: "Database",
                                   title: String(localized: "Errors in the database log"),
                                   detail: bad.joined(separator: "\n"),
                                   level: level,
                                   remedy: remedy))
            }
        }
        return out
    }

    /// The date at the front of a MariaDB log line: “2026-08-29 19:16:13 0 [ERROR] …”.
    private static func timestamp(ofLogLine line: String) -> Date? {
        let head = String(line.prefix(19))
        guard head.count == 19 else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: head)
    }

    // MARK: - Site folders

    private func folders(profiles: [ServerProfile]) -> [Finding] {
        var out: [Finding] = []
        let manager = FileManager.default

        for profile in profiles {
            let root = AppPaths.expand(profile.rootPath)
            var isDirectory: ObjCBool = false

            guard manager.fileExists(atPath: root, isDirectory: &isDirectory) else {
                out.append(Finding(id: "root-\(profile.id)", group: "Sites",
                                   title: profile.name,
                                   detail: String(localized: "\(AppPaths.abbreviate(root)) does not exist."),
                                   level: .broken,
                                   remedy: String(localized: "The folder was moved or deleted. Point the profile somewhere else.")))
                continue
            }
            guard isDirectory.boolValue else {
                out.append(Finding(id: "root-\(profile.id)", group: "Sites",
                                   title: profile.name,
                                   detail: String(localized: "\(AppPaths.abbreviate(root)) is a file, not a folder."),
                                   level: .broken))
                continue
            }
            guard manager.isReadableFile(atPath: root) else {
                out.append(Finding(id: "root-\(profile.id)", group: "Sites",
                                   title: profile.name,
                                   detail: String(localized: "\(AppPaths.abbreviate(root)) cannot be read."),
                                   level: .broken,
                                   remedy: String(localized: "Check the permissions on the folder.")))
                continue
            }

            // Apache and PHP-FPM run as themselves, not as the app, and macOS
            // privacy rules stop them reading Documents, Desktop and Downloads
            // whatever the file permissions say. This is invisible until every
            // asset comes back 403.
            var level = Finding.Level.fine
            var detail = AppPaths.abbreviate(root)
            var remedy = ""
            // Only the Apache macOS ships is refused here. A Homebrew httpd is
            // not a platform binary and inherits this app's own access, so the
            // same folder is fine — warning about it either way is how a
            // diagnostic loses the reader's trust.
            if [.apache, .apachePHP].contains(profile.engine),
               let warning = ApacheInstallation.privacyWarning(forRoot: root) {
                level = .warning
                detail = String(localized: "\(AppPaths.abbreviate(root)) is in a folder macOS protects.")
                remedy = warning
            }
            out.append(Finding(id: "root-\(profile.id)", group: "Sites",
                               title: profile.name, detail: detail, level: level, remedy: remedy))
        }
        return out
    }

    // MARK: - The app's own data

    private func appData() -> [Finding] {
        var out: [Finding] = []

        for (name, url) in [("Profiles", AppPaths.profilesFile), ("Settings", AppPaths.settingsFile)] {
            guard let data = try? Data(contentsOf: url) else { continue }
            let readable = (try? JSONSerialization.jsonObject(with: data)) != nil
            out.append(Finding(id: "data-\(name)", group: "App data",
                               title: name,
                               detail: readable
                                ? String(localized: "\(data.count) bytes, readable.")
                                : String(localized: "\(data.count) bytes and not valid JSON."),
                               level: readable ? .fine : .broken,
                               remedy: readable ? "" : String(localized: "The file is damaged. Move it aside; the app will start fresh."),
                               command: readable ? nil : "mv \(url.path) \(url.path).broken"))
        }

        let shared = AppPaths.shared.appendingPathComponent("status.json")
        let reachable = FileManager.default.fileExists(atPath: shared.path)
        out.append(Finding(id: "data-shared", group: "App data",
                           title: String(localized: "Shared with the widget and Safari"),
                           detail: reachable
                            ? AppPaths.abbreviate(AppPaths.shared.path)
                            : String(localized: "Nothing written to the group container yet."),
                           level: reachable ? .fine : .note))
        return out
    }

    private static func folderSize(_ path: String) -> Int64 {
        guard let walk = FileManager.default.enumerator(at: URL(fileURLWithPath: path),
                                                        includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walk {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
