namespace ServerMaster.Windows.Models;

public sealed record SiteHealthTarget(Guid Id, string Name, string Address, string? CertificatePath = null);

public sealed record SiteHealthResult(Guid Id, string Name, string Address, int? Status, long Milliseconds, string? Server, string? Problem)
{
    // List rows and combo items are announced by this text (otherwise the type name).
    public override string ToString() => $"{Name}: {Summary}";

    public bool IsGood => Status is >= 200 and < 400;
    public string Glyph => IsGood ? "\uE73E" : "\uEA39";
    public string Tint => IsGood ? "#32B875" : "#E66A72";
    public string Summary => Problem ?? (Status is { } status
        ? $"{status}" + (string.IsNullOrWhiteSpace(Server) ? "" : " · " + Server) + $" · {Milliseconds} ms"
        : "No answer");
}
