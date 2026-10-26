using System.Net;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Security.AccessControl;
using System.Security.Principal;
using ServerMaster.Windows.Models;

namespace ServerMaster.Windows.Services;

public enum CertificateTrustState { Missing, Invalid, Untrusted, Trusted }
public sealed record CertificateTrustStatus(CertificateTrustState State, string Message);

public static class LocalCertificates
{
    public static CertificateTrustStatus Status(ServerProfile profile)
    {
        if (!File.Exists(profile.CertificatePath) || !File.Exists(profile.PrivateKeyPath))
            return new(CertificateTrustState.Missing, "No certificate yet. HTTPS will not start without one.");
        try
        {
            Validate(profile);
            using var certificate = X509Certificate2.CreateFromPemFile(profile.CertificatePath, profile.PrivateKeyPath);
            using var chain = new X509Chain();
            chain.ChainPolicy.RevocationMode = X509RevocationMode.NoCheck;
            if (chain.Build(certificate))
                return new(CertificateTrustState.Trusted, "Windows trusts this certificate. The browser should not show a certificate warning.");
            return new(CertificateTrustState.Untrusted, "Windows does not trust this certificate. The browser will show a warning.");
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or CryptographicException or InvalidOperationException)
        {
            return new(CertificateTrustState.Invalid, ex.Message);
        }
    }

    public static string[] Names(string input)
    {
        var names = input.Split([',', ';', ' ', '\r', '\n'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
        if (names.Length == 0 || names.Any(name => Uri.CheckHostName(name) == UriHostNameType.Unknown || name.Contains('*')))
            throw new InvalidOperationException("Enter host names or IP addresses, without https://, ports or paths.");
        return names;
    }

    public static void Generate(ServerProfile profile, string domains, bool trust)
    {
        var names = Names(domains);
        using var key = RSA.Create(2048);
        var request = new CertificateRequest("CN=ServerMaster local development", key, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        var san = new SubjectAlternativeNameBuilder();
        foreach (var name in names)
            if (IPAddress.TryParse(name, out var address)) san.AddIpAddress(address); else san.AddDnsName(name);
        request.CertificateExtensions.Add(san.Build());
        request.CertificateExtensions.Add(new X509BasicConstraintsExtension(false, false, 0, true));
        request.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.DigitalSignature | X509KeyUsageFlags.KeyEncipherment, true));
        request.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension(new OidCollection { new("1.3.6.1.5.5.7.3.1") }, true));
        using var certificate = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddMinutes(-5), DateTimeOffset.UtcNow.AddDays(90));
        var folder = Path.Combine(AppPaths.Runtime, "certificates", profile.Id.ToString("N"), Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        var access = new DirectorySecurity();
        access.SetAccessRuleProtection(true, false);
        access.AddAccessRule(new FileSystemAccessRule(WindowsIdentity.GetCurrent().User!, FileSystemRights.FullControl,
            InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
        new DirectoryInfo(folder).SetAccessControl(access);
        var certPath = Path.Combine(folder, "localhost.pem");
        var keyPath = Path.Combine(folder, "localhost-key.pem");
        File.WriteAllText(certPath, certificate.ExportCertificatePem());
        File.WriteAllText(keyPath, key.ExportPkcs8PrivateKeyPem());
        if (trust)
        {
            try
            {
                using var store = new X509Store(StoreName.Root, StoreLocation.CurrentUser);
                store.Open(OpenFlags.ReadWrite);
                using var publicCertificate = new X509Certificate2(certificate.Export(X509ContentType.Cert));
                store.Add(publicCertificate);
            }
            catch (CryptographicException ex) { throw new InvalidOperationException("Windows could not trust the certificate. Retry with the trust checkbox cleared, or check your account's certificate policy.", ex); }
        }
        profile.CertificatePath = certPath;
        profile.PrivateKeyPath = keyPath;
    }

    public static void Validate(ServerProfile profile)
    {
        if (!File.Exists(profile.CertificatePath) || !File.Exists(profile.PrivateKeyPath))
            throw new InvalidOperationException("HTTPS needs a certificate and private key. Open Certificates in this profile to generate them.");
        try
        {
            using var certificate = X509Certificate2.CreateFromPemFile(profile.CertificatePath, profile.PrivateKeyPath);
            if (certificate.NotAfter.ToUniversalTime() <= DateTime.UtcNow || certificate.NotBefore.ToUniversalTime() > DateTime.UtcNow)
                throw new InvalidOperationException("The HTTPS certificate is expired or not yet valid. Generate a new certificate.");
            if (!certificate.MatchesHostname(profile.DisplayHost.Trim('[', ']'), allowCommonName: false))
                throw new InvalidOperationException("The certificate does not include the profile's host. Generate a certificate with " + profile.DisplayHost + " included.");
        }
        catch (CryptographicException ex) { throw new InvalidOperationException("The certificate and key could not be loaded or do not match. Generate a new pair.", ex); }
    }
}
