using Npgsql;

namespace NikkeLocalLab.BattleLog;

public static class ProjectileAnalysisStore
{
  public static void Save(NpgsqlConnection connection, NpgsqlTransaction transaction, Guid battleUid, ProjectileAnalysis analysis)
  {
    using var insert = new NpgsqlCommand("""
            INSERT INTO lab_private_server.raid_projectile_analysis
                (battle_uid,analysis_version,log_sha256,status)
            VALUES (@battle,@version,@hash,@status)
            ON CONFLICT (battle_uid,analysis_version) DO NOTHING RETURNING battle_uid
            """, connection, transaction);
    insert.Parameters.AddWithValue("battle", battleUid);
    insert.Parameters.AddWithValue("version", analysis.Version);
    insert.Parameters.AddWithValue("hash", analysis.LogSha256);
    insert.Parameters.AddWithValue("status", analysis.Status);
    if (insert.ExecuteScalar() is null)
    {
      using var previous = new NpgsqlCommand("SELECT log_sha256,status FROM lab_private_server.raid_projectile_analysis WHERE battle_uid=@battle AND analysis_version=@version", connection, transaction);
      previous.Parameters.AddWithValue("battle", battleUid); previous.Parameters.AddWithValue("version", analysis.Version);
      using var reader = previous.ExecuteReader();
      if (!reader.Read() || reader.GetString(0) != analysis.LogSha256 || reader.GetString(1) != analysis.Status)
        throw new InvalidOperationException("raid_analysis_replay_conflict");
      return;
    }
    if (analysis.Status != "ready") return;
    foreach (var row in analysis.Characters)
    {
      using var child = new NpgsqlCommand("""
                INSERT INTO lab_private_server.raid_character_projectile_damage
                    (battle_uid,analysis_version,ordinal,projectile_damage,excluded_damage)
                SELECT @battle,@version,@ordinal,@projectile,@excluded
                FROM lab_private_server.raid_character_damage
                WHERE battle_uid=@battle AND ordinal=@ordinal AND attack_total_damage=@projectile+@excluded
                """, connection, transaction);
      child.Parameters.AddWithValue("battle", battleUid); child.Parameters.AddWithValue("version", analysis.Version);
      child.Parameters.AddWithValue("ordinal", row.Ordinal); child.Parameters.AddWithValue("projectile", row.ProjectileDamage);
      child.Parameters.AddWithValue("excluded", row.ExcludedDamage);
      if (child.ExecuteNonQuery() != 1) throw new InvalidOperationException("raid_analysis_source_mismatch");
    }
  }
}
