import Foundation
import Testing
@testable import ServerMaster

@MainActor
@Suite("Runtime package manager")
struct RuntimePackagesTests {
    @MainActor private final class Fake {
        var calls: [[String]] = []
        var installed = ["22.1.0"]
        var formula = "node@22"
        var prefix = "/brew/opt/node@22"
        var active = "/brew/opt/node@22/bin/node"
        var latest = "22.2.0"
        var binaryVersion = "v22.2.0"
        var failMutation = false

        func run(_ executable: String, _ arguments: [String], _ timeout: TimeInterval) async -> CommandResult {
            calls.append([executable] + arguments)
            if arguments.first == "info" {
                let payload: [String: Any] = ["formulae": [["name": arguments.last!, "versions": ["stable": latest], "installed": installed.map { ["version": $0] }, "outdated": installed.first != latest]]]
                let data = try! JSONSerialization.data(withJSONObject: payload)
                return .init(exitCode: 0, stdout: String(decoding: data, as: UTF8.self), stderr: "")
            }
            if arguments.first == "--prefix" { return .init(exitCode: 0, stdout: prefix, stderr: "") }
            if arguments.first == "search" { return .init(exitCode: 0, stdout: "node\nnode@22\nnode@24\nnot-node\nnode@22;touch", stderr: "") }
            if arguments == ["--version"] { return .init(exitCode: 0, stdout: binaryVersion, stderr: "") }
            if ["install", "upgrade", "uninstall"].contains(arguments.first ?? "") {
                if failMutation { return .init(exitCode: 1, stdout: "", stderr: "Package required by another formula") }
                installed = arguments.first == "uninstall" ? [] : [latest]
                return .init(exitCode: 0, stdout: "Done", stderr: "")
            }
            return .init(exitCode: 1, stdout: "", stderr: "Unexpected mock command")
        }

        func manager() -> RuntimePackages {
            RuntimePackages(run: run, which: { _ in self.active }, canonical: {
                $0.replacingOccurrences(of: "/brew/opt/node@22", with: "/brew/Cellar/node@22/22.1.0")
            })
        }
    }

    @Test("Stable npm versions are filtered and sorted numerically")
    func versions() throws {
        #expect(try RuntimePackages.npmVersions(#"["1.9.0","1.10.0","1.10.0","2.0.0-beta.1","latest","1.0.0;echo"]"#) == ["1.10.0", "1.9.0"])
        #expect(throws: (any Error).self) { try RuntimePackages.npmVersions("[]") }
        #expect(throws: (any Error).self) { try RuntimePackages.npmVersions(#"{"versions":[]}"#) }
        #expect(RuntimePackages.validNodeFormula("node@24"))
        #expect(!RuntimePackages.validNodeFormula("node@24;rm"))
        #expect(!RuntimePackages.supports("lsof"))
        #expect(!RuntimePackages.supports("brew"))
    }

    @Test("Versioned Node is detected and only that formula is upgraded")
    func upgrade() async throws {
        let fake = Fake()
        let manager = fake.manager()
        let before = try await manager.inspect(command: "node")
        #expect(before.formula == "node@22")
        #expect(before.isManaged && before.outdated)
        _ = try await manager.perform(command: "node", action: .update, log: ConsoleLog())
        #expect(fake.calls.contains(["brew", "upgrade", "--formula", "node@22"]))
        #expect(fake.calls.contains([fake.active, "--version"]))
        #expect(!(try await manager.inspect(command: "node")).outdated)
    }

    @Test("An executable outside Homebrew cannot be upgraded or removed", arguments: [RuntimePackages.Action.update, .remove])
    func foreignExecutable(action: RuntimePackages.Action) async throws {
        let fake = Fake()
        fake.active = "/usr/bin/node"
        do {
            _ = try await fake.manager().perform(command: "node", action: action, log: ConsoleLog())
            Issue.record("A foreign executable was changed")
        } catch {
            #expect(!fake.calls.contains { ["upgrade", "uninstall"].contains($0.dropFirst().first ?? "") })
        }
    }

    @Test("Dependency refusal is surfaced without forcing uninstall")
    func dependencyRefusal() async throws {
        let fake = Fake()
        fake.failMutation = true
        do {
            _ = try await fake.manager().perform(command: "node", action: .remove, log: ConsoleLog())
            Issue.record("Uninstall refusal was ignored")
        } catch {
            #expect(error.localizedDescription.contains("required"))
            #expect(!fake.calls.flatMap { $0 }.contains("--ignore-dependencies"))
            #expect(!fake.calls.flatMap { $0 }.contains("--force"))
        }
    }

