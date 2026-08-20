using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Microsoft.AspNetCore.Builder;
using NikkeLocalLab.Admin.Api;

namespace NikkeLocalLab.Admin.Api.UnitTests;

[Collection("Admin API environment")]
public sealed class AdminApiSecurityTests
{
  [Fact]
  public void ProductionCompositionFailsClosedWhenRequiredSecurityOrPersistenceIsMissing()
  {
    var hostileArguments = Assert.Throws<InvalidOperationException>(() =>
        AdminApiHost.Build(
            ["--Kestrel:Endpoints:Evil:Url=http://0.0.0.0:0"],
            new AdminApiHostOptions { BootstrapCodeSink = _ => { } }));
    Assert.Equal("admin_host_arguments_not_supported", hostileArguments.Message);

    var missingDelivery = Assert.Throws<InvalidOperationException>(() => AdminApiHost.Build());
    Assert.Equal("admin_bootstrap_delivery_missing", missingDelivery.Message);

    var missingPersistence = Assert.Throws<InvalidOperationException>(() =>
        AdminApiHost.Build(
            [],
            new AdminApiHostOptions
            {
              Port = 0,
              BootstrapCodeSink = _ => { }
            }));
    Assert.Equal("profile_management_composition_missing", missingPersistence.Message);
  }

  [Fact]
  public async Task EditorAndApiAreLoopbackSameOriginAndFailClosed()
  {
    await using var fixture = await RunningApi.StartAsync();

    var editor = await fixture.Client.GetAsync("/editor/");
    Assert.Equal(HttpStatusCode.OK, editor.StatusCode);
    Assert.Equal("DENY", editor.Headers.GetValues("X-Frame-Options").Single());
    Assert.Contains("default-src 'none'", editor.Headers.GetValues("Content-Security-Policy").Single());
    Assert.False(editor.Headers.Contains("Access-Control-Allow-Origin"));
    Assert.Contains("관리 Editor", await editor.Content.ReadAsStringAsync(), StringComparison.Ordinal);

    using var rejectedHost = new HttpRequestMessage(HttpMethod.Get, "/editor/");
    rejectedHost.Headers.Host = "example.invalid";
    var rejectedHostResponse = await fixture.Client.SendAsync(rejectedHost);
    Assert.Equal(HttpStatusCode.Forbidden, rejectedHostResponse.StatusCode);

    var sessionRequired = await fixture.Client.GetAsync("/admin-api/v1/security/csrf");
    Assert.Equal(HttpStatusCode.Unauthorized, sessionRequired.StatusCode);
    Assert.Equal("admin_session_required", await ReadCodeAsync(sessionRequired));
    Assert.Equal("DENY", sessionRequired.Headers.GetValues("X-Frame-Options").Single());
    Assert.Contains(
        "default-src 'none'",
        sessionRequired.Headers.GetValues("Content-Security-Policy").Single());

    var profileUid = Guid.NewGuid().ToString("D");
    var missingOrigin = await fixture.Client.PostAsJsonAsync(
        $"/admin-api/v1/accounts/{Guid.NewGuid():D}/profile/preview",
        new { operationUid = Guid.NewGuid(), operations = Array.Empty<object>() });
    Assert.Equal(HttpStatusCode.Forbidden, missingOrigin.StatusCode);
    Assert.Equal("origin_rejected", await ReadCodeAsync(missingOrigin));

    var csrf = await fixture.GetCsrfAsync();
    using var missingCsrf = new HttpRequestMessage(
        HttpMethod.Post,
        $"/admin-api/v1/accounts/{Guid.NewGuid():D}/profile/preview");
    missingCsrf.Headers.TryAddWithoutValidation("Origin", fixture.Origin);
    missingCsrf.Headers.TryAddWithoutValidation("If-Match", $"\"{profileUid}\"");
    missingCsrf.Content = JsonContent.Create(new
    {
      operationUid = Guid.NewGuid(),
      operations = new[] { new { fieldCode = "character_level", valueKind = "integer", integerValue = 1 } }
    });
    var missingCsrfResponse = await fixture.Client.SendAsync(missingCsrf);
    Assert.Equal(HttpStatusCode.Forbidden, missingCsrfResponse.StatusCode);
    Assert.Equal("csrf_validation_failed", await ReadCodeAsync(missingCsrfResponse));

    using var validGuarded = new HttpRequestMessage(
        HttpMethod.Post,
        $"/admin-api/v1/accounts/{Guid.NewGuid():D}/profile/preview");
    validGuarded.Headers.TryAddWithoutValidation("Origin", fixture.Origin);
    validGuarded.Headers.TryAddWithoutValidation("X-NLL-CSRF", csrf);
    validGuarded.Headers.TryAddWithoutValidation("If-Match", $"\"{profileUid}\"");
    validGuarded.Content = JsonContent.Create(new
    {
      operationUid = Guid.NewGuid(),
      operations = new[] { new { fieldCode = "character_level", valueKind = "integer", integerValue = 1 } }
    });
    var unavailable = await fixture.Client.SendAsync(validGuarded);
    Assert.Equal(HttpStatusCode.ServiceUnavailable, unavailable.StatusCode);
    Assert.Equal("profile_management_not_configured", await ReadCodeAsync(unavailable));
  }

