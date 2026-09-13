using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

// Offline projection of a receipt-pinned LOCAL account snapshot. No database,
// login, registration, server, or game process is opened by this transformation.
internal static class UserValidationAccount
{
  internal sealed record Result(byte[] Database, byte[] Context, byte[] Receipt);

  internal static Result Create(byte[] source, byte[] sourceReceipt, Guid assessment,
      int selectedManager, int season, string weakness, string profileHash,
      byte[] credentialEntropy, byte[] launcherKey, byte[] encryptionKey)
  {
    Require(assessment != Guid.Empty && selectedManager > 0 && season is > 0 and <= 1000 &&
        weakness is "fire" or "water" or "wind" or "electric" or "iron" && IsHash(profileHash) &&
        credentialEntropy.Length == 15 && launcherKey.Length == 32 && encryptionKey.Length == 32 &&
        !launcherKey.SequenceEqual(encryptionKey));
    var database = Parse(source, 32 * 1024 * 1024);
    var proof = Parse(sourceReceipt, 65536);
    Require(Text(proof, "contractId") == "nll/phase-d-runtime-materialization/v1" &&
        Text(proof, "runtimeDatabaseSha256") == Hash(source) &&
        proof["progressionPreserved"]?.GetValue<bool>() == true &&
        proof["sourceDatabaseModified"]?.GetValue<bool>() == false &&
        proof["identitySecretPersisted"]?.GetValue<bool>() == false &&
        proof["officialOutboundUsed"]?.GetValue<bool>() == false);
    Require(database["Users"] is JsonArray { Count: 1 } && database["Users"]![0] is JsonObject);
    var user = (JsonObject)database["Users"]![0]!;
    var binding = user["LocalPersistenceBinding"] as JsonObject;
    Require(binding is not null && Guid.TryParse(Text(binding, "AccountUid"), out var account) &&
        account != Guid.Empty && account.ToString("D") == Text(proof, "accountUid") &&
        IsHash(Text(proof, "accountRevisionSetSha256")) &&
        Text(binding, "ProfileRevisionSha256") == Text(proof, "accountRevisionSetSha256"));
    foreach (var pair in new[] { ("Characters", "characterCount"),
        ("CompletedScenarios", "completedScenarioCount") })
      Require(user[pair.Item1] is JsonArray rows && rows.Count > 0 &&
          rows.Count == proof[pair.Item2]?.GetValue<int>());
    Require(user["ClearedTutorialDataNew"] is JsonObject tutorials && tutorials.Count > 0 &&
        tutorials.Count == proof["tutorialGroupCount"]?.GetValue<int>() &&
        user.ContainsKey("SelectedClassicSoloRaidManagerId") && user.ContainsKey("Username") &&
        user.ContainsKey("Password") && database.ContainsKey("LauncherTokenKey") &&
        database.ContainsKey("EncryptionTokenKey"));

    var original = database.DeepClone();
    var username = "synthetic-validation-" + assessment.ToString("D");
    var password = Convert.ToBase64String(credentialEntropy);
    user["Username"] = username;
    // Existing local SDK protocol expects MD5; not used as a new password-storage scheme.
    user["Password"] = Convert.ToHexString(MD5.HashData(Encoding.UTF8.GetBytes(password))).ToLowerInvariant();
    user["LocalPersistenceBinding"] = null; // No write-back to the operating account/preferences store.
    user["SelectedClassicSoloRaidManagerId"] = selectedManager;
    database["LauncherTokenKey"] = Convert.ToBase64String(launcherKey);
    database["EncryptionTokenKey"] = Convert.ToBase64String(encryptionKey);
    var unchanged = database.DeepClone();
    foreach (var name in new[] { "Username", "Password", "LocalPersistenceBinding", "SelectedClassicSoloRaidManagerId" })
      unchanged["Users"]![0]![name] = original["Users"]![0]![name]?.DeepClone();
    foreach (var name in new[] { "LauncherTokenKey", "EncryptionTokenKey" })
      unchanged[name] = original[name]?.DeepClone();
    Require(JsonNode.DeepEquals(original, unchanged));
    var dbBytes = Encoding.UTF8.GetBytes(database.ToJsonString());
    var context = JsonSerializer.SerializeToUtf8Bytes(new { username, password });
    var receipt = JsonSerializer.SerializeToUtf8Bytes(new
    {
      contractId = "nll/user-validation-prepared-account/v1",
      assessmentUid = assessment.ToString("D"),
      executionOwnerCode = "user",
      seasonNumber = season,
      weaknessCode = weakness,
      profileSha256 = profileHash,
      sourceDatabaseSha256 = Hash(source),
      sourceReceiptSha256 = Hash(sourceReceipt),
      accountRevisionSetSha256 = Text(proof, "accountRevisionSetSha256"),
      runtimeDatabaseSha256 = Hash(dbBytes),
      syntheticContextSha256 = Hash(context),
      characterCount = proof["characterCount"]!.GetValue<int>(),
      tutorialGroupCount = proof["tutorialGroupCount"]!.GetValue<int>(),
      completedScenarioCount = proof["completedScenarioCount"]!.GetValue<int>(),
      allOtherFieldsPreserved = true,
      operatingPersistenceDetached = true,
      localCredentialsReplaced = true,
      localTokenKeysReplaced = true,
      rawSourceIdentifiersPersisted = false,
      sourceDatabaseModified = false,
      officialOutboundUsed = false,
      gameStarted = false,
      nativeAdmission = "not_assessed"
    });
    return new(dbBytes, context, receipt);
  }

  private static JsonObject Parse(byte[] bytes, int limit)
  {
    Require(bytes.Length > 0 && bytes.Length <= limit);
    using var document = JsonDocument.Parse(bytes, new JsonDocumentOptions { MaxDepth = 64 });
    RejectDuplicates(document.RootElement);
    return JsonNode.Parse(bytes) as JsonObject ?? throw Rejected();
  }
  private static void RejectDuplicates(JsonElement element)
  {
    if (element.ValueKind == JsonValueKind.Object)
    {
      var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
      foreach (var property in element.EnumerateObject())
      {
        Require(names.Add(property.Name));
        RejectDuplicates(property.Value);
      }
    }
    else if (element.ValueKind == JsonValueKind.Array)
      foreach (var child in element.EnumerateArray()) RejectDuplicates(child);
  }
  private static string Text(JsonObject obj, string key) => obj[key]?.GetValue<string>() ?? "";
  internal static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
  private static bool IsHash(string value) => value.Length == 64 && value.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f');
  private static InvalidOperationException Rejected() => new("phase_d_user_validation_account_rejected");
  private static void Require(bool value) { if (!value) throw Rejected(); }
}
