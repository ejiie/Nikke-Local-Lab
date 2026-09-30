using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

internal sealed record BossRuntimeVariantChallengeSelector(
    string DifficultyTypeCode,
    int WaveOrder,
    int TargetCardinality);

internal sealed record BossRuntimeVariantManagerObservation(
    string ContractId,
    string CanonicalizationCode,
    string SourceObservationSha256,
    int[] RoleLineCounts,
    int CanonicalLineCount,
    int CanonicalByteLength,
    string TrustedSha256);

internal sealed record BossRuntimeVariantAffinity(
    string BossElementCode,
    string WeaknessCode);

internal sealed record BossRuntimeVariantSkillClosure(
    int MonsterSkillRelationCount,
    int MonsterSkillRecordCount,
    int PassiveStateEffectRecordCount,
    int RootFunctionRecordCount,
    int ClosedFunctionRecordCount,
    int MissingReferenceCount,
    string CanonicalSha256);

internal sealed record BossRuntimeVariantBehaviorAssembly(
    string ModeCode,
    int RootReferenceCount,
    string RootReferenceSetSha256,
    string AssetClosureStatusCode,
    long BundleByteLength,
    string BundleSha256,
    int GraphMatchCount,
    int NodeCount,
    string CanonicalGraphSha256,
    string TaskTypeSetSha256,
    string SkillAnimationReferenceSetSha256,
    string PartReferenceSetSha256,
    string PointReferenceSetSha256);

internal sealed record BossRuntimeVariantAssetBundle(
    string Sha256,
    long ByteLength);

internal sealed record BossRuntimeVariantShieldFxMapping(
    string SourceFxPrefabSetSha256,
    string TargetFxPrefabSetSha256,
    string AssetBundleSetSha256,
    BossRuntimeVariantAssetBundle[] AssetBundles,
    string SourceKindCode);

internal sealed record BossRuntimeVariantShieldFxVariant(
    string BossElementCode,
    string MappingSetSha256,
    BossRuntimeVariantShieldFxMapping[] Mappings);

internal sealed record BossRuntimeVariantElementShield(
    string ModeCode,
    string FunctionTypeCode,
    int FunctionRecordCount,
    int SkillBindingCount,
    int PassiveBindingCount,
    string FunctionSetSha256,
    string SourceFxPrefabSetSha256,
    bool FxVariantRequired,
    string FxVariantStatusCode,
    BossRuntimeVariantShieldFxVariant[] FxVariants);

internal sealed record BossRuntimeVariantQuickTimeEventAffinity(
    string ModeCode,
    int RecordCount,
    int MonsterReferenceCount,
    string RecordSetSha256,
    string ImmutablePayloadSetSha256,
    string SourceElementSetSha256,
    string[] SourceElementCodes);

internal sealed record BossRuntimeVariantShieldFxTransformVariant(
    string BossElementCode,
    string SourceBundleSha256,
    long SourceBundleByteLength,
    string TargetBundleSha256,
    long TargetBundleByteLength,
    string VariantBundleSha256,
    long VariantBundleByteLength,
    int SourceTransformCount,
    int TargetTransformCount,
    int MatchedTransformCount,
    int ModifiedTransformCount,
    string MatchedTransformValueSetSha256,
    string NonTransformObjectSetSha256);

internal sealed record BossRuntimeVariantShieldFxTransformNormalization(
    string ModeCode,
    string SourceBossElementCode,
    string[] TargetBossElementCodes,
    BossRuntimeVariantShieldFxTransformVariant[] Variants);

internal sealed record BossRuntimeVariantShieldFxPreparedVariant(
    string BossElementCode, string SourceFxPrefabSetSha256, string TargetFxPrefabSetSha256,
    string OperationCode, BossRuntimeVariantAssetBundle SourceBundle,
    BossRuntimeVariantAssetBundle TargetBundle, BossRuntimeVariantAssetBundle OutputBundle);

internal sealed record BossRuntimeVariantShieldFxPreparation(
    string ContractId, string PolicyCode, string SourceBossElementCode,
    string RecipeManifestSha256, BossRuntimeVariantShieldFxPreparedVariant[] Variants);

