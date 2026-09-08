using System.Collections.ObjectModel;
using System.Globalization;
using System.Text;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Automation;

public enum PipelineStepKind
{
  Inventory,
  Validate,
  Project,
  Build,
  Stage,
  Run,
  Complete,
  Promote,
  Backup
}

public sealed record PipelineTarget
{
  public PipelineTarget(
      string kindCode,
      int? seasonNumber,
      string clientBuildCode,
      string modeCode)
  {
    if (seasonNumber is <= 0)
    {
      throw new ArgumentOutOfRangeException(nameof(seasonNumber));
    }

    KindCode = ControlledCode.Require(kindCode, nameof(kindCode));
    SeasonNumber = seasonNumber;
    ClientBuildCode = ControlledCode.Require(clientBuildCode, nameof(clientBuildCode));
    ModeCode = ControlledCode.Require(modeCode, nameof(modeCode));
  }

  public string KindCode { get; }

  public int? SeasonNumber { get; }

  public string ClientBuildCode { get; }

  public string ModeCode { get; }
}

public sealed record PipelineArtifactSpec
{
  public PipelineArtifactSpec(
      string roleCode,
      string relativePath,
      long byteLength,
      Sha256Digest sha256)
  {
    if (byteLength < 0)
    {
      throw new ArgumentOutOfRangeException(nameof(byteLength));
    }

    RoleCode = ControlledCode.Require(roleCode, nameof(roleCode));
    RelativePath = RequireRelativePath(relativePath);
    ByteLength = byteLength;
    Sha256 = RequireDigest(sha256, nameof(sha256));
  }

  public string RoleCode { get; }

  public string RelativePath { get; }

  public long ByteLength { get; }

  public Sha256Digest Sha256 { get; }

  private static string RequireRelativePath(string value)
  {
    if (string.IsNullOrWhiteSpace(value) || Path.IsPathRooted(value))
    {
      throw new ArgumentException("A pipeline artifact path must be a non-empty relative path.", nameof(value));
    }

    var normalized = value.Replace('\\', '/').Trim();
    var segments = normalized.Split('/', StringSplitOptions.RemoveEmptyEntries);
    if (segments.Length == 0 || segments.Any(static segment => segment is "." or ".."))
    {
      throw new ArgumentException("A pipeline artifact path cannot traverse its inventory root.", nameof(value));
    }

    return string.Join('/', segments);
  }

  private static Sha256Digest RequireDigest(Sha256Digest value, string parameterName)
  {
    if (string.IsNullOrEmpty(value.Hex))
    {
      throw new ArgumentException("A pipeline digest must be initialized.", parameterName);
    }

    return value;
  }
}

public sealed record PipelineAction
{
  public PipelineAction(string actionCode, string targetRoleCode)
  {
    ActionCode = ControlledCode.Require(actionCode, nameof(actionCode));
    TargetRoleCode = ControlledCode.Require(targetRoleCode, nameof(targetRoleCode));
  }

  public string ActionCode { get; }

  public string TargetRoleCode { get; }
}

public sealed record PipelineStepDefinition
{
  public PipelineStepDefinition(
      string stepId,
      PipelineStepKind kind,
      bool mutation,
      IEnumerable<string>? dependencyStepIds,
      IEnumerable<string>? outputRoleCodes,
      IEnumerable<PipelineAction>? actions = null,
      IEnumerable<PipelineAction>? rollbackActions = null)
  {
    StepId = ControlledCode.Require(stepId, nameof(stepId));
    Kind = kind;
    Mutation = mutation;
    DependencyStepIds = NormalizeCodes(dependencyStepIds, nameof(dependencyStepIds));
    OutputRoleCodes = NormalizeCodes(outputRoleCodes, nameof(outputRoleCodes));
    Actions = NormalizeActions(actions, nameof(actions));
    RollbackActions = NormalizeActions(rollbackActions, nameof(rollbackActions));

    if ((kind is PipelineStepKind.Inventory or PipelineStepKind.Validate) && mutation)
    {
      throw new ArgumentException("Inventory and validation steps must be read-only.", nameof(mutation));
    }

    if (mutation && (Actions.Count == 0 || RollbackActions.Count == 0))
    {
      throw new ArgumentException("A mutating pipeline step must declare actions and rollback actions.", nameof(actions));
    }

    if (!mutation && (Actions.Count != 0 || RollbackActions.Count != 0))
    {
      throw new ArgumentException("A read-only pipeline step cannot declare mutation or rollback actions.", nameof(actions));
    }
  }

