using ServerMaster.Windows.Models;

namespace ServerMaster.Windows.Services;

/// <summary>
/// Fills the Web-to-Print Showcase template: a Ukrainian print shop that is ready to present the
/// moment it opens. Everything is seeded by one PHP file in one WP-CLI run (each run boots
/// WordPress again, which is the slow part on a weak laptop): store settings, print attributes
/// (format, paper, run, finish), variable products with prices and generated images, delivery,
/// payment and a few orders in different production states. The seed is safe to run twice.
/// </summary>
public static class ShowcaseStore
{
    public const string SeedFileName = "servermaster-showcase-seed.php";

    public static async Task PrepareAsync(ServerProfile profile, string root, ConsoleLog log, Func<IReadOnlyList<string>, TimeSpan, Task> wpCli)
    {
        // Ukrainian for WordPress and WooCommerce; needs the internet once, and the store still
        // works in English if the language packs cannot be downloaded.
        log.System("Installing the Ukrainian language for WordPress and WooCommerce.");
        await wpCli(["language", "core", "install", "uk", "--activate"], TimeSpan.FromMinutes(3));
        await wpCli(["language", "plugin", "install", "woocommerce", "uk"], TimeSpan.FromMinutes(3));

        var seed = Path.Combine(root, "wp-content", SeedFileName);
        await File.WriteAllTextAsync(seed, Seed);
        try
        {
            log.System("Filling the print shop: products, print options, delivery, payment and orders.");
            await wpCli(["eval-file", seed], TimeSpan.FromMinutes(6));
        }
        finally { File.Delete(seed); }
    }

    public static Task WriteNotesAsync(string path, ServerProfile profile, string user, string password, bool existingInstall)
    {
        if (existingInstall && File.Exists(path)) return Task.CompletedTask;
        var admin = profile.Address.TrimEnd('/') + "/wp-admin/";
        // Only a re-run in the same folder keeps an existing WordPress; its password is unchanged.
        if (existingInstall) password = "не змінювався (той самий, що й під час першого встановлення в цій папці)";
        return File.WriteAllTextAsync(path, $"""
            # Друкарня «Відбиток» — демо Web-to-Print

            Магазин: {profile.Address}
            Адмінка: {admin}
            Логін: {user}
            Пароль: {password}

            Що вже готово:
            - товари «Візитки», «Флаєри», «Плакати», «Наліпки» з вибором формату, паперу,
              тиражу й обробки та цінами за тираж;
            - доставка «Нова Пошта» і самовивіз, оплата при отриманні або на рахунок;
            - замовлення у різних станах виробництва (WooCommerce → Замовлення).

            Конструктор макетів Printcart працює лише з інтернетом і обліковим записом Printcart.
            """);
    }

