using System.Globalization;
using System.Text.Json;
using System.Text;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Import.Profile;
using NikkeLocalLab.Provenance;
using Xunit;

namespace NikkeLocalLab.ProfileImport.UnitTests;

public sealed class CredentialBearingProfileSanitizerTests
{
  private static readonly byte[] IdentitySecret = Enumerable.Range(1, 32)
      .Select(static value => checked((byte)value))
      .ToArray();
  private static readonly Sha256Digest TransformerBinarySha256 =
      Sha256Digest.ComputeUtf8("synthetic-profile-transformer-binary-v1");

  [Fact]
  public void Coverage_preserves_four_by_three_coordinates_and_resolves_sparse_state_effects()
  {
    using var source = SyntheticCapture.Create();

    var result = new CredentialBearingProfileSanitizer().InspectCoverage(source);

    Assert.True(
        result.Succeeded,
        string.Join(',', result.Diagnostics.Select(static item => $"{item.Code}:{item.Count}")));
    var coverage = Assert.IsType<CredentialBearingProfileCoverage>(result.Coverage);
    Assert.Equal(2, coverage.RosterObservationCount);
    Assert.Equal(2, coverage.DetailObservationCount);
    Assert.Equal(1, coverage.CharacterLevelDifferenceCount);
    Assert.Equal(8, coverage.EquipmentCoordinateCount);
    Assert.Equal(2, coverage.OverloadReferenceCount);
    Assert.Equal(coverage.OverloadReferenceCount, coverage.StateEffectResolvedReferenceCount);
    Assert.Equal(1, coverage.SparseOverloadEquipmentCount);
    Assert.Equal(9, coverage.ConsoleObservationCount);
  }

  [Fact]
  public void Default_draft_keeps_both_levels_unresolved_and_contains_no_source_identifiers()
  {
    using var source = SyntheticCapture.Create();
    var resolver = SyntheticResolver.Create();
    var options = new OfflineProfileImportOptions(
        new DateTimeOffset(2026, 8, 20, 0, 0, 0, TimeSpan.Zero),
        TransformerBinarySha256);

    var result = new CredentialBearingProfileSanitizer().Sanitize(
        source,
        IdentitySecret,
        resolver,
        options);

    Assert.True(result.Succeeded);
    var draft = Assert.IsType<SanitizedProfileDraft>(result.Draft);
    Assert.Equal(SanitizedProfileDraftContract.SchemaCode, draft.Provenance.SchemaCode);
    Assert.False(draft.CanMaterializeLocalAccountProfile);
    Assert.False(draft.IsLocalAccountProfileWriteReady);
    Assert.All(draft.Builds, build =>
    {
      Assert.Equal(ProfileImportFactStatus.Unresolved, build.Level.ResolvedBattleLevel.Status);
      Assert.Equal("level_authority_not_selected", build.Level.ResolvedBattleLevel.ReasonCode);
      Assert.Null(build.Level.AuthorityPolicyCode);
    });
    var sparse = draft.Builds.SelectMany(static build => build.Equipment)
        .Single(static item => item.OverloadLines.Count == 2);
    Assert.Equal(new[] { 1, 3 }, sparse.OverloadLines.Select(static item => item.LineIndex));
    Assert.Equal(333, sparse.OverloadLines.Single(static item => item.LineIndex == 3)
        .ExactValue.UnscaledValue);
    Assert.Equal(9, draft.AccountState.Consoles.Count);
    Assert.All(draft.AccountState.Consoles, static item => Assert.True(item.ObservedExperience >= 0));
    Assert.Contains(result.Diagnostics, static item => item.Code == "capture_atomicity_unresolved");
    Assert.Contains(result.Diagnostics, static item => item.Code == "level_authority_not_selected");

    var serialized = JsonSerializer.Serialize(result);
    Assert.DoesNotContain("raw-account-sentinel", serialized, StringComparison.Ordinal);
    Assert.DoesNotContain("secret-token-value", serialized, StringComparison.Ordinal);
    Assert.DoesNotContain("https://official.invalid/private", serialized, StringComparison.Ordinal);
    foreach (var sourceReference in SyntheticCapture.AllSourceReferences)
    {
      Assert.DoesNotContain(sourceReference.ToString(), serialized, StringComparison.Ordinal);
    }
  }

  [Theory]
  [InlineData(CharacterLevelAuthorityPolicy.RosterObservationV1, "roster_observation/v1", 100)]
  [InlineData(CharacterLevelAuthorityPolicy.DetailObservationV1, "detail_observation/v1", 200)]
  public void Explicit_level_authority_materializes_only_the_selected_observation(
      CharacterLevelAuthorityPolicy authority,
      string expectedCode,
      int expectedFirstLevel)
  {
    using var source = SyntheticCapture.Create();
    var options = new OfflineProfileImportOptions(
        new DateTimeOffset(2026, 8, 20, 0, 0, 0, TimeSpan.Zero),
        TransformerBinarySha256,
        authority);

    var result = new CredentialBearingProfileSanitizer().Sanitize(
        source,
        IdentitySecret,
        SyntheticResolver.Create(),
        options);

    Assert.True(result.Succeeded);
    var draft = Assert.IsType<SanitizedProfileDraft>(result.Draft);
    Assert.True(draft.CanMaterializeLocalAccountProfile);
    Assert.True(draft.IsLocalAccountProfileWriteReady);
    var first = draft.Builds.Single(static item => item.Level.RosterLevel == 100);
    Assert.Equal(100, first.Level.RosterLevel);
    Assert.Equal(200, first.Level.DetailLevel);
    Assert.Equal(ProfileImportFactStatus.Ready, first.Level.ResolvedBattleLevel.Status);
    Assert.Equal(expectedFirstLevel, first.Level.ResolvedBattleLevel.Value);
    Assert.Equal(expectedCode, first.Level.AuthorityPolicyCode);
  }

  [Fact]
  public void Different_level_authority_policies_produce_different_sanitized_hashes()
  {
    var sanitizer = new CredentialBearingProfileSanitizer();
    using var rosterSource = SyntheticCapture.Create();
    using var detailSource = SyntheticCapture.Create();

    var roster = sanitizer.Sanitize(
        rosterSource,
        IdentitySecret,
        SyntheticResolver.Create(),
        new OfflineProfileImportOptions(
            new DateTimeOffset(2026, 8, 20, 0, 0, 0, TimeSpan.Zero),
            TransformerBinarySha256,
            CharacterLevelAuthorityPolicy.RosterObservationV1));
    var detail = sanitizer.Sanitize(
        detailSource,
        IdentitySecret,
        SyntheticResolver.Create(),
        new OfflineProfileImportOptions(
            new DateTimeOffset(2026, 8, 20, 0, 0, 0, TimeSpan.Zero),
            TransformerBinarySha256,
            CharacterLevelAuthorityPolicy.DetailObservationV1));

    Assert.NotEqual(
        Assert.IsType<SanitizedProfileDraft>(roster.Draft).Provenance.SanitizedPayloadSha256,
        Assert.IsType<SanitizedProfileDraft>(detail.Draft).Provenance.SanitizedPayloadSha256);
  }

  [Fact]
  public void Transformer_binary_hash_is_preserved_and_part_of_the_sanitized_hash()
  {
    var otherBinary = Sha256Digest.ComputeUtf8("synthetic-profile-transformer-binary-v2");
    using var firstSource = SyntheticCapture.Create();
    using var secondSource = SyntheticCapture.Create();
    var sanitizer = new CredentialBearingProfileSanitizer();

    var first = sanitizer.Sanitize(
        firstSource,
        IdentitySecret,
        SyntheticResolver.Create(),
        new OfflineProfileImportOptions(
            new DateTimeOffset(2026, 8, 20, 0, 0, 0, TimeSpan.Zero),
            TransformerBinarySha256,
            CharacterLevelAuthorityPolicy.DetailObservationV1));
    var second = sanitizer.Sanitize(
        secondSource,
        IdentitySecret,
        SyntheticResolver.Create(),
        new OfflineProfileImportOptions(
            new DateTimeOffset(2026, 8, 20, 0, 0, 0, TimeSpan.Zero),
            otherBinary,
            CharacterLevelAuthorityPolicy.DetailObservationV1));

    var firstDraft = Assert.IsType<SanitizedProfileDraft>(first.Draft);
    var secondDraft = Assert.IsType<SanitizedProfileDraft>(second.Draft);
    Assert.Equal(TransformerBinarySha256, firstDraft.Provenance.TransformerBinarySha256);
    Assert.Equal(otherBinary, secondDraft.Provenance.TransformerBinarySha256);
    Assert.NotEqual(
        firstDraft.Provenance.SanitizedPayloadSha256,
        secondDraft.Provenance.SanitizedPayloadSha256);
  }

  [Fact]
  public void Recognized_payload_with_unknown_field_fails_closed_without_echoing_it()
  {
    using var source = SyntheticCapture.Create(addUnknownRosterField: true);

    var result = new CredentialBearingProfileSanitizer().InspectCoverage(source);

    Assert.False(result.Succeeded);
    Assert.Null(result.Coverage);
    var diagnostic = Assert.Single(result.Diagnostics);
    Assert.Equal("roster_payload_shape_invalid", diagnostic.Code);
    Assert.DoesNotContain("credential_sentinel_field", JsonSerializer.Serialize(result));
  }

