using EpinelPS.Models;
using Newtonsoft.Json;

internal static class ClassicBattleHistoryPolicy
{
  internal static void RequireAppendOnly(SoloRaidInfo? previous, SoloRaidInfo? next)
  {
    if (previous is null || previous.BattleHistory.Count == 0) return;
    Require(next is not null && next.BattleHistory.Count >= previous.BattleHistory.Count);
    for (var index = 0; index < previous.BattleHistory.Count; index++)
    {
      var old = previous.BattleHistory[index];
      Require(JsonConvert.SerializeObject(old) == JsonConvert.SerializeObject(next!.BattleHistory[index]));
      Require(previous.BattleRunStatus.TryGetValue(old.RunUid, out var oldStatus) &&
          next.BattleRunStatus.TryGetValue(old.RunUid, out var newStatus) &&
          (oldStatus == newStatus || oldStatus == "open" && newStatus is "completed" or "abandoned"));
    }
  }

  private static void Require(bool condition)
  {
    if (!condition) throw new InvalidOperationException("phase_d_battle_history_regression");
  }
}
