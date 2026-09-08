using System.Text.Json;
using System.Text.Json.Serialization;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Automation;

public static class PipelineManifestJson
{
  private static readonly JsonSerializerOptions ReadOptions = new()
  {
    PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    PropertyNameCaseInsensitive = false,
    AllowTrailingCommas = false,
    ReadCommentHandling = JsonCommentHandling.Disallow
  };

  public static PipelineRunManifest Deserialize(string json)
  {
    var document = JsonSerializer.Deserialize<PipelineManifestDocument>(json, ReadOptions) ??
        throw new PipelineManifestException("pipeline_document_empty");
    if (document.SchemaVersion != 1 || !string.Equals(
            document.ContractId,
            PipelineRunManifest.ContractId,
            StringComparison.Ordinal))
    {
      throw new PipelineManifestException("pipeline_contract_invalid");
    }

    if (!Guid.TryParseExact(document.PipelineUid, "D", out var pipelineUid) || pipelineUid == Guid.Empty)
    {
      throw new PipelineManifestException("pipeline_uid_invalid");
    }

    if (document.Target is null || document.Inputs is null || document.Steps is null)
    {
      throw new PipelineManifestException("pipeline_document_shape_invalid");
    }

    return new PipelineRunManifest(
        new EntityUid(pipelineUid),
        new PipelineTarget(
            document.Target.KindCode,
            document.Target.SeasonNumber,
            document.Target.ClientBuildCode,
            document.Target.ModeCode),
        document.Inputs.Select(input => new PipelineArtifactSpec(
            input.RoleCode,
            input.RelativePath,
            input.ByteLength,
            Sha256Digest.Parse(input.Sha256))),
        document.Steps.Select(step => new PipelineStepDefinition(
            step.StepId,
            ParseStepKind(step.KindCode),
            step.Mutation,
            step.DependencyStepIds,
            step.OutputRoleCodes,
            step.Actions?.Select(action => new PipelineAction(action.ActionCode, action.TargetRoleCode)),
            step.RollbackActions?.Select(action => new PipelineAction(action.ActionCode, action.TargetRoleCode)))));
  }

  private static PipelineStepKind ParseStepKind(string value) => value switch
  {
    "inventory" => PipelineStepKind.Inventory,
    "validate" => PipelineStepKind.Validate,
    "project" => PipelineStepKind.Project,
    "build" => PipelineStepKind.Build,
    "stage" => PipelineStepKind.Stage,
    "run" => PipelineStepKind.Run,
    "complete" => PipelineStepKind.Complete,
    "promote" => PipelineStepKind.Promote,
    "backup" => PipelineStepKind.Backup,
    _ => throw new PipelineManifestException("pipeline_step_kind_invalid")
  };

  private sealed record PipelineManifestDocument(
      int SchemaVersion,
      string ContractId,
      string PipelineUid,
      PipelineTargetDocument Target,
      IReadOnlyList<PipelineArtifactDocument> Inputs,
      IReadOnlyList<PipelineStepDocument> Steps);

  private sealed record PipelineTargetDocument(
      string KindCode,
      int? SeasonNumber,
      string ClientBuildCode,
      string ModeCode);

  private sealed record PipelineArtifactDocument(
      string RoleCode,
      string RelativePath,
      long ByteLength,
      string Sha256);

  private sealed record PipelineStepDocument(
      string StepId,
      string KindCode,
      bool Mutation,
      IReadOnlyList<string>? DependencyStepIds,
      IReadOnlyList<string>? OutputRoleCodes,
      IReadOnlyList<PipelineActionDocument>? Actions,
      IReadOnlyList<PipelineActionDocument>? RollbackActions);

  private sealed record PipelineActionDocument(string ActionCode, string TargetRoleCode);
}
