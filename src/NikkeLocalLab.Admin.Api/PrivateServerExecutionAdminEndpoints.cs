using NikkeLocalLab.Application.PrivateServer;
using NikkeLocalLab.Domain.PrivateServer;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Admin.Api;

internal static class PrivateServerExecutionAdminEndpoints
{
  internal static void MapPrivateServerExecutionAdminEndpoints(this WebApplication app)
  {
    var group = app.MapGroup("/admin-api/v1/private-server/accounts/{accountUid}");
    group.MapPost("/runtime-execution-profile/preview", PreviewRuntime);
    group.MapPut("/runtime-execution-profile", SaveRuntimeAsync);
    group.MapPost("/combat-control-profile/preview", PreviewCombat);
    group.MapPut("/combat-control-profile", SaveCombatAsync);
  }

  private static IResult PreviewRuntime(
      string accountUid,
      RuntimeExecutionProfileContentRequest request)
  {
    _ = ParseUid(accountUid, "account_uid_invalid");
    var content = BuildRuntimeContent(request);
    return Results.Json(ProjectRuntimeContent(content));
  }

  private static async Task<IResult> SaveRuntimeAsync(
      string accountUid,
      SaveRuntimeExecutionProfileRequest request,
      IPrivateServerService service,
      TimeProvider timeProvider,
      HttpContext context)
  {
    var account = ParseUid(accountUid, "account_uid_invalid");
    var operation = ParseUid(request.OperationUid, "operation_uid_invalid");
    var profile = ParseUid(request.ProfileUid, "runtime_execution_profile_uid_invalid");
    var content = request.Content is null
        ? throw Invalid("runtime_execution_profile_content_required")
        : BuildRuntimeContent(request.Content);
    var projection = await service.SaveRuntimeExecutionProfileAsync(
        new SaveRuntimeExecutionProfileCommand(
            operation,
            account,
            profile,
            RequireRevisionPrecondition(context.Request),
            content,
            ObservedNow(timeProvider)),
        context.RequestAborted).ConfigureAwait(false);
    if (projection.Revision.AccountUid != account || projection.Revision.ProfileUid != profile)
    {
      throw new InvalidOperationException("runtime_execution_profile_scope_invalid");
    }

    context.Response.Headers.ETag = Quote(projection.Revision.RevisionUid.ToString());
    return Results.Json(ProjectRuntimeRevision(projection.Revision));
  }

  private static IResult PreviewCombat(
      string accountUid,
      CombatControlProfileContentRequest request)
  {
    _ = ParseUid(accountUid, "account_uid_invalid");
    var content = BuildCombatContent(request);
    return Results.Json(ProjectCombatContent(content));
  }

  private static async Task<IResult> SaveCombatAsync(
      string accountUid,
      SaveCombatControlProfileRequest request,
      IPrivateServerService service,
      TimeProvider timeProvider,
      HttpContext context)
  {
    var account = ParseUid(accountUid, "account_uid_invalid");
    var operation = ParseUid(request.OperationUid, "operation_uid_invalid");
    var profile = ParseUid(request.ProfileUid, "combat_control_profile_uid_invalid");
    var content = request.Content is null
        ? throw Invalid("combat_control_profile_content_required")
        : BuildCombatContent(request.Content);
    var projection = await service.SaveCombatControlProfileAsync(
        new SaveCombatControlProfileCommand(
            operation,
            account,
            profile,
            RequireRevisionPrecondition(context.Request),
            content,
            ObservedNow(timeProvider)),
        context.RequestAborted).ConfigureAwait(false);
    if (projection.Revision.AccountUid != account || projection.Revision.ProfileUid != profile)
    {
      throw new InvalidOperationException("combat_control_profile_scope_invalid");
    }

    context.Response.Headers.ETag = Quote(projection.Revision.RevisionUid.ToString());
    return Results.Json(ProjectCombatRevision(projection.Revision));
  }

  private static RuntimeExecutionProfileContent BuildRuntimeContent(
      RuntimeExecutionProfileContentRequest request) => Materialize(() =>
  {
    if (request.OriginalClientRuntimeBuild is null || request.Requested is null)
    {
      throw Invalid("runtime_execution_profile_content_required");
    }

    return new RuntimeExecutionProfileContent(
        BuildOriginalRuntimeBinding(request.OriginalClientRuntimeBuild),
        BuildRuntimeSettings(request.Requested),
        OptionalEffective(
            request.EffectiveReadbackStatusCode,
            request.Effective,
            BuildRuntimeSettings));
  });

