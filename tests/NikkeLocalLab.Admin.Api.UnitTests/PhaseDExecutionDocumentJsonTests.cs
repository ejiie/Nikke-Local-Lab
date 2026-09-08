using System.Text.Json;
using NikkeLocalLab.Application.ProfileManagement;

namespace NikkeLocalLab.Admin.Api.UnitTests;

public sealed class PhaseDExecutionDocumentJsonTests
{
  [Fact]
  public void RuntimeCandidateRoundTripsWithStrictCamelCaseContract()
  {
    var document = new PhaseDRuntimeCandidateDocument(
        1,
        "nll/runtime-projection-candidate/v1",
        new string('a', 64),
        "10000000-0000-4000-8000-000000000001",
        "synthetic-account",
        new PhaseDRuntimeCandidateRevisionsDocument(
            "20000000-0000-4000-8000-000000000001",
            "30000000-0000-4000-8000-000000000001",
            null,
            new string('b', 64)),
        "ready",
        [],
        [
          new PhaseDRuntimeCandidateValueDocument(
              "synchro_level",
              null,
              "ready",
              773,
              null,
              null,
              null,
              null,
              null,
              null)
        ]);
    var options = PhaseDExecutionDocumentJson.CreateOptions(writeIndented: true);

    var json = JsonSerializer.Serialize(document, options);
    var roundTrip = JsonSerializer.Deserialize<PhaseDRuntimeCandidateDocument>(json, options);

    Assert.Contains("\"schemaVersion\"", json, StringComparison.Ordinal);
    Assert.DoesNotContain("\"SchemaVersion\"", json, StringComparison.Ordinal);
    Assert.NotNull(roundTrip);
    Assert.Equal(document.SchemaVersion, roundTrip.SchemaVersion);
    Assert.Equal(document.ContractId, roundTrip.ContractId);
    Assert.Equal(document.BaseRevisions, roundTrip.BaseRevisions);
    Assert.Equal(document.ValidationReasonCodes, roundTrip.ValidationReasonCodes);
    Assert.Equal(document.Values, roundTrip.Values);
  }

  [Fact]
  public void RuntimeCandidateRejectsWrongCaseAndUnknownMembers()
  {
    var options = PhaseDExecutionDocumentJson.CreateOptions();
    const string valid = """
        {
          "schemaVersion": 1,
          "contractId": "nll/runtime-projection-candidate/v1",
          "candidateSha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "accountUid": "10000000-0000-4000-8000-000000000001",
          "accountLabel": "synthetic-account",
          "baseRevisions": {
            "profileRevisionUid": "20000000-0000-4000-8000-000000000001",
            "accountStateRevisionUid": "30000000-0000-4000-8000-000000000001",
            "progressionRevisionUid": null,
            "revisionSetSha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
          },
          "validationStatusCode": "ready",
          "validationReasonCodes": [],
          "values": []
        }
        """;

    var wrongCase = valid.Replace("\"schemaVersion\"", "\"SchemaVersion\"", StringComparison.Ordinal);
    var unknownMember = valid.Replace(
        "\"values\": []",
        "\"values\": [], \"unexpectedMember\": true",
        StringComparison.Ordinal);

    Assert.Throws<JsonException>(() =>
        JsonSerializer.Deserialize<PhaseDRuntimeCandidateDocument>(wrongCase, options));
    Assert.Throws<JsonException>(() =>
        JsonSerializer.Deserialize<PhaseDRuntimeCandidateDocument>(unknownMember, options));
  }

  [Fact]
  public void LobbyRoundTripsWithTheSameStrictContract()
  {
    var document = new PhaseDLobbyDocument(
        1,
        "nll/phase-d-lobby-projection/v1",
        "10000000-0000-4000-8000-000000000001",
        "40000000-0000-4000-8000-000000000001",
        new string('c', 64),
        "synthetic-commander",
        896);
    var options = PhaseDExecutionDocumentJson.CreateOptions();

    var json = JsonSerializer.Serialize(document, options);
    var roundTrip = JsonSerializer.Deserialize<PhaseDLobbyDocument>(json, options);

    Assert.Equal(document, roundTrip);
  }
}
