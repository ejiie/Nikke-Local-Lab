using System.Globalization;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Domain.PrivateServer;

public enum ExecutionFactStatus
{
  Ready,
  Unresolved,
  NotApplicable
}

public sealed record ExecutionFact<T>
    where T : struct
{
  public ExecutionFact(
      ExecutionFactStatus status,
      T? value = null,
      string? reasonCode = null)
  {
    if (!Enum.IsDefined(status) ||
        (status == ExecutionFactStatus.Ready && (!value.HasValue || reasonCode is not null)) ||
        (status == ExecutionFactStatus.Unresolved && (value.HasValue || reasonCode is null)) ||
        (status == ExecutionFactStatus.NotApplicable && (value.HasValue || reasonCode is not null)))
    {
      throw new PrivateServerIntegrityException("execution_fact_shape_invalid");
    }

    Status = status;
    Value = value;
    ReasonCode = reasonCode is null
        ? null
        : PrivateServerGuard.RequireCode(reasonCode, nameof(reasonCode));
  }

  public ExecutionFactStatus Status { get; }

  public T? Value { get; }

  public string? ReasonCode { get; }

  public bool IsResolved => Status is ExecutionFactStatus.Ready or ExecutionFactStatus.NotApplicable;

  public static ExecutionFact<T> Ready(T value) => new(ExecutionFactStatus.Ready, value);

  public static ExecutionFact<T> Unresolved(string reasonCode) =>
      new(ExecutionFactStatus.Unresolved, reasonCode: reasonCode);

  public static ExecutionFact<T> NotApplicable() => new(ExecutionFactStatus.NotApplicable);
}

public sealed record ExecutionCodeFact
{
  public ExecutionCodeFact(
      ExecutionFactStatus status,
      string? valueCode = null,
      string? reasonCode = null)
  {
    if (!Enum.IsDefined(status) ||
        (status == ExecutionFactStatus.Ready && (valueCode is null || reasonCode is not null)) ||
        (status == ExecutionFactStatus.Unresolved && (valueCode is not null || reasonCode is null)) ||
        (status == ExecutionFactStatus.NotApplicable &&
            (valueCode is not null || reasonCode is not null)))
    {
      throw new PrivateServerIntegrityException("execution_code_fact_shape_invalid");
    }

    Status = status;
    ValueCode = valueCode is null
        ? null
        : PrivateServerGuard.RequireCode(valueCode, nameof(valueCode));
    ReasonCode = reasonCode is null
        ? null
        : PrivateServerGuard.RequireCode(reasonCode, nameof(reasonCode));
  }

  public ExecutionFactStatus Status { get; }

  public string? ValueCode { get; }

  public string? ReasonCode { get; }

  public bool IsResolved => Status is ExecutionFactStatus.Ready or ExecutionFactStatus.NotApplicable;

  public static ExecutionCodeFact Ready(string valueCode) =>
      new(ExecutionFactStatus.Ready, valueCode);

  public static ExecutionCodeFact Unresolved(string reasonCode) =>
      new(ExecutionFactStatus.Unresolved, reasonCode: reasonCode);

  public static ExecutionCodeFact NotApplicable() => new(ExecutionFactStatus.NotApplicable);
}

public enum TargetFrameRate
{
  Fps30 = 30,
  Fps60 = 60
}

public enum TimeScalePolicy
{
  NormalOneX
}

