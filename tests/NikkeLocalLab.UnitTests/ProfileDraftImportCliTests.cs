using System.Globalization;
using NikkeLocalLab.Configuration;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Import.Profile;
using NikkeLocalLab.Persistence.PostgreSql;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.UnitTests;

public sealed class ProfileDraftImportCliTests
{
  [Theory]
  [InlineData(
      CharacterLevelAuthorityPolicyCodes.RosterObservationV1,
      CharacterLevelAuthorityPolicy.RosterObservationV1)]
  [InlineData(
      CharacterLevelAuthorityPolicyCodes.DetailObservationV1,
      CharacterLevelAuthorityPolicy.DetailObservationV1)]
  public void Exact_level_authority_and_idempotency_pair_are_accepted(
      string authorityCode,
      CharacterLevelAuthorityPolicy expectedAuthority)
  {
    var operationUid = Uid(10);
    var request = ProfileDraftImportCli.ParseRequest(
        Options(
            authorityCode,
            ("operation-uid", operationUid.ToString()),
            ("imported-at-utc", "2026-08-20T01:02:03.456789Z")),
        new FixedTimeProvider(new DateTimeOffset(2026, 1, 1, 0, 0, 0, TimeSpan.Zero)),
        new FixedUidGenerator(Uid(20)));

    Assert.Equal(expectedAuthority, request.LevelAuthority);
    Assert.Equal(operationUid, request.OperationUid);
    Assert.Equal(
        new DateTimeOffset(2026, 8, 20, 1, 2, 3, 456, TimeSpan.Zero).AddTicks(7_890),
        request.ImportedAtUtc);
    Assert.True(request.IsIdempotencyKeyExplicit);
  }

  [Fact]
  public void Generated_operation_uses_postgresql_safe_utc_microseconds()
  {
    var expectedUid = Uid(30);
    var now = new DateTimeOffset(638_900_000_000_000_019, TimeSpan.FromHours(9));
    var request = ProfileDraftImportCli.ParseRequest(
        Options(CharacterLevelAuthorityPolicyCodes.RosterObservationV1),
        new FixedTimeProvider(now),
        new FixedUidGenerator(expectedUid));

    Assert.Equal(expectedUid, request.OperationUid);
    Assert.Equal(TimeSpan.Zero, request.ImportedAtUtc.Offset);
    Assert.Equal(0, request.ImportedAtUtc.Ticks % 10);
    Assert.Equal(now.ToUniversalTime().Ticks - 9, request.ImportedAtUtc.Ticks);
    Assert.False(request.IsIdempotencyKeyExplicit);
  }

  [Theory]
  [InlineData("missing_authority", "profile_level_authority_required")]
  [InlineData("invalid_authority", "profile_level_authority_invalid")]
  [InlineData("raw_path_option", "profile_import_option_not_supported")]
  [InlineData("operation_without_timestamp", "profile_import_idempotency_option_incomplete")]
  [InlineData("timestamp_without_operation", "profile_import_idempotency_option_incomplete")]
  [InlineData("empty_operation", "profile_import_operation_uid_invalid")]
  [InlineData("non_utc_timestamp", "profile_import_timestamp_invalid")]
  [InlineData("sub_microsecond_timestamp", "profile_import_timestamp_invalid")]
  public void Invalid_requests_map_to_controlled_codes(string scenario, string expectedCode)
  {
    var options = scenario switch
    {
      "missing_authority" => Options(null),
      "invalid_authority" => Options("roster"),
      "raw_path_option" => Options(
          CharacterLevelAuthorityPolicyCodes.RosterObservationV1,
          ("source-path", "forbidden")),
      "operation_without_timestamp" => Options(
          CharacterLevelAuthorityPolicyCodes.RosterObservationV1,
          ("operation-uid", Uid(40).ToString())),
      "timestamp_without_operation" => Options(
          CharacterLevelAuthorityPolicyCodes.RosterObservationV1,
          ("imported-at-utc", "2026-08-20T01:02:03.456789Z")),
      "empty_operation" => Options(
          CharacterLevelAuthorityPolicyCodes.RosterObservationV1,
          ("operation-uid", Guid.Empty.ToString("D")),
          ("imported-at-utc", "2026-08-20T01:02:03.456789Z")),
      "non_utc_timestamp" => Options(
          CharacterLevelAuthorityPolicyCodes.RosterObservationV1,
          ("operation-uid", Uid(40).ToString()),
          ("imported-at-utc", "2026-08-20T10:02:03.456789+09:00")),
      "sub_microsecond_timestamp" => Options(
          CharacterLevelAuthorityPolicyCodes.RosterObservationV1,
          ("operation-uid", Uid(40).ToString()),
          ("imported-at-utc", "2026-08-20T01:02:03.4567890Z")),
      _ => throw new InvalidOperationException()
    };

    var failure = Assert.Throws<LabConfigurationException>(() =>
        ProfileDraftImportCli.ParseRequest(
            options,
            new FixedTimeProvider(DateTimeOffset.UnixEpoch),
            new FixedUidGenerator(Uid(50))));

    Assert.Equal(expectedCode, failure.Code);
  }

