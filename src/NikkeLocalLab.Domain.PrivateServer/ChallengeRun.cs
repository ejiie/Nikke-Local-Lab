using System.Globalization;
using System.Numerics;
using NikkeLocalLab.Domain.Profile;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Domain.PrivateServer;

public readonly record struct NonNegativeIntegerDamage : IComparable<NonNegativeIntegerDamage>
{
  public const string ContractId = "nonnegative_integer_decimal/v1";
  public const int MaximumDigits = 78;

  private NonNegativeIntegerDamage(string canonicalDigits)
  {
    CanonicalDigits = canonicalDigits;
  }

  public string CanonicalDigits { get; }

  public static NonNegativeIntegerDamage Zero { get; } = new("0");

  public static NonNegativeIntegerDamage Parse(string value)
  {
    if (!TryParse(value, out var damage))
    {
      throw new PrivateServerIntegrityException("damage_observation_value_invalid");
    }

    return damage;
  }

  public static bool TryParse(string? value, out NonNegativeIntegerDamage damage)
  {
    damage = default;
    if (string.IsNullOrEmpty(value) || value.Length > MaximumDigits ||
        (value.Length > 1 && value[0] == '0') ||
        value.Any(static character => character is < '0' or > '9'))
    {
      return false;
    }

    damage = new NonNegativeIntegerDamage(value);
    return true;
  }

  public static NonNegativeIntegerDamage Add(
      NonNegativeIntegerDamage left,
      NonNegativeIntegerDamage right)
  {
    var sum = left.ToBigInteger() + right.ToBigInteger();
    var canonical = sum.ToString(CultureInfo.InvariantCulture);
    if (canonical.Length > MaximumDigits)
    {
      throw new PrivateServerIntegrityException("damage_observation_sum_exceeds_lab_limit");
    }

    return new NonNegativeIntegerDamage(canonical);
  }

  public BigInteger ToBigInteger()
  {
    if (!TryParse(CanonicalDigits, out _))
    {
      throw new PrivateServerIntegrityException("damage_observation_value_uninitialized");
    }

    return BigInteger.Parse(CanonicalDigits, NumberStyles.None, CultureInfo.InvariantCulture);
  }

  public int CompareTo(NonNegativeIntegerDamage other) =>
      ToBigInteger().CompareTo(other.ToBigInteger());

  public override string ToString() => CanonicalDigits ?? string.Empty;
}

public sealed class BattleFrameTelemetry
{
  public const string ContractId = "nll/battle-frame-telemetry/v1";

  public BattleFrameTelemetry(
      long renderFrameCount,
      long behaviorTickCount,
      long fixedUpdateCount,
      long wallClockMicroseconds,
      decimal frameTimeMedianMilliseconds,
      decimal frameTimeP95Milliseconds,
      decimal frameTimeP99Milliseconds,
      long droppedFrameCount,
      long stalledFrameCount,
      IEnumerable<string>? warningCodes = null)
  {
    if (renderFrameCount < 0 || behaviorTickCount < 0 || fixedUpdateCount < 0 ||
        wallClockMicroseconds < 0 || frameTimeMedianMilliseconds < 0 ||
        frameTimeP95Milliseconds < frameTimeMedianMilliseconds ||
        frameTimeP99Milliseconds < frameTimeP95Milliseconds ||
        droppedFrameCount < 0 || stalledFrameCount < 0)
    {
      throw new PrivateServerIntegrityException("battle_frame_telemetry_invalid");
    }

    _ = PrivateServerGuard.RequireStorageDecimal(
        frameTimeMedianMilliseconds,
        maximumIntegerDigits: 17,
        maximumScale: 3,
        errorCode: "battle_frame_time_storage_invalid");
    _ = PrivateServerGuard.RequireStorageDecimal(
        frameTimeP95Milliseconds,
        maximumIntegerDigits: 17,
        maximumScale: 3,
        errorCode: "battle_frame_time_storage_invalid");
    _ = PrivateServerGuard.RequireStorageDecimal(
        frameTimeP99Milliseconds,
        maximumIntegerDigits: 17,
        maximumScale: 3,
        errorCode: "battle_frame_time_storage_invalid");

    RenderFrameCount = renderFrameCount;
    BehaviorTickCount = behaviorTickCount;
    FixedUpdateCount = fixedUpdateCount;
    WallClockMicroseconds = wallClockMicroseconds;
    FrameTimeMedianMilliseconds = frameTimeMedianMilliseconds;
    FrameTimeP95Milliseconds = frameTimeP95Milliseconds;
    FrameTimeP99Milliseconds = frameTimeP99Milliseconds;
    DroppedFrameCount = droppedFrameCount;
    StalledFrameCount = stalledFrameCount;
    WarningCodes = PrivateServerGuard.NormalizeCodes(warningCodes, nameof(warningCodes));
    ContentSha256 = PrivateServerHash.Compute(ContractId, hash =>
    {
      PrivateServerHash.Append(hash, RenderFrameCount);
      PrivateServerHash.Append(hash, BehaviorTickCount);
      PrivateServerHash.Append(hash, FixedUpdateCount);
      PrivateServerHash.Append(hash, WallClockMicroseconds);
      PrivateServerHash.Append(hash, FrameTimeMedianMilliseconds);
      PrivateServerHash.Append(hash, FrameTimeP95Milliseconds);
      PrivateServerHash.Append(hash, FrameTimeP99Milliseconds);
      PrivateServerHash.Append(hash, DroppedFrameCount);
      PrivateServerHash.Append(hash, StalledFrameCount);
      foreach (var warningCode in WarningCodes)
      {
        PrivateServerHash.Append(hash, warningCode);
      }
    });
  }

  public long RenderFrameCount { get; }
  public long BehaviorTickCount { get; }
  public long FixedUpdateCount { get; }
  public long WallClockMicroseconds { get; }
  public decimal FrameTimeMedianMilliseconds { get; }
  public decimal FrameTimeP95Milliseconds { get; }
  public decimal FrameTimeP99Milliseconds { get; }
  public long DroppedFrameCount { get; }
  public long StalledFrameCount { get; }
  public IReadOnlyList<string> WarningCodes { get; }
  public Sha256Digest ContentSha256 { get; }
}

public sealed record ExecutionSegment
{
  public ExecutionSegment(
      int ordinal,
      EntityUid runtimeExecutionProfileRevisionUid,
      EntityUid combatControlProfileRevisionUid,
      long startRenderFrame,
      long endRenderFrame,
      long startBehaviorTick,
      long endBehaviorTick,
      long startFixedUpdate,
      long endFixedUpdate,
      long startWallClockMicroseconds,
      long endWallClockMicroseconds,
      NonNegativeIntegerDamage startDamage,
      NonNegativeIntegerDamage endDamage)
  {
    if (ordinal < 1 || startRenderFrame < 0 || endRenderFrame < startRenderFrame ||
        startBehaviorTick < 0 || endBehaviorTick < startBehaviorTick ||
        startFixedUpdate < 0 || endFixedUpdate < startFixedUpdate ||
        startWallClockMicroseconds < 0 || endWallClockMicroseconds < startWallClockMicroseconds ||
        endDamage.CompareTo(startDamage) < 0)
    {
      throw new PrivateServerIntegrityException("execution_segment_shape_invalid");
    }

    Ordinal = ordinal;
    RuntimeExecutionProfileRevisionUid = PrivateServerGuard.RequireUid(
        runtimeExecutionProfileRevisionUid,
        nameof(runtimeExecutionProfileRevisionUid));
    CombatControlProfileRevisionUid = PrivateServerGuard.RequireUid(
        combatControlProfileRevisionUid,
        nameof(combatControlProfileRevisionUid));
    StartRenderFrame = startRenderFrame;
    EndRenderFrame = endRenderFrame;
    StartBehaviorTick = startBehaviorTick;
    EndBehaviorTick = endBehaviorTick;
    StartFixedUpdate = startFixedUpdate;
    EndFixedUpdate = endFixedUpdate;
    StartWallClockMicroseconds = startWallClockMicroseconds;
    EndWallClockMicroseconds = endWallClockMicroseconds;
    StartDamage = startDamage;
    EndDamage = endDamage;
  }

