using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace NikkeLocalLab.Phase3B2.LocalBootstrap;

internal sealed class ResourceProbeBootstrapSettings
{
    private const string RuntimeParent = @"C:\NLL\Runtime\ResourceProbeBootstrap";
    internal const string ClientRoot = @"C:\NLL\Clients\NIKKE-151.8.5-ResourceProbe";
    internal string ClientPath => Path.Combine(ClientRoot, "NIKKE", "game", "nikke.exe");
    internal string ResourcePath => Path.Combine(ClientRoot, "Unity", "com_proximabeta_NIKKE") + @"\";
    internal string AssessmentUid { get; }
    internal string ContextPath { get; }
    internal string RunRoot { get; }
    internal int DurationSeconds { get; }
    internal bool AuthOnly { get; }
    private readonly string certificatePath;
    internal sealed record Pin(string Path, long Length, string Sha256);
    internal sealed record Plan(string ContractId, string AssessmentUid, int DurationSeconds, bool AuthOnly, Pin[] RuntimeFiles, Pin[] ClientFiles);

    private ResourceProbeBootstrapSettings(Plan plan, string directory)
    {
        AssessmentUid = plan.AssessmentUid;
        DurationSeconds = plan.DurationSeconds;
        AuthOnly = plan.AuthOnly;
        ContextPath = Path.Combine(directory, "synthetic-context.json");
        certificatePath = Path.Combine(directory, "trust-root.cer");
        RunRoot = Path.Combine(@"C:\NLL\Staging\ResourceProbeRuns", AssessmentUid);
    }