  [Fact]
  public void Sanitizer_failures_choose_a_deterministic_source_free_code()
  {
    ProfileImportDiagnostic[] diagnostics =
    [
      new(
          "z_failure",
          ProfileImportDiagnosticSeverity.Error,
          ProfileImportDiagnosticScope.Capture,
          1),
      new(
          "warning_only",
          ProfileImportDiagnosticSeverity.Warning,
          ProfileImportDiagnosticScope.Character,
          9),
      new(
          "a_failure",
          ProfileImportDiagnosticSeverity.Error,
          ProfileImportDiagnosticScope.Catalog,
          2)
    ];

    Assert.Equal("a_failure", ProfileDraftImportCli.SelectFailureCode(diagnostics));
    Assert.Equal(
        "profile_source_invalid",
        ProfileDraftImportCli.SelectFailureCode(
        [
          new ProfileImportDiagnostic(
              "warning_only",
              ProfileImportDiagnosticSeverity.Warning,
              ProfileImportDiagnosticScope.Character,
              1)
        ]));
  }

  [Theory]
  [InlineData(false, false, "status=succeeded")]
  [InlineData(false, true, "status=content_reused")]
  [InlineData(true, true, "status=idempotent_replay")]
  public void Receipt_output_is_source_free_aggregate_only(
      bool replay,
      bool contentReused,
      string expectedStatus)
  {
    var digest = Sha256Digest.ComputeUtf8("synthetic");
    var receipt = new SanitizedProfileDraftReceipt(
        Uid(60),
        replay,
        contentReused,
        Uid(61),
        SanitizedProfileDraftDerivationKind.OfflineSanitizedImport,
        null,
        SanitizedProfileDraftContract.SchemaCode,
        digest,
        digest,
        digest,
        digest,
        new DateTimeOffset(2026, 8, 20, 1, 2, 3, 456, TimeSpan.Zero).AddTicks(7_890));
    var provenance = new SanitizedProfileImportProvenance(
        SanitizedProfileDraftContract.SchemaCode,
        digest,
        SanitizedProfileDraftContract.TransformerId,
        SanitizedProfileDraftContract.TransformerVersion,
        digest,
        digest,
        digest,
        digest,
        DateTimeOffset.UnixEpoch,
        ProfileImportFact<DateTimeOffset>.Unresolved("capture_time_not_observed"),
        ProfileCaptureAtomicity.Unresolved,
        CredentialBearingSourceHashPolicy.Prohibited);
    var characterCatalog = new ProfileImportCatalogBinding(Uid(62), Uid(63), digest);
    var supportCatalog = new ProfileImportCatalogBinding(Uid(64), Uid(65), digest);
    var draft = new SanitizedProfileDraft(
        provenance,
        characterCatalog,
        supportCatalog,
        new SanitizedAccountCombatStateDraft(1, 0, []),
        [],
        [],
        CanMaterializeLocalAccountProfile: true,
        IsLocalAccountProfileWriteReady: false);
    using var writer = new StringWriter(CultureInfo.InvariantCulture);

    ProfileDraftImportCli.WriteReceipt(writer, receipt, draft, []);

    var output = writer.ToString();
    Assert.Contains("profile_draft_imported", output, StringComparison.Ordinal);
    Assert.Contains(expectedStatus, output, StringComparison.Ordinal);
    Assert.Contains("completed_at_utc=2026-08-20T01:02:03.456789Z", output, StringComparison.Ordinal);
    Assert.Contains($"sanitized_payload_sha256={digest}", output, StringComparison.Ordinal);
    Assert.Contains(
        $"character_catalog_snapshot_uid={characterCatalog.CatalogSnapshotUid}",
        output,
        StringComparison.Ordinal);
    Assert.Contains(
        $"combat_support_catalog_snapshot_uid={supportCatalog.CatalogSnapshotUid}",
        output,
        StringComparison.Ordinal);
    Assert.Contains("build_count=0", output, StringComparison.Ordinal);
    Assert.Contains("console_count=0", output, StringComparison.Ordinal);
    Assert.Contains("result_scope=sanitized_draft_only", output, StringComparison.Ordinal);
    Assert.Contains(
        "next_step=review_draft_then_create_local_profile",
        output,
        StringComparison.Ordinal);
    Assert.DoesNotContain("path=", output, StringComparison.OrdinalIgnoreCase);
    Assert.DoesNotContain("token=", output, StringComparison.OrdinalIgnoreCase);
    Assert.DoesNotContain("source_id=", output, StringComparison.OrdinalIgnoreCase);
  }

  private static Dictionary<string, string> Options(
      string? authority,
      params (string Key, string Value)[] extras)
  {
    var options = new Dictionary<string, string>(StringComparer.Ordinal)
    {
      ["config"] = "synthetic-config",
      ["repository-root"] = "synthetic-repository"
    };
    if (authority is not null)
    {
      options.Add("level-authority", authority);
    }

    foreach (var (key, value) in extras)
    {
      options.Add(key, value);
    }

    return options;
  }

  private static EntityUid Uid(int value) => new(Guid.ParseExact(
      $"00000000-0000-0000-0000-{value:x12}",
      "D"));

  private sealed class FixedUidGenerator(EntityUid uid) : IEntityUidGenerator
  {
    public EntityUid NewUid() => uid;
  }

  private sealed class FixedTimeProvider(DateTimeOffset now) : TimeProvider
  {
    public override DateTimeOffset GetUtcNow() => now;
  }
}
