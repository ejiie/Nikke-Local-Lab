using NikkeLocalLab.Automation;

namespace NikkeLocalLab.Automation.UnitTests;

public sealed class PipelineStateMachineTests
{
  [Fact]
  public void ExactSuccessfulReplayReusesExistingReceipt()
  {
    var manifest = PipelineManifestTests.Manifest();
    var state = new PipelineRunState(PipelineManifestTests.Uid(20), manifest.ContentSha256);
    var receipt = Receipt(manifest, "inventory", PipelineStepResult.Succeeded, "input", "output");

    var first = PipelineStateMachine.Record(manifest, state, receipt);
    var replay = PipelineStateMachine.Record(manifest, first.State, receipt);

    Assert.False(first.ReusedExistingReceipt);
    Assert.True(replay.ReusedExistingReceipt);
    Assert.Same(first.State, replay.State);
    Assert.Single(replay.State.Receipts);
  }

  [Fact]
  public void ChangedOutputAfterSuccessIsDrift()
  {
    var manifest = PipelineManifestTests.Manifest();
    var state = new PipelineRunState(PipelineManifestTests.Uid(21), manifest.ContentSha256);
    state = PipelineStateMachine.Record(
        manifest,
        state,
        Receipt(manifest, "inventory", PipelineStepResult.Succeeded, "input", "output-a")).State;

    var exception = Assert.Throws<PipelineStateException>(() => PipelineStateMachine.Record(
        manifest,
        state,
        Receipt(manifest, "inventory", PipelineStepResult.Succeeded, "input", "output-b")));

    Assert.Equal("pipeline_completed_step_drift", exception.FailureCode);
  }

  [Fact]
  public void FailedStepCanResumeWithoutRepeatingSuccessfulDependency()
  {
    var manifest = PipelineManifestTests.Manifest();
    var state = new PipelineRunState(PipelineManifestTests.Uid(22), manifest.ContentSha256);
    state = PipelineStateMachine.Record(
        manifest,
        state,
        Receipt(manifest, "inventory", PipelineStepResult.Succeeded, "input", "inventory-ok")).State;
    state = PipelineStateMachine.Record(
        manifest,
        state,
        Receipt(manifest, "validate", PipelineStepResult.Failed, "inventory-ok", "validation-failed")).State;

    Assert.Equal(["validate"], PipelineStateMachine.GetRunnableStepIds(manifest, state));

    state = PipelineStateMachine.Record(
        manifest,
        state,
        Receipt(manifest, "validate", PipelineStepResult.Succeeded, "inventory-ok", "validation-ok")).State;

    Assert.Equal(["stage"], PipelineStateMachine.GetRunnableStepIds(manifest, state));
    Assert.Equal(3, state.Receipts.Count);
  }

  [Fact]
  public void StagePlanIsReadOnlyAndReadyAfterValidation()
  {
    var manifest = PipelineManifestTests.Manifest();
    var state = new PipelineRunState(PipelineManifestTests.Uid(23), manifest.ContentSha256);
    state = PipelineStateMachine.Record(
        manifest,
        state,
        Receipt(manifest, "inventory", PipelineStepResult.Succeeded, "input", "inventory-ok")).State;
    state = PipelineStateMachine.Record(
        manifest,
        state,
        Receipt(manifest, "validate", PipelineStepResult.Succeeded, "inventory-ok", "validation-ok")).State;

    var plan = StagePlanFactory.Create(manifest, state);

    Assert.True(plan.StageReady);
    Assert.False(plan.MutationPerformed);
    Assert.Single(plan.PlannedActions);
    Assert.Single(plan.RollbackActions);
  }

  [Fact]
  public void CannotRunValidationBeforeInventory()
  {
    var manifest = PipelineManifestTests.Manifest();
    var state = new PipelineRunState(PipelineManifestTests.Uid(24), manifest.ContentSha256);

    var exception = Assert.Throws<PipelineStateException>(() => PipelineStateMachine.Record(
        manifest,
        state,
        Receipt(manifest, "validate", PipelineStepResult.Succeeded, "input", "output")));

    Assert.Equal("pipeline_dependency_incomplete", exception.FailureCode);
  }

  [Fact]
  public void PartialMutationProducesReverseRollbackPlan()
  {
    var manifest = PipelineManifestTests.Manifest();
    var state = new PipelineRunState(PipelineManifestTests.Uid(25), manifest.ContentSha256);
    state = PipelineStateMachine.Record(
        manifest,
        state,
        Receipt(manifest, "inventory", PipelineStepResult.Succeeded, "input", "inventory-ok")).State;
    state = PipelineStateMachine.Record(
        manifest,
        state,
        Receipt(manifest, "validate", PipelineStepResult.Succeeded, "inventory-ok", "validation-ok")).State;
    state = PipelineStateMachine.Record(
        manifest,
        state,
        Receipt(manifest, "stage", PipelineStepResult.Failed, "validation-ok", "partial-stage", true)).State;

    var plan = RollbackPlanFactory.Create(manifest, state);

    Assert.True(plan.RollbackRequired);
    Assert.False(plan.MutationPerformed);
    Assert.Equal(["stage"], plan.AffectedStepIds);
    Assert.Single(plan.PlannedActions);
    Assert.Equal("remove_candidate", plan.PlannedActions[0].ActionCode);
  }

  [Fact]
  public void SuccessfulMutatingStepCannotClaimNoMutation()
  {
    var manifest = PipelineManifestTests.Manifest();
    var state = new PipelineRunState(PipelineManifestTests.Uid(26), manifest.ContentSha256);
    state = PipelineStateMachine.Record(
        manifest,
        state,
        Receipt(manifest, "inventory", PipelineStepResult.Succeeded, "input", "inventory-ok")).State;
    state = PipelineStateMachine.Record(
        manifest,
        state,
        Receipt(manifest, "validate", PipelineStepResult.Succeeded, "inventory-ok", "validation-ok")).State;

    var exception = Assert.Throws<PipelineStateException>(() => PipelineStateMachine.Record(
        manifest,
        state,
        Receipt(manifest, "stage", PipelineStepResult.Succeeded, "validation-ok", "stage-ok")));

    Assert.Equal("pipeline_mutating_step_reported_no_mutation", exception.FailureCode);
  }

  private static PipelineStepReceipt Receipt(
      PipelineRunManifest manifest,
      string step,
      PipelineStepResult result,
      string input,
      string output,
      bool mutationPerformed = false) => new(
      PipelineManifestTests.Uid(Random.Shared.Next(1000, 999999)),
      manifest.ContentSha256,
      step,
      result,
      PipelineManifestTests.Hash(input),
      PipelineManifestTests.Hash(output),
      mutationPerformed,
      DateTimeOffset.Parse("2026-08-28T00:00:00Z", System.Globalization.CultureInfo.InvariantCulture),
      DateTimeOffset.Parse("2026-08-28T00:00:01Z", System.Globalization.CultureInfo.InvariantCulture),
      result == PipelineStepResult.Succeeded ? [] : ["test_failure"]);
}
