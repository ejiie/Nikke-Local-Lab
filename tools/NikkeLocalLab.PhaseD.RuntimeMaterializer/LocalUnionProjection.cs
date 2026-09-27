using System.Security.Cryptography;
using System.Text.Json;
using EpinelPS;
using EpinelPS.Models;
using NikkeLocalLab.Persistence.PostgreSql;
using Npgsql;

internal static class LocalUnionProjection
{
  internal static async Task RestoreAsync(User user, NpgsqlDataSource source, Guid accountUid, string sourcePack, string connectionEnvironmentVariable)
  {
    var membership = await LocalUnionStore.ReadAsync(source, accountUid);
    if (membership is null) return;
    user.Guild.guildId = 1;
    user.Guild.LeaveAt = null;
    user.LocalUnionRaid = new LocalUnionRaidState { Name = membership.Name, Level = membership.Level,
      ConnectionEnvironmentVariable = connectionEnvironmentVariable };
    if (membership.SeasonNumber == 0) return;
    BossSeasonCatalog.Plain(membership.PublicationRoot);
    var receiptPath = Path.Combine(membership.PublicationRoot, "receipt.json");
    byte[] Read(string path)
    {
      BossSeasonCatalog.Plain(path);
      if (new FileInfo(path).Length is <= 0 or > 16777216) throw new InvalidOperationException("phase_d_union_publication_invalid");
      return File.ReadAllBytes(path);
    }
    var bytes = Read(receiptPath);
    static string Hash(byte[] value) => Convert.ToHexStringLower(SHA256.HashData(value));
    if (Hash(bytes) != membership.ReceiptSha256) throw new InvalidOperationException("phase_d_union_publication_changed");
    using var receipt = JsonDocument.Parse(bytes);
    var r = receipt.RootElement;
    if (r.GetProperty("contractId").GetString() != "nll/union-raid-hard-assembly/v1" ||
        r.GetProperty("catalogSha256").GetString() != membership.CatalogSha256 ||
        r.GetProperty("seasonNumber").GetInt32() != membership.SeasonNumber ||
        r.GetProperty("elementModified").GetBoolean() || r.GetProperty("fxModified").GetBoolean())
      throw new InvalidOperationException("phase_d_union_publication_invalid");
    var runtime = Read(Path.Combine(membership.PublicationRoot, "runtime.private.json"));
    if (Hash(runtime) != r.GetProperty("runtimeSha256").GetString()) throw new InvalidOperationException("phase_d_union_publication_changed");
    using var document = JsonDocument.Parse(runtime);
    var data = document.RootElement;
    // Membership survives updates. Old private source references are never
    // interpreted against another pack until that season has been reassembled.
    if (data.GetProperty("sourceStaticDataSha256").GetString() != Hash(File.ReadAllBytes(sourcePack))) return;
    if (data.GetProperty("contractId").GetString() != "nll/private-union-raid-hard/v1" ||
        data.GetProperty("seasonNumber").GetInt32() != membership.SeasonNumber ||
        !data.GetProperty("bosses").EnumerateArray().Select(b => b.GetProperty("order").GetInt32()).SequenceEqual(Enumerable.Range(1, 5)))
      throw new InvalidOperationException("phase_d_union_publication_invalid");
    user.LocalUnionRaid.SeasonNumber = membership.SeasonNumber;
    user.LocalUnionRaid.ManagerTid = data.GetProperty("manager").GetProperty("id").GetInt32();
    user.LocalUnionRaid.NormalLastLevel = data.GetProperty("normalLastLevel").GetInt32();
    user.LocalUnionRaid.NormalCleared = membership.NormalCleared;
  }
}
