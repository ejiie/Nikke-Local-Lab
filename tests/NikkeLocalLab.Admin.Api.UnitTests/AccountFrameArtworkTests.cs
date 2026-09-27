using System.Security.Cryptography;
using System.Text;

namespace NikkeLocalLab.Admin.Api.UnitTests;

public sealed class AccountFrameArtworkTests
{
  [Fact]
  public void FrameProjectionAuthenticatesAccountAndContentBeforeReading()
  {
    var account = Guid.NewGuid();
    var executableHash = SHA256.HashData("synthetic-client"u8);
    var key = RandomNumberGenerator.GetBytes(32);
    var clear = "{\"ProfileFrame\":12345,\"UnrelatedPrivateField\":\"synthetic\"}"u8.ToArray();
    var encrypted = new byte[clear.Length + 36];
    "NLLSRP01"u8.CopyTo(encrypted);
    RandomNumberGenerator.Fill(encrypted.AsSpan(8, 12));
    var aad = Encoding.UTF8.GetBytes($"nll/runtime-preferences-protected/v1\n{account:D}\nsynthetic-build\n{Convert.ToHexString(executableHash).ToLowerInvariant()}\n");
    using var aes = new AesGcm(key, 16);
    aes.Encrypt(encrypted.AsSpan(8, 12), clear, encrypted.AsSpan(36), encrypted.AsSpan(20, 16), aad);
    var protectedHash = SHA256.HashData(encrypted);
    var contentHash = SHA256.HashData(clear);
    Assert.Equal(12345, AccountFrameArtwork.ReadFrame(encrypted, protectedHash, contentHash, key, account, "synthetic-build", executableHash));
    Assert.ThrowsAny<CryptographicException>(() => AccountFrameArtwork.ReadFrame(encrypted, protectedHash, contentHash, key, Guid.NewGuid(), "synthetic-build", executableHash));
    Assert.Throws<InvalidDataException>(() => AccountFrameArtwork.ReadFrame(encrypted, protectedHash, new byte[32], key, account, "synthetic-build", executableHash));
    encrypted[^1] ^= 1;
    Assert.Throws<InvalidDataException>(() => AccountFrameArtwork.ReadFrame(encrypted, protectedHash, contentHash, key, account, "synthetic-build", executableHash));
  }
}
