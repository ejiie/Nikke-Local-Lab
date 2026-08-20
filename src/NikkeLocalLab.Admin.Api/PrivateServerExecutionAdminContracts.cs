namespace NikkeLocalLab.Admin.Api;

internal sealed record ExecutionIntegerFactRequest(
    string? StatusCode,
    int? Value,
    string? ReasonCode);

internal sealed record ExecutionBooleanFactRequest(
    string? StatusCode,
    bool? Value,
    string? ReasonCode);

internal sealed record ExecutionDecimalFactRequest(
    string? StatusCode,
    decimal? Value,
    string? ReasonCode);

internal sealed record ExecutionCodeFactRequest(
    string? StatusCode,
    string? ValueCode,
    string? ReasonCode);

internal sealed record OriginalRuntimeBuildBindingRequest(
    string? StatusCode,
    string? BuildUid,
    string? BuildSha256,
    string? UnresolvedReasonCode);

internal sealed record RuntimeSchedulerSettingsRequest(
    ExecutionIntegerFactRequest? TargetFrameRate,
    ExecutionIntegerFactRequest? FixedDeltaDenominator,
    ExecutionBooleanFactRequest? VsyncEnabled,
    ExecutionBooleanFactRequest? MultiplayerEnabled,
    ExecutionCodeFactRequest? TimeScale);

internal sealed record RuntimeDisplaySettingsRequest(
    ExecutionCodeFactRequest? Platform,
    ExecutionCodeFactRequest? DisplayMode,
    ExecutionIntegerFactRequest? Width,
    ExecutionIntegerFactRequest? Height,
    ExecutionDecimalFactRequest? RefreshRateHz);

internal sealed record RuntimeGraphicsOptionRequest(
    string? FieldCode,
    ExecutionCodeFactRequest? Value);

internal sealed record RuntimeExecutionSettingsRequest(
    RuntimeSchedulerSettingsRequest? Scheduler,
    RuntimeDisplaySettingsRequest? Display,
    IReadOnlyList<RuntimeGraphicsOptionRequest?>? Graphics);

internal sealed record RuntimeExecutionProfileContentRequest(
    OriginalRuntimeBuildBindingRequest? OriginalClientRuntimeBuild,
    RuntimeExecutionSettingsRequest? Requested,
    string? EffectiveReadbackStatusCode,
    RuntimeExecutionSettingsRequest? Effective);

internal sealed record SaveRuntimeExecutionProfileRequest(
    string? OperationUid,
    string? ProfileUid,
    RuntimeExecutionProfileContentRequest? Content);

internal sealed record CombatControlSettingsRequest(
    ExecutionDecimalFactRequest? AimSensitivity,
    ExecutionBooleanFactRequest? UseAimAssistant,
    ExecutionDecimalFactRequest? AimAssistantIntensity,
    ExecutionBooleanFactRequest? UsePcAimSync,
    ExecutionBooleanFactRequest? MaxPerShotCorrect,
    ExecutionBooleanFactRequest? AutoCombat,
    ExecutionBooleanFactRequest? AutoBurst);

internal sealed record CombatControlProfileContentRequest(
    CombatControlSettingsRequest? Requested,
    string? EffectiveReadbackStatusCode,
    CombatControlSettingsRequest? Effective);

internal sealed record SaveCombatControlProfileRequest(
    string? OperationUid,
    string? ProfileUid,
    CombatControlProfileContentRequest? Content);
