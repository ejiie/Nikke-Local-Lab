using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using NikkeLocalLab.Persistence.PostgreSql;
using Npgsql;

namespace NikkeLocalLab.Admin.Api;

// Presentation-only projection of the current, version-independent local
// preferences head. Source frame IDs never leave this process in API responses.
public sealed class AccountFrameArtwork(NpgsqlDataSource source, AccountImportOptions options,
    string identitySecretEnvironmentVariable, ILogger<AccountFrameArtwork> logger)
{
  public async Task<IReadOnlyList<DirectoryUnion>> ApplyAsync(IReadOnlyList<DirectoryUnion> unions,
      CancellationToken token)
  {
    try { return await ApplyCoreAsync(unions, token).ConfigureAwait(false); }
    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException or
        FormatException or CryptographicException or KeyNotFoundException or InvalidOperationException)
    {
      logger.LogWarning("account_frame_artwork_unavailable");
      return unions;
    }
  }

  private async Task<IReadOnlyList<DirectoryUnion>> ApplyCoreAsync(IReadOnlyList<DirectoryUnion> unions,
      CancellationToken token)
  {
    var index = Path.Combine(options.RuntimeRoot, "ProfileFrames", "index.private.json");
    var secretText = Environment.GetEnvironmentVariable(identitySecretEnvironmentVariable);
    if (!File.Exists(index) || string.IsNullOrWhiteSpace(secretText)) return unions;
    using var manifest = JsonDocument.Parse(await File.ReadAllBytesAsync(index, token).ConfigureAwait(false));
    if (manifest.RootElement.GetProperty("contract").GetString() != "local-profile-frames/v1") return unions;
    var frames = manifest.RootElement.GetProperty("frames");
    var secret = Convert.FromBase64String(secretText);
    var key = HMACSHA256.HashData(secret, Encoding.UTF8.GetBytes("nll/phase-d-classic-solo-raid-runtime-state-key/v1"));
    CryptographicOperations.ZeroMemory(secret);
    var paths = new Dictionary<Guid, string?>();
    try
    {
      await using var command = source.CreateCommand("""
          SELECT s.local_account_uid,r.protected_payload,r.protected_payload_sha256,r.content_sha256,
                 c.client_build_code,c.client_executable_sha256
          FROM lab_private_server.runtime_preferences_scope s
          JOIN lab_private_server.runtime_preferences p USING(preferences_uid)
          JOIN lab_private_server.runtime_preferences_revision r ON r.revision_uid=p.current_revision_uid
          JOIN lab_private_server.runtime_preferences_revision_context c ON c.revision_uid=r.revision_uid
          JOIN lab_profile.local_account a ON a.local_account_uid=s.local_account_uid
          LEFT JOIN lab_profile.account_directory_presentation d USING(local_account_id)
          WHERE d.frame_path IS NULL OR d.imported_at_utc IS NULL OR r.captured_at_utc > d.imported_at_utc;
          """);
      await using var reader = await command.ExecuteReaderAsync(token).ConfigureAwait(false);
      while (await reader.ReadAsync(token).ConfigureAwait(false))
      {
        var uid = reader.GetGuid(0);
        try
        {
          var frame = ReadFrame(reader.GetFieldValue<byte[]>(1), reader.GetFieldValue<byte[]>(2),
              reader.GetFieldValue<byte[]>(3), key, uid, reader.GetString(4), reader.GetFieldValue<byte[]>(5));
          paths[uid] = null;
          if (frames.TryGetProperty(frame.ToString(System.Globalization.CultureInfo.InvariantCulture), out var mapped))
            paths[uid] = Publish(uid, mapped.GetString());
        }
        catch (Exception ex) when (ex is CryptographicException or JsonException or InvalidDataException or IOException)
        {
          // A missing/corrupt optional frame must not prevent account selection.
          // Do not log the encrypted payload or source metadata.
          logger.LogWarning("account_frame_artwork_unavailable");
          paths[uid] = null;
        }
      }
    }
    finally { CryptographicOperations.ZeroMemory(key); }
    return unions.Select(union => union with
    {
      Members = union.Members.Select(member => paths.TryGetValue(member.AccountUid.Value, out var path)
          ? member with { FramePath = path } : member).ToArray()
    }).ToArray();
  }

  internal static int ReadFrame(byte[] encrypted, byte[] protectedHash, byte[] contentHash,
      byte[] key, Guid account, string build, byte[] executableHash)
  {
    if (encrypted.Length is < 53 or > 16_777_216 || !encrypted.AsSpan(0, 8).SequenceEqual("NLLSRP01"u8) ||
        !SHA256.HashData(encrypted).AsSpan().SequenceEqual(protectedHash)) throw new InvalidDataException();
    var clear = new byte[encrypted.Length - 36];
    try
    {
      var aad = Encoding.UTF8.GetBytes($"nll/runtime-preferences-protected/v1\n{account:D}\n{build}\n{Convert.ToHexString(executableHash).ToLowerInvariant()}\n");
      using var aes = new AesGcm(key, 16);
      aes.Decrypt(encrypted.AsSpan(8, 12), encrypted.AsSpan(36), encrypted.AsSpan(20, 16), clear, aad);
      if (!SHA256.HashData(clear).AsSpan().SequenceEqual(contentHash)) throw new InvalidDataException();
      using var document = JsonDocument.Parse(clear);
      if (!document.RootElement.TryGetProperty("ProfileFrame", out var frame) ||
          !frame.TryGetInt32(out var value) || value < 0) throw new InvalidDataException();
      return value;
    }
    finally { CryptographicOperations.ZeroMemory(clear); }
  }

  private string? Publish(Guid account, string? digest)
  {
    if (digest is null || digest.Length != 64 || digest.Any(c => !char.IsAsciiHexDigit(c))) return null;
    digest = digest.ToLowerInvariant();
    var path = Path.Combine(options.RuntimeRoot, "ProfileFrames", digest + ".png");
    if (!File.Exists(path)) return null;
    var info = new FileInfo(path);
    if (info.Length is < 8 or > 16_777_216 || info.Attributes.HasFlag(FileAttributes.ReparsePoint)) return null;
    var bytes = File.ReadAllBytes(path);
    if (!bytes.AsSpan(0, 8).SequenceEqual(new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 }) ||
        Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant() != digest) return null;
    var leaf = $"{account:D}-frame-{digest}.png";
    var root = Path.Combine(options.RuntimeRoot, "AccountArtwork");
    Directory.CreateDirectory(root);
    var destination = Path.Combine(root, leaf);
    // Concurrent directory reads share the same immutable content-addressed file.
    if (!File.Exists(destination))
    {
      var temporary = Path.Combine(root, Guid.NewGuid().ToString("N") + ".tmp");
      try { File.WriteAllBytes(temporary, bytes); File.Move(temporary, destination, overwrite: true); }
      finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
    return "/admin-api/v1/account-art/" + leaf;
  }
}
