using NikkeLocalLab.Automation;
using Xunit;

namespace NikkeLocalLab.Automation.UnitTests;

public sealed class LegacyVersionHeaderTests
{
  private const string Valid = "synthetic\ncore:1.0.b1,1\ndp:abc,2\nen:abc,3\nja:abc,4\nko:abc,5\nfd:abc,6\nsaus:abc,7\n";

  [Fact]
  public void HeaderPreservesSeparateCoreAndVoiceVersions()
  {
    var entries = LegacyVersionHeader.Parse(Valid);
    Assert.Equal("1.0.b1", entries["core"]);
    Assert.Equal(7, entries.Count);
    Assert.Equal("abc", entries["ko"]);
    Assert.Equal(entries["core"], LegacyVersionHeader.Parse(Valid.Replace("\n", "\r\n", StringComparison.Ordinal))["core"]);
  }

  [Theory]
  [InlineData("", "invalid")]
  [InlineData("synthetic\n", "")]
  [InlineData("ko:abc,5", "en:abc,5")]
  [InlineData("ko:abc,5", "ko:../abc,5")]
  [InlineData("ko:abc,5", "ko:abc,5\nextra:abc,8")]
  public void RejectsTruncatedDuplicateOrTraversalHeaders(string oldValue, string newValue)
  {
    var candidate = oldValue.Length == 0 ? newValue : Valid.Replace(oldValue, newValue, StringComparison.Ordinal);
    Assert.Equal("resource_version_header_invalid",
        Assert.Throws<PipelineManifestException>(() => LegacyVersionHeader.Parse(candidate)).FailureCode);
  }
}
