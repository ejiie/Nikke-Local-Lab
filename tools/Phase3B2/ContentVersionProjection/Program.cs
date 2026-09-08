using System.Collections;
using System.Formats.Nrbf;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

const string ContractId = "nll/phase3b2-local-content-version-projection/v3";
string[] orderedEntryNames = ["core", "dp", "en", "ja", "ko", "fd", "saus"];

if (args.Length != 3)
{
    Console.Error.WriteLine(
        "usage: ContentVersionProjection <lcv-path> <gameconfig-path> <cache-root>");
    return 2;
}

string sourcePath = Path.GetFullPath(args[0]);
string gameConfigPath = Path.GetFullPath(args[1]);
string cacheRoot = Path.GetFullPath(args[2]);

if (!File.Exists(sourcePath) || !File.Exists(gameConfigPath))
{
    Console.Error.WriteLine("phase3b2_content_version_projection_input_missing");
    return 3;
}

try
{
    using FileStream sourceStream = File.OpenRead(sourcePath);
    SerializationRecord decoded = NrbfDecoder.Decode(sourceStream);
    if (decoded is not ClassRecord root ||
        !root.TypeName.FullName.EndsWith(
            "NK.GameInitialize.ContentVersion2", StringComparison.Ordinal))
    {
        throw new InvalidDataException(
            "phase3b2_content_version_projection_root_invalid");
    }

    ClassRecord dataPack = root.GetClassRecord("_DataPack")
        ?? throw new InvalidDataException(
            "phase3b2_content_version_projection_datapack_missing");
    string baseUrl = RequireString(dataPack, "<BaseUrl>k__BackingField");
    string latestPostFix = RequireString(
        dataPack, "<LatestPostFix>k__BackingField");
    string rootVersion = RequireString(dataPack, "<Version>k__BackingField");
    string rootRevision = RequireString(dataPack, "<Revision>k__BackingField");

    using JsonDocument gameConfig = JsonDocument.Parse(
        File.ReadAllBytes(gameConfigPath));
    string configuredBaseUrl = gameConfig.RootElement
        .GetProperty("ResourceBaseURL").GetString()
        ?? throw new InvalidDataException(
            "phase3b2_content_version_projection_config_base_missing");
    string configuredPostFix = gameConfig.RootElement
        .GetProperty("ResourceDataPackVersion").GetString()
        ?? throw new InvalidDataException(
            "phase3b2_content_version_projection_config_postfix_missing");
    configuredBaseUrl = configuredBaseUrl.Replace(
        "{Platform}", "StandaloneWindows64", StringComparison.OrdinalIgnoreCase)
        .TrimEnd('/') + "/pck/";

    if (!Uri.TryCreate(baseUrl, UriKind.Absolute, out Uri? baseUri) ||
        baseUri.Scheme != Uri.UriSchemeHttps ||
        !string.Equals(baseUri.Host, "cloud.nikke-kr.com",
            StringComparison.OrdinalIgnoreCase) ||
        !Regex.IsMatch(baseUri.AbsolutePath,
            "^/prdenv/[a-z0-9-]+/StandaloneWindows64/pck/$",
            RegexOptions.CultureInvariant) ||
        !string.Equals(baseUrl, configuredBaseUrl, StringComparison.Ordinal) ||
        !string.Equals(latestPostFix, configuredPostFix,
            StringComparison.Ordinal) ||
        !Regex.IsMatch(latestPostFix, "^[0-9]+$", RegexOptions.CultureInvariant))
    {
        throw new InvalidDataException(
            "phase3b2_content_version_projection_contract_mismatch");
    }

    ClassRecord subEntries = dataPack.GetClassRecord(
        "<SubEntries>k__BackingField")
        ?? throw new InvalidDataException(
            "phase3b2_content_version_projection_subentries_missing");
    Dictionary<string, (string Tag, string Revision)> entries =
        ReadSubEntries(subEntries);
    if (entries.Count != orderedEntryNames.Length ||
        orderedEntryNames.Any(name => !entries.ContainsKey(name)) ||
        entries.Keys.Any(name => !orderedEntryNames.Contains(
            name, StringComparer.Ordinal)))
    {
        throw new InvalidDataException(
            "phase3b2_content_version_projection_entry_shape_invalid");
    }

    foreach ((string name, (string tag, string revision)) in entries)
    {
        if (!Regex.IsMatch(name, "^[a-z]+$", RegexOptions.CultureInvariant) ||
            !Regex.IsMatch(tag, "^[A-Za-z0-9.]+$",
                RegexOptions.CultureInvariant) ||
            !Regex.IsMatch(revision, "^[0-9]+$", RegexOptions.CultureInvariant))
        {
            throw new InvalidDataException(
                "phase3b2_content_version_projection_entry_value_invalid");
        }
    }

    (string Tag, string Revision) dp = entries["dp"];
    if (!Regex.IsMatch(rootVersion, "^[A-Za-z0-9.]+$",
            RegexOptions.CultureInvariant) ||
        !Regex.IsMatch(rootRevision, "^[0-9]+$",
            RegexOptions.CultureInvariant) ||
        !string.Equals(dp.Revision, rootRevision, StringComparison.Ordinal))
    {
        throw new InvalidDataException(
            "phase3b2_content_version_projection_root_revision_mismatch");
    }

    // The native 150.6.9 parser consumes the first LF-delimited value as
    // DataPackEntry.Version and only parses the remaining values into
    // SubEntries.  Omitting this header silently drops the first named entry
    // ("core") and later Host.GetVersion() fails when it indexes that key.
    string text = string.Join('\n', new[] { rootVersion }.Concat(
        orderedEntryNames.Select(name =>
        {
            (string tag, string revision) = entries[name];
            return $"{name}:{tag},{revision}";
        })));
    byte[] projectedBytes = new UTF8Encoding(false, true).GetBytes(text);

    string relativePath = baseUri.AbsolutePath.TrimStart('/') +
        $"latest-{latestPostFix}.txt";
    string targetPath = Path.GetFullPath(Path.Combine(
        cacheRoot, relativePath.Replace('/', Path.DirectorySeparatorChar)));
    string canonicalCacheRoot = cacheRoot.TrimEnd(Path.DirectorySeparatorChar) +
        Path.DirectorySeparatorChar;
    if (!targetPath.StartsWith(canonicalCacheRoot,
        StringComparison.OrdinalIgnoreCase))
    {
        throw new InvalidDataException(
            "phase3b2_content_version_projection_target_outside_cache");
    }

    Directory.CreateDirectory(Path.GetDirectoryName(targetPath)!);
    bool targetAlreadyMatched = File.Exists(targetPath);
    if (targetAlreadyMatched)
    {
        byte[] existing = File.ReadAllBytes(targetPath);
        if (!existing.AsSpan().SequenceEqual(projectedBytes))
        {
            throw new InvalidDataException(
                "phase3b2_content_version_projection_target_collision");
        }
    }
    else
    {
        string temporaryPath = targetPath + ".tmp." + Guid.NewGuid().ToString("N");
        try
        {
            File.WriteAllBytes(temporaryPath, projectedBytes);
            File.Move(temporaryPath, targetPath);
        }
        finally
        {
            if (File.Exists(temporaryPath))
            {
                File.Delete(temporaryPath);
            }
        }
    }

    byte[] sourceBytes = File.ReadAllBytes(sourcePath);
    object receipt = new
    {
        schemaVersion = 1,
        contractId = ContractId,
        projectedAtUtc = DateTimeOffset.UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"),
        sourceRoleCode = "installed_client_serialized_content_version",
        sourceByteLength = sourceBytes.LongLength,
        sourceSha256 = Convert.ToHexStringLower(SHA256.HashData(sourceBytes)),
        decoderCode = "system_formats_nrbf_record_projection_no_type_deserialization",
        standaloneVersionHeader = rootVersion,
        standaloneVersionMatchesLatestPostfix = string.Equals(
            rootVersion, latestPostFix, StringComparison.Ordinal),
        projectedLineCount = entries.Count + 1,
        entryCount = entries.Count,
        entryNameSetSha256 = Sha256Utf8(
            string.Join('\n', orderedEntryNames) + "\n"),
        aggregateVersionRelationCode = string.Equals(
            rootVersion, dp.Tag, StringComparison.Ordinal)
            ? "same_as_dp_tag"
            : "separate_from_dp_tag",
        aggregateRevisionMatchesDp = true,
        projectionCanonicalization =
            "standalone_version_lf_then_entry_name_colon_tag_comma_revision_lf_between_no_terminal_newline_v1",
        cacheRelativePathSha256 = Sha256Utf8(relativePath),
        projectedByteLength = projectedBytes.LongLength,
        projectedSha256 = Convert.ToHexStringLower(
            SHA256.HashData(projectedBytes)),
        targetAlreadyMatched,
        officialOutboundUsed = false,
        officialIdentityPersisted = false,
        officialCredentialPersisted = false,
        serverExecutionStarted = false,
        clientExecutionStarted = false
    };
    Console.WriteLine(JsonSerializer.Serialize(receipt,
        new JsonSerializerOptions { WriteIndented = true }));
    CryptographicOperations.ZeroMemory(sourceBytes);
    CryptographicOperations.ZeroMemory(projectedBytes);
    return 0;
}
catch (Exception exception) when (exception is InvalidDataException or
    IOException or UnauthorizedAccessException or JsonException)
{
    Console.Error.WriteLine(exception.Message.StartsWith("phase3b2_",
        StringComparison.Ordinal)
        ? exception.Message
        : "phase3b2_content_version_projection_failed");
    return 4;
}

