using System.Globalization;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Domain.PrivateServer;

public enum PolicyResolutionStatus
{
  Configured,
  Unresolved
}

public enum ChallengeEntryConsumptionPoint
{
  RunOpened,
  FirstTeamEntered,
  RunClosed
}

public enum ActiveRunAtResetPolicy
{
  PinOpeningRaidDay,
  RejectPostBoundaryProgress
}

public enum DailyCounterScope
{
  PerSeason,
  SharedAcrossDirectory
}

public enum MockBattleCapability
{
  Unsupported,
  LabOwnedOnly
}

public enum LocalRankingCapability
{
  Unsupported,
  LocalRecordsOnly
}

public sealed record PolicyFact<T>
    where T : struct
{
  public PolicyFact(
      PolicyResolutionStatus status,
      T? value = null,
      string? unresolvedReasonCode = null)
  {
    if (!Enum.IsDefined(status) ||
        (status == PolicyResolutionStatus.Configured &&
            (!value.HasValue || unresolvedReasonCode is not null)) ||
        (status == PolicyResolutionStatus.Unresolved &&
            (value.HasValue || unresolvedReasonCode is null)))
    {
      throw new PrivateServerIntegrityException("challenge_policy_fact_shape_invalid");
    }

    Status = status;
    Value = value;
    UnresolvedReasonCode = unresolvedReasonCode is null
        ? null
        : PrivateServerGuard.RequireCode(unresolvedReasonCode, nameof(unresolvedReasonCode));
  }

  public PolicyResolutionStatus Status { get; }

  public T? Value { get; }

  public string? UnresolvedReasonCode { get; }

  public bool IsConfigured => Status == PolicyResolutionStatus.Configured;

  public static PolicyFact<T> Configured(T value) =>
      new(PolicyResolutionStatus.Configured, value);

  public static PolicyFact<T> Unresolved(string reasonCode) =>
      new(PolicyResolutionStatus.Unresolved, unresolvedReasonCode: reasonCode);

  public T RequireConfigured()
  {
    if (!IsConfigured || !Value.HasValue)
    {
      throw new PrivateServerIntegrityException("challenge_operational_policy_unresolved");
    }

    return Value.Value;
  }
}

public sealed class ChallengeOperationalPolicy
{
  public const string UnresolvedPolicyId = "challenge-operational-policy/unresolved/v1";

  public ChallengeOperationalPolicy(
      EntityUid policyUid,
      string policyId,
      PolicyFact<int> dailyEntryLimit,
      PolicyFact<ChallengeEntryConsumptionPoint> entryConsumptionPoint,
      PolicyFact<ActiveRunAtResetPolicy> activeRunAtReset,
      PolicyFact<DailyCounterScope> dailyCounterScope,
      PolicyFact<MockBattleCapability> mockBattleCapability,
      PolicyFact<LocalRankingCapability> localRankingCapability)
  {
    PolicyUid = PrivateServerGuard.RequireUid(policyUid, nameof(policyUid));
    PolicyId = PrivateServerGuard.RequireVersionedContract(
        policyId,
        "challenge-operational-policy/",
        nameof(policyId));
    DailyEntryLimit = dailyEntryLimit ?? throw new ArgumentNullException(nameof(dailyEntryLimit));
    EntryConsumptionPoint = entryConsumptionPoint ??
        throw new ArgumentNullException(nameof(entryConsumptionPoint));
    ActiveRunAtReset = activeRunAtReset ?? throw new ArgumentNullException(nameof(activeRunAtReset));
    DailyCounterScope = dailyCounterScope ?? throw new ArgumentNullException(nameof(dailyCounterScope));
    MockBattleCapability = mockBattleCapability ??
        throw new ArgumentNullException(nameof(mockBattleCapability));
    LocalRankingCapability = localRankingCapability ??
        throw new ArgumentNullException(nameof(localRankingCapability));

    ValidateConfiguredEnum(entryConsumptionPoint);
    ValidateConfiguredEnum(activeRunAtReset);
    ValidateConfiguredEnum(dailyCounterScope);
    ValidateConfiguredEnum(mockBattleCapability);
    ValidateConfiguredEnum(localRankingCapability);
    if (dailyEntryLimit.Value is <= 0 or > 1_000_000)
    {
      throw new PrivateServerIntegrityException("challenge_daily_entry_limit_invalid");
    }

    var factsConfigured = new[]
    {
      dailyEntryLimit.IsConfigured,
      entryConsumptionPoint.IsConfigured,
      activeRunAtReset.IsConfigured,
      dailyCounterScope.IsConfigured,
      mockBattleCapability.IsConfigured,
      localRankingCapability.IsConfigured
    };
    if (factsConfigured.Any(static configured => configured) &&
        factsConfigured.Any(static configured => !configured))
    {
      throw new PrivateServerIntegrityException("challenge_operational_policy_partially_configured");
    }

    ResolutionStatus = factsConfigured.All(static configured => configured)
        ? PolicyResolutionStatus.Configured
        : PolicyResolutionStatus.Unresolved;
    if ((ResolutionStatus == PolicyResolutionStatus.Unresolved) !=
        string.Equals(PolicyId, UnresolvedPolicyId, StringComparison.Ordinal))
    {
      throw new PrivateServerIntegrityException("challenge_operational_policy_id_mismatch");
    }

    ContentSha256 = ComputeContentSha256(this);
  }