  public int Ordinal { get; }
  public EntityUid RuntimeExecutionProfileRevisionUid { get; }
  public EntityUid CombatControlProfileRevisionUid { get; }
  public long StartRenderFrame { get; }
  public long EndRenderFrame { get; }
  public long StartBehaviorTick { get; }
  public long EndBehaviorTick { get; }
  public long StartFixedUpdate { get; }
  public long EndFixedUpdate { get; }
  public long StartWallClockMicroseconds { get; }
  public long EndWallClockMicroseconds { get; }
  public NonNegativeIntegerDamage StartDamage { get; }
  public NonNegativeIntegerDamage EndDamage { get; }
}

public sealed record ChallengeCharacterPin
{
  public ChallengeCharacterPin(
      int slot,
      EntityUid characterUid,
      EntityUid characterBuildUid,
      EntityUid buildRevisionUid,
      Sha256Digest buildContentSha256)
  {
    if (slot is < 1 or > 5)
    {
      throw new PrivateServerIntegrityException("challenge_character_slot_invalid");
    }

    Slot = slot;
    CharacterUid = PrivateServerGuard.RequireUid(characterUid, nameof(characterUid));
    CharacterBuildUid = PrivateServerGuard.RequireUid(characterBuildUid, nameof(characterBuildUid));
    BuildRevisionUid = PrivateServerGuard.RequireUid(buildRevisionUid, nameof(buildRevisionUid));
    BuildContentSha256 = PrivateServerGuard.RequireDigest(
        buildContentSha256,
        nameof(buildContentSha256));
  }

  public int Slot { get; }
  public EntityUid CharacterUid { get; }
  public EntityUid CharacterBuildUid { get; }
  public EntityUid BuildRevisionUid { get; }
  public Sha256Digest BuildContentSha256 { get; }
}

public sealed class ChallengeTeamPin
{
  private ChallengeTeamPin(
      int ordinal,
      EntityUid profileRevisionUid,
      Sha256Digest profileContentSha256,
      EntityUid accountCombatStateRevisionUid,
      EntityUid squadUid,
      EntityUid squadRevisionUid,
      Sha256Digest squadContentSha256,
      IReadOnlyList<ChallengeCharacterPin> members)
  {
    if (ordinal is < 1 or > 5 || members is null || members.Count != 5 ||
        !members.Select(static member => member.Slot).SequenceEqual(Enumerable.Range(1, 5)) ||
        members.Select(static member => member.CharacterUid).Distinct().Count() != 5 ||
        members.Select(static member => member.CharacterBuildUid).Distinct().Count() != 5 ||
        members.Select(static member => member.BuildRevisionUid).Distinct().Count() != 5)
    {
      throw new PrivateServerIntegrityException("challenge_team_pin_shape_invalid");
    }

    Ordinal = ordinal;
    ProfileRevisionUid = PrivateServerGuard.RequireUid(profileRevisionUid, nameof(profileRevisionUid));
    ProfileContentSha256 = PrivateServerGuard.RequireDigest(profileContentSha256, nameof(profileContentSha256));
    AccountCombatStateRevisionUid = PrivateServerGuard.RequireUid(accountCombatStateRevisionUid, nameof(accountCombatStateRevisionUid));
    SquadUid = PrivateServerGuard.RequireUid(squadUid, nameof(squadUid));
    SquadRevisionUid = PrivateServerGuard.RequireUid(squadRevisionUid, nameof(squadRevisionUid));
    SquadContentSha256 = PrivateServerGuard.RequireDigest(squadContentSha256, nameof(squadContentSha256));
    Members = Array.AsReadOnly(members.ToArray());
    ContentSha256 = PrivateServerHash.Compute("nll/challenge-team-pin/v1", hash =>
    {
      PrivateServerHash.Append(hash, Ordinal);
      PrivateServerHash.Append(hash, ProfileRevisionUid);
      PrivateServerHash.Append(hash, ProfileContentSha256);
      PrivateServerHash.Append(hash, AccountCombatStateRevisionUid);
      PrivateServerHash.Append(hash, SquadUid);
      PrivateServerHash.Append(hash, SquadRevisionUid);
      PrivateServerHash.Append(hash, SquadContentSha256);
      foreach (var member in Members)
      {
        PrivateServerHash.Append(hash, member.Slot);
        PrivateServerHash.Append(hash, member.CharacterUid);
        PrivateServerHash.Append(hash, member.CharacterBuildUid);
        PrivateServerHash.Append(hash, member.BuildRevisionUid);
        PrivateServerHash.Append(hash, member.BuildContentSha256);
      }
    });
  }

  public int Ordinal { get; }
  public EntityUid ProfileRevisionUid { get; }
  public Sha256Digest ProfileContentSha256 { get; }
  public EntityUid AccountCombatStateRevisionUid { get; }
  public EntityUid SquadUid { get; }
  public EntityUid SquadRevisionUid { get; }
  public Sha256Digest SquadContentSha256 { get; }
  public IReadOnlyList<ChallengeCharacterPin> Members { get; }
  public Sha256Digest ContentSha256 { get; }

  public static ChallengeTeamPin Restore(
      int ordinal,
      EntityUid profileRevisionUid,
      Sha256Digest profileContentSha256,
      EntityUid accountCombatStateRevisionUid,
      EntityUid squadUid,
      EntityUid squadRevisionUid,
      Sha256Digest squadContentSha256,
      IEnumerable<ChallengeCharacterPin> orderedMembers)
  {
    ArgumentNullException.ThrowIfNull(orderedMembers);
    return new ChallengeTeamPin(
        ordinal,
        profileRevisionUid,
        profileContentSha256,
        accountCombatStateRevisionUid,
        squadUid,
        squadRevisionUid,
        squadContentSha256,
        orderedMembers.ToArray());
  }

  public static ChallengeTeamPin Create(
      int ordinal,
      ProfileTemplateRevision profile,
      SquadRevisionReference squad)
  {
    ArgumentNullException.ThrowIfNull(profile);
    ArgumentNullException.ThrowIfNull(squad);
    if (ordinal is < 1 or > 5 || profile.Readiness != ProfileReadiness.Ready ||
        squad.LocalAccountUid != profile.LocalAccountUid || squad.Readiness != ProfileReadiness.Ready)
    {
      throw new PrivateServerIntegrityException("challenge_team_profile_binding_invalid");
    }

    var members = squad.Members
        .Select((member, index) => new ChallengeCharacterPin(
            index + 1,
            member.CharacterUid,
            member.CharacterBuildUid,
            member.RevisionUid,
            member.ContentSha256))
        .ToArray();
    if (members.Length != 5 || members.Select(static member => member.CharacterUid).Distinct().Count() != 5 ||
        members.Select(static member => member.CharacterBuildUid).Distinct().Count() != 5 ||
        members.Any(member => !profile.Content.BuildRevisions.Any(build =>
            build.CharacterUid == member.CharacterUid &&
            build.CharacterBuildUid == member.CharacterBuildUid &&
            build.RevisionUid == member.BuildRevisionUid &&
            build.ContentSha256 == member.BuildContentSha256)))
    {
      throw new PrivateServerIntegrityException("challenge_team_build_not_in_pinned_profile");
    }

    return new ChallengeTeamPin(
        ordinal,
        profile.ProfileTemplateRevisionUid,
        profile.ContentSha256,
        profile.Content.AccountCombatStateRevision.RevisionUid,
        squad.SquadUid,
        squad.RevisionUid,
        squad.ContentSha256,
        Array.AsReadOnly(members));
  }
}

