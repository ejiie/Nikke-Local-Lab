using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;

internal sealed record CommonFilePin(string Path, long Length, string Sha256);
internal sealed record CommonNativePatch(string RoleCode, long Offset, CommonFilePin Before, CommonFilePin After);

internal static class CommonDeliveryFiles
{
  internal static readonly JsonSerializerOptions Json = new()
  { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow };
  internal static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
  internal static string FileHash(string path)
  { using var input = File.OpenRead(Plain(path)); return Convert.ToHexString(SHA256.HashData(input)).ToLowerInvariant(); }
  internal static void Require([System.Diagnostics.CodeAnalysis.DoesNotReturnIf(false)] bool ok)
  { if (!ok) throw new InvalidDataException("phase_d_common_delivery_invalid"); }
  internal static string Plain(string path)
  {
    Require(Path.IsPathFullyQualified(path) && !path.StartsWith(@"\\", StringComparison.Ordinal));
    path = Path.GetFullPath(path);
    Require(!path[Path.GetPathRoot(path)!.Length..].Contains(':'));
    for (var p = path; p is not null; p = Path.GetDirectoryName(p))
      if (File.Exists(p) || Directory.Exists(p)) Require((File.GetAttributes(p) & FileAttributes.ReparsePoint) == 0);
    return path;
  }
  internal static byte[] Read(CommonFilePin pin, long maximum = 1048576)
  {
    Require(pin.Length is > 0 && pin.Length <= maximum);
    using var stream = new FileStream(Plain(pin.Path), FileMode.Open, FileAccess.Read, FileShare.Read);
    Require(stream.Length == pin.Length);
    var bytes = new byte[checked((int)stream.Length)]; stream.ReadExactly(bytes);
    Require(Hash(bytes) == pin.Sha256); return bytes;
  }
  internal static JsonDocument ReadJson(string path, string hash) => JsonDocument.Parse(Read(new(path, new FileInfo(path).Length, hash)));
  internal static string Text(JsonElement row, string key) => row.GetProperty(key).GetString()!;
  internal static string InstalledStoreBuild(string path)
  {
    path = Plain(path);
    foreach (var build in new[] { "151.8.5", "152.8.11" })
      if (path.StartsWith(@"C:\NLL\Clients\NIKKE-" + build + @"-ResourceProbe\Unity\com_proximabeta_NIKKE\com.shiftup.patch\", StringComparison.OrdinalIgnoreCase) &&
          path.EndsWith(@"\chunk\store.cdb", StringComparison.OrdinalIgnoreCase)) return build;
    throw new InvalidDataException("phase_d_common_delivery_store_not_admitted");
  }
  internal static CommonFilePin Pin(string path) => new(Plain(path), new FileInfo(path).Length, FileHash(path));
  internal static void Save(string path, object value)
  {
    using var file = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.Read);
    JsonSerializer.Serialize(file, value, Json); file.Flush(true);
  }
  internal static void Publish(string path, object value)
  {
    var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
    try { Save(temporary, value); File.Move(temporary, path); }
    finally { if (File.Exists(temporary)) File.Delete(temporary); }
  }
}