  [Fact]
  public void Duplicate_raw_property_fails_closed_before_any_identity_resolution()
  {
    using var valid = SyntheticCapture.Create();
    var text = Encoding.UTF8.GetString(valid.ToArray());
    const string property = "\"uid\":\"raw-account-sentinel\",";
    Assert.Contains(property, text, StringComparison.Ordinal);
    using var source = new MemoryStream(
        Encoding.UTF8.GetBytes(text.Replace(property, property + property, StringComparison.Ordinal)),
        writable: false);

    var result = new CredentialBearingProfileSanitizer().InspectCoverage(source);

    Assert.False(result.Succeeded);
    Assert.Equal("source_root_shape_invalid", Assert.Single(result.Diagnostics).Code);
  }

  [Fact]
  public void Missing_state_effect_dictionary_entry_fails_closed()
  {
    using var source = SyntheticCapture.Create(omitSecondStateEffect: true);

    var result = new CredentialBearingProfileSanitizer().InspectCoverage(source);

    Assert.False(result.Succeeded);
    Assert.Equal(
        "overload_same_packet_state_effect_missing",
        Assert.Single(result.Diagnostics).Code);
  }

  [Fact]
  public void State_effect_from_another_detail_packet_cannot_satisfy_an_overload_reference()
  {
    using var source = SyntheticCapture.Create(moveSecondStateEffectToAnotherDetailPacket: true);

    var result = new CredentialBearingProfileSanitizer().InspectCoverage(source);

    Assert.False(result.Succeeded);
    Assert.Equal(
        "overload_same_packet_state_effect_missing",
        Assert.Single(result.Diagnostics).Code);
  }

  [Fact]
  public void Missing_catalog_alias_fails_without_exposing_the_fingerprint()
  {
    using var source = SyntheticCapture.Create();
    var resolver = SyntheticResolver.Create();
    resolver.RemoveEquipmentAlias();

    var result = new CredentialBearingProfileSanitizer().Sanitize(
        source,
        IdentitySecret,
        resolver,
        new OfflineProfileImportOptions(
            new DateTimeOffset(2026, 8, 20, 0, 0, 0, TimeSpan.Zero),
            TransformerBinarySha256,
            CharacterLevelAuthorityPolicy.DetailObservationV1));

    Assert.False(result.Succeeded);
    Assert.Null(result.Draft);
    Assert.Equal("equipment_alias_missing", Assert.Single(result.Diagnostics).Code);
    Assert.Equal(
        "equipment_alias_missing",
        JsonSerializer.Serialize(result.Diagnostics).Contains("equipment_alias_missing", StringComparison.Ordinal)
            ? Assert.Single(result.Diagnostics).Code
            : string.Empty);
  }

  [Fact]
  public void Tier_10_equipment_manufacturer_is_not_applicable()
  {
    using var source = SyntheticCapture.Create(equipmentManufacturerCode: 0);

    var result = new CredentialBearingProfileSanitizer().Sanitize(
        source,
        IdentitySecret,
        SyntheticResolver.Create(),
        new OfflineProfileImportOptions(
            new DateTimeOffset(2026, 8, 20, 0, 0, 0, TimeSpan.Zero),
            TransformerBinarySha256,
            CharacterLevelAuthorityPolicy.DetailObservationV1));

    Assert.True(result.Succeeded);
    var equipped = Assert.IsType<SanitizedProfileDraft>(result.Draft).Builds
        .SelectMany(static build => build.Equipment)
        .Single(static item => item.State == ProfileImportAttachmentState.Equipped);
    Assert.Equal(
        ProfileImportFactStatus.NotApplicable,
        equipped.ManufacturerMatchedObservation?.Status);
    Assert.Equal(
        ProfileImportFactStatus.NotApplicable,
        equipped.ResolvedManufacturerMatched?.Status);
    var draft = Assert.IsType<SanitizedProfileDraft>(result.Draft);
    Assert.True(draft.CanMaterializeLocalAccountProfile);
    Assert.True(draft.IsLocalAccountProfileWriteReady);
    Assert.DoesNotContain(
        result.Diagnostics,
        static item => item.Code == "equipment_manufacturer_observation_unresolved");
  }

  [Fact]
  public void Missing_tier_9_equipment_manufacturer_code_uses_exact_catalog_definition()
  {
    using var source = SyntheticCapture.Create(
        equipmentManufacturerCode: 0,
        equipmentTier: 9);

    var result = new CredentialBearingProfileSanitizer().Sanitize(
        source,
        IdentitySecret,
        SyntheticResolver.Create(equipmentTier: 9),
        Options(CharacterLevelAuthorityPolicy.DetailObservationV1));

    Assert.True(result.Succeeded);
    var draft = Assert.IsType<SanitizedProfileDraft>(result.Draft);
    var equipped = draft.Builds.SelectMany(static build => build.Equipment)
        .Single(static item => item.State == ProfileImportAttachmentState.Equipped);
    Assert.Equal(ProfileImportFactStatus.Ready, equipped.ResolvedManufacturerMatched?.Status);
    Assert.True(equipped.ResolvedManufacturerMatched?.Value);
    Assert.True(draft.IsLocalAccountProfileWriteReady);
    Assert.DoesNotContain(
        result.Diagnostics,
        static item => item.Code == "equipment_manufacturer_observation_unresolved");
  }

  [Fact]
  public void Manufacturerless_tier_9_equipment_is_not_applicable()
  {
    using var source = SyntheticCapture.Create(
        equipmentManufacturerCode: 0,
        equipmentTier: 9);
    var resolver = SyntheticResolver.Create(equipmentTier: 9);
    resolver.MakeEquipmentCatalogManufacturerNotApplicable();

    var result = new CredentialBearingProfileSanitizer().Sanitize(
        source,
        IdentitySecret,
        resolver,
        Options(CharacterLevelAuthorityPolicy.DetailObservationV1));

    Assert.True(result.Succeeded);
    var draft = Assert.IsType<SanitizedProfileDraft>(result.Draft);
    var equipped = draft.Builds.SelectMany(static build => build.Equipment)
        .Single(static item => item.State == ProfileImportAttachmentState.Equipped);
    Assert.Equal(
        ProfileImportFactStatus.NotApplicable,
        equipped.ResolvedManufacturerMatched?.Status);
    Assert.True(draft.IsLocalAccountProfileWriteReady);
  }

  [Fact]
  public void Observed_equipment_manufacturer_must_match_the_exact_catalog_definition()
  {
    using var source = SyntheticCapture.Create(equipmentManufacturerCode: 1, equipmentTier: 9);
    var resolver = SyntheticResolver.Create(equipmentTier: 9);
    resolver.ChangeEquipmentCatalogManufacturer(ProfileImportManufacturer.Missilis);

    var result = new CredentialBearingProfileSanitizer().Sanitize(
        source,
        IdentitySecret,
        resolver,
        Options(CharacterLevelAuthorityPolicy.DetailObservationV1));

    Assert.False(result.Succeeded);
    Assert.Equal(
        "equipment_manufacturer_catalog_mismatch",
        Assert.Single(result.Diagnostics).Code);
  }

  [Fact]
  public void Non_R_zero_bond_observation_prevents_profile_write_readiness()
  {
    using var source = SyntheticCapture.Create(firstBondLevel: 0);

    var result = new CredentialBearingProfileSanitizer().Sanitize(
        source,
        IdentitySecret,
        SyntheticResolver.Create(),
        new OfflineProfileImportOptions(
            new DateTimeOffset(2026, 8, 20, 0, 0, 0, TimeSpan.Zero),
            TransformerBinarySha256,
            CharacterLevelAuthorityPolicy.DetailObservationV1));

    Assert.True(result.Succeeded);
    var draft = Assert.IsType<SanitizedProfileDraft>(result.Draft);
    Assert.True(draft.CanMaterializeLocalAccountProfile);
    Assert.False(draft.IsLocalAccountProfileWriteReady);
    Assert.Contains(
        draft.Builds,
        static build => build.ResolvedBondLevel.Status == ProfileImportFactStatus.Unresolved);
    Assert.Contains(
        result.Diagnostics,
        static item => item.Code == "bond_level_zero_semantics_unresolved");
  }

  [Fact]
  public void R_character_zero_bond_is_not_applicable()
  {
    using var source = SyntheticCapture.Create(firstBondLevel: 0);
    var resolver = SyntheticResolver.Create();
    resolver.ChangeFirstCharacterRarity(ProfileImportRarity.R);

    var result = new CredentialBearingProfileSanitizer().Sanitize(
        source,
        IdentitySecret,
        resolver,
        Options(CharacterLevelAuthorityPolicy.DetailObservationV1));

    Assert.True(result.Succeeded);
    var draft = Assert.IsType<SanitizedProfileDraft>(result.Draft);
    var build = draft.Builds.Single(static item => item.BondLevelObservation == 0);
    Assert.Equal(ProfileImportFactStatus.NotApplicable, build.ResolvedBondLevel.Status);
    Assert.True(draft.IsLocalAccountProfileWriteReady);
    Assert.DoesNotContain(
        result.Diagnostics,
        static item => item.Code == "bond_level_zero_semantics_unresolved");
  }

