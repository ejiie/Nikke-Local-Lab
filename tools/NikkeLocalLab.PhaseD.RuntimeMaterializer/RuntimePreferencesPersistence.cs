using System.Security.Cryptography;
using System.Text;
using EpinelPS.Models;
using Newtonsoft.Json;
using NikkeLocalLab.Persistence.PostgreSql;
using Npgsql;

internal sealed record RuntimePreferencesPending(Guid AccountUid, string ClientBuildCode,
    string ClientExecutableSha256, Guid LaunchContextUid, Guid? ExpectedRevisionUid,
    DateTimeOffset CapturedAtUtc, string ContentSha256, string ProtectedPayloadSha256,
    string ProtectedPayloadBase64, string RequestSha256);

internal static class RuntimePreferencesPersistence
{
  internal static async Task<Guid?> RestoreAsync(User user, NpgsqlDataSource dataSource, byte[] secret,
      RuntimePreferencesKey key, string profileSha256, string weakness, Dictionary<long, string> characterUids)
  {
    var head = await new RuntimePreferencesStore(dataSource).GetHeadAsync(key);
    RuntimePreferencesPayload? payload = null;
    if (head is not null)
    {
      var clear = ClassicSoloRaidRuntimeState.Unprotect(head.ProtectedPayload, secret, AssociatedData(
          key with { ClientBuildCode = head.ClientBuildCode, ClientExecutableSha256 = head.ClientExecutableSha256 }));
      try
      {
        Require(SHA256.HashData(clear).AsSpan().SequenceEqual(head.ContentSha256), "phase_d_preferences_content_mismatch");
        payload = Deserialize(clear);
        RuntimePreferencesProjection.Restore(user, payload, characterUids);
      }
      finally { CryptographicOperations.ZeroMemory(clear); }
    }
    user.LocalPersistenceBinding = new LocalRuntimePersistenceBinding
    {
      AccountUid = key.AccountUid, ProfileRevisionSha256 = profileSha256, SelectedWeaknessCode = weakness,
      PreferencesHeadUid = head?.RevisionUid, CharacterUidByCsn = characterUids,
      BaselineBadgeFingerprints = user.Badges.Select(RuntimePreferencesProjection.BadgeFingerprint).Order(StringComparer.Ordinal).ToList(),
      DismissedBadgeFingerprints = payload?.DismissedBadges.ToList() ?? [],
    };
    return head?.RevisionUid;
  }

  internal static RuntimePreferencesPending Capture(User user, RuntimePreferencesKey key,
      string profileSha256, string weakness, byte[] secret, Guid launchUid, DateTimeOffset instant)
  {
    var binding = user.LocalPersistenceBinding;
    Require(binding is not null && binding.AccountUid == key.AccountUid &&
        binding.ProfileRevisionSha256 == profileSha256 && binding.SelectedWeaknessCode == weakness,
        "phase_d_preferences_source_binding_mismatch");
    var clear = Encoding.UTF8.GetBytes(JsonConvert.SerializeObject(RuntimePreferencesProjection.Capture(user)));
    try
    {
      var contentHash = SHA256.HashData(clear);
      var encrypted = ClassicSoloRaidRuntimeState.Protect(clear, secret, AssociatedData(key));
      try
      {
        var capture = new RuntimePreferencesCapture(key, launchUid, binding!.PreferencesHeadUid,
            encrypted, SHA256.HashData(encrypted), contentHash, instant);
        return new RuntimePreferencesPending(key.AccountUid, key.ClientBuildCode,
            Convert.ToHexStringLower(key.ClientExecutableSha256), launchUid, binding.PreferencesHeadUid, instant,
            Convert.ToHexStringLower(contentHash), Convert.ToHexStringLower(capture.ProtectedPayloadSha256),
            Convert.ToBase64String(encrypted), Convert.ToHexStringLower(RuntimePreferencesStore.ComputeRequestSha256(capture)));
      }
      finally { CryptographicOperations.ZeroMemory(encrypted); }
    }
    finally { CryptographicOperations.ZeroMemory(clear); }
  }

  internal static async Task<RuntimePreferencesResult> PersistAsync(RuntimePreferencesPending pending,
      NpgsqlDataSource dataSource, RuntimePreferencesKey expectedKey, Guid launchUid, byte[] secret)
  {
    Require(pending.AccountUid == expectedKey.AccountUid && pending.ClientBuildCode == expectedKey.ClientBuildCode &&
        pending.ClientExecutableSha256 == Convert.ToHexStringLower(expectedKey.ClientExecutableSha256) &&
        pending.LaunchContextUid == launchUid, "phase_d_preferences_pending_binding_mismatch");
    var encrypted = Convert.FromBase64String(pending.ProtectedPayloadBase64);
    try
    {
      Require(encrypted.Length is >= 53 and <= 16_777_216 &&
          Convert.ToHexStringLower(SHA256.HashData(encrypted)) == pending.ProtectedPayloadSha256,
          "phase_d_preferences_protected_hash_mismatch");
      var clear = ClassicSoloRaidRuntimeState.Unprotect(encrypted, secret, AssociatedData(expectedKey));
      try
      {
        Require(Convert.ToHexStringLower(SHA256.HashData(clear)) == pending.ContentSha256,
            "phase_d_preferences_content_mismatch");
        RuntimePreferencesProjection.Validate(Deserialize(clear));
      }
      finally { CryptographicOperations.ZeroMemory(clear); }
      var capture = new RuntimePreferencesCapture(expectedKey, launchUid, pending.ExpectedRevisionUid, encrypted,
          Convert.FromHexString(pending.ProtectedPayloadSha256), Convert.FromHexString(pending.ContentSha256), pending.CapturedAtUtc);
      Require(Convert.ToHexStringLower(RuntimePreferencesStore.ComputeRequestSha256(capture)) == pending.RequestSha256,
          "phase_d_preferences_request_hash_mismatch");
      return await new RuntimePreferencesStore(dataSource).PersistAsync(capture);
    }
    finally { CryptographicOperations.ZeroMemory(encrypted); }
  }

  internal static string PendingHash(RuntimePreferencesPending pending) => Convert.ToHexStringLower(SHA256.HashData(
      Encoding.UTF8.GetBytes(JsonConvert.SerializeObject(pending))));

  private static RuntimePreferencesPayload Deserialize(byte[] clear) => JsonConvert.DeserializeObject<RuntimePreferencesPayload>(
      Encoding.UTF8.GetString(clear)) ?? throw new InvalidOperationException("phase_d_preferences_payload_invalid");
  private static byte[] AssociatedData(RuntimePreferencesKey key) => Encoding.UTF8.GetBytes(string.Join('\n',
      "nll/runtime-preferences-protected/v1", key.AccountUid.ToString("D"), key.ClientBuildCode,
      Convert.ToHexStringLower(key.ClientExecutableSha256)) + "\n");
  private static void Require(bool condition, string code)
  {
    if (!condition) throw new InvalidOperationException(code);
  }
}
