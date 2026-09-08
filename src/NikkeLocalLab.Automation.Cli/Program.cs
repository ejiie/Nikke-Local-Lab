using System.Text.Json;
using NikkeLocalLab.Automation;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

return await AutomationCli.RunAsync(args);

internal static class AutomationCli
{
  private static readonly JsonSerializerOptions OutputOptions = new()
  {
    WriteIndented = true,
    PropertyNamingPolicy = JsonNamingPolicy.CamelCase
  };

  public static async Task<int> RunAsync(string[] args)
  {
    try
    {
      if (args.Length != 4 || !string.Equals(args[0], "dry-run", StringComparison.Ordinal))
      {
        Console.Error.WriteLine("usage: NikkeLocalLab.Automation.Cli dry-run <manifest.json> <inventory-root> <output-directory>");
        return 2;
      }

      var manifestPath = Path.GetFullPath(args[1]);
      var inventoryRoot = Path.GetFullPath(args[2]);
      var outputDirectory = Path.GetFullPath(args[3]);
      var manifest = PipelineManifestJson.Deserialize(await File.ReadAllTextAsync(manifestPath).ConfigureAwait(false));
      var startedAt = DateTimeOffset.UtcNow;
      var inventory = await FileInventoryVerifier.ObserveAsync(manifest, inventoryRoot).ConfigureAwait(false);
      var state = new PipelineRunState(EntityUid.New(), manifest.ContentSha256);
      var inventoryStep = manifest.Steps.Single(static step => step.Kind == PipelineStepKind.Inventory);
      var inventoryReceipt = new PipelineStepReceipt(
          EntityUid.New(),
          manifest.ContentSha256,
          inventoryStep.StepId,
          inventory.AllMatched ? PipelineStepResult.Succeeded : PipelineStepResult.Blocked,
          manifest.ContentSha256,
          inventory.CanonicalSha256,
          false,
          startedAt,
          DateTimeOffset.UtcNow,
          inventory.AllMatched ? [] : ["pipeline_inventory_drift"]);
      state = PipelineStateMachine.Record(manifest, state, inventoryReceipt).State;

      PipelineStepReceipt? validationReceipt = null;
      if (inventory.AllMatched)
      {
        var validationStep = manifest.Steps.Single(static step => step.Kind == PipelineStepKind.Validate);
        validationReceipt = new PipelineStepReceipt(
            EntityUid.New(),
            manifest.ContentSha256,
            validationStep.StepId,
            PipelineStepResult.Succeeded,
            inventory.CanonicalSha256,
            manifest.ContentSha256,
            false,
            DateTimeOffset.UtcNow,
            DateTimeOffset.UtcNow);
        state = PipelineStateMachine.Record(manifest, state, validationReceipt).State;
      }

      var stagePlan = StagePlanFactory.Create(manifest, state);
      Directory.CreateDirectory(outputDirectory);
      await WriteJsonAsync(Path.Combine(outputDirectory, "inventory.receipt.json"), InventoryDocument(manifest, inventoryReceipt, inventory)).ConfigureAwait(false);
      if (validationReceipt is not null)
      {
        await WriteJsonAsync(Path.Combine(outputDirectory, "validation.receipt.json"), ReceiptDocument(validationReceipt)).ConfigureAwait(false);
      }

      await WriteJsonAsync(Path.Combine(outputDirectory, "pipeline.state.json"), StateDocument(state)).ConfigureAwait(false);
      await WriteJsonAsync(Path.Combine(outputDirectory, "stage.plan.json"), StagePlanDocument(stagePlan)).ConfigureAwait(false);

      Console.WriteLine(JsonSerializer.Serialize(new
      {
        contractId = "nll/pipeline-dry-run-summary/v1",
        pipelineUid = manifest.PipelineUid.ToString(),
        manifestSha256 = manifest.ContentSha256.Hex,
        inventoryMatched = inventory.AllMatched,
        inputCount = inventory.Observations.Count,
        stageReady = stagePlan.StageReady,
        mutationPerformed = false
      }, OutputOptions));
      return stagePlan.StageReady ? 0 : 10;
    }
    catch (Exception exception) when (exception is PipelineManifestException or PipelineStateException or
                                      FormatException or IOException or UnauthorizedAccessException)
    {
      var code = exception switch
      {
        PipelineManifestException manifest => manifest.FailureCode,
        PipelineStateException state => state.FailureCode,
        _ => "pipeline_dry_run_failed"
      };
      Console.Error.WriteLine(code);
      return 20;
    }
  }

  private static object InventoryDocument(
      PipelineRunManifest manifest,
      PipelineStepReceipt receipt,
      InventoryObservationSet inventory) => new
      {
        schemaVersion = 1,
        contractId = "nll/pipeline-inventory-receipt/v1",
        pipelineUid = manifest.PipelineUid.ToString(),
        manifestSha256 = manifest.ContentSha256.Hex,
        receipt = ReceiptDocument(receipt),
        allMatched = inventory.AllMatched,
        observationSetSha256 = inventory.CanonicalSha256.Hex,
        observations = inventory.Observations.Select(observation => new
        {
          roleCode = observation.RoleCode,
          observedByteLength = observation.ObservedByteLength,
          observedSha256 = observation.ObservedSha256?.Hex,
          statusCode = InventoryObservationSet.StatusCode(observation.Status)
        })
      };

  private static object ReceiptDocument(PipelineStepReceipt receipt) => new
  {
    receiptUid = receipt.ReceiptUid.ToString(),
    receiptSha256 = receipt.ReceiptSha256.Hex,
    manifestSha256 = receipt.ManifestSha256.Hex,
    stepId = receipt.StepId,
    resultCode = PipelineStepReceipt.ResultCode(receipt.Result),
    inputSetSha256 = receipt.InputSetSha256.Hex,
    outputSetSha256 = receipt.OutputSetSha256.Hex,
    mutationPerformed = receipt.MutationPerformed,
    startedAtUtc = receipt.StartedAtUtc.ToString("O"),
    finishedAtUtc = receipt.FinishedAtUtc.ToString("O"),
    reasonCodes = receipt.ReasonCodes
  };

  private static object StateDocument(PipelineRunState state) => new
  {
    schemaVersion = 1,
    contractId = "nll/pipeline-run-state/v1",
    runUid = state.RunUid.ToString(),
    manifestSha256 = state.ManifestSha256.Hex,
    receipts = state.Receipts.Select(ReceiptDocument)
  };

  private static object StagePlanDocument(StagePlan plan) => new
  {
    schemaVersion = 1,
    contractId = plan.ContractId,
    pipelineUid = plan.PipelineUid.ToString(),
    manifestSha256 = plan.ManifestSha256.Hex,
    stageStepId = plan.StageStepId,
    stageReady = plan.StageReady,
    mutationPerformed = plan.MutationPerformed,
    plannedActions = plan.PlannedActions.Select(static action => new
    {
      actionCode = action.ActionCode,
      targetRoleCode = action.TargetRoleCode
    }),
    rollbackActions = plan.RollbackActions.Select(static action => new
    {
      actionCode = action.ActionCode,
      targetRoleCode = action.TargetRoleCode
    })
  };

  private static async Task WriteJsonAsync(string path, object value)
  {
    var json = JsonSerializer.Serialize(value, OutputOptions) + Environment.NewLine;
    await File.WriteAllTextAsync(path, json, new System.Text.UTF8Encoding(false)).ConfigureAwait(false);
  }
}
