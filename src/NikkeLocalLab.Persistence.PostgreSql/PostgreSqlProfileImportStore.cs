using System.Data;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using ImportProfile = NikkeLocalLab.Import.Profile;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;
using Npgsql;
using NpgsqlTypes;

namespace NikkeLocalLab.Persistence.PostgreSql;

public enum SanitizedProfileDraftDerivationKind
{
  OfflineSanitizedImport,
  Rebase,
  ReviewedOverride
}

public enum ProfileDraftApplicationKind
{
  Apply,
  SaveAs,
  Rebase,
  Create
}

public sealed record SanitizedProfileDraftWrite
{
  public const string SchemaCode = "nll/sanitized-profile-draft/v1";

  public SanitizedProfileDraftWrite(
      SanitizedProfileDraftDerivationKind derivationKind,
      EntityUid? previousDraftUid,
      Sha256Digest sanitizerContractSha256,
      Sha256Digest transformerSha256,
      Sha256Digest semanticOptionsSha256,
      LocalProfileCatalogBindingWrite characterCatalog,
      LocalProfileCatalogBindingWrite combatSupportCatalog,
      string canonicalPayloadJson)
  {
    if (!Enum.IsDefined(derivationKind) ||
        (derivationKind == SanitizedProfileDraftDerivationKind.OfflineSanitizedImport &&
         previousDraftUid.HasValue) ||
        (derivationKind is SanitizedProfileDraftDerivationKind.Rebase or
             SanitizedProfileDraftDerivationKind.ReviewedOverride &&
          !previousDraftUid.HasValue) ||
        sanitizerContractSha256 == default || transformerSha256 == default ||
        semanticOptionsSha256 == default)
    {
      throw new LocalGameStateIntegrityException("sanitized_profile_draft_shape_invalid");
    }

    CharacterCatalog = characterCatalog ?? throw new ArgumentNullException(nameof(characterCatalog));
    CombatSupportCatalog = combatSupportCatalog ??
        throw new ArgumentNullException(nameof(combatSupportCatalog));
    CanonicalPayloadJson = SanitizedProfileJsonGuard.RequireSourceFreeObject(canonicalPayloadJson);
    ImportProfile.SanitizedProfileDraft decoded;
    try
    {
      decoded = ImportProfile.SanitizedProfileDraftJsonCodec.Decode(
          Encoding.UTF8.GetBytes(CanonicalPayloadJson));
    }
    catch (ImportProfile.SanitizedProfileDraftCodecException exception)
    {
      throw new LocalGameStateIntegrityException(exception.Code);
    }

    if (decoded.Provenance.SourceSchemaSha256 != sanitizerContractSha256 ||
        decoded.Provenance.TransformerBinarySha256 != transformerSha256 ||
        decoded.Provenance.SemanticOptionsSha256 != semanticOptionsSha256 ||
        !BindingEquals(CharacterCatalog, decoded.CharacterCatalog) ||
        !BindingEquals(CombatSupportCatalog, decoded.CombatSupportCatalog))
    {
      throw new LocalGameStateIntegrityException("sanitized_profile_storage_parity_invalid");
    }

    var expectedTransformer = derivationKind switch
    {
      SanitizedProfileDraftDerivationKind.OfflineSanitizedImport =>
          ImportProfile.SanitizedProfileDraftContract.Transformer,
      SanitizedProfileDraftDerivationKind.Rebase =>
          ImportProfile.SanitizedProfileDraftContract.RebaseTransformer,
      SanitizedProfileDraftDerivationKind.ReviewedOverride =>
          ImportProfile.SanitizedProfileDraftContract.ReviewedOverrideTransformer,
      _ => throw new LocalGameStateIntegrityException("sanitized_profile_draft_kind_invalid")
    };
    if (decoded.Provenance.TransformerId != expectedTransformer.ExtractorId ||
        decoded.Provenance.TransformerVersion != expectedTransformer.ExtractorVersion ||
        decoded.Provenance.SourceSchemaSha256 != expectedTransformer.ContractSha256 ||
        decoded.Provenance.TransformerFingerprintSha256 != expectedTransformer.FingerprintSha256)
    {
      throw new LocalGameStateIntegrityException("sanitized_profile_derivation_transformer_mismatch");
    }

    DerivationKind = derivationKind;
    PreviousDraftUid = previousDraftUid;
    SanitizerContractSha256 = sanitizerContractSha256;
    TransformerSha256 = transformerSha256;
    SemanticOptionsSha256 = semanticOptionsSha256;
    CanonicalPayloadSha256 = Sha256Digest.ComputeUtf8(CanonicalPayloadJson);
    ImportedAtUtc = decoded.Provenance.ImportedAtUtc;
  }

  public SanitizedProfileDraftDerivationKind DerivationKind { get; }

  public EntityUid? PreviousDraftUid { get; }

  public Sha256Digest SanitizerContractSha256 { get; }

  public Sha256Digest TransformerSha256 { get; }

  public Sha256Digest SemanticOptionsSha256 { get; }

  public LocalProfileCatalogBindingWrite CharacterCatalog { get; }

  public LocalProfileCatalogBindingWrite CombatSupportCatalog { get; }

  public string CanonicalPayloadJson { get; }

  public Sha256Digest CanonicalPayloadSha256 { get; }

  public DateTimeOffset ImportedAtUtc { get; }

  private static bool BindingEquals(
      LocalProfileCatalogBindingWrite stored,
      ImportProfile.ProfileImportCatalogBinding decoded) =>
      stored.CatalogSnapshotUid == decoded.CatalogSnapshotUid &&
      stored.DatasetSnapshotUid == decoded.DatasetSnapshotUid &&
      stored.CatalogManifestSha256 == decoded.ManifestSha256;
}

public sealed record ImportSanitizedProfileDraftCommand
{
  public ImportSanitizedProfileDraftCommand(
      EntityUid operationUid,
      SanitizedProfileDraftWrite draft,
      DateTimeOffset completedAtUtc)
  {
    LocalGameStateContractGuard.RequireUid(operationUid, "sanitized_import_operation_uid_invalid");
    LocalGameStateContractGuard.RequireTimestamp(completedAtUtc);
    OperationUid = operationUid;
    Draft = draft ?? throw new ArgumentNullException(nameof(draft));
    if (draft.ImportedAtUtc != completedAtUtc)
    {
      throw new LocalGameStateIntegrityException("sanitized_profile_timestamp_mismatch");
    }

    CompletedAtUtc = completedAtUtc;
    RequestSha256 = ProfileImportCanonicalizer.ComputeImportRequestSha256(this);
  }

  public EntityUid OperationUid { get; }

  public SanitizedProfileDraftWrite Draft { get; }

  public DateTimeOffset CompletedAtUtc { get; }

  public Sha256Digest RequestSha256 { get; }
}

public sealed record SanitizedProfileDraftReceipt(
    EntityUid OperationUid,
    bool IsIdempotentReplay,
    bool IsContentReused,
    EntityUid DraftUid,
    SanitizedProfileDraftDerivationKind DerivationKind,
    EntityUid? PreviousDraftUid,
    string PayloadSchemaCode,
    Sha256Digest SanitizerContractSha256,
    Sha256Digest TransformerSha256,
    Sha256Digest SemanticOptionsSha256,
    Sha256Digest CanonicalPayloadSha256,
    DateTimeOffset CreatedAtUtc);

public sealed record SanitizedProfileDraftDocument(
    EntityUid DraftUid,
    SanitizedProfileDraftDerivationKind DerivationKind,
    EntityUid? PreviousDraftUid,
    string PayloadSchemaCode,
    Sha256Digest SanitizerContractSha256,
    Sha256Digest TransformerSha256,
    Sha256Digest SemanticOptionsSha256,
    LocalProfileCatalogBindingWrite CharacterCatalog,
    LocalProfileCatalogBindingWrite CombatSupportCatalog,
    string CanonicalPayloadJson,
    Sha256Digest CanonicalPayloadSha256,
    DateTimeOffset CreatedAtUtc);

public sealed record ProfileEditCandidateDocument(
    EntityUid CandidateUid,
    EntityUid OperationUid,
    Sha256Digest RequestSha256,
    EntityUid AccountUid,
    EntityUid BaseProfileTemplateRevisionUid,
    string ContractVersion,
    string CanonicalOperationsJson,
    Sha256Digest CanonicalOperationsSha256,
    int OperationCount,
    DateTimeOffset CreatedAtUtc);

public sealed record ProfileDraftDiffWrite
{
  public ProfileDraftDiffWrite(
      string contractVersion,
      string canonicalDiffJson,
      int changeCount,
      bool hasConflicts)
  {
    ContractVersion = LocalGameStateContractGuard.RequireCode(contractVersion);
    CanonicalDiffJson = SanitizedProfileJsonGuard.RequireSourceFreeObject(canonicalDiffJson);
    if (changeCount < 0)
    {
      throw new LocalGameStateIntegrityException("profile_draft_diff_count_invalid");
    }

    ChangeCount = changeCount;
    HasConflicts = hasConflicts;
    CanonicalDiffSha256 = Sha256Digest.ComputeUtf8(CanonicalDiffJson);
  }

  public string ContractVersion { get; }

  public string CanonicalDiffJson { get; }

  public Sha256Digest CanonicalDiffSha256 { get; }

  public int ChangeCount { get; }

  public bool HasConflicts { get; }
}

public sealed record CreateProfileDraftDiffCommand
{
  public CreateProfileDraftDiffCommand(
      EntityUid diffUid,
      EntityUid draftUid,
      EntityUid accountUid,
      EntityUid expectedProfileTemplateRevisionUid,
      ProfileDraftDiffWrite diff,
      DateTimeOffset createdAtUtc)
  {
    LocalGameStateContractGuard.RequireUid(diffUid, "profile_draft_diff_uid_invalid");
    LocalGameStateContractGuard.RequireUid(draftUid, "sanitized_profile_draft_uid_invalid");
    LocalGameStateContractGuard.RequireUid(accountUid, "local_game_account_uid_invalid");
    LocalGameStateContractGuard.RequireUid(
        expectedProfileTemplateRevisionUid,
        "local_game_profile_revision_uid_invalid");
    LocalGameStateContractGuard.RequireTimestamp(createdAtUtc);
    DiffUid = diffUid;
    DraftUid = draftUid;
    AccountUid = accountUid;
    ExpectedProfileTemplateRevisionUid = expectedProfileTemplateRevisionUid;
    Diff = diff ?? throw new ArgumentNullException(nameof(diff));
    CreatedAtUtc = createdAtUtc;
    RequestSha256 = ProfileImportCanonicalizer.ComputeDiffRequestSha256(this);
  }

  public EntityUid DiffUid { get; }

  public EntityUid DraftUid { get; }

  public EntityUid AccountUid { get; }

  public EntityUid ExpectedProfileTemplateRevisionUid { get; }

  public ProfileDraftDiffWrite Diff { get; }

  public DateTimeOffset CreatedAtUtc { get; }

  public Sha256Digest RequestSha256 { get; }
}

public sealed record CreateImportProfileDraftDiffCommand
{
  public CreateImportProfileDraftDiffCommand(
      EntityUid diffUid,
      EntityUid draftUid,
      ProfileDraftDiffWrite diff,
      DateTimeOffset createdAtUtc)
  {
    LocalGameStateContractGuard.RequireUid(diffUid, "profile_draft_diff_uid_invalid");
    LocalGameStateContractGuard.RequireUid(draftUid, "sanitized_profile_draft_uid_invalid");
    LocalGameStateContractGuard.RequireTimestamp(createdAtUtc);
    DiffUid = diffUid;
    DraftUid = draftUid;
    Diff = diff ?? throw new ArgumentNullException(nameof(diff));
    CreatedAtUtc = createdAtUtc;
    RequestSha256 = ProfileImportCanonicalizer.ComputeCreateDiffRequestSha256(this);
  }

  public EntityUid DiffUid { get; }

  public EntityUid DraftUid { get; }

  public ProfileDraftDiffWrite Diff { get; }

  public DateTimeOffset CreatedAtUtc { get; }

  public Sha256Digest RequestSha256 { get; }
}

public sealed record ProfileDraftDiffReceipt(
    EntityUid DiffUid,
    bool IsIdempotentReplay,
    EntityUid DraftUid,
    EntityUid? AccountUid,
    EntityUid? BaseProfileTemplateRevisionUid,
    string ContractVersion,
    Sha256Digest CanonicalDiffSha256,
    int ChangeCount,
    bool HasConflicts,
    DateTimeOffset CreatedAtUtc);

public sealed record ProfileDraftDiffDocument(
    EntityUid DiffUid,
    Sha256Digest RequestSha256,
    EntityUid DraftUid,
    EntityUid? AccountUid,
    EntityUid? BaseProfileTemplateRevisionUid,
    string ContractVersion,
    string CanonicalDiffJson,
    Sha256Digest CanonicalDiffSha256,
    int ChangeCount,
    bool HasConflicts,
    DateTimeOffset CreatedAtUtc);

