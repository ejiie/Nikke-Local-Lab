using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace NikkeLocalLab.Automation;

public sealed record ExecutionAssetBinding(
    string ExecutionCode, string CandidateSealSha256, string ProfileSha256, string WeaknessCode);

/// <summary>
/// Optional local-only transport component, not runtime admission. No shared/cache
/// path is ever written. A sticky exclusive lease prevents reuse after an unclean
/// owner exit; recovery must establish ownership explicitly, not guess from a PID.
/// </summary>
public sealed class ExecutionAssetOverlay : IDisposable
{
  private const string Contract = "nll/execution-fx-delivery/v1";
  private const int MaximumAssetLength = 64 * 1024 * 1024;
  private static readonly JsonSerializerOptions JsonOptions = new()
  {
    PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow
  };
  private readonly object gate = new();
  private readonly string requestPath;
  private readonly Lease lease;
  private byte[]? payload;

  private ExecutionAssetOverlay(string path, byte[] bytes, Lease ownedLease)
  {
    requestPath = path;
    payload = bytes;
    lease = ownedLease;
  }

  public static ExecutionAssetOverlay Open(
      string root, string manifestSha256, ExecutionAssetBinding binding, bool officialOutboundEnabled)
  {
    Require(!officialOutboundEnabled, "execution_fx_official_outbound_forbidden");
    root = PlainDirectory(root);
    ReadManifest(root, manifestSha256, binding); // Never create a lease in an unsealed input directory.
    var ownedLease = Lease.Acquire(root);
    try
    {
      Require(!File.Exists(Path.Combine(root, ".retiring")) &&
          !File.Exists(Path.Combine(root, "retired.json")), "execution_fx_retired");
      var manifest = ReadManifest(root, manifestSha256, binding);
      CheckInventory(root, retiringAllowed: false);
      CryptographicOperations.ZeroMemory(ReadPinned(root, "original.bundle", manifest.Original));
      return new ExecutionAssetOverlay(manifest.RequestPath,
          ReadPinned(root, "overlay.bundle", manifest.Overlay), ownedLease);
    }
    catch
    {
      ownedLease.Dispose();
      throw;
    }
  }

  /// <summary>
  /// Pass the HTTP raw target, not a decoded/normalized path. null is an exact
  /// route miss; invalid requests throw and must never fall back to cached bytes.
  /// Each response owns a copy, so range processing and disposal cannot alter it.
  /// </summary>
  public byte[]? GetResponse(string rawTarget)
  {
    lock (gate)
    {
      Require(payload is not null, "execution_fx_closed");
      ValidateRequestPath(rawTarget);
      return string.Equals(rawTarget, requestPath, StringComparison.Ordinal)
          ? payload!.ToArray() : null;
    }
  }

  public void Dispose()
  {
    lock (gate)
    {
      if (payload is null)
        return;
      CryptographicOperations.ZeroMemory(payload);
      payload = null;
      lease.Dispose();
    }
  }