  private static OriginalClientRuntimeBuildBinding BuildOriginalRuntimeBinding(
      OriginalRuntimeBuildBindingRequest request) => request.StatusCode switch
      {
        "ready" when request.UnresolvedReasonCode is null =>
            OriginalClientRuntimeBuildBinding.Ready(
                ParseUid(request.BuildUid, "original_runtime_build_uid_invalid"),
                ParseDigest(request.BuildSha256, "original_runtime_build_sha256_invalid")),
        "unresolved" when request.BuildUid is null && request.BuildSha256 is null &&
            request.UnresolvedReasonCode is not null =>
            OriginalClientRuntimeBuildBinding.Unresolved(request.UnresolvedReasonCode),
        _ => throw Invalid("original_runtime_build_binding_invalid")
      };

  private static RuntimeExecutionSettingsSnapshot BuildRuntimeSettings(
      RuntimeExecutionSettingsRequest request) => Materialize(() =>
  {
    if (request.Scheduler is null || request.Display is null || request.Graphics is null ||
        request.Graphics.Any(static option => option is null))
    {
      throw Invalid("runtime_execution_settings_required");
    }

    var scheduler = request.Scheduler;
    var display = request.Display;
    if (scheduler.TargetFrameRate is null || scheduler.FixedDeltaDenominator is null ||
        scheduler.VsyncEnabled is null || scheduler.MultiplayerEnabled is null ||
        scheduler.TimeScale is null || display.Platform is null ||
        display.DisplayMode is null || display.Width is null || display.Height is null ||
        display.RefreshRateHz is null)
    {
      throw Invalid("runtime_execution_settings_required");
    }

    return new RuntimeExecutionSettingsSnapshot(
        new RuntimeSchedulerSettings(
            BuildFact(
                scheduler.TargetFrameRate,
                static value => value switch
                {
                  30 => TargetFrameRate.Fps30,
                  60 => TargetFrameRate.Fps60,
                  _ => throw Invalid("runtime_target_frame_rate_invalid")
                }),
            BuildFact(scheduler.FixedDeltaDenominator, static value => value),
            BuildFact(scheduler.VsyncEnabled, static value => value),
            BuildFact(scheduler.MultiplayerEnabled, static value => value),
            BuildTimeScaleFact(scheduler.TimeScale)),
        new RuntimeDisplaySettings(
            BuildCodeFact(display.Platform),
            BuildCodeFact(display.DisplayMode),
            BuildFact(display.Width, static value => value),
            BuildFact(display.Height, static value => value),
            BuildFact(display.RefreshRateHz, static value => value)),
        new RuntimeGraphicsSettings(request.Graphics.Select(option =>
            new RuntimeGraphicsOption(
                option!.FieldCode ?? throw Invalid("runtime_graphics_field_code_invalid"),
                option.Value is null
                    ? throw Invalid("runtime_graphics_fact_required")
                    : BuildCodeFact(option.Value)))));
  });

  private static CombatControlProfileContent BuildCombatContent(
      CombatControlProfileContentRequest request) => Materialize(() =>
  {
    if (request.Requested is null)
    {
      throw Invalid("combat_control_profile_content_required");
    }

    return new CombatControlProfileContent(
        BuildCombatSettings(request.Requested),
        OptionalEffective(
            request.EffectiveReadbackStatusCode,
            request.Effective,
            BuildCombatSettings));
  });

  private static CombatControlSettingsSnapshot BuildCombatSettings(
      CombatControlSettingsRequest request) => Materialize(() =>
  {
    if (request.AimSensitivity is null || request.UseAimAssistant is null ||
        request.AimAssistantIntensity is null || request.UsePcAimSync is null ||
        request.MaxPerShotCorrect is null || request.AutoCombat is null ||
        request.AutoBurst is null)
    {
      throw Invalid("combat_control_settings_required");
    }

    return new CombatControlSettingsSnapshot(
        BuildFact(request.AimSensitivity, static value => value),
        BuildFact(request.UseAimAssistant, static value => value),
        BuildFact(request.AimAssistantIntensity, static value => value),
        BuildFact(request.UsePcAimSync, static value => value),
        BuildFact(request.MaxPerShotCorrect, static value => value),
        BuildFact(request.AutoCombat, static value => value),
        BuildFact(request.AutoBurst, static value => value));
  });