  [Fact]
  public void Resolved_collection_cannot_hide_ambiguity_in_the_other_alias_namespace()
  {
    using var source = SyntheticCapture.Create();
    var resolver = SyntheticResolver.Create();
    resolver.MakeFavoriteAliasAmbiguous();

    var result = new CredentialBearingProfileSanitizer().Sanitize(
        source,
        IdentitySecret,
        resolver,
        new OfflineProfileImportOptions(
            new DateTimeOffset(2026, 8, 20, 0, 0, 0, TimeSpan.Zero),
            TransformerBinarySha256));

    Assert.False(result.Succeeded);
    Assert.Equal("collection_alias_ambiguous", Assert.Single(result.Diagnostics).Code);
  }

  [Fact]
  public void Generic_collection_must_match_the_character_weapon()
  {
    using var source = SyntheticCapture.Create();
    var resolver = SyntheticResolver.Create();
    resolver.ChangeGenericCollectionWeapon(ProfileImportWeaponClass.Shotgun);

    var result = new CredentialBearingProfileSanitizer().Sanitize(
        source,
        IdentitySecret,
        resolver,
        new OfflineProfileImportOptions(
            new DateTimeOffset(2026, 8, 20, 0, 0, 0, TimeSpan.Zero),
            TransformerBinarySha256));

    Assert.False(result.Succeeded);
    Assert.Equal("collection_catalog_mismatch", Assert.Single(result.Diagnostics).Code);
  }

  [Fact]
  public void Character_observation_outside_the_exact_catalog_maximum_fails_closed()
  {
    using var source = SyntheticCapture.Create();
    var resolver = SyntheticResolver.Create();
    resolver.LowerFirstCharacterSkillMaximum();

    var result = new CredentialBearingProfileSanitizer().Sanitize(
        source,
        IdentitySecret,
        resolver,
        new OfflineProfileImportOptions(
            new DateTimeOffset(2026, 8, 20, 0, 0, 0, TimeSpan.Zero),
            TransformerBinarySha256));

    Assert.False(result.Succeeded);
    Assert.Equal("character_catalog_range_mismatch", Assert.Single(result.Diagnostics).Code);
  }

  [Fact]
  public void Console_selected_level_minimum_synchro_mismatch_fails_closed()
  {
    using var source = SyntheticCapture.Create();
    var resolver = SyntheticResolver.Create();
    resolver.RaiseFirstConsoleMinimumSynchroAboveAccount();

    var result = new CredentialBearingProfileSanitizer().Sanitize(
        source,
        IdentitySecret,
        resolver,
        Options(CharacterLevelAuthorityPolicy.DetailObservationV1));

    Assert.False(result.Succeeded);
    Assert.Equal("console_minimum_synchro_mismatch", Assert.Single(result.Diagnostics).Code);
  }

  [Fact]
  public void Unresolved_console_minimum_synchro_has_a_distinct_controlled_failure()
  {
    using var source = SyntheticCapture.Create();
    var resolver = SyntheticResolver.Create();
    resolver.MakeFirstConsoleMinimumSynchroUnresolved();

    var result = new CredentialBearingProfileSanitizer().Sanitize(
        source,
        IdentitySecret,
        resolver,
        Options(CharacterLevelAuthorityPolicy.DetailObservationV1));

    Assert.False(result.Succeeded);
    Assert.Equal("console_minimum_synchro_unresolved", Assert.Single(result.Diagnostics).Code);
  }

  [Fact]
  public void Console_level_zero_is_an_explicit_no_gate_coordinate()
  {
    using var source = SyntheticCapture.Create(firstConsoleLevel: 0);
    var resolver = SyntheticResolver.Create();
    resolver.SetFirstConsoleToExplicitZeroLevel();

    var result = new CredentialBearingProfileSanitizer().Sanitize(
        source,
        IdentitySecret,
        resolver,
        Options(CharacterLevelAuthorityPolicy.DetailObservationV1));

    Assert.True(result.Succeeded);
    var zero = Assert.IsType<SanitizedProfileDraft>(result.Draft).AccountState.Consoles
        .Single(static item => item.Coordinate == ProfileImportConsoleCoordinate.Common);
    Assert.Equal(0, zero.Level);
  }

  [Fact]
  public void Overload_legal_value_must_preserve_raw_evidence_and_positive_application_magnitude()
  {
    using var source = SyntheticCapture.Create();
    var resolver = SyntheticResolver.Create();
    resolver.CorruptFirstOverloadApplicationValue();

    var result = new CredentialBearingProfileSanitizer().Sanitize(
        source,
        IdentitySecret,
        resolver,
        Options(CharacterLevelAuthorityPolicy.DetailObservationV1));

    Assert.False(result.Succeeded);
    Assert.Equal("overload_exact_value_mismatch", Assert.Single(result.Diagnostics).Code);
  }

  [Fact]
  public void Overload_legal_value_rejects_signed_raw_value_as_application_value()
  {
    using var source = SyntheticCapture.Create();
    var resolver = SyntheticResolver.Create();
    resolver.NegateFirstOverloadApplicationValue();

    var result = new CredentialBearingProfileSanitizer().Sanitize(
        source,
        IdentitySecret,
        resolver,
        Options(CharacterLevelAuthorityPolicy.DetailObservationV1));

    Assert.False(result.Succeeded);
    Assert.Equal("overload_exact_value_mismatch", Assert.Single(result.Diagnostics).Code);
  }

  [Fact]
  public void Resolver_exception_is_replaced_with_a_controlled_diagnostic()
  {
    using var source = SyntheticCapture.Create();
    var resolver = SyntheticResolver.Create();
    resolver.ThrowOnCharacterResolution();

    var result = new CredentialBearingProfileSanitizer().Sanitize(
        source,
        IdentitySecret,
        resolver,
        new OfflineProfileImportOptions(
            new DateTimeOffset(2026, 8, 20, 0, 0, 0, TimeSpan.Zero),
            TransformerBinarySha256));

    Assert.False(result.Succeeded);
    Assert.Equal("profile_sanitization_failed", Assert.Single(result.Diagnostics).Code);
    Assert.DoesNotContain("secret-resolver-value", JsonSerializer.Serialize(result));
  }

  [Fact]
  public void Runtime_read_limit_rejects_a_stream_that_misreports_its_length()
  {
    using var source = new MisreportedLengthWhitespaceStream();

    var result = new CredentialBearingProfileSanitizer().InspectCoverage(source);

    Assert.False(result.Succeeded);
    Assert.Equal("source_size_limit_exceeded", Assert.Single(result.Diagnostics).Code);
  }

  [Fact]
  public void Declared_source_size_limit_fails_before_reading_the_stream()
  {
    using var source = new DeclaredOversizedStream();

    var result = new CredentialBearingProfileSanitizer().InspectCoverage(source);

    Assert.False(result.Succeeded);
    Assert.Equal("source_size_limit_exceeded", Assert.Single(result.Diagnostics).Code);
    Assert.False(source.WasRead);
  }

  [Fact]
  public void Canonical_draft_codec_round_trips_exact_bytes_and_source_free_public_state()
  {
    var draft = CreateSanitizedDraft(CharacterLevelAuthorityPolicy.DetailObservationV1);

    var canonical = SanitizedProfileDraftJsonCodec.Encode(draft);
    var decoded = SanitizedProfileDraftJsonCodec.Decode(canonical);
    var reencoded = SanitizedProfileDraftJsonCodec.Encode(decoded);

    Assert.Equal(canonical, reencoded);
    Assert.Equal(draft.Provenance.SanitizedPayloadSha256, decoded.Provenance.SanitizedPayloadSha256);
    var publicText = Encoding.UTF8.GetString(canonical);
    Assert.DoesNotContain("raw-account-sentinel", publicText, StringComparison.Ordinal);
    Assert.DoesNotContain("secret-token-value", publicText, StringComparison.Ordinal);
    Assert.DoesNotContain("official.invalid", publicText, StringComparison.Ordinal);
    foreach (var sourceReference in SyntheticCapture.AllSourceReferences)
    {
      Assert.DoesNotContain(sourceReference.ToString(), publicText, StringComparison.Ordinal);
    }
  }

