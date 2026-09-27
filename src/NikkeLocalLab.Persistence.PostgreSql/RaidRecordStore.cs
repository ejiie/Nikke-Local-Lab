using System.Globalization;
using Npgsql;
using NikkeLocalLab.BattleLog;

namespace NikkeLocalLab.Persistence.PostgreSql;

public sealed record RaidRecordCharacter(int Ordinal, int Slot, Guid? CharacterUid, string? Damage,
    string? ProjectileDamage, string? ProjectileExcludedDamage);
public sealed class RaidRecord
{
  public Guid BattleUid { get; init; }
  public Guid AccountUid { get; init; }
  public int SeasonNumber { get; init; }
  public string Mode { get; init; } = "";
  public string RaidKind { get; init; } = "";
  public int BossStep { get; init; }
  public string WeaknessCode { get; init; } = "";
  public DateTime PlayedAt { get; init; }
  public string TeamLabel { get; init; } = "";
  public string ResultDamage { get; init; } = "";
  public string AnalysisStatus { get; init; } = "missing";
  public List<RaidRecordCharacter> Characters { get; } = [];
  public string? ProjectileExcludedDamage => Characters.Count > 0 && Characters.All(c => c.ProjectileExcludedDamage is not null)
      ? Characters.Aggregate(System.Numerics.BigInteger.Zero, (sum, c) => sum + System.Numerics.BigInteger.Parse(c.ProjectileExcludedDamage!, CultureInfo.InvariantCulture)).ToString(CultureInfo.InvariantCulture) : null;
}
public sealed record RaidRecordPage(IReadOnlyList<RaidRecord> Records, string? NextCursor);

public sealed class RaidRecordStore(NpgsqlDataSource dataSource)
{
  public async Task<RaidRecordPage> ListAsync(Guid account, int season, string kind, int step,
      string mode, string weakness, string? cursor, CancellationToken token)
  {
    var before = DateTime.SpecifyKind(DateTime.MaxValue, DateTimeKind.Utc); var beforeUid = Guid.Empty;
    if (!string.IsNullOrEmpty(cursor))
    {
      var parts = cursor.Split('.');
      if (parts.Length != 2 || !long.TryParse(parts[0], out var ticks) || ticks < DateTime.MinValue.Ticks || ticks > DateTime.MaxValue.Ticks ||
          !Guid.TryParse(parts[1], out beforeUid)) throw new ArgumentException("raid_cursor_invalid");
      before = new DateTime(ticks, DateTimeKind.Utc);
    }
    var wireMode = kind == "solo" ? (mode == "live" ? "solo_challenge" : "solo_challenge_practice")
        : (mode == "live" ? "union_hard" : "union_hard_practice");
    await using var command = dataSource.CreateCommand("""
            WITH selected AS (
                SELECT * FROM lab_private_server.raid_battle_observation
                WHERE account_uid=@account AND season_number=@season AND mode=@mode AND boss_step=@step
                  AND (@weakness='all' OR COALESCE(NULLIF(payload->>'Weakness',''),'unknown')=@weakness)
                  AND (@first OR (accepted_at_utc,battle_uid)<(@before,@uid))
                ORDER BY accepted_at_utc DESC,battle_uid DESC LIMIT 101
            )
            SELECT b.battle_uid,b.accepted_at_utc,b.team,b.request_damage,
                   COALESCE(NULLIF(b.payload->>'Weakness',''),'unknown'),COALESCE(a.status,'missing'),
                   c.ordinal,c.slot,c.character_uid,c.attack_total_damage,p.projectile_damage,p.excluded_damage
            FROM selected b
            LEFT JOIN lab_private_server.raid_character_damage c ON c.battle_uid=b.battle_uid
            LEFT JOIN lab_private_server.raid_projectile_analysis a ON a.battle_uid=b.battle_uid AND a.analysis_version=@version
            LEFT JOIN lab_private_server.raid_character_projectile_damage p
              ON p.battle_uid=c.battle_uid AND p.ordinal=c.ordinal AND p.analysis_version=a.analysis_version AND a.status='ready'
            ORDER BY b.accepted_at_utc DESC,b.battle_uid DESC,c.slot,c.ordinal
            """);
    command.Parameters.AddWithValue("account", account); command.Parameters.AddWithValue("season", season);
    command.Parameters.AddWithValue("mode", wireMode); command.Parameters.AddWithValue("step", step);
    command.Parameters.AddWithValue("weakness", weakness); command.Parameters.AddWithValue("first", string.IsNullOrEmpty(cursor));
    command.Parameters.AddWithValue("before", before); command.Parameters.AddWithValue("uid", beforeUid);
    command.Parameters.AddWithValue("version", ProjectileAnalysis.CurrentVersion);
    await using var reader = await command.ExecuteReaderAsync(token).ConfigureAwait(false);
    var rows = new List<RaidRecord>();
    while (await reader.ReadAsync(token).ConfigureAwait(false))
    {
      var battle = reader.GetGuid(0);
      if (rows.LastOrDefault()?.BattleUid != battle)
        rows.Add(new RaidRecord
        {
          BattleUid = battle,
          AccountUid = account,
          SeasonNumber = season,
          Mode = mode,
          RaidKind = kind,
          BossStep = step,
          PlayedAt = reader.GetDateTime(1),
          TeamLabel = "덱 " + reader.GetInt32(2).ToString(CultureInfo.InvariantCulture),
          ResultDamage = reader.GetInt64(3).ToString(CultureInfo.InvariantCulture),
          WeaknessCode = reader.GetString(4),
          AnalysisStatus = reader.GetString(5)
        });
      if (!reader.IsDBNull(6)) rows[^1].Characters.Add(new(reader.GetInt32(6), reader.GetInt32(7),
          reader.IsDBNull(8) ? null : reader.GetGuid(8), Number(9), Number(10), Number(11)));
    }
    string? next = null;
    if (rows.Count > 100)
    {
      rows.RemoveAt(100); var last = rows[^1];
      next = last.PlayedAt.Ticks.ToString(CultureInfo.InvariantCulture) + "." + last.BattleUid.ToString("D");
    }
    return new(rows, next);
    string? Number(int index) => reader.IsDBNull(index) ? null : reader.GetInt64(index).ToString(CultureInfo.InvariantCulture);
  }
}