public sealed class RuntimeSchedulerSettings
{
  public RuntimeSchedulerSettings(
      ExecutionFact<TargetFrameRate> targetFrameRate,
      ExecutionFact<int> fixedDeltaDenominator,
      ExecutionFact<bool> vsyncEnabled,
      ExecutionFact<bool> multiplayerEnabled,
      ExecutionFact<TimeScalePolicy> timeScale)
  {
    TargetFrameRate = targetFrameRate ?? throw new ArgumentNullException(nameof(targetFrameRate));
    FixedDeltaDenominator = fixedDeltaDenominator ??
        throw new ArgumentNullException(nameof(fixedDeltaDenominator));
    VsyncEnabled = vsyncEnabled ?? throw new ArgumentNullException(nameof(vsyncEnabled));
    MultiplayerEnabled = multiplayerEnabled ??
        throw new ArgumentNullException(nameof(multiplayerEnabled));
    TimeScale = timeScale ?? throw new ArgumentNullException(nameof(timeScale));

    if ((targetFrameRate.Value.HasValue && !Enum.IsDefined(targetFrameRate.Value.Value)) ||
        (timeScale.Value.HasValue && !Enum.IsDefined(timeScale.Value.Value)) ||
        fixedDeltaDenominator.Value is <= 0)
    {
      throw new PrivateServerIntegrityException("runtime_scheduler_setting_invalid");
    }

    if (targetFrameRate.Value.HasValue && fixedDeltaDenominator.Value.HasValue &&
        (int)targetFrameRate.Value.Value != fixedDeltaDenominator.Value.Value)
    {
      throw new PrivateServerIntegrityException("runtime_target_fixed_delta_mismatch");
    }

    if (multiplayerEnabled.Value == true)
    {
      throw new PrivateServerIntegrityException("runtime_multiplayer_must_be_disabled");
    }
  }

  public ExecutionFact<TargetFrameRate> TargetFrameRate { get; }

  public ExecutionFact<int> FixedDeltaDenominator { get; }

  public ExecutionFact<bool> VsyncEnabled { get; }

  public ExecutionFact<bool> MultiplayerEnabled { get; }

  public ExecutionFact<TimeScalePolicy> TimeScale { get; }

  public bool IsLaunchReady =>
      TargetFrameRate.Status == ExecutionFactStatus.Ready &&
      FixedDeltaDenominator.Status == ExecutionFactStatus.Ready &&
      VsyncEnabled.Status == ExecutionFactStatus.Ready &&
      MultiplayerEnabled.Status == ExecutionFactStatus.Ready &&
      TimeScale.Status == ExecutionFactStatus.Ready;
}

public sealed class RuntimeDisplaySettings
{
  public RuntimeDisplaySettings(
      ExecutionCodeFact platform,
      ExecutionCodeFact displayMode,
      ExecutionFact<int> width,
      ExecutionFact<int> height,
      ExecutionFact<decimal> refreshRateHz)
  {
    Platform = platform ?? throw new ArgumentNullException(nameof(platform));
    DisplayMode = displayMode ?? throw new ArgumentNullException(nameof(displayMode));
    Width = width ?? throw new ArgumentNullException(nameof(width));
    Height = height ?? throw new ArgumentNullException(nameof(height));
    RefreshRateHz = refreshRateHz ?? throw new ArgumentNullException(nameof(refreshRateHz));
    if (width.Value is <= 0 || height.Value is <= 0 || refreshRateHz.Value is <= 0)
    {
      throw new PrivateServerIntegrityException("runtime_display_setting_invalid");
    }

    if (refreshRateHz.Value.HasValue)
    {
      _ = PrivateServerGuard.RequireStorageDecimal(
          refreshRateHz.Value.Value,
          maximumIntegerDigits: 17,
          maximumScale: 12,
          errorCode: "runtime_refresh_rate_storage_invalid");
    }
  }

  public ExecutionCodeFact Platform { get; }

  public ExecutionCodeFact DisplayMode { get; }

  public ExecutionFact<int> Width { get; }

  public ExecutionFact<int> Height { get; }

  public ExecutionFact<decimal> RefreshRateHz { get; }

  public bool IsLaunchReady =>
      Platform.Status == ExecutionFactStatus.Ready &&
      DisplayMode.Status == ExecutionFactStatus.Ready &&
      Width.Status == ExecutionFactStatus.Ready &&
      Height.Status == ExecutionFactStatus.Ready &&
      RefreshRateHz.Status == ExecutionFactStatus.Ready;
}

public sealed record RuntimeGraphicsOption
{
  public RuntimeGraphicsOption(string fieldCode, ExecutionCodeFact value)
  {
    FieldCode = PrivateServerGuard.RequireCode(fieldCode, nameof(fieldCode));
    Value = value ?? throw new ArgumentNullException(nameof(value));
  }

  public string FieldCode { get; }

  public ExecutionCodeFact Value { get; }
}

