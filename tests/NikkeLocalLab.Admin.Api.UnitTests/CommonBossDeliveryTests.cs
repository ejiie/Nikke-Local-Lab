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
    }
    await Assert.ThrowsAnyAsync<Exception>(() => fixture.Stage());
  }

  [Fact]
  public async Task Historical_seal_without_lengths_launches_with_digest_check()
  {
    using var fixture = new Fixture();
    fixture.Rows[1].Remove("byteLength");
    fixture.Publish();
    await fixture.Validate(full: false);
    Assert.Null(await fixture.Stage());
    var bytes = File.ReadAllBytes(fixture.Asset);
    File.WriteAllBytes(fixture.Asset, bytes.Select(static _ => (byte)'x').ToArray());
    await Assert.ThrowsAsync<InvalidDataException>(() => fixture.Validate(full: false));
    await Assert.ThrowsAsync<InvalidDataException>(() => fixture.Stage());
  }

  [Theory]
  [InlineData("fire")]
  [InlineData("water")]
  [InlineData("wind")]
  [InlineData("electric")]
  public async Task Sealed_variant_is_copied_byte_for_byte_without_rebuilding(string weakness)
  {
    using var fixture = new Fixture();
    fixture.AddVariant(weakness);
    var pack = File.ReadAllBytes(fixture.VariantPack(weakness));
    var receipt = File.ReadAllBytes(fixture.VariantReceipt(weakness));
    var hash = await fixture.CopyVariant(weakness);
    Assert.Equal(Hash(pack), hash);
    Assert.Equal(pack, File.ReadAllBytes(fixture.OutputPack));
    Assert.Equal(receipt, File.ReadAllBytes(fixture.OutputReceipt));
    // Copy, not a hardlink: runtime changes cannot modify the onboarding seal.
    File.WriteAllText(fixture.OutputPack, "runtime only");
    Assert.Equal(pack, File.ReadAllBytes(fixture.VariantPack(weakness)));
    Assert.Equal(receipt, File.ReadAllBytes(fixture.VariantReceipt(weakness)));
    await Assert.ThrowsAsync<IOException>(() => fixture.CopyVariant(weakness));
  }

  [Fact]
  public async Task Changed_client_pack_requires_reonboarding_before_any_output_is_written()
  {
    using var fixture = new Fixture();
    fixture.AddVariant("water");
    File.WriteAllText(fixture.SourcePack, "synthetic source modified");
    var error = await Assert.ThrowsAsync<InvalidOperationException>(() => fixture.CopyVariant("water"));
    Assert.Equal("phase_d_variant_pack_source_changed", error.Message);
    Assert.False(File.Exists(fixture.OutputPack));
    Assert.False(File.Exists(fixture.OutputReceipt));
  }

  [Theory]
  [InlineData("receipt_drift")]
  [InlineData("profile")]
  [InlineData("weakness")]
  [InlineData("hash")]
  [InlineData("not_required")]
  [InlineData("missing_receipt")]
  [InlineData("missing_pack")]
  [InlineData("unsealed_receipt")]
  [InlineData("unsealed_pack")]
  public async Task Reuse_requires_the_selected_sealed_pack_and_receipt(string fault)
  {
    using var fixture = new Fixture();
    fixture.AddVariant("water");
    var receiptPath = fixture.VariantReceipt("water");
    if (fault == "receipt_drift")
      File.WriteAllText(receiptPath, File.ReadAllText(receiptPath).Replace("water", "xxxxx", StringComparison.Ordinal));
    else if (fault == "missing_receipt") File.Delete(receiptPath);
    else if (fault == "missing_pack") File.Delete(fixture.VariantPack("water"));
    else if (fault.StartsWith("unsealed_", StringComparison.Ordinal))
    {
      var name = "five-affinity-variants/water." + (fault == "unsealed_pack" ? "pack" : "receipt.json");
      fixture.Rows.RemoveAll(row => (string)row["relativePath"] == name);
      fixture.Publish();
    }
    else
    {
      var row = System.Text.Json.Nodes.JsonNode.Parse(File.ReadAllText(receiptPath))!;
      switch (fault)
      {
        case "profile": row["variantProfileSha256"] = new string('a', 64); break;
        case "weakness": row["weaknessCode"] = "fire"; break;
        case "hash": row["variantStaticDataSha256"] = new string('b', 64); break;
        case "not_required": row["variantRequired"] = false; break;
      }
      File.WriteAllText(receiptPath, row.ToJsonString());
      fixture.PinVariantReceipt("water");
    }
    await Assert.ThrowsAnyAsync<Exception>(() => fixture.CopyVariant("water"));
    Assert.False(File.Exists(fixture.OutputPack));
    Assert.False(File.Exists(fixture.OutputReceipt));
  }

  private sealed class Fixture : IDisposable
  {
    public string Root { get; } = Path.Combine(Path.GetTempPath(), "nll-delivery-" + Guid.NewGuid().ToString("N"));
    public string Profile => Path.Combine(Root, "boss-runtime-variant.profile.json");
    public string Asset => Path.Combine(Root, "synthetic.bundle");
    public string Seal => Path.Combine(Root, "seal.json");
    public string Descriptor => Path.Combine(Root, "delivery.json");
    public List<Dictionary<string, object>> Rows { get; } = [];
    public string SourcePack => Path.Combine(Root, "current-client.pack");
    public string OutputPack => Path.Combine(Root, "runtime", "StaticData.pack");
    public string OutputReceipt => Path.Combine(Root, "runtime.receipt.json");
    public string VariantPack(string weakness) => Path.Combine(Root, "five-affinity-variants", weakness + ".pack");
    public string VariantReceipt(string weakness) => Path.Combine(Root, "five-affinity-variants", weakness + ".receipt.json");

    public void AddVariant(string weakness)
    {
      Directory.CreateDirectory(Path.GetDirectoryName(VariantPack(weakness))!);
      File.WriteAllText(SourcePack, "synthetic source original");
      File.WriteAllText(VariantPack(weakness), "synthetic sealed " + weakness + " pack, not an encrypted archive");
      File.WriteAllText(VariantReceipt(weakness), JsonSerializer.Serialize(new
      {
        contractId = "nll/boss-affinity-static-data-variant/v1",
        variantProfileSha256 = FileHash(Profile),
        weaknessCode = weakness,
        variantRequired = true,
        sourceStaticDataSha256 = FileHash(SourcePack),
        variantStaticDataSha256 = FileHash(VariantPack(weakness))
      }));
      Rows.Add(new()
      {
        ["relativePath"] = "five-affinity-variants/" + weakness + ".pack",
        ["byteLength"] = new FileInfo(VariantPack(weakness)).Length,
        ["sha256"] = FileHash(VariantPack(weakness))
      });
      PinVariantReceipt(weakness);
    }

    public void PinVariantReceipt(string weakness)
    {
      var name = "five-affinity-variants/" + weakness + ".receipt.json";
      Rows.RemoveAll(row => (string)row["relativePath"] == name);
      Rows.Add(new()
      {
        ["relativePath"] = name,
        ["byteLength"] = new FileInfo(VariantReceipt(weakness)).Length,
        ["sha256"] = FileHash(VariantReceipt(weakness))
      });
      Publish();
    }

    public async Task<string> CopyVariant(string weakness)
    {
      var ready = await CommonBossDelivery.Validate(Descriptor, _digest, Profile, weakness, fullVerification: false);
      return CommonBossDelivery.CopyVariant(ready.Plan, ready.Seal, ready.Profile, weakness,
          FileHash(SourcePack), OutputPack, OutputReceipt);
    }
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
