using System.Net;
using System.Net.Http.Json;
using System.Reflection;
using System.Text.Json;
using App = NikkeLocalLab.Application.ProfileManagement;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Admin.Api.UnitTests;

public sealed partial class AdminApiSecurityTests
{
  [Fact]
  public async Task WorkspaceRecoveryApiPreservesReadOnlyDiscoveryAndExactResumeBinding()
  {
    var service = DispatchProxy.Create<App.IProfileManagementService, RecoveryProfiles>();
    var proxy = (RecoveryProfiles)(object)service;
    await using var api = await RunningApi.StartAsync(profiles: service);
    var path = $"/admin-api/v1/accounts/{proxy.Account}/workspace/saves";
    Assert.Equal(HttpStatusCode.Unauthorized, (await api.Client.GetAsync(path)).StatusCode);
    var csrf = await api.GetCsrfAsync();
    var read = await api.Client.GetAsync(path);
    Assert.Equal(HttpStatusCode.OK, read.StatusCode);
    Assert.True(read.Headers.CacheControl!.NoStore);
    Assert.Equal(0, proxy.Writes);
    var json = await read.Content.ReadAsStringAsync();
    Assert.DoesNotContain("requestPayload", json, StringComparison.Ordinal);
    Assert.Contains("exact_request_available", json, StringComparison.Ordinal);
    using var write = new HttpRequestMessage(HttpMethod.Post, path + "/resume");
    write.Headers.TryAddWithoutValidation("Origin", api.Origin);
    write.Headers.TryAddWithoutValidation("X-NLL-CSRF", csrf);
    write.Headers.TryAddWithoutValidation("If-Match", $"\"{proxy.Hash}\"");
    write.Content = JsonContent.Create(new { operationUid = proxy.Operation.ToString() });
    var result = await api.Client.SendAsync(write);
    Assert.Equal(HttpStatusCode.OK, result.StatusCode);
    Assert.Equal(new App.ResumeWorkspaceSaveCommand(proxy.Account, proxy.Operation, proxy.Hash), proxy.LastCommand);
    Assert.Equal(1, proxy.Writes);
  }

  [Theory]
  [InlineData("origin", HttpStatusCode.Forbidden)]
  [InlineData("csrf", HttpStatusCode.Forbidden)]
  [InlineData("if_match", HttpStatusCode.PreconditionRequired)]
  [InlineData("unknown", HttpStatusCode.BadRequest)]
  [InlineData("duplicate", HttpStatusCode.BadRequest)]
  public async Task WorkspaceRecoveryApiRejectsInvalidMutationBeforeCallingService(string missing, HttpStatusCode expected)
  {
    var service = DispatchProxy.Create<App.IProfileManagementService, RecoveryProfiles>();
    var proxy = (RecoveryProfiles)(object)service;
    await using var api = await RunningApi.StartAsync(profiles: service);
    var csrf = await api.GetCsrfAsync();
    using var write = new HttpRequestMessage(HttpMethod.Post, $"/admin-api/v1/accounts/{proxy.Account}/workspace/saves/resume");
    if (missing != "origin") write.Headers.TryAddWithoutValidation("Origin", api.Origin);
    if (missing != "csrf") write.Headers.TryAddWithoutValidation("X-NLL-CSRF", csrf);
    if (missing != "if_match") write.Headers.TryAddWithoutValidation("If-Match", $"\"{proxy.Hash}\"");
    var body = JsonSerializer.Serialize(new { operationUid = proxy.Operation.ToString() });
    if (missing == "unknown") body = body.Insert(1, "\"commanderLevel\":999,");
    if (missing == "duplicate") body = body.Insert(1, $"\"operationUid\":\"{proxy.Operation}\",");
    write.Content = new StringContent(body, System.Text.Encoding.UTF8, "application/json");
    Assert.Equal(expected, (await api.Client.SendAsync(write)).StatusCode);
    Assert.Equal(0, proxy.Writes);
  }

  public class RecoveryProfiles : DispatchProxy
  {
    public EntityUid Account { get; } = EntityUid.New();
    public EntityUid Operation { get; } = EntityUid.New();
    public Sha256Digest Hash { get; } = Sha256Digest.ComputeUtf8("synthetic-request");
    public int Writes { get; private set; }
    public App.ResumeWorkspaceSaveCommand? LastCommand { get; private set; }
    protected override object? Invoke(MethodInfo? targetMethod, object?[]? args)
    {
      if (targetMethod!.Name == nameof(App.IProfileManagementService.GetWorkspaceSaveRecoveryAsync))
        return Task.FromResult<IReadOnlyList<App.WorkspaceSaveRecoveryProjection>>([
          new(Operation, Account, false, "pending", Hash, DateTimeOffset.UnixEpoch, "exact_request_available", null)]);
      if (targetMethod.Name == nameof(App.IProfileManagementService.ResumeWorkspaceSaveAsync))
      {
        Writes++;
        LastCommand = (App.ResumeWorkspaceSaveCommand)args![0]!;
        var revision = new App.RevisionReference(EntityUid.New(), Hash, 1);
        return Task.FromResult(new App.SaveAccountWorkspaceReceipt(Operation, true, false, Account, Account, "synthetic",
            revision, revision, revision, Hash, null));
      }
      throw new InvalidOperationException("unexpected_recovery_service_call");
    }
  }
}
