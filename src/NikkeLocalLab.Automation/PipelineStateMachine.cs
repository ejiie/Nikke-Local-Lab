using System.Collections.ObjectModel;
using System.Globalization;
using System.Text;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Automation;

public enum PipelineStepResult
{
  Succeeded,
  Failed,
  Blocked
}

public sealed record PipelineStepReceipt
{
  public PipelineStepReceipt(
      EntityUid receiptUid,
      Sha256Digest manifestSha256,
      string stepId,
      PipelineStepResult result,
      Sha256Digest inputSetSha256,
      Sha256Digest outputSetSha256,
      bool mutationPerformed,
      DateTimeOffset startedAtUtc,
      DateTimeOffset finishedAtUtc,
      IEnumerable<string>? reasonCodes = null)
  {
    if (receiptUid.Value == Guid.Empty || string.IsNullOrEmpty(manifestSha256.Hex) ||
        string.IsNullOrEmpty(inputSetSha256.Hex) || string.IsNullOrEmpty(outputSetSha256.Hex))
    {
      throw new ArgumentException("Pipeline receipt identities and digests must be initialized.");
    }

    var started = startedAtUtc.ToUniversalTime();
    var finished = finishedAtUtc.ToUniversalTime();
    if (finished < started)
    {
      throw new ArgumentOutOfRangeException(nameof(finishedAtUtc));
    }

    ReceiptUid = receiptUid;
    ManifestSha256 = manifestSha256;
    StepId = ControlledCode.Require(stepId, nameof(stepId));
    Result = result;
    InputSetSha256 = inputSetSha256;
    OutputSetSha256 = outputSetSha256;
    MutationPerformed = mutationPerformed;
    StartedAtUtc = started;
    FinishedAtUtc = finished;
    ReasonCodes = Array.AsReadOnly((reasonCodes ?? [])
        .Select(value => ControlledCode.Require(value, nameof(reasonCodes)))
        .Distinct(StringComparer.Ordinal)
        .OrderBy(static value => value, StringComparer.Ordinal)
        .ToArray());
    ReceiptSha256 = ComputeHash(this);
  }

  public EntityUid ReceiptUid { get; }

  public Sha256Digest ManifestSha256 { get; }

  public string StepId { get; }

  public PipelineStepResult Result { get; }

  public Sha256Digest InputSetSha256 { get; }

  public Sha256Digest OutputSetSha256 { get; }

  public bool MutationPerformed { get; }

  public DateTimeOffset StartedAtUtc { get; }

  public DateTimeOffset FinishedAtUtc { get; }

  public IReadOnlyList<string> ReasonCodes { get; }

  public Sha256Digest ReceiptSha256 { get; }

  private static Sha256Digest ComputeHash(PipelineStepReceipt value)
  {
    var canonical = string.Join(
        '\n',
        "nll/pipeline-step-receipt/v1",
        $"receipt-uid={value.ReceiptUid}",
        $"manifest={value.ManifestSha256.Hex}",
        $"step={value.StepId}",
        $"result={ResultCode(value.Result)}",
        $"input={value.InputSetSha256.Hex}",
        $"output={value.OutputSetSha256.Hex}",
        $"mutation={(value.MutationPerformed ? "true" : "false")}",
        $"started={value.StartedAtUtc:O}",
        $"finished={value.FinishedAtUtc:O}",
        $"reasons={string.Join(',', value.ReasonCodes)}");
    return Sha256Digest.ComputeUtf8(canonical);
  }

  public static string ResultCode(PipelineStepResult value) => value switch
  {
    PipelineStepResult.Succeeded => "succeeded",
    PipelineStepResult.Failed => "failed",
    PipelineStepResult.Blocked => "blocked",
    _ => throw new ArgumentOutOfRangeException(nameof(value))
  };
}

public sealed class PipelineRunState
{
  public PipelineRunState(
      EntityUid runUid,
      Sha256Digest manifestSha256,
      IEnumerable<PipelineStepReceipt>? receipts = null)
  {
    if (runUid.Value == Guid.Empty || string.IsNullOrEmpty(manifestSha256.Hex))
    {
      throw new ArgumentException("Pipeline state identities and digests must be initialized.");
    }

    RunUid = runUid;
    ManifestSha256 = manifestSha256;
    Receipts = Array.AsReadOnly((receipts ?? []).ToArray());
  }

  public EntityUid RunUid { get; }

  public Sha256Digest ManifestSha256 { get; }

  public IReadOnlyList<PipelineStepReceipt> Receipts { get; }

  public PipelineStepReceipt? LatestFor(string stepId) => Receipts.LastOrDefault(
      receipt => string.Equals(receipt.StepId, stepId, StringComparison.Ordinal));
}

public sealed record PipelineTransition(PipelineRunState State, bool ReusedExistingReceipt);

