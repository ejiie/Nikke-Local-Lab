using NikkeLocalLab.Phase3B2.UserValidation;
using Xunit;

namespace NikkeLocalLab.Admin.Api.UnitTests;

public sealed class UserValidationProfileVersionTests
{
  [Fact]
  public void AcceptsOnlyExactVersionPairs()
  {
    foreach (var schema in new[] { -1, 0, 1, 2, 3, 4, int.MaxValue })
      foreach (var version in new[] { -1, 0, 1, 2, 3, 4 })
        Assert.Equal(schema == version && schema is >= 1 and <= 3,
            UserValidationProfileVersion.IsSupported(schema, "nll/boss-runtime-variant-profile/v" + version));
  }

  [Theory]
  [InlineData(null)]
  [InlineData("")]
  [InlineData("nll/boss-runtime-variant-profile/v3 ")]
  [InlineData("NLL/boss-runtime-variant-profile/v3")]
  [InlineData("nll/other-profile/v3")]
  public void RejectsUnknownOrNormalizedContracts(string? value) =>
      Assert.False(UserValidationProfileVersion.IsSupported(3, value));
}
