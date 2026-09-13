using NikkeLocalLab.Phase3B2.UserValidation;
using Xunit;

namespace NikkeLocalLab.Admin.Api.UnitTests;

public sealed class UserValidationServerEnvironmentTests
{
  [Fact]
  public void PinsLocalSqliteAndFreshRuntimeStorage()
  {
    var uid = Guid.Parse("be5dfe46-26a7-494c-ab70-25069a611042");
    var root = @"C:\NLL\Runtime\EpinelPS-151-UserValidation\" + uid;
    var environment = UserValidationServerEnvironment.Create(uid, 42, null);
    Assert.Equal(16, environment.Count);
    Assert.Equal("sqlite", environment["ConnectionStrings__EpinelPSConnectionType"]);
    Assert.Equal("Data Source=\"" + root + "\\epinelps.db\"", environment["ConnectionStrings__EpinelPSConnection"]);
    Assert.Equal("profile_trusted_unique/v1", environment["EPINELPS_CLASSIC_SOLO_RAID_MANAGER_SELECTION"]);
    Assert.Equal("42", environment["EPINELPS_CLASSIC_SOLO_RAID_ACCOUNT_ID"]);
    foreach (var name in new[] { "TEMP", "TMP", "APPDATA", "LOCALAPPDATA" })
      Assert.Equal(root + @"\scratch", environment[name]);
    foreach (var name in new[] { "HTTP_PROXY", "HTTPS_PROXY", "DOTNET_STARTUP_HOOKS", "ASPNETCORE_URLS",
        "EPINELPS_CLASSIC_SOLO_RAID_MANAGER_ID", "EPINELPS_CLIENT_STATIC_DATA_VARIANT_PATH" })
      Assert.False(environment.ContainsKey(name));
  }

  [Fact]
  public void BindsExactVariantOnlyInsideItsNewServerRoot()
  {
    var uid = Guid.NewGuid();
    var digest = new string('a', 64);
    var environment = UserValidationServerEnvironment.Create(uid, ulong.MaxValue, digest);
    Assert.Equal(18, environment.Count);
    Assert.Equal(digest, environment["EPINELPS_CLIENT_STATIC_DATA_VARIANT_SHA256"]);
    Assert.Equal(@"C:\NLL\Runtime\EpinelPS-151-UserValidation\" + uid + @"\client-static-data-variant.pack",
        environment["EPINELPS_CLIENT_STATIC_DATA_VARIANT_PATH"]);
    Assert.Equal("18446744073709551615", environment["EPINELPS_CLASSIC_SOLO_RAID_ACCOUNT_ID"]);
  }

  [Theory]
  [InlineData("")]
  [InlineData("not-a-digest")]
  [InlineData("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")]
  public void RejectsInvalidVariantPin(string value) => Assert.Throws<InvalidOperationException>(() =>
      UserValidationServerEnvironment.Create(Guid.NewGuid(), 42, value));

  [Fact]
  public void RejectsMissingIdentity()
  {
    Assert.Throws<InvalidOperationException>(() => UserValidationServerEnvironment.Create(Guid.Empty, 42, null));
    Assert.Throws<InvalidOperationException>(() => UserValidationServerEnvironment.Create(Guid.NewGuid(), 0, null));
  }
}