public sealed class ChallengeRunPlan
{
  public ChallengeRunPlan(IEnumerable<ChallengeTeamPin> orderedTeams)
  {
    ArgumentNullException.ThrowIfNull(orderedTeams);
    var teams = orderedTeams
        .Select(static team => team ??
            throw new PrivateServerIntegrityException("challenge_team_pin_null"))
        .ToArray();
    if (teams.Length is < 1 or > 5 ||
        !teams.Select(static team => team.Ordinal).SequenceEqual(Enumerable.Range(1, teams.Length)) ||
        teams.Select(static team => team.SquadRevisionUid).Distinct().Count() != teams.Length ||
        teams.Select(static team => team.ProfileRevisionUid).Distinct().Count() != 1 ||
        teams.Select(static team => team.ProfileContentSha256).Distinct().Count() != 1 ||
        teams.Select(static team => team.AccountCombatStateRevisionUid).Distinct().Count() != 1 ||
        teams.SelectMany(static team => team.Members).Select(static member => member.CharacterUid)
            .Distinct().Count() != teams.Length * 5 ||
        teams.SelectMany(static team => team.Members).Select(static member => member.CharacterBuildUid)
            .Distinct().Count() != teams.Length * 5 ||
        teams.SelectMany(static team => team.Members).Select(static member => member.BuildRevisionUid)
            .Distinct().Count() != teams.Length * 5)
    {
      throw new PrivateServerIntegrityException("challenge_run_plan_invalid");
    }

    Teams = Array.AsReadOnly(teams);
    ContentSha256 = PrivateServerHash.Compute("nll/challenge-run-plan/v1", hash =>
    {
      foreach (var team in Teams)
      {
        PrivateServerHash.Append(hash, team.ContentSha256);
      }
    });
  }

  public IReadOnlyList<ChallengeTeamPin> Teams { get; }
  public Sha256Digest ContentSha256 { get; }
}

public sealed class LabHarnessTeamResultReceipt
{
  public const string ObservationContractId = "lab_harness_observation/v1";

  public LabHarnessTeamResultReceipt(
      EntityUid receiptUid,
      EntityUid runUid,
      ChallengeTeamPin team,
      NonNegativeIntegerDamage observedDamage,
      BattleFrameTelemetry telemetry,
      IEnumerable<ExecutionSegment> executionSegments,
      IEnumerable<string>? warningCodes,
      DateTimeOffset observedAtUtc)
  {
    ReceiptUid = PrivateServerGuard.RequireUid(receiptUid, nameof(receiptUid));
    RunUid = PrivateServerGuard.RequireUid(runUid, nameof(runUid));
    Team = team ?? throw new ArgumentNullException(nameof(team));
    ObservedDamage = observedDamage;
    Telemetry = telemetry ?? throw new ArgumentNullException(nameof(telemetry));
    ArgumentNullException.ThrowIfNull(executionSegments);
    var segments = executionSegments.ToArray();
    if (segments.Length is < 1 or > 64 ||
        segments.Any(static segment => segment is null) ||
        !segments.Select(static segment => segment.Ordinal).SequenceEqual(Enumerable.Range(1, segments.Length)) ||
        segments[0].StartDamage != NonNegativeIntegerDamage.Zero ||
        segments[0].StartRenderFrame != 0 || segments[0].StartBehaviorTick != 0 ||
        segments[0].StartFixedUpdate != 0 || segments[0].StartWallClockMicroseconds != 0 ||
        segments[^1].EndDamage != observedDamage ||
        segments[^1].EndRenderFrame != telemetry.RenderFrameCount ||
        segments[^1].EndBehaviorTick != telemetry.BehaviorTickCount ||
        segments[^1].EndFixedUpdate != telemetry.FixedUpdateCount ||
        segments[^1].EndWallClockMicroseconds != telemetry.WallClockMicroseconds)
    {
      throw new PrivateServerIntegrityException("challenge_result_segment_set_invalid");
    }

    for (var index = 1; index < segments.Length; index++)
    {
      var previous = segments[index - 1];
      var current = segments[index];
      if (previous.EndRenderFrame != current.StartRenderFrame ||
          previous.EndBehaviorTick != current.StartBehaviorTick ||
          previous.EndFixedUpdate != current.StartFixedUpdate ||
          previous.EndWallClockMicroseconds != current.StartWallClockMicroseconds ||
          previous.EndDamage != current.StartDamage)
      {
        throw new PrivateServerIntegrityException("challenge_result_segment_gap_or_overlap");
      }
    }

    ExecutionSegments = Array.AsReadOnly(segments);
    WarningCodes = PrivateServerGuard.NormalizeCodes(warningCodes, nameof(warningCodes));
    ObservedAtUtc = PrivateServerGuard.NormalizeUtc(observedAtUtc, nameof(observedAtUtc));
    ContentSha256 = PrivateServerHash.Compute("nll/lab-harness-team-result-receipt/v1", hash =>
    {
      PrivateServerHash.Append(hash, ObservationContractId);
      PrivateServerHash.Append(hash, RunUid);
      PrivateServerHash.Append(hash, Team.ContentSha256);
      PrivateServerHash.Append(hash, ObservedDamage.CanonicalDigits);
      PrivateServerHash.Append(hash, Telemetry.ContentSha256);
      foreach (var segment in ExecutionSegments)
      {
        AppendSegment(hash, segment);
      }

      foreach (var warningCode in WarningCodes)
      {
        PrivateServerHash.Append(hash, warningCode);
      }

      PrivateServerHash.Append(hash, ObservedAtUtc);
    });
  }

  public EntityUid ReceiptUid { get; }
  public EntityUid RunUid { get; }
  public ChallengeTeamPin Team { get; }
  public NonNegativeIntegerDamage ObservedDamage { get; }
  public BattleFrameTelemetry Telemetry { get; }
  public IReadOnlyList<ExecutionSegment> ExecutionSegments { get; }
  public IReadOnlyList<string> WarningCodes { get; }
  public DateTimeOffset ObservedAtUtc { get; }
  public string ObservationSourceCode => ObservationContractId;
  public bool IsOriginalClientRuntimeObservation => false;
  public Sha256Digest ContentSha256 { get; }

  public static LabHarnessTeamResultReceipt Restore(
      EntityUid receiptUid,
      EntityUid runUid,
      ChallengeTeamPin team,
      NonNegativeIntegerDamage observedDamage,
      BattleFrameTelemetry telemetry,
      IEnumerable<ExecutionSegment> executionSegments,
      IEnumerable<string>? warningCodes,
      DateTimeOffset observedAtUtc) =>
      new(
          receiptUid,
          runUid,
          team,
          observedDamage,
          telemetry,
          executionSegments,
          warningCodes,
          observedAtUtc);

