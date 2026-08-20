using NikkeLocalLab.Application.PrivateServer;
using NikkeLocalLab.Domain.PrivateServer;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Admin.Api;

internal static class PrivateServerPolicyAdminEndpoints
{
  internal static void MapPrivateServerPolicyAdminEndpoints(this WebApplication app)
  {
    var group = app.MapGroup("/admin-api/v1/private-server/challenge-policy");
    group.MapGet("/", GetAsync);
    group.MapPost("/preview", Preview);
    group.MapPost("/publish", PublishAsync);
    group.MapPost("/activate-next-raid-day", ActivateNextRaidDayAsync);
  }

  private static async Task<IResult> GetAsync(
      IPrivateServerService service,
      TimeProvider timeProvider,
      HttpContext context)
  {
    var state = await service.GetChallengeOperationalPolicyAsync(
        new ChallengePolicyStateQuery(ObservedNow(timeProvider)),
        context.RequestAborted).ConfigureAwait(false);
    context.Response.Headers.ETag = Quote(state.Activation.Revision.RevisionUid.ToString());
    return Results.Json(State(state));
  }

  private static IResult Preview(
      ChallengePolicyValuesRequest request,
      TimeProvider timeProvider)
  {
    var policy = BuildPolicy(
        request.PolicyUid,
        request.PolicyId,
        request.DailyEntryLimit,
        request.EntryConsumptionPoint,
        request.ActiveRunAtReset,
        request.DailyCounterScope,
        request.MockBattleCapability,
        request.LocalRankingCapability);
    var currentDay = AsiaSeoulRaidDay.GetKey(ObservedNow(timeProvider));
    return Results.Json(new
    {
      policy = Policy(policy, publishedAtUtc: null, isActive: false, effectiveRaidDayKey: null),
      activation = new
      {
        mode = "next_raid_day",
        effectiveRaidDayKey = RaidDayKey.FromDate(currentDay.Date.AddDays(1)).Value
      }
    });
  }

  private static async Task<IResult> PublishAsync(
      PublishChallengePolicyRequest request,
      IPrivateServerService service,
      TimeProvider timeProvider,
      HttpContext context)
  {
    var observedAtUtc = ObservedNow(timeProvider);
    var policy = BuildPolicy(
        request.PolicyUid,
        request.PolicyId,
        request.DailyEntryLimit,
        request.EntryConsumptionPoint,
        request.ActiveRunAtReset,
        request.DailyCounterScope,
        request.MockBattleCapability,
        request.LocalRankingCapability);
    var result = await service.PublishChallengeOperationalPolicyAsync(
        new PublishChallengeOperationalPolicyCommand(
            ParseUid(request.OperationUid, "operation_uid_invalid"),
            policy,
            observedAtUtc),
        context.RequestAborted).ConfigureAwait(false);
    return Results.Json(Project(result), statusCode: StatusCodes.Status201Created);
  }

  private static async Task<IResult> ActivateNextRaidDayAsync(
      ActivateChallengePolicyRequest request,
      IPrivateServerService service,
      TimeProvider timeProvider,
      HttpContext context)
  {
    var observedAtUtc = ObservedNow(timeProvider);
    var observedDay = AsiaSeoulRaidDay.GetKey(observedAtUtc);
    var nextDay = RaidDayKey.FromDate(observedDay.Date.AddDays(1));
    var result = await service.ActivateChallengeOperationalPolicyAsync(
        new ActivateChallengeOperationalPolicyCommand(
            ParseUid(request.OperationUid, "operation_uid_invalid"),
            ParseUid(request.PolicyUid, "challenge_policy_uid_invalid"),
            ParseDigest(request.ExpectedPolicySha256, "challenge_policy_sha256_invalid"),
            nextDay,
            RequireIfMatch(context.Request),
            observedAtUtc),
        context.RequestAborted).ConfigureAwait(false);
    context.Response.Headers.ETag = Quote(result.Activation.Revision.RevisionUid.ToString());
    return Results.Json(State(result));
  }

  private static ChallengeOperationalPolicy BuildPolicy(
      string? policyUid,
      string? policyId,
      int? dailyEntryLimit,
      string? entryConsumptionPoint,
      string? activeRunAtReset,
      string? dailyCounterScope,
      string? mockBattleCapability,
      string? localRankingCapability)
  {
    if (!dailyEntryLimit.HasValue || string.IsNullOrEmpty(policyId))
    {
      throw Invalid("challenge_policy_all_axes_required");
    }

    try
    {
      return ChallengeOperationalPolicy.CreateConfiguredV1(
          ParseUid(policyUid, "challenge_policy_uid_invalid"),
          policyId,
          dailyEntryLimit.Value,
          ParseEntryConsumptionPoint(entryConsumptionPoint),
          ParseActiveRunAtReset(activeRunAtReset),
          ParseDailyCounterScope(dailyCounterScope),
          ParseMockBattleCapability(mockBattleCapability),
          ParseLocalRankingCapability(localRankingCapability));
    }
    catch (PrivateServerIntegrityException exception)
    {
      throw Invalid(exception.Code);
    }
  }

