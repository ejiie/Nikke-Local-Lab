using System.Text.Json;
using System.Text.Json.Nodes;
using NikkeLocalLab.Configuration;
using NikkeLocalLab.Import.Sources;
using NikkeLocalLab.Persistence.PostgreSql;

namespace NikkeLocalLab.UnitTests;

public sealed class ConfigurationAndSourceBoundaryTests
{
  [Fact]
  public void CheckedInExampleConfigurationMatchesTheFailClosedLoaderContract()
  {
    using var temporary = new TemporaryDirectory();
    var sourceRoot = temporary.CreateDirectory("source");
    var repositoryRoot = temporary.CreateDirectory("repository");
    var runtimeRoot = System.IO.Path.Combine(temporary.Path, "runtime-home");
    var examplePath = System.IO.Path.Combine(AppContext.BaseDirectory, "Fixtures", "appsettings.example.json");
    var example = JsonNode.Parse(File.ReadAllText(examplePath))?.AsObject()
        ?? throw new InvalidOperationException("The checked-in example configuration is invalid.");
    var paths = example["paths"]?.AsObject()
        ?? throw new InvalidOperationException("The checked-in example paths section is missing.");
    paths["gameRoot"] = sourceRoot;
    var configPath = System.IO.Path.Combine(temporary.Path, "checked-in-example.json");
    File.WriteAllText(configPath, example.ToJsonString());

    var resolved = LabConfigurationLoader.Load(
        configPath,
        repositoryRoot,
        new FakeEnvironment(runtimeRoot, null));

    Assert.Equal(sourceRoot, resolved.GameRoot);
    Assert.Equal(runtimeRoot, resolved.RuntimeRoot);
    Assert.Equal("NIKKE_LAB_DB", resolved.DatabaseConnectionStringEnvironmentVariable);
    Assert.Equal("127.0.0.1", resolved.BindAddress);
    Assert.Equal(17878, resolved.Port);
  }

  [Fact]
  public void SoloRaidScopeMutationFailsClosed()
  {
    using var temporary = new TemporaryDirectory();
    var sourceRoot = temporary.CreateDirectory("source");
    var repositoryRoot = temporary.CreateDirectory("repository");
    var runtimeRoot = System.IO.Path.Combine(temporary.Path, "runtime-home");
    var configPath = WriteConfig(temporary.Path, sourceRoot);
    var document = JsonNode.Parse(File.ReadAllText(configPath))?.AsObject()
        ?? throw new InvalidOperationException("The synthetic configuration is invalid.");
    var soloRaid = document["soloRaid"]?.AsObject()
        ?? throw new InvalidOperationException("The synthetic Solo Raid section is missing.");
    soloRaid["unionRaidEnabled"] = true;
    File.WriteAllText(configPath, document.ToJsonString());

    var exception = Assert.Throws<LabConfigurationException>(() =>
        LabConfigurationLoader.Load(configPath, repositoryRoot, new FakeEnvironment(runtimeRoot, null)));

    Assert.Equal("solo_raid_configuration_invalid", exception.Code);
  }

  [Theory]
  [InlineData("challenge_locked")]
  [InlineData("quick_battle_enabled")]
  [InlineData("season_expiring")]
  [InlineData("season_directory_changed")]
  [InlineData("selection_scope_changed")]
  [InlineData("daily_reset_changed")]
  public void PermanentChallengePolicyMutationFailsClosed(string mutation)
  {
    using var temporary = new TemporaryDirectory();
    var sourceRoot = temporary.CreateDirectory("source");
    var repositoryRoot = temporary.CreateDirectory("repository");
    var runtimeRoot = System.IO.Path.Combine(temporary.Path, "runtime-home");
    var configPath = WriteConfig(temporary.Path, sourceRoot);
    var document = JsonNode.Parse(File.ReadAllText(configPath))?.AsObject()
        ?? throw new InvalidOperationException("The synthetic configuration is invalid.");
    var soloRaid = document["soloRaid"]?.AsObject()
        ?? throw new InvalidOperationException("The synthetic Solo Raid section is missing.");

    switch (mutation)
    {
      case "challenge_locked":
        soloRaid["challengeUnlocked"] = false;
        break;
      case "quick_battle_enabled":
        soloRaid["quickBattleSupported"] = true;
        break;
      case "season_expiring":
        soloRaid["seasonEndsAt"] = "2099-01-01T00:00:00Z";
        break;
      case "season_directory_changed":
        soloRaid["publishedSeasonNumbers"] = new JsonArray(7, 13, 26, 29, 34);
        break;
      case "selection_scope_changed":
        soloRaid["oneSelectedSeasonPerClientContext"] = false;
        break;
      case "daily_reset_changed":
        soloRaid["dailyReset"]!["hour"] = 4;
        break;
      default:
        throw new InvalidOperationException("Unknown synthetic mutation.");
    }

    File.WriteAllText(configPath, document.ToJsonString());
    var exception = Assert.Throws<LabConfigurationException>(() =>
        LabConfigurationLoader.Load(configPath, repositoryRoot, new FakeEnvironment(runtimeRoot, null)));

    Assert.Equal("solo_raid_configuration_invalid", exception.Code);
  }