  [Fact]
  public void Typed_rebase_requires_complete_explicit_maps_and_recomputes_provenance()
  {
    var draft = CreateSanitizedDraft(CharacterLevelAuthorityPolicy.DetailObservationV1);
    var targetCharacterCatalog = TestBinding();
    var targetCombatSupportCatalog = TestBinding();
    var mappings = ReferencedDefinitionUids(draft).ToDictionary(
        static uid => uid,
        static _ => EntityUid.New());

    var rebased = SanitizedProfileDraftJsonCodec.Rebase(
        draft,
        new DateTimeOffset(2026, 8, 20, 0, 1, 0, TimeSpan.Zero),
        draft.Provenance.TransformerBinarySha256,
        targetCharacterCatalog,
        targetCombatSupportCatalog,
        mappings);

    Assert.True(rebased.CanMaterializeLocalAccountProfile);
    Assert.True(rebased.IsLocalAccountProfileWriteReady);
    Assert.Equal(SanitizedProfileDraftContract.RebaseTransformerId, rebased.Provenance.TransformerId);
    Assert.Equal(targetCharacterCatalog, rebased.CharacterCatalog);
    Assert.Equal(targetCombatSupportCatalog, rebased.CombatSupportCatalog);
    Assert.NotEqual(draft.Provenance.SemanticOptionsSha256, rebased.Provenance.SemanticOptionsSha256);
    Assert.NotEqual(draft.Provenance.SanitizedPayloadSha256, rebased.Provenance.SanitizedPayloadSha256);
    Assert.Equal(
        SanitizedProfileDraftJsonCodec.Encode(rebased),
        SanitizedProfileDraftJsonCodec.Encode(
            SanitizedProfileDraftJsonCodec.Decode(
                SanitizedProfileDraftJsonCodec.Encode(rebased))));

    var incomplete = mappings.Skip(1).ToDictionary(static item => item.Key, static item => item.Value);
    var failure = Assert.Throws<SanitizedProfileDraftCodecException>(() =>
        SanitizedProfileDraftJsonCodec.Rebase(
            draft,
            new DateTimeOffset(2026, 8, 20, 0, 1, 0, TimeSpan.Zero),
            draft.Provenance.TransformerBinarySha256,
            targetCharacterCatalog,
            targetCombatSupportCatalog,
            incomplete));
    Assert.Equal("sanitized_draft_rebase_mapping_set_invalid", failure.Code);

    var unchangedFailure = Assert.Throws<SanitizedProfileDraftCodecException>(() =>
        SanitizedProfileDraftJsonCodec.Rebase(
            draft,
            new DateTimeOffset(2026, 8, 20, 0, 1, 0, TimeSpan.Zero),
            draft.Provenance.TransformerBinarySha256,
            draft.CharacterCatalog,
            draft.CombatSupportCatalog,
            new Dictionary<EntityUid, EntityUid>()));
    Assert.Equal("sanitized_draft_rebase_target_unchanged", unchangedFailure.Code);
  }

  [Fact]
  public void Reviewed_overrides_preserve_raw_observations_and_create_a_distinct_derived_draft()
  {
    var draft = CreateSanitizedDraft(
        CharacterLevelAuthorityPolicy.DetailObservationV1,
        firstBondLevel: 0,
        equipmentManufacturerCode: 0,
        equipmentTier: 9,
        unresolvedCatalogManufacturer: true);
    Assert.True(draft.CanMaterializeLocalAccountProfile);
    Assert.False(draft.IsLocalAccountProfileWriteReady);
    var bondBuild = draft.Builds.Single(static build => build.BondLevelObservation == 0);
    var manufacturerBuild = draft.Builds.Single(static build => build.Equipment.Any(
        static equipment => equipment.ManufacturerMatchedObservation?.Status ==
            ProfileImportFactStatus.Unresolved));

    var derived = SanitizedProfileDraftJsonCodec.ApplyReviewedOverrides(
        draft,
        new DateTimeOffset(2026, 8, 20, 0, 2, 0, TimeSpan.Zero),
        TransformerBinarySha256,
        new[]
        {
          new SanitizedProfileReviewedOverrideRequest(
              SanitizedProfileReviewedOverrideKind.BondLevel,
              bondBuild.CharacterUid,
              null,
              1,
              null,
              "user_reviewed_override"),
          new SanitizedProfileReviewedOverrideRequest(
              SanitizedProfileReviewedOverrideKind.EquipmentManufacturerMatched,
              manufacturerBuild.CharacterUid,
              ProfileImportEquipmentSlot.Head,
              null,
              true,
              "user_reviewed_override")
        });

    Assert.True(derived.CanMaterializeLocalAccountProfile);
    Assert.True(derived.IsLocalAccountProfileWriteReady);
    Assert.Equal(
        SanitizedProfileDraftContract.ReviewedOverrideTransformerId,
        derived.Provenance.TransformerId);
    Assert.Equal(2, derived.ReviewedOverrides.Count);
    var derivedBond = derived.Builds.Single(build => build.CharacterUid == bondBuild.CharacterUid);
    Assert.Equal(0, derivedBond.BondLevelObservation);
    Assert.Equal(1, derivedBond.ResolvedBondLevel.Value);
    var derivedEquipment = derived.Builds.Single(
            build => build.CharacterUid == manufacturerBuild.CharacterUid)
        .Equipment.Single(static equipment => equipment.Slot == ProfileImportEquipmentSlot.Head);
    Assert.Equal(
        ProfileImportFactStatus.Unresolved,
        derivedEquipment.ManufacturerMatchedObservation?.Status);
    Assert.True(derivedEquipment.ResolvedManufacturerMatched?.Value);
    Assert.NotEqual(draft.Provenance.SemanticOptionsSha256, derived.Provenance.SemanticOptionsSha256);
    Assert.NotEqual(draft.Provenance.SanitizedPayloadSha256, derived.Provenance.SanitizedPayloadSha256);
    var canonical = SanitizedProfileDraftJsonCodec.Encode(derived);
    Assert.Equal(canonical, SanitizedProfileDraftJsonCodec.Encode(
        SanitizedProfileDraftJsonCodec.Decode(canonical)));

    var unsafeReason = Assert.Throws<SanitizedProfileDraftCodecException>(() =>
        SanitizedProfileDraftJsonCodec.ApplyReviewedOverrides(
            draft,
            new DateTimeOffset(2026, 8, 20, 0, 2, 0, TimeSpan.Zero),
            TransformerBinarySha256,
            new[]
            {
              new SanitizedProfileReviewedOverrideRequest(
                  SanitizedProfileReviewedOverrideKind.BondLevel,
                  bondBuild.CharacterUid,
                  null,
                  1,
                  null,
                  "source_771001001")
            }));
    Assert.Equal("sanitized_draft_override_request_invalid", unsafeReason.Code);
    Assert.DoesNotContain("771001001", unsafeReason.Message, StringComparison.Ordinal);
  }

  [Fact]
  public void Canonical_draft_codec_rejects_unknown_and_duplicate_properties_without_echo()
  {
    var canonical = SanitizedProfileDraftJsonCodec.Encode(
        CreateSanitizedDraft(CharacterLevelAuthorityPolicy.DetailObservationV1));
    var text = Encoding.UTF8.GetString(canonical);
    var unknown = Encoding.UTF8.GetBytes(
        text[..^1] + ",\"credential_sentinel_field\":\"must-never-echo\"}");
    var schemaProperty =
        $"\"schema_code\":\"{SanitizedProfileDraftContract.SchemaCode}\",";
    Assert.StartsWith("{" + schemaProperty, text, StringComparison.Ordinal);
    var duplicate = Encoding.UTF8.GetBytes("{" + schemaProperty + text[1..]);

    var unknownFailure = Assert.Throws<SanitizedProfileDraftCodecException>(
        () => SanitizedProfileDraftJsonCodec.Decode(unknown));
    var duplicateFailure = Assert.Throws<SanitizedProfileDraftCodecException>(
        () => SanitizedProfileDraftJsonCodec.Decode(duplicate));

    Assert.Equal("sanitized_draft_root_shape_invalid", unknownFailure.Code);
    Assert.Equal("sanitized_draft_root_shape_invalid", duplicateFailure.Code);
    Assert.DoesNotContain("must-never-echo", unknownFailure.Message, StringComparison.Ordinal);
  }

  [Fact]
  public void Canonical_draft_codec_rejects_noncanonical_and_default_serializer_shapes()
  {
    var draft = CreateSanitizedDraft(CharacterLevelAuthorityPolicy.DetailObservationV1);
    var canonical = SanitizedProfileDraftJsonCodec.Encode(draft);
    var whitespace = new byte[canonical.Length + 1];
    whitespace[0] = (byte)' ';
    canonical.CopyTo(whitespace, 1);

    var whitespaceFailure = Assert.Throws<SanitizedProfileDraftCodecException>(
        () => SanitizedProfileDraftJsonCodec.Decode(whitespace));
    var defaultShapeFailure = Assert.Throws<SanitizedProfileDraftCodecException>(
        () => SanitizedProfileDraftJsonCodec.Decode(JsonSerializer.SerializeToUtf8Bytes(draft)));

    Assert.Equal("sanitized_draft_json_not_canonical", whitespaceFailure.Code);
    Assert.Equal("sanitized_draft_root_shape_invalid", defaultShapeFailure.Code);
  }

  [Fact]
  public void Canonical_draft_codec_rejects_unknown_transformer_provenance_profiles()
  {
    var draft = CreateSanitizedDraft(CharacterLevelAuthorityPolicy.DetailObservationV1);
    var canonical = Encoding.UTF8.GetString(SanitizedProfileDraftJsonCodec.Encode(draft));
    var tampered = Encoding.UTF8.GetBytes(canonical.Replace(
        $"\"transformer_id\":\"{SanitizedProfileDraftContract.TransformerId}\"",
        "\"transformer_id\":\"profile-editor-candidate\"",
        StringComparison.Ordinal));

    var failure = Assert.Throws<SanitizedProfileDraftCodecException>(
        () => SanitizedProfileDraftJsonCodec.Decode(tampered));

    Assert.Equal("sanitized_draft_transformer_profile_invalid", failure.Code);
  }