  public EntityUid PolicyUid { get; }

  public string PolicyId { get; }

  public PolicyResolutionStatus ResolutionStatus { get; }

  public PolicyFact<int> DailyEntryLimit { get; }

  public PolicyFact<ChallengeEntryConsumptionPoint> EntryConsumptionPoint { get; }

  public PolicyFact<ActiveRunAtResetPolicy> ActiveRunAtReset { get; }

  public PolicyFact<DailyCounterScope> DailyCounterScope { get; }

  public PolicyFact<MockBattleCapability> MockBattleCapability { get; }

  public PolicyFact<LocalRankingCapability> LocalRankingCapability { get; }

  public Sha256Digest ContentSha256 { get; }

  public bool IsAdmissionReady => ResolutionStatus == PolicyResolutionStatus.Configured;

  public static ChallengeOperationalPolicy CreateUnresolvedV1(
      EntityUid policyUid,
      string reasonCode = "policy_not_configured")
  {
    var reason = PrivateServerGuard.RequireCode(reasonCode, nameof(reasonCode));
    return new ChallengeOperationalPolicy(
        policyUid,
        UnresolvedPolicyId,
        PolicyFact<int>.Unresolved(reason),
        PolicyFact<ChallengeEntryConsumptionPoint>.Unresolved(reason),
        PolicyFact<ActiveRunAtResetPolicy>.Unresolved(reason),
        PolicyFact<DailyCounterScope>.Unresolved(reason),
        PolicyFact<MockBattleCapability>.Unresolved(reason),
        PolicyFact<LocalRankingCapability>.Unresolved(reason));
  }

  public static ChallengeOperationalPolicy CreateConfiguredV1(
      EntityUid policyUid,
      string policyId,
      int dailyEntryLimit,
      ChallengeEntryConsumptionPoint entryConsumptionPoint,
      ActiveRunAtResetPolicy activeRunAtReset,
      DailyCounterScope dailyCounterScope,
      MockBattleCapability mockBattleCapability,
      LocalRankingCapability localRankingCapability) =>
      new(
          policyUid,
          policyId,
          PolicyFact<int>.Configured(dailyEntryLimit),
          PolicyFact<ChallengeEntryConsumptionPoint>.Configured(entryConsumptionPoint),
          PolicyFact<ActiveRunAtResetPolicy>.Configured(activeRunAtReset),
          PolicyFact<DailyCounterScope>.Configured(dailyCounterScope),
          PolicyFact<MockBattleCapability>.Configured(mockBattleCapability),
          PolicyFact<LocalRankingCapability>.Configured(localRankingCapability));

