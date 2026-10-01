using EpinelPS.Data;

internal static class UnionRaidCatalogChecks
{
  internal static object Verify()
  {
    var passed = 0;
    void Check(bool condition) { if (!condition) throw new InvalidOperationException("boss_union_synthetic_failed"); passed++; }
    var managers = new[] { new UnionRaidManagerRecord { Id = 1001, MonsterPreset = 10 }, new UnionRaidManagerRecord { Id = 1003, MonsterPreset = 30 } };
    var rows = Enumerable.Range(1, 5).SelectMany(order => Enumerable.Range(1, 3).Select(level => new UnionRaidPresetRecord
    { PresetGroupId = 30, DifficultyType = UnionRaidDifficultyType.Hard, WaveOrder = order, WaveChangeStep = level, Wave = order })).ToList();
    rows.Add(new() { PresetGroupId = 30, DifficultyType = UnionRaidDifficultyType.Normal, WaveOrder = 5, WaveChangeStep = 10 });
    rows.Add(new() { PresetGroupId = 30, DifficultyType = UnionRaidDifficultyType.Hard, WaveOrder = 5, WaveChangeStep = 4, IsTrial = true, Wave = 6 });
    var waves = Enumerable.Range(1, 6).Select(i => new WaveDataRecord { StageId = i, TargetList = [i],
      WaveData = [new WaveData { WaveMonsterList = [new WaveMonsterData { WaveMonsterId = i }] }] }).ToArray();
    var monsters = Enumerable.Range(1, 6).Select(i => new MonsterRecord { Id = i, SpotAi = "synthetic-" + i,
      NameLocalkey = "synthetic_name", ElementId = [i] }).ToArray();
    var names = new Dictionary<string, string> { ["Locale_System:synthetic_name"] = "합성 보스" };
    UnionRaidCatalog.Season[] Build() => UnionRaidCatalog.Build(managers, rows.ToArray(), waves, monsters, names);
    var result = Build();
    Check(result.Select(s => s.Number).SequenceEqual([3, 1]));
    Check(result[1].FailureCode == "boss_union_hard_not_available");
    Check(result[0].Bosses.Length == 5 && result[0].NormalLastLevel == 10);
    Check(result[0].Bosses[4].Presets.Length == 4 && result[0].Bosses[4].BehaviorKeys.Length == 2);
    Check(result[0].Bosses.All(b => b.DisplayName == "합성 보스"));
    Check(result[0].Bosses[0].Monsters[0].ElementId!.SequenceEqual([1]));
    var elements = Enumerable.Range(1, 6).Select(i => new ElementRecord
      { Id = i, Element = AttackType.Fire, WeakElementId = 7 }).Append(new ElementRecord
      { Id = 7, Element = AttackType.Water, WeakElementId = 1 }).ToArray();
    Check(result[0].Bosses.All(b => UnionRaidCatalog.Weakness(b, elements) == "water"));
    elements[5].WeakElementId = 1;
    Check(UnionRaidCatalog.Weakness(Build()[0].Bosses[4], elements) is null && Build()[0].FailureCode is null);
    elements[5].WeakElementId = 7;
    Check(UnionRaidCatalog.Weakness(result[0].Bosses[4], elements[..5]) is null);
    Check(UnionRaidCatalog.Weakness(result[0].Bosses[4], elements.Where(e => e.Id != 6).ToArray()) is null);
    monsters[0].ElementId = [];
    Check(UnionRaidCatalog.Weakness(Build()[0].Bosses[0], elements) is null && Build()[0].FailureCode is null);
    monsters[0].ElementId = [1, 7];
    Check(UnionRaidCatalog.Weakness(Build()[0].Bosses[0], elements) is null);
    monsters[0].ElementId = [1];
    foreach (var row in rows.Where(p => p.DifficultyType == UnionRaidDifficultyType.Hard))
    { row.MonsterImage = "full_synthetic"; row.MonsterImageSi = "synthetic_si"; }
    var hints = UnionRaidCatalog.ImageHints(Build());
    Check(hints.Length == 5 && hints.All(h => h.SeasonNumber == 3 && h.MonsterImage == "full_synthetic"));
    Check(hints.Select(h => h.Order).SequenceEqual(Enumerable.Range(1, 5)));
    rows.Single(p => p.IsTrial).MonsterImage = "full_other";
    Check(UnionRaidCatalog.ImageHints(Build()).Length == 4 && Build()[0].FailureCode is null);
    rows[0].MonsterImage = null;
    Check(UnionRaidCatalog.ImageHints(Build()).All(h => h.Order is not (1 or 5)));
    waves[0].TargetList = [999]; Check(Build()[0].FailureCode == "boss_union_target_unresolved");
    waves[0].TargetList = [1];
    rows.RemoveAll(p => p.WaveOrder == 4); Check(Build()[0].FailureCode == "boss_union_five_bosses_unresolved");
    return new { contractId = "nll/union-raid-hard-synthetic-checks/v1", checksPassed = passed, nativeClientExecuted = false };
  }
}
