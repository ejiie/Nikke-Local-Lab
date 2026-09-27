using EpinelPS.Data;

internal static class SoloRaidManagerSelection
{
  // The current source record has exactly Id, MonsterPreset and RankingGroupId.
  // Fail on a future schema extension until its equivalence rules are reviewed.
  internal static SoloRaidManagerRecord[] ForSeason(IEnumerable<SoloRaidManagerRecord> rows, int season)
  {
    if (!typeof(SoloRaidManagerRecord).GetFields().Select(field => field.Name).Order(StringComparer.Ordinal)
        .SequenceEqual(new[] { "Id", "MonsterPreset", "RankingGroupId" }))
      throw new InvalidOperationException("phase_d_boss_catalog_manager_schema_changed");
    return rows.Where(row => row.RankingGroupId == season)
        .GroupBy(row => (row.RankingGroupId, row.MonsterPreset))
        .Select(group => group.MinBy(row => row.Id)!).OrderBy(row => row.Id).ToArray();
  }
}