  public static ChallengeOperationalPolicy CreateFromControlledCodes(
      EntityUid policyUid,
      string policyId,
      string resolutionStatusCode,
      int? dailyEntryLimit,
      string entryConsumptionPointCode,
      string activeRunAtResetCode,
      string dailyCounterScopeCode,
      string mockBattleCapabilityCode,
      string localRankingCapabilityCode)
  {
    if (string.Equals(resolutionStatusCode, "unresolved", StringComparison.Ordinal))
    {
      if (!string.Equals(policyId, UnresolvedPolicyId, StringComparison.Ordinal) ||
          dailyEntryLimit.HasValue ||
          !string.Equals(entryConsumptionPointCode, "unresolved", StringComparison.Ordinal) ||
          !string.Equals(activeRunAtResetCode, "unresolved", StringComparison.Ordinal) ||
          !string.Equals(dailyCounterScopeCode, "unresolved", StringComparison.Ordinal) ||
          !string.Equals(mockBattleCapabilityCode, "unresolved", StringComparison.Ordinal) ||
          !string.Equals(localRankingCapabilityCode, "unresolved", StringComparison.Ordinal))
      {
        throw new PrivateServerIntegrityException(
            "challenge_operational_policy_code_shape_invalid");
      }

      return CreateUnresolvedV1(policyUid);
    }

    if (!string.Equals(resolutionStatusCode, "configured", StringComparison.Ordinal) ||
        !dailyEntryLimit.HasValue)
    {
      throw new PrivateServerIntegrityException(
          "challenge_operational_policy_code_shape_invalid");
    }

    return CreateConfiguredV1(
        policyUid,
        policyId,
        dailyEntryLimit.Value,
        ParseEntryConsumptionPoint(entryConsumptionPointCode),
        ParseActiveRunAtReset(activeRunAtResetCode),
        ParseDailyCounterScope(dailyCounterScopeCode),
        ParseMockBattleCapability(mockBattleCapabilityCode),
        ParseLocalRankingCapability(localRankingCapabilityCode));
  }

  public void RequireAdmissionReady()
  {
    if (!IsAdmissionReady)
    {
      throw new PrivateServerIntegrityException("challenge_operational_policy_unresolved");
    }
  }

  public bool ConsumesAttemptAt(ChallengeEntryConsumptionPoint transition)
  {
    RequireAdmissionReady();
    return EntryConsumptionPoint.RequireConfigured() == transition;
  }

  public bool AllowsMockBattle(bool requested)
  {
    RequireAdmissionReady();
    return !requested || MockBattleCapability.RequireConfigured() ==
        Domain.PrivateServer.MockBattleCapability.LabOwnedOnly;
  }

  private static void ValidateConfiguredEnum<T>(PolicyFact<T> fact)
      where T : struct, Enum
  {
    if (fact.Value.HasValue && !Enum.IsDefined(fact.Value.Value))
    {
      throw new PrivateServerIntegrityException("challenge_operational_policy_value_invalid");
    }
  }

  private static ChallengeEntryConsumptionPoint ParseEntryConsumptionPoint(string value) =>
      value switch
      {
        "run_opened" => ChallengeEntryConsumptionPoint.RunOpened,
        "first_team_entered" => ChallengeEntryConsumptionPoint.FirstTeamEntered,
        "run_closed" => ChallengeEntryConsumptionPoint.RunClosed,
        _ => throw new PrivateServerIntegrityException(
            "challenge_entry_consumption_point_invalid")
      };

  private static ActiveRunAtResetPolicy ParseActiveRunAtReset(string value) => value switch
  {
    "pin_opening_raid_day" => ActiveRunAtResetPolicy.PinOpeningRaidDay,
    "reject_post_boundary_progress" => ActiveRunAtResetPolicy.RejectPostBoundaryProgress,
    _ => throw new PrivateServerIntegrityException("challenge_active_run_reset_policy_invalid")
  };

  private static DailyCounterScope ParseDailyCounterScope(string value) => value switch
  {
    "per_season" => global::NikkeLocalLab.Domain.PrivateServer.DailyCounterScope.PerSeason,
    "shared_across_directory" =>
        global::NikkeLocalLab.Domain.PrivateServer.DailyCounterScope.SharedAcrossDirectory,
    _ => throw new PrivateServerIntegrityException("challenge_daily_counter_scope_invalid")
  };