public static class PipelineStateMachine
{
  public static PipelineTransition Record(
      PipelineRunManifest manifest,
      PipelineRunState state,
      PipelineStepReceipt receipt)
  {
    ArgumentNullException.ThrowIfNull(manifest);
    ArgumentNullException.ThrowIfNull(state);
    ArgumentNullException.ThrowIfNull(receipt);
    if (state.ManifestSha256 != manifest.ContentSha256 || receipt.ManifestSha256 != manifest.ContentSha256)
    {
      throw new PipelineStateException("pipeline_manifest_drift");
    }

    var step = manifest.RequireStep(receipt.StepId);
    if (!step.Mutation && receipt.MutationPerformed)
    {
      throw new PipelineStateException("pipeline_read_only_step_mutated");
    }

    if (step.Mutation && receipt.Result == PipelineStepResult.Succeeded && !receipt.MutationPerformed)
    {
      throw new PipelineStateException("pipeline_mutating_step_reported_no_mutation");
    }

    var current = state.LatestFor(step.StepId);
    if (current is { Result: PipelineStepResult.Succeeded })
    {
      if (current.InputSetSha256 == receipt.InputSetSha256 &&
          current.OutputSetSha256 == receipt.OutputSetSha256 &&
          current.MutationPerformed == receipt.MutationPerformed &&
          receipt.Result == PipelineStepResult.Succeeded)
      {
        return new PipelineTransition(state, true);
      }

      throw new PipelineStateException("pipeline_completed_step_drift");
    }

    foreach (var dependency in step.DependencyStepIds)
    {
      if (state.LatestFor(dependency)?.Result != PipelineStepResult.Succeeded)
      {
        throw new PipelineStateException("pipeline_dependency_incomplete");
      }
    }

    return new PipelineTransition(
        new PipelineRunState(state.RunUid, state.ManifestSha256, state.Receipts.Append(receipt)),
        false);
  }

  public static IReadOnlyList<string> GetRunnableStepIds(
      PipelineRunManifest manifest,
      PipelineRunState state)
  {
    ArgumentNullException.ThrowIfNull(manifest);
    ArgumentNullException.ThrowIfNull(state);
    if (state.ManifestSha256 != manifest.ContentSha256)
    {
      throw new PipelineStateException("pipeline_manifest_drift");
    }

    return Array.AsReadOnly(manifest.Steps
        .Where(step => state.LatestFor(step.StepId)?.Result != PipelineStepResult.Succeeded)
        .Where(step => step.DependencyStepIds.All(
            dependency => state.LatestFor(dependency)?.Result == PipelineStepResult.Succeeded))
        .Select(static step => step.StepId)
        .ToArray());
  }
}

public sealed class PipelineStateException : Exception
{
  public PipelineStateException(string failureCode)
      : base("The pipeline state transition is invalid.")
  {
    FailureCode = ControlledCode.Require(failureCode, nameof(failureCode));
  }

  public string FailureCode { get; }
}

public sealed record StagePlan(
    string ContractId,
    EntityUid PipelineUid,
    Sha256Digest ManifestSha256,
    string StageStepId,
    bool StageReady,
    bool MutationPerformed,
    IReadOnlyList<PipelineAction> PlannedActions,
    IReadOnlyList<PipelineAction> RollbackActions);

public static class StagePlanFactory
{
  public const string ContractId = "nll/pipeline-stage-plan/v1";

  public static StagePlan Create(PipelineRunManifest manifest, PipelineRunState state)
  {
    ArgumentNullException.ThrowIfNull(manifest);
    ArgumentNullException.ThrowIfNull(state);
    if (state.ManifestSha256 != manifest.ContentSha256)
    {
      throw new PipelineStateException("pipeline_manifest_drift");
    }

    var stage = manifest.Steps.SingleOrDefault(static step => step.Kind == PipelineStepKind.Stage) ??
        throw new PipelineStateException("pipeline_stage_step_missing");
    var ready = stage.DependencyStepIds.All(
        dependency => state.LatestFor(dependency)?.Result == PipelineStepResult.Succeeded);
    return new StagePlan(
        ContractId,
        manifest.PipelineUid,
        manifest.ContentSha256,
        stage.StepId,
        ready,
        false,
        stage.Actions,
        stage.RollbackActions);
  }
}

public sealed record RollbackPlan(
    string ContractId,
    EntityUid PipelineUid,
    Sha256Digest ManifestSha256,
    bool RollbackRequired,
    bool MutationPerformed,
    IReadOnlyList<string> AffectedStepIds,
    IReadOnlyList<PipelineAction> PlannedActions);

public static class RollbackPlanFactory
{
  public const string ContractId = "nll/pipeline-rollback-plan/v1";

  public static RollbackPlan Create(PipelineRunManifest manifest, PipelineRunState state)
  {
    ArgumentNullException.ThrowIfNull(manifest);
    ArgumentNullException.ThrowIfNull(state);
    if (state.ManifestSha256 != manifest.ContentSha256)
    {
      throw new PipelineStateException("pipeline_manifest_drift");
    }

    var affectedSteps = manifest.Steps
        .Where(step => step.Mutation && state.LatestFor(step.StepId)?.MutationPerformed == true)
        .Reverse()
        .ToArray();
    var actions = affectedSteps
        .SelectMany(static step => step.RollbackActions.Reverse())
        .ToArray();
    return new RollbackPlan(
        ContractId,
        manifest.PipelineUid,
        manifest.ContentSha256,
        affectedSteps.Length != 0,
        false,
        Array.AsReadOnly(affectedSteps.Select(static step => step.StepId).ToArray()),
        Array.AsReadOnly(actions));
  }
}