public sealed class RuntimeGraphicsSettings
{
  private static readonly string[] RequiredFieldCodes =
  [
    "anti_aliasing_enabled",
    "anti_aliasing_step",
    "battle_animation_physics_flags",
    "battle_effect_quality",
    "default_quality_level",
    "graphic_option_mode",
    "mesh_quality",
    "post_process_flags",
    "spine_resolution",
    "texture_quality",
    "volumetric_fog_quality"
  ];

  public RuntimeGraphicsSettings(IEnumerable<RuntimeGraphicsOption> options)
  {
    ArgumentNullException.ThrowIfNull(options);
    var normalized = options
        .Select(static option => option ??
            throw new PrivateServerIntegrityException("runtime_graphics_option_null"))
        .OrderBy(static option => option.FieldCode, StringComparer.Ordinal)
        .ToArray();
    if (normalized.Select(static option => option.FieldCode).Distinct(StringComparer.Ordinal).Count() !=
        normalized.Length ||
        normalized.Length != RequiredFieldCodes.Length ||
        RequiredFieldCodes.Except(
            normalized.Select(static option => option.FieldCode),
            StringComparer.Ordinal).Any())
    {
      throw new PrivateServerIntegrityException("runtime_graphics_option_set_invalid");
    }

    Options = Array.AsReadOnly(normalized);
  }

  public IReadOnlyList<RuntimeGraphicsOption> Options { get; }

  public bool IsLaunchReady =>
      Options.All(static option => option.Value.Status == ExecutionFactStatus.Ready);
}

public sealed class RuntimeExecutionSettingsSnapshot
{
  public RuntimeExecutionSettingsSnapshot(
      RuntimeSchedulerSettings scheduler,
      RuntimeDisplaySettings display,
      RuntimeGraphicsSettings graphics)
  {
    Scheduler = scheduler ?? throw new ArgumentNullException(nameof(scheduler));
    Display = display ?? throw new ArgumentNullException(nameof(display));
    Graphics = graphics ?? throw new ArgumentNullException(nameof(graphics));
    ContentSha256 = ComputeContentSha256(this);
  }

  public RuntimeSchedulerSettings Scheduler { get; }

  public RuntimeDisplaySettings Display { get; }

  public RuntimeGraphicsSettings Graphics { get; }

  public bool IsLaunchReady => Scheduler.IsLaunchReady && Display.IsLaunchReady && Graphics.IsLaunchReady;

  public Sha256Digest ContentSha256 { get; }

  private static Sha256Digest ComputeContentSha256(RuntimeExecutionSettingsSnapshot value) =>
      PrivateServerHash.Compute("nll/runtime-execution-settings/v1", hash =>
      {
        AppendFact(hash, value.Scheduler.TargetFrameRate, static item => ((int)item).ToString(CultureInfo.InvariantCulture));
        AppendFact(hash, value.Scheduler.FixedDeltaDenominator, static item => item.ToString(CultureInfo.InvariantCulture));
        AppendFact(hash, value.Scheduler.VsyncEnabled, FormatBool);
        AppendFact(hash, value.Scheduler.MultiplayerEnabled, FormatBool);
        AppendFact(hash, value.Scheduler.TimeScale, TimeScaleCode);
        AppendCodeFact(hash, value.Display.Platform);
        AppendCodeFact(hash, value.Display.DisplayMode);
        AppendFact(hash, value.Display.Width, static item => item.ToString(CultureInfo.InvariantCulture));
        AppendFact(hash, value.Display.Height, static item => item.ToString(CultureInfo.InvariantCulture));
        AppendFact(hash, value.Display.RefreshRateHz, static item => item.ToString("G29", CultureInfo.InvariantCulture));
        foreach (var option in value.Graphics.Options)
        {
          PrivateServerHash.Append(hash, option.FieldCode);
          AppendCodeFact(hash, option.Value);
        }
      });

  internal static void AppendFact<T>(
      System.Security.Cryptography.IncrementalHash hash,
      ExecutionFact<T> fact,
      Func<T, string> format)
      where T : struct
  {
    PrivateServerHash.Append(hash, FactStatusCode(fact.Status));
    PrivateServerHash.Append(hash, fact.Value.HasValue ? format(fact.Value.Value) : string.Empty);
    PrivateServerHash.Append(hash, fact.ReasonCode ?? string.Empty);
  }