  public string StepId { get; }

  public PipelineStepKind Kind { get; }

  public bool Mutation { get; }

  public IReadOnlyList<string> DependencyStepIds { get; }

  public IReadOnlyList<string> OutputRoleCodes { get; }

  public IReadOnlyList<PipelineAction> Actions { get; }

  public IReadOnlyList<PipelineAction> RollbackActions { get; }

  private static IReadOnlyList<string> NormalizeCodes(IEnumerable<string>? values, string parameterName)
  {
    var normalized = (values ?? []).Select(value => ControlledCode.Require(value, parameterName)).ToArray();
    if (normalized.Distinct(StringComparer.Ordinal).Count() != normalized.Length)
    {
      throw new ArgumentException("Pipeline controlled-code collections must be unique.", parameterName);
    }

    return Array.AsReadOnly(normalized);
  }

  private static IReadOnlyList<PipelineAction> NormalizeActions(
      IEnumerable<PipelineAction>? values,
      string parameterName)
  {
    var normalized = (values ?? []).ToArray();
    if (normalized.Any(static value => value is null) ||
        normalized.Select(static value => (value.ActionCode, value.TargetRoleCode)).Distinct().Count() != normalized.Length)
    {
      throw new ArgumentException("Pipeline actions must be non-null and unique.", parameterName);
    }

    return Array.AsReadOnly(normalized);
  }
}

public sealed class PipelineRunManifest
{
  public const string ContractId = "nll/pipeline-run-manifest/v1";

  public PipelineRunManifest(
      EntityUid pipelineUid,
      PipelineTarget target,
      IEnumerable<PipelineArtifactSpec> inputs,
      IEnumerable<PipelineStepDefinition> steps)
  {
    PipelineUid = pipelineUid.Value == Guid.Empty
        ? throw new ArgumentException("A pipeline UID cannot be empty.", nameof(pipelineUid))
        : pipelineUid;
    Target = target ?? throw new ArgumentNullException(nameof(target));
    Inputs = NormalizeInputs(inputs);
    Steps = NormalizeSteps(steps);
    ContentSha256 = PipelineManifestCanonicalizer.Compute(this);
  }

  public EntityUid PipelineUid { get; }

  public PipelineTarget Target { get; }

  public IReadOnlyList<PipelineArtifactSpec> Inputs { get; }

  public IReadOnlyList<PipelineStepDefinition> Steps { get; }

  public Sha256Digest ContentSha256 { get; }

  public PipelineStepDefinition RequireStep(string stepId) =>
      Steps.SingleOrDefault(step => string.Equals(step.StepId, stepId, StringComparison.Ordinal)) ??
      throw new PipelineManifestException("pipeline_step_unknown");

  private static IReadOnlyList<PipelineArtifactSpec> NormalizeInputs(IEnumerable<PipelineArtifactSpec> inputs)
  {
    ArgumentNullException.ThrowIfNull(inputs);
    var values = inputs.ToArray();
    if (values.Length == 0 || values.Any(static value => value is null) ||
        values.Select(static value => value.RoleCode).Distinct(StringComparer.Ordinal).Count() != values.Length ||
        values.Select(static value => value.RelativePath).Distinct(StringComparer.OrdinalIgnoreCase).Count() != values.Length)
    {
      throw new PipelineManifestException("pipeline_inputs_invalid");
    }

    return Array.AsReadOnly(values.OrderBy(static value => value.RoleCode, StringComparer.Ordinal).ToArray());
  }

