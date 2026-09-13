using System.Text;
using System.Text.Json;
using NikkeLocalLab.Phase3B2.LocalBootstrap;

namespace NikkeLocalLab.Admin.Api.UnitTests;

public sealed class UserValidationBootstrapPlanTests
{
  private static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
  internal static UserValidationBootstrapPlan Example()
  {
    var assessment = "11111111-1111-4111-8111-111111111111";
    var trial = "22222222-2222-4222-8222-222222222222";
    var runtime = UserValidationBootstrapPlan.RuntimeParent + "\\" + assessment;
    var client = @"C:\NLL\Clients\NIKKE-151.8.5-UserValidation-" + trial;
    UserValidationFilePin Pin(string path, string? hash = null) => new(path, 100, hash ?? new string('a', 64));
    var store = Pin(client + @"\Unity\com_proximabeta_NIKKE\com.shiftup.patch\synthetic\store.cdb");
    return new("nll/native-fx-user-validation-bootstrap/v1", assessment, trial, "user", 1200, 29,
      "water", "candidate", new string('b', 64), new string('c', 64), new string('d', 64),
      "Local\\NLL.FxValidation." + Guid.Parse(assessment).ToString("N"), store,
      new[] { "synthetic-context.json", "server.cer", "trust-root.cer", "sail_api_impl64.dll",
        "NikkeLocalLab.NativeFxUserValidationBootstrap.exe", "NikkeLocalLab.NativeFxUserValidationBootstrap.dll" }
        .Select(name => Pin(runtime + "\\" + name, name switch
        {
          "sail_api_impl64.dll" => "8e0a742c4092738e65cac47d58a3b0780bedff7fc4a0cac2b7abfeb989adad1d",
          "trust-root.cer" => "6228094602b86c0f3481f1a8c6e4e4964c2a324b609bc3eda4c2be05c08cfeda",
          _ => null
        })).ToArray(),
      [Pin(client + @"\NIKKE\game\nikke.exe", "36fa20306d010087cdb336bbbb8a6718013d4a16838178045b1270af631b1732"),
        Pin(client + @"\NIKKE\game\GameAssembly.dll", "23b64ef22957356bfb3f02096a8fd59c5e2b6426bafb44520acd7fcd12a060ed"),
        Pin(client + @"\NIKKE\game\nikke_Data\Plugins\x86_64\sodium.dll", "54ee18f5ee3d16fea8bb6c3407a880727aa3b848f6a55908e6bf90f8635e5662"),
        store]);
  }
  public static IEnumerable<object[]> Cases() => from weakness in new[] { "fire", "water", "wind", "electric", "iron" }
                                                 from caseCode in new[] { "baseline", "candidate", "restored" }
                                                 select new object[] { weakness, caseCode };
  [Theory]
  [MemberData(nameof(Cases))]
  public void AllFiveWeaknessesHaveSeparateBaselineCandidateAndRestoredCases(string weakness, string caseCode)
  {
    var plan = Example() with { WeaknessCode = weakness, CaseCode = caseCode };
    var copy = UserValidationBootstrapPlan.Parse(JsonSerializer.SerializeToUtf8Bytes(plan, Json));
    Assert.Equal(weakness, copy.WeaknessCode);
    Assert.Equal(caseCode, copy.CaseCode);
    Assert.Equal(plan.ClientRoot, copy.ClientRoot);
    Assert.NotEqual(@"C:\NLL\Clients\NIKKE-151.8.5-ResourceProbe", copy.ClientRoot);
  }
  [Theory]
  [InlineData("..\\outside.dll")]
  [InlineData("bad/other.dll")]
  [InlineData("x.dll:stream")]
  [InlineData("x.dll.")]
  [InlineData("NUL")]
  [InlineData("COM1.dll")]
  [InlineData("LPT9")]
  [InlineData("x\\..\\y")]
  [InlineData("x\\\\y")]
  [InlineData("x\ny")]
  [InlineData(" file.txt")]
  [InlineData("file.txt ")]
  [InlineData("file\".txt")]
  public void RuntimeMembersRejectAliasTraversalAndWindowsDevices(string relative)
  {
    var plan = Example();
    var pins = plan.RuntimeFiles.Append(new(plan.RuntimeRoot + "\\" + relative, 3, new string('a', 64))).ToArray();
    Assert.Throws<InvalidOperationException>(() => (plan with { RuntimeFiles = pins }).ValidateShape());
  }
  [Fact]
  public void UserOwnerJobIdentityApprovalPinsAndExactStoreMembershipAreMandatory()
  {
    var p = Example();
    foreach (var invalid in new[] { p with { ExecutionOwnerCode = "agent" }, p with { JobName = "Local\\other" },
      p with { ContractId = "nll/native-fx-probe-bootstrap/v1" }, p with { TrialUid = p.AssessmentUid },
      p with { TrialUid = Guid.Empty.ToString("D") }, p with { WeaknessCode = "none" },
      p with { DurationSeconds = 1801 }, p with { DurationSeconds = 59 }, p with { CaseCode = "ready" },
      p with { ParentPlanSha256 = "" }, p with { NativeStore = p.NativeStore with { Sha256 = new string('0', 64) } },
      p with { SeasonNumber = 0 }, p with { SeasonNumber = 1001 },
      p with { ClientFiles = p.ClientFiles.Skip(1).ToArray() } })
      Assert.Throws<InvalidOperationException>(invalid.ValidateShape);
    var changed = p.ClientFiles.ToArray();
    changed[2] = changed[2] with { Sha256 = new string('0', 64) };
    Assert.Throws<InvalidOperationException>(() => (p with { ClientFiles = changed }).ValidateShape());
    foreach (var name in new[] { "sail_api_impl64.dll", "trust-root.cer" })
    {
      var runtime = p.RuntimeFiles.Select(pin => pin.Path.EndsWith("\\" + name, StringComparison.Ordinal)
          ? pin with { Sha256 = new string('0', 64) } : pin).ToArray();
      Assert.Throws<InvalidOperationException>(() => (p with { RuntimeFiles = runtime }).ValidateShape());
    }
  }
  [Fact]
  public void DuplicateAndUnknownJsonFieldsCannotCreateAlternativeInterpretations()
  {
    var json = JsonSerializer.Serialize(Example(), Json);
    foreach (var extra in new[] { "\"executionOwnerCode\":\"agent\",", "\"clientRoot\":\"C:\\\\NIKKE\",", "\"authOnly\":true," })
    {
      var bytes = Encoding.UTF8.GetBytes("{" + extra + json[1..]);
      Assert.ThrowsAny<Exception>(() => UserValidationBootstrapPlan.Parse(bytes));
    }
    Assert.ThrowsAny<Exception>(() => UserValidationBootstrapPlan.Parse(Encoding.UTF8.GetBytes(json.Replace(
      "\"length\":100", "\"length\":1,\"length\":100", StringComparison.Ordinal))));
  }
  [Fact]
  public void DuplicateCrossRootMissingAndUnboundedFilesAreRejected()
  {
    var p = Example();
    foreach (var runtimePins in new[] { p.RuntimeFiles.Skip(1).ToArray(), p.RuntimeFiles.Append(p.RuntimeFiles[0]).ToArray(),
      p.RuntimeFiles.Append(p.ClientFiles[0]).ToArray(), p.RuntimeFiles.Append(new UserValidationFilePin(
        p.RuntimeRoot + @"\large.bin", 512L * 1024 * 1024 + 1, new string('a', 64))).ToArray() })
      Assert.Throws<InvalidOperationException>(() => (p with { RuntimeFiles = runtimePins }).ValidateShape());
    var bigStore = p.NativeStore with { Length = 6574364321 };
    (p with { NativeStore = bigStore, ClientFiles = p.ClientFiles.Take(3).Append(bigStore).ToArray() }).ValidateShape();
    var aliases = p.ClientFiles.Append(p.ClientFiles[0] with { Path = p.ClientFiles[0].Path.Replace("nikke.exe", "NIKKE.EXE", StringComparison.Ordinal) }).ToArray();
    Assert.Throws<InvalidOperationException>(() => (p with { ClientFiles = aliases }).ValidateShape());
  }

