using System.Security.Cryptography;
using System.Text;
using Npgsql;

namespace NikkeLocalLab.Persistence.PostgreSql;

public sealed record CommonBossRuntimeBinding(int SeasonNumber, Guid RaidSnapshotUid, byte[] RaidSnapshotSha256);

// The caller validates the sealed assembly before publication. This store owns
// atomic, immutable identity and retry semantics; it never edits account state.
public sealed class CommonBossRuntimeBindingStore(NpgsqlDataSource dataSource)
{
  public async Task<CommonBossRuntimeBinding> FindAsync(int season, byte[] profileHash,
      CancellationToken cancellationToken = default)
  {
    Validate(season, profileHash);
    await using var connection = await dataSource.OpenConnectionAsync(cancellationToken);
    return await FindAsync(connection, null, season, profileHash, cancellationToken) ??
        throw new InvalidOperationException("phase_d_raid_state_operational_binding_missing");
  }

  public async Task<CommonBossRuntimeBinding> PublishAsync(int season, byte[] profileHash,
      byte[] sourceHash, byte[] candidateHash, CancellationToken cancellationToken = default, bool requireLegacy = false,
      byte[]? equivalentProfileSha256 = null)
  {
    Validate(season, profileHash, sourceHash, candidateHash);
    if (equivalentProfileSha256 is not null) Validate(season, equivalentProfileSha256);
    await using var connection = await dataSource.OpenConnectionAsync(cancellationToken);
    await using var transaction = await connection.BeginTransactionAsync(cancellationToken);
    await using (var command = new NpgsqlCommand("SELECT pg_advisory_xact_lock(174903, $1)", connection, transaction))
    {
      command.Parameters.AddWithValue(season);
      await command.ExecuteNonQueryAsync(cancellationToken);
    }
    var existing = await FindAsync(connection, transaction, season, profileHash, cancellationToken);
    if (existing is not null)
    {
      await using var verify = new NpgsqlCommand("SELECT source_sha256 FROM lab_private_server.common_boss_runtime_binding WHERE profile_sha256=$1", connection, transaction);
      verify.Parameters.AddWithValue(profileHash);
      var registeredSource = (byte[])(await verify.ExecuteScalarAsync(cancellationToken))!;
      if (!sourceHash.AsSpan().SequenceEqual(registeredSource))
        throw new InvalidOperationException("phase_d_boss_runtime_binding_conflict");
      await transaction.CommitAsync(cancellationToken);
      return existing;
    }

    long? snapshotId = null;
    // Reassembly/FX changes with identical source evidence retain the same
    // progression identity. Different source evidence gets a new snapshot.
    await using (var command = new NpgsqlCommand("""
        SELECT DISTINCT raid_snapshot_id FROM lab_private_server.common_boss_runtime_binding
         WHERE season_number=$1 AND source_sha256=$2
        """, connection, transaction))
    {
      command.Parameters.AddWithValue(season); command.Parameters.AddWithValue(sourceHash);
      await using var reader = await command.ExecuteReaderAsync(cancellationToken);
      if (await reader.ReadAsync(cancellationToken)) snapshotId = reader.GetInt64(0);
      if (await reader.ReadAsync(cancellationToken)) throw new InvalidOperationException("phase_d_boss_runtime_binding_ambiguous");
    }
    // A version-update caller may attest that only the containing archive's
    // provenance changed. The materializer compares the complete combat evidence
    // before supplying this immutable, already registered predecessor profile.
    if (equivalentProfileSha256 is not null)
    {
      await using var command = new NpgsqlCommand("SELECT raid_snapshot_id FROM lab_private_server.common_boss_runtime_binding WHERE season_number=$1 AND profile_sha256=$2", connection, transaction);
      command.Parameters.AddWithValue(season); command.Parameters.AddWithValue(equivalentProfileSha256);
      var previousId = await command.ExecuteScalarAsync(cancellationToken);
      if (previousId is not long previous || (snapshotId is not null && snapshotId != previous))
        throw new InvalidOperationException("phase_d_boss_update_previous_binding_invalid");
      snapshotId = previous;
    }
    // Initial adoption preserves an unambiguous historical season identity.
    // Once any source has been published, never attach a changed source to it.
    if (snapshotId is null)
    {
      await using var command = new NpgsqlCommand("""
          SELECT raid_snapshot_id FROM lab_private_server.runtime_raid_snapshot
           WHERE season_number=$1 AND legacy_snapshot_id IS NOT NULL
             AND NOT EXISTS (SELECT 1 FROM lab_private_server.common_boss_runtime_binding WHERE season_number=$1)
          """, connection, transaction);
      command.Parameters.AddWithValue(season);
      await using var reader = await command.ExecuteReaderAsync(cancellationToken);
      if (await reader.ReadAsync(cancellationToken)) snapshotId = reader.GetInt64(0);
      if (await reader.ReadAsync(cancellationToken)) throw new InvalidOperationException("phase_d_boss_runtime_legacy_binding_ambiguous");
    }
    if (snapshotId is null)
    {
      if (requireLegacy) throw new InvalidOperationException("phase_d_boss_runtime_legacy_binding_missing");
      var hash = SHA256.HashData(Encoding.UTF8.GetBytes("nll/common-raid-runtime-snapshot/v1\n" +
          season.ToString(System.Globalization.CultureInfo.InvariantCulture) + "\n" + Convert.ToHexString(sourceHash).ToLowerInvariant() + "\n"));
      await using var command = new NpgsqlCommand("""
          INSERT INTO lab_private_server.runtime_raid_snapshot
              (raid_snapshot_id, raid_snapshot_uid, season_number, content_sha256, source_sha256, created_at_utc)
          VALUES (nextval('lab_private_server.common_runtime_snapshot_id_seq'), $1, $2, $3, $4, now())
          RETURNING raid_snapshot_id
          """, connection, transaction);
      command.Parameters.AddWithValue(Guid.NewGuid()); command.Parameters.AddWithValue(season);
      command.Parameters.AddWithValue(hash); command.Parameters.AddWithValue(sourceHash);
      snapshotId = (long)(await command.ExecuteScalarAsync(cancellationToken))!;
    }
    await using (var command = new NpgsqlCommand("""
        INSERT INTO lab_private_server.common_boss_runtime_binding
            (profile_sha256, season_number, source_sha256, candidate_sha256, raid_snapshot_id, admission_policy_id, created_at_utc)
        VALUES ($1, $2, $3, $4, $5, 'common-boss-runtime-admission/v1', now())
        """, connection, transaction))
    {
      command.Parameters.AddWithValue(profileHash); command.Parameters.AddWithValue(season);
      command.Parameters.AddWithValue(sourceHash); command.Parameters.AddWithValue(candidateHash);
      command.Parameters.AddWithValue(snapshotId.Value);
      await command.ExecuteNonQueryAsync(cancellationToken);
    }
    var result = await FindAsync(connection, transaction, season, profileHash, cancellationToken) ??
        throw new InvalidOperationException("phase_d_boss_runtime_binding_publish_failed");
    await transaction.CommitAsync(cancellationToken);
    return result;
  }

  private static async Task<CommonBossRuntimeBinding?> FindAsync(NpgsqlConnection connection, NpgsqlTransaction? transaction,
      int season, byte[] hash, CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand("""
        SELECT binding.season_number, snapshot.raid_snapshot_uid, snapshot.content_sha256
          FROM lab_private_server.common_boss_runtime_binding binding
          JOIN lab_private_server.runtime_raid_snapshot snapshot ON snapshot.raid_snapshot_id=binding.raid_snapshot_id
         WHERE binding.profile_sha256=$1
        """, connection, transaction);
    command.Parameters.AddWithValue(hash);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    if (!await reader.ReadAsync(cancellationToken)) return null;
    if (reader.GetInt32(0) != season) throw new InvalidOperationException("phase_d_boss_runtime_binding_conflict");
    return new(season, reader.GetGuid(1), reader.GetFieldValue<byte[]>(2));
  }

  private static void Validate(int season, params byte[][] hashes)
  {
    if (season <= 0 || hashes.Any(hash => hash is null || hash.Length != 32))
      throw new InvalidOperationException("phase_d_boss_runtime_binding_invalid");
  }
}
