using System.Security.Cryptography;
using System.Text.Json;
using Npgsql;
using NikkeLocalLab.BattleLog;
using NikkeLocalLab.Persistence.PostgreSql;

var options = new JsonSerializerOptions { PropertyNameCaseInsensitive = true, WriteIndented = true };
if (args.Length == 4 && args[0] == "composition")
{
    var catalogBytes = File.ReadAllBytes(args[2]);
    var catalog = JsonSerializer.Deserialize<DamageCatalog>(catalogBytes, options)!;
    var catalogHash = Convert.ToHexString(SHA256.HashData(catalogBytes)).ToLowerInvariant();
    var inputs = JsonSerializer.Deserialize<Input[]>(File.ReadAllText(args[1]), options)!;
    var results = inputs.Select(input => {
        var raw = File.ReadAllBytes(input.RawPath);
        if (Convert.ToHexString(SHA256.HashData(raw)).ToLowerInvariant() != input.RawSha256) throw new InvalidDataException("input_changed");
        var projectile = BattleLogProjectileDecoder.Analyze(raw, input.Characters, input.ReportedTotal);
        return new { input.BattleUid, input.AccountUid, Analysis = DamageCompositionAnalyzer.Analyze(raw, input.Characters, projectile, catalog, catalogHash) };
    }).ToArray();
    File.WriteAllText(args[3], JsonSerializer.Serialize(results, options));
    Console.WriteLine(JsonSerializer.Serialize(new { count = results.Length, statuses = results.GroupBy(r => r.Analysis.Status).ToDictionary(g => g.Key, g => g.Count()) }));
    return;
}
if (args.Length == 3 && args[0] == "analyze")
{
    var inputs = JsonSerializer.Deserialize<Input[]>(File.ReadAllText(args[1]), options)!;
    var output = new List<AnalysisInput>();
    foreach (var input in inputs)
    {
        if (new FileInfo(input.RawPath).Length > BattleLogProjectileDecoder.MaximumRawBytes) throw new InvalidDataException("input_oversize");
        var raw = File.ReadAllBytes(input.RawPath);
        if (Convert.ToHexString(SHA256.HashData(raw)).ToLowerInvariant() != input.RawSha256) throw new InvalidDataException("input_changed");
        var analysis = BattleLogProjectileDecoder.Analyze(raw, input.Characters, input.ReportedTotal);
        output.Add(new(input.BattleUid, input.AccountUid, input.ReportedTotal, input.Characters.Select(c => new SourceCharacter(c.Ordinal, c.TabDamage)).ToArray(), analysis));
    }
    File.WriteAllText(args[2], JsonSerializer.Serialize(output, options));
    Console.WriteLine(JsonSerializer.Serialize(new { count = output.Count, statuses = output.GroupBy(x => x.Analysis.Status).ToDictionary(g => g.Key, g => g.Count()) }));
    return;
}
await using var data = PostgreSqlDataSourceFactory.Create(PostgreSqlConnectionPolicy.ResolveFromEnvironment("NIKKE_LAB_DB"));
if (args.Length == 1 && args[0] == "migrate") { Console.WriteLine(await new PostgreSqlMigrationRunner().MigrateAsync(data)); return; }
if (args.Length == 2 && args[0] == "import")
{
    var inputs = JsonSerializer.Deserialize<AnalysisInput[]>(File.ReadAllText(args[1]), options)!;
    await using var connection = await data.OpenConnectionAsync();
    await using var tx = await connection.BeginTransactionAsync();
    foreach (var input in inputs.Where(x => x.Analysis.Status == "ready"))
    {
        await using (var command = new NpgsqlCommand("""
            SELECT b.account_uid,c.ordinal,c.attack_total_damage,
              (SELECT sum(projectile_damage_received) FROM lab_private_server.raid_monster_damage m WHERE m.battle_uid=b.battle_uid)
            FROM lab_private_server.raid_battle_observation b
            JOIN lab_private_server.raid_character_damage c USING(battle_uid) WHERE b.battle_uid=@battle ORDER BY c.ordinal
            """, connection, tx))
        {
            command.Parameters.AddWithValue("battle", input.BattleUid);
            await using var reader = await command.ExecuteReaderAsync();
            var count = 0;
            while (await reader.ReadAsync())
            {
                var source = input.Characters.Single(c => c.Ordinal == reader.GetInt32(1));
                if (reader.GetGuid(0) != input.AccountUid || reader.IsDBNull(2) || reader.GetInt64(2) != source.TabDamage ||
                    reader.IsDBNull(3) || reader.GetFieldValue<decimal>(3) != input.ReportedTotal) throw new InvalidDataException("backfill_source_mismatch");
                count++;
            }
            if (count != input.Characters.Length || count != input.Analysis.Characters.Count) throw new InvalidDataException("backfill_count_mismatch");
        }
        ProjectileAnalysisStore.Save(connection, tx, input.BattleUid, input.Analysis);
    }
    await tx.CommitAsync();
    Console.WriteLine("backfilled=" + inputs.Count(x => x.Analysis.Status == "ready")); return;
}
throw new ArgumentException("usage: analyze inputs output | migrate | import analyses");

record Input(Guid BattleUid, Guid AccountUid, string RawPath, string RawSha256, BattleLogCharacter[] Characters, long? ReportedTotal);
record SourceCharacter(int Ordinal, long? TabDamage);
record AnalysisInput(Guid BattleUid, Guid AccountUid, long? ReportedTotal, SourceCharacter[] Characters, ProjectileAnalysis Analysis);
