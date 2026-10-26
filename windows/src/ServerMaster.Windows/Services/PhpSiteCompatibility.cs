using System.Text;

namespace ServerMaster.Windows.Services;

public static class PhpSiteCompatibility
{
    public static bool IsJoomla(string root) =>
        File.Exists(Path.Combine(root, "libraries", "src", "Uri", "Uri.php")) &&
        File.Exists(Path.Combine(root, "administrator", "index.php"));

    public static string EnsureJoomlaRouter()
    {
        var folder = Path.Combine(AppPaths.Runtime, "routers");
        Directory.CreateDirectory(folder);
        var path = Path.Combine(folder, "joomla.php");
        if (!File.Exists(path) || File.ReadAllText(path) != Router)
            File.WriteAllText(path, Router, new UTF8Encoding(false));
        return path;
    }

    // Joomla's cli-server URI handling treats explicit index.php URLs as directories.
    // Canonicalize only its known entry points; leave assets and other PHP scripts to PHP.
    public const string Router = """
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
        """;
}