  private static void AppendSegment(
      System.Security.Cryptography.IncrementalHash hash,
      ExecutionSegment segment)
  {
    PrivateServerHash.Append(hash, segment.Ordinal);
    PrivateServerHash.Append(hash, segment.RuntimeExecutionProfileRevisionUid);
    PrivateServerHash.Append(hash, segment.CombatControlProfileRevisionUid);
    PrivateServerHash.Append(hash, segment.StartRenderFrame);
    PrivateServerHash.Append(hash, segment.EndRenderFrame);
    PrivateServerHash.Append(hash, segment.StartBehaviorTick);
    PrivateServerHash.Append(hash, segment.EndBehaviorTick);
    PrivateServerHash.Append(hash, segment.StartFixedUpdate);
    PrivateServerHash.Append(hash, segment.EndFixedUpdate);
    PrivateServerHash.Append(hash, segment.StartWallClockMicroseconds);
    PrivateServerHash.Append(hash, segment.EndWallClockMicroseconds);
    PrivateServerHash.Append(hash, segment.StartDamage.CanonicalDigits);
    PrivateServerHash.Append(hash, segment.EndDamage.CanonicalDigits);
  }
}

public sealed record ChallengeRunBindingSnapshot(
    EntityUid AccountUid,
    EntityUid SessionUid,
    EntityUid ClientContextUid,
    EntityUid ClientContextRevisionUid,
    EntityUid ApplicationBuildUid,
    Sha256Digest ApplicationBuildSha256,
    string ApplicationContractId,
    EntityUid CapabilityManifestUid,
    Sha256Digest CapabilityManifestSha256,
    EntityUid DirectoryUid,
    Sha256Digest DirectoryContentSha256,
    EntityUid DailyStateUid,
    EntityUid DailyStateRevisionUid,
    Sha256Digest DailyStateContentSha256,
    EntityUid SelectedSeasonRevisionUid,
    Sha256Digest SelectedSeasonContentSha256,
    EntityUid RaidSnapshotUid,
    EntityUid RaidDatasetSnapshotUid,
    Sha256Digest RaidSnapshotContentSha256,
    EntityUid ProfileRevisionUid,
    Sha256Digest ProfileContentSha256,
    EntityUid AccountCombatStateRevisionUid,
    EntityUid RuntimeExecutionProfileRevisionUid,
    Sha256Digest RuntimeExecutionProfileContentSha256,
    EntityUid CombatControlProfileRevisionUid,
    Sha256Digest CombatControlProfileContentSha256,
    EntityUid OperationalPolicyUid,
    Sha256Digest OperationalPolicySha256,
    ChallengeEntryConsumptionPoint EntryConsumptionPoint,
    ActiveRunAtResetPolicy ActiveRunAtReset,
    DailyCounterScope DailyCounterScope,
    bool IsMockBattle,
    RaidDayKey RaidDayKey);

public sealed class ChallengeRunBinding
{
  private ChallengeRunBinding(
      LocalClientContext context,
      SelectedRaidSeasonRevision selection,
      RaidSeasonDirectory directory,
      ChallengeDailyStateRevision dailyState,
      ChallengeOperationalPolicy policy,
      PrivateServerCapabilityManifest capabilityManifest,
      RuntimeExecutionProfileRevision runtimeProfile,
      CombatControlProfileRevision controlProfile,
      ChallengeRunPlan plan,
      bool isMockBattle,
      RaidDayKey raidDayKey)
      : this(
          new ChallengeRunBindingSnapshot(
              context.AccountUid,
              context.SessionUid,
              context.ClientContextUid,
              context.ContextRevisionUid,
              context.ApplicationBuildUid,
              context.ApplicationBuildSha256,
              context.ApplicationContractId,
              capabilityManifest.ManifestUid,
              capabilityManifest.ContentSha256,
              directory.DirectoryUid,
              directory.ContentSha256,
              dailyState.DailyStateUid,
              dailyState.DailyStateRevisionUid,
              dailyState.ContentSha256,
              selection.SelectionRevisionUid,
              selection.ContentSha256,
              selection.Member.RaidSnapshotUid,
              selection.Member.DatasetSnapshotUid,
              selection.Member.RaidSnapshotContentSha256,
              plan.Teams[0].ProfileRevisionUid,
              plan.Teams[0].ProfileContentSha256,
              plan.Teams[0].AccountCombatStateRevisionUid,
              runtimeProfile.RevisionUid,
              runtimeProfile.ContentSha256,
              controlProfile.RevisionUid,
              controlProfile.ContentSha256,
              policy.PolicyUid,
              policy.ContentSha256,
              policy.EntryConsumptionPoint.RequireConfigured(),
              policy.ActiveRunAtReset.RequireConfigured(),
              policy.DailyCounterScope.RequireConfigured(),
              isMockBattle,
              raidDayKey),
          plan)
  {
  }

  private ChallengeRunBinding(
      ChallengeRunBindingSnapshot snapshot,
      ChallengeRunPlan plan)
  {
    ArgumentNullException.ThrowIfNull(snapshot);
    Plan = plan ?? throw new ArgumentNullException(nameof(plan));
    AccountUid = PrivateServerGuard.RequireUid(snapshot.AccountUid, nameof(snapshot.AccountUid));
    SessionUid = PrivateServerGuard.RequireUid(snapshot.SessionUid, nameof(snapshot.SessionUid));
    ClientContextUid = PrivateServerGuard.RequireUid(snapshot.ClientContextUid, nameof(snapshot.ClientContextUid));
    ClientContextRevisionUid = PrivateServerGuard.RequireUid(snapshot.ClientContextRevisionUid, nameof(snapshot.ClientContextRevisionUid));
    ApplicationBuildUid = PrivateServerGuard.RequireUid(snapshot.ApplicationBuildUid, nameof(snapshot.ApplicationBuildUid));
    ApplicationBuildSha256 = PrivateServerGuard.RequireDigest(snapshot.ApplicationBuildSha256, nameof(snapshot.ApplicationBuildSha256));
    ApplicationContractId = PrivateServerGuard.RequireVersionedContract(snapshot.ApplicationContractId, "nll/private-server-application/", nameof(snapshot.ApplicationContractId));
    CapabilityManifestUid = PrivateServerGuard.RequireUid(snapshot.CapabilityManifestUid, nameof(snapshot.CapabilityManifestUid));
    CapabilityManifestSha256 = PrivateServerGuard.RequireDigest(snapshot.CapabilityManifestSha256, nameof(snapshot.CapabilityManifestSha256));
    DirectoryUid = PrivateServerGuard.RequireUid(snapshot.DirectoryUid, nameof(snapshot.DirectoryUid));
    DirectoryContentSha256 = PrivateServerGuard.RequireDigest(snapshot.DirectoryContentSha256, nameof(snapshot.DirectoryContentSha256));
    DailyStateUid = PrivateServerGuard.RequireUid(snapshot.DailyStateUid, nameof(snapshot.DailyStateUid));
    DailyStateRevisionUid = PrivateServerGuard.RequireUid(snapshot.DailyStateRevisionUid, nameof(snapshot.DailyStateRevisionUid));
    DailyStateContentSha256 = PrivateServerGuard.RequireDigest(snapshot.DailyStateContentSha256, nameof(snapshot.DailyStateContentSha256));
    SelectedSeasonRevisionUid = PrivateServerGuard.RequireUid(snapshot.SelectedSeasonRevisionUid, nameof(snapshot.SelectedSeasonRevisionUid));
    SelectedSeasonContentSha256 = PrivateServerGuard.RequireDigest(snapshot.SelectedSeasonContentSha256, nameof(snapshot.SelectedSeasonContentSha256));
    RaidSnapshotUid = PrivateServerGuard.RequireUid(snapshot.RaidSnapshotUid, nameof(snapshot.RaidSnapshotUid));
    RaidDatasetSnapshotUid = PrivateServerGuard.RequireUid(snapshot.RaidDatasetSnapshotUid, nameof(snapshot.RaidDatasetSnapshotUid));
    RaidSnapshotContentSha256 = PrivateServerGuard.RequireDigest(snapshot.RaidSnapshotContentSha256, nameof(snapshot.RaidSnapshotContentSha256));
    ProfileRevisionUid = PrivateServerGuard.RequireUid(snapshot.ProfileRevisionUid, nameof(snapshot.ProfileRevisionUid));
    ProfileContentSha256 = PrivateServerGuard.RequireDigest(snapshot.ProfileContentSha256, nameof(snapshot.ProfileContentSha256));
    AccountCombatStateRevisionUid = PrivateServerGuard.RequireUid(snapshot.AccountCombatStateRevisionUid, nameof(snapshot.AccountCombatStateRevisionUid));
    RuntimeExecutionProfileRevisionUid = PrivateServerGuard.RequireUid(snapshot.RuntimeExecutionProfileRevisionUid, nameof(snapshot.RuntimeExecutionProfileRevisionUid));
    RuntimeExecutionProfileContentSha256 = PrivateServerGuard.RequireDigest(snapshot.RuntimeExecutionProfileContentSha256, nameof(snapshot.RuntimeExecutionProfileContentSha256));
    CombatControlProfileRevisionUid = PrivateServerGuard.RequireUid(snapshot.CombatControlProfileRevisionUid, nameof(snapshot.CombatControlProfileRevisionUid));
    CombatControlProfileContentSha256 = PrivateServerGuard.RequireDigest(snapshot.CombatControlProfileContentSha256, nameof(snapshot.CombatControlProfileContentSha256));
    OperationalPolicyUid = PrivateServerGuard.RequireUid(snapshot.OperationalPolicyUid, nameof(snapshot.OperationalPolicyUid));
    OperationalPolicySha256 = PrivateServerGuard.RequireDigest(snapshot.OperationalPolicySha256, nameof(snapshot.OperationalPolicySha256));
    if (!Enum.IsDefined(snapshot.EntryConsumptionPoint) ||
        !Enum.IsDefined(snapshot.ActiveRunAtReset) ||
        !Enum.IsDefined(snapshot.DailyCounterScope) ||
        plan.Teams.Any(team =>
            team.ProfileRevisionUid != ProfileRevisionUid ||
            team.ProfileContentSha256 != ProfileContentSha256 ||
            team.AccountCombatStateRevisionUid != AccountCombatStateRevisionUid))
    {
      throw new PrivateServerIntegrityException("challenge_run_binding_shape_invalid");
    }

    EntryConsumptionPoint = snapshot.EntryConsumptionPoint;
    ActiveRunAtReset = snapshot.ActiveRunAtReset;
    DailyCounterScope = snapshot.DailyCounterScope;
    IsMockBattle = snapshot.IsMockBattle;
    RaidDayKey = snapshot.RaidDayKey;
    ContentSha256 = ComputeContentSha256(this);
  }

