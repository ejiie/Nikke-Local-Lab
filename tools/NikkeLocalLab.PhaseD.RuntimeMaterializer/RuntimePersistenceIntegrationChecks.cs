using EpinelPS;
using EpinelPS.Models;
using EpinelPS.LobbyServer.Soloraid;
using Newtonsoft.Json;
using NikkeLocalLab.Persistence.PostgreSql;
using Npgsql;
using System.Security.Cryptography;

// Explicit local-only integration gate; the caller provisions the synthetic account/catalog.
internal static class RuntimePersistenceIntegrationChecks
{
  internal static async Task RunAsync(IReadOnlyDictionary<string,string> input)
  {
    var connection = Environment.GetEnvironmentVariable("NIKKE_LAB_TEST_DB") ?? "";
    var parsed = new NpgsqlConnectionStringBuilder(connection);
    if (parsed.Host != "127.0.0.1" || parsed.Port != 55432 || parsed.Database != "nikke_local_lab_lifecycle_test" ||
        Environment.GetEnvironmentVariable("NIKKE_LAB_TEST_RESET_TOKEN") != "allow-phase1a-disposable-schema-reset")
      throw new InvalidOperationException("phase_d_persistence_disposable_database_required");
    var account = Guid.Parse(input["account-uid"]);
    var profile = input["account-revision-set-sha256"];
    var secret = RandomNumberGenerator.GetBytes(32);
    Environment.SetEnvironmentVariable("NLL_SYNTHETIC_PERSISTENCE_SECRET", Convert.ToBase64String(secret));
    var root = Path.Combine(Path.GetTempPath(), "nll-persistence-roundtrip-" + Guid.NewGuid().ToString("N"));
    Directory.CreateDirectory(root);
    var savedOutput = Console.Out;
    var checks = 0;
    void Check(bool value) { if (!value) throw new InvalidOperationException("phase_d_persistence_integration_failed_" + checks); checks++; }
    var options = new Dictionary<string,string>(input)
    {
      ["connection-string-env"] = "NIKKE_LAB_TEST_DB", ["identity-secret-env"] = "NLL_SYNTHETIC_PERSISTENCE_SECRET",
      ["weakness-code"] = "iron", ["expected-head-revision-uid"] = "none",
    };
    var operational = new ClassicSoloRaidRuntimeOperationalBinding(account, 26,
        Guid.Parse(input["raid-snapshot-uid"]), Convert.FromHexString(input["raid-snapshot-sha256"]));
    var preferencesKey = new RuntimePreferencesKey(account, input["client-build-code"], Convert.FromHexString(input["client-executable-sha256"]));
    var raidKey = new ClassicSoloRaidRuntimeStateKey(account, 26, operational.RaidSnapshotUid, operational.RaidSnapshotSha256,
        preferencesKey.ClientBuildCode, preferencesKey.ClientExecutableSha256, "iron");
    var characterUid = Guid.NewGuid().ToString("D");
    await using var source = NpgsqlDataSource.Create(connection);
    User UserWithCsn(int csn) => new()
    {
      SelectedClassicSoloRaidManagerId = 123,
      Characters = [new CharacterModel { Csn = csn, CostumeId = 17 }],
      SoloRaidData = new Dictionary<int,SoloRaidInfo> { [123] = new SoloRaidInfo { RaidId = 123 } },
    };
    async Task<ClassicSoloRaidRestoreProjection> Restore(User user, string weakness, int csn, string? changedProfile = null)
    {
      options["weakness-code"] = weakness;
      var selectedProfile = changedProfile ?? profile;
      await RuntimePreferencesPersistence.RestoreAsync(user, source, secret, preferencesKey, selectedProfile, weakness,
          new Dictionary<long,string> { [csn] = characterUid });
      return await ClassicSoloRaidRuntimeState.RestoreAsync(user, source, secret, options, account, operational, Convert.FromHexString(selectedProfile));
    }
    void Play(User user, params long[][] runs)
    {
      var raid = new SoloRaidInfo { RaidId = 123, LastDateDay = 1 };
      user.SoloRaidData[123] = raid;
      foreach (var damages in runs)
      {
        raid.TrialCount++;
        raid.SoloRaidLevels.Add(new SoloRaidLevelData { RaidLevel = 8, Type = SoloRaidType.Trial, IsOpen = true, Hp = 1000 });
        foreach (var damage in damages)
        {
          var response = new ResSetSoloRaidTrialDamage();
          Check(SoloRaidHelper.SetDamageTrial(user, ref response, new ReqSetSoloRaidTrialDamage
          {
            RaidLevel = 8, Damage = damage, AntiCheatBattleData = new NetAntiCheatBattleData(),
          }, 123));
        }
      }
      if (raid.SoloRaidLevels.Any(level => level.IsOpen)) Check(SoloRaidHelper.CloseSoloRaid(user,123,8,SoloRaidType.Trial));
    }
    async Task<Dictionary<string,string>> Capture(User user, Guid? head, string name)
    {
      var captureOptions = new Dictionary<string,string>(options)
      {
        ["source-db"] = Path.Combine(root,name + ".source.json"),
        ["pending-payload"] = Path.Combine(root,name + ".pending.json"),
        ["receipt"] = Path.Combine(root,name + ".capture.json"),
        ["launch-context-uid"] = Guid.NewGuid().ToString("D"),
        ["expected-head-revision-uid"] = head?.ToString("D") ?? "none",
      };
      await File.WriteAllTextAsync(captureOptions["source-db"], JsonConvert.SerializeObject(new CoreInfo { Users = [user] }));
      await ClassicSoloRaidRuntimeState.CaptureAsync(captureOptions);
      captureOptions["capture-receipt"] = captureOptions["receipt"];
      captureOptions["receipt"] = Path.Combine(root,name + ".persist.json");
      Check(File.Exists(captureOptions["pending-payload"]));
      return captureOptions;
    }
    try
    {
      using var output = new StringWriter();
      Console.SetOut(output); // Never emit synthetic payloads, private envelopes or database details.
      var iron = UserWithCsn(1);
      var empty = await Restore(iron,"iron",1);
      Check(!empty.StateAvailable && iron.SoloRaidData.Count == 0);
      var team = new NetUserTeamData { Type = (int)EpinelPS.Data.TeamType.SoloRaid, LastContentsTeamNumber = 2 };
      var deck = new NetTeamData { TeamNumber = 2 };
      deck.Slots.Add(new NetTeamSlot { Slot = 1, Value = 1 }); team.Teams.Add(deck); iron.UserTeams.Add(team.Type,team);
      Play(iron, [20,30,50,10,15], [25,35,55,15,20], [15,25,45,5,10], [61]);
      var first = await Capture(iron,null,"iron");
      await ClassicSoloRaidRuntimeState.PersistAsync(first);
      await ClassicSoloRaidRuntimeState.PersistAsync(first);
      var receipt = Newtonsoft.Json.Linq.JObject.Parse(await File.ReadAllTextAsync(first["receipt"]));
      Check((bool)receipt["exactReplay"]! && (bool)receipt["preferencesExactReplay"]!);
      var restored = UserWithCsn(101);
      var projection = await Restore(restored,"iron",101);
      Check(projection.CompletedBestTotalDamage == 150 && restored.SoloRaidData[123].BattleHistory.Count == 16);
      Check(restored.UserTeams[team.Type].Teams.Single().Slots.Single().Value == 101);
      var logs = new ResGetSoloRaidLogs();
      SoloRaidHelper.GetSoloRaidLog(restored,ref logs,123,8);
      Check(logs.Logs.Count == 16 && logs.Logs[0].Damage == 61);
      var water = UserWithCsn(202);
      var waterBefore = await Restore(water,"water",202);
      Check(!waterBefore.StateAvailable && water.SoloRaidData.Count == 0);
      Check(water.UserTeams[team.Type].Teams.Single().Slots.Single().Value == 202 && water.Characters.Single().CostumeId == 17);
      water.Characters.Single().CostumeId = 99;
      Play(water,[15,25,45,5,10]);
      var waterCapture = await Capture(water,null,"water");
      await ClassicSoloRaidRuntimeState.PersistAsync(waterCapture);
      var ironAgain = UserWithCsn(303);
      var ironRestored = await Restore(ironAgain,"iron",303);
      Check(ironRestored.CompletedBestTotalDamage == 150 && ironAgain.Characters.Single().CostumeId == 99);
      var waterAgain = UserWithCsn(404);
      var waterRestored = await Restore(waterAgain,"water",404);
      Check(waterRestored.CompletedBestTotalDamage == 100 && waterAgain.SoloRaidData[123].BattleHistory.Count == 5);
      var raidStore = new ClassicSoloRaidRuntimeStateStore(source);
      Check((await raidStore.GetHeadAsync(raidKey))!.RevisionNumber == 1);
      Check((await new RuntimePreferencesStore(source).GetHeadAsync(preferencesKey))!.RevisionNumber == 2);
      // Saving a profile after the 05:00 reset releases an open run without
      // underflowing its now-zero daily counter or deleting accepted decks.
      options["weakness-code"] = "iron";
      ironAgain.SoloRaidData[123].TrialCount = 0;
      ironAgain.SoloRaidData[123].SoloRaidLevels.Add(new SoloRaidLevelData { RaidLevel = 8, Type = SoloRaidType.Trial, IsOpen = true, Hp = 1000 });
      var partialResponse = new ResSetSoloRaidTrialDamage();
      Check(SoloRaidHelper.SetDamageTrial(ironAgain,ref partialResponse,new ReqSetSoloRaidTrialDamage
      {
        RaidLevel = 8, Damage = 62, AntiCheatBattleData = new NetAntiCheatBattleData(),
      },123));
      var partialCapture = await Capture(ironAgain,ironRestored.HeadRevisionUid,"partial-after-reset");
      await ClassicSoloRaidRuntimeState.PersistAsync(partialCapture);
      var changed = UserWithCsn(505);
      var changedProjection = await Restore(changed,"iron",505,new string('b',64));
      Check(changedProjection.OpenRunDiscardedForProfileRevisionMismatch && !changedProjection.OpenRunRestored);
      Check(changedProjection.CompletedBestTotalDamage == 150 && changed.SoloRaidData[123].BattleHistory.Count == 17);
      Check(changed.SoloRaidData[123].TrialCount == 0 && changed.SoloRaidData[123].BattleRunStatus.Values.Count(value => value == "abandoned") == 2);
      // A real encrypted capture cannot be moved into another selected weakness.
      options["weakness-code"] = "water";
      var failed = false;
      try { await Capture(ironAgain,ironRestored.HeadRevisionUid,"mismatched"); }
      catch (InvalidOperationException) { failed = true; }
      Check(failed && !File.Exists(Path.Combine(root,"mismatched.pending.json")));

      // Any future build continues the same authenticated history and daily state.
      // No known-version pair or completed-best prerequisite is involved.
      options["weakness-code"] = "iron";
      var initialHead = (await raidStore.GetHeadAsync(raidKey))!;
      var previousHistory = JsonConvert.SerializeObject(changed.SoloRaidData[123].BattleHistory);
      var expectedTrials = 0;
      var expectedCostume = 99;
      foreach (var build in new[] { "synthetic-future-a", "synthetic-future-b", preferencesKey.ClientBuildCode })
      {
        var exe = SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(build));
        options["client-build-code"] = build;
        options["client-executable-sha256"] = Convert.ToHexStringLower(exe);
        var target = UserWithCsn(707);
        var targetPreferences = new RuntimePreferencesKey(account, build, exe);
        await RuntimePreferencesPersistence.RestoreAsync(target, source, secret, targetPreferences, profile, "iron",
            new() { [707] = characterUid });
        var projectionAcrossVersion = await ClassicSoloRaidRuntimeState.RestoreAsync(target, source, secret,
            options, account, operational, Convert.FromHexString(profile));
        Check(projectionAcrossVersion.HeadRevisionUid == initialHead.RevisionUid);
        Check(projectionAcrossVersion.CompletedBestTotalDamage == 150 && !projectionAcrossVersion.OpenRunRestored);
        Check(target.SoloRaidData[123].TrialCount == expectedTrials && target.SoloRaidData[123].LastDateDay == 1);
        Check(JsonConvert.SerializeObject(target.SoloRaidData[123].BattleHistory) == previousHistory);
        Check(target.UserTeams[team.Type].Teams.Single().Slots.Single().Value == 707 && target.Characters.Single().CostumeId == expectedCostume);
        // One additional lobby abandonment must remain consumed across the next build.
        target.SoloRaidData[123].TrialCount = ++expectedTrials;
        target.Characters.Single().CostumeId = ++expectedCostume;
        var next = await Capture(target, initialHead.RevisionUid, build);
        await ClassicSoloRaidRuntimeState.PersistAsync(next);
        Check(!(bool)Newtonsoft.Json.Linq.JObject.Parse(await File.ReadAllTextAsync(next["receipt"]))["quarantined"]!);
        var nextHead = (await raidStore.GetHeadAsync(raidKey))!;
        Check(nextHead.ClientBuildCode == build && nextHead.RevisionNumber == initialHead.RevisionNumber + 1);
        // Every build reads the same logical head, including going back to an older build.
        Check((await raidStore.GetHeadAsync(raidKey with { ClientBuildCode = "unlisted-build" }))!.RevisionUid == nextHead.RevisionUid);
        var reloaded = UserWithCsn(708);
        var restoredAcrossVersion = await ClassicSoloRaidRuntimeState.RestoreAsync(reloaded, source, secret,
            options, account, operational, Convert.FromHexString(profile));
        Check(reloaded.SoloRaidData[123].TrialCount == expectedTrials && restoredAcrossVersion.HeadRevisionUid == nextHead.RevisionUid);
        initialHead = nextHead;
      }
      // A version without a completed run must still recover its consumed attempts.
      options["weakness-code"] = "wind";
      var noBest = UserWithCsn(709);
      var buildKey = new RuntimePreferencesKey(account, options["client-build-code"], Convert.FromHexString(options["client-executable-sha256"]));
      await RuntimePreferencesPersistence.RestoreAsync(noBest, source, secret, buildKey, profile, "wind", new() { [709] = characterUid });
      noBest.SoloRaidData[123].TrialCount = 3;
      noBest.SoloRaidData[123].LastDateDay = 42;
      var noBestCapture = await Capture(noBest, null, "no-best");
      await ClassicSoloRaidRuntimeState.PersistAsync(noBestCapture);
      options["client-build-code"] = "synthetic-next-unlisted";
      options["client-executable-sha256"] = new string('f',64);
      var nextNoBest = UserWithCsn(710);
      var noBestRestored = await ClassicSoloRaidRuntimeState.RestoreAsync(nextNoBest, source, secret, options,
          account, operational, Convert.FromHexString(profile));
      Check(noBestRestored.StateRestored && noBestRestored.CompletedBestTeamCount == 0);
      Check(nextNoBest.SoloRaidData[123].TrialCount == 3 && nextNoBest.SoloRaidData[123].LastDateDay == 42);
    }
    finally
    {
      Console.SetOut(savedOutput);
      Environment.SetEnvironmentVariable("NLL_SYNTHETIC_PERSISTENCE_SECRET", null);
      CryptographicOperations.ZeroMemory(secret);
      foreach (var path in Directory.EnumerateFiles(root)) File.Delete(path);
      Directory.Delete(root);
    }
    Console.WriteLine(System.Text.Json.JsonSerializer.Serialize(new { status = "passed", checks, syntheticOnly = true,
        actualCapturePersistRestore = true, originalClientExecuted = false, operatingDatabaseTouched = false }));
  }
}
