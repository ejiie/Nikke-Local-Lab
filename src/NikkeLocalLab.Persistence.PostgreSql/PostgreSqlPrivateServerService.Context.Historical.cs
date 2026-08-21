using System.Data;
using App = NikkeLocalLab.Application.PrivateServer;
using ProfileApp = NikkeLocalLab.Application.ProfileManagement;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;
using Npgsql;
using NpgsqlTypes;

namespace NikkeLocalLab.Persistence.PostgreSql;

internal sealed record HistoricalAccountBootstrapPin(
    EntityUid AccountUid,
    Sha256Digest AccountRevisionSetSha256,
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

internal interface IHistoricalAccountBootstrapReader
{
  Task<ProfileApp.AccountBootstrapProjection?> GetHistoricalBootstrapAsync(
      HistoricalAccountBootstrapPin pin,
      CancellationToken cancellationToken = default);
}

public sealed partial class PostgreSqlProfileManagementService :
    IHistoricalAccountBootstrapReader
{
  Task<ProfileApp.AccountBootstrapProjection?>
      IHistoricalAccountBootstrapReader.GetHistoricalBootstrapAsync(
          HistoricalAccountBootstrapPin pin,
          CancellationToken cancellationToken) => TranslateAsync(async () =>
  {
    ArgumentNullException.ThrowIfNull(pin);
    var profile = await _profileStore.GetAtRevisionAsync(
        pin.AccountUid,
        pin.ProfileTemplateRevisionId,
        cancellationToken).ConfigureAwait(false);
    if (profile is null)
    {
      return null;
    }

    if (profile.Revision.AccountUid != pin.AccountUid ||
        profile.Revision.AccountCombatStateRevisionUid != pin.AccountStateRevisionUid ||
        profile.Revision.ProfileTemplateRevisionUid != pin.ProfileTemplateRevisionUid ||
        profile.Revision.ProfileContentSha256 != pin.ProfileTemplateContentSha256 ||
        profile.Revision.SquadRevisionUid != pin.SquadRevisionUid ||
        profile.Revision.SquadContentSha256 != pin.SquadRevisionContentSha256)
    {
      throw new LocalAccountProfileIntegrityException(
          "historical_profile_bootstrap_pin_conflict");
    }

    var bootstrap = await _gameStateStore.GetAtRevisionSetAsync(
        pin,
        cancellationToken).ConfigureAwait(false);
    if (bootstrap is null)
    {
      return null;
    }

    if (bootstrap.ProfileTemplateRevisionUid !=
            profile.Revision.ProfileTemplateRevisionUid ||
        bootstrap.AccountStateRevisionUid !=
            profile.Revision.AccountCombatStateRevisionUid ||
        bootstrap.RevisionSetSha256 != pin.AccountRevisionSetSha256)
    {
      throw new LocalGameStateIntegrityException(
          "historical_bootstrap_revision_set_conflict");
    }

    return MapBootstrap(bootstrap, MapProfile(profile));
  });
}

public sealed partial class PostgreSqlLocalAccountProfileStore
{
  internal async Task<LocalCurrentAccountProfile?> GetAtRevisionAsync(
      EntityUid accountUid,
      long profileRevisionId,
      CancellationToken cancellationToken = default)
  {
    RequireUid(accountUid, "profile_account_uid_invalid");
    if (profileRevisionId <= 0)
    {
      throw new LocalAccountProfileIntegrityException(
          "historical_profile_revision_id_invalid");
    }

    await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken)
        .ConfigureAwait(false);
    await using var transaction = await connection.BeginTransactionAsync(
        IsolationLevel.RepeatableRead,
        cancellationToken).ConfigureAwait(false);
    await using (var command = new NpgsqlCommand(
        """
        SELECT profile.profile_template_revision_id
          FROM lab_profile.local_account account
          JOIN lab_profile.profile_template_revision profile
            ON profile.local_account_id = account.local_account_id
         WHERE account.local_account_uid = @account_uid
           AND profile.profile_template_revision_id = @profile_revision_id
        """,
        connection,
        transaction))
    {
      Add(command, "account_uid", NpgsqlDbType.Uuid, accountUid.Value);
      Add(command, "profile_revision_id", NpgsqlDbType.Bigint, profileRevisionId);
      var value = await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false);
      if (value is null or DBNull)
      {
        await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
        return null;
      }
    }

    var receipt = await ReadReceiptAsync(
        connection,
        transaction,
        operationUid: null,
        profileRevisionId,
        isReplay: false,
        cancellationToken).ConfigureAwait(false);
    var profile = await ReadProfileAsync(
        connection,
        transaction,
        profileRevisionId,
        cancellationToken).ConfigureAwait(false);
    VerifyAggregateProjection(receipt, profile);
    await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
    return new LocalCurrentAccountProfile(receipt, profile);
  }
}

