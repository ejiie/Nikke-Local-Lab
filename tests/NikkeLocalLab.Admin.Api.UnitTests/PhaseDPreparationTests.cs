using System.Text.Json;
using System.Text.Json.Nodes;

namespace NikkeLocalLab.Admin.Api.UnitTests;

public sealed class PhaseDPreparationTests
{
  private static string Json(PhaseDPreparationProjection projection) => JsonSerializer.Serialize(projection,
      new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase });

  [Fact]
  public void ReadyAndBlockedHaveStrictSourceFreeShapes()
  {
    var ready = new PhaseDPreparationProjection(1, "nll/phase-d-preparation/v1", 26, "water", "ready", null, new string('a', 64), "build_151.8.5");
    Assert.Equal(ready, PowerShellPhaseDPreparationService.ParseProjection(Json(ready), 26, "water"));
    var blocked = PhaseDPreparationProjection.Blocked(29, "fire", "phase_d_boss_variant_profile_drifted");
    Assert.Equal(blocked, PowerShellPhaseDPreparationService.ParseProjection(Json(blocked), 29, "fire"));
  }

  [Theory]
  [InlineData("schemaVersion", "2")]
  [InlineData("contractId", "\"other\"")]
  [InlineData("seasonNumber", "29")]
  [InlineData("weaknessCode", "\"fire\"")]
  [InlineData("bindingSha256", "null")]
  [InlineData("statusCode", "\"started\"")]
  [InlineData("clientBuildCode", "\"unknown\"")]
  [InlineData("failureCode", "\"C:\\\\private\"")]
  [InlineData("plan", "{}")]
  public void RejectsUnexpectedOrPrivateProjection(string field, string value)
  {
    var node = JsonNode.Parse(Json(new PhaseDPreparationProjection(1, "nll/phase-d-preparation/v1", 26, "water", "ready", null, new string('a', 64), "build_151.8.5")))!;
    node[field] = JsonNode.Parse(value);
    Assert.Throws<JsonException>(() => PowerShellPhaseDPreparationService.ParseProjection(node.ToJsonString(), 26, "water"));
  }

  [Fact]
  public async Task UnavailableOrInvalidQueryCannotBeReady()
  {
    var unavailable = await new UnavailablePhaseDPreparationService().PrepareAsync(26, "water");
    Assert.Equal("blocked", unavailable.StatusCode);
    var service = new PowerShellPhaseDPreparationService("not-used", "not-used");
    Assert.Equal("phase_d_launch_request_invalid", (await service.PrepareAsync(26, "WATER")).FailureCode);
    Assert.Equal("phase_d_preparation_unavailable", (await service.PrepareAsync(26, "water")).FailureCode);
  }
}
