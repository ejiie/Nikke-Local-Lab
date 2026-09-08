using System.Collections;
using System.Formats.Nrbf;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

const string ContractId =
    "nll/phase3b2-local-content-version-cache-scan/v1";
const long MaximumCandidateLength = 1024 * 1024;
string[] orderedEntryNames = ["core", "dp", "en", "ja", "ko", "fd", "saus"];

if (args.Length != 3)
{
    Console.Error.WriteLine(
        "usage: ContentVersionCacheScanner <lcv-path> <scan-root> <output-root>");
    return 2;
}

string sourcePath = Path.GetFullPath(args[0]);
string scanRoot = Path.GetFullPath(args[1]);
string outputRoot = Path.GetFullPath(args[2]);
if (!File.Exists(sourcePath) || !Directory.Exists(scanRoot))
{
    Console.Error.WriteLine("phase3b2_content_version_cache_scan_input_missing");
    return 3;
}

try
{
    Dictionary<string, (string Tag, string Revision)> entries =
        ReadContentVersion(sourcePath, orderedEntryNames);
    List<byte[]> requiredTokens = [];
    foreach (string name in orderedEntryNames)
    {
        (string tag, string revision) = entries[name];
        requiredTokens.Add(Encoding.UTF8.GetBytes(name + ":"));
        requiredTokens.Add(Encoding.UTF8.GetBytes(tag));
        requiredTokens.Add(Encoding.UTF8.GetBytes(revision));
    }

    Directory.CreateDirectory(outputRoot);
    long scannedFileCount = 0;
    long scannedContentByteLength = 0;
    int inaccessibleDirectoryCount = 0;
    int unreadableFileCount = 0;
    Dictionary<string, Candidate> candidates = new(StringComparer.Ordinal);
    Queue<string> directories = new();
    directories.Enqueue(scanRoot);
    while (directories.Count > 0)
    {
        string directory = directories.Dequeue();
        try
        {
            foreach (string child in Directory.EnumerateDirectories(directory))
            {
                directories.Enqueue(child);
            }
        }
        catch (UnauthorizedAccessException)
        {
            inaccessibleDirectoryCount++;
        }
        catch (IOException)
        {
            inaccessibleDirectoryCount++;
        }

        IEnumerable<string> files;
        try
        {
            files = Directory.EnumerateFiles(directory).ToArray();
        }
        catch (UnauthorizedAccessException)
        {
            inaccessibleDirectoryCount++;
            continue;
        }
        catch (IOException)
        {
            inaccessibleDirectoryCount++;
            continue;
        }

        foreach (string path in files)
        {
            try
            {
                FileInfo info = new(path);
                if (info.Length <= 0 || info.Length > MaximumCandidateLength)
                {
                    continue;
                }

                byte[] bytes = ReadSharedBytes(path);
                try
                {
                    scannedFileCount++;
                    scannedContentByteLength += bytes.LongLength;
                    if (!requiredTokens.All(token =>
                            bytes.AsSpan().IndexOf(token) >= 0))
                    {
                        continue;
                    }

                    string sha256 = Convert.ToHexStringLower(
                        SHA256.HashData(bytes));
                    if (!candidates.ContainsKey(sha256))
                    {
                        string outputPath = Path.Combine(
                            outputRoot, $"candidate-{sha256}.bin");
                        if (File.Exists(outputPath))
                        {
                            byte[] existing = File.ReadAllBytes(outputPath);
                            try
                            {
                                if (!existing.AsSpan().SequenceEqual(bytes))
                                {
                                    throw new InvalidDataException(
                                        "phase3b2_content_version_cache_scan_output_collision");
                                }
                            }
                            finally
                            {
                                CryptographicOperations.ZeroMemory(existing);
                            }
                        }
                        else
                        {
                            File.WriteAllBytes(outputPath, bytes);
                        }
                        candidates.Add(sha256,
                            new Candidate(bytes.LongLength, sha256));
                    }
                }
                finally
                {
                    CryptographicOperations.ZeroMemory(bytes);
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
    }

    byte[] sourceBytes = File.ReadAllBytes(sourcePath);
    object receipt = new
    {
        schemaVersion = 1,
        contractId = ContractId,
        scannedAtUtc = DateTimeOffset.UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"),
        sourceRoleCode = "installed_client_serialized_content_version",
        sourceByteLength = sourceBytes.LongLength,
        sourceSha256 = Convert.ToHexStringLower(SHA256.HashData(sourceBytes)),
        decoderCode =
            "system_formats_nrbf_record_scan_no_type_deserialization",
        scanRootRoleSha256 = Sha256Utf8(scanRoot.ToLowerInvariant()),
        maximumCandidateByteLength = MaximumCandidateLength,
        scannedFileCount,
        scannedContentByteLength,
        inaccessibleDirectoryCount,
        unreadableFileCount,
        requiredTupleCount = entries.Count,
        candidateCount = candidates.Count,
        candidates = candidates.Values.OrderBy(candidate => candidate.Sha256),
        rawCandidateContentEmitted = false,
        rawCandidateContentCopiedToExternalOutput = candidates.Count > 0,
        sourceCacheModified = false,
        officialOutboundUsed = false,
        officialIdentityPersisted = false,
        officialCredentialPersisted = false,
        serverExecutionStarted = false,
        clientExecutionStarted = false
    };
    Console.WriteLine(JsonSerializer.Serialize(receipt,
        new JsonSerializerOptions { WriteIndented = true }));
    CryptographicOperations.ZeroMemory(sourceBytes);
    foreach (byte[] token in requiredTokens)
    {
        CryptographicOperations.ZeroMemory(token);
    }
    return 0;
}
catch (Exception exception) when (exception is InvalidDataException or
    IOException or UnauthorizedAccessException)
{
    Console.Error.WriteLine(exception.Message.StartsWith("phase3b2_",
        StringComparison.Ordinal)
        ? exception.Message
        : "phase3b2_content_version_cache_scan_failed");
    return 4;
}

static Dictionary<string, (string Tag, string Revision)> ReadContentVersion(
    string sourcePath,
    IReadOnlyCollection<string> orderedEntryNames)
{
    using FileStream stream = File.OpenRead(sourcePath);
    SerializationRecord decoded = NrbfDecoder.Decode(stream);
    if (decoded is not ClassRecord root ||
        !root.TypeName.FullName.EndsWith(
            "NK.GameInitialize.ContentVersion2", StringComparison.Ordinal))
    {
        throw new InvalidDataException(
            "phase3b2_content_version_cache_scan_root_invalid");
    }

    ClassRecord dataPack = root.GetClassRecord("_DataPack")
        ?? throw new InvalidDataException(
            "phase3b2_content_version_cache_scan_datapack_missing");
    ClassRecord subEntries = dataPack.GetClassRecord(
        "<SubEntries>k__BackingField")
        ?? throw new InvalidDataException(
            "phase3b2_content_version_cache_scan_subentries_missing");
    Dictionary<string, (string Tag, string Revision)> entries =
        ReadSubEntries(subEntries);
    if (entries.Count != orderedEntryNames.Count ||
        orderedEntryNames.Any(name => !entries.ContainsKey(name)) ||
        entries.Keys.Any(name => !orderedEntryNames.Contains(name)))
    {
        throw new InvalidDataException(
            "phase3b2_content_version_cache_scan_entry_shape_invalid");
    }
    foreach ((string name, (string tag, string revision)) in entries)
    {
        if (!Regex.IsMatch(name, "^[a-z]+$", RegexOptions.CultureInvariant) ||
            !Regex.IsMatch(tag, "^[A-Za-z0-9.]+$",
                RegexOptions.CultureInvariant) ||
            !Regex.IsMatch(revision, "^[0-9]+$", RegexOptions.CultureInvariant))
        {
            throw new InvalidDataException(
                "phase3b2_content_version_cache_scan_entry_value_invalid");
        }
    }
    return entries;
}

static Dictionary<string, (string Tag, string Revision)> ReadSubEntries(
    ClassRecord dictionaryRecord)
{
    object arrayRecord = dictionaryRecord.GetRawValue("KeyValuePairs")
        ?? throw new InvalidDataException(
            "phase3b2_content_version_cache_scan_pairs_missing");
    FieldInfo recordsField = arrayRecord.GetType().GetField(
        "<Records>k__BackingField",
        BindingFlags.Instance | BindingFlags.NonPublic)
        ?? throw new InvalidDataException(
            "phase3b2_content_version_cache_scan_records_unavailable");
    if (recordsField.GetValue(arrayRecord) is not IEnumerable serializedPairs)
    {
        throw new InvalidDataException(
            "phase3b2_content_version_cache_scan_records_invalid");
    }

    Dictionary<string, (string Tag, string Revision)> result =
        new(StringComparer.Ordinal);
    foreach (object? item in serializedPairs)
    {
        if (item is not ClassRecord pair ||
            pair.GetRawValue("key") is not string key ||
            pair.GetRawValue("value") is not ClassRecord tuple ||
            tuple.GetRawValue("Item1") is not string tag ||
            tuple.GetRawValue("Item2") is not string revision ||
            !result.TryAdd(key, (tag, revision)))
        {
            throw new InvalidDataException(
                "phase3b2_content_version_cache_scan_pair_invalid");
        }
    }
    return result;
}

static byte[] ReadSharedBytes(string path)
{
    using FileStream stream = new(
        path,
        FileMode.Open,
        FileAccess.Read,
        FileShare.ReadWrite | FileShare.Delete);
    byte[] bytes = new byte[stream.Length];
    int offset = 0;
    while (offset < bytes.Length)
    {
        int read = stream.Read(bytes, offset, bytes.Length - offset);
        if (read <= 0)
        {
            throw new IOException("phase3b2_content_version_cache_scan_short_read");
        }
        offset += read;
    }
    return bytes;
}

static string Sha256Utf8(string text) => Convert.ToHexStringLower(
    SHA256.HashData(Encoding.UTF8.GetBytes(text)));

internal sealed record Candidate(long ByteLength, string Sha256);
