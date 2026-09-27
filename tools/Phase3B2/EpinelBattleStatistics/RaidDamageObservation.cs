using EpinelPS.Models;

namespace EpinelPS.Database;

// Numeric observations only. Never serialize the protobuf, source IDs, report bytes or credentials.
public sealed record DamageTotals(long TotalDamage, long TotalActualDamage);
public sealed record MonsterDamageTotals(long TotalDamageReceived, long TotalActualDamageReceived,
    long TotalPartsDestroyDamageReceived, long TotalProjectileDamageReceived);
public sealed record CharacterDamageObservation(int Ordinal, int Slot, Guid? CharacterUid,
    int? Level, long? Combat, DamageTotals? Attack, DamageTotals? Skill, DamageTotals? StatFunctionAttack);
public sealed record MonsterDamageObservation(int Ordinal, MonsterDamageTotals? Hp);

public sealed class RaidDamageObservation
{
    public int SchemaVersion { get; set; } = 1;
    public Guid BattleUid { get; set; }
    public Guid AccountUid { get; set; }
    public Guid? RunUid { get; set; }
    public string Mode { get; set; } = "";
    public int Season { get; set; }
    public int RaidLevel { get; set; }
    public int BossStep { get; set; }
    public int Team { get; set; }
    public int? BattleResult { get; set; }
    public long RequestDamage { get; set; }
    public long AcceptedDamage { get; set; }
    public long? InitialHp { get; set; }
    public string ProfileRevisionSha256 { get; set; } = "";
    public string ClientBuild { get; set; } = "";
    public string Weakness { get; set; } = "";
    public DateTimeOffset AcceptedAtUtc { get; set; }
    public bool ReportPresent { get; set; }
    public int? BattleDuration { get; set; }
    public List<CharacterDamageObservation> Characters { get; set; } = [];
    public List<MonsterDamageObservation> Monsters { get; set; } = [];
    [Newtonsoft.Json.JsonProperty(NullValueHandling = Newtonsoft.Json.NullValueHandling.Ignore)]
    public NikkeLocalLab.BattleLog.ProjectileAnalysis? ProjectileAnalysis { get; set; }

    public static RaidDamageObservation Capture(User user, NetAntiCheatBattleData? report, Guid battleUid,
        string mode, int season, int level, int step, int team, long requestDamage, long acceptedDamage,
        DateTimeOffset at, Guid? runUid = null, int? battleResult = null, long? initialHp = null)
    {
        var binding = user.LocalPersistenceBinding;
        var result = new RaidDamageObservation
        {
            BattleUid = battleUid, AccountUid = binding?.AccountUid ?? Guid.Empty, RunUid = runUid,
            Mode = mode, Season = season, RaidLevel = level, BossStep = step, Team = team,
            RequestDamage = requestDamage, AcceptedDamage = acceptedDamage, AcceptedAtUtc = at,
            BattleResult = battleResult, InitialHp = initialHp, ReportPresent = report is not null,
            BattleDuration = report?.BattleDuration, ProfileRevisionSha256 = binding?.ProfileRevisionSha256 ?? "",
            Weakness = binding?.SelectedWeaknessCode ?? "", ClientBuild = binding?.DamageCaptureClientBuild ?? "",
        };
        BattleLogDiagnostics.TryCapture(report, result);
        if (report is null) return result;
        foreach (var c in report.Characters)
        {
            Guid? uid = binding is not null && binding.CharacterUidByCsn.TryGetValue(c.Csn, out var value)
                && Guid.TryParse(value, out var resolved) ? resolved : null;
            result.Characters.Add(new(result.Characters.Count + 1, c.Slot, uid, c.CharacterSpec?.Level,
                c.CharacterSpec?.Combat,
                c.Attack is null ? null : new(c.Attack.TotalDamage, c.Attack.TotalActualDamage),
                c.Skill is null ? null : new(c.Skill.TotalDamage, c.Skill.TotalActualDamage),
                c.StatFunctionAttack is null ? null : new(c.StatFunctionAttack.TotalDamage, c.StatFunctionAttack.TotalActualDamage)));
        }
        foreach (var m in report.Monsters)
            result.Monsters.Add(new(result.Monsters.Count + 1, m.Hp is null ? null :
                new(m.Hp.TotalDamageReceived, m.Hp.TotalActualDamageReceived,
                    m.Hp.TotalPartsDestroyDamageReceived, m.Hp.TotalProjectileDamageReceived)));
        if (result.AccountUid != Guid.Empty)
        {
            var identities = report.Characters.Select((c, i) => new NikkeLocalLab.BattleLog.BattleLogCharacter(
                i + 1, c.Tid, c.Attack?.TotalDamage)).ToArray();
            try
            {
                long? total = result.Monsters.Count > 0 && result.Monsters.All(m => m.Hp is not null)
                    ? result.Monsters.Sum(m => m.Hp!.TotalProjectileDamageReceived) : null;
                result.ProjectileAnalysis = NikkeLocalLab.BattleLog.BattleLogProjectileDecoder.Analyze(
                    report.BattleLog.ToByteArray(), identities, total);
                BattleLogArchive.Save(report.BattleLog.ToByteArray(), result, identities);
            }
            catch (Exception) { Console.WriteLine("NLL_BATTLE_ANALYSIS_FAILED/v1"); }
        }
        return result;
    }
}