static string RequireString(ClassRecord record, string memberName)
{
    string? value = record.GetRawValue(memberName) as string;
    return !string.IsNullOrWhiteSpace(value)
        ? value
        : throw new InvalidDataException(
            "phase3b2_content_version_projection_string_missing");
}

static Dictionary<string, (string Tag, string Revision)> ReadSubEntries(
    ClassRecord dictionaryRecord)
{
    object arrayRecord = dictionaryRecord.GetRawValue("KeyValuePairs")
        ?? throw new InvalidDataException(
            "phase3b2_content_version_projection_key_value_pairs_missing");
    FieldInfo recordsField = arrayRecord.GetType().GetField(
        "<Records>k__BackingField",
        BindingFlags.Instance | BindingFlags.NonPublic)
        ?? throw new InvalidDataException(
            "phase3b2_content_version_projection_records_unavailable");
    if (recordsField.GetValue(arrayRecord) is not IEnumerable serializedPairs)
    {
        throw new InvalidDataException(
            "phase3b2_content_version_projection_records_invalid");
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
                "phase3b2_content_version_projection_pair_invalid");
        }
    }
    return result;
}

static string Sha256Utf8(string text) => Convert.ToHexStringLower(
    SHA256.HashData(Encoding.UTF8.GetBytes(text)));
