using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text.Json;
using NikkeLocalLab.Automation;

namespace ResourceCatalogPreflight;

internal static class LoopbackTransport
{
    public static async Task VerifyAsync(string receiptPath)
    {
        if (new FileInfo(receiptPath).Length is < 1 or > 1024 * 1024)
            throw new PreflightException("resource_transport_contract_invalid");
        using var document = JsonDocument.Parse(File.ReadAllBytes(receiptPath));
        var members = ReadPlan(document.RootElement);
        using var handler = new SocketsHttpHandler
        {
            UseProxy = false,
            AllowAutoRedirect = false,
            AutomaticDecompression = DecompressionMethods.None,
            ConnectCallback = async (context, token) =>
            {
                if (context.DnsEndPoint.Host != "cloud.nikke-kr.com" || context.DnsEndPoint.Port != 443)
                    throw new PreflightException("resource_transport_endpoint_invalid");
                var socket = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
                try
                {
                    await socket.ConnectAsync(new IPEndPoint(IPAddress.Loopback, 443), token);
                    return new NetworkStream(socket, ownsSocket: true);
                }
                catch { socket.Dispose(); throw; }
            }
        };
        using var client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(15) };
        await VerifyMembersAsync(members, client);
    }

    internal sealed record Member(Uri Address, long ByteLength, string Sha256);

    internal static Member[] ReadPlan(JsonElement root)
    {
        if (root.GetProperty("contractId").GetString() != "nll/resource-catalog-preflight/v1" ||
            root.GetProperty("statusCode").GetString() != "catalogs_verified")
            throw new PreflightException("resource_transport_contract_invalid");
        var selection = new ResourceSelection(root.GetProperty("voiceLanguage").GetString(),
            root.GetProperty("downloadScope").GetString() switch
            {
                "minimal" => VoiceDownloadScope.Minimal, "full" => VoiceDownloadScope.Full,
                _ => VoiceDownloadScope.Unresolved
            });
        var expectedRoles = selection.RequiredCatalogRoles().ToHashSet(StringComparer.Ordinal);
        var plan = new List<Member>();
        Add(root.GetProperty("headerUrl").GetString()!, root.GetProperty("headerByteLength").GetInt64(),
            root.GetProperty("headerSha256").GetString()!);
        var transports = root.GetProperty("transports").EnumerateArray().ToArray();
        foreach (var member in transports)
        {
            if (!expectedRoles.Remove(member.GetProperty("roleCode").GetString()!))
                throw new PreflightException("resource_transport_members_invalid");
            var transport = member.GetProperty("bodyTransportCode").GetString();
            var prefix = transport switch { "decrypted_sqlite" => "decrypted", "original_nkdb" => "encrypted",
                _ => throw new PreflightException("resource_transport_kind_unsupported") };
            var bodyUrl = member.GetProperty("bodyUrl").GetString()!;
            var signatureUrl = member.GetProperty("signatureUrl").GetString()!;
            if (signatureUrl != bodyUrl + ".nds")
                throw new PreflightException("resource_transport_pair_invalid");
            Add(bodyUrl,
                member.GetProperty(prefix + "ByteLength").GetInt64(), member.GetProperty(prefix + "Sha256").GetString()!);
            Add(signatureUrl, 96, member.GetProperty("signatureSha256").GetString()!);
        }
        if (expectedRoles.Count != 0 || plan.Select(member => member.Address).Distinct().Count() != plan.Count)
            throw new PreflightException("resource_transport_members_invalid");
        return plan.ToArray();

        void Add(string address, long expectedLength, string expectedHash)
        {
            var uri = new Uri(address);
            if (uri.Scheme != "https" || uri.Host != "cloud.nikke-kr.com" || uri.Port != 443 ||
                uri.UserInfo.Length != 0 || uri.Query.Length != 0 || uri.Fragment.Length != 0 ||
                !uri.AbsolutePath.StartsWith("/prdenv/", StringComparison.Ordinal) ||
                expectedLength is < 1 or > 512 * 1024 * 1024 ||
                !System.Text.RegularExpressions.Regex.IsMatch(expectedHash, "^[0-9a-f]{64}$"))
                throw new PreflightException("resource_transport_contract_invalid");
            plan.Add(new Member(uri, expectedLength, expectedHash));
        }
    }

    // Test seam uses in-memory responses, not a second production transport.
    internal static async Task VerifyMembersAsync(Member[] members, HttpClient client)
    {
        foreach (var member in members)
        {
            var expectedLength = member.ByteLength;
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(15));
            using var response = await client.GetAsync(member.Address, HttpCompletionOption.ResponseHeadersRead, timeout.Token);
            if (response.StatusCode != HttpStatusCode.OK)
                throw new PreflightException("resource_loopback_status_invalid");
            if (response.Content.Headers.ContentLength is long contentLength && contentLength != expectedLength)
                throw new PreflightException("resource_loopback_length_mismatch");
            await using var stream = await response.Content.ReadAsStreamAsync(timeout.Token);
            using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            var buffer = new byte[128 * 1024];
            long length = 0;
            int read;
            while ((read = await stream.ReadAsync(buffer, timeout.Token)) != 0)
            {
                length += read;
                if (length > expectedLength) throw new PreflightException("resource_loopback_length_mismatch");
                hash.AppendData(buffer, 0, read);
            }
            if (length != expectedLength || Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant() != member.Sha256)
                throw new PreflightException("resource_loopback_digest_mismatch");
        }
    }
}