public sealed partial class PostgreSqlLocalGameStateStore
{
  internal async Task<LocalClientBootstrapProjection?> GetAtRevisionSetAsync(
      HistoricalAccountBootstrapPin pin,
      CancellationToken cancellationToken = default)
  {
    ArgumentNullException.ThrowIfNull(pin);
    await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken)
        .ConfigureAwait(false);
    await using var transaction = await connection.BeginTransactionAsync(
        IsolationLevel.RepeatableRead,
        cancellationToken).ConfigureAwait(false);
    var binding = await ReadHistoricalBootstrapBindingAsync(
        connection,
        transaction,
        pin,
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

    if (lobby.RevisionUid != pin.LobbyPresentationRevisionUid ||
        wallet.RevisionUid != pin.WalletRevisionUid ||
        feature.ManifestUid != pin.ClientFeatureManifestUid ||
        feature.ContentSha256 != pin.ClientFeatureManifestContentSha256 ||
        squad?.SquadRevisionUid != pin.SquadRevisionUid)
    {
      throw new LocalGameStateIntegrityException(
          "historical_bootstrap_component_pin_conflict");
    }

    var revisionUids = new List<EntityUid>
    {
      binding.ProfileRevisionUid,
      binding.AccountStateRevisionUid,
      lobby.RevisionUid,
      wallet.RevisionUid,
      feature.ManifestUid
    };
    revisionUids.AddRange(roster.Select(static item => item.BuildRevisionUid));
    if (squad is not null)
    {
      revisionUids.Add(squad.SquadRevisionUid);
    }

    var revisionSetSha256 =
        LocalGameStateContractCanonicalizer.ComputeRevisionSetSha256(
            revisionUids.ToArray());
    if (revisionSetSha256 != pin.AccountRevisionSetSha256)
    {
      throw new LocalGameStateIntegrityException(
          "historical_bootstrap_revision_set_conflict");
    }

    var result = new LocalClientBootstrapProjection(
        pin.AccountUid,
        binding.ProfileRevisionUid,
        binding.AccountStateRevisionUid,
        revisionSetSha256,
        lobby,
        wallet,
        feature,
        roster,
        squad,
        inventory);
    await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
    return result;
  }

