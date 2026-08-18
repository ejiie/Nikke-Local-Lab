using System.Diagnostics;
using System.Text;
using System.Text.Json.Nodes;

namespace NikkeLocalLab.Raid.UnitTests;

public sealed class RaidSnapshotContractTests
{
  [Fact]
  public void Domain_dto_serializes_to_the_schema_fixture_and_round_trips_without_loss()
  {
    var root = FindRepositoryRoot();
    var fixture = File.ReadAllText(Path.Combine(
        root,
        "tests",
        "fixtures",
        "synthetic",
        "raid-snapshot.challenge.json"));
    var snapshot = RaidTestData.Snapshot(
        tier: RaidCompatibilityTier.AssetExactRuntimeCurrent,
        runtimeRelation: RuntimeRelation.CurrentRuntimeMatch,
        resolvedRuntime: true,
        resolvedTiming: true);

    var serialized = RaidSnapshotContractSerializer.Serialize(snapshot);
    var deserialized = RaidSnapshotContractSerializer.Deserialize(serialized);
    var roundTripped = RaidSnapshotContractSerializer.Serialize(deserialized);

    AssertJsonEqual(fixture, serialized);
    AssertJsonEqual(serialized, roundTripped);
    AssertSchemaValidity(root, serialized, expected: true);
  }

  [Fact]
  public void Static_exact_fixture_round_trips_with_empty_higher_tier_evidence()
  {
    var root = FindRepositoryRoot();
    var fixture = File.ReadAllText(Path.Combine(
        root,
        "tests",
        "fixtures",
        "synthetic",
        "raid-snapshot.static-exact.json"));

    var document = RaidSnapshotContractSerializer.Deserialize(fixture);
    var roundTripped = RaidSnapshotContractSerializer.Serialize(document);

    AssertJsonEqual(fixture, roundTripped);
    Assert.Empty(document.Provenance.SelectedAssetBundles);
    Assert.Null(document.Provenance.AssetBundleSetSha256);
    Assert.Null(document.Provenance.Behavior);
    Assert.Empty(document.Provenance.Timelines);
    AssertSchemaValidity(root, roundTripped, expected: true);
  }

  [Fact]
  public void Schema_rejects_a_static_exact_document_that_hides_missing_evidence()
  {
    var root = FindRepositoryRoot();
    var path = Path.Combine(
        root,
        "tests",
        "fixtures",
        "synthetic",
        "raid-snapshot.static-exact.json");
    var rootNode = JsonNode.Parse(File.ReadAllText(path))!.AsObject();
    rootNode["compatibility"]!["evidenceWarnings"] = new JsonArray();

    AssertSchemaValidity(root, rootNode.ToJsonString(), expected: false);
  }

  [Fact]
  public void Schema_rejects_a_behavior_exact_claim_without_behavior_and_bundle_evidence()
  {
    var root = FindRepositoryRoot();
    var path = Path.Combine(
        root,
        "tests",
        "fixtures",
        "synthetic",
        "raid-snapshot.static-exact.json");
    var rootNode = JsonNode.Parse(File.ReadAllText(path))!.AsObject();
    rootNode["compatibility"]!["tier"] = "behavior_exact";

    AssertSchemaValidity(root, rootNode.ToJsonString(), expected: false);
  }

  [Fact]
  public void Schema_rejects_a_runtime_exact_claim_with_an_unresolved_related_clock()
  {
    var root = FindRepositoryRoot();
    var path = Path.Combine(
        root,
        "tests",
        "fixtures",
        "synthetic",
        "raid-snapshot.challenge.json");
    var rootNode = JsonNode.Parse(File.ReadAllText(path))!.AsObject();
    var clock = rootNode["provenance"]!["timing"]!["clockBases"]![0]!.AsObject();
    clock["resolution"] = "unresolved";
    clock["evidenceArtifacts"] = new JsonArray();
    clock["reasonCode"] = "not_evaluated";

    AssertSchemaValidity(root, rootNode.ToJsonString(), expected: false);
  }

  [Fact]
  public void Schema_rejects_an_evaluated_runtime_relation_without_runtime_evidence()
  {
    var root = FindRepositoryRoot();
    var path = Path.Combine(
        root,
        "tests",
        "fixtures",
        "synthetic",
        "raid-snapshot.challenge.json");
    var rootNode = JsonNode.Parse(File.ReadAllText(path))!.AsObject();
    rootNode["compatibility"]!["tier"] = "behavior_exact";
    var runtime = rootNode["provenance"]!["clientRuntime"]!.AsObject();
    runtime["buildUid"] = null;
    runtime["localBuildLabel"] = null;
    runtime["sha256"] = null;

    AssertSchemaValidity(root, rootNode.ToJsonString(), expected: false);
  }

