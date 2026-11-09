import Foundation
import Darwin

/// Small read-only environment/version probes. No dependency on ShellEnvironment:
/// discovering PATH must not recursively try to discover PATH again.
nonisolated enum ExecutableProbe {
    struct Result: Sendable {
        var output: String
        var succeeded: Bool
        var timedOut: Bool
        var exitCode: Int32? = nil
        var launchError: String? = nil
    }

    static func run(_ executable: String, arguments: [String], environment: [String: String],
                    timeout: TimeInterval = 2, outputLimit: Int = 65_536,
                    includeStandardError: Bool = false) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        if includeStandardError { process.standardError = pipe }
        let reader = pipe.fileHandleForReading
        defer { try? reader.close(); try? pipe.fileHandleForWriting.close() }
        let fd = reader.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        do { try process.run() }
        catch { return Result(output: "", succeeded: false, timedOut: false, launchError: error.localizedDescription) }
        let pid = process.processIdentifier
        let ownsGroup = getpgid(pid) == pid
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 8192)
        func drain() {
            for _ in 0..<16 {
                let count = Darwin.read(fd, &bytes, bytes.count)
                guard count > 0 else { return }
                if data.count < outputLimit { data.append(contentsOf: bytes.prefix(min(count, outputLimit - data.count))) }
            }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(max(0, timeout)))
        while process.isRunning && ContinuousClock.now < deadline {
            drain()
            usleep(10_000)
        }
        let timedOut = process.isRunning
        // Probe descendants (for example `sleep` in a shell rc file) must not
        // keep running or keep the output pipe open after the probe has ended.
        if ownsGroup { kill(-pid, SIGTERM) }
        if timedOut { process.terminate() }
        if timedOut || ownsGroup {
            usleep(20_000)
            if ownsGroup { kill(-pid, SIGKILL) }
            if process.isRunning { kill(pid, SIGKILL) }
        }
        drain()
        return Result(output: String(decoding: data, as: UTF8.self),
                      succeeded: !timedOut && !process.isRunning && process.terminationStatus == 0,
                      timedOut: timedOut, exitCode: process.isRunning ? nil : process.terminationStatus)
    }
}