  [Fact]
  public void Canonical_draft_codec_rejects_hash_tampering_and_scalar_overflow()
  {
    var draft = CreateSanitizedDraft(CharacterLevelAuthorityPolicy.DetailObservationV1);
    var canonicalText = Encoding.UTF8.GetString(SanitizedProfileDraftJsonCodec.Encode(draft));
    var tamperedHash = Encoding.UTF8.GetBytes(canonicalText.Replace(
        draft.Provenance.SanitizedPayloadSha256.Hex,
        new string('0', Sha256Digest.HexLength),
        StringComparison.Ordinal));
    var oversizedSkill = Encoding.UTF8.GetBytes(canonicalText.Replace(
        "\"skill1_level\":10",
        "\"skill1_level\":1000001",
        StringComparison.Ordinal));

    var hashFailure = Assert.Throws<SanitizedProfileDraftCodecException>(
        () => SanitizedProfileDraftJsonCodec.Decode(tamperedHash));
    var rangeFailure = Assert.Throws<SanitizedProfileDraftCodecException>(
        () => SanitizedProfileDraftJsonCodec.Decode(oversizedSkill));

    Assert.Equal("sanitized_draft_hash_mismatch", hashFailure.Code);
    Assert.Equal("sanitized_draft_build_invalid", rangeFailure.Code);
  }

  [Fact]
  public void Sanitized_hash_and_canonical_bytes_are_culture_independent()
  {
    var baseline = CreateSanitizedDraft(CharacterLevelAuthorityPolicy.DetailObservationV1);
    var baselineBytes = SanitizedProfileDraftJsonCodec.Encode(baseline);
    var priorCulture = CultureInfo.CurrentCulture;
    var priorUiCulture = CultureInfo.CurrentUICulture;
    try
    {
      CultureInfo.CurrentCulture = CultureInfo.GetCultureInfo("tr-TR");
      CultureInfo.CurrentUICulture = CultureInfo.GetCultureInfo("tr-TR");
      var localized = CreateSanitizedDraft(CharacterLevelAuthorityPolicy.DetailObservationV1);

      Assert.Equal(
          baseline.Provenance.SanitizedPayloadSha256,
          localized.Provenance.SanitizedPayloadSha256);
      Assert.Equal(baselineBytes, SanitizedProfileDraftJsonCodec.Encode(localized));
    }
    finally
    {
      CultureInfo.CurrentCulture = priorCulture;
      CultureInfo.CurrentUICulture = priorUiCulture;
    }
  }

  [Fact]
  public void Optional_local_smoke_reports_only_aggregate_coverage()
  {
    var sourceLocation = Environment.GetEnvironmentVariable("NLL_PROFILE_SMOKE_SOURCE");
    if (string.IsNullOrWhiteSpace(sourceLocation))
    {
      return;
    }

    var expectedText = Environment.GetEnvironmentVariable("NLL_PROFILE_SMOKE_EXPECTED_CHARACTERS");
    var expected = string.IsNullOrWhiteSpace(expectedText) ? 192 : int.Parse(expectedText);
    using var source = new FileStream(
        sourceLocation,
        FileMode.Open,
        FileAccess.Read,
        FileShare.Read);

    var result = new CredentialBearingProfileSanitizer().InspectCoverage(source);

    Assert.True(
        result.Succeeded,
        string.Join(',', result.Diagnostics.Select(static item => $"{item.Code}:{item.Count}")));
    var coverage = Assert.IsType<CredentialBearingProfileCoverage>(result.Coverage);
    Assert.Equal(expected, coverage.RosterObservationCount);
    Assert.Equal(expected, coverage.DetailObservationCount);
    Assert.Equal(checked(expected * 4), coverage.EquipmentCoordinateCount);
    Assert.Equal(coverage.OverloadReferenceCount, coverage.StateEffectResolvedReferenceCount);
    Assert.Equal(9, coverage.ConsoleObservationCount);
  }

  [Fact]
  public void Fetched_snapshot_materializes_only_source_free_profile_and_progression_values()
  {
    using var coverageSource = SyntheticCapture.Create();
    var coverageResult = new CredentialBearingProfileSanitizer().InspectCoverage(coverageSource);
    using var profileSource = SyntheticCapture.Create();
    var sanitized = new CredentialBearingProfileSanitizer().Sanitize(
        profileSource,
        IdentitySecret,
        SyntheticResolver.Create(),
        Options(CharacterLevelAuthorityPolicy.RosterObservationV1));
    var draft = Assert.IsType<SanitizedProfileDraft>(sanitized.Draft);
    var coverage = Assert.IsType<CredentialBearingProfileCoverage>(coverageResult.Coverage);

    var snapshot = FetchedAccountSnapshotMaterializer.Materialize(
        new FetchedAccountSnapshotMaterializationCommand(
            EntityUid.New(),
            new DateTimeOffset(2026, 8, 29, 0, 0, 0, TimeSpan.Zero),
            draft,
            coverage,
            new FetchedBasicAccountObservation("SyntheticLab", 893, "34-38", "20-31", "34-38"),
            new FetchedProgressionObservation(
                Sha256Digest.ComputeUtf8("synthetic-main-quest-data"),
                611,
                611,
                17),
            sanitized.Diagnostics));

    Assert.Equal("complete", snapshot.Completeness.StatusCode);
    Assert.Empty(snapshot.Completeness.ReasonCodes);
    Assert.Equal(2, snapshot.Completeness.RosterCount);
    Assert.Equal(2, snapshot.Completeness.CharacterDetailCount);
    Assert.Equal(2, snapshot.Completeness.EquipmentCharacterCount);
    Assert.Equal(9, snapshot.Account.Consoles.Count);
    Assert.Equal(2, snapshot.Characters.Count);
    Assert.All(snapshot.Characters, static character => Assert.Equal(4, character.Equipment.Count));
    Assert.False(snapshot.Source.CredentialOrSessionPersisted);
    Assert.False(snapshot.Source.RawSourcePersisted);

    var encoded = FetchedAccountSnapshotJsonCodec.Encode(snapshot);
    var decoded = FetchedAccountSnapshotJsonCodec.Decode(encoded);
    Assert.Equal(encoded, FetchedAccountSnapshotJsonCodec.Encode(decoded));
    var json = Encoding.UTF8.GetString(encoded);
    Assert.DoesNotContain("raw-account-sentinel", json, StringComparison.Ordinal);
    Assert.DoesNotContain("secret-token-value", json, StringComparison.Ordinal);
    Assert.DoesNotContain("official.invalid", json, StringComparison.Ordinal);
    foreach (var sourceReference in SyntheticCapture.AllSourceReferences)
    {
      Assert.DoesNotContain(sourceReference.ToString(), json, StringComparison.Ordinal);
    }
  }

  [Fact]
  public void Fetched_snapshot_marks_roster_detail_drift_incomplete_without_guessing()
  {
    var draft = CreateSanitizedDraft(CharacterLevelAuthorityPolicy.RosterObservationV1);
    var snapshot = FetchedAccountSnapshotMaterializer.Materialize(
        new FetchedAccountSnapshotMaterializationCommand(
            EntityUid.New(),
            new DateTimeOffset(2026, 8, 29, 0, 0, 0, TimeSpan.Zero),
            draft,
            new CredentialBearingProfileCoverage(2, 1, 0, 8, 2, 2, 1, 9),
            new FetchedBasicAccountObservation("SyntheticLab", 893, "34-38", "20-31", "34-38"),
            new FetchedProgressionObservation(null, null, null, null),
            Array.Empty<ProfileImportDiagnostic>()));

    Assert.Equal("incomplete", snapshot.Completeness.StatusCode);
    Assert.Contains("roster_detail_count_mismatch", snapshot.Completeness.ReasonCodes);
    Assert.Contains("progression_summary_missing", snapshot.Completeness.ReasonCodes);
    Assert.Equal(1, snapshot.Completeness.MissingCharacterCount);
  }

