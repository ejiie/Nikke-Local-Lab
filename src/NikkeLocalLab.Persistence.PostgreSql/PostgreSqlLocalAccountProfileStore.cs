using System.Data;
using NikkeLocalLab.Domain.Profile;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;
using Npgsql;
using NpgsqlTypes;
using CombatSupport = NikkeLocalLab.Domain.CombatSupport;
using DomainProfile = NikkeLocalLab.Domain.Profile;

namespace NikkeLocalLab.Persistence.PostgreSql;

public sealed partial class PostgreSqlLocalAccountProfileStore
{
  private const long OperationLockSeed = 7_220_612_749_941_337_821;
  private readonly NpgsqlDataSource _dataSource;
  private readonly IEntityUidGenerator _uidGenerator;

  public PostgreSqlLocalAccountProfileStore(
      NpgsqlDataSource dataSource,
      IEntityUidGenerator uidGenerator)
  {
    _dataSource = dataSource ?? throw new ArgumentNullException(nameof(dataSource));
    _uidGenerator = uidGenerator ?? throw new ArgumentNullException(nameof(uidGenerator));
  }

  public async Task<LocalAccountProfileReceipt> CreateAsync(
      CreateLocalAccountProfileCommand command,
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
      await AcquireOperationLockAsync(
          connection,
          transaction,
          command.OperationUid,
          cancellationToken).ConfigureAwait(false);
      var replay = await ReadOperationAsync(
          connection,
          transaction,
          command.OperationUid,
          command.RequestSha256,
          "create",
          cancellationToken).ConfigureAwait(false);
      if (replay is { } replayedRevisionId)
      {
        var receipt = await ReadReceiptAsync(
            connection,
            transaction,
            command.OperationUid,
            replayedRevisionId,
            true,
            cancellationToken).ConfigureAwait(false);
        await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
        return receipt;
      }

      var catalogs = await ResolveCatalogsAsync(
          connection,
          transaction,
          command.Profile,
          cancellationToken).ConfigureAwait(false);
      var account = await InsertAccountAsync(
          connection,
          transaction,
          command.CreatedAtUtc,
          command.AccountLabel,
          command.SaveAsParentAccountUid,
          cancellationToken).ConfigureAwait(false);
      var stored = await PersistAggregateAsync(
          connection,
          transaction,
          account,
          catalogs,
          command.Profile,
          command.CreatedAtUtc,
          cancellationToken).ConfigureAwait(false);
      await SwapCurrentGraphAsync(
          connection,
          transaction,
          account.Id,
          expectedProfileRevisionId: null,
          stored,
          cancellationToken).ConfigureAwait(false);
      await RecordOperationAsync(
          connection,
          transaction,
          command.OperationUid,
          "create",
          command.RequestSha256,
          account.Id,
          expectedRevisionUid: null,
          stored.ProfileRevisionId,
          command.CreatedAtUtc,
          cancellationToken).ConfigureAwait(false);

      var result = await ReadReceiptAsync(
          connection,
          transaction,
          command.OperationUid,
          stored.ProfileRevisionId,
          false,
          cancellationToken).ConfigureAwait(false);
      await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
      return result;
    }
    catch (PostgresException exception)
    {
      throw MapDatabaseException(exception);
    }
  }

  public async Task<LocalAccountProfileReceipt> SaveAsync(
      SaveLocalAccountProfileCommand command,
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
      await AcquireOperationLockAsync(
          connection,
          transaction,
          command.OperationUid,
          cancellationToken).ConfigureAwait(false);
      var replay = await ReadOperationAsync(
          connection,
          transaction,
          command.OperationUid,
          command.RequestSha256,
          "save",
          cancellationToken).ConfigureAwait(false);
      if (replay is { } replayedRevisionId)
      {
        var receipt = await ReadReceiptAsync(
            connection,
            transaction,
            command.OperationUid,
            replayedRevisionId,
            true,
            cancellationToken).ConfigureAwait(false);
        await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
        return receipt;
      }

      var account = await LockAccountAsync(
          connection,
          transaction,
          command.AccountUid,
          cancellationToken).ConfigureAwait(false);
      if (account.CurrentProfileRevisionUid != command.ExpectedProfileTemplateRevisionUid)
      {
        throw new LocalAccountProfileIntegrityException("profile_revision_conflict");
      }

      var catalogs = await ResolveCatalogsAsync(
          connection,
          transaction,
          command.Profile,
          cancellationToken).ConfigureAwait(false);
      var stored = await PersistAggregateAsync(
          connection,
          transaction,
          account,
          catalogs,
          command.Profile,
          command.CreatedAtUtc,
          cancellationToken).ConfigureAwait(false);
      await SwapCurrentGraphAsync(
          connection,
          transaction,
          account.Id,
          account.CurrentProfileRevisionId,
          stored,
          cancellationToken).ConfigureAwait(false);
      await RecordOperationAsync(
          connection,
          transaction,
          command.OperationUid,
          "save",
          command.RequestSha256,
          account.Id,
          command.ExpectedProfileTemplateRevisionUid,
          stored.ProfileRevisionId,
          command.CreatedAtUtc,
          cancellationToken).ConfigureAwait(false);

      var result = await ReadReceiptAsync(
          connection,
          transaction,
          command.OperationUid,
          stored.ProfileRevisionId,
          false,
          cancellationToken).ConfigureAwait(false);
      await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
      return result;
    }
    catch (PostgresException exception)
    {
      throw MapDatabaseException(exception);
    }
  }

  public async Task<LocalCurrentAccountProfile?> GetCurrentAsync(
      EntityUid accountUid,
      CancellationToken cancellationToken = default)
  {
    RequireUid(accountUid, "profile_account_uid_invalid");
    await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken)
        .ConfigureAwait(false);
    await using var transaction = await connection.BeginTransactionAsync(
        IsolationLevel.RepeatableRead,
        cancellationToken).ConfigureAwait(false);
    var result = await GetCurrentAsync(connection, transaction, accountUid, cancellationToken).ConfigureAwait(false);
    await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
    return result;
  }

  internal static async Task<LocalCurrentAccountProfile?> GetCurrentAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      EntityUid accountUid,
      CancellationToken cancellationToken)
  {
    RequireUid(accountUid, "profile_account_uid_invalid");
    var current = await ReadCurrentRevisionAsync(
        connection,
        transaction,
        accountUid,
        cancellationToken).ConfigureAwait(false);
    if (current is null)
    {
      return null;
    }

    return await ReadVerifiedProfileAsync(connection, transaction, current.Value, cancellationToken).ConfigureAwait(false);
  }

  internal async Task<LocalCurrentAccountProfile?> GetRevisionAsync(
      EntityUid accountUid,
      EntityUid revisionUid,
      CancellationToken cancellationToken)
  {
    await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken).ConfigureAwait(false);
    await using var transaction = await connection.BeginTransactionAsync(IsolationLevel.RepeatableRead, cancellationToken).ConfigureAwait(false);
    await using var command = new NpgsqlCommand("""
        SELECT revision.profile_template_revision_id
        FROM lab_profile.profile_template_revision AS revision
        JOIN lab_profile.local_account AS account ON account.local_account_id = revision.local_account_id
        WHERE account.local_account_uid = @account_uid AND revision.profile_template_revision_uid = @revision_uid;
        """, connection, transaction);
    command.Parameters.AddWithValue("account_uid", accountUid.Value);
    command.Parameters.AddWithValue("revision_uid", revisionUid.Value);
    var id = await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false);
    var result = id is long revisionId
        ? await ReadVerifiedProfileAsync(connection, transaction, revisionId, cancellationToken).ConfigureAwait(false)
        : null;
    await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
    return result;
  }

  private static async Task<LocalCurrentAccountProfile> ReadVerifiedProfileAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      long revisionId,
      CancellationToken cancellationToken)
  {

    var receipt = await ReadReceiptAsync(
        connection,
        transaction,
        operationUid: null,
        revisionId,
        false,
        cancellationToken).ConfigureAwait(false);
    var profile = await ReadProfileAsync(
        connection,
        transaction,
        revisionId,
        cancellationToken).ConfigureAwait(false);
    VerifyAggregateProjection(receipt, profile);

    return new LocalCurrentAccountProfile(receipt, profile);
  }

  public async Task<LocalAccountProfileReceipt?> GetByOperationAsync(
      EntityUid operationUid,
      CancellationToken cancellationToken = default)
  {
    RequireUid(operationUid, "profile_operation_uid_invalid");
    await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken)
        .ConfigureAwait(false);
    await using var transaction = await connection.BeginTransactionAsync(
        IsolationLevel.RepeatableRead,
        cancellationToken).ConfigureAwait(false);
    await using var command = new NpgsqlCommand(
        """
        SELECT result_profile_template_revision_id
        FROM lab_profile.profile_write_operation
        WHERE operation_uid = @operation_uid;
        """,
        connection,
        transaction);
    Add(command, "operation_uid", NpgsqlDbType.Uuid, operationUid.Value);
    var value = await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false);
    if (value is null)
    {
      await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
      return null;
    }

    var receipt = await ReadReceiptAsync(
        connection,
        transaction,
        operationUid,
        Convert.ToInt64(value, System.Globalization.CultureInfo.InvariantCulture),
        isReplay: true,
        cancellationToken).ConfigureAwait(false);
    await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
    return receipt;
  }

  public async Task<LocalSessionReceipt> IssueLocalSessionAsync(
      EntityUid accountUid,
      DateTimeOffset issuedAtUtc,
      DateTimeOffset expiresAtUtc,
      CancellationToken cancellationToken = default)
  {
    RequireUid(accountUid, "profile_account_uid_invalid");
    RequireUtc(issuedAtUtc);
    RequireUtc(expiresAtUtc);
    if (expiresAtUtc <= issuedAtUtc)
    {
      throw new LocalAccountProfileIntegrityException("profile_session_lifetime_invalid");
    }

    var sessionUid = _uidGenerator.NewUid();
    await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken)
        .ConfigureAwait(false);
    await using var command = new NpgsqlCommand(
        """
        INSERT INTO lab_profile.local_session (
            local_session_uid,
            local_account_id,
            issued_at_utc,
            expires_at_utc
        )
        SELECT @session_uid, account.local_account_id, @issued_at, @expires_at
        FROM lab_profile.local_account AS account
        WHERE account.local_account_uid = @account_uid
        RETURNING local_account_id;
        """,
        connection);
    Add(command, "session_uid", NpgsqlDbType.Uuid, sessionUid.Value);
    Add(command, "account_uid", NpgsqlDbType.Uuid, accountUid.Value);
    Add(command, "issued_at", NpgsqlDbType.TimestampTz, issuedAtUtc);
    Add(command, "expires_at", NpgsqlDbType.TimestampTz, expiresAtUtc);
    var accountId = await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false);
    if (accountId is null)
    {
      throw new LocalAccountProfileIntegrityException("profile_account_not_found");
    }

    return new LocalSessionReceipt(
        sessionUid,
        accountUid,
        issuedAtUtc,
        expiresAtUtc,
        null,
        LocalSessionStatus.Active);
  }

  public async Task<LocalSessionReceipt?> GetLocalSessionAsync(
      EntityUid sessionUid,
      DateTimeOffset observedAtUtc,
      CancellationToken cancellationToken = default)
  {
    RequireUid(sessionUid, "profile_session_uid_invalid");
    RequireUtc(observedAtUtc);
    await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken)
        .ConfigureAwait(false);
    return await ReadSessionAsync(
        connection,
        transaction: null,
        sessionUid,
        observedAtUtc,
        forUpdate: false,
        cancellationToken).ConfigureAwait(false);
  }

  public async Task<LocalSessionReceipt> RevokeLocalSessionAsync(
      EntityUid sessionUid,
      DateTimeOffset revokedAtUtc,
      CancellationToken cancellationToken = default)
  {
    RequireUid(sessionUid, "profile_session_uid_invalid");
    RequireUtc(revokedAtUtc);
    await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken)
        .ConfigureAwait(false);
    await using var transaction = await connection.BeginTransactionAsync(cancellationToken)
        .ConfigureAwait(false);
    var current = await ReadSessionAsync(
        connection,
        transaction,
        sessionUid,
        revokedAtUtc,
        forUpdate: true,
        cancellationToken).ConfigureAwait(false) ??
        throw new LocalAccountProfileIntegrityException("profile_session_not_found");
    if (current.RevokedAtUtc is null)
    {
      if (current.Status != LocalSessionStatus.Active ||
          revokedAtUtc < current.IssuedAtUtc ||
          revokedAtUtc >= current.ExpiresAtUtc)
      {
        throw new LocalAccountProfileIntegrityException("profile_session_revoke_time_invalid");
      }

      await using var update = new NpgsqlCommand(
          """
          UPDATE lab_profile.local_session
          SET revoked_at_utc = @revoked_at
          WHERE local_session_uid = @session_uid
            AND revoked_at_utc IS NULL;
          """,
          connection,
          transaction);
      Add(update, "revoked_at", NpgsqlDbType.TimestampTz, revokedAtUtc);
      Add(update, "session_uid", NpgsqlDbType.Uuid, sessionUid.Value);
      if (await update.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false) != 1)
      {
        throw new LocalAccountProfileIntegrityException("profile_session_revoke_conflict");
      }

      current = current with
      {
        RevokedAtUtc = revokedAtUtc,
        Status = LocalSessionStatus.Revoked
      };
    }

    await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
    return current;
  }

  private async Task<StoredAggregate> PersistAggregateAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      AccountRow account,
      CatalogPair catalogs,
      LocalAccountProfileWrite profile,
      DateTimeOffset createdAtUtc,
      CancellationToken cancellationToken)
  {
    var ownedCubes = profile.AccountState.Cubes.ToDictionary(static cube => cube.DefinitionUid);
    if (ownedCubes.Count > 0 && profile.Builds.Any(build =>
        build.Cube.DefinitionUid is { } uid &&
        (!ownedCubes.TryGetValue(uid, out var owned) || build.Cube.Level?.Value != owned.Level)))
    {
      throw new LocalAccountProfileIntegrityException("profile_cube_level_account_mismatch");
    }

    var stateValidation = await ValidateAccountStateAsync(
        connection,
        transaction,
        catalogs.Support,
        profile.AccountState,
        cancellationToken).ConfigureAwait(false);
    var state = await StoreAccountStateAsync(
        connection,
        transaction,
        account.Id,
        catalogs,
        profile.AccountState,
        stateValidation,
        createdAtUtc,
        cancellationToken).ConfigureAwait(false);

    var builds = new List<StoredBuild>(profile.Builds.Count);
    foreach (var build in profile.Builds)
    {
      builds.Add(await StoreBuildAsync(
          connection,
          transaction,
          account.Id,
          catalogs,
          build,
          createdAtUtc,
          cancellationToken).ConfigureAwait(false));
    }

    StoredSquad? squad = null;
    if (profile.SquadCharacterUids is not null)
    {
      squad = await StoreSquadAsync(
          connection,
          transaction,
          account,
          catalogs,
          profile.SquadCharacterUids,
          builds,
          profile.SquadOrigin,
          createdAtUtc,
          cancellationToken).ConfigureAwait(false);
    }

    var template = await StoreTemplateAsync(
        connection,
        transaction,
        account,
        catalogs,
        state,
        builds,
        squad,
        profile,
        createdAtUtc,
        cancellationToken).ConfigureAwait(false);
    return new StoredAggregate(state.Id, builds, squad, template.RevisionId);
  }

  private async Task<CatalogPair> ResolveCatalogsAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      LocalAccountProfileWrite profile,
      CancellationToken cancellationToken)
  {
    var character = await ResolveCatalogAsync(
        connection,
        transaction,
        profile.CharacterCatalog,
        characterCatalog: true,
        cancellationToken).ConfigureAwait(false);
    var support = await ResolveCatalogAsync(
        connection,
        transaction,
        profile.CombatSupportCatalog,
        characterCatalog: false,
        cancellationToken).ConfigureAwait(false);
    return new CatalogPair(character, support);
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
    Add(command, "catalog_uid", NpgsqlDbType.Uuid, binding.CatalogSnapshotUid.Value);
    Add(command, "dataset_uid", NpgsqlDbType.Uuid, binding.DatasetSnapshotUid.Value);
    Add(command, "manifest", NpgsqlDbType.Bytea, binding.CatalogManifestSha256.ToByteArray());
    await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
    if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      throw new LocalAccountProfileIntegrityException(
          characterCatalog ? "profile_character_catalog_binding_invalid" :
              "profile_support_catalog_binding_invalid");
    }

    return new CatalogRow(
        reader.GetInt64(0),
        reader.GetInt64(1),
        binding);
  }

  private async Task<AccountRow> InsertAccountAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      DateTimeOffset createdAtUtc,
      string? accountLabel,
      EntityUid? saveAsParentAccountUid,
      CancellationToken cancellationToken)
  {
    var uid = _uidGenerator.NewUid();
    var stateUid = _uidGenerator.NewUid();
    var account = new DomainProfile.LocalAccount(uid, createdAtUtc);
    await using var command = new NpgsqlCommand(
        """
        INSERT INTO lab_profile.local_account (
            local_account_uid,
            account_combat_state_uid,
            canonical_sha256,
            created_at_utc
        ) VALUES (@uid, @state_uid, @canonical_hash, @created_at)
        RETURNING local_account_id;
        """,
        connection,
        transaction);
    Add(command, "uid", NpgsqlDbType.Uuid, uid.Value);
    Add(command, "state_uid", NpgsqlDbType.Uuid, stateUid.Value);
    Add(command, "canonical_hash", NpgsqlDbType.Bytea, account.CanonicalSha256.ToByteArray());
    Add(command, "created_at", NpgsqlDbType.TimestampTz, createdAtUtc);
    var id = Convert.ToInt64(
        await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false),
        System.Globalization.CultureInfo.InvariantCulture);

    await using var workspace = new NpgsqlCommand(
        """
        INSERT INTO lab_profile.account_workspace (
            local_account_id,
            workspace_uid,
            account_label,
            save_as_parent_account_uid,
            fetched_snapshot_uid,
            last_fetched_at_utc,
            last_execution_result_code,
            created_at_utc,
            updated_at_utc
        ) VALUES (
            @account_id,
            @workspace_uid,
            @account_label,
            @parent_uid,
            NULL,
            NULL,
            NULL,
            @created_at,
            @created_at
        );
        """,
        connection,
        transaction);
    Add(workspace, "account_id", NpgsqlDbType.Bigint, id);
    Add(workspace, "workspace_uid", NpgsqlDbType.Uuid, uid.Value);
    Add(
        workspace,
        "account_label",
        NpgsqlDbType.Text,
        accountLabel ?? $"account_{uid}");
    Add(
        workspace,
        "parent_uid",
        NpgsqlDbType.Uuid,
        saveAsParentAccountUid?.Value);
    Add(workspace, "created_at", NpgsqlDbType.TimestampTz, createdAtUtc);
    await workspace.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);

    return new AccountRow(
        id,
        uid,
        stateUid,
        createdAtUtc,
        account.CanonicalSha256,
        null,
        null);
  }

  private static async Task<AccountRow> LockAccountAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      EntityUid accountUid,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        SELECT
            account.local_account_id,
            account.account_combat_state_uid,
            account.created_at_utc,
            account.canonical_sha256,
            account.current_profile_template_revision_id
        FROM lab_profile.local_account AS account
        WHERE account.local_account_uid = @uid
        FOR UPDATE OF account;
        """,
        connection,
        transaction);
    Add(command, "uid", NpgsqlDbType.Uuid, accountUid.Value);
    long id;
    EntityUid accountCombatStateUid;
    DateTimeOffset createdAtUtc;
    Sha256Digest canonicalSha256;
    long? currentProfileRevisionId;
    await using (var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false))
    {
      if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
      {
        throw new LocalAccountProfileIntegrityException("profile_account_not_found");
      }

      id = reader.GetInt64(0);
      accountCombatStateUid = new EntityUid(reader.GetGuid(1));
      createdAtUtc = reader.GetFieldValue<DateTimeOffset>(2);
      canonicalSha256 = Sha256Digest.FromBytes((byte[])reader.GetValue(3));
      currentProfileRevisionId = reader.IsDBNull(4) ? null : reader.GetInt64(4);
    }

    EntityUid? currentProfileRevisionUid = null;
    if (currentProfileRevisionId is { } revisionId)
    {
      await using var revisionCommand = new NpgsqlCommand(
          """
          SELECT revision.profile_template_revision_uid
          FROM lab_profile.profile_template_revision AS revision
          WHERE revision.profile_template_revision_id = @revision_id
            AND revision.local_account_id = @account_id;
          """,
          connection,
          transaction);
      Add(revisionCommand, "revision_id", NpgsqlDbType.Bigint, revisionId);
      Add(revisionCommand, "account_id", NpgsqlDbType.Bigint, id);
      var revisionUid = await revisionCommand.ExecuteScalarAsync(cancellationToken)
          .ConfigureAwait(false);
      if (revisionUid is not Guid value)
      {
        throw new LocalAccountProfileIntegrityException("profile_current_graph_inconsistent");
      }

      currentProfileRevisionUid = new EntityUid(value);
    }

    return new AccountRow(
        id,
        accountUid,
        accountCombatStateUid,
        createdAtUtc,
        canonicalSha256,
        currentProfileRevisionId,
        currentProfileRevisionUid);
  }

  private static async Task<ValidatedAccountState> ValidateAccountStateAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      CatalogRow supportCatalog,
      LocalAccountCombatStateWrite state,
      CancellationToken cancellationToken)
  {
    var resolved = new List<ResolvedConsole>(9);
    var gameLegal = state.ValidationMode == LocalProfileValidationMode.GameLegal;
    string? issue = gameLegal ? null : "research_mode";
    string? combatIssue = state.SynchroLevel.Status == LocalProfileFactStatus.Ready &&
        state.SynchroLevel.Value > 0
        ? null
        : "profile_account_combat_unresolved";
    string? fidelityIssue = null;
    foreach (var console in state.Consoles)
    {
      var definition = await ResolveSupportVersionAsync(
          connection,
          transaction,
          supportCatalog.Id,
          console.ConsoleDefinitionUid,
          "console",
          cancellationToken).ConfigureAwait(false);
      await using var detail = new NpgsqlCommand(
          """
          SELECT coordinate_code, maximum_level_status, maximum_level
          FROM lab_combat_support.console_definition_detail
          WHERE definition_version_id = @version_id;
          """,
          connection,
          transaction);
      Add(detail, "version_id", NpgsqlDbType.Bigint, definition.VersionId);
      await using var reader = await detail.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
      if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false) ||
          !string.Equals(
              reader.GetString(0),
              LocalAccountProfileCanonicalizer.Code(console.Coordinate),
              StringComparison.Ordinal))
      {
        throw new LocalAccountProfileIntegrityException("profile_console_coordinate_mismatch");
      }

      var maximumStatus = reader.GetString(1);
      var maximumReady = maximumStatus == "ready";
      var maximum = reader.IsDBNull(2) ? (int?)null : reader.GetInt32(2);
      await reader.DisposeAsync().ConfigureAwait(false);
      if (console.Level.Value is { } level)
      {
        if (maximumReady && maximum is { } resolvedMaximum)
        {
          if (level > resolvedMaximum)
          {
            throw new LocalAccountProfileIntegrityException("profile_console_level_exceeds_cap");
          }
        }
        else if (maximumStatus == "unresolved")
        {
          combatIssue ??= "profile_account_combat_unresolved";
          if (gameLegal)
          {
            issue ??= "profile_semantics_unresolved";
          }
        }
        else
        {
          throw new LocalAccountProfileIntegrityException("profile_console_cap_invalid");
        }

        if (gameLegal && level > 0)
        {
          await using var gate = new NpgsqlCommand(
              """
              SELECT minimum_synchro_level
              FROM lab_combat_support.console_legal_level
              WHERE definition_version_id = @version_id
                AND level = @level;
              """,
              connection,
              transaction);
          Add(gate, "version_id", NpgsqlDbType.Bigint, definition.VersionId);
          Add(gate, "level", NpgsqlDbType.Integer, level);
          await using var gateReader = await gate.ExecuteReaderAsync(cancellationToken)
              .ConfigureAwait(false);
          if (!await gateReader.ReadAsync(cancellationToken).ConfigureAwait(false))
          {
            if (maximumReady)
            {
              throw new LocalAccountProfileIntegrityException("profile_console_level_not_legal");
            }

            issue ??= "profile_semantics_unresolved";
          }
          else if (state.SynchroLevel.Value is { } synchroLevel)
          {
            if (synchroLevel < gateReader.GetInt32(0))
            {
              throw new LocalAccountProfileIntegrityException(
                  "profile_console_synchro_gate_failed");
            }
          }
          else
          {
            issue ??= "profile_semantics_unresolved";
          }
        }
      }
      else if (gameLegal)
      {
        issue ??= "profile_semantics_unresolved";
      }

      if (console.Level.Status != LocalProfileFactStatus.Ready)
      {
        combatIssue ??= "profile_account_combat_unresolved";
      }

      if (!definition.HasCompleteCombatSemantics)
      {
        combatIssue ??= "profile_account_combat_semantics_unresolved";
      }

      if (console.ObservedExperience.Status != LocalProfileFactStatus.Ready)
      {
        fidelityIssue ??= "profile_experience_not_observed";
      }

      resolved.Add(new ResolvedConsole(console, definition));
    }

    fidelityIssue ??= combatIssue;

    if (gameLegal && state.SynchroLevel.Status != LocalProfileFactStatus.Ready)
    {
      issue ??= "profile_semantics_unresolved";
    }

    var ownedCubes = new List<ResolvedOwnedCube>();
    foreach (var cube in state.Cubes)
    {
      var definition = await ResolveSupportVersionAsync(
          connection, transaction, supportCatalog.Id, cube.DefinitionUid, "cube", cancellationToken)
          .ConfigureAwait(false);
      await using var gate = new NpgsqlCommand(
          """
          SELECT 1 FROM lab_combat_support.cube_definition_detail detail
          JOIN lab_combat_support.definition_level_coordinate coordinate
            ON coordinate.definition_version_id = detail.definition_version_id
          WHERE detail.definition_version_id = @version_id
            AND detail.maximum_level_status = 'ready'
            AND @level <= detail.maximum_level AND coordinate.level = @level;
          """, connection, transaction);
      Add(gate, "version_id", NpgsqlDbType.Bigint, definition.VersionId);
      Add(gate, "level", NpgsqlDbType.Integer, cube.Level);
      if (await gate.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false) is null)
      {
        throw new LocalAccountProfileIntegrityException("profile_cube_level_not_in_catalog");
      }

      ownedCubes.Add(new ResolvedOwnedCube(cube, definition));
    }

    return new ValidatedAccountState(
        resolved,
        ownedCubes,
        new ValidationResult(combatIssue is null, combatIssue),
        new ValidationResult(fidelityIssue is null, fidelityIssue),
        new ValidationResult(issue is null, issue));
  }

  private async Task<StoredState> StoreAccountStateAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      long accountId,
      CatalogPair catalogs,
      LocalAccountCombatStateWrite state,
      ValidatedAccountState validated,
      DateTimeOffset createdAtUtc,
      CancellationToken cancellationToken)
  {
    var content = ProjectAccountState(catalogs, state, validated);
    var hash = DomainProfile.ProfileCanonicalizer.ComputeContentHash(content);
    StoredStateHead? head = null;
    await using (var existing = new NpgsqlCommand(
        """
        SELECT
            revision.account_state_revision_id,
            revision.account_state_revision_uid,
            revision.revision_number,
            previous.account_state_revision_uid,
            revision.content_sha256,
            revision.revision_origin,
            revision.materialized_at_utc,
            revision.combat_readiness_status,
            revision.combat_readiness_issue_code,
            revision.full_fidelity_status,
            revision.full_fidelity_issue_code,
            revision.game_legal_readiness_status,
            revision.game_legal_issue_code
        FROM lab_profile.local_account AS account
        LEFT JOIN lab_profile.account_state_revision AS revision
          ON revision.account_state_revision_id = account.current_account_state_revision_id
        LEFT JOIN lab_profile.account_state_revision AS previous
          ON previous.account_state_revision_id = revision.previous_account_state_revision_id
        WHERE account.local_account_id = @account_id;
        """,
        connection,
        transaction))
    {
      Add(existing, "account_id", NpgsqlDbType.Bigint, accountId);
      await using var reader = await existing.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
      if (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
      {
        if (!reader.IsDBNull(0))
        {
          var storedHash = Sha256Digest.FromBytes((byte[])reader.GetValue(4));
          head = new StoredStateHead(
              reader.GetInt64(0),
              new EntityUid(reader.GetGuid(1)),
              reader.GetInt32(2));
          if (storedHash == hash)
          {
            return new StoredState(
                reader.GetInt64(0),
                new EntityUid(reader.GetGuid(1)),
                new LocalRevisionLineage(
                    reader.GetInt32(2),
                    reader.IsDBNull(3) ? null : new EntityUid(reader.GetGuid(3)),
                    ParseRevisionOrigin(reader.GetString(5)),
                    reader.GetFieldValue<DateTimeOffset>(6)),
                hash,
                reader.GetString(7) == "ready",
                reader.GetString(9) == "ready",
                reader.GetString(11) == "ready",
                CompactIssues(
                    reader.IsDBNull(8) ? null : reader.GetString(8),
                    reader.IsDBNull(10) ? null : reader.GetString(10),
                    reader.IsDBNull(12) ? null : reader.GetString(12)));
          }
        }
      }
    }

    var uid = _uidGenerator.NewUid();
    long revisionId;
    await using (var insert = new NpgsqlCommand(
        """
        INSERT INTO lab_profile.account_state_revision (
            account_state_revision_uid,
            local_account_id,
            revision_number,
            previous_account_state_revision_id,
            character_catalog_snapshot_id,
            character_dataset_snapshot_id,
            character_catalog_manifest_sha256,
            support_catalog_snapshot_id,
            support_dataset_snapshot_id,
            support_catalog_manifest_sha256,
            synchro_level_status,
            synchro_level,
            synchro_level_unresolved_reason_code,
            validation_mode,
            combat_readiness_status,
            combat_readiness_issue_code,
            full_fidelity_status,
            full_fidelity_issue_code,
            game_legal_readiness_status,
            game_legal_issue_code,
            console_count,
            cube_count,
            content_sha256,
            revision_origin,
            materialized_at_utc
        ) VALUES (
            @uid, @account_id, @revision_number, @previous_revision_id,
            @character_catalog_id, @character_dataset_id, @character_manifest,
            @support_catalog_id, @support_dataset_id, @support_manifest,
            @synchro_status, @synchro_value, @synchro_reason, @validation_mode,
            @combat_readiness, @combat_issue, @fidelity_readiness, @fidelity_issue,
            @readiness, @issue_code, 9, @cube_count, @content_hash, @origin, @created_at
        )
        RETURNING account_state_revision_id;
        """,
        connection,
        transaction))
    {
      Add(insert, "uid", NpgsqlDbType.Uuid, uid.Value);
      Add(insert, "account_id", NpgsqlDbType.Bigint, accountId);
      Add(insert, "revision_number", NpgsqlDbType.Integer, (head?.RevisionNumber ?? 0) + 1);
      Add(insert, "previous_revision_id", NpgsqlDbType.Bigint, head?.Id);
      AddCatalogParameters(insert, "character", catalogs.Character);
      AddCatalogParameters(insert, "support", catalogs.Support);
      AddFactParameters(insert, "synchro", state.SynchroLevel, NpgsqlDbType.Integer);
      Add(insert, "validation_mode", NpgsqlDbType.Text,
          LocalAccountProfileCanonicalizer.Code(state.ValidationMode));
      Add(insert, "combat_readiness", NpgsqlDbType.Text,
          validated.Combat.IsReady ? "ready" : "unresolved");
      Add(insert, "combat_issue", NpgsqlDbType.Text, validated.Combat.IssueCode);
      Add(insert, "fidelity_readiness", NpgsqlDbType.Text,
          validated.FullFidelity.IsReady ? "ready" : "unresolved");
      Add(insert, "fidelity_issue", NpgsqlDbType.Text,
          validated.FullFidelity.IssueCode);
      Add(insert, "readiness", NpgsqlDbType.Text,
          validated.GameLegal.IsReady ? "ready" : "unresolved");
      Add(insert, "issue_code", NpgsqlDbType.Text, validated.GameLegal.IssueCode);
      Add(insert, "content_hash", NpgsqlDbType.Bytea, hash.ToByteArray());
      Add(insert, "cube_count", NpgsqlDbType.Integer, validated.Cubes.Count);
      Add(insert, "origin", NpgsqlDbType.Text,
          LocalAccountProfileCanonicalizer.Code(state.Origin));
      Add(insert, "created_at", NpgsqlDbType.TimestampTz, createdAtUtc);
      revisionId = Convert.ToInt64(
          await insert.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false),
          System.Globalization.CultureInfo.InvariantCulture);
    }

    foreach (var item in validated.Consoles)
    {
      await using var insert = new NpgsqlCommand(
          """
          INSERT INTO lab_profile.account_console_state (
              account_state_revision_id,
              support_catalog_snapshot_id,
              coordinate_code,
              definition_entity_id,
              definition_version_id,
              definition_kind,
              level_status,
              level,
              level_unresolved_reason_code,
              observed_experience_status,
              observed_experience,
              observed_experience_unresolved_reason_code
          ) VALUES (
              @revision_id, @support_catalog_id, @coordinate,
              @entity_id, @version_id, 'console',
              @level_status, @level_value, @level_reason,
              @experience_status, @experience_value, @experience_reason
          );
          """,
          connection,
          transaction);
      Add(insert, "revision_id", NpgsqlDbType.Bigint, revisionId);
      Add(insert, "support_catalog_id", NpgsqlDbType.Bigint, catalogs.Support.Id);
      Add(insert, "coordinate", NpgsqlDbType.Text,
          LocalAccountProfileCanonicalizer.Code(item.Write.Coordinate));
      Add(insert, "entity_id", NpgsqlDbType.Bigint, item.Definition.EntityId);
      Add(insert, "version_id", NpgsqlDbType.Bigint, item.Definition.VersionId);
      AddFactParameters(insert, "level", item.Write.Level, NpgsqlDbType.Integer);
      AddFactParameters(
          insert,
          "experience",
          item.Write.ObservedExperience,
          NpgsqlDbType.Bigint);
      await insert.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
    }

    foreach (var cube in validated.Cubes)
    {
      await using var insert = new NpgsqlCommand(
          """
          INSERT INTO lab_profile.account_cube_state (
              account_state_revision_id, support_catalog_snapshot_id,
              definition_entity_id, definition_version_id, definition_kind, level
          ) VALUES (@revision_id, @catalog_id, @entity_id, @version_id, 'cube', @level);
          """, connection, transaction);
      Add(insert, "revision_id", NpgsqlDbType.Bigint, revisionId);
      Add(insert, "catalog_id", NpgsqlDbType.Bigint, catalogs.Support.Id);
      Add(insert, "entity_id", NpgsqlDbType.Bigint, cube.Definition.EntityId);
      Add(insert, "version_id", NpgsqlDbType.Bigint, cube.Definition.VersionId);
      Add(insert, "level", NpgsqlDbType.Integer, cube.Write.Level);
      await insert.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
    }

    return new StoredState(
        revisionId,
        uid,
        new LocalRevisionLineage(
            (head?.RevisionNumber ?? 0) + 1,
            head?.Uid,
            state.Origin,
            createdAtUtc),
        hash,
        validated.Combat.IsReady,
        validated.FullFidelity.IsReady,
        validated.GameLegal.IsReady,
        CompactIssues(
            validated.Combat.IssueCode,
            validated.FullFidelity.IssueCode,
            validated.GameLegal.IssueCode));
  }

  private static async Task<CharacterVersion> ResolveCharacterVersionAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      CatalogRow catalog,
      EntityUid characterUid,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        SELECT
            entity.character_entity_id,
            member.character_definition_version_id,
            version.character_definition_version_uid,
            version.definition_content_sha256,
            version.combat_class_status,
            version.combat_class_code,
            version.weapon_status,
            version.weapon_code,
            version.manufacturer_status,
            version.manufacturer_code,
            version.rarity_status,
            version.rarity_code,
            version.element_status
        FROM lab_catalog.character_catalog_snapshot_member AS member
        JOIN lab_catalog.character_entity AS entity
          ON entity.character_entity_id = member.character_entity_id
        JOIN lab_catalog.character_definition_version AS version
          ON version.character_definition_version_id =
             member.character_definition_version_id
        WHERE member.character_catalog_snapshot_id = @catalog_id
          AND entity.character_uid = @character_uid;
        """,
        connection,
        transaction);
    Add(command, "catalog_id", NpgsqlDbType.Bigint, catalog.Id);
    Add(command, "character_uid", NpgsqlDbType.Uuid, characterUid.Value);
    long entityId;
    long versionId;
    EntityUid definitionVersionUid;
    Sha256Digest definitionContentSha256;
    string? combatClass;
    string? weapon;
    string? manufacturer;
    string? rarity;
    bool characterProfileSemanticsReady;
    await using (var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false))
    {
      if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
      {
        throw new LocalAccountProfileIntegrityException("profile_character_not_in_catalog");
      }

      entityId = reader.GetInt64(0);
      versionId = reader.GetInt64(1);
      combatClass = reader.GetString(4) == "ready" && !reader.IsDBNull(5)
          ? reader.GetString(5)
          : null;
      weapon = reader.GetString(6) == "ready" && !reader.IsDBNull(7)
          ? reader.GetString(7)
          : null;
      manufacturer = reader.GetString(8) == "ready" && !reader.IsDBNull(9)
          ? reader.GetString(9)
          : null;
      rarity = reader.GetString(10) == "ready" && !reader.IsDBNull(11)
          ? reader.GetString(11)
          : null;

      definitionVersionUid = new EntityUid(reader.GetGuid(2));
      definitionContentSha256 = Sha256Digest.FromBytes((byte[])reader.GetValue(3));
      characterProfileSemanticsReady = reader.GetString(4) == "ready" &&
          reader.GetString(6) == "ready" &&
          reader.GetString(8) == "ready" &&
          reader.GetString(10) == "ready" &&
          reader.GetString(12) == "ready";
    }

    var capabilities = new Dictionary<string, CapabilityRow>(StringComparer.Ordinal);
    await using var capabilityCommand = new NpgsqlCommand(
        """
        SELECT capability_code, resolution_status, maximum_level, unresolved_reason_code
        FROM lab_catalog.character_definition_capability
        WHERE character_definition_version_id = @version_id;
        """,
        connection,
        transaction);
    Add(capabilityCommand, "version_id", NpgsqlDbType.Bigint, versionId);
    await using var capabilityReader = await capabilityCommand.ExecuteReaderAsync(cancellationToken)
        .ConfigureAwait(false);
    while (await capabilityReader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      capabilities.Add(
          capabilityReader.GetString(0),
          new CapabilityRow(
              capabilityReader.GetString(1),
              capabilityReader.IsDBNull(2) ? null : capabilityReader.GetInt32(2),
              capabilityReader.IsDBNull(3) ? null : capabilityReader.GetString(3)));
    }

    return new CharacterVersion(
        characterUid,
        entityId,
        versionId,
        definitionVersionUid,
        definitionContentSha256,
        characterProfileSemanticsReady,
        combatClass,
        weapon,
        manufacturer,
        rarity,
        capabilities);
  }

  private static async Task<SupportVersion> ResolveSupportVersionAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      long catalogId,
      EntityUid definitionUid,
      string expectedKind,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        SELECT
            member.definition_entity_id,
            member.definition_version_id,
            version.definition_version_uid,
            version.definition_content_sha256,
            version.complete_semantics_status
        FROM lab_combat_support.catalog_snapshot_member AS member
        JOIN lab_combat_support.definition_entity AS entity
          ON entity.definition_entity_id = member.definition_entity_id
        JOIN lab_combat_support.definition_version AS version
          ON version.definition_version_id = member.definition_version_id
        WHERE member.catalog_snapshot_id = @catalog_id
          AND entity.definition_uid = @definition_uid
          AND member.definition_kind = @definition_kind;
        """,
        connection,
        transaction);
    Add(command, "catalog_id", NpgsqlDbType.Bigint, catalogId);
    Add(command, "definition_uid", NpgsqlDbType.Uuid, definitionUid.Value);
    Add(command, "definition_kind", NpgsqlDbType.Text, expectedKind);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
    if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      throw new LocalAccountProfileIntegrityException("profile_definition_not_in_catalog");
    }

    return new SupportVersion(
        definitionUid,
        reader.GetInt64(0),
        reader.GetInt64(1),
        new EntityUid(reader.GetGuid(2)),
        Sha256Digest.FromBytes((byte[])reader.GetValue(3)),
        expectedKind,
        reader.GetString(4) == "ready");
  }

  private static async Task<ValidatedBuild> ValidateBuildAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      CatalogPair catalogs,
      LocalCharacterBuildWrite build,
      CancellationToken cancellationToken)
  {
    var character = await ResolveCharacterVersionAsync(
        connection,
        transaction,
        catalogs.Character,
        build.CharacterUid,
        cancellationToken).ConfigureAwait(false);
    var gameLegal = build.ValidationMode == LocalProfileValidationMode.GameLegal;
    string? issue = gameLegal ? null : "research_mode";

    var scalarSelectionResolved = ValidateCharacterLevelCapability(
        character,
        build.CharacterLevel,
        gameLegal,
        ref issue);
    scalarSelectionResolved &= ValidateFactCapability(
        character, "skill_1", build.Skill1Level, gameLegal, false, ref issue);
    scalarSelectionResolved &= ValidateFactCapability(
        character, "skill_2", build.Skill2Level, gameLegal, false, ref issue);
    scalarSelectionResolved &= ValidateFactCapability(
        character, "burst", build.BurstLevel, gameLegal, false, ref issue);
    scalarSelectionResolved &= ValidateFactCapability(
        character, "limit_break", build.LimitBreak, gameLegal, false, ref issue);
    scalarSelectionResolved &= ValidateFactCapability(
        character, "core_level", build.CoreLevel, gameLegal, true, ref issue);
    scalarSelectionResolved &= ValidateFactCapability(
        character,
        "bond_level",
        build.BondLevel,
        gameLegal,
        character.Rarity == "r",
        ref issue);

    var equipment = new List<ResolvedEquipment>(4);
    foreach (var write in build.Equipment)
    {
      if (write.State != LocalEquipmentState.Equipped)
      {
        if (gameLegal && write.State == LocalEquipmentState.Unresolved)
        {
          issue ??= "profile_semantics_unresolved";
        }

        equipment.Add(new ResolvedEquipment(
            write,
            null,
            null,
            [],
            write.State == LocalEquipmentState.Unequipped));
        continue;
      }

      var definition = await ResolveSupportVersionAsync(
          connection,
          transaction,
          catalogs.Support.Id,
          write.EquipmentDefinitionUid!.Value,
          "equipment",
          cancellationToken).ConfigureAwait(false);
      await using var detail = new NpgsqlCommand(
          """
          SELECT
              equipment_slot,
              combat_class_status,
              combat_class_code,
              combat_class_unresolved_reason_code,
              manufacturer_status,
              manufacturer_code,
              manufacturer_unresolved_reason_code,
              tier_status,
              tier_value,
              tier_unresolved_reason_code,
              enhancement_status,
              maximum_enhancement_level,
              enhancement_unresolved_reason_code,
              overload_eligible_status,
              overload_eligible,
              overload_eligible_unresolved_reason_code
          FROM lab_combat_support.equipment_definition_detail
          WHERE definition_version_id = @version_id;
          """,
          connection,
          transaction);
      Add(detail, "version_id", NpgsqlDbType.Bigint, definition.VersionId);
      string? equipmentManufacturer;
      string equipmentManufacturerStatus;
      LocalProfileFact<int> equipmentTier;
      bool equipmentRoleReady;
      bool manufacturerSelectionResolved;
      var equipmentSelectionResolved = true;
      var overloadEligibleStatus = "unresolved";
      bool? overloadEligible = null;
      await using (var reader = await detail.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false))
      {
        if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false) ||
            reader.GetString(0) != LocalAccountProfileCanonicalizer.Code(write.Slot))
        {
          throw new LocalAccountProfileIntegrityException("profile_equipment_slot_mismatch");
        }

        var combatClassStatus = reader.GetString(1);
        if (combatClassStatus == "ready" && character.CombatClass is not null &&
            reader.GetString(2) != character.CombatClass)
        {
          throw new LocalAccountProfileIntegrityException("profile_equipment_class_mismatch");
        }

        if (combatClassStatus != "ready" || character.CombatClass is null)
        {
          issue ??= "profile_semantics_unresolved";
        }

        equipmentRoleReady = combatClassStatus == "ready" &&
            character.CombatClass is not null;
        if (combatClassStatus is not ("ready" or "unresolved"))
        {
          throw new LocalAccountProfileIntegrityException("profile_equipment_class_invalid");
        }

        equipmentManufacturerStatus = reader.GetString(4);
        equipmentManufacturer = equipmentManufacturerStatus == "ready" && !reader.IsDBNull(5)
            ? reader.GetString(5)
            : null;
        manufacturerSelectionResolved = equipmentManufacturerStatus == "not_applicable" ||
            (equipmentManufacturerStatus == "ready" && character.Manufacturer is not null);
        var tierStatus = reader.GetString(7);
        if (tierStatus == "ready" && !reader.IsDBNull(8) &&
            reader.GetInt32(8) is 9 or 10)
        {
          equipmentTier = LocalProfileFact<int>.Ready(reader.GetInt32(8));
        }
        else if (tierStatus == "unresolved" && !reader.IsDBNull(9))
        {
          equipmentTier = LocalProfileFact<int>.Unresolved(
              new LocalProfileReasonCode(reader.GetString(9)));
          equipmentSelectionResolved = false;
          issue ??= "profile_semantics_unresolved";
        }
        else
        {
          throw new LocalAccountProfileIntegrityException("profile_equipment_tier_invalid");
        }

        var enhancementStatus = reader.GetString(10);
        if (write.EnhancementLevel!.Status == LocalProfileFactStatus.Unresolved)
        {
          equipmentSelectionResolved = false;
          issue ??= "profile_semantics_unresolved";
        }
        else if (write.EnhancementLevel.Status != LocalProfileFactStatus.Ready)
        {
          throw new LocalAccountProfileIntegrityException("profile_equipment_level_invalid");
        }

        if (enhancementStatus == "ready" && !reader.IsDBNull(11))
        {
          if (write.EnhancementLevel.Value is { } selectedEnhancement &&
              selectedEnhancement > reader.GetInt32(11))
          {
            throw new LocalAccountProfileIntegrityException("profile_equipment_level_exceeds_cap");
          }
        }
        else if (enhancementStatus == "unresolved" && !reader.IsDBNull(12))
        {
          equipmentSelectionResolved = false;
          issue ??= "profile_semantics_unresolved";
        }
        else
        {
          throw new LocalAccountProfileIntegrityException("profile_equipment_cap_invalid");
        }

        overloadEligibleStatus = reader.GetString(13);
        overloadEligible = overloadEligibleStatus == "ready" && !reader.IsDBNull(14)
            ? reader.GetBoolean(14)
            : null;
      }

      if (write.ManufacturerMatched?.Value is { } manufacturerMatched)
      {
        if (equipmentManufacturerStatus == "ready" && character.Manufacturer is not null)
        {
          var expectedManufacturerMatch = equipmentManufacturer == character.Manufacturer;
          if (manufacturerMatched != expectedManufacturerMatch)
          {
            throw new LocalAccountProfileIntegrityException(
                "profile_equipment_manufacturer_mismatch");
          }
        }
        else if (equipmentManufacturerStatus == "unresolved" ||
                 equipmentManufacturerStatus == "ready")
        {
          issue ??= "profile_semantics_unresolved";
        }
        else if (equipmentManufacturerStatus != "not_applicable")
        {
          throw new LocalAccountProfileIntegrityException(
              "profile_equipment_manufacturer_unresolved");
        }
      }
      else if (gameLegal)
      {
        issue ??= "profile_semantics_unresolved";
      }

      if (write.OverloadLines.Count > 0 &&
          ((overloadEligibleStatus == "ready" && overloadEligible != true) ||
           (equipmentTier.Status == LocalProfileFactStatus.Ready && equipmentTier.Value != 10)))
      {
        throw new LocalAccountProfileIntegrityException("profile_overload_equipment_invalid");
      }

      if (write.OverloadLines.Count > 0 &&
          (overloadEligibleStatus != "ready" ||
           equipmentTier.Status != LocalProfileFactStatus.Ready))
      {
        equipmentSelectionResolved = false;
        issue ??= "profile_semantics_unresolved";
      }

      var overloads = new List<ResolvedOverload>(write.OverloadLines.Count);
      var optionTypeCounts = new Dictionary<string, int>(StringComparer.Ordinal);
      var forbiddenDuplicateTypes = new HashSet<string>(StringComparer.Ordinal);
      foreach (var line in write.OverloadLines)
      {
        var option = await ResolveSupportVersionAsync(
            connection,
            transaction,
            catalogs.Support.Id,
            line.OptionDefinitionUid,
            "overload_option",
            cancellationToken).ConfigureAwait(false);
        await using var optionDetail = new NpgsqlCommand(
            """
            SELECT
                option_type_status,
                option_type_code,
                option_type_unresolved_reason_code,
                unit_status,
                unit_code,
                unit_unresolved_reason_code,
                duplicate_policy_status,
                duplicate_policy_code
            FROM lab_combat_support.overload_option_definition_detail
            WHERE definition_version_id = @version_id;
            """,
            connection,
            transaction);
        Add(optionDetail, "version_id", NpgsqlDbType.Bigint, option.VersionId);
        string? optionType;
        string? optionTypeReason;
        bool unitResolved;
        string? unitReason;
        string? duplicatePolicy;
        await using (var optionReader = await optionDetail.ExecuteReaderAsync(cancellationToken)
            .ConfigureAwait(false))
        {
          if (!await optionReader.ReadAsync(cancellationToken).ConfigureAwait(false))
          {
            throw new LocalAccountProfileIntegrityException("profile_overload_detail_missing");
          }

          var optionTypeStatus = optionReader.GetString(0);
          if (optionTypeStatus == "ready" && !optionReader.IsDBNull(1))
          {
            optionType = optionReader.GetString(1);
            optionTypeReason = null;
          }
          else if (optionTypeStatus == "unresolved" && !optionReader.IsDBNull(2))
          {
            optionType = null;
            optionTypeReason = optionReader.GetString(2);
          }
          else
          {
            throw new LocalAccountProfileIntegrityException("profile_overload_type_invalid");
          }

          var unitStatus = optionReader.GetString(3);
          if (unitStatus == "ready" && !optionReader.IsDBNull(4))
          {
            if (optionReader.GetString(4) != LocalAccountProfileCanonicalizer.Code(line.Unit))
            {
              throw new LocalAccountProfileIntegrityException("profile_overload_unit_mismatch");
            }

            unitResolved = true;
            unitReason = null;
          }
          else if (unitStatus == "unresolved" && !optionReader.IsDBNull(5))
          {
            unitResolved = false;
            unitReason = optionReader.GetString(5);
          }
          else
          {
            throw new LocalAccountProfileIntegrityException("profile_overload_unit_invalid");
          }

          duplicatePolicy = optionReader.GetString(6) == "ready" && !optionReader.IsDBNull(7)
              ? optionReader.GetString(7)
              : null;
        }

        if (gameLegal)
        {
          if (optionType is null || !unitResolved)
          {
            issue ??= "profile_semantics_unresolved";
          }
          else
          {
            await using var legalValue = new NpgsqlCommand(
                """
                SELECT 1
                FROM lab_combat_support.overload_legal_value
                WHERE definition_version_id = @version_id
                  AND engine_fraction_unscaled_value::numeric *
                      power(10::numeric, @scale) =
                      @unscaled::numeric *
                      power(10::numeric, engine_fraction_decimal_scale);
                """,
                connection,
                transaction);
            Add(legalValue, "version_id", NpgsqlDbType.Bigint, option.VersionId);
            Add(legalValue, "unscaled", NpgsqlDbType.Bigint, line.ExactValue.UnscaledValue);
            Add(legalValue, "scale", NpgsqlDbType.Smallint,
                checked((short)line.ExactValue.DecimalScale));
            if (await legalValue.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false) is null)
            {
              throw new LocalAccountProfileIntegrityException("profile_overload_value_not_legal");
            }

            optionTypeCounts[optionType] = optionTypeCounts.GetValueOrDefault(optionType) + 1;
            if (duplicatePolicy == "forbid_same_type")
            {
              forbiddenDuplicateTypes.Add(optionType);
            }
          }
        }

        overloads.Add(new ResolvedOverload(
            line,
            option,
            optionType,
            optionTypeReason,
            unitResolved,
            unitReason));
      }

      if (optionTypeCounts.Any(item =>
              item.Value > 1 && forbiddenDuplicateTypes.Contains(item.Key)))
      {
        throw new LocalAccountProfileIntegrityException("profile_overload_duplicate_forbidden");
      }

      equipment.Add(new ResolvedEquipment(
          write,
          definition,
          equipmentTier,
          overloads,
          equipmentSelectionResolved && equipmentRoleReady && manufacturerSelectionResolved &&
          overloads.All(static item => item.IsSelectionResolved)));
    }

    var cube = await ValidateCubeAsync(
        connection,
        transaction,
        catalogs.Support,
        character,
        build.Cube,
        gameLegal,
        cancellationToken).ConfigureAwait(false);
    if (gameLegal && !cube.IsSelectionResolved)
    {
      issue ??= "profile_semantics_unresolved";
    }

    var collection = await ValidateCollectionAsync(
        connection,
        transaction,
        catalogs.Support,
        character,
        build.Collection,
        gameLegal,
        cancellationToken).ConfigureAwait(false);
    if (gameLegal && !collection.IsSelectionResolved)
    {
      issue ??= "profile_semantics_unresolved";
    }

    if (build.MaterializationPolicy == LocalProfileMaterializationPolicy.CombatMaxV1)
    {
      await ValidateCombatMaxPolicyAsync(
          connection,
          transaction,
          catalogs.Support.Id,
          build,
          character,
          equipment,
          cube,
          collection,
          cancellationToken).ConfigureAwait(false);
    }

    return new ValidatedBuild(
        character,
        equipment,
        cube,
        collection,
        scalarSelectionResolved,
        new ValidationResult(issue is null, issue));
  }

  private static async Task ValidateCombatMaxPolicyAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      long supportCatalogId,
      LocalCharacterBuildWrite build,
      CharacterVersion character,
      IReadOnlyList<ResolvedEquipment> equipment,
      ResolvedCube cube,
      ResolvedCollection collection,
      CancellationToken cancellationToken)
  {
    if (cube.Write.State != LocalOptionalSelectionState.Unequipped)
    {
      throw new LocalAccountProfileIntegrityException("profile_combat_max_policy_invalid");
    }

    RequireCombatMaxInvestmentFact(character, "limit_break", build.LimitBreak);
    RequireCombatMaxInvestmentFact(character, "core_level", build.CoreLevel);
    RequireCombatMaxInvestmentFact(character, "bond_level", build.BondLevel);
    RequireCombatMaxSkillFact(character, "skill_1", build.Skill1Level);
    RequireCombatMaxSkillFact(character, "skill_2", build.Skill2Level);
    RequireCombatMaxSkillFact(character, "burst", build.BurstLevel);

    foreach (var selectedEquipment in equipment)
    {
      if (character.CombatClass is null)
      {
        RequireCombatMaxUnresolvedEquipment(
            selectedEquipment.Write,
            "character_combat_role_unresolved");
        continue;
      }

      await using var candidates = new NpgsqlCommand(
          """
          SELECT member.definition_version_id
          FROM lab_combat_support.catalog_snapshot_member AS member
          JOIN lab_combat_support.definition_version AS version
            ON version.definition_version_id = member.definition_version_id
          JOIN lab_combat_support.equipment_definition_detail AS detail
            ON detail.definition_version_id = member.definition_version_id
          WHERE member.catalog_snapshot_id = @catalog_id
            AND member.definition_kind = 'equipment'
            AND version.profile_selectable_status = 'ready'
            AND detail.equipment_slot = @slot
            AND detail.tier_status = 'ready'
            AND detail.tier_value = 10
            AND detail.combat_class_status = 'ready'
            AND detail.combat_class_code = @combat_class
            AND detail.enhancement_status = 'ready'
            AND detail.maximum_enhancement_level >= 5;
          """,
          connection,
          transaction);
      Add(candidates, "catalog_id", NpgsqlDbType.Bigint, supportCatalogId);
      Add(candidates, "slot", NpgsqlDbType.Text,
          LocalAccountProfileCanonicalizer.Code(selectedEquipment.Write.Slot));
      Add(candidates, "combat_class", NpgsqlDbType.Text, character.CombatClass);
      var versionIds = new List<long>();
      await using var reader = await candidates.ExecuteReaderAsync(cancellationToken)
          .ConfigureAwait(false);
      while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
      {
        versionIds.Add(reader.GetInt64(0));
      }

      if (versionIds.Count != 1)
      {
        RequireCombatMaxUnresolvedEquipment(
            selectedEquipment.Write,
            versionIds.Count == 0
                ? "combat_max_equipment_definition_missing"
                : "combat_max_equipment_definition_ambiguous");
        continue;
      }

      if (selectedEquipment.Write.State != LocalEquipmentState.Equipped ||
          selectedEquipment.Definition is null ||
          versionIds[0] != selectedEquipment.Definition.Value.VersionId ||
          selectedEquipment.Tier?.Value != 10 ||
          selectedEquipment.Write.EnhancementLevel?.Status != LocalProfileFactStatus.Ready ||
          selectedEquipment.Write.EnhancementLevel!.Value != 5 ||
          selectedEquipment.Overloads.Count != 0)
      {
        throw new LocalAccountProfileIntegrityException("profile_combat_max_policy_invalid");
      }
    }

    if (!character.Capabilities.TryGetValue("favorite_item", out var favoriteCapability))
    {
      throw new LocalAccountProfileIntegrityException("profile_combat_max_policy_invalid");
    }

    if (favoriteCapability.Status == "ready")
    {
      await using var favorites = new NpgsqlCommand(
          """
          SELECT
              member.definition_version_id,
              detail.maximum_level_status,
              detail.maximum_level
          FROM lab_combat_support.catalog_snapshot_member AS member
          JOIN lab_combat_support.favorite_definition_detail AS detail
            ON detail.definition_version_id = member.definition_version_id
          WHERE member.catalog_snapshot_id = @catalog_id
            AND member.definition_kind = 'favorite'
            AND detail.applicable_character_status = 'ready'
            AND detail.applicable_character_entity_id = @character_entity_id;
          """,
          connection,
          transaction);
      Add(favorites, "catalog_id", NpgsqlDbType.Bigint, supportCatalogId);
      Add(favorites, "character_entity_id", NpgsqlDbType.Bigint, character.EntityId);
      var rows = new List<(long VersionId, string MaximumStatus, int? MaximumLevel)>();
      await using var favoriteReader = await favorites.ExecuteReaderAsync(cancellationToken)
          .ConfigureAwait(false);
      while (await favoriteReader.ReadAsync(cancellationToken).ConfigureAwait(false))
      {
        rows.Add((
            favoriteReader.GetInt64(0),
            favoriteReader.GetString(1),
            favoriteReader.IsDBNull(2) ? null : favoriteReader.GetInt32(2)));
      }

      if (rows.Count != 1 || rows[0].MaximumStatus != "ready" ||
          rows[0].MaximumLevel is null)
      {
        RequireCombatMaxUnresolvedCollection(
            collection.Write,
            "favorite_selection_not_unique");
        return;
      }

      if (collection.Write.Kind != LocalCollectionSelectionKind.Favorite ||
          collection.Definition is null ||
          rows[0].VersionId != collection.Definition.Value.VersionId ||
          collection.DefinitionMaximumLevel != rows[0].MaximumLevel ||
          collection.Write.Level?.Status != LocalProfileFactStatus.Ready ||
          collection.Write.Level!.Value != rows[0].MaximumLevel)
      {
        throw new LocalAccountProfileIntegrityException("profile_combat_max_policy_invalid");
      }

      return;
    }

    if (favoriteCapability.Status == "unresolved")
    {
      RequireCombatMaxUnresolvedCollection(
          collection.Write,
          favoriteCapability.UnresolvedReasonCode ?? "favorite_applicability_unresolved");
      return;
    }

    if (favoriteCapability.Status != "not_applicable" ||
        !character.Capabilities.TryGetValue("collection_item", out var collectionCapability))
    {
      throw new LocalAccountProfileIntegrityException("profile_combat_max_policy_invalid");
    }

    if (collectionCapability.Status == "not_applicable")
    {
      if (collection.Write.Kind != LocalCollectionSelectionKind.NotApplicable)
      {
        throw new LocalAccountProfileIntegrityException("profile_combat_max_policy_invalid");
      }

      return;
    }

    if (collectionCapability.Status == "unresolved")
    {
      RequireCombatMaxUnresolvedCollection(
          collection.Write,
          collectionCapability.UnresolvedReasonCode ?? "collection_applicability_unresolved");
      return;
    }

    if (collectionCapability.Status != "ready")
    {
      throw new LocalAccountProfileIntegrityException("profile_combat_max_policy_invalid");
    }

    if (character.Weapon is null)
    {
      RequireCombatMaxUnresolvedCollection(collection.Write, "collection_weapon_unresolved");
      return;
    }

    await using (var candidates = new NpgsqlCommand(
          """
          SELECT
              member.definition_version_id,
              detail.rarity_code,
              detail.maximum_level_status,
              detail.maximum_level
          FROM lab_combat_support.catalog_snapshot_member AS member
          JOIN lab_combat_support.collection_definition_detail AS detail
            ON detail.definition_version_id = member.definition_version_id
          WHERE member.catalog_snapshot_id = @catalog_id
            AND member.definition_kind = 'collection'
            AND detail.weapon_class_status = 'ready'
            AND detail.weapon_class_code = @weapon
            AND detail.rarity_status = 'ready';
          """,
          connection,
          transaction))
    {
      Add(candidates, "catalog_id", NpgsqlDbType.Bigint, supportCatalogId);
      Add(candidates, "weapon", NpgsqlDbType.Text, character.Weapon);
      var rows = new List<(long VersionId, int Rarity, string MaximumStatus, int? MaximumLevel)>();
      await using var candidateReader = await candidates.ExecuteReaderAsync(cancellationToken)
          .ConfigureAwait(false);
      while (await candidateReader.ReadAsync(cancellationToken).ConfigureAwait(false))
      {
        rows.Add((
            candidateReader.GetInt64(0),
            candidateReader.GetString(1) switch
            {
              "r" => 0,
              "sr" => 1,
              "ssr" => 2,
              _ => throw new LocalAccountProfileIntegrityException(
                  "profile_collection_rarity_invalid")
            },
            candidateReader.GetString(2),
            candidateReader.IsDBNull(3) ? null : candidateReader.GetInt32(3)));
      }

      if (rows.Count == 0)
      {
        RequireCombatMaxUnresolvedCollection(
            collection.Write,
            "collection_selection_missing");
        return;
      }

      var maximumRarity = rows.Max(static item => item.Rarity);
      var maxima = rows.Where(item => item.Rarity == maximumRarity).ToArray();
      if (maxima.Length != 1 || maxima[0].MaximumStatus != "ready" ||
          maxima[0].MaximumLevel is null)
      {
        RequireCombatMaxUnresolvedCollection(
            collection.Write,
            "collection_selection_not_unique");
        return;
      }

      if (collection.Write.Kind != LocalCollectionSelectionKind.GenericCollection ||
          collection.Definition is null ||
          maxima[0].VersionId != collection.Definition.Value.VersionId ||
          collection.DefinitionMaximumLevel != maxima[0].MaximumLevel ||
          collection.Write.Level?.Status != LocalProfileFactStatus.Ready ||
          collection.Write.Level!.Value != maxima[0].MaximumLevel)
      {
        throw new LocalAccountProfileIntegrityException("profile_combat_max_policy_invalid");
      }
    }
  }

  private static void RequireCombatMaxInvestmentFact(
      CharacterVersion character,
      string capabilityCode,
      LocalProfileFact<int> fact)
  {
    if (!character.Capabilities.TryGetValue(capabilityCode, out var capability))
    {
      throw new LocalAccountProfileIntegrityException("profile_combat_max_policy_invalid");
    }

    var valid = capability.Status switch
    {
      "ready" => capability.MaximumLevel is { } maximum &&
          fact.Status == LocalProfileFactStatus.Ready && fact.Value == maximum,
      "unresolved" => IsUnresolvedFact(
          fact,
          capability.UnresolvedReasonCode ?? "character_fact_unresolved"),
      "not_applicable" => fact.Status == LocalProfileFactStatus.NotApplicable,
      _ => false
    };
    if (!valid)
    {
      throw new LocalAccountProfileIntegrityException("profile_combat_max_policy_invalid");
    }
  }

  private static void RequireCombatMaxSkillFact(
      CharacterVersion character,
      string capabilityCode,
      LocalProfileFact<int> fact)
  {
    if (!character.Capabilities.TryGetValue(capabilityCode, out var capability))
    {
      throw new LocalAccountProfileIntegrityException("profile_combat_max_policy_invalid");
    }

    var valid = capability.Status switch
    {
      "ready" when capability.MaximumLevel >= 10 =>
          fact.Status == LocalProfileFactStatus.Ready && fact.Value == 10,
      "ready" => IsUnresolvedFact(fact, "level_ten_unsupported"),
      "unresolved" => IsUnresolvedFact(
          fact,
          capability.UnresolvedReasonCode ?? "skill_maximum_unresolved"),
      "not_applicable" => IsUnresolvedFact(fact, "skill_not_applicable"),
      _ => false
    };
    if (!valid)
    {
      throw new LocalAccountProfileIntegrityException("profile_combat_max_policy_invalid");
    }
  }

  private static void RequireCombatMaxUnresolvedEquipment(
      LocalEquipmentWrite equipment,
      string reasonCode)
  {
    if (equipment.State != LocalEquipmentState.Unresolved ||
        equipment.UnresolvedReasonCode?.Code != reasonCode)
    {
      throw new LocalAccountProfileIntegrityException("profile_combat_max_policy_invalid");
    }
  }

  private static void RequireCombatMaxUnresolvedCollection(
      LocalCollectionSelectionWrite collection,
      string reasonCode)
  {
    if (collection.Kind != LocalCollectionSelectionKind.Unresolved ||
        collection.UnresolvedReasonCode?.Code != reasonCode)
    {
      throw new LocalAccountProfileIntegrityException("profile_combat_max_policy_invalid");
    }
  }

  private static bool IsUnresolvedFact(LocalProfileFact<int> fact, string reasonCode) =>
      fact.Status == LocalProfileFactStatus.Unresolved &&
      fact.ReasonCode?.Code == reasonCode;

  private static async Task<ResolvedCube> ValidateCubeAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      CatalogRow supportCatalog,
      CharacterVersion character,
      LocalCubeSelectionWrite write,
      bool gameLegal,
      CancellationToken cancellationToken)
  {
    if (write.State != LocalOptionalSelectionState.Equipped)
    {
      var detached = write.State == LocalOptionalSelectionState.Unequipped;
      return new ResolvedCube(write, null, detached, detached);
    }

    var definition = await ResolveSupportVersionAsync(
        connection,
        transaction,
        supportCatalog.Id,
        write.DefinitionUid!.Value,
        "cube",
        cancellationToken).ConfigureAwait(false);
    await using var detail = new NpgsqlCommand(
        """
        SELECT
            applicable_combat_class_status,
            applicable_combat_class_code,
            maximum_level_status,
            maximum_level,
            skill_semantics_status
        FROM lab_combat_support.cube_definition_detail
        WHERE definition_version_id = @version_id;
        """,
        connection,
        transaction);
    Add(detail, "version_id", NpgsqlDbType.Bigint, definition.VersionId);
    await using var reader = await detail.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
    if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      throw new LocalAccountProfileIntegrityException("profile_cube_detail_missing");
    }

    var applicabilityStatus = reader.GetString(0);
    var applicabilityResolved = applicabilityStatus == "not_applicable" ||
        (applicabilityStatus == "ready" && character.CombatClass is not null &&
         !reader.IsDBNull(1));
    if (applicabilityStatus == "ready" && character.CombatClass is not null &&
        !reader.IsDBNull(1) && reader.GetString(1) != character.CombatClass)
    {
      throw new LocalAccountProfileIntegrityException("profile_cube_class_mismatch");
    }

    if (applicabilityStatus is not ("ready" or "not_applicable" or "unresolved"))
    {
      throw new LocalAccountProfileIntegrityException("profile_cube_applicability_unresolved");
    }

    var selectionResolved = applicabilityResolved;
    var maximumStatus = reader.GetString(2);
    var selectedLevel = write.Level!;
    if (selectedLevel.Status == LocalProfileFactStatus.Unresolved)
    {
      selectionResolved = false;
    }
    else if (selectedLevel.Status != LocalProfileFactStatus.Ready)
    {
      throw new LocalAccountProfileIntegrityException("profile_cube_level_invalid");
    }

    if (maximumStatus == "ready" && !reader.IsDBNull(3))
    {
      if (selectedLevel.Value is { } resolvedLevel &&
          resolvedLevel > Math.Min(15, reader.GetInt32(3)))
      {
        throw new LocalAccountProfileIntegrityException("profile_cube_level_exceeds_cap");
      }
    }
    else if (maximumStatus == "unresolved")
    {
      selectionResolved = false;
    }
    else
    {
      throw new LocalAccountProfileIntegrityException("profile_cube_cap_invalid");
    }

    var semanticsReady = reader.GetString(4) == "ready";
    await reader.DisposeAsync().ConfigureAwait(false);
    if (!character.Capabilities.TryGetValue("cube", out var cubeCapability))
    {
      throw new LocalAccountProfileIntegrityException("profile_character_cap_missing");
    }

    if (cubeCapability.Status == "ready" && cubeCapability.MaximumLevel is { } cubeMaximum)
    {
      if (selectedLevel.Value is { } resolvedLevel && resolvedLevel > cubeMaximum)
      {
        throw new LocalAccountProfileIntegrityException("profile_cube_level_exceeds_character_cap");
      }
    }
    else if (cubeCapability.Status == "unresolved")
    {
      selectionResolved = false;
    }
    else
    {
      throw new LocalAccountProfileIntegrityException("profile_cube_character_cap_invalid");
    }

    if (selectedLevel.Value is { } coordinateLevel && maximumStatus == "ready")
    {
      await using var coordinate = new NpgsqlCommand(
          """
          SELECT 1
          FROM lab_combat_support.definition_level_coordinate
          WHERE definition_version_id = @version_id
            AND level = @level;
          """,
          connection,
          transaction);
      Add(coordinate, "version_id", NpgsqlDbType.Bigint, definition.VersionId);
      Add(coordinate, "level", NpgsqlDbType.Integer, coordinateLevel);
      if (await coordinate.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false) is null)
      {
        throw new LocalAccountProfileIntegrityException("profile_cube_level_not_in_catalog");
      }
    }

    return new ResolvedCube(write, definition, selectionResolved, semanticsReady);
  }

  private static async Task<ResolvedCollection> ValidateCollectionAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      CatalogRow supportCatalog,
      CharacterVersion character,
      LocalCollectionSelectionWrite write,
      bool gameLegal,
      CancellationToken cancellationToken)
  {
    if (write.Kind == LocalCollectionSelectionKind.NotApplicable)
    {
      if (!character.Capabilities.TryGetValue("collection_item", out var collectionCapability) ||
          !character.Capabilities.TryGetValue("favorite_item", out var favoriteCapability) ||
          collectionCapability.Status != "not_applicable" ||
          favoriteCapability.Status != "not_applicable")
      {
        throw new LocalAccountProfileIntegrityException("profile_collectible_is_applicable");
      }

      return new ResolvedCollection(write, null, null, true, true);
    }

    if (write.Kind is LocalCollectionSelectionKind.Detached or
        LocalCollectionSelectionKind.Unresolved)
    {
      return new ResolvedCollection(
          write,
          null,
          null,
          write.Kind == LocalCollectionSelectionKind.Detached,
          write.Kind == LocalCollectionSelectionKind.Detached);
    }

    var kind = write.Kind == LocalCollectionSelectionKind.GenericCollection
        ? "collection"
        : "favorite";
    var definition = await ResolveSupportVersionAsync(
        connection,
        transaction,
        supportCatalog.Id,
        write.DefinitionUid!.Value,
        kind,
        cancellationToken).ConfigureAwait(false);
    var sql = kind == "collection"
        ? """
          SELECT
              weapon_class_status,
              weapon_class_code,
              maximum_level_status,
              maximum_level,
              skill_semantics_status
          FROM lab_combat_support.collection_definition_detail
          WHERE definition_version_id = @version_id;
          """
        : """
          SELECT
              applicable_character_status,
              applicable_character_entity_id,
              maximum_level_status,
              maximum_level,
              skill_semantics_status
          FROM lab_combat_support.favorite_definition_detail
          WHERE definition_version_id = @version_id;
          """;
    await using var detail = new NpgsqlCommand(sql, connection, transaction);
    Add(detail, "version_id", NpgsqlDbType.Bigint, definition.VersionId);
    await using var reader = await detail.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
    if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      throw new LocalAccountProfileIntegrityException("profile_collection_detail_missing");
    }

    var applicabilityStatus = reader.GetString(0);
    var selectionResolved = applicabilityStatus == "ready" && !reader.IsDBNull(1);

    if (kind == "collection")
    {
      if (applicabilityStatus == "ready" && character.Weapon is not null &&
          reader.GetString(1) != character.Weapon)
      {
        throw new LocalAccountProfileIntegrityException("profile_collection_weapon_mismatch");
      }

      selectionResolved &= character.Weapon is not null;
    }
    else if (applicabilityStatus == "ready" && reader.GetInt64(1) != character.EntityId)
    {
      throw new LocalAccountProfileIntegrityException("profile_favorite_character_mismatch");
    }

    if (applicabilityStatus is not ("ready" or "unresolved"))
    {
      throw new LocalAccountProfileIntegrityException("profile_collection_applicability_invalid");
    }

    var selectedLevel = write.Level!;
    if (selectedLevel.Status == LocalProfileFactStatus.Unresolved)
    {
      selectionResolved = false;
    }
    else if (selectedLevel.Status != LocalProfileFactStatus.Ready)
    {
      throw new LocalAccountProfileIntegrityException("profile_collection_level_invalid");
    }

    var maximumStatus = reader.GetString(2);
    int? definitionMaximumLevel = null;
    if (maximumStatus == "ready" && !reader.IsDBNull(3))
    {
      definitionMaximumLevel = reader.GetInt32(3);
      if (selectedLevel.Value is { } resolvedLevel && resolvedLevel > definitionMaximumLevel)
      {
        throw new LocalAccountProfileIntegrityException("profile_collection_level_exceeds_cap");
      }
    }
    else if (maximumStatus == "unresolved")
    {
      selectionResolved = false;
    }
    else
    {
      throw new LocalAccountProfileIntegrityException("profile_collection_cap_invalid");
    }

    var semanticsReady = reader.GetString(4) == "ready";
    await reader.DisposeAsync().ConfigureAwait(false);
    var capabilityCode = kind == "collection" ? "collection_item" : "favorite_item";
    if (!character.Capabilities.TryGetValue(capabilityCode, out var capability))
    {
      throw new LocalAccountProfileIntegrityException("profile_character_cap_missing");
    }

    if (capability.Status == "ready" && capability.MaximumLevel is { } characterMaximum)
    {
      if (selectedLevel.Value is { } resolvedLevel && resolvedLevel > characterMaximum)
      {
        throw new LocalAccountProfileIntegrityException(
            "profile_collection_level_exceeds_character_cap");
      }
    }
    else if (capability.Status == "unresolved")
    {
      selectionResolved = false;
    }
    else
    {
      throw new LocalAccountProfileIntegrityException(
          "profile_collection_character_cap_invalid");
    }

    if (selectedLevel.Value is { } coordinateLevel && maximumStatus == "ready")
    {
      await using var coordinate = new NpgsqlCommand(
          """
          SELECT 1
          FROM lab_combat_support.definition_level_coordinate
          WHERE definition_version_id = @version_id
            AND level = @level;
          """,
          connection,
          transaction);
      Add(coordinate, "version_id", NpgsqlDbType.Bigint, definition.VersionId);
      Add(coordinate, "level", NpgsqlDbType.Integer, coordinateLevel);
      if (await coordinate.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false) is null)
      {
        throw new LocalAccountProfileIntegrityException("profile_collection_level_not_in_catalog");
      }
    }

    return new ResolvedCollection(
        write,
        definition,
        definitionMaximumLevel,
        selectionResolved,
        semanticsReady);
  }

  private static bool ValidateCharacterLevelCapability(
      CharacterVersion character,
      int value,
      bool gameLegal,
      ref string? issue)
  {
    if (!character.Capabilities.TryGetValue("character_level", out var capability))
    {
      throw new LocalAccountProfileIntegrityException("profile_character_cap_missing");
    }

    if (capability.Status == "unresolved")
    {
      if (gameLegal)
      {
        issue ??= "profile_semantics_unresolved";
      }

      return false;
    }

    if (capability.Status != "ready" || capability.MaximumLevel is null)
    {
      throw new LocalAccountProfileIntegrityException("profile_character_cap_invalid");
    }

    if (value > capability.MaximumLevel.Value)
    {
      throw new LocalAccountProfileIntegrityException("profile_character_level_exceeds_cap");
    }

    return true;
  }

  private static bool ValidateFactCapability(
      CharacterVersion character,
      string code,
      LocalProfileFact<int> fact,
      bool gameLegal,
      bool allowNotApplicable,
      ref string? issue)
  {
    if (!character.Capabilities.TryGetValue(code, out var capability))
    {
      throw new LocalAccountProfileIntegrityException("profile_character_cap_missing");
    }

    if (fact.Status == LocalProfileFactStatus.Ready)
    {
      if (capability.Status != "ready" || capability.MaximumLevel is null)
      {
        if (capability.Status == "unresolved")
        {
          if (gameLegal)
          {
            issue ??= "profile_semantics_unresolved";
          }

          return false;
        }

        throw new LocalAccountProfileIntegrityException("profile_character_cap_invalid");
      }

      if (fact.Value!.Value > capability.MaximumLevel.Value)
      {
        throw new LocalAccountProfileIntegrityException("profile_character_level_exceeds_cap");
      }
    }
    else if (fact.Status == LocalProfileFactStatus.NotApplicable)
    {
      if (!allowNotApplicable ||
          (capability.Status != "not_applicable" &&
           !(code == "bond_level" && character.Rarity == "r")))
      {
        throw new LocalAccountProfileIntegrityException("profile_character_fact_not_applicable");
      }
    }
    else
    {
      if (gameLegal)
      {
        issue ??= "profile_semantics_unresolved";
      }

      return false;
    }

    return true;
  }

  private async Task<StoredBuild> StoreBuildAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      long accountId,
      CatalogPair catalogs,
      LocalCharacterBuildWrite build,
      DateTimeOffset createdAtUtc,
      CancellationToken cancellationToken)
  {
    var validated = await ValidateBuildAsync(
        connection,
        transaction,
        catalogs,
        build,
        cancellationToken).ConfigureAwait(false);
    var logical = await ResolveBuildLogicalAsync(
        connection,
        transaction,
        accountId,
        validated.Character.EntityId,
        createdAtUtc,
        cancellationToken).ConfigureAwait(false);
    var content = ProjectBuild(catalogs, build, validated, logical.Slots);
    var hash = DomainProfile.ProfileCanonicalizer.ComputeContentHash(content);
    if (logical.CurrentRevisionId is { } currentId && logical.CurrentContentSha256 == hash)
    {
      return await ReadStoredBuildAsync(
          connection,
          transaction,
          currentId,
          build.CharacterUid,
          logical,
          cancellationToken).ConfigureAwait(false);
    }

    var selectionReady = IsSelectionReady(build, validated);
    var semanticsReady = HasCombatSemantics(build, validated);
    var selectionIssue = selectionReady ? null : "profile_selection_unresolved";
    var semanticsIssue = semanticsReady ? null : "profile_semantics_unresolved";
    var revisionUid = _uidGenerator.NewUid();
    var revisionNumber = (logical.CurrentRevisionNumber ?? 0) + 1;
    long revisionId;
    await using (var insert = new NpgsqlCommand(
        """
        INSERT INTO lab_profile.character_build_revision (
            build_revision_uid,
            character_build_id,
            revision_number,
            previous_build_revision_id,
            character_entity_id,
            character_catalog_snapshot_id,
            character_dataset_snapshot_id,
            character_catalog_manifest_sha256,
            character_definition_version_id,
            support_catalog_snapshot_id,
            support_dataset_snapshot_id,
            support_catalog_manifest_sha256,
            character_level,
            limit_break_status,
            limit_break_level,
            limit_break_unresolved_reason_code,
            core_level_status,
            core_level,
            core_level_unresolved_reason_code,
            bond_level_status,
            bond_level,
            bond_level_unresolved_reason_code,
            skill_1_status,
            skill_1_level,
            skill_1_unresolved_reason_code,
            skill_2_status,
            skill_2_level,
            skill_2_unresolved_reason_code,
            burst_status,
            burst_level,
            burst_unresolved_reason_code,
            materialization_policy,
            cube_state,
            cube_definition_entity_id,
            cube_definition_version_id,
            cube_definition_kind,
            cube_level_status,
            cube_level,
            cube_level_unresolved_reason_code,
            cube_unresolved_reason_code,
            collection_kind,
            collection_definition_entity_id,
            collection_definition_version_id,
            collection_definition_kind,
            collection_level_status,
            collection_level,
            collection_level_unresolved_reason_code,
            collection_unresolved_reason_code,
            validation_mode,
            selection_readiness_status,
            selection_readiness_issue_code,
            combat_semantics_readiness_status,
            combat_semantics_readiness_issue_code,
            game_legal_readiness_status,
            game_legal_issue_code,
            equipment_count,
            content_sha256,
            revision_origin,
            materialized_at_utc
        ) VALUES (
            @revision_uid, @build_id, @revision_number, @previous_revision_id,
            @character_entity_id,
            @character_catalog_id, @character_dataset_id, @character_manifest,
            @character_version_id,
            @support_catalog_id, @support_dataset_id, @support_manifest,
            @character_level,
            @limit_break_status, @limit_break_value, @limit_break_reason,
            @core_level_status, @core_level_value, @core_level_reason,
            @bond_level_status, @bond_level_value, @bond_level_reason,
            @skill_1_status, @skill_1_value, @skill_1_reason,
            @skill_2_status, @skill_2_value, @skill_2_reason,
            @burst_status, @burst_value, @burst_reason,
            @materialization_policy,
            @cube_state, @cube_entity_id, @cube_version_id, @cube_kind,
            @cube_level_status, @cube_level_value, @cube_level_reason, @cube_reason,
            @collection_kind, @collection_entity_id, @collection_version_id,
            @collection_definition_kind,
            @collection_level_status, @collection_level_value, @collection_level_reason,
            @collection_reason,
            @validation_mode,
            @selection_readiness, @selection_issue,
            @semantics_readiness, @semantics_issue,
            @game_legal_readiness, @game_legal_issue,
            4, @content_hash, @origin, @created_at
        )
        RETURNING build_revision_id;
        """,
        connection,
        transaction))
    {
      Add(insert, "revision_uid", NpgsqlDbType.Uuid, revisionUid.Value);
      Add(insert, "build_id", NpgsqlDbType.Bigint, logical.Id);
      Add(insert, "revision_number", NpgsqlDbType.Integer, revisionNumber);
      Add(insert, "previous_revision_id", NpgsqlDbType.Bigint, logical.CurrentRevisionId);
      Add(insert, "character_entity_id", NpgsqlDbType.Bigint, validated.Character.EntityId);
      AddCatalogParameters(insert, "character", catalogs.Character);
      Add(insert, "character_version_id", NpgsqlDbType.Bigint,
          validated.Character.VersionId);
      AddCatalogParameters(insert, "support", catalogs.Support);
      Add(insert, "character_level", NpgsqlDbType.Integer, build.CharacterLevel);
      AddFactParameters(insert, "limit_break", build.LimitBreak, NpgsqlDbType.Integer);
      AddFactParameters(insert, "core_level", build.CoreLevel, NpgsqlDbType.Integer);
      AddFactParameters(insert, "bond_level", build.BondLevel, NpgsqlDbType.Integer);
      AddFactParameters(insert, "skill_1", build.Skill1Level, NpgsqlDbType.Integer);
      AddFactParameters(insert, "skill_2", build.Skill2Level, NpgsqlDbType.Integer);
      AddFactParameters(insert, "burst", build.BurstLevel, NpgsqlDbType.Integer);
      Add(insert, "materialization_policy", NpgsqlDbType.Text,
          LocalAccountProfileCanonicalizer.Code(build.MaterializationPolicy));
      Add(insert, "cube_state", NpgsqlDbType.Text,
          LocalAccountProfileCanonicalizer.Code(build.Cube.State));
      Add(insert, "cube_entity_id", NpgsqlDbType.Bigint,
          validated.Cube.Definition?.EntityId);
      Add(insert, "cube_version_id", NpgsqlDbType.Bigint,
          validated.Cube.Definition?.VersionId);
      Add(insert, "cube_kind", NpgsqlDbType.Text,
          validated.Cube.Definition is null ? null : "cube");
      AddOptionalFactParameters(insert, "cube_level", build.Cube.Level, NpgsqlDbType.Integer);
      Add(insert, "cube_reason", NpgsqlDbType.Text,
          ReasonCode(build.Cube.UnresolvedReasonCode));
      Add(insert, "collection_kind", NpgsqlDbType.Text,
          CollectionKindCode(build.Collection.Kind));
      Add(insert, "collection_entity_id", NpgsqlDbType.Bigint,
          validated.Collection.Definition?.EntityId);
      Add(insert, "collection_version_id", NpgsqlDbType.Bigint,
          validated.Collection.Definition?.VersionId);
      Add(insert, "collection_definition_kind", NpgsqlDbType.Text,
          validated.Collection.Definition?.Kind);
      AddOptionalFactParameters(
          insert,
          "collection_level",
          build.Collection.Level,
          NpgsqlDbType.Integer);
      Add(insert, "collection_reason", NpgsqlDbType.Text,
          ReasonCode(build.Collection.UnresolvedReasonCode));
      Add(insert, "validation_mode", NpgsqlDbType.Text,
          LocalAccountProfileCanonicalizer.Code(build.ValidationMode));
      Add(insert, "selection_readiness", NpgsqlDbType.Text,
          selectionReady ? "ready" : "unresolved");
      Add(insert, "selection_issue", NpgsqlDbType.Text, selectionIssue);
      Add(insert, "semantics_readiness", NpgsqlDbType.Text,
          semanticsReady ? "ready" : "unresolved");
      Add(insert, "semantics_issue", NpgsqlDbType.Text, semanticsIssue);
      Add(insert, "game_legal_readiness", NpgsqlDbType.Text,
          validated.Validation.IsReady ? "ready" : "unresolved");
      Add(insert, "game_legal_issue", NpgsqlDbType.Text,
          validated.Validation.IssueCode);
      Add(insert, "content_hash", NpgsqlDbType.Bytea, hash.ToByteArray());
      Add(insert, "origin", NpgsqlDbType.Text,
          LocalAccountProfileCanonicalizer.Code(build.Origin));
      Add(insert, "created_at", NpgsqlDbType.TimestampTz, createdAtUtc);
      revisionId = Convert.ToInt64(
          await insert.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false),
          System.Globalization.CultureInfo.InvariantCulture);
    }

    foreach (var equipment in validated.Equipment)
    {
      var slot = logical.Slots.Single(item => item.Slot == equipment.Write.Slot);
      long equipmentStateId;
      await using (var insert = new NpgsqlCommand(
          """
          INSERT INTO lab_profile.build_equipment_state (
              build_revision_id,
              character_build_id,
              equipment_slot_id,
              slot_code,
              support_catalog_snapshot_id,
              equipment_state,
              definition_entity_id,
              definition_version_id,
              definition_kind,
              enhancement_level_status,
              enhancement_level,
              enhancement_level_unresolved_reason_code,
              manufacturer_matched_status,
              manufacturer_matched,
              manufacturer_matched_unresolved_reason_code,
              equipment_unresolved_reason_code,
              overload_line_count
          ) VALUES (
              @revision_id, @build_id, @slot_id, @slot_code, @support_catalog_id,
              @equipment_state, @definition_entity_id, @definition_version_id,
              @definition_kind,
              @enhancement_level_status, @enhancement_level_value, @enhancement_level_reason,
              @manufacturer_status, @manufacturer_value, @manufacturer_reason,
              @equipment_reason, @overload_count
          )
          RETURNING build_equipment_state_id;
          """,
          connection,
          transaction))
      {
        Add(insert, "revision_id", NpgsqlDbType.Bigint, revisionId);
        Add(insert, "build_id", NpgsqlDbType.Bigint, logical.Id);
        Add(insert, "slot_id", NpgsqlDbType.Bigint, slot.Id);
        Add(insert, "slot_code", NpgsqlDbType.Text,
            LocalAccountProfileCanonicalizer.Code(equipment.Write.Slot));
        Add(insert, "support_catalog_id", NpgsqlDbType.Bigint, catalogs.Support.Id);
        Add(insert, "equipment_state", NpgsqlDbType.Text,
            LocalAccountProfileCanonicalizer.Code(equipment.Write.State));
        Add(insert, "definition_entity_id", NpgsqlDbType.Bigint,
            equipment.Definition?.EntityId);
        Add(insert, "definition_version_id", NpgsqlDbType.Bigint,
            equipment.Definition?.VersionId);
        Add(insert, "definition_kind", NpgsqlDbType.Text,
            equipment.Definition?.Kind);
        Add(insert, "enhancement_level_status", NpgsqlDbType.Text,
            equipment.Write.EnhancementLevel is null
                ? null
                : LocalAccountProfileCanonicalizer.Code(
                    equipment.Write.EnhancementLevel.Status));
        Add(insert, "enhancement_level_value", NpgsqlDbType.Smallint,
            equipment.Write.EnhancementLevel?.Value is { } enhancement
                ? checked((short)enhancement)
                : null);
        Add(insert, "enhancement_level_reason", NpgsqlDbType.Text,
            equipment.Write.EnhancementLevel is null
                ? null
                : ReasonCode(equipment.Write.EnhancementLevel.ReasonCode));
        AddOptionalFactParameters(
            insert,
            "manufacturer",
            equipment.Write.ManufacturerMatched,
            NpgsqlDbType.Boolean);
        Add(insert, "equipment_reason", NpgsqlDbType.Text,
            ReasonCode(equipment.Write.UnresolvedReasonCode));
        Add(insert, "overload_count", NpgsqlDbType.Smallint,
            checked((short)equipment.Overloads.Count));
        equipmentStateId = Convert.ToInt64(
            await insert.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false),
            System.Globalization.CultureInfo.InvariantCulture);
      }

      foreach (var overload in equipment.Overloads)
      {
        await using var insert = new NpgsqlCommand(
            """
            INSERT INTO lab_profile.build_overload_line (
                build_equipment_state_id,
                support_catalog_snapshot_id,
                line_index,
                definition_entity_id,
                definition_version_id,
                definition_kind,
                unit_code,
                exact_unscaled_value,
                exact_decimal_scale
            ) VALUES (
                @equipment_state_id, @support_catalog_id, @line_index,
                @entity_id, @version_id, 'overload_option', @unit_code,
                @unscaled, @scale
            );
            """,
            connection,
            transaction);
        Add(insert, "equipment_state_id", NpgsqlDbType.Bigint, equipmentStateId);
        Add(insert, "support_catalog_id", NpgsqlDbType.Bigint, catalogs.Support.Id);
        Add(insert, "line_index", NpgsqlDbType.Smallint,
            checked((short)overload.Write.LineIndex));
        Add(insert, "entity_id", NpgsqlDbType.Bigint, overload.Definition.EntityId);
        Add(insert, "version_id", NpgsqlDbType.Bigint, overload.Definition.VersionId);
        Add(insert, "unit_code", NpgsqlDbType.Text,
            LocalAccountProfileCanonicalizer.Code(overload.Write.Unit));
        Add(insert, "unscaled", NpgsqlDbType.Bigint,
            overload.Write.ExactValue.UnscaledValue);
        Add(insert, "scale", NpgsqlDbType.Smallint,
            checked((short)overload.Write.ExactValue.DecimalScale));
        await insert.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
      }
    }

    return new StoredBuild(
        logical.Id,
        logical.Uid,
        build.CharacterUid,
        revisionId,
        revisionUid,
        new LocalRevisionLineage(
            revisionNumber,
            logical.CurrentRevisionUid,
            build.Origin,
            createdAtUtc),
        hash,
        selectionReady,
        semanticsReady,
        validated.Validation.IsReady,
        CompactIssues(selectionIssue, semanticsIssue, validated.Validation.IssueCode),
        logical.Slots);
  }

  private async Task<BuildLogical> ResolveBuildLogicalAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      long accountId,
      long characterEntityId,
      DateTimeOffset createdAtUtc,
      CancellationToken cancellationToken)
  {
    await using (var read = new NpgsqlCommand(
        """
        SELECT
            build.character_build_id,
            build.character_build_uid,
            build.current_build_revision_id,
            revision.build_revision_uid,
            revision.revision_number,
            revision.content_sha256
        FROM lab_profile.character_build AS build
        LEFT JOIN lab_profile.character_build_revision AS revision
          ON revision.build_revision_id = build.current_build_revision_id
        WHERE build.local_account_id = @account_id
          AND build.character_entity_id = @character_entity_id
        FOR UPDATE OF build;
        """,
        connection,
        transaction))
    {
      Add(read, "account_id", NpgsqlDbType.Bigint, accountId);
      Add(read, "character_entity_id", NpgsqlDbType.Bigint, characterEntityId);
      await using var reader = await read.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
      if (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
      {
        var id = reader.GetInt64(0);
        var uid = new EntityUid(reader.GetGuid(1));
        long? currentId = reader.IsDBNull(2) ? null : reader.GetInt64(2);
        EntityUid? currentUid = reader.IsDBNull(3) ? null : new EntityUid(reader.GetGuid(3));
        int? number = reader.IsDBNull(4) ? null : reader.GetInt32(4);
        var hash = reader.IsDBNull(5) ? default(Sha256Digest?) :
            Sha256Digest.FromBytes((byte[])reader.GetValue(5));
        await reader.DisposeAsync().ConfigureAwait(false);
        return new BuildLogical(
            id,
            uid,
            currentId,
            currentUid,
            number,
            hash,
            await ReadEquipmentSlotsAsync(
                connection,
                transaction,
                id,
                cancellationToken).ConfigureAwait(false));
      }
    }

    var buildUid = _uidGenerator.NewUid();
    long buildId;
    await using (var insert = new NpgsqlCommand(
        """
        INSERT INTO lab_profile.character_build (
            character_build_uid,
            local_account_id,
            character_entity_id,
            created_at_utc
        ) VALUES (@uid, @account_id, @character_entity_id, @created_at)
        RETURNING character_build_id;
        """,
        connection,
        transaction))
    {
      Add(insert, "uid", NpgsqlDbType.Uuid, buildUid.Value);
      Add(insert, "account_id", NpgsqlDbType.Bigint, accountId);
      Add(insert, "character_entity_id", NpgsqlDbType.Bigint, characterEntityId);
      Add(insert, "created_at", NpgsqlDbType.TimestampTz, createdAtUtc);
      buildId = Convert.ToInt64(
          await insert.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false),
          System.Globalization.CultureInfo.InvariantCulture);
    }

    var slots = new List<EquipmentSlotRow>(4);
    foreach (var slot in Enum.GetValues<LocalEquipmentSlot>())
    {
      var slotUid = _uidGenerator.NewUid();
      await using var insert = new NpgsqlCommand(
          """
          INSERT INTO lab_profile.equipment_slot_entity (
              equipment_slot_uid,
              character_build_id,
              slot_code,
              created_at_utc
          ) VALUES (@uid, @build_id, @slot_code, @created_at)
          RETURNING equipment_slot_id;
          """,
          connection,
          transaction);
      Add(insert, "uid", NpgsqlDbType.Uuid, slotUid.Value);
      Add(insert, "build_id", NpgsqlDbType.Bigint, buildId);
      Add(insert, "slot_code", NpgsqlDbType.Text,
          LocalAccountProfileCanonicalizer.Code(slot));
      Add(insert, "created_at", NpgsqlDbType.TimestampTz, createdAtUtc);
      var slotId = Convert.ToInt64(
          await insert.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false),
          System.Globalization.CultureInfo.InvariantCulture);
      slots.Add(new EquipmentSlotRow(slotId, slotUid, slot));
    }

    return new BuildLogical(buildId, buildUid, null, null, null, null, slots);
  }

  private static async Task<IReadOnlyList<EquipmentSlotRow>> ReadEquipmentSlotsAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      long buildId,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        SELECT equipment_slot_id, equipment_slot_uid, slot_code
        FROM lab_profile.equipment_slot_entity
        WHERE character_build_id = @build_id
        ORDER BY slot_code;
        """,
        connection,
        transaction);
    Add(command, "build_id", NpgsqlDbType.Bigint, buildId);
    var slots = new List<EquipmentSlotRow>(4);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
    while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      slots.Add(new EquipmentSlotRow(
          reader.GetInt64(0),
          new EntityUid(reader.GetGuid(1)),
          ParseEquipmentSlot(reader.GetString(2))));
    }

    if (slots.Count != 4)
    {
      throw new LocalAccountProfileIntegrityException("profile_equipment_slot_set_corrupt");
    }

    return slots;
  }

  private static async Task<StoredBuild> ReadStoredBuildAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      long revisionId,
      EntityUid characterUid,
      BuildLogical logical,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        SELECT
            revision.build_revision_uid,
            revision.revision_number,
            previous.build_revision_uid,
            revision.content_sha256,
            revision.revision_origin,
            revision.materialized_at_utc,
            revision.selection_readiness_status,
            revision.selection_readiness_issue_code,
            revision.combat_semantics_readiness_status,
            revision.combat_semantics_readiness_issue_code,
            revision.game_legal_readiness_status,
            revision.game_legal_issue_code
        FROM lab_profile.character_build_revision AS revision
        LEFT JOIN lab_profile.character_build_revision AS previous
          ON previous.build_revision_id = revision.previous_build_revision_id
        WHERE revision.build_revision_id = @revision_id;
        """,
        connection,
        transaction);
    Add(command, "revision_id", NpgsqlDbType.Bigint, revisionId);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
    if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      throw new LocalAccountProfileIntegrityException("profile_build_revision_missing");
    }

    return new StoredBuild(
        logical.Id,
        logical.Uid,
        characterUid,
        revisionId,
        new EntityUid(reader.GetGuid(0)),
        new LocalRevisionLineage(
            reader.GetInt32(1),
            reader.IsDBNull(2) ? null : new EntityUid(reader.GetGuid(2)),
            ParseRevisionOrigin(reader.GetString(4)),
            reader.GetFieldValue<DateTimeOffset>(5)),
        Sha256Digest.FromBytes((byte[])reader.GetValue(3)),
        reader.GetString(6) == "ready",
        reader.GetString(8) == "ready",
        reader.GetString(10) == "ready",
        CompactIssues(
            reader.IsDBNull(7) ? null : reader.GetString(7),
            reader.IsDBNull(9) ? null : reader.GetString(9),
            reader.IsDBNull(11) ? null : reader.GetString(11)),
        logical.Slots);
  }

  private async Task<StoredSquad> StoreSquadAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      AccountRow account,
      CatalogPair catalogs,
      IReadOnlyList<EntityUid> orderedCharacters,
      IReadOnlyList<StoredBuild> builds,
      LocalProfileRevisionOrigin origin,
      DateTimeOffset createdAtUtc,
      CancellationToken cancellationToken)
  {
    var orderedBuilds = orderedCharacters
        .Select(uid => builds.Single(build => build.CharacterUid == uid))
        .ToArray();
    var content = DomainProfile.ProfilePersistedProjection.Squad(
        ToDomainBinding(catalogs),
        orderedBuilds.Select(build => ToDomainBuildReference(account.Uid, catalogs, build)));
    var hash = DomainProfile.ProfileCanonicalizer.ComputeContentHash(content);
    var selectionReady = orderedBuilds.All(static build => build.IsSelectionReady);
    var semanticsReady = orderedBuilds.All(static build => build.HasCombatSemantics);
    var logical = await ResolveSquadLogicalAsync(
        connection,
        transaction,
        account.Id,
        createdAtUtc,
        cancellationToken).ConfigureAwait(false);
    if (logical.CurrentRevisionId is { } currentId && logical.CurrentContentSha256 == hash)
    {
      return new StoredSquad(
          logical.Id,
          logical.Uid,
          currentId,
          logical.CurrentRevisionUid!.Value,
          new LocalRevisionLineage(
              logical.CurrentRevisionNumber!.Value,
              logical.CurrentPreviousRevisionUid,
              logical.CurrentOrigin!.Value,
              logical.CurrentMaterializedAtUtc!.Value),
          hash,
          selectionReady,
          semanticsReady,
          orderedBuilds);
    }

    var revisionUid = _uidGenerator.NewUid();
    var revisionNumber = (logical.CurrentRevisionNumber ?? 0) + 1;
    long revisionId;
    await using (var insert = new NpgsqlCommand(
        """
        INSERT INTO lab_profile.squad_revision (
            squad_revision_uid,
            local_squad_id,
            local_account_id,
            revision_number,
            previous_squad_revision_id,
            character_catalog_snapshot_id,
            character_dataset_snapshot_id,
            character_catalog_manifest_sha256,
            support_catalog_snapshot_id,
            support_dataset_snapshot_id,
            support_catalog_manifest_sha256,
            selection_readiness_status,
            selection_readiness_issue_code,
            combat_semantics_readiness_status,
            combat_semantics_readiness_issue_code,
            member_count,
            content_sha256,
            revision_origin,
            materialized_at_utc
        ) VALUES (
            @uid, @squad_id, @account_id, @revision_number,
            @previous_revision_id,
            @character_catalog_id, @character_dataset_id, @character_manifest,
            @support_catalog_id, @support_dataset_id, @support_manifest,
            @selection_readiness, @selection_issue,
            @semantics_readiness, @semantics_issue,
            5, @content_hash, @origin, @created_at
        )
        RETURNING squad_revision_id;
        """,
        connection,
        transaction))
    {
      Add(insert, "uid", NpgsqlDbType.Uuid, revisionUid.Value);
      Add(insert, "squad_id", NpgsqlDbType.Bigint, logical.Id);
      Add(insert, "account_id", NpgsqlDbType.Bigint, account.Id);
      Add(insert, "revision_number", NpgsqlDbType.Integer, revisionNumber);
      Add(insert, "previous_revision_id", NpgsqlDbType.Bigint, logical.CurrentRevisionId);
      AddCatalogParameters(insert, "character", catalogs.Character);
      AddCatalogParameters(insert, "support", catalogs.Support);
      Add(insert, "selection_readiness", NpgsqlDbType.Text,
          selectionReady ? "ready" : "unresolved");
      Add(insert, "selection_issue", NpgsqlDbType.Text,
          selectionReady ? null : "profile_selection_unresolved");
      Add(insert, "semantics_readiness", NpgsqlDbType.Text,
          semanticsReady ? "ready" : "unresolved");
      Add(insert, "semantics_issue", NpgsqlDbType.Text,
          semanticsReady ? null : "profile_semantics_unresolved");
      Add(insert, "content_hash", NpgsqlDbType.Bytea, hash.ToByteArray());
      Add(insert, "origin", NpgsqlDbType.Text,
          LocalAccountProfileCanonicalizer.Code(origin));
      Add(insert, "created_at", NpgsqlDbType.TimestampTz, createdAtUtc);
      revisionId = Convert.ToInt64(
          await insert.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false),
          System.Globalization.CultureInfo.InvariantCulture);
    }

    for (var index = 0; index < orderedBuilds.Length; index++)
    {
      var build = orderedBuilds[index];
      await using var insert = new NpgsqlCommand(
          """
          INSERT INTO lab_profile.squad_revision_member (
              squad_revision_id,
              position,
              character_build_id,
              build_revision_id
          ) VALUES (@revision_id, @position, @build_id, @build_revision_id);
          """,
          connection,
          transaction);
      Add(insert, "revision_id", NpgsqlDbType.Bigint, revisionId);
      Add(insert, "position", NpgsqlDbType.Smallint, checked((short)(index + 1)));
      Add(insert, "build_id", NpgsqlDbType.Bigint, build.Id);
      Add(insert, "build_revision_id", NpgsqlDbType.Bigint, build.RevisionId);
      await insert.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
    }

    return new StoredSquad(
        logical.Id,
        logical.Uid,
        revisionId,
        revisionUid,
        new LocalRevisionLineage(
            revisionNumber,
            logical.CurrentRevisionUid,
            origin,
            createdAtUtc),
        hash,
        selectionReady,
        semanticsReady,
        orderedBuilds);
  }

  private async Task<SquadLogical> ResolveSquadLogicalAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      long accountId,
      DateTimeOffset createdAtUtc,
      CancellationToken cancellationToken)
  {
    await using (var read = new NpgsqlCommand(
        """
        SELECT
            squad.local_squad_id,
            squad.local_squad_uid,
            squad.current_squad_revision_id,
            revision.squad_revision_uid,
            revision.revision_number,
            previous.squad_revision_uid,
            revision.content_sha256,
            revision.revision_origin,
            revision.materialized_at_utc
        FROM lab_profile.local_squad AS squad
        LEFT JOIN lab_profile.squad_revision AS revision
          ON revision.squad_revision_id = squad.current_squad_revision_id
        LEFT JOIN lab_profile.squad_revision AS previous
          ON previous.squad_revision_id = revision.previous_squad_revision_id
        WHERE squad.local_account_id = @account_id
        FOR UPDATE OF squad;
        """,
        connection,
        transaction))
    {
      Add(read, "account_id", NpgsqlDbType.Bigint, accountId);
      await using var reader = await read.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
      if (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
      {
        return new SquadLogical(
            reader.GetInt64(0),
            new EntityUid(reader.GetGuid(1)),
            reader.IsDBNull(2) ? null : reader.GetInt64(2),
            reader.IsDBNull(3) ? null : new EntityUid(reader.GetGuid(3)),
            reader.IsDBNull(4) ? null : reader.GetInt32(4),
            reader.IsDBNull(5) ? null : new EntityUid(reader.GetGuid(5)),
            reader.IsDBNull(6) ? null :
                Sha256Digest.FromBytes((byte[])reader.GetValue(6)),
            reader.IsDBNull(7) ? null : ParseRevisionOrigin(reader.GetString(7)),
            reader.IsDBNull(8) ? null : reader.GetFieldValue<DateTimeOffset>(8));
      }
    }

    var uid = _uidGenerator.NewUid();
    await using var insert = new NpgsqlCommand(
        """
        INSERT INTO lab_profile.local_squad (
            local_squad_uid,
            local_account_id,
            created_at_utc
        ) VALUES (@uid, @account_id, @created_at)
        RETURNING local_squad_id;
        """,
        connection,
        transaction);
    Add(insert, "uid", NpgsqlDbType.Uuid, uid.Value);
    Add(insert, "account_id", NpgsqlDbType.Bigint, accountId);
    Add(insert, "created_at", NpgsqlDbType.TimestampTz, createdAtUtc);
    var id = Convert.ToInt64(
        await insert.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false),
        System.Globalization.CultureInfo.InvariantCulture);
    return new SquadLogical(id, uid, null, null, null, null, null, null, null);
  }

  private async Task<StoredTemplate> StoreTemplateAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      AccountRow account,
      CatalogPair catalogs,
      StoredState state,
      IReadOnlyList<StoredBuild> builds,
      StoredSquad? squad,
      LocalAccountProfileWrite profile,
      DateTimeOffset createdAtUtc,
      CancellationToken cancellationToken)
  {
    var logical = await ResolveTemplateLogicalAsync(
        connection,
        transaction,
        account.Id,
        createdAtUtc,
        cancellationToken).ConfigureAwait(false);
    var binding = ToDomainBinding(catalogs);
    var buildReferences = builds.Select(build =>
        ToDomainBuildReference(account.Uid, catalogs, build)).ToArray();
    var accountStateReference = DomainProfile.AccountCombatStateRevisionReference.Restore(
        account.AccountCombatStateUid,
        state.Uid,
        account.Uid,
        binding,
        state.ContentSha256,
        ToDomainReadiness(state.IsCombatReady),
        ToDomainReadiness(state.IsFullFidelity));
    DomainProfile.SquadRevisionReference? squadReference = squad is null
        ? null
        : DomainProfile.SquadRevisionReference.Restore(
            squad.Uid,
            squad.RevisionUid,
            account.Uid,
            binding,
            squad.Builds.Select(build => ToDomainBuildReference(account.Uid, catalogs, build)),
            squad.ContentSha256,
            ToDomainReadiness(squad.IsSelectionReady),
            ToDomainReadiness(squad.HasCombatSemantics));
    var content = DomainProfile.ProfilePersistedProjection.ProfileTemplate(
        binding,
        accountStateReference,
        buildReferences,
        squadReference);
    var hash = DomainProfile.ProfileCanonicalizer.ComputeContentHash(content);
    if (logical.CurrentRevisionId is { } currentId && logical.CurrentContentSha256 == hash)
    {
      return new StoredTemplate(
          logical.Id,
          logical.Uid,
          currentId,
          logical.CurrentRevisionUid!.Value,
          new LocalRevisionLineage(
              logical.CurrentRevisionNumber!.Value,
              logical.CurrentPreviousRevisionUid,
              logical.CurrentOrigin!.Value,
              logical.CurrentMaterializedAtUtc!.Value),
          hash);
    }

    var activeBuilds = squad?.Builds ?? [];
    var combatReady = squad is not null && state.IsCombatReady && squad.IsSelectionReady;
    var hasCompleteCombatSemantics = combatReady && squad!.HasCombatSemantics;
    var gameLegalReady = squad is not null && state.IsGameLegalReady &&
        activeBuilds.All(static build => build.IsGameLegalReady);
    string? gameLegalIssue = gameLegalReady
        ? null
        : squad is null
            ? "draft_profile"
            : "profile_game_legal_unresolved";
    var revisionUid = _uidGenerator.NewUid();
    var revisionNumber = (logical.CurrentRevisionNumber ?? 0) + 1;
    long revisionId;
    await using (var insert = new NpgsqlCommand(
        """
        INSERT INTO lab_profile.profile_template_revision (
            profile_template_revision_uid,
            profile_template_id,
            local_account_id,
            revision_number,
            previous_profile_template_revision_id,
            character_catalog_snapshot_id,
            character_dataset_snapshot_id,
            character_catalog_manifest_sha256,
            support_catalog_snapshot_id,
            support_dataset_snapshot_id,
            support_catalog_manifest_sha256,
            account_state_revision_id,
            squad_revision_id,
            build_count,
            is_combat_ready,
            has_complete_combat_semantics,
            game_legal_readiness_status,
            game_legal_issue_code,
            content_sha256,
            revision_origin,
            materialized_at_utc
        ) VALUES (
            @uid, @template_id, @account_id, @revision_number, @previous_revision_id,
            @character_catalog_id, @character_dataset_id, @character_manifest,
            @support_catalog_id, @support_dataset_id, @support_manifest,
            @state_revision_id, @squad_revision_id, @build_count,
            @combat_ready, @complete_semantics,
            @game_legal_readiness, @game_legal_issue,
            @content_hash, @origin, @created_at
        )
        RETURNING profile_template_revision_id;
        """,
        connection,
        transaction))
    {
      Add(insert, "uid", NpgsqlDbType.Uuid, revisionUid.Value);
      Add(insert, "template_id", NpgsqlDbType.Bigint, logical.Id);
      Add(insert, "account_id", NpgsqlDbType.Bigint, account.Id);
      Add(insert, "revision_number", NpgsqlDbType.Integer, revisionNumber);
      Add(insert, "previous_revision_id", NpgsqlDbType.Bigint, logical.CurrentRevisionId);
      AddCatalogParameters(insert, "character", catalogs.Character);
      AddCatalogParameters(insert, "support", catalogs.Support);
      Add(insert, "state_revision_id", NpgsqlDbType.Bigint, state.Id);
      Add(insert, "squad_revision_id", NpgsqlDbType.Bigint, squad?.RevisionId);
      Add(insert, "build_count", NpgsqlDbType.Integer, builds.Count);
      Add(insert, "combat_ready", NpgsqlDbType.Boolean, combatReady);
      Add(insert, "complete_semantics", NpgsqlDbType.Boolean,
          hasCompleteCombatSemantics);
      Add(insert, "game_legal_readiness", NpgsqlDbType.Text,
          gameLegalReady ? "ready" : "unresolved");
      Add(insert, "game_legal_issue", NpgsqlDbType.Text, gameLegalIssue);
      Add(insert, "content_hash", NpgsqlDbType.Bytea, hash.ToByteArray());
      Add(insert, "origin", NpgsqlDbType.Text,
          LocalAccountProfileCanonicalizer.Code(profile.ProfileTemplateOrigin));
      Add(insert, "created_at", NpgsqlDbType.TimestampTz, createdAtUtc);
      revisionId = Convert.ToInt64(
          await insert.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false),
          System.Globalization.CultureInfo.InvariantCulture);
    }

    for (var ordinal = 0; ordinal < builds.Count; ordinal++)
    {
      var build = builds[ordinal];
      await using var insert = new NpgsqlCommand(
          """
          INSERT INTO lab_profile.profile_template_revision_build (
              profile_template_revision_id,
              ordinal,
              character_build_id,
              build_revision_id
          ) VALUES (@revision_id, @ordinal, @build_id, @build_revision_id);
          """,
          connection,
          transaction);
      Add(insert, "revision_id", NpgsqlDbType.Bigint, revisionId);
      Add(insert, "ordinal", NpgsqlDbType.Integer, ordinal);
      Add(insert, "build_id", NpgsqlDbType.Bigint, build.Id);
      Add(insert, "build_revision_id", NpgsqlDbType.Bigint, build.RevisionId);
      await insert.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
    }

    return new StoredTemplate(
        logical.Id,
        logical.Uid,
        revisionId,
        revisionUid,
        new LocalRevisionLineage(
            revisionNumber,
            logical.CurrentRevisionUid,
            profile.ProfileTemplateOrigin,
            createdAtUtc),
        hash);
  }

  private async Task<TemplateLogical> ResolveTemplateLogicalAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      long accountId,
      DateTimeOffset createdAtUtc,
      CancellationToken cancellationToken)
  {
    await using (var read = new NpgsqlCommand(
        """
        SELECT
            template.profile_template_id,
            template.profile_template_uid,
            template.current_profile_template_revision_id,
            revision.profile_template_revision_uid,
            revision.revision_number,
            previous.profile_template_revision_uid,
            revision.content_sha256,
            revision.revision_origin,
            revision.materialized_at_utc
        FROM lab_profile.profile_template AS template
        LEFT JOIN lab_profile.profile_template_revision AS revision
          ON revision.profile_template_revision_id =
             template.current_profile_template_revision_id
        LEFT JOIN lab_profile.profile_template_revision AS previous
          ON previous.profile_template_revision_id =
             revision.previous_profile_template_revision_id
        WHERE template.local_account_id = @account_id
        FOR UPDATE OF template;
        """,
        connection,
        transaction))
    {
      Add(read, "account_id", NpgsqlDbType.Bigint, accountId);
      await using var reader = await read.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
      if (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
      {
        return new TemplateLogical(
            reader.GetInt64(0),
            new EntityUid(reader.GetGuid(1)),
            reader.IsDBNull(2) ? null : reader.GetInt64(2),
            reader.IsDBNull(3) ? null : new EntityUid(reader.GetGuid(3)),
            reader.IsDBNull(4) ? null : reader.GetInt32(4),
            reader.IsDBNull(5) ? null : new EntityUid(reader.GetGuid(5)),
            reader.IsDBNull(6) ? null :
                Sha256Digest.FromBytes((byte[])reader.GetValue(6)),
            reader.IsDBNull(7) ? null : ParseRevisionOrigin(reader.GetString(7)),
            reader.IsDBNull(8) ? null : reader.GetFieldValue<DateTimeOffset>(8));
      }
    }

    var uid = _uidGenerator.NewUid();
    await using var insert = new NpgsqlCommand(
        """
        INSERT INTO lab_profile.profile_template (
            profile_template_uid,
            local_account_id,
            created_at_utc
        ) VALUES (@uid, @account_id, @created_at)
        RETURNING profile_template_id;
        """,
        connection,
        transaction);
    Add(insert, "uid", NpgsqlDbType.Uuid, uid.Value);
    Add(insert, "account_id", NpgsqlDbType.Bigint, accountId);
    Add(insert, "created_at", NpgsqlDbType.TimestampTz, createdAtUtc);
    var id = Convert.ToInt64(
        await insert.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false),
        System.Globalization.CultureInfo.InvariantCulture);
    return new TemplateLogical(id, uid, null, null, null, null, null, null, null);
  }

  private static async Task SwapCurrentGraphAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      long accountId,
      long? expectedProfileRevisionId,
      StoredAggregate stored,
      CancellationToken cancellationToken)
  {
    foreach (var build in stored.Builds)
    {
      await using var update = new NpgsqlCommand(
          """
          UPDATE lab_profile.character_build
          SET current_build_revision_id = @revision_id
          WHERE character_build_id = @build_id;
          """,
          connection,
          transaction);
      Add(update, "revision_id", NpgsqlDbType.Bigint, build.RevisionId);
      Add(update, "build_id", NpgsqlDbType.Bigint, build.Id);
      if (await update.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false) != 1)
      {
        throw new LocalAccountProfileIntegrityException("profile_build_pointer_conflict");
      }
    }

    if (stored.Squad is { } squad)
    {
      await using var update = new NpgsqlCommand(
          """
          UPDATE lab_profile.local_squad
          SET current_squad_revision_id = @revision_id
          WHERE local_squad_id = @squad_id;
          """,
          connection,
          transaction);
      Add(update, "revision_id", NpgsqlDbType.Bigint, squad.RevisionId);
      Add(update, "squad_id", NpgsqlDbType.Bigint, squad.Id);
      if (await update.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false) != 1)
      {
        throw new LocalAccountProfileIntegrityException("profile_squad_pointer_conflict");
      }
    }

    await using (var update = new NpgsqlCommand(
        """
        UPDATE lab_profile.profile_template
        SET current_profile_template_revision_id = @revision_id
        WHERE profile_template_id = (
            SELECT profile_template_id
            FROM lab_profile.profile_template_revision
            WHERE profile_template_revision_id = @revision_id
        );
        """,
        connection,
        transaction))
    {
      Add(update, "revision_id", NpgsqlDbType.Bigint, stored.ProfileRevisionId);
      if (await update.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false) != 1)
      {
        throw new LocalAccountProfileIntegrityException("profile_template_pointer_conflict");
      }
    }

    var expectedPredicate = expectedProfileRevisionId is null
        ? "current_profile_template_revision_id IS NULL"
        : "current_profile_template_revision_id = @expected_revision_id";
    await using var accountUpdate = new NpgsqlCommand(
        $"""
        UPDATE lab_profile.local_account
        SET current_account_state_revision_id = @state_revision_id,
            current_squad_revision_id = @squad_revision_id,
            current_profile_template_revision_id = @profile_revision_id
        WHERE local_account_id = @account_id
          AND {expectedPredicate};
        """,
        connection,
        transaction);
    Add(accountUpdate, "state_revision_id", NpgsqlDbType.Bigint, stored.StateRevisionId);
    Add(accountUpdate, "squad_revision_id", NpgsqlDbType.Bigint, stored.Squad?.RevisionId);
    Add(accountUpdate, "profile_revision_id", NpgsqlDbType.Bigint, stored.ProfileRevisionId);
    Add(accountUpdate, "account_id", NpgsqlDbType.Bigint, accountId);
    if (expectedProfileRevisionId is { } expected)
    {
      Add(accountUpdate, "expected_revision_id", NpgsqlDbType.Bigint, expected);
    }

    if (await accountUpdate.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false) != 1)
    {
      throw new LocalAccountProfileIntegrityException("profile_revision_conflict");
    }
  }

  private static async Task AcquireOperationLockAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      EntityUid operationUid,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        "SELECT pg_advisory_xact_lock(hashtextextended(@operation_uid, @seed));",
        connection,
        transaction);
    Add(command, "operation_uid", NpgsqlDbType.Text, operationUid.ToString());
    Add(command, "seed", NpgsqlDbType.Bigint, OperationLockSeed);
    await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
  }

  private static async Task<long?> ReadOperationAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      EntityUid operationUid,
      Sha256Digest requestSha256,
      string expectedKind,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        SELECT operation_kind, request_sha256, result_profile_template_revision_id
        FROM lab_profile.profile_write_operation
        WHERE operation_uid = @operation_uid;
        """,
        connection,
        transaction);
    Add(command, "operation_uid", NpgsqlDbType.Uuid, operationUid.Value);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
    if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      return null;
    }

    var storedHash = Sha256Digest.FromBytes((byte[])reader.GetValue(1));
    if (reader.GetString(0) != expectedKind || storedHash != requestSha256)
    {
      throw new LocalAccountProfileIntegrityException("profile_operation_reuse_mismatch");
    }

    return reader.GetInt64(2);
  }

  private static async Task RecordOperationAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      EntityUid operationUid,
      string kind,
      Sha256Digest requestSha256,
      long accountId,
      EntityUid? expectedRevisionUid,
      long resultRevisionId,
      DateTimeOffset completedAtUtc,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        INSERT INTO lab_profile.profile_write_operation (
            operation_uid,
            operation_kind,
            request_sha256,
            local_account_id,
            expected_profile_template_revision_uid,
            result_profile_template_revision_id,
            completed_at_utc
        ) VALUES (
            @operation_uid, @operation_kind, @request_hash, @account_id,
            @expected_revision_uid, @result_revision_id, @completed_at
        );
        """,
        connection,
        transaction);
    Add(command, "operation_uid", NpgsqlDbType.Uuid, operationUid.Value);
    Add(command, "operation_kind", NpgsqlDbType.Text, kind);
    Add(command, "request_hash", NpgsqlDbType.Bytea, requestSha256.ToByteArray());
    Add(command, "account_id", NpgsqlDbType.Bigint, accountId);
    Add(command, "expected_revision_uid", NpgsqlDbType.Uuid, expectedRevisionUid?.Value);
    Add(command, "result_revision_id", NpgsqlDbType.Bigint, resultRevisionId);
    Add(command, "completed_at", NpgsqlDbType.TimestampTz, completedAtUtc);
    await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
  }

  private static async Task<long?> ReadCurrentRevisionAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      EntityUid accountUid,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        SELECT current_profile_template_revision_id
        FROM lab_profile.local_account
        WHERE local_account_uid = @account_uid;
        """,
        connection,
        transaction);
    Add(command, "account_uid", NpgsqlDbType.Uuid, accountUid.Value);
    var value = await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false);
    return value is null or DBNull ? null : Convert.ToInt64(
        value,
        System.Globalization.CultureInfo.InvariantCulture);
  }

  private static async Task<LocalAccountProfileReceipt> ReadReceiptAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      EntityUid? operationUid,
      long profileRevisionId,
      bool isReplay,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        SELECT
            account.local_account_uid,
            account.account_combat_state_uid,
            account.created_at_utc,
            account.canonical_sha256,
            state.account_state_revision_uid,
            state.revision_number,
            previous_state.account_state_revision_uid,
            state.revision_origin,
            state.materialized_at_utc,
            state.content_sha256,
            state.combat_readiness_status,
            state.full_fidelity_status,
            state.game_legal_readiness_status,
            squad.local_squad_uid,
            squad_revision.squad_revision_uid,
            squad_revision.revision_number,
            previous_squad.squad_revision_uid,
            squad_revision.revision_origin,
            squad_revision.materialized_at_utc,
            squad_revision.content_sha256,
            squad_revision.selection_readiness_status,
            squad_revision.combat_semantics_readiness_status,
            template.profile_template_uid,
            profile.profile_template_revision_uid,
            profile.revision_number,
            previous_profile.profile_template_revision_uid,
            profile.revision_origin,
            profile.materialized_at_utc,
            profile.content_sha256,
            profile.is_combat_ready,
            profile.has_complete_combat_semantics,
            profile.game_legal_readiness_status
        FROM lab_profile.profile_template_revision AS profile
        JOIN lab_profile.local_account AS account
          ON account.local_account_id = profile.local_account_id
        JOIN lab_profile.account_state_revision AS state
          ON state.account_state_revision_id = profile.account_state_revision_id
        LEFT JOIN lab_profile.account_state_revision AS previous_state
          ON previous_state.account_state_revision_id =
             state.previous_account_state_revision_id
        JOIN lab_profile.profile_template AS template
          ON template.profile_template_id = profile.profile_template_id
        LEFT JOIN lab_profile.squad_revision AS squad_revision
          ON squad_revision.squad_revision_id = profile.squad_revision_id
        LEFT JOIN lab_profile.squad_revision AS previous_squad
          ON previous_squad.squad_revision_id =
             squad_revision.previous_squad_revision_id
        LEFT JOIN lab_profile.local_squad AS squad
          ON squad.local_squad_id = squad_revision.local_squad_id
        LEFT JOIN lab_profile.profile_template_revision AS previous_profile
          ON previous_profile.profile_template_revision_id =
             profile.previous_profile_template_revision_id
        WHERE profile.profile_template_revision_id = @revision_id;
        """,
        connection,
        transaction);
    Add(command, "revision_id", NpgsqlDbType.Bigint, profileRevisionId);
    EntityUid accountUid;
    EntityUid accountStateUid;
    DateTimeOffset accountCreatedAtUtc;
    Sha256Digest accountCanonicalSha256;
    EntityUid stateUid;
    LocalRevisionLineage stateLineage;
    Sha256Digest stateHash;
    bool accountCombatReady;
    bool fullFidelity;
    bool accountGameLegalReady;
    EntityUid? squadUid;
    EntityUid? squadRevisionUid;
    LocalRevisionLineage? squadLineage;
    Sha256Digest? squadHash;
    bool? squadSelectionReady;
    bool? squadSemanticsReady;
    EntityUid templateUid;
    EntityUid templateRevisionUid;
    LocalRevisionLineage templateLineage;
    Sha256Digest hash;
    bool combatReady;
    bool completeSemantics;
    bool gameLegalReady;
    await using (var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false))
    {
      if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
      {
        throw new LocalAccountProfileIntegrityException("profile_revision_not_found");
      }

      accountUid = new EntityUid(reader.GetGuid(0));
      accountStateUid = new EntityUid(reader.GetGuid(1));
      accountCreatedAtUtc = reader.GetFieldValue<DateTimeOffset>(2);
      accountCanonicalSha256 = Sha256Digest.FromBytes((byte[])reader.GetValue(3));
      var canonicalAccount = new DomainProfile.LocalAccount(accountUid, accountCreatedAtUtc);
      if (canonicalAccount.CanonicalSha256 != accountCanonicalSha256)
      {
        throw new LocalAccountProfileIntegrityException("profile_account_hash_mismatch");
      }

      stateUid = new EntityUid(reader.GetGuid(4));
      stateLineage = new LocalRevisionLineage(
          reader.GetInt32(5),
          reader.IsDBNull(6) ? null : new EntityUid(reader.GetGuid(6)),
          ParseRevisionOrigin(reader.GetString(7)),
          reader.GetFieldValue<DateTimeOffset>(8));
      stateHash = Sha256Digest.FromBytes((byte[])reader.GetValue(9));
      accountCombatReady = reader.GetString(10) == "ready";
      fullFidelity = reader.GetString(11) == "ready";
      accountGameLegalReady = reader.GetString(12) == "ready";
      squadUid = reader.IsDBNull(13) ? null : new EntityUid(reader.GetGuid(13));
      squadRevisionUid = reader.IsDBNull(14) ? null : new EntityUid(reader.GetGuid(14));
      squadLineage = reader.IsDBNull(15)
          ? null
          : new LocalRevisionLineage(
              reader.GetInt32(15),
              reader.IsDBNull(16) ? null : new EntityUid(reader.GetGuid(16)),
              ParseRevisionOrigin(reader.GetString(17)),
              reader.GetFieldValue<DateTimeOffset>(18));
      squadHash = reader.IsDBNull(19)
          ? null
          : Sha256Digest.FromBytes((byte[])reader.GetValue(19));
      squadSelectionReady = reader.IsDBNull(20) ? null : reader.GetString(20) == "ready";
      squadSemanticsReady = reader.IsDBNull(21) ? null : reader.GetString(21) == "ready";
      templateUid = new EntityUid(reader.GetGuid(22));
      templateRevisionUid = new EntityUid(reader.GetGuid(23));
      templateLineage = new LocalRevisionLineage(
          reader.GetInt32(24),
          reader.IsDBNull(25) ? null : new EntityUid(reader.GetGuid(25)),
          ParseRevisionOrigin(reader.GetString(26)),
          reader.GetFieldValue<DateTimeOffset>(27));
      hash = Sha256Digest.FromBytes((byte[])reader.GetValue(28));
      combatReady = reader.GetBoolean(29);
      completeSemantics = reader.GetBoolean(30);
      gameLegalReady = reader.GetString(31) == "ready";
    }

    var builds = await ReadBuildReceiptsAsync(
        connection,
        transaction,
        profileRevisionId,
        cancellationToken).ConfigureAwait(false);
    var issues = await ReadIssueCodesAsync(
        connection,
        transaction,
        profileRevisionId,
        cancellationToken).ConfigureAwait(false);
    return new LocalAccountProfileReceipt(
        operationUid,
        isReplay,
        accountUid,
        accountCreatedAtUtc,
        accountCanonicalSha256,
        accountStateUid,
        stateUid,
        stateLineage,
        stateHash,
        accountCombatReady,
        fullFidelity,
        accountGameLegalReady,
        squadUid,
        squadRevisionUid,
        squadLineage,
        squadHash,
        squadSelectionReady,
        squadSemanticsReady,
        templateUid,
        templateRevisionUid,
        templateLineage,
        hash,
        combatReady,
        completeSemantics,
        gameLegalReady,
        issues,
        builds);
  }

  private static async Task<IReadOnlyList<LocalCharacterBuildReceipt>> ReadBuildReceiptsAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      long profileRevisionId,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        SELECT
            character.character_uid,
            build.character_build_uid,
            revision.build_revision_id,
            revision.build_revision_uid,
            revision.revision_number,
            previous.build_revision_uid,
            revision.revision_origin,
            revision.materialized_at_utc,
            revision.content_sha256,
            revision.selection_readiness_status,
            revision.selection_readiness_issue_code,
            revision.combat_semantics_readiness_status,
            revision.combat_semantics_readiness_issue_code,
            revision.game_legal_readiness_status,
            revision.game_legal_issue_code,
            member.ordinal
        FROM lab_profile.profile_template_revision_build AS member
        JOIN lab_profile.character_build AS build
          ON build.character_build_id = member.character_build_id
        JOIN lab_catalog.character_entity AS character
          ON character.character_entity_id = build.character_entity_id
        JOIN lab_profile.character_build_revision AS revision
          ON revision.build_revision_id = member.build_revision_id
        LEFT JOIN lab_profile.character_build_revision AS previous
          ON previous.build_revision_id = revision.previous_build_revision_id
        WHERE member.profile_template_revision_id = @profile_revision_id
        ORDER BY member.ordinal;
        """,
        connection,
        transaction);
    Add(command, "profile_revision_id", NpgsqlDbType.Bigint, profileRevisionId);
    var rows = new List<BuildReceiptRow>();
    await using (var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false))
    {
      while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
      {
        rows.Add(new BuildReceiptRow(
            new EntityUid(reader.GetGuid(0)),
            new EntityUid(reader.GetGuid(1)),
            reader.GetInt64(2),
            new EntityUid(reader.GetGuid(3)),
            new LocalRevisionLineage(
                reader.GetInt32(4),
                reader.IsDBNull(5) ? null : new EntityUid(reader.GetGuid(5)),
                ParseRevisionOrigin(reader.GetString(6)),
                reader.GetFieldValue<DateTimeOffset>(7)),
            Sha256Digest.FromBytes((byte[])reader.GetValue(8)),
            reader.GetString(9) == "ready",
            reader.IsDBNull(10) ? null : reader.GetString(10),
            reader.GetString(11) == "ready",
            reader.IsDBNull(12) ? null : reader.GetString(12),
            reader.GetString(13) == "ready",
            reader.IsDBNull(14) ? null : reader.GetString(14)));
      }
    }

    var results = new List<LocalCharacterBuildReceipt>(rows.Count);
    foreach (var row in rows)
    {
      var slots = await ReadEquipmentSlotReceiptsAsync(
          connection,
          transaction,
          row.RevisionId,
          cancellationToken).ConfigureAwait(false);
      results.Add(new LocalCharacterBuildReceipt(
          row.CharacterUid,
          row.BuildUid,
          row.RevisionUid,
          row.Lineage,
          row.ContentSha256,
          row.IsSelectionReady,
          row.HasCombatSemantics,
          row.IsGameLegalReady,
          CompactIssues(row.SelectionIssue, row.SemanticsIssue, row.GameLegalIssue),
          slots));
    }

    return results;
  }

  private static async Task<IReadOnlyList<LocalEquipmentSlotReceipt>>
      ReadEquipmentSlotReceiptsAsync(
          NpgsqlConnection connection,
          NpgsqlTransaction transaction,
          long buildRevisionId,
          CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        SELECT slot.slot_code, slot.equipment_slot_uid
        FROM lab_profile.build_equipment_state AS equipment
        JOIN lab_profile.equipment_slot_entity AS slot
          ON slot.equipment_slot_id = equipment.equipment_slot_id
        WHERE equipment.build_revision_id = @revision_id
        ORDER BY slot.slot_code;
        """,
        connection,
        transaction);
    Add(command, "revision_id", NpgsqlDbType.Bigint, buildRevisionId);
    var result = new List<LocalEquipmentSlotReceipt>(4);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
    while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      result.Add(new LocalEquipmentSlotReceipt(
          ParseEquipmentSlot(reader.GetString(0)),
          new EntityUid(reader.GetGuid(1))));
    }

    return result;
  }

  private static async Task<IReadOnlyList<string>> ReadIssueCodesAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      long profileRevisionId,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        SELECT issue_code
        FROM (
            SELECT state.combat_readiness_issue_code AS issue_code
            FROM lab_profile.profile_template_revision profile
            JOIN lab_profile.account_state_revision state
              ON state.account_state_revision_id = profile.account_state_revision_id
            WHERE profile.profile_template_revision_id = @revision_id
            UNION ALL
            SELECT state.full_fidelity_issue_code
            FROM lab_profile.profile_template_revision profile
            JOIN lab_profile.account_state_revision state
              ON state.account_state_revision_id = profile.account_state_revision_id
            WHERE profile.profile_template_revision_id = @revision_id
            UNION ALL
            SELECT state.game_legal_issue_code
            FROM lab_profile.profile_template_revision profile
            JOIN lab_profile.account_state_revision state
              ON state.account_state_revision_id = profile.account_state_revision_id
            WHERE profile.profile_template_revision_id = @revision_id
            UNION ALL
            SELECT build.selection_readiness_issue_code
            FROM lab_profile.profile_template_revision_build member
            JOIN lab_profile.character_build_revision build
              ON build.build_revision_id = member.build_revision_id
            WHERE member.profile_template_revision_id = @revision_id
            UNION ALL
            SELECT build.combat_semantics_readiness_issue_code
            FROM lab_profile.profile_template_revision_build member
            JOIN lab_profile.character_build_revision build
              ON build.build_revision_id = member.build_revision_id
            WHERE member.profile_template_revision_id = @revision_id
            UNION ALL
            SELECT build.game_legal_issue_code
            FROM lab_profile.profile_template_revision_build member
            JOIN lab_profile.character_build_revision build
              ON build.build_revision_id = member.build_revision_id
            WHERE member.profile_template_revision_id = @revision_id
            UNION ALL
            SELECT squad.selection_readiness_issue_code
            FROM lab_profile.profile_template_revision profile
            JOIN lab_profile.squad_revision squad
              ON squad.squad_revision_id = profile.squad_revision_id
            WHERE profile.profile_template_revision_id = @revision_id
            UNION ALL
            SELECT squad.combat_semantics_readiness_issue_code
            FROM lab_profile.profile_template_revision profile
            JOIN lab_profile.squad_revision squad
              ON squad.squad_revision_id = profile.squad_revision_id
            WHERE profile.profile_template_revision_id = @revision_id
            UNION ALL
            SELECT profile.game_legal_issue_code
            FROM lab_profile.profile_template_revision profile
            WHERE profile.profile_template_revision_id = @revision_id
        ) issues
        WHERE issue_code IS NOT NULL
        ORDER BY issue_code;
        """,
        connection,
        transaction);
    Add(command, "revision_id", NpgsqlDbType.Bigint, profileRevisionId);
    var result = new List<string>();
    await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
    while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      var code = reader.GetString(0);
      if (!result.Contains(code, StringComparer.Ordinal))
      {
        result.Add(code);
      }
    }

    return result;
  }

  private static async Task<LocalAccountProfileWrite> ReadProfileAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      long profileRevisionId,
      CancellationToken cancellationToken)
  {
    LocalProfileCatalogBindingWrite characterBinding;
    LocalProfileCatalogBindingWrite supportBinding;
    long stateRevisionId;
    long? squadRevisionId;
    LocalProfileRevisionOrigin squadOrigin;
    LocalProfileRevisionOrigin profileTemplateOrigin;
    await using (var command = new NpgsqlCommand(
        """
        SELECT
            character_catalog.character_catalog_snapshot_uid,
            character_dataset.dataset_snapshot_uid,
            profile.character_catalog_manifest_sha256,
            support_catalog.catalog_snapshot_uid,
            support_dataset.dataset_snapshot_uid,
            profile.support_catalog_manifest_sha256,
            profile.account_state_revision_id,
            profile.squad_revision_id,
            profile.revision_origin,
            squad.revision_origin
        FROM lab_profile.profile_template_revision AS profile
        JOIN lab_catalog.character_catalog_snapshot AS character_catalog
          ON character_catalog.character_catalog_snapshot_id =
             profile.character_catalog_snapshot_id
        JOIN lab_import.dataset_snapshot AS character_dataset
          ON character_dataset.dataset_snapshot_id = profile.character_dataset_snapshot_id
        JOIN lab_combat_support.catalog_snapshot AS support_catalog
          ON support_catalog.catalog_snapshot_id = profile.support_catalog_snapshot_id
        JOIN lab_import.dataset_snapshot AS support_dataset
          ON support_dataset.dataset_snapshot_id = profile.support_dataset_snapshot_id
        LEFT JOIN lab_profile.squad_revision AS squad
          ON squad.squad_revision_id = profile.squad_revision_id
        WHERE profile.profile_template_revision_id = @revision_id;
        """,
        connection,
        transaction))
    {
      Add(command, "revision_id", NpgsqlDbType.Bigint, profileRevisionId);
      await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
      if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
      {
        throw new LocalAccountProfileIntegrityException("profile_revision_not_found");
      }

      characterBinding = new LocalProfileCatalogBindingWrite(
          new EntityUid(reader.GetGuid(0)),
          new EntityUid(reader.GetGuid(1)),
          Sha256Digest.FromBytes((byte[])reader.GetValue(2)));
      supportBinding = new LocalProfileCatalogBindingWrite(
          new EntityUid(reader.GetGuid(3)),
          new EntityUid(reader.GetGuid(4)),
          Sha256Digest.FromBytes((byte[])reader.GetValue(5)));
      stateRevisionId = reader.GetInt64(6);
      squadRevisionId = reader.IsDBNull(7) ? null : reader.GetInt64(7);
      profileTemplateOrigin = ParseRevisionOrigin(reader.GetString(8));
      squadOrigin = reader.IsDBNull(9)
          ? LocalProfileRevisionOrigin.UserEdit
          : ParseRevisionOrigin(reader.GetString(9));
    }

    var state = await ReadAccountStateAsync(
        connection,
        transaction,
        stateRevisionId,
        cancellationToken).ConfigureAwait(false);
    var builds = await ReadBuildWritesAsync(
        connection,
        transaction,
        profileRevisionId,
        cancellationToken).ConfigureAwait(false);
    IReadOnlyList<EntityUid>? squad = null;
    if (squadRevisionId is { } squadId)
    {
      squad = await ReadSquadCharactersAsync(
          connection,
          transaction,
          squadId,
          cancellationToken).ConfigureAwait(false);
    }

    return new LocalAccountProfileWrite(
        characterBinding,
        supportBinding,
        state,
        builds,
        squad,
        squadOrigin,
        profileTemplateOrigin);
  }

  private static async Task<LocalAccountCombatStateWrite> ReadAccountStateAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      long stateRevisionId,
      CancellationToken cancellationToken)
  {
    LocalProfileFact<int> synchro;
    LocalProfileValidationMode validationMode;
    LocalProfileRevisionOrigin origin;
    await using (var command = new NpgsqlCommand(
        """
        SELECT
            synchro_level_status,
            synchro_level,
            synchro_level_unresolved_reason_code,
            validation_mode,
            revision_origin
        FROM lab_profile.account_state_revision
        WHERE account_state_revision_id = @revision_id;
        """,
        connection,
        transaction))
    {
      Add(command, "revision_id", NpgsqlDbType.Bigint, stateRevisionId);
      await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
      if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
      {
        throw new LocalAccountProfileIntegrityException("profile_account_state_missing");
      }

      synchro = ReadIntFact(reader, 0, 1, 2);
      validationMode = ParseValidationMode(reader.GetString(3));
      origin = ParseRevisionOrigin(reader.GetString(4));
    }

    await using var consoleCommand = new NpgsqlCommand(
        """
        SELECT
            console.coordinate_code,
            definition.definition_uid,
            console.level_status,
            console.level,
            console.level_unresolved_reason_code,
            console.observed_experience_status,
            console.observed_experience,
            console.observed_experience_unresolved_reason_code
        FROM lab_profile.account_console_state AS console
        JOIN lab_combat_support.definition_entity AS definition
          ON definition.definition_entity_id = console.definition_entity_id
        WHERE console.account_state_revision_id = @revision_id
        ORDER BY console.coordinate_code;
        """,
        connection,
        transaction);
    Add(consoleCommand, "revision_id", NpgsqlDbType.Bigint, stateRevisionId);
    var consoles = new List<LocalConsoleStateWrite>(9);
    await using var consoleReader = await consoleCommand.ExecuteReaderAsync(cancellationToken)
        .ConfigureAwait(false);
    while (await consoleReader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      consoles.Add(new LocalConsoleStateWrite(
          ParseConsoleCoordinate(consoleReader.GetString(0)),
          new EntityUid(consoleReader.GetGuid(1)),
          ReadIntFact(consoleReader, 2, 3, 4),
          ReadLongFact(consoleReader, 5, 6, 7)));
    }

    await consoleReader.DisposeAsync().ConfigureAwait(false);
    await using var cubeCommand = new NpgsqlCommand(
        """
        SELECT definition.definition_uid, cube.level
        FROM lab_profile.account_cube_state cube
        JOIN lab_combat_support.definition_entity definition
          ON definition.definition_entity_id = cube.definition_entity_id
        WHERE cube.account_state_revision_id = @revision_id
        ORDER BY definition.definition_uid;
        """, connection, transaction);
    Add(cubeCommand, "revision_id", NpgsqlDbType.Bigint, stateRevisionId);
    var cubes = new List<LocalOwnedCubeWrite>();
    await using var cubeReader = await cubeCommand.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
    while (await cubeReader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      cubes.Add(new LocalOwnedCubeWrite(new EntityUid(cubeReader.GetGuid(0)), cubeReader.GetInt32(1)));
    }

    return new LocalAccountCombatStateWrite(synchro, consoles, validationMode, origin, cubes);
  }

  private static async Task<IReadOnlyList<LocalCharacterBuildWrite>> ReadBuildWritesAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      long profileRevisionId,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        SELECT
            revision.build_revision_id,
            character.character_uid,
            revision.character_level,
            revision.limit_break_status,
            revision.limit_break_level,
            revision.limit_break_unresolved_reason_code,
            revision.core_level_status,
            revision.core_level,
            revision.core_level_unresolved_reason_code,
            revision.bond_level_status,
            revision.bond_level,
            revision.bond_level_unresolved_reason_code,
            revision.skill_1_status,
            revision.skill_1_level,
            revision.skill_1_unresolved_reason_code,
            revision.skill_2_status,
            revision.skill_2_level,
            revision.skill_2_unresolved_reason_code,
            revision.burst_status,
            revision.burst_level,
            revision.burst_unresolved_reason_code,
            revision.materialization_policy,
            revision.revision_origin,
            revision.cube_state,
            cube.definition_uid,
            revision.cube_level_status,
            revision.cube_level,
            revision.cube_level_unresolved_reason_code,
            revision.cube_unresolved_reason_code,
            revision.collection_kind,
            collectible.definition_uid,
            revision.collection_level_status,
            revision.collection_level,
            revision.collection_level_unresolved_reason_code,
            revision.collection_unresolved_reason_code,
            revision.validation_mode
        FROM lab_profile.profile_template_revision_build AS member
        JOIN lab_profile.character_build_revision AS revision
          ON revision.build_revision_id = member.build_revision_id
        JOIN lab_catalog.character_entity AS character
          ON character.character_entity_id = revision.character_entity_id
        LEFT JOIN lab_combat_support.definition_entity AS cube
          ON cube.definition_entity_id = revision.cube_definition_entity_id
        LEFT JOIN lab_combat_support.definition_entity AS collectible
          ON collectible.definition_entity_id = revision.collection_definition_entity_id
        WHERE member.profile_template_revision_id = @profile_revision_id
        ORDER BY member.ordinal;
        """,
        connection,
        transaction);
    Add(command, "profile_revision_id", NpgsqlDbType.Bigint, profileRevisionId);
    var rows = new List<BuildWriteRow>();
    await using (var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false))
    {
      while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
      {
        rows.Add(new BuildWriteRow(
            reader.GetInt64(0),
            new EntityUid(reader.GetGuid(1)),
            reader.GetInt32(2),
            ReadIntFact(reader, 3, 4, 5),
            ReadIntFact(reader, 6, 7, 8),
            ReadIntFact(reader, 9, 10, 11),
            ReadIntFact(reader, 12, 13, 14),
            ReadIntFact(reader, 15, 16, 17),
            ReadIntFact(reader, 18, 19, 20),
            ParseMaterializationPolicy(reader.GetString(21)),
            ParseRevisionOrigin(reader.GetString(22)),
            ParseSelectionState(reader.GetString(23)),
            reader.IsDBNull(24) ? null : new EntityUid(reader.GetGuid(24)),
            ReadOptionalIntFact(reader, 25, 26, 27),
            ReadReason(reader, 28),
            ParseCollectionKind(reader.GetString(29)),
            reader.IsDBNull(30) ? null : new EntityUid(reader.GetGuid(30)),
            ReadOptionalIntFact(reader, 31, 32, 33),
            ReadReason(reader, 34),
            ParseValidationMode(reader.GetString(35))));
      }
    }

    var builds = new List<LocalCharacterBuildWrite>(rows.Count);
    foreach (var row in rows)
    {
      var equipment = await ReadEquipmentWritesAsync(
          connection,
          transaction,
          row.RevisionId,
          cancellationToken).ConfigureAwait(false);
      builds.Add(new LocalCharacterBuildWrite(
          row.CharacterUid,
          row.CharacterLevel,
          row.LimitBreak,
          row.CoreLevel,
          row.BondLevel,
          row.Skill1,
          row.Skill2,
          row.Burst,
          equipment,
          new LocalCubeSelectionWrite(
              row.CubeState,
              row.CubeDefinitionUid,
              row.CubeLevel,
              row.CubeReason),
          new LocalCollectionSelectionWrite(
              row.CollectionKind,
              row.CollectionDefinitionUid,
              row.CollectionLevel,
          row.CollectionReason),
          row.ValidationMode,
          row.MaterializationPolicy,
          row.Origin));
    }

    return builds;
  }

  private static async Task<IReadOnlyList<LocalEquipmentWrite>> ReadEquipmentWritesAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      long buildRevisionId,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        SELECT
            equipment.build_equipment_state_id,
            equipment.slot_code,
            equipment.equipment_state,
            definition.definition_uid,
            equipment.enhancement_level_status,
            equipment.enhancement_level,
            equipment.enhancement_level_unresolved_reason_code,
            equipment.manufacturer_matched_status,
            equipment.manufacturer_matched,
            equipment.manufacturer_matched_unresolved_reason_code,
            equipment.equipment_unresolved_reason_code
        FROM lab_profile.build_equipment_state AS equipment
        LEFT JOIN lab_combat_support.definition_entity AS definition
          ON definition.definition_entity_id = equipment.definition_entity_id
        WHERE equipment.build_revision_id = @revision_id
        ORDER BY equipment.slot_code;
        """,
        connection,
        transaction);
    Add(command, "revision_id", NpgsqlDbType.Bigint, buildRevisionId);
    var rows = new List<EquipmentWriteRow>(4);
    await using (var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false))
    {
      while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
      {
        rows.Add(new EquipmentWriteRow(
            reader.GetInt64(0),
            ParseEquipmentSlot(reader.GetString(1)),
            ParseEquipmentState(reader.GetString(2)),
            reader.IsDBNull(3) ? null : new EntityUid(reader.GetGuid(3)),
            ReadOptionalSmallIntFact(reader, 4, 5, 6),
            ReadOptionalBoolFact(reader, 7, 8, 9),
            ReadReason(reader, 10)));
      }
    }

    var overloads = await ReadBuildOverloadLinesAsync(
        connection,
        transaction,
        buildRevisionId,
        cancellationToken).ConfigureAwait(false);
    var result = new List<LocalEquipmentWrite>(rows.Count);
    foreach (var row in rows)
    {
      result.Add(new LocalEquipmentWrite(
          row.Slot,
          row.State,
          row.DefinitionUid,
          row.EnhancementLevel,
          row.ManufacturerMatched,
          overloads.TryGetValue(row.EquipmentStateId, out var lines) ? lines : [],
          row.UnresolvedReason));
    }

    return result;
  }

  private static async Task<IReadOnlyDictionary<long, List<LocalOverloadLineWrite>>> ReadBuildOverloadLinesAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      long buildRevisionId,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        SELECT
            line.build_equipment_state_id,
            line.line_index,
            definition.definition_uid,
            line.unit_code,
            line.exact_unscaled_value,
            line.exact_decimal_scale
        FROM lab_profile.build_overload_line AS line
        JOIN lab_profile.build_equipment_state AS equipment
          ON equipment.build_equipment_state_id = line.build_equipment_state_id
        JOIN lab_combat_support.definition_entity AS definition
          ON definition.definition_entity_id = line.definition_entity_id
        WHERE equipment.build_revision_id = @build_revision_id
        ORDER BY line.build_equipment_state_id, line.line_index;
        """,
        connection,
        transaction);
    Add(command, "build_revision_id", NpgsqlDbType.Bigint, buildRevisionId);
    var result = new Dictionary<long, List<LocalOverloadLineWrite>>(4);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
    while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      var equipmentStateId = reader.GetInt64(0);
      if (!result.TryGetValue(equipmentStateId, out var lines))
      {
        lines = new List<LocalOverloadLineWrite>(3);
        result.Add(equipmentStateId, lines);
      }

      lines.Add(new LocalOverloadLineWrite(
          reader.GetInt16(1),
          new EntityUid(reader.GetGuid(2)),
          ParseValueUnit(reader.GetString(3)),
          new LocalProfileExactValue(reader.GetInt64(4), reader.GetInt16(5))));
    }

    return result;
  }

  private static async Task<IReadOnlyList<EntityUid>> ReadSquadCharactersAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      long squadRevisionId,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        SELECT character.character_uid
        FROM lab_profile.squad_revision_member AS member
        JOIN lab_profile.character_build AS build
          ON build.character_build_id = member.character_build_id
        JOIN lab_catalog.character_entity AS character
          ON character.character_entity_id = build.character_entity_id
        WHERE member.squad_revision_id = @revision_id
        ORDER BY member.position;
        """,
        connection,
        transaction);
    Add(command, "revision_id", NpgsqlDbType.Bigint, squadRevisionId);
    var result = new List<EntityUid>(5);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
    while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      result.Add(new EntityUid(reader.GetGuid(0)));
    }

    return result;
  }

  private static async Task<LocalSessionReceipt?> ReadSessionAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction? transaction,
      EntityUid sessionUid,
      DateTimeOffset observedAtUtc,
      bool forUpdate,
      CancellationToken cancellationToken)
  {
    var lockClause = forUpdate ? " FOR UPDATE OF session" : string.Empty;
    await using var command = new NpgsqlCommand(
        $"""
        SELECT
            account.local_account_uid,
            session.issued_at_utc,
            session.expires_at_utc,
            session.revoked_at_utc
        FROM lab_profile.local_session AS session
        JOIN lab_profile.local_account AS account
          ON account.local_account_id = session.local_account_id
        WHERE session.local_session_uid = @session_uid{lockClause};
        """,
        connection,
        transaction);
    Add(command, "session_uid", NpgsqlDbType.Uuid, sessionUid.Value);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
    if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      return null;
    }

    var issued = reader.GetFieldValue<DateTimeOffset>(1);
    var expires = reader.GetFieldValue<DateTimeOffset>(2);
    DateTimeOffset? revoked = reader.IsDBNull(3)
        ? null
        : reader.GetFieldValue<DateTimeOffset>(3);
    var status = revoked is not null
        ? LocalSessionStatus.Revoked
        : expires <= observedAtUtc
            ? LocalSessionStatus.Expired
            : LocalSessionStatus.Active;
    return new LocalSessionReceipt(
        sessionUid,
        new EntityUid(reader.GetGuid(0)),
        issued,
        expires,
        revoked,
        status);
  }

  private static bool IsSelectionReady(
      LocalCharacterBuildWrite build,
      ValidatedBuild validated) =>
      validated.ScalarSelectionResolved &&
      build.LimitBreak.Status != LocalProfileFactStatus.Unresolved &&
      build.CoreLevel.Status != LocalProfileFactStatus.Unresolved &&
      build.BondLevel.Status != LocalProfileFactStatus.Unresolved &&
      build.Equipment.All(static equipment => equipment.State != LocalEquipmentState.Unresolved) &&
      build.Equipment.All(static equipment =>
          equipment.State != LocalEquipmentState.Equipped ||
          equipment.ManufacturerMatched?.Status != LocalProfileFactStatus.Unresolved) &&
      validated.Equipment.All(static equipment => equipment.IsSelectionResolved) &&
      validated.Cube.IsSelectionResolved &&
      build.Cube.State != LocalOptionalSelectionState.Unresolved &&
      build.Collection.Kind != LocalCollectionSelectionKind.Unresolved &&
      validated.Collection.IsSelectionResolved;

  private static bool HasCombatSemantics(
      LocalCharacterBuildWrite build,
      ValidatedBuild validated) =>
      IsSelectionReady(build, validated) &&
      validated.Character.HasCompleteCombatSemantics &&
      validated.Equipment.All(static equipment =>
          equipment.Definition is null || equipment.Definition.Value.HasCompleteCombatSemantics) &&
      validated.Cube.HasCompleteSkillSemantics &&
      (validated.Cube.Definition is null || validated.Cube.Definition.Value.HasCompleteCombatSemantics) &&
      validated.Collection.HasCompleteSkillSemantics &&
      (validated.Collection.Definition is null ||
       validated.Collection.Definition.Value.HasCompleteCombatSemantics);

  private static DomainProfile.ProfileDatasetBinding ToDomainBinding(CatalogPair catalogs) =>
      ToDomainBinding(catalogs.Character.Binding, catalogs.Support.Binding);

  private static DomainProfile.ProfileDatasetBinding ToDomainBinding(
      LocalProfileCatalogBindingWrite characterCatalog,
      LocalProfileCatalogBindingWrite supportCatalog) =>
      new(
          new DomainProfile.ProfileCatalogBinding(
              characterCatalog.CatalogSnapshotUid,
              characterCatalog.DatasetSnapshotUid,
              characterCatalog.CatalogManifestSha256),
          new DomainProfile.ProfileCatalogBinding(
              supportCatalog.CatalogSnapshotUid,
              supportCatalog.DatasetSnapshotUid,
              supportCatalog.CatalogManifestSha256));

  private static void VerifyAggregateProjection(
      LocalAccountProfileReceipt receipt,
      LocalAccountProfileWrite profile)
  {
    var binding = ToDomainBinding(profile.CharacterCatalog, profile.CombatSupportCatalog);
    var buildReferences = receipt.Builds.Select(build =>
        DomainProfile.CharacterBuildRevisionReference.Restore(
            build.CharacterBuildUid,
            build.CharacterBuildRevisionUid,
            receipt.AccountUid,
            build.CharacterUid,
            binding,
            build.ContentSha256,
            ToDomainReadiness(build.IsSelectionReady),
            ToDomainReadiness(build.HasCombatSemantics))).ToArray();
    if (buildReferences.Length != profile.Builds.Count ||
        profile.Builds.Any(write =>
            buildReferences.All(reference => reference.CharacterUid != write.CharacterUid)))
    {
      throw new LocalAccountProfileIntegrityException("profile_read_graph_mismatch");
    }

    var accountReference = DomainProfile.AccountCombatStateRevisionReference.Restore(
        receipt.AccountCombatStateUid,
        receipt.AccountCombatStateRevisionUid,
        receipt.AccountUid,
        binding,
        receipt.AccountStateContentSha256,
        ToDomainReadiness(receipt.IsAccountCombatReady),
        ToDomainReadiness(receipt.IsFullFidelity));

    DomainProfile.SquadRevisionReference? squadReference = null;
    if (profile.SquadCharacterUids is null)
    {
      if (receipt.SquadUid is not null || receipt.SquadRevisionUid is not null ||
          receipt.SquadLineage is not null || receipt.SquadContentSha256 is not null ||
          receipt.IsSquadSelectionReady is not null ||
          receipt.SquadHasCompleteCombatSemantics is not null)
      {
        throw new LocalAccountProfileIntegrityException("profile_read_graph_mismatch");
      }
    }
    else
    {
      if (receipt.SquadUid is not { } squadUid ||
          receipt.SquadRevisionUid is not { } squadRevisionUid ||
          receipt.SquadContentSha256 is not { } squadHash ||
          receipt.IsSquadSelectionReady is not { } squadSelectionReady ||
          receipt.SquadHasCompleteCombatSemantics is not { } squadSemanticsReady)
      {
        throw new LocalAccountProfileIntegrityException("profile_read_graph_mismatch");
      }

      var ordered = profile.SquadCharacterUids.Select(characterUid =>
          buildReferences.Single(reference => reference.CharacterUid == characterUid)).ToArray();
      var squadContent = DomainProfile.ProfilePersistedProjection.Squad(binding, ordered);
      if (DomainProfile.ProfileCanonicalizer.ComputeContentHash(squadContent) != squadHash ||
          squadSelectionReady != ordered.All(static build =>
              build.Readiness == DomainProfile.ProfileReadiness.Ready) ||
          squadSemanticsReady != ordered.All(static build =>
              build.CombatSemanticsReadiness == DomainProfile.ProfileReadiness.Ready))
      {
        throw new LocalAccountProfileIntegrityException("profile_read_squad_mismatch");
      }

      squadReference = DomainProfile.SquadRevisionReference.Restore(
          squadUid,
          squadRevisionUid,
          receipt.AccountUid,
          binding,
          ordered,
          squadHash,
          ToDomainReadiness(squadSelectionReady),
          ToDomainReadiness(squadSemanticsReady));
    }

    var templateContent = DomainProfile.ProfilePersistedProjection.ProfileTemplate(
        binding,
        accountReference,
        buildReferences,
        squadReference);
    var expectedCombatReady = receipt.IsAccountCombatReady &&
        receipt.IsSquadSelectionReady == true;
    var expectedSemanticsReady = expectedCombatReady &&
        receipt.SquadHasCompleteCombatSemantics == true;
    var activeBuilds = profile.SquadCharacterUids is null
        ? Array.Empty<LocalCharacterBuildReceipt>()
        : profile.SquadCharacterUids.Select(characterUid =>
            receipt.Builds.Single(build => build.CharacterUid == characterUid)).ToArray();
    var expectedGameLegalReady = profile.SquadCharacterUids is not null &&
        receipt.IsAccountGameLegalReady &&
        activeBuilds.All(static build => build.IsGameLegalReady);
    if (DomainProfile.ProfileCanonicalizer.ComputeContentHash(templateContent) !=
            receipt.ProfileContentSha256 ||
        receipt.IsCombatReady != expectedCombatReady ||
        receipt.HasCompleteCombatSemantics != expectedSemanticsReady ||
        receipt.IsGameLegalReady != expectedGameLegalReady)
    {
      throw new LocalAccountProfileIntegrityException("profile_read_template_mismatch");
    }
  }

  private static DomainProfile.ProfileFact<T> ToDomainFact<T>(LocalProfileFact<T> fact)
      where T : struct => fact.Status switch
      {
        LocalProfileFactStatus.Ready => DomainProfile.ProfileFact<T>.Ready(fact.Value!.Value),
        LocalProfileFactStatus.Unresolved => DomainProfile.ProfileFact<T>.Unresolved(
            fact.ReasonCode!.Value.Code),
        LocalProfileFactStatus.NotApplicable => DomainProfile.ProfileFact<T>.NotApplicable(),
        _ => throw new ArgumentOutOfRangeException(nameof(fact))
      };

  private static DomainProfile.AccountCombatStateRevisionContent ProjectAccountState(
      CatalogPair catalogs,
      LocalAccountCombatStateWrite state,
      ValidatedAccountState validated) =>
      DomainProfile.ProfilePersistedProjection.AccountCombatState(
          ToDomainBinding(catalogs),
          ToDomainValidationMode(state.ValidationMode),
          ToDomainFact(state.SynchroLevel),
          validated.Consoles.Select(item =>
              DomainProfile.ProfilePersistedProjection.ConsoleProgress(
                  ToDomainConsoleCoordinate(item.Write.Coordinate),
                  ToDomainSupportReference(catalogs.Support, item.Definition),
                  ToDomainFact(item.Write.Level),
                  ToDomainFact(item.Write.ObservedExperience))),
          validated.Cubes.Select(item => new DomainProfile.OwnedCubeProgressState(
              ToDomainSupportReference(catalogs.Support, item.Definition), item.Write.Level)));

  private static DomainProfile.CharacterBuildRevisionContent ProjectBuild(
      CatalogPair catalogs,
      LocalCharacterBuildWrite build,
      ValidatedBuild validated,
      IReadOnlyList<EquipmentSlotRow> slots)
  {
    var equipment = validated.Equipment.Select(item =>
    {
      var slot = slots.Single(candidate => candidate.Slot == item.Write.Slot);
      return item.Write.State switch
      {
        LocalEquipmentState.Equipped =>
            DomainProfile.ProfilePersistedProjection.AttachedEquipment(
                slot.Uid,
                ToDomainEquipmentSlot(item.Write.Slot),
                ToDomainSupportReference(catalogs.Support, item.Definition!.Value),
                ToDomainFact(item.Tier!),
                ToDomainFact(item.Write.EnhancementLevel!),
                ToDomainFact(item.Write.ManufacturerMatched!),
                item.Overloads.Select(overload =>
                    DomainProfile.ProfilePersistedProjection.OverloadLine(
                        overload.Write.LineIndex,
                        ToDomainSupportReference(catalogs.Support, overload.Definition),
                        overload.OptionTypeCode is { } optionType
                            ? DomainProfile.ProfileFact<CombatSupport.CombatSupportOverloadOptionType>.Ready(
                                ParseDomainOverloadOptionType(optionType))
                            : DomainProfile.ProfileFact<CombatSupport.CombatSupportOverloadOptionType>.Unresolved(
                                overload.OptionTypeReasonCode ?? "overload_option_type_unresolved"),
                        overload.UnitResolved
                            ? DomainProfile.ProfileFact<CombatSupport.CombatSupportValueUnit>.Ready(
                                ToDomainValueUnit(overload.Write.Unit))
                            : DomainProfile.ProfileFact<CombatSupport.CombatSupportValueUnit>.Unresolved(
                                overload.UnitReasonCode ?? "overload_unit_unresolved"),
                        new CombatSupport.CombatSupportExactValue(
                            overload.Write.ExactValue.UnscaledValue,
                            overload.Write.ExactValue.DecimalScale)))),
        LocalEquipmentState.Unequipped =>
            DomainProfile.ProfilePersistedProjection.DetachedEquipment(
                slot.Uid,
                ToDomainEquipmentSlot(item.Write.Slot)),
        LocalEquipmentState.Unresolved =>
            DomainProfile.ProfilePersistedProjection.UnresolvedEquipment(
                slot.Uid,
                ToDomainEquipmentSlot(item.Write.Slot),
                item.Write.UnresolvedReasonCode!.Value.Code),
        _ => throw new ArgumentOutOfRangeException(nameof(item.Write.State))
      };
    }).ToArray();

    var cube = validated.Cube.Write.State switch
    {
      LocalOptionalSelectionState.Equipped =>
          DomainProfile.ProfilePersistedProjection.AttachedCube(
              ToDomainSupportReference(catalogs.Support, validated.Cube.Definition!.Value),
              ToDomainFact(validated.Cube.Write.Level!)),
      LocalOptionalSelectionState.Unequipped =>
          DomainProfile.ProfilePersistedProjection.DetachedCube(),
      LocalOptionalSelectionState.Unresolved =>
          DomainProfile.ProfilePersistedProjection.UnresolvedCube(
              validated.Cube.Write.UnresolvedReasonCode!.Value.Code),
      _ => throw new ArgumentOutOfRangeException(nameof(validated.Cube.Write.State))
    };
    var collectible = validated.Collection.Write.Kind switch
    {
      LocalCollectionSelectionKind.GenericCollection =>
          DomainProfile.ProfilePersistedProjection.SelectedCollectible(
              DomainProfile.CharacterCollectibleSelectionKind.GenericCollection,
              ToDomainSupportReference(catalogs.Support, validated.Collection.Definition!.Value),
              ToDomainFact(validated.Collection.Write.Level!)),
      LocalCollectionSelectionKind.Favorite =>
          DomainProfile.ProfilePersistedProjection.SelectedCollectible(
              DomainProfile.CharacterCollectibleSelectionKind.Favorite,
              ToDomainSupportReference(catalogs.Support, validated.Collection.Definition!.Value),
              ToDomainFact(validated.Collection.Write.Level!)),
      LocalCollectionSelectionKind.Detached =>
          DomainProfile.ProfilePersistedProjection.DetachedCollectible(),
      LocalCollectionSelectionKind.NotApplicable =>
          DomainProfile.ProfilePersistedProjection.NotApplicableCollectible(),
      LocalCollectionSelectionKind.Unresolved =>
          DomainProfile.ProfilePersistedProjection.UnresolvedCollectible(
              validated.Collection.Write.UnresolvedReasonCode!.Value.Code),
      _ => throw new ArgumentOutOfRangeException(nameof(validated.Collection.Write.Kind))
    };

    return DomainProfile.ProfilePersistedProjection.CharacterBuild(
        ToDomainBinding(catalogs),
        ToDomainMaterializationPolicy(build.MaterializationPolicy),
        ToDomainValidationMode(build.ValidationMode),
        DomainProfile.CharacterDefinitionReference.Restore(
            validated.Character.CharacterUid,
            validated.Character.DefinitionVersionUid,
            catalogs.Character.Binding.DatasetSnapshotUid,
            validated.Character.DefinitionContentSha256),
        new DomainProfile.CharacterInvestmentState(
            build.CharacterLevel,
            ToDomainFact(build.LimitBreak),
            ToDomainFact(build.CoreLevel),
            ToDomainFact(build.BondLevel)),
        new DomainProfile.CharacterSkillState(
            ToDomainFact(build.Skill1Level),
            ToDomainFact(build.Skill2Level),
            ToDomainFact(build.BurstLevel)),
        equipment,
        cube,
        collectible);
  }

  private static DomainProfile.CombatSupportDefinitionReference ToDomainSupportReference(
      CatalogRow supportCatalog,
      SupportVersion version) =>
      DomainProfile.CombatSupportDefinitionReference.Restore(
          version.Uid,
          version.DefinitionVersionUid,
          supportCatalog.Binding.DatasetSnapshotUid,
          ParseDomainDefinitionKind(version.Kind),
          version.DefinitionContentSha256);

  private static DomainProfile.CharacterBuildRevisionReference ToDomainBuildReference(
      EntityUid accountUid,
      CatalogPair catalogs,
      StoredBuild build) =>
      DomainProfile.CharacterBuildRevisionReference.Restore(
          build.Uid,
          build.RevisionUid,
          accountUid,
          build.CharacterUid,
          ToDomainBinding(catalogs),
          build.ContentSha256,
          ToDomainReadiness(build.IsSelectionReady),
          ToDomainReadiness(build.HasCombatSemantics));

  private static DomainProfile.ProfileReadiness ToDomainReadiness(bool ready) =>
      ready ? DomainProfile.ProfileReadiness.Ready : DomainProfile.ProfileReadiness.Unresolved;

  private static DomainProfile.ProfileValidationMode ToDomainValidationMode(
      LocalProfileValidationMode value) => value switch
      {
        LocalProfileValidationMode.Research => DomainProfile.ProfileValidationMode.Research,
        LocalProfileValidationMode.GameLegal => DomainProfile.ProfileValidationMode.GameLegal,
        _ => throw new ArgumentOutOfRangeException(nameof(value))
      };

  private static DomainProfile.CharacterBuildMaterializationPolicy ToDomainMaterializationPolicy(
      LocalProfileMaterializationPolicy value) => value switch
      {
        LocalProfileMaterializationPolicy.ExplicitV1 =>
            DomainProfile.CharacterBuildMaterializationPolicy.ExplicitV1,
        LocalProfileMaterializationPolicy.CombatMaxV1 =>
            DomainProfile.CharacterBuildMaterializationPolicy.CombatMaxV1,
        _ => throw new ArgumentOutOfRangeException(nameof(value))
      };

  private static CombatSupport.CombatSupportEquipmentSlot ToDomainEquipmentSlot(
      LocalEquipmentSlot value) => value switch
      {
        LocalEquipmentSlot.Head => CombatSupport.CombatSupportEquipmentSlot.Head,
        LocalEquipmentSlot.Torso => CombatSupport.CombatSupportEquipmentSlot.Torso,
        LocalEquipmentSlot.Arms => CombatSupport.CombatSupportEquipmentSlot.Arms,
        LocalEquipmentSlot.Legs => CombatSupport.CombatSupportEquipmentSlot.Legs,
        _ => throw new ArgumentOutOfRangeException(nameof(value))
      };

  private static CombatSupport.CombatSupportConsoleCoordinate ToDomainConsoleCoordinate(
      LocalConsoleCoordinate value) => value switch
      {
        LocalConsoleCoordinate.Common => CombatSupport.CombatSupportConsoleCoordinate.Common,
        LocalConsoleCoordinate.Attacker => CombatSupport.CombatSupportConsoleCoordinate.Attacker,
        LocalConsoleCoordinate.Defender => CombatSupport.CombatSupportConsoleCoordinate.Defender,
        LocalConsoleCoordinate.Supporter => CombatSupport.CombatSupportConsoleCoordinate.Supporter,
        LocalConsoleCoordinate.Elysion => CombatSupport.CombatSupportConsoleCoordinate.Elysion,
        LocalConsoleCoordinate.Missilis => CombatSupport.CombatSupportConsoleCoordinate.Missilis,
        LocalConsoleCoordinate.Tetra => CombatSupport.CombatSupportConsoleCoordinate.Tetra,
        LocalConsoleCoordinate.Pilgrim => CombatSupport.CombatSupportConsoleCoordinate.Pilgrim,
        LocalConsoleCoordinate.Abnormal => CombatSupport.CombatSupportConsoleCoordinate.Abnormal,
        _ => throw new ArgumentOutOfRangeException(nameof(value))
      };

  private static CombatSupport.CombatSupportValueUnit ToDomainValueUnit(
      LocalProfileValueUnit value) => value switch
      {
        LocalProfileValueUnit.Absolute => CombatSupport.CombatSupportValueUnit.Absolute,
        LocalProfileValueUnit.Ratio => CombatSupport.CombatSupportValueUnit.Ratio,
        LocalProfileValueUnit.Percent => CombatSupport.CombatSupportValueUnit.Percent,
        LocalProfileValueUnit.Count => CombatSupport.CombatSupportValueUnit.Count,
        _ => throw new ArgumentOutOfRangeException(nameof(value))
      };

  private static CombatSupport.CombatSupportDefinitionKind ParseDomainDefinitionKind(
      string value) => value switch
      {
        "equipment" => CombatSupport.CombatSupportDefinitionKind.Equipment,
        "cube" => CombatSupport.CombatSupportDefinitionKind.HarmonyCube,
        "collection" => CombatSupport.CombatSupportDefinitionKind.GenericCollection,
        "favorite" => CombatSupport.CombatSupportDefinitionKind.Favorite,
        "console" => CombatSupport.CombatSupportDefinitionKind.Console,
        "overload_option" => CombatSupport.CombatSupportDefinitionKind.OverloadOption,
        _ => throw new LocalAccountProfileIntegrityException("profile_definition_kind_invalid")
      };

  private static CombatSupport.CombatSupportOverloadOptionType ParseDomainOverloadOptionType(
      string value) => value switch
      {
        "attack" => CombatSupport.CombatSupportOverloadOptionType.Attack,
        "defence" => CombatSupport.CombatSupportOverloadOptionType.Defence,
        "maximum_ammunition" => CombatSupport.CombatSupportOverloadOptionType.MaximumAmmunition,
        "critical_rate" => CombatSupport.CombatSupportOverloadOptionType.CriticalRate,
        "critical_damage" => CombatSupport.CombatSupportOverloadOptionType.CriticalDamage,
        "charge_damage" => CombatSupport.CombatSupportOverloadOptionType.ChargeDamage,
        "charge_speed" => CombatSupport.CombatSupportOverloadOptionType.ChargeSpeed,
        "elemental_damage" => CombatSupport.CombatSupportOverloadOptionType.ElementalDamage,
        "hit_rate" => CombatSupport.CombatSupportOverloadOptionType.HitRate,
        _ => throw new LocalAccountProfileIntegrityException("profile_overload_type_invalid")
      };

  private static IReadOnlyList<string> CompactIssues(params string?[] values) =>
      values.Where(static value => value is not null)
          .Select(static value => value!)
          .Distinct(StringComparer.Ordinal)
          .Order(StringComparer.Ordinal)
          .ToArray();

  private static void AddCatalogParameters(
      NpgsqlCommand command,
      string prefix,
      CatalogRow catalog)
  {
    Add(command, $"{prefix}_catalog_id", NpgsqlDbType.Bigint, catalog.Id);
    Add(command, $"{prefix}_dataset_id", NpgsqlDbType.Bigint, catalog.DatasetId);
    Add(command, $"{prefix}_manifest", NpgsqlDbType.Bytea,
        catalog.Binding.CatalogManifestSha256.ToByteArray());
  }

  private static void AddFactParameters<T>(
      NpgsqlCommand command,
      string prefix,
      LocalProfileFact<T> fact,
      NpgsqlDbType valueType)
      where T : struct
  {
    Add(command, $"{prefix}_status", NpgsqlDbType.Text,
        LocalAccountProfileCanonicalizer.Code(fact.Status));
    Add(command, $"{prefix}_value", valueType, fact.Value);
    Add(command, $"{prefix}_reason", NpgsqlDbType.Text, ReasonCode(fact.ReasonCode));
  }

  private static void AddOptionalFactParameters<T>(
      NpgsqlCommand command,
      string prefix,
      LocalProfileFact<T>? fact,
      NpgsqlDbType valueType)
      where T : struct
  {
    Add(command, $"{prefix}_status", NpgsqlDbType.Text,
        fact is null ? null : LocalAccountProfileCanonicalizer.Code(fact.Status));
    Add(command, $"{prefix}_value", valueType, fact?.Value);
    Add(command, $"{prefix}_reason", NpgsqlDbType.Text,
        fact is null ? null : ReasonCode(fact.ReasonCode));
  }

  private static void Add(
      NpgsqlCommand command,
      string name,
      NpgsqlDbType type,
      object? value)
  {
    command.Parameters.Add(name, type).Value = value ?? DBNull.Value;
  }

  private static string? ReasonCode(LocalProfileReasonCode? reason) =>
      reason is { } value ? LocalAccountProfileCanonicalizer.Code(value) : null;

  private static string CollectionKindCode(LocalCollectionSelectionKind kind) => kind switch
  {
    LocalCollectionSelectionKind.Detached => "detached",
    LocalCollectionSelectionKind.GenericCollection => "collection",
    LocalCollectionSelectionKind.Favorite => "favorite",
    LocalCollectionSelectionKind.Unresolved => "unresolved",
    LocalCollectionSelectionKind.NotApplicable => "not_applicable",
    _ => throw new LocalAccountProfileIntegrityException("profile_collection_kind_invalid")
  };

  private static LocalProfileFact<int> ReadIntFact(
      NpgsqlDataReader reader,
      int statusOrdinal,
      int valueOrdinal,
      int reasonOrdinal) =>
      ReadFact(
          reader,
          statusOrdinal,
          valueOrdinal,
          reasonOrdinal,
          static (valueReader, ordinal) => valueReader.GetInt32(ordinal));

  private static LocalProfileFact<long> ReadLongFact(
      NpgsqlDataReader reader,
      int statusOrdinal,
      int valueOrdinal,
      int reasonOrdinal) =>
      ReadFact(
          reader,
          statusOrdinal,
          valueOrdinal,
          reasonOrdinal,
          static (valueReader, ordinal) => valueReader.GetInt64(ordinal));

  private static LocalProfileFact<bool>? ReadOptionalBoolFact(
      NpgsqlDataReader reader,
      int statusOrdinal,
      int valueOrdinal,
      int reasonOrdinal) =>
      reader.IsDBNull(statusOrdinal)
          ? null
          : ReadFact(
              reader,
              statusOrdinal,
              valueOrdinal,
              reasonOrdinal,
              static (valueReader, ordinal) => valueReader.GetBoolean(ordinal));

  private static LocalProfileFact<int>? ReadOptionalIntFact(
      NpgsqlDataReader reader,
      int statusOrdinal,
      int valueOrdinal,
      int reasonOrdinal) =>
      reader.IsDBNull(statusOrdinal)
          ? null
          : ReadFact(
              reader,
              statusOrdinal,
              valueOrdinal,
              reasonOrdinal,
              static (valueReader, ordinal) => valueReader.GetInt32(ordinal));

  private static LocalProfileFact<int>? ReadOptionalSmallIntFact(
      NpgsqlDataReader reader,
      int statusOrdinal,
      int valueOrdinal,
      int reasonOrdinal) =>
      reader.IsDBNull(statusOrdinal)
          ? null
          : ReadFact(
              reader,
              statusOrdinal,
              valueOrdinal,
              reasonOrdinal,
              static (valueReader, ordinal) => (int)valueReader.GetInt16(ordinal));

  private static LocalProfileFact<T> ReadFact<T>(
      NpgsqlDataReader reader,
      int statusOrdinal,
      int valueOrdinal,
      int reasonOrdinal,
      Func<NpgsqlDataReader, int, T> readValue)
      where T : struct
  {
    var status = reader.GetString(statusOrdinal);
    return status switch
    {
      "ready" => LocalProfileFact<T>.Ready(readValue(reader, valueOrdinal)),
      "unresolved" => LocalProfileFact<T>.Unresolved(
          new LocalProfileReasonCode(reader.GetString(reasonOrdinal))),
      "not_applicable" => LocalProfileFact<T>.NotApplicable(),
      _ => throw new LocalAccountProfileIntegrityException("profile_fact_status_invalid")
    };
  }

  private static LocalProfileReasonCode? ReadReason(NpgsqlDataReader reader, int ordinal) =>
      reader.IsDBNull(ordinal) ? null : new LocalProfileReasonCode(reader.GetString(ordinal));

  private static LocalEquipmentSlot ParseEquipmentSlot(string value) => value switch
  {
    "head" => LocalEquipmentSlot.Head,
    "torso" => LocalEquipmentSlot.Torso,
    "arms" => LocalEquipmentSlot.Arms,
    "legs" => LocalEquipmentSlot.Legs,
    _ => throw new LocalAccountProfileIntegrityException("profile_equipment_slot_invalid")
  };

  private static LocalEquipmentState ParseEquipmentState(string value) => value switch
  {
    "equipped" => LocalEquipmentState.Equipped,
    "unequipped" => LocalEquipmentState.Unequipped,
    "unresolved" => LocalEquipmentState.Unresolved,
    _ => throw new LocalAccountProfileIntegrityException("profile_equipment_state_invalid")
  };

  private static LocalOptionalSelectionState ParseSelectionState(string value) => value switch
  {
    "equipped" => LocalOptionalSelectionState.Equipped,
    "unequipped" => LocalOptionalSelectionState.Unequipped,
    "unresolved" => LocalOptionalSelectionState.Unresolved,
    _ => throw new LocalAccountProfileIntegrityException("profile_selection_state_invalid")
  };

  private static LocalCollectionSelectionKind ParseCollectionKind(string value) => value switch
  {
    "detached" => LocalCollectionSelectionKind.Detached,
    "collection" => LocalCollectionSelectionKind.GenericCollection,
    "favorite" => LocalCollectionSelectionKind.Favorite,
    "unresolved" => LocalCollectionSelectionKind.Unresolved,
    "not_applicable" => LocalCollectionSelectionKind.NotApplicable,
    _ => throw new LocalAccountProfileIntegrityException("profile_collection_kind_invalid")
  };

  private static LocalConsoleCoordinate ParseConsoleCoordinate(string value) => value switch
  {
    "common" => LocalConsoleCoordinate.Common,
    "attacker" => LocalConsoleCoordinate.Attacker,
    "defender" => LocalConsoleCoordinate.Defender,
    "supporter" => LocalConsoleCoordinate.Supporter,
    "elysion" => LocalConsoleCoordinate.Elysion,
    "missilis" => LocalConsoleCoordinate.Missilis,
    "tetra" => LocalConsoleCoordinate.Tetra,
    "pilgrim" => LocalConsoleCoordinate.Pilgrim,
    "abnormal" => LocalConsoleCoordinate.Abnormal,
    _ => throw new LocalAccountProfileIntegrityException("profile_console_coordinate_invalid")
  };

  private static LocalProfileValidationMode ParseValidationMode(string value) => value switch
  {
    "research" => LocalProfileValidationMode.Research,
    "game_legal" => LocalProfileValidationMode.GameLegal,
    _ => throw new LocalAccountProfileIntegrityException("profile_validation_mode_invalid")
  };

  private static LocalProfileMaterializationPolicy ParseMaterializationPolicy(string value) =>
      value switch
      {
        "explicit_v1" => LocalProfileMaterializationPolicy.ExplicitV1,
        "combat_max_v1" => LocalProfileMaterializationPolicy.CombatMaxV1,
        _ => throw new LocalAccountProfileIntegrityException(
            "profile_materialization_policy_invalid")
      };

  private static LocalProfileRevisionOrigin ParseRevisionOrigin(string value) => value switch
  {
    "user_edit" => LocalProfileRevisionOrigin.UserEdit,
    "combat_max_v1" => LocalProfileRevisionOrigin.CombatMaxV1,
    "offline_sanitized_import" => LocalProfileRevisionOrigin.OfflineSanitizedImport,
    "rebase" => LocalProfileRevisionOrigin.Rebase,
    _ => throw new LocalAccountProfileIntegrityException("profile_revision_origin_invalid")
  };

  private static LocalProfileValueUnit ParseValueUnit(string value) => value switch
  {
    "absolute" => LocalProfileValueUnit.Absolute,
    "ratio" => LocalProfileValueUnit.Ratio,
    "percent" => LocalProfileValueUnit.Percent,
    "count" => LocalProfileValueUnit.Count,
    _ => throw new LocalAccountProfileIntegrityException("profile_value_unit_invalid")
  };

  private static void RequireUid(EntityUid uid, string code)
  {
    if (uid.Value == Guid.Empty)
    {
      throw new LocalAccountProfileIntegrityException(code);
    }
  }

  private static void RequireUtc(DateTimeOffset value)
  {
    if (value.Offset != TimeSpan.Zero || value.Ticks % 10 != 0)
    {
      throw new LocalAccountProfileIntegrityException("profile_timestamp_invalid");
    }
  }

  private static LocalAccountProfileIntegrityException MapDatabaseException(
      PostgresException exception)
  {
    var code = exception.MessageText switch
    {
      "profile_revision_lineage_invalid" => "profile_revision_conflict",
      "profile_current_graph_inconsistent" => "profile_current_graph_inconsistent",
      "profile_overload_equipment_invalid" => "profile_overload_equipment_invalid",
      "local_game_lobby_character_not_in_profile" =>
          "local_game_lobby_character_not_in_profile",
      "immutable_profile_row" => "profile_immutable_violation",
      _ when exception.SqlState == PostgresErrorCodes.UniqueViolation &&
          string.Equals(
              exception.ConstraintName,
              "account_workspace_account_label_key",
              StringComparison.Ordinal) => "account_label_conflict",
      _ when exception.SqlState == PostgresErrorCodes.ForeignKeyViolation =>
          "profile_reference_invalid",
      _ when exception.SqlState == PostgresErrorCodes.UniqueViolation =>
          "profile_concurrency_conflict",
      _ when exception.SqlState == PostgresErrorCodes.CheckViolation =>
          "profile_database_constraint",
      _ => "profile_database_write_failed"
    };
    return new LocalAccountProfileIntegrityException(code);
  }

  private readonly record struct AccountRow(
      long Id,
      EntityUid Uid,
      EntityUid AccountCombatStateUid,
      DateTimeOffset CreatedAtUtc,
      Sha256Digest CanonicalSha256,
      long? CurrentProfileRevisionId,
      EntityUid? CurrentProfileRevisionUid);

  private readonly record struct CatalogRow(
      long Id,
      long DatasetId,
      LocalProfileCatalogBindingWrite Binding);

  private readonly record struct CatalogPair(CatalogRow Character, CatalogRow Support);

  private readonly record struct CapabilityRow(
      string Status,
      int? MaximumLevel,
      string? UnresolvedReasonCode);

  private sealed record CharacterVersion(
      EntityUid CharacterUid,
      long EntityId,
      long VersionId,
      EntityUid DefinitionVersionUid,
      Sha256Digest DefinitionContentSha256,
      bool HasCompleteCombatSemantics,
      string? CombatClass,
      string? Weapon,
      string? Manufacturer,
      string? Rarity,
      IReadOnlyDictionary<string, CapabilityRow> Capabilities);

  private readonly record struct SupportVersion(
      EntityUid Uid,
      long EntityId,
      long VersionId,
      EntityUid DefinitionVersionUid,
      Sha256Digest DefinitionContentSha256,
      string Kind,
      bool HasCompleteCombatSemantics);

  private sealed record ResolvedConsole(
      LocalConsoleStateWrite Write,
      SupportVersion Definition);

  private sealed record ValidationResult(bool IsReady, string? IssueCode);

  private sealed record ResolvedOwnedCube(LocalOwnedCubeWrite Write, SupportVersion Definition);

  private sealed record ValidatedAccountState(
      IReadOnlyList<ResolvedConsole> Consoles,
      IReadOnlyList<ResolvedOwnedCube> Cubes,
      ValidationResult Combat,
      ValidationResult FullFidelity,
      ValidationResult GameLegal);

  private sealed record ResolvedOverload(
      LocalOverloadLineWrite Write,
      SupportVersion Definition,
      string? OptionTypeCode,
      string? OptionTypeReasonCode,
      bool UnitResolved,
      string? UnitReasonCode)
  {
    public bool IsSelectionResolved => OptionTypeCode is not null && UnitResolved;
  }

  private sealed record ResolvedEquipment(
      LocalEquipmentWrite Write,
      SupportVersion? Definition,
      LocalProfileFact<int>? Tier,
      IReadOnlyList<ResolvedOverload> Overloads,
      bool IsSelectionResolved);

  private sealed record ResolvedCube(
      LocalCubeSelectionWrite Write,
      SupportVersion? Definition,
      bool IsSelectionResolved,
      bool HasCompleteSkillSemantics);

  private sealed record ResolvedCollection(
      LocalCollectionSelectionWrite Write,
      SupportVersion? Definition,
      int? DefinitionMaximumLevel,
      bool IsSelectionResolved,
      bool HasCompleteSkillSemantics);

  private sealed record ValidatedBuild(
      CharacterVersion Character,
      IReadOnlyList<ResolvedEquipment> Equipment,
      ResolvedCube Cube,
      ResolvedCollection Collection,
      bool ScalarSelectionResolved,
      ValidationResult Validation);

  private readonly record struct StoredStateHead(long Id, EntityUid Uid, int RevisionNumber);

  private sealed record StoredState(
      long Id,
      EntityUid Uid,
      LocalRevisionLineage Lineage,
      Sha256Digest ContentSha256,
      bool IsCombatReady,
      bool IsFullFidelity,
      bool IsGameLegalReady,
      IReadOnlyList<string> Issues);

  private sealed record EquipmentSlotRow(
      long Id,
      EntityUid Uid,
      LocalEquipmentSlot Slot);

  private sealed record BuildLogical(
      long Id,
      EntityUid Uid,
      long? CurrentRevisionId,
      EntityUid? CurrentRevisionUid,
      int? CurrentRevisionNumber,
      Sha256Digest? CurrentContentSha256,
      IReadOnlyList<EquipmentSlotRow> Slots);

  private sealed record StoredBuild(
      long Id,
      EntityUid Uid,
      EntityUid CharacterUid,
      long RevisionId,
      EntityUid RevisionUid,
      LocalRevisionLineage Lineage,
      Sha256Digest ContentSha256,
      bool IsSelectionReady,
      bool HasCombatSemantics,
      bool IsGameLegalReady,
      IReadOnlyList<string> Issues,
      IReadOnlyList<EquipmentSlotRow> Slots);

  private sealed record SquadLogical(
      long Id,
      EntityUid Uid,
      long? CurrentRevisionId,
      EntityUid? CurrentRevisionUid,
      int? CurrentRevisionNumber,
      EntityUid? CurrentPreviousRevisionUid,
      Sha256Digest? CurrentContentSha256,
      LocalProfileRevisionOrigin? CurrentOrigin,
      DateTimeOffset? CurrentMaterializedAtUtc);

  private sealed record StoredSquad(
      long Id,
      EntityUid Uid,
      long RevisionId,
      EntityUid RevisionUid,
      LocalRevisionLineage Lineage,
      Sha256Digest ContentSha256,
      bool IsSelectionReady,
      bool HasCombatSemantics,
      IReadOnlyList<StoredBuild> Builds);

  private sealed record TemplateLogical(
      long Id,
      EntityUid Uid,
      long? CurrentRevisionId,
      EntityUid? CurrentRevisionUid,
      int? CurrentRevisionNumber,
      EntityUid? CurrentPreviousRevisionUid,
      Sha256Digest? CurrentContentSha256,
      LocalProfileRevisionOrigin? CurrentOrigin,
      DateTimeOffset? CurrentMaterializedAtUtc);

  private sealed record StoredTemplate(
      long Id,
      EntityUid Uid,
      long RevisionId,
      EntityUid RevisionUid,
      LocalRevisionLineage Lineage,
      Sha256Digest ContentSha256);

  private sealed record StoredAggregate(
      long StateRevisionId,
      IReadOnlyList<StoredBuild> Builds,
      StoredSquad? Squad,
      long ProfileRevisionId);

  private sealed record BuildReceiptRow(
      EntityUid CharacterUid,
      EntityUid BuildUid,
      long RevisionId,
      EntityUid RevisionUid,
      LocalRevisionLineage Lineage,
      Sha256Digest ContentSha256,
      bool IsSelectionReady,
      string? SelectionIssue,
      bool HasCombatSemantics,
      string? SemanticsIssue,
      bool IsGameLegalReady,
      string? GameLegalIssue);

  private sealed record BuildWriteRow(
      long RevisionId,
      EntityUid CharacterUid,
      int CharacterLevel,
      LocalProfileFact<int> LimitBreak,
      LocalProfileFact<int> CoreLevel,
      LocalProfileFact<int> BondLevel,
      LocalProfileFact<int> Skill1,
      LocalProfileFact<int> Skill2,
      LocalProfileFact<int> Burst,
      LocalProfileMaterializationPolicy MaterializationPolicy,
      LocalProfileRevisionOrigin Origin,
      LocalOptionalSelectionState CubeState,
      EntityUid? CubeDefinitionUid,
      LocalProfileFact<int>? CubeLevel,
      LocalProfileReasonCode? CubeReason,
      LocalCollectionSelectionKind CollectionKind,
      EntityUid? CollectionDefinitionUid,
      LocalProfileFact<int>? CollectionLevel,
      LocalProfileReasonCode? CollectionReason,
      LocalProfileValidationMode ValidationMode);

  private sealed record EquipmentWriteRow(
      long EquipmentStateId,
      LocalEquipmentSlot Slot,
      LocalEquipmentState State,
      EntityUid? DefinitionUid,
      LocalProfileFact<int>? EnhancementLevel,
      LocalProfileFact<bool>? ManufacturerMatched,
      LocalProfileReasonCode? UnresolvedReason);
}
