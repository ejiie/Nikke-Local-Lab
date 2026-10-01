using System.Text.Json;
using static CommonDeliveryFiles;

internal sealed record CommonBossDeliveryPlan(string ContractId, string ProfileSha256,
    CommonFilePin CandidateSeal, CommonFilePin? NativeChunkReceipt, CommonFilePin? NativeStore);
internal sealed record CommonNativeExecution(string ContractId, string ExecutionUid, string ProfileSha256,
    string CandidateSealSha256, string WeaknessCode, CommonFilePin OriginalStore,
    string CandidateStoreSha256, CommonNativePatch[] Patches);

// Common preparation: profile semantics and all sealed assembly outputs precede
// admission. Reading this descriptor neither launches nor writes client inputs.
internal static class CommonBossDelivery
{
  private static void Require([System.Diagnostics.CodeAnalysis.DoesNotReturnIf(false)] bool ok) => CommonDeliveryFiles.Require(ok);
  internal static async Task<(CommonBossDeliveryPlan Plan, BossRuntimeVariantProfile Profile, CommonNativePatch[] Patches, JsonElement Seal)>
      Validate(string descriptor, string digest, string profilePath, string weakness, bool fullVerification = true)
  {
    using var document = ReadJson(descriptor, digest);
    var plan = document.RootElement.Deserialize<CommonBossDeliveryPlan>(Json)!;
    Require(plan is not null && plan.ContractId == "nll/common-boss-delivery/v1");
    var profile = await BossRuntimeVariantProfile.LoadAsync(Plain(profilePath));
    Require(profile.Sha256 == plan.ProfileSha256);
    var target = weakness switch { "fire" => "wind", "water" => "fire", "wind" => "iron", "electric" => "water", "iron" => "electric", _ => "" };
    Require(target != "");
    using var candidate = JsonDocument.Parse(Read(plan.CandidateSeal));
    var seal = candidate.RootElement;
    Require(Text(seal, "contractId") == "nll/boss-onboarding-verified-candidate/v1" &&
        Text(seal, "profileSha256") == profile.Sha256 && seal.GetProperty("affinityVariantCount").GetInt32() == 5 &&
        Text(seal, "fiveAffinityVariantStatusCode") == "passed" && !seal.GetProperty("clientStarted").GetBoolean());
    var root = Path.GetDirectoryName(plan.CandidateSeal.Path)!;
    var names = new HashSet<string>(StringComparer.Ordinal);
    foreach (var row in seal.GetProperty("artifacts").EnumerateArray())
    {
      var name = Text(row, "relativePath");
      var path = Plain(Path.Combine(root, name));
      Require(!Path.IsPathRooted(name) && names.Add(name) && path.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase));
      // Seals published before byteLength keep the digest check at launch.
      var sealedLength = row.TryGetProperty("byteLength", out var size);
      if (fullVerification || !sealedLength) Require(FileHash(path) == Text(row, "sha256"));
      if (sealedLength)
        Require(size.TryGetInt64(out var length) && length >= 0 && File.Exists(path) && new FileInfo(path).Length == length);
    }
    Require(names.Contains("boss-runtime-variant.profile.json") && FileHash(Path.Combine(root, "boss-runtime-variant.profile.json")) == profile.Sha256);
    var adjusted = profile.ShieldFxPreparation?.Variants.Where(row => row.OperationCode == "adjust_candidate").ToArray() ?? [];
    if (profile.ShieldFxPreparation is { } preparation)
    {
      Require(names.Contains("shield-fx-preparation/recipes.receipt.json") &&
          FileHash(Path.Combine(root, "shield-fx-preparation", "recipes.receipt.json")) == preparation.RecipeManifestSha256);
    }
    if (adjusted.Length == 0) { Require(plan.NativeChunkReceipt is null && plan.NativeStore is null); return (plan, profile, [], seal.Clone()); }
    Require(plan.NativeChunkReceipt is not null && plan.NativeStore is not null);
    // The installed target is the selected, isolated compatibility clone only.
    var store = Plain(plan.NativeStore!.Path);
    _ = InstalledStoreBuild(store);
    using var chunks = JsonDocument.Parse(Read(plan.NativeChunkReceipt!));
    var c = chunks.RootElement;
    Require(Text(c, "contractId") == "nll/native-fx-chunk-candidate/v1" && Text(c, "statusCode") == "offline_chunk_candidate_verified" &&
        c.GetProperty("sourceFilesUnchanged").GetBoolean() && c.GetProperty("indexTrailerVerified").GetBoolean() &&
        c.GetProperty("exactCompressedLengthRoundTripVerified").GetBoolean() && !c.GetProperty("installedFilesModified").GetBoolean() &&
        Text(c, "sourceStoreSha256") == plan.NativeStore.Sha256 && c.GetProperty("sourceStoreByteLength").GetInt64() == plan.NativeStore.Length);
    var chunkRoot = Path.GetDirectoryName(plan.NativeChunkReceipt!.Path)!;
    using var manifest = ReadJson(Path.Combine(chunkRoot, "manifest.private.json"), Text(c, "manifestSha256"));
    var nativeRoot = Path.Combine(Path.GetDirectoryName(chunkRoot)!, "native-candidate");
    var layoutRoot = Path.Combine(Path.GetDirectoryName(chunkRoot)!, "native-fixed-layout");
    using var layout = ReadJson(Path.Combine(layoutRoot, "receipt.json"), Text(c, "layoutSha256"));
    using var native = ReadJson(Path.Combine(nativeRoot, "receipt.json"), Text(layout.RootElement, "sourceCandidateSha256"));
    Require(Text(native.RootElement, "profileSha256") == profile.Sha256 &&
        Text(native.RootElement, "sourceCandidateManifestSha256") == profile.ShieldFxPreparation!.RecipeManifestSha256 &&
        Text(native.RootElement, "recipePolicyCode") == profile.ShieldFxPreparation.PolicyCode);
    var requiredRoles = adjusted.Select(row => row.BossElementCode).ToHashSet(StringComparer.Ordinal);
    Require(requiredRoles.Count == adjusted.Length && requiredRoles.SetEquals(c.GetProperty("roleCodes").EnumerateArray().Select(row => row.GetString()!)));
    var patches = new List<CommonNativePatch>();
    long end = 256;
    foreach (var row in manifest.RootElement.GetProperty("entries").EnumerateArray().OrderBy(row => row.GetProperty("offset").GetInt64()))
    {
      var role = Text(row, "roleCode"); var ordinal = row.GetProperty("ordinal").GetInt32();
      var size = row.GetProperty("byteLength").GetInt64(); var offset = row.GetProperty("offset").GetInt64();
      Require(requiredRoles.Contains(role) && size is > 0 and <= 16777216 && offset >= end && offset <= plan.NativeStore.Length - size);
      CommonFilePin Chunk(string kind)
      {
        var name = $"{role}-{ordinal}-{kind}.chunk"; Require(Text(row, kind + "File") == name);
        var pin = new CommonFilePin(Path.Combine(chunkRoot, name), size, Text(row, kind + "Sha256"));
        if (fullVerification) _ = Read(pin, 16777216);
        else Require(File.Exists(Plain(pin.Path)) && new FileInfo(pin.Path).Length == pin.Length);
        return pin;
      }
      var before = Chunk("before"); var after = Chunk("after"); Require(before.Sha256 != after.Sha256);
      patches.Add(new(role, offset, before, after)); end = offset + size;
    }
    Require(patches.Count is > 0 and <= 32 && patches.Sum(row => row.Before.Length) <= 67108864 &&
        requiredRoles.SetEquals(patches.Select(row => row.RoleCode)));
    return (plan, profile, patches.Where(row => row.RoleCode == target).ToArray(), seal.Clone());
  }

  // Called only with the candidate seal returned by Validate. Its installation
  // verification already proved the pack; launch checks its length, not its payload.
  internal static string CopyVariant(CommonBossDeliveryPlan plan, JsonElement seal,
      BossRuntimeVariantProfile profile, string weakness, string sourcePackSha256,
      string variantPackPath, string receiptPath)
  {
    var root = Path.GetDirectoryName(plan.CandidateSeal.Path)!;
    JsonElement Member(string name) => seal.GetProperty("artifacts").EnumerateArray()
        .Single(row => Text(row, "relativePath") == name);
    var prefix = "five-affinity-variants/" + weakness;
    var receiptName = prefix + ".receipt.json";
    var receiptSource = Path.Combine(root, receiptName);
    using var receipt = ReadJson(receiptSource, Text(Member(receiptName), "sha256"));
    var row = receipt.RootElement;
    if (Text(row, "sourceStaticDataSha256") != sourcePackSha256)
      throw new InvalidOperationException("phase_d_variant_pack_source_changed");
    Require(Text(row, "contractId") == "nll/boss-affinity-static-data-variant/v1" &&
        Text(row, "variantProfileSha256") == profile.Sha256 && Text(row, "weaknessCode") == weakness &&
        row.GetProperty("variantRequired").GetBoolean());
    var packName = prefix + ".pack";
    var hash = Text(Member(packName), "sha256");
    Require(Text(row, "variantStaticDataSha256") == hash);
    // Preserve the onboarding receipt as provenance; target/shield admission was
    // checked against the current runtime data before this copy.
    Directory.CreateDirectory(Path.GetDirectoryName(variantPackPath)!);
    File.Copy(Plain(Path.Combine(root, packName)), variantPackPath);
    File.Copy(receiptSource, receiptPath);
    return hash;
  }

  internal static async Task<object?> Stage(string descriptor, string digest, string profilePath, string weakness, string launchRoot)
  {
    var (plan, profile, patches, _) = await Validate(descriptor, digest, profilePath, weakness, fullVerification: false);
    return Stage(plan, profile, patches, weakness, launchRoot);
  }

  internal static object? Stage(CommonBossDeliveryPlan plan, BossRuntimeVariantProfile profile,
      CommonNativePatch[] patches, string weakness, string launchRoot)
  {
    if (patches.Length == 0) return null;
    var baseline = CommonNativeFxBaseline.Load(plan.NativeStore!);
    return NativeFxExecutionDelivery.Stage(launchRoot, profile.Sha256, plan.CandidateSeal.Sha256,
        profile.ShieldFxPreparation!.RecipeManifestSha256, weakness, baseline.Pin, baseline.Registration, patches);
  }
}