  [Fact]
  public async Task BootstrapCodeIsSingleUseAndIsNotEchoedByTheExchange()
  {
    await using var fixture = await RunningApi.StartAsync();

    using var accepted = await fixture.ExchangeBootstrapAsync();
    Assert.Equal(HttpStatusCode.NoContent, accepted.StatusCode);
    Assert.DoesNotContain(
        fixture.BootstrapCode,
        await accepted.Content.ReadAsStringAsync(),
        StringComparison.Ordinal);

    using var rejected = await fixture.ExchangeBootstrapAsync();
    Assert.Equal(HttpStatusCode.Unauthorized, rejected.StatusCode);
    Assert.Equal("admin_bootstrap_rejected", await ReadCodeAsync(rejected));
  }

  [Fact]
  public async Task DuplicateJsonPropertiesAndUnknownAdminRoutesFailWithControlledResponses()
  {
    await using var fixture = await RunningApi.StartAsync();
    using var duplicate = new HttpRequestMessage(HttpMethod.Post, "/admin-auth/v1/bootstrap");
    duplicate.Headers.TryAddWithoutValidation("Origin", fixture.Origin);
    duplicate.Content = new StringContent(
        $"{{\"code\":\"invalid\",\"code\":\"{fixture.BootstrapCode}\"}}",
        System.Text.Encoding.UTF8,
        "application/json");
    var duplicateResponse = await fixture.Client.SendAsync(duplicate);
    Assert.Equal(HttpStatusCode.BadRequest, duplicateResponse.StatusCode);
    Assert.Equal("request_json_duplicate_property", await ReadCodeAsync(duplicateResponse));

    _ = await fixture.GetCsrfAsync();
    var missing = await fixture.Client.GetAsync("/admin-api/v1/not-a-route");
    Assert.Equal(HttpStatusCode.NotFound, missing.StatusCode);
    Assert.Equal("admin_route_not_found", await ReadCodeAsync(missing));
    Assert.Equal("application/problem+json", missing.Content.Headers.ContentType?.MediaType);
    Assert.Equal("DENY", missing.Headers.GetValues("X-Frame-Options").Single());
  }

  [Fact]
  public async Task HostEnvironmentCannotAddListenersOrReplaceTheStaticRoot()
  {
    var priorEndpoint = Environment.GetEnvironmentVariable("Kestrel__Endpoints__Evil__Url");
    var priorWebRoot = Environment.GetEnvironmentVariable("ASPNETCORE_WEBROOT");
    var priorHostingStartup = Environment.GetEnvironmentVariable(
        "ASPNETCORE_HOSTINGSTARTUPASSEMBLIES");
    try
    {
      Environment.SetEnvironmentVariable(
          "Kestrel__Endpoints__Evil__Url",
          "http://0.0.0.0:0");
      Environment.SetEnvironmentVariable("ASPNETCORE_WEBROOT", FindRepositoryRoot());
      Environment.SetEnvironmentVariable(
          "ASPNETCORE_HOSTINGSTARTUPASSEMBLIES",
          "Untrusted.Hosting.Startup");

      await using var fixture = await RunningApi.StartAsync();
      Assert.Single(fixture.Addresses);
      Assert.StartsWith("http://127.0.0.1:", fixture.Addresses[0], StringComparison.Ordinal);
      var leaked = await fixture.Client.GetAsync("/config/appsettings.example.json");
      Assert.Equal(HttpStatusCode.NotFound, leaked.StatusCode);
    }
    finally
    {
      Environment.SetEnvironmentVariable("Kestrel__Endpoints__Evil__Url", priorEndpoint);
      Environment.SetEnvironmentVariable("ASPNETCORE_WEBROOT", priorWebRoot);
      Environment.SetEnvironmentVariable(
          "ASPNETCORE_HOSTINGSTARTUPASSEMBLIES",
          priorHostingStartup);
    }
  }

