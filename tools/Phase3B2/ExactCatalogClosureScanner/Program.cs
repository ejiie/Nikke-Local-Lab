using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

const string contractId = "nll/phase3b2-exact-catalog-closure-scan/v1";
const int signatureLength = 96;
const int signaturePrefixLength = 32;
ReadOnlySpan<byte> nkdbMagic = "NKDB"u8;

if (args.Length < 2)
{
    Console.Error.WriteLine(
        "usage: ExactCatalogClosureScanner <scan-root> <trusted-nds-sample> [--emit-relative-paths] [--output <json-path>]");
    return 2;
}

string scanRoot = Path.GetFullPath(args[0]);
string trustedSignaturePath = Path.GetFullPath(args[1]);
bool emitRelativePaths = false;
string? outputPath = null;
for (int index = 2; index < args.Length; index++)
{
    if (string.Equals(args[index], "--emit-relative-paths",
            StringComparison.Ordinal))
    {
        emitRelativePaths = true;
        continue;
    }

    if (string.Equals(args[index], "--output", StringComparison.Ordinal) &&
        index + 1 < args.Length && outputPath is null)
    {
        outputPath = Path.GetFullPath(args[++index]);
        continue;
    }

    Console.Error.WriteLine("phase3b2_exact_catalog_scan_argument_invalid");
    return 2;
}
if (!Directory.Exists(scanRoot) || !File.Exists(trustedSignaturePath))
{
    Console.Error.WriteLine("phase3b2_exact_catalog_scan_input_missing");
    return 3;
}