  public EntityUid AccountUid { get; }
  public EntityUid SessionUid { get; }
  public EntityUid ClientContextUid { get; }
  public EntityUid ClientContextRevisionUid { get; }
  public EntityUid ApplicationBuildUid { get; }
  public Sha256Digest ApplicationBuildSha256 { get; }
  public string ApplicationContractId { get; }
  public EntityUid CapabilityManifestUid { get; }
  public Sha256Digest CapabilityManifestSha256 { get; }
  public EntityUid DirectoryUid { get; }
  public Sha256Digest DirectoryContentSha256 { get; }
  public EntityUid DailyStateUid { get; }
  public EntityUid DailyStateRevisionUid { get; }
  public Sha256Digest DailyStateContentSha256 { get; }
  public EntityUid SelectedSeasonRevisionUid { get; }
  public Sha256Digest SelectedSeasonContentSha256 { get; }
  public EntityUid RaidSnapshotUid { get; }
  public EntityUid RaidDatasetSnapshotUid { get; }
  public Sha256Digest RaidSnapshotContentSha256 { get; }
  public EntityUid ProfileRevisionUid { get; }
  public Sha256Digest ProfileContentSha256 { get; }
  public EntityUid AccountCombatStateRevisionUid { get; }
  public EntityUid RuntimeExecutionProfileRevisionUid { get; }
  public Sha256Digest RuntimeExecutionProfileContentSha256 { get; }
  public EntityUid CombatControlProfileRevisionUid { get; }
  public Sha256Digest CombatControlProfileContentSha256 { get; }
  public EntityUid OperationalPolicyUid { get; }
  public Sha256Digest OperationalPolicySha256 { get; }
  public ChallengeEntryConsumptionPoint EntryConsumptionPoint { get; }
  public ActiveRunAtResetPolicy ActiveRunAtReset { get; }
  public DailyCounterScope DailyCounterScope { get; }
  public bool IsMockBattle { get; }
  public RaidDayKey RaidDayKey { get; }
  public ChallengeRunPlan Plan { get; }
  public string ExecutionSourceCode => LabHarnessTeamResultReceipt.ObservationContractId;
  public Sha256Digest ContentSha256 { get; }

  public static ChallengeRunBinding Restore(
      ChallengeRunBindingSnapshot snapshot,
      ChallengeRunPlan plan) =>
      new(snapshot, plan);

  public static ChallengeRunBinding CreateForLabHarness(
      LocalClientContext context,
      SelectedRaidSeasonRevision selection,
      RaidSeasonDirectory directory,
      ChallengeDailyStateRevision dailyState,
      ChallengeOperationalPolicy policy,
      PrivateServerCapabilityManifest capabilityManifest,
      RuntimeExecutionProfileRevision runtimeProfile,
      CombatControlProfileRevision controlProfile,
      ProfileTemplateRevision profile,
      IEnumerable<SquadRevisionReference> orderedSquads,
      bool isMockBattle,
      DateTimeOffset openedAtUtc)
  {
    ArgumentNullException.ThrowIfNull(context);
    ArgumentNullException.ThrowIfNull(selection);
    ArgumentNullException.ThrowIfNull(directory);
    ArgumentNullException.ThrowIfNull(dailyState);
    ArgumentNullException.ThrowIfNull(policy);
    ArgumentNullException.ThrowIfNull(capabilityManifest);
    ArgumentNullException.ThrowIfNull(runtimeProfile);
    ArgumentNullException.ThrowIfNull(controlProfile);
    ArgumentNullException.ThrowIfNull(profile);
    ArgumentNullException.ThrowIfNull(orderedSquads);
    context.RequireLobbyReady(openedAtUtc);
    policy.RequireAdmissionReady();
    if (!policy.AllowsMockBattle(isMockBattle) ||
        !capabilityManifest.IsBackendChallengeStateSupported ||
        !capabilityManifest.IsOriginalClientPresentationAdapterBlocked ||
        context.CapabilityManifestUid != capabilityManifest.ManifestUid ||
        context.CapabilityManifestSha256 != capabilityManifest.ContentSha256 ||
        capabilityManifest.OperationalPolicyUid != policy.PolicyUid ||
        capabilityManifest.OperationalPolicySha256 != policy.ContentSha256 ||
        context.AccountUid != selection.AccountUid || context.SessionUid != selection.SessionUid ||
        context.ClientContextUid != selection.ClientContextUid ||
        context.SelectedSeasonRevisionUid != selection.SelectionRevisionUid ||
        context.SelectedSeasonContentSha256 != selection.ContentSha256 ||
        selection.DirectoryUid != directory.DirectoryUid ||
        selection.DirectoryContentSha256 != directory.ContentSha256 ||
        dailyState.AccountUid != context.AccountUid ||
        dailyState.PolicyUid != policy.PolicyUid ||
        dailyState.PolicyContentSha256 != policy.ContentSha256 ||
        dailyState.DirectoryUid != directory.DirectoryUid ||
        dailyState.DirectoryContentSha256 != directory.ContentSha256 ||
        dailyState.RaidDayKey != AsiaSeoulRaidDay.GetKey(openedAtUtc) ||
        dailyState.CounterScope != policy.DailyCounterScope.RequireConfigured() ||
        (dailyState.CounterScope == DailyCounterScope.PerSeason
            ? dailyState.RaidSnapshotUid != selection.Member.RaidSnapshotUid
            : dailyState.RaidSnapshotUid.HasValue) ||
        profile.LocalAccountUid != context.AccountUid ||
        runtimeProfile.AccountUid != context.AccountUid || controlProfile.AccountUid != context.AccountUid ||
        !runtimeProfile.Content.IsHarnessValidationReady ||
        !controlProfile.Content.IsManualBattleReady)
    {
      throw new PrivateServerIntegrityException("challenge_run_admission_binding_invalid");
    }

    var teams = orderedSquads
        .Select((squad, index) => ChallengeTeamPin.Create(index + 1, profile, squad))
        .ToArray();
    var plan = new ChallengeRunPlan(teams);
    return new ChallengeRunBinding(
        context,
        selection,
        directory,
        dailyState,
        policy,
        capabilityManifest,
        runtimeProfile,
        controlProfile,
        plan,
        isMockBattle,
        AsiaSeoulRaidDay.GetKey(openedAtUtc));
  }

