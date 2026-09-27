using EpinelPS.Models;
using Newtonsoft.Json;
using Npgsql;
using NpgsqlTypes;
using System.Security.Cryptography;
using System.Text;

namespace EpinelPS.Database;

public static class RaidDamageObservationStore
{
    // The Solo JSON receipt is a durable outbox. A failed projection never discards it.
    public static void FlushSolo(CoreInfo core, bool required = false)
    {
        BattleLogDiagnostics.ReportReadinessOnce();
        foreach (var user in core.Users)
        {
            var observations = user.SoloRaidData.Values.SelectMany(r => r.BattleHistory)
                .Where(b => b.DamageStatistics is not null).Select(b => b.DamageStatistics!).ToArray();
            if (observations.Length == 0) continue;
            var variable = user.LocalPersistenceBinding?.DamageCaptureConnectionEnvironmentVariable;
            if (string.IsNullOrEmpty(variable)) continue; // Synthetic/legacy runtimes have no capture binding.
            try
            {
                var connectionString = Environment.GetEnvironmentVariable(variable);
                if (string.IsNullOrWhiteSpace(connectionString)) throw new InvalidOperationException("raid_damage_store_unavailable");
                using var connection = new NpgsqlConnection(connectionString);
                connection.Open();
                using var transaction = connection.BeginTransaction();
                foreach (var observation in observations) Write(connection, transaction, observation);
                transaction.Commit();
            }
            catch
            {
                if (required) throw new InvalidOperationException("raid_damage_capture_pending");
                Console.WriteLine("NLL_RAID_DAMAGE_CAPTURE_PENDING/v1 source=solo_receipt");
            }
        }
    }

    public static void Write(NpgsqlConnection connection, NpgsqlTransaction transaction, RaidDamageObservation value)
    {
        if (value.AccountUid == Guid.Empty || value.BattleUid == Guid.Empty || value.Season <= 0)
            throw new InvalidOperationException("raid_damage_identity_missing");
        var json = JsonConvert.SerializeObject(value);
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(json));
        using var parent = new NpgsqlCommand("""
            INSERT INTO lab_private_server.raid_battle_observation
              (battle_uid,account_uid,mode,season_number,raid_level,boss_step,team,request_damage,accepted_damage,
               accepted_at_utc,payload,payload_sha256)
            VALUES (@battle,@account,@mode,@season,@level,@step,@team,@request,@accepted,@at,@payload,@hash)
            ON CONFLICT (battle_uid) DO NOTHING RETURNING battle_uid
            """, connection, transaction);
        parent.Parameters.AddWithValue("battle", value.BattleUid);
        parent.Parameters.AddWithValue("account", value.AccountUid);
        parent.Parameters.AddWithValue("mode", value.Mode);
        parent.Parameters.AddWithValue("season", value.Season);
        parent.Parameters.AddWithValue("level", value.RaidLevel);
        parent.Parameters.AddWithValue("step", value.BossStep);
        parent.Parameters.AddWithValue("team", value.Team);
        parent.Parameters.AddWithValue("request", value.RequestDamage);
        parent.Parameters.AddWithValue("accepted", value.AcceptedDamage);
        parent.Parameters.AddWithValue("at", value.AcceptedAtUtc.UtcDateTime);
        parent.Parameters.AddWithValue("payload", NpgsqlDbType.Jsonb, json);
        parent.Parameters.AddWithValue("hash", hash);
        if (parent.ExecuteScalar() is null)
        {
            using var check = new NpgsqlCommand("SELECT payload_sha256 FROM lab_private_server.raid_battle_observation WHERE battle_uid=@battle", connection, transaction);
            check.Parameters.AddWithValue("battle", value.BattleUid);
            if (check.ExecuteScalar() is not byte[] previous || !previous.AsSpan().SequenceEqual(hash))
                throw new InvalidOperationException("raid_damage_replay_conflict");
            return;
        }
        foreach (var c in value.Characters)
        {
            using var child = new NpgsqlCommand("""
                INSERT INTO lab_private_server.raid_character_damage
                  (battle_uid,ordinal,slot,character_uid,attack_total_damage,attack_total_actual_damage,
                   skill_total_damage,skill_total_actual_damage,stat_function_total_damage,stat_function_total_actual_damage)
                VALUES (@battle,@ordinal,@slot,@character,@attack,@attackActual,@skill,@skillActual,@stat,@statActual)
                """, connection, transaction);
            child.Parameters.AddWithValue("battle", value.BattleUid);
            child.Parameters.AddWithValue("ordinal", c.Ordinal);
            child.Parameters.AddWithValue("slot", c.Slot);
            Add(child,"character",NpgsqlDbType.Uuid,c.CharacterUid);
            Add(child,"attack",NpgsqlDbType.Bigint,c.Attack?.TotalDamage);
            Add(child,"attackActual",NpgsqlDbType.Bigint,c.Attack?.TotalActualDamage);
            Add(child,"skill",NpgsqlDbType.Bigint,c.Skill?.TotalDamage);
            Add(child,"skillActual",NpgsqlDbType.Bigint,c.Skill?.TotalActualDamage);
            Add(child,"stat",NpgsqlDbType.Bigint,c.StatFunctionAttack?.TotalDamage);
            Add(child,"statActual",NpgsqlDbType.Bigint,c.StatFunctionAttack?.TotalActualDamage);
            child.ExecuteNonQuery();
        }
        foreach (var m in value.Monsters)
        {
            using var child = new NpgsqlCommand("""
                INSERT INTO lab_private_server.raid_monster_damage
                  (battle_uid,ordinal,hp_total_damage_received,hp_total_actual_damage_received,
                   parts_destroy_damage_received,projectile_damage_received)
                VALUES (@battle,@ordinal,@hp,@actual,@parts,@projectile)
                """, connection, transaction);
            child.Parameters.AddWithValue("battle", value.BattleUid);
            child.Parameters.AddWithValue("ordinal", m.Ordinal);
            Add(child,"hp",NpgsqlDbType.Bigint,m.Hp?.TotalDamageReceived);
            Add(child,"actual",NpgsqlDbType.Bigint,m.Hp?.TotalActualDamageReceived);
            Add(child,"parts",NpgsqlDbType.Bigint,m.Hp?.TotalPartsDestroyDamageReceived);
            Add(child,"projectile",NpgsqlDbType.Bigint,m.Hp?.TotalProjectileDamageReceived);
            child.ExecuteNonQuery();
        }
        if (value.ProjectileAnalysis is { } analysis)
            NikkeLocalLab.BattleLog.ProjectileAnalysisStore.Save(connection, transaction, value.BattleUid, analysis);
    }
    private static void Add(NpgsqlCommand command,string name,NpgsqlDbType type,object? value) =>
        command.Parameters.AddWithValue(name,type,value ?? DBNull.Value);
}