  private static MockBattleCapability ParseMockBattleCapability(string value) => value switch
  {
    "unsupported" =>
        global::NikkeLocalLab.Domain.PrivateServer.MockBattleCapability.Unsupported,
    "lab_owned_only" =>
        global::NikkeLocalLab.Domain.PrivateServer.MockBattleCapability.LabOwnedOnly,
    _ => throw new PrivateServerIntegrityException("challenge_mock_battle_capability_invalid")
  };

  private static LocalRankingCapability ParseLocalRankingCapability(string value) => value switch
  {
    "unsupported" =>
        global::NikkeLocalLab.Domain.PrivateServer.LocalRankingCapability.Unsupported,
    "local_records_only" =>
        global::NikkeLocalLab.Domain.PrivateServer.LocalRankingCapability.LocalRecordsOnly,
    _ => throw new PrivateServerIntegrityException("challenge_local_ranking_capability_invalid")
  };

  private static Sha256Digest ComputeContentSha256(ChallengeOperationalPolicy value) =>
      PrivateServerHash.Compute("nll/challenge-operational-policy/v1", hash =>
      {
        PrivateServerHash.Append(hash, value.PolicyId);
        AppendFact(
            hash,
            value.DailyEntryLimit,
            static item => item.ToString(CultureInfo.InvariantCulture));
        AppendFact(hash, value.EntryConsumptionPoint, Code);
        AppendFact(hash, value.ActiveRunAtReset, Code);
        AppendFact(hash, value.DailyCounterScope, Code);
        AppendFact(hash, value.MockBattleCapability, Code);
        AppendFact(hash, value.LocalRankingCapability, Code);
      });

  private static void AppendFact<T>(
      System.Security.Cryptography.IncrementalHash hash,
      PolicyFact<T> fact,
      Func<T, string> formatter)
      where T : struct
  {
    PrivateServerHash.Append(hash, Code(fact.Status));
    PrivateServerHash.Append(hash, fact.Value.HasValue ? formatter(fact.Value.Value) : string.Empty);
    PrivateServerHash.Append(hash, fact.UnresolvedReasonCode ?? string.Empty);
  }

  public static string Code(PolicyResolutionStatus value) => value switch
  {
    PolicyResolutionStatus.Configured => "configured",
    PolicyResolutionStatus.Unresolved => "unresolved",
    _ => throw new PrivateServerIntegrityException("challenge_policy_resolution_invalid")
  };

  public static string Code(ChallengeEntryConsumptionPoint value) => value switch
  {
    ChallengeEntryConsumptionPoint.RunOpened => "run_opened",
    ChallengeEntryConsumptionPoint.FirstTeamEntered => "first_team_entered",
    ChallengeEntryConsumptionPoint.RunClosed => "run_closed",
    _ => throw new PrivateServerIntegrityException("challenge_entry_consumption_point_invalid")
  };

  public static string Code(ActiveRunAtResetPolicy value) => value switch
  {
    ActiveRunAtResetPolicy.PinOpeningRaidDay => "pin_opening_raid_day",
    ActiveRunAtResetPolicy.RejectPostBoundaryProgress => "reject_post_boundary_progress",
    _ => throw new PrivateServerIntegrityException("challenge_active_run_at_reset_invalid")
  };

  public static string Code(DailyCounterScope value) => value switch
  {
    Domain.PrivateServer.DailyCounterScope.PerSeason => "per_season",
    Domain.PrivateServer.DailyCounterScope.SharedAcrossDirectory => "shared_across_directory",
    _ => throw new PrivateServerIntegrityException("challenge_daily_counter_scope_invalid")
  };

  public static string Code(MockBattleCapability value) => value switch
  {
    Domain.PrivateServer.MockBattleCapability.Unsupported => "unsupported",
    Domain.PrivateServer.MockBattleCapability.LabOwnedOnly => "lab_owned_only",
    _ => throw new PrivateServerIntegrityException("challenge_mock_battle_capability_invalid")
  };

  public static string Code(LocalRankingCapability value) => value switch
  {
    Domain.PrivateServer.LocalRankingCapability.Unsupported => "unsupported",
    Domain.PrivateServer.LocalRankingCapability.LocalRecordsOnly => "local_records_only",
    _ => throw new PrivateServerIntegrityException("challenge_local_ranking_capability_invalid")
  };
}