  [Fact]
  public void Schema_rejects_a_runtime_timeline_clock_missing_from_the_scheduler_relation()
  {
    var root = FindRepositoryRoot();
    var path = Path.Combine(
        root,
        "tests",
        "fixtures",
        "synthetic",
        "raid-snapshot.challenge.json");
    var rootNode = JsonNode.Parse(File.ReadAllText(path))!.AsObject();
    rootNode["provenance"]!["timing"]!["scheduler"]!["relatedClockBases"] = new JsonArray(
        "fixed_update",
        "wall_clock");

    AssertSchemaValidity(root, rootNode.ToJsonString(), expected: false);
  }

  [Fact]
  public void Schema_rejects_a_path_like_runtime_label()
  {
    var root = FindRepositoryRoot();
    var path = Path.Combine(
        root,
        "tests",
        "fixtures",
        "synthetic",
        "raid-snapshot.challenge.json");
    var rootNode = JsonNode.Parse(File.ReadAllText(path))!.AsObject();
    rootNode["provenance"]!["clientRuntime"]!["localBuildLabel"] =
        "C:/private/runtime";

    AssertSchemaValidity(root, rootNode.ToJsonString(), expected: false);
  }

  [Fact]
  public void Schema_rejects_non_controlled_warning_values()
  {
    var root = FindRepositoryRoot();
    var path = Path.Combine(
        root,
        "tests",
        "fixtures",
        "synthetic",
        "raid-snapshot.static-exact.json");
    var evidenceWarning = JsonNode.Parse(File.ReadAllText(path))!.AsObject();
    evidenceWarning["compatibility"]!["evidenceWarnings"] = new JsonArray(
        "C:/private/evidence");
    AssertSchemaValidity(root, evidenceWarning.ToJsonString(), expected: false);

    var readinessWarning = JsonNode.Parse(File.ReadAllText(path))!.AsObject();
    readinessWarning["readiness"]!["warnings"] = new JsonArray("not safe");
    AssertSchemaValidity(root, readinessWarning.ToJsonString(), expected: false);
  }

  private static void AssertJsonEqual(string expected, string actual)
  {
    var expectedNode = JsonNode.Parse(expected);
    var actualNode = JsonNode.Parse(actual);
    Assert.True(
        JsonNode.DeepEquals(expectedNode, actualNode),
        $"JSON documents differ.{Environment.NewLine}Expected:{Environment.NewLine}{expected}" +
        $"{Environment.NewLine}Actual:{Environment.NewLine}{actual}");
  }

  private static void AssertSchemaValidity(string root, string json, bool expected)
  {
    var schema = Path.Combine(root, "contracts", "raid-snapshot.schema.json");
    var temporary = Path.Combine(Path.GetTempPath(), $"nll-raid-contract-{Guid.NewGuid():N}.json");
    File.WriteAllText(temporary, json, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
    try
    {
      var startInfo = new ProcessStartInfo
      {
        FileName = "pwsh",
        RedirectStandardError = true,
        RedirectStandardOutput = true,
        UseShellExecute = false,
        CreateNoWindow = true,
      };
      startInfo.ArgumentList.Add("-NoProfile");
      startInfo.ArgumentList.Add("-NonInteractive");
      startInfo.ArgumentList.Add("-Command");
      startInfo.ArgumentList.Add(
          "$payload = Get-Content -Raw -LiteralPath $env:NLL_RAID_CONTRACT_JSON; " +
          "if (Test-Json -Json $payload -SchemaFile $env:NLL_RAID_CONTRACT_SCHEMA -ErrorAction Stop) " +
          "{ exit 0 }; exit 1");
      startInfo.Environment["NLL_RAID_CONTRACT_JSON"] = temporary;
      startInfo.Environment["NLL_RAID_CONTRACT_SCHEMA"] = schema;

      using var process = Process.Start(startInfo) ??
          throw new InvalidOperationException("PowerShell JSON Schema validation did not start.");
      var output = process.StandardOutput.ReadToEnd();
      var error = process.StandardError.ReadToEnd();
      process.WaitForExit();

      Assert.True(
          expected ? process.ExitCode == 0 : process.ExitCode != 0,
          $"Schema result differed from expectation. Exit={process.ExitCode}. Output={output}. Error={error}");
    }
    finally
    {
      File.Delete(temporary);
    }
  }

  private static string FindRepositoryRoot()
  {
    DirectoryInfo? directory = new(AppContext.BaseDirectory);
    while (directory is not null)
    {
      if (File.Exists(Path.Combine(directory.FullName, "contracts", "raid-snapshot.schema.json")))
      {
        return directory.FullName;
      }

      directory = directory.Parent;
    }

    throw new DirectoryNotFoundException("Cannot locate the repository root from the test output path.");
  }
}
