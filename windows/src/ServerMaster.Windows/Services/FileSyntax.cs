using System.Text.RegularExpressions;

namespace ServerMaster.Windows.Services;

public enum FileSyntaxKind { Keyword, Number, String, Comment }

public readonly record struct FileSyntaxSpan(int Start, int Length, FileSyntaxKind Kind);

public sealed record FileSyntax(IReadOnlyList<string> CommentPrefixes,
    IReadOnlyList<(string Open, string Close)> BlockComments, IReadOnlySet<string> Keywords)
{
    public static FileSyntax ForFile(string name)
    {
        var lower = name.ToLowerInvariant();
        if (lower.EndsWith(".php") || lower == "configuration.php")
            return new(["//", "#"], [("/*", "*/")], Set("public", "private", "protected", "var", "class", "function", "return", "null", "true", "false", "const", "define", "new"));
        if (lower.EndsWith(".json")) return new([], [], Set("true", "false", "null"));
        if (lower.EndsWith(".js") || lower.EndsWith(".ts"))
            return new(["//"], [("/*", "*/")], Set("const", "let", "var", "function", "return", "import", "export", "async", "await", "class", "if", "else", "true", "false", "null"));
        if (lower.EndsWith(".conf") || lower.StartsWith("nginx"))
            return new(["#"], [], Set("server", "location", "listen", "root", "index", "proxy_pass", "server_name", "include", "ssl_certificate", "return", "rewrite"));
        if (lower == ".htaccess" || lower.EndsWith(".htaccess"))
            return new(["#"], [], Set("RewriteEngine", "RewriteRule", "RewriteCond", "RewriteBase", "Options", "Require", "Header", "ErrorDocument", "AddType", "DirectoryIndex", "IfModule"));
        if (lower == ".env" || lower.StartsWith(".env")) return new(["#"], [], Set());
        if (lower == "caddyfile") return new(["#"], [], Set("root", "file_server", "reverse_proxy", "tls", "encode", "php_fastcgi"));
        return new(["#", "//"], [], Set());
    }

    public IReadOnlyList<FileSyntaxSpan> Highlight(string text)
    {
        var spans = new List<FileSyntaxSpan>();
        if (Keywords.Count > 0)
        {
            var words = string.Join('|', Keywords.Select(Regex.Escape));
            Add(spans, text, $@"\b({words})\b", FileSyntaxKind.Keyword, RegexOptions.IgnoreCase);
        }
        Add(spans, text, @"\b[0-9]+(?:\.[0-9]+)?\b", FileSyntaxKind.Number);
        Add(spans, text, "\"[^\"\\r\\n]*\"|'[^'\\r\\n]*'", FileSyntaxKind.String);
        foreach (var (open, close) in BlockComments)
            Add(spans, text, Regex.Escape(open) + "[\\s\\S]*?" + Regex.Escape(close), FileSyntaxKind.Comment);
        foreach (var prefix in CommentPrefixes)
            Add(spans, text, @"^\s*" + Regex.Escape(prefix) + ".*$", FileSyntaxKind.Comment, RegexOptions.Multiline);
        return spans;
    }

    private static HashSet<string> Set(params string[] values) => new(values, StringComparer.OrdinalIgnoreCase);

    private static void Add(List<FileSyntaxSpan> spans, string text, string pattern, FileSyntaxKind kind, RegexOptions options = RegexOptions.None)
    {
        foreach (Match match in Regex.Matches(text, pattern, options | RegexOptions.CultureInvariant))
            spans.Add(new(match.Index, match.Length, kind));
    }
}
