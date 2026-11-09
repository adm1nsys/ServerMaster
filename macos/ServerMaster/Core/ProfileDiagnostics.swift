import Foundation

/// Read-only checks of an existing project, deliberately separate from the launch
/// builder: building a plan may create runtime/config folders or reserve ports.
@MainActor
enum ProfileDiagnostics {
    static func runtime(_ profile: ServerProfile, tool: String) throws -> String {
        if tool == "php" { return try LaunchPlanBuilder.requirePHP(profile: profile) }
        if tool == "php-fpm" { return try LaunchPlanBuilder.requirePHPFPM(profile: profile) }
        if tool == "httpd" { return try LaunchPlanBuilder.requireApache() }
        guard let binary = ShellEnvironment.shared.which(tool) else { throw LaunchPlanBuilder.BuildError.toolNotFound(tool) }
        return binary
    }

    static func check(_ profile: ServerProfile, state: ServerState, databaseRunning: Bool,
                      resolve: @MainActor (ServerProfile, String) throws -> String = runtime) async -> [Finding] {
        var result: [Finding] = []
        func add(_ key: String, _ title: String, _ detail: String, _ level: Finding.Level = .fine,
                 remedy: String = "") {
            result.append(.init(id: "profile-\(profile.id)-\(key)", group: profile.name,
                                title: title, detail: detail, level: level, remedy: remedy))
        }
        let errors = profile.validationErrors
        if !errors.isEmpty {
            add("validation", String(localized: "Profile validation"), errors.joined(separator: "\n"), .broken)
        }
        let settingsRemedy = String(localized: "Check this profile's paths and engine in Profiles.")
        let recipeRemedy = String(localized: "Restore the missing project files from a backup or the upstream package. Diagnostics does not change the project.")
        let root = URL(fileURLWithPath: AppPaths.expand(profile.rootPath))
        let working = profile.effectiveWorkingDirectory
        var directory: ObjCBool = false
        let workingOK = FileManager.default.fileExists(atPath: working, isDirectory: &directory)
            && directory.boolValue && FileManager.default.isReadableFile(atPath: working)
        add("working", String(localized: "Working directory"), working, workingOK ? .fine : .broken,
            remedy: workingOK ? "" : settingsRemedy)

        func file(_ key: String, title: String, url: URL, recipe: Bool = false) {
            do {
                if recipe {
                    let access = try SiteFileAccess(root: root)
                    _ = try access.checked(url)
                }
                let checkedURL = recipe ? url : url.resolvingSymlinksInPath()
                let values = try checkedURL.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey])
                guard values.isRegularFile == true, values.isReadable == true else {
                    throw CocoaError(.fileReadNoPermission)
                }
                add(key, title, url.path)
            } catch {
                // Do not print configuration contents, environment values or credentials.
                add(key, title, url.path, .broken, remedy: recipe ? recipeRemedy : settingsRemedy)
            }
        }
        if !(1...65535).contains(profile.port) {
            add("port", String(localized: "Port"), String(profile.port), .broken, remedy: settingsRemedy)
        }
        if profile.engine == .nodeScript {
            file("entry", title: String(localized: "Node entry file"), url: URL(fileURLWithPath: profile.resolvedNodeEntry),
                 recipe: profile.templateId == "printshopcrm")
        }
        if profile.engine.usesConfigFile && !profile.configPath.isEmpty {
            file("config", title: String(localized: "Server configuration"), url: URL(fileURLWithPath: AppPaths.expand(profile.configPath)))
        }
        if profile.httpsEnabled && profile.engine.supportsHTTPS {
            file("certificate", title: String(localized: "HTTPS certificate"), url: URL(fileURLWithPath: AppPaths.expand(profile.certificatePath)))
            file("key", title: String(localized: "HTTPS private key"), url: URL(fileURLWithPath: AppPaths.expand(profile.privateKeyPath)))
        }

        for tool in Set(profile.requiredTools).sorted() {
            do {
                let binary = try resolve(profile, tool)
                let arguments = tool == "caddy" ? ["version"] : ["php", "php-fpm", "httpd", "nginx"].contains(tool) ? ["-v"] : ["--version"]
                let probe = await ProcessRunner.run(binary, arguments, timeout: 3)
                let version = probe.combined.components(separatedBy: .newlines).first ?? ""
                add("runtime-\(tool)", String(localized: "Runtime: \(tool)"), binary + "\n" + version,
                    probe.succeeded ? .fine : .broken,
                    remedy: probe.succeeded ? "" : String(localized: "Select an installed runtime in Dependencies and check this profile's runtime version."))
                if profile.templateId == "joomla6", ["php", "php-fpm"].contains(tool), probe.succeeded {
                    let expression = try NSRegularExpression(pattern: "PHP ([0-9]+\\.[0-9]+)")
                    let range = NSRange(version.startIndex..., in: version)
                    let selected = expression.firstMatch(in: version, range: range)
                        .flatMap { Range($0.range(at: 1), in: version) }.map { String(version[$0]) }
                    if let selected, !ServerProfile.phpVersion(selected, isAtLeast: "8.3") {
                        add("php-minimum", String(localized: "Joomla PHP requirement"), version, .broken,
                            remedy: String(localized: "Joomla 6 requires PHP 8.3 or newer. Select PHP 8.3 or later for this profile."))
                    }
                }
            } catch {
                add("runtime-\(tool)", String(localized: "Runtime: \(tool)"), error.localizedDescription, .broken,
                    remedy: String(localized: "Select an installed runtime in Dependencies and check this profile's runtime version."))
            }
        }
        if profile.engine == .custom {
            let executable = ShellEnvironment.shared.which(AppPaths.expand(profile.customCommand))
            add("custom", String(localized: "Custom executable"), profile.customCommand,
                executable == nil ? .broken : .note, remedy: executable == nil ? settingsRemedy : "")
        }

        if profile.templateId == "printshopcrm" {
            file("package", title: "PrintShopCRM package.json", url: root.appendingPathComponent("package.json"), recipe: true)
        }
        if ["web-to-print-store", "web-to-print-showcase"].contains(profile.templateId) {
            for (key, title, relative) in [
                ("wp-config", String(localized: "WordPress configuration"), "wp-config.php"),
                ("wp-admin", String(localized: "WordPress admin"), "wp-admin/install.php"),
                ("woocommerce", String(localized: "WooCommerce plugin"), "wp-content/plugins/woocommerce/woocommerce.php"),
                ("printcart", String(localized: "Printcart plugin"), "wp-content/plugins/printcart-integration/nbdesigner.php")
            ] {
                file(key, title: title, url: root.appendingPathComponent(relative), recipe: true)
            }
        }
        if profile.needsDatabase {
            add("database", String(localized: "Database"), databaseRunning ? String(localized: "Running") : String(localized: "Stopped"),
                databaseRunning ? .fine : state == .running ? .warning : .note,
                remedy: databaseRunning ? "" : String(localized: "Start MariaDB from Database before using this template."))
        }
        let failed: Bool
        if case .failed = state { failed = true } else { failed = false }
        add("state", String(localized: "Server state"), state.title,
            failed ? .broken : state == .running ? .fine : .note,
            remedy: failed ? String(localized: "Check Console for the start error.") : "")
        guard state == .running else {
            add("http", String(localized: "Local HTTP response"), String(localized: "Start the profile to check its HTTP response."), .note)
            return result
        }
        // Never send a diagnostic request to an arbitrary external hostname, nor
        // disable TLS verification globally for the sake of a local health check.
        let host = profile.host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard ["localhost", "127.0.0.1", "0.0.0.0", "::1", "::"].contains(host), (1...65535).contains(profile.port) else {
            add("http", String(localized: "Local HTTP response"), String(localized: "Automatic HTTP checks are limited to loopback addresses."), .note)
            return result
        }
        let address = "\(profile.scheme)://\(["::", "::1"].contains(host) ? "[::1]" : "127.0.0.1"):\(profile.port)/"
        var arguments = ["--silent", "--show-error", "--noproxy", "*", "--max-time", "4", "--output", "/dev/null", "--write-out", "%{http_code}"]
        if profile.httpsEnabled && !profile.certificatePath.isEmpty {
            arguments += ["--cacert", AppPaths.expand(profile.certificatePath)]
        }
        let response = await ProcessRunner.run("/usr/bin/curl", arguments + [address], timeout: 5)
        let code = Int(response.stdout) ?? 0
        let fine = response.succeeded && (200..<400).contains(code)
        add("http", String(localized: "Local HTTP response"), address + " · " + (response.succeeded ? String(code) : response.stderr),
            fine ? .fine : .warning,
            remedy: fine ? "" : String(localized: "Check Console, the site's index, authentication and HTTPS certificate."))
        return result
    }
}
