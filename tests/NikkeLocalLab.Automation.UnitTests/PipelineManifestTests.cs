using NikkeLocalLab.Automation;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Automation.UnitTests;

public sealed class PipelineManifestTests
{
  [Fact]
  public void RejectsInputPathTraversal()
  {
    var exception = Assert.Throws<ArgumentException>(() => new PipelineArtifactSpec(
        "server_dll",
        "../runtime/server.dll",
        1,
        Hash("server")));

    Assert.Contains("cannot traverse", exception.Message, StringComparison.Ordinal);
  }

  [Fact]
  public void RejectsDependencyThatAppearsAfterItsConsumer()
  {
    var exception = Assert.Throws<PipelineManifestException>(() => new PipelineRunManifest(
        Uid(1),
        Target(),
        [Input("server_dll", "runtime/server.dll", 1, "server")],
        [
          Step("validate", PipelineStepKind.Validate, false, ["inventory"]),
          Step("inventory", PipelineStepKind.Inventory, false)
        ]));

    Assert.Equal("pipeline_dependency_order_invalid", exception.FailureCode);
  }

  [Fact]
  public void Season26ManifestPinsReadOnlyInventoryBeforeStage()
  {
    var path = Path.Combine(AppContext.BaseDirectory, "Fixtures", "season26-v8.pipeline.json");
    var manifest = PipelineManifestJson.Deserialize(File.ReadAllText(path));

    Assert.Equal(26, manifest.Target.SeasonNumber);
    Assert.Equal("build_150.6.9", manifest.Target.ClientBuildCode);
    Assert.Equal(12, manifest.Inputs.Count);
    Assert.Collection(
        manifest.Steps,
        step => Assert.Equal(PipelineStepKind.Inventory, step.Kind),
        step => Assert.Equal(PipelineStepKind.Validate, step.Kind),
        step =>
        {
          Assert.Equal(PipelineStepKind.Stage, step.Kind);
          Assert.True(step.Mutation);
          Assert.NotEmpty(step.RollbackActions);
        });
  }

  internal static PipelineRunManifest Manifest() => new(
      Uid(10),
      Target(),
      [Input("server_dll", "runtime/server.dll", 1, "server")],
      [
        Step("inventory", PipelineStepKind.Inventory, false, outputs: ["inventory_receipt"]),
        Step("validate", PipelineStepKind.Validate, false, ["inventory"], ["validation_receipt"]),
        Step(
            "stage",
            PipelineStepKind.Stage,
            true,
            ["validate"],
            ["deployment_receipt"],
            [new PipelineAction("install_candidate", "runtime_overlay")],
            [new PipelineAction("remove_candidate", "runtime_overlay")])
      ]);

  internal static PipelineTarget Target() => new(
      "season_checkpoint",
      26,
      "build_150.6.9",
      "classic_challenge");

  internal static PipelineArtifactSpec Input(
      string role,
      string path,
      long length,
      string seed) => new(role, path, length, Hash(seed));

  internal static PipelineStepDefinition Step(
      string id,
      PipelineStepKind kind,
      bool mutation,
      IEnumerable<string>? dependencies = null,
      IEnumerable<string>? outputs = null,
      IEnumerable<PipelineAction>? actions = null,
      IEnumerable<PipelineAction>? rollback = null) =>
      new(id, kind, mutation, dependencies, outputs, actions, rollback);

  internal static Sha256Digest Hash(string value) => Sha256Digest.ComputeUtf8(value);

  internal static EntityUid Uid(int suffix) => new(Guid.Parse(
      $"00000000-0000-4000-8000-{suffix.ToString("D12", System.Globalization.CultureInfo.InvariantCulture)}"));
}