  private static ExecutionFact<TimeScalePolicy> BuildTimeScaleFact(
      ExecutionCodeFactRequest request) => request.StatusCode switch
      {
        "ready" when request.ValueCode == "normal_1x" && request.ReasonCode is null =>
            ExecutionFact<TimeScalePolicy>.Ready(TimeScalePolicy.NormalOneX),
        "unresolved" when request.ValueCode is null && request.ReasonCode is not null =>
            ExecutionFact<TimeScalePolicy>.Unresolved(request.ReasonCode),
        "not_applicable" when request.ValueCode is null && request.ReasonCode is null =>
            ExecutionFact<TimeScalePolicy>.NotApplicable(),
        _ => throw Invalid("execution_fact_shape_invalid")
      };

  private static ExecutionCodeFact BuildCodeFact(ExecutionCodeFactRequest request) =>
      request.StatusCode switch
      {
        "ready" when request.ValueCode is not null && request.ReasonCode is null =>
            ExecutionCodeFact.Ready(request.ValueCode),
        "unresolved" when request.ValueCode is null && request.ReasonCode is not null =>
            ExecutionCodeFact.Unresolved(request.ReasonCode),
        "not_applicable" when request.ValueCode is null && request.ReasonCode is null =>
            ExecutionCodeFact.NotApplicable(),
        _ => throw Invalid("execution_fact_shape_invalid")
      };

  private static ExecutionFact<TOutput> BuildFact<TInput, TOutput>(
      string? statusCode,
      TInput? value,
      string? reasonCode,
      Func<TInput, TOutput> convert)
      where TInput : struct
      where TOutput : struct => statusCode switch
      {
        "ready" when value.HasValue && reasonCode is null =>
            ExecutionFact<TOutput>.Ready(convert(value.Value)),
        "unresolved" when !value.HasValue && reasonCode is not null =>
            ExecutionFact<TOutput>.Unresolved(reasonCode),
        "not_applicable" when !value.HasValue && reasonCode is null =>
            ExecutionFact<TOutput>.NotApplicable(),
        _ => throw Invalid("execution_fact_shape_invalid")
      };

  private static ExecutionFact<TOutput> BuildFact<TOutput>(
      ExecutionIntegerFactRequest request,
      Func<int, TOutput> convert)
      where TOutput : struct =>
      BuildFact(request.StatusCode, request.Value, request.ReasonCode, convert);

  private static ExecutionFact<TOutput> BuildFact<TOutput>(
      ExecutionBooleanFactRequest request,
      Func<bool, TOutput> convert)
      where TOutput : struct =>
      BuildFact(request.StatusCode, request.Value, request.ReasonCode, convert);

  private static ExecutionFact<TOutput> BuildFact<TOutput>(
      ExecutionDecimalFactRequest request,
      Func<decimal, TOutput> convert)
      where TOutput : struct =>
      BuildFact(request.StatusCode, request.Value, request.ReasonCode, convert);

  private static T? OptionalEffective<TRequest, T>(
      string? statusCode,
      TRequest? request,
      Func<TRequest, T> materialize)
      where TRequest : class
      where T : class => statusCode switch
      {
        "not_observed" when request is null => null,
        "provided" when request is not null => materialize(request),
        _ => throw Invalid("effective_readback_shape_invalid")
      };

  private static EntityUid? RequireRevisionPrecondition(HttpRequest request)
  {
    var ifMatch = request.Headers.IfMatch;
    var ifNoneMatch = request.Headers.IfNoneMatch;
    if (ifMatch.Count == 0 && ifNoneMatch.Count == 0)
    {
      throw new ApiRequestException(
          StatusCodes.Status428PreconditionRequired,
          "profile_revision_precondition_required");
    }

    if (ifMatch.Count == 0 && ifNoneMatch.Count == 1 && ifNoneMatch[0] == "*")
    {
      return null;
    }

    if (ifNoneMatch.Count == 0 && ifMatch.Count == 1)
    {
      var value = ifMatch[0];
      if (value is not null && value.Length == 38 && value[0] == '"' && value[^1] == '"')
      {
        return ParseUid(value[1..^1], "revision_precondition_invalid");
      }
    }

    throw Invalid("revision_precondition_invalid");
  }

  private static object ProjectRuntimeRevision(RuntimeExecutionProfileRevision value) => new
  {
    value.ProfileUid,
    value.RevisionUid,
    value.AccountUid,
    value.RevisionNumber,
    value.PredecessorRevisionUid,
    value.MaterializedAtUtc,
    content = ProjectRuntimeContent(value.Content)
  };

