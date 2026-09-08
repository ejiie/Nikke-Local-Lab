using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using Microsoft.AspNetCore.Http;
using ResourceCatalogPreflight;
using Xunit;

namespace ResourceCatalogPreflight.Tests;

public sealed class ResourceRouteProbeHostTests
{
  [Fact]
  public void CertificateMustHavePrivateKeyValidDatesAndMatchingSan()
  {
    using var certificate = CreateCertificate();
    ResourceRouteProbeHost.ValidateCertificate(certificate, "fixture.example");
    Assert.Throws<PreflightException>(() => ResourceRouteProbeHost.ValidateCertificate(certificate, "other.example"));
    using var publicOnly = X509CertificateLoader.LoadCertificate(certificate.RawData);
    Assert.Throws<PreflightException>(() => ResourceRouteProbeHost.ValidateCertificate(publicOnly, "fixture.example"));
    using var expired = CreateCertificate(expired: true);
    Assert.Throws<PreflightException>(() => ResourceRouteProbeHost.ValidateCertificate(expired, "fixture.example"));
  }

  [Fact]
  public async Task RealTlsLoopbackServesOnlyMetadataWithPrivateTrustAndStopsCleanly()
  {
    using var certificate = CreateCertificate();
    var bytes = Encoding.UTF8.GetBytes("abcdef0\ncore:151.8.b1,123\ndp:abcdef1,124\nfd:abcdef2,125\nsaus:abcdef3,126\nko:abcdef4,127\nen:abcdef5,128\nja:abcdef6,129\n");
    var digest = Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
    var count = 0;
    var endpoint = new ResourceRouteProbe("fixture.example", "/fixture/pck/latest-123.txt", bytes, digest,
        _ => { count++; return true; }, port: 8443);
    await using var app = ResourceRouteProbeHost.CreateApplication(Path.GetTempPath(), certificate,
        endpoint.HandleAsync, port: 0);
    await app.StartAsync();
    var address = Assert.Single(app.Urls);
    Assert.StartsWith("https://127.0.0.1:", address);
    var localPort = new Uri(address).Port;
    try
    {
      using var handler = new SocketsHttpHandler
      {
        UseProxy = false,
        UseCookies = false,
        AllowAutoRedirect = false,
        ConnectCallback = async (_, cancellation) =>
        {
          var socket = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
          try
          {
            await socket.ConnectAsync(new IPEndPoint(IPAddress.Loopback, localPort), cancellation);
            return new NetworkStream(socket, ownsSocket: true);
          }
          catch { socket.Dispose(); throw; }
        },
        SslOptions = new SslClientAuthenticationOptions
        {
          CertificateChainPolicy = new X509ChainPolicy
          {
            TrustMode = X509ChainTrustMode.CustomRootTrust,
            CustomTrustStore = { certificate },
            RevocationMode = X509RevocationMode.NoCheck,
            DisableCertificateDownloads = true
          }
        }
      };
      using var client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(10) };
      using var metadata = await client.GetAsync("https://fixture.example:8443/fixture/pck/latest-123.txt");
      Assert.Equal(HttpStatusCode.OK, metadata.StatusCode);
      Assert.Equal(bytes, await metadata.Content.ReadAsByteArrayAsync());
      using var catalog = await client.GetAsync("https://fixture.example:8443/catalog.ndb");
      Assert.Equal(HttpStatusCode.NotFound, catalog.StatusCode);
      Assert.Empty(await catalog.Content.ReadAsByteArrayAsync());
      // Default hostname validation remains enabled, despite the private test root.
      await Assert.ThrowsAsync<HttpRequestException>(() => client.GetAsync("https://other.example:8443/catalog.ndb"));
      Assert.Equal(2, count);
    }
    finally { await app.StopAsync(); }
    using var probe = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
    using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(3));
    await Assert.ThrowsAsync<SocketException>(async () =>
        await probe.ConnectAsync(new IPEndPoint(IPAddress.Loopback, localPort), timeout.Token));
  }

  private static X509Certificate2 CreateCertificate(bool expired = false)
  {
    using var key = RSA.Create(2048);
    var request = new CertificateRequest("CN=fixture.example", key, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
    request.CertificateExtensions.Add(new X509BasicConstraintsExtension(true, false, 0, true));
    var names = new SubjectAlternativeNameBuilder();
    names.AddDnsName("fixture.example");
    request.CertificateExtensions.Add(names.Build());
    using var generated = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-2),
        DateTimeOffset.UtcNow.AddDays(expired ? -1 : 1));
    var pfx = generated.Export(X509ContentType.Pfx);
    try { return X509CertificateLoader.LoadPkcs12(pfx, "", X509KeyStorageFlags.DefaultKeySet); }
    finally { CryptographicOperations.ZeroMemory(pfx); }
  }
}
