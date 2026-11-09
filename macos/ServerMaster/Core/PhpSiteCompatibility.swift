import Foundation

/// Matches the Windows PHP built-in compatibility router. Only known Joomla
/// entry points are canonicalised; assets and arbitrary PHP scripts stay with PHP.
nonisolated enum PhpSiteCompatibility {
    static func isJoomla(root: String) -> Bool {
        let folder = URL(fileURLWithPath: root)
        return ["libraries/src/Uri/Uri.php", "administrator/index.php"].allSatisfy {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
    }

    static let router = """
    <?php
    $uri = $_SERVER['REQUEST_URI'] ?? '/';
    $path = parse_url($uri, PHP_URL_PATH);
    $entries = [
        '/index.php' => '/',
        '/installation/index.php' => '/installation/',
        '/administrator/index.php' => '/administrator/',
        '/api/index.php' => '/api/',
    ];
    if (isset($entries[$path])) {
        $query = parse_url($uri, PHP_URL_QUERY);
        header('Location: ' . $entries[$path] . ($query !== null ? '?' . $query : ''), true, 307);
        exit;
    }
    return false;
    """
}
