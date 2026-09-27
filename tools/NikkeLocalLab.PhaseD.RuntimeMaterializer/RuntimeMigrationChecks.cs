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
    const string updated = "9c50d1e5e2312783b7ae908237081ff2976e06dcb0d90ae1d59f563afc5c73ef";
    Check(RuntimeVersionBinding.ExpectedArchive("build_152.8.11", updated) ==
        "42611495f81734528e8d9f3b4286ed2f8531ad0d75be087a1fb8ef39f9c32367");
    foreach (var pair in new[] { ("build_150.6.9", current), ("build_151.8.5", previous),
        ("build_152.8.11", current), ("build_151.8.5", updated), ("build_unknown", current) })
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
    Console.WriteLine(System.Text.Json.JsonSerializer.Serialize(new { status = "passed", checks, syntheticOnly = true, databaseChanged = false }));
  }
}
