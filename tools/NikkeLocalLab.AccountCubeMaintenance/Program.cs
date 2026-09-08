using System.Text.Json;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Persistence.PostgreSql;

try
{
  if (args.Length != 1 || args[0] is not ("--apply" or "--verify"))
    throw new InvalidOperationException("cube_maintenance_mode_required");
  var connectionString = PostgreSqlConnectionPolicy.ResolveFromEnvironment("NIKKE_LAB_DB");
  await using var dataSource = PostgreSqlDataSourceFactory.Create(connectionString);
  if (args[0] == "--apply") await new PostgreSqlMigrationRunner().MigrateAsync(dataSource);
  var store = new PostgreSqlLocalAccountProfileStore(dataSource, new RandomEntityUidGenerator());
  var service = new PostgreSqlProfileManagementService(dataSource, new RandomEntityUidGenerator());
  var accounts = new List<EntityUid>();
  await using (var command = dataSource.CreateCommand("SELECT local_account_uid FROM lab_profile.local_account ORDER BY local_account_uid;"))
  await using (var reader = await command.ExecuteReaderAsync())
    while (await reader.ReadAsync()) accounts.Add(new EntityUid(reader.GetGuid(0)));
  var changed = 0;
  var totalOwned = 0;
  foreach (var account in accounts)
  {
    var current = await store.GetCurrentAsync(account) ?? throw new InvalidOperationException("cube_maintenance_profile_missing");
    if (args[0] == "--apply")
    {
      var preview = await service.PreviewProfileEditsAsync(new(EntityUid.New(), account, current.Revision.ProfileTemplateRevisionUid, []));
      if (preview.Changes.Count > 0)
      {
        await service.SaveProfileAsync(new(EntityUid.New(), account, current.Revision.ProfileTemplateRevisionUid,
            preview.CandidateDraftUid, preview.CandidateSha256, preview.DiffSha256));
        changed++;
      }
    }
    current = await store.GetCurrentAsync(account) ?? throw new InvalidOperationException("cube_maintenance_profile_missing");
    var owned = current.Profile.AccountState.Cubes.ToDictionary(cube => cube.DefinitionUid);
    await using var count = dataSource.CreateCommand("""
        SELECT count(*) FROM lab_combat_support.catalog_snapshot snapshot
        JOIN lab_combat_support.catalog_snapshot_member member ON member.catalog_snapshot_id = snapshot.catalog_snapshot_id
        WHERE snapshot.catalog_snapshot_uid = @uid AND member.definition_kind = 'cube';
        """);
    count.Parameters.AddWithValue("uid", current.Profile.CombatSupportCatalog.CatalogSnapshotUid.Value);
    if (owned.Count != Convert.ToInt32(await count.ExecuteScalarAsync()) ||
        current.Profile.Builds.Any(build => build.Cube.DefinitionUid is { } uid &&
            (!owned.TryGetValue(uid, out var cube) || cube.Level != build.Cube.Level?.Value)))
      throw new InvalidOperationException("cube_maintenance_inventory_incomplete");
    totalOwned += owned.Count;
  }
  Console.WriteLine(JsonSerializer.Serialize(new { status = "verified", accountCount = accounts.Count,
      changedAccountCount = changed, totalOwnedCubeCount = totalOwned, defaultMissingLevel = 15 }));
  return 0;
}
catch (Exception error)
{
  // Never print database exception details or connection strings in maintenance receipts.
  Console.Error.WriteLine(error is InvalidOperationException && error.Message.StartsWith("cube_maintenance_", StringComparison.Ordinal)
      ? error.Message : "cube_maintenance_failed");
  return 1;
}