  internal static void AppendCodeFact(
      System.Security.Cryptography.IncrementalHash hash,
      ExecutionCodeFact fact)
  {
    PrivateServerHash.Append(hash, FactStatusCode(fact.Status));
    PrivateServerHash.Append(hash, fact.ValueCode ?? string.Empty);
    PrivateServerHash.Append(hash, fact.ReasonCode ?? string.Empty);
  }

  public static string FactStatusCode(ExecutionFactStatus value) => value switch
  {
    ExecutionFactStatus.Ready => "ready",
    ExecutionFactStatus.Unresolved => "unresolved",
    ExecutionFactStatus.NotApplicable => "not_applicable",
    _ => throw new PrivateServerIntegrityException("execution_fact_status_invalid")
  };

  public static string TimeScaleCode(TimeScalePolicy value) => value switch
  {
    TimeScalePolicy.NormalOneX => "normal_1x",
    _ => throw new PrivateServerIntegrityException("runtime_time_scale_invalid")
  };

  private static string FormatBool(bool value) => value ? "true" : "false";
}

public sealed record OriginalClientRuntimeBuildBinding
{
  public OriginalClientRuntimeBuildBinding(
      ExecutionFactStatus status,
      EntityUid? buildUid = null,
      Sha256Digest? buildSha256 = null,
      string? unresolvedReasonCode = null)
  {
    if (!Enum.IsDefined(status) || status == ExecutionFactStatus.NotApplicable ||
        (status == ExecutionFactStatus.Ready &&
            (!buildUid.HasValue || !buildSha256.HasValue || unresolvedReasonCode is not null)) ||
        (status == ExecutionFactStatus.Unresolved &&
            (buildUid.HasValue || buildSha256.HasValue || unresolvedReasonCode is null)))
    {
      throw new PrivateServerIntegrityException("original_client_runtime_build_binding_invalid");
    }

    Status = status;
    BuildUid = buildUid.HasValue
        ? PrivateServerGuard.RequireUid(buildUid.Value, nameof(buildUid))
        : null;
    BuildSha256 = buildSha256.HasValue
        ? PrivateServerGuard.RequireDigest(buildSha256.Value, nameof(buildSha256))
        : null;
    UnresolvedReasonCode = unresolvedReasonCode is null
        ? null
        : PrivateServerGuard.RequireCode(unresolvedReasonCode, nameof(unresolvedReasonCode));
  }

  public ExecutionFactStatus Status { get; }

  public EntityUid? BuildUid { get; }

  public Sha256Digest? BuildSha256 { get; }

  public string? UnresolvedReasonCode { get; }

  public bool IsResolved => Status == ExecutionFactStatus.Ready;

  public static OriginalClientRuntimeBuildBinding Ready(
      EntityUid buildUid,
      Sha256Digest buildSha256) =>
      new(ExecutionFactStatus.Ready, buildUid, buildSha256);

  public static OriginalClientRuntimeBuildBinding Unresolved(
      string reasonCode = "original_client_runtime_build_unresolved") =>
      new(ExecutionFactStatus.Unresolved, unresolvedReasonCode: reasonCode);
}

public sealed class RuntimeExecutionProfileContent
{
  public RuntimeExecutionProfileContent(
      OriginalClientRuntimeBuildBinding originalClientRuntimeBuild,
      RuntimeExecutionSettingsSnapshot requested,
      RuntimeExecutionSettingsSnapshot? effective)
  {
    OriginalClientRuntimeBuild = originalClientRuntimeBuild ??
        throw new ArgumentNullException(nameof(originalClientRuntimeBuild));
    Requested = requested ?? throw new ArgumentNullException(nameof(requested));
    Effective = effective;
    ContentSha256 = PrivateServerHash.Compute("nll/runtime-execution-profile-content/v1", hash =>
    {
      PrivateServerHash.Append(hash, OriginalClientRuntimeBuild.BuildUid);
      PrivateServerHash.Append(hash, OriginalClientRuntimeBuild.BuildSha256);
      PrivateServerHash.Append(
          hash,
          RuntimeExecutionSettingsSnapshot.FactStatusCode(OriginalClientRuntimeBuild.Status));
      PrivateServerHash.Append(hash, OriginalClientRuntimeBuild.UnresolvedReasonCode ?? string.Empty);
      PrivateServerHash.Append(hash, Requested.ContentSha256);
      PrivateServerHash.Append(hash, Effective?.ContentSha256);
    });
  }