    @Test("Unsupported Node versions are refused before installation")
    func unknownVersion() async throws {
        let fake = Fake()
        do {
            _ = try await fake.manager().perform(command: "node", action: .install, selectedVersion: "node@999", log: ConsoleLog())
            Issue.record("Installed an unoffered version")
        } catch {
            #expect(!fake.calls.contains { $0.contains("install") })
        }
    }

    @Test("Selecting Node verifies its executable and returns an app PATH preference")
    func selection() async throws {
        let fake = Fake()
        let bin = try await fake.manager().perform(command: "node", action: .install,
                                                  selectedVersion: "node@22", log: ConsoleLog())
        #expect(bin == "/brew/opt/node@22/bin")
        #expect(!fake.calls.flatMap { $0 }.contains("link"))
        fake.binaryVersion = "v20.0.0"
        do {
            _ = try await fake.manager().perform(command: "node", action: .install,
                                                 selectedVersion: "node@22", log: ConsoleLog())
            Issue.record("Wrong Node executable accepted")
        } catch { #expect(error is RuntimePackages.Failure) }
    }

    @Test("Only one package mutation can run at a time, and failures release the lock")
    func lock() async throws {
        let dependencies = DependencyChecker()
        try await dependencies.managePackages {
            #expect(dependencies.isManagingPackages)
            do {
                try await dependencies.managePackages { Issue.record("Concurrent mutation entered") }
                Issue.record("Concurrent mutation was not refused")
            } catch { #expect(error is RuntimePackages.Failure) }
        }
        #expect(!dependencies.isManagingPackages)
        do {
            try await dependencies.managePackages { throw RuntimePackages.Failure(message: "Fixture") }
        } catch { }
        #expect(!dependencies.isManagingPackages)
    }

    @MainActor private final class NpmFake {
        var version: String? = "14.1.0"
        var reportedBinary: String?
        var calls: [[String]] = []

        func manager() -> RuntimePackages {
            RuntimePackages(run: { executable, args, _ in
                self.calls.append([executable] + args)
                var output = ""
                if args == ["prefix", "--global"] { output = "/npm" }
                else if args.first == "list" {
                    output = self.version.map { "{\"dependencies\":{\"http-server\":{\"version\":\"\($0)\"}}}" } ?? "{\"dependencies\":{}}"
                } else if args == ["view", "http-server", "version", "--json"] { output = "\"14.1.1\"" }
                else if args == ["view", "http-server", "versions", "--json"] { output = "[\"14.1.0\",\"14.1.1\"]" }
                else if args.first == "install" { self.version = String(args.last!.split(separator: "@").last!) }
                else if args.first == "uninstall" { self.version = nil }
                else if args == ["--version"] { output = self.reportedBinary ?? self.version ?? "" }
                else { return .init(exitCode: 1, stdout: "", stderr: "Unexpected command") }
                return .init(exitCode: 0, stdout: output, stderr: "")
            }, which: { _ in self.version == nil ? nil : "/npm/bin/http-server" }, canonical: { $0 })
        }
    }

    @Test("npm can upgrade, select an older release and remove only http-server")
    func npmLifecycle() async throws {
        let fake = NpmFake()
        let manager = fake.manager()
        #expect(try await manager.inspect(command: "http-server").outdated)
        _ = try await manager.perform(command: "http-server", action: .update, log: ConsoleLog())
        #expect(fake.version == "14.1.1")
        _ = try await manager.perform(command: "http-server", action: .install, selectedVersion: "14.1.0", log: ConsoleLog())
        #expect(fake.version == "14.1.0")
        _ = try await manager.perform(command: "http-server", action: .remove, log: ConsoleLog())
        #expect(fake.version == nil)
        #expect(fake.calls.contains(["npm", "uninstall", "--global", "http-server"]))
        #expect(!fake.calls.flatMap { $0 }.contains("sudo"))
    }

    @Test("npm metadata success does not hide the wrong active executable version")
    func npmWrongBinary() async throws {
        let fake = NpmFake()
        fake.reportedBinary = "13.0.0"
        do {
            _ = try await fake.manager().perform(command: "http-server", action: .install,
                                                 selectedVersion: "14.1.1", log: ConsoleLog())
            Issue.record("Old binary was accepted after package installation")
        } catch { #expect(error is RuntimePackages.Failure) }
    }
}