  [Fact]
  public async Task ImportApplyRequiresExplicitLevelAuthorityBeforeCallingService()
  {
    await using var fixture = await RunningApi.StartAsync();
    var csrf = await fixture.GetCsrfAsync();
    var draftUid = Guid.NewGuid().ToString("D");
    var profileRevisionUid = Guid.NewGuid().ToString("D");
    var digest = new string('a', 64);
    using var request = new HttpRequestMessage(
        HttpMethod.Post,
        $"/admin-api/v1/import-drafts/{draftUid}/apply");
    request.Headers.TryAddWithoutValidation("Origin", fixture.Origin);
    request.Headers.TryAddWithoutValidation("X-NLL-CSRF", csrf);
    request.Headers.TryAddWithoutValidation("If-Match", $"\"{profileRevisionUid}\"");
    request.Content = JsonContent.Create(new
    {
      operationUid = Guid.NewGuid(),
      expectedDraftSha256 = digest,
      targetAccountUid = Guid.NewGuid(),
      expectedDiffSha256 = digest,
      levelAuthorityPolicy = "unresolved/no_apply",
      scopes = new[] { "full_profile" }
    });

    var response = await fixture.Client.SendAsync(request);
    Assert.Equal(HttpStatusCode.Conflict, response.StatusCode);
    Assert.Equal("level_authority_required", await ReadCodeAsync(response));

    using var accountOnly = new HttpRequestMessage(
        HttpMethod.Post,
        $"/admin-api/v1/import-drafts/{draftUid}/apply");
    accountOnly.Headers.TryAddWithoutValidation("Origin", fixture.Origin);
    accountOnly.Headers.TryAddWithoutValidation("X-NLL-CSRF", csrf);
    accountOnly.Headers.TryAddWithoutValidation("If-Match", $"\"{profileRevisionUid}\"");
    accountOnly.Content = JsonContent.Create(new
    {
      operationUid = Guid.NewGuid(),
      expectedDraftSha256 = digest,
      targetAccountUid = Guid.NewGuid(),
      expectedDiffSha256 = digest,
      levelAuthorityPolicy = "unresolved/no_apply",
      scopes = new[] { "account_state_only" }
    });
    var accountOnlyResponse = await fixture.Client.SendAsync(accountOnly);
    Assert.Equal(HttpStatusCode.ServiceUnavailable, accountOnlyResponse.StatusCode);
    Assert.Equal("profile_management_not_configured", await ReadCodeAsync(accountOnlyResponse));
  }

  [Fact]
  public async Task EmptyEditPreviewIsAcceptedForNoChangeSaveAs()
  {
    await using var fixture = await RunningApi.StartAsync();
    var csrf = await fixture.GetCsrfAsync();
    using var request = new HttpRequestMessage(
        HttpMethod.Post,
        $"/admin-api/v1/accounts/{Guid.NewGuid():D}/profile/preview");
    request.Headers.TryAddWithoutValidation("Origin", fixture.Origin);
    request.Headers.TryAddWithoutValidation("X-NLL-CSRF", csrf);
    request.Headers.TryAddWithoutValidation("If-Match", $"\"{Guid.NewGuid():D}\"");
    request.Content = JsonContent.Create(new
    {
      operationUid = Guid.NewGuid(),
      operations = Array.Empty<object>()
    });

    var response = await fixture.Client.SendAsync(request);
    Assert.Equal(HttpStatusCode.ServiceUnavailable, response.StatusCode);
    Assert.Equal("profile_management_not_configured", await ReadCodeAsync(response));
  }

