using App = NikkeLocalLab.Application.ProfileManagement;
using NikkeLocalLab.Identity;
using Npgsql;

namespace NikkeLocalLab.Persistence.PostgreSql;

public sealed partial class PostgreSqlProfileManagementService
{
  private async Task<LocalAccountProfileWrite> EnsureCubeInventoryAsync(
      LocalAccountProfileWrite profile,
      CancellationToken cancellationToken)
  {
    var available = await _profileStore.GetCubeCatalogLevelsAsync(
        profile.CombatSupportCatalog.CatalogSnapshotUid, cancellationToken).ConfigureAwait(false);
    var owned = profile.AccountState.Cubes.ToDictionary(static cube => cube.DefinitionUid);
    if (owned.Keys.Any(uid => !available.ContainsKey(uid)))
    {
      throw new LocalAccountProfileIntegrityException("profile_account_cube_not_in_catalog");
    }

    foreach (var (uid, levels) in available)
    {
      if (owned.ContainsKey(uid)) continue;
      // Preserve the highest existing observation for a shared cube. New local ownership
      // uses the established level-15 preset, bounded by this immutable catalog snapshot.
      var observed = profile.Builds.Where(build => build.Cube.DefinitionUid == uid)
          .Select(build => build.Cube.Level?.Value).OfType<int>().ToArray();
      var level = observed.Length > 0 ? observed.Max() : levels.Max();
      owned.Add(uid, new LocalOwnedCubeWrite(uid, level));
    }

    foreach (var cube in owned.Values)
    {
      if (!available[cube.DefinitionUid].Contains(cube.Level))
      {
        throw new LocalAccountProfileIntegrityException("profile_cube_level_not_in_catalog");
      }
    }

    var state = profile.AccountState;
    return new LocalAccountProfileWrite(
        profile.CharacterCatalog, profile.CombatSupportCatalog,
        new LocalAccountCombatStateWrite(state.SynchroLevel, state.Consoles,
            state.ValidationMode, state.Origin, owned.Values),
        profile.Builds.Select(build => build.Cube.DefinitionUid is { } uid && owned.TryGetValue(uid, out var cube) &&
            build.Cube.Level?.Value != cube.Level
            ? ApplyBuildOperations(build, [new App.ProfileEditOperation(
                "cube.level", build.CharacterUid, "integer", IntegerValue: cube.Level)])
            : build),
        profile.SquadCharacterUids, profile.SquadOrigin, profile.ProfileTemplateOrigin);
  }
}

public sealed partial class PostgreSqlLocalAccountProfileStore
{
  internal async Task<IReadOnlyDictionary<EntityUid, int[]>> GetCubeCatalogLevelsAsync(
      EntityUid catalogUid, CancellationToken cancellationToken)
  {
    await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken).ConfigureAwait(false);
    await using var command = new NpgsqlCommand(
        """
        SELECT entity.definition_uid, array_agg(coordinate.level ORDER BY coordinate.level)
        FROM lab_combat_support.catalog_snapshot snapshot
        JOIN lab_combat_support.catalog_snapshot_member member
          ON member.catalog_snapshot_id = snapshot.catalog_snapshot_id
        JOIN lab_combat_support.definition_entity entity
          ON entity.definition_entity_id = member.definition_entity_id
        JOIN lab_combat_support.definition_level_coordinate coordinate
          ON coordinate.definition_version_id = member.definition_version_id
        WHERE snapshot.catalog_snapshot_uid = @uid AND member.definition_kind = 'cube'
          AND coordinate.level BETWEEN 1 AND 15
        GROUP BY entity.definition_uid;
        """, connection);
    command.Parameters.AddWithValue("uid", catalogUid.Value);
    var result = new Dictionary<EntityUid, int[]>();
    await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
    while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      result.Add(new EntityUid(reader.GetGuid(0)), reader.GetFieldValue<int[]>(1));
    }

    return result;
  }
}