  private static IReadOnlyList<PipelineStepDefinition> NormalizeSteps(IEnumerable<PipelineStepDefinition> steps)
  {
    ArgumentNullException.ThrowIfNull(steps);
    var values = steps.ToArray();
    if (values.Length == 0 || values.Any(static value => value is null) ||
        values.Select(static value => value.StepId).Distinct(StringComparer.Ordinal).Count() != values.Length)
    {
      throw new PipelineManifestException("pipeline_steps_invalid");
    }

    var known = new HashSet<string>(StringComparer.Ordinal);
    foreach (var step in values)
    {
      if (step.DependencyStepIds.Any(dependency => !known.Contains(dependency)))
      {
        throw new PipelineManifestException("pipeline_dependency_order_invalid");
      }

      known.Add(step.StepId);
    }

    var outputCodes = values.SelectMany(static step => step.OutputRoleCodes).ToArray();
    if (outputCodes.Distinct(StringComparer.Ordinal).Count() != outputCodes.Length)
    {
      throw new PipelineManifestException("pipeline_output_roles_duplicate");
    }

    return Array.AsReadOnly(values);
  }
}

public static class PipelineManifestCanonicalizer
{
  public static Sha256Digest Compute(PipelineRunManifest manifest)
  {
    ArgumentNullException.ThrowIfNull(manifest);
    var text = new StringBuilder();
    text.Append(PipelineRunManifest.ContractId).Append('\n');
    text.Append("pipeline-uid=").Append(manifest.PipelineUid).Append('\n');
    text.Append("target.kind=").Append(manifest.Target.KindCode).Append('\n');
    text.Append("target.season=").Append(manifest.Target.SeasonNumber?.ToString(CultureInfo.InvariantCulture) ?? "null").Append('\n');
    text.Append("target.client-build=").Append(manifest.Target.ClientBuildCode).Append('\n');
    text.Append("target.mode=").Append(manifest.Target.ModeCode).Append('\n');
    text.Append("inputs.count=").Append(manifest.Inputs.Count.ToString(CultureInfo.InvariantCulture)).Append('\n');
    foreach (var input in manifest.Inputs)
    {
      text.Append("input=")
          .Append(input.RoleCode).Append('\t')
          .Append(input.RelativePath).Append('\t')
          .Append(input.ByteLength.ToString(CultureInfo.InvariantCulture)).Append('\t')
          .Append(input.Sha256.Hex).Append('\n');
    }

    text.Append("steps.count=").Append(manifest.Steps.Count.ToString(CultureInfo.InvariantCulture)).Append('\n');
    foreach (var step in manifest.Steps)
    {
      text.Append("step=")
          .Append(step.StepId).Append('\t')
          .Append(StepKindCode(step.Kind)).Append('\t')
          .Append(step.Mutation ? "true" : "false").Append('\t')
          .Append(string.Join(',', step.DependencyStepIds)).Append('\t')
          .Append(string.Join(',', step.OutputRoleCodes)).Append('\n');
      foreach (var action in step.Actions)
      {
        text.Append("action=").Append(step.StepId).Append('\t')
            .Append(action.ActionCode).Append('\t').Append(action.TargetRoleCode).Append('\n');
      }

      foreach (var rollback in step.RollbackActions)
      {
        text.Append("rollback=").Append(step.StepId).Append('\t')
            .Append(rollback.ActionCode).Append('\t').Append(rollback.TargetRoleCode).Append('\n');
      }
    }

    return Sha256Digest.ComputeUtf8(text.ToString());
  }

  internal static string StepKindCode(PipelineStepKind value) => value switch
  {
    PipelineStepKind.Inventory => "inventory",
    PipelineStepKind.Validate => "validate",
    PipelineStepKind.Project => "project",
    PipelineStepKind.Build => "build",
    PipelineStepKind.Stage => "stage",
    PipelineStepKind.Run => "run",
    PipelineStepKind.Complete => "complete",
    PipelineStepKind.Promote => "promote",
    PipelineStepKind.Backup => "backup",
    _ => throw new ArgumentOutOfRangeException(nameof(value))
  };
}

public sealed class PipelineManifestException : Exception
{
  public PipelineManifestException(string failureCode)
      : base("The pipeline manifest is invalid.")
  {
    FailureCode = ControlledCode.Require(failureCode, nameof(failureCode));
  }

  public string FailureCode { get; }
}
