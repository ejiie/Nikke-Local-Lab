using System.Data;
using System.Globalization;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;
using Npgsql;
using NpgsqlTypes;

namespace NikkeLocalLab.Persistence.PostgreSql;

public sealed partial class PostgreSqlLocalGameStateStore
{
  private const long OperationLockSeed = 5_468_271_903_729_346_087;
  private const long ContentLockSeed = 5_468_271_903_729_346_088;
  private readonly NpgsqlDataSource _dataSource;
  private readonly IEntityUidGenerator _uidGenerator;

  public PostgreSqlLocalGameStateStore(
      NpgsqlDataSource dataSource,
      IEntityUidGenerator uidGenerator)
  {
    _dataSource = dataSource ?? throw new ArgumentNullException(nameof(dataSource));
    _uidGenerator = uidGenerator ?? throw new ArgumentNullException(nameof(uidGenerator));
  }

  public async Task<LocalClientFeatureManifestReceipt> PublishFeatureManifestAsync(
      PublishLocalClientFeatureManifestCommand command,
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
          "publish_feature_manifest",
          cancellationToken).ConfigureAwait(false);
      if (replay is { ManifestId: { } replayedId })
      {
        var replayed = await ReadFeatureManifestAsync(
            connection,
            transaction,
            replayedId,
            isReused: true,
            cancellationToken).ConfigureAwait(false);
        await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
        return replayed;
      }

      await AcquireContentLockAsync(
          connection,
          transaction,
          command.Manifest.ContentSha256,
          cancellationToken).ConfigureAwait(false);
      var manifestId = await FindFeatureManifestByHashAsync(
          connection,
          transaction,
          command.Manifest.ContentSha256,
          cancellationToken).ConfigureAwait(false);
      var reused = manifestId.HasValue;
      if (!manifestId.HasValue)
      {
        manifestId = await InsertFeatureManifestAsync(
            connection,
            transaction,
            command.Manifest,
            command.CreatedAtUtc,
            cancellationToken).ConfigureAwait(false);
      }