  private static object ProjectCombatRevision(CombatControlProfileRevision value) => new
  {
    value.ProfileUid,
    value.RevisionUid,
    value.AccountUid,
    value.RevisionNumber,
    value.PredecessorRevisionUid,
    value.MaterializedAtUtc,
    content = ProjectCombatContent(value.Content)
  };

  private static object ProjectRuntimeContent(RuntimeExecutionProfileContent value) => new
  {
    value.ContentSha256,
    value.IsHarnessValidationReady,
    value.IsOriginalClientLaunchReady,
    value.IsEffectiveReadbackReady,
    originalClientRuntimeBuild = new
    {
      statusCode = RuntimeExecutionSettingsSnapshot.FactStatusCode(
          value.OriginalClientRuntimeBuild.Status),
      value.OriginalClientRuntimeBuild.BuildUid,
      value.OriginalClientRuntimeBuild.BuildSha256,
      value.OriginalClientRuntimeBuild.UnresolvedReasonCode
    },
    requested = ProjectRuntimeSettings(value.Requested),
    effectiveReadbackStatusCode = value.Effective is null ? "not_observed" : "provided",
    effective = value.Effective is null ? null : ProjectRuntimeSettings(value.Effective)
  };

  private static object ProjectRuntimeSettings(RuntimeExecutionSettingsSnapshot value) => new
  {
    value.ContentSha256,
    value.IsLaunchReady,
    scheduler = new
    {
      targetFrameRate = ProjectFact(value.Scheduler.TargetFrameRate, static item => (int)item),
      fixedDeltaDenominator = ProjectFact(value.Scheduler.FixedDeltaDenominator, static item => item),
      vsyncEnabled = ProjectFact(value.Scheduler.VsyncEnabled, static item => item),
      multiplayerEnabled = ProjectFact(value.Scheduler.MultiplayerEnabled, static item => item),
      timeScale = ProjectFact(
          value.Scheduler.TimeScale,
          RuntimeExecutionSettingsSnapshot.TimeScaleCode)
    },
    display = new
    {
      platform = ProjectCodeFact(value.Display.Platform),
      displayMode = ProjectCodeFact(value.Display.DisplayMode),
      width = ProjectFact(value.Display.Width, static item => item),
      height = ProjectFact(value.Display.Height, static item => item),
      refreshRateHz = ProjectFact(value.Display.RefreshRateHz, static item => item)
    },
    graphics = value.Graphics.Options.Select(option => new
    {
      option.FieldCode,
      value = ProjectCodeFact(option.Value)
    }).ToArray()
  };

  private static object ProjectCombatContent(CombatControlProfileContent value) => new
  {
    value.ContentSha256,
    value.IsManualBattleReady,
    value.IsEffectiveReadbackReady,
    requested = ProjectCombatSettings(value.Requested),
    effectiveReadbackStatusCode = value.Effective is null ? "not_observed" : "provided",
    effective = value.Effective is null ? null : ProjectCombatSettings(value.Effective)
  };

  private static object ProjectCombatSettings(CombatControlSettingsSnapshot value) => new
  {
    value.ContentSha256,
    value.IsManualBattleReady,
    aimSensitivity = ProjectFact(value.AimSensitivity, static item => item),
    useAimAssistant = ProjectFact(value.UseAimAssistant, static item => item),
    aimAssistantIntensity = ProjectFact(value.AimAssistantIntensity, static item => item),
    usePcAimSync = ProjectFact(value.UsePcAimSync, static item => item),
    maxPerShotCorrect = ProjectFact(value.MaxPerShotCorrect, static item => item),
    autoCombat = ProjectFact(value.AutoCombat, static item => item),
    autoBurst = ProjectFact(value.AutoBurst, static item => item)
  };

  private static object ProjectFact<T, TOutput>(
      ExecutionFact<T> value,
    Func<T, TOutput> project)
      where T : struct => new
      {
        statusCode = RuntimeExecutionSettingsSnapshot.FactStatusCode(value.Status),
        value = value.Value.HasValue ? (object?)project(value.Value.Value) : null,
        value.ReasonCode
      };

  private static object ProjectCodeFact(ExecutionCodeFact value) => new
  {
    statusCode = RuntimeExecutionSettingsSnapshot.FactStatusCode(value.Status),
    value.ValueCode,
    value.ReasonCode
  };

  private static T Materialize<T>(Func<T> factory)
  {
    try
    {
      return factory();
    }
    catch (PrivateServerIntegrityException exception)
    {
      throw Invalid(exception.Code);
    }
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