public sealed record LinkProfileDraftApplicationCommand
{
  public LinkProfileDraftApplicationCommand(
      EntityUid applicationUid,
      ProfileDraftApplicationKind applicationKind,
      EntityUid diffUid,
      EntityUid profileWriteOperationUid,
      DateTimeOffset appliedAtUtc)
  {
    LocalGameStateContractGuard.RequireUid(applicationUid, "profile_draft_application_uid_invalid");
    LocalGameStateContractGuard.RequireUid(diffUid, "profile_draft_diff_uid_invalid");
    LocalGameStateContractGuard.RequireUid(
        profileWriteOperationUid,
        "profile_write_operation_uid_invalid");
    LocalGameStateContractGuard.RequireTimestamp(appliedAtUtc);
    if (!Enum.IsDefined(applicationKind))
    {
      throw new LocalGameStateIntegrityException("profile_draft_application_kind_invalid");
    }

    ApplicationUid = applicationUid;
    ApplicationKind = applicationKind;
    DiffUid = diffUid;
    ProfileWriteOperationUid = profileWriteOperationUid;
    AppliedAtUtc = appliedAtUtc;
    RequestSha256 = ProfileImportCanonicalizer.ComputeApplicationRequestSha256(this);
  }

  public EntityUid ApplicationUid { get; }

  public ProfileDraftApplicationKind ApplicationKind { get; }

  public EntityUid DiffUid { get; }

  public EntityUid ProfileWriteOperationUid { get; }

  public DateTimeOffset AppliedAtUtc { get; }

  public Sha256Digest RequestSha256 { get; }
}

public sealed record ProfileDraftApplicationReceipt(
    EntityUid ApplicationUid,
    bool IsIdempotentReplay,
    ProfileDraftApplicationKind ApplicationKind,
    EntityUid DiffUid,
    EntityUid ProfileWriteOperationUid,
    EntityUid? SourceAccountUid,
    EntityUid? SourceBaseProfileTemplateRevisionUid,
    EntityUid ResultAccountUid,
    EntityUid ResultProfileTemplateRevisionUid,
    DateTimeOffset AppliedAtUtc);

public sealed record ProfileDraftApplicationIntentReceipt(
    EntityUid ApplicationUid,
    bool IsIdempotentReplay,
    ProfileDraftApplicationKind ApplicationKind,
    EntityUid DiffUid,
    EntityUid ProfileWriteOperationUid,
    DateTimeOffset RequestedAtUtc);

public sealed record ResolvedCharacterPrivateAlias(
    EntityUid CharacterUid,
    EntityUid CharacterDefinitionVersionUid);

public sealed record ResolvedCombatSupportPrivateAlias(
    EntityUid DefinitionUid,
    EntityUid DefinitionVersionUid,
    string DefinitionKind);

public sealed record ResolvedOverloadPrivateAlias(
    EntityUid DefinitionUid,
    EntityUid DefinitionVersionUid,
    int RollLevel);

public interface IPrivateProfileAliasResolver
{
  Task<ResolvedCharacterPrivateAlias> ResolveCharacterAliasAsync(
      LocalProfileCatalogBindingWrite selectedCatalog,
      Sha256Digest aliasFingerprint,
      CancellationToken cancellationToken = default);

  Task<ResolvedCombatSupportPrivateAlias> ResolveCombatSupportAliasAsync(
      LocalProfileCatalogBindingWrite selectedCatalog,
      Sha256Digest aliasFingerprint,
      string expectedDefinitionKind,
      CancellationToken cancellationToken = default);

  Task<ResolvedOverloadPrivateAlias> ResolveOverloadAliasAsync(
      LocalProfileCatalogBindingWrite selectedCatalog,
      Sha256Digest aliasFingerprint,
      CancellationToken cancellationToken = default);
}

public sealed class PostgreSqlProfileImportStore : IPrivateProfileAliasResolver
{
  private const long OperationLockSeed = 4_679_839_211_553_607_001;
  private const long ContentLockSeed = 4_679_839_211_553_607_002;
  private readonly NpgsqlDataSource _dataSource;
  private readonly IEntityUidGenerator _uidGenerator;

  public PostgreSqlProfileImportStore(
      NpgsqlDataSource dataSource,
      IEntityUidGenerator uidGenerator)
  {
    _dataSource = dataSource ?? throw new ArgumentNullException(nameof(dataSource));
    _uidGenerator = uidGenerator ?? throw new ArgumentNullException(nameof(uidGenerator));
  }