try
{
    byte[] trustedSignature = ReadSharedBytes(trustedSignaturePath,
        signatureLength, requireExactLength: true);
    byte[] trustedPrefix = trustedSignature[..signaturePrefixLength];
    string trustedSignatureSha256 = Sha256Hex(trustedSignature);
    CryptographicOperations.ZeroMemory(trustedSignature);

    long enumeratedFileCount = 0;
    long headerReadByteLength = 0;
    int inaccessibleDirectoryCount = 0;
    int unreadableFileCount = 0;
    List<CatalogBodyCandidate> bodies = [];
    List<SignatureCandidate> signatures = [];
    EnumerationOptions enumerationOptions = new()
    {
        RecurseSubdirectories = true,
        IgnoreInaccessible = true,
        AttributesToSkip = FileAttributes.ReparsePoint,
        ReturnSpecialDirectories = false
    };
    IEnumerable<string> files = Directory.EnumerateFiles(
        scanRoot, "*", enumerationOptions);
    foreach (string path in files)
    {
        enumeratedFileCount++;
        try
        {
            FileInfo info = new(path);
            int requiredLength = info.Length == signatureLength
                ? signatureLength
                : nkdbMagic.Length;
            if (info.Length < requiredLength)
            {
                continue;
            }

            byte[] header = ReadSharedBytes(path, requiredLength,
                requireExactLength: false);
            headerReadByteLength += header.LongLength;
            try
            {
                if (header.AsSpan(0, nkdbMagic.Length).SequenceEqual(
                        nkdbMagic))
                {
                    string? siblingSignaturePath = path + ".nds";
                    bool pairedSignaturePresent =
                        File.Exists(siblingSignaturePath) &&
                        new FileInfo(siblingSignaturePath).Length ==
                            signatureLength;
                    bodies.Add(new CatalogBodyCandidate(
                        GetPathValue(scanRoot, path, emitRelativePaths),
                        Path.GetFileName(path),
                        info.Length,
                        Sha256File(path),
                        pairedSignaturePresent,
                        pairedSignaturePresent
                            ? Sha256File(siblingSignaturePath)
                            : null));
                }

                if (info.Length == signatureLength &&
                    header.AsSpan(0, signaturePrefixLength).SequenceEqual(
                        trustedPrefix))
                {
                    signatures.Add(new SignatureCandidate(
                        GetPathValue(scanRoot, path, emitRelativePaths),
                        Path.GetFileName(path),
                        info.Length,
                        Sha256Hex(header)));
                }
            }
            finally
            {
                CryptographicOperations.ZeroMemory(header);
            }
        }
        catch (UnauthorizedAccessException)
        {
            unreadableFileCount++;
        }
        catch (IOException)
        {
            unreadableFileCount++;
        }
    }

    byte[] rootRoleBytes = Encoding.UTF8.GetBytes(
        scanRoot.TrimEnd(Path.DirectorySeparatorChar).ToLowerInvariant());
    object receipt = new
    {
        schemaVersion = 1,
        contractId,
        scannedAtUtc = DateTimeOffset.UtcNow.ToString(
            "yyyy-MM-dd'T'HH:mm:ss'Z'"),
        scanRootRoleSha256 = Sha256Hex(rootRoleBytes),
        trustedSignatureRoleCode = "installed_client_catalog_nds_sample",
        trustedSignatureByteLength = signatureLength,
        trustedSignatureSha256,
        signaturePrefixByteLength = signaturePrefixLength,
        enumeratedFileCount,
        headerReadByteLength,
        inaccessibleDirectoryCount,
        unreadableFileCount,
        nkdbBodyCandidateCount = bodies.Count,
        matchingNdsSignatureCandidateCount = signatures.Count,
        pairedNkdbBodyCandidateCount = bodies.Count(body =>
            body.PairedSignaturePresent),
        candidates = bodies.OrderBy(body => body.PathValue,
            StringComparer.Ordinal),
        signatures = signatures.OrderBy(signature => signature.PathValue,
            StringComparer.Ordinal),
        relativePathsEmitted = emitRelativePaths,
        rawContentEmitted = false,
        sourceMutationPerformed = false,
        officialOutboundUsed = false,
        serverExecutionStarted = false,
        clientExecutionStarted = false
    };
    string json = JsonSerializer.Serialize(receipt,
        new JsonSerializerOptions { WriteIndented = true }) + "\n";
    if (outputPath is not null)
    {
        string? outputDirectory = Path.GetDirectoryName(outputPath);
        if (string.IsNullOrWhiteSpace(outputDirectory) ||
            !Directory.Exists(outputDirectory) || File.Exists(outputPath))
        {
            throw new InvalidDataException(
                "phase3b2_exact_catalog_scan_output_invalid");
        }

        string temporaryPath = outputPath + ".tmp." +
            Guid.NewGuid().ToString("N");
        try
        {
            File.WriteAllText(temporaryPath, json,
                new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
            File.Move(temporaryPath, outputPath);
        }
        finally
        {
            if (File.Exists(temporaryPath))
            {
                File.Delete(temporaryPath);
            }
        }
    }

    Console.Write(json);
    CryptographicOperations.ZeroMemory(trustedPrefix);
    CryptographicOperations.ZeroMemory(rootRoleBytes);
    return 0;
}
catch (Exception exception) when (exception is InvalidDataException or
    IOException or UnauthorizedAccessException)
{
    Console.Error.WriteLine(exception.Message.StartsWith("phase3b2_",
        StringComparison.Ordinal)
        ? exception.Message
        : "phase3b2_exact_catalog_scan_failed");
    return 4;
}

static byte[] ReadSharedBytes(string path, int requestedLength,
    bool requireExactLength)
{
    using FileStream stream = new(
        path,
        FileMode.Open,
        FileAccess.Read,
        FileShare.ReadWrite | FileShare.Delete,
        4096,
        FileOptions.SequentialScan);
    if (requireExactLength && stream.Length != requestedLength)
    {
        throw new InvalidDataException(
            "phase3b2_exact_catalog_scan_signature_length_invalid");
    }

    int length = checked((int)Math.Min(stream.Length, requestedLength));
    byte[] bytes = new byte[length];
    stream.ReadExactly(bytes);
    return bytes;
}

static string Sha256File(string path)
{
    using FileStream stream = new(
        path,
        FileMode.Open,
        FileAccess.Read,
        FileShare.ReadWrite | FileShare.Delete,
        65536,
        FileOptions.SequentialScan);
    return Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
}

static string Sha256Hex(ReadOnlySpan<byte> bytes) =>
    Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();

static string GetPathValue(string root, string path, bool emitRelativePaths)
{
    string relativePath = Path.GetRelativePath(root, path)
        .Replace(Path.DirectorySeparatorChar, '/');
    if (emitRelativePaths)
    {
        return relativePath;
    }

    byte[] bytes = Encoding.UTF8.GetBytes(relativePath.ToLowerInvariant());
    try
    {
        return "sha256:" + Sha256Hex(bytes);
    }
    finally
    {
        CryptographicOperations.ZeroMemory(bytes);
    }
}

internal sealed record CatalogBodyCandidate(
    string PathValue,
    string FileName,
    long ByteLength,
    string Sha256,
    bool PairedSignaturePresent,
    string? PairedSignatureSha256);

internal sealed record SignatureCandidate(
    string PathValue,
    string FileName,
    long ByteLength,
    string Sha256);
