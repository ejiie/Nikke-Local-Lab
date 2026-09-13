using System.Text.Json;
using System.Text.Json.Nodes;
using NikkeLocalLab.Phase3B2.LocalBootstrap;
using NikkeLocalLab.Phase3B2.UserValidation;

namespace NikkeLocalLab.Admin.Api.UnitTests;

public sealed class UserValidationProcessInputsTests
{
  internal static JsonObject Staging(UserValidationBootstrapPlan plan)
  {
    var root = @"C:\NLL\Runtime\EpinelPS-151-UserValidation\" + plan.AssessmentUid;
    var files = new[] { "EpinelPS.exe", "EpinelPS.dll", "EpinelPS.deps.json", "EpinelPS.runtimeconfig.json",
      "db.json", "site.pfx", "gameconfig.json", "boss-runtime-variant.profile.json" }.Select(name =>
        new UserValidationFilePin(root + "\\" + name, 100,
          name == "boss-runtime-variant.profile.json" ? plan.ProfileSha256 : new string('a', 64))).ToList();
    if (plan.WeaknessCode != "iron") files.Add(new(root + @"\client-static-data-variant.pack", 100, new string('f', 64)));
    return JsonSerializer.SerializeToNode(new
    {
      contractId = "nll/user-validation-runtime-staging/v1",
      plan.AssessmentUid,
      plan.TrialUid,
      executionOwnerCode = "user",
      plan.SeasonNumber,
      plan.WeaknessCode,
      plan.ProfileSha256,
      plan.CandidateReceiptSha256,
      serverRoot = root,
      bootstrapRoot = plan.RuntimeRoot,
      runRoot = plan.RunRoot,
      installedBundlePreserved = true,
      preparedAccountPreserved = true,
      serverStarted = false,
      gameStarted = false,
      clientModified = false,
      systemChangesApplied = false,
      readyForGameLaunch = false,
      runtimeAdmissionStatusCode = "not_assessed",
      serverFiles = files,
      bootstrapFiles = plan.RuntimeFiles,
      staticDataVariantRequired = plan.WeaknessCode != "iron",
      variantStaticDataSha256 = plan.WeaknessCode == "iron" ? null : new string('f', 64)
    }, new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase })!.AsObject();
  }

  private static UserValidationProcessInputs Bind(UserValidationBootstrapPlan plan, JsonObject staging)
  {
    using var document = JsonDocument.Parse(staging.ToJsonString());
    return UserValidationProcessInputs.Bind(plan, document.RootElement);
  }

  [Theory]
  [InlineData("fire")]
  [InlineData("water")]
  [InlineData("wind")]
  [InlineData("electric")]
  [InlineData("iron")]
  public void StartsOnlyBoundIndependentServerAndExplicitUserBootstrap(string weakness)
  {
    var plan = UserValidationBootstrapPlanTests.Example() with { WeaknessCode = weakness };
    var inputs = Bind(plan, Staging(plan));
    var server = inputs.ServerStart(42);
    Assert.Equal(inputs.ServerRoot + @"\EpinelPS.exe", server.FileName);
    Assert.Equal(inputs.ServerRoot, server.WorkingDirectory);
    Assert.Equal(new[] { "--headless", "--local-only" }, server.ArgumentList);
    Assert.False(server.UseShellExecute);
    Assert.True(server.CreateNoWindow && server.RedirectStandardError && server.RedirectStandardOutput);
    Assert.Equal(weakness == "iron" ? 16 : 18, server.Environment.Count);
    Assert.Equal("sqlite", server.Environment["ConnectionStrings__EpinelPSConnectionType"]);
    Assert.Equal("42", server.Environment["EPINELPS_CLASSIC_SOLO_RAID_ACCOUNT_ID"]);
    Assert.Equal(weakness == "iron" ? null : new string('f', 64), inputs.VariantSha256);
    var bootstrap = inputs.BootstrapStart(new string('a', 64));
    Assert.Equal(plan.RuntimeRoot + @"\NikkeLocalLab.NativeFxUserValidationBootstrap.exe", bootstrap.FileName);
    Assert.Equal(plan.RuntimeRoot, bootstrap.WorkingDirectory);
    Assert.Equal(new[] { "--user-start" }, bootstrap.ArgumentList);
    Assert.Equal(8, bootstrap.Environment.Count);
    Assert.Equal(new string('a', 64), bootstrap.Environment["NLL_USER_VALIDATION_BOOTSTRAP_SHA256"]);
    Assert.Equal(plan.RunRoot + @"\scratch", bootstrap.Environment["TEMP"]);
    foreach (var info in new[] { server, bootstrap })
      foreach (var forbidden in new[] { "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "ASPNETCORE_URLS",
          "DOTNET_STARTUP_HOOKS", "DOTNET_ADDITIONAL_DEPS", "__COMPAT_LAYER", "EPINELPS_CLASSIC_SOLO_RAID_MANAGER_ID" })
        Assert.False(info.Environment.ContainsKey(forbidden));
  }

  [Theory]
  [InlineData("trialUid")]
  [InlineData("assessmentUid")]
  [InlineData("profileSha256")]
  [InlineData("candidateReceiptSha256")]
  [InlineData("weaknessCode")]
  [InlineData("executionOwnerCode")]
  [InlineData("serverRoot")]
  [InlineData("bootstrapRoot")]
  [InlineData("runRoot")]
  [InlineData("runtimeAdmissionStatusCode")]
  public void RejectsCrossRunAndPublicationDrift(string field)
  {
    var plan = UserValidationBootstrapPlanTests.Example();
    var staging = Staging(plan); staging[field] = "wrong";
    Assert.Throws<InvalidOperationException>(() => Bind(plan, staging));
  }

  [Theory]
  [InlineData("installedBundlePreserved")]
  [InlineData("preparedAccountPreserved")]
  [InlineData("serverStarted")]
  [InlineData("gameStarted")]
  [InlineData("clientModified")]
  [InlineData("systemChangesApplied")]
  [InlineData("readyForGameLaunch")]
  [InlineData("staticDataVariantRequired")]
  public void RejectsChangedPreparationFacts(string field)
  {
    var plan = UserValidationBootstrapPlanTests.Example();
    var staging = Staging(plan); staging[field] = !staging[field]!.GetValue<bool>();
    Assert.Throws<InvalidOperationException>(() => Bind(plan, staging));
  }

  [Theory]
  [InlineData("missing")]
  [InlineData("duplicate")]
  [InlineData("cross-root")]
  [InlineData("too-large")]
  [InlineData("empty")]
  [InlineData("profile")]
  [InlineData("variant")]
  [InlineData("sqlite")]
  [InlineData("bootstrap")]
  public void RejectsUnsafeOrInconsistentFileSets(string mutation)
  {
    var plan = UserValidationBootstrapPlanTests.Example(); var staging = Staging(plan);
    var files = staging["serverFiles"]!.AsArray();
    switch (mutation)
    {
      case "missing": files.RemoveAt(0); break;
      case "duplicate": files.Add(files[0]!.DeepClone()); break;
      case "cross-root": files[0]!["path"] = plan.RuntimeRoot + @"\EpinelPS.exe"; break;
      case "too-large": files[0]!["length"] = 536870913L; break;
      case "empty": files[0]!["length"] = 0; break;
      case "profile": files[7]!["sha256"] = new string('0', 64); break;
      case "variant": files[8]!["sha256"] = new string('0', 64); break;
      case "sqlite":
        var extra = files[0]!.DeepClone(); extra["path"] = staging["serverRoot"]!.GetValue<string>() + @"\epinelps.db";
        files.Add(extra); break;
      case "bootstrap": staging["bootstrapFiles"]![0]!["sha256"] = new string('0', 64); break;
    }
    Assert.Throws<InvalidOperationException>(() => Bind(plan, staging));
  }

  [Fact]
  public void DuplicateInputFieldsAndUnpreparedAccountsCannotBeConsumed()
  {
    var p = UserValidationBootstrapPlanTests.Example();
    using var duplicate = JsonDocument.Parse("{\"executionOwnerCode\":\"agent\"," + Staging(p).ToJsonString()[1..]);
    Assert.Throws<InvalidOperationException>(() => UserValidationProcessInputs.Bind(p, duplicate.RootElement));
    const string user = "{\"ID\":42,\"Username\":\"synthetic-validation-example\",\"LocalPersistenceBinding\":null,\"SelectedClassicSoloRaidManagerId\":7}";
    using var valid = JsonDocument.Parse("{\"Users\":[" + user + "]}");
    Assert.Equal(42UL, UserValidationProcessInputs.ReadLocalAccountId(valid.RootElement));
    foreach (var input in new[] { "{\"Users\":[]}", "{\"Users\":[" + user + "," + user + "]}",
        valid.RootElement.GetRawText().Replace("synthetic-validation-", "other-", StringComparison.Ordinal),
        valid.RootElement.GetRawText().Replace(":42", ":0", StringComparison.Ordinal),
        valid.RootElement.GetRawText().Replace(":null", ":{}", StringComparison.Ordinal) })
    {
      using var invalid = JsonDocument.Parse(input);
      Assert.Throws<InvalidOperationException>(() => UserValidationProcessInputs.ReadLocalAccountId(invalid.RootElement));
    }
  }

  [Fact]
  public void OriginalIronInputHasNoInventedDerivedPackHash()
  {
    var plan = UserValidationBootstrapPlanTests.Example() with { WeaknessCode = "iron" };
    var stage = Staging(plan);
    Assert.Null(Bind(plan, stage).VariantSha256);
    stage["variantStaticDataSha256"] = new string('f', 64);
    Assert.Throws<InvalidOperationException>(() => Bind(plan, stage));
  }
}
