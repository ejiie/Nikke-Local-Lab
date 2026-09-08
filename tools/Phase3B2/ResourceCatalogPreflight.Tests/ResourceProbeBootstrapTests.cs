using System.Net;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using NikkeLocalLab.Phase3B2.LocalBootstrap;
using Xunit;

namespace ResourceCatalogPreflight.Tests;

public sealed class ResourceProbeBootstrapTests
{
  [Theory]
  [InlineData("li-sg.intlgame.com", 443, true)]
  [InlineData("aws-na.intlgame.com", 443, true)]
  [InlineData("li-sg.intlgame.com", 80, false)]
  [InlineData("aws-na.intlgame.com", 8443, false)]
  [InlineData("cloud.nikke-kr.com", 443, false)]
  [InlineData("other.example", 443, false)]
  [InlineData("127.0.0.1", 443, false)]
  public void OnlyExactSdkHostsUsePhysicalLoopbackTransport(string host, int port, bool allowed) =>
      Assert.Equal(allowed, ResourceProbeBootstrapSettings.IsAuthenticationEndpoint(new DnsEndPoint(host, port)));

  [Fact]
  public void NeitherTestOutputNorOld150DirectoryIsAnApprovedProbeRuntime()
  {
    Assert.Throws<InvalidOperationException>(() => ResourceProbeBootstrapSettings.Load());
    Assert.Contains("151.8.5-ResourceProbe", ResourceProbeBootstrapSettings.ClientRoot);
    Assert.DoesNotContain("150.6.9", ResourceProbeBootstrapSettings.ClientRoot);
  }

  [Fact]
  public void EndEntityCannotBeUsedAsItsOwnIssuerEvenWithIdenticalSubjectName()
  {
    using var key = RSA.Create(2048);
    var request = new CertificateRequest("CN=synthetic-probe", key, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
    request.CertificateExtensions.Add(new X509BasicConstraintsExtension(false, false, 0, true));
    using var generated = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddMinutes(-1), DateTimeOffset.UtcNow.AddHours(1));
    using var publicOnly = X509CertificateLoader.LoadCertificate(generated.RawData);
    Assert.Throws<InvalidOperationException>(() => ResourceProbeBootstrapSettings.CreateChainPolicy(publicOnly));
  }

  [Fact]
  public void PublicIssuerValidatesIssuedLeafWithoutSystemTrustOrCertificateDownloads()
  {
    using var issuerKey = RSA.Create(2048);
    var issuerRequest = new CertificateRequest("CN=synthetic-probe-ca", issuerKey, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
    issuerRequest.CertificateExtensions.Add(new X509BasicConstraintsExtension(true, false, 0, true));
    issuerRequest.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.KeyCertSign, true));
    using var issuer = issuerRequest.CreateSelfSigned(DateTimeOffset.UtcNow.AddMinutes(-1), DateTimeOffset.UtcNow.AddHours(2));
    using var publicIssuer = X509CertificateLoader.LoadCertificate(issuer.RawData);
    using var leafKey = RSA.Create(2048);
    var leafRequest = new CertificateRequest("CN=synthetic-probe-leaf", leafKey, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
    leafRequest.CertificateExtensions.Add(new X509BasicConstraintsExtension(false, false, 0, true));
    using var leaf = leafRequest.Create(issuer, DateTimeOffset.UtcNow.AddMinutes(-1), DateTimeOffset.UtcNow.AddHours(1), [1, 2, 3]);
    using var chain = new X509Chain { ChainPolicy = ResourceProbeBootstrapSettings.CreateChainPolicy(publicIssuer) };
    Assert.True(chain.ChainPolicy.DisableCertificateDownloads);
    Assert.Equal(X509ChainTrustMode.CustomRootTrust, chain.ChainPolicy.TrustMode);
    Assert.True(chain.Build(leaf));
    Assert.Throws<InvalidOperationException>(() => ResourceProbeBootstrapSettings.CreateChainPolicy(issuer));
  }
}
