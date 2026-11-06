//
//  WebToPrintRecipe.swift
//  ServerMaster
//
//  The macOS counterpart of the Windows Web-to-Print preparation flow. It is
//  deliberately resumable: downloaded project files are never deleted when a
//  dependency, network request or WordPress command fails.
//

import Foundation
import CryptoKit

nonisolated enum WebToPrintRecipe {
    struct Outcome: Sendable {
        var databaseName: String?
    }

    static func prepare(template: ProfileTemplate, profile: ServerProfile,
                        database: DatabaseService, log: ConsoleLog) async throws -> Outcome {
        switch template.packageKind {
        case "wordpress-w2p":
            return try await prepareWebToPrint(template: template, profile: profile, database: database, log: log)
        case "printshopcrm":
            try await preparePrintShopCRM(profile: profile, log: log)
            return Outcome(databaseName: nil)
        default:
            throw RecipeError.unsupported
        }
    }

    private static func prepareWebToPrint(template: ProfileTemplate, profile: ServerProfile,
                                          database: DatabaseService, log: ConsoleLog) async throws -> Outcome {
        let root = AppPaths.expand(profile.rootPath)
        guard FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent("wp-config-sample.php")) else {
            throw RecipeError.missingWordPress
        }

        await database.start()
        guard database.state == .running else { throw RecipeError.databaseUnavailable }

        let name = uniqueDatabaseName(profile.databaseName.isEmpty ? suggestedName(profile.name) : profile.databaseName,
                                      taken: Set(database.databases.map(\.name)))
        let user = "sm_" + name.prefix(45)
        let password = randomSecret()
        let created = await database.createDatabase(name: name, user: user, password: password)
        guard created.succeeded else { throw RecipeError.databaseCreation(created.combined) }
        try writeConfig(in: root, database: database, name: name, user: user, password: password,
                        showcase: template.recipeKind == "wordpress-w2p-showcase")

        let wp = try await wordpressCLI(log: log)
        try await run(wp, ["core", "is-installed"], root: root, log: log, allowFailure: true)
        let check = await command(wp, ["core", "is-installed"], root: root)
        if !check.succeeded {
            let adminPassword = randomSecret()
            try await run(wp, ["core", "install", "--url=\(profile.address)",
                               "--title=ServerMaster Web-to-Print",
                               "--admin_user=servermaster", "--admin_password=\(adminPassword)",
                               "--admin_email=servermaster@example.local", "--skip-email"], root: root, log: log)
            try """
            # ServerMaster Web-to-Print

            Admin: \(profile.address)/wp-admin/
            User: servermaster
            Password: \(adminPassword)
            """.write(to: URL(fileURLWithPath: root).appendingPathComponent("servermaster-demo.md"),
                         atomically: true, encoding: .utf8)
        }

        try await run(wp, ["plugin", "install", "woocommerce", "--activate"], root: root, log: log)
        // Printcart is optional at runtime: its designer requires a separate
        // cloud account, so a local store must remain usable without it.
        _ = await command(wp, ["plugin", "install", "printcart-integration", "--activate"], root: root)
        try await run(wp, ["option", "update", "woocommerce_currency", "UAH"], root: root, log: log)

        if template.recipeKind == "wordpress-w2p-showcase" {
            try await seedShowcase(wp, root: root, log: log)
        }
        log.system("Web-to-Print preparation completed. Open \(profile.address).")
        return Outcome(databaseName: name)
    }

    private static func preparePrintShopCRM(profile: ServerProfile, log: ConsoleLog) async throws {
        let root = AppPaths.expand(profile.rootPath)
        guard FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent("package.json")) else {
            throw RecipeError.missingPrintShop
        }
        guard ShellEnvironment.shared.which("npm") != nil else { throw RecipeError.npmMissing }
        let data = URL(fileURLWithPath: root).appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: data.appendingPathComponent("uploads", isDirectory: true),
                                                withIntermediateDirectories: true)
        let environment = URL(fileURLWithPath: root).appendingPathComponent(".env")
        if !FileManager.default.fileExists(atPath: environment.path) {
            let database = data.appendingPathComponent("printshop.db").path
            let uploads = data.appendingPathComponent("uploads", isDirectory: true).path
            try """
            PORT=\(profile.port)
            PSC_HOST=127.0.0.1
            PSC_AUTH=0
            PSC_DB=\(database)
            PSC_UPLOADS=\(uploads)
            PSC_SECRET=\(randomSecret())
            """.write(to: environment, atomically: true, encoding: .utf8)
        }
        try await runExecutable("npm", ["install"], root: root, log: log, timeout: 600)
        // Seeding is optional in upstream versions; do not turn an otherwise
        // usable install into a failure merely because this script is absent.
        _ = await ProcessRunner.run("npm", ["run", "seed"], cwd: root, timeout: 300)
        guard FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent("node_modules")) else {
            throw RecipeError.commandFailed("npm install completed but node_modules was not created.")
        }
        log.system("Print Shop CRM is ready in \(root).")
    }

    private static func wordpressCLI(log: ConsoleLog) async throws -> URL {
        if let installed = ShellEnvironment.shared.which("wp") {
            return URL(fileURLWithPath: installed)
        }
        guard ShellEnvironment.shared.which("php") != nil else { throw RecipeError.phpMissing }
        let tool = AppPaths.subdir("Tools").appendingPathComponent("wp-cli.phar")
        if !FileManager.default.fileExists(atPath: tool.path) {
            log.system("Downloading WP-CLI…")
            let source = URL(string: "https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar")!
            let (temporary, response) = try await URLSession.shared.download(from: source)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw RecipeError.wpCLIUnavailable }
            try FileManager.default.moveItem(at: temporary, to: tool)
        }
        return tool
    }

    private static func command(_ wp: URL, _ args: [String], root: String) async -> CommandResult {
        if wp.lastPathComponent == "wp" { return await ProcessRunner.run(wp.path, args, cwd: root, timeout: 300) }
        guard let php = ShellEnvironment.shared.which("php") else {
            return CommandResult(exitCode: 127, stdout: "", stderr: "PHP was not found")
        }
        return await ProcessRunner.run(php, [wp.path] + args, cwd: root, timeout: 300)
    }

    private static func run(_ wp: URL, _ args: [String], root: String, log: ConsoleLog,
                            allowFailure: Bool = false) async throws {
        let result = await command(wp, args, root: root)
        if !result.combined.isEmpty { log.append(result.combined, stream: result.succeeded ? .stdout : .stderr) }
        if !allowFailure && !result.succeeded { throw RecipeError.commandFailed(result.combined) }
    }

    private static func runExecutable(_ executable: String, _ args: [String], root: String,
                                      log: ConsoleLog, timeout: TimeInterval) async throws {
        let result = await ProcessRunner.run(executable, args, cwd: root, timeout: timeout)
        if !result.combined.isEmpty { log.append(result.combined, stream: result.succeeded ? .stdout : .stderr) }
        if !result.succeeded { throw RecipeError.commandFailed(result.combined) }
    }

    private static func seedShowcase(_ wp: URL, root: String, log: ConsoleLog) async throws {
        let php = """
        update_option('blogname', 'Друкарня «Відбиток»');
        update_option('blogdescription', 'Онлайн-замовлення друкованої продукції');
        update_option('woocommerce_currency', 'UAH');
        foreach ([['Візитки','350'],['Флаєри','500'],['Плакати','800'],['Наліпки','300']] as $item) {
          $existing = get_page_by_title($item[0], OBJECT, 'product');
          if (!$existing && class_exists('WC_Product_Simple')) { $p = new WC_Product_Simple(); $p->set_name($item[0]); $p->set_regular_price($item[1]); $p->set_status('publish'); $p->save(); }
        }
        """
        try await run(wp, ["eval", php], root: root, log: log)
    }

    private static func writeConfig(in root: String, database: DatabaseService, name: String, user: String,
                                    password: String, showcase: Bool) throws {
        let destination = URL(fileURLWithPath: root).appendingPathComponent("wp-config.php")
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }
        let sample = try String(contentsOf: URL(fileURLWithPath: root).appendingPathComponent("wp-config-sample.php"))
        let config = sample.replacingOccurrences(of: "database_name_here", with: name)
            .replacingOccurrences(of: "username_here", with: user)
            .replacingOccurrences(of: "password_here", with: password)
            .replacingOccurrences(of: "localhost", with: "127.0.0.1:\(database.port)")
            .replacingOccurrences(of: "$table_prefix = 'wp_';", with: "$table_prefix = 'wp_';\ndefine('WP_ENVIRONMENT_TYPE', 'local');\ndefine('DISALLOW_FILE_EDIT', true);" + (showcase ? "\ndefine('DISABLE_WP_CRON', true);" : ""))
        try config.write(to: destination, atomically: true, encoding: .utf8)
    }

    private static func suggestedName(_ name: String) -> String {
        let safe = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }
        return String(safe).trimmingCharacters(in: CharacterSet(charactersIn: "_")) + "_w2p"
    }
    private static func uniqueDatabaseName(_ base: String, taken: Set<String>) -> String {
        let trimmed = String(base.prefix(58))
        var candidate = trimmed; var suffix = 2
        while taken.contains(candidate) { candidate = String(trimmed.prefix(58)) + "_\(suffix)"; suffix += 1 }
        return candidate
    }
    private static func randomSecret() -> String { SHA256.hash(data: Data(UUID().uuidString.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined() }

    enum RecipeError: LocalizedError { case unsupported, missingWordPress, missingPrintShop, databaseUnavailable, databaseCreation(String), phpMissing, npmMissing, wpCLIUnavailable, commandFailed(String)
        var errorDescription: String? { switch self {
        case .unsupported: return "This project has no macOS setup recipe."
        case .missingWordPress: return "WordPress files are missing. Download the project into an empty folder first."
        case .missingPrintShop: return "Print Shop CRM files are missing. Download the project into an empty folder first."
        case .databaseUnavailable: return "MariaDB could not start."
        case .databaseCreation(let message): return message.isEmpty ? "Could not create the WordPress database." : message
        case .phpMissing: return "PHP is required to prepare WordPress."
        case .npmMissing: return "npm is required to prepare Print Shop CRM."
        case .wpCLIUnavailable: return "WP-CLI could not be downloaded."
        case .commandFailed(let message): return message.isEmpty ? "A WordPress setup command failed." : message
        } }
    }
}
