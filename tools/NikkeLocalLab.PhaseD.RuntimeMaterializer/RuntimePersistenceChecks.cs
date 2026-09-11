using EpinelPS;
using EpinelPS.Models;
using Newtonsoft.Json;
using NikkeLocalLab.Persistence.PostgreSql;
using System.Security.Cryptography;

internal static class RuntimePersistenceChecks
{
  internal static void Run()
  {
    var passed = 0;
    void Check(bool condition) { if (!condition) throw new InvalidOperationException("phase_d_persistence_check_failed_" + passed); passed++; }
    void Reject(Action action)
    {
      var failed = false;
      try { action(); } catch (InvalidOperationException) { failed = true; }
      Check(failed);
    }
    var account = Guid.NewGuid();
    var first = Guid.NewGuid().ToString("D");
    var second = Guid.NewGuid().ToString("D");
    var oldMap = new Dictionary<long, string> { [1] = first, [2] = second };
    var newMap = new Dictionary<long, string> { [101] = first, [202] = second };
    var deleted = new BadgeModel { Seq = 7, BadgeGuid = Guid.NewGuid().ToString("D"), Location = "synthetic", BadgeContent = (BadgeContents)1 };
    var visible = new BadgeModel { Seq = 8, BadgeGuid = Guid.NewGuid().ToString("D"), Location = "synthetic", BadgeContent = (BadgeContents)1 };
    var source = new User
    {
      Characters = [new CharacterModel { Csn = 1, CostumeId = 17 }, new CharacterModel { Csn = 2, CostumeId = 0 }],
      WallpaperList = [new NetWallpaperData { Order = 2, Type = 1, Id = 17 }],
      WallpaperBackground = [new NetWallpaperBackground { Order = 2, LobbyDecoBackgroundId = 33 }],
      ProfileIconId = 401, ProfileIconIsPrism = true, ProfileFrame = 5, TitleId = 9,
      ProfileCardDecoration = new ProfileCardDecorationLayout { BackgroundId = 11, ShowCharacterSpine = true },
      Badges = [visible],
      LocalPersistenceBinding = new LocalRuntimePersistenceBinding
      {
        AccountUid = account, ProfileRevisionSha256 = new string('a',64), SelectedWeaknessCode = "iron",
        CharacterUidByCsn = oldMap,
        BaselineBadgeFingerprints = [RuntimePreferencesProjection.BadgeFingerprint(deleted), RuntimePreferencesProjection.BadgeFingerprint(visible)],
      },
    };
    source.LobbyMusic.TableId = 101;
    source.CommanderMusic.TableId = 202;
    source.ContentsOpenUnlocked.Add(123, new UnlockData(true, false));
    source.ContentsOpenUnlocked.Add(124, new UnlockData(false, true));
    var teams = new NetUserTeamData { Type = (int)EpinelPS.Data.TeamType.SoloRaid, LastContentsTeamNumber = 3 };
    for (var number = 5; number >= 1; number--)
    {
      var team = new NetTeamData { TeamNumber = number };
      team.Slots.Add(new NetTeamSlot { Slot = 3, Value = 2 });
      team.Slots.Add(new NetTeamSlot { Slot = 1, Value = 1 });
      team.Slots.Add(new NetTeamSlot { Slot = 2, Value = 0 });
      teams.Teams.Add(team);
    }
    source.UserTeams.Add(teams.Type, teams);
    source = Clone(source); // This is the actual Epinel User DB serialization path.
    var payload = Clone(RuntimePreferencesProjection.Capture(source));
    Check(payload.SoloRaidTeams!.Teams.Length == 5 && payload.SoloRaidTeams.LastSelected == 3);
    Check(payload.SoloRaidTeams.Teams.Select(team => team.Number).SequenceEqual(new[] {1,2,3,4,5}));
    Check(payload.SoloRaidTeams.Teams.All(team => team.Slots[1].CharacterUid is null));
    Check(payload.DismissedBadges.SequenceEqual(new[] {RuntimePreferencesProjection.BadgeFingerprint(deleted)}));
    var serialized = JsonConvert.SerializeObject(payload);
    Check(!serialized.Contains("Password") && !serialized.Contains("StageClear") && !serialized.Contains("WallpaperFavorite"));
    var newBadge = Clone(deleted);
    newBadge.BadgeGuid = Guid.NewGuid().ToString("D"); // Same sequence/content is still a new event.
    var target = new User
    {
      Characters = [new CharacterModel { Csn = 101, CostumeId = 0 }, new CharacterModel { Csn = 202, CostumeId = 44 }],
      Badges = [Clone(deleted), Clone(visible), newBadge], LiveWallpaperList = [77],
      LastNormalStageCleared = 111, CompletedScenarios = ["synthetic-progress"],
    };
    target.ContentsOpenUnlocked.Add(125, new UnlockData(true, true));
    var run = new SoloRaidInfo { RaidId = 123 };
    run.SoloRaidLevels.Add(new SoloRaidLevelData { IsOpen = true, RaidJoinCount = 1, Logs =
        [new SoloRaidLogData { Damage = 61, Team = [new TeamCharacterData { Csn = 1, CostumeId = 0 }] }] });
    target.SoloRaidData.Add(123, run);
    var historic = JsonConvert.SerializeObject(target.SoloRaidData);
    var progression = RuntimeProgressionSnapshot.Capture(target);
    RuntimePreferencesProjection.Restore(target, payload, newMap);
    target = Clone(target);
    Check(JsonConvert.SerializeObject(target.SoloRaidData) == historic);
    Check(RuntimeProgressionSnapshot.Capture(target) == progression);
    Check(target.UserTeams[teams.Type].LastContentsTeamNumber == 3);
    Check(target.UserTeams[teams.Type].Teams.All(team => team.Slots.Select(slot => slot.Value).SequenceEqual(new long[] {101,0,202})));
    Check(target.Characters[0].CostumeId == 17 && target.Characters[1].CostumeId == 0);
    Check(target.ContentsOpenUnlocked[123].ButtonAnimationPlayed && !target.ContentsOpenUnlocked[123].PopupAnimationPlayed);
    Check(!target.ContentsOpenUnlocked[124].ButtonAnimationPlayed && target.ContentsOpenUnlocked[124].PopupAnimationPlayed);
    Check(target.ContentsOpenUnlocked[125].ButtonAnimationPlayed && target.ContentsOpenUnlocked[125].PopupAnimationPlayed);
    Check(target.WallpaperList.Single().Id == 17 && target.WallpaperBackground.Single().LobbyDecoBackgroundId == 33);
    Check(target.LiveWallpaperList.SequenceEqual(new[] {77}));
    Check(target.LobbyMusic.TableId == 101 && target.CommanderMusic.TableId == 202);
    Check(target.ProfileIconId == 401 && target.ProfileIconIsPrism && target.ProfileFrame == 5 && target.TitleId == 9);
    Check(target.ProfileCardDecoration.BackgroundId == 11 && target.ProfileCardDecoration.ShowCharacterSpine);
    Check(target.Badges.Count == 2 && target.Badges.Any(badge => badge.BadgeGuid == newBadge.BadgeGuid));
    var before = JsonConvert.SerializeObject(target);
    Reject(() => RuntimePreferencesProjection.Restore(target, payload, new Dictionary<long, string> { [101] = first }));
    Check(JsonConvert.SerializeObject(target) == before);
    Reject(() => RuntimePreferencesProjection.Validate(payload with { SoloRaidTeams = payload.SoloRaidTeams with { LastSelected = 6 } }));
    var invalid = Clone(source);
    invalid.UserTeams[teams.Type].Teams[0].Slots[0].ValueType = 1;
    Reject(() => RuntimePreferencesProjection.Capture(invalid));
    var history = new SoloRaidInfo();
    var historyRun = new SoloRaidLevelData { RaidLevel = 8, Type = SoloRaidType.Trial, IsOpen = true, RaidJoinCount = 1 };
    ClassicSoloRaidBattleReceipt.Append(history, historyRun, new SoloRaidLogData { Damage = 61 });
    var nextHistory = Clone(history);
    ClassicSoloRaidBattleReceipt.Close(nextHistory, historyRun, "abandoned");
    ClassicBattleHistoryPolicy.RequireAppendOnly(history, nextHistory); Check(true);
    var tampered = Clone(nextHistory);
    tampered.BattleHistory[0].Log.Damage++;
    Reject(() => ClassicBattleHistoryPolicy.RequireAppendOnly(history, tampered));
    tampered = Clone(nextHistory); tampered.BattleHistory.Clear();
    Reject(() => ClassicBattleHistoryPolicy.RequireAppendOnly(history, tampered));
    Reject(() => ClassicBattleHistoryPolicy.RequireAppendOnly(nextHistory, history));
    var key = new RuntimePreferencesKey(account, "synthetic", SHA256.HashData("synthetic-client"u8));
    var secret = RandomNumberGenerator.GetBytes(32);
    try
    {
      var pending = RuntimePreferencesPersistence.Capture(source, key, new string('a',64), "iron", secret, Guid.NewGuid(), DateTimeOffset.UtcNow);
      Check(pending.ContentSha256.Length == 64 && pending.ProtectedPayloadSha256.Length == 64);
      Check(RuntimePreferencesPersistence.PendingHash(pending).Length == 64);
      Reject(() => RuntimePreferencesPersistence.Capture(source, key with { AccountUid = Guid.NewGuid() }, new string('a',64), "iron", secret, Guid.NewGuid(), DateTimeOffset.UtcNow));
      Reject(() => RuntimePreferencesPersistence.Capture(source, key, new string('a',64), "water", secret, Guid.NewGuid(), DateTimeOffset.UtcNow));
      Reject(() => RuntimePreferencesPersistence.Capture(source, key, new string('b',64), "iron", secret, Guid.NewGuid(), DateTimeOffset.UtcNow));
    }
    finally { CryptographicOperations.ZeroMemory(secret); }
    Console.WriteLine(System.Text.Json.JsonSerializer.Serialize(new { status = "passed", checks = passed, syntheticOnly = true,
        originalClientExecuted = false, operatingDatabaseTouched = false }));
  }

  private static T Clone<T>(T value) => JsonConvert.DeserializeObject<T>(JsonConvert.SerializeObject(value))!;
}