  [Fact]
  public void RuntimeRootIsInitializedOutsideRepositoryAndSource()
  {
    using var temporary = new TemporaryDirectory();
    var sourceRoot = temporary.CreateDirectory("source");
    var repositoryRoot = temporary.CreateDirectory("repository");
    var runtimeRoot = System.IO.Path.Combine(temporary.Path, "runtime-home");
    var configPath = WriteConfig(temporary.Path, sourceRoot);
    var environment = new FakeEnvironment(runtimeRoot, null);

    var resolved = LabConfigurationLoader.Load(configPath, repositoryRoot, environment);
    var first = RuntimeRootInitializer.Initialize(resolved, repositoryRoot);
    var second = RuntimeRootInitializer.Initialize(resolved, repositoryRoot);

    Assert.Equal(first, second);
    var children = Directory.GetDirectories(runtimeRoot)
        .Select(System.IO.Path.GetFileName)
        .OrderBy(name => name, StringComparer.Ordinal)
        .ToArray();
    Assert.Equal(
        new[] { "cache", "data", "database", "logs", "secrets", "staging", "vault" },
        children);
    Assert.Empty(Directory.GetFileSystemEntries(sourceRoot));
    Assert.Empty(Directory.GetFileSystemEntries(repositoryRoot));
  }

  [Fact]
  public void RuntimeRootOverlapAndMissingFallbackFailClosed()
  {
    using var temporary = new TemporaryDirectory();
    var sourceRoot = temporary.CreateDirectory("source");
    var repositoryRoot = temporary.CreateDirectory("repository");
    var configPath = WriteConfig(temporary.Path, sourceRoot);

    Assert.Throws<LabConfigurationException>(() => LabConfigurationLoader.Load(
        configPath,
        repositoryRoot,
        new FakeEnvironment(System.IO.Path.Combine(repositoryRoot, "runtime"), null)));
    Assert.Throws<LabConfigurationException>(() => LabConfigurationLoader.Load(
        configPath,
        repositoryRoot,
        new FakeEnvironment(null, null)));
  }

  [Fact]
  public void UnknownSafetyConfigurationPropertyFailsClosed()
  {
    using var temporary = new TemporaryDirectory();
    var sourceRoot = temporary.CreateDirectory("source");
    var repositoryRoot = temporary.CreateDirectory("repository");
    var runtimeRoot = System.IO.Path.Combine(temporary.Path, "runtime-home");
    var configPath = WriteConfig(temporary.Path, sourceRoot);
    var json = File.ReadAllText(configPath);
    var changed = json.Replace(
        "\"paths\":{",
        "\"paths\":{\"unexpectedSafetySwitch\":true,",
        StringComparison.Ordinal);
    Assert.NotEqual(json, changed);
    File.WriteAllText(configPath, changed);

    var exception = Assert.Throws<LabConfigurationException>(() =>
        LabConfigurationLoader.Load(configPath, repositoryRoot, new FakeEnvironment(runtimeRoot, null)));

    Assert.Equal("config_read_failed", exception.Code);
  }