  [Fact]
  public void CasesCanShareTheTrialCloneWithoutOverwritingAnotherRunPlan()
  {
    var baseline = Example() with { CaseCode = "baseline" };
    var candidate = baseline with { AssessmentUid = "33333333-3333-4333-8333-333333333333", CaseCode = "candidate", WeaknessCode = "iron" };
    Assert.Equal(baseline.ClientRoot, candidate.ClientRoot);
    Assert.NotEqual(baseline.RuntimeRoot, candidate.RuntimeRoot);
    Assert.NotEqual(baseline.ParentPlanPath, candidate.ParentPlanPath);
    Assert.Equal(baseline.RunRoot + @"\validation.private.json", baseline.ParentPlanPath);
    Assert.Equal(candidate.RunRoot + @"\validation.private.json", candidate.ParentPlanPath);
  }

  [Fact]
  public void PinnedClientInventoryIncludesEmptyFilesAndLiteralSpacesOrParentheses()
  {
    var p = Example();
    var empty = new UserValidationFilePin(p.ClientRoot + @"\NIKKE\game\Synthetic Group(HD).txt", 0,
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
    (p with { ClientFiles = p.ClientFiles.Append(empty).ToArray() }).ValidateShape();
    Assert.Throws<InvalidOperationException>(() => (p with
    {
      ClientFiles = p.ClientFiles.Append(empty with { Sha256 = new string('0', 64) }).ToArray()
    }).ValidateShape());
    Assert.Throws<InvalidOperationException>(() => (p with
    {
      RuntimeFiles = p.RuntimeFiles.Append(empty with { Path = p.RuntimeRoot + @"\empty.dll" }).ToArray()
    }).ValidateShape());
  }
}
