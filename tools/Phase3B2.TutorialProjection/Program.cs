using System.Globalization;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using EpinelPS.Data;

const string ProjectionContract =
    "nll/phase3b2-epinel-exact-build-tutorial-private-projection/v1";
const string SummaryContract =
    "nll/phase3b2-epinel-exact-build-tutorial-projection-summary/v1";

if (args.Length < 1)
    throw new InvalidOperationException("command is required");

switch (args[0])
{
    case "project":
        await ProjectAsync(args[1..]);
        break;
    case "apply":
        await ApplyAsync(args[1..]);
        break;
    default:
        throw new InvalidOperationException("supported commands: project, apply");
}

static async Task ProjectAsync(string[] commandArgs)
{
    if (commandArgs.Length != 2)
        throw new InvalidOperationException(
            "project requires: <StaticData.pack> <private-projection.json>");

    var packPath = Path.GetFullPath(commandArgs[0]);
    var projectionPath = Path.GetFullPath(commandArgs[1]);
    if (!File.Exists(packPath) || File.Exists(projectionPath))
        throw new InvalidDataException("projection input or destination invalid");

    var originalOut = Console.Out;
    GameData gameData;
    try
    {
        Console.SetOut(TextWriter.Null);
        gameData = new GameData(packPath);
        var instanceField = typeof(GameData).GetField(
            "_instance", BindingFlags.Static | BindingFlags.NonPublic) ??
            throw new MissingFieldException(typeof(GameData).FullName, "_instance");
        instanceField.SetValue(null, gameData);
        await gameData.Parse();
    }
    finally
    {
        Console.SetOut(originalOut);
    }

    var rows = gameData.TutorialTable.Values
        .OrderBy(row => row.GroupId)
        .ThenBy(row => row.Id)
        .ToArray();
    if (rows.Length == 0)
        throw new InvalidDataException("tutorial table is empty");

    var groups = rows
        .GroupBy(row => row.GroupId)
        .Select(group =>
        {
            var terminal = group.OrderByDescending(row => row.Id).First();
            return new TutorialProjectionGroup(
                terminal.GroupId, terminal.Id, terminal.VersionGroup,
                group.Count());
        })
        .OrderBy(group => group.GroupId)
        .ToArray();
    if (groups.Length == 0 || groups.Select(group => group.GroupId).Distinct().Count() !=
        groups.Length)
    {
        throw new InvalidDataException("tutorial group projection invalid");
    }

    var groupCanonical = string.Concat(groups.Select(group =>
        string.Create(CultureInfo.InvariantCulture,
            $"{group.GroupId}\t{group.TerminalTutorialId}\t" +
            $"{group.VersionGroup}\t{group.MemberCount}\n")));
    var projection = new TutorialProjection(
        1,
        ProjectionContract,
        await Sha256FileAsync(packPath),
        new FileInfo(packPath).Length,
        rows.Length,
        groups.Length,
        Sha256Text(groupCanonical),
        groups);
    await WriteExclusiveJsonAsync(projectionPath, projection);

    var summary = new
    {
        schemaVersion = 1,
        contractId = SummaryContract,
        staticDataPackByteLength = projection.StaticDataPackByteLength,
        staticDataPackSha256 = projection.StaticDataPackSha256,
        tutorialRecordCount = projection.TutorialRecordCount,
        tutorialGroupCount = projection.TutorialGroupCount,
        tutorialGroupCanonicalSha256 = projection.TutorialGroupCanonicalSha256,
        privateProjectionByteLength = new FileInfo(projectionPath).Length,
        privateProjectionSha256 = await Sha256FileAsync(projectionPath),
        rawTutorialIdentifiersEmittedToStdout = false
    };
    Console.WriteLine(JsonSerializer.Serialize(summary, JsonOptions()));
}