  [Theory]
  [InlineData("../outside")]
  [InlineData(".\\inside")]
  [InlineData("C:\\outside")]
  [InlineData("/outside")]
  [InlineData("\\outside")]
  [InlineData("file:stream")]
  [InlineData("\\\\server\\share\\file")]
  public void SourceRelativePathRejectsUnsafeForms(string value)
  {
    Assert.Throws<SourceBoundaryException>(() => SourceRelativePath.Parse(value));
  }

  [Fact]
  public async Task SourceAdapterOnlyReturnsReadStreamsAndDoesNotModifySource()
  {
    using var temporary = new TemporaryDirectory();
    var sourceRoot = temporary.CreateDirectory("source");
    var repositoryRoot = temporary.CreateDirectory("repository");
    var runtimeRoot = temporary.CreateDirectory("runtime");
    var sourceFile = System.IO.Path.Combine(sourceRoot, "fixture.txt");
    await File.WriteAllTextAsync(sourceFile, "synthetic-source");
    var beforeBytes = await File.ReadAllBytesAsync(sourceFile);
    var beforeWriteTime = File.GetLastWriteTimeUtc(sourceFile);

    var root = new ReadOnlySourceRoot(sourceRoot, repositoryRoot, runtimeRoot);
    var artifact = root.Bind(SourceRelativePath.Parse("fixture.txt"), "synthetic_catalog");
    var streamShape = await artifact.ReadAsync((stream, _) => Task.FromResult(new
    {
      stream.CanWrite,
      IsFileStream = stream is FileStream,
      ExposesName = stream.GetType().GetProperty("Name") is not null
    }));
    var observation = await artifact.ObserveAsync();

    Assert.False(streamShape.CanWrite);
    Assert.False(streamShape.IsFileStream);
    Assert.False(streamShape.ExposesName);
    Assert.Equal(beforeBytes.Length, observation.ByteLength);
    Assert.Equal(beforeBytes, await File.ReadAllBytesAsync(sourceFile));
    Assert.Equal(beforeWriteTime, File.GetLastWriteTimeUtc(sourceFile));
    Assert.DoesNotContain(
        artifact.GetType().GetMethods().Where(method => method.IsPublic).Select(method => method.Name),
        name => name.Contains("Write", StringComparison.OrdinalIgnoreCase) ||
            name.Contains("Create", StringComparison.OrdinalIgnoreCase) ||
            name.Contains("Delete", StringComparison.OrdinalIgnoreCase));
  }

  [Fact]
  public void SourceAdapterRejectsReparsePointWhenPlatformAllowsCreatingOne()
  {
    using var temporary = new TemporaryDirectory();
    var sourceRoot = temporary.CreateDirectory("source");
    var repositoryRoot = temporary.CreateDirectory("repository");
    var runtimeRoot = temporary.CreateDirectory("runtime");
    var outside = temporary.CreateDirectory("outside");
    File.WriteAllText(System.IO.Path.Combine(outside, "fixture.txt"), "synthetic");
    var link = System.IO.Path.Combine(sourceRoot, "linked");

    try
    {
      Directory.CreateSymbolicLink(link, outside);
    }
    catch (Exception exception) when (exception is UnauthorizedAccessException or IOException or PlatformNotSupportedException)
    {
      return;
    }

    var root = new ReadOnlySourceRoot(sourceRoot, repositoryRoot, runtimeRoot);
    Assert.Throws<SourceBoundaryException>(() =>
        root.Bind(SourceRelativePath.Parse("linked/fixture.txt"), "synthetic_catalog"));
  }

  [Theory]
  [InlineData("Host=example.com;Database=lab;Username=lab;Password=synthetic")]
  [InlineData("Host=127.0.0.1,example.com;Database=lab;Username=lab;Password=synthetic")]
  [InlineData("Host=127.0.0.1;Database=lab;Username=lab;Password=synthetic;Include Error Detail=true")]
  public void PostgreSqlPolicyRejectsRemoteOrVerboseConnections(string connectionString)
  {
    Assert.Throws<PostgreSqlPolicyException>(() => PostgreSqlConnectionPolicy.Validate(connectionString));
  }

