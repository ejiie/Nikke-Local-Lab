using System.Security.Cryptography;
using System.Text;
using EpinelPS.Models;
using Newtonsoft.Json;

internal static class RuntimeVersionBinding
{
  // A new client is admitted as a complete executable + decoded-data pair.
  // Do not accept either archive merely because it is in a list of known hashes.
  internal static string ExpectedArchive(string build, string executableSha256) => build switch
  {
    "build_150.6.9" when executableSha256 ==
        "2cfaa12b7d708aa6a741faee17c3ac14d8e9cd6be1b5e4e773ee1535b6ddaa30" =>
        "925762cd3ef56601916b2e2ae58f929d4dd389055b0d8bcd2176e9abd9b29e69",
    "build_151.8.5" when executableSha256 ==
        "36fa20306d010087cdb336bbbb8a6718013d4a16838178045b1270af631b1732" =>
        "d14690756e7e8d24cf13df50a7db62a6c932c28e7a759ba6e731fdfcf1e15a5b",
    "build_152.8.11" when executableSha256 ==
        "9c50d1e5e2312783b7ae908237081ff2976e06dcb0d90ae1d59f563afc5c73ef" =>
        "42611495f81734528e8d9f3b4286ed2f8531ad0d75be087a1fb8ef39f9c32367",
    _ => throw new InvalidOperationException("phase_d_client_staticdata_binding_invalid")
  };
}

internal static class RuntimeProgressionSnapshot
{
  // These fields come from the existing local seed, not a fresh probe account.
  // Character/profile edits must not synthesize or reset campaign completion.
  internal static string Capture(User user)
  {
    var json = JsonConvert.SerializeObject(new
    {
      user.LastNormalStageCleared,
      user.LastStoryStageCleared,
      user.LastHardStageCleared,
      user.LastClearedDifficulty,
      user.ClearedTutorialDataNew,
      user.CompletedScenarios,
      user.FieldInfo,
      user.FieldInfoNew,
      user.CompletedSideStoryStages,
      user.ViewedSideStoryStages,
      user.ClearedOutpostScenarioIds,
      user.StageClearHistorys
    });
    return Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(json)));
  }
}