  [Fact]
  public void Progression_v2_sanitizes_observed_and_derived_components_without_source_ids()
  {
    const string privateSourceJson = """
        {
          "schemaVersion": 1,
          "contractId": "nll/phase3b2-user-progression-private-source/v1",
          "sourceSequencePersisted": false,
          "officialUserIdentifierPersisted": false,
          "credentialOrSessionFieldPersisted": false,
          "selectedTriggers": [
            { "typeCode": 2, "conditionId": 920001, "userValue": 1, "createdAt": 100 },
            { "typeCode": 22, "conditionId": 920002, "userValue": 1, "createdAt": 101 }
          ],
          "mainQuestData": [
            { "questId": 910001, "rewardClaimed": true },
            { "questId": 910002, "rewardClaimed": true }
          ]
        }
        """;
    const string candidateJson = """
        {
          "Users": [
            {
              "CompletedScenarios": [930001, 930002, 930003],
              "MainQuestData": { "910001": true, "910002": true },
              "ContentsOpenUnlocked": {
                "940001": { "ButtonAnimationPlayed": true, "PopupAnimationPlayed": true }
              },
              "StageClearHistorys": [],
              "Triggers": [
                { "Type": 2, "ConditionId": 920001 },
                { "Type": 22, "ConditionId": 920002 }
              ]
            }
          ]
        }
        """;
    using var privateSource = new MemoryStream(Encoding.UTF8.GetBytes(privateSourceJson));
    using var candidate = new MemoryStream(Encoding.UTF8.GetBytes(candidateJson));

    var observation = LegacyProgressionObservationMaterializerV2.Materialize(
        new LegacyProgressionMaterializationCommandV2(
            EntityUid.New(),
            new DateTimeOffset(2026, 8, 29, 0, 0, 0, TimeSpan.Zero),
            privateSource,
            candidate,
            IdentitySecret));

    Assert.Equal("incomplete", observation.Completeness.StatusCode);
    Assert.Equal(2, observation.Completeness.AvailableComponentCount);
    Assert.Equal(2, observation.Completeness.DerivedComponentCount);
    Assert.Equal(1, observation.Completeness.UnavailableComponentCount);
    Assert.Equal("observed", observation.MainQuestData.Summary.StateCode);
    Assert.Equal(2, observation.MainQuestData.CompletedCount);
    Assert.Equal(2, observation.MainQuestData.RewardClaimedCount);
    Assert.Equal(3, observation.CompletedScenarios.Summary.ItemCount);
    Assert.Equal(1, observation.ContentsOpenUnlocked.Summary.ItemCount);
    Assert.Null(observation.StageClearHistorys.Summary.ItemCount);
    Assert.Equal(2, observation.Triggers.Summary.ItemCount);
    Assert.Contains("stage_clear_historys_unavailable", observation.Completeness.ReasonCodes);

    var canonical = FetchedProgressionObservationV2JsonCodec.Encode(observation);
    var decoded = FetchedProgressionObservationV2JsonCodec.Decode(canonical);
    Assert.Equal(canonical, FetchedProgressionObservationV2JsonCodec.Encode(decoded));
    var json = Encoding.UTF8.GetString(canonical);
    foreach (var sourceId in new[] { "910001", "910002", "920001", "920002", "930001", "940001" })
      Assert.DoesNotContain(sourceId, json, StringComparison.Ordinal);
    Assert.DoesNotContain("conditionId", json, StringComparison.OrdinalIgnoreCase);
    Assert.DoesNotContain("questId", json, StringComparison.OrdinalIgnoreCase);
  }

  [Fact]
  public void Progression_v2_does_not_promote_absent_legacy_components_to_empty_observed_sets()
  {
    const string privateSourceJson = """
        {
          "schemaVersion": 1,
          "contractId": "nll/phase3b2-user-progression-private-source/v1",
          "sourceSequencePersisted": false,
          "officialUserIdentifierPersisted": false,
          "credentialOrSessionFieldPersisted": false,
          "selectedTriggers": [],
          "mainQuestData": []
        }
        """;
    using var privateSource = new MemoryStream(Encoding.UTF8.GetBytes(privateSourceJson));

    var observation = LegacyProgressionObservationMaterializerV2.Materialize(
        new LegacyProgressionMaterializationCommandV2(
            EntityUid.New(),
            new DateTimeOffset(2026, 8, 29, 0, 0, 0, TimeSpan.Zero),
            privateSource,
            null,
            IdentitySecret));

    Assert.Equal("observed", observation.MainQuestData.Summary.StateCode);
    Assert.Equal(0, observation.MainQuestData.Summary.ItemCount);
    Assert.Equal("observed", observation.Triggers.Summary.StateCode);
    Assert.Equal(0, observation.Triggers.Summary.ItemCount);
    Assert.Equal("unavailable", observation.CompletedScenarios.Summary.StateCode);
    Assert.Null(observation.CompletedScenarios.Summary.ItemCount);
    Assert.Equal("unavailable", observation.ContentsOpenUnlocked.Summary.StateCode);
    Assert.Equal("unavailable", observation.StageClearHistorys.Summary.StateCode);
  }

  [Fact]
  public void Fetched_snapshot_projects_bound_progression_v2_without_hiding_missing_stage_history()
  {
    var snapshotUid = EntityUid.New();
    var draft = CreateSanitizedDraft(CharacterLevelAuthorityPolicy.RosterObservationV1);
    var snapshot = FetchedAccountSnapshotMaterializer.Materialize(
        new FetchedAccountSnapshotMaterializationCommand(
            snapshotUid,
            new DateTimeOffset(2026, 8, 29, 0, 0, 0, TimeSpan.Zero),
            draft,
            new CredentialBearingProfileCoverage(2, 2, 0, 8, 2, 2, 1, 9),
            new FetchedBasicAccountObservation("SyntheticLab", 893, "34-38", "20-31", "34-38"),
            new FetchedProgressionObservation(
                Sha256Digest.ComputeUtf8("main-quest"),
                2,
                3,
                1,
                snapshotUid,
                Sha256Digest.ComputeUtf8("progression-v2"),
                "incomplete",
                ["stage_clear_historys_unavailable"],
                null,
                2),
            Array.Empty<ProfileImportDiagnostic>()));

    Assert.DoesNotContain("progression_summary_missing", snapshot.Completeness.ReasonCodes);
    Assert.Contains("stage_clear_historys_unavailable", snapshot.Completeness.ReasonCodes);
    Assert.Equal("incomplete", snapshot.Completeness.StatusCode);
  }

  [Fact]
  public void Basic_info_sanitizer_whitelists_values_and_drops_identity_transport_fields()
  {
    const string sourceText = """
        {
          "uid": "raw-account-sentinel",
          "phase_1_initial_load": [
            {
              "endpoint": "GetUserProfileBasicInfo",
              "url": "https://official.invalid/private?token=secret-token-value",
              "data": {
                "trace_id": "secret-trace",
                "basic_info": {
                  "nickname": "SyntheticLab",
                  "lv": 893,
                  "progress_normal_campaign": 3438,
                  "progress_hard_campaign": "20-31",
                  "progress_easy_campaign": 3438,
                  "ignored_identity": "must-not-survive"
                }
              }
            }
          ],
          "phase_2_after_click": []
        }
        """;
    using var source = new MemoryStream(Encoding.UTF8.GetBytes(sourceText));

    var result = CredentialBearingBasicInfoSanitizer.Sanitize(source);

    Assert.True(result.Succeeded);
    var observation = Assert.IsType<FetchedBasicAccountObservation>(result.Observation);
    Assert.Equal("SyntheticLab", observation.DisplayName);
    Assert.Equal(893, observation.CommanderLevel);
    Assert.Equal("3438", observation.NormalStageLabel);
    Assert.Equal("20-31", observation.HardStageLabel);
    var json = JsonSerializer.Serialize(observation);
    Assert.DoesNotContain("raw-account-sentinel", json, StringComparison.Ordinal);
    Assert.DoesNotContain("secret-token-value", json, StringComparison.Ordinal);
    Assert.DoesNotContain("must-not-survive", json, StringComparison.Ordinal);
  }

  private static OfflineProfileImportOptions Options(
      CharacterLevelAuthorityPolicy? authority = null) => new(
          new DateTimeOffset(2026, 8, 20, 0, 0, 0, TimeSpan.Zero),
          TransformerBinarySha256,
          authority);

  private static SanitizedProfileDraft CreateSanitizedDraft(
      CharacterLevelAuthorityPolicy authority,
      int firstBondLevel = 30,
      int equipmentManufacturerCode = 0,
      int equipmentTier = 10,
      bool unresolvedCatalogManufacturer = false)
  {
    using var source = SyntheticCapture.Create(
        equipmentManufacturerCode: equipmentManufacturerCode,
        equipmentTier: equipmentTier,
        firstBondLevel: firstBondLevel);
    var resolver = SyntheticResolver.Create(equipmentTier);
    if (unresolvedCatalogManufacturer)
    {
      resolver.MakeEquipmentCatalogManufacturerUnresolved();
    }
    var result = new CredentialBearingProfileSanitizer().Sanitize(
        source,
        IdentitySecret,
        resolver,
        Options(authority));
    Assert.True(
        result.Succeeded,
        string.Join(',', result.Diagnostics.Select(static item => $"{item.Code}:{item.Count}")));
    return Assert.IsType<SanitizedProfileDraft>(result.Draft);
  }

  private static ProfileImportCatalogBinding TestBinding()
  {
    var catalogUid = EntityUid.New();
    return new ProfileImportCatalogBinding(
        catalogUid,
        EntityUid.New(),
        Sha256Digest.ComputeUtf8("test-binding-" + catalogUid));
  }

  private static IReadOnlyList<EntityUid> ReferencedDefinitionUids(
      SanitizedProfileDraft draft) => draft.Builds.Select(static build => build.CharacterUid)
      .Concat(draft.AccountState.Consoles.Select(static console => console.DefinitionUid))
      .Concat(draft.Builds.SelectMany(static build => build.Equipment)
          .Where(static equipment => equipment.DefinitionUid.HasValue)
          .Select(static equipment => equipment.DefinitionUid!.Value))
      .Concat(draft.Builds.SelectMany(static build => build.Equipment)
          .SelectMany(static equipment => equipment.OverloadLines)
          .Select(static line => line.OptionDefinitionUid))
      .Concat(draft.Builds.Where(static build => build.Cube.DefinitionUid.HasValue)
          .Select(static build => build.Cube.DefinitionUid!.Value))
      .Concat(draft.Builds.Where(static build => build.Collection.DefinitionUid.HasValue)
          .Select(static build => build.Collection.DefinitionUid!.Value))
      .Distinct()
      .ToArray();