internal sealed record BossRuntimeVariantTransformation(
    string ModeCode,
    string[] AllowedTableCodes,
    bool PreserveElementTable,
    bool RestrictToTargetMonsterElementIds,
    bool RawSourceIdentifiersPersisted);

internal sealed record BossRuntimeVariantProfile(
    int SchemaVersion,
    string ContractId,
    string ProfileCode,
    int SeasonNumber,
    string DisplayNameCode,
    BossRuntimeVariantManagerObservation SelectedManagerObservation,
    BossRuntimeVariantChallengeSelector ChallengeSelector,
    BossRuntimeVariantAffinity SourceAffinity,
    BossRuntimeVariantSkillClosure? SkillClosure,
    BossRuntimeVariantBehaviorAssembly? BehaviorAssembly,
    BossRuntimeVariantElementShield ElementShield,
    BossRuntimeVariantQuickTimeEventAffinity? QuickTimeEventAffinity,
    BossRuntimeVariantShieldFxTransformNormalization? ShieldFxTransformNormalization,
    BossRuntimeVariantShieldFxPreparation? ShieldFxPreparation,
    BossRuntimeVariantTransformation Transformation,
    string Sha256)
{
  public const string V1ContractId = "nll/boss-runtime-variant-profile/v1";
  public const string V2ContractId = "nll/boss-runtime-variant-profile/v2";
  public const string V3ContractId = "nll/boss-runtime-variant-profile/v3";
  public const string V4ContractId = "nll/boss-runtime-variant-profile/v4";

  public static async Task<BossRuntimeVariantProfile> LoadAsync(string path)
  {
    path = Path.GetFullPath(path);
    Require(File.Exists(path), "phase_d_boss_variant_profile_missing");
    var bytes = await File.ReadAllBytesAsync(path);
    try
    {
      var document = JsonSerializer.Deserialize<BossRuntimeVariantProfileDocument>(
          bytes,
          new JsonSerializerOptions
          {
            PropertyNameCaseInsensitive = true,
            UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow
          }) ??
          throw new InvalidOperationException("phase_d_boss_variant_profile_invalid");
      var profile = new BossRuntimeVariantProfile(
          document.SchemaVersion,
          document.ContractId ?? string.Empty,
          document.ProfileCode ?? string.Empty,
          document.SeasonNumber,
          document.DisplayNameCode ?? string.Empty,
          document.SelectedManagerObservation ?? new(
              string.Empty, string.Empty, string.Empty, [], 0, 0, string.Empty),
          document.ChallengeSelector ?? new(string.Empty, 0, 0),
          document.SourceAffinity ?? new(string.Empty, string.Empty),
          document.SkillClosure,
          document.BehaviorAssembly,
          document.ElementShield ?? new(
              string.Empty, string.Empty, 0, 0, 0, string.Empty, string.Empty,
              false, string.Empty, []),
          document.QuickTimeEventAffinity,
          document.ShieldFxTransformNormalization,
          document.ShieldFxPreparation,
          document.Transformation ?? new(string.Empty, [], false, false, true),
          Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant());
      profile.Validate();
      return profile;
    }
    catch (JsonException)
    {
      throw new InvalidOperationException("phase_d_boss_variant_profile_invalid");
    }
    finally
    {
      CryptographicOperations.ZeroMemory(bytes);
    }
  }

  private void Validate()
  {
    Require((SchemaVersion == 1 && ContractId == V1ContractId) ||
            (SchemaVersion == 2 && ContractId == V2ContractId) ||
            (SchemaVersion == 3 && ContractId == V3ContractId) ||
            (SchemaVersion == 4 && ContractId == V4ContractId),
        "phase_d_boss_variant_profile_invalid");
    Require(IsCode(ProfileCode) && IsCode(DisplayNameCode) && SeasonNumber > 0,
        "phase_d_boss_variant_profile_invalid");
    Require(ChallengeSelector.DifficultyTypeCode == "challenge" &&
            ChallengeSelector.WaveOrder > 0 &&
            ChallengeSelector.TargetCardinality == 1,
        "phase_d_boss_variant_profile_invalid");
    Require(SelectedManagerObservation.ContractId.Length is >= 1 and <= 128 &&
            SelectedManagerObservation.CanonicalizationCode.Length is >= 1 and <= 128 &&
            IsSha256(SelectedManagerObservation.SourceObservationSha256) &&
            (SchemaVersion == 1 ||
             (SelectedManagerObservation.RoleLineCounts is { Length: 6 } &&
              SelectedManagerObservation.RoleLineCounts.All(value => value > 0) &&
              SelectedManagerObservation.RoleLineCounts.Take(3).SequenceEqual([3, 13, 13]) &&
              SelectedManagerObservation.RoleLineCounts.Sum() + 1 ==
                  SelectedManagerObservation.CanonicalLineCount)) &&
            SelectedManagerObservation.CanonicalLineCount > 0 &&
            SelectedManagerObservation.CanonicalByteLength > 0 &&
            IsSha256(SelectedManagerObservation.TrustedSha256),
        "phase_d_boss_variant_profile_invalid");
    Require(IsElement(SourceAffinity.BossElementCode) &&
            IsElement(SourceAffinity.WeaknessCode),
        "phase_d_boss_variant_profile_invalid");
    Require(SchemaVersion is 3 or 4 ||
            (QuickTimeEventAffinity is null && ShieldFxTransformNormalization is null),
        "phase_d_boss_variant_profile_invalid");
    Require((SchemaVersion == 4 || ShieldFxPreparation is null) &&
            (SchemaVersion == 3 || ShieldFxTransformNormalization is null), "phase_d_boss_variant_profile_invalid");
    if (SchemaVersion == 1)
    {
      Require(ElementShield.ModeCode == "none" &&
              !ElementShield.FxVariantRequired &&
              ElementShield.FxVariantStatusCode == "not_required" &&
              Transformation.ModeCode == "target_monster_element_reference" &&
              Transformation.AllowedTableCodes is { Length: 1 } &&
              Transformation.AllowedTableCodes[0] == "monster",
          "phase_d_boss_variant_profile_invalid");
    }
    else
    {
      Require(SkillClosure is not null &&
              SkillClosure.MonsterSkillRelationCount > 0 &&
              SkillClosure.MonsterSkillRecordCount > 0 &&
              SkillClosure.PassiveStateEffectRecordCount >= 0 &&
              SkillClosure.RootFunctionRecordCount >= 0 &&
              SkillClosure.ClosedFunctionRecordCount >=
                  SkillClosure.RootFunctionRecordCount &&
              SkillClosure.MissingReferenceCount == 0 &&
              IsSha256(SkillClosure.CanonicalSha256),
          "phase_d_boss_variant_profile_invalid");
      Require(BehaviorAssembly is not null &&
              BehaviorAssembly.ModeCode == "preserve_exact_external_behavior_tree" &&
              BehaviorAssembly.RootReferenceCount > 0 &&
              IsSha256(BehaviorAssembly.RootReferenceSetSha256) &&
              BehaviorAssembly.AssetClosureStatusCode == "resolved" &&
              BehaviorAssembly.BundleByteLength > 0 &&
              IsSha256(BehaviorAssembly.BundleSha256) &&
              BehaviorAssembly.GraphMatchCount == BehaviorAssembly.RootReferenceCount &&
              BehaviorAssembly.NodeCount > 0 &&
              IsSha256(BehaviorAssembly.CanonicalGraphSha256) &&
              IsSha256(BehaviorAssembly.TaskTypeSetSha256) &&
              IsSha256(BehaviorAssembly.SkillAnimationReferenceSetSha256) &&
              IsSha256(BehaviorAssembly.PartReferenceSetSha256) &&
              IsSha256(BehaviorAssembly.PointReferenceSetSha256),
          "phase_d_boss_variant_profile_invalid");
      ValidateV2Shield();
      if (SchemaVersion == 3) ValidateV3QteAndShieldTransform();
      if (SchemaVersion == 4)
      {
        if (QuickTimeEventAffinity is not null) ValidateQte();
        ValidatePreparedShield();
      }
    }
    Require(
            Transformation.PreserveElementTable &&
            Transformation.RestrictToTargetMonsterElementIds &&
            !Transformation.RawSourceIdentifiersPersisted,
        "phase_d_boss_variant_profile_invalid");
  }

  private void ValidateV2Shield()
  {
    if (ElementShield.ModeCode == "none")
    {
      Require(ElementShield.FunctionTypeCode == "not_applicable" &&
              ElementShield.FunctionRecordCount == 0 &&
              ElementShield.SkillBindingCount == 0 &&
              ElementShield.PassiveBindingCount == 0 &&
              !ElementShield.FxVariantRequired &&
              ElementShield.FxVariantStatusCode == "not_required" &&
              ElementShield.FxVariants.Length == 0 &&
              Transformation.ModeCode == (QuickTimeEventAffinity is null ? "target_monster_element_reference" : "target_monster_element_and_qte_element") &&
              Transformation.AllowedTableCodes.SequenceEqual(QuickTimeEventAffinity is null ? ["monster"] : new[] { "monster", "quick_time_event" }),
          "phase_d_boss_variant_profile_invalid");
      return;
    }
    var expectedTransformationMode = QuickTimeEventAffinity is not null
        ? "target_monster_element_dynamic_shield_fx_and_qte_element"
        : "target_monster_element_and_dynamic_shield_fx";
    var expectedAllowedTables = QuickTimeEventAffinity is not null
        ? new[] { "monster", "function", "quick_time_event" }
        : new[] { "monster", "function" };
    Require(ElementShield.ModeCode == "dynamic_affinity_linked" &&
            ElementShield.FunctionTypeCode == "immune_other_element" &&
            ElementShield.FunctionRecordCount > 0 &&
            ElementShield.SkillBindingCount + ElementShield.PassiveBindingCount > 0 &&
            IsSha256(ElementShield.FunctionSetSha256) &&
            IsSha256(ElementShield.SourceFxPrefabSetSha256) &&
            ElementShield.FxVariantRequired &&
            ElementShield.FxVariantStatusCode == "resolved" &&
            ElementShield.FxVariants is { Length: 5 } &&
            ElementShield.FxVariants.Select(value => value.BossElementCode)
                .Distinct(StringComparer.Ordinal).Count() == 5 &&
            ElementShield.FxVariants.All(ValidateShieldFxVariant) &&
            ElementShield.FxVariants.Single(value =>
                value.BossElementCode == SourceAffinity.BossElementCode).Mappings.All(
                    mapping => mapping.SourceFxPrefabSetSha256 ==
                        mapping.TargetFxPrefabSetSha256) &&
            Transformation.ModeCode == expectedTransformationMode &&
            Transformation.AllowedTableCodes.SequenceEqual(expectedAllowedTables),
        "phase_d_boss_variant_profile_invalid");
  }

  private void ValidateV3QteAndShieldTransform()
  {
    ValidateQte();
    Require(ShieldFxTransformNormalization is not null &&
            ShieldFxTransformNormalization.ModeCode ==
                "per_execution_target_bundle_overlay" &&
            ShieldFxTransformNormalization.SourceBossElementCode ==
                SourceAffinity.BossElementCode &&
            ShieldFxTransformNormalization.TargetBossElementCodes
                .SequenceEqual(["fire", "wind", "iron"]) &&
            ShieldFxTransformNormalization.Variants is { Length: 3 } &&
            ShieldFxTransformNormalization.Variants.Select(value =>
                value.BossElementCode).SequenceEqual(["fire", "wind", "iron"]) &&
            ShieldFxTransformNormalization.Variants.All(ValidateTransformVariant),
        "phase_d_boss_variant_profile_invalid");
  }

  private void ValidateQte()
  {
    // Linked rows may keep different original elements (the set is sorted and
    // unique). The variant converts or preserves them per row, so the set need
    // not equal the boss element.
    var codes = QuickTimeEventAffinity?.SourceElementCodes ?? [];
    Require(QuickTimeEventAffinity is not null &&
            QuickTimeEventAffinity.ModeCode == "target_monster_linked_element_only" &&
            QuickTimeEventAffinity.RecordCount > 0 &&
            QuickTimeEventAffinity.MonsterReferenceCount > 0 &&
            IsSha256(QuickTimeEventAffinity.RecordSetSha256) &&
            IsSha256(QuickTimeEventAffinity.ImmutablePayloadSetSha256) &&
            IsSha256(QuickTimeEventAffinity.SourceElementSetSha256) &&
            codes.Length > 0 && codes.Length <= QuickTimeEventAffinity.RecordCount &&
            codes.All(IsElement) &&
            codes.SequenceEqual(codes.Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal)),
        "phase_d_boss_variant_profile_invalid");
  }

  private void ValidatePreparedShield()
  {
    if (ElementShield.ModeCode == "none")
    {
      Require(ShieldFxPreparation is null, "phase_d_boss_variant_profile_invalid");
      return;
    }
    var plan = ShieldFxPreparation;
    Require(plan is not null && plan.ContractId == "nll/boss-shield-fx-preparation/v1" &&
            plan.PolicyCode == "source_shield_size_candidate/v2" &&
            plan.SourceBossElementCode == SourceAffinity.BossElementCode && IsSha256(plan.RecipeManifestSha256),
            "phase_d_boss_variant_profile_invalid");
    var expected = ElementShield.FxVariants.SelectMany(v => v.Mappings.Select(m => (v.BossElementCode, Mapping: m)))
        .ToDictionary(v => (v.BossElementCode, v.Mapping.SourceFxPrefabSetSha256), v => v.Mapping);
    Require(plan!.Variants.Length == expected.Count &&
            plan.Variants.Select(v => (v.BossElementCode, v.SourceFxPrefabSetSha256)).Distinct().Count() == expected.Count,
            "phase_d_boss_variant_profile_invalid");
    foreach (var row in plan.Variants)
    {
      Require(expected.TryGetValue((row.BossElementCode, row.SourceFxPrefabSetSha256), out var mapping) &&
              expected.TryGetValue((SourceAffinity.BossElementCode, row.SourceFxPrefabSetSha256), out _),
              "phase_d_boss_variant_profile_invalid");
      var source = expected[(SourceAffinity.BossElementCode, row.SourceFxPrefabSetSha256)];
      Require(mapping!.TargetFxPrefabSetSha256 == row.TargetFxPrefabSetSha256 &&
              mapping.AssetBundles.SequenceEqual([row.TargetBundle]) && source.AssetBundles.SequenceEqual([row.SourceBundle]) &&
              row.OutputBundle is not null && IsSha256(row.OutputBundle.Sha256) && row.OutputBundle.ByteLength > 0 &&
              (row.OperationCode == "reuse" ? row.OutputBundle == row.TargetBundle :
               row.OperationCode == "adjust_candidate" && row.OutputBundle != row.TargetBundle) &&
              (row.BossElementCode != SourceAffinity.BossElementCode || row.OperationCode == "reuse"),
              "phase_d_boss_variant_profile_invalid");
    }
  }

  private bool ValidateTransformVariant(BossRuntimeVariantShieldFxTransformVariant value)
  {
    if (!IsElement(value.BossElementCode) ||
        !IsSha256(value.SourceBundleSha256) || value.SourceBundleByteLength <= 0 ||
        !IsSha256(value.TargetBundleSha256) || value.TargetBundleByteLength <= 0 ||
        !IsSha256(value.VariantBundleSha256) || value.VariantBundleByteLength <= 0 ||
        value.SourceTransformCount <= 0 || value.TargetTransformCount <= 0 ||
        value.MatchedTransformCount <= 0 || value.ModifiedTransformCount <= 0 ||
        value.MatchedTransformCount > value.TargetTransformCount ||
        value.ModifiedTransformCount > value.MatchedTransformCount ||
        !IsSha256(value.MatchedTransformValueSetSha256) ||
        !IsSha256(value.NonTransformObjectSetSha256))
    {
      return false;
    }
    var sourceBundles = ElementShield.FxVariants.Single(variant =>
        variant.BossElementCode == SourceAffinity.BossElementCode).Mappings
        .SelectMany(mapping => mapping.AssetBundles).ToArray();
    var targetBundles = ElementShield.FxVariants.Single(variant =>
        variant.BossElementCode == value.BossElementCode).Mappings
        .SelectMany(mapping => mapping.AssetBundles).ToArray();
    return sourceBundles.Length == 1 && targetBundles.Length == 1 &&
        sourceBundles[0].Sha256 == value.SourceBundleSha256 &&
        sourceBundles[0].ByteLength == value.SourceBundleByteLength &&
        targetBundles[0].Sha256 == value.TargetBundleSha256 &&
        targetBundles[0].ByteLength == value.TargetBundleByteLength;
  }

  private bool ValidateShieldFxVariant(BossRuntimeVariantShieldFxVariant value)
  {
    if (!IsElement(value.BossElementCode) ||
        !IsSha256(value.MappingSetSha256) ||
        value.Mappings.Length == 0 ||
        value.Mappings.Select(mapping => mapping.SourceFxPrefabSetSha256)
            .Distinct(StringComparer.Ordinal).Count() != value.Mappings.Length)
    {
      return false;
    }
    var sourceSet = HashStrings(value.Mappings
        .Select(mapping => mapping.SourceFxPrefabSetSha256)
        .Order(StringComparer.Ordinal));
    if (sourceSet != ElementShield.SourceFxPrefabSetSha256) return false;
    foreach (var mapping in value.Mappings)
    {
      if (!IsSha256(mapping.SourceFxPrefabSetSha256) ||
          !IsSha256(mapping.TargetFxPrefabSetSha256) ||
          !IsSha256(mapping.AssetBundleSetSha256) ||
          mapping.SourceKindCode is not ("boss_specific" or "common") ||
          mapping.AssetBundles.Length == 0 ||
          mapping.AssetBundles.Select(bundle => bundle.Sha256)
              .Distinct(StringComparer.Ordinal).Count() != mapping.AssetBundles.Length ||
          mapping.AssetBundles.Any(bundle =>
              !IsSha256(bundle.Sha256) || bundle.ByteLength <= 0))
      {
        return false;
      }
      var bundleSet = HashStrings(mapping.AssetBundles
          .Select(bundle => $"{bundle.ByteLength}\t{bundle.Sha256}")
          .Order(StringComparer.Ordinal));
      if (bundleSet != mapping.AssetBundleSetSha256) return false;
    }
    var mappingSet = HashStrings(value.Mappings.Select(mapping => string.Join('\t',
        mapping.SourceFxPrefabSetSha256,
        mapping.TargetFxPrefabSetSha256,
        mapping.AssetBundleSetSha256,
        mapping.SourceKindCode)).Order(StringComparer.Ordinal));
    return mappingSet == value.MappingSetSha256;
  }

  private static bool IsCode(string value) =>
      value.Length is >= 1 and <= 64 &&
      value[0] is >= 'a' and <= 'z' &&
      value.All(static character =>
          character is >= 'a' and <= 'z' or >= '0' and <= '9' or '.' or '_' or '-');

  private static bool IsElement(string value) =>
      value is "fire" or "water" or "wind" or "electric" or "iron";

  private static bool IsSha256(string value) =>
      value.Length == 64 && value.All(static character =>
          character is >= '0' and <= '9' or >= 'a' and <= 'f');

  private static string HashStrings(IEnumerable<string> values) =>
      Convert.ToHexString(SHA256.HashData(
          Encoding.UTF8.GetBytes(string.Join("\n", values)))).ToLowerInvariant();

  private static void Require(bool condition, string code)
  {
    if (!condition) throw new InvalidOperationException(code);
  }

  private sealed record BossRuntimeVariantProfileDocument(
      int SchemaVersion,
      string? ContractId,
      string? ProfileCode,
      int SeasonNumber,
      string? DisplayNameCode,
      BossRuntimeVariantManagerObservation? SelectedManagerObservation,
      BossRuntimeVariantChallengeSelector? ChallengeSelector,
      BossRuntimeVariantAffinity? SourceAffinity,
      BossRuntimeVariantSkillClosure? SkillClosure,
      BossRuntimeVariantBehaviorAssembly? BehaviorAssembly,
      BossRuntimeVariantElementShield? ElementShield,
      BossRuntimeVariantQuickTimeEventAffinity? QuickTimeEventAffinity,
      BossRuntimeVariantShieldFxTransformNormalization? ShieldFxTransformNormalization,
      BossRuntimeVariantShieldFxPreparation? ShieldFxPreparation,
      BossRuntimeVariantTransformation? Transformation);
}
