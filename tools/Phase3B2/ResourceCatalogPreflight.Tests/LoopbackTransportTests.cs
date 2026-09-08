using System.Net;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;
using ResourceCatalogPreflight;
using Xunit;

namespace ResourceCatalogPreflight.Tests;

public sealed class LoopbackTransportTests
{
    private static readonly string Digest = new('a', 64);

    [Theory]
    [InlineData("en", "minimal")]
    [InlineData("ko", "minimal")]
    [InlineData("ja", "full")]
    public void OnlySelectedVoiceIsRequired(string language, string scope)
    {
        using var document = JsonDocument.Parse(Receipt(language, scope).ToJsonString());
        Assert.Equal(11, LoopbackTransport.ReadPlan(document.RootElement).Length);
    }

    [Theory]
    [InlineData("https://unapproved.example/prdenv/catalog.db")]
    [InlineData("http://cloud.nikke-kr.com/prdenv/catalog.db")]
    [InlineData("https://cloud.nikke-kr.com:444/prdenv/catalog.db")]
    [InlineData("https://user@cloud.nikke-kr.com/prdenv/catalog.db")]
    [InlineData("https://cloud.nikke-kr.com/prdenv/catalog.db?key=value")]
    public void BadLastEndpointIsRejectedWhileReadingPlanBeforeAnyNetwork(string url)
    {
        var receipt = Receipt();
        receipt["transports"]![4]!["bodyUrl"] = url;
        receipt["transports"]![4]!["signatureUrl"] = url + ".nds";
        using var document = JsonDocument.Parse(receipt.ToJsonString());
        Assert.Equal("resource_transport_contract_invalid", Assert.Throws<PreflightException>(
            () => LoopbackTransport.ReadPlan(document.RootElement)).Message);
    }

    [Theory]
    [InlineData("core")]
    [InlineData("en")]
    public void DuplicateOrWrongVoiceRoleCannotReplaceSelectedVoice(string role)
    {
        var receipt = Receipt();
        receipt["transports"]![4]!["roleCode"] = role;
        using var document = JsonDocument.Parse(receipt.ToJsonString());
        Assert.Equal("resource_transport_members_invalid", Assert.Throws<PreflightException>(
            () => LoopbackTransport.ReadPlan(document.RootElement)).Message);
    }

    [Fact]
    public void SignatureFromAnotherPairIsRejected()
    {
        var receipt = Receipt();
        receipt["transports"]![4]!["signatureUrl"] = "https://cloud.nikke-kr.com/prdenv/other.nds";
        using var document = JsonDocument.Parse(receipt.ToJsonString());
        Assert.Equal("resource_transport_pair_invalid", Assert.Throws<PreflightException>(
            () => LoopbackTransport.ReadPlan(document.RootElement)).Message);
    }

    [Fact]
    public async Task ExactSyntheticResponsePassesWithoutNetwork()
    {
        byte[] bytes = [1, 2, 3, 4];
        using var client = new HttpClient(new ResponseHandler(HttpStatusCode.OK, bytes));
        await LoopbackTransport.VerifyMembersAsync([Member(bytes.Length, bytes)], client);
    }

    [Theory]
    [InlineData(404, 4, "resource_loopback_status_invalid")]
    [InlineData(302, 4, "resource_loopback_status_invalid")]
    [InlineData(200, 3, "resource_loopback_length_mismatch")]
    [InlineData(200, 5, "resource_loopback_length_mismatch")]
    [InlineData(200, 4, "resource_loopback_digest_mismatch")]
    public async Task MissingRedirectedTruncatedAndWrongBodiesFail(int status, int length, string failure)
    {
        using var client = new HttpClient(new ResponseHandler((HttpStatusCode)status, new byte[length]));
        Assert.Equal(failure, (await Assert.ThrowsAsync<PreflightException>(() =>
            LoopbackTransport.VerifyMembersAsync([Member(4, [1, 2, 3, 4])], client))).Message);
    }

    private static LoopbackTransport.Member Member(int length, byte[] bytes) => new(
        new Uri("https://cloud.nikke-kr.com/prdenv/synthetic"), length,
        Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant());

    private sealed class ResponseHandler(HttpStatusCode status, byte[] bytes) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token) =>
            Task.FromResult(new HttpResponseMessage(status) { Content = new ByteArrayContent(bytes) });
    }

    private static JsonObject Receipt(string voice = "ko", string scope = "minimal")
    {
        var members = new JsonArray();
        foreach (var role in new[] { "core", "dp", "fd", "saus", voice })
        {
            var url = "https://cloud.nikke-kr.com/prdenv/synthetic/" + role + "/catalog";
            members.Add(new JsonObject
            {
                ["roleCode"] = role, ["bodyUrl"] = url, ["signatureUrl"] = url + ".nds",
                ["bodyTransportCode"] = "original_nkdb", ["encryptedByteLength"] = 36,
                ["encryptedSha256"] = Digest, ["signatureSha256"] = Digest
            });
        }
        return new JsonObject
        {
            ["contractId"] = "nll/resource-catalog-preflight/v1", ["statusCode"] = "catalogs_verified",
            ["voiceLanguage"] = voice, ["downloadScope"] = scope,
            ["headerUrl"] = "https://cloud.nikke-kr.com/prdenv/synthetic/header",
            ["headerByteLength"] = 1, ["headerSha256"] = Digest, ["transports"] = members
        };
    }
}