      await RecordOperationAsync(
          connection,
          transaction,
          command.OperationUid,
          "publish_feature_manifest",
          command.RequestSha256,
          accountId: null,
          expectedRevisionUid: null,
          lobbyRevisionId: null,
          walletRevisionId: null,
          manifestId,
          command.CreatedAtUtc,
          cancellationToken).ConfigureAwait(false);
      var result = await ReadFeatureManifestAsync(
          connection,
          transaction,
          manifestId.Value,
          reused,
          cancellationToken).ConfigureAwait(false);
      await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
      return result;
    }
    catch (PostgresException exception)
    {
      throw MapDatabaseException(exception);
    }
  }

  public async Task<LocalGameStateReceipt> InitializeAsync(
      InitializeLocalGameStateCommand command,
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
          "initialize",
          cancellationToken).ConfigureAwait(false);
      if (replay is { AccountId: { } replayAccountId })
      {
        var replayed = await ReadStateReceiptAsync(
            connection,
            transaction,
            replayAccountId,
            command.OperationUid,
            isReplay: true,
            cancellationToken).ConfigureAwait(false);
        await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
        return replayed;
      }

      var profile = await LockCurrentProfileAsync(
          connection,
          transaction,
          command.AccountUid,
          command.ExpectedProfileTemplateRevisionUid,
          cancellationToken).ConfigureAwait(false);
      if (await AccountClientStateExistsAsync(
              connection,
              transaction,
              profile.AccountId,
              cancellationToken).ConfigureAwait(false))
      {
        throw new LocalGameStateIntegrityException("local_game_state_already_initialized");
      }

      var manifestId = await ResolveFeatureManifestAsync(
          connection,
          transaction,
          command.FeatureManifestUid,
          cancellationToken).ConfigureAwait(false);
      var lobby = await InsertLobbyRevisionAsync(
          connection,
          transaction,
          profile,
          previous: null,
          command.Lobby,
          command.CreatedAtUtc,
          cancellationToken).ConfigureAwait(false);
      var wallet = await InsertWalletRevisionAsync(
          connection,
          transaction,
          profile.AccountId,
          previous: null,
          command.Wallet,
          command.CreatedAtUtc,
          cancellationToken).ConfigureAwait(false);

      await using (var insert = new NpgsqlCommand(
          """
          INSERT INTO lab_local_game.account_client_state (
              local_account_id,
              current_lobby_presentation_revision_id,
              current_wallet_revision_id,
              current_client_feature_manifest_id,
              created_at_utc
          ) VALUES (@account_id, @lobby_id, @wallet_id, @manifest_id, @created_at);
          """,
          connection,
          transaction))
      {
        Add(insert, "account_id", NpgsqlDbType.Bigint, profile.AccountId);
        Add(insert, "lobby_id", NpgsqlDbType.Bigint, lobby.Id);
        Add(insert, "wallet_id", NpgsqlDbType.Bigint, wallet.Id);
        Add(insert, "manifest_id", NpgsqlDbType.Bigint, manifestId);
        Add(insert, "created_at", NpgsqlDbType.TimestampTz, command.CreatedAtUtc);
        await insert.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
      }

      await RecordOperationAsync(
          connection,
          transaction,
          command.OperationUid,
          "initialize",
          command.RequestSha256,
          profile.AccountId,
          expectedRevisionUid: null,
          lobby.Id,
          wallet.Id,
          manifestId,
          command.CreatedAtUtc,
          cancellationToken).ConfigureAwait(false);
      var result = await ReadStateReceiptAsync(
          connection,
          transaction,
          profile.AccountId,
          command.OperationUid,
          isReplay: false,
          cancellationToken).ConfigureAwait(false);
      await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
      return result;
    }
    catch (PostgresException exception)
    {
      throw MapDatabaseException(exception);
    }
  }

  public async Task<LocalGameStateReceipt?> TryReplayInitializeAsync(
      InitializeLocalGameStateCommand command,
      CancellationToken cancellationToken = default)
  {
    ArgumentNullException.ThrowIfNull(command);
    await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken)
        .ConfigureAwait(false);
    await using var transaction = await connection.BeginTransactionAsync(
        IsolationLevel.ReadCommitted,
        cancellationToken).ConfigureAwait(false);
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
        "initialize",
        cancellationToken).ConfigureAwait(false);
    if (replay is not { AccountId: { } accountId })
    {
      await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
      return null;
    }

    var result = await ReadStateReceiptAsync(
        connection,
        transaction,
        accountId,
        command.OperationUid,
        isReplay: true,
        cancellationToken).ConfigureAwait(false);
    await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
    return result;
  }

  public async Task<LocalLobbyPresentationReceipt> SaveLobbyPresentationAsync(
      SaveLobbyPresentationCommand command,
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
          "save_lobby",
          cancellationToken).ConfigureAwait(false);
      if (replay is { LobbyRevisionId: { } replayedId })
      {
        var replayed = await ReadLobbyAsync(
            connection,
            transaction,
            replayedId,
            cancellationToken).ConfigureAwait(false);
        await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
        return replayed;
      }

      var profile = await LockCurrentProfileAsync(
          connection,
          transaction,
          command.AccountUid,
          command.ExpectedProfileTemplateRevisionUid,
          cancellationToken).ConfigureAwait(false);
      var state = await LockClientStateAsync(
          connection,
          transaction,
          profile.AccountId,
          cancellationToken).ConfigureAwait(false);
      var current = await ReadLobbyAsync(
          connection,
          transaction,
          state.LobbyRevisionId,
          cancellationToken).ConfigureAwait(false);
      if (current.RevisionUid != command.ExpectedLobbyPresentationRevisionUid)
      {
        throw new LocalGameStateIntegrityException("local_game_lobby_revision_conflict");
      }

      StoredRevision stored;
      if (current.ContentSha256 == command.Lobby.ContentSha256)
      {
        stored = new StoredRevision(
            state.LobbyRevisionId,
            current.RevisionUid,
            current.Lineage.RevisionNumber,
            current.Lineage.PreviousRevisionUid,
            current.ContentSha256,
            current.Lineage.Origin,
            current.Lineage.MaterializedAtUtc);
      }
      else
      {
        stored = await InsertLobbyRevisionAsync(
            connection,
            transaction,
            profile,
            ToStoredRevision(state.LobbyRevisionId, current),
            command.Lobby,
            command.CreatedAtUtc,
            cancellationToken).ConfigureAwait(false);
        await UpdateLobbyPointerAsync(
            connection,
            transaction,
            profile.AccountId,
            state.LobbyRevisionId,
            stored.Id,
            cancellationToken).ConfigureAwait(false);
      }

      await RecordOperationAsync(
          connection,
          transaction,
          command.OperationUid,
          "save_lobby",
          command.RequestSha256,
          profile.AccountId,
          command.ExpectedLobbyPresentationRevisionUid,
          stored.Id,
          walletRevisionId: null,
          manifestId: null,
          command.CreatedAtUtc,
          cancellationToken).ConfigureAwait(false);
      var result = await ReadLobbyAsync(
          connection,
          transaction,
          stored.Id,
          cancellationToken).ConfigureAwait(false);
      await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
      return result;
    }
    catch (PostgresException exception)
    {
      throw MapDatabaseException(exception);
    }
  }

  public async Task<LocalLobbyPresentationReceipt?> TryReplayLobbyPresentationAsync(
      EntityUid operationUid,
      EntityUid accountUid,
      EntityUid expectedLobbyPresentationRevisionUid,
      LocalLobbyPresentationWrite lobby,
      CancellationToken cancellationToken = default)
  {
    LocalGameStateContractGuard.RequireUid(operationUid, "local_game_operation_uid_invalid");
    LocalGameStateContractGuard.RequireUid(accountUid, "local_game_account_uid_invalid");
    LocalGameStateContractGuard.RequireUid(
        expectedLobbyPresentationRevisionUid,
        "local_game_expected_revision_uid_invalid");
    ArgumentNullException.ThrowIfNull(lobby);
    await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken)
        .ConfigureAwait(false);
    await using var transaction = await connection.BeginTransactionAsync(
        IsolationLevel.ReadCommitted,
        cancellationToken).ConfigureAwait(false);
    await AcquireOperationLockAsync(
        connection,
        transaction,
        operationUid,
        cancellationToken).ConfigureAwait(false);

    string? operationKind = null;
    Sha256Digest storedRequestSha256 = default;
    EntityUid storedAccountUid = default;
    EntityUid? storedExpectedLobbyUid = null;
    long? lobbyRevisionId = null;
    EntityUid? validatedProfileRevisionUid = null;
    DateTimeOffset completedAtUtc = default;
    var found = false;
    await using (var read = new NpgsqlCommand(
        """
        SELECT operation.operation_kind,
               operation.request_sha256,
               account.local_account_uid,
               operation.expected_revision_uid,
               operation.result_lobby_presentation_revision_id,
               profile.profile_template_revision_uid,
               operation.completed_at_utc
        FROM lab_local_game.client_state_write_operation AS operation
        LEFT JOIN lab_profile.local_account AS account
          ON account.local_account_id = operation.local_account_id
        LEFT JOIN lab_local_game.lobby_presentation_revision AS lobby
          ON lobby.lobby_presentation_revision_id =
             operation.result_lobby_presentation_revision_id
        LEFT JOIN lab_profile.profile_template_revision AS profile
          ON profile.profile_template_revision_id =
             lobby.validated_profile_template_revision_id
         AND profile.local_account_id = lobby.local_account_id
        WHERE operation.operation_uid = @operation_uid;
        """,
        connection,
        transaction))
    {
      Add(read, "operation_uid", NpgsqlDbType.Uuid, operationUid.Value);
      await using var reader = await read.ExecuteReaderAsync(cancellationToken)
          .ConfigureAwait(false);
      if (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
      {
        found = true;
        operationKind = reader.GetString(0);
        storedRequestSha256 = Sha256Digest.FromBytes((byte[])reader.GetValue(1));
        storedAccountUid = reader.IsDBNull(2)
            ? default
            : new EntityUid(reader.GetGuid(2));
        storedExpectedLobbyUid = reader.IsDBNull(3)
            ? null
            : new EntityUid(reader.GetGuid(3));
        lobbyRevisionId = reader.IsDBNull(4) ? null : reader.GetInt64(4);
        validatedProfileRevisionUid = reader.IsDBNull(5)
            ? null
            : new EntityUid(reader.GetGuid(5));
        completedAtUtc = reader.GetFieldValue<DateTimeOffset>(6);
      }
    }

    if (!found)
    {
      await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
      return null;
    }

    if (!string.Equals(operationKind, "save_lobby", StringComparison.Ordinal) ||
        storedAccountUid != accountUid ||
        storedExpectedLobbyUid != expectedLobbyPresentationRevisionUid ||
        lobbyRevisionId is null || validatedProfileRevisionUid is null)
    {
      throw new LocalGameStateIntegrityException("local_game_operation_reuse_mismatch");
    }

    var canonical = new SaveLobbyPresentationCommand(
        operationUid,
        accountUid,
        expectedLobbyPresentationRevisionUid,
        validatedProfileRevisionUid.Value,
        lobby,
        completedAtUtc);
    if (canonical.RequestSha256 != storedRequestSha256)
    {
      throw new LocalGameStateIntegrityException("local_game_operation_reuse_mismatch");
    }

    var result = await ReadLobbyAsync(
        connection,
        transaction,
        lobbyRevisionId.Value,
        cancellationToken).ConfigureAwait(false);
    await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
    return result;
  }

  public async Task<LocalWalletReceipt> SaveWalletAsync(
      SaveWalletCommand command,
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
          "save_wallet",
          cancellationToken).ConfigureAwait(false);
      if (replay is { WalletRevisionId: { } replayedId })
      {
        var replayed = await ReadWalletAsync(
            connection,
            transaction,
            replayedId,
            cancellationToken).ConfigureAwait(false);
        await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
        return replayed;
      }

      var profile = await LockCurrentProfileAsync(
          connection,
          transaction,
          command.AccountUid,
          expectedProfileRevisionUid: null,
          cancellationToken).ConfigureAwait(false);
      var state = await LockClientStateAsync(
          connection,
          transaction,
          profile.AccountId,
          cancellationToken).ConfigureAwait(false);
      var current = await ReadWalletAsync(
          connection,
          transaction,
          state.WalletRevisionId,
          cancellationToken).ConfigureAwait(false);
      if (current.RevisionUid != command.ExpectedWalletRevisionUid)
      {
        throw new LocalGameStateIntegrityException("local_game_wallet_revision_conflict");
      }

      StoredRevision stored;
      if (current.ContentSha256 == command.Wallet.ContentSha256)
      {
        stored = new StoredRevision(
            state.WalletRevisionId,
            current.RevisionUid,
            current.Lineage.RevisionNumber,
            current.Lineage.PreviousRevisionUid,
            current.ContentSha256,
            current.Lineage.Origin,
            current.Lineage.MaterializedAtUtc);
      }
      else
      {
        stored = await InsertWalletRevisionAsync(
            connection,
            transaction,
            profile.AccountId,
            ToStoredRevision(state.WalletRevisionId, current),
            command.Wallet,
            command.CreatedAtUtc,
            cancellationToken).ConfigureAwait(false);
        await UpdateWalletPointerAsync(
            connection,
            transaction,
            profile.AccountId,
            state.WalletRevisionId,
            stored.Id,
            cancellationToken).ConfigureAwait(false);
      }

      await RecordOperationAsync(
          connection,
          transaction,
          command.OperationUid,
          "save_wallet",
          command.RequestSha256,
          profile.AccountId,
          command.ExpectedWalletRevisionUid,
          lobbyRevisionId: null,
          stored.Id,
          manifestId: null,
          command.CreatedAtUtc,
          cancellationToken).ConfigureAwait(false);
      var result = await ReadWalletAsync(
          connection,
          transaction,
          stored.Id,
          cancellationToken).ConfigureAwait(false);
      await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
      return result;
    }
    catch (PostgresException exception)
    {
      throw MapDatabaseException(exception);
    }
  }

  public async Task<LocalClientBootstrapProjection?> GetBootstrapAsync(
      EntityUid accountUid,
      CancellationToken cancellationToken = default)
  {
    LocalGameStateContractGuard.RequireUid(accountUid, "local_game_account_uid_invalid");
    await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken)
        .ConfigureAwait(false);
    await using var transaction = await connection.BeginTransactionAsync(
        IsolationLevel.RepeatableRead,
        cancellationToken).ConfigureAwait(false);
    var binding = await ReadBootstrapBindingAsync(
        connection,
        transaction,
        accountUid,
        cancellationToken).ConfigureAwait(false);
    if (binding is null)
    {
      await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
      return null;
    }

    await EnsureCurrentLobbyCompatibilityAsync(
        connection,
        transaction,
        binding,
        cancellationToken).ConfigureAwait(false);
    var lobby = await ReadLobbyAsync(
        connection,
        transaction,
        binding.LobbyRevisionId,
        cancellationToken).ConfigureAwait(false);
    var wallet = await ReadWalletAsync(
        connection,
        transaction,
        binding.WalletRevisionId,
        cancellationToken).ConfigureAwait(false);
    var feature = await ReadFeatureManifestAsync(
        connection,
        transaction,
        binding.FeatureManifestId,
        isReused: false,
        cancellationToken).ConfigureAwait(false);
    var roster = await ReadRosterAsync(
        connection,
        transaction,
        binding.ProfileRevisionId,
        cancellationToken).ConfigureAwait(false);
    var squad = await ReadSquadAsync(
        connection,
        transaction,
        binding.SquadRevisionId,
        cancellationToken).ConfigureAwait(false);
    var inventory = await ReadInventoryAsync(
        connection,
        transaction,
        binding.ProfileRevisionId,
        cancellationToken).ConfigureAwait(false);
    var revisionSet = new List<EntityUid>
    {
      binding.ProfileRevisionUid,
      binding.AccountStateRevisionUid,
      lobby.RevisionUid,
      wallet.RevisionUid,
      feature.ManifestUid
    };
    revisionSet.AddRange(roster.Select(static item => item.BuildRevisionUid));
    if (squad is not null)
    {
      revisionSet.Add(squad.SquadRevisionUid);
    }

    var result = new LocalClientBootstrapProjection(
        accountUid,
        binding.ProfileRevisionUid,
        binding.AccountStateRevisionUid,
        LocalGameStateContractCanonicalizer.ComputeRevisionSetSha256(revisionSet.ToArray()),
        lobby,
        wallet,
        feature,
        roster,
        squad,
        inventory);
    await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
    return result;
  }

  // Administrative repair reads intentionally do not apply the bootstrap's stale-lobby gate.
  // The returned head UID is required to publish a new lobby revision validated against the
  // current profile after a profile change.
  public async Task<LocalLobbyPresentationReceipt?> GetLobbyPresentationHeadAsync(
      EntityUid accountUid,
      CancellationToken cancellationToken = default)
  {
    LocalGameStateContractGuard.RequireUid(accountUid, "local_game_account_uid_invalid");
    await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken)
        .ConfigureAwait(false);
    await using var transaction = await connection.BeginTransactionAsync(
        IsolationLevel.RepeatableRead,
        cancellationToken).ConfigureAwait(false);
    var revisionId = await ReadClientStateHeadIdAsync(
        connection,
        transaction,
        accountUid,
        "lobby",
        cancellationToken).ConfigureAwait(false);
    if (revisionId is null)
    {
      await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
      return null;
    }

    var result = await ReadLobbyAsync(
        connection,
        transaction,
        revisionId.Value,
        cancellationToken).ConfigureAwait(false);
    await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
    return result;
  }

  public async Task<LocalWalletReceipt?> GetWalletHeadAsync(
      EntityUid accountUid,
      CancellationToken cancellationToken = default)
  {
    LocalGameStateContractGuard.RequireUid(accountUid, "local_game_account_uid_invalid");
    await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken)
        .ConfigureAwait(false);
    await using var transaction = await connection.BeginTransactionAsync(
        IsolationLevel.RepeatableRead,
        cancellationToken).ConfigureAwait(false);
    var revisionId = await ReadClientStateHeadIdAsync(
        connection,
        transaction,
        accountUid,
        "wallet",
        cancellationToken).ConfigureAwait(false);
    if (revisionId is null)
    {
      await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
      return null;
    }

    var result = await ReadWalletAsync(
        connection,
        transaction,
        revisionId.Value,
        cancellationToken).ConfigureAwait(false);
    await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
    return result;
  }

  public async Task<LocalClientFeatureManifestReceipt?> GetLatestFeatureManifestAsync(
      CancellationToken cancellationToken = default)
  {
    await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken)
        .ConfigureAwait(false);
    await using var transaction = await connection.BeginTransactionAsync(
        IsolationLevel.RepeatableRead,
        cancellationToken).ConfigureAwait(false);
    await using var command = new NpgsqlCommand(
        """
        SELECT client_feature_manifest_id
        FROM lab_local_game.client_feature_manifest
        ORDER BY client_feature_manifest_id DESC
        LIMIT 1;
        """,
        connection,
        transaction);
    var value = await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false);
    if (value is null)
    {
      await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
      return null;
    }

    var result = await ReadFeatureManifestAsync(
        connection,
        transaction,
        Convert.ToInt64(value, CultureInfo.InvariantCulture),
        isReused: false,
        cancellationToken).ConfigureAwait(false);
    await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
    return result;
  }

  private static async Task<long?> ReadClientStateHeadIdAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      EntityUid accountUid,
      string headKind,
      CancellationToken cancellationToken)
  {
    var column = headKind switch
    {
      "lobby" => "current_lobby_presentation_revision_id",
      "wallet" => "current_wallet_revision_id",
      _ => throw new ArgumentOutOfRangeException(nameof(headKind))
    };
    await using var command = new NpgsqlCommand(
        $"""
        SELECT state.{column}
        FROM lab_profile.local_account AS account
        JOIN lab_local_game.account_client_state AS state
          ON state.local_account_id = account.local_account_id
        WHERE account.local_account_uid = @account_uid;
        """,
        connection,
        transaction);
    Add(command, "account_uid", NpgsqlDbType.Uuid, accountUid.Value);
    var value = await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false);
    return value is null or DBNull ? null : Convert.ToInt64(value, CultureInfo.InvariantCulture);
  }

  private async Task<StoredRevision> InsertLobbyRevisionAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      CurrentProfile profile,
      StoredRevision? previous,
      LocalLobbyPresentationWrite lobby,
      DateTimeOffset createdAtUtc,
      CancellationToken cancellationToken)
  {
    long? characterEntityId = null;
    long? characterVersionId = null;
    if (lobby.LobbyCharacter.Value is { } characterUid)
    {
      (characterEntityId, characterVersionId) = await ResolveLobbyCharacterAsync(
          connection,
          transaction,
          profile,
          characterUid,
          cancellationToken).ConfigureAwait(false);
    }

    var uid = _uidGenerator.NewUid();
    await using var command = new NpgsqlCommand(
        """
        INSERT INTO lab_local_game.lobby_presentation_revision (
            lobby_presentation_revision_uid,
            local_account_id,
            revision_number,
            previous_lobby_presentation_revision_id,
            validated_profile_template_revision_id,
            character_catalog_snapshot_id,
            display_name,
            commander_level_status,
            commander_level,
            commander_level_unresolved_reason_code,
            lobby_character_status,
            lobby_character_entity_id,
            lobby_character_definition_version_id,
            lobby_character_unresolved_reason_code,
            profile_icon_status,
            profile_icon_selection_uid,
            profile_icon_unresolved_reason_code,
            profile_frame_status,
            profile_frame_selection_uid,
            profile_frame_unresolved_reason_code,
            lobby_background_status,
            lobby_background_selection_uid,
            lobby_background_unresolved_reason_code,
            content_sha256,
            revision_origin,
            materialized_at_utc
        ) VALUES (
            @uid, @account_id, @revision_number, @previous_id,
            @profile_revision_id, @character_catalog_id, @display_name,
            @commander_status, @commander_value, @commander_reason,
            @character_status, @character_entity_id, @character_version_id, @character_reason,
            @icon_status, @icon_uid, @icon_reason,
            @frame_status, @frame_uid, @frame_reason,
            @background_status, @background_uid, @background_reason,
            @content_hash, @origin, @created_at
        )
        RETURNING lobby_presentation_revision_id;
        """,
        connection,
        transaction);
    Add(command, "uid", NpgsqlDbType.Uuid, uid.Value);
    Add(command, "account_id", NpgsqlDbType.Bigint, profile.AccountId);
    Add(command, "revision_number", NpgsqlDbType.Integer, (previous?.RevisionNumber ?? 0) + 1);
    Add(command, "previous_id", NpgsqlDbType.Bigint, previous?.Id);
    Add(command, "profile_revision_id", NpgsqlDbType.Bigint, profile.ProfileRevisionId);
    Add(command, "character_catalog_id", NpgsqlDbType.Bigint, profile.CharacterCatalogId);
    Add(command, "display_name", NpgsqlDbType.Text, lobby.DisplayName);
    AddIntFact(command, "commander", lobby.CommanderLevel);
    AddUidFact(command, "character", lobby.LobbyCharacter, characterEntityId, characterVersionId);
    AddUidFact(command, "icon", lobby.ProfileIcon);
    AddUidFact(command, "frame", lobby.ProfileFrame);
    AddUidFact(command, "background", lobby.LobbyBackground);
    Add(command, "content_hash", NpgsqlDbType.Bytea, lobby.ContentSha256.ToByteArray());
    Add(command, "origin", NpgsqlDbType.Text,
        LocalGameStateContractCanonicalizer.Code(lobby.Origin));
    Add(command, "created_at", NpgsqlDbType.TimestampTz, createdAtUtc);
    var id = Convert.ToInt64(
        await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false),
        CultureInfo.InvariantCulture);
    return new StoredRevision(
        id,
        uid,
        (previous?.RevisionNumber ?? 0) + 1,
        previous?.Uid,
        lobby.ContentSha256,
        lobby.Origin,
        createdAtUtc);
  }

  private async Task<StoredRevision> InsertWalletRevisionAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      long accountId,
      StoredRevision? previous,
      LocalWalletWrite wallet,
      DateTimeOffset createdAtUtc,
      CancellationToken cancellationToken)
  {
    var uid = _uidGenerator.NewUid();
    long id;
    await using (var command = new NpgsqlCommand(
        """
        INSERT INTO lab_local_game.wallet_revision (
            wallet_revision_uid,
            local_account_id,
            revision_number,
            previous_wallet_revision_id,
            balance_count,
            content_sha256,
            revision_origin,
            materialized_at_utc
        ) VALUES (
            @uid, @account_id, @revision_number, @previous_id,
            2, @content_hash, @origin, @created_at
        )
        RETURNING wallet_revision_id;
        """,
        connection,
        transaction))
    {
      Add(command, "uid", NpgsqlDbType.Uuid, uid.Value);
      Add(command, "account_id", NpgsqlDbType.Bigint, accountId);
      Add(command, "revision_number", NpgsqlDbType.Integer, (previous?.RevisionNumber ?? 0) + 1);
      Add(command, "previous_id", NpgsqlDbType.Bigint, previous?.Id);
      Add(command, "content_hash", NpgsqlDbType.Bytea, wallet.ContentSha256.ToByteArray());
      Add(command, "origin", NpgsqlDbType.Text,
          LocalGameStateContractCanonicalizer.Code(wallet.Origin));
      Add(command, "created_at", NpgsqlDbType.TimestampTz, createdAtUtc);
      id = Convert.ToInt64(
          await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false),
          CultureInfo.InvariantCulture);
    }

    foreach (var balance in wallet.Balances)
    {
      await using var insert = new NpgsqlCommand(
          """
          INSERT INTO lab_local_game.wallet_balance (
              wallet_revision_id, currency_code, amount
          ) VALUES (@revision_id, @currency, @amount);
          """,
          connection,
          transaction);
      Add(insert, "revision_id", NpgsqlDbType.Bigint, id);
      Add(insert, "currency", NpgsqlDbType.Text,
          LocalGameStateContractCanonicalizer.Code(balance.Currency));
      Add(insert, "amount", NpgsqlDbType.Bigint, balance.Amount);
      await insert.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
    }

    return new StoredRevision(
        id,
        uid,
        (previous?.RevisionNumber ?? 0) + 1,
        previous?.Uid,
        wallet.ContentSha256,
        wallet.Origin,
        createdAtUtc);
  }

  private async Task<long> InsertFeatureManifestAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      LocalClientFeatureManifestWrite manifest,
      DateTimeOffset createdAtUtc,
      CancellationToken cancellationToken)
  {
    var uid = _uidGenerator.NewUid();
    long id;
    await using (var command = new NpgsqlCommand(
        """
        INSERT INTO lab_local_game.client_feature_manifest (
            client_feature_manifest_uid,
            contract_version,
            entry_count,
            content_sha256,
            published_at_utc
        ) VALUES (@uid, @version, @count, @content_hash, @created_at)
        RETURNING client_feature_manifest_id;
        """,
        connection,
        transaction))
    {
      Add(command, "uid", NpgsqlDbType.Uuid, uid.Value);
      Add(command, "version", NpgsqlDbType.Text, manifest.ContractVersion);
      Add(command, "count", NpgsqlDbType.Integer, manifest.Entries.Count);
      Add(command, "content_hash", NpgsqlDbType.Bytea, manifest.ContentSha256.ToByteArray());
      Add(command, "created_at", NpgsqlDbType.TimestampTz, createdAtUtc);
      id = Convert.ToInt64(
          await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false),
          CultureInfo.InvariantCulture);
    }

    foreach (var entry in manifest.Entries)
    {
      await using var insert = new NpgsqlCommand(
          """
          INSERT INTO lab_local_game.client_feature_manifest_entry (
              client_feature_manifest_id, route_code, capability_code
          ) VALUES (@manifest_id, @route, @capability);
          """,
          connection,
          transaction);
      Add(insert, "manifest_id", NpgsqlDbType.Bigint, id);
      Add(insert, "route", NpgsqlDbType.Text, entry.RouteCode);
      Add(insert, "capability", NpgsqlDbType.Text,
          LocalGameStateContractCanonicalizer.Code(entry.Capability));
      await insert.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
    }

    return id;
  }

  private static async Task<CurrentProfile> LockCurrentProfileAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      EntityUid accountUid,
      EntityUid? expectedProfileRevisionUid,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        SELECT
            account.local_account_id,
            profile.profile_template_revision_id,
            profile.profile_template_revision_uid,
            profile.character_catalog_snapshot_id
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

    var profile = new CurrentProfile(
        reader.GetInt64(0),
        reader.GetInt64(1),
        new EntityUid(reader.GetGuid(2)),
        reader.GetInt64(3));
    if (expectedProfileRevisionUid is { } expected && profile.ProfileRevisionUid != expected)
    {
      throw new LocalGameStateIntegrityException("local_game_profile_revision_conflict");
    }

    return profile;
  }

  private static async Task<(long EntityId, long VersionId)> ResolveLobbyCharacterAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      CurrentProfile profile,
      EntityUid characterUid,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        SELECT member.character_entity_id, member.character_definition_version_id
        FROM lab_catalog.character_catalog_snapshot_member AS member
        JOIN lab_catalog.character_entity AS character
          ON character.character_entity_id = member.character_entity_id
        WHERE member.character_catalog_snapshot_id = @catalog_id
          AND character.character_uid = @character_uid
          AND EXISTS (
              SELECT 1
              FROM lab_profile.profile_template_revision_build AS profile_member
              JOIN lab_profile.character_build AS build
                ON build.character_build_id = profile_member.character_build_id
              WHERE profile_member.profile_template_revision_id = @profile_revision_id
                AND build.character_entity_id = member.character_entity_id
          );
        """,
        connection,
        transaction);
    Add(command, "catalog_id", NpgsqlDbType.Bigint, profile.CharacterCatalogId);
    Add(command, "character_uid", NpgsqlDbType.Uuid, characterUid.Value);
    Add(command, "profile_revision_id", NpgsqlDbType.Bigint, profile.ProfileRevisionId);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
    if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      throw new LocalGameStateIntegrityException("local_game_lobby_character_not_in_profile");
    }

    return (reader.GetInt64(0), reader.GetInt64(1));
  }

  private static async Task<bool> AccountClientStateExistsAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      long accountId,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        "SELECT EXISTS (SELECT 1 FROM lab_local_game.account_client_state WHERE local_account_id = @account_id);",
        connection,
        transaction);
    Add(command, "account_id", NpgsqlDbType.Bigint, accountId);
    return Convert.ToBoolean(
        await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false),
        CultureInfo.InvariantCulture);
  }

  private static async Task<ClientStateHead> LockClientStateAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      long accountId,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        SELECT
            current_lobby_presentation_revision_id,
            current_wallet_revision_id,
            current_client_feature_manifest_id
        FROM lab_local_game.account_client_state
        WHERE local_account_id = @account_id
        FOR UPDATE;
        """,
        connection,
        transaction);
    Add(command, "account_id", NpgsqlDbType.Bigint, accountId);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
    if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      throw new LocalGameStateIntegrityException("local_game_state_not_initialized");
    }

    return new ClientStateHead(reader.GetInt64(0), reader.GetInt64(1), reader.GetInt64(2));
  }

  private static async Task<long> ResolveFeatureManifestAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      EntityUid manifestUid,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        SELECT client_feature_manifest_id
        FROM lab_local_game.client_feature_manifest
        WHERE client_feature_manifest_uid = @uid;
        """,
        connection,
        transaction);
    Add(command, "uid", NpgsqlDbType.Uuid, manifestUid.Value);
    var value = await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false);
    if (value is null)
    {
      throw new LocalGameStateIntegrityException("local_game_feature_manifest_not_found");
    }

    return Convert.ToInt64(value, CultureInfo.InvariantCulture);
  }

  private static async Task<long?> FindFeatureManifestByHashAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      Sha256Digest hash,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        SELECT client_feature_manifest_id
        FROM lab_local_game.client_feature_manifest
        WHERE content_sha256 = @content_hash;
        """,
        connection,
        transaction);
    Add(command, "content_hash", NpgsqlDbType.Bytea, hash.ToByteArray());
    var value = await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false);
    return value is null ? null : Convert.ToInt64(value, CultureInfo.InvariantCulture);
  }

  private static async Task UpdateLobbyPointerAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      long accountId,
      long expectedId,
      long resultId,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        UPDATE lab_local_game.account_client_state
        SET current_lobby_presentation_revision_id = @result_id
        WHERE local_account_id = @account_id
          AND current_lobby_presentation_revision_id = @expected_id;
        """,
        connection,
        transaction);
    Add(command, "result_id", NpgsqlDbType.Bigint, resultId);
    Add(command, "account_id", NpgsqlDbType.Bigint, accountId);
    Add(command, "expected_id", NpgsqlDbType.Bigint, expectedId);
    if (await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false) != 1)
    {
      throw new LocalGameStateIntegrityException("local_game_lobby_revision_conflict");
    }
  }

  private static async Task UpdateWalletPointerAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      long accountId,
      long expectedId,
      long resultId,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        UPDATE lab_local_game.account_client_state
        SET current_wallet_revision_id = @result_id
        WHERE local_account_id = @account_id
          AND current_wallet_revision_id = @expected_id;
        """,
        connection,
        transaction);
    Add(command, "result_id", NpgsqlDbType.Bigint, resultId);
    Add(command, "account_id", NpgsqlDbType.Bigint, accountId);
    Add(command, "expected_id", NpgsqlDbType.Bigint, expectedId);
    if (await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false) != 1)
    {
      throw new LocalGameStateIntegrityException("local_game_wallet_revision_conflict");
    }
  }

  private static async Task<LocalLobbyPresentationReceipt> ReadLobbyAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      long revisionId,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        SELECT
            revision.lobby_presentation_revision_uid,
            revision.revision_number,
            previous.lobby_presentation_revision_uid,
            revision.display_name,
            revision.commander_level_status,
            revision.commander_level,
            revision.commander_level_unresolved_reason_code,
            revision.lobby_character_status,
            character.character_uid,
            revision.lobby_character_unresolved_reason_code,
            revision.profile_icon_status,
            revision.profile_icon_selection_uid,
            revision.profile_icon_unresolved_reason_code,
            revision.profile_frame_status,
            revision.profile_frame_selection_uid,
            revision.profile_frame_unresolved_reason_code,
            revision.lobby_background_status,
            revision.lobby_background_selection_uid,
            revision.lobby_background_unresolved_reason_code,
            revision.content_sha256,
            revision.revision_origin,
            revision.materialized_at_utc
        FROM lab_local_game.lobby_presentation_revision AS revision
        LEFT JOIN lab_local_game.lobby_presentation_revision AS previous
          ON previous.lobby_presentation_revision_id =
             revision.previous_lobby_presentation_revision_id
        LEFT JOIN lab_catalog.character_entity AS character
          ON character.character_entity_id = revision.lobby_character_entity_id
        WHERE revision.lobby_presentation_revision_id = @revision_id;
        """,
        connection,
        transaction);
    Add(command, "revision_id", NpgsqlDbType.Bigint, revisionId);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
    if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      throw new LocalGameStateIntegrityException("local_game_lobby_revision_not_found");
    }

    var origin = LocalGameStateContractCanonicalizer.ParseOrigin(reader.GetString(20));
    var content = new LocalLobbyPresentationWrite(
        reader.GetString(3),
        ReadIntFact(reader, 4, 5, 6),
        ReadUidFact(reader, 7, 8, 9),
        ReadUidFact(reader, 10, 11, 12),
        ReadUidFact(reader, 13, 14, 15),
        ReadUidFact(reader, 16, 17, 18),
        origin);
    var storedHash = Sha256Digest.FromBytes((byte[])reader.GetValue(19));
    if (content.ContentSha256 != storedHash)
    {
      throw new LocalGameStateIntegrityException("local_game_lobby_hash_mismatch");
    }

    return new LocalLobbyPresentationReceipt(
        new EntityUid(reader.GetGuid(0)),
        new LocalGameRevisionLineage(
            reader.GetInt32(1),
            reader.IsDBNull(2) ? null : new EntityUid(reader.GetGuid(2)),
            origin,
            reader.GetFieldValue<DateTimeOffset>(21)),
        storedHash,
        content);
  }

  private static async Task<LocalWalletReceipt> ReadWalletAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      long revisionId,
      CancellationToken cancellationToken)
  {
    EntityUid uid;
    int number;
    EntityUid? previousUid;
    Sha256Digest hash;
    LocalGameRevisionOrigin origin;
    DateTimeOffset materializedAt;
    await using (var command = new NpgsqlCommand(
        """
        SELECT
            revision.wallet_revision_uid,
            revision.revision_number,
            previous.wallet_revision_uid,
            revision.content_sha256,
            revision.revision_origin,
            revision.materialized_at_utc
        FROM lab_local_game.wallet_revision AS revision
        LEFT JOIN lab_local_game.wallet_revision AS previous
          ON previous.wallet_revision_id = revision.previous_wallet_revision_id
        WHERE revision.wallet_revision_id = @revision_id;
        """,
        connection,
        transaction))
    {
      Add(command, "revision_id", NpgsqlDbType.Bigint, revisionId);
      await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
      if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
      {
        throw new LocalGameStateIntegrityException("local_game_wallet_revision_not_found");
      }

      uid = new EntityUid(reader.GetGuid(0));
      number = reader.GetInt32(1);
      previousUid = reader.IsDBNull(2) ? null : new EntityUid(reader.GetGuid(2));
      hash = Sha256Digest.FromBytes((byte[])reader.GetValue(3));
      origin = LocalGameStateContractCanonicalizer.ParseOrigin(reader.GetString(4));
      materializedAt = reader.GetFieldValue<DateTimeOffset>(5);
    }

    var balances = new List<LocalWalletBalance>(2);
    await using (var command = new NpgsqlCommand(
        """
        SELECT currency_code, amount
        FROM lab_local_game.wallet_balance
        WHERE wallet_revision_id = @revision_id
        ORDER BY currency_code;
        """,
        connection,
        transaction))
    {
      Add(command, "revision_id", NpgsqlDbType.Bigint, revisionId);
      await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
      while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
      {
        balances.Add(new LocalWalletBalance(
            ParseCurrency(reader.GetString(0)),
            reader.GetInt64(1)));
      }
    }

    var content = new LocalWalletWrite(balances, origin);
    if (content.ContentSha256 != hash)
    {
      throw new LocalGameStateIntegrityException("local_game_wallet_hash_mismatch");
    }

    return new LocalWalletReceipt(
        uid,
        new LocalGameRevisionLineage(number, previousUid, origin, materializedAt),
        hash,
        content);
  }

  private static async Task<LocalClientFeatureManifestReceipt> ReadFeatureManifestAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      long manifestId,
      bool isReused,
      CancellationToken cancellationToken)
  {
    EntityUid uid;
    string version;
    Sha256Digest hash;
    DateTimeOffset publishedAt;
    await using (var command = new NpgsqlCommand(
        """
        SELECT
            client_feature_manifest_uid,
            contract_version,
            content_sha256,
            published_at_utc
        FROM lab_local_game.client_feature_manifest
        WHERE client_feature_manifest_id = @manifest_id;
        """,
        connection,
        transaction))
    {
      Add(command, "manifest_id", NpgsqlDbType.Bigint, manifestId);
      await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
      if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
      {
        throw new LocalGameStateIntegrityException("local_game_feature_manifest_not_found");
      }

      uid = new EntityUid(reader.GetGuid(0));
      version = reader.GetString(1);
      hash = Sha256Digest.FromBytes((byte[])reader.GetValue(2));
      publishedAt = reader.GetFieldValue<DateTimeOffset>(3);
    }

    var entries = new List<LocalClientFeatureEntry>();
    await using (var command = new NpgsqlCommand(
        """
        SELECT route_code, capability_code
        FROM lab_local_game.client_feature_manifest_entry
        WHERE client_feature_manifest_id = @manifest_id
        ORDER BY route_code;
        """,
        connection,
        transaction))
    {
      Add(command, "manifest_id", NpgsqlDbType.Bigint, manifestId);
      await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
      while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
      {
        entries.Add(new LocalClientFeatureEntry(
            reader.GetString(0),
            LocalGameStateContractCanonicalizer.ParseCapability(reader.GetString(1))));
      }
    }

    var projected = new LocalClientFeatureManifestWrite(version, entries);
    if (projected.ContentSha256 != hash)
    {
      throw new LocalGameStateIntegrityException("local_game_feature_manifest_hash_mismatch");
    }

    return new LocalClientFeatureManifestReceipt(
        uid,
        isReused,
        version,
        hash,
        publishedAt,
        entries.AsReadOnly());
  }

  private static async Task<LocalGameStateReceipt> ReadStateReceiptAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      long accountId,
      EntityUid? operationUid,
      bool isReplay,
      CancellationToken cancellationToken)
  {
    EntityUid accountUid;
    EntityUid profileRevisionUid;
    ClientStateHead state;
    await using (var command = new NpgsqlCommand(
        """
        SELECT
            account.local_account_uid,
            profile.profile_template_revision_uid,
            state.current_lobby_presentation_revision_id,
            state.current_wallet_revision_id,
            state.current_client_feature_manifest_id
        FROM lab_profile.local_account AS account
        JOIN lab_profile.profile_template_revision AS profile
          ON profile.profile_template_revision_id =
             account.current_profile_template_revision_id
        JOIN lab_local_game.account_client_state AS state
          ON state.local_account_id = account.local_account_id
        WHERE account.local_account_id = @account_id;
        """,
        connection,
        transaction))
    {
      Add(command, "account_id", NpgsqlDbType.Bigint, accountId);
      await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
      if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
      {
        throw new LocalGameStateIntegrityException("local_game_state_not_initialized");
      }

      accountUid = new EntityUid(reader.GetGuid(0));
      profileRevisionUid = new EntityUid(reader.GetGuid(1));
      state = new ClientStateHead(reader.GetInt64(2), reader.GetInt64(3), reader.GetInt64(4));
    }

    return new LocalGameStateReceipt(
        operationUid,
        isReplay,
        accountUid,
        profileRevisionUid,
        await ReadLobbyAsync(
            connection,
            transaction,
            state.LobbyRevisionId,
            cancellationToken).ConfigureAwait(false),
        await ReadWalletAsync(
            connection,
            transaction,
            state.WalletRevisionId,
            cancellationToken).ConfigureAwait(false),
        await ReadFeatureManifestAsync(
            connection,
            transaction,
            state.FeatureManifestId,
            isReused: false,
            cancellationToken).ConfigureAwait(false));
  }

  private static async Task<BootstrapBinding?> ReadBootstrapBindingAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      EntityUid accountUid,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        SELECT
            account.local_account_id,
            profile.profile_template_revision_id,
            profile.profile_template_revision_uid,
            state_revision.account_state_revision_uid,
            profile.squad_revision_id,
            client.current_lobby_presentation_revision_id,
            client.current_wallet_revision_id,
            client.current_client_feature_manifest_id,
            profile.character_catalog_snapshot_id
        FROM lab_profile.local_account AS account
        JOIN lab_profile.profile_template_revision AS profile
          ON profile.profile_template_revision_id =
             account.current_profile_template_revision_id
        JOIN lab_profile.account_state_revision AS state_revision
          ON state_revision.account_state_revision_id = profile.account_state_revision_id
        JOIN lab_local_game.account_client_state AS client
          ON client.local_account_id = account.local_account_id
        WHERE account.local_account_uid = @account_uid;
        """,
        connection,
        transaction);
    Add(command, "account_uid", NpgsqlDbType.Uuid, accountUid.Value);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
    if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      return null;
    }

    return new BootstrapBinding(
        reader.GetInt64(0),
        reader.GetInt64(1),
        new EntityUid(reader.GetGuid(2)),
        new EntityUid(reader.GetGuid(3)),
        reader.IsDBNull(4) ? null : reader.GetInt64(4),
        reader.GetInt64(5),
        reader.GetInt64(6),
        reader.GetInt64(7),
        reader.GetInt64(8));
  }

  private static async Task EnsureCurrentLobbyCompatibilityAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      BootstrapBinding binding,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        SELECT EXISTS (
            SELECT 1
            FROM lab_local_game.lobby_presentation_revision AS lobby
            WHERE lobby.lobby_presentation_revision_id = @lobby_id
              AND lobby.local_account_id = @account_id
              AND lobby.character_catalog_snapshot_id = @catalog_id
              AND lobby.validated_profile_template_revision_id = @profile_id
              AND (
                  lobby.lobby_character_status = 'unresolved'
                  OR EXISTS (
                      SELECT 1
                      FROM lab_profile.profile_template_revision_build AS member
                      JOIN lab_profile.character_build AS build
                        ON build.character_build_id = member.character_build_id
                      WHERE member.profile_template_revision_id = @profile_id
                        AND build.character_entity_id = lobby.lobby_character_entity_id
                  )
              )
        );
        """,
        connection,
        transaction);
    Add(command, "lobby_id", NpgsqlDbType.Bigint, binding.LobbyRevisionId);
    Add(command, "account_id", NpgsqlDbType.Bigint, binding.AccountId);
    Add(command, "catalog_id", NpgsqlDbType.Bigint, binding.CharacterCatalogId);
    Add(command, "profile_id", NpgsqlDbType.Bigint, binding.ProfileRevisionId);
    var valid = Convert.ToBoolean(
        await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false),
        CultureInfo.InvariantCulture);
    if (!valid)
    {
      throw new LocalGameStateIntegrityException("local_game_lobby_profile_stale");
    }
  }

  private static async Task<IReadOnlyList<LocalClientRosterEntryProjection>> ReadRosterAsync(
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
            revision.build_revision_uid,
            revision.content_sha256,
            revision.selection_readiness_status,
            revision.combat_semantics_readiness_status
        FROM lab_profile.profile_template_revision_build AS member
        JOIN lab_profile.character_build AS build
          ON build.character_build_id = member.character_build_id
        JOIN lab_catalog.character_entity AS character
          ON character.character_entity_id = build.character_entity_id
        JOIN lab_profile.character_build_revision AS revision
          ON revision.build_revision_id = member.build_revision_id
        WHERE member.profile_template_revision_id = @profile_id
        ORDER BY member.ordinal;
        """,
        connection,
        transaction);
    Add(command, "profile_id", NpgsqlDbType.Bigint, profileRevisionId);
    var result = new List<LocalClientRosterEntryProjection>();
    await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
    while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      result.Add(new LocalClientRosterEntryProjection(
          new EntityUid(reader.GetGuid(0)),
          new EntityUid(reader.GetGuid(1)),
          new EntityUid(reader.GetGuid(2)),
          Sha256Digest.FromBytes((byte[])reader.GetValue(3)),
          reader.GetString(4) == "ready",
          reader.GetString(5) == "ready"));
    }

    return result.AsReadOnly();
  }

  private static async Task<LocalClientSquadProjection?> ReadSquadAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      long? squadRevisionId,
      CancellationToken cancellationToken)
  {
    if (!squadRevisionId.HasValue)
    {
      return null;
    }

    EntityUid squadUid;
    EntityUid revisionUid;
    await using (var header = new NpgsqlCommand(
        """
        SELECT squad.local_squad_uid, revision.squad_revision_uid
        FROM lab_profile.squad_revision AS revision
        JOIN lab_profile.local_squad AS squad
          ON squad.local_squad_id = revision.local_squad_id
        WHERE revision.squad_revision_id = @revision_id;
        """,
        connection,
        transaction))
    {
      Add(header, "revision_id", NpgsqlDbType.Bigint, squadRevisionId.Value);
      await using var reader = await header.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
      if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
      {
        throw new LocalGameStateIntegrityException("local_game_squad_revision_not_found");
      }

      squadUid = new EntityUid(reader.GetGuid(0));
      revisionUid = new EntityUid(reader.GetGuid(1));
    }

    var members = new List<LocalClientSquadMemberProjection>(5);
    await using (var command = new NpgsqlCommand(
        """
        SELECT
            member.position,
            character.character_uid,
            build.character_build_uid,
            revision.build_revision_uid
        FROM lab_profile.squad_revision_member AS member
        JOIN lab_profile.character_build AS build
          ON build.character_build_id = member.character_build_id
        JOIN lab_catalog.character_entity AS character
          ON character.character_entity_id = build.character_entity_id
        JOIN lab_profile.character_build_revision AS revision
          ON revision.build_revision_id = member.build_revision_id
        WHERE member.squad_revision_id = @revision_id
        ORDER BY member.position;
        """,
        connection,
        transaction))
    {
      Add(command, "revision_id", NpgsqlDbType.Bigint, squadRevisionId.Value);
      await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
      while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
      {
        members.Add(new LocalClientSquadMemberProjection(
            reader.GetInt16(0),
            new EntityUid(reader.GetGuid(1)),
            new EntityUid(reader.GetGuid(2)),
            new EntityUid(reader.GetGuid(3))));
      }
    }

    return new LocalClientSquadProjection(squadUid, revisionUid, members.AsReadOnly());
  }

  private static async Task<LocalClientInventorySubsetProjection> ReadInventoryAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      long profileRevisionId,
      CancellationToken cancellationToken)
  {
    var items = new List<LocalClientInventoryItemProjection>();
    var equipmentValues = new Dictionary<long, List<LocalClientInventoryValueProjection>>();
    var overloadIndexes = new Dictionary<long, HashSet<int>>();
    await using (var equipment = new NpgsqlCommand(
        """
        SELECT
            state.build_equipment_state_id,
            slot.equipment_slot_uid,
            character.character_uid,
            revision.build_revision_uid,
            state.slot_code,
            state.equipment_state,
            definition.definition_uid,
            version.definition_version_uid,
            state.enhancement_level_status,
            state.enhancement_level,
            state.enhancement_level_unresolved_reason_code,
            state.manufacturer_matched_status,
            state.manufacturer_matched,
            state.manufacturer_matched_unresolved_reason_code
        FROM lab_profile.profile_template_revision_build AS member
        JOIN lab_profile.character_build AS build
          ON build.character_build_id = member.character_build_id
        JOIN lab_catalog.character_entity AS character
          ON character.character_entity_id = build.character_entity_id
        JOIN lab_profile.character_build_revision AS revision
          ON revision.build_revision_id = member.build_revision_id
        JOIN lab_profile.build_equipment_state AS state
          ON state.build_revision_id = revision.build_revision_id
        JOIN lab_profile.equipment_slot_entity AS slot
          ON slot.equipment_slot_id = state.equipment_slot_id
        LEFT JOIN lab_combat_support.definition_entity AS definition
          ON definition.definition_entity_id = state.definition_entity_id
        LEFT JOIN lab_combat_support.definition_version AS version
          ON version.definition_version_id = state.definition_version_id
        WHERE member.profile_template_revision_id = @profile_id
        ORDER BY member.ordinal, state.slot_code;
        """,
        connection,
        transaction))
    {
      Add(equipment, "profile_id", NpgsqlDbType.Bigint, profileRevisionId);
      await using var reader = await equipment.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
      while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
      {
        var stateId = reader.GetInt64(0);
        var values = new List<LocalClientInventoryValueProjection>();
        if (!reader.IsDBNull(11))
        {
          values.Add(new LocalClientInventoryValueProjection(
              "manufacturer_matched",
              reader.GetString(11),
              BooleanValue: reader.IsDBNull(12) ? null : reader.GetBoolean(12),
              UnresolvedReasonCode: reader.IsDBNull(13) ? null : reader.GetString(13)));
        }

        equipmentValues.Add(stateId, values);
        overloadIndexes.Add(stateId, []);
        items.Add(new LocalClientInventoryItemProjection(
            "equipment",
            new EntityUid(reader.GetGuid(1)),
            new EntityUid(reader.GetGuid(2)),
            new EntityUid(reader.GetGuid(3)),
            reader.GetString(4),
            reader.GetString(5),
            reader.IsDBNull(6) ? null : new EntityUid(reader.GetGuid(6)),
            reader.IsDBNull(7) ? null : new EntityUid(reader.GetGuid(7)),
            reader.IsDBNull(8) ? null : reader.GetString(8),
            reader.IsDBNull(9) ? null : reader.GetInt16(9),
            reader.IsDBNull(10) ? null : reader.GetString(10),
            values));
      }
    }

    await using (var overload = new NpgsqlCommand(
        """
        SELECT
            state.build_equipment_state_id,
            line.line_index,
            definition.definition_uid,
            version.definition_version_uid,
            line.unit_code,
            line.exact_unscaled_value,
            line.exact_decimal_scale
        FROM lab_profile.profile_template_revision_build AS member
        JOIN lab_profile.character_build_revision AS revision
          ON revision.build_revision_id = member.build_revision_id
        JOIN lab_profile.build_equipment_state AS state
          ON state.build_revision_id = revision.build_revision_id
        JOIN lab_profile.build_overload_line AS line
          ON line.build_equipment_state_id = state.build_equipment_state_id
        JOIN lab_combat_support.definition_entity AS definition
          ON definition.definition_entity_id = line.definition_entity_id
        JOIN lab_combat_support.definition_version AS version
          ON version.definition_version_id = line.definition_version_id
        WHERE member.profile_template_revision_id = @profile_id
        ORDER BY member.ordinal, state.slot_code, line.line_index;
        """,
        connection,
        transaction))
    {
      Add(overload, "profile_id", NpgsqlDbType.Bigint, profileRevisionId);
      await using var reader = await overload.ExecuteReaderAsync(cancellationToken)
          .ConfigureAwait(false);
      while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
      {
        var stateId = reader.GetInt64(0);
        var lineIndex = reader.GetInt16(1);
        if (!equipmentValues.TryGetValue(stateId, out var values) ||
            !overloadIndexes[stateId].Add(lineIndex))
        {
          throw new LocalGameStateIntegrityException("local_game_inventory_overload_invalid");
        }

        var prefix = $"overload.{lineIndex}";
        values.Add(new LocalClientInventoryValueProjection(
            $"{prefix}.state", "ready", ControlledValue: "present"));
        values.Add(new LocalClientInventoryValueProjection(
            $"{prefix}.definition", "ready", ReferenceUid: new EntityUid(reader.GetGuid(2))));
        values.Add(new LocalClientInventoryValueProjection(
            $"{prefix}.definition_version",
            "ready",
            ReferenceUid: new EntityUid(reader.GetGuid(3))));
        values.Add(new LocalClientInventoryValueProjection(
            $"{prefix}.unit", "ready", ControlledValue: reader.GetString(4)));
        values.Add(new LocalClientInventoryValueProjection(
            $"{prefix}.value",
            "ready",
            UnscaledValue: reader.GetInt64(5),
            DecimalScale: reader.GetInt16(6)));
      }
    }

    foreach (var (stateId, values) in equipmentValues)
    {
      for (var lineIndex = 1; lineIndex <= 3; lineIndex++)
      {
        if (!overloadIndexes[stateId].Contains(lineIndex))
        {
          values.Add(new LocalClientInventoryValueProjection(
              $"overload.{lineIndex}.state", "ready", ControlledValue: "absent"));
        }
      }
    }

    await using (var optional = new NpgsqlCommand(
        """
        SELECT
            character.character_uid,
            revision.build_revision_uid,
            revision.cube_state,
            cube.definition_uid,
            cube_version.definition_version_uid,
            revision.cube_level_status,
            revision.cube_level,
            revision.cube_level_unresolved_reason_code,
            revision.collection_kind,
            collection.definition_uid,
            collection_version.definition_version_uid,
            revision.collection_level_status,
            revision.collection_level,
            revision.collection_level_unresolved_reason_code
        FROM lab_profile.profile_template_revision_build AS member
        JOIN lab_profile.character_build AS build
          ON build.character_build_id = member.character_build_id
        JOIN lab_catalog.character_entity AS character
          ON character.character_entity_id = build.character_entity_id
        JOIN lab_profile.character_build_revision AS revision
          ON revision.build_revision_id = member.build_revision_id
        LEFT JOIN lab_combat_support.definition_entity AS cube
          ON cube.definition_entity_id = revision.cube_definition_entity_id
        LEFT JOIN lab_combat_support.definition_version AS cube_version
          ON cube_version.definition_version_id = revision.cube_definition_version_id
        LEFT JOIN lab_combat_support.definition_entity AS collection
          ON collection.definition_entity_id = revision.collection_definition_entity_id
        LEFT JOIN lab_combat_support.definition_version AS collection_version
          ON collection_version.definition_version_id = revision.collection_definition_version_id
        WHERE member.profile_template_revision_id = @profile_id
        ORDER BY member.ordinal;
        """,
        connection,
        transaction))
    {
      Add(optional, "profile_id", NpgsqlDbType.Bigint, profileRevisionId);
      await using var reader = await optional.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
      while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
      {
        var characterUid = new EntityUid(reader.GetGuid(0));
        var buildRevisionUid = new EntityUid(reader.GetGuid(1));
        items.Add(new LocalClientInventoryItemProjection(
            "cube",
            null,
            characterUid,
            buildRevisionUid,
            null,
            reader.GetString(2),
            reader.IsDBNull(3) ? null : new EntityUid(reader.GetGuid(3)),
            reader.IsDBNull(4) ? null : new EntityUid(reader.GetGuid(4)),
            reader.IsDBNull(5) ? null : reader.GetString(5),
            reader.IsDBNull(6) ? null : reader.GetInt16(6),
            reader.IsDBNull(7) ? null : reader.GetString(7)));
        var collectionKind = reader.GetString(8);
        items.Add(new LocalClientInventoryItemProjection(
            collectionKind is "favorite" ? "favorite" : "collection",
            null,
            characterUid,
            buildRevisionUid,
            null,
            collectionKind,
            reader.IsDBNull(9) ? null : new EntityUid(reader.GetGuid(9)),
            reader.IsDBNull(10) ? null : new EntityUid(reader.GetGuid(10)),
            reader.IsDBNull(11) ? null : reader.GetString(11),
            reader.IsDBNull(12) ? null : reader.GetInt32(12),
            reader.IsDBNull(13) ? null : reader.GetString(13)));
      }
    }

    return new LocalClientInventorySubsetProjection(
        "equipped_combat_items_v1",
        IsCompleteInventory: false,
        IsReadOnly: true,
        items.AsReadOnly());
  }

  private static LocalGameIntFact ReadIntFact(
      NpgsqlDataReader reader,
      int statusOrdinal,
      int valueOrdinal,
      int reasonOrdinal) => reader.GetString(statusOrdinal) switch
      {
        "ready" => LocalGameIntFact.Ready(reader.GetInt32(valueOrdinal)),
        "unresolved" => LocalGameIntFact.Unresolved(reader.GetString(reasonOrdinal)),
        _ => throw new LocalGameStateIntegrityException("local_game_fact_status_invalid")
      };

  private static LocalGameUidFact ReadUidFact(
      NpgsqlDataReader reader,
      int statusOrdinal,
      int valueOrdinal,
      int reasonOrdinal) => reader.GetString(statusOrdinal) switch
      {
        "ready" => LocalGameUidFact.Ready(new EntityUid(reader.GetGuid(valueOrdinal))),
        "unresolved" => LocalGameUidFact.Unresolved(reader.GetString(reasonOrdinal)),
        _ => throw new LocalGameStateIntegrityException("local_game_fact_status_invalid")
      };

  private static LocalWalletCurrency ParseCurrency(string value) => value switch
  {
    "jewel" => LocalWalletCurrency.Jewel,
    "credit" => LocalWalletCurrency.Credit,
    _ => throw new LocalGameStateIntegrityException("local_game_currency_invalid")
  };

  private static void AddIntFact(
      NpgsqlCommand command,
      string prefix,
      LocalGameIntFact fact)
  {
    Add(command, $"{prefix}_status", NpgsqlDbType.Text,
        LocalGameStateContractCanonicalizer.Code(fact.Status));
    Add(command, $"{prefix}_value", NpgsqlDbType.Integer, fact.Value);
    Add(command, $"{prefix}_reason", NpgsqlDbType.Text, fact.UnresolvedReasonCode);
  }

  private static void AddUidFact(
      NpgsqlCommand command,
      string prefix,
      LocalGameUidFact fact,
      long? entityId = null,
      long? versionId = null)
  {
    Add(command, $"{prefix}_status", NpgsqlDbType.Text,
        LocalGameStateContractCanonicalizer.Code(fact.Status));
    if (prefix == "character")
    {
      Add(command, "character_entity_id", NpgsqlDbType.Bigint, entityId);
      Add(command, "character_version_id", NpgsqlDbType.Bigint, versionId);
    }
    else
    {
      Add(command, $"{prefix}_uid", NpgsqlDbType.Uuid, fact.Value?.Value);
    }

    Add(command, $"{prefix}_reason", NpgsqlDbType.Text, fact.UnresolvedReasonCode);
  }

  private static StoredRevision ToStoredRevision(
      long id,
      LocalLobbyPresentationReceipt receipt) => new(
          id,
          receipt.RevisionUid,
          receipt.Lineage.RevisionNumber,
          receipt.Lineage.PreviousRevisionUid,
          receipt.ContentSha256,
          receipt.Lineage.Origin,
          receipt.Lineage.MaterializedAtUtc);

  private static StoredRevision ToStoredRevision(long id, LocalWalletReceipt receipt) => new(
      id,
      receipt.RevisionUid,
      receipt.Lineage.RevisionNumber,
      receipt.Lineage.PreviousRevisionUid,
      receipt.ContentSha256,
      receipt.Lineage.Origin,
      receipt.Lineage.MaterializedAtUtc);

  private static async Task AcquireOperationLockAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      EntityUid operationUid,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        "SELECT pg_advisory_xact_lock(hashtextextended(@value, @seed));",
        connection,
        transaction);
    Add(command, "value", NpgsqlDbType.Text, operationUid.ToString());
    Add(command, "seed", NpgsqlDbType.Bigint, OperationLockSeed);
    await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
  }

  private static async Task AcquireContentLockAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      Sha256Digest contentSha256,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        "SELECT pg_advisory_xact_lock(hashtextextended(@value, @seed));",
        connection,
        transaction);
    Add(command, "value", NpgsqlDbType.Text, contentSha256.ToString());
    Add(command, "seed", NpgsqlDbType.Bigint, ContentLockSeed);
    await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
  }

  private static async Task<OperationRow?> ReadOperationAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      EntityUid operationUid,
      Sha256Digest requestSha256,
      string expectedKind,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        SELECT
            operation_kind,
            request_sha256,
            local_account_id,
            result_lobby_presentation_revision_id,
            result_wallet_revision_id,
            result_client_feature_manifest_id
        FROM lab_local_game.client_state_write_operation
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
      throw new LocalGameStateIntegrityException("local_game_operation_reuse_mismatch");
    }

    return new OperationRow(
        reader.IsDBNull(2) ? null : reader.GetInt64(2),
        reader.IsDBNull(3) ? null : reader.GetInt64(3),
        reader.IsDBNull(4) ? null : reader.GetInt64(4),
        reader.IsDBNull(5) ? null : reader.GetInt64(5));
  }

  private static async Task RecordOperationAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      EntityUid operationUid,
      string kind,
      Sha256Digest requestSha256,
      long? accountId,
      EntityUid? expectedRevisionUid,
      long? lobbyRevisionId,
      long? walletRevisionId,
      long? manifestId,
      DateTimeOffset completedAtUtc,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        INSERT INTO lab_local_game.client_state_write_operation (
            operation_uid,
            operation_kind,
            request_sha256,
            local_account_id,
            expected_revision_uid,
            result_lobby_presentation_revision_id,
            result_wallet_revision_id,
            result_client_feature_manifest_id,
            completed_at_utc
        ) VALUES (
            @operation_uid, @kind, @request_hash, @account_id, @expected_uid,
            @lobby_id, @wallet_id, @manifest_id, @completed_at
        );
        """,
        connection,
        transaction);
    Add(command, "operation_uid", NpgsqlDbType.Uuid, operationUid.Value);
    Add(command, "kind", NpgsqlDbType.Text, kind);
    Add(command, "request_hash", NpgsqlDbType.Bytea, requestSha256.ToByteArray());
    Add(command, "account_id", NpgsqlDbType.Bigint, accountId);
    Add(command, "expected_uid", NpgsqlDbType.Uuid, expectedRevisionUid?.Value);
    Add(command, "lobby_id", NpgsqlDbType.Bigint, lobbyRevisionId);
    Add(command, "wallet_id", NpgsqlDbType.Bigint, walletRevisionId);
    Add(command, "manifest_id", NpgsqlDbType.Bigint, manifestId);
    Add(command, "completed_at", NpgsqlDbType.TimestampTz, completedAtUtc);
    await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
  }

  private static LocalGameStateIntegrityException MapDatabaseException(PostgresException exception)
  {
    var code = exception.MessageText switch
    {
      "immutable_local_game_row" => "local_game_immutable_row",
      "local_game_wallet_incomplete" => "local_game_wallet_incomplete",
      "local_game_feature_manifest_incomplete" => "local_game_feature_manifest_incomplete",
      "local_game_lobby_profile_binding_invalid" => "local_game_lobby_profile_binding_invalid",
      "local_game_lobby_character_not_in_profile" => "local_game_lobby_character_not_in_profile",
      "local_game_revision_lineage_invalid" => "local_game_revision_lineage_invalid",
      _ when exception.SqlState == PostgresErrorCodes.UniqueViolation =>
          "local_game_unique_constraint_conflict",
      _ when exception.SqlState == PostgresErrorCodes.ForeignKeyViolation =>
          "local_game_reference_invalid",
      _ when exception.SqlState == PostgresErrorCodes.CheckViolation =>
          "local_game_value_invalid",
      _ => "local_game_database_rejected"
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

  private sealed record CurrentProfile(
      long AccountId,
      long ProfileRevisionId,
      EntityUid ProfileRevisionUid,
      long CharacterCatalogId);

  private sealed record ClientStateHead(
      long LobbyRevisionId,
      long WalletRevisionId,
      long FeatureManifestId);

  private sealed record StoredRevision(
      long Id,
      EntityUid Uid,
      int RevisionNumber,
      EntityUid? PreviousUid,
      Sha256Digest ContentSha256,
      LocalGameRevisionOrigin Origin,
      DateTimeOffset MaterializedAtUtc);

  private sealed record OperationRow(
      long? AccountId,
      long? LobbyRevisionId,
      long? WalletRevisionId,
      long? ManifestId);

  private sealed record BootstrapBinding(
      long AccountId,
      long ProfileRevisionId,
      EntityUid ProfileRevisionUid,
      EntityUid AccountStateRevisionUid,
      long? SquadRevisionId,
      long LobbyRevisionId,
      long WalletRevisionId,
      long FeatureManifestId,
      long CharacterCatalogId);
}
