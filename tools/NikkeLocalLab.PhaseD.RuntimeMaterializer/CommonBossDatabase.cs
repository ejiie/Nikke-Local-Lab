using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using NikkeLocalLab.Persistence.PostgreSql;
using Npgsql;

internal static class CommonBossDatabase
{
  internal static async Task<CommonBossRuntimeBinding> Register(string descriptor, string digest, string profilePath, string connection,
      string? previousProfilePath = null)
  {
    var ready = await CommonBossDelivery.Validate(descriptor, digest, profilePath, "iron");
    byte[]? equivalentProfile = null;
    if (previousProfilePath is not null)
    {
      var previous = await BossRuntimeVariantProfile.LoadAsync(previousProfilePath);
      if (!SourceIdentity(previous, false).AsSpan().SequenceEqual(SourceIdentity(ready.Profile, false)))
        throw new InvalidOperationException("phase_d_boss_update_combat_source_changed");
      equivalentProfile = Convert.FromHexString(previous.Sha256);
    }
    return await Publish(ready.Profile, ready.Plan.CandidateSeal.Sha256, connection, false, equivalentProfile);
  }

  internal static async Task<CommonBossRuntimeBinding> AdoptLegacy(string profilePath, string connection) =>
      await Publish(await BossRuntimeVariantProfile.LoadAsync(profilePath), CommonDeliveryFiles.FileHash(profilePath), connection, true);

  private static byte[] SourceIdentity(BossRuntimeVariantProfile p, bool includeArchiveOrigin) =>
      SHA256.HashData(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new
      {
        contractId = "nll/common-boss-runtime-source/v1", p.SeasonNumber,
        SelectedManagerObservation = includeArchiveOrigin ? p.SelectedManagerObservation :
            p.SelectedManagerObservation with { SourceObservationSha256 = new string('0', 64) },
        p.ChallengeSelector, p.SourceAffinity, p.SkillClosure, p.BehaviorAssembly, p.QuickTimeEventAffinity
      })));

  private static async Task<CommonBossRuntimeBinding> Publish(BossRuntimeVariantProfile p, string candidateHash, string connection,
      bool requireLegacy, byte[]? equivalentProfile = null)
  {
    // Source identity excludes generated FX and the selected weakness. Corrections
    // to delivery alone must not reset the player's existing Challenge history.
    var source = SourceIdentity(p, true);
    await using var dataSource = NpgsqlDataSource.Create(connection);
    return await new CommonBossRuntimeBindingStore(dataSource).PublishAsync(p.SeasonNumber,
        Convert.FromHexString(p.Sha256), source, Convert.FromHexString(candidateHash), requireLegacy: requireLegacy,
        equivalentProfileSha256: equivalentProfile);
  }

  internal static async Task Verify(BossRuntimeVariantProfile profile, string connection)
  {
    await using var dataSource = NpgsqlDataSource.Create(connection);
    _ = await new CommonBossRuntimeBindingStore(dataSource).FindAsync(profile.SeasonNumber, Convert.FromHexString(profile.Sha256));
  }
}
