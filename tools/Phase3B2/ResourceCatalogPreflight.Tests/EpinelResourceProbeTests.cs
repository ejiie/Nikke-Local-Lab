using System.Reflection;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;
using EpinelPS.Execution;
using Microsoft.Extensions.Configuration;
using Xunit;

namespace ResourceCatalogPreflight.Tests;

public sealed class EpinelResourceProbeTests : IDisposable
{
  private readonly string directory = Path.Combine(Path.GetTempPath(), "nll-process-admission-" + Guid.NewGuid().ToString("N"));
  private readonly ResourceProbeExecution.FilePin pin;
  private readonly string uid = Guid.NewGuid().ToString("D");

  public EpinelResourceProbeTests()
  {
    Directory.CreateDirectory(directory);
    var bytes = "synthetic process admission fixture"u8.ToArray();
    File.WriteAllBytes(Path.Combine(directory, "fixture.bin"), bytes);
    pin = new("fixture.bin", bytes.Length, Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant());
  }

  [Fact]
  public void ProcessAdmissionHasNoHttpEntryPointOrDispatchSwitch()
  {
    var type = typeof(ResourceProbeExecution);
    var flags = BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance | BindingFlags.Static | BindingFlags.DeclaredOnly;
    Assert.Null(type.GetMethod("HandleAsync", flags));
    Assert.Null(type.GetMethod("SetLocalStartupAuthorization", flags));
    Assert.Null(type.GetMethod("DispatchSummary", flags));
    Assert.Null(type.GetProperty("DispatchMode", flags));
    Assert.DoesNotContain(type.GetFields(flags), field =>
        field.FieldType.FullName?.Contains("Observer", StringComparison.Ordinal) == true ||
        field.FieldType.FullName?.StartsWith("Microsoft.AspNetCore", StringComparison.Ordinal) == true);
    Assert.DoesNotContain(type.GetMethods(flags).SelectMany(method => method.GetParameters()),
        parameter => parameter.ParameterType.Namespace?.StartsWith("Microsoft.AspNetCore", StringComparison.Ordinal) == true);
    Assert.Equal(new[] { "AssessmentUid", "ContractId", "DurationSeconds", "Files" },
        typeof(ResourceProbeExecution.Plan).GetProperties().Select(p => p.Name).Order().ToArray());
  }

  [Theory]
  [InlineData(30)]
  [InlineData(60)]
  [InlineData(240)]
  [InlineData(300)]
  public void NewProcessOnlyPlanPreservesBoundedDurationAndPins(int duration)
  {
    var plan = ResourceProbeExecution.ReadPlan(PlanBytes(duration), uid);
    Assert.Equal(ResourceProbeExecution.ContractId, plan.ContractId);
    Assert.Equal(duration, plan.DurationSeconds);
    Assert.Equal(pin, Assert.Single(plan.Files));
  }

  [Theory]
  [InlineData("dispatchMode", "\"guarded\"")]
  [InlineData("dispatchMode", "\"legacy_pipeline_passthrough\"")]
  [InlineData("observer", "null")]
  [InlineData("observer", "{}")]
  [InlineData("unknown", "true")]
  public void RemovedInspectionFieldsCannotBeSilentlyReintroduced(string name, string value)
  {
    var json = JsonNode.Parse(PlanBytes())!.AsObject();
    json[name] = JsonNode.Parse(value);
    Assert.Throws<JsonException>(() => ResourceProbeExecution.ReadPlan(JsonSerializer.SerializeToUtf8Bytes(json), uid));
  }

  [Fact]
  public void HistoricalManifestRequiresFreshStaging()
  {
    var json = JsonNode.Parse(PlanBytes())!.AsObject();
    json["contractId"] = "nll/epinel-resource-probe-runtime/v1";
    Assert.Throws<InvalidOperationException>(() =>
        ResourceProbeExecution.ReadPlan(JsonSerializer.SerializeToUtf8Bytes(json), uid));
  }

  [Theory]
  [InlineData(0)]
  [InlineData(29)]
  [InlineData(301)]
  public void UnboundedOrInvalidDurationRemainsForbidden(int duration) =>
      Assert.Throws<InvalidOperationException>(() => ResourceProbeExecution.ReadPlan(PlanBytes(duration), uid));

