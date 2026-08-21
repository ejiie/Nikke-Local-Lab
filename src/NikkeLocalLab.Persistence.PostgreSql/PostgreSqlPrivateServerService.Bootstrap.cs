using System.Reflection;
using App = NikkeLocalLab.Application.PrivateServer;
using Game = global::NikkeLocalLab.Domain.LocalGameState;
using PrivateServerDomain = global::NikkeLocalLab.Domain.PrivateServer;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;
using Npgsql;
using NpgsqlTypes;

namespace NikkeLocalLab.Persistence.PostgreSql;

public sealed partial class PostgreSqlPrivateServerService
{
  private const string ApplicationContractId =
      "nll/private-server-application/postgresql/v1";

  private sealed record StoredFeatureManifest(
      long Id,
      EntityUid Uid,
      Game.ClientFeatureManifestContent Content,
      DateTimeOffset PublishedAtUtc);

  private sealed record StoredPolicy(
      long Id,
      PrivateServerDomain.ChallengeOperationalPolicy Policy,
      DateTimeOffset PublishedAtUtc);

  private sealed record StoredActivation(
      long Id,
      PrivateServerDomain.ChallengeOperationalPolicyActivationRevision Revision);

  private sealed record StoredDirectory(
      long Id,
      long CatalogSnapshotId,
      PrivateServerDomain.RaidSeasonDirectory Directory);

  private sealed record StoredCapabilityManifest(
      long Id,
      PrivateServerDomain.PrivateServerCapabilityManifest Manifest,
      DateTimeOffset PublishedAtUtc);

  private sealed record StoredApplicationSelection(
      long SelectionRevisionId,
      EntityUid SelectionRevisionUid,
      long RevisionNumber,
      long ApplicationBuildId,
      EntityUid ApplicationBuildUid,
      Sha256Digest ApplicationBuildSha256,
      string ApplicationContractId,
      Sha256Digest SelectionContentSha256);

  private sealed record StoredBoot(
      long Id,
      long ApplicationBuildId,
      long DirectoryId,
      long CapabilityManifestId,
      long PolicyId,
      long ActivationRevisionId,
      App.PrivateServerBootProjection Projection);

  internal Task InitializeAsync(CancellationToken cancellationToken) =>
      InitializeAsync(initialOperationalPolicy: null, cancellationToken);