  private static async Task<BootstrapBinding?> ReadHistoricalBootstrapBindingAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      HistoricalAccountBootstrapPin pin,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        SELECT account.local_account_id,
               profile.profile_template_revision_id,
               profile.profile_template_revision_uid,
               state.account_state_revision_uid,
               profile.squad_revision_id,
               @lobby_revision_id::bigint,
               @wallet_revision_id::bigint,
               @feature_manifest_id::bigint,
               profile.character_catalog_snapshot_id,
               squad.squad_revision_uid,
               squad.content_sha256
          FROM lab_profile.local_account account
          JOIN lab_profile.profile_template_revision profile
            ON profile.profile_template_revision_id = @profile_revision_id
           AND profile.local_account_id = account.local_account_id
          JOIN lab_profile.account_state_revision state
            ON state.account_state_revision_id = @account_state_revision_id
           AND state.local_account_id = account.local_account_id
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
           AND profile.account_state_revision_id = @account_state_revision_id
           AND profile.profile_template_revision_uid = @profile_revision_uid
           AND profile.content_sha256 = @profile_sha256
           AND state.account_state_revision_uid = @account_state_revision_uid
           AND lobby.lobby_presentation_revision_uid = @lobby_revision_uid
           AND wallet.wallet_revision_uid = @wallet_revision_uid
           AND feature.client_feature_manifest_uid = @feature_manifest_uid
           AND feature.content_sha256 = @feature_manifest_sha256
           AND profile.squad_revision_id IS NOT DISTINCT FROM @squad_revision_id
           AND squad.squad_revision_uid IS NOT DISTINCT FROM @squad_revision_uid
           AND squad.content_sha256 IS NOT DISTINCT FROM @squad_revision_sha256
        """,
        connection,
        transaction);
    Add(command, "account_uid", NpgsqlDbType.Uuid, pin.AccountUid.Value);
    Add(command, "account_state_revision_id", NpgsqlDbType.Bigint, pin.AccountStateRevisionId);
    Add(command, "account_state_revision_uid", NpgsqlDbType.Uuid, pin.AccountStateRevisionUid.Value);
    Add(command, "profile_revision_id", NpgsqlDbType.Bigint, pin.ProfileTemplateRevisionId);
    Add(command, "profile_revision_uid", NpgsqlDbType.Uuid, pin.ProfileTemplateRevisionUid.Value);
    Add(command, "profile_sha256", NpgsqlDbType.Bytea, pin.ProfileTemplateContentSha256.ToByteArray());
    Add(command, "lobby_revision_id", NpgsqlDbType.Bigint, pin.LobbyPresentationRevisionId);
    Add(command, "lobby_revision_uid", NpgsqlDbType.Uuid, pin.LobbyPresentationRevisionUid.Value);
    Add(command, "wallet_revision_id", NpgsqlDbType.Bigint, pin.WalletRevisionId);
    Add(command, "wallet_revision_uid", NpgsqlDbType.Uuid, pin.WalletRevisionUid.Value);
    Add(command, "feature_manifest_id", NpgsqlDbType.Bigint, pin.ClientFeatureManifestId);
    Add(command, "feature_manifest_uid", NpgsqlDbType.Uuid, pin.ClientFeatureManifestUid.Value);
    Add(
        command,
        "feature_manifest_sha256",
        NpgsqlDbType.Bytea,
        pin.ClientFeatureManifestContentSha256.ToByteArray());
    Add(command, "squad_revision_id", NpgsqlDbType.Bigint, pin.SquadRevisionId);
    Add(command, "squad_revision_uid", NpgsqlDbType.Uuid, pin.SquadRevisionUid?.Value);
    Add(
        command,
        "squad_revision_sha256",
        NpgsqlDbType.Bytea,
        pin.SquadRevisionContentSha256?.ToByteArray());
    await using var reader = await command.ExecuteReaderAsync(cancellationToken)
        .ConfigureAwait(false);
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
}

public sealed partial class PostgreSqlPrivateServerService
{
  private async Task<ProfileApp.AccountBootstrapProjection>
      RequireHistoricalAccountBootstrapAsync(
          StoredContext context,
          StoredAccountPins pins,
          CancellationToken cancellationToken)
  {
    if (_profiles is not IHistoricalAccountBootstrapReader historical)
    {
      throw Failure(
          App.PrivateServerFailureKind.Unavailable,
          "historical_account_bootstrap_reader_not_configured");
    }

    var revisionSetSha256 = context.Context.AccountRevisionSetSha256 ?? throw Failure(
        App.PrivateServerFailureKind.Conflict,
        "account_revision_set_not_bound");
    var pin = new HistoricalAccountBootstrapPin(
        context.Context.AccountUid,
        revisionSetSha256,
        pins.AccountStateRevisionId,
        pins.AccountStateRevisionUid,
        pins.ProfileTemplateRevisionId,
        pins.ProfileTemplateRevisionUid,
        pins.ProfileTemplateContentSha256,
        pins.LobbyPresentationRevisionId,
        pins.LobbyPresentationRevisionUid,
        pins.WalletRevisionId,
        pins.WalletRevisionUid,
        pins.ClientFeatureManifestId,
        pins.ClientFeatureManifestUid,
        pins.ClientFeatureManifestContentSha256,
        pins.SquadRevisionId,
        pins.SquadRevisionUid,
        pins.SquadRevisionContentSha256);
    try
    {
      return await historical.GetHistoricalBootstrapAsync(pin, cancellationToken)
          .ConfigureAwait(false) ?? throw Failure(
              App.PrivateServerFailureKind.NotFound,
              "historical_account_bootstrap_not_found");
    }
    catch (ProfileApp.ProfileManagementException exception)
    {
      throw exception.Kind switch
      {
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
}
