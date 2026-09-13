using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using Xunit;

namespace NikkeLocalLab.Admin.Api.UnitTests;

public sealed class UserValidationAccountTests
{
  private static readonly Guid Assessment = Guid.Parse("936faec8-54d8-4852-8e4c-9b37b6bc2450");
  private static readonly string Revision = new('a', 64);
  private static readonly string Profile = new('b', 64);

  [Theory]
  [InlineData("fire")]
  [InlineData("water")]
  [InlineData("wind")]
  [InlineData("electric")]
  [InlineData("iron")]
  public void PreservesEveryUnrelatedFieldAndDetachesOperatingPersistence(string weakness)
  {
    var (source, proof) = Fixture();
    var sourceBytes = Bytes(source);
    var result = Create(source, proof, weakness);
    var db = JsonNode.Parse(result.Database)!;
    var context = JsonNode.Parse(result.Context)!;
    var receipt = JsonNode.Parse(result.Receipt)!;
    Assert.Equal(sourceBytes, Bytes(source));
    Assert.Equal("synthetic-validation-" + Assessment, context["username"]!.GetValue<string>());
    Assert.Equal(20, context["password"]!.GetValue<string>().Length);
    Assert.Equal(Convert.ToHexString(MD5.HashData(Encoding.UTF8.GetBytes(context["password"]!.GetValue<string>())))
        .ToLowerInvariant(), db["Users"]![0]!["Password"]!.GetValue<string>());
    Assert.Null(db["Users"]![0]!["LocalPersistenceBinding"]);
    Assert.Equal(29001, db["Users"]![0]!["SelectedClassicSoloRaidManagerId"]!.GetValue<int>());
    foreach (var name in new[] { "Username", "Password", "LocalPersistenceBinding", "SelectedClassicSoloRaidManagerId" })
      db["Users"]![0]![name] = source["Users"]![0]![name]?.DeepClone();
    foreach (var name in new[] { "LauncherTokenKey", "EncryptionTokenKey" }) db[name] = source[name]?.DeepClone();
    Assert.True(JsonNode.DeepEquals(source, db));
    Assert.Equal(UserValidationAccount.Hash(result.Database), receipt["runtimeDatabaseSha256"]!.GetValue<string>());
    Assert.Equal(UserValidationAccount.Hash(result.Context), receipt["syntheticContextSha256"]!.GetValue<string>());
    Assert.Equal(weakness, receipt["weaknessCode"]!.GetValue<string>());
    Assert.Equal("not_assessed", receipt["nativeAdmission"]!.GetValue<string>());
    Assert.False(receipt["gameStarted"]!.GetValue<bool>());
    Assert.DoesNotContain("29001", Encoding.UTF8.GetString(result.Receipt));
    Assert.DoesNotContain("password", Encoding.UTF8.GetString(result.Receipt), StringComparison.OrdinalIgnoreCase);
  }

  [Theory]
  [InlineData("contractId")]
  [InlineData("runtimeDatabaseSha256")]
  [InlineData("accountUid")]
  [InlineData("accountRevisionSetSha256")]
  public void RejectsUnboundReceipt(string field)
  {
    var (source, proof) = Fixture();
    proof[field] = "wrong";
    Assert.Throws<InvalidOperationException>(() => Create(source, proof));
  }

  [Theory]
  [InlineData("progressionPreserved", false)]
  [InlineData("sourceDatabaseModified", true)]
  [InlineData("identitySecretPersisted", true)]
  [InlineData("officialOutboundUsed", true)]
  public void RejectsUnapprovedProvenance(string field, bool value)
  {
    var (source, proof) = Fixture();
    proof[field] = value;
    Assert.Throws<InvalidOperationException>(() => Create(source, proof));
  }

  [Theory]
  [InlineData("characterCount")]
  [InlineData("tutorialGroupCount")]
  [InlineData("completedScenarioCount")]
  public void RejectsUnpreparedCounts(string field)
  {
    var (source, proof) = Fixture();
    proof[field] = 0;
    Assert.Throws<InvalidOperationException>(() => Create(source, proof));
  }