  private static Sha256Digest ComputeContentSha256(ChallengeRunBinding value) =>
      PrivateServerHash.Compute("nll/challenge-run-binding/v1", hash =>
      {
        PrivateServerHash.Append(hash, value.AccountUid);
        PrivateServerHash.Append(hash, value.SessionUid);
        PrivateServerHash.Append(hash, value.ClientContextUid);
        PrivateServerHash.Append(hash, value.ClientContextRevisionUid);
        PrivateServerHash.Append(hash, value.ApplicationBuildUid);
        PrivateServerHash.Append(hash, value.ApplicationBuildSha256);
        PrivateServerHash.Append(hash, value.ApplicationContractId);
        PrivateServerHash.Append(hash, value.CapabilityManifestUid);
        PrivateServerHash.Append(hash, value.CapabilityManifestSha256);
        PrivateServerHash.Append(hash, value.DirectoryUid);
        PrivateServerHash.Append(hash, value.DirectoryContentSha256);
        PrivateServerHash.Append(hash, value.DailyStateUid);
        PrivateServerHash.Append(hash, value.DailyStateRevisionUid);
        PrivateServerHash.Append(hash, value.DailyStateContentSha256);
        PrivateServerHash.Append(hash, value.SelectedSeasonRevisionUid);
        PrivateServerHash.Append(hash, value.SelectedSeasonContentSha256);
        PrivateServerHash.Append(hash, value.RaidSnapshotUid);
        PrivateServerHash.Append(hash, value.RaidDatasetSnapshotUid);
        PrivateServerHash.Append(hash, value.RaidSnapshotContentSha256);
        PrivateServerHash.Append(hash, value.ProfileRevisionUid);
        PrivateServerHash.Append(hash, value.ProfileContentSha256);
        PrivateServerHash.Append(hash, value.AccountCombatStateRevisionUid);
        PrivateServerHash.Append(hash, value.RuntimeExecutionProfileRevisionUid);
        PrivateServerHash.Append(hash, value.RuntimeExecutionProfileContentSha256);
        PrivateServerHash.Append(hash, value.CombatControlProfileRevisionUid);
        PrivateServerHash.Append(hash, value.CombatControlProfileContentSha256);
        PrivateServerHash.Append(hash, value.OperationalPolicyUid);
        PrivateServerHash.Append(hash, value.OperationalPolicySha256);
        PrivateServerHash.Append(hash, ChallengeOperationalPolicy.Code(value.EntryConsumptionPoint));
        PrivateServerHash.Append(hash, ChallengeOperationalPolicy.Code(value.ActiveRunAtReset));
        PrivateServerHash.Append(hash, ChallengeOperationalPolicy.Code(value.DailyCounterScope));
        PrivateServerHash.Append(hash, value.IsMockBattle);
        PrivateServerHash.Append(hash, value.RaidDayKey.Value);
        PrivateServerHash.Append(hash, value.ExecutionSourceCode);
        PrivateServerHash.Append(hash, value.Plan.ContentSha256);
      });
}

public enum ChallengeRunState
{
  Open,
  TeamInProgress,
  TeamResultAccepted,
  RegroupReady,
  Completed,
  Abandoned
}

public sealed record ChallengeTeamAttempt(
    ChallengeTeamPin Team,
    DateTimeOffset EnteredAtUtc,
    LabHarnessTeamResultReceipt? ResultReceipt);

public sealed class ChallengeRun
{
  public const string OwningSessionInactiveRecoveryReasonCode =
      "owning_session_inactive_recovery";

  private ChallengeRun(
      EntityUid runUid,
      EntityUid runRevisionUid,
      long revisionNumber,
      EntityUid? predecessorRevisionUid,
      ChallengeRunBinding binding,
      ChallengeRunState state,
      DateTimeOffset openedAtUtc,
      DateTimeOffset updatedAtUtc,
      IReadOnlyList<ChallengeTeamAttempt> attempts,
      NonNegativeIntegerDamage cumulativeDamage,
      EntityUid? finalResultUid,
      EntityUid? abandonmentUid,
      string? abandonReasonCode)
  {
    PrivateServerGuard.RequireRevisionShape(revisionNumber, predecessorRevisionUid);
    RunUid = PrivateServerGuard.RequireUid(runUid, nameof(runUid));
    RunRevisionUid = PrivateServerGuard.RequireUid(runRevisionUid, nameof(runRevisionUid));
    RevisionNumber = revisionNumber;
    PredecessorRevisionUid = predecessorRevisionUid;
    Binding = binding ?? throw new ArgumentNullException(nameof(binding));
    if (!Enum.IsDefined(state))
    {
      throw new PrivateServerIntegrityException("challenge_run_state_invalid");
    }

    State = state;
    OpenedAtUtc = PrivateServerGuard.NormalizeUtc(openedAtUtc, nameof(openedAtUtc));
    UpdatedAtUtc = PrivateServerGuard.NormalizeUtc(updatedAtUtc, nameof(updatedAtUtc));
    ArgumentNullException.ThrowIfNull(attempts);
    if (UpdatedAtUtc < OpenedAtUtc || attempts.Count > binding.Plan.Teams.Count)
    {
      throw new PrivateServerIntegrityException("challenge_run_revision_shape_invalid");
    }

    var normalizedAttempts = attempts.Select((attempt, index) =>
    {
      if (attempt is null || attempt.Team.ContentSha256 != binding.Plan.Teams[index].ContentSha256)
      {
        throw new PrivateServerIntegrityException("challenge_run_attempt_binding_invalid");
      }

      if (attempt.ResultReceipt is { } boundReceipt &&
          boundReceipt.ExecutionSegments.Any(segment =>
              segment.RuntimeExecutionProfileRevisionUid !=
                  binding.RuntimeExecutionProfileRevisionUid ||
              segment.CombatControlProfileRevisionUid !=
                  binding.CombatControlProfileRevisionUid))
      {
        throw new PrivateServerIntegrityException("challenge_run_attempt_binding_invalid");
      }

      var enteredAt = PrivateServerGuard.NormalizeUtc(attempt.EnteredAtUtc, nameof(attempts));
      if (enteredAt < OpenedAtUtc || enteredAt > UpdatedAtUtc ||
          (index > 0 && enteredAt < attempts[index - 1].EnteredAtUtc) ||
          (attempt.ResultReceipt is { } receipt &&
              (receipt.RunUid != RunUid || receipt.Team.ContentSha256 != attempt.Team.ContentSha256 ||
               receipt.ObservedAtUtc < enteredAt || receipt.ObservedAtUtc > UpdatedAtUtc)))
      {
        throw new PrivateServerIntegrityException("challenge_run_attempt_shape_invalid");
      }

      return attempt with { EnteredAtUtc = enteredAt };
    }).ToArray();
    Attempts = Array.AsReadOnly(normalizedAttempts);
    _ = cumulativeDamage.ToBigInteger();
    var acceptedDamage = normalizedAttempts
        .Where(static attempt => attempt.ResultReceipt is not null)
        .Aggregate(
            NonNegativeIntegerDamage.Zero,
            static (sum, attempt) => NonNegativeIntegerDamage.Add(
                sum,
                attempt.ResultReceipt!.ObservedDamage));
    if (acceptedDamage != cumulativeDamage)
    {
      throw new PrivateServerIntegrityException("challenge_run_cumulative_damage_invalid");
    }

    CumulativeDamage = cumulativeDamage;
    FinalResultUid = finalResultUid.HasValue
        ? PrivateServerGuard.RequireUid(finalResultUid.Value, nameof(finalResultUid))
        : null;
    if (abandonmentUid.HasValue != (abandonReasonCode is not null))
    {
      throw new PrivateServerIntegrityException("challenge_run_abandonment_shape_invalid");
    }

    AbandonmentUid = abandonmentUid.HasValue
        ? PrivateServerGuard.RequireUid(abandonmentUid.Value, nameof(abandonmentUid))
        : null;
    AbandonReasonCode = abandonReasonCode is null
        ? null
        : PrivateServerGuard.RequireCode(abandonReasonCode, nameof(abandonReasonCode));
    ValidateStateShape();
    ContentSha256 = ComputeContentSha256(this);
  }