  public async Task<ResolvedCharacterPrivateAlias> ResolveCharacterAliasAsync(
      LocalProfileCatalogBindingWrite selectedCatalog,
      Sha256Digest aliasFingerprint,
      CancellationToken cancellationToken = default)
  {
    ArgumentNullException.ThrowIfNull(selectedCatalog);
    RequireFingerprint(aliasFingerprint);
    await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken)
        .ConfigureAwait(false);
    await using var command = new NpgsqlCommand(
        """
        SELECT character.character_uid, version.character_definition_version_uid
        FROM lab_private.character_source_alias AS source_alias
        JOIN lab_catalog.character_entity AS character
          ON character.character_entity_id = source_alias.character_entity_id
        JOIN lab_catalog.character_catalog_snapshot_member AS member
          ON member.character_entity_id = character.character_entity_id
        JOIN lab_catalog.character_definition_version AS version
          ON version.character_definition_version_id =
             member.character_definition_version_id
        JOIN lab_catalog.character_catalog_snapshot AS catalog
          ON catalog.character_catalog_snapshot_id = member.character_catalog_snapshot_id
        JOIN lab_import.dataset_snapshot AS dataset
          ON dataset.dataset_snapshot_id = catalog.dataset_snapshot_id
        WHERE source_alias.alias_fingerprint = @fingerprint
          AND catalog.character_catalog_snapshot_uid = @catalog_uid
          AND dataset.dataset_snapshot_uid = @dataset_uid
          AND catalog.catalog_manifest_sha256 = @manifest;
        """,
        connection);
    AddCatalog(command, selectedCatalog);
    Add(command, "fingerprint", NpgsqlDbType.Bytea, aliasFingerprint.ToByteArray());
    await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
    if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      throw new LocalGameStateIntegrityException("sanitized_import_character_alias_unresolved");
    }

    var result = new ResolvedCharacterPrivateAlias(
        new EntityUid(reader.GetGuid(0)),
        new EntityUid(reader.GetGuid(1)));
    if (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      throw new LocalGameStateIntegrityException("sanitized_import_character_alias_ambiguous");
    }

    return result;
  }

  public async Task<ResolvedCombatSupportPrivateAlias> ResolveCombatSupportAliasAsync(
      LocalProfileCatalogBindingWrite selectedCatalog,
      Sha256Digest aliasFingerprint,
      string expectedDefinitionKind,
      CancellationToken cancellationToken = default)
  {
    ArgumentNullException.ThrowIfNull(selectedCatalog);
    RequireFingerprint(aliasFingerprint);
    var kind = RequireDefinitionKind(expectedDefinitionKind);
    await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken)
        .ConfigureAwait(false);
    await using var command = new NpgsqlCommand(
        """
        SELECT definition.definition_uid, version.definition_version_uid,
               definition.definition_kind
        FROM lab_private.combat_support_source_alias AS source_alias
        JOIN lab_combat_support.definition_entity AS definition
          ON definition.definition_entity_id = source_alias.definition_entity_id
        JOIN lab_combat_support.catalog_snapshot_member AS member
          ON member.definition_entity_id = definition.definition_entity_id
         AND member.definition_kind = definition.definition_kind
        JOIN lab_combat_support.definition_version AS version
          ON version.definition_version_id = member.definition_version_id
        JOIN lab_combat_support.catalog_snapshot AS catalog
          ON catalog.catalog_snapshot_id = member.catalog_snapshot_id
        JOIN lab_import.dataset_snapshot AS dataset
          ON dataset.dataset_snapshot_id = catalog.dataset_snapshot_id
        WHERE source_alias.alias_fingerprint = @fingerprint
          AND definition.definition_kind = @kind
          AND catalog.catalog_snapshot_uid = @catalog_uid
          AND dataset.dataset_snapshot_uid = @dataset_uid
          AND catalog.catalog_manifest_sha256 = @manifest;
        """,
        connection);
    AddCatalog(command, selectedCatalog);
    Add(command, "fingerprint", NpgsqlDbType.Bytea, aliasFingerprint.ToByteArray());
    Add(command, "kind", NpgsqlDbType.Text, kind);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
    if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      throw new LocalGameStateIntegrityException("sanitized_import_support_alias_unresolved");
    }

    var result = new ResolvedCombatSupportPrivateAlias(
        new EntityUid(reader.GetGuid(0)),
        new EntityUid(reader.GetGuid(1)),
        reader.GetString(2));
    if (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      throw new LocalGameStateIntegrityException("sanitized_import_support_alias_ambiguous");
    }

    return result;
  }

  public async Task<ResolvedOverloadPrivateAlias> ResolveOverloadAliasAsync(
      LocalProfileCatalogBindingWrite selectedCatalog,
      Sha256Digest aliasFingerprint,
      CancellationToken cancellationToken = default)
  {
    ArgumentNullException.ThrowIfNull(selectedCatalog);
    RequireFingerprint(aliasFingerprint);
    await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken)
        .ConfigureAwait(false);
    await using var command = new NpgsqlCommand(
        """
        SELECT definition.definition_uid, version.definition_version_uid,
               source_alias.roll_level
        FROM lab_private.overload_legal_value_source_alias AS source_alias
        JOIN lab_combat_support.definition_entity AS definition
          ON definition.definition_entity_id = source_alias.definition_entity_id
        JOIN lab_combat_support.definition_version AS version
          ON version.definition_version_id = source_alias.definition_version_id
        JOIN lab_combat_support.catalog_snapshot_member AS member
          ON member.definition_entity_id = source_alias.definition_entity_id
         AND member.definition_version_id = source_alias.definition_version_id
         AND member.definition_kind = 'overload_option'
        JOIN lab_combat_support.catalog_snapshot AS catalog
          ON catalog.catalog_snapshot_id = member.catalog_snapshot_id
        JOIN lab_import.dataset_snapshot AS dataset
          ON dataset.dataset_snapshot_id = catalog.dataset_snapshot_id
        WHERE source_alias.alias_fingerprint = @fingerprint
          AND catalog.catalog_snapshot_uid = @catalog_uid
          AND dataset.dataset_snapshot_uid = @dataset_uid
          AND catalog.catalog_manifest_sha256 = @manifest;
        """,
        connection);
    AddCatalog(command, selectedCatalog);
    Add(command, "fingerprint", NpgsqlDbType.Bytea, aliasFingerprint.ToByteArray());
    await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
    if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      throw new LocalGameStateIntegrityException("sanitized_import_overload_alias_unresolved");
    }

    var result = new ResolvedOverloadPrivateAlias(
        new EntityUid(reader.GetGuid(0)),
        new EntityUid(reader.GetGuid(1)),
        reader.GetInt32(2));
    if (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      throw new LocalGameStateIntegrityException("sanitized_import_overload_alias_ambiguous");
    }

    return result;
  }

  public async Task<ProfileEditCandidateDocument> SaveProfileEditCandidateAsync(
      EntityUid operationUid,
      EntityUid accountUid,
      EntityUid baseProfileTemplateRevisionUid,
      string canonicalOperationsJson,
      int operationCount,
      DateTimeOffset createdAtUtc,
      CancellationToken cancellationToken = default)
  {
    LocalGameStateContractGuard.RequireUid(operationUid, "profile_edit_operation_uid_invalid");
    LocalGameStateContractGuard.RequireUid(accountUid, "local_game_account_uid_invalid");
    LocalGameStateContractGuard.RequireUid(
        baseProfileTemplateRevisionUid,
        "local_game_profile_revision_uid_invalid");
    LocalGameStateContractGuard.RequireTimestamp(createdAtUtc);
    if (operationCount is < 0 or > 512)
    {
      throw new LocalGameStateIntegrityException("profile_edit_operation_count_invalid");
    }

    var canonical = SanitizedProfileJsonGuard.RequireSourceFreeObject(canonicalOperationsJson);
    var payloadHash = Sha256Digest.ComputeUtf8(canonical);
    var requestHash = ProfileImportCanonicalizer.ComputeEditCandidateRequestSha256(
        accountUid,
        baseProfileTemplateRevisionUid,
        payloadHash,
        operationCount);
    await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken)
        .ConfigureAwait(false);
    await using var transaction = await connection.BeginTransactionAsync(
        IsolationLevel.ReadCommitted,
        cancellationToken).ConfigureAwait(false);
    try
    {
      await AcquireLockAsync(
          connection,
          transaction,
          operationUid.ToString(),
          OperationLockSeed,
          cancellationToken).ConfigureAwait(false);
      var replay = await ReadEditCandidateByOperationAsync(
          connection,
          transaction,
          operationUid,
          cancellationToken).ConfigureAwait(false);
      if (replay is not null)
      {
        if (replay.RequestSha256 != requestHash)
        {
          throw new LocalGameStateIntegrityException("profile_edit_operation_reuse_mismatch");
        }

        await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
        return replay;
      }

      var profile = await LockCurrentProfileAsync(
          connection,
          transaction,
          accountUid,
          baseProfileTemplateRevisionUid,
          cancellationToken).ConfigureAwait(false);
      var candidateUid = _uidGenerator.NewUid();
      await using (var insert = new NpgsqlCommand(
          """
          INSERT INTO lab_local_game.profile_edit_candidate (
              profile_edit_candidate_uid,
              operation_uid,
              request_sha256,
              local_account_id,
              base_profile_template_revision_id,
              candidate_contract_version,
              canonical_operations_json,
              canonical_operations_sha256,
              operation_count,
              created_at_utc
          ) VALUES (
              @candidate_uid, @operation_uid, @request_hash, @account_id, @base_id,
              'nll/profile-edit-candidate/v1', @canonical_json, @payload_hash,
              @operation_count, @created_at
          );
          """,
          connection,
          transaction))
      {
        Add(insert, "candidate_uid", NpgsqlDbType.Uuid, candidateUid.Value);
        Add(insert, "operation_uid", NpgsqlDbType.Uuid, operationUid.Value);
        Add(insert, "request_hash", NpgsqlDbType.Bytea, requestHash.ToByteArray());
        Add(insert, "account_id", NpgsqlDbType.Bigint, profile.AccountId);
        Add(insert, "base_id", NpgsqlDbType.Bigint, profile.ProfileRevisionId);
        Add(insert, "canonical_json", NpgsqlDbType.Text, canonical);
        Add(insert, "payload_hash", NpgsqlDbType.Bytea, payloadHash.ToByteArray());
        Add(insert, "operation_count", NpgsqlDbType.Integer, operationCount);
        Add(insert, "created_at", NpgsqlDbType.TimestampTz, createdAtUtc);
        await insert.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
      }

      var result = await ReadEditCandidateByOperationAsync(
          connection,
          transaction,
          operationUid,
          cancellationToken).ConfigureAwait(false) ??
          throw new LocalGameStateIntegrityException("profile_edit_candidate_not_found");
      await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
      return result;
    }
    catch (PostgresException exception)
    {
      throw MapDatabaseException(exception);
    }
  }

  public async Task<ProfileEditCandidateDocument?> GetProfileEditCandidateAsync(
      EntityUid candidateUid,
      CancellationToken cancellationToken = default)
  {
    LocalGameStateContractGuard.RequireUid(candidateUid, "profile_edit_candidate_uid_invalid");
    await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken)
        .ConfigureAwait(false);
    return await ReadEditCandidateAsync(
        connection,
        transaction: null,
        candidateUid,
        operationUid: null,
        cancellationToken).ConfigureAwait(false);
  }

  public async Task<ProfileEditCandidateDocument?> GetProfileEditCandidateByOperationAsync(
      EntityUid operationUid,
      CancellationToken cancellationToken = default)
  {
    LocalGameStateContractGuard.RequireUid(operationUid, "profile_edit_operation_uid_invalid");
    await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken)
        .ConfigureAwait(false);
    return await ReadEditCandidateAsync(
        connection,
        transaction: null,
        candidateUid: null,
        operationUid,
        cancellationToken).ConfigureAwait(false);
  }

  public async Task<SanitizedProfileDraftDocument?> GetDraftAsync(
      EntityUid draftUid,
      CancellationToken cancellationToken = default)
  {
    LocalGameStateContractGuard.RequireUid(draftUid, "sanitized_profile_draft_uid_invalid");
    await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken)
        .ConfigureAwait(false);
    await using var command = new NpgsqlCommand(
        """
        SELECT
            draft.derivation_kind,
            previous.sanitized_profile_draft_uid,
            draft.payload_schema_code,
            draft.sanitizer_contract_sha256,
            draft.transformer_sha256,
            draft.semantic_options_sha256,
            character_catalog.character_catalog_snapshot_uid,
            character_dataset.dataset_snapshot_uid,
            draft.character_catalog_manifest_sha256,
            support_catalog.catalog_snapshot_uid,
            support_dataset.dataset_snapshot_uid,
            draft.support_catalog_manifest_sha256,
            draft.canonical_payload_json,
            draft.canonical_payload_sha256,
            draft.created_at_utc
        FROM lab_local_game.sanitized_profile_draft AS draft
        LEFT JOIN lab_local_game.sanitized_profile_draft AS previous
          ON previous.sanitized_profile_draft_id =
             draft.previous_sanitized_profile_draft_id
        JOIN lab_catalog.character_catalog_snapshot AS character_catalog
          ON character_catalog.character_catalog_snapshot_id =
             draft.character_catalog_snapshot_id
        JOIN lab_import.dataset_snapshot AS character_dataset
          ON character_dataset.dataset_snapshot_id =
             draft.character_dataset_snapshot_id
        JOIN lab_combat_support.catalog_snapshot AS support_catalog
          ON support_catalog.catalog_snapshot_id = draft.support_catalog_snapshot_id
        JOIN lab_import.dataset_snapshot AS support_dataset
          ON support_dataset.dataset_snapshot_id = draft.support_dataset_snapshot_id
        WHERE draft.sanitized_profile_draft_uid = @uid;
        """,
        connection);
    Add(command, "uid", NpgsqlDbType.Uuid, draftUid.Value);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
    if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      return null;
    }

    var schema = reader.GetString(2);
    var canonicalJson = SanitizedProfileJsonGuard.RequireSourceFreeObject(reader.GetString(12));
    var storedHash = Sha256Digest.FromBytes((byte[])reader.GetValue(13));
    if (!string.Equals(schema, SanitizedProfileDraftWrite.SchemaCode, StringComparison.Ordinal) ||
        Sha256Digest.ComputeUtf8(canonicalJson) != storedHash)
    {
      throw new LocalGameStateIntegrityException("sanitized_profile_draft_hash_mismatch");
    }

    return new SanitizedProfileDraftDocument(
        draftUid,
        ParseDraftKind(reader.GetString(0)),
        reader.IsDBNull(1) ? null : new EntityUid(reader.GetGuid(1)),
        schema,
        Sha256Digest.FromBytes((byte[])reader.GetValue(3)),
        Sha256Digest.FromBytes((byte[])reader.GetValue(4)),
        Sha256Digest.FromBytes((byte[])reader.GetValue(5)),
        new LocalProfileCatalogBindingWrite(
            new EntityUid(reader.GetGuid(6)),
            new EntityUid(reader.GetGuid(7)),
            Sha256Digest.FromBytes((byte[])reader.GetValue(8))),
        new LocalProfileCatalogBindingWrite(
            new EntityUid(reader.GetGuid(9)),
            new EntityUid(reader.GetGuid(10)),
            Sha256Digest.FromBytes((byte[])reader.GetValue(11))),
        canonicalJson,
        storedHash,
        reader.GetFieldValue<DateTimeOffset>(14));
  }

  public async Task<SanitizedProfileDraftDocument?> GetDraftByOperationAsync(
      EntityUid operationUid,
      CancellationToken cancellationToken = default)
  {
    LocalGameStateContractGuard.RequireUid(operationUid, "sanitized_import_operation_uid_invalid");
    await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken)
        .ConfigureAwait(false);
    await using var command = new NpgsqlCommand(
        """
        SELECT draft.sanitized_profile_draft_uid
        FROM lab_local_game.sanitized_import_operation AS operation
        JOIN lab_local_game.sanitized_profile_draft AS draft
          ON draft.sanitized_profile_draft_id = operation.result_draft_id
        WHERE operation.operation_uid = @uid;
        """,
        connection);
    Add(command, "uid", NpgsqlDbType.Uuid, operationUid.Value);
    var result = await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false);
    return result is Guid uid
        ? await GetDraftAsync(new EntityUid(uid), cancellationToken).ConfigureAwait(false)
        : null;
  }

  public async Task<ProfileDraftDiffDocument?> GetDiffAsync(
      EntityUid diffUid,
      CancellationToken cancellationToken = default)
  {
    LocalGameStateContractGuard.RequireUid(diffUid, "profile_draft_diff_uid_invalid");
    await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken)
        .ConfigureAwait(false);
    await using var command = new NpgsqlCommand(
        """
        SELECT
            diff.request_sha256,
            COALESCE(draft.sanitized_profile_draft_uid,
                     candidate.profile_edit_candidate_uid),
            account.local_account_uid,
            base.profile_template_revision_uid,
            diff.diff_contract_version,
            diff.canonical_diff_json,
            diff.canonical_diff_sha256,
            diff.change_count,
            diff.has_conflicts,
            diff.created_at_utc
        FROM lab_local_game.profile_draft_diff AS diff
        LEFT JOIN lab_local_game.sanitized_profile_draft AS draft
          ON draft.sanitized_profile_draft_id = diff.sanitized_profile_draft_id
        LEFT JOIN lab_local_game.profile_edit_candidate AS candidate
          ON candidate.profile_edit_candidate_id = diff.profile_edit_candidate_id
        LEFT JOIN lab_profile.local_account AS account
          ON account.local_account_id = diff.local_account_id
        LEFT JOIN lab_profile.profile_template_revision AS base
          ON base.profile_template_revision_id = diff.base_profile_template_revision_id
         AND base.local_account_id = diff.local_account_id
        WHERE diff.profile_draft_diff_uid = @uid;
        """,
        connection);
    Add(command, "uid", NpgsqlDbType.Uuid, diffUid.Value);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
    if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      return null;
    }

    var canonicalJson = SanitizedProfileJsonGuard.RequireSourceFreeObject(reader.GetString(5));
    var storedHash = Sha256Digest.FromBytes((byte[])reader.GetValue(6));
    if (Sha256Digest.ComputeUtf8(canonicalJson) != storedHash)
    {
      throw new LocalGameStateIntegrityException("profile_draft_diff_hash_mismatch");
    }

    return new ProfileDraftDiffDocument(
        diffUid,
        Sha256Digest.FromBytes((byte[])reader.GetValue(0)),
        new EntityUid(reader.GetGuid(1)),
        reader.IsDBNull(2) ? null : new EntityUid(reader.GetGuid(2)),
        reader.IsDBNull(3) ? null : new EntityUid(reader.GetGuid(3)),
        reader.GetString(4),
        canonicalJson,
        storedHash,
        reader.GetInt32(7),
        reader.GetBoolean(8),
        reader.GetFieldValue<DateTimeOffset>(9));
  }

  public async Task<ProfileDraftDiffDocument?> FindDiffAsync(
      EntityUid draftUid,
      EntityUid accountUid,
      EntityUid baseProfileTemplateRevisionUid,
      Sha256Digest diffSha256,
      CancellationToken cancellationToken = default)
  {
    LocalGameStateContractGuard.RequireUid(draftUid, "sanitized_profile_draft_uid_invalid");
    LocalGameStateContractGuard.RequireUid(accountUid, "local_game_account_uid_invalid");
    LocalGameStateContractGuard.RequireUid(
        baseProfileTemplateRevisionUid,
        "local_game_profile_revision_uid_invalid");
    if (diffSha256 == default)
    {
      throw new LocalGameStateIntegrityException("profile_draft_diff_hash_invalid");
    }

    await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken)
        .ConfigureAwait(false);
    await using var command = new NpgsqlCommand(
        """
        SELECT diff.profile_draft_diff_uid
        FROM lab_local_game.profile_draft_diff AS diff
        LEFT JOIN lab_local_game.sanitized_profile_draft AS draft
          ON draft.sanitized_profile_draft_id = diff.sanitized_profile_draft_id
        LEFT JOIN lab_local_game.profile_edit_candidate AS candidate
          ON candidate.profile_edit_candidate_id = diff.profile_edit_candidate_id
        JOIN lab_profile.local_account AS account
          ON account.local_account_id = diff.local_account_id
        JOIN lab_profile.profile_template_revision AS base
          ON base.profile_template_revision_id = diff.base_profile_template_revision_id
         AND base.local_account_id = diff.local_account_id
        WHERE COALESCE(draft.sanitized_profile_draft_uid,
                       candidate.profile_edit_candidate_uid) = @draft_uid
          AND account.local_account_uid = @account_uid
          AND base.profile_template_revision_uid = @base_uid
          AND diff.canonical_diff_sha256 = @diff_hash
        ORDER BY diff.profile_draft_diff_id DESC
        LIMIT 1;
        """,
        connection);
    Add(command, "draft_uid", NpgsqlDbType.Uuid, draftUid.Value);
    Add(command, "account_uid", NpgsqlDbType.Uuid, accountUid.Value);
    Add(command, "base_uid", NpgsqlDbType.Uuid, baseProfileTemplateRevisionUid.Value);
    Add(command, "diff_hash", NpgsqlDbType.Bytea, diffSha256.ToByteArray());
    var result = await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false);
    return result is Guid uid
        ? await GetDiffAsync(new EntityUid(uid), cancellationToken).ConfigureAwait(false)
        : null;
  }

  public async Task<ProfileDraftDiffDocument?> FindCreateDiffAsync(
      EntityUid draftUid,
      Sha256Digest diffSha256,
      CancellationToken cancellationToken = default)
  {
    LocalGameStateContractGuard.RequireUid(draftUid, "sanitized_profile_draft_uid_invalid");
    if (diffSha256 == default)
    {
      throw new LocalGameStateIntegrityException("profile_draft_diff_hash_invalid");
    }

    await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken)
        .ConfigureAwait(false);
    await using var command = new NpgsqlCommand(
        """
        SELECT diff.profile_draft_diff_uid
        FROM lab_local_game.profile_draft_diff AS diff
        JOIN lab_local_game.sanitized_profile_draft AS draft
          ON draft.sanitized_profile_draft_id = diff.sanitized_profile_draft_id
        WHERE draft.sanitized_profile_draft_uid = @draft_uid
          AND diff.profile_edit_candidate_id IS NULL
          AND diff.local_account_id IS NULL
          AND diff.base_profile_template_revision_id IS NULL
          AND diff.canonical_diff_sha256 = @diff_hash
        ORDER BY diff.profile_draft_diff_id DESC
        LIMIT 1;
        """,
        connection);
    Add(command, "draft_uid", NpgsqlDbType.Uuid, draftUid.Value);
    Add(command, "diff_hash", NpgsqlDbType.Bytea, diffSha256.ToByteArray());
    var result = await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false);
    return result is Guid uid
        ? await GetDiffAsync(new EntityUid(uid), cancellationToken).ConfigureAwait(false)
        : null;
  }

  public async Task<SanitizedProfileDraftReceipt> ImportDraftAsync(
      ImportSanitizedProfileDraftCommand command,
      CancellationToken cancellationToken = default)
  {
    ArgumentNullException.ThrowIfNull(command);
    await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken)
        .ConfigureAwait(false);
    await using var transaction = await connection.BeginTransactionAsync(
        IsolationLevel.ReadCommitted,
        cancellationToken).ConfigureAwait(false);
    try
    {
      await AcquireLockAsync(
          connection,
          transaction,
          command.OperationUid.ToString(),
          OperationLockSeed,
          cancellationToken).ConfigureAwait(false);
      var replay = await ReadImportOperationAsync(
          connection,
          transaction,
          command,
          cancellationToken).ConfigureAwait(false);
      if (replay is not null)
      {
        await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
        return replay;
      }

      var characterCatalog = await ResolveCatalogAsync(
          connection,
          transaction,
          command.Draft.CharacterCatalog,
          characterCatalog: true,
          cancellationToken).ConfigureAwait(false);
      var supportCatalog = await ResolveCatalogAsync(
          connection,
          transaction,
          command.Draft.CombatSupportCatalog,
          characterCatalog: false,
          cancellationToken).ConfigureAwait(false);
      long? previousDraftId = null;
      if (command.Draft.PreviousDraftUid is { } previousUid)
      {
        previousDraftId = await ResolveDraftIdAsync(
            connection,
            transaction,
            previousUid,
            cancellationToken).ConfigureAwait(false);
      }

      await AcquireLockAsync(
          connection,
          transaction,
          command.Draft.CanonicalPayloadSha256.ToString(),
          ContentLockSeed,
          cancellationToken).ConfigureAwait(false);
      var existingId = await FindDraftAsync(
          connection,
          transaction,
          command.Draft,
          previousDraftId,
          cancellationToken).ConfigureAwait(false);
      var contentReused = existingId.HasValue;
      var draftId = existingId ?? await InsertDraftAsync(
          connection,
          transaction,
          command.Draft,
          previousDraftId,
          characterCatalog,
          supportCatalog,
          command.CompletedAtUtc,
          cancellationToken).ConfigureAwait(false);
      await RecordImportOperationAsync(
          connection,
          transaction,
          command,
          draftId,
          contentReused,
          cancellationToken).ConfigureAwait(false);
      var result = await ReadDraftReceiptAsync(
          connection,
          transaction,
          command.OperationUid,
          draftId,
          isReplay: false,
          contentReused,
          cancellationToken).ConfigureAwait(false);
      await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
      return result;
    }
    catch (PostgresException exception)
    {
      throw MapDatabaseException(exception);
    }
  }

  public async Task<ProfileDraftDiffReceipt> CreateDiffAsync(
      CreateProfileDraftDiffCommand command,
      CancellationToken cancellationToken = default)
  {
    ArgumentNullException.ThrowIfNull(command);
    await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken)
        .ConfigureAwait(false);
    await using var transaction = await connection.BeginTransactionAsync(
        IsolationLevel.ReadCommitted,
        cancellationToken).ConfigureAwait(false);
    try
    {
      await AcquireLockAsync(
          connection,
          transaction,
          command.DiffUid.ToString(),
          OperationLockSeed,
          cancellationToken).ConfigureAwait(false);
      var replay = await ReadDiffByUidAsync(
          connection,
          transaction,
          command.DiffUid,
          command.RequestSha256,
          isReplay: true,
          cancellationToken).ConfigureAwait(false);
      if (replay is not null)
      {
        await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
        return replay;
      }

      var candidate = await ResolveCandidateDocumentIdAsync(
          connection,
          transaction,
          command.DraftUid,
          cancellationToken).ConfigureAwait(false);
      var profile = await LockCurrentProfileAsync(
          connection,
          transaction,
          command.AccountUid,
          command.ExpectedProfileTemplateRevisionUid,
          cancellationToken).ConfigureAwait(false);
      await using (var insert = new NpgsqlCommand(
          """
          INSERT INTO lab_local_game.profile_draft_diff (
              profile_draft_diff_uid,
              request_sha256,
              sanitized_profile_draft_id,
              profile_edit_candidate_id,
              local_account_id,
              base_profile_template_revision_id,
              diff_contract_version,
              canonical_diff_json,
              canonical_diff_sha256,
              change_count,
              has_conflicts,
              created_at_utc
          ) VALUES (
              @uid, @request_hash, @draft_id, @edit_candidate_id,
              @account_id, @profile_id,
              @contract_version, @canonical_json, @diff_hash,
              @change_count, @has_conflicts, @created_at
          );
          """,
          connection,
          transaction))
      {
        Add(insert, "uid", NpgsqlDbType.Uuid, command.DiffUid.Value);
        Add(insert, "request_hash", NpgsqlDbType.Bytea, command.RequestSha256.ToByteArray());
        Add(insert, "draft_id", NpgsqlDbType.Bigint, candidate.SanitizedDraftId);
        Add(insert, "edit_candidate_id", NpgsqlDbType.Bigint, candidate.EditCandidateId);
        Add(insert, "account_id", NpgsqlDbType.Bigint, profile.AccountId);
        Add(insert, "profile_id", NpgsqlDbType.Bigint, profile.ProfileRevisionId);
        Add(insert, "contract_version", NpgsqlDbType.Text, command.Diff.ContractVersion);
        Add(insert, "canonical_json", NpgsqlDbType.Text, command.Diff.CanonicalDiffJson);
        Add(insert, "diff_hash", NpgsqlDbType.Bytea,
            command.Diff.CanonicalDiffSha256.ToByteArray());
        Add(insert, "change_count", NpgsqlDbType.Integer, command.Diff.ChangeCount);
        Add(insert, "has_conflicts", NpgsqlDbType.Boolean, command.Diff.HasConflicts);
        Add(insert, "created_at", NpgsqlDbType.TimestampTz, command.CreatedAtUtc);
        await insert.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
      }

      var result = await ReadDiffByUidAsync(
          connection,
          transaction,
          command.DiffUid,
          command.RequestSha256,
          isReplay: false,
          cancellationToken).ConfigureAwait(false) ??
          throw new LocalGameStateIntegrityException("profile_draft_diff_not_found");
      await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
      return result;
    }
    catch (PostgresException exception)
    {
      throw MapDatabaseException(exception);
    }
  }

  public async Task<ProfileDraftDiffReceipt> CreateImportDiffAsync(
      CreateImportProfileDraftDiffCommand command,
      CancellationToken cancellationToken = default)
  {
    ArgumentNullException.ThrowIfNull(command);
    await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken)
        .ConfigureAwait(false);
    await using var transaction = await connection.BeginTransactionAsync(
        IsolationLevel.ReadCommitted,
        cancellationToken).ConfigureAwait(false);
    try
    {
      await AcquireLockAsync(
          connection,
          transaction,
          command.DiffUid.ToString(),
          OperationLockSeed,
          cancellationToken).ConfigureAwait(false);
      var replay = await ReadDiffByUidAsync(
          connection,
          transaction,
          command.DiffUid,
          command.RequestSha256,
          isReplay: true,
          cancellationToken).ConfigureAwait(false);
      if (replay is not null)
      {
        if (replay.AccountUid is not null || replay.BaseProfileTemplateRevisionUid is not null)
        {
          throw new LocalGameStateIntegrityException("profile_draft_diff_topology_invalid");
        }

        await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
        return replay;
      }

      var draftId = await ResolveDraftIdAsync(
          connection,
          transaction,
          command.DraftUid,
          cancellationToken).ConfigureAwait(false);
      await using (var insert = new NpgsqlCommand(
          """
          INSERT INTO lab_local_game.profile_draft_diff (
              profile_draft_diff_uid,
              request_sha256,
              sanitized_profile_draft_id,
              profile_edit_candidate_id,
              local_account_id,
              base_profile_template_revision_id,
              diff_contract_version,
              canonical_diff_json,
              canonical_diff_sha256,
              change_count,
              has_conflicts,
              created_at_utc
          ) VALUES (
              @uid, @request_hash, @draft_id, NULL, NULL, NULL,
              @contract_version, @canonical_json, @diff_hash,
              @change_count, @has_conflicts, @created_at
          );
          """,
          connection,
          transaction))
      {
        Add(insert, "uid", NpgsqlDbType.Uuid, command.DiffUid.Value);
        Add(insert, "request_hash", NpgsqlDbType.Bytea, command.RequestSha256.ToByteArray());
        Add(insert, "draft_id", NpgsqlDbType.Bigint, draftId);
        Add(insert, "contract_version", NpgsqlDbType.Text, command.Diff.ContractVersion);
        Add(insert, "canonical_json", NpgsqlDbType.Text, command.Diff.CanonicalDiffJson);
        Add(insert, "diff_hash", NpgsqlDbType.Bytea,
            command.Diff.CanonicalDiffSha256.ToByteArray());
        Add(insert, "change_count", NpgsqlDbType.Integer, command.Diff.ChangeCount);
        Add(insert, "has_conflicts", NpgsqlDbType.Boolean, command.Diff.HasConflicts);
        Add(insert, "created_at", NpgsqlDbType.TimestampTz, command.CreatedAtUtc);
        await insert.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
      }

      var result = await ReadDiffByUidAsync(
          connection,
          transaction,
          command.DiffUid,
          command.RequestSha256,
          isReplay: false,
          cancellationToken).ConfigureAwait(false) ??
          throw new LocalGameStateIntegrityException("profile_draft_diff_not_found");
      await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
      return result;
    }
    catch (PostgresException exception)
    {
      throw MapDatabaseException(exception);
    }
  }

  public async Task<ProfileDraftApplicationIntentReceipt> BeginApplicationAsync(
      LinkProfileDraftApplicationCommand command,
      CancellationToken cancellationToken = default)
  {
    ArgumentNullException.ThrowIfNull(command);
    await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken)
        .ConfigureAwait(false);
    await using var transaction = await connection.BeginTransactionAsync(
        IsolationLevel.ReadCommitted,
        cancellationToken).ConfigureAwait(false);
    try
    {
      await AcquireLockAsync(
          connection,
          transaction,
          command.ApplicationUid.ToString(),
          OperationLockSeed,
          cancellationToken).ConfigureAwait(false);
      var replay = await ReadApplicationIntentAsync(
          connection,
          transaction,
          command,
          isReplay: true,
          cancellationToken).ConfigureAwait(false);
      if (replay is not null)
      {
        await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
        return replay;
      }

      var diffId = await ResolveDiffIdAsync(
          connection,
          transaction,
          command.DiffUid,
          cancellationToken).ConfigureAwait(false);
      await using (var insert = new NpgsqlCommand(
          """
          INSERT INTO lab_local_game.profile_draft_application_intent (
              application_uid,
              request_sha256,
              application_kind,
              profile_draft_diff_id,
              profile_write_operation_uid,
              requested_at_utc
          ) VALUES (
              @uid, @request_hash, @kind, @diff_id, @write_operation_uid,
              @requested_at
          );
          """,
          connection,
          transaction))
      {
        Add(insert, "uid", NpgsqlDbType.Uuid, command.ApplicationUid.Value);
        Add(insert, "request_hash", NpgsqlDbType.Bytea, command.RequestSha256.ToByteArray());
        Add(insert, "kind", NpgsqlDbType.Text, ApplicationKindCode(command.ApplicationKind));
        Add(insert, "diff_id", NpgsqlDbType.Bigint, diffId);
        Add(insert, "write_operation_uid", NpgsqlDbType.Uuid,
            command.ProfileWriteOperationUid.Value);
        Add(insert, "requested_at", NpgsqlDbType.TimestampTz, command.AppliedAtUtc);
        await insert.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
      }

      var result = await ReadApplicationIntentAsync(
          connection,
          transaction,
          command,
          isReplay: false,
          cancellationToken).ConfigureAwait(false) ??
          throw new LocalGameStateIntegrityException("profile_draft_application_intent_not_found");
      await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
      return result;
    }
    catch (PostgresException exception)
    {
      throw MapDatabaseException(exception);
    }
  }

  public async Task<ProfileDraftApplicationIntentReceipt?> GetApplicationIntentAsync(
      EntityUid applicationUid,
      CancellationToken cancellationToken = default)
  {
    LocalGameStateContractGuard.RequireUid(
        applicationUid,
        "profile_draft_application_uid_invalid");
    await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken)
        .ConfigureAwait(false);
    await using var command = new NpgsqlCommand(
        """
        SELECT intent.request_sha256,
               intent.application_kind,
               diff.profile_draft_diff_uid,
               intent.profile_write_operation_uid,
               intent.requested_at_utc
        FROM lab_local_game.profile_draft_application_intent AS intent
        JOIN lab_local_game.profile_draft_diff AS diff
          ON diff.profile_draft_diff_id = intent.profile_draft_diff_id
        WHERE intent.application_uid = @uid;
        """,
        connection);
    Add(command, "uid", NpgsqlDbType.Uuid, applicationUid.Value);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken)
        .ConfigureAwait(false);
    if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      return null;
    }

    var kind = ParseApplicationKind(reader.GetString(1));
    var diffUid = new EntityUid(reader.GetGuid(2));
    var writeOperationUid = new EntityUid(reader.GetGuid(3));
    var requestedAtUtc = reader.GetFieldValue<DateTimeOffset>(4);
    var canonical = new LinkProfileDraftApplicationCommand(
        applicationUid,
        kind,
        diffUid,
        writeOperationUid,
        requestedAtUtc);
    if (canonical.RequestSha256 != Sha256Digest.FromBytes((byte[])reader.GetValue(0)))
    {
      throw new LocalGameStateIntegrityException(
          "profile_draft_application_intent_hash_mismatch");
    }

    return new ProfileDraftApplicationIntentReceipt(
        applicationUid,
        true,
        kind,
        diffUid,
        writeOperationUid,
        requestedAtUtc);
  }

  public async Task<ProfileDraftApplicationReceipt?> TryRecoverApplicationAsync(
      EntityUid applicationUid,
      ProfileDraftApplicationKind applicationKind,
      EntityUid diffUid,
      EntityUid profileWriteOperationUid,
      CancellationToken cancellationToken = default)
  {
    LocalGameStateContractGuard.RequireUid(
        applicationUid,
        "profile_draft_application_uid_invalid");
    LocalGameStateContractGuard.RequireUid(diffUid, "profile_draft_diff_uid_invalid");
    LocalGameStateContractGuard.RequireUid(
        profileWriteOperationUid,
        "profile_write_operation_uid_invalid");
    if (!Enum.IsDefined(applicationKind))
    {
      throw new LocalGameStateIntegrityException("profile_draft_application_kind_invalid");
    }

    DateTimeOffset requestedAt;
    Sha256Digest requestHash;
    bool writeExists;
    await using (var connection = await _dataSource.OpenConnectionAsync(cancellationToken)
        .ConfigureAwait(false))
    await using (var command = new NpgsqlCommand(
        """
        SELECT intent.application_kind,
               diff.profile_draft_diff_uid,
               intent.profile_write_operation_uid,
               intent.requested_at_utc,
               intent.request_sha256,
               EXISTS (
                   SELECT 1
                   FROM lab_profile.profile_write_operation AS operation
                   WHERE operation.operation_uid = intent.profile_write_operation_uid
               )
        FROM lab_local_game.profile_draft_application_intent AS intent
        JOIN lab_local_game.profile_draft_diff AS diff
          ON diff.profile_draft_diff_id = intent.profile_draft_diff_id
        WHERE intent.application_uid = @application_uid;
        """,
        connection))
    {
      Add(command, "application_uid", NpgsqlDbType.Uuid, applicationUid.Value);
      await using var reader = await command.ExecuteReaderAsync(cancellationToken)
          .ConfigureAwait(false);
      if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
      {
        return null;
      }

      if (ParseApplicationKind(reader.GetString(0)) != applicationKind ||
          new EntityUid(reader.GetGuid(1)) != diffUid ||
          new EntityUid(reader.GetGuid(2)) != profileWriteOperationUid)
      {
        throw new LocalGameStateIntegrityException(
            "profile_draft_application_intent_reuse_mismatch");
      }

      requestedAt = reader.GetFieldValue<DateTimeOffset>(3);
      requestHash = Sha256Digest.FromBytes((byte[])reader.GetValue(4));
      writeExists = reader.GetBoolean(5);
    }

    var link = new LinkProfileDraftApplicationCommand(
        applicationUid,
        applicationKind,
        diffUid,
        profileWriteOperationUid,
        requestedAt);
    if (link.RequestSha256 != requestHash)
    {
      throw new LocalGameStateIntegrityException(
          "profile_draft_application_intent_reuse_mismatch");
    }

    return writeExists
        ? await LinkApplicationAsync(link, cancellationToken).ConfigureAwait(false)
        : null;
  }

  public async Task<ProfileDraftApplicationReceipt> LinkApplicationAsync(
      LinkProfileDraftApplicationCommand command,
      CancellationToken cancellationToken = default)
  {
    ArgumentNullException.ThrowIfNull(command);
    await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken)
        .ConfigureAwait(false);
    await using var transaction = await connection.BeginTransactionAsync(
        IsolationLevel.ReadCommitted,
        cancellationToken).ConfigureAwait(false);
    try
    {
      await AcquireLockAsync(
          connection,
          transaction,
          command.ApplicationUid.ToString(),
          OperationLockSeed,
          cancellationToken).ConfigureAwait(false);
      var replay = await ReadApplicationAsync(
          connection,
          transaction,
          command.ApplicationUid,
          command.RequestSha256,
          isReplay: true,
          cancellationToken).ConfigureAwait(false);
      if (replay is not null)
      {
        await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
        return replay;
      }

      var intentId = await ResolveApplicationIntentIdAsync(
          connection,
          transaction,
          command,
          cancellationToken).ConfigureAwait(false);

      var diffId = await ResolveDiffIdAsync(
          connection,
          transaction,
          command.DiffUid,
          cancellationToken).ConfigureAwait(false);
      var diff = await ReadDiffTopologyAsync(
          connection,
          transaction,
          diffId,
          cancellationToken).ConfigureAwait(false);
      var write = await ResolveProfileWriteOperationAsync(
          connection,
          transaction,
          command.ProfileWriteOperationUid,
          cancellationToken).ConfigureAwait(false);
      ValidateApplicationTopology(command.ApplicationKind, diff, write);
      await using (var insert = new NpgsqlCommand(
          """
          INSERT INTO lab_local_game.profile_draft_application (
              application_uid,
              request_sha256,
              profile_draft_application_intent_id,
              application_kind,
              profile_draft_diff_id,
              profile_write_operation_id,
              profile_write_operation_uid,
              source_local_account_id,
              source_base_profile_template_revision_id,
              result_local_account_id,
              result_profile_template_revision_id,
              applied_at_utc
          ) VALUES (
              @uid, @request_hash, @intent_id, @kind, @diff_id, @write_operation_id,
              @write_operation_uid,
              @source_account_id, @source_base_revision_id, @result_account_id,
              @result_revision_id, @applied_at
          );
          """,
          connection,
          transaction))
      {
        Add(insert, "uid", NpgsqlDbType.Uuid, command.ApplicationUid.Value);
        Add(insert, "request_hash", NpgsqlDbType.Bytea, command.RequestSha256.ToByteArray());
        Add(insert, "intent_id", NpgsqlDbType.Bigint, intentId);
        Add(insert, "kind", NpgsqlDbType.Text, ApplicationKindCode(command.ApplicationKind));
        Add(insert, "diff_id", NpgsqlDbType.Bigint, diffId);
        Add(insert, "write_operation_id", NpgsqlDbType.Bigint, write.OperationId);
        Add(insert, "write_operation_uid", NpgsqlDbType.Uuid,
            command.ProfileWriteOperationUid.Value);
        Add(insert, "source_account_id", NpgsqlDbType.Bigint, diff.AccountId);
        Add(insert, "source_base_revision_id", NpgsqlDbType.Bigint, diff.BaseRevisionId);
        Add(insert, "result_account_id", NpgsqlDbType.Bigint, write.AccountId);
        Add(insert, "result_revision_id", NpgsqlDbType.Bigint, write.ResultRevisionId);
        Add(insert, "applied_at", NpgsqlDbType.TimestampTz, command.AppliedAtUtc);
        await insert.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
      }

      var result = await ReadApplicationAsync(
          connection,
          transaction,
          command.ApplicationUid,
          command.RequestSha256,
          isReplay: false,
          cancellationToken).ConfigureAwait(false) ??
          throw new LocalGameStateIntegrityException("profile_draft_application_not_found");
      await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
      return result;
    }
    catch (PostgresException exception)
    {
      throw MapDatabaseException(exception);
    }
  }

  private async Task<long> InsertDraftAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      SanitizedProfileDraftWrite draft,
      long? previousDraftId,
      CatalogRow characterCatalog,
      CatalogRow supportCatalog,
      DateTimeOffset createdAtUtc,
      CancellationToken cancellationToken)
  {
    var uid = _uidGenerator.NewUid();
    await using var command = new NpgsqlCommand(
        """
        INSERT INTO lab_local_game.sanitized_profile_draft (
            sanitized_profile_draft_uid,
            derivation_kind,
            previous_sanitized_profile_draft_id,
            payload_schema_code,
            sanitizer_contract_sha256,
            transformer_sha256,
            semantic_options_sha256,
            character_catalog_snapshot_id,
            character_dataset_snapshot_id,
            character_catalog_manifest_sha256,
            support_catalog_snapshot_id,
            support_dataset_snapshot_id,
            support_catalog_manifest_sha256,
            canonical_payload_json,
            canonical_payload_sha256,
            created_at_utc
        ) VALUES (
            @uid, @kind, @previous_id, @schema_code,
            @sanitizer_hash, @transformer_hash, @options_hash,
            @character_catalog_id, @character_dataset_id, @character_manifest,
            @support_catalog_id, @support_dataset_id, @support_manifest,
            @canonical_json, @payload_hash, @created_at
        )
        RETURNING sanitized_profile_draft_id;
        """,
        connection,
        transaction);
    Add(command, "uid", NpgsqlDbType.Uuid, uid.Value);
    Add(command, "kind", NpgsqlDbType.Text, DraftKindCode(draft.DerivationKind));
    Add(command, "previous_id", NpgsqlDbType.Bigint, previousDraftId);
    Add(command, "schema_code", NpgsqlDbType.Text, SanitizedProfileDraftWrite.SchemaCode);
    Add(command, "sanitizer_hash", NpgsqlDbType.Bytea,
        draft.SanitizerContractSha256.ToByteArray());
    Add(command, "transformer_hash", NpgsqlDbType.Bytea, draft.TransformerSha256.ToByteArray());
    Add(command, "options_hash", NpgsqlDbType.Bytea, draft.SemanticOptionsSha256.ToByteArray());
    Add(command, "character_catalog_id", NpgsqlDbType.Bigint, characterCatalog.Id);
    Add(command, "character_dataset_id", NpgsqlDbType.Bigint, characterCatalog.DatasetId);
    Add(command, "character_manifest", NpgsqlDbType.Bytea,
        draft.CharacterCatalog.CatalogManifestSha256.ToByteArray());
    Add(command, "support_catalog_id", NpgsqlDbType.Bigint, supportCatalog.Id);
    Add(command, "support_dataset_id", NpgsqlDbType.Bigint, supportCatalog.DatasetId);
    Add(command, "support_manifest", NpgsqlDbType.Bytea,
        draft.CombatSupportCatalog.CatalogManifestSha256.ToByteArray());
    Add(command, "canonical_json", NpgsqlDbType.Text, draft.CanonicalPayloadJson);
    Add(command, "payload_hash", NpgsqlDbType.Bytea, draft.CanonicalPayloadSha256.ToByteArray());
    Add(command, "created_at", NpgsqlDbType.TimestampTz, createdAtUtc);
    return Convert.ToInt64(
        await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false),
        CultureInfo.InvariantCulture);
  }

  private static async Task<CatalogRow> ResolveCatalogAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      LocalProfileCatalogBindingWrite binding,
      bool characterCatalog,
      CancellationToken cancellationToken)
  {
    var sql = characterCatalog
        ? """
          SELECT catalog.character_catalog_snapshot_id, catalog.dataset_snapshot_id
          FROM lab_catalog.character_catalog_snapshot AS catalog
          JOIN lab_import.dataset_snapshot AS dataset
            ON dataset.dataset_snapshot_id = catalog.dataset_snapshot_id
          WHERE catalog.character_catalog_snapshot_uid = @catalog_uid
            AND dataset.dataset_snapshot_uid = @dataset_uid
            AND catalog.catalog_manifest_sha256 = @manifest;
          """
        : """
          SELECT catalog.catalog_snapshot_id, catalog.dataset_snapshot_id
          FROM lab_combat_support.catalog_snapshot AS catalog
          JOIN lab_import.dataset_snapshot AS dataset
            ON dataset.dataset_snapshot_id = catalog.dataset_snapshot_id
          WHERE catalog.catalog_snapshot_uid = @catalog_uid
            AND dataset.dataset_snapshot_uid = @dataset_uid
            AND catalog.catalog_manifest_sha256 = @manifest;
          """;
    await using var command = new NpgsqlCommand(sql, connection, transaction);
    AddCatalog(command, binding);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
    if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      throw new LocalGameStateIntegrityException(
          characterCatalog
              ? "sanitized_import_character_catalog_invalid"
              : "sanitized_import_support_catalog_invalid");
    }

    return new CatalogRow(reader.GetInt64(0), reader.GetInt64(1));
  }

  private static async Task<long?> FindDraftAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      SanitizedProfileDraftWrite draft,
      long? previousDraftId,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        SELECT sanitized_profile_draft_id
        FROM lab_local_game.sanitized_profile_draft
        WHERE derivation_kind = @kind
          AND previous_sanitized_profile_draft_id IS NOT DISTINCT FROM @previous_id
          AND payload_schema_code = @schema_code
          AND sanitizer_contract_sha256 = @sanitizer_hash
          AND transformer_sha256 = @transformer_hash
          AND semantic_options_sha256 = @options_hash
          AND canonical_payload_sha256 = @payload_hash;
        """,
        connection,
        transaction);
    Add(command, "kind", NpgsqlDbType.Text, DraftKindCode(draft.DerivationKind));
    Add(command, "previous_id", NpgsqlDbType.Bigint, previousDraftId);
    Add(command, "schema_code", NpgsqlDbType.Text, SanitizedProfileDraftWrite.SchemaCode);
    Add(command, "sanitizer_hash", NpgsqlDbType.Bytea,
        draft.SanitizerContractSha256.ToByteArray());
    Add(command, "transformer_hash", NpgsqlDbType.Bytea, draft.TransformerSha256.ToByteArray());
    Add(command, "options_hash", NpgsqlDbType.Bytea, draft.SemanticOptionsSha256.ToByteArray());
    Add(command, "payload_hash", NpgsqlDbType.Bytea, draft.CanonicalPayloadSha256.ToByteArray());
    var value = await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false);
    return value is null ? null : Convert.ToInt64(value, CultureInfo.InvariantCulture);
  }

  private static async Task<long> ResolveDraftIdAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      EntityUid draftUid,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        SELECT sanitized_profile_draft_id
        FROM lab_local_game.sanitized_profile_draft
        WHERE sanitized_profile_draft_uid = @uid;
        """,
        connection,
        transaction);
    Add(command, "uid", NpgsqlDbType.Uuid, draftUid.Value);
    var value = await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false);
    if (value is null)
    {
      throw new LocalGameStateIntegrityException("sanitized_profile_draft_not_found");
    }

    return Convert.ToInt64(value, CultureInfo.InvariantCulture);
  }

  private static async Task<CandidateDocumentIds> ResolveCandidateDocumentIdAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      EntityUid candidateUid,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        SELECT sanitized_profile_draft_id, NULL::bigint
        FROM lab_local_game.sanitized_profile_draft
        WHERE sanitized_profile_draft_uid = @uid
        UNION ALL
        SELECT NULL::bigint, profile_edit_candidate_id
        FROM lab_local_game.profile_edit_candidate
        WHERE profile_edit_candidate_uid = @uid;
        """,
        connection,
        transaction);
    Add(command, "uid", NpgsqlDbType.Uuid, candidateUid.Value);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
    if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      throw new LocalGameStateIntegrityException("profile_candidate_not_found");
    }

    var result = new CandidateDocumentIds(
        reader.IsDBNull(0) ? null : reader.GetInt64(0),
        reader.IsDBNull(1) ? null : reader.GetInt64(1));
    if (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      throw new LocalGameStateIntegrityException("profile_candidate_uid_ambiguous");
    }

    return result;
  }

  private static async Task<SanitizedProfileDraftReceipt?> ReadImportOperationAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      ImportSanitizedProfileDraftCommand command,
      CancellationToken cancellationToken)
  {
    await using var read = new NpgsqlCommand(
        """
        SELECT operation_kind, request_sha256, result_draft_id, result_status
        FROM lab_local_game.sanitized_import_operation
        WHERE operation_uid = @operation_uid;
        """,
        connection,
        transaction);
    Add(read, "operation_uid", NpgsqlDbType.Uuid, command.OperationUid.Value);
    await using var reader = await read.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
    if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      return null;
    }

    var expectedKind = ImportOperationKind(command.Draft.DerivationKind);
    var storedHash = Sha256Digest.FromBytes((byte[])reader.GetValue(1));
    if (reader.GetString(0) != expectedKind || storedHash != command.RequestSha256)
    {
      throw new LocalGameStateIntegrityException("sanitized_import_operation_reuse_mismatch");
    }

    var draftId = reader.GetInt64(2);
    var reused = reader.GetString(3) == "reused";
    await reader.DisposeAsync().ConfigureAwait(false);
    return await ReadDraftReceiptAsync(
        connection,
        transaction,
        command.OperationUid,
        draftId,
        isReplay: true,
        reused,
        cancellationToken).ConfigureAwait(false);
  }

  private static async Task RecordImportOperationAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      ImportSanitizedProfileDraftCommand command,
      long draftId,
      bool reused,
      CancellationToken cancellationToken)
  {
    await using var insert = new NpgsqlCommand(
        """
        INSERT INTO lab_local_game.sanitized_import_operation (
            operation_uid,
            operation_kind,
            request_sha256,
            result_draft_id,
            result_status,
            completed_at_utc
        ) VALUES (@uid, @kind, @request_hash, @draft_id, @status, @completed_at);
        """,
        connection,
        transaction);
    Add(insert, "uid", NpgsqlDbType.Uuid, command.OperationUid.Value);
    Add(insert, "kind", NpgsqlDbType.Text,
        ImportOperationKind(command.Draft.DerivationKind));
    Add(insert, "request_hash", NpgsqlDbType.Bytea, command.RequestSha256.ToByteArray());
    Add(insert, "draft_id", NpgsqlDbType.Bigint, draftId);
    Add(insert, "status", NpgsqlDbType.Text, reused ? "reused" : "succeeded");
    Add(insert, "completed_at", NpgsqlDbType.TimestampTz, command.CompletedAtUtc);
    await insert.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
  }

  private static async Task<SanitizedProfileDraftReceipt> ReadDraftReceiptAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      EntityUid operationUid,
      long draftId,
      bool isReplay,
      bool contentReused,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        SELECT
            draft.sanitized_profile_draft_uid,
            draft.derivation_kind,
            previous.sanitized_profile_draft_uid,
            draft.payload_schema_code,
            draft.sanitizer_contract_sha256,
            draft.transformer_sha256,
            draft.semantic_options_sha256,
            draft.canonical_payload_sha256,
            draft.created_at_utc
        FROM lab_local_game.sanitized_profile_draft AS draft
        LEFT JOIN lab_local_game.sanitized_profile_draft AS previous
          ON previous.sanitized_profile_draft_id =
             draft.previous_sanitized_profile_draft_id
        WHERE draft.sanitized_profile_draft_id = @draft_id;
        """,
        connection,
        transaction);
    Add(command, "draft_id", NpgsqlDbType.Bigint, draftId);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
    if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      throw new LocalGameStateIntegrityException("sanitized_profile_draft_not_found");
    }

    return new SanitizedProfileDraftReceipt(
        operationUid,
        isReplay,
        contentReused,
        new EntityUid(reader.GetGuid(0)),
        ParseDraftKind(reader.GetString(1)),
        reader.IsDBNull(2) ? null : new EntityUid(reader.GetGuid(2)),
        reader.GetString(3),
        Sha256Digest.FromBytes((byte[])reader.GetValue(4)),
        Sha256Digest.FromBytes((byte[])reader.GetValue(5)),
        Sha256Digest.FromBytes((byte[])reader.GetValue(6)),
        Sha256Digest.FromBytes((byte[])reader.GetValue(7)),
        reader.GetFieldValue<DateTimeOffset>(8));
  }

  private static async Task<ProfileDraftDiffReceipt?> ReadDiffByUidAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      EntityUid diffUid,
      Sha256Digest requestSha256,
      bool isReplay,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        SELECT
            diff.request_sha256,
            COALESCE(draft.sanitized_profile_draft_uid,
                     candidate.profile_edit_candidate_uid),
            account.local_account_uid,
            profile.profile_template_revision_uid,
            diff.diff_contract_version,
            diff.canonical_diff_sha256,
            diff.change_count,
            diff.has_conflicts,
            diff.created_at_utc
        FROM lab_local_game.profile_draft_diff AS diff
        LEFT JOIN lab_local_game.sanitized_profile_draft AS draft
          ON draft.sanitized_profile_draft_id = diff.sanitized_profile_draft_id
        LEFT JOIN lab_local_game.profile_edit_candidate AS candidate
          ON candidate.profile_edit_candidate_id = diff.profile_edit_candidate_id
        LEFT JOIN lab_profile.local_account AS account
          ON account.local_account_id = diff.local_account_id
        LEFT JOIN lab_profile.profile_template_revision AS profile
          ON profile.profile_template_revision_id =
             diff.base_profile_template_revision_id
        WHERE diff.profile_draft_diff_uid = @uid;
        """,
        connection,
        transaction);
    Add(command, "uid", NpgsqlDbType.Uuid, diffUid.Value);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
    if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      return null;
    }

    if (Sha256Digest.FromBytes((byte[])reader.GetValue(0)) != requestSha256)
    {
      throw new LocalGameStateIntegrityException("profile_draft_diff_reuse_mismatch");
    }

    return new ProfileDraftDiffReceipt(
        diffUid,
        isReplay,
        new EntityUid(reader.GetGuid(1)),
        reader.IsDBNull(2) ? null : new EntityUid(reader.GetGuid(2)),
        reader.IsDBNull(3) ? null : new EntityUid(reader.GetGuid(3)),
        reader.GetString(4),
        Sha256Digest.FromBytes((byte[])reader.GetValue(5)),
        reader.GetInt32(6),
        reader.GetBoolean(7),
        reader.GetFieldValue<DateTimeOffset>(8));
  }

  private static async Task<CurrentProfileRow> LockCurrentProfileAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      EntityUid accountUid,
      EntityUid expectedProfileRevisionUid,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        SELECT
            account.local_account_id,
            profile.profile_template_revision_id,
            profile.profile_template_revision_uid
        FROM lab_profile.local_account AS account
        JOIN lab_profile.profile_template_revision AS profile
          ON profile.profile_template_revision_id =
             account.current_profile_template_revision_id
        WHERE account.local_account_uid = @account_uid
        FOR UPDATE OF account;
        """,
        connection,
        transaction);
    Add(command, "account_uid", NpgsqlDbType.Uuid, accountUid.Value);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
    if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      throw new LocalGameStateIntegrityException("local_game_account_not_found");
    }

    var result = new CurrentProfileRow(
        reader.GetInt64(0),
        reader.GetInt64(1),
        new EntityUid(reader.GetGuid(2)));
    if (result.ProfileRevisionUid != expectedProfileRevisionUid)
    {
      throw new LocalGameStateIntegrityException("local_game_profile_revision_conflict");
    }

    return result;
  }

  private static Task<ProfileEditCandidateDocument?> ReadEditCandidateByOperationAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      EntityUid operationUid,
      CancellationToken cancellationToken) => ReadEditCandidateAsync(
          connection,
          transaction,
          candidateUid: null,
          operationUid,
          cancellationToken);

  private static async Task<ProfileEditCandidateDocument?> ReadEditCandidateAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction? transaction,
      EntityUid? candidateUid,
      EntityUid? operationUid,
      CancellationToken cancellationToken)
  {
    if ((candidateUid is null) == (operationUid is null))
    {
      throw new ArgumentException("Exactly one editor-candidate lookup key is required.");
    }

    await using var command = new NpgsqlCommand(
        """
        SELECT
            candidate.profile_edit_candidate_uid,
            candidate.operation_uid,
            candidate.request_sha256,
            account.local_account_uid,
            base.profile_template_revision_uid,
            candidate.candidate_contract_version,
            candidate.canonical_operations_json,
            candidate.canonical_operations_sha256,
            candidate.operation_count,
            candidate.created_at_utc
        FROM lab_local_game.profile_edit_candidate AS candidate
        JOIN lab_profile.local_account AS account
          ON account.local_account_id = candidate.local_account_id
        JOIN lab_profile.profile_template_revision AS base
          ON base.profile_template_revision_id = candidate.base_profile_template_revision_id
         AND base.local_account_id = candidate.local_account_id
        WHERE (@candidate_uid IS NOT NULL
               AND candidate.profile_edit_candidate_uid = @candidate_uid)
           OR (@operation_uid IS NOT NULL
               AND candidate.operation_uid = @operation_uid);
        """,
        connection,
        transaction);
    Add(command, "candidate_uid", NpgsqlDbType.Uuid, candidateUid?.Value);
    Add(command, "operation_uid", NpgsqlDbType.Uuid, operationUid?.Value);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
    if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      return null;
    }

    var canonical = SanitizedProfileJsonGuard.RequireSourceFreeObject(reader.GetString(6));
    var storedHash = Sha256Digest.FromBytes((byte[])reader.GetValue(7));
    if (Sha256Digest.ComputeUtf8(canonical) != storedHash ||
        reader.GetString(5) != "nll/profile-edit-candidate/v1")
    {
      throw new LocalGameStateIntegrityException("profile_edit_candidate_hash_mismatch");
    }

    return new ProfileEditCandidateDocument(
        new EntityUid(reader.GetGuid(0)),
        new EntityUid(reader.GetGuid(1)),
        Sha256Digest.FromBytes((byte[])reader.GetValue(2)),
        new EntityUid(reader.GetGuid(3)),
        new EntityUid(reader.GetGuid(4)),
        reader.GetString(5),
        canonical,
        storedHash,
        reader.GetInt32(8),
        reader.GetFieldValue<DateTimeOffset>(9));
  }

  private static async Task<long> ResolveDiffIdAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      EntityUid diffUid,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        "SELECT profile_draft_diff_id FROM lab_local_game.profile_draft_diff WHERE profile_draft_diff_uid = @uid;",
        connection,
        transaction);
    Add(command, "uid", NpgsqlDbType.Uuid, diffUid.Value);
    var value = await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false);
    if (value is null)
    {
      throw new LocalGameStateIntegrityException("profile_draft_diff_not_found");
    }

    return Convert.ToInt64(value, CultureInfo.InvariantCulture);
  }

  private static async Task<ProfileWriteRow> ResolveProfileWriteOperationAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      EntityUid operationUid,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        SELECT
            operation.profile_write_operation_id,
            operation.local_account_id,
            operation.result_profile_template_revision_id,
            operation.operation_kind,
            operation.expected_profile_template_revision_uid
        FROM lab_profile.profile_write_operation AS operation
        WHERE operation.operation_uid = @uid;
        """,
        connection,
        transaction);
    Add(command, "uid", NpgsqlDbType.Uuid, operationUid.Value);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
    if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      throw new LocalGameStateIntegrityException("profile_write_operation_not_found");
    }

    return new ProfileWriteRow(
        reader.GetInt64(0),
        reader.GetInt64(1),
        reader.GetInt64(2),
        reader.GetString(3),
        reader.IsDBNull(4) ? null : new EntityUid(reader.GetGuid(4)));
  }

  private static async Task<DiffTopologyRow> ReadDiffTopologyAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      long diffId,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        SELECT diff.local_account_id,
               diff.base_profile_template_revision_id,
               base.profile_template_revision_uid,
               diff.sanitized_profile_draft_id IS NOT NULL,
               diff.profile_edit_candidate_id IS NOT NULL,
               draft.derivation_kind
        FROM lab_local_game.profile_draft_diff AS diff
        LEFT JOIN lab_local_game.sanitized_profile_draft AS draft
          ON draft.sanitized_profile_draft_id = diff.sanitized_profile_draft_id
        LEFT JOIN lab_profile.profile_template_revision AS base
          ON base.profile_template_revision_id = diff.base_profile_template_revision_id
         AND base.local_account_id = diff.local_account_id
        WHERE diff.profile_draft_diff_id = @diff_id;
        """,
        connection,
        transaction);
    Add(command, "diff_id", NpgsqlDbType.Bigint, diffId);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
    if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      throw new LocalGameStateIntegrityException("profile_draft_diff_not_found");
    }

    return new DiffTopologyRow(
        reader.IsDBNull(0) ? null : reader.GetInt64(0),
        reader.IsDBNull(1) ? null : reader.GetInt64(1),
        reader.IsDBNull(2) ? null : new EntityUid(reader.GetGuid(2)),
        reader.GetBoolean(3),
        reader.GetBoolean(4),
        reader.IsDBNull(5) ? null : ParseDraftKind(reader.GetString(5)));
  }

  private static void ValidateApplicationTopology(
      ProfileDraftApplicationKind kind,
      DiffTopologyRow diff,
      ProfileWriteRow write)
  {
    var valid = kind switch
    {
      ProfileDraftApplicationKind.SaveAs =>
          write.OperationKind == "create" &&
          write.ExpectedRevisionUid is null &&
          diff.IsEditCandidate &&
          diff.AccountId.HasValue &&
          diff.BaseRevisionId.HasValue &&
          write.AccountId != diff.AccountId,
      ProfileDraftApplicationKind.Create =>
          write.OperationKind == "create" &&
          write.ExpectedRevisionUid is null &&
          diff.IsSanitizedDraft &&
          !diff.IsEditCandidate &&
          diff.AccountId is null &&
          diff.BaseRevisionId is null &&
          diff.BaseRevisionUid is null,
      ProfileDraftApplicationKind.Apply =>
          write.OperationKind == "save" &&
          diff.AccountId.HasValue &&
          diff.BaseRevisionId.HasValue &&
          write.ExpectedRevisionUid == diff.BaseRevisionUid &&
          write.AccountId == diff.AccountId &&
          (diff.IsEditCandidate ||
           diff.DerivationKind is SanitizedProfileDraftDerivationKind.OfflineSanitizedImport or
               SanitizedProfileDraftDerivationKind.ReviewedOverride),
      ProfileDraftApplicationKind.Rebase =>
          write.OperationKind == "save" &&
          diff.AccountId.HasValue &&
          diff.BaseRevisionId.HasValue &&
          write.ExpectedRevisionUid == diff.BaseRevisionUid &&
          write.AccountId == diff.AccountId &&
          diff.IsSanitizedDraft &&
          !diff.IsEditCandidate &&
          diff.DerivationKind == SanitizedProfileDraftDerivationKind.Rebase,
      _ => false
    };
    if (!valid)
    {
      throw new LocalGameStateIntegrityException("profile_draft_application_topology_invalid");
    }
  }

  private static async Task<ProfileDraftApplicationIntentReceipt?> ReadApplicationIntentAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      LinkProfileDraftApplicationCommand command,
      bool isReplay,
      CancellationToken cancellationToken)
  {
    await using var read = new NpgsqlCommand(
        """
        SELECT intent.request_sha256,
               intent.application_kind,
               diff.profile_draft_diff_uid,
               intent.profile_write_operation_uid,
               intent.requested_at_utc
        FROM lab_local_game.profile_draft_application_intent AS intent
        JOIN lab_local_game.profile_draft_diff AS diff
          ON diff.profile_draft_diff_id = intent.profile_draft_diff_id
        WHERE intent.application_uid = @uid;
        """,
        connection,
        transaction);
    Add(read, "uid", NpgsqlDbType.Uuid, command.ApplicationUid.Value);
    await using var reader = await read.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
    if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      return null;
    }

    if (Sha256Digest.FromBytes((byte[])reader.GetValue(0)) != command.RequestSha256 ||
        ParseApplicationKind(reader.GetString(1)) != command.ApplicationKind ||
        new EntityUid(reader.GetGuid(2)) != command.DiffUid ||
        new EntityUid(reader.GetGuid(3)) != command.ProfileWriteOperationUid ||
        reader.GetFieldValue<DateTimeOffset>(4) != command.AppliedAtUtc)
    {
      throw new LocalGameStateIntegrityException("profile_draft_application_intent_reuse_mismatch");
    }

    return new ProfileDraftApplicationIntentReceipt(
        command.ApplicationUid,
        isReplay,
        command.ApplicationKind,
        command.DiffUid,
        command.ProfileWriteOperationUid,
        command.AppliedAtUtc);
  }

  private static async Task<long> ResolveApplicationIntentIdAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      LinkProfileDraftApplicationCommand command,
      CancellationToken cancellationToken)
  {
    await using var read = new NpgsqlCommand(
        """
        SELECT intent.profile_draft_application_intent_id
        FROM lab_local_game.profile_draft_application_intent AS intent
        JOIN lab_local_game.profile_draft_diff AS diff
          ON diff.profile_draft_diff_id = intent.profile_draft_diff_id
        WHERE intent.application_uid = @uid
          AND intent.request_sha256 = @request_hash
          AND intent.application_kind = @kind
          AND diff.profile_draft_diff_uid = @diff_uid
          AND intent.profile_write_operation_uid = @write_operation_uid
          AND intent.requested_at_utc = @requested_at;
        """,
        connection,
        transaction);
    Add(read, "uid", NpgsqlDbType.Uuid, command.ApplicationUid.Value);
    Add(read, "request_hash", NpgsqlDbType.Bytea, command.RequestSha256.ToByteArray());
    Add(read, "kind", NpgsqlDbType.Text, ApplicationKindCode(command.ApplicationKind));
    Add(read, "diff_uid", NpgsqlDbType.Uuid, command.DiffUid.Value);
    Add(read, "write_operation_uid", NpgsqlDbType.Uuid,
        command.ProfileWriteOperationUid.Value);
    Add(read, "requested_at", NpgsqlDbType.TimestampTz, command.AppliedAtUtc);
    var value = await read.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false);
    if (value is null)
    {
      throw new LocalGameStateIntegrityException("profile_draft_application_intent_not_found");
    }

    return Convert.ToInt64(value, CultureInfo.InvariantCulture);
  }

  private static async Task<ProfileDraftApplicationReceipt?> ReadApplicationAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      EntityUid applicationUid,
      Sha256Digest requestSha256,
      bool isReplay,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        SELECT
            application.request_sha256,
            application.application_kind,
            diff.profile_draft_diff_uid,
            operation.operation_uid,
            source_account.local_account_uid,
            source_base.profile_template_revision_uid,
            result_account.local_account_uid,
            profile.profile_template_revision_uid,
            application.applied_at_utc
        FROM lab_local_game.profile_draft_application AS application
        JOIN lab_local_game.profile_draft_diff AS diff
          ON diff.profile_draft_diff_id = application.profile_draft_diff_id
        JOIN lab_profile.profile_write_operation AS operation
          ON operation.profile_write_operation_id =
             application.profile_write_operation_id
        LEFT JOIN lab_profile.local_account AS source_account
          ON source_account.local_account_id = application.source_local_account_id
        LEFT JOIN lab_profile.profile_template_revision AS source_base
          ON source_base.profile_template_revision_id =
             application.source_base_profile_template_revision_id
         AND source_base.local_account_id = application.source_local_account_id
        JOIN lab_profile.local_account AS result_account
          ON result_account.local_account_id = application.result_local_account_id
        JOIN lab_profile.profile_template_revision AS profile
          ON profile.profile_template_revision_id =
             application.result_profile_template_revision_id
         AND profile.local_account_id = application.result_local_account_id
        WHERE application.application_uid = @uid;
        """,
        connection,
        transaction);
    Add(command, "uid", NpgsqlDbType.Uuid, applicationUid.Value);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
    if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      return null;
    }

    if (Sha256Digest.FromBytes((byte[])reader.GetValue(0)) != requestSha256)
    {
      throw new LocalGameStateIntegrityException("profile_draft_application_reuse_mismatch");
    }

    return new ProfileDraftApplicationReceipt(
        applicationUid,
        isReplay,
        ParseApplicationKind(reader.GetString(1)),
        new EntityUid(reader.GetGuid(2)),
        new EntityUid(reader.GetGuid(3)),
        reader.IsDBNull(4) ? null : new EntityUid(reader.GetGuid(4)),
        reader.IsDBNull(5) ? null : new EntityUid(reader.GetGuid(5)),
        new EntityUid(reader.GetGuid(6)),
        new EntityUid(reader.GetGuid(7)),
        reader.GetFieldValue<DateTimeOffset>(8));
  }

  private static async Task AcquireLockAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      string value,
      long seed,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        "SELECT pg_advisory_xact_lock(hashtextextended(@value, @seed));",
        connection,
        transaction);
    Add(command, "value", NpgsqlDbType.Text, value);
    Add(command, "seed", NpgsqlDbType.Bigint, seed);
    await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
  }

  private static void AddCatalog(
      NpgsqlCommand command,
      LocalProfileCatalogBindingWrite catalog)
  {
    Add(command, "catalog_uid", NpgsqlDbType.Uuid, catalog.CatalogSnapshotUid.Value);
    Add(command, "dataset_uid", NpgsqlDbType.Uuid, catalog.DatasetSnapshotUid.Value);
    Add(command, "manifest", NpgsqlDbType.Bytea, catalog.CatalogManifestSha256.ToByteArray());
  }

  private static void RequireFingerprint(Sha256Digest value)
  {
    if (value == default)
    {
      throw new LocalGameStateIntegrityException("sanitized_import_alias_fingerprint_invalid");
    }
  }

  private static string RequireDefinitionKind(string value) => value switch
  {
    "equipment" or "cube" or "collection" or "favorite" or "console" or
        "overload_option" => value,
    _ => throw new LocalGameStateIntegrityException("sanitized_import_definition_kind_invalid")
  };

  private static string DraftKindCode(SanitizedProfileDraftDerivationKind value) => value switch
  {
    SanitizedProfileDraftDerivationKind.OfflineSanitizedImport => "offline_sanitized_import",
    SanitizedProfileDraftDerivationKind.Rebase => "rebase",
    SanitizedProfileDraftDerivationKind.ReviewedOverride => "reviewed_override",
    _ => throw new LocalGameStateIntegrityException("sanitized_profile_draft_kind_invalid")
  };

  private static SanitizedProfileDraftDerivationKind ParseDraftKind(string value) => value switch
  {
    "offline_sanitized_import" => SanitizedProfileDraftDerivationKind.OfflineSanitizedImport,
    "rebase" => SanitizedProfileDraftDerivationKind.Rebase,
    "reviewed_override" => SanitizedProfileDraftDerivationKind.ReviewedOverride,
    _ => throw new LocalGameStateIntegrityException("sanitized_profile_draft_kind_invalid")
  };

  private static string ImportOperationKind(SanitizedProfileDraftDerivationKind value) => value switch
  {
    SanitizedProfileDraftDerivationKind.OfflineSanitizedImport => "sanitize",
    SanitizedProfileDraftDerivationKind.Rebase => "rebase",
    SanitizedProfileDraftDerivationKind.ReviewedOverride => "reviewed_override",
    _ => throw new LocalGameStateIntegrityException("sanitized_profile_draft_kind_invalid")
  };

  private static string ApplicationKindCode(ProfileDraftApplicationKind value) => value switch
  {
    ProfileDraftApplicationKind.Apply => "apply",
    ProfileDraftApplicationKind.SaveAs => "save_as",
    ProfileDraftApplicationKind.Rebase => "rebase",
    ProfileDraftApplicationKind.Create => "create",
    _ => throw new LocalGameStateIntegrityException("profile_draft_application_kind_invalid")
  };

  private static ProfileDraftApplicationKind ParseApplicationKind(string value) => value switch
  {
    "apply" => ProfileDraftApplicationKind.Apply,
    "save_as" => ProfileDraftApplicationKind.SaveAs,
    "rebase" => ProfileDraftApplicationKind.Rebase,
    "create" => ProfileDraftApplicationKind.Create,
    _ => throw new LocalGameStateIntegrityException("profile_draft_application_kind_invalid")
  };

  private static LocalGameStateIntegrityException MapDatabaseException(PostgresException exception)
  {
    var code = exception.MessageText switch
    {
      "immutable_local_game_row" => "local_game_immutable_row",
      "local_game_draft_application_invalid" => "profile_draft_application_invalid",
      _ when exception.SqlState == PostgresErrorCodes.UniqueViolation =>
          "sanitized_import_unique_constraint_conflict",
      _ when exception.SqlState == PostgresErrorCodes.ForeignKeyViolation =>
          "sanitized_import_reference_invalid",
      _ when exception.SqlState == PostgresErrorCodes.CheckViolation =>
          "sanitized_import_value_invalid",
      _ => "sanitized_import_database_rejected"
    };
    return new LocalGameStateIntegrityException(code);
  }

  private static void Add(
      NpgsqlCommand command,
      string name,
      NpgsqlDbType type,
      object? value)
  {
    command.Parameters.Add(new NpgsqlParameter(name, type)
    {
      Value = value ?? DBNull.Value
    });
  }

  private sealed record CatalogRow(long Id, long DatasetId);

  private sealed record CandidateDocumentIds(long? SanitizedDraftId, long? EditCandidateId);

  private sealed record CurrentProfileRow(
      long AccountId,
      long ProfileRevisionId,
      EntityUid ProfileRevisionUid);

  private sealed record ProfileWriteRow(
      long OperationId,
      long AccountId,
      long ResultRevisionId,
      string OperationKind,
      EntityUid? ExpectedRevisionUid);

  private sealed record DiffTopologyRow(
      long? AccountId,
      long? BaseRevisionId,
      EntityUid? BaseRevisionUid,
      bool IsSanitizedDraft,
      bool IsEditCandidate,
      SanitizedProfileDraftDerivationKind? DerivationKind);
}

internal static class ProfileImportCanonicalizer
{
  internal static Sha256Digest ComputeEditCandidateRequestSha256(
      EntityUid accountUid,
      EntityUid baseProfileTemplateRevisionUid,
      Sha256Digest canonicalOperationsSha256,
      int operationCount) => Compute(
          "nll/profile-edit-candidate-request/v1",
          accountUid.ToString(),
          baseProfileTemplateRevisionUid.ToString(),
          canonicalOperationsSha256.ToString(),
          operationCount.ToString(CultureInfo.InvariantCulture));

  internal static Sha256Digest ComputeImportRequestSha256(
      ImportSanitizedProfileDraftCommand command) => Compute(
          "nll/sanitized-profile-import-request/v1",
          DraftKind(command.Draft.DerivationKind),
          command.Draft.PreviousDraftUid?.ToString() ?? string.Empty,
          SanitizedProfileDraftWrite.SchemaCode,
          command.Draft.SanitizerContractSha256.ToString(),
          command.Draft.TransformerSha256.ToString(),
          command.Draft.SemanticOptionsSha256.ToString(),
          command.Draft.CharacterCatalog.CatalogSnapshotUid.ToString(),
          command.Draft.CharacterCatalog.DatasetSnapshotUid.ToString(),
          command.Draft.CharacterCatalog.CatalogManifestSha256.ToString(),
          command.Draft.CombatSupportCatalog.CatalogSnapshotUid.ToString(),
          command.Draft.CombatSupportCatalog.DatasetSnapshotUid.ToString(),
          command.Draft.CombatSupportCatalog.CatalogManifestSha256.ToString(),
          command.Draft.CanonicalPayloadSha256.ToString(),
          Timestamp(command.CompletedAtUtc));

  internal static Sha256Digest ComputeDiffRequestSha256(CreateProfileDraftDiffCommand command) =>
      Compute(
          "nll/profile-draft-diff-request/v1",
          command.DraftUid.ToString(),
          command.AccountUid.ToString(),
          command.ExpectedProfileTemplateRevisionUid.ToString(),
          command.Diff.ContractVersion,
          command.Diff.CanonicalDiffSha256.ToString(),
          command.Diff.ChangeCount.ToString(CultureInfo.InvariantCulture),
          command.Diff.HasConflicts ? "true" : "false");

  internal static Sha256Digest ComputeCreateDiffRequestSha256(
      CreateImportProfileDraftDiffCommand command) => Compute(
          "nll/create-import-profile-diff-request/v1",
          command.DraftUid.ToString(),
          command.Diff.ContractVersion,
          command.Diff.CanonicalDiffSha256.ToString(),
          command.Diff.ChangeCount.ToString(CultureInfo.InvariantCulture),
          command.Diff.HasConflicts ? "true" : "false");

  internal static Sha256Digest ComputeApplicationRequestSha256(
      LinkProfileDraftApplicationCommand command) => Compute(
          "nll/profile-draft-application-request/v1",
          ApplicationKind(command.ApplicationKind),
          command.DiffUid.ToString(),
          command.ProfileWriteOperationUid.ToString(),
          Timestamp(command.AppliedAtUtc));

  private static Sha256Digest Compute(string domain, params string[] values)
  {
    using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
    Append(hash, domain);
    foreach (var value in values)
    {
      Append(hash, value);
    }

    return Sha256Digest.FromBytes(hash.GetHashAndReset());
  }

  private static void Append(IncrementalHash hash, string value)
  {
    var bytes = Encoding.UTF8.GetBytes(value);
    Span<byte> length = stackalloc byte[4];
    System.Buffers.Binary.BinaryPrimitives.WriteInt32BigEndian(length, bytes.Length);
    hash.AppendData(length);
    hash.AppendData(bytes);
  }

  private static string DraftKind(SanitizedProfileDraftDerivationKind value) => value switch
  {
    SanitizedProfileDraftDerivationKind.OfflineSanitizedImport => "offline_sanitized_import",
    SanitizedProfileDraftDerivationKind.Rebase => "rebase",
    SanitizedProfileDraftDerivationKind.ReviewedOverride => "reviewed_override",
    _ => throw new LocalGameStateIntegrityException("sanitized_profile_draft_kind_invalid")
  };

  private static string ApplicationKind(ProfileDraftApplicationKind value) => value switch
  {
    ProfileDraftApplicationKind.Apply => "apply",
    ProfileDraftApplicationKind.SaveAs => "save_as",
    ProfileDraftApplicationKind.Rebase => "rebase",
    ProfileDraftApplicationKind.Create => "create",
    _ => throw new LocalGameStateIntegrityException("profile_draft_application_kind_invalid")
  };

  private static string Timestamp(DateTimeOffset value) =>
      value.ToUniversalTime().ToString("O", CultureInfo.InvariantCulture);
}

internal static class SanitizedProfileJsonGuard
{
  private static readonly HashSet<string> ForbiddenNames = new(StringComparer.OrdinalIgnoreCase)
  {
    "account_uid",
    "authorization",
    "cookie",
    "credential",
    "envelope",
    "mtime",
    "open_id",
    "password",
    "path",
    "raw_hash",
    "source_id",
    "token",
    "url"
  };

  internal static string RequireSourceFreeObject(string value)
  {
    ArgumentNullException.ThrowIfNull(value);
    if (!string.Equals(value, value.Trim(), StringComparison.Ordinal) ||
        Encoding.UTF8.GetByteCount(value) is < 2 or > 67_108_864)
    {
      throw new LocalGameStateIntegrityException("sanitized_profile_json_shape_invalid");
    }

    try
    {
      using var document = JsonDocument.Parse(value, new JsonDocumentOptions
      {
        AllowTrailingCommas = false,
        CommentHandling = JsonCommentHandling.Disallow,
        MaxDepth = 128
      });
      if (document.RootElement.ValueKind != JsonValueKind.Object)
      {
        throw new LocalGameStateIntegrityException("sanitized_profile_json_shape_invalid");
      }

      Inspect(document.RootElement);
    }
    catch (JsonException)
    {
      throw new LocalGameStateIntegrityException("sanitized_profile_json_invalid");
    }

    return value;
  }

  private static void Inspect(JsonElement element)
  {
    if (element.ValueKind == JsonValueKind.Object)
    {
      foreach (var property in element.EnumerateObject())
      {
        if (ForbiddenNames.Contains(property.Name) ||
            property.Name.EndsWith("Path", StringComparison.OrdinalIgnoreCase) ||
            property.Name.EndsWith("Url", StringComparison.OrdinalIgnoreCase) ||
            property.Name.EndsWith("Token", StringComparison.OrdinalIgnoreCase))
        {
          throw new LocalGameStateIntegrityException("sanitized_profile_forbidden_field");
        }

        Inspect(property.Value);
      }
    }
    else if (element.ValueKind == JsonValueKind.Array)
    {
      foreach (var item in element.EnumerateArray())
      {
        Inspect(item);
      }
    }
  }
}