  public OriginalClientRuntimeBuildBinding OriginalClientRuntimeBuild { get; }

  public bool IsHarnessValidationReady => Requested.IsLaunchReady;

  public RuntimeExecutionSettingsSnapshot Requested { get; }

  public RuntimeExecutionSettingsSnapshot? Effective { get; }

  public bool IsOriginalClientLaunchReady =>
      OriginalClientRuntimeBuild.IsResolved && Requested.IsLaunchReady;

  public bool IsEffectiveReadbackReady =>
      IsOriginalClientLaunchReady && Effective is { IsLaunchReady: true } &&
      Effective.ContentSha256 == Requested.ContentSha256;

  public Sha256Digest ContentSha256 { get; }
}

public sealed class RuntimeExecutionProfileRevision
{
  private RuntimeExecutionProfileRevision(
      EntityUid profileUid,
      EntityUid revisionUid,
      EntityUid accountUid,
      long revisionNumber,
      EntityUid? predecessorRevisionUid,
      DateTimeOffset materializedAtUtc,
      RuntimeExecutionProfileContent content)
  {
    PrivateServerGuard.RequireRevisionShape(revisionNumber, predecessorRevisionUid);
    ProfileUid = PrivateServerGuard.RequireUid(profileUid, nameof(profileUid));
    RevisionUid = PrivateServerGuard.RequireUid(revisionUid, nameof(revisionUid));
    AccountUid = PrivateServerGuard.RequireUid(accountUid, nameof(accountUid));
    RevisionNumber = revisionNumber;
    PredecessorRevisionUid = predecessorRevisionUid;
    MaterializedAtUtc = PrivateServerGuard.NormalizeUtc(materializedAtUtc, nameof(materializedAtUtc));
    Content = content ?? throw new ArgumentNullException(nameof(content));
  }

  public EntityUid ProfileUid { get; }

  public EntityUid RevisionUid { get; }

  public EntityUid AccountUid { get; }

  public long RevisionNumber { get; }

  public EntityUid? PredecessorRevisionUid { get; }

  public DateTimeOffset MaterializedAtUtc { get; }

  public RuntimeExecutionProfileContent Content { get; }

  public Sha256Digest ContentSha256 => Content.ContentSha256;

  public static RuntimeExecutionProfileRevision Create(
      EntityUid profileUid,
      EntityUid revisionUid,
      EntityUid accountUid,
      DateTimeOffset materializedAtUtc,
      RuntimeExecutionProfileContent content) =>
      new(profileUid, revisionUid, accountUid, 1, null, materializedAtUtc, content);

  public RuntimeExecutionProfileRevision Revise(
      EntityUid nextRevisionUid,
      DateTimeOffset materializedAtUtc,
      RuntimeExecutionProfileContent content)
  {
    ArgumentNullException.ThrowIfNull(content);
    return content.ContentSha256 == ContentSha256
        ? this
        : new RuntimeExecutionProfileRevision(
            ProfileUid,
            nextRevisionUid,
            AccountUid,
            RevisionNumber + 1,
            RevisionUid,
            materializedAtUtc,
            content);
  }

  public static RuntimeExecutionProfileRevision Restore(
      EntityUid profileUid,
      EntityUid revisionUid,
      EntityUid accountUid,
      long revisionNumber,
      EntityUid? predecessorRevisionUid,
      DateTimeOffset materializedAtUtc,
      RuntimeExecutionProfileContent content) =>
      new(
          profileUid,
          revisionUid,
          accountUid,
          revisionNumber,
          predecessorRevisionUid,
          materializedAtUtc,
          content);
}