  [Fact]
  public async Task CreateFromImportPreviewRequiresDraftCasAndExplicitLevelAuthority()
  {
    await using var fixture = await RunningApi.StartAsync();
    var csrf = await fixture.GetCsrfAsync();
    var draftUid = Guid.NewGuid();
    var digest = new string('a', 64);

    async Task<HttpResponseMessage> SendAsync(Guid ifMatch, string levelAuthority)
    {
      using var request = new HttpRequestMessage(
          HttpMethod.Post,
          $"/admin-api/v1/import-drafts/{draftUid:D}/create/preview");
      request.Headers.TryAddWithoutValidation("Origin", fixture.Origin);
      request.Headers.TryAddWithoutValidation("X-NLL-CSRF", csrf);
      request.Headers.TryAddWithoutValidation("If-Match", $"\"{ifMatch:D}\"");
      request.Content = JsonContent.Create(new
      {
        operationUid = Guid.NewGuid(),
        expectedDraftSha256 = digest,
        levelAuthorityPolicy = levelAuthority,
        scopes = new[] { "full_profile" }
      });
      return await fixture.Client.SendAsync(request);
    }

    using var wrongDraft = await SendAsync(Guid.NewGuid(), "roster_observation/v1");
    Assert.Equal(HttpStatusCode.Conflict, wrongDraft.StatusCode);
    Assert.Equal("import_draft_revision_conflict", await ReadCodeAsync(wrongDraft));

    using var unresolved = await SendAsync(draftUid, "unresolved/no_apply");
    Assert.Equal(HttpStatusCode.Conflict, unresolved.StatusCode);
    Assert.Equal("level_authority_required", await ReadCodeAsync(unresolved));

    using var validBoundary = await SendAsync(draftUid, "detail_observation/v1");
    Assert.Equal(HttpStatusCode.ServiceUnavailable, validBoundary.StatusCode);
    Assert.Equal("profile_management_not_configured", await ReadCodeAsync(validBoundary));
  }

  [Fact]
  public async Task ReviewedOverrideRequiresTypedShapeAndDraftCas()
  {
    await using var fixture = await RunningApi.StartAsync();
    var csrf = await fixture.GetCsrfAsync();
    var draftUid = Guid.NewGuid();
    var characterUid = Guid.NewGuid();
    var digest = new string('a', 64);

    async Task<HttpResponseMessage> SendAsync(string kind, Guid ifMatch)
    {
      using var request = new HttpRequestMessage(
          HttpMethod.Post,
          $"/admin-api/v1/import-drafts/{draftUid:D}/review/preview");
      request.Headers.TryAddWithoutValidation("Origin", fixture.Origin);
      request.Headers.TryAddWithoutValidation("X-NLL-CSRF", csrf);
      request.Headers.TryAddWithoutValidation("If-Match", $"\"{ifMatch:D}\"");
      request.Content = JsonContent.Create(new
      {
        operationUid = Guid.NewGuid(),
        expectedDraftSha256 = digest,
        overrides = new[]
        {
          new
          {
            kind,
            characterUid,
            equipmentSlot = (string?)null,
            integerValue = (int?)10,
            booleanValue = (bool?)null,
            reasonCode = "user_reviewed_override"
          }
        },
        expectedDiffSha256 = (string?)null
      });
      return await fixture.Client.SendAsync(request);
    }

    using var wrongDraft = await SendAsync("bond_level", Guid.NewGuid());
    Assert.Equal(HttpStatusCode.Conflict, wrongDraft.StatusCode);
    Assert.Equal("import_draft_revision_conflict", await ReadCodeAsync(wrongDraft));

    using var invalidKind = await SendAsync("arbitrary_field", draftUid);
    Assert.Equal(HttpStatusCode.BadRequest, invalidKind.StatusCode);
    Assert.Equal("import_review_override_kind_invalid", await ReadCodeAsync(invalidKind));

    using var validBoundary = await SendAsync("bond_level", draftUid);
    Assert.Equal(HttpStatusCode.ServiceUnavailable, validBoundary.StatusCode);
    Assert.Equal("profile_management_not_configured", await ReadCodeAsync(validBoundary));
  }

