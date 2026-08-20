using System.Data;
using System.Globalization;
using App = NikkeLocalLab.Application.PrivateServer;
using ProfileApp = NikkeLocalLab.Application.ProfileManagement;
using PrivateServerDomain = global::NikkeLocalLab.Domain.PrivateServer;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;
using Npgsql;
using NpgsqlTypes;

namespace NikkeLocalLab.Persistence.PostgreSql;

public sealed partial class PostgreSqlPrivateServerService
{
  private const long PrivateServerContextOperationLockSeed = 5_614_803_147_991_271_091;

  private sealed record StoredSession(
      long Id,
      long AccountId,
      EntityUid SessionUid,
      EntityUid AccountUid,
      DateTimeOffset IssuedAtUtc,
      DateTimeOffset ExpiresAtUtc,
      DateTimeOffset? RevokedAtUtc);

  private sealed record StoredContext(
      long Id,
      long RevisionId,
      long SessionId,
      long AccountId,
      long BootId,
      long CapabilityManifestId,
      long ApplicationBuildId,
      long? AccountStateRevisionId,
      long? ProfileTemplateRevisionId,
      long? LobbyPresentationRevisionId,
      long? WalletRevisionId,
      long? ClientFeatureManifestId,
      long? SquadRevisionId,
      long? SelectedSeasonRevisionId,
      PrivateServerDomain.LocalClientContext Context,
      StoredSession Session);

  private sealed record StoredSelection(
      long SelectionId,
      long RevisionId,
      PrivateServerDomain.SelectedRaidSeasonRevision Revision);

  private sealed record StoredAccountPins(
      long AccountId,
      long AccountStateRevisionId,
      EntityUid AccountStateRevisionUid,
      long ProfileTemplateRevisionId,
      EntityUid ProfileTemplateRevisionUid,
      Sha256Digest ProfileTemplateContentSha256,
      long LobbyPresentationRevisionId,
      EntityUid LobbyPresentationRevisionUid,
      long WalletRevisionId,
      EntityUid WalletRevisionUid,
      long ClientFeatureManifestId,
      EntityUid ClientFeatureManifestUid,
      Sha256Digest ClientFeatureManifestContentSha256,
      long? SquadRevisionId,
      EntityUid? SquadRevisionUid,
      Sha256Digest? SquadRevisionContentSha256);