public sealed class CombatControlSettingsSnapshot
{
  public CombatControlSettingsSnapshot(
      ExecutionFact<decimal> aimSensitivity,
      ExecutionFact<bool> useAimAssistant,
      ExecutionFact<decimal> aimAssistantIntensity,
      ExecutionFact<bool> usePcAimSync,
      ExecutionFact<bool> maxPerShotCorrect,
      ExecutionFact<bool> autoCombat,
      ExecutionFact<bool> autoBurst)
  {
    AimSensitivity = aimSensitivity ?? throw new ArgumentNullException(nameof(aimSensitivity));
    UseAimAssistant = useAimAssistant ?? throw new ArgumentNullException(nameof(useAimAssistant));
    AimAssistantIntensity = aimAssistantIntensity ??
        throw new ArgumentNullException(nameof(aimAssistantIntensity));
    UsePcAimSync = usePcAimSync ?? throw new ArgumentNullException(nameof(usePcAimSync));
    MaxPerShotCorrect = maxPerShotCorrect ??
        throw new ArgumentNullException(nameof(maxPerShotCorrect));
    AutoCombat = autoCombat ?? throw new ArgumentNullException(nameof(autoCombat));
    AutoBurst = autoBurst ?? throw new ArgumentNullException(nameof(autoBurst));
    if (aimSensitivity.Value is < 0 || aimAssistantIntensity.Value is < 0)
    {
      throw new PrivateServerIntegrityException("combat_control_numeric_value_invalid");
    }


    if (aimSensitivity.Value.HasValue)
    {
      _ = PrivateServerGuard.RequireStorageDecimal(
          aimSensitivity.Value.Value,
          maximumIntegerDigits: 17,
          maximumScale: 12,
          errorCode: "combat_control_aim_sensitivity_storage_invalid");
    }

    if (aimAssistantIntensity.Value.HasValue)
    {
      _ = PrivateServerGuard.RequireStorageDecimal(
          aimAssistantIntensity.Value.Value,
          maximumIntegerDigits: 12,
          maximumScale: 8,
          errorCode: "combat_control_aim_intensity_storage_invalid");
    }

    if (useAimAssistant.Value == true &&
        aimAssistantIntensity.Status != ExecutionFactStatus.Ready)
    {
      throw new PrivateServerIntegrityException("aim_assistant_intensity_required");
    }

    if (useAimAssistant.Value == false &&
        aimAssistantIntensity.Status != ExecutionFactStatus.NotApplicable)
    {
      throw new PrivateServerIntegrityException("aim_assistant_intensity_not_applicable");
    }

    ContentSha256 = ComputeContentSha256(this);
  }

  public ExecutionFact<decimal> AimSensitivity { get; }

  public ExecutionFact<bool> UseAimAssistant { get; }

  public ExecutionFact<decimal> AimAssistantIntensity { get; }

  public ExecutionFact<bool> UsePcAimSync { get; }

  public ExecutionFact<bool> MaxPerShotCorrect { get; }

  public ExecutionFact<bool> AutoCombat { get; }

  public ExecutionFact<bool> AutoBurst { get; }

  public bool IsManualBattleReady =>
      AimSensitivity.Status == ExecutionFactStatus.Ready &&
      UseAimAssistant.Status == ExecutionFactStatus.Ready &&
      AimAssistantIntensity.IsResolved &&
      UsePcAimSync.Status == ExecutionFactStatus.Ready &&
      MaxPerShotCorrect.Status == ExecutionFactStatus.Ready;

  public Sha256Digest ContentSha256 { get; }

  private static Sha256Digest ComputeContentSha256(CombatControlSettingsSnapshot value) =>
      PrivateServerHash.Compute("nll/combat-control-settings/v1", hash =>
      {
        RuntimeExecutionSettingsSnapshot.AppendFact(
            hash,
            value.AimSensitivity,
            static item => item.ToString("G29", CultureInfo.InvariantCulture));
        RuntimeExecutionSettingsSnapshot.AppendFact(hash, value.UseAimAssistant, FormatBool);
        RuntimeExecutionSettingsSnapshot.AppendFact(
            hash,
            value.AimAssistantIntensity,
            static item => item.ToString("G29", CultureInfo.InvariantCulture));
        RuntimeExecutionSettingsSnapshot.AppendFact(hash, value.UsePcAimSync, FormatBool);
        RuntimeExecutionSettingsSnapshot.AppendFact(hash, value.MaxPerShotCorrect, FormatBool);
        RuntimeExecutionSettingsSnapshot.AppendFact(hash, value.AutoCombat, FormatBool);
        RuntimeExecutionSettingsSnapshot.AppendFact(hash, value.AutoBurst, FormatBool);
      });