  [Fact]
  public void PostgreSqlPolicyAcceptsLoopbackWithoutEchoingTheSecret()
  {
    const string connectionString = "Host=127.0.0.1;Database=lab;Username=lab;Password=synthetic-secret;Include Error Detail=false";

    var result = PostgreSqlConnectionPolicy.Validate(connectionString);

    Assert.Contains("127.0.0.1", result, StringComparison.Ordinal);
    var exception = Assert.Throws<PostgreSqlPolicyException>(() =>
        PostgreSqlConnectionPolicy.ResolveFromEnvironment("MISSING", _ => null));
    Assert.DoesNotContain("synthetic-secret", exception.Message, StringComparison.Ordinal);
  }

  private static string WriteConfig(string basePath, string gameRoot)
  {
    var configPath = System.IO.Path.Combine(basePath, $"config-{Guid.NewGuid():N}.json");
    var json = JsonSerializer.Serialize(new
    {
      paths = new
      {
        gameRoot,
        runtimeRootEnvironmentVariable = "NIKKE_LAB_HOME"
      },
      network = new
      {
        bindAddress = "127.0.0.1",
        port = 17878,
        lanEnabled = false,
        allowedCidrs = Array.Empty<string>(),
        localAuthenticationRequiredForLan = true,
        allowOfficialOutbound = false
      },
      database = new
      {
        provider = "postgresql",
        connectionStringEnvironmentVariable = "NIKKE_LAB_DB"
      },
      identity = new
      {
        hmacSecretEnvironmentVariable = "NIKKE_LAB_ID_SECRET",
        exposeSourceAliases = false
      },
      sources = new
      {
        gameFilesReadOnly = true,
        allowOfficialNetwork = false,
        allowAuthenticatedSources = false,
        allowRepositoryAssetCopies = false
      },
      characterBuildDefaults = new
      {
        policyId = "combat-max/v1",
        characterLevel = "explicit_required",
        limitBreak = "max_supported",
        coreLevel = "max_if_applicable",
        bond = "max_for_character",
        equipmentTier = 10,
        equipmentEnhancementLevel = 5,
        manufacturerMatched = (bool?)null,
        cubeInitialState = "unequipped",
        cubeSelection = "explicit_required",
        cubeLevelWhenEquipped = 15,
        skillLevels = new
        {
          skill1 = 10,
          skill2 = 10,
          burst = 10
        },
        overloadValidationMode = "research",
        collectibleSelection = "favorite_max_if_applicable_else_highest_rarity_collection_max"
      },
      soloRaid = new
      {
        enabled = true,
        supportedModes = new[] { "challenge" },
        supportPolicy = new
        {
          policyId = "challenge-boss-support/v1",
          excludedSeasonNumbers = new[] { 14, 39 },
          rules = new object[]
                {
                        new
                        {
                            kind = "element_weakness",
                            bossElement = "electric",
                            weaknessCode = "iron"
                        },
                        new
                        {
                            kind = "explicit_season",
                            seasonNumber = 40
                        }
                },
          rejectUnresolvedCandidates = true
        },
        challengeCompatibility = new
        {
          difficultyType = 2,
          waveOrder = 8
        },
        normalStages = new
        {
          implemented = false,
          unlockStateOnly = true,
          lastClearLevel = 7
        },
        publishedSeasonNumbers = new[] { 7, 13, 26, 29, 34, 40 },
        oneSelectedSeasonPerClientContext = true,
        challengeUnlocked = true,
        quickBattleSupported = false,
        seasonAvailability = "permanent",
        seasonEndsAt = (string?)null,
        dailyReset = new
        {
          timeZoneId = "Asia/Seoul",
          hour = 5,
          minute = 0
        },
        unionRaidEnabled = false,
        requireRuntimeMatchForOriginalClientExecution = true
      },
      originalClientCompatibility = new
      {
        enabled = false,
        status = "blocked",
        requiredRoute = "supported_local_or_test_only",
        allowEndpointMutation = false,
        allowAuthBypass = false,
        allowOfficialCredentials = false,
        allowProcessInjection = false,
        allowAntiCheatBypass = false
      }
    });
    File.WriteAllText(configPath, json);
    return configPath;
  }

  private sealed class FakeEnvironment(string? runtimeRoot, string? localApplicationData) : ILabEnvironment
  {
    public string? GetEnvironmentVariable(string name) => runtimeRoot;

    public string? GetLocalApplicationData() => localApplicationData;
  }
}