  [Theory]
  [InlineData("LocalPersistenceBinding")]
  [InlineData("SelectedClassicSoloRaidManagerId")]
  [InlineData("Characters")]
  [InlineData("ClearedTutorialDataNew")]
  [InlineData("CompletedScenarios")]
  [InlineData("Password")]
  public void RejectsIncompleteSourceEvenWithRecomputedHash(string field)
  {
    var (source, proof) = Fixture();
    source["Users"]![0]!.AsObject().Remove(field);
    proof["runtimeDatabaseSha256"] = UserValidationAccount.Hash(Bytes(source));
    Assert.Throws<InvalidOperationException>(() => Create(source, proof));
  }

  [Theory]
  [InlineData(0)]
  [InlineData(2)]
  public void RejectsWrongAccountCardinality(int count)
  {
    var (source, proof) = Fixture();
    var user = source["Users"]![0]!.DeepClone();
    source["Users"] = new JsonArray(Enumerable.Range(0, count).Select(_ => user.DeepClone()).ToArray());
    proof["runtimeDatabaseSha256"] = UserValidationAccount.Hash(Bytes(source));
    Assert.Throws<InvalidOperationException>(() => Create(source, proof));
  }

  [Fact]
  public void RejectsDuplicateJsonKeysIncludingCaseCollisions()
  {
    var (source, proof) = Fixture();
    var bytes = Encoding.UTF8.GetBytes(source.ToJsonString().Replace("\"Users\":", "\"users\":[],\"Users\":"));
    proof["runtimeDatabaseSha256"] = UserValidationAccount.Hash(bytes);
    Assert.Throws<InvalidOperationException>(() => Transform(bytes, Bytes(proof), "iron"));
  }

  [Theory]
  [InlineData("unknown")]
  [InlineData("Iron")]
  [InlineData("")]
  public void RejectsUnknownWeakness(string weakness)
  {
    var (source, proof) = Fixture();
    Assert.Throws<InvalidOperationException>(() => Create(source, proof, weakness));
  }

  private static UserValidationAccount.Result Create(JsonObject source, JsonObject proof, string weakness = "iron") =>
      Transform(Bytes(source), Bytes(proof), weakness);
  private static UserValidationAccount.Result Transform(byte[] source, byte[] proof, string weakness) =>
      UserValidationAccount.Create(source, proof, Assessment, 29001, 29, weakness, Profile,
          new byte[15], Enumerable.Repeat((byte)1, 32).ToArray(), Enumerable.Repeat((byte)2, 32).ToArray());
  private static byte[] Bytes(JsonNode value) => Encoding.UTF8.GetBytes(value.ToJsonString());

  private static (JsonObject, JsonObject) Fixture()
  {
    var account = "2039c73c-fd8a-4e7b-9f14-f5ec1e0a89de";
    var source = JsonNode.Parse("""
        {"Users":[{"Username":"synthetic-old","Password":"synthetic-hash","LocalPersistenceBinding":{},
          "SelectedClassicSoloRaidManagerId":26001,"Characters":[{"Build":"retained"}],
          "CompletedScenarios":["synthetic-scene"],"ClearedTutorialDataNew":{"1":{"Value":7}},
          "SoloRaidData":{"synthetic-old-season":{"Best":12345678901234567890}},
          "UnknownFutureField":{"nested":[true,null,1.250]}}],
          "LauncherTokenKey":"old","EncryptionTokenKey":"old","UnknownRootField":[1,2,3]}
        """)!.AsObject();
    source["Users"]![0]!["LocalPersistenceBinding"] = new JsonObject
    { ["AccountUid"] = account, ["ProfileRevisionSha256"] = Revision };
    var proof = new JsonObject
    {
      ["contractId"] = "nll/phase-d-runtime-materialization/v1",
      ["runtimeDatabaseSha256"] = UserValidationAccount.Hash(Bytes(source)),
      ["accountUid"] = account,
      ["accountRevisionSetSha256"] = Revision,
      ["characterCount"] = 1,
      ["tutorialGroupCount"] = 1,
      ["completedScenarioCount"] = 1,
      ["progressionPreserved"] = true,
      ["sourceDatabaseModified"] = false,
      ["identitySecretPersisted"] = false,
      ["officialOutboundUsed"] = false
    };
    return (source, proof);
  }
}
