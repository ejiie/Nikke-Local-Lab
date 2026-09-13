using EpinelPS.Data;

internal static class BossSeasonCatalogChecks
{
  internal static object Verify()
  {
    var passed = 0;
    void Check(bool condition) { if (!condition) throw new InvalidOperationException("phase_d_boss_catalog_synthetic_failed"); passed++; }
    var managers = new[] { new SoloRaidManagerRecord { RankingGroupId = 1, MonsterPreset = 100 },
      new SoloRaidManagerRecord { RankingGroupId = 3, MonsterPreset = 300 } };
    var presets = new[] { new SoloRaidPresetRecord { PresetGroupId = 100, DifficultyType = (DifficultyType)2, WaveOrder = 8, Wave = 10 },
      new SoloRaidPresetRecord { PresetGroupId = 300, DifficultyType = (DifficultyType)2, WaveOrder = 8, Wave = 30 } };
    var waves = new[] { new WaveDataRecord { StageId = 10, TargetList = [1], WaveData = [new WaveData { WaveMonsterList = [new WaveMonsterData { WaveMonsterId = 1 }] }] },
      new WaveDataRecord { StageId = 30, TargetList = [2], WaveData = [new WaveData { WaveMonsterList = [new WaveMonsterData { WaveMonsterId = 2 }] }] } };
    var monsters = new[] { new MonsterRecord { Id = 1, NameLocalkey = "synthetic_boss", ElementId = [11] },
      new MonsterRecord { Id = 2, NameLocalkey = "synthetic_boss", ElementId = [13] } };
    var elements = new[] { new ElementRecord { Id = 11, Element = AttackType.Fire, WeakElementId = 12 },
      new ElementRecord { Id = 12, Element = AttackType.Water, WeakElementId = 13 },
      new ElementRecord { Id = 13, Element = AttackType.Wind, WeakElementId = 11 } };
    var names = new Dictionary<string, string> { ["Locale_System:synthetic_boss"] = "합성 보스" };
    BossSeasonCatalog.Snapshot Run() => BossSeasonCatalog.Build(managers, presets, waves, monsters, elements, names);
    var result = Run();
    Check(result.MaximumKnownSeason == 3 && result.Seasons.Length == 3);
    Check(result.Seasons[1].DiscoveryStatusCode == "unresolved" && result.Seasons[1].DefaultWeaknessCode is null);
    Check(result.Seasons[0].DisplayName == "합성 보스" && result.Seasons[2].DisplayName == "합성 보스");
    Check(result.Seasons[0].DefaultWeaknessCode == "water" && result.Seasons[2].DefaultWeaknessCode == "fire");
    Check(result.Images.Length == 2 && result.Seasons.All(row => row.ImageStatusCode == "unresolved"));
    names.Clear();
    Check(Run().Seasons[0].DisplayName is null && Run().Seasons[0].NameStatusCode == "unresolved");
    names["Locale_System:synthetic_boss"] = "invalid\nname";
    Check(Run().Seasons[0].DisplayName is null);
    names["Locale_System:synthetic_boss"] = new string('a', 161);
    Check(Run().Seasons[0].DisplayName is null);
    monsters[0].ElementId = [11, 12];
    Check(Run().Seasons[0].FailureCode == "phase_d_boss_catalog_affinity_unresolved");
    monsters[0].ElementId = [11];
    waves[0].TargetList = [999];
    Check(Run().Seasons[0].FailureCode == "phase_d_boss_catalog_target_unresolved");
    waves[0].TargetList = [1, 1];
    Check(Run().Seasons[0].DiscoveryStatusCode == "resolved");
    presets[0].DifficultyType = (DifficultyType)1;
    Check(Run().Seasons[0].FailureCode == "phase_d_boss_catalog_challenge_preset_unresolved");
    presets[0].DifficultyType = (DifficultyType)2;
    presets[0].WaveOrder = 7;
    Check(Run().Seasons[0].FailureCode == "phase_d_boss_catalog_challenge_preset_unresolved");
    presets[0].WaveOrder = 8;
    managers = [managers[0], managers[0], managers[1]];
    Check(Run().Seasons[0].FailureCode == "phase_d_boss_catalog_manager_unresolved");
    managers = [new SoloRaidManagerRecord { RankingGroupId = 1001 }];
    var rejected = false;
    try { Run(); } catch (InvalidOperationException error) { rejected = error.Message == "phase_d_boss_catalog_season_range_invalid"; }
    Check(rejected);
    managers = [];
    rejected = false;
    try { Run(); } catch (InvalidOperationException error) { rejected = error.Message == "phase_d_boss_catalog_season_range_invalid"; }
    Check(rejected);
    return new { contractId = "nll/boss-season-catalog-synthetic-check/v1", passed, failed = 0,
      syntheticOnly = true, nativeClientExecuted = false, localGameDataRead = false };
  }
}
