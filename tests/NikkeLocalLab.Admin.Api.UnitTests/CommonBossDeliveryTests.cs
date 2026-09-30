using System.Text.Json;
using Xunit;
using static CommonDeliveryFiles;

namespace NikkeLocalLab.Admin.Api.UnitTests;

public sealed class CommonBossDeliveryTests
{
  [Fact]
  public async Task Launch_checks_lengths_and_security_pins_while_explicit_verification_hashes_artifacts()
  {
    using var fixture = new Fixture();
    await fixture.Validate(full: true);
    await fixture.Validate(full: false);
    Assert.Null(await fixture.Stage());
    var bytes = File.ReadAllBytes(fixture.Asset);
    File.WriteAllBytes(fixture.Asset, bytes.Select(static _ => (byte)'x').ToArray());
    Assert.Null(await fixture.Stage());
    await Assert.ThrowsAsync<InvalidDataException>(() => fixture.Validate(full: true));
    File.AppendAllText(fixture.Asset, "longer");
    await Assert.ThrowsAsync<InvalidDataException>(() => fixture.Validate(full: false));
    await Assert.ThrowsAsync<InvalidDataException>(() => fixture.Stage());
    Assert.False(Directory.Exists(Path.Combine(fixture.Root, "unused-launch")));
  }

  [Theory]
  [InlineData("descriptor")]
  [InlineData("seal")]
  [InlineData("profile")]
  [InlineData("missing")]
  [InlineData("escape")]
  [InlineData("duplicate")]
  [InlineData("length")]
  [InlineData("unsealed-length")]
  public async Task Launch_rejects_drift_or_invalid_artifact_paths(string fault)
  {
    using var fixture = new Fixture();
    switch (fault)
    {
      case "descriptor": File.AppendAllText(fixture.Descriptor, " "); break;
      case "seal": File.AppendAllText(fixture.Seal, " "); break;
      case "profile": File.AppendAllText(fixture.Profile, " "); break;
      case "missing": File.Delete(fixture.Asset); break;
      case "escape": fixture.Rows[1]["relativePath"] = "../outside.bundle"; fixture.Publish(); break;
      case "duplicate": fixture.Rows.Add(fixture.Rows[1]); fixture.Publish(); break;
      case "length": fixture.Rows[1]["byteLength"] = 1; fixture.Publish(); break;
      case "unsealed-length": fixture.Rows[1].Remove("byteLength"); fixture.Publish(); break;
    }
    await Assert.ThrowsAnyAsync<Exception>(() => fixture.Stage());
  }

  [Fact]
  public async Task Historical_seal_can_be_fully_verified_for_resealing_but_cannot_launch()
  {
    using var fixture = new Fixture();
    fixture.Rows[1].Remove("byteLength");
    fixture.Publish();
    await fixture.Validate(full: true);
    await Assert.ThrowsAsync<InvalidDataException>(() => fixture.Stage());
  }

  private sealed class Fixture : IDisposable
  {
    public string Root { get; } = Path.Combine(Path.GetTempPath(), "nll-delivery-" + Guid.NewGuid().ToString("N"));
    public string Profile => Path.Combine(Root, "boss-runtime-variant.profile.json");
    public string Asset => Path.Combine(Root, "synthetic.bundle");
    public string Seal => Path.Combine(Root, "seal.json");
    public string Descriptor => Path.Combine(Root, "delivery.json");
    public List<Dictionary<string, object>> Rows { get; } = [];
    private string _digest = "";

    public Fixture()
    {
      Directory.CreateDirectory(Root);
      var repository = new DirectoryInfo(AppContext.BaseDirectory);
      while (repository is not null && !File.Exists(Path.Combine(repository.FullName, "NikkeLocalLab.sln"))) repository = repository.Parent;
      File.Copy(Path.Combine(repository!.FullName, "config", "boss-runtime-variants", "season-26-providence.json"), Profile);
      File.WriteAllText(Asset, "synthetic asset");
      foreach (var path in new[] { Profile, Asset })
        Rows.Add(new() { ["relativePath"] = Path.GetFileName(path), ["byteLength"] = new FileInfo(path).Length, ["sha256"] = FileHash(path) });
      Publish();
    }

    public void Publish()
    {
      File.WriteAllText(Seal, JsonSerializer.Serialize(new
      {
        contractId = "nll/boss-onboarding-verified-candidate/v1",
        profileSha256 = FileHash(Profile),
        affinityVariantCount = 5,
        fiveAffinityVariantStatusCode = "passed",
        clientStarted = false,
        artifacts = Rows
      }));
      File.WriteAllText(Descriptor, JsonSerializer.Serialize(new CommonBossDeliveryPlan(
          "nll/common-boss-delivery/v1", FileHash(Profile), Pin(Seal), null, null), Json));
      _digest = FileHash(Descriptor);
    }

    public Task Validate(bool full) => CommonBossDelivery.Validate(Descriptor, _digest, Profile, "water", full);
    public Task<object?> Stage() => CommonBossDelivery.Stage(Descriptor, _digest, Profile, "water", Path.Combine(Root, "unused-launch"));
    public void Dispose() => Directory.Delete(Root, recursive: true);
  }
}
