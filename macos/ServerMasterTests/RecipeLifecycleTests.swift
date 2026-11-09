import Foundation
import Testing
@testable import ServerMaster

/// Explicit opt-in: official source archives, disposable MariaDB/SQLite and
/// project directories; login Keychain and user projects are never accessed.
@MainActor
@Suite("T3 real recipe lifecycle", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["SERVERMASTER_TEST_RECIPES"] != nil))
struct RecipeLifecycleTests {
    private var fixtures: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["SERVERMASTER_TEST_RECIPES"]!) }
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("recipe-t3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    private func template(_ id: String) throws -> ProfileTemplate {
        try #require(ProfileTemplate.builtIn.first { $0.id == id })
    }
    private func database(_ directory: URL) throws -> DatabaseService {
        let access = DatabaseCredentialAccess(save: { _, _, _ in }, read: { _ in nil }, delete: { _ in })
        return DatabaseService(runtimeDirectory: directory.appendingPathComponent("database"),
            socketPath: "/tmp/sm-t3-\(UUID().uuidString.prefix(12)).sock",
            port: try BuiltinHTTPS.freeBackendPort(excluding: 3307), credentials: access)
    }
    private func wp(_ root: URL, _ php: String) async throws -> [String: Any] {
        let result = await ProcessRunner.run("php", [fixtures.appendingPathComponent("wp-cli.phar").path, "eval",
            "echo '\nT3JSON:'.json_encode((function(){ \(php) })(),JSON_UNESCAPED_UNICODE).'\n';"], cwd: root.path, timeout: 90)
        try #require(result.succeeded, "\(result.combined.suffix(3000))")
        let suffix = try #require(result.stdout.components(separatedBy: "T3JSON:").last)
        return try #require(JSONSerialization.jsonObject(with: Data(suffix.trimmingCharacters(in: .whitespacesAndNewlines).utf8)) as? [String: Any])
    }
    private func complete(_ root: URL) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(".servermaster-recipe.json").path)
    }

    @Test("WordPress/Woo/Printcart, partial Showcase recovery, Ukrainian data and repeat")
    func showcase() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try database(directory)
        defer { db.stopImmediately() }
        let root = directory.appendingPathComponent("Showcase with spaces")
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("wp-source/wordpress"), to: root)
        let source = try template("web-to-print-showcase")
        var profile = source.makeProfile(name: "Друкарня", port: try BuiltinHTTPS.freeBackendPort(excluding: db.port), root: root.path)
        profile.openBrowserOnStart = false
        let log = ConsoleLog()
        var failPlugin = true
        var failProduct = false
        var failOrder = false
        var failActivation = false
        var runtime = WebToPrintRecipe.Runtime()
        runtime.privateDirectory = directory.appendingPathComponent("credentials")
        runtime.wordpressCLI = fixtures.appendingPathComponent("wp-cli.phar")
        runtime.pluginArchives = ["woocommerce": fixtures.appendingPathComponent("woocommerce.zip"),
                                  "printcart-integration": fixtures.appendingPathComponent("printcart.zip")]
        runtime.execute = { executable, arguments, cwd, timeout in
            var args = arguments
            if failPlugin && args.contains("install") && args.contains(where: { $0.hasSuffix("printcart.zip") }) {
                failPlugin = false
                return CommandResult(exitCode: 1, stdout: "", stderr: "T3 injected plugin failure")
            }
            if failActivation && args.contains("activate") && args.contains("woocommerce") {
                failActivation = false
                return CommandResult(exitCode: 1, stdout: "", stderr: "T3 injected activation failure")
            }
            if let index = args.firstIndex(of: "eval"), index + 1 < args.count {
                if failProduct {
                    failProduct = false
                    args[index+1] = args[index+1].replacingOccurrences(of: "$variation->save();",
                        with: "$variation->save(); throw new Exception('T3 partial product');")
                } else if failOrder {
                    failOrder = false
                    args[index+1] = args[index+1].replacingOccurrences(of: "wc_transaction_query('commit');",
                        with: "throw new Exception('T3 partial orders'); wc_transaction_query('commit');")
                }
            }
            return await ProcessRunner.run(executable, args, cwd: cwd, timeout: timeout)
        }
        do {
            _ = try await WebToPrintRecipe.prepare(template: source, profile: profile, database: db, log: log, runtime: runtime)
            Issue.record("Injected plugin failure was ignored")
        } catch { #expect(!complete(root)) }
        let before = db.databases.map(\.name)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("wp-config.php").path))
        let config = root.appendingPathComponent("wp-config.php")
        let configText = try String(contentsOf: config, encoding: .utf8)
        try configText.replacingOccurrences(of: "define(", with: "define (").write(to: config, atomically: true, encoding: .utf8)
        failProduct = true
        do {
            _ = try await WebToPrintRecipe.prepare(template: source, profile: profile, database: db, log: log, runtime: runtime)
            Issue.record("Partial product failure was ignored")
        } catch { #expect(!complete(root)) }
        let partial = try await wp(root, "return ['products'=>(int)wp_count_posts('product')->publish,'variations'=>(int)wp_count_posts('product_variation')->publish];")
        #expect(partial["products"] as? Int == 1)
        #expect(partial["variations"] as? Int == 1)
        failOrder = true
        do {
            _ = try await WebToPrintRecipe.prepare(template: source, profile: profile, database: db, log: log, runtime: runtime)
            Issue.record("Partial order failure was ignored")
        } catch { #expect(!complete(root)) }
        let rolledBack = try await wp(root, "return ['orders'=>count(wc_get_orders(['limit'=>-1]))];")
        #expect(rolledBack["orders"] as? Int == 0, "An interrupted order must roll back")
        let outcome = try await WebToPrintRecipe.prepare(template: source, profile: profile, database: db, log: log, runtime: runtime)
        #expect(complete(root))
        await db.reloadDatabases()
        #expect(db.databases.map(\.name) == before, "Retries must reuse the configured DB")
        #expect(outcome.databaseName != nil)
        let check = """
        $products=wc_get_products(['limit'=>-1,'type'=>'variable']); $images=true;$variations=0;
        foreach($products as $p){$file=get_attached_file($p->get_image_id()); $size=$file?getimagesize($file):false; $images=$images && $size && $size[0]===800 && $size[1]===800; $variations+=count($p->get_children());}
        $orders=wc_get_orders(['limit'=>-1]); $ua=true;
        foreach($orders as $o){$ua=$ua && $o->get_currency()==='UAH' && $o->get_billing_country()==='UA' && count($o->get_items())===1;}
        return ['title'=>get_option('blogname'),'products'=>count($products),'variations'=>$variations,'images'=>$images,'orders'=>count($orders),'ua'=>$ua,'plugins'=>is_plugin_active('woocommerce/woocommerce.php') && is_plugin_active('printcart-integration/nbdesigner.php')];
        """
        let snapshot = try await wp(root, check)
        #expect(snapshot["title"] as? String == "Друкарня «Відбиток»")
        #expect(snapshot["products"] as? Int == 4)
        #expect(snapshot["variations"] as? Int == 12)
        #expect(snapshot["orders"] as? Int == 4)
        #expect(snapshot["images"] as? Bool == true)
        #expect(snapshot["ua"] as? Bool == true)
        #expect(snapshot["plugins"] as? Bool == true)
        let credentials = directory.appendingPathComponent("credentials/\(profile.id.uuidString).txt")
        let privateText = try String(contentsOf: credentials, encoding: .utf8)
        let password = try #require(privateText.components(separatedBy: "Password: ").last?.trimmingCharacters(in: .whitespacesAndNewlines))
        let publicNotes = try String(contentsOf: root.appendingPathComponent("servermaster-demo.md"), encoding: .utf8)
        #expect(!publicNotes.contains(password))
        let permissions = try FileManager.default.attributesOfItem(atPath: credentials.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        let pages = try await wp(root, "return ['private'=>get_page_by_path('create-your-own')?->post_status,'sample'=>get_page_by_path('sample-page')===null];")
        #expect(pages["private"] as? String != "publish", "A fresh install remains fresh after a failed plugin attempt")
        #expect(pages["sample"] as? Bool == true)

        failActivation = true
        do {
            _ = try await WebToPrintRecipe.prepare(template: source, profile: profile, database: db, log: log, runtime: runtime)
            Issue.record("A stale completion marker survived a failed retry")
        } catch { #expect(!complete(root)) }
        _ = try await WebToPrintRecipe.prepare(template: source, profile: profile, database: db, log: log, runtime: runtime)
        #expect(complete(root))
        let repeated = try await wp(root, check)
        #expect(repeated["orders"] as? Int == 4)
        #expect(repeated["variations"] as? Int == 12)
        // Exercise both WooCommerce order storage implementations. A new HPOS
        // demo set must also survive an interrupted first order and a repeat.
        _ = try await wp(root, "foreach(wc_get_orders(['limit'=>-1]) as $o){delete_option($o->get_meta('_servermaster_demo_key'));$o->delete(true);} delete_option('servermaster_showcase_orders'); update_option('woocommerce_custom_orders_table_enabled','yes'); return ['ok'=>true];")
        failOrder = true
        do {
            _ = try await WebToPrintRecipe.prepare(template: source, profile: profile, database: db, log: log, runtime: runtime)
            Issue.record("HPOS partial order failure was ignored")
        } catch { #expect(!complete(root)) }
        _ = try await WebToPrintRecipe.prepare(template: source, profile: profile, database: db, log: log, runtime: runtime)
        _ = try await WebToPrintRecipe.prepare(template: source, profile: profile, database: db, log: log, runtime: runtime)
        let hpos = try await wp(root, "return ['enabled'=>\\Automattic\\WooCommerce\\Utilities\\OrderUtil::custom_orders_table_usage_is_enabled(),'orders'=>count(wc_get_orders(['limit'=>-1]))];")
        #expect(hpos["enabled"] as? Bool == true)
        #expect(hpos["orders"] as? Int == 4)
        let controller = ServerController(runtimeRoot: directory.appendingPathComponent("runtime"))
        defer { controller.stopImmediately() }
        var settings = AppSettings(); settings.writeLogsToFile = false
        await controller.start(profile: profile, settings: settings)
        try #require(controller.state == .running, "\(controller.log.plainText)")
        let page = await ProcessRunner.run("/usr/bin/curl", ["--silent","--show-error","--fail","--location","--max-time","15",profile.address])
        #expect(page.succeeded && page.stdout.contains("Відбиток"), "\(page.combined.suffix(1000))")
        await controller.stop(settings: settings)

        // Store is its own recipe, without Showcase catalogue/seeding.
        let store = directory.appendingPathComponent("Store")
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("wp-source/wordpress"), to: store)
        let storeTemplate = try template("web-to-print-store")
        var storeProfile = storeTemplate.makeProfile(name: "Store", port: try BuiltinHTTPS.freeBackendPort(excluding: db.port), root: store.path)
        storeProfile.openBrowserOnStart = false
        _ = try await WebToPrintRecipe.prepare(template: storeTemplate, profile: storeProfile, database: db, log: log, runtime: runtime)
        let plain = try await wp(store, "return ['products'=>(int)wp_count_posts('product')->publish,'currency'=>get_option('woocommerce_currency')];")
        #expect(complete(store))
        #expect(plain["products"] as? Int == 0)
        #expect(plain["currency"] as? String == "UAH")
    }

    @Test("CRM failure/retry, SQLite preservation, environment and actual HTTP startup")
    func crm() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("CRM with spaces")
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("crm-source/printshopcrm-main"), to: root)
        let source = try template("printshopcrm")
        let db = try database(directory) // Not started: CRM must never require MariaDB.
        var profile = source.makeProfile(name: "CRM", port: try BuiltinHTTPS.freeBackendPort(excluding: 0), root: root.path)
        profile.openBrowserOnStart = false
        let log = ConsoleLog()
        var failSeed = true
        var seedRuns = 0
        var enteredInstall = false
        var releaseInstall = false
        var holdInstall = true
        var runtime = WebToPrintRecipe.Runtime()
        runtime.execute = { executable, args, cwd, timeout in
            if args == ["install"] && holdInstall {
                holdInstall = false
                enteredInstall = true
                while !releaseInstall { try? await Task.sleep(for: .milliseconds(20)) }
            }
            if args == ["run", "seed"] {
                seedRuns += 1
                if failSeed { failSeed = false; return CommandResult(exitCode: 1, stdout: "", stderr: "T3 injected seed failure") }
            }
            return await ProcessRunner.run(executable, args, cwd: cwd, env: ["npm_config_cache": directory.appendingPathComponent("npm-cache").path], timeout: timeout)
        }
        let firstAttempt = Task {
            try await WebToPrintRecipe.prepare(template: source, profile: profile, database: db, log: log, runtime: runtime)
        }
        for _ in 0..<100 where !enteredInstall { try? await Task.sleep(for: .milliseconds(50)) }
        #expect(enteredInstall)
        var alias = profile
        alias.rootPath = root.path + "/../CRM with spaces"
        do {
            _ = try await WebToPrintRecipe.prepare(template: source, profile: alias, database: db, log: log, runtime: runtime)
            Issue.record("Concurrent preparation of the same directory was allowed")
        } catch WebToPrintRecipe.RecipeError.alreadyPreparing { }
        catch { Issue.record("Wrong concurrent preparation error: \(error)") }
        releaseInstall = true
        do {
            _ = try await firstAttempt.value
            Issue.record("CRM seed failure was ignored")
        } catch { #expect(!complete(root)) }
        _ = try await WebToPrintRecipe.prepare(template: source, profile: profile, database: db, log: log, runtime: runtime)
        #expect(complete(root))
        #expect(seedRuns == 2)
        let environment = try String(contentsOf: root.appendingPathComponent(".env"), encoding: .utf8)
        let sqlite = root.appendingPathComponent("data/printshop.db")
        let header = try FileHandle(forReadingFrom: sqlite)
        #expect(try header.read(upToCount: 16) == Data("SQLite format 3\0".utf8))
        try header.close()
        let sentinel = root.appendingPathComponent("data/uploads/keep-me.txt")
        try "existing upload".write(to: sentinel, atomically: true, encoding: .utf8)
        _ = try await WebToPrintRecipe.prepare(template: source, profile: profile, database: db, log: log, runtime: runtime)
        #expect(seedRuns == 2, "A repeat must not wipe/reseed an existing CRM DB")
        #expect(try String(contentsOf: root.appendingPathComponent(".env"), encoding: .utf8) == environment)
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "existing upload")
        let generated = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("data/uploads").path)
        #expect(generated.contains(where: { $0.hasSuffix(".svg") }), "Seed artwork must land in the configured uploads folder")
        let probe = "import {DatabaseSync} from 'node:sqlite';const db=new DatabaseSync('data/printshop.db');console.log(db.prepare('SELECT filename FROM art_versions LIMIT 1').get().filename);db.close();"
        let artifact = await ProcessRunner.run("node", ["--input-type=module", "-e", probe], cwd: root.path)
        try #require(artifact.succeeded, "\(artifact.combined)")
        #expect(db.state != .running)
        let controller = ServerController(runtimeRoot: directory.appendingPathComponent("runtime"))
        defer { controller.stopImmediately() }
        var settings = AppSettings(); settings.writeLogsToFile = false
        await controller.start(profile: profile, settings: settings)
        try #require(controller.state == .running, "\(controller.log.plainText)")
        let response = await ProcessRunner.run("/usr/bin/curl", ["--silent","--show-error","--fail","--max-time","10",profile.address + "/health"])
        #expect(response.succeeded && response.stdout.contains("ok"), "\(response.combined)\n\(controller.log.plainText)")
        let image = await ProcessRunner.run("/usr/bin/curl", ["--silent", "--show-error", "--fail", "--max-time", "10", profile.address + "/uploads/" + artifact.stdout.trimmingCharacters(in: .whitespacesAndNewlines)])
        #expect(image.succeeded && image.stdout.contains("<svg"), "\(image.combined)")
        await controller.stop(settings: settings)
        let original = try Data(contentsOf: sqlite)
        try Data("not a SQLite database".utf8).write(to: sqlite, options: .atomic)
        do {
            _ = try await WebToPrintRecipe.prepare(template: source, profile: profile, database: db, log: log, runtime: runtime)
            Issue.record("A corrupt existing SQLite was marked ready")
        } catch { #expect(!complete(root)) }
        #expect(seedRuns == 2, "A corrupt user DB must not be wiped by seed")
        #expect(try Data(contentsOf: sqlite) == Data("not a SQLite database".utf8))
        try original.write(to: sqlite, options: .atomic)
    }
}
