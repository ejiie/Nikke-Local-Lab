using System.Globalization;

namespace NikkeLocalLab.Phase3B2.UserValidation;

internal static class UserValidationServerEnvironment
{
  // Never inherit ConnectionStrings, ASPNETCORE/Kestrel settings, startup hooks,
  // proxies, official credentials or EPINELPS_* from a desktop/administrator shell.
  internal static IReadOnlyDictionary<string, string> Create(Guid assessment, ulong localAccountId,
      string? variantSha256)
  {
    if (assessment == Guid.Empty || localAccountId == 0 || variantSha256 is not null &&
        (variantSha256.Length != 64 || variantSha256.Any(c => c is not (>= '0' and <= '9') and not (>= 'a' and <= 'f'))))
      throw new InvalidOperationException("user_validation_server_environment_invalid");
    var root = @"C:\NLL\Runtime\EpinelPS-151-UserValidation\" + assessment.ToString("D");
    var environment = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
    {
      ["SystemRoot"] = @"C:\Windows",
      ["WINDIR"] = @"C:\Windows",
      ["PATH"] = @"C:\Windows\System32;C:\Windows;C:\Program Files\dotnet",
      ["DOTNET_ROOT"] = @"C:\Program Files\dotnet",
      ["DOTNET_EnableDiagnostics"] = "0",
      ["DOTNET_ENVIRONMENT"] = "Production",
      ["ASPNETCORE_ENVIRONMENT"] = "Production",
      ["TEMP"] = root + @"\scratch",
      ["TMP"] = root + @"\scratch",
      ["APPDATA"] = root + @"\scratch",
      ["LOCALAPPDATA"] = root + @"\scratch",
      ["ConnectionStrings__EpinelPSConnectionType"] = "sqlite",
      ["ConnectionStrings__EpinelPSConnection"] = "Data Source=\"" + root + "\\epinelps.db\"",
      ["EPINELPS_CLASSIC_SOLO_RAID_ACCOUNT_ID"] = localAccountId.ToString(CultureInfo.InvariantCulture),
      ["EPINELPS_CLASSIC_SOLO_RAID_MANAGER_SELECTION"] = "profile_trusted_unique/v1",
      ["EPINELPS_CLASSIC_SOLO_RAID_TARGET_PROFILE_PATH"] = root + @"\boss-runtime-variant.profile.json"
    };
    if (variantSha256 is not null)
    {
      environment["EPINELPS_CLIENT_STATIC_DATA_VARIANT_PATH"] = root + @"\client-static-data-variant.pack";
      environment["EPINELPS_CLIENT_STATIC_DATA_VARIANT_SHA256"] = variantSha256;
    }
    return environment;
  }
}
