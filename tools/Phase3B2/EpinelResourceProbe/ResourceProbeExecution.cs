using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Extensions.Configuration;

namespace EpinelPS.Execution;

// Candidate-only process admission/configuration. There is deliberately no HTTP
// middleware, resource adapter, authentication delegate, or dispatch mode here.
// The original Epinel pipeline handles every request; its existing logs remain.
public sealed class ResourceProbeExecution
{
    // Retained CLI spelling identifies the bounded run, not a request interceptor.
    public const string Argument = "--resource-route-probe";
    public const string ContractId = "nll/epinel-resource-probe-runtime/v2";
    private const string Parent = @"C:\NLL\Runtime\EpinelPS-151-ResourceProbe";
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow
    };
    public sealed record FilePin(string Path, long Length, string Sha256);
    public sealed record Plan(string ContractId, string AssessmentUid, int DurationSeconds, FilePin[] Files);
    public int DurationSeconds { get; }
    private ResourceProbeExecution(int seconds) => DurationSeconds = seconds;

    public static ResourceProbeExecution? Prepare(string[] args)
    {
        if (!args.Contains(Argument, StringComparer.Ordinal)) return null;
        if (args is not ["--headless", "--local-only", Argument, var digest]) Fail("arguments_invalid");
        else
        {
            var directory = Path.TrimEndingDirectorySeparator(Path.GetFullPath(AppContext.BaseDirectory));
            Guid uid = default;
            if (!directory.StartsWith(Parent + @"\", StringComparison.OrdinalIgnoreCase) ||
                !Guid.TryParseExact(Path.GetRelativePath(Parent, directory), "D", out uid) ||
                !string.Equals(directory, Path.TrimEndingDirectorySeparator(Path.GetFullPath(Environment.CurrentDirectory)), StringComparison.OrdinalIgnoreCase))
                Fail("runtime_path_invalid");
            var planPath = Path.Combine(directory, "resource-probe-runtime.private.json");
            var info = new FileInfo(planPath);
            if (!info.Exists || info.Length is < 1 or > 1024 * 1024) Fail("plan_size_invalid");
            var bytes = File.ReadAllBytes(planPath);
            if (Hash(bytes) != digest) Fail("plan_hash_drift");
            var plan = ReadPlan(bytes, uid.ToString("D"));
            VerifyFiles(directory, plan.Files);
            if (Environment.GetEnvironmentVariables().Keys.Cast<string>().Any(key => key.StartsWith("EPINELPS_", StringComparison.OrdinalIgnoreCase)))
                Fail("inherited_raid_configuration");
            // Neither production account stores nor previous runs are reusable.
            foreach (var name in new[] { "db.json", "epinelps.db", "probe-started.marker" })
                if (File.Exists(Path.Combine(directory, name))) Fail("runtime_not_fresh");
            using var marker = new FileStream(Path.Combine(directory, "probe-started.marker"), FileMode.CreateNew, FileAccess.Write, FileShare.None);
            marker.WriteByte(1);
            marker.Flush(true);
            return new ResourceProbeExecution(plan.DurationSeconds);
        }
        return null;
    }

    internal static Plan ReadPlan(byte[] bytes, string assessmentUid)
    {
        // Old plans are intentionally not upgraded implicitly. In particular,
        // removed observer/dispatch fields must not silently regain authority.
        var plan = JsonSerializer.Deserialize<Plan>(bytes, JsonOptions) ?? throw new InvalidOperationException("resource_probe_plan_invalid");
        if (plan.ContractId != ContractId || plan.AssessmentUid != assessmentUid ||
            plan.DurationSeconds is < 30 or > 300 || plan.Files is not { Length: > 0 and <= 512 }) Fail("plan_invalid");
        return plan;
    }

    internal static void VerifyFiles(string directory, FilePin[] files)
    {
        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var pin in files)
        {
            if (string.IsNullOrEmpty(pin.Path) || pin.Path.Contains('\\') || pin.Path.Contains(':') ||
                pin.Path.Split('/').Any(part => part is "" or "." or "..") || !names.Add(pin.Path) ||
                pin.Length is < 1 or > 512L * 1024 * 1024 || pin.Sha256 is not { Length: 64 }) Fail("file_pin_invalid");
            var path = Path.GetFullPath(Path.Combine(directory, pin.Path));
            if (!path.StartsWith(Path.GetFullPath(directory) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) Fail("file_path_invalid");
            for (FileSystemInfo? entry = new FileInfo(path); entry is not null;
                entry = entry is FileInfo file ? file.Directory : ((DirectoryInfo)entry).Parent)
                if (!entry.Exists || (entry.Attributes & FileAttributes.ReparsePoint) != 0) Fail("file_reparse_or_missing");
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
            if (stream.Length != pin.Length || Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant() != pin.Sha256)
                Fail("file_hash_drift");
        }
        var actual = Directory.GetFiles(directory, "*", SearchOption.AllDirectories)
            .Select(path => Path.GetRelativePath(directory, path).Replace('\\', '/'))
            .Where(path => path != "resource-probe-runtime.private.json").ToHashSet(StringComparer.OrdinalIgnoreCase);
        if (!actual.SetEquals(names)) Fail("runtime_inventory_drift");
    }

    public static void Configure(ConfigurationManager configuration)
    {
        configuration.Sources.Clear();
        configuration.AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["ConnectionStrings:EpinelPSConnectionType"] = "sqlite",
            ["ConnectionStrings:EpinelPSConnection"] = "Data Source=\"(startupDirectory)/epinelps.db\""
        });
    }

    private static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
    [System.Diagnostics.CodeAnalysis.DoesNotReturn]
    private static void Fail(string code) => throw new InvalidOperationException("resource_probe_" + code);
}