  /// <summary>
  /// Retire this delivery folder only: detach the route, delete its two private
  /// copies, retain the manifest/tombstone. No installed bytes were overwritten,
  /// so rollback requires no write through the parent's cache junction. The
  /// execution coordinator must separately wait for its whole process tree.
  /// </summary>
  public static void Retire(string root, string manifestSha256, ExecutionAssetBinding binding)
  {
    root = PlainDirectory(root);
    ReadManifest(root, manifestSha256, binding);
    using var ownedLease = Lease.Acquire(root);
    var manifest = ReadManifest(root, manifestSha256, binding);
    CheckInventory(root, retiringAllowed: true);
    var marker = Path.Combine(root, ".retiring");
    var receipt = Path.Combine(root, "retired.json");
    var retiring = File.Exists(marker);
    var markerBytes = Encoding.UTF8.GetBytes(manifestSha256);
    if (retiring)
      Require(ReadSmall(marker).SequenceEqual(markerBytes), "execution_fx_retirement_drifted");
    var receiptBytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new
    {
      contractId = "nll/execution-fx-retirement/v1",
      manifestSha256,
      executionCode = binding.ExecutionCode,
      statusCode = "private_delivery_retired",
      sharedCacheModified = false,
      runtimeAdmissionStatusCode = "not_assessed"
    }));
    if (File.Exists(receipt))
    {
      Require(retiring && ReadSmall(receipt).SequenceEqual(receiptBytes) &&
          !File.Exists(Path.Combine(root, "original.bundle")) &&
          !File.Exists(Path.Combine(root, "overlay.bundle")), "execution_fx_retirement_drifted");
      return;
    }
    // Preflight ALL remaining files before creating intent or deleting any.
    foreach (var (leaf, pin) in Files(manifest))
    {
      if (File.Exists(Path.Combine(root, leaf)))
        CryptographicOperations.ZeroMemory(ReadPinned(root, leaf, pin));
      else
        Require(retiring, "execution_fx_asset_missing");
    }
    if (!retiring)
      WriteNew(marker, markerBytes); // Sticky intent: Open can never revive partial cleanup.
    foreach (var (leaf, pin) in Files(manifest))
    {
      var path = Path.Combine(root, leaf);
      if (!File.Exists(path))
        continue;
      CryptographicOperations.ZeroMemory(ReadPinned(root, leaf, pin));
      File.Delete(path); // Fixed, hash-checked private file; never recursive or shared.
    }
    WriteNew(receipt, receiptBytes);
  }

  private static IEnumerable<(string Leaf, Pin Pin)> Files(Manifest manifest)
  {
    yield return ("original.bundle", manifest.Original);
    yield return ("overlay.bundle", manifest.Overlay);
  }

  private static Manifest ReadManifest(string root, string expectedSha, ExecutionAssetBinding binding)
  {
    Require(IsSha(expectedSha) && IsSha(binding.ProfileSha256) && IsSha(binding.CandidateSealSha256) &&
        Regex.IsMatch(binding.ExecutionCode, "\\A[0-9a-f]{32}\\z", RegexOptions.CultureInvariant),
        "execution_fx_binding_invalid");
    var raw = ReadSmall(Path.Combine(root, "manifest.private.json"));
    Require(Hash(raw) == expectedSha, "execution_fx_manifest_drifted");
    Manifest manifest;
    try
    {
      manifest = JsonSerializer.Deserialize<Manifest>(raw, JsonOptions)
          ?? throw new JsonException();
    }
    catch (JsonException)
    {
      throw new InvalidDataException("execution_fx_manifest_invalid");
    }
    Require(manifest.SchemaVersion == 1 && manifest.ContractId == Contract &&
        manifest.RuntimeAdmissionStatusCode == "not_assessed" &&
        manifest.ExecutionCode == binding.ExecutionCode && manifest.ProfileSha256 == binding.ProfileSha256 &&
        manifest.CandidateSealSha256 == binding.CandidateSealSha256 && manifest.WeaknessCode == binding.WeaknessCode &&
        (manifest.WeaknessCode, manifest.BossElementCode) is ("water", "fire") or ("fire", "wind") or ("wind", "iron"),
        "execution_fx_binding_invalid");
    ValidateRequestPath(manifest.RequestPath);
    ValidatePin(manifest.Original);
    ValidatePin(manifest.Overlay);
    Require(manifest.Original != manifest.Overlay, "execution_fx_overlay_invalid");
    return manifest;
  }

  private static void ValidateRequestPath(string? value)
  {
    Require(value is not null && value.Length <= 2048 &&
        Regex.IsMatch(value, "\\A/(PC|prdenv)/[A-Za-z0-9_./-]+\\.bundle\\z", RegexOptions.CultureInvariant) &&
        value[1..].Split('/').All(part => part is not ("" or "." or "..")),
        "execution_fx_request_path_invalid");
  }

  private static bool IsSha(string? value) => value is not null &&
      Regex.IsMatch(value, "\\A[0-9a-f]{64}\\z", RegexOptions.CultureInvariant);

  private static void ValidatePin(Pin? pin) => Require(pin is not null && IsSha(pin.Sha256) &&
      pin.ByteLength is > 0 and <= MaximumAssetLength, "execution_fx_pin_invalid");

  private static byte[] ReadPinned(string root, string leaf, Pin pin)
  {
    var path = PlainFile(Path.Combine(root, leaf));
    Require(new FileInfo(path).Length == pin.ByteLength, "execution_fx_asset_drifted");
    var raw = ReadBounded(path, MaximumAssetLength);
    if (raw.Length != pin.ByteLength || Hash(raw) != pin.Sha256)
    {
      CryptographicOperations.ZeroMemory(raw);
      throw new InvalidDataException("execution_fx_asset_drifted");
    }
    return raw;
  }

  private static byte[] ReadSmall(string path)
  {
    path = PlainFile(path);
    Require(new FileInfo(path).Length is > 0 and <= 32768, "execution_fx_metadata_invalid");
    return ReadBounded(path, 32768);
  }

  private static byte[] ReadBounded(string path, int limit)
  {
    using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
    Require(stream.Length is > 0 && stream.Length <= limit, "execution_fx_file_size_invalid");
    var bytes = new byte[checked((int)stream.Length)];
    try
    {
      stream.ReadExactly(bytes);
      Require(stream.ReadByte() == -1, "execution_fx_file_changed_during_read");
      return bytes;
    }
    catch
    {
      CryptographicOperations.ZeroMemory(bytes);
      throw;
    }
  }

  private static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();

  private static string PlainDirectory(string path)
  {
    var full = Path.GetFullPath(path);
    var directory = new DirectoryInfo(full);
    for (var current = directory; current is not null; current = current.Parent)
      Require(current.Exists && (current.Attributes & FileAttributes.ReparsePoint) == 0,
          "execution_fx_reparse_or_directory_invalid");
    return full;
  }

  private static string PlainFile(string path)
  {
    PlainDirectory(Path.GetDirectoryName(path)!);
    var info = new FileInfo(path);
    Require(info.Exists && (info.Attributes & (FileAttributes.ReparsePoint | FileAttributes.Directory)) == 0,
        "execution_fx_file_invalid");
    return info.FullName;
  }

  private static void CheckInventory(string root, bool retiringAllowed)
  {
    var allowed = new HashSet<string>(StringComparer.Ordinal)
            { "manifest.private.json", "original.bundle", "overlay.bundle", ".lease" };
    if (retiringAllowed)
      allowed.UnionWith([".retiring", "retired.json"]);
    foreach (var file in Directory.EnumerateFileSystemEntries(root))
    {
      Require(allowed.Contains(Path.GetFileName(file)), "execution_fx_foreign_member");
      PlainFile(file);
    }
  }

  private static void WriteNew(string path, byte[] bytes)
  {
    using var stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None);
    stream.Write(bytes);
    stream.Flush(flushToDisk: true);
  }

  private static void Require(bool condition, string code)
  {
    if (!condition)
      throw new InvalidDataException(code);
  }

  private sealed record Pin(string Sha256, long ByteLength);
  private sealed record Manifest(int SchemaVersion, string ContractId, string ExecutionCode,
      string CandidateSealSha256, string ProfileSha256, string WeaknessCode, string BossElementCode,
      string RequestPath, Pin Original, Pin Overlay, string RuntimeAdmissionStatusCode);

  private sealed class Lease(string path, FileStream stream) : IDisposable
  {
    public static Lease Acquire(string root)
    {
      var path = Path.Combine(root, ".lease");
      try
      {
        return new Lease(path, new FileStream(path, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None));
      }
      catch (IOException)
      {
        throw new InvalidDataException("execution_fx_busy_or_unclean_owner");
      }
    }

    public void Dispose()
    {
      // The lease remains on an unclean process exit. Never infer that an
      // existing lease is stale, and never unlink a substituted directory.
      stream.Dispose();
      PlainFile(path);
      Require(new FileInfo(path).Length == 0, "execution_fx_lease_drifted");
      File.Delete(path);
    }
  }
}