static async Task ApplyAsync(string[] commandArgs)
{
    if (commandArgs.Length != 3)
        throw new InvalidOperationException(
            "apply requires: <private-projection.json> <input-db.json> " +
            "<output-db.json>");

    var projectionPath = Path.GetFullPath(commandArgs[0]);
    var inputPath = Path.GetFullPath(commandArgs[1]);
    var outputPath = Path.GetFullPath(commandArgs[2]);
    if (!File.Exists(projectionPath) || !File.Exists(inputPath) ||
        File.Exists(outputPath))
    {
        throw new InvalidDataException("apply input or destination invalid");
    }

    var projection = JsonSerializer.Deserialize<TutorialProjection>(
        await File.ReadAllTextAsync(projectionPath), JsonOptions()) ??
        throw new InvalidDataException("tutorial projection JSON invalid");
    if (projection.SchemaVersion != 1 ||
        !string.Equals(projection.ContractId, ProjectionContract,
            StringComparison.Ordinal) ||
        projection.TutorialGroupCount != projection.Groups.Length ||
        projection.Groups.Select(group => group.GroupId).Distinct().Count() !=
            projection.Groups.Length)
    {
        throw new InvalidDataException("tutorial projection contract invalid");
    }

    var input = JsonNode.Parse(await File.ReadAllTextAsync(inputPath)) as JsonObject ??
        throw new InvalidDataException("database JSON root invalid");
    var users = input["Users"] as JsonArray ??
        throw new InvalidDataException("database users missing");
    if (users.Count != 1 || users[0] is not JsonObject user)
        throw new InvalidDataException("database user shape invalid");
    var existing = user["ClearedTutorialDataNew"] as JsonObject ??
        throw new InvalidDataException("tutorial state property invalid");
    if (existing.Count != 0)
        throw new InvalidDataException("tutorial state is not empty baseline");

    var beforeInvariant = NonTutorialCanonicalSha256(input);
    var materialized = new JsonObject();
    foreach (var group in projection.Groups.OrderBy(group => group.GroupId))
    {
        materialized.Add(group.GroupId.ToString(CultureInfo.InvariantCulture),
            new JsonObject
            {
                ["Id"] = group.TerminalTutorialId,
                ["VersionGroup"] = group.VersionGroup
            });
    }
    user["ClearedTutorialDataNew"] = materialized;
    var afterInvariant = NonTutorialCanonicalSha256(input);
    if (!string.Equals(beforeInvariant, afterInvariant, StringComparison.Ordinal))
        throw new InvalidDataException("non-tutorial database state changed");

    await WriteExclusiveJsonAsync(outputPath, input);
    var reloaded = JsonNode.Parse(await File.ReadAllTextAsync(outputPath)) as JsonObject ??
        throw new InvalidDataException("written database JSON invalid");
    var reloadedUsers = reloaded["Users"] as JsonArray;
    var reloadedUser = reloadedUsers?[0] as JsonObject;
    var reloadedTutorial = reloadedUser?["ClearedTutorialDataNew"] as JsonObject;
    if (reloadedTutorial?.Count != projection.TutorialGroupCount ||
        !string.Equals(NonTutorialCanonicalSha256(reloaded), beforeInvariant,
            StringComparison.Ordinal))
    {
        throw new InvalidDataException("written tutorial database verification failed");
    }

    var summary = new
    {
        schemaVersion = 1,
        contractId =
            "nll/phase3b2-epinel-tutorial-only-db-materialization-summary/v1",
        databaseBeforeByteLength = new FileInfo(inputPath).Length,
        databaseBeforeSha256 = await Sha256FileAsync(inputPath),
        databaseAfterByteLength = new FileInfo(outputPath).Length,
        databaseAfterSha256 = await Sha256FileAsync(outputPath),
        tutorialGroupCount = projection.TutorialGroupCount,
        tutorialGroupCanonicalSha256 = projection.TutorialGroupCanonicalSha256,
        nonTutorialCanonicalSha256 = beforeInvariant,
        nonTutorialStateChanged = false,
        rawTutorialIdentifiersEmittedToStdout = false
    };
    Console.WriteLine(JsonSerializer.Serialize(summary, JsonOptions()));
}

static string NonTutorialCanonicalSha256(JsonObject database)
{
    var clone = database.DeepClone() as JsonObject ??
        throw new InvalidDataException("database clone invalid");
    var users = clone["Users"] as JsonArray ??
        throw new InvalidDataException("database clone users missing");
    var user = users[0] as JsonObject ??
        throw new InvalidDataException("database clone user missing");
    user["ClearedTutorialDataNew"] = new JsonObject();
    return Sha256Text(clone.ToJsonString(new JsonSerializerOptions
    {
        WriteIndented = false
    }));
}

static async Task WriteExclusiveJsonAsync(string path, object value)
{
    Directory.CreateDirectory(Path.GetDirectoryName(path) ??
        throw new InvalidDataException("output parent invalid"));
    await using var stream = new FileStream(path, FileMode.CreateNew,
        FileAccess.Write, FileShare.None);
    await JsonSerializer.SerializeAsync(stream, value, JsonOptions());
    await stream.WriteAsync(Encoding.UTF8.GetBytes("\n"));
}

static JsonSerializerOptions JsonOptions() => new()
{
    PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    PropertyNameCaseInsensitive = true,
    WriteIndented = true
};

static async Task<string> Sha256FileAsync(string path)
{
    await using var stream = File.OpenRead(path);
    var digest = await SHA256.HashDataAsync(stream);
    return Convert.ToHexStringLower(digest);
}

static string Sha256Text(string text) =>
    Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(text)));

internal sealed record TutorialProjection(
    int SchemaVersion,
    string ContractId,
    string StaticDataPackSha256,
    long StaticDataPackByteLength,
    int TutorialRecordCount,
    int TutorialGroupCount,
    string TutorialGroupCanonicalSha256,
    TutorialProjectionGroup[] Groups);

internal sealed record TutorialProjectionGroup(
    int GroupId,
    int TerminalTutorialId,
    int VersionGroup,
    int MemberCount);
