using System.Text.Json;
using NikkeLocalLab.Application.Importing;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Import.Sources;

namespace NikkeLocalLab.UnitTests;

public sealed class SyntheticImportTests
{
  private const string RawCanary = "SYNTHETIC-RAW-ID-MUST-NOT-LEAK";
  private const string DecodedCanary = "SYNTHETIC-DECODED-CONTENT-MUST-NOT-LEAK";

  [Fact]
  public void DiagnosticCodesMustComeFromTheControlledCatalog()
  {
    Assert.Throws<ArgumentException>(() => new SafeDiagnostic(
        ImportDiagnosticSeverity.Error,
        "extract",
        "private_source_name"));
    Assert.Throws<ArgumentException>(() => new SafeImportFailureException(
        "private_stage_name",
        "synthetic_parse_failed"));
  }

  [Fact]
  public async Task SameSyntheticInputReusesArtifactAndSnapshotWithoutLeakingSourceData()
  {
    using var temporary = new TemporaryDirectory();
    var sourceRoot = temporary.CreateDirectory("source");
    var repositoryRoot = temporary.CreateDirectory("repository");
    var runtimeRoot = temporary.CreateDirectory("runtime");
    var fixturePath = System.IO.Path.Combine(AppContext.BaseDirectory, "Fixtures", "import-source.phase1a.json");
    var sourceFile = System.IO.Path.Combine(sourceRoot, "private-source-name.json");
    File.Copy(fixturePath, sourceFile);
    var beforeBytes = await File.ReadAllBytesAsync(sourceFile);
    var beforeWriteTime = File.GetLastWriteTimeUtc(sourceFile);

    var source = new ReadOnlySourceRoot(sourceRoot, repositoryRoot, runtimeRoot)
        .Bind(SourceRelativePath.Parse("private-source-name.json"), "synthetic_catalog");
    var ledger = new InMemoryImportLedger();
    var coordinator = new ImportCoordinator(ledger, new RandomEntityUidGenerator());
    var extractor = new SyntheticFixtureExtractor();

    var first = await coordinator.ImportSingleAsync(source, "catalog", extractor);
    var second = await coordinator.ImportSingleAsync(source, "catalog", extractor);

    Assert.Equal(ImportReceiptStatus.Succeeded, first.Status);
    Assert.Equal(ImportReceiptStatus.Reused, second.Status);
    Assert.NotEqual(first.ImportRunUid, second.ImportRunUid);
    Assert.Equal(first.DatasetSnapshotUid, second.DatasetSnapshotUid);
    Assert.Equal(first.SourceArtifactUids, second.SourceArtifactUids);
    Assert.Equal(1, ledger.ArtifactCount);
    Assert.Equal(1, ledger.SnapshotCount);
    Assert.Equal(beforeBytes, await File.ReadAllBytesAsync(sourceFile));
    Assert.Equal(beforeWriteTime, File.GetLastWriteTimeUtc(sourceFile));

    var publicProjection = JsonSerializer.Serialize(new
    {
      first,
      second,
      ledger = ledger.SafeProjectionJson()
    });
    Assert.DoesNotContain(RawCanary, publicProjection, StringComparison.Ordinal);
    Assert.DoesNotContain(DecodedCanary, publicProjection, StringComparison.Ordinal);
    Assert.DoesNotContain("private-source-name", publicProjection, StringComparison.Ordinal);
    Assert.DoesNotContain(sourceRoot, publicProjection, StringComparison.OrdinalIgnoreCase);
  }

  [Fact]
  public async Task ControlledExtractorFailurePersistsOnlySafeDiagnosticCode()
  {
    using var temporary = new TemporaryDirectory();
    var sourceRoot = temporary.CreateDirectory("source");
    var repositoryRoot = temporary.CreateDirectory("repository");
    var runtimeRoot = temporary.CreateDirectory("runtime");
    var sourceFile = System.IO.Path.Combine(sourceRoot, "private-failure-source.json");
    await File.WriteAllTextAsync(sourceFile, $"{RawCanary}:{DecodedCanary}");
    var source = new ReadOnlySourceRoot(sourceRoot, repositoryRoot, runtimeRoot)
        .Bind(SourceRelativePath.Parse("private-failure-source.json"), "synthetic_catalog");
    var ledger = new InMemoryImportLedger();
    var coordinator = new ImportCoordinator(ledger, new RandomEntityUidGenerator());

    var receipt = await coordinator.ImportSingleAsync(source, "catalog", new ControlledFailureExtractor());
    var projection = ledger.SafeProjectionJson();

    Assert.Equal(ImportReceiptStatus.Failed, receipt.Status);
    Assert.Null(receipt.DatasetSnapshotUid);
    Assert.Equal(new[] { "synthetic_parse_failed" }, receipt.DiagnosticCodes);
    Assert.DoesNotContain(RawCanary, projection, StringComparison.Ordinal);
    Assert.DoesNotContain(DecodedCanary, projection, StringComparison.Ordinal);
    Assert.DoesNotContain("private-failure-source", projection, StringComparison.Ordinal);
  }
}