  private static ChallengeEntryConsumptionPoint ParseEntryConsumptionPoint(string? value) =>
      value switch
      {
        "run_opened" => ChallengeEntryConsumptionPoint.RunOpened,
        "first_team_entered" => ChallengeEntryConsumptionPoint.FirstTeamEntered,
        "run_closed" => ChallengeEntryConsumptionPoint.RunClosed,
        _ => throw Invalid("challenge_policy_all_axes_required")
      };

  private static ActiveRunAtResetPolicy ParseActiveRunAtReset(string? value) => value switch
  {
    "pin_opening_raid_day" => ActiveRunAtResetPolicy.PinOpeningRaidDay,
    "reject_post_boundary_progress" => ActiveRunAtResetPolicy.RejectPostBoundaryProgress,
    _ => throw Invalid("challenge_policy_all_axes_required")
  };

  private static DailyCounterScope ParseDailyCounterScope(string? value) => value switch
  {
    "per_season" => DailyCounterScope.PerSeason,
    "shared_across_directory" => DailyCounterScope.SharedAcrossDirectory,
    _ => throw Invalid("challenge_policy_all_axes_required")
  };

  private static MockBattleCapability ParseMockBattleCapability(string? value) => value switch
  {
    "unsupported" => MockBattleCapability.Unsupported,
    "lab_owned_only" => MockBattleCapability.LabOwnedOnly,
    _ => throw Invalid("challenge_policy_all_axes_required")
  };

  private static LocalRankingCapability ParseLocalRankingCapability(string? value) => value switch
  {
    "unsupported" => LocalRankingCapability.Unsupported,
    "local_records_only" => LocalRankingCapability.LocalRecordsOnly,
    _ => throw Invalid("challenge_policy_all_axes_required")
  };

  private static object State(ChallengePolicyStateProjection value) => new
  {
    current = Project(value.Current),
    scheduled = value.Scheduled is null ? null : Project(value.Scheduled),
    activation = new
    {
      value.Activation.ActivationUid,
      revision = value.Activation.Revision,
      value.Activation.PolicyUid,
      policySha256 = value.Activation.PolicySha256,
      effectiveRaidDayKey = value.Activation.EffectiveRaidDayKey.Value
    }
  };

  private static object Project(ChallengeOperationalPolicyProjection value) =>
      Policy(
          value.Policy,
          value.PublishedAtUtc,
          value.IsActive,
          value.EffectiveRaidDayKey?.Value);

  private static object Policy(
      ChallengeOperationalPolicy policy,
      DateTimeOffset? publishedAtUtc,
      bool isActive,
      string? effectiveRaidDayKey) => new
      {
        policy.PolicyUid,
        policy.PolicyId,
        resolutionStatusCode = ChallengeOperationalPolicy.Code(policy.ResolutionStatus),
        policy.ContentSha256,
        publishedAtUtc,
        isActive,
        effectiveRaidDayKey,
        dailyEntryLimit = policy.DailyEntryLimit.Value,
        entryConsumptionPoint = policy.EntryConsumptionPoint.Value.HasValue
        ? ChallengeOperationalPolicy.Code(policy.EntryConsumptionPoint.Value.Value)
        : null,
        activeRunAtReset = policy.ActiveRunAtReset.Value.HasValue
        ? ChallengeOperationalPolicy.Code(policy.ActiveRunAtReset.Value.Value)
        : null,
        dailyCounterScope = policy.DailyCounterScope.Value.HasValue
        ? ChallengeOperationalPolicy.Code(policy.DailyCounterScope.Value.Value)
        : null,
        mockBattleCapability = policy.MockBattleCapability.Value.HasValue
        ? ChallengeOperationalPolicy.Code(policy.MockBattleCapability.Value.Value)
        : null,
        localRankingCapability = policy.LocalRankingCapability.Value.HasValue
        ? ChallengeOperationalPolicy.Code(policy.LocalRankingCapability.Value.Value)
        : null
      };

  private static EntityUid RequireIfMatch(HttpRequest request)
  {
    var values = request.Headers.IfMatch;
    if (values.Count != 1)
    {
      throw new ApiRequestException(
          StatusCodes.Status428PreconditionRequired,
          "challenge_policy_activation_revision_required");
    }

    var value = values[0];
    if (value is null || value.Length != 38 || value[0] != '"' || value[^1] != '"')
    {
      throw Invalid("revision_precondition_invalid");
    }

    return ParseUid(value[1..^1], "revision_precondition_invalid");
  }

  private static EntityUid ParseUid(string? value, string code)
  {
    if (!Guid.TryParseExact(value, "D", out var guid) || guid == Guid.Empty)
    {
      throw Invalid(code);
    }

    return new EntityUid(guid);
  }

  private static Sha256Digest ParseDigest(string? value, string code)
  {
    if (!Sha256Digest.TryParse(value, out var digest))
    {
      throw Invalid(code);
    }

    return digest;
  }

  private static DateTimeOffset ObservedNow(TimeProvider timeProvider)
  {
    var utc = timeProvider.GetUtcNow().ToUniversalTime();
    return new DateTimeOffset(utc.Ticks - (utc.Ticks % 10), TimeSpan.Zero);
  }

  private static string Quote(string value) => $"\"{value}\"";

  private static ApiRequestException Invalid(string code) =>
      new(StatusCodes.Status400BadRequest, code);
}
