using System.Security.Cryptography;
using System.Text;
using EpinelPS;
using EpinelPS.Models;
using Newtonsoft.Json;

internal sealed record LocalTeamSlot(int Slot, int ValueType, string? CharacterUid);
internal sealed record LocalTeam(int Number, LocalTeamSlot[] Slots);
internal sealed record LocalTeams(int LastSelected, LocalTeam[] Teams);
internal sealed record RuntimePreferencesPayload(
    string ContractId,
    LocalTeams? SoloRaidTeams,
    SortedDictionary<string, int> Costumes,
    SortedDictionary<int, UnlockData> UnlockAnimations,
    NetWallpaperData[] Wallpapers,
    NetWallpaperBackground[] Backgrounds,
    JukeBoxSetting LobbyMusic,
    JukeBoxSetting CommanderMusic,
    int ProfileIconId, bool ProfileIconIsPrism, int ProfileFrame, int TitleId,
    ProfileCardDecorationLayout CardLayout,
    string[] DismissedBadges);

internal static class RuntimePreferencesProjection
{
  internal const string ContractId = "nll/runtime-preferences/v1";
  private const int SoloRaidTeamType = (int)EpinelPS.Data.TeamType.SoloRaid;

  internal static RuntimePreferencesPayload Capture(User user)
  {
    var binding = user.LocalPersistenceBinding ?? throw new InvalidOperationException("phase_d_preferences_binding_missing");
    LocalTeams? teams = null;
    if (user.UserTeams.TryGetValue(SoloRaidTeamType, out var source))
    {
      teams = new LocalTeams(source.LastContentsTeamNumber, source.Teams.OrderBy(team => team.TeamNumber)
          .Select(team => new LocalTeam(team.TeamNumber, team.Slots.OrderBy(slot => slot.Slot).Select(slot =>
          {
            string? uid = null;
            Require(slot.Value >= 0 && slot.ValueType == 0, "phase_d_preferences_team_reference_unsupported");
            if (slot.Value != 0)
              Require(binding.CharacterUidByCsn.TryGetValue(slot.Value, out uid), "phase_d_preferences_character_unresolved");
            return new LocalTeamSlot(slot.Slot, slot.ValueType, uid);
          }).ToArray())).ToArray());
    }
    var costumes = new SortedDictionary<string, int>(StringComparer.Ordinal);
    foreach (var character in user.Characters)
    {
      // Non-roster seed characters are not assigned guessed local identities.
      if (binding.CharacterUidByCsn.TryGetValue(character.Csn, out var uid)) costumes.Add(uid, character.CostumeId);
    }
    var visible = user.Badges.Select(BadgeFingerprint).ToHashSet(StringComparer.Ordinal);
    var dismissed = binding.DismissedBadgeFingerprints.Concat(binding.BaselineBadgeFingerprints.Where(value => !visible.Contains(value)))
        .Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal).ToArray();
    var result = new RuntimePreferencesPayload(ContractId, teams, costumes,
        new SortedDictionary<int, UnlockData>(user.ContentsOpenUnlocked),
        user.WallpaperList.OrderBy(item => item.Order).Select(item => item.Clone()).ToArray(),
        user.WallpaperBackground.OrderBy(item => item.Order).Select(item => item.Clone()).ToArray(),
        Clone(user.LobbyMusic), Clone(user.CommanderMusic), user.ProfileIconId, user.ProfileIconIsPrism,
        user.ProfileFrame, user.TitleId, user.ProfileCardDecoration.Clone(), dismissed);
    Validate(result);
    return Clone(result);
  }

  internal static void Restore(User user, RuntimePreferencesPayload payload, IReadOnlyDictionary<long, string> characterUids)
  {
    Validate(payload);
    var current = characterUids.ToDictionary(pair => pair.Value, pair => pair.Key, StringComparer.Ordinal);
    // Resolve everything before mutating: missing characters must not silently erase slots/costumes.
    foreach (var uid in payload.Costumes.Keys.Concat(payload.SoloRaidTeams?.Teams.SelectMany(team => team.Slots)
        .Where(slot => slot.CharacterUid is not null).Select(slot => slot.CharacterUid!) ?? []))
      Require(current.ContainsKey(uid), "phase_d_preferences_character_unresolved");
    if (payload.SoloRaidTeams is null) user.UserTeams.Remove(SoloRaidTeamType);
    else
    {
      var teams = new NetUserTeamData { Type = SoloRaidTeamType, LastContentsTeamNumber = payload.SoloRaidTeams.LastSelected };
      foreach (var team in payload.SoloRaidTeams.Teams)
      {
        var mapped = new NetTeamData { TeamNumber = team.Number };
        mapped.Slots.AddRange(team.Slots.Select(slot => new NetTeamSlot
        {
          Slot = slot.Slot, ValueType = slot.ValueType, Value = slot.CharacterUid is null ? 0 : current[slot.CharacterUid],
        }));
        teams.Teams.Add(mapped);
      }
      user.UserTeams[SoloRaidTeamType] = teams;
    }
    foreach (var pair in payload.Costumes)
      user.Characters.Single(character => character.Csn == current[pair.Key]).CostumeId = pair.Value;
    foreach (var pair in payload.UnlockAnimations)
    {
      if (!user.ContentsOpenUnlocked.TryGetValue(pair.Key, out var animation))
        user.ContentsOpenUnlocked[pair.Key] = animation = new UnlockData();
      animation.ButtonAnimationPlayed |= pair.Value.ButtonAnimationPlayed;
      animation.PopupAnimationPlayed |= pair.Value.PopupAnimationPlayed;
    }
    user.WallpaperList = payload.Wallpapers.Select(item => item.Clone()).ToArray();
    user.WallpaperBackground = payload.Backgrounds.Select(item => item.Clone()).ToArray();
    user.LobbyMusic = Clone(payload.LobbyMusic);
    user.CommanderMusic = Clone(payload.CommanderMusic);
    user.ProfileIconId = payload.ProfileIconId;
    user.ProfileIconIsPrism = payload.ProfileIconIsPrism;
    user.ProfileFrame = payload.ProfileFrame;
    user.TitleId = payload.TitleId;
    user.ProfileCardDecoration = payload.CardLayout.Clone();
    var dismissed = payload.DismissedBadges.ToHashSet(StringComparer.Ordinal);
    user.Badges.RemoveAll(badge => dismissed.Contains(BadgeFingerprint(badge)));
  }

  internal static string BadgeFingerprint(BadgeModel badge) => Convert.ToHexStringLower(SHA256.HashData(
      Encoding.UTF8.GetBytes(JsonConvert.SerializeObject(new { badge.BadgeGuid, badge.Seq, badge.BadgeContent, badge.Location }))));

  internal static void Validate(RuntimePreferencesPayload payload)
  {
    Require(payload.ContractId == ContractId && payload.ProfileIconId >= 0 && payload.ProfileFrame >= 0 && payload.TitleId >= 0,
        "phase_d_preferences_payload_invalid");
    Require(payload.Costumes.All(pair => Guid.TryParse(pair.Key, out var uid) && uid != Guid.Empty && pair.Value >= 0) &&
        payload.DismissedBadges.All(value => value.Length == 64 && value.All(character => character is >= '0' and <= '9' or >= 'a' and <= 'f')) &&
        payload.DismissedBadges.Distinct(StringComparer.Ordinal).Count() == payload.DismissedBadges.Length,
        "phase_d_preferences_payload_invalid");
    Require(payload.LobbyMusic.Location == NetJukeboxLocation.Lobby && payload.CommanderMusic.Location == NetJukeboxLocation.CommanderRoom,
        "phase_d_preferences_music_location_invalid");
    if (payload.SoloRaidTeams is not { } teams) return;
    Require(teams.LastSelected is >= 1 and <= 5 && teams.Teams.Length <= 5 &&
        teams.Teams.Select(team => team.Number).Distinct().Count() == teams.Teams.Length,
        "phase_d_preferences_teams_invalid");
    foreach (var team in teams.Teams)
    {
      Require(team.Number is >= 1 and <= 5 && team.Slots.Length <= 5 &&
          team.Slots.Select(slot => slot.Slot).Distinct().Count() == team.Slots.Length &&
          team.Slots.All(slot => slot.Slot is >= 1 and <= 5 && slot.ValueType == 0 &&
              (slot.CharacterUid is null || Guid.TryParse(slot.CharacterUid, out var uid) && uid != Guid.Empty)),
          "phase_d_preferences_teams_invalid");
    }
  }

  private static T Clone<T>(T source) => JsonConvert.DeserializeObject<T>(JsonConvert.SerializeObject(source))
      ?? throw new InvalidOperationException("phase_d_preferences_clone_invalid");
  private static void Require(bool condition, string code)
  {
    if (!condition) throw new InvalidOperationException(code);
  }
}