  private static string FormatBool(bool value) => value ? "true" : "false";
}

public sealed class CombatControlProfileContent
{
  public CombatControlProfileContent(
      CombatControlSettingsSnapshot requested,
      CombatControlSettingsSnapshot? effective)
  {
    Requested = requested ?? throw new ArgumentNullException(nameof(requested));
    Effective = effective;
    ContentSha256 = PrivateServerHash.Compute("nll/combat-control-profile-content/v1", hash =>
    {
      PrivateServerHash.Append(hash, Requested.ContentSha256);
      PrivateServerHash.Append(hash, Effective?.ContentSha256);
    });
  }

  public CombatControlSettingsSnapshot Requested { get; }

  public CombatControlSettingsSnapshot? Effective { get; }

  public bool IsManualBattleReady => Requested.IsManualBattleReady;

  public bool IsEffectiveReadbackReady =>
      IsManualBattleReady && Effective is { IsManualBattleReady: true } &&
      Effective.ContentSha256 == Requested.ContentSha256;

  public Sha256Digest ContentSha256 { get; }
}

public sealed class CombatControlProfileRevision
{
  private CombatControlProfileRevision(
      EntityUid profileUid,
      EntityUid revisionUid,
      EntityUid accountUid,
      long revisionNumber,
      EntityUid? predecessorRevisionUid,
      DateTimeOffset materializedAtUtc,
      CombatControlProfileContent content)
  {
    PrivateServerGuard.RequireRevisionShape(revisionNumber, predecessorRevisionUid);
    ProfileUid = PrivateServerGuard.RequireUid(profileUid, nameof(profileUid));
    RevisionUid = PrivateServerGuard.RequireUid(revisionUid, nameof(revisionUid));
    AccountUid = PrivateServerGuard.RequireUid(accountUid, nameof(accountUid));
    RevisionNumber = revisionNumber;
    PredecessorRevisionUid = predecessorRevisionUid;
    MaterializedAtUtc = PrivateServerGuard.NormalizeUtc(materializedAtUtc, nameof(materializedAtUtc));
    Content = content ?? throw new ArgumentNullException(nameof(content));
  }

  public EntityUid ProfileUid { get; }

  public EntityUid RevisionUid { get; }

  public EntityUid AccountUid { get; }

  public long RevisionNumber { get; }

  public EntityUid? PredecessorRevisionUid { get; }

  public DateTimeOffset MaterializedAtUtc { get; }

  public CombatControlProfileContent Content { get; }

  public Sha256Digest ContentSha256 => Content.ContentSha256;

  public static CombatControlProfileRevision Create(
      EntityUid profileUid,
      EntityUid revisionUid,
      EntityUid accountUid,
      DateTimeOffset materializedAtUtc,
      CombatControlProfileContent content) =>
      new(profileUid, revisionUid, accountUid, 1, null, materializedAtUtc, content);

  public CombatControlProfileRevision Revise(
      EntityUid nextRevisionUid,
      DateTimeOffset materializedAtUtc,
      CombatControlProfileContent content)
  {
    ArgumentNullException.ThrowIfNull(content);
    return content.ContentSha256 == ContentSha256
        ? this
        : new CombatControlProfileRevision(
            ProfileUid,
            nextRevisionUid,
            AccountUid,
            RevisionNumber + 1,
            RevisionUid,
            materializedAtUtc,
            content);
  }

  public static CombatControlProfileRevision Restore(
      EntityUid profileUid,
      EntityUid revisionUid,
      EntityUid accountUid,
      long revisionNumber,
      EntityUid? predecessorRevisionUid,
      DateTimeOffset materializedAtUtc,
      CombatControlProfileContent content) =>
      new(
          profileUid,
          revisionUid,
          accountUid,
          revisionNumber,
          predecessorRevisionUid,
          materializedAtUtc,
          content);
}