  private static class SyntheticCapture
  {
    public const long CharacterA = 771_001_001;
    public const long CharacterB = 771_001_002;
    public const long EquipmentHead = 772_001_001;
    public const long Cube = 773_001_001;
    public const long Collection = 774_001_001;
    public const long OverloadLine1 = 775_001_001;
    public const long OverloadLine3 = 775_001_003;
    public const long ConsoleBase = 776_001_000;

    public static IReadOnlyList<long> AllSourceReferences { get; } =
        new[] { CharacterA, CharacterB, EquipmentHead, Cube, Collection, OverloadLine1, OverloadLine3 }
            .Concat(Enumerable.Range(1, 9).Select(static value => ConsoleBase + value))
            .ToArray();

    public static MemoryStream Create(
        bool addUnknownRosterField = false,
        bool omitSecondStateEffect = false,
        int equipmentManufacturerCode = 0,
        int equipmentTier = 10,
        int firstBondLevel = 30,
        bool moveSecondStateEffectToAnotherDetailPacket = false,
        int firstConsoleLevel = 1)
    {
      var rosterData = new Dictionary<string, object?>
      {
        ["characters"] = new[]
        {
          Roster(CharacterA, 100, 1_000),
          Roster(CharacterB, 101, 2_000)
        }
      };
      if (addUnknownRosterField)
      {
        rosterData["credential_sentinel_field"] = "must-never-echo";
      }

      var stateEffects = new List<object>
      {
        StateEffect(OverloadLine1, 111)
      };
      if (!omitSecondStateEffect)
      {
        stateEffects.Add(StateEffect(OverloadLine3, -333));
      }

      var firstDetail = Detail(
          CharacterA,
          200,
          1_000,
          withEquipment: true,
          equipmentManufacturerCode,
          equipmentTier,
          firstBondLevel);
      var secondDetail = Detail(
          CharacterB,
          101,
          2_000,
          withEquipment: false,
          equipmentManufacturerCode: 0,
          equipmentTier: 0,
          bondLevel: 30);
      object[] detailPackets = moveSecondStateEffectToAnotherDetailPacket
          ?
          [
              Packet("details-a", "https://official.invalid/private", new
              {
                character_details = new[] { firstDetail },
                state_effects = new[] { StateEffect(OverloadLine1, 111) }
              }),
            Packet("details-b", "https://official.invalid/private", new
            {
              character_details = new[] { secondDetail },
              state_effects = new[] { StateEffect(OverloadLine3, -333) }
            })
          ]
          :
          [
              Packet("details", "https://official.invalid/private", new
              {
                character_details = new[] { firstDetail, secondDetail },
                state_effects = stateEffects.ToArray()
              })
          ];

      var root = new Dictionary<string, object?>
      {
        ["uid"] = "raw-account-sentinel",
        ["phase_1_initial_load"] = new object[]
        {
          Packet("roster", "https://official.invalid/private", rosterData),
          Packet("outpost", "https://official.invalid/private", new
          {
            outpost_info = new
            {
              synchro_level = 200,
              synchro_nonempty_slot_count = 2,
              recycle_room_researches = Enumerable.Range(1, 9)
                  .Select(index => new
                  {
                    tid = ConsoleBase + index,
                    lv = index == 1 ? firstConsoleLevel : index,
                    exp = index * 10L
                  })
                  .ToArray()
            }
          }),
          Packet("login", "https://official.invalid/private", new
          {
            open_id = "raw-open-id-sentinel",
            token = "secret-token-value"
          })
        },
        ["phase_2_after_click"] = detailPackets
      };
      return new MemoryStream(JsonSerializer.SerializeToUtf8Bytes(root), writable: false);
    }

    private static object Packet(string endpoint, string url, object data) => new
    {
      endpoint,
      url,
      data
    };

    private static object Roster(long reference, int level, long combat) => new
    {
      name_code = reference,
      lv = level,
      grade = 3,
      core = 2,
      combat,
      costume_id = 991_000_001L
    };

    private static Dictionary<string, object> Detail(
        long reference,
        int level,
        long combat,
        bool withEquipment,
        int equipmentManufacturerCode,
        int equipmentTier,
        int bondLevel)
    {
      var value = new Dictionary<string, object>
      {
        ["name_code"] = reference,
        ["lv"] = level,
        ["grade"] = 3,
        ["core"] = 2,
        ["combat"] = combat,
        ["attractive_lv"] = bondLevel,
        ["skill1_lv"] = 10,
        ["skill2_lv"] = 10,
        ["ulti_skill_lv"] = 10,
        ["harmony_cube_tid"] = withEquipment ? Cube : 0L,
        ["harmony_cube_lv"] = withEquipment ? 15 : 0,
        ["favorite_item_tid"] = withEquipment ? Collection : 0L,
        ["favorite_item_lv"] = withEquipment ? 5 : 0
      };
      foreach (var prefix in new[] { "head", "torso", "arm", "leg" })
      {
        var equipped = withEquipment && prefix == "head";
        value[$"{prefix}_equip_tid"] = equipped ? EquipmentHead : 0L;
        value[$"{prefix}_equip_tier"] = equipped ? equipmentTier : 0;
        value[$"{prefix}_equip_lv"] = equipped ? 5 : 0;
        value[$"{prefix}_equip_corporation_type"] = equipped ? equipmentManufacturerCode : 0;
        value[$"{prefix}_equip_option1_id"] = equipped ? OverloadLine1 : 0L;
        value[$"{prefix}_equip_option2_id"] = 0L;
        value[$"{prefix}_equip_option3_id"] = equipped ? OverloadLine3 : 0L;
      }

      return value;
    }

    private static object StateEffect(long reference, long rawValue) => new
    {
      id = reference.ToString(),
      function_details = new[]
      {
        new
        {
          id = reference + 10,
          function_type = "synthetic",
          function_value = rawValue,
          function_value_type = "Percent"
        }
      }
    };
  }

  private sealed class MisreportedLengthWhitespaceStream : Stream
  {
    private long _position;

    public override bool CanRead => true;

    public override bool CanSeek => true;

    public override bool CanWrite => false;

    public override long Length => 1;

    public override long Position
    {
      get => _position;
      set => _position = value;
    }

    public override int Read(byte[] buffer, int offset, int count)
    {
      Array.Fill(buffer, (byte)' ', offset, count);
      _position = checked(_position + count);
      return count;
    }

    public override int Read(Span<byte> buffer)
    {
      buffer.Fill((byte)' ');
      _position = checked(_position + buffer.Length);
      return buffer.Length;
    }

    public override void Flush() => throw new NotSupportedException();

    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();

    public override void SetLength(long value) => throw new NotSupportedException();

    public override void Write(byte[] buffer, int offset, int count) =>
        throw new NotSupportedException();
  }

  private sealed class DeclaredOversizedStream : Stream
  {
    public bool WasRead { get; private set; }

    public override bool CanRead => true;

    public override bool CanSeek => true;

    public override bool CanWrite => false;

    public override long Length => (16L * 1024 * 1024) + 1;

    public override long Position { get; set; }

    public override int Read(byte[] buffer, int offset, int count)
    {
      WasRead = true;
      return 0;
    }

    public override int Read(Span<byte> buffer)
    {
      WasRead = true;
      return 0;
    }

    public override void Flush() => throw new NotSupportedException();

    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();

    public override void SetLength(long value) => throw new NotSupportedException();

    public override void Write(byte[] buffer, int offset, int count) =>
        throw new NotSupportedException();
  }

  private sealed class SyntheticResolver : IProfileCatalogAliasResolver
  {
    private readonly Dictionary<SourceAliasFingerprint, ResolvedProfileCharacter> _characters = new();
    private readonly Dictionary<SourceAliasFingerprint, ResolvedProfileEquipment> _equipment = new();
    private readonly Dictionary<SourceAliasFingerprint, ResolvedProfileCube> _cubes = new();
    private readonly Dictionary<SourceAliasFingerprint, ResolvedProfileCollection> _collections = new();
    private readonly Dictionary<SourceAliasFingerprint, ResolvedProfileCollection> _favorites = new();
    private readonly Dictionary<SourceAliasFingerprint, ResolvedProfileConsole> _consoles = new();
    private readonly Dictionary<SourceAliasFingerprint, ResolvedProfileOverloadValue> _overloads = new();
    private bool _throwOnCharacterResolution;
    private ProfileAliasResolution<ResolvedProfileCollection>? _favoriteResolutionOverride;

    private SyntheticResolver()
    {
      CharacterCatalog = Binding(1);
      CombatSupportCatalog = Binding(2);
    }

    public ProfileImportCatalogBinding CharacterCatalog { get; }

    public ProfileImportCatalogBinding CombatSupportCatalog { get; }