  [Fact]
  public void WrongAssessmentAndMissingInventoryRemainForbidden()
  {
    Assert.Throws<InvalidOperationException>(() => ResourceProbeExecution.ReadPlan(PlanBytes(), Guid.NewGuid().ToString("D")));
    var json = JsonNode.Parse(PlanBytes())!.AsObject();
    json["files"] = new JsonArray();
    Assert.Throws<InvalidOperationException>(() => ResourceProbeExecution.ReadPlan(JsonSerializer.SerializeToUtf8Bytes(json), uid));
    json["files"] = null;
    Assert.Throws<InvalidOperationException>(() => ResourceProbeExecution.ReadPlan(JsonSerializer.SerializeToUtf8Bytes(json), uid));
  }

  [Fact]
  public void ExistingModesRemainUnchangedAndProbeCannotRunFromTestOutput()
  {
    Assert.Null(ResourceProbeExecution.Prepare(["--headless", "--local-only"]));
    Assert.Throws<InvalidOperationException>(() => ResourceProbeExecution.Prepare([ResourceProbeExecution.Argument]));
    Assert.Throws<InvalidOperationException>(() => ResourceProbeExecution.Prepare(
        ["--headless", "--local-only", ResourceProbeExecution.Argument, new string('a', 64)]));
  }

  [Fact]
  public void ProbeConfigurationCannotInheritDatabaseOrPublicListeners()
  {
    using var configuration = new ConfigurationManager();
    configuration.AddInMemoryCollection(new Dictionary<string, string?>
    {
      ["ConnectionStrings:EpinelPSConnection"] = "production-must-not-be-used",
      ["ConnectionStrings:EpinelPSConnectionType"] = "npgsql",
      ["Kestrel:Endpoints:Public:Url"] = "http://0.0.0.0:8765"
    });
    ResourceProbeExecution.Configure(configuration);
    Assert.Null(configuration["Kestrel:Endpoints:Public:Url"]);
    Assert.Equal("sqlite", configuration["ConnectionStrings:EpinelPSConnectionType"]);
    Assert.Equal("Data Source=\"(startupDirectory)/epinelps.db\"", configuration["ConnectionStrings:EpinelPSConnection"]);
  }

  [Fact]
  public void ExactInventoryAndFileHashesStillRequired()
  {
    ResourceProbeExecution.VerifyFiles(directory, [pin]);
    Assert.Throws<InvalidOperationException>(() => ResourceProbeExecution.VerifyFiles(directory, [pin, pin]));
    Assert.Throws<InvalidOperationException>(() => ResourceProbeExecution.VerifyFiles(directory, [pin with { Length = pin.Length + 1 }]));
    Assert.Throws<InvalidOperationException>(() => ResourceProbeExecution.VerifyFiles(directory, [pin with { Sha256 = new string('a', 64) }]));
    Assert.Throws<InvalidOperationException>(() => ResourceProbeExecution.VerifyFiles(directory, [pin with { Path = "missing.bin" }]));
    File.WriteAllText(Path.Combine(directory, "unlisted.bin"), "synthetic extra");
    Assert.Throws<InvalidOperationException>(() => ResourceProbeExecution.VerifyFiles(directory, [pin]));
  }

  [Fact]
  public void ManifestIsExcludedFromInventoryButRuntimeDataIsNot()
  {
    File.WriteAllBytes(Path.Combine(directory, "resource-probe-runtime.private.json"), PlanBytes());
    ResourceProbeExecution.VerifyFiles(directory, [pin]);
    File.WriteAllText(Path.Combine(directory, "epinelps.db"), "synthetic store marker");
    Assert.Throws<InvalidOperationException>(() => ResourceProbeExecution.VerifyFiles(directory, [pin]));
  }

  [Theory]
  [InlineData("../fixture.bin")]
  [InlineData("a/../fixture.bin")]
  [InlineData("a\\fixture.bin")]
  [InlineData("C:/fixture.bin")]
  [InlineData("/fixture.bin")]
  [InlineData("")]
  public void FilePinsCannotEscapeTheSealedRuntime(string path) =>
      Assert.Throws<InvalidOperationException>(() => ResourceProbeExecution.VerifyFiles(directory, [pin with { Path = path }]));

  private byte[] PlanBytes(int duration = 60) => JsonSerializer.SerializeToUtf8Bytes(
      new ResourceProbeExecution.Plan(ResourceProbeExecution.ContractId, uid, duration, [pin]),
      new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase });

  public void Dispose() => Directory.Delete(directory, recursive: true);
}
