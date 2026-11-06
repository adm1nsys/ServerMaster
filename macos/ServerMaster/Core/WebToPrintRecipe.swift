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
        let check = await command(wp, ["core", "is-installed"], root: root)
        let isFreshInstall = !check.succeeded
        if isFreshInstall {
            let adminPassword = randomSecret()
            try await run(wp, ["core", "install", "--url=\(profile.address)",
                               "--title=ServerMaster Web-to-Print",
                               "--admin_user=servermaster", "--admin_password=\(adminPassword)",
                               "--admin_email=servermaster@example.local", "--skip-email"], root: root, log: log)
            let notes = template.recipeKind == "wordpress-w2p-showcase" ? """
            # Друкарня «Відбиток» — демо Web-to-Print

            Магазин: \(profile.address)
            Адмінка: \(profile.address)/wp-admin/
            Логін: servermaster
            Пароль: \(adminPassword)

            Уже готово: україномовний магазин, товари з варіантами друку,
            «Нова Пошта», самовивіз, оплата при отриманні та демо-замовлення.
            """ : """
            # ServerMaster Web-to-Print

            Admin: \(profile.address)/wp-admin/
            User: servermaster
            Password: \(adminPassword)
            """
            try notes.write(to: URL(fileURLWithPath: root).appendingPathComponent("servermaster-demo.md"),
                         atomically: true, encoding: .utf8)
        }

        try await ensurePlugin("woocommerce", wp: wp, root: root, log: log)
        // The designer itself needs a Printcart account, but the integration is
        // part of this template on both platforms and must be present locally.
        try await ensurePlugin("printcart-integration", wp: wp, root: root, log: log)
        guard FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent("wp-content/plugins/woocommerce/woocommerce.php")),
              FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent("wp-content/plugins/printcart-integration/nbdesigner.php"))
        else { throw RecipeError.webToPrintPluginMissing }
        try await run(wp, ["option", "update", "woocommerce_currency", "UAH"], root: root, log: log)

        if template.recipeKind == "wordpress-w2p-showcase" {
            // Language packs need an internet connection once. They are optional so
            // an offline local install remains usable, just in its fallback locale.
            try await run(wp, ["language", "core", "install", "uk", "--activate"], root: root, log: log, allowFailure: true)
            try await run(wp, ["language", "plugin", "install", "woocommerce", "uk"], root: root, log: log, allowFailure: true)
            try await seedShowcase(wp, root: root, log: log, isFreshInstall: isFreshInstall)
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
        let entry = (root as NSString).appendingPathComponent(profile.nodeEntryFile)
        guard FileManager.default.fileExists(atPath: entry) else {
            throw RecipeError.printShopEntryMissing(profile.nodeEntryFile)
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

    /// `wp plugin install` fails when a partially completed earlier run already
    /// downloaded the plugin. Checking first makes the recipe actually resumable
    /// and matches the Windows downloader's existing-folder behaviour.
    private static func ensurePlugin(_ slug: String, wp: URL, root: String, log: ConsoleLog) async throws {
        let existing = await command(wp, ["plugin", "is-installed", slug], root: root)
        if existing.succeeded {
            try await run(wp, ["plugin", "activate", slug], root: root, log: log)
        } else {
            try await run(wp, ["plugin", "install", slug, "--activate"], root: root, log: log)
        }
    }

    private static func seedShowcase(_ wp: URL, root: String, log: ConsoleLog, isFreshInstall: Bool) async throws {
        let freshInstall = isFreshInstall ? "true" : "false"
        let php = """
        $sm_fresh_install = \(freshInstall);
        if (!class_exists('WooCommerce')) { WP_CLI::error('WooCommerce is not active.'); }
        update_option('blogname', 'Друкарня «Відбиток»');
        update_option('blogdescription', 'Онлайн-замовлення друкованої продукції');
        update_option('timezone_string', 'Europe/Kyiv');
        foreach (array('woocommerce_currency' => 'UAH', 'woocommerce_currency_pos' => 'right_space',
          'woocommerce_price_num_decimals' => '0', 'woocommerce_price_thousand_sep' => ' ',
          'woocommerce_price_decimal_sep' => ',', 'woocommerce_default_country' => 'UA',
          'woocommerce_store_address' => 'вул. Друкарська, 1', 'woocommerce_store_city' => 'Київ',
          'woocommerce_store_postcode' => '01001', 'woocommerce_allow_tracking' => 'no',
          'woocommerce_coming_soon' => 'no', 'woocommerce_store_pages_only' => 'no',
          'woocommerce_task_list_hidden' => 'yes', 'woocommerce_task_list_complete' => 'yes',
          'woocommerce_show_marketplace_suggestions' => 'no', 'woocommerce_calc_taxes' => 'no',
          'woocommerce_enable_guest_checkout' => 'yes', 'woocommerce_ship_to_countries' => '') as $key => $value) { update_option($key, $value); }
        update_option('woocommerce_allowed_countries', 'specific');
        update_option('woocommerce_specific_allowed_countries', array('UA'));
        update_option('woocommerce_default_customer_address', 'base');
        update_option('woocommerce_onboarding_profile', array('skipped' => true, 'completed' => true));
        delete_transient('_wc_activation_redirect');
        update_option('woocommerce_cod_settings', array('enabled'=>'yes','title'=>'Оплата при отриманні',
          'description'=>'Оплата готової продукції у друкарні або на пошті.'));
        update_option('woocommerce_bacs_settings', array('enabled'=>'yes','title'=>'Оплата на рахунок',
          'description'=>'Рахунок надішлемо після перевірки макета.'));
        $hasZone = false; foreach (WC_Shipping_Zones::get_zones() as $zone) if ($zone['zone_name'] === 'Україна') $hasZone = true;
        if (!$hasZone) { $zone = new WC_Shipping_Zone(); $zone->set_zone_name('Україна'); $zone->set_zone_order(1); $zone->add_location('UA','country'); $zone->save();
          $post = $zone->add_shipping_method('flat_rate'); update_option('woocommerce_flat_rate_'.$post.'_settings',array('title'=>'Нова Пошта','tax_status'=>'none','cost'=>'80'));
          $pickup = $zone->add_shipping_method('local_pickup'); update_option('woocommerce_local_pickup_'.$pickup.'_settings',array('title'=>'Самовивіз з друкарні','tax_status'=>'none','cost'=>'0')); }

        function sm_attribute($slug, $name, $terms) {
          if (!wc_attribute_taxonomy_id_by_name($slug)) wc_create_attribute(array('name'=>$name,'slug'=>$slug,'type'=>'select','order_by'=>'menu_order','has_archives'=>false));
          $taxonomy = 'pa_' . $slug;
          if (!taxonomy_exists($taxonomy)) register_taxonomy($taxonomy, array('product'), array('hierarchical'=>false,'show_ui'=>false));
          foreach ($terms as $termSlug=>$termName) if (!get_term_by('slug',$termSlug,$taxonomy)) wp_insert_term($termName,$taxonomy,array('slug'=>$termSlug));
        }
        sm_attribute('format','Формат',array('90x50'=>'90×50 мм','85x55'=>'85×55 мм','a6'=>'A6 (105×148 мм)','a5'=>'A5 (148×210 мм)','a4'=>'A4 (210×297 мм)','a3'=>'A3 (297×420 мм)','a2'=>'A2 (420×594 мм)','a1'=>'A1 (594×841 мм)','50x50'=>'50×50 мм','70x70'=>'70×70 мм'));
        sm_attribute('papir','Папір',array('kreid-300'=>'Крейдований 300 г/м²','dyzain-290'=>'Дизайнерський 290 г/м²','lion-250'=>'Льон 250 г/м²','kreid-130'=>'Крейдований 130 г/м²','kreid-170'=>'Крейдований 170 г/м²','foto-200'=>'Фотопапір 200 г/м²','samoklei-glianets'=>'Самоклейка глянцева','samoklei-mat'=>'Самоклейка матова'));
        sm_attribute('tyrazh','Тираж',array('10'=>'10 шт.','50'=>'50 шт.','100'=>'100 шт.','500'=>'500 шт.','1000'=>'1000 шт.','5000'=>'5000 шт.'));
        sm_attribute('obrobka','Обробка',array('bez'=>'Без обробки','lam-mat'=>'Ламінування матове','lam-hlianets'=>'Ламінування глянцеве','kuty'=>'Скруглення кутів','porizka'=>'Контурна порізка'));

        // Generated artwork makes the empty local catalogue presentation-ready.
        // Windows has Segoe fonts; macOS uses the bundled Helvetica or Arial font.
        function sm_image($slug, $title, $label, $colour, $w, $h) {
          if (!function_exists('imagecreatetruecolor')) return 0;
          $existing=get_page_by_path('sm-'.$slug,OBJECT,'attachment'); if($existing) return $existing->ID;
          $size=800; $im=imagecreatetruecolor($size,$size); list($r,$g,$b)=sscanf($colour,'#%02x%02x%02x');
          for($y=0;$y<$size;$y++){ $k=1-.38*$y/$size; imageline($im,0,$y,$size,$y,imagecolorallocate($im,(int)($r*$k),(int)($g*$k),(int)($b*$k))); }
          $scale=430/max($w,$h); $sw=(int)($w*$scale); $sh=(int)($h*$scale); $x=(int)(($size-$sw)/2); $top=(int)(($size-$sh)/2)-40;
          imagefilledrectangle($im,$x+16,$top+20,$x+$sw+16,$top+$sh+20,imagecolorallocatealpha($im,0,0,0,85));
          imagefilledrectangle($im,$x,$top,$x+$sw,$top+$sh,imagecolorallocate($im,251,250,247));
          foreach(array(array(0,174,239),array(236,0,140),array(255,222,0),array(35,31,32)) as $i=>$m){ $mx=$x+14+$i*26; imagefilledrectangle($im,$mx,$top+$sh-30,$mx+20,$top+$sh-12,imagecolorallocate($im,$m[0],$m[1],$m[2])); }
          $fonts=array('/System/Library/Fonts/Helvetica.ttc','/System/Library/Fonts/Supplemental/Arial Bold.ttf'); $font=''; foreach($fonts as $candidate) if(file_exists($candidate)){ $font=$candidate; break; }
          if(function_exists('imagettftext') && $font){ $white=imagecolorallocate($im,255,255,255); $box=imagettfbbox(46,0,$font,$title); imagettftext($im,46,0,(int)(($size-($box[2]-$box[0]))/2),$size-78,$white,$font,$title); $ink=imagecolorallocate($im,(int)($r*.7),(int)($g*.7),(int)($b*.7)); $box=imagettfbbox(24,0,$font,$label); imagettftext($im,24,0,(int)($x+($sw-($box[2]-$box[0]))/2),(int)($top+$sh/2+10),$ink,$font,$label); }
          ob_start(); imagepng($im); $png=ob_get_clean(); imagedestroy($im); $upload=wp_upload_bits('sm-'.$slug.'.png',null,$png); if(!empty($upload['error'])) return 0;
          $id=wp_insert_attachment(array('post_title'=>$title,'post_name'=>'sm-'.$slug,'post_mime_type'=>'image/png','post_status'=>'inherit'),$upload['file']); require_once ABSPATH.'wp-admin/includes/image.php'; wp_update_attachment_metadata($id,wp_generate_attachment_metadata($id,$upload['file'])); return $id;
        }

        $category=get_term_by('slug','drukovana-produktsiia','product_cat'); $categoryId=$category ? $category->term_id : 0;
        if(!$categoryId){ $created=wp_insert_term('Друкована продукція','product_cat',array('slug'=>'drukovana-produktsiia')); $categoryId=is_wp_error($created)?0:$created['term_id']; }
        $requirements='<h3>Вимоги до макета</h3><ul><li>PDF (PDF/X-1a) або TIFF, 300 dpi</li><li>Колірна модель CMYK, без RGB та Pantone</li><li>Вильоти 2 мм з кожного боку, важливі елементи — не ближче 3 мм до краю</li><li>Шрифти переведені в криві</li></ul><p>Перед друком дизайнер перевіряє макет і надсилає підтвердження.</p>';

        function sm_product($item, $categoryId, $requirements) {
          $existing = get_page_by_path($item['slug'], OBJECT, 'product'); if ($existing) return $existing->ID;
          $product = new WC_Product_Variable(); $product->set_name($item['name']); $product->set_slug($item['slug']); $product->set_status('publish'); $product->set_short_description($item['description']); $product->set_description('<p>'.$item['description'].'</p>'.$requirements); if($categoryId) $product->set_category_ids(array($categoryId));
          $attributes = array(); foreach ($item['options'] as $slug=>$values) { $ids=array(); foreach($values as $value) { $term=get_term_by('slug',$value,'pa_'.$slug); if($term) $ids[]=$term->term_id; } $a=new WC_Product_Attribute(); $a->set_id(wc_attribute_taxonomy_id_by_name($slug)); $a->set_name('pa_'.$slug); $a->set_options($ids); $a->set_visible(true); $a->set_variation(true); $attributes[]=$a; }
          $product->set_attributes($attributes); $product->set_default_attributes(array('pa_format'=>$item['options']['format'][0],'pa_papir'=>$item['options']['papir'][0],'pa_tyrazh'=>$item['options']['tyrazh'][0],'pa_obrobka'=>$item['options']['obrobka'][0])); $image=sm_image($item['slug'],$item['name'],$item['label'],$item['colour'],$item['w'],$item['h']); if($image) $product->set_image_id($image); $id=$product->save();
          foreach($item['prices'] as $run=>$price) { $variation=new WC_Product_Variation(); $variation->set_parent_id($id); $variation->set_attributes(array('pa_format'=>'','pa_papir'=>'','pa_tyrazh'=>(string)$run,'pa_obrobka'=>'')); $variation->set_regular_price((string)$price); $variation->set_stock_status('instock'); $variation->set_status('publish'); $variation->save(); } WC_Product_Variable::sync($id); return $id;
        }
        $products=array(
          array('slug'=>'vizytky','name'=>'Візитки','label'=>'90 × 50 мм','colour'=>'#3d5afe','w'=>90,'h'=>50,'description'=>'Класичні візитки на щільному папері: друк з двох боків, ламінування та скруглення кутів на вибір.','options'=>array('format'=>array('90x50','85x55'),'papir'=>array('kreid-300','dyzain-290','lion-250'),'tyrazh'=>array('100','500','1000'),'obrobka'=>array('bez','lam-mat','lam-hlianets','kuty')),'prices'=>array('100'=>350,'500'=>890,'1000'=>1290)),
          array('slug'=>'flaiery','name'=>'Флаєри','label'=>'A5','colour'=>'#e5484d','w'=>148,'h'=>210,'description'=>'Рекламні флаєри та листівки для акцій і заходів. Що більший тираж, то нижча ціна за примірник.','options'=>array('format'=>array('a6','a5','a4'),'papir'=>array('kreid-130','kreid-170'),'tyrazh'=>array('500','1000','5000'),'obrobka'=>array('bez','lam-hlianets')),'prices'=>array('500'=>790,'1000'=>1190,'5000'=>3990)),
          array('slug'=>'plakaty','name'=>'Плакати','label'=>'A2','colour'=>'#12a594','w'=>420,'h'=>594,'description'=>'Плакати й афіші великого формату для вітрин, виставок і подій.','options'=>array('format'=>array('a3','a2','a1'),'papir'=>array('kreid-170','foto-200'),'tyrazh'=>array('10','50','100'),'obrobka'=>array('bez','lam-mat')),'prices'=>array('10'=>450,'50'=>1690,'100'=>2990)),
          array('slug'=>'nalipky','name'=>'Наліпки','label'=>'50 × 50 мм','colour'=>'#f5a524','w'=>50,'h'=>50,'description'=>'Наліпки на самоклейці з контурною порізкою — для пакування, етикеток і мерчу.','options'=>array('format'=>array('50x50','70x70','a6'),'papir'=>array('samoklei-glianets','samoklei-mat'),'tyrazh'=>array('100','500','1000'),'obrobka'=>array('porizka','bez')),'prices'=>array('100'=>390,'500'=>1150,'1000'=>1890))
        ); foreach($products as $item) sm_product($item,$categoryId,$requirements);
        foreach(array('shop'=>'Каталог','cart'=>'Кошик','checkout'=>'Оформлення замовлення','my-account'=>'Мій кабінет') as $slug=>$title) { $page=get_page_by_path($slug); if($page) wp_update_post(array('ID'=>$page->ID,'post_title'=>$title)); }
        // Never alter a user's existing store on a retry. These are only the
        // stock WordPress/Printcart pages of a fresh Showcase installation.
        if ($sm_fresh_install) {
          foreach(array('create-your-own','design-studio','nbd-logged','templates','designer','product-builder','raq','upload-design-file','upload-your-file') as $slug) { $page=get_page_by_path($slug); if($page && $page->post_status==='publish') wp_update_post(array('ID'=>$page->ID,'post_status'=>'private')); }
          foreach(array(array('sample-page','page'),array('hello-world','post')) as $sample) { $post=get_page_by_path($sample[0],OBJECT,$sample[1]); if($post) wp_delete_post($post->ID,true); }
        }
        $shop=wc_get_page_id('shop'); if($shop>0) { update_option('show_on_front','page'); update_option('page_on_front',$shop); }
        if (get_option('servermaster_showcase_orders') !== 'yes') {
          $orders=array(
            array('Олена','Коваль','', 'olena.koval@example.local','+380671112233','Київ','vizytky','500',array('format'=>'90x50','papir'=>'dyzain-290','obrobka'=>'lam-mat'),'processing','Макет у PDF, CMYK. Прошу скруглити кути.','Макет перевірено, передано в друк.',1),
            array('Ігор','Бондар','Кав’ярня «Зерно»','zerno@example.local','+380503334455','Львів','flaiery','1000',array('format'=>'a5','papir'=>'kreid-170','obrobka'=>'lam-hlianets'),'on-hold','Флаєри для відкриття, потрібні до п’ятниці.','Очікуємо виправлений макет: текст ближче 3 мм до краю.',0),
            array('Андрій','Мельник','Театр «Сцена»','scena@example.local','+380937778899','Одеса','plakaty','50',array('format'=>'a2','papir'=>'foto-200','obrobka'=>'bez'),'completed','Афіші вистави.','Видано клієнту.',3),
            array('Марія','Шевченко','Пекарня «Колосок»','kolosok@example.local','+380665556677','Київ','nalipky','1000',array('format'=>'70x70','papir'=>'samoklei-mat','obrobka'=>'porizka'),'processing','Наліпки на коробки, контурна порізка по колу.','У порізці.',0)
          );
          foreach($orders as $o) { $post=get_page_by_path($o[6],OBJECT,'product'); if(!$post) continue; $product=wc_get_product($post->ID); $variation=null; foreach($product->get_children() as $childId) { $child=wc_get_product($childId); if($child && get_post_meta($childId,'attribute_pa_tyrazh',true)===$o[7]) { $variation=$child; break; } } if(!$variation) continue;
            $order=wc_create_order(array('customer_note'=>$o[10])); $chosen=array('attribute_pa_tyrazh'=>$o[7]); foreach($o[8] as $slug=>$value) $chosen['attribute_pa_'.$slug]=$value; $order->add_product($variation,1,array('variation'=>$chosen));
            $address=array('first_name'=>$o[0],'last_name'=>$o[1],'company'=>$o[2],'email'=>$o[3],'phone'=>$o[4],'city'=>$o[5],'country'=>'UA','address_1'=>'Відділення Нової Пошти №1'); $order->set_address($address,'billing'); $order->set_address($address,'shipping'); $order->set_payment_method('cod'); $order->set_payment_method_title('Оплата при отриманні');
            $shipping=new WC_Order_Item_Shipping(); $shipping->set_method_title('Нова Пошта'); $shipping->set_method_id('flat_rate'); $shipping->set_total(80); $order->add_item($shipping); $order->set_date_created(time()-$o[12]*DAY_IN_SECONDS-3600); $order->calculate_totals(false); $order->update_status($o[9],'Демо-замовлення ServerMaster.'); $order->add_order_note($o[11]); }
          update_option('servermaster_showcase_orders','yes');
        }
        WP_CLI::success('Друкарня «Відбиток» готова.');
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

    enum RecipeError: LocalizedError { case unsupported, missingWordPress, missingPrintShop, printShopEntryMissing(String), webToPrintPluginMissing, databaseUnavailable, databaseCreation(String), phpMissing, npmMissing, wpCLIUnavailable, commandFailed(String)
        var errorDescription: String? { switch self {
        case .unsupported: return "This project has no macOS setup recipe."
        case .missingWordPress: return "WordPress files are missing. Download the project into an empty folder first."
        case .missingPrintShop: return "Print Shop CRM files are missing. Download the project into an empty folder first."
        case .printShopEntryMissing(let entry): return "Print Shop CRM entry file was not found: \(entry)"
        case .webToPrintPluginMissing: return "WooCommerce or Printcart Integration was not installed completely."
        case .databaseUnavailable: return "MariaDB could not start."
        case .databaseCreation(let message): return message.isEmpty ? "Could not create the WordPress database." : message
        case .phpMissing: return "PHP is required to prepare WordPress."
        case .npmMissing: return "npm is required to prepare Print Shop CRM."
        case .wpCLIUnavailable: return "WP-CLI could not be downloaded."
        case .commandFailed(let message): return message.isEmpty ? "A WordPress setup command failed." : message
        } }
    }
}
