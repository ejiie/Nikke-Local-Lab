using System.Text.Json;
using System.Text.Json.Serialization;

namespace NikkeLocalLab.Application.ProfileManagement;

public static class PhaseDExecutionDocumentJson
{
  public static JsonSerializerOptions CreateOptions(bool writeIndented = false) => new()
  {
    PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    PropertyNameCaseInsensitive = false,
    UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
    WriteIndented = writeIndented
  };
}

public sealed record PhaseDRuntimeCandidateDocument(
    int SchemaVersion,
    string ContractId,
    string CandidateSha256,
    string AccountUid,
    string AccountLabel,
    PhaseDRuntimeCandidateRevisionsDocument BaseRevisions,
    string ValidationStatusCode,
    IReadOnlyList<string> ValidationReasonCodes,
    IReadOnlyList<PhaseDRuntimeCandidateValueDocument> Values);

public sealed record PhaseDRuntimeCandidateRevisionsDocument(
    string ProfileRevisionUid,
    string AccountStateRevisionUid,
    string? ProgressionRevisionUid,
    string RevisionSetSha256);

public sealed record PhaseDRuntimeCandidateValueDocument(
    string FieldCode,
    string? SubjectUid,
    string Status,
    long? IntegerValue,
    bool? BooleanValue,
    string? ReferenceUid,
    long? UnscaledValue,
    int? DecimalScale,
    string? ControlledValue,
    string? ReasonCode);

public sealed record PhaseDLobbyDocument(
    int SchemaVersion,
    string ContractId,
    string AccountUid,
    string RevisionUid,
    string ContentSha256,
    string DisplayName,
    int CommanderLevel);