  public EntityUid RunUid { get; }
  public EntityUid RunRevisionUid { get; }
  public long RevisionNumber { get; }
  public EntityUid? PredecessorRevisionUid { get; }
  public ChallengeRunBinding Binding { get; }
  public ChallengeRunState State { get; }
  public DateTimeOffset OpenedAtUtc { get; }
  public DateTimeOffset UpdatedAtUtc { get; }
  public IReadOnlyList<ChallengeTeamAttempt> Attempts { get; }
  public NonNegativeIntegerDamage CumulativeDamage { get; }
  public EntityUid? FinalResultUid { get; }
  public EntityUid? AbandonmentUid { get; }
  public string? AbandonReasonCode { get; }
  public Sha256Digest ContentSha256 { get; }

  public static ChallengeRun Open(
      EntityUid runUid,
      EntityUid runRevisionUid,
      ChallengeRunBinding binding,
      DateTimeOffset openedAtUtc) =>
      new(
          runUid,
          runRevisionUid,
          1,
          null,
          binding,
          ChallengeRunState.Open,
          openedAtUtc,
          openedAtUtc,
          Array.Empty<ChallengeTeamAttempt>(),
          NonNegativeIntegerDamage.Zero,
          null,
          null,
          null);

  public static ChallengeRun Restore(
      EntityUid runUid,
      EntityUid runRevisionUid,
      long revisionNumber,
      EntityUid? predecessorRevisionUid,
      ChallengeRunBinding binding,
      ChallengeRunState state,
      DateTimeOffset openedAtUtc,
      DateTimeOffset updatedAtUtc,
      IEnumerable<ChallengeTeamAttempt> attempts,
      NonNegativeIntegerDamage cumulativeDamage,
      EntityUid? finalResultUid,
      EntityUid? abandonmentUid,
      string? abandonReasonCode)
  {
    ArgumentNullException.ThrowIfNull(attempts);
    return new ChallengeRun(
        runUid,
        runRevisionUid,
        revisionNumber,
        predecessorRevisionUid,
        binding,
        state,
        openedAtUtc,
        updatedAtUtc,
        attempts.ToArray(),
        cumulativeDamage,
        finalResultUid,
        abandonmentUid,
        abandonReasonCode);
  }

  public ChallengeRun EnterTeam(
      EntityUid nextRevisionUid,
      int teamOrdinal,
      DateTimeOffset observedAtUtc)
  {
    if (State is not (ChallengeRunState.Open or ChallengeRunState.RegroupReady) ||
        teamOrdinal != Attempts.Count + 1 || teamOrdinal > Binding.Plan.Teams.Count)
    {
      throw new PrivateServerIntegrityException("challenge_team_enter_transition_invalid");
    }

    var observed = RequireProgressInstant(observedAtUtc);
    var attempt = new ChallengeTeamAttempt(
        Binding.Plan.Teams[teamOrdinal - 1],
        observed,
        null);
    return Advance(
        nextRevisionUid,
        ChallengeRunState.TeamInProgress,
        observed,
        Attempts.Append(attempt).ToArray(),
        CumulativeDamage,
        null);
  }

  public ChallengeRun AcceptTeamResult(
      EntityUid nextRevisionUid,
      LabHarnessTeamResultReceipt receipt)
  {
    ArgumentNullException.ThrowIfNull(receipt);
    if (State != ChallengeRunState.TeamInProgress || Attempts.Count == 0 ||
        receipt.RunUid != RunUid ||
        receipt.Team.ContentSha256 != Attempts[^1].Team.ContentSha256 ||
        receipt.ExecutionSegments.Any(segment =>
            segment.RuntimeExecutionProfileRevisionUid !=
                Binding.RuntimeExecutionProfileRevisionUid ||
            segment.CombatControlProfileRevisionUid !=
                Binding.CombatControlProfileRevisionUid) ||
        receipt.ObservedAtUtc < Attempts[^1].EnteredAtUtc)
    {
      throw new PrivateServerIntegrityException("challenge_team_result_transition_invalid");
    }

    _ = RequireProgressInstant(receipt.ObservedAtUtc);
    var updatedAttempts = Attempts.ToArray();
    updatedAttempts[^1] = updatedAttempts[^1] with { ResultReceipt = receipt };
    return Advance(
        nextRevisionUid,
        ChallengeRunState.TeamResultAccepted,
        receipt.ObservedAtUtc,
        updatedAttempts,
        NonNegativeIntegerDamage.Add(CumulativeDamage, receipt.ObservedDamage),
        null);
  }

  public ChallengeRun PrepareRegroup(
      EntityUid nextRevisionUid,
      DateTimeOffset observedAtUtc)
  {
    if (State != ChallengeRunState.TeamResultAccepted ||
        Attempts.Count >= Binding.Plan.Teams.Count || Attempts.Count >= 5)
    {
      throw new PrivateServerIntegrityException("challenge_regroup_transition_invalid");
    }

    var observed = RequireProgressInstant(observedAtUtc);
    return Advance(
        nextRevisionUid,
        ChallengeRunState.RegroupReady,
        observed,
        Attempts,
        CumulativeDamage,
        null);
  }

