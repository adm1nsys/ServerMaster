//
//  SafariWebExtensionHandler.swift
//  ServerMasterWeb Extension
//
//  The native half of the Safari extension: the only part of it that can see
//  the file system. The page in the popup asks questions here and gets plain
//  dictionaries back.
//
//  Two things are read or run, and nothing else:
//
//   - `status.json`, which the app rewrites whenever the picture changes. It
//     holds names, addresses and states — no paths, no passwords.
//   - `command.json`, where a request to start or stop is left for the app to
//     pick up. This extension is sandboxed — macOS will not register one that is
//     not — so it cannot start a server itself, and that is the right shape
//     anyway: the browser asks, the app decides.
//
//  Nothing from the browser reaches a shell. The only argument that comes from
//  the page is a profile id, and it is checked against the list of profiles the
//  app itself wrote before it is written down.
//

import SafariServices
import os.log

class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {

    private let log = Logger(subsystem: "com.adm1nsys.ServerMaster", category: "safari")

    func beginRequest(with context: NSExtensionContext) {
        let request = context.inputItems.first as? NSExtensionItem
        let message = request?.userInfo?[SFExtensionMessageKey] as? [String: Any] ?? [:]
        let action = message["action"] as? String ?? "status"

        let answer: [String: Any]
        switch action {
        case "status":
            answer = status()
        case "start", "stop", "restart":
            answer = run(action, profile: message["profile"] as? String)
        default:
            answer = ["error": "Unknown action “\(action)”."]
        }

        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: answer]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }

    // MARK: - Where things are

    /// The group container: the one folder this extension and the app can both
    /// see, now that the extension is sandboxed.
    private var shared: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "88M5SYPGUR.com.adm1nsys.ServerMaster")
    }

    private var statusFile: URL? { shared?.appendingPathComponent("status.json") }
    private var commandFile: URL? { shared?.appendingPathComponent("command.json") }

    // MARK: - Reading

    private func status() -> [String: Any] {
        guard let statusFile, let data = try? Data(contentsOf: statusFile),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return ["profiles": [], "stale": true,
                    "error": "ServerMaster has not run yet on this Mac."]
        }

        // The app rewrites this file as things change, so a file that has not
        // been touched in a while means the app is not running. Saying so is
        // better than showing a state that stopped being true hours ago.
        let updated = (object["updated"] as? Double).map {
            Date(timeIntervalSinceReferenceDate: $0)
        }
        object["stale"] = !appIsRunning && (updated.map { Date().timeIntervalSince($0) > 60 } ?? true)
        return object
    }

    private var appIsRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.adm1nsys.ServerMaster").isEmpty
    }

    // MARK: - Changing

    private func run(_ action: String, profile: String?) -> [String: Any] {
        guard let profile, !profile.isEmpty else {
            return ["error": "No profile was named."]
        }
        // The id has to be one the app itself published. This is what keeps the
        // page from naming anything else, whatever it sends.
        guard known(profile) else {
            return ["error": "That profile is not one of yours."]
        }
        guard appIsRunning else {
            return ["error": "ServerMaster is not running — open it first."]
        }
        guard let commandFile else {
            return ["error": "This copy of ServerMaster cannot reach its shared folder."]
        }

        let request: [String: Any] = [
            "action": action,
            "profile": profile,
            // The app ignores anything it has already carried out, and anything
            // stale — a request left behind by a crash should not fire hours
            // later when the app is next opened.
            "id": UUID().uuidString,
            "at": Date().timeIntervalSinceReferenceDate
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              (try? data.write(to: commandFile, options: .atomic)) != nil else {
            return ["error": "The request could not be written."]
        }
        return ["ok": true, "queued": action]
    }

    private func known(_ id: String) -> Bool {
        guard let statusFile, let data = try? Data(contentsOf: statusFile),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profiles = object["profiles"] as? [[String: Any]]
        else { return false }
        return profiles.contains { $0["id"] as? String == id }
    }
}