    internal static ResourceProbeBootstrapSettings Load()
    {
        var directory = Path.TrimEndingDirectorySeparator(Path.GetFullPath(AppContext.BaseDirectory));
        var uid = Path.GetRelativePath(RuntimeParent, directory);
        Require(directory.StartsWith(RuntimeParent + @"\", StringComparison.OrdinalIgnoreCase) && Guid.TryParseExact(uid, "D", out _));
        var path = Path.Combine(directory, "bootstrap.private.json");
        var digest = Environment.GetEnvironmentVariable("NLL_RESOURCE_PROBE_BOOTSTRAP_SHA256");
        var planLength = new FileInfo(path).Length;
        Require(planLength is > 0 and <= 1024 * 1024);
        var bytes = ReadPinned(new(path, planLength, digest ?? ""), directory, readContents: true);
        var plan = JsonSerializer.Deserialize<Plan>(bytes, new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow
        }) ?? throw new InvalidOperationException("resource_probe_bootstrap_plan_invalid");
        Require(plan.ContractId == "nll/resource-probe-bootstrap/v1" && plan.AssessmentUid == uid &&
            plan.DurationSeconds is >= 30 and <= 180 && plan.RuntimeFiles is { Length: > 0 and <= 64 } &&
            plan.ClientFiles is { Length: > 0 and <= 512 });
        foreach (var pin in plan.RuntimeFiles) _ = ReadPinned(pin, directory);
        foreach (var pin in plan.ClientFiles) _ = ReadPinned(pin, ClientRoot);
        var pinnedPaths = plan.RuntimeFiles.Select(pin => pin.Path).ToHashSet(StringComparer.OrdinalIgnoreCase);
        Require(pinnedPaths.Count == plan.RuntimeFiles.Length &&
            Directory.GetFiles(directory, "*", SearchOption.AllDirectories).Where(file => file != path)
                .ToHashSet(StringComparer.OrdinalIgnoreCase).SetEquals(pinnedPaths));
        var required = new[] { "synthetic-context.json", "server.cer", "trust-root.cer", "sail_api_impl64.dll",
            "NikkeLocalLab.Phase3B2.ResourceProbeBootstrap.exe", "NikkeLocalLab.Phase3B2.ResourceProbeBootstrap.dll" };
        Require(required.All(name => plan.RuntimeFiles.Any(pin => pin.Path == Path.Combine(directory, name))));
        Require(plan.ClientFiles.Any(pin => pin.Path == Path.Combine(ClientRoot, "NIKKE", "game", "nikke.exe")));
        var settings = new ResourceProbeBootstrapSettings(plan, directory);
        Require(Directory.Exists(settings.RunRoot));
        // The elevated runner must supply a recent, plan-bound isolation receipt
        // before native startup. Auth-only smoke has no game execution authority.
        if (!plan.AuthOnly)
        {
            var readyPath = Path.Combine(settings.RunRoot, "isolation.ready.json");
            using var ready = JsonDocument.Parse(File.ReadAllBytes(readyPath));
            var root = ready.RootElement;
            var appliedAt = root.GetProperty("verifiedAtUtc").GetDateTimeOffset();
            Require(root.GetProperty("contractId").GetString() == "nll/resource-probe-isolation/v2" &&
                root.GetProperty("assessmentUid").GetString() == uid &&
                root.GetProperty("bootstrapPlanSha256").GetString() == digest &&
                root.GetProperty("allProgramsBlocked").GetBoolean() &&
                root.GetProperty("rollbackPrepared").GetBoolean() &&
                root.GetProperty("systemChangesVerified").GetBoolean() &&
                DateTimeOffset.UtcNow - appliedAt >= TimeSpan.Zero &&
                DateTimeOffset.UtcNow - appliedAt < TimeSpan.FromMinutes(5));
        }
        return settings;
    }

    internal HttpClient CreateClient()
    {
        using var certificate = X509CertificateLoader.LoadCertificateFromFile(certificatePath);
        var handler = new SocketsHttpHandler
        {
            UseProxy = false, UseCookies = false, AllowAutoRedirect = false,
            AutomaticDecompression = DecompressionMethods.None,
            ConnectCallback = ConnectLoopbackAsync,
            SslOptions = new SslClientAuthenticationOptions
            {
                CertificateChainPolicy = CreateChainPolicy(certificate)
            }
        };
        return new(handler) { Timeout = TimeSpan.FromSeconds(15), MaxResponseContentBufferSize = 1024 * 1024 };
    }

    internal static X509ChainPolicy CreateChainPolicy(X509Certificate2 certificate)
    {
        Require(!certificate.HasPrivateKey && certificate.NotBefore.ToUniversalTime() <= DateTime.UtcNow &&
            certificate.NotAfter.ToUniversalTime() > DateTime.UtcNow &&
            certificate.Extensions.OfType<X509BasicConstraintsExtension>().SingleOrDefault()?.CertificateAuthority == true);
        return new X509ChainPolicy
        {
            TrustMode = X509ChainTrustMode.CustomRootTrust,
            CustomTrustStore = { X509CertificateLoader.LoadCertificate(certificate.RawData) },
            RevocationMode = X509RevocationMode.NoCheck,
            DisableCertificateDownloads = true
        };
    }

    internal static async ValueTask<Stream> ConnectLoopbackAsync(SocketsHttpConnectionContext context, CancellationToken cancellation)
    {
        Require(IsAuthenticationEndpoint(context.DnsEndPoint));
        var socket = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
        try
        {
            await socket.ConnectAsync(new IPEndPoint(IPAddress.Loopback, 443), cancellation);
            return new NetworkStream(socket, ownsSocket: true);
        }
        catch { socket.Dispose(); throw; }
    }

    internal static bool IsAuthenticationEndpoint(DnsEndPoint endpoint) =>
        endpoint.Host is "li-sg.intlgame.com" or "aws-na.intlgame.com" && endpoint.Port == 443;

    private static byte[] ReadPinned(Pin pin, string parent, bool readContents = false)
    {
        var path = Path.GetFullPath(pin.Path);
        Require(path.StartsWith(parent + @"\", StringComparison.OrdinalIgnoreCase) && pin.Length is > 0 and <= 512L * 1024 * 1024 && pin.Sha256.Length == 64);
        for (FileSystemInfo? entry = new FileInfo(path); entry is not null;
            entry = entry is FileInfo file ? file.Directory : ((DirectoryInfo)entry).Parent)
            Require(entry.Exists && (entry.Attributes & FileAttributes.ReparsePoint) == 0);
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        Require(stream.Length == pin.Length && Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant() == pin.Sha256);
        if (!readContents) return [];
        stream.Position = 0;
        var bytes = new byte[checked((int)stream.Length)];
        stream.ReadExactly(bytes);
        return bytes;
    }
    private static void Require(bool value)
    {
        if (!value) throw new InvalidOperationException("resource_probe_bootstrap_boundary_invalid");
    }
}