  internal async Task InitializeAsync(
      PrivateServerDomain.ChallengeOperationalPolicy? initialOperationalPolicy,
      CancellationToken cancellationToken)
  {
    try
    {
      await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken)
          .ConfigureAwait(false);
      await using var transaction = await connection.BeginTransactionAsync(
          WriteIsolation,
          cancellationToken).ConfigureAwait(false);
      await TakeBootstrapLockAsync(connection, transaction, cancellationToken)
          .ConfigureAwait(false);

      var now = Now();
      var feature = await EnsureFeatureManifestV2Async(
          connection,
          transaction,
          now,
          cancellationToken).ConfigureAwait(false);
      var activation = await EnsureInitialPolicyActivationAsync(
          connection,
          transaction,
          initialOperationalPolicy,
          now,
          cancellationToken).ConfigureAwait(false);
      var policy = await LoadPolicyByUidAsync(
          connection,
          transaction,
          activation.Revision.PolicyUid,
          cancellationToken).ConfigureAwait(false) ??
          throw Failure(App.PrivateServerFailureKind.Unavailable, "challenge_policy_not_persisted");
      var application = await EnsureApplicationBuildAsync(
          connection,
          transaction,
          now,
          cancellationToken).ConfigureAwait(false);
      var directory = await EnsureSeasonDirectoryAsync(
          connection,
          transaction,
          now,
          cancellationToken).ConfigureAwait(false);
      var capability = await EnsureCapabilityManifestAsync(
          connection,
          transaction,
          feature,
          policy,
          now,
          cancellationToken).ConfigureAwait(false);
      _ = await EnsureBootRevisionAsync(
          connection,
          transaction,
          application,
          directory,
          capability,
          policy,
          activation,
          now,
          cancellationToken).ConfigureAwait(false);

      await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
    }
    catch (PostgresException exception)
    {
      throw MapDatabaseException(exception);
    }
    catch (NpgsqlException exception)
    {
      throw MapDatabaseException(exception);
    }
  }

  public async Task<App.PrivateServerBootProjection> GetBootAsync(
      App.BootQuery query,
      CancellationToken cancellationToken = default)
  {
    ArgumentNullException.ThrowIfNull(query);
    try
    {
      await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken)
          .ConfigureAwait(false);
      var stored = await LoadBootAsync(
          connection,
          transaction: null,
          NormalizeInstant(query.ObservedAtUtc),
          cancellationToken).ConfigureAwait(false);
      return stored.Projection;
    }
    catch (PostgresException exception)
    {
      throw MapDatabaseException(exception);
    }
    catch (NpgsqlException exception)
    {
      throw MapDatabaseException(exception);
    }
  }

  private static Game.ClientFeatureManifestContent Phase2BFeatureManifest() => new(
      "nll/client-feature-manifest/v2",
      new[]
      {
        new Game.ClientFeatureEntry("lobby.profile", Game.ClientFeatureCapability.Supported),
        new Game.ClientFeatureEntry("lobby.wallet", Game.ClientFeatureCapability.Supported),
        new Game.ClientFeatureEntry("lobby.nikke", Game.ClientFeatureCapability.Supported),
        new Game.ClientFeatureEntry("lobby.squad", Game.ClientFeatureCapability.Supported),
        new Game.ClientFeatureEntry("lobby.inventory", Game.ClientFeatureCapability.Supported),
        new Game.ClientFeatureEntry("lobby.recruit", Game.ClientFeatureCapability.VisibleNoOp),
        new Game.ClientFeatureEntry("lobby.messenger", Game.ClientFeatureCapability.Hidden),
        new Game.ClientFeatureEntry("lobby.tracing_the_stars", Game.ClientFeatureCapability.Hidden),
        new Game.ClientFeatureEntry("lobby.costume_pick", Game.ClientFeatureCapability.Hidden),
        new Game.ClientFeatureEntry("lobby.trail_marker", Game.ClientFeatureCapability.Hidden),
        new Game.ClientFeatureEntry("lobby.more", Game.ClientFeatureCapability.Hidden),
        new Game.ClientFeatureEntry("lobby.pickup_banner", Game.ClientFeatureCapability.Hidden),
        new Game.ClientFeatureEntry("lobby.right_side", Game.ClientFeatureCapability.Hidden),
        new Game.ClientFeatureEntry("lobby.shop", Game.ClientFeatureCapability.Hidden),
        new Game.ClientFeatureEntry("lobby.cash_shop", Game.ClientFeatureCapability.Hidden),
        new Game.ClientFeatureEntry("lobby.outpost", Game.ClientFeatureCapability.Hidden),
        new Game.ClientFeatureEntry("lobby.outpost_defense", Game.ClientFeatureCapability.Hidden),
        new Game.ClientFeatureEntry("lobby.solo_raid", Game.ClientFeatureCapability.Supported),
        new Game.ClientFeatureEntry("solo_raid.directory", Game.ClientFeatureCapability.Supported),
        new Game.ClientFeatureEntry("solo_raid.normal_battle", Game.ClientFeatureCapability.NotSupported),
        new Game.ClientFeatureEntry("solo_raid.quick_battle", Game.ClientFeatureCapability.NotSupported),
        new Game.ClientFeatureEntry("solo_raid.challenge", Game.ClientFeatureCapability.Supported)
      });

  private async Task<StoredFeatureManifest> EnsureFeatureManifestV2Async(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      DateTimeOffset publishedAtUtc,
      CancellationToken cancellationToken)
  {
    var expected = Phase2BFeatureManifest();
    var existing = await LoadFeatureManifestByContentAsync(
        connection,
        transaction,
        expected.ContentSha256,
        cancellationToken).ConfigureAwait(false);
    if (existing is not null)
    {
      return existing;
    }

    var manifestUid = _uidGenerator.NewUid();
    const string insertManifest = """
        INSERT INTO lab_local_game.client_feature_manifest (
            client_feature_manifest_uid, contract_version, entry_count,
            content_sha256, published_at_utc
        ) VALUES (
            @uid, @contract, @count, @content, @published
        )
        RETURNING client_feature_manifest_id
        """;
    long manifestId;
    await using (var command = new NpgsqlCommand(insertManifest, connection, transaction))
    {
      Add(command, "uid", NpgsqlDbType.Uuid, manifestUid.Value);
      Add(command, "contract", NpgsqlDbType.Text, expected.ContractVersion);
      Add(command, "count", NpgsqlDbType.Integer, expected.Entries.Count);
      Add(command, "content", NpgsqlDbType.Bytea, expected.ContentSha256.ToByteArray());
      Add(command, "published", NpgsqlDbType.TimestampTz, publishedAtUtc);
      manifestId = (long)(await command.ExecuteScalarAsync(cancellationToken)
          .ConfigureAwait(false) ?? throw new InvalidOperationException());
    }

    const string insertEntry = """
        INSERT INTO lab_local_game.client_feature_manifest_entry (
            client_feature_manifest_id, route_code, capability_code
        ) VALUES (@id, @route, @capability)
        """;
    foreach (var entry in expected.Entries)
    {
      await using var command = new NpgsqlCommand(insertEntry, connection, transaction);
      Add(command, "id", NpgsqlDbType.Bigint, manifestId);
      Add(command, "route", NpgsqlDbType.Text, entry.RouteCode);
      Add(command, "capability", NpgsqlDbType.Text, FeatureCapabilityCode(entry.Capability));
      _ = await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
    }

    var operationUid = _uidGenerator.NewUid();
    await InsertWriteOperationAsync(
        connection,
        transaction,
        operationUid,
        "publish_client_feature_manifest_v2",
        RequestHash("nll/private-server/publish-feature/v1", expected.ContentSha256),
        null,
        null,
        manifestUid,
        null,
        expected.ContentSha256,
        publishedAtUtc,
        cancellationToken).ConfigureAwait(false);
    return new StoredFeatureManifest(manifestId, manifestUid, expected, publishedAtUtc);
  }

  private static async Task<StoredFeatureManifest?> LoadFeatureManifestByContentAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction? transaction,
      Sha256Digest contentSha256,
      CancellationToken cancellationToken)
  {
    const string sql = """
        SELECT client_feature_manifest_id, client_feature_manifest_uid,
               contract_version, content_sha256, published_at_utc
          FROM lab_local_game.client_feature_manifest
         WHERE content_sha256 = @content
        """;
    long id;
    EntityUid uid;
    string contract;
    DateTimeOffset published;
    await using (var command = new NpgsqlCommand(sql, connection, transaction))
    {
      Add(command, "content", NpgsqlDbType.Bytea, contentSha256.ToByteArray());
      await using var reader = await command.ExecuteReaderAsync(cancellationToken)
          .ConfigureAwait(false);
      if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
      {
        return null;
      }

      id = reader.GetInt64(0);
      uid = Uid(reader.GetValue(1));
      contract = reader.GetString(2);
      if (Digest(reader.GetValue(3)) != contentSha256)
      {
        throw Failure(App.PrivateServerFailureKind.Unavailable, "feature_manifest_digest_invalid");
      }
      published = Instant(reader.GetValue(4));
    }

    var entries = new List<Game.ClientFeatureEntry>();
    const string entrySql = """
        SELECT route_code, capability_code
          FROM lab_local_game.client_feature_manifest_entry
         WHERE client_feature_manifest_id = @id
         ORDER BY route_code
        """;
    await using (var command = new NpgsqlCommand(entrySql, connection, transaction))
    {
      Add(command, "id", NpgsqlDbType.Bigint, id);
      await using var reader = await command.ExecuteReaderAsync(cancellationToken)
          .ConfigureAwait(false);
      while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
      {
        entries.Add(new Game.ClientFeatureEntry(
            reader.GetString(0),
            ParseFeatureCapability(reader.GetString(1))));
      }
    }

    var content = new Game.ClientFeatureManifestContent(contract, entries);
    if (content.ContentSha256 != contentSha256)
    {
      throw Failure(App.PrivateServerFailureKind.Unavailable, "feature_manifest_content_invalid");
    }
    return new StoredFeatureManifest(id, uid, content, published);
  }

  private static string FeatureCapabilityCode(Game.ClientFeatureCapability value) => value switch
  {
    Game.ClientFeatureCapability.Supported => "supported",
    Game.ClientFeatureCapability.Hidden => "hidden",
    Game.ClientFeatureCapability.VisibleNoOp => "visible_no_op",
    Game.ClientFeatureCapability.NotSupported => "not_supported",
    _ => throw new InvalidOperationException()
  };

  private static Game.ClientFeatureCapability ParseFeatureCapability(string value) => value switch
  {
    "supported" => Game.ClientFeatureCapability.Supported,
    "hidden" => Game.ClientFeatureCapability.Hidden,
    "visible_no_op" => Game.ClientFeatureCapability.VisibleNoOp,
    "not_supported" => Game.ClientFeatureCapability.NotSupported,
    _ => throw Failure(App.PrivateServerFailureKind.Unavailable, "feature_manifest_capability_invalid")
  };

  private async Task<StoredActivation> EnsureInitialPolicyActivationAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      PrivateServerDomain.ChallengeOperationalPolicy? initialOperationalPolicy,
      DateTimeOffset observedAtUtc,
      CancellationToken cancellationToken)
  {
    var head = await LoadLatestActivationAsync(
        connection,
        transaction,
        cancellationToken).ConfigureAwait(false);
    if (head is not null)
    {
      return head;
    }

    StoredPolicy policy;
    if (initialOperationalPolicy is not null)
    {
      policy = await LoadPolicyByUidAsync(
          connection,
          transaction,
          initialOperationalPolicy.PolicyUid,
          cancellationToken).ConfigureAwait(false) ??
          await InsertPolicyAsync(
              connection,
              transaction,
              initialOperationalPolicy,
              observedAtUtc,
              _uidGenerator.NewUid(),
              cancellationToken).ConfigureAwait(false);
      if (policy.Policy.ContentSha256 != initialOperationalPolicy.ContentSha256)
      {
        throw Failure(App.PrivateServerFailureKind.Conflict, "initial_challenge_policy_conflict");
      }
    }
    else
    {
      var policies = await LoadAllPoliciesAsync(connection, transaction, cancellationToken)
          .ConfigureAwait(false);
      if (policies.Count == 0)
      {
        var unresolved = PrivateServerDomain.ChallengeOperationalPolicy.CreateUnresolvedV1(
            _uidGenerator.NewUid());
        policy = await InsertPolicyAsync(
            connection,
            transaction,
            unresolved,
            observedAtUtc,
            _uidGenerator.NewUid(),
            cancellationToken).ConfigureAwait(false);
      }
      else if (policies.Count == 1)
      {
        policy = policies[0];
      }
      else
      {
        throw Failure(App.PrivateServerFailureKind.Unavailable, "initial_challenge_policy_ambiguous");
      }
    }

    var day = PrivateServerDomain.AsiaSeoulRaidDay.GetKey(observedAtUtc);
    var activation = PrivateServerDomain.ChallengeOperationalPolicyActivationRevision.CreateInitial(
        _uidGenerator.NewUid(),
        _uidGenerator.NewUid(),
        policy.Policy,
        day,
        observedAtUtc,
        day,
        currentDayConsumedEntries: 0,
        currentActiveRunCount: 0);
    var id = await InsertActivationRevisionAsync(
        connection,
        transaction,
        activation,
        policy.Id,
        previousId: null,
        cancellationToken).ConfigureAwait(false);
    const string insertState = """
        INSERT INTO lab_private_server.challenge_policy_state (
            singleton, latest_scheduled_activation_revision_id, updated_at_utc
        ) VALUES (TRUE, @id, @updated)
        """;
    await using (var command = new NpgsqlCommand(insertState, connection, transaction))
    {
      Add(command, "id", NpgsqlDbType.Bigint, id);
      Add(command, "updated", NpgsqlDbType.TimestampTz, observedAtUtc);
      _ = await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
    }
    return new StoredActivation(id, activation);
  }

  private async Task<StoredApplicationSelection> EnsureApplicationBuildAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      DateTimeOffset publishedAtUtc,
      CancellationToken cancellationToken)
  {
    var current = await LoadCurrentApplicationSelectionAsync(
        connection,
        transaction,
        cancellationToken).ConfigureAwait(false);
    var buildSha = await ComputeApplicationBuildSha256Async(cancellationToken)
        .ConfigureAwait(false);
    if (current is not null)
    {
      if (current.ApplicationBuildSha256 != buildSha ||
          !string.Equals(
              current.ApplicationContractId,
              ApplicationContractId,
              StringComparison.Ordinal))
      {
        throw Failure(App.PrivateServerFailureKind.Unavailable, "application_build_selection_mismatch");
      }
      return current;
    }

    var buildUid = _uidGenerator.NewUid();
    var buildContent = RequestHash(
        "nll/private-server-application-build/v1",
        ApplicationContractId,
        buildSha);
    const string insertBuild = """
        INSERT INTO lab_private_server.application_build (
            application_build_uid, application_contract_id,
            application_build_sha256, content_sha256, published_at_utc
        ) VALUES (@uid, @contract, @build_sha, @content, @published)
        RETURNING application_build_id
        """;
    long buildId;
    await using (var command = new NpgsqlCommand(insertBuild, connection, transaction))
    {
      Add(command, "uid", NpgsqlDbType.Uuid, buildUid.Value);
      Add(command, "contract", NpgsqlDbType.Text, ApplicationContractId);
      Add(command, "build_sha", NpgsqlDbType.Bytea, buildSha.ToByteArray());
      Add(command, "content", NpgsqlDbType.Bytea, buildContent.ToByteArray());
      Add(command, "published", NpgsqlDbType.TimestampTz, publishedAtUtc);
      buildId = (long)(await command.ExecuteScalarAsync(cancellationToken)
          .ConfigureAwait(false) ?? throw new InvalidOperationException());
    }

    var selectionRevisionUid = _uidGenerator.NewUid();
    var selectionContent = RequestHash(
        "nll/private-server-application-build-selection/v1",
        buildUid,
        buildSha,
        ApplicationContractId);
    const string insertSelection = """
        INSERT INTO lab_private_server.application_build_selection_revision (
            application_build_selection_revision_uid, revision_number,
            previous_application_build_selection_revision_id, application_build_id,
            application_build_sha256, content_sha256, selected_at_utc
        ) VALUES (@uid, 1, NULL, @build_id, @build_sha, @content, @selected)
        RETURNING application_build_selection_revision_id
        """;
    long selectionId;
    await using (var command = new NpgsqlCommand(insertSelection, connection, transaction))
    {
      Add(command, "uid", NpgsqlDbType.Uuid, selectionRevisionUid.Value);
      Add(command, "build_id", NpgsqlDbType.Bigint, buildId);
      Add(command, "build_sha", NpgsqlDbType.Bytea, buildSha.ToByteArray());
      Add(command, "content", NpgsqlDbType.Bytea, selectionContent.ToByteArray());
      Add(command, "selected", NpgsqlDbType.TimestampTz, publishedAtUtc);
      selectionId = (long)(await command.ExecuteScalarAsync(cancellationToken)
          .ConfigureAwait(false) ?? throw new InvalidOperationException());
    }

    const string insertState = """
        INSERT INTO lab_private_server.application_build_state (
            singleton, current_application_build_selection_revision_id, updated_at_utc
        ) VALUES (TRUE, @selection_id, @updated)
        """;
    await using (var command = new NpgsqlCommand(insertState, connection, transaction))
    {
      Add(command, "selection_id", NpgsqlDbType.Bigint, selectionId);
      Add(command, "updated", NpgsqlDbType.TimestampTz, publishedAtUtc);
      _ = await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
    }

    await InsertWriteOperationAsync(
        connection,
        transaction,
        _uidGenerator.NewUid(),
        "publish_application_build",
        RequestHash("nll/private-server/publish-application-build/v1", buildSha),
        null,
        null,
        buildUid,
        null,
        buildContent,
        publishedAtUtc,
        cancellationToken).ConfigureAwait(false);
    return new StoredApplicationSelection(
        selectionId,
        selectionRevisionUid,
        1,
        buildId,
        buildUid,
        buildSha,
        ApplicationContractId,
        selectionContent);
  }

  private static async Task<Sha256Digest> ComputeApplicationBuildSha256Async(
      CancellationToken cancellationToken)
  {
    var location = typeof(PostgreSqlPrivateServerService).Assembly.Location;
    if (string.IsNullOrEmpty(location))
    {
      throw Failure(App.PrivateServerFailureKind.Unavailable, "application_build_artifact_unavailable");
    }
    await using var stream = File.OpenRead(location);
    return await Sha256Digest.ComputeAsync(stream, cancellationToken).ConfigureAwait(false);
  }

  private static async Task<StoredApplicationSelection?> LoadCurrentApplicationSelectionAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction? transaction,
      CancellationToken cancellationToken)
  {
    const string sql = """
        SELECT s.application_build_selection_revision_id,
               s.application_build_selection_revision_uid, s.revision_number,
               b.application_build_id, b.application_build_uid,
               b.application_build_sha256, b.application_contract_id,
               s.content_sha256
          FROM lab_private_server.application_build_state state
          JOIN lab_private_server.application_build_selection_revision s
            ON s.application_build_selection_revision_id =
               state.current_application_build_selection_revision_id
          JOIN lab_private_server.application_build b
            ON b.application_build_id = s.application_build_id
         WHERE state.singleton
        """;
    await using var command = new NpgsqlCommand(sql, connection, transaction);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken)
        .ConfigureAwait(false);
    if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      return null;
    }
    return new StoredApplicationSelection(
        reader.GetInt64(0),
        Uid(reader.GetValue(1)),
        reader.GetInt64(2),
        reader.GetInt64(3),
        Uid(reader.GetValue(4)),
        Digest(reader.GetValue(5)),
        reader.GetString(6),
        Digest(reader.GetValue(7)));
  }

  private async Task<StoredDirectory> EnsureSeasonDirectoryAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      DateTimeOffset publishedAtUtc,
      CancellationToken cancellationToken)
  {
    var existing = await LoadDirectoryByContractAsync(
        connection,
        transaction,
        cancellationToken).ConfigureAwait(false);
    if (existing is not null)
    {
      return existing;
    }

    const string candidateSql = """
        SELECT c.raid_catalog_snapshot_id
          FROM lab_raid.raid_catalog_snapshot c
          JOIN lab_raid.raid_catalog_snapshot_member cm
            ON cm.raid_catalog_snapshot_id = c.raid_catalog_snapshot_id
          JOIN lab_raid.raid_snapshot r ON r.raid_snapshot_id = cm.raid_snapshot_id
         WHERE r.readiness_status = 'ready'
           AND r.admission_status = 'supported'
           AND r.admission_policy_id = 'challenge-boss-support/v1'
           AND r.mode = 'challenge'
           AND r.difficulty_type = 2
           AND r.wave_order = 8
         GROUP BY c.raid_catalog_snapshot_id, c.member_count
        HAVING c.member_count = 6
           AND count(*) = 6
           AND array_agg(r.season_number ORDER BY r.season_number) =
               ARRAY[7,13,26,29,34,40]::integer[]
        """;
    var candidates = new List<long>();
    await using (var command = new NpgsqlCommand(candidateSql, connection, transaction))
    await using (var reader = await command.ExecuteReaderAsync(cancellationToken)
        .ConfigureAwait(false))
    {
      while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
      {
        candidates.Add(reader.GetInt64(0));
      }
    }
    if (candidates.Count != 1)
    {
      throw Failure(
          App.PrivateServerFailureKind.Unavailable,
          candidates.Count == 0
              ? "raid_season_directory_source_not_found"
              : "raid_season_directory_source_ambiguous");
    }

    var members = await LoadPublishedSnapshotMembersAsync(
        connection,
        transaction,
        candidates[0],
        cancellationToken).ConfigureAwait(false);
    var directory = new PrivateServerDomain.RaidSeasonDirectory(
        _uidGenerator.NewUid(),
        publishedAtUtc,
        members);
    const string insertDirectory = """
        INSERT INTO lab_private_server.raid_season_directory (
            raid_season_directory_uid, contract_version, raid_catalog_snapshot_id,
            member_count, season_availability, season_ends_at_utc,
            normal_stages_implemented, normal_last_clear_level, challenge_unlocked,
            normal_combat_capability, quick_battle_capability,
            content_sha256, published_at_utc
        ) VALUES (
            @uid, @contract, @catalog_id, 6, 'permanent', NULL,
            FALSE, 7, TRUE, 'unsupported', 'unsupported', @content, @published
        ) RETURNING raid_season_directory_id
        """;
    long directoryId;
    await using (var command = new NpgsqlCommand(insertDirectory, connection, transaction))
    {
      Add(command, "uid", NpgsqlDbType.Uuid, directory.DirectoryUid.Value);
      Add(command, "contract", NpgsqlDbType.Text, PrivateServerDomain.RaidSeasonDirectory.ContractId);
      Add(command, "catalog_id", NpgsqlDbType.Bigint, candidates[0]);
      Add(command, "content", NpgsqlDbType.Bytea, directory.ContentSha256.ToByteArray());
      Add(command, "published", NpgsqlDbType.TimestampTz, publishedAtUtc);
      directoryId = (long)(await command.ExecuteScalarAsync(cancellationToken)
          .ConfigureAwait(false) ?? throw new InvalidOperationException());
    }

    const string memberLookup = """
        SELECT r.raid_snapshot_id
          FROM lab_raid.raid_snapshot r
         WHERE r.raid_snapshot_uid = @uid
        """;
    const string insertMember = """
        INSERT INTO lab_private_server.raid_season_directory_member (
            raid_season_directory_id, raid_catalog_snapshot_id, ordinal,
            season_number, raid_snapshot_id, raid_snapshot_content_sha256,
            presentation_status, presentation_uid,
            presentation_unresolved_reason_code
        ) VALUES (
            @directory_id, @catalog_id, @ordinal, @season, @snapshot_id,
            @content, 'unresolved', NULL, 'presentation_binding_unresolved'
        )
        """;
    for (var index = 0; index < directory.Members.Count; index++)
    {
      var member = directory.Members[index];
      long snapshotId;
      await using (var command = new NpgsqlCommand(memberLookup, connection, transaction))
      {
        Add(command, "uid", NpgsqlDbType.Uuid, member.RaidSnapshotUid.Value);
        snapshotId = (long)(await command.ExecuteScalarAsync(cancellationToken)
            .ConfigureAwait(false) ?? throw new InvalidOperationException());
      }
      await using (var command = new NpgsqlCommand(insertMember, connection, transaction))
      {
        Add(command, "directory_id", NpgsqlDbType.Bigint, directoryId);
        Add(command, "catalog_id", NpgsqlDbType.Bigint, candidates[0]);
        Add(command, "ordinal", NpgsqlDbType.Smallint, (short)(index + 1));
        Add(command, "season", NpgsqlDbType.Integer, member.SeasonNumber);
        Add(command, "snapshot_id", NpgsqlDbType.Bigint, snapshotId);
        Add(command, "content", NpgsqlDbType.Bytea, member.RaidSnapshotContentSha256.ToByteArray());
        _ = await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
      }
    }

    await InsertWriteOperationAsync(
        connection,
        transaction,
        _uidGenerator.NewUid(),
        "publish_season_directory",
        RequestHash("nll/private-server/publish-directory/v1", directory.ContentSha256),
        null,
        null,
        directory.DirectoryUid,
        null,
        directory.ContentSha256,
        publishedAtUtc,
        cancellationToken).ConfigureAwait(false);
    return new StoredDirectory(directoryId, candidates[0], directory);
  }

  private static async Task<IReadOnlyList<PrivateServerDomain.RaidSeasonDirectoryMember>>
      LoadPublishedSnapshotMembersAsync(
          NpgsqlConnection connection,
          NpgsqlTransaction? transaction,
          long catalogSnapshotId,
          CancellationToken cancellationToken)
  {
    const string sql = """
        SELECT r.season_number, r.raid_snapshot_uid, ds.dataset_snapshot_uid,
               ce.challenge_encounter_uid, bv.boss_variant_uid,
               r.content_sha256, r.compatibility_tier
          FROM lab_raid.raid_catalog_snapshot_member cm
          JOIN lab_raid.raid_snapshot r ON r.raid_snapshot_id = cm.raid_snapshot_id
          JOIN lab_import.dataset_snapshot ds ON ds.dataset_snapshot_id = r.dataset_snapshot_id
          JOIN lab_raid.challenge_encounter_entity ce
            ON ce.challenge_encounter_id = r.challenge_encounter_id
         JOIN lab_raid.boss_variant_entity bv ON bv.boss_variant_id = r.boss_variant_id
         WHERE cm.raid_catalog_snapshot_id = @catalog_id
           AND r.readiness_status = 'ready'
           AND r.admission_status = 'supported'
           AND r.admission_policy_id = 'challenge-boss-support/v1'
           AND r.mode = 'challenge'
           AND r.difficulty_type = 2
           AND r.wave_order = 8
         ORDER BY r.season_number
        """;
    var result = new List<PrivateServerDomain.RaidSeasonDirectoryMember>();
    await using var command = new NpgsqlCommand(sql, connection, transaction);
    Add(command, "catalog_id", NpgsqlDbType.Bigint, catalogSnapshotId);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken)
        .ConfigureAwait(false);
    while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      result.Add(new PrivateServerDomain.RaidSeasonDirectoryMember(
          reader.GetInt32(0),
          Uid(reader.GetValue(1)),
          Uid(reader.GetValue(2)),
          Uid(reader.GetValue(3)),
          Uid(reader.GetValue(4)),
          Digest(reader.GetValue(5)),
          reader.GetString(6),
          PrivateServerDomain.SeasonPresentationBinding.Unresolved()));
    }
    return result;
  }

  private static async Task<StoredDirectory?> LoadDirectoryByContractAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction? transaction,
      CancellationToken cancellationToken)
  {
    const string sql = """
        SELECT raid_season_directory_id, raid_season_directory_uid,
               raid_catalog_snapshot_id, content_sha256, published_at_utc
          FROM lab_private_server.raid_season_directory
         WHERE contract_version = 'nll/raid-season-directory/v1'
        """;
    long id;
    EntityUid uid;
    long catalogId;
    Sha256Digest digest;
    DateTimeOffset published;
    await using (var command = new NpgsqlCommand(sql, connection, transaction))
    await using (var reader = await command.ExecuteReaderAsync(cancellationToken)
        .ConfigureAwait(false))
    {
      if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
      {
        return null;
      }
      id = reader.GetInt64(0);
      uid = Uid(reader.GetValue(1));
      catalogId = reader.GetInt64(2);
      digest = Digest(reader.GetValue(3));
      published = Instant(reader.GetValue(4));
    }
    var members = await LoadPublishedSnapshotMembersAsync(
        connection,
        transaction,
        catalogId,
        cancellationToken).ConfigureAwait(false);
    var directory = new PrivateServerDomain.RaidSeasonDirectory(uid, published, members);
    if (directory.ContentSha256 != digest)
    {
      throw Failure(App.PrivateServerFailureKind.Unavailable, "raid_season_directory_content_invalid");
    }
    return new StoredDirectory(id, catalogId, directory);
  }

  private async Task<StoredCapabilityManifest> EnsureCapabilityManifestAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      StoredFeatureManifest feature,
      StoredPolicy policy,
      DateTimeOffset publishedAtUtc,
      CancellationToken cancellationToken)
  {
    var existing = await LoadCapabilityManifestAsync(
        connection,
        transaction,
        policy,
        feature,
        cancellationToken).ConfigureAwait(false);
    if (existing is not null)
    {
      return existing;
    }

    var manifest = PrivateServerDomain.PrivateServerCapabilityManifest.CreatePhase2B(
        _uidGenerator.NewUid(),
        feature.Uid,
        feature.Content,
        policy.Policy);
    const string insert = """
        INSERT INTO lab_private_server.capability_manifest (
            capability_manifest_uid, contract_version, client_feature_manifest_id,
            client_feature_manifest_content_sha256,
            client_feature_manifest_contract_version,
            challenge_operational_policy_id, policy_content_sha256,
            entry_count, content_sha256, published_at_utc
        ) VALUES (
            @uid, @contract, @feature_id, @feature_sha, @feature_contract,
            @policy_id, @policy_sha, 12, @content, @published
        ) RETURNING capability_manifest_id
        """;
    long id;
    await using (var command = new NpgsqlCommand(insert, connection, transaction))
    {
      Add(command, "uid", NpgsqlDbType.Uuid, manifest.ManifestUid.Value);
      Add(command, "contract", NpgsqlDbType.Text, PrivateServerDomain.PrivateServerCapabilityManifest.ContractId);
      Add(command, "feature_id", NpgsqlDbType.Bigint, feature.Id);
      Add(command, "feature_sha", NpgsqlDbType.Bytea, feature.Content.ContentSha256.ToByteArray());
      Add(command, "feature_contract", NpgsqlDbType.Text, feature.Content.ContractVersion);
      Add(command, "policy_id", NpgsqlDbType.Bigint, policy.Id);
      Add(command, "policy_sha", NpgsqlDbType.Bytea, policy.Policy.ContentSha256.ToByteArray());
      Add(command, "content", NpgsqlDbType.Bytea, manifest.ContentSha256.ToByteArray());
      Add(command, "published", NpgsqlDbType.TimestampTz, publishedAtUtc);
      id = (long)(await command.ExecuteScalarAsync(cancellationToken)
          .ConfigureAwait(false) ?? throw new InvalidOperationException());
    }
    const string insertEntry = """
        INSERT INTO lab_private_server.capability_manifest_entry (
            capability_manifest_id, capability_code, status_code, reason_code
        ) VALUES (@id, @code, @status, @reason)
        """;
    foreach (var entry in manifest.Entries)
    {
      await using var command = new NpgsqlCommand(insertEntry, connection, transaction);
      Add(command, "id", NpgsqlDbType.Bigint, id);
      Add(command, "code", NpgsqlDbType.Text, entry.CapabilityCode);
      Add(command, "status", NpgsqlDbType.Text, PrivateServerDomain.PrivateServerCapabilityManifest.Code(entry.Status));
      Add(command, "reason", NpgsqlDbType.Text, entry.ReasonCode);
      _ = await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
    }
    await InsertWriteOperationAsync(
        connection,
        transaction,
        _uidGenerator.NewUid(),
        "publish_capability_manifest",
        RequestHash("nll/private-server/publish-capability/v1", manifest.ContentSha256),
        null,
        null,
        manifest.ManifestUid,
        null,
        manifest.ContentSha256,
        publishedAtUtc,
        cancellationToken).ConfigureAwait(false);
    return new StoredCapabilityManifest(id, manifest, publishedAtUtc);
  }

  private static async Task<StoredCapabilityManifest?> LoadCapabilityManifestAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction? transaction,
      StoredPolicy policy,
      StoredFeatureManifest feature,
      CancellationToken cancellationToken)
  {
    const string sql = """
        SELECT capability_manifest_id, capability_manifest_uid,
               content_sha256, published_at_utc
          FROM lab_private_server.capability_manifest
         WHERE challenge_operational_policy_id = @policy_id
           AND client_feature_manifest_id = @feature_id
        """;
    await using var command = new NpgsqlCommand(sql, connection, transaction);
    Add(command, "policy_id", NpgsqlDbType.Bigint, policy.Id);
    Add(command, "feature_id", NpgsqlDbType.Bigint, feature.Id);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken)
        .ConfigureAwait(false);
    if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      return null;
    }
    var manifest = PrivateServerDomain.PrivateServerCapabilityManifest.CreatePhase2B(
        Uid(reader.GetValue(1)),
        feature.Uid,
        feature.Content,
        policy.Policy);
    if (manifest.ContentSha256 != Digest(reader.GetValue(2)))
    {
      throw Failure(App.PrivateServerFailureKind.Unavailable, "capability_manifest_content_invalid");
    }
    return new StoredCapabilityManifest(
        reader.GetInt64(0),
        manifest,
        Instant(reader.GetValue(3)));
  }

  private async Task<StoredBoot> EnsureBootRevisionAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      StoredApplicationSelection application,
      StoredDirectory directory,
      StoredCapabilityManifest capability,
      StoredPolicy policy,
      StoredActivation activation,
      DateTimeOffset materializedAtUtc,
      CancellationToken cancellationToken)
  {
    var existing = await LoadBootByActivationAsync(
        connection,
        transaction,
        activation.Id,
        cancellationToken).ConfigureAwait(false);
    if (existing is not null)
    {
      return existing;
    }

    long? previousId = null;
    long revisionNumber = 1;
    const string headSql = """
        SELECT b.private_server_boot_revision_id,
               b.private_server_boot_revision_uid, b.revision_number
          FROM lab_private_server.private_server_boot_state state
          JOIN lab_private_server.private_server_boot_revision b
            ON b.private_server_boot_revision_id = state.latest_scheduled_boot_revision_id
         WHERE state.singleton
         FOR UPDATE OF state
        """;
    await using (var command = new NpgsqlCommand(headSql, connection, transaction))
    await using (var reader = await command.ExecuteReaderAsync(cancellationToken)
        .ConfigureAwait(false))
    {
      if (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
      {
        previousId = reader.GetInt64(0);
        revisionNumber = reader.GetInt64(2) + 1;
      }
    }

    var revisionUid = _uidGenerator.NewUid();
    var content = RequestHash(
        "nll/private-server-boot/v1",
        activation.Revision.EffectiveRaidDayKey,
        application.ApplicationBuildUid,
        application.ApplicationBuildSha256,
        application.ApplicationContractId,
        directory.Directory.DirectoryUid,
        directory.Directory.ContentSha256,
        capability.Manifest.ManifestUid,
        capability.Manifest.ContentSha256,
        activation.Revision.ActivationRevisionUid,
        policy.Policy.PolicyUid,
        policy.Policy.ContentSha256);
    const string insert = """
        INSERT INTO lab_private_server.private_server_boot_revision (
            private_server_boot_revision_uid, revision_number,
            previous_private_server_boot_revision_id, effective_raid_day_key,
            application_build_selection_revision_id, application_build_id,
            application_build_sha256, application_contract_id,
            raid_season_directory_id, directory_content_sha256,
            capability_manifest_id, capability_manifest_content_sha256,
            challenge_policy_activation_revision_id,
            challenge_operational_policy_id, content_sha256, materialized_at_utc
        ) VALUES (
            @uid, @number, @previous, @day,
            @application_selection_id, @application_id, @application_sha, @application_contract,
            @directory_id, @directory_sha, @capability_id, @capability_sha,
            @activation_id, @policy_id, @content, @materialized
        ) RETURNING private_server_boot_revision_id
        """;
    long id;
    await using (var command = new NpgsqlCommand(insert, connection, transaction))
    {
      Add(command, "uid", NpgsqlDbType.Uuid, revisionUid.Value);
      Add(command, "number", NpgsqlDbType.Integer, checked((int)revisionNumber));
      Add(command, "previous", NpgsqlDbType.Bigint, previousId);
      Add(command, "day", NpgsqlDbType.Date, activation.Revision.EffectiveRaidDayKey.Date);
      Add(command, "application_selection_id", NpgsqlDbType.Bigint, application.SelectionRevisionId);
      Add(command, "application_id", NpgsqlDbType.Bigint, application.ApplicationBuildId);
      Add(command, "application_sha", NpgsqlDbType.Bytea, application.ApplicationBuildSha256.ToByteArray());
      Add(command, "application_contract", NpgsqlDbType.Text, application.ApplicationContractId);
      Add(command, "directory_id", NpgsqlDbType.Bigint, directory.Id);
      Add(command, "directory_sha", NpgsqlDbType.Bytea, directory.Directory.ContentSha256.ToByteArray());
      Add(command, "capability_id", NpgsqlDbType.Bigint, capability.Id);
      Add(command, "capability_sha", NpgsqlDbType.Bytea, capability.Manifest.ContentSha256.ToByteArray());
      Add(command, "activation_id", NpgsqlDbType.Bigint, activation.Id);
      Add(command, "policy_id", NpgsqlDbType.Bigint, policy.Id);
      Add(command, "content", NpgsqlDbType.Bytea, content.ToByteArray());
      Add(command, "materialized", NpgsqlDbType.TimestampTz, materializedAtUtc);
      id = (long)(await command.ExecuteScalarAsync(cancellationToken)
          .ConfigureAwait(false) ?? throw new InvalidOperationException());
    }

    if (previousId.HasValue)
    {
      const string update = """
          UPDATE lab_private_server.private_server_boot_state
             SET latest_scheduled_boot_revision_id = @id, updated_at_utc = @updated
           WHERE singleton
          """;
      await using var command = new NpgsqlCommand(update, connection, transaction);
      Add(command, "id", NpgsqlDbType.Bigint, id);
      Add(command, "updated", NpgsqlDbType.TimestampTz, materializedAtUtc);
      _ = await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
    }
    else
    {
      const string insertState = """
          INSERT INTO lab_private_server.private_server_boot_state (
              singleton, latest_scheduled_boot_revision_id, updated_at_utc
          ) VALUES (TRUE, @id, @updated)
          """;
      await using var command = new NpgsqlCommand(insertState, connection, transaction);
      Add(command, "id", NpgsqlDbType.Bigint, id);
      Add(command, "updated", NpgsqlDbType.TimestampTz, materializedAtUtc);
      _ = await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
    }

    return BuildStoredBoot(
        id,
        revisionUid,
        revisionNumber,
        content,
        application,
        directory,
        capability,
        policy,
        activation);
  }

  private static StoredBoot BuildStoredBoot(
      long id,
      EntityUid revisionUid,
      long revisionNumber,
      Sha256Digest contentSha256,
      StoredApplicationSelection application,
      StoredDirectory directory,
      StoredCapabilityManifest capability,
      StoredPolicy policy,
      StoredActivation activation) => new(
      id,
      application.ApplicationBuildId,
      directory.Id,
      capability.Id,
      policy.Id,
      activation.Id,
      new App.PrivateServerBootProjection(
          new App.RevisionProjection(revisionUid, revisionNumber, contentSha256),
          application.ApplicationBuildUid,
          application.ApplicationBuildSha256,
          application.ApplicationContractId,
          new App.RaidSeasonDirectoryProjection(directory.Directory),
          PrivateServerDomain.SoloRaidFixedCapabilities.V1,
          new App.ChallengeOperationalPolicyProjection(
              policy.Policy,
              policy.PublishedAtUtc,
              true,
              activation.Revision.EffectiveRaidDayKey),
          new App.PrivateServerCapabilityManifestProjection(capability.Manifest)));

  private async Task<StoredBoot> LoadBootAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction? transaction,
      DateTimeOffset observedAtUtc,
      CancellationToken cancellationToken)
  {
    var day = PrivateServerDomain.AsiaSeoulRaidDay.GetKey(observedAtUtc);
    const string sql = """
        SELECT private_server_boot_revision_id
          FROM lab_private_server.private_server_boot_revision
         WHERE effective_raid_day_key <= @day
         ORDER BY revision_number DESC
         LIMIT 1
        """;
    await using var command = new NpgsqlCommand(sql, connection, transaction);
    Add(command, "day", NpgsqlDbType.Date, day.Date);
    var value = await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false) ??
        throw Failure(App.PrivateServerFailureKind.Unavailable, "private_server_boot_not_available");
    return await LoadBootByIdAsync(
        connection,
        transaction,
        (long)value,
        cancellationToken).ConfigureAwait(false);
  }

  private async Task<StoredBoot> LoadBootByIdAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction? transaction,
      long id,
      CancellationToken cancellationToken)
  {
    const string sql = """
        SELECT private_server_boot_revision_uid, revision_number, content_sha256,
               application_build_selection_revision_id, raid_season_directory_id,
               capability_manifest_id, challenge_operational_policy_id,
               challenge_policy_activation_revision_id
          FROM lab_private_server.private_server_boot_revision
         WHERE private_server_boot_revision_id = @id
        """;
    EntityUid revisionUid;
    long revisionNumber;
    Sha256Digest content;
    long applicationSelectionId;
    long directoryId;
    long capabilityId;
    long policyId;
    long activationId;
    await using (var command = new NpgsqlCommand(sql, connection, transaction))
    {
      Add(command, "id", NpgsqlDbType.Bigint, id);
      await using var reader = await command.ExecuteReaderAsync(cancellationToken)
          .ConfigureAwait(false);
      if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
      {
        throw Failure(App.PrivateServerFailureKind.Unavailable, "private_server_boot_not_available");
      }
      revisionUid = Uid(reader.GetValue(0));
      revisionNumber = reader.GetInt64(1);
      content = Digest(reader.GetValue(2));
      applicationSelectionId = reader.GetInt64(3);
      directoryId = reader.GetInt64(4);
      capabilityId = reader.GetInt64(5);
      policyId = reader.GetInt64(6);
      activationId = reader.GetInt64(7);
    }

    var application = await LoadApplicationSelectionByIdAsync(
        connection,
        transaction,
        applicationSelectionId,
        cancellationToken).ConfigureAwait(false);
    var directory = await LoadDirectoryByIdAsync(
        connection,
        transaction,
        directoryId,
        cancellationToken).ConfigureAwait(false);
    var policy = await LoadPolicyByIdAsync(
        connection,
        transaction,
        policyId,
        cancellationToken).ConfigureAwait(false);
    var feature = await LoadFeatureForCapabilityAsync(
        connection,
        transaction,
        capabilityId,
        cancellationToken).ConfigureAwait(false);
    var capability = await LoadCapabilityManifestByIdAsync(
        connection,
        transaction,
        capabilityId,
        policy,
        feature,
        cancellationToken).ConfigureAwait(false);
    var activation = await LoadActivationByIdAsync(
        connection,
        transaction,
        activationId,
        cancellationToken).ConfigureAwait(false);
    var expectedContent = RequestHash(
        "nll/private-server-boot/v1",
        activation.Revision.EffectiveRaidDayKey,
        application.ApplicationBuildUid,
        application.ApplicationBuildSha256,
        application.ApplicationContractId,
        directory.Directory.DirectoryUid,
        directory.Directory.ContentSha256,
        capability.Manifest.ManifestUid,
        capability.Manifest.ContentSha256,
        activation.Revision.ActivationRevisionUid,
        policy.Policy.PolicyUid,
        policy.Policy.ContentSha256);
    if (expectedContent != content)
    {
      throw Failure(App.PrivateServerFailureKind.Unavailable, "private_server_boot_content_invalid");
    }
    return BuildStoredBoot(
        id,
        revisionUid,
        revisionNumber,
        content,
        application,
        directory,
        capability,
        policy,
        activation);
  }

  private async Task<StoredBoot?> LoadBootByActivationAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      long activationId,
      CancellationToken cancellationToken)
  {
    const string sql = """
        SELECT private_server_boot_revision_id
          FROM lab_private_server.private_server_boot_revision
         WHERE challenge_policy_activation_revision_id = @activation_id
        """;
    long? bootId = null;
    await using (var command = new NpgsqlCommand(sql, connection, transaction))
    {
      Add(command, "activation_id", NpgsqlDbType.Bigint, activationId);
      var result = await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false);
      if (result is not null)
      {
        bootId = (long)result;
      }
    }
    return bootId.HasValue
        ? await LoadBootByIdAsync(connection, transaction, bootId.Value, cancellationToken)
            .ConfigureAwait(false)
        : null;
  }

  private static async Task<StoredApplicationSelection> LoadApplicationSelectionByIdAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction? transaction,
      long id,
      CancellationToken cancellationToken)
  {
    const string sql = """
        SELECT s.application_build_selection_revision_id,
               s.application_build_selection_revision_uid, s.revision_number,
               b.application_build_id, b.application_build_uid,
               b.application_build_sha256, b.application_contract_id,
               s.content_sha256
          FROM lab_private_server.application_build_selection_revision s
          JOIN lab_private_server.application_build b
            ON b.application_build_id = s.application_build_id
         WHERE s.application_build_selection_revision_id = @id
        """;
    await using var command = new NpgsqlCommand(sql, connection, transaction);
    Add(command, "id", NpgsqlDbType.Bigint, id);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken)
        .ConfigureAwait(false);
    if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      throw Failure(App.PrivateServerFailureKind.Unavailable, "application_build_selection_not_found");
    }
    return new StoredApplicationSelection(
        reader.GetInt64(0), Uid(reader.GetValue(1)), reader.GetInt64(2),
        reader.GetInt64(3), Uid(reader.GetValue(4)), Digest(reader.GetValue(5)),
        reader.GetString(6), Digest(reader.GetValue(7)));
  }

  private static async Task<StoredDirectory> LoadDirectoryByIdAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction? transaction,
      long id,
      CancellationToken cancellationToken)
  {
    const string sql = """
        SELECT raid_season_directory_uid, raid_catalog_snapshot_id,
               content_sha256, published_at_utc
          FROM lab_private_server.raid_season_directory
         WHERE raid_season_directory_id = @id
        """;
    EntityUid uid;
    long catalogId;
    Sha256Digest content;
    DateTimeOffset published;
    await using (var command = new NpgsqlCommand(sql, connection, transaction))
    {
      Add(command, "id", NpgsqlDbType.Bigint, id);
      await using var reader = await command.ExecuteReaderAsync(cancellationToken)
          .ConfigureAwait(false);
      if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
      {
        throw Failure(App.PrivateServerFailureKind.Unavailable, "raid_season_directory_not_found");
      }
      uid = Uid(reader.GetValue(0));
      catalogId = reader.GetInt64(1);
      content = Digest(reader.GetValue(2));
      published = Instant(reader.GetValue(3));
    }
    var members = await LoadPublishedSnapshotMembersAsync(
        connection,
        transaction,
        catalogId,
        cancellationToken).ConfigureAwait(false);
    var directory = new PrivateServerDomain.RaidSeasonDirectory(uid, published, members);
    if (directory.ContentSha256 != content)
    {
      throw Failure(App.PrivateServerFailureKind.Unavailable, "raid_season_directory_content_invalid");
    }
    return new StoredDirectory(id, catalogId, directory);
  }

  private static async Task<StoredFeatureManifest> LoadFeatureForCapabilityAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction? transaction,
      long capabilityId,
      CancellationToken cancellationToken)
  {
    const string sql = """
        SELECT client_feature_manifest_content_sha256
          FROM lab_private_server.capability_manifest
         WHERE capability_manifest_id = @id
        """;
    Sha256Digest digest;
    await using (var command = new NpgsqlCommand(sql, connection, transaction))
    {
      Add(command, "id", NpgsqlDbType.Bigint, capabilityId);
      digest = Digest(await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false) ??
          throw Failure(App.PrivateServerFailureKind.Unavailable, "capability_manifest_not_found"));
    }
    return await LoadFeatureManifestByContentAsync(
        connection,
        transaction,
        digest,
        cancellationToken).ConfigureAwait(false) ??
        throw Failure(App.PrivateServerFailureKind.Unavailable, "feature_manifest_not_found");
  }

  private static async Task<StoredCapabilityManifest> LoadCapabilityManifestByIdAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction? transaction,
      long id,
      StoredPolicy policy,
      StoredFeatureManifest feature,
      CancellationToken cancellationToken)
  {
    const string sql = """
        SELECT capability_manifest_uid, content_sha256, published_at_utc
          FROM lab_private_server.capability_manifest
         WHERE capability_manifest_id = @id
           AND challenge_operational_policy_id = @policy_id
           AND client_feature_manifest_id = @feature_id
        """;
    await using var command = new NpgsqlCommand(sql, connection, transaction);
    Add(command, "id", NpgsqlDbType.Bigint, id);
    Add(command, "policy_id", NpgsqlDbType.Bigint, policy.Id);
    Add(command, "feature_id", NpgsqlDbType.Bigint, feature.Id);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken)
        .ConfigureAwait(false);
    if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      throw Failure(App.PrivateServerFailureKind.Unavailable, "capability_manifest_not_found");
    }
    var manifest = PrivateServerDomain.PrivateServerCapabilityManifest.CreatePhase2B(
        Uid(reader.GetValue(0)), feature.Uid, feature.Content, policy.Policy);
    if (manifest.ContentSha256 != Digest(reader.GetValue(1)))
    {
      throw Failure(App.PrivateServerFailureKind.Unavailable, "capability_manifest_content_invalid");
    }
    return new StoredCapabilityManifest(id, manifest, Instant(reader.GetValue(2)));
  }
}