  public ChallengeRun Close(
      EntityUid nextRevisionUid,
      EntityUid finalResultUid,
      DateTimeOffset observedAtUtc)
  {
    if (State is not (ChallengeRunState.TeamResultAccepted or ChallengeRunState.RegroupReady) ||
        Attempts.Count == 0 || Attempts.Any(static attempt => attempt.ResultReceipt is null))
    {
      throw new PrivateServerIntegrityException("challenge_close_transition_invalid");
    }

    var observed = RequireProgressInstant(observedAtUtc);

    return Advance(
        nextRevisionUid,
        ChallengeRunState.Completed,
        observed,
        Attempts,
        CumulativeDamage,
        PrivateServerGuard.RequireUid(finalResultUid, nameof(finalResultUid)),
        null,
        null);
  }

  public ChallengeRun Abandon(
      EntityUid nextRevisionUid,
      EntityUid abandonmentUid,
      string reasonCode,
      DateTimeOffset observedAtUtc)
  {
    var controlledReason = PrivateServerGuard.RequireCode(
        reasonCode,
        nameof(reasonCode));
    if (controlledReason == OwningSessionInactiveRecoveryReasonCode)
    {
      throw new PrivateServerIntegrityException(
          "challenge_abandon_reason_reserved_for_recovery");
    }

    return AbandonCore(
        nextRevisionUid,
        abandonmentUid,
        controlledReason,
        observedAtUtc);
  }

  public ChallengeRun RecoverAfterOwningSessionInactive(
      EntityUid nextRevisionUid,
      EntityUid abandonmentUid,
      DateTimeOffset observedAtUtc) =>
      AbandonCore(
          nextRevisionUid,
          abandonmentUid,
          OwningSessionInactiveRecoveryReasonCode,
          observedAtUtc);

  private ChallengeRun AbandonCore(
      EntityUid nextRevisionUid,
      EntityUid abandonmentUid,
      string reasonCode,
      DateTimeOffset observedAtUtc)
  {
    if (State is ChallengeRunState.Completed or ChallengeRunState.Abandoned)
    {
      throw new PrivateServerIntegrityException("challenge_abandon_transition_invalid");
    }

    // Abandonment remains available after a raid-day boundary so a crashed or
    // exited run cannot permanently hold the account's active-run slot.
    var observed = PrivateServerGuard.NormalizeUtc(observedAtUtc, nameof(observedAtUtc));
    if (observed < UpdatedAtUtc)
    {
      throw new PrivateServerIntegrityException("challenge_run_time_reversal");
    }

    return Advance(
        nextRevisionUid,
        ChallengeRunState.Abandoned,
        observed,
        Attempts,
        CumulativeDamage,
        null,
        PrivateServerGuard.RequireUid(abandonmentUid, nameof(abandonmentUid)),
        PrivateServerGuard.RequireCode(reasonCode, nameof(reasonCode)));
  }

  public bool TransitionConsumesAttempt(ChallengeEntryConsumptionPoint transition) =>
      !Binding.IsMockBattle && Binding.EntryConsumptionPoint == transition;

  public bool AbandonmentConsumesAttempt =>
      !Binding.IsMockBattle &&
      Binding.EntryConsumptionPoint == ChallengeEntryConsumptionPoint.RunClosed &&
      Attempts.Count > 0;

  private ChallengeRun Advance(
      EntityUid nextRevisionUid,
      ChallengeRunState state,
      DateTimeOffset updatedAtUtc,
      IReadOnlyList<ChallengeTeamAttempt> attempts,
      NonNegativeIntegerDamage cumulativeDamage,
      EntityUid? finalResultUid,
      EntityUid? abandonmentUid = null,
      string? abandonReasonCode = null) =>
      new(
          RunUid,
          nextRevisionUid,
          RevisionNumber + 1,
          RunRevisionUid,
          Binding,
          state,
          OpenedAtUtc,
          updatedAtUtc,
          Array.AsReadOnly(attempts.ToArray()),
          cumulativeDamage,
          finalResultUid,
          abandonmentUid,
          abandonReasonCode);

  private DateTimeOffset RequireProgressInstant(DateTimeOffset value)
  {
    var observed = PrivateServerGuard.NormalizeUtc(value, nameof(value));
    if (observed < UpdatedAtUtc)
    {
      throw new PrivateServerIntegrityException("challenge_run_time_reversal");
    }

    if (Binding.ActiveRunAtReset == ActiveRunAtResetPolicy.RejectPostBoundaryProgress &&
        AsiaSeoulRaidDay.GetKey(observed) != Binding.RaidDayKey)
    {
      throw new PrivateServerIntegrityException("challenge_run_crossed_raid_day_boundary");
    }

    return observed;
  }

  private void ValidateStateShape()
  {
    var hasActiveAttempt = Attempts.Count > 0 && Attempts[^1].ResultReceipt is null;
    var allAccepted = Attempts.All(static attempt => attempt.ResultReceipt is not null);
    var valid = State switch
    {
      ChallengeRunState.Open => Attempts.Count == 0 && FinalResultUid is null && AbandonmentUid is null,
      ChallengeRunState.TeamInProgress => hasActiveAttempt && FinalResultUid is null && AbandonmentUid is null,
      ChallengeRunState.TeamResultAccepted => Attempts.Count > 0 && allAccepted && FinalResultUid is null && AbandonmentUid is null,
      ChallengeRunState.RegroupReady => Attempts.Count > 0 && allAccepted &&
          Attempts.Count < Binding.Plan.Teams.Count && FinalResultUid is null && AbandonmentUid is null,
      ChallengeRunState.Completed => Attempts.Count > 0 && allAccepted && FinalResultUid.HasValue &&
          AbandonmentUid is null,
      ChallengeRunState.Abandoned => FinalResultUid is null && AbandonmentUid.HasValue &&
          AbandonReasonCode is not null,
      _ => false
    };
    if (!valid)
    {
      throw new PrivateServerIntegrityException("challenge_run_state_shape_invalid");
    }
  }

  private static Sha256Digest ComputeContentSha256(ChallengeRun value) =>
      PrivateServerHash.Compute("nll/challenge-run/v1", hash =>
      {
        PrivateServerHash.Append(hash, value.Binding.ContentSha256);
        PrivateServerHash.Append(hash, StateCode(value.State));
        PrivateServerHash.Append(hash, value.OpenedAtUtc);
        PrivateServerHash.Append(hash, value.UpdatedAtUtc);
        foreach (var attempt in value.Attempts)
        {
          PrivateServerHash.Append(hash, attempt.Team.ContentSha256);
          PrivateServerHash.Append(hash, attempt.EnteredAtUtc);
          PrivateServerHash.Append(hash, attempt.ResultReceipt?.ContentSha256);
        }

        PrivateServerHash.Append(hash, value.CumulativeDamage.CanonicalDigits);
        PrivateServerHash.Append(hash, value.FinalResultUid);
        PrivateServerHash.Append(hash, value.AbandonmentUid);
        PrivateServerHash.Append(hash, value.AbandonReasonCode is not null);
        if (value.AbandonReasonCode is not null)
        {
          PrivateServerHash.Append(hash, value.AbandonReasonCode);
        }
      });

  public static string StateCode(ChallengeRunState value) => value switch
  {
    ChallengeRunState.Open => "open",
    ChallengeRunState.TeamInProgress => "team_in_progress",
    ChallengeRunState.TeamResultAccepted => "team_result_accepted",
    ChallengeRunState.RegroupReady => "regroup_ready",
    ChallengeRunState.Completed => "completed",
    ChallengeRunState.Abandoned => "abandoned",
    _ => throw new PrivateServerIntegrityException("challenge_run_state_invalid")
  };
}