  [Fact]
  public async Task NullCollectionElementsFailAsControlledBadRequests()
  {
    await using var fixture = await RunningApi.StartAsync();
    var csrf = await fixture.GetCsrfAsync();
    var accountUid = Guid.NewGuid();
    var revisionUid = Guid.NewGuid();
    var draftUid = Guid.NewGuid();
    var digest = new string('a', 64);

    async Task<HttpResponseMessage> SendAsync(string path, object body, Guid ifMatch)
    {
      using var request = new HttpRequestMessage(HttpMethod.Post, path);
      request.Headers.TryAddWithoutValidation("Origin", fixture.Origin);
      request.Headers.TryAddWithoutValidation("X-NLL-CSRF", csrf);
      request.Headers.TryAddWithoutValidation("If-Match", $"\"{ifMatch:D}\"");
      request.Content = JsonContent.Create(body);
      return await fixture.Client.SendAsync(request);
    }

    using var edit = await SendAsync(
        $"/admin-api/v1/accounts/{accountUid:D}/profile/preview",
        new { operationUid = Guid.NewGuid(), operations = new object?[] { null } },
        revisionUid);
    Assert.Equal(HttpStatusCode.BadRequest, edit.StatusCode);
    Assert.Equal("profile_edit_operation_invalid", await ReadCodeAsync(edit));

    using var rebase = await SendAsync(
        $"/admin-api/v1/import-drafts/{draftUid:D}/rebase/preview",
        new
        {
          operationUid = Guid.NewGuid(),
          expectedDraftSha256 = digest,
          targetCharacterCatalog = (object?)null,
          targetCombatSupportCatalog = (object?)null,
          explicitMappings = new object?[] { null },
          expectedDiffSha256 = (string?)null
        },
        draftUid);
    Assert.Equal(HttpStatusCode.BadRequest, rebase.StatusCode);
    Assert.Equal("rebase_mapping_set_invalid", await ReadCodeAsync(rebase));

    using var review = await SendAsync(
        $"/admin-api/v1/import-drafts/{draftUid:D}/review/preview",
        new
        {
          operationUid = Guid.NewGuid(),
          expectedDraftSha256 = digest,
          overrides = new object?[] { null },
          expectedDiffSha256 = (string?)null
        },
        draftUid);
    Assert.Equal(HttpStatusCode.BadRequest, review.StatusCode);
    Assert.Equal("import_review_override_invalid", await ReadCodeAsync(review));

    using var wallet = new HttpRequestMessage(
        HttpMethod.Put,
        $"/admin-api/v1/accounts/{accountUid:D}/wallet");
    wallet.Headers.TryAddWithoutValidation("Origin", fixture.Origin);
    wallet.Headers.TryAddWithoutValidation("X-NLL-CSRF", csrf);
    wallet.Headers.TryAddWithoutValidation("If-Match", $"\"{revisionUid:D}\"");
    wallet.Content = JsonContent.Create(new
    {
      operationUid = Guid.NewGuid(),
      balances = new object?[] { null }
    });
    var walletResponse = await fixture.Client.SendAsync(wallet);
    Assert.Equal(HttpStatusCode.BadRequest, walletResponse.StatusCode);
    Assert.Equal("wallet_balance_invalid", await ReadCodeAsync(walletResponse));
  }

  [Fact]
  public async Task WritesRequireIfMatchAndRespectTheKestrelBodyLimit()
  {
    await using var fixture = await RunningApi.StartAsync();
    var csrf = await fixture.GetCsrfAsync();
    using var missingPrecondition = new HttpRequestMessage(
        HttpMethod.Post,
        $"/admin-api/v1/accounts/{Guid.NewGuid():D}/profile/preview");
    missingPrecondition.Headers.TryAddWithoutValidation("Origin", fixture.Origin);
    missingPrecondition.Headers.TryAddWithoutValidation("X-NLL-CSRF", csrf);
    missingPrecondition.Content = JsonContent.Create(new
    {
      operationUid = Guid.NewGuid(),
      operations = new[] { new { fieldCode = "character_level", valueKind = "integer", integerValue = 1 } }
    });
    var missingPreconditionResponse = await fixture.Client.SendAsync(missingPrecondition);
    Assert.Equal((HttpStatusCode)428, missingPreconditionResponse.StatusCode);
    Assert.Equal("if_match_required", await ReadCodeAsync(missingPreconditionResponse));

    using var oversized = new HttpRequestMessage(
        HttpMethod.Post,
        $"/admin-api/v1/accounts/{Guid.NewGuid():D}/profile/preview");
    oversized.Headers.TryAddWithoutValidation("Origin", fixture.Origin);
    oversized.Headers.TryAddWithoutValidation("X-NLL-CSRF", csrf);
    oversized.Headers.TryAddWithoutValidation("If-Match", $"\"{Guid.NewGuid():D}\"");
    oversized.Content = JsonContent.Create(new
    {
      operationUid = Guid.NewGuid(),
      operations = new[]
      {
        new
        {
          fieldCode = "character_level",
          valueKind = "controlled",
          controlledValue = new string('a', 20_000)
        }
      }
    });
    var oversizedResponse = await fixture.Client.SendAsync(oversized);
    Assert.Equal(HttpStatusCode.RequestEntityTooLarge, oversizedResponse.StatusCode);
  }