  public async Task ValidateSessionAccessAsync(
      App.ValidateLocalSessionAccessQuery query,
      CancellationToken cancellationToken = default)
  {
    ArgumentNullException.ThrowIfNull(query);
    RequireUid(query.LocalSessionUid, "local_session_uid_invalid");
    try
    {
      await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken)
          .ConfigureAwait(false);
      _ = await RequireActiveSessionAsync(
          connection,
          transaction: null,
          query.LocalSessionUid,
          NormalizeInstant(query.ObservedAtUtc),
          forUpdate: false,
          cancellationToken).ConfigureAwait(false);
    }
    catch (PostgresException exception)
    {
      throw MapDatabaseException(exception);
    }
    catch (NpgsqlException exception)
    {
      throw Failure(
          App.PrivateServerFailureKind.Unavailable,
          "private_server_store_unavailable",
          exception);
    }
    catch (PrivateServerDomain.PrivateServerIntegrityException exception)
    {
      throw Failure(
          App.PrivateServerFailureKind.Unavailable,
          "private_server_context_persisted_content_invalid",
          exception);
    }
  }

  public async Task<App.ClientContextProjection> OpenSessionAsync(
      App.OpenLocalSessionCommand command,
      CancellationToken cancellationToken = default)
  {
    ArgumentNullException.ThrowIfNull(command);
    RequireUid(command.OperationUid, "operation_uid_invalid");
    RequireUid(command.AccountUid, "account_uid_invalid");
    RequireUid(command.ExpectedBootRevisionUid, "boot_revision_uid_invalid");
    RequireDigest(command.ExpectedBootContentSha256, "boot_content_sha256_invalid");
    var issuedAtUtc = NormalizeInstant(command.IssuedAtUtc);
    var expiresAtUtc = NormalizeInstant(command.ExpiresAtUtc);
    if (expiresAtUtc <= issuedAtUtc || expiresAtUtc - issuedAtUtc > TimeSpan.FromHours(24))
    {
      throw Failure(App.PrivateServerFailureKind.InvalidRequest, "local_session_window_invalid");
    }

    // Issued/expires are server-observed envelope values. They are intentionally
    // excluded so a delayed retry can recover the first sealed response.
    var requestSha256 = RequestHash(
        "nll/private-server/open-client-context/v1",
        command.AccountUid,
        command.ExpectedBootRevisionUid,
        command.ExpectedBootContentSha256);
    await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken)
        .ConfigureAwait(false);
    await using var transaction = await connection.BeginTransactionAsync(
        WriteIsolation,
        cancellationToken).ConfigureAwait(false);
    try
    {
      await AcquireContextOperationLockAsync(
          connection,
          transaction,
          command.OperationUid,
          cancellationToken).ConfigureAwait(false);
      var replay = await LoadWriteOperationAsync(
          connection,
          transaction,
          command.OperationUid,
          cancellationToken).ConfigureAwait(false);
      if (replay is not null)
      {
        RequireReplay(replay, "open_client_context", requestSha256);
        var replayed = await RequireOperationContextAsync(
            connection,
            transaction,
            replay,
            command.AccountUid,
            cancellationToken).ConfigureAwait(false);
        await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
        return Project(replayed.Context);
      }

      var accountId = await LockAccountIdAsync(
          connection,
          transaction,
          command.AccountUid,
          cancellationToken).ConfigureAwait(false);
      var boot = await LoadBootAsync(
          connection,
          transaction,
          issuedAtUtc,
          cancellationToken).ConfigureAwait(false);
      if (boot.Projection.Revision.RevisionUid != command.ExpectedBootRevisionUid ||
          boot.Projection.Revision.ContentSha256 != command.ExpectedBootContentSha256)
      {
        throw Failure(App.PrivateServerFailureKind.Conflict, "private_server_boot_conflict");
      }

      var sessionUid = _uidGenerator.NewUid();
      var contextUid = _uidGenerator.NewUid();
      var contextRevisionUid = _uidGenerator.NewUid();
      var contextValue = PrivateServerDomain.LocalClientContext.Open(
          contextUid,
          contextRevisionUid,
          sessionUid,
          command.AccountUid,
          boot.Projection.ApplicationBuildUid,
          boot.Projection.ApplicationBuildSha256,
          boot.Projection.ApplicationContractId,
          boot.Projection.CapabilityManifest.Manifest,
          issuedAtUtc,
          expiresAtUtc);
      var sessionId = await InsertLocalSessionAsync(
          connection,
          transaction,
          sessionUid,
          accountId,
          contextValue.IssuedAtUtc,
          contextValue.ExpiresAtUtc,
          cancellationToken).ConfigureAwait(false);
      var contextId = await InsertContextAggregateAsync(
          connection,
          transaction,
          contextUid,
          sessionId,
          accountId,
          issuedAtUtc,
          cancellationToken).ConfigureAwait(false);
      var contextRevisionId = await InsertContextRevisionAsync(
          connection,
          transaction,
          contextId,
          sessionId,
          accountId,
          boot,
          previousRevisionId: null,
          contextValue,
          accountPins: null,
          selectedSeasonRevisionId: null,
          issuedAtUtc,
          cancellationToken).ConfigureAwait(false);
      await AdvanceContextHeadAsync(
          connection,
          transaction,
          contextId,
          contextRevisionId,
          cancellationToken).ConfigureAwait(false);
      await InsertWriteOperationAsync(
          connection,
          transaction,
          command.OperationUid,
          "open_client_context",
          requestSha256,
          accountId,
          expectedRevisionUid: null,
          contextUid,
          contextRevisionUid,
          contextValue.ContentSha256,
          issuedAtUtc,
          cancellationToken).ConfigureAwait(false);
      await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
      return Project(contextValue);
    }
    catch (PostgresException exception)
    {
      throw MapDatabaseException(exception);
    }
    catch (NpgsqlException exception)
    {
      throw Failure(
          App.PrivateServerFailureKind.Unavailable,
          "private_server_store_unavailable",
          exception);
    }
    catch (PrivateServerDomain.PrivateServerIntegrityException exception)
    {
      throw Failure(
          App.PrivateServerFailureKind.Conflict,
          "private_server_context_integrity_conflict",
          exception);
    }
  }

  public async Task<App.RaidSeasonDirectoryProjection> GetSeasonDirectoryAsync(
      App.SeasonDirectoryQuery query,
      CancellationToken cancellationToken = default)
  {
    ArgumentNullException.ThrowIfNull(query);
    var observedAtUtc = NormalizeInstant(query.ObservedAtUtc);
    try
    {
      await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken)
          .ConfigureAwait(false);
      var context = await RequireCurrentContextAsync(
          connection,
          transaction: null,
          query.SessionUid,
          query.ClientContextUid,
          query.ExpectedContextRevisionUid,
          observedAtUtc,
          forUpdate: false,
          cancellationToken).ConfigureAwait(false);
      var boot = await LoadBootByIdAsync(
          connection,
          transaction: null,
          context.BootId,
          cancellationToken).ConfigureAwait(false);
      return boot.Projection.Directory;
    }
    catch (PostgresException exception)
    {
      throw MapDatabaseException(exception);
    }
    catch (NpgsqlException exception)
    {
      throw Failure(
          App.PrivateServerFailureKind.Unavailable,
          "private_server_store_unavailable",
          exception);
    }
    catch (PrivateServerDomain.PrivateServerIntegrityException exception)
    {
      throw Failure(
          App.PrivateServerFailureKind.Unavailable,
          "private_server_context_persisted_content_invalid",
          exception);
    }
  }

  public async Task<App.ClientContextProjection> ConnectSessionAsync(
      App.ConnectLocalSessionCommand command,
      CancellationToken cancellationToken = default)
  {
    ArgumentNullException.ThrowIfNull(command);
    RequireMutationPin(command.OperationUid, command.RequestPin);
    RequireUid(command.ExpectedDirectoryUid, "directory_uid_invalid");
    RequireDigest(command.ExpectedDirectorySha256, "directory_sha256_invalid");
    RequireUid(command.SelectedRaidSnapshotUid, "selected_raid_snapshot_uid_invalid");
    var requestSha256 = RequestHash(
        "nll/private-server/connect-client-context/v1",
        command.RequestPin.SessionUid,
        command.RequestPin.ClientContextUid,
        command.RequestPin.ExpectedContextRevisionUid,
        command.ExpectedDirectoryUid,
        command.ExpectedDirectorySha256,
        command.SelectedRaidSnapshotUid);
    return await MutateContextAsync(
        command.OperationUid,
        "connect_client_context",
        requestSha256,
        command.RequestPin,
        async (connection, transaction, current, observedAtUtc, cancellation) =>
        {
          var boot = await LoadBootByIdAsync(
              connection,
              transaction,
              current.BootId,
              cancellation).ConfigureAwait(false);
          var directory = boot.Projection.Directory.Directory;
          if (directory.DirectoryUid != command.ExpectedDirectoryUid ||
              directory.ContentSha256 != command.ExpectedDirectorySha256)
          {
            throw Failure(
                App.PrivateServerFailureKind.Conflict,
                "raid_season_directory_conflict");
          }

          var selectedMember = directory.RequireMember(command.SelectedRaidSnapshotUid);
          var selectionUid = _uidGenerator.NewUid();
          var selectionRevisionUid = _uidGenerator.NewUid();
          var selection = PrivateServerDomain.SelectedRaidSeasonRevision.CreateInitial(
              selectionUid,
              selectionRevisionUid,
              current.Context.AccountUid,
              current.Context.SessionUid,
              current.Context.ClientContextUid,
              directory,
              selectedMember.RaidSnapshotUid,
              observedAtUtc);
          var selectionId = await InsertSelectionAggregateAsync(
              connection,
              transaction,
              selectionUid,
              current.Id,
              current.SessionId,
              current.AccountId,
              observedAtUtc,
              cancellation).ConfigureAwait(false);
          var raidSnapshotId = await RequireRaidSnapshotIdAsync(
              connection,
              transaction,
              boot.DirectoryId,
              selectedMember.RaidSnapshotUid,
              cancellation).ConfigureAwait(false);
          var selectionRevisionId = await InsertSelectionRevisionAsync(
              connection,
              transaction,
              selectionId,
              current,
              previousRevisionId: null,
              boot.DirectoryId,
              raidSnapshotId,
              selection,
              cancellation).ConfigureAwait(false);
          await AdvanceSelectionHeadAsync(
              connection,
              transaction,
              selectionId,
              selectionRevisionId,
              cancellation).ConfigureAwait(false);

          var next = current.Context.Connect(
              _uidGenerator.NewUid(),
              observedAtUtc,
              selection.SelectionRevisionUid,
              selection.ContentSha256);
          var nextRevisionId = await InsertContextRevisionAsync(
              connection,
              transaction,
              current.Id,
              current.SessionId,
              current.AccountId,
              boot,
              current.RevisionId,
              next,
              accountPins: null,
              selectionRevisionId,
              observedAtUtc,
              cancellation).ConfigureAwait(false);
          await AdvanceContextHeadAsync(
              connection,
              transaction,
              current.Id,
              nextRevisionId,
              cancellation).ConfigureAwait(false);
          return next;
        },
        cancellationToken).ConfigureAwait(false);
  }

  public async Task<App.LobbyBootstrapProjection> EnterLobbyAsync(
      App.EnterLobbyCommand command,
      CancellationToken cancellationToken = default)
  {
    ArgumentNullException.ThrowIfNull(command);
    RequireMutationPin(command.OperationUid, command.RequestPin);
    var requestSha256 = RequestHash(
        "nll/private-server/enter-lobby/v1",
        command.RequestPin.SessionUid,
        command.RequestPin.ClientContextUid,
        command.RequestPin.ExpectedContextRevisionUid);
    var context = await MutateContextAsync(
        command.OperationUid,
        "enter_lobby",
        requestSha256,
        command.RequestPin,
        async (connection, transaction, current, observedAtUtc, cancellation) =>
        {
          var bootstrap = await RequireAccountBootstrapAsync(
              current.Context.AccountUid,
              cancellation).ConfigureAwait(false);
          var pins = await LockAndVerifyAccountPinsAsync(
              connection,
              transaction,
              bootstrap,
              cancellation).ConfigureAwait(false);
          var selection = await RequireCurrentSelectionAsync(
              connection,
              transaction,
              current,
              cancellation).ConfigureAwait(false);
          var boot = await LoadBootByIdAsync(
              connection,
              transaction,
              current.BootId,
              cancellation).ConfigureAwait(false);
          var next = current.Context.BindLobby(
              _uidGenerator.NewUid(),
              observedAtUtc,
              bootstrap.RevisionSetSha256,
              selection.Revision.SelectionRevisionUid,
              selection.Revision.ContentSha256);
          var nextRevisionId = await InsertContextRevisionAsync(
              connection,
              transaction,
              current.Id,
              current.SessionId,
              current.AccountId,
              boot,
              current.RevisionId,
              next,
              pins,
              selection.RevisionId,
              observedAtUtc,
              cancellation).ConfigureAwait(false);
          await AdvanceContextHeadAsync(
              connection,
              transaction,
              current.Id,
              nextRevisionId,
              cancellation).ConfigureAwait(false);
          return next;
        },
        cancellationToken).ConfigureAwait(false);
    return await BuildLobbyBootstrapAsync(context, cancellationToken).ConfigureAwait(false);
  }

  public async Task<App.LobbyBootstrapProjection> GetLobbyBootstrapAsync(
      App.LobbyBootstrapQuery query,
      CancellationToken cancellationToken = default)
  {
    ArgumentNullException.ThrowIfNull(query);
    try
    {
      await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken)
          .ConfigureAwait(false);
      var stored = await RequireCurrentContextAsync(
          connection,
          transaction: null,
          query.SessionUid,
          query.ClientContextUid,
          query.ExpectedContextRevisionUid,
          NormalizeInstant(query.ObservedAtUtc),
          forUpdate: false,
          cancellationToken).ConfigureAwait(false);
      RequireLobbyReady(stored);
      return await BuildLobbyBootstrapAsync(
          connection,
          transaction: null,
          stored,
          cancellationToken).ConfigureAwait(false);
    }
    catch (PostgresException exception)
    {
      throw MapDatabaseException(exception);
    }
    catch (NpgsqlException exception)
    {
      throw Failure(
          App.PrivateServerFailureKind.Unavailable,
          "private_server_store_unavailable",
          exception);
    }
    catch (PrivateServerDomain.PrivateServerIntegrityException exception)
    {
      throw Failure(
          App.PrivateServerFailureKind.Unavailable,
          "private_server_context_persisted_content_invalid",
          exception);
    }
  }

  public async Task<App.SelectedRaidSeasonProjection> SelectSeasonAsync(
      App.SelectRaidSeasonCommand command,
      CancellationToken cancellationToken = default)
  {
    ArgumentNullException.ThrowIfNull(command);
    RequireMutationPin(command.OperationUid, command.RequestPin);
    RequireUid(command.ExpectedSelectionRevisionUid, "selection_revision_uid_invalid");
    RequireUid(command.ExpectedDirectoryUid, "directory_uid_invalid");
    RequireDigest(command.ExpectedDirectorySha256, "directory_sha256_invalid");
    RequireUid(command.SelectedRaidSnapshotUid, "selected_raid_snapshot_uid_invalid");
    var requestSha256 = RequestHash(
        "nll/private-server/select-raid-season/v1",
        command.RequestPin.SessionUid,
        command.RequestPin.ClientContextUid,
        command.RequestPin.ExpectedContextRevisionUid,
        command.ExpectedSelectionRevisionUid,
        command.ExpectedDirectoryUid,
        command.ExpectedDirectorySha256,
        command.SelectedRaidSnapshotUid);
    var context = await MutateContextAsync(
        command.OperationUid,
        "select_raid_season",
        requestSha256,
        command.RequestPin,
        async (connection, transaction, current, observedAtUtc, cancellation) =>
        {
          RequireLobbyReady(current);
          var boot = await LoadBootByIdAsync(
              connection,
              transaction,
              current.BootId,
              cancellation).ConfigureAwait(false);
          var directory = boot.Projection.Directory.Directory;
          if (directory.DirectoryUid != command.ExpectedDirectoryUid ||
              directory.ContentSha256 != command.ExpectedDirectorySha256)
          {
            throw Failure(
                App.PrivateServerFailureKind.Conflict,
                "raid_season_directory_conflict");
          }

          var selection = await RequireCurrentSelectionAsync(
              connection,
              transaction,
              current,
              cancellation).ConfigureAwait(false);
          if (selection.Revision.SelectionRevisionUid != command.ExpectedSelectionRevisionUid)
          {
            throw Failure(
                App.PrivateServerFailureKind.Conflict,
                "selected_raid_season_revision_conflict");
          }

          var nextSelection = selection.Revision.Select(
              _uidGenerator.NewUid(),
              directory,
              command.SelectedRaidSnapshotUid,
              observedAtUtc);
          if (ReferenceEquals(nextSelection, selection.Revision))
          {
            return current.Context;
          }

          await RequireNoActiveChallengeRunForSelectionChangeAsync(
              connection,
              transaction,
              current.AccountId,
              current.Id,
              cancellation).ConfigureAwait(false);

          var selectedMember = directory.RequireMember(command.SelectedRaidSnapshotUid);
          var raidSnapshotId = await RequireRaidSnapshotIdAsync(
              connection,
              transaction,
              boot.DirectoryId,
              selectedMember.RaidSnapshotUid,
              cancellation).ConfigureAwait(false);
          var nextSelectionRevisionId = await InsertSelectionRevisionAsync(
              connection,
              transaction,
              selection.SelectionId,
              current,
              selection.RevisionId,
              boot.DirectoryId,
              raidSnapshotId,
              nextSelection,
              cancellation).ConfigureAwait(false);
          await AdvanceSelectionHeadAsync(
              connection,
              transaction,
              selection.SelectionId,
              nextSelectionRevisionId,
              cancellation).ConfigureAwait(false);
          var nextContext = current.Context.RebindSelectedSeason(
              _uidGenerator.NewUid(),
              observedAtUtc,
              nextSelection.SelectionRevisionUid,
              nextSelection.ContentSha256);
          var nextContextRevisionId = await InsertContextRevisionAsync(
              connection,
              transaction,
              current.Id,
              current.SessionId,
              current.AccountId,
              boot,
              current.RevisionId,
              nextContext,
              await RequireStoredAccountPinsAsync(
                  connection,
                  transaction,
                  current,
                  cancellation).ConfigureAwait(false),
              nextSelectionRevisionId,
              observedAtUtc,
              cancellation).ConfigureAwait(false);
          await AdvanceContextHeadAsync(
              connection,
              transaction,
              current.Id,
              nextContextRevisionId,
              cancellation).ConfigureAwait(false);
          return nextContext;
        },
        cancellationToken).ConfigureAwait(false);
    return await LoadSelectedProjectionForContextAsync(context, cancellationToken)
        .ConfigureAwait(false);
  }

  public async Task<App.SoloRaidStateProjection> GetSoloRaidStateAsync(
      App.SoloRaidStateQuery query,
      CancellationToken cancellationToken = default)
  {
    ArgumentNullException.ThrowIfNull(query);
    var observedAtUtc = NormalizeInstant(query.ObservedAtUtc);
    try
    {
      await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken)
          .ConfigureAwait(false);
      var stored = await RequireCurrentContextAsync(
          connection,
          transaction: null,
          query.SessionUid,
          query.ClientContextUid,
          query.ExpectedContextRevisionUid,
          observedAtUtc,
          forUpdate: false,
          cancellationToken).ConfigureAwait(false);
      RequireLobbyReady(stored);
      var boot = await LoadBootByIdAsync(
          connection,
          transaction: null,
          stored.BootId,
          cancellationToken).ConfigureAwait(false);
      var selection = await RequireCurrentSelectionAsync(
          connection,
          transaction: null,
          stored,
          cancellationToken).ConfigureAwait(false);
      var admission = await LoadAdmissionPinsAsync(
          connection,
          transaction: null,
          stored,
          cancellationToken).ConfigureAwait(false);
      var daily = await LoadCurrentDailyStateProjectionAsync(
          connection,
          transaction: null,
          stored,
          boot,
          selection,
          observedAtUtc,
          cancellationToken).ConfigureAwait(false);
      var activeRun = await LoadActiveChallengeRunForSoloRaidAsync(
          connection,
          transaction: null,
          stored.AccountId,
          cancellationToken).ConfigureAwait(false);
      return new App.SoloRaidStateProjection(
          Project(stored.Context),
          boot.Projection.Directory,
          new App.SelectedRaidSeasonProjection(selection.Revision, Project(stored.Context)),
          admission,
          boot.Projection.FixedCapabilities,
          boot.Projection.OperationalPolicy,
          daily,
          activeRun,
          boot.Projection.CapabilityManifest);
    }
    catch (PostgresException exception)
    {
      throw MapDatabaseException(exception);
    }
    catch (NpgsqlException exception)
    {
      throw Failure(
          App.PrivateServerFailureKind.Unavailable,
          "private_server_store_unavailable",
          exception);
    }
    catch (PrivateServerDomain.PrivateServerIntegrityException exception)
    {
      throw Failure(
          App.PrivateServerFailureKind.Unavailable,
          "private_server_context_persisted_content_invalid",
          exception);
    }
  }

  private async Task<App.ClientContextProjection> MutateContextAsync(
      EntityUid operationUid,
      string operationKind,
      Sha256Digest requestSha256,
      App.SessionRequestPin requestPin,
      Func<
          NpgsqlConnection,
          NpgsqlTransaction,
          StoredContext,
          DateTimeOffset,
          CancellationToken,
          Task<PrivateServerDomain.LocalClientContext>> mutate,
      CancellationToken cancellationToken)
  {
    var observedAtUtc = NormalizeInstant(requestPin.ObservedAtUtc);
    await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken)
        .ConfigureAwait(false);
    await using var transaction = await connection.BeginTransactionAsync(
        WriteIsolation,
        cancellationToken).ConfigureAwait(false);
    try
    {
      await AcquireContextOperationLockAsync(
          connection,
          transaction,
          operationUid,
          cancellationToken).ConfigureAwait(false);
      var session = await RequireActiveSessionAsync(
          connection,
          transaction,
          requestPin.SessionUid,
          observedAtUtc,
          forUpdate: true,
          cancellationToken).ConfigureAwait(false);
      var replay = await LoadWriteOperationAsync(
          connection,
          transaction,
          operationUid,
          cancellationToken).ConfigureAwait(false);
      if (replay is not null)
      {
        RequireReplay(replay, operationKind, requestSha256);
        var replayed = await RequireOperationContextAsync(
            connection,
            transaction,
            replay,
            session.AccountUid,
            cancellationToken).ConfigureAwait(false);
        if (replayed.Context.SessionUid != requestPin.SessionUid ||
            replayed.Context.ClientContextUid != requestPin.ClientContextUid)
        {
          throw Failure(
              App.PrivateServerFailureKind.Conflict,
              "operation_uid_context_conflict");
        }

        await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
        return Project(replayed.Context);
      }

      var current = await RequireCurrentContextAsync(
          connection,
          transaction,
          requestPin.SessionUid,
          requestPin.ClientContextUid,
          requestPin.ExpectedContextRevisionUid,
          observedAtUtc,
          forUpdate: true,
          cancellationToken).ConfigureAwait(false);
      var result = await mutate(
          connection,
          transaction,
          current,
          observedAtUtc,
          cancellationToken).ConfigureAwait(false);
      await InsertWriteOperationAsync(
          connection,
          transaction,
          operationUid,
          operationKind,
          requestSha256,
          current.AccountId,
          requestPin.ExpectedContextRevisionUid,
          result.ClientContextUid,
          result.ContextRevisionUid,
          result.ContentSha256,
          observedAtUtc,
          cancellationToken).ConfigureAwait(false);
      await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
      return Project(result);
    }
    catch (PostgresException exception)
    {
      throw MapDatabaseException(exception);
    }
    catch (NpgsqlException exception)
    {
      throw Failure(
          App.PrivateServerFailureKind.Unavailable,
          "private_server_store_unavailable",
          exception);
    }
    catch (PrivateServerDomain.PrivateServerIntegrityException exception)
    {
      throw Failure(
          App.PrivateServerFailureKind.Conflict,
          "private_server_context_integrity_conflict",
          exception);
    }
  }

  private static async Task AcquireContextOperationLockAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      EntityUid operationUid,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        "SELECT pg_advisory_xact_lock(hashtextextended(@operation_uid, @seed))",
        connection,
        transaction);
    Add(command, "operation_uid", NpgsqlDbType.Text, operationUid.ToString());
    Add(command, "seed", NpgsqlDbType.Bigint, PrivateServerContextOperationLockSeed);
    _ = await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false);
  }

  private static async Task<long> LockAccountIdAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      EntityUid accountUid,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        SELECT local_account_id
          FROM lab_profile.local_account
         WHERE local_account_uid = @account_uid
         FOR UPDATE
        """,
        connection,
        transaction);
    Add(command, "account_uid", NpgsqlDbType.Uuid, accountUid.Value);
    var value = await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false);
    if (value is null or DBNull)
    {
      throw Failure(App.PrivateServerFailureKind.NotFound, "private_server_account_not_found");
    }

    return Convert.ToInt64(value, CultureInfo.InvariantCulture);
  }

  private static async Task RequireNoActiveChallengeRunForSelectionChangeAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      long accountId,
      long contextId,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        SELECT challenge_run_id
          FROM lab_private_server.challenge_run
         WHERE (local_account_id = @account_id
                OR local_client_context_id = @context_id)
           AND status NOT IN ('completed', 'abandoned')
         ORDER BY challenge_run_id
         LIMIT 1
         FOR UPDATE
        """,
        connection,
        transaction);
    Add(command, "account_id", NpgsqlDbType.Bigint, accountId);
    Add(command, "context_id", NpgsqlDbType.Bigint, contextId);
    var activeRunId = await command.ExecuteScalarAsync(cancellationToken)
        .ConfigureAwait(false);
    if (activeRunId is not null and not DBNull)
    {
      throw Failure(
          App.PrivateServerFailureKind.Conflict,
          "active_challenge_run_blocks_season_selection");
    }
  }

  private static async Task<StoredSession> RequireActiveSessionAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction? transaction,
      EntityUid sessionUid,
      DateTimeOffset observedAtUtc,
      bool forUpdate,
      CancellationToken cancellationToken)
  {
    RequireUid(sessionUid, "local_session_uid_invalid");
    var sql = forUpdate
        ? """
          SELECT session.local_session_id, session.local_account_id,
                 session.local_session_uid, account.local_account_uid,
                 session.issued_at_utc, session.expires_at_utc,
                 session.revoked_at_utc
            FROM lab_profile.local_session session
            JOIN lab_profile.local_account account
              ON account.local_account_id = session.local_account_id
           WHERE session.local_session_uid = @session_uid
           FOR UPDATE OF session
          """
        : """
          SELECT session.local_session_id, session.local_account_id,
                 session.local_session_uid, account.local_account_uid,
                 session.issued_at_utc, session.expires_at_utc,
                 session.revoked_at_utc
            FROM lab_profile.local_session session
            JOIN lab_profile.local_account account
              ON account.local_account_id = session.local_account_id
           WHERE session.local_session_uid = @session_uid
          """;
    await using var command = new NpgsqlCommand(sql, connection, transaction);
    Add(command, "session_uid", NpgsqlDbType.Uuid, sessionUid.Value);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken)
        .ConfigureAwait(false);
    if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      throw Failure(
          App.PrivateServerFailureKind.Forbidden,
          "private_server_local_session_not_found");
    }

    var stored = new StoredSession(
        reader.GetInt64(0),
        reader.GetInt64(1),
        Uid(reader.GetValue(2)),
        Uid(reader.GetValue(3)),
        Instant(reader.GetValue(4)),
        Instant(reader.GetValue(5)),
        reader.IsDBNull(6) ? null : Instant(reader.GetValue(6)));
    RequireActive(stored, observedAtUtc);
    return stored;
  }

  private static void RequireActive(StoredSession session, DateTimeOffset observedAtUtc)
  {
    var observed = NormalizeInstant(observedAtUtc);
    if (session.RevokedAtUtc.HasValue)
    {
      throw Failure(
          App.PrivateServerFailureKind.Forbidden,
          "private_server_local_session_revoked");
    }

    if (observed < session.IssuedAtUtc || observed >= session.ExpiresAtUtc)
    {
      throw Failure(
          App.PrivateServerFailureKind.Forbidden,
          "private_server_local_session_not_active");
    }
  }

  private static async Task<long> InsertLocalSessionAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      EntityUid sessionUid,
      long accountId,
      DateTimeOffset issuedAtUtc,
      DateTimeOffset expiresAtUtc,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        INSERT INTO lab_profile.local_session (
            local_session_uid, local_account_id, issued_at_utc, expires_at_utc
        ) VALUES (
            @session_uid, @account_id, @issued_at_utc, @expires_at_utc
        )
        RETURNING local_session_id
        """,
        connection,
        transaction);
    Add(command, "session_uid", NpgsqlDbType.Uuid, sessionUid.Value);
    Add(command, "account_id", NpgsqlDbType.Bigint, accountId);
    Add(command, "issued_at_utc", NpgsqlDbType.TimestampTz, issuedAtUtc);
    Add(command, "expires_at_utc", NpgsqlDbType.TimestampTz, expiresAtUtc);
    return Convert.ToInt64(
        await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false) ??
            throw new InvalidOperationException("local_session_insert_failed"),
        CultureInfo.InvariantCulture);
  }

  private static async Task<long> InsertContextAggregateAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      EntityUid contextUid,
      long sessionId,
      long accountId,
      DateTimeOffset createdAtUtc,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        INSERT INTO lab_private_server.local_client_context (
            local_client_context_uid, local_session_id, local_account_id, created_at_utc
        ) VALUES (
            @context_uid, @session_id, @account_id, @created_at_utc
        )
        RETURNING local_client_context_id
        """,
        connection,
        transaction);
    Add(command, "context_uid", NpgsqlDbType.Uuid, contextUid.Value);
    Add(command, "session_id", NpgsqlDbType.Bigint, sessionId);
    Add(command, "account_id", NpgsqlDbType.Bigint, accountId);
    Add(command, "created_at_utc", NpgsqlDbType.TimestampTz, createdAtUtc);
    return Convert.ToInt64(
        await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false) ??
            throw new InvalidOperationException("client_context_insert_failed"),
        CultureInfo.InvariantCulture);
  }

  private static async Task<long> InsertContextRevisionAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      long contextId,
      long sessionId,
      long accountId,
      StoredBoot boot,
      long? previousRevisionId,
      PrivateServerDomain.LocalClientContext context,
      StoredAccountPins? accountPins,
      long? selectedSeasonRevisionId,
      DateTimeOffset materializedAtUtc,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        INSERT INTO lab_private_server.local_client_context_revision (
            local_client_context_revision_uid, local_client_context_id,
            local_session_id, local_account_id, revision_number,
            previous_local_client_context_revision_id,
            private_server_boot_revision_id, private_server_boot_content_sha256,
            capability_manifest_id, capability_manifest_content_sha256,
            application_build_id, application_build_sha256, application_contract_id,
            issued_at_utc, expires_at_utc, stage, connected_at_utc,
            lobby_ready_at_utc, account_revision_set_sha256,
            account_state_revision_id, profile_template_revision_id,
            lobby_presentation_revision_id, wallet_revision_id,
            client_feature_manifest_id, client_feature_manifest_uid,
            client_feature_manifest_content_sha256,
            squad_revision_id, squad_revision_uid, squad_revision_content_sha256,
            selected_raid_season_revision_id, selected_season_content_sha256,
            closed_at_utc, content_sha256, materialized_at_utc
        ) VALUES (
            @revision_uid, @context_id, @session_id, @account_id, @revision_number,
            @previous_revision_id, @boot_id, @boot_sha256,
            @capability_id, @capability_sha256,
            @application_build_id, @application_build_sha256, @application_contract_id,
            @issued_at_utc, @expires_at_utc, @stage, @connected_at_utc,
            @lobby_ready_at_utc, @account_revision_set_sha256,
            @account_state_revision_id, @profile_template_revision_id,
            @lobby_presentation_revision_id, @wallet_revision_id,
            @feature_manifest_id, @feature_manifest_uid, @feature_manifest_sha256,
            @squad_revision_id, @squad_revision_uid, @squad_revision_sha256,
            @selected_revision_id, @selected_content_sha256,
            @closed_at_utc, @content_sha256, @materialized_at_utc
        )
        RETURNING local_client_context_revision_id
        """,
        connection,
        transaction);
    Add(command, "revision_uid", NpgsqlDbType.Uuid, context.ContextRevisionUid.Value);
    Add(command, "context_id", NpgsqlDbType.Bigint, contextId);
    Add(command, "session_id", NpgsqlDbType.Bigint, sessionId);
    Add(command, "account_id", NpgsqlDbType.Bigint, accountId);
    Add(command, "revision_number", NpgsqlDbType.Integer, checked((int)context.RevisionNumber));
    Add(command, "previous_revision_id", NpgsqlDbType.Bigint, previousRevisionId);
    Add(command, "boot_id", NpgsqlDbType.Bigint, boot.Id);
    Add(
        command,
        "boot_sha256",
        NpgsqlDbType.Bytea,
        boot.Projection.Revision.ContentSha256.ToByteArray());
    Add(command, "capability_id", NpgsqlDbType.Bigint, boot.CapabilityManifestId);
    Add(
        command,
        "capability_sha256",
        NpgsqlDbType.Bytea,
        context.CapabilityManifestSha256.ToByteArray());
    Add(command, "application_build_id", NpgsqlDbType.Bigint, boot.ApplicationBuildId);
    Add(
        command,
        "application_build_sha256",
        NpgsqlDbType.Bytea,
        context.ApplicationBuildSha256.ToByteArray());
    Add(command, "application_contract_id", NpgsqlDbType.Text, context.ApplicationContractId);
    Add(command, "issued_at_utc", NpgsqlDbType.TimestampTz, context.IssuedAtUtc);
    Add(command, "expires_at_utc", NpgsqlDbType.TimestampTz, context.ExpiresAtUtc);
    Add(
        command,
        "stage",
        NpgsqlDbType.Text,
        PrivateServerDomain.LocalClientContext.Code(context.Stage));
    Add(command, "connected_at_utc", NpgsqlDbType.TimestampTz, context.ConnectedAtUtc);
    Add(command, "lobby_ready_at_utc", NpgsqlDbType.TimestampTz, context.LobbyReadyAtUtc);
    Add(
        command,
        "account_revision_set_sha256",
        NpgsqlDbType.Bytea,
        context.AccountRevisionSetSha256?.ToByteArray());
    Add(
        command,
        "account_state_revision_id",
        NpgsqlDbType.Bigint,
        accountPins?.AccountStateRevisionId);
    Add(
        command,
        "profile_template_revision_id",
        NpgsqlDbType.Bigint,
        accountPins?.ProfileTemplateRevisionId);
    Add(
        command,
        "lobby_presentation_revision_id",
        NpgsqlDbType.Bigint,
        accountPins?.LobbyPresentationRevisionId);
    Add(command, "wallet_revision_id", NpgsqlDbType.Bigint, accountPins?.WalletRevisionId);
    Add(
        command,
        "feature_manifest_id",
        NpgsqlDbType.Bigint,
        accountPins?.ClientFeatureManifestId);
    Add(
        command,
        "feature_manifest_uid",
        NpgsqlDbType.Uuid,
        accountPins?.ClientFeatureManifestUid.Value);
    Add(
        command,
        "feature_manifest_sha256",
        NpgsqlDbType.Bytea,
        accountPins?.ClientFeatureManifestContentSha256.ToByteArray());
    Add(command, "squad_revision_id", NpgsqlDbType.Bigint, accountPins?.SquadRevisionId);
    Add(
        command,
        "squad_revision_uid",
        NpgsqlDbType.Uuid,
        accountPins?.SquadRevisionUid?.Value);
    Add(
        command,
        "squad_revision_sha256",
        NpgsqlDbType.Bytea,
        accountPins?.SquadRevisionContentSha256?.ToByteArray());
    Add(command, "selected_revision_id", NpgsqlDbType.Bigint, selectedSeasonRevisionId);
    Add(
        command,
        "selected_content_sha256",
        NpgsqlDbType.Bytea,
        context.SelectedSeasonContentSha256?.ToByteArray());
    Add(command, "closed_at_utc", NpgsqlDbType.TimestampTz, context.ClosedAtUtc);
    Add(command, "content_sha256", NpgsqlDbType.Bytea, context.ContentSha256.ToByteArray());
    Add(
        command,
        "materialized_at_utc",
        NpgsqlDbType.TimestampTz,
        NormalizeInstant(materializedAtUtc));
    return Convert.ToInt64(
        await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false) ??
            throw new InvalidOperationException("client_context_revision_insert_failed"),
        CultureInfo.InvariantCulture);
  }

  private static async Task AdvanceContextHeadAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      long contextId,
      long revisionId,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        UPDATE lab_private_server.local_client_context
           SET current_local_client_context_revision_id = @revision_id
         WHERE local_client_context_id = @context_id
        """,
        connection,
        transaction);
    Add(command, "revision_id", NpgsqlDbType.Bigint, revisionId);
    Add(command, "context_id", NpgsqlDbType.Bigint, contextId);
    if (await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false) != 1)
    {
      throw Failure(App.PrivateServerFailureKind.Conflict, "client_context_head_conflict");
    }
  }

  private static async Task<StoredContext> RequireCurrentContextAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction? transaction,
      EntityUid sessionUid,
      EntityUid contextUid,
      EntityUid expectedRevisionUid,
      DateTimeOffset observedAtUtc,
      bool forUpdate,
      CancellationToken cancellationToken)
  {
    RequireUid(sessionUid, "local_session_uid_invalid");
    RequireUid(contextUid, "client_context_uid_invalid");
    RequireUid(expectedRevisionUid, "context_revision_uid_invalid");
    var sql = ContextSelectSql(
        "WHERE session.local_session_uid = @session_uid " +
        "AND context.local_client_context_uid = @context_uid",
        forUpdate);
    await using var command = new NpgsqlCommand(sql, connection, transaction);
    Add(command, "session_uid", NpgsqlDbType.Uuid, sessionUid.Value);
    Add(command, "context_uid", NpgsqlDbType.Uuid, contextUid.Value);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken)
        .ConfigureAwait(false);
    if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      throw Failure(App.PrivateServerFailureKind.NotFound, "client_context_not_found");
    }

    var stored = ReadStoredContext(reader);
    if (stored.Context.ContextRevisionUid != expectedRevisionUid)
    {
      throw Failure(App.PrivateServerFailureKind.Conflict, "client_context_revision_conflict");
    }

    RequireActive(stored.Session, observedAtUtc);
    if (stored.Context.Stage == PrivateServerDomain.ClientContextStage.Closed ||
        observedAtUtc < stored.Context.IssuedAtUtc ||
        observedAtUtc >= stored.Context.ExpiresAtUtc)
    {
      throw Failure(
          App.PrivateServerFailureKind.Forbidden,
          "private_server_client_context_not_active");
    }

    return stored;
  }

  private static async Task<StoredContext?> LoadContextByRevisionUidAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction? transaction,
      EntityUid revisionUid,
      CancellationToken cancellationToken)
  {
    var sql = ContextSelectSql(
        "WHERE revision.local_client_context_revision_uid = @revision_uid",
        forUpdate: false,
        useCurrentRevision: false);
    await using var command = new NpgsqlCommand(sql, connection, transaction);
    Add(command, "revision_uid", NpgsqlDbType.Uuid, revisionUid.Value);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken)
        .ConfigureAwait(false);
    return await reader.ReadAsync(cancellationToken).ConfigureAwait(false)
        ? ReadStoredContext(reader)
        : null;
  }

  private static string ContextSelectSql(
      string predicate,
      bool forUpdate,
      bool useCurrentRevision = true) => $"""
      SELECT context.local_client_context_id,
             context.local_client_context_uid,
             context.local_session_id,
             context.local_account_id,
             revision.local_client_context_revision_id,
             revision.local_client_context_revision_uid,
             revision.revision_number,
             previous.local_client_context_revision_uid,
             revision.private_server_boot_revision_id,
             revision.capability_manifest_id,
             revision.application_build_id,
             revision.issued_at_utc,
             revision.expires_at_utc,
             revision.stage,
             revision.connected_at_utc,
             revision.lobby_ready_at_utc,
             revision.account_revision_set_sha256,
             revision.selected_raid_season_revision_id,
             selected.selected_raid_season_revision_uid,
             revision.selected_season_content_sha256,
             revision.closed_at_utc,
             revision.content_sha256,
             revision.materialized_at_utc,
             revision.account_state_revision_id,
             revision.profile_template_revision_id,
             revision.lobby_presentation_revision_id,
             revision.wallet_revision_id,
             revision.client_feature_manifest_id,
             revision.squad_revision_id,
             session.local_session_uid,
             account.local_account_uid,
             session.issued_at_utc,
             session.expires_at_utc,
             session.revoked_at_utc,
             application.application_build_uid,
             revision.application_build_sha256,
             revision.application_contract_id,
             capability.capability_manifest_uid,
             revision.capability_manifest_content_sha256
        FROM lab_private_server.local_client_context context
        JOIN lab_private_server.local_client_context_revision revision
          ON revision.local_client_context_revision_id =
             {(useCurrentRevision ? "context.current_local_client_context_revision_id" : "revision.local_client_context_revision_id")}
         AND revision.local_client_context_id = context.local_client_context_id
        JOIN lab_profile.local_session session
          ON session.local_session_id = context.local_session_id
        JOIN lab_profile.local_account account
          ON account.local_account_id = context.local_account_id
        JOIN lab_private_server.application_build application
          ON application.application_build_id = revision.application_build_id
        JOIN lab_private_server.capability_manifest capability
          ON capability.capability_manifest_id = revision.capability_manifest_id
        LEFT JOIN lab_private_server.local_client_context_revision previous
          ON previous.local_client_context_revision_id =
             revision.previous_local_client_context_revision_id
        LEFT JOIN lab_private_server.selected_raid_season_revision selected
          ON selected.selected_raid_season_revision_id =
             revision.selected_raid_season_revision_id
       {predicate}
       {(forUpdate ? "FOR UPDATE OF context, session" : string.Empty)}
      """;

  private static StoredContext ReadStoredContext(NpgsqlDataReader reader)
  {
    var session = new StoredSession(
        reader.GetInt64(2),
        reader.GetInt64(3),
        Uid(reader.GetValue(29)),
        Uid(reader.GetValue(30)),
        Instant(reader.GetValue(31)),
        Instant(reader.GetValue(32)),
        reader.IsDBNull(33) ? null : Instant(reader.GetValue(33)));
    var context = PrivateServerDomain.LocalClientContext.Restore(
        Uid(reader.GetValue(1)),
        Uid(reader.GetValue(5)),
        reader.GetInt32(6),
        NullableUid(reader.GetValue(7)),
        session.SessionUid,
        session.AccountUid,
        Uid(reader.GetValue(34)),
        Digest(reader.GetValue(35)),
        reader.GetString(36),
        Uid(reader.GetValue(37)),
        Digest(reader.GetValue(38)),
        Instant(reader.GetValue(11)),
        Instant(reader.GetValue(12)),
        ParseContextStage(reader.GetString(13)),
        reader.IsDBNull(14) ? null : Instant(reader.GetValue(14)),
        reader.IsDBNull(15) ? null : Instant(reader.GetValue(15)),
        NullableDigest(reader.GetValue(16)),
        NullableUid(reader.GetValue(18)),
        NullableDigest(reader.GetValue(19)),
        reader.IsDBNull(20) ? null : Instant(reader.GetValue(20)));
    if (context.ContentSha256 != Digest(reader.GetValue(21)) ||
        context.IssuedAtUtc != session.IssuedAtUtc ||
        context.ExpiresAtUtc != session.ExpiresAtUtc)
    {
      throw Failure(
          App.PrivateServerFailureKind.Unavailable,
          "client_context_persisted_content_invalid");
    }

    return new StoredContext(
        reader.GetInt64(0),
        reader.GetInt64(4),
        reader.GetInt64(2),
        reader.GetInt64(3),
        reader.GetInt64(8),
        reader.GetInt64(9),
        reader.GetInt64(10),
        reader.IsDBNull(23) ? null : reader.GetInt64(23),
        reader.IsDBNull(24) ? null : reader.GetInt64(24),
        reader.IsDBNull(25) ? null : reader.GetInt64(25),
        reader.IsDBNull(26) ? null : reader.GetInt64(26),
        reader.IsDBNull(27) ? null : reader.GetInt64(27),
        reader.IsDBNull(28) ? null : reader.GetInt64(28),
        reader.IsDBNull(17) ? null : reader.GetInt64(17),
        context,
        session);
  }

  private static PrivateServerDomain.ClientContextStage ParseContextStage(string value) =>
      value switch
      {
        "loading" => PrivateServerDomain.ClientContextStage.Loading,
        "local_connected" => PrivateServerDomain.ClientContextStage.LocalConnected,
        "lobby_ready" => PrivateServerDomain.ClientContextStage.LobbyReady,
        "closed" => PrivateServerDomain.ClientContextStage.Closed,
        _ => throw Failure(
            App.PrivateServerFailureKind.Unavailable,
            "client_context_stage_invalid")
      };

  private static async Task<StoredContext> RequireOperationContextAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      StoredWriteOperation operation,
      EntityUid expectedAccountUid,
      CancellationToken cancellationToken)
  {
    if (!operation.ResultRevisionUid.HasValue || !operation.LocalAccountId.HasValue)
    {
      throw Failure(
          App.PrivateServerFailureKind.Unavailable,
          "client_context_operation_result_invalid");
    }

    var context = await LoadContextByRevisionUidAsync(
        connection,
        transaction,
        operation.ResultRevisionUid.Value,
        cancellationToken).ConfigureAwait(false) ?? throw Failure(
            App.PrivateServerFailureKind.Unavailable,
            "client_context_operation_result_missing");
    if (context.Context.ClientContextUid != operation.ResultEntityUid ||
        context.Context.ContentSha256 != operation.ResultContentSha256 ||
        context.AccountId != operation.LocalAccountId.Value ||
        context.Context.AccountUid != expectedAccountUid)
    {
      throw Failure(
          App.PrivateServerFailureKind.Unavailable,
          "client_context_operation_result_mismatch");
    }

    return context;
  }

  private static App.ClientContextProjection Project(
      PrivateServerDomain.LocalClientContext context) => new(
      context.ClientContextUid,
      new App.RevisionProjection(
          context.ContextRevisionUid,
          context.RevisionNumber,
          context.ContentSha256),
      context.SessionUid,
      context.AccountUid,
      context.ApplicationBuildUid,
      context.ApplicationBuildSha256,
      context.ApplicationContractId,
      context.CapabilityManifestUid,
      context.CapabilityManifestSha256,
      context.IssuedAtUtc,
      context.ExpiresAtUtc,
      PrivateServerDomain.LocalClientContext.Code(context.Stage),
      context.SelectedSeasonRevisionUid,
      context.SelectedSeasonContentSha256);

  private static void RequireMutationPin(EntityUid operationUid, App.SessionRequestPin pin)
  {
    ArgumentNullException.ThrowIfNull(pin);
    RequireUid(operationUid, "operation_uid_invalid");
    RequireUid(pin.SessionUid, "local_session_uid_invalid");
    RequireUid(pin.ClientContextUid, "client_context_uid_invalid");
    RequireUid(pin.ExpectedContextRevisionUid, "context_revision_uid_invalid");
  }

  private static void RequireUid(EntityUid value, string code)
  {
    if (value.Value == Guid.Empty)
    {
      throw Failure(App.PrivateServerFailureKind.InvalidRequest, code);
    }
  }

  private static void RequireDigest(Sha256Digest value, string code)
  {
    if (value == default)
    {
      throw Failure(App.PrivateServerFailureKind.InvalidRequest, code);
    }
  }

  private static App.PrivateServerApplicationException Failure(
      App.PrivateServerFailureKind kind,
      string code,
      Exception innerException)
  {
    _ = innerException;
    return new App.PrivateServerApplicationException(kind, code);
  }

  private static Task<long> InsertSelectionAggregateAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      EntityUid selectionUid,
      long contextId,
      long sessionId,
      long accountId,
      DateTimeOffset createdAtUtc,
      CancellationToken cancellationToken) => InsertSelectionAggregateCoreAsync(
      connection,
      transaction,
      selectionUid,
      contextId,
      sessionId,
      accountId,
      createdAtUtc,
      cancellationToken);

  private static async Task<long> InsertSelectionAggregateCoreAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      EntityUid selectionUid,
      long contextId,
      long sessionId,
      long accountId,
      DateTimeOffset createdAtUtc,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        INSERT INTO lab_private_server.raid_season_selection (
            raid_season_selection_uid, local_client_context_id,
            local_session_id, local_account_id, created_at_utc
        ) VALUES (
            @selection_uid, @context_id, @session_id, @account_id, @created_at_utc
        )
        RETURNING raid_season_selection_id
        """,
        connection,
        transaction);
    Add(command, "selection_uid", NpgsqlDbType.Uuid, selectionUid.Value);
    Add(command, "context_id", NpgsqlDbType.Bigint, contextId);
    Add(command, "session_id", NpgsqlDbType.Bigint, sessionId);
    Add(command, "account_id", NpgsqlDbType.Bigint, accountId);
    Add(command, "created_at_utc", NpgsqlDbType.TimestampTz, createdAtUtc);
    return Convert.ToInt64(
        await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false) ??
            throw new InvalidOperationException("raid_selection_insert_failed"),
        CultureInfo.InvariantCulture);
  }

  private static Task<long> RequireRaidSnapshotIdAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction? transaction,
      long directoryId,
      EntityUid raidSnapshotUid,
      CancellationToken cancellationToken) => RequireRaidSnapshotIdCoreAsync(
      connection,
      transaction,
      directoryId,
      raidSnapshotUid,
      cancellationToken);

  private static async Task<long> RequireRaidSnapshotIdCoreAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction? transaction,
      long directoryId,
      EntityUid raidSnapshotUid,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        SELECT snapshot.raid_snapshot_id
          FROM lab_private_server.raid_season_directory_member member
          JOIN lab_raid.raid_snapshot snapshot
            ON snapshot.raid_snapshot_id = member.raid_snapshot_id
         WHERE member.raid_season_directory_id = @directory_id
           AND snapshot.raid_snapshot_uid = @snapshot_uid
        """,
        connection,
        transaction);
    Add(command, "directory_id", NpgsqlDbType.Bigint, directoryId);
    Add(command, "snapshot_uid", NpgsqlDbType.Uuid, raidSnapshotUid.Value);
    var value = await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false);
    if (value is null or DBNull)
    {
      throw Failure(App.PrivateServerFailureKind.NotFound, "raid_season_not_in_directory");
    }

    return Convert.ToInt64(value, CultureInfo.InvariantCulture);
  }

  private static Task<long> InsertSelectionRevisionAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      long selectionId,
      StoredContext context,
      long? previousRevisionId,
      long directoryId,
      long raidSnapshotId,
      PrivateServerDomain.SelectedRaidSeasonRevision selection,
      CancellationToken cancellationToken) => InsertSelectionRevisionCoreAsync(
      connection,
      transaction,
      selectionId,
      context,
      previousRevisionId,
      directoryId,
      raidSnapshotId,
      selection,
      cancellationToken);

  private static async Task<long> InsertSelectionRevisionCoreAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      long selectionId,
      StoredContext context,
      long? previousRevisionId,
      long directoryId,
      long raidSnapshotId,
      PrivateServerDomain.SelectedRaidSeasonRevision selection,
      CancellationToken cancellationToken)
  {
    if (selection.AccountUid != context.Context.AccountUid ||
        selection.SessionUid != context.Context.SessionUid ||
        selection.ClientContextUid != context.Context.ClientContextUid)
    {
      throw Failure(App.PrivateServerFailureKind.Conflict, "raid_selection_scope_conflict");
    }

    await using var command = new NpgsqlCommand(
        """
        INSERT INTO lab_private_server.selected_raid_season_revision (
            selected_raid_season_revision_uid, raid_season_selection_id,
            local_client_context_id, local_session_id, local_account_id,
            revision_number, previous_selected_raid_season_revision_id,
            raid_season_directory_id, directory_content_sha256,
            raid_snapshot_id, season_number, raid_snapshot_content_sha256,
            content_sha256, materialized_at_utc
        ) VALUES (
            @revision_uid, @selection_id, @context_id, @session_id, @account_id,
            @revision_number, @previous_revision_id,
            @directory_id, @directory_sha256,
            @snapshot_id, @season_number, @snapshot_sha256,
            @content_sha256, @materialized_at_utc
        )
        RETURNING selected_raid_season_revision_id
        """,
        connection,
        transaction);
    Add(command, "revision_uid", NpgsqlDbType.Uuid, selection.SelectionRevisionUid.Value);
    Add(command, "selection_id", NpgsqlDbType.Bigint, selectionId);
    Add(command, "context_id", NpgsqlDbType.Bigint, context.Id);
    Add(command, "session_id", NpgsqlDbType.Bigint, context.SessionId);
    Add(command, "account_id", NpgsqlDbType.Bigint, context.AccountId);
    Add(command, "revision_number", NpgsqlDbType.Integer, checked((int)selection.RevisionNumber));
    Add(command, "previous_revision_id", NpgsqlDbType.Bigint, previousRevisionId);
    Add(command, "directory_id", NpgsqlDbType.Bigint, directoryId);
    Add(
        command,
        "directory_sha256",
        NpgsqlDbType.Bytea,
        selection.DirectoryContentSha256.ToByteArray());
    Add(command, "snapshot_id", NpgsqlDbType.Bigint, raidSnapshotId);
    Add(command, "season_number", NpgsqlDbType.Integer, selection.Member.SeasonNumber);
    Add(
        command,
        "snapshot_sha256",
        NpgsqlDbType.Bytea,
        selection.Member.RaidSnapshotContentSha256.ToByteArray());
    Add(command, "content_sha256", NpgsqlDbType.Bytea, selection.ContentSha256.ToByteArray());
    Add(
        command,
        "materialized_at_utc",
        NpgsqlDbType.TimestampTz,
        selection.MaterializedAtUtc);
    return Convert.ToInt64(
        await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false) ??
            throw new InvalidOperationException("raid_selection_revision_insert_failed"),
        CultureInfo.InvariantCulture);
  }

  private static Task AdvanceSelectionHeadAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      long selectionId,
      long revisionId,
      CancellationToken cancellationToken) => AdvanceSelectionHeadCoreAsync(
      connection,
      transaction,
      selectionId,
      revisionId,
      cancellationToken);

  private static async Task AdvanceSelectionHeadCoreAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      long selectionId,
      long revisionId,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        UPDATE lab_private_server.raid_season_selection
           SET current_selected_raid_season_revision_id = @revision_id
         WHERE raid_season_selection_id = @selection_id
        """,
        connection,
        transaction);
    Add(command, "revision_id", NpgsqlDbType.Bigint, revisionId);
    Add(command, "selection_id", NpgsqlDbType.Bigint, selectionId);
    if (await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false) != 1)
    {
      throw Failure(App.PrivateServerFailureKind.Conflict, "raid_selection_head_conflict");
    }
  }

  private Task<ProfileApp.AccountBootstrapProjection> RequireAccountBootstrapAsync(
      EntityUid accountUid,
      CancellationToken cancellationToken) => RequireAccountBootstrapCoreAsync(
      accountUid,
      cancellationToken);

  private async Task<ProfileApp.AccountBootstrapProjection> RequireAccountBootstrapCoreAsync(
      EntityUid accountUid,
      CancellationToken cancellationToken)
  {
    try
    {
      return await _profiles.GetCurrentBootstrapAsync(accountUid, cancellationToken)
          .ConfigureAwait(false) ?? throw Failure(
              App.PrivateServerFailureKind.NotFound,
              "private_server_account_bootstrap_not_found");
    }
    catch (ProfileApp.ProfileManagementException exception)
    {
      throw exception.Kind switch
      {
        ProfileApp.ProfileManagementFailureKind.InvalidRequest => Failure(
            App.PrivateServerFailureKind.InvalidRequest,
            exception.Code),
        ProfileApp.ProfileManagementFailureKind.NotFound => Failure(
            App.PrivateServerFailureKind.NotFound,
            exception.Code),
        ProfileApp.ProfileManagementFailureKind.Conflict => Failure(
            App.PrivateServerFailureKind.Conflict,
            exception.Code),
        ProfileApp.ProfileManagementFailureKind.Unprocessable => Failure(
            App.PrivateServerFailureKind.Conflict,
            exception.Code),
        _ => Failure(App.PrivateServerFailureKind.Unavailable, exception.Code)
      };
    }
  }

  private static Task<StoredAccountPins> LockAndVerifyAccountPinsAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      ProfileApp.AccountBootstrapProjection bootstrap,
      CancellationToken cancellationToken) => LoadAndVerifyAccountPinsAsync(
      connection,
      transaction,
      bootstrap,
      expected: null,
      lockHeads: true,
      cancellationToken);

  private static async Task<StoredAccountPins> LoadAndVerifyAccountPinsAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction? transaction,
      ProfileApp.AccountBootstrapProjection? bootstrap,
      StoredContext? expected,
      bool lockHeads,
      CancellationToken cancellationToken)
  {
    var sql = lockHeads
        ? """
          SELECT account.local_account_id,
                 state.account_state_revision_id,
                 state.account_state_revision_uid,
                 profile.profile_template_revision_id,
                 profile.profile_template_revision_uid,
                 profile.content_sha256,
                 lobby.lobby_presentation_revision_id,
                 lobby.lobby_presentation_revision_uid,
                 wallet.wallet_revision_id,
                 wallet.wallet_revision_uid,
                 feature.client_feature_manifest_id,
                 feature.client_feature_manifest_uid,
                 feature.content_sha256,
                 squad.squad_revision_id,
                 squad.squad_revision_uid,
                 squad.content_sha256
            FROM lab_profile.local_account account
            JOIN lab_profile.account_state_revision state
              ON state.account_state_revision_id = account.current_account_state_revision_id
            JOIN lab_profile.profile_template_revision profile
              ON profile.profile_template_revision_id =
                 account.current_profile_template_revision_id
            JOIN lab_local_game.account_client_state client
              ON client.local_account_id = account.local_account_id
            JOIN lab_local_game.lobby_presentation_revision lobby
              ON lobby.lobby_presentation_revision_id =
                 client.current_lobby_presentation_revision_id
            JOIN lab_local_game.wallet_revision wallet
              ON wallet.wallet_revision_id = client.current_wallet_revision_id
            JOIN lab_local_game.client_feature_manifest feature
              ON feature.client_feature_manifest_id =
                 client.current_client_feature_manifest_id
            LEFT JOIN lab_profile.squad_revision squad
              ON squad.squad_revision_id = profile.squad_revision_id
             AND squad.local_account_id = account.local_account_id
           WHERE account.local_account_uid = @account_uid
           FOR UPDATE OF account, client
          """
        : """
          SELECT account.local_account_id,
                 state.account_state_revision_id,
                 state.account_state_revision_uid,
                 profile.profile_template_revision_id,
                 profile.profile_template_revision_uid,
                 profile.content_sha256,
                 lobby.lobby_presentation_revision_id,
                 lobby.lobby_presentation_revision_uid,
                 wallet.wallet_revision_id,
                 wallet.wallet_revision_uid,
                 feature.client_feature_manifest_id,
                 feature.client_feature_manifest_uid,
                 feature.content_sha256,
                 squad.squad_revision_id,
                 squad.squad_revision_uid,
                 squad.content_sha256
            FROM lab_profile.local_account account
            JOIN lab_profile.account_state_revision state
              ON state.account_state_revision_id = @account_state_revision_id
             AND state.local_account_id = account.local_account_id
            JOIN lab_profile.profile_template_revision profile
              ON profile.profile_template_revision_id = @profile_revision_id
             AND profile.local_account_id = account.local_account_id
            JOIN lab_local_game.lobby_presentation_revision lobby
              ON lobby.lobby_presentation_revision_id = @lobby_revision_id
             AND lobby.local_account_id = account.local_account_id
            JOIN lab_local_game.wallet_revision wallet
              ON wallet.wallet_revision_id = @wallet_revision_id
             AND wallet.local_account_id = account.local_account_id
            JOIN lab_local_game.client_feature_manifest feature
              ON feature.client_feature_manifest_id = @feature_manifest_id
            LEFT JOIN lab_profile.squad_revision squad
              ON squad.squad_revision_id = @squad_revision_id
             AND squad.local_account_id = account.local_account_id
            WHERE account.local_account_uid = @account_uid
              AND profile.squad_revision_id IS NOT DISTINCT FROM @squad_revision_id
          """;
    var accountUid = bootstrap?.AccountUid ?? expected?.Context.AccountUid ?? default;
    await using var command = new NpgsqlCommand(sql, connection, transaction);
    Add(command, "account_uid", NpgsqlDbType.Uuid, accountUid.Value);
    if (!lockHeads)
    {
      Add(
          command,
          "account_state_revision_id",
          NpgsqlDbType.Bigint,
          expected?.AccountStateRevisionId);
      Add(
          command,
          "profile_revision_id",
          NpgsqlDbType.Bigint,
          expected?.ProfileTemplateRevisionId);
      Add(
          command,
          "lobby_revision_id",
          NpgsqlDbType.Bigint,
          expected?.LobbyPresentationRevisionId);
      Add(
          command,
          "wallet_revision_id",
          NpgsqlDbType.Bigint,
          expected?.WalletRevisionId);
      Add(
          command,
          "feature_manifest_id",
          NpgsqlDbType.Bigint,
          expected?.ClientFeatureManifestId);
      Add(
          command,
          "squad_revision_id",
          NpgsqlDbType.Bigint,
          expected?.SquadRevisionId);
    }

    await using var reader = await command.ExecuteReaderAsync(cancellationToken)
        .ConfigureAwait(false);
    if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      throw Failure(App.PrivateServerFailureKind.Conflict, "account_revision_set_not_ready");
    }

    var pins = new StoredAccountPins(
        reader.GetInt64(0),
        reader.GetInt64(1),
        Uid(reader.GetValue(2)),
        reader.GetInt64(3),
        Uid(reader.GetValue(4)),
        Digest(reader.GetValue(5)),
        reader.GetInt64(6),
        Uid(reader.GetValue(7)),
        reader.GetInt64(8),
        Uid(reader.GetValue(9)),
        reader.GetInt64(10),
        Uid(reader.GetValue(11)),
        Digest(reader.GetValue(12)),
        reader.IsDBNull(13) ? null : reader.GetInt64(13),
        NullableUid(reader.GetValue(14)),
        NullableDigest(reader.GetValue(15)));
    if (bootstrap is not null &&
        (pins.AccountId <= 0 || bootstrap.Profile.AccountUid != bootstrap.AccountUid ||
         bootstrap.Lobby.AccountUid != bootstrap.AccountUid ||
         bootstrap.Wallet.AccountUid != bootstrap.AccountUid ||
         pins.ProfileTemplateRevisionUid != bootstrap.Profile.ProfileRevision.RevisionUid ||
         pins.ProfileTemplateContentSha256 != bootstrap.Profile.ProfileRevision.ContentSha256 ||
         pins.LobbyPresentationRevisionUid != bootstrap.Lobby.Revision.RevisionUid ||
         pins.WalletRevisionUid != bootstrap.Wallet.Revision.RevisionUid ||
         pins.ClientFeatureManifestUid != bootstrap.FeatureManifest.ManifestUid ||
         pins.ClientFeatureManifestContentSha256 != bootstrap.FeatureManifest.ContentSha256 ||
         pins.SquadRevisionUid != bootstrap.Squad?.SquadRevisionUid ||
         ComputeAccountRevisionSetSha256(bootstrap, pins) != bootstrap.RevisionSetSha256))
    {
      throw Failure(App.PrivateServerFailureKind.Conflict, "account_revision_set_conflict");
    }

    return pins;
  }

  private static Sha256Digest ComputeAccountRevisionSetSha256(
      ProfileApp.AccountBootstrapProjection bootstrap,
      StoredAccountPins pins)
  {
    var revisionUids = new List<EntityUid>
    {
      pins.ProfileTemplateRevisionUid,
      pins.AccountStateRevisionUid,
      pins.LobbyPresentationRevisionUid,
      pins.WalletRevisionUid,
      pins.ClientFeatureManifestUid
    };
    revisionUids.AddRange(bootstrap.Roster.Select(static item => item.BuildRevisionUid));
    if (pins.SquadRevisionUid.HasValue)
    {
      revisionUids.Add(pins.SquadRevisionUid.Value);
    }

    return LocalGameStateContractCanonicalizer.ComputeRevisionSetSha256(
        revisionUids.ToArray());
  }

  private Task<StoredSelection> RequireCurrentSelectionAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction? transaction,
      StoredContext context,
      CancellationToken cancellationToken) => LoadSelectionAsync(
      connection,
      transaction,
      context,
      requireCurrent: true,
      cancellationToken);

  private async Task<StoredSelection> LoadSelectionAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction? transaction,
      StoredContext context,
      bool requireCurrent,
      CancellationToken cancellationToken)
  {
    if (!context.SelectedSeasonRevisionId.HasValue ||
        !context.Context.SelectedSeasonRevisionUid.HasValue)
    {
      throw Failure(App.PrivateServerFailureKind.Conflict, "selected_raid_season_required");
    }

    var boot = await LoadBootByIdAsync(
        connection,
        transaction,
        context.BootId,
        cancellationToken).ConfigureAwait(false);
    var sql = requireCurrent
        ? """
          SELECT selection.raid_season_selection_id,
                 selection.raid_season_selection_uid,
                 revision.selected_raid_season_revision_id,
                 revision.selected_raid_season_revision_uid,
                 revision.revision_number,
                 previous.selected_raid_season_revision_uid,
                 revision.raid_season_directory_id,
                 revision.directory_content_sha256,
                 snapshot.raid_snapshot_uid,
                 revision.content_sha256,
                 revision.materialized_at_utc
            FROM lab_private_server.raid_season_selection selection
            JOIN lab_private_server.selected_raid_season_revision revision
              ON revision.selected_raid_season_revision_id =
                 selection.current_selected_raid_season_revision_id
            JOIN lab_raid.raid_snapshot snapshot
              ON snapshot.raid_snapshot_id = revision.raid_snapshot_id
            LEFT JOIN lab_private_server.selected_raid_season_revision previous
              ON previous.selected_raid_season_revision_id =
                 revision.previous_selected_raid_season_revision_id
           WHERE selection.local_client_context_id = @context_id
           FOR UPDATE OF selection
          """
        : """
          SELECT selection.raid_season_selection_id,
                 selection.raid_season_selection_uid,
                 revision.selected_raid_season_revision_id,
                 revision.selected_raid_season_revision_uid,
                 revision.revision_number,
                 previous.selected_raid_season_revision_uid,
                 revision.raid_season_directory_id,
                 revision.directory_content_sha256,
                 snapshot.raid_snapshot_uid,
                 revision.content_sha256,
                 revision.materialized_at_utc
            FROM lab_private_server.raid_season_selection selection
            JOIN lab_private_server.selected_raid_season_revision revision
              ON revision.raid_season_selection_id = selection.raid_season_selection_id
            JOIN lab_raid.raid_snapshot snapshot
              ON snapshot.raid_snapshot_id = revision.raid_snapshot_id
            LEFT JOIN lab_private_server.selected_raid_season_revision previous
              ON previous.selected_raid_season_revision_id =
                 revision.previous_selected_raid_season_revision_id
           WHERE selection.local_client_context_id = @context_id
             AND revision.selected_raid_season_revision_id = @revision_id
          """;
    await using var command = new NpgsqlCommand(sql, connection, transaction);
    Add(command, "context_id", NpgsqlDbType.Bigint, context.Id);
    if (!requireCurrent)
    {
      Add(
          command,
          "revision_id",
          NpgsqlDbType.Bigint,
          context.SelectedSeasonRevisionId.Value);
    }

    await using var reader = await command.ExecuteReaderAsync(cancellationToken)
        .ConfigureAwait(false);
    if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      throw Failure(App.PrivateServerFailureKind.NotFound, "selected_raid_season_not_found");
    }

    var selection = PrivateServerDomain.SelectedRaidSeasonRevision.Restore(
        Uid(reader.GetValue(1)),
        Uid(reader.GetValue(3)),
        reader.GetInt32(4),
        NullableUid(reader.GetValue(5)),
        context.Context.AccountUid,
        context.Context.SessionUid,
        context.Context.ClientContextUid,
        boot.Projection.Directory.Directory,
        Uid(reader.GetValue(8)),
        Instant(reader.GetValue(10)));
    if (reader.GetInt64(6) != boot.DirectoryId ||
        Digest(reader.GetValue(7)) != boot.Projection.Directory.Directory.ContentSha256 ||
        Digest(reader.GetValue(9)) != selection.ContentSha256 ||
        selection.SelectionRevisionUid != context.Context.SelectedSeasonRevisionUid)
    {
      throw Failure(
          App.PrivateServerFailureKind.Unavailable,
          "selected_raid_season_persisted_content_invalid");
    }

    var stored = new StoredSelection(reader.GetInt64(0), reader.GetInt64(2), selection);
    if (requireCurrent && stored.RevisionId != context.SelectedSeasonRevisionId.Value)
    {
      throw Failure(
          App.PrivateServerFailureKind.Conflict,
          "selected_raid_season_context_conflict");
    }

    return stored;
  }

  private Task<App.LobbyBootstrapProjection> BuildLobbyBootstrapAsync(
      App.ClientContextProjection context,
      CancellationToken cancellationToken) => BuildLobbyBootstrapCoreAsync(
      context,
      cancellationToken);

  private async Task<App.LobbyBootstrapProjection> BuildLobbyBootstrapCoreAsync(
      App.ClientContextProjection context,
      CancellationToken cancellationToken)
  {
    try
    {
      await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken)
          .ConfigureAwait(false);
      var stored = await LoadContextByRevisionUidAsync(
          connection,
          transaction: null,
          context.Revision.RevisionUid,
          cancellationToken).ConfigureAwait(false) ?? throw Failure(
              App.PrivateServerFailureKind.Unavailable,
              "client_context_operation_result_missing");
      if (stored.Context.ClientContextUid != context.ClientContextUid ||
          stored.Context.ContentSha256 != context.Revision.ContentSha256)
      {
        throw Failure(
            App.PrivateServerFailureKind.Unavailable,
            "client_context_operation_result_mismatch");
      }

      return await BuildLobbyBootstrapAsync(
          connection,
          transaction: null,
          stored,
          cancellationToken).ConfigureAwait(false);
    }
    catch (PostgresException exception)
    {
      throw MapDatabaseException(exception);
    }
    catch (NpgsqlException exception)
    {
      throw Failure(
          App.PrivateServerFailureKind.Unavailable,
          "private_server_store_unavailable",
          exception);
    }
    catch (PrivateServerDomain.PrivateServerIntegrityException exception)
    {
      throw Failure(
          App.PrivateServerFailureKind.Unavailable,
          "private_server_context_persisted_content_invalid",
          exception);
    }
  }

  private Task<App.LobbyBootstrapProjection> BuildLobbyBootstrapAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction? transaction,
      StoredContext context,
      CancellationToken cancellationToken) => BuildLobbyBootstrapCoreAsync(
      connection,
      transaction,
      context,
      cancellationToken);

  private async Task<App.LobbyBootstrapProjection> BuildLobbyBootstrapCoreAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction? transaction,
      StoredContext context,
      CancellationToken cancellationToken)
  {
    RequireLobbyReady(context);
    var pins = await RequireStoredAccountPinsAsync(
        connection,
        transaction,
        context,
        cancellationToken).ConfigureAwait(false);
    var bootstrap = await RequireHistoricalAccountBootstrapAsync(
        context,
        pins,
        cancellationToken).ConfigureAwait(false);

    var selection = await LoadSelectionAsync(
        connection,
        transaction,
        context,
        requireCurrent: false,
        cancellationToken).ConfigureAwait(false);
    var boot = await LoadBootByIdAsync(
        connection,
        transaction,
        context.BootId,
        cancellationToken).ConfigureAwait(false);
    return new App.LobbyBootstrapProjection(
        Project(context.Context),
        new App.PrivateServerAccountProjection(
            bootstrap.AccountUid,
            bootstrap.RevisionSetSha256,
            bootstrap.Profile,
            bootstrap.Lobby,
            bootstrap.Wallet,
            bootstrap.Roster,
            bootstrap.Squad,
            bootstrap.Inventory),
        boot.Projection.Directory,
        new App.SelectedRaidSeasonProjection(selection.Revision, Project(context.Context)),
        boot.Projection.FixedCapabilities,
        boot.Projection.OperationalPolicy,
        boot.Projection.CapabilityManifest);
  }

  private static void RequireLobbyReady(StoredContext context)
  {
    if (context.Context.Stage != PrivateServerDomain.ClientContextStage.LobbyReady)
    {
      throw Failure(App.PrivateServerFailureKind.Conflict, "client_context_lobby_not_ready");
    }
  }

  private static Task<StoredAccountPins> RequireStoredAccountPinsAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction? transaction,
      StoredContext context,
      CancellationToken cancellationToken)
  {
    if (!context.AccountStateRevisionId.HasValue ||
        !context.ProfileTemplateRevisionId.HasValue ||
        !context.LobbyPresentationRevisionId.HasValue ||
        !context.WalletRevisionId.HasValue ||
        !context.ClientFeatureManifestId.HasValue)
    {
      throw Failure(App.PrivateServerFailureKind.Conflict, "account_revision_set_not_bound");
    }

    return LoadAndVerifyAccountPinsAsync(
        connection,
        transaction,
        bootstrap: null,
        context,
        lockHeads: false,
        cancellationToken);
  }

  private Task<App.SelectedRaidSeasonProjection> LoadSelectedProjectionForContextAsync(
      App.ClientContextProjection context,
      CancellationToken cancellationToken) => LoadSelectedProjectionForContextCoreAsync(
      context,
      cancellationToken);

  private async Task<App.SelectedRaidSeasonProjection>
      LoadSelectedProjectionForContextCoreAsync(
          App.ClientContextProjection context,
          CancellationToken cancellationToken)
  {
    try
    {
      await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken)
          .ConfigureAwait(false);
      var stored = await LoadContextByRevisionUidAsync(
          connection,
          transaction: null,
          context.Revision.RevisionUid,
          cancellationToken).ConfigureAwait(false) ?? throw Failure(
              App.PrivateServerFailureKind.Unavailable,
              "client_context_operation_result_missing");
      if (stored.Context.ClientContextUid != context.ClientContextUid ||
          stored.Context.ContentSha256 != context.Revision.ContentSha256)
      {
        throw Failure(
            App.PrivateServerFailureKind.Unavailable,
            "client_context_operation_result_mismatch");
      }

      var selection = await LoadSelectionAsync(
          connection,
          transaction: null,
          stored,
          requireCurrent: false,
          cancellationToken).ConfigureAwait(false);
      return new App.SelectedRaidSeasonProjection(selection.Revision, context);
    }
    catch (PostgresException exception)
    {
      throw MapDatabaseException(exception);
    }
    catch (NpgsqlException exception)
    {
      throw Failure(
          App.PrivateServerFailureKind.Unavailable,
          "private_server_store_unavailable",
          exception);
    }
    catch (PrivateServerDomain.PrivateServerIntegrityException exception)
    {
      throw Failure(
          App.PrivateServerFailureKind.Unavailable,
          "private_server_context_persisted_content_invalid",
          exception);
    }
  }

  private static Task<App.ChallengeAdmissionPinProjection> LoadAdmissionPinsAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction? transaction,
      StoredContext context,
      CancellationToken cancellationToken) => LoadAdmissionPinsCoreAsync(
      connection,
      transaction,
      context,
      cancellationToken);

  private static async Task<App.ChallengeAdmissionPinProjection> LoadAdmissionPinsCoreAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction? transaction,
      StoredContext context,
      CancellationToken cancellationToken)
  {
    var pins = await RequireStoredAccountPinsAsync(
        connection,
        transaction,
        context,
        cancellationToken).ConfigureAwait(false);
    var runtime = await LoadCurrentRuntimeExecutionPinAsync(
        connection,
        transaction,
        context.AccountId,
        cancellationToken).ConfigureAwait(false);
    var control = await LoadCurrentCombatControlPinAsync(
        connection,
        transaction,
        context.AccountId,
        cancellationToken).ConfigureAwait(false);
    return new App.ChallengeAdmissionPinProjection(
        pins.ProfileTemplateRevisionUid,
        pins.ProfileTemplateContentSha256,
        pins.AccountStateRevisionUid,
        runtime,
        control);
  }

  private static Task<App.ChallengeDailyStateProjection?> LoadCurrentDailyStateProjectionAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction? transaction,
      StoredContext context,
      StoredBoot boot,
      StoredSelection selection,
      DateTimeOffset observedAtUtc,
      CancellationToken cancellationToken) => LoadCurrentDailyStateProjectionCoreAsync(
      connection,
      transaction,
      context,
      boot,
      selection,
      observedAtUtc,
      cancellationToken);

  private static async Task<App.ChallengeDailyStateProjection?>
      LoadCurrentDailyStateProjectionCoreAsync(
          NpgsqlConnection connection,
          NpgsqlTransaction? transaction,
          StoredContext context,
          StoredBoot boot,
          StoredSelection selection,
          DateTimeOffset observedAtUtc,
          CancellationToken cancellationToken)
  {
    var policy = boot.Projection.OperationalPolicy.Policy;
    if (!policy.IsAdmissionReady)
    {
      return null;
    }

    var raidDay = PrivateServerDomain.AsiaSeoulRaidDay.GetKey(observedAtUtc);
    var counterScope = policy.DailyCounterScope.RequireConfigured();
    var snapshotUid = counterScope == PrivateServerDomain.DailyCounterScope.PerSeason
        ? selection.Revision.Member.RaidSnapshotUid
        : (EntityUid?)null;
    await using var command = new NpgsqlCommand(
        """
        SELECT state.challenge_daily_state_uid,
               revision.challenge_daily_state_revision_uid,
               revision.revision_number,
               previous.challenge_daily_state_revision_uid,
               account.local_account_uid,
               policy.challenge_operational_policy_uid,
               state.policy_content_sha256,
               directory.raid_season_directory_uid,
               directory.content_sha256,
               state.raid_day_key,
               state.counter_scope,
               snapshot.raid_snapshot_uid,
               revision.consumed_entries,
               revision.content_sha256
          FROM lab_private_server.challenge_daily_state state
          JOIN lab_private_server.challenge_daily_state_revision revision
            ON revision.challenge_daily_state_revision_id =
               state.current_challenge_daily_state_revision_id
          JOIN lab_profile.local_account account
            ON account.local_account_id = state.local_account_id
          JOIN lab_private_server.challenge_operational_policy policy
            ON policy.challenge_operational_policy_id =
               state.challenge_operational_policy_id
          JOIN lab_private_server.raid_season_directory directory
            ON directory.raid_season_directory_id = state.raid_season_directory_id
          LEFT JOIN lab_raid.raid_snapshot snapshot
            ON snapshot.raid_snapshot_id = state.raid_snapshot_id
          LEFT JOIN lab_private_server.challenge_daily_state_revision previous
            ON previous.challenge_daily_state_revision_id =
               revision.previous_challenge_daily_state_revision_id
         WHERE state.local_account_id = @account_id
           AND state.challenge_operational_policy_id = @policy_id
           AND state.raid_season_directory_id = @directory_id
           AND state.raid_day_key = @raid_day
           AND state.counter_scope = @counter_scope
           AND (
                (@snapshot_uid IS NULL AND state.raid_snapshot_id IS NULL)
                OR snapshot.raid_snapshot_uid = @snapshot_uid
           )
        """,
        connection,
        transaction);
    Add(command, "account_id", NpgsqlDbType.Bigint, context.AccountId);
    Add(command, "policy_id", NpgsqlDbType.Bigint, boot.PolicyId);
    Add(command, "directory_id", NpgsqlDbType.Bigint, boot.DirectoryId);
    Add(command, "raid_day", NpgsqlDbType.Date, raidDay.Date);
    Add(
        command,
        "counter_scope",
        NpgsqlDbType.Text,
        PrivateServerDomain.ChallengeOperationalPolicy.Code(counterScope));
    Add(command, "snapshot_uid", NpgsqlDbType.Uuid, snapshotUid?.Value);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken)
        .ConfigureAwait(false);
    if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      return null;
    }

    var daily = PrivateServerDomain.ChallengeDailyStateRevision.Restore(
        Uid(reader.GetValue(0)),
        Uid(reader.GetValue(1)),
        reader.GetInt32(2),
        NullableUid(reader.GetValue(3)),
        Uid(reader.GetValue(4)),
        Uid(reader.GetValue(5)),
        Digest(reader.GetValue(6)),
        Uid(reader.GetValue(7)),
        Digest(reader.GetValue(8)),
        PrivateServerDomain.RaidDayKey.FromDate(Date(reader.GetValue(9))),
        ParseDailyCounterScope(reader.GetString(10)),
        NullableUid(reader.GetValue(11)),
        reader.GetInt32(12));
    if (daily.ContentSha256 != Digest(reader.GetValue(13)) ||
        daily.AccountUid != context.Context.AccountUid ||
        daily.PolicyUid != policy.PolicyUid ||
        daily.PolicyContentSha256 != policy.ContentSha256 ||
        daily.DirectoryUid != boot.Projection.Directory.Directory.DirectoryUid ||
        daily.DirectoryContentSha256 !=
            boot.Projection.Directory.Directory.ContentSha256)
    {
      throw Failure(
          App.PrivateServerFailureKind.Unavailable,
          "challenge_daily_state_persisted_content_invalid");
    }

    return new App.ChallengeDailyStateProjection(
        daily.DailyStateUid,
        new App.RevisionProjection(
            daily.DailyStateRevisionUid,
            daily.RevisionNumber,
            daily.ContentSha256),
        daily.RaidDayKey,
        PrivateServerDomain.ChallengeOperationalPolicy.Code(daily.CounterScope),
        daily.RaidSnapshotUid,
        daily.ConsumedEntries,
        policy.DailyEntryLimit.RequireConfigured());
  }

  private static PrivateServerDomain.DailyCounterScope ParseDailyCounterScope(
      string value) => value switch
      {
        "per_season" => PrivateServerDomain.DailyCounterScope.PerSeason,
        "shared_across_directory" =>
            PrivateServerDomain.DailyCounterScope.SharedAcrossDirectory,
        _ => throw Failure(
            App.PrivateServerFailureKind.Unavailable,
            "challenge_daily_counter_scope_invalid")
      };

}
