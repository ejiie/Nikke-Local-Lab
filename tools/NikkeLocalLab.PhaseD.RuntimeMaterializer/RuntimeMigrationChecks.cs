using EpinelPS.Models;
using Newtonsoft.Json;

internal static class RuntimeMigrationChecks
{
  internal static void Run()
  {
    var checks = 0;
    void Check(bool value) { if (!value) throw new InvalidOperationException("phase_d_runtime_migration_test_failed"); checks++; }
    const string previous = "2cfaa12b7d708aa6a741faee17c3ac14d8e9cd6be1b5e4e773ee1535b6ddaa30";
    const string current = "36fa20306d010087cdb336bbbb8a6718013d4a16838178045b1270af631b1732";
    Check(RuntimeVersionBinding.ExpectedArchive("build_150.6.9", previous).Length == 64);
    Check(RuntimeVersionBinding.ExpectedArchive("build_151.8.5", current).Length == 64);
    foreach (var pair in new[] { ("build_150.6.9", current), ("build_151.8.5", previous), ("build_unknown", current) })
    {
      var rejected = false;
      try { RuntimeVersionBinding.ExpectedArchive(pair.Item1, pair.Item2); }
      catch (InvalidOperationException) { rejected = true; }
      Check(rejected);
    }
    var user = new User { LastNormalStageCleared = 123, LastStoryStageCleared = 122, CompletedScenarios = ["synthetic-completed"] };
    var before = RuntimeProgressionSnapshot.Capture(user);
    var roundTrip = JsonConvert.DeserializeObject<User>(JsonConvert.SerializeObject(user))!;
    Check(RuntimeProgressionSnapshot.Capture(roundTrip) == before);
    roundTrip.SynchroDeviceLevel = 400;
    Check(RuntimeProgressionSnapshot.Capture(roundTrip) == before);
    roundTrip.CompletedScenarios.Clear();
    Check(RuntimeProgressionSnapshot.Capture(roundTrip) != before);
    var source = new SoloRaidInfo { TrialCount = 2, RaidOpenCount = 1, LastDateDay = 123 };
    source.SoloRaidLevels.Add(new SoloRaidLevelData { IsOpen = false, IsClear = true, RaidJoinCount = 5, TotalDamage = 400 });
    source.SoloRaidLevels.Add(new SoloRaidLevelData { IsOpen = true, RaidJoinCount = 3, TotalDamage = 300 });
    var copy = JsonConvert.DeserializeObject<SoloRaidInfo>(JsonConvert.SerializeObject(source))!;
    RuntimeCompletedRaidMigration.KeepCompletedOnly(copy);
    Check(copy.SoloRaidLevels.Count == 1);
    Check(copy.SoloRaidLevels[0].TotalDamage == 400 && copy.SoloRaidLevels[0].RaidJoinCount == 5);
    Check(copy.TrialCount == 0 && copy.RaidOpenCount == 0 && copy.LastDateDay == 0);
    Check(source.SoloRaidLevels.Count == 2 && source.TrialCount == 2);
    Console.WriteLine(System.Text.Json.JsonSerializer.Serialize(new { status = "passed", checks, syntheticOnly = true, databaseChanged = false }));
  }
}