  [Fact]
  public async Task WalletRequiresTheExactJewelAndCreditSet()
  {
    await using var fixture = await RunningApi.StartAsync();
    var csrf = await fixture.GetCsrfAsync();
    var accountUid = Guid.NewGuid();
    var revisionUid = Guid.NewGuid();

    async Task<HttpResponseMessage> SendAsync(object[] balances)
    {
      using var request = new HttpRequestMessage(
          HttpMethod.Put,
          $"/admin-api/v1/accounts/{accountUid:D}/wallet");
      request.Headers.TryAddWithoutValidation("Origin", fixture.Origin);
      request.Headers.TryAddWithoutValidation("X-NLL-CSRF", csrf);
      request.Headers.TryAddWithoutValidation("If-Match", $"\"{revisionUid:D}\"");
      request.Content = JsonContent.Create(new { operationUid = Guid.NewGuid(), balances });
      return await fixture.Client.SendAsync(request);
    }

    using var incomplete = await SendAsync(
        [new { currencyCode = "jewel", balance = 1L }]);
    Assert.Equal(HttpStatusCode.BadRequest, incomplete.StatusCode);
    Assert.Equal("wallet_balance_set_invalid", await ReadCodeAsync(incomplete));

    using var exact = await SendAsync(
        [
          new { currencyCode = "jewel", balance = 1L },
          new { currencyCode = "credit", balance = 2L }
        ]);
    Assert.Equal(HttpStatusCode.ServiceUnavailable, exact.StatusCode);
    Assert.Equal("profile_management_not_configured", await ReadCodeAsync(exact));
  }

  private static async Task<string?> ReadCodeAsync(HttpResponseMessage response)
  {
    using var document = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
    return document.RootElement.GetProperty("code").GetString();
  }

  private static string FindRepositoryRoot()
  {
    var current = new DirectoryInfo(AppContext.BaseDirectory);
    while (current is not null && !File.Exists(Path.Combine(current.FullName, "NikkeLocalLab.sln")))
    {
      current = current.Parent;
    }

    return current?.FullName ?? throw new InvalidOperationException("repository_root_not_found");
  }

  private sealed class RunningApi : IAsyncDisposable
  {
    private readonly WebApplication _application;

    private bool _loggedIn;

    private RunningApi(
        WebApplication application,
        HttpClient client,
        string origin,
        string bootstrapCode,
        IReadOnlyList<string> addresses)
    {
      _application = application;
      Client = client;
      Origin = origin;
      BootstrapCode = bootstrapCode;
      Addresses = addresses;
    }

    public HttpClient Client { get; }

    public string Origin { get; }

    public string BootstrapCode { get; }

    public IReadOnlyList<string> Addresses { get; }

    public static async Task<RunningApi> StartAsync()
    {
      string? bootstrapCode = null;
      var application = AdminApiHost.Build(
          [],
          new AdminApiHostOptions
          {
            Port = 0,
            MaximumRequestBodyBytes = 16_384,
            BootstrapCodeSink = code => bootstrapCode = code,
            AllowUnavailableProfileManagementForTests = true
          });
      await application.StartAsync();
      var addresses = application.Urls.Order(StringComparer.Ordinal).ToArray();
      var address = addresses.Single(url => url.StartsWith("http://127.0.0.1:", StringComparison.Ordinal));
      var handler = new HttpClientHandler
      {
        CookieContainer = new CookieContainer(),
        UseCookies = true,
        AllowAutoRedirect = false
      };
      return new RunningApi(
          application,
          new HttpClient(handler) { BaseAddress = new Uri(address) },
          address,
          bootstrapCode ?? throw new InvalidOperationException("bootstrap_code_missing"),
          addresses);
    }

    public async Task<string> GetCsrfAsync()
    {
      if (!_loggedIn)
      {
        using var loginResponse = await ExchangeBootstrapAsync();
        loginResponse.EnsureSuccessStatusCode();
        _loggedIn = true;
      }

      var response = await Client.GetAsync("/admin-api/v1/security/csrf");
      response.EnsureSuccessStatusCode();
      using var document = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
      return document.RootElement.GetProperty("requestToken").GetString() ??
          throw new InvalidOperationException("csrf_missing");
    }

    public async Task<HttpResponseMessage> ExchangeBootstrapAsync()
    {
      using var login = new HttpRequestMessage(HttpMethod.Post, "/admin-auth/v1/bootstrap");
      login.Headers.TryAddWithoutValidation("Origin", Origin);
      login.Content = JsonContent.Create(new { code = BootstrapCode });
      return await Client.SendAsync(login);
    }

    public async ValueTask DisposeAsync()
    {
      Client.Dispose();
      await _application.StopAsync();
      await _application.DisposeAsync();
    }
  }
}