    private const string Seed = """
        <?php
        // ServerMaster Web-to-Print Showcase seed. Runs once through `wp eval-file`; safe to repeat.
        if (!class_exists('WooCommerce')) { WP_CLI::error('WooCommerce is not active.'); }

        // --- Store --------------------------------------------------------------------------
        update_option('blogname', 'Друкарня «Відбиток»');
        update_option('blogdescription', 'Онлайн-замовлення друкованої продукції');
        update_option('timezone_string', 'Europe/Kyiv');
        foreach (array(
            'woocommerce_currency' => 'UAH',
            'woocommerce_currency_pos' => 'right_space',
            'woocommerce_price_num_decimals' => '0',
            'woocommerce_price_thousand_sep' => ' ',
            'woocommerce_price_decimal_sep' => ',',
            'woocommerce_default_country' => 'UA',
            'woocommerce_store_address' => 'вул. Друкарська, 1',
            'woocommerce_store_city' => 'Київ',
            'woocommerce_store_postcode' => '01001',
            'woocommerce_allow_tracking' => 'no',
            'woocommerce_coming_soon' => 'no',
            'woocommerce_store_pages_only' => 'no',
            'woocommerce_task_list_hidden' => 'yes',
            'woocommerce_task_list_complete' => 'yes',
            'woocommerce_show_marketplace_suggestions' => 'no',
            'woocommerce_calc_taxes' => 'no',
            'woocommerce_enable_guest_checkout' => 'yes',
            'woocommerce_ship_to_countries' => '',
        ) as $key => $value) { update_option($key, $value); }
        // A Ukrainian shop: the country is filled in at checkout instead of a list of every country.
        update_option('woocommerce_allowed_countries', 'specific');
        update_option('woocommerce_specific_allowed_countries', array('UA'));
        update_option('woocommerce_default_customer_address', 'base');
        update_option('woocommerce_onboarding_profile', array('skipped' => true, 'completed' => true));
        delete_transient('_wc_activation_redirect');

        // --- Payment and delivery -----------------------------------------------------------
        update_option('woocommerce_cod_settings', array('enabled' => 'yes', 'title' => 'Оплата при отриманні',
            'description' => 'Оплата готової продукції у друкарні або на пошті.', 'instructions' => '',
            'enable_for_methods' => array(), 'enable_for_virtual' => 'yes'));
        update_option('woocommerce_bacs_settings', array('enabled' => 'yes', 'title' => 'Оплата на рахунок',
            'description' => 'Рахунок надішлемо після перевірки макета.', 'instructions' => 'Рахунок надішлемо після перевірки макета.'));
        $hasZone = false;
        foreach (WC_Shipping_Zones::get_zones() as $zone) { if ($zone['zone_name'] === 'Україна') { $hasZone = true; } }
        if (!$hasZone) {
            $zone = new WC_Shipping_Zone();
            $zone->set_zone_name('Україна');
            $zone->set_zone_order(1);
            $zone->add_location('UA', 'country');
            $zone->save();
            $post = $zone->add_shipping_method('flat_rate');
            update_option('woocommerce_flat_rate_' . $post . '_settings', array('title' => 'Нова Пошта', 'tax_status' => 'none', 'cost' => '80'));
            $pickup = $zone->add_shipping_method('local_pickup');
            update_option('woocommerce_local_pickup_' . $pickup . '_settings', array('title' => 'Самовивіз з друкарні', 'tax_status' => 'none', 'cost' => '0'));
        }

        // --- Print options as WooCommerce attributes ----------------------------------------
        function sm_attribute($slug, $name, $terms) {
            if (!wc_attribute_taxonomy_id_by_name($slug)) {
                wc_create_attribute(array('name' => $name, 'slug' => $slug, 'type' => 'select', 'order_by' => 'menu_order', 'has_archives' => false));
            }
            $taxonomy = 'pa_' . $slug;
            if (!taxonomy_exists($taxonomy)) {
                register_taxonomy($taxonomy, array('product'), array('hierarchical' => false, 'show_ui' => false, 'query_var' => true, 'rewrite' => false));
            }
            foreach ($terms as $termSlug => $termName) {
                if (!get_term_by('slug', $termSlug, $taxonomy)) { wp_insert_term($termName, $taxonomy, array('slug' => $termSlug)); }
            }
        }
        sm_attribute('format', 'Формат', array('90x50' => '90×50 мм', '85x55' => '85×55 мм', 'a6' => 'A6 (105×148 мм)', 'a5' => 'A5 (148×210 мм)',
            'a4' => 'A4 (210×297 мм)', 'a3' => 'A3 (297×420 мм)', 'a2' => 'A2 (420×594 мм)', 'a1' => 'A1 (594×841 мм)', '50x50' => '50×50 мм', '70x70' => '70×70 мм'));
        sm_attribute('papir', 'Папір', array('kreid-300' => 'Крейдований 300 г/м²', 'dyzain-290' => 'Дизайнерський 290 г/м²', 'lion-250' => 'Льон 250 г/м²',
            'kreid-130' => 'Крейдований 130 г/м²', 'kreid-170' => 'Крейдований 170 г/м²', 'foto-200' => 'Фотопапір 200 г/м²',
            'samoklei-glianets' => 'Самоклейка глянцева', 'samoklei-mat' => 'Самоклейка матова'));
        sm_attribute('tyrazh', 'Тираж', array('10' => '10 шт.', '50' => '50 шт.', '100' => '100 шт.', '500' => '500 шт.', '1000' => '1000 шт.', '5000' => '5000 шт.'));
        sm_attribute('obrobka', 'Обробка', array('bez' => 'Без обробки', 'lam-mat' => 'Ламінування матове', 'lam-hlianets' => 'Ламінування глянцеве',
            'kuty' => 'Скруглення кутів', 'porizka' => 'Контурна порізка'));

        // --- Product images, drawn with GD: the sheet in its proportions with CMYK marks ------
        function sm_image($slug, $title, $label, $colour, $w, $h) {
            if (!function_exists('imagecreatetruecolor')) { return 0; }
            $existing = get_page_by_path('sm-' . $slug, OBJECT, 'attachment');
            if ($existing) { return $existing->ID; }
            $size = 800;
            $im = imagecreatetruecolor($size, $size);
            list($r, $g, $b) = sscanf($colour, '#%02x%02x%02x');
            for ($y = 0; $y < $size; $y++) {
                $k = 1 - 0.38 * $y / $size;
                imageline($im, 0, $y, $size, $y, imagecolorallocate($im, (int)($r * $k), (int)($g * $k), (int)($b * $k)));
            }
            $scale = 430 / max($w, $h);
            $sw = (int)($w * $scale); $sh = (int)($h * $scale);
            $x = (int)(($size - $sw) / 2); $top = (int)(($size - $sh) / 2) - 40;
            imagefilledrectangle($im, $x + 16, $top + 20, $x + $sw + 16, $top + $sh + 20, imagecolorallocatealpha($im, 0, 0, 0, 85));
            imagefilledrectangle($im, $x, $top, $x + $sw, $top + $sh, imagecolorallocate($im, 251, 250, 247));
            $marks = array(array(0, 174, 239), array(236, 0, 140), array(255, 222, 0), array(35, 31, 32));
            foreach ($marks as $i => $m) {
                $mx = $x + 14 + $i * 26;
                imagefilledrectangle($im, $mx, $top + $sh - 30, $mx + 20, $top + $sh - 12, imagecolorallocate($im, $m[0], $m[1], $m[2]));
            }
            $windows = getenv('WINDIR') ? getenv('WINDIR') : 'C:\\Windows';
            $bold = $windows . '\\Fonts\\segoeuib.ttf';
            $regular = $windows . '\\Fonts\\segoeui.ttf';
            if (function_exists('imagettftext') && file_exists($bold)) {
                $white = imagecolorallocate($im, 255, 255, 255);
                $box = imagettfbbox(46, 0, $bold, $title);
                imagettftext($im, 46, 0, (int)(($size - ($box[2] - $box[0])) / 2), $size - 78, $white, $bold, $title);
                $ink = imagecolorallocate($im, (int)($r * .7), (int)($g * .7), (int)($b * .7));
                $font = file_exists($regular) ? $regular : $bold;
                $box = imagettfbbox(24, 0, $font, $label);
                imagettftext($im, 24, 0, (int)($x + ($sw - ($box[2] - $box[0])) / 2), (int)($top + $sh / 2 + 10), $ink, $font, $label);
            }
            ob_start(); imagepng($im); $png = ob_get_clean(); imagedestroy($im);
            $upload = wp_upload_bits('sm-' . $slug . '.png', null, $png);
            if (!empty($upload['error'])) { return 0; }
            $id = wp_insert_attachment(array('post_title' => $title, 'post_name' => 'sm-' . $slug, 'post_mime_type' => 'image/png', 'post_status' => 'inherit'), $upload['file']);
            require_once ABSPATH . 'wp-admin/includes/image.php';
            wp_update_attachment_metadata($id, wp_generate_attachment_metadata($id, $upload['file']));
            return $id;
        }

        // --- Products: variations by run (price per run), other options chosen freely --------
        $category = get_term_by('slug', 'drukovana-produktsiia', 'product_cat');
        $categoryId = $category ? $category->term_id : 0;
        if (!$categoryId) {
            $created = wp_insert_term('Друкована продукція', 'product_cat', array('slug' => 'drukovana-produktsiia'));
            $categoryId = is_wp_error($created) ? 0 : $created['term_id'];
        }
        $requirements = '<h3>Вимоги до макета</h3><ul><li>PDF (PDF/X-1a) або TIFF, 300 dpi</li><li>Колірна модель CMYK, без RGB та Pantone</li>'
            . '<li>Вильоти 2 мм з кожного боку, важливі елементи — не ближче 3 мм до краю</li><li>Шрифти переведені в криві</li></ul>'
            . '<p>Перед друком дизайнер перевіряє макет і надсилає підтвердження.</p>';
        function sm_product($p, $categoryId, $requirements) {
            $existing = get_page_by_path($p['slug'], OBJECT, 'product');
            if ($existing) { return $existing->ID; }
            $product = new WC_Product_Variable();
            $product->set_name($p['name']);
            $product->set_slug($p['slug']);
            $product->set_status('publish');
            $product->set_short_description($p['short']);
            $product->set_description('<p>' . $p['short'] . '</p>' . $requirements);
            if ($categoryId) { $product->set_category_ids(array($categoryId)); }
            $attributes = array();
            foreach ($p['options'] as $slug => $values) {
                $taxonomy = 'pa_' . $slug;
                $ids = array();
                foreach ($values as $value) { $term = get_term_by('slug', $value, $taxonomy); if ($term) { $ids[] = $term->term_id; } }
                $attribute = new WC_Product_Attribute();
                $attribute->set_id(wc_attribute_taxonomy_id_by_name($slug));
                $attribute->set_name($taxonomy);
                $attribute->set_options($ids);
                $attribute->set_visible(true);
                $attribute->set_variation(true);
                $attributes[] = $attribute;
            }
            $product->set_attributes($attributes);
            $defaults = array();
            foreach ($p['options'] as $slug => $values) { $defaults['pa_' . $slug] = $values[0]; }
            $product->set_default_attributes($defaults);
            $image = sm_image($p['slug'], $p['name'], $p['label'], $p['colour'], $p['w'], $p['h']);
            if ($image) { $product->set_image_id($image); }
            $id = $product->save();
            foreach ($p['prices'] as $run => $price) {
                $variation = new WC_Product_Variation();
                $variation->set_parent_id($id);
                $chosen = array();
                foreach (array_keys($p['options']) as $slug) { $chosen['pa_' . $slug] = $slug === 'tyrazh' ? (string)$run : ''; }
                $variation->set_attributes($chosen);
                $variation->set_regular_price((string)$price);
                $variation->set_stock_status('instock');
                $variation->set_status('publish');
                $variation->save();
            }
            WC_Product_Variable::sync($id);
            return $id;
        }
        $products = array(
            array('slug' => 'vizytky', 'name' => 'Візитки', 'label' => '90 × 50 мм', 'colour' => '#3d5afe', 'w' => 90, 'h' => 50,
                'short' => 'Класичні візитки на щільному папері: друк з двох боків, ламінування та скруглення кутів на вибір.',
                'options' => array('format' => array('90x50', '85x55'), 'papir' => array('kreid-300', 'dyzain-290', 'lion-250'),
                    'tyrazh' => array('100', '500', '1000'), 'obrobka' => array('bez', 'lam-mat', 'lam-hlianets', 'kuty')),
                'prices' => array('100' => 350, '500' => 890, '1000' => 1290)),
            array('slug' => 'flaiery', 'name' => 'Флаєри', 'label' => 'A5', 'colour' => '#e5484d', 'w' => 148, 'h' => 210,
                'short' => 'Рекламні флаєри та листівки для акцій і заходів. Що більший тираж, то нижча ціна за примірник.',
                'options' => array('format' => array('a6', 'a5', 'a4'), 'papir' => array('kreid-130', 'kreid-170'),
                    'tyrazh' => array('500', '1000', '5000'), 'obrobka' => array('bez', 'lam-hlianets')),
                'prices' => array('500' => 790, '1000' => 1190, '5000' => 3990)),
            array('slug' => 'plakaty', 'name' => 'Плакати', 'label' => 'A2', 'colour' => '#12a594', 'w' => 420, 'h' => 594,
                'short' => 'Плакати й афіші великого формату для вітрин, виставок і подій.',
                'options' => array('format' => array('a3', 'a2', 'a1'), 'papir' => array('kreid-170', 'foto-200'),
                    'tyrazh' => array('10', '50', '100'), 'obrobka' => array('bez', 'lam-mat')),
                'prices' => array('10' => 450, '50' => 1690, '100' => 2990)),
            array('slug' => 'nalipky', 'name' => 'Наліпки', 'label' => '50 × 50 мм', 'colour' => '#f5a524', 'w' => 50, 'h' => 50,
                'short' => 'Наліпки на самоклейці з контурною порізкою — для пакування, етикеток і мерчу.',
                'options' => array('format' => array('50x50', '70x70', 'a6'), 'papir' => array('samoklei-glianets', 'samoklei-mat'),
                    'tyrazh' => array('100', '500', '1000'), 'obrobka' => array('porizka', 'bez')),
                'prices' => array('100' => 390, '500' => 1150, '1000' => 1890)),
        );
        foreach ($products as $p) { sm_product($p, $categoryId, $requirements); }

        // --- Pages: Ukrainian titles, the shop is the front page; the WordPress samples go ---
        // WooCommerce and Printcart create their pages before the language switch, in English.
        foreach (array('shop' => 'Каталог', 'cart' => 'Кошик', 'checkout' => 'Оформлення замовлення', 'my-account' => 'Мій кабінет') as $slug => $title) {
            $page = get_page_by_path($slug);
            if ($page) { wp_update_post(array('ID' => $page->ID, 'post_title' => $title)); }
        }
        // Printcart's own pages (designer, gallery, quotes, uploads) need its cloud service; an
        // offline showcase keeps them out of the menu. They stay in the admin, set to private.
        foreach (array('create-your-own', 'design-studio', 'nbd-logged', 'templates', 'designer', 'product-builder', 'raq', 'upload-design-file', 'upload-your-file') as $slug) {
            $page = get_page_by_path($slug);
            if ($page && $page->post_status === 'publish') { wp_update_post(array('ID' => $page->ID, 'post_status' => 'private')); }
        }
        $shop = wc_get_page_id('shop');
        if ($shop > 0) { update_option('show_on_front', 'page'); update_option('page_on_front', $shop); }
        foreach (array(array('sample-page', 'page'), array('hello-world', 'post')) as $sample) {
            $post = get_page_by_path($sample[0], OBJECT, $sample[1]);
            if ($post) { wp_delete_post($post->ID, true); }
        }

        // --- Orders in different production states ------------------------------------------
        if (get_option('servermaster_showcase_orders') !== 'yes') {
            $orders = array(
                array('Олена', 'Коваль', '', 'olena.koval@example.local', '+380671112233', 'Київ', 'vizytky', '500',
                    array('format' => '90x50', 'papir' => 'dyzain-290', 'obrobka' => 'lam-mat'), 'processing', 'Макет у PDF, CMYK. Прошу скруглити кути.', 'Макет перевірено, передано в друк.', 1),
                array('Ігор', 'Бондар', 'Кав’ярня «Зерно»', 'zerno@example.local', '+380503334455', 'Львів', 'flaiery', '1000',
                    array('format' => 'a5', 'papir' => 'kreid-170', 'obrobka' => 'lam-hlianets'), 'on-hold', 'Флаєри для відкриття, потрібні до п’ятниці.', 'Очікуємо виправлений макет: текст ближче 3 мм до краю.', 0),
                array('Андрій', 'Мельник', 'Театр «Сцена»', 'scena@example.local', '+380937778899', 'Одеса', 'plakaty', '50',
                    array('format' => 'a2', 'papir' => 'foto-200', 'obrobka' => 'bez'), 'completed', 'Афіші вистави.', 'Видано клієнту.', 3),
                array('Марія', 'Шевченко', 'Пекарня «Колосок»', 'kolosok@example.local', '+380665556677', 'Київ', 'nalipky', '1000',
                    array('format' => '70x70', 'papir' => 'samoklei-mat', 'obrobka' => 'porizka'), 'processing', 'Наліпки на коробки, контурна порізка по колу.', 'У порізці.', 0),
            );
            foreach ($orders as $o) {
                $parent = get_page_by_path($o[6], OBJECT, 'product');
                if (!$parent) { continue; }
                $variation = null;
                foreach (wc_get_product($parent->ID)->get_children() as $childId) {
                    $child = wc_get_product($childId);
                    if ($child && $child->get_attribute('pa_tyrazh') !== '' && get_post_meta($childId, 'attribute_pa_tyrazh', true) === $o[7]) { $variation = $child; break; }
                }
                if (!$variation) { continue; }
                $order = wc_create_order(array('customer_note' => $o[10]));
                $chosen = array('attribute_pa_tyrazh' => $o[7]);
                foreach ($o[8] as $slug => $value) { $chosen['attribute_pa_' . $slug] = $value; }
                $order->add_product($variation, 1, array('variation' => $chosen));
                $address = array('first_name' => $o[0], 'last_name' => $o[1], 'company' => $o[2], 'email' => $o[3], 'phone' => $o[4],
                    'city' => $o[5], 'country' => 'UA', 'address_1' => 'Відділення Нової Пошти №1');
                $order->set_address($address, 'billing');
                $order->set_address($address, 'shipping');
                $order->set_payment_method('cod');
                $order->set_payment_method_title('Оплата при отриманні');
                $shipping = new WC_Order_Item_Shipping();
                $shipping->set_method_title('Нова Пошта');
                $shipping->set_method_id('flat_rate');
                $shipping->set_total(80);
                $order->add_item($shipping);
                $order->set_date_created(time() - $o[12] * DAY_IN_SECONDS - 3600);
                $order->calculate_totals(false);
                $order->update_status($o[9], 'Демо-замовлення ServerMaster.');
                $order->add_order_note($o[11]);
            }
            update_option('servermaster_showcase_orders', 'yes');
        }
        WP_CLI::success('Друкарня «Відбиток» готова.');
        """;
}
