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
    private struct RecipeState: Codable {
        var recipeKind: String
        var databaseName: String?
        var completedAt: Date
    }

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

        let previous = readState(in: root)
        let configuredName = databaseName(in: root)
        let reusedName = previous?.databaseName ?? configuredName
        let name: String
        if let reusedName, !reusedName.isEmpty {
            name = reusedName
            log.system("Reusing the existing Web-to-Print database \(name).")
        } else {
            name = uniqueDatabaseName(profile.databaseName.isEmpty ? suggestedName(profile.name) : profile.databaseName,
                                      taken: Set(database.databases.map(\.name)))
            let user = "sm_" + name.prefix(45)
            let password = randomSecret()
            let created = await database.createDatabase(name: name, user: user, password: password)
            guard created.succeeded else { throw RecipeError.databaseCreation(created.combined) }
            try writeConfig(in: root, database: database, name: name, user: user, password: password,
                            showcase: template.recipeKind == "wordpress-w2p-showcase")
        }

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
        try writeState(.init(recipeKind: template.recipeKind, databaseName: name, completedAt: .now), in: root)
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
        try writeState(.init(recipeKind: "printshopcrm", databaseName: nil, completedAt: .now), in: root)
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
        if (!class_exists('WooCommerce')) { WP_CLI::error('WooCommerce is not active.'); }
        update_option('blogname', 'Друкарня «Відбиток»');
        update_option('blogdescription', 'Онлайн-замовлення друкованої продукції');
        update_option('timezone_string', 'Europe/Kyiv');
        foreach (array('woocommerce_currency' => 'UAH', 'woocommerce_currency_pos' => 'right_space',
          'woocommerce_price_num_decimals' => '0', 'woocommerce_price_thousand_sep' => ' ',
          'woocommerce_price_decimal_sep' => ',', 'woocommerce_default_country' => 'UA',
          'woocommerce_store_city' => 'Київ', 'woocommerce_allow_tracking' => 'no',
          'woocommerce_enable_guest_checkout' => 'yes') as $key => $value) { update_option($key, $value); }
        update_option('woocommerce_allowed_countries', 'specific');
        update_option('woocommerce_specific_allowed_countries', array('UA'));
        update_option('woocommerce_cod_settings', array('enabled'=>'yes','title'=>'Оплата при отриманні',
          'description'=>'Оплата готової продукції у друкарні або на пошті.'));
        update_option('woocommerce_bacs_settings', array('enabled'=>'yes','title'=>'Оплата на рахунок',
          'description'=>'Рахунок надішлемо після перевірки макета.'));
        $hasZone = false; foreach (WC_Shipping_Zones::get_zones() as $zone) if ($zone['zone_name'] === 'Україна') $hasZone = true;
        if (!$hasZone) { $zone = new WC_Shipping_Zone(); $zone->set_zone_name('Україна'); $zone->set_zone_order(1); $zone->add_location('UA','country'); $zone->save();
          $post = $zone->add_shipping_method('flat_rate'); update_option('woocommerce_flat_rate_'.$post.'_settings',array('title'=>'Нова Пошта','tax_status'=>'none','cost'=>'80'));
          $pickup = $zone->add_shipping_method('local_pickup'); update_option('woocommerce_local_pickup_'.$pickup.'_settings',array('title'=>'Самовивіз з друкарні','tax_status'=>'none','cost'=>'0')); }

        function sm_attribute($slug, $name, $terms) {
          if (!wc_attribute_taxonomy_id_by_name($slug)) wc_create_attribute(array('name'=>$name,'slug'=>$slug,'type'=>'select'));
          $taxonomy = 'pa_' . $slug;
          if (!taxonomy_exists($taxonomy)) register_taxonomy($taxonomy, array('product'), array('hierarchical'=>false,'show_ui'=>false));
          foreach ($terms as $termSlug=>$termName) if (!get_term_by('slug',$termSlug,$taxonomy)) wp_insert_term($termName,$taxonomy,array('slug'=>$termSlug));
        }
        sm_attribute('format','Формат',array('90x50'=>'90×50 мм','85x55'=>'85×55 мм','a6'=>'A6 (105×148 мм)','a5'=>'A5 (148×210 мм)','a4'=>'A4 (210×297 мм)','a2'=>'A2 (420×594 мм)'));
        sm_attribute('papir','Папір',array('kreid-300'=>'Крейдований 300 г/м²','dyzain-290'=>'Дизайнерський 290 г/м²','kreid-170'=>'Крейдований 170 г/м²','foto-200'=>'Фотопапір 200 г/м²','samoklei-mat'=>'Самоклейка матова'));
        sm_attribute('tyrazh','Тираж',array('10'=>'10 шт.','100'=>'100 шт.','500'=>'500 шт.','1000'=>'1000 шт.','5000'=>'5000 шт.'));
        sm_attribute('obrobka','Обробка',array('bez'=>'Без обробки','lam-mat'=>'Ламінування матове','lam-hlianets'=>'Ламінування глянцеве','porizka'=>'Контурна порізка'));

        function sm_product($item) {
          $existing = get_page_by_path($item['slug'], OBJECT, 'product'); if ($existing) return $existing->ID;
          $product = new WC_Product_Variable(); $product->set_name($item['name']); $product->set_slug($item['slug']); $product->set_status('publish'); $product->set_description($item['description']);
          $attributes = array(); foreach ($item['options'] as $slug=>$values) { $ids=array(); foreach($values as $value) { $term=get_term_by('slug',$value,'pa_'.$slug); if($term) $ids[]=$term->term_id; } $a=new WC_Product_Attribute(); $a->set_id(wc_attribute_taxonomy_id_by_name($slug)); $a->set_name('pa_'.$slug); $a->set_options($ids); $a->set_visible(true); $a->set_variation(true); $attributes[]=$a; }
          $product->set_attributes($attributes); $product->set_default_attributes(array('pa_format'=>$item['options']['format'][0],'pa_papir'=>$item['options']['papir'][0],'pa_tyrazh'=>$item['options']['tyrazh'][0],'pa_obrobka'=>$item['options']['obrobka'][0])); $id=$product->save();
          foreach($item['prices'] as $run=>$price) { $variation=new WC_Product_Variation(); $variation->set_parent_id($id); $variation->set_attributes(array('pa_format'=>'','pa_papir'=>'','pa_tyrazh'=>(string)$run,'pa_obrobka'=>'')); $variation->set_regular_price((string)$price); $variation->set_stock_status('instock'); $variation->set_status('publish'); $variation->save(); } WC_Product_Variable::sync($id); return $id;
        }
        $products=array(
          array('slug'=>'vizytky','name'=>'Візитки','description'=>'Класичні візитки на щільному папері.','options'=>array('format'=>array('90x50','85x55'),'papir'=>array('kreid-300','dyzain-290'),'tyrazh'=>array('100','500','1000'),'obrobka'=>array('bez','lam-mat','lam-hlianets')),'prices'=>array('100'=>350,'500'=>890,'1000'=>1290)),
          array('slug'=>'flaiery','name'=>'Флаєри','description'=>'Рекламні флаєри та листівки для акцій і заходів.','options'=>array('format'=>array('a6','a5','a4'),'papir'=>array('kreid-170'),'tyrazh'=>array('500','1000','5000'),'obrobka'=>array('bez','lam-hlianets')),'prices'=>array('500'=>790,'1000'=>1190,'5000'=>3990)),
          array('slug'=>'plakaty','name'=>'Плакати','description'=>'Плакати й афіші великого формату.','options'=>array('format'=>array('a2','a4'),'papir'=>array('kreid-170','foto-200'),'tyrazh'=>array('10','100'),'obrobka'=>array('bez','lam-mat')),'prices'=>array('10'=>450,'100'=>2990)),
          array('slug'=>'nalipky','name'=>'Наліпки','description'=>'Наліпки для пакування, етикеток і мерчу.','options'=>array('format'=>array('a6','90x50'),'papir'=>array('samoklei-mat'),'tyrazh'=>array('100','500','1000'),'obrobka'=>array('porizka','bez')),'prices'=>array('100'=>390,'500'=>1150,'1000'=>1890))
        ); foreach($products as $item) sm_product($item);
        foreach(array('shop'=>'Каталог','cart'=>'Кошик','checkout'=>'Оформлення замовлення','my-account'=>'Мій кабінет') as $slug=>$title) { $page=get_page_by_path($slug); if($page) wp_update_post(array('ID'=>$page->ID,'post_title'=>$title)); }
        $shop=wc_get_page_id('shop'); if($shop>0) { update_option('show_on_front','page'); update_option('page_on_front',$shop); }
        if (get_option('servermaster_showcase_orders') !== 'yes') {
          foreach(array(array('vizytky','500','processing','Олена Коваль'),array('flaiery','1000','on-hold','Ігор Бондар'),array('plakaty','100','completed','Андрій Мельник'),array('nalipky','1000','processing','Марія Шевченко')) as $demo) { $post=get_page_by_path($demo[0],OBJECT,'product'); if(!$post) continue; $product=wc_get_product($post->ID); $children=$product ? $product->get_children() : array(); $variation=$children ? wc_get_product($children[0]) : null; if(!$variation) continue; $order=wc_create_order(); $order->add_product($variation,1,array('variation'=>array('attribute_pa_tyrazh'=>$demo[1]))); $order->set_billing_first_name($demo[3]); $order->set_billing_country('UA'); $order->set_payment_method('cod'); $order->set_payment_method_title('Оплата при отриманні'); $order->calculate_totals(false); $order->update_status($demo[2],'Демо-замовлення ServerMaster.'); }
          update_option('servermaster_showcase_orders','yes');
        }
        """
        try await run(wp, ["eval", php], root: root, log: log)
    }

    private static func stateURL(in root: String) -> URL {
        URL(fileURLWithPath: root).appendingPathComponent(".servermaster-recipe.json")
    }

    private static func readState(in root: String) -> RecipeState? {
        let url = stateURL(in: root)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RecipeState.self, from: data)
    }

    private static func writeState(_ state: RecipeState, in root: String) throws {
        let data = try JSONEncoder().encode(state)
        try data.write(to: stateURL(in: root), options: .atomic)
    }

    private static func databaseName(in root: String) -> String? {
        let config = URL(fileURLWithPath: root).appendingPathComponent("wp-config.php")
        guard let text = try? String(contentsOf: config, encoding: .utf8) else { return nil }
        let pattern = #"define\(\s*['\"]DB_NAME['\"]\s*,\s*['\"]([^'\"]+)['\"]\s*\)"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
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