    public static SyntheticResolver Create(int equipmentTier = 10)
    {
      var result = new SyntheticResolver();
      result._characters.Add(
          Alias("character-resource", SyntheticCapture.CharacterA),
          new ResolvedProfileCharacter(
              Uid(100),
              ProfileImportRarity.Ssr,
              ProfileImportCombatRole.Attacker,
              ProfileImportManufacturer.Elysion,
              ProfileImportWeaponClass.AssaultRifle,
              1_000,
              3,
              10,
              40,
              10,
              10,
              10));
      result._characters.Add(
          Alias("character-resource", SyntheticCapture.CharacterB),
          new ResolvedProfileCharacter(
              Uid(101),
              ProfileImportRarity.Ssr,
              ProfileImportCombatRole.Attacker,
              ProfileImportManufacturer.Elysion,
              ProfileImportWeaponClass.AssaultRifle,
              1_000,
              3,
              10,
              40,
              10,
              10,
              10));
      result._equipment.Add(
          Alias("combat-support-equipment", SyntheticCapture.EquipmentHead),
          new ResolvedProfileEquipment(
              Uid(200),
              ProfileImportEquipmentSlot.Head,
              ProfileImportCombatRole.Attacker,
              equipmentTier == 10
                  ? ProfileImportFact<ProfileImportManufacturer>.NotApplicable()
                  : ProfileImportFact<ProfileImportManufacturer>.Ready(
                      ProfileImportManufacturer.Elysion),
              equipmentTier,
              5,
              true));
      result._cubes.Add(
          Alias("combat-support-harmony-cube", SyntheticCapture.Cube),
          new ResolvedProfileCube(Uid(300), 15, ProfileImportCombatRole.Attacker));
      result._collections.Add(
          Alias("combat-support-generic-collection", SyntheticCapture.Collection),
          new ResolvedProfileCollection(
              Uid(400),
              ProfileImportCollectionKind.GenericCollection,
              15,
              null,
              ProfileImportWeaponClass.AssaultRifle));
      foreach (var coordinate in Enum.GetValues<ProfileImportConsoleCoordinate>())
      {
        var source = SyntheticCapture.ConsoleBase + (int)coordinate + 1;
        result._consoles.Add(
            Alias("combat-support-console", source),
            new ResolvedProfileConsole(
                Uid(500 + (int)coordinate),
                coordinate,
                (int)coordinate + 1,
                680,
                ProfileImportFact<int>.Ready(100)));
      }

      result._overloads.Add(
          Alias("combat-support-overload-legal-value", SyntheticCapture.OverloadLine1),
          new ResolvedProfileOverloadValue(
              Uid(600),
              ProfileImportValueUnit.Ratio,
              111,
              new ProfileImportExactValue(111, 4)));
      result._overloads.Add(
          Alias("combat-support-overload-legal-value", SyntheticCapture.OverloadLine3),
          new ResolvedProfileOverloadValue(
              Uid(601),
              ProfileImportValueUnit.Ratio,
              -333,
              new ProfileImportExactValue(333, 4)));
      return result;
    }

    public void RemoveEquipmentAlias() => _equipment.Clear();

    public void ThrowOnCharacterResolution() => _throwOnCharacterResolution = true;

    public void MakeFavoriteAliasAmbiguous() =>
        _favoriteResolutionOverride = ProfileAliasResolution<ResolvedProfileCollection>.Ambiguous();

    public void ChangeGenericCollectionWeapon(ProfileImportWeaponClass weaponClass)
    {
      var alias = Alias("combat-support-generic-collection", SyntheticCapture.Collection);
      _collections[alias] = _collections[alias] with { ApplicableWeaponClass = weaponClass };
    }

    public void ChangeFirstCharacterRarity(ProfileImportRarity rarity)
    {
      var alias = Alias("character-resource", SyntheticCapture.CharacterA);
      _characters[alias] = _characters[alias] with { Rarity = rarity };
    }

    public void LowerFirstCharacterSkillMaximum()
    {
      var alias = Alias("character-resource", SyntheticCapture.CharacterA);
      _characters[alias] = _characters[alias] with { MaximumSkill1Level = 9 };
    }

    public void MakeFirstConsoleMinimumSynchroUnresolved()
    {
      var alias = Alias("combat-support-console", SyntheticCapture.ConsoleBase + 1);
      _consoles[alias] = _consoles[alias] with
      {
        SelectedLevelMinimumSynchroLevel =
            ProfileImportFact<int>.Unresolved("console_minimum_synchro_not_normalized")
      };
    }

    public void SetFirstConsoleToExplicitZeroLevel()
    {
      var alias = Alias("combat-support-console", SyntheticCapture.ConsoleBase + 1);
      _consoles[alias] = _consoles[alias] with
      {
        SelectedLevel = 0,
        SelectedLevelMinimumSynchroLevel = ProfileImportFact<int>.Ready(0)
      };
    }

    public void RaiseFirstConsoleMinimumSynchroAboveAccount()
    {
      var alias = Alias("combat-support-console", SyntheticCapture.ConsoleBase + 1);
      _consoles[alias] = _consoles[alias] with
      {
        SelectedLevelMinimumSynchroLevel = ProfileImportFact<int>.Ready(201)
      };
    }

    public void CorruptFirstOverloadApplicationValue()
    {
      var alias = Alias(
          "combat-support-overload-legal-value",
          SyntheticCapture.OverloadLine1);
      _overloads[alias] = _overloads[alias] with
      {
        ApplicationValue = new ProfileImportExactValue(112, 4)
      };
    }

    public void NegateFirstOverloadApplicationValue()
    {
      var alias = Alias(
          "combat-support-overload-legal-value",
          SyntheticCapture.OverloadLine1);
      _overloads[alias] = _overloads[alias] with
      {
        ApplicationValue = new ProfileImportExactValue(-111, 4)
      };
    }

    public void ChangeEquipmentCatalogManufacturer(ProfileImportManufacturer manufacturer)
    {
      var alias = Alias("combat-support-equipment", SyntheticCapture.EquipmentHead);
      _equipment[alias] = _equipment[alias] with
      {
        Manufacturer = ProfileImportFact<ProfileImportManufacturer>.Ready(manufacturer)
      };
    }

    public void MakeEquipmentCatalogManufacturerUnresolved()
    {
      var alias = Alias("combat-support-equipment", SyntheticCapture.EquipmentHead);
      _equipment[alias] = _equipment[alias] with
      {
        Manufacturer = ProfileImportFact<ProfileImportManufacturer>.Unresolved(
            "fixture_equipment_manufacturer_unresolved")
      };
    }

    public void MakeEquipmentCatalogManufacturerNotApplicable()
    {
      var alias = Alias("combat-support-equipment", SyntheticCapture.EquipmentHead);
      _equipment[alias] = _equipment[alias] with
      {
        Manufacturer = ProfileImportFact<ProfileImportManufacturer>.NotApplicable()
      };
    }

    public ProfileAliasResolution<ResolvedProfileCharacter> ResolveCharacter(
        SourceAliasFingerprint sourceAlias)
    {
      if (_throwOnCharacterResolution)
      {
        throw new InvalidOperationException("secret-resolver-value");
      }

      return Resolve(_characters, sourceAlias);
    }

    public ProfileAliasResolution<ResolvedProfileEquipment> ResolveEquipment(
        SourceAliasFingerprint sourceAlias) => Resolve(_equipment, sourceAlias);

    public ProfileAliasResolution<ResolvedProfileCube> ResolveCube(
        SourceAliasFingerprint sourceAlias) => Resolve(_cubes, sourceAlias);

    public ProfileAliasResolution<ResolvedProfileCollection> ResolveGenericCollection(
        SourceAliasFingerprint sourceAlias) => Resolve(_collections, sourceAlias);

    public ProfileAliasResolution<ResolvedProfileCollection> ResolveFavorite(
        SourceAliasFingerprint sourceAlias) =>
        _favoriteResolutionOverride ?? Resolve(_favorites, sourceAlias);

    public ProfileAliasResolution<ResolvedProfileConsole> ResolveConsole(
        SourceAliasFingerprint sourceAlias,
        int selectedLevel)
    {
      var result = Resolve(_consoles, sourceAlias);
      return result.Status != ProfileAliasResolutionStatus.Resolved ||
          result.Value!.SelectedLevel == selectedLevel
          ? result
          : ProfileAliasResolution<ResolvedProfileConsole>.CatalogMismatch();
    }

    public ProfileAliasResolution<ResolvedProfileOverloadValue> ResolveOverloadValue(
        SourceAliasFingerprint sourceAlias) => Resolve(_overloads, sourceAlias);

    private static ProfileAliasResolution<T> Resolve<T>(
        IReadOnlyDictionary<SourceAliasFingerprint, T> values,
        SourceAliasFingerprint alias)
        where T : class => values.TryGetValue(alias, out var value)
            ? ProfileAliasResolution<T>.Resolved(value)
            : ProfileAliasResolution<T>.Missing();

    private static ProfileImportCatalogBinding Binding(int value) => new(
        Uid(10 + value),
        Uid(20 + value),
        Sha256Digest.ComputeUtf8($"synthetic-catalog-{value}"));

    private static SourceAliasFingerprint Alias(string kind, long sourceReference) =>
        SourceAliasFingerprintEncoder.Encode(
            IdentitySecret,
            "nikke-staticdata",
            kind,
            sourceReference.ToString());

    private static EntityUid Uid(int value)
    {
      Span<byte> bytes = stackalloc byte[16];
      BitConverter.TryWriteBytes(bytes, value);
      bytes[15] = 1;
      return new EntityUid(new Guid(bytes));
    }
  }
}
