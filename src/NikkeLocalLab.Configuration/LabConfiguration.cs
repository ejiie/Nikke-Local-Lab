using System.Text.Json;

namespace NikkeLocalLab.Configuration;

public sealed record LabPathOptions
{
  public required string GameRoot { get; init; }

  public required string RuntimeRootEnvironmentVariable { get; init; }
}

public sealed record LabDatabaseOptions
{
  public required string Provider { get; init; }

  public required string ConnectionStringEnvironmentVariable { get; init; }
}

public sealed record LabSourceOptions
{
  public required bool GameFilesReadOnly { get; init; }

  public required bool AllowOfficialNetwork { get; init; }

  public required bool AllowAuthenticatedSources { get; init; }

  public required bool AllowRepositoryAssetCopies { get; init; }
}

public sealed record LabNetworkOptions
{
  public required string BindAddress { get; init; }

  public required int Port { get; init; }

  public required bool LanEnabled { get; init; }

  public required string[] AllowedCidrs { get; init; }

  public required bool LocalAuthenticationRequiredForLan { get; init; }

  public required bool AllowOfficialOutbound { get; init; }
}

public sealed record LabIdentityOptions
{
  public required string HmacSecretEnvironmentVariable { get; init; }

  public required bool ExposeSourceAliases { get; init; }
}

public sealed record CharacterSkillDefaultOptions
{
  public required int Skill1 { get; init; }

  public required int Skill2 { get; init; }

  public required int Burst { get; init; }
}

public sealed record CharacterBuildDefaultOptions
{
  public required string PolicyId { get; init; }

  public required string CharacterLevel { get; init; }

  public required string LimitBreak { get; init; }

  public required string CoreLevel { get; init; }

  public required string Bond { get; init; }

  public required int EquipmentTier { get; init; }

  public required int EquipmentEnhancementLevel { get; init; }

  public required bool? ManufacturerMatched { get; init; }

  public required string CubeInitialState { get; init; }

  public required string CubeSelection { get; init; }

  public required int CubeLevelWhenEquipped { get; init; }

  public required CharacterSkillDefaultOptions SkillLevels { get; init; }

  public required string OverloadValidationMode { get; init; }

  public required string CollectibleSelection { get; init; }
}

public sealed record SoloRaidSupportRuleOptions
{
  public required string Kind { get; init; }

  public string? BossElement { get; init; }

  public string? WeaknessCode { get; init; }

  public int? SeasonNumber { get; init; }
}

public sealed record SoloRaidSupportPolicyOptions
{
  public required string PolicyId { get; init; }

  public required int[] ExcludedSeasonNumbers { get; init; }

  public required SoloRaidSupportRuleOptions[] Rules { get; init; }

  public required bool RejectUnresolvedCandidates { get; init; }
}

public sealed record SoloRaidChallengeCompatibilityOptions
{
  public required int DifficultyType { get; init; }

  public required int WaveOrder { get; init; }
}

public sealed record SoloRaidNormalStageOptions
{
  public required bool Implemented { get; init; }

  public required bool UnlockStateOnly { get; init; }

  public required int LastClearLevel { get; init; }
}

public sealed record SoloRaidOptions
{
  public required bool Enabled { get; init; }

  public required string[] SupportedModes { get; init; }

  public required SoloRaidSupportPolicyOptions SupportPolicy { get; init; }

  public required SoloRaidChallengeCompatibilityOptions ChallengeCompatibility { get; init; }

  public required SoloRaidNormalStageOptions NormalStages { get; init; }

  public required bool OneActiveSeasonAtATime { get; init; }

  public required bool UnionRaidEnabled { get; init; }

  public required bool RequireRuntimeMatchForOriginalClientExecution { get; init; }
}

public sealed record OriginalClientCompatibilityOptions
{
  public required bool Enabled { get; init; }

  public required string Status { get; init; }

  public required string RequiredRoute { get; init; }

  public required bool AllowEndpointMutation { get; init; }

  public required bool AllowAuthBypass { get; init; }

  public required bool AllowOfficialCredentials { get; init; }

  public required bool AllowProcessInjection { get; init; }

  public required bool AllowAntiCheatBypass { get; init; }
}

public sealed record LabConfigDocument
{
  public required LabPathOptions Paths { get; init; }

  public required LabNetworkOptions Network { get; init; }

  public required LabDatabaseOptions Database { get; init; }

  public required LabIdentityOptions Identity { get; init; }

  public required LabSourceOptions Sources { get; init; }

  public required CharacterBuildDefaultOptions CharacterBuildDefaults { get; init; }

  public required SoloRaidOptions SoloRaid { get; init; }

  public required OriginalClientCompatibilityOptions OriginalClientCompatibility { get; init; }
}

public sealed record ResolvedLabConfiguration(
    string GameRoot,
    string RuntimeRoot,
    string DatabaseConnectionStringEnvironmentVariable,
    string IdentitySecretEnvironmentVariable);

public interface ILabEnvironment
{
  string? GetEnvironmentVariable(string name);

  string? GetLocalApplicationData();
}

public sealed class SystemLabEnvironment : ILabEnvironment
{
  public string? GetEnvironmentVariable(string name) => Environment.GetEnvironmentVariable(name);

  public string? GetLocalApplicationData() =>
      Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
}

public sealed class LabConfigurationException : Exception
{
  public LabConfigurationException(string code)
      : base(code)
  {
    Code = code;
  }

  public string Code { get; }
}

public static class LabConfigurationLoader
{
  private static readonly JsonSerializerOptions SerializerOptions = new()
  {
    PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    PropertyNameCaseInsensitive = false,
    UnmappedMemberHandling = System.Text.Json.Serialization.JsonUnmappedMemberHandling.Disallow
  };

  public static ResolvedLabConfiguration Load(
      string configPath,
      string repositoryRoot,
      ILabEnvironment? environment = null)
  {
    environment ??= new SystemLabEnvironment();

    LabConfigDocument document;
    try
    {
      using var stream = new FileStream(configPath, FileMode.Open, FileAccess.Read, FileShare.Read);
      document = JsonSerializer.Deserialize<LabConfigDocument>(stream, SerializerOptions)
          ?? throw new LabConfigurationException("config_empty");
    }
    catch (LabConfigurationException)
    {
      throw;
    }
    catch
    {
      throw new LabConfigurationException("config_read_failed");
    }

    ValidateFailClosed(document);

    var gameRoot = PathBoundary.NormalizeAbsoluteLocalPath(document.Paths.GameRoot, "game_root_invalid");
    var runtimeOverride = environment.GetEnvironmentVariable(document.Paths.RuntimeRootEnvironmentVariable);
    var runtimeRoot = string.IsNullOrWhiteSpace(runtimeOverride)
        ? ResolveDefaultRuntimeRoot(environment)
        : PathBoundary.NormalizeAbsoluteLocalPath(runtimeOverride, "runtime_root_invalid");
    var normalizedRepositoryRoot = PathBoundary.NormalizeAbsoluteLocalPath(repositoryRoot, "repository_root_invalid");

    PathBoundary.EnsureDisjoint(gameRoot, runtimeRoot, "source_runtime_overlap");
    PathBoundary.EnsureDisjoint(normalizedRepositoryRoot, runtimeRoot, "repository_runtime_overlap");
    PathBoundary.EnsureDisjoint(normalizedRepositoryRoot, gameRoot, "repository_source_overlap");

    return new ResolvedLabConfiguration(
        gameRoot,
        runtimeRoot,
        document.Database.ConnectionStringEnvironmentVariable,
        document.Identity.HmacSecretEnvironmentVariable);
  }

  private static string ResolveDefaultRuntimeRoot(ILabEnvironment environment)
  {
    var localApplicationData = environment.GetLocalApplicationData();
    if (string.IsNullOrWhiteSpace(localApplicationData))
    {
      throw new LabConfigurationException("local_app_data_unavailable");
    }

    var root = Path.Combine(localApplicationData, "NikkeLocalLab");
    return PathBoundary.NormalizeAbsoluteLocalPath(root, "runtime_root_invalid");
  }

  private static void ValidateFailClosed(LabConfigDocument document)
  {
    if (document.Paths is null ||
        document.Network is null ||
        document.Database is null ||
        document.Identity is null ||
        document.Sources is null ||
        document.CharacterBuildDefaults is null ||
        document.SoloRaid is null ||
        document.OriginalClientCompatibility is null)
    {
      throw new LabConfigurationException("configuration_section_missing");
    }

    if (!string.Equals(document.Database.Provider, "postgresql", StringComparison.Ordinal))
    {
      throw new LabConfigurationException("database_provider_not_supported");
    }

    if (string.IsNullOrWhiteSpace(document.Paths.RuntimeRootEnvironmentVariable) ||
        string.IsNullOrWhiteSpace(document.Database.ConnectionStringEnvironmentVariable) ||
        string.IsNullOrWhiteSpace(document.Identity.HmacSecretEnvironmentVariable))
    {
      throw new LabConfigurationException("environment_variable_name_missing");
    }

    if (!document.Sources.GameFilesReadOnly ||
        document.Sources.AllowOfficialNetwork ||
        document.Sources.AllowAuthenticatedSources ||
        document.Sources.AllowRepositoryAssetCopies ||
        document.Network.AllowOfficialOutbound ||
        document.Network.LanEnabled ||
        document.Network.Port is < 1 or > 65535 ||
        document.Network.AllowedCidrs is null ||
        document.Network.AllowedCidrs.Length != 0 ||
        !document.Network.LocalAuthenticationRequiredForLan ||
        !string.Equals(document.Network.BindAddress, "127.0.0.1", StringComparison.Ordinal) ||
        document.Identity.ExposeSourceAliases ||
        document.OriginalClientCompatibility.Enabled ||
        !string.Equals(document.OriginalClientCompatibility.Status, "blocked", StringComparison.Ordinal) ||
        !string.Equals(
            document.OriginalClientCompatibility.RequiredRoute,
            "supported_local_or_test_only",
            StringComparison.Ordinal) ||
        document.OriginalClientCompatibility.AllowEndpointMutation ||
        document.OriginalClientCompatibility.AllowAuthBypass ||
        document.OriginalClientCompatibility.AllowOfficialCredentials ||
        document.OriginalClientCompatibility.AllowProcessInjection ||
        document.OriginalClientCompatibility.AllowAntiCheatBypass)
    {
      throw new LabConfigurationException("unsafe_configuration_rejected");
    }

    ValidateCharacterBuildDefaults(document.CharacterBuildDefaults);
    ValidateSoloRaid(document.SoloRaid);
  }

  private static void ValidateCharacterBuildDefaults(CharacterBuildDefaultOptions options)
  {
    if (options.SkillLevels is null ||
        !string.Equals(options.PolicyId, "combat-max/v1", StringComparison.Ordinal) ||
        !string.Equals(options.CharacterLevel, "explicit_required", StringComparison.Ordinal) ||
        !string.Equals(options.LimitBreak, "max_supported", StringComparison.Ordinal) ||
        !string.Equals(options.CoreLevel, "max_if_applicable", StringComparison.Ordinal) ||
        !string.Equals(options.Bond, "max_for_character", StringComparison.Ordinal) ||
        options.EquipmentTier != 10 ||
        options.EquipmentEnhancementLevel != 5 ||
        options.ManufacturerMatched is not null ||
        !string.Equals(options.CubeInitialState, "unequipped", StringComparison.Ordinal) ||
        !string.Equals(options.CubeSelection, "explicit_required", StringComparison.Ordinal) ||
        options.CubeLevelWhenEquipped != 15 ||
        options.SkillLevels.Skill1 != 10 ||
        options.SkillLevels.Skill2 != 10 ||
        options.SkillLevels.Burst != 10 ||
        !string.Equals(options.OverloadValidationMode, "research", StringComparison.Ordinal) ||
        !string.Equals(
            options.CollectibleSelection,
            "favorite_max_if_applicable_else_highest_rarity_collection_max",
            StringComparison.Ordinal))
    {
      throw new LabConfigurationException("character_build_defaults_invalid");
    }
  }

  private static void ValidateSoloRaid(SoloRaidOptions options)
  {
    if (options.SupportedModes is null ||
        options.SupportPolicy is null ||
        options.SupportPolicy.ExcludedSeasonNumbers is null ||
        options.SupportPolicy.Rules is null ||
        options.ChallengeCompatibility is null ||
        options.NormalStages is null ||
        !options.Enabled ||
        !options.SupportedModes.SequenceEqual(["challenge"], StringComparer.Ordinal) ||
        !string.Equals(
            options.SupportPolicy.PolicyId,
            "challenge-boss-support/v1",
            StringComparison.Ordinal) ||
        !options.SupportPolicy.ExcludedSeasonNumbers.Order().SequenceEqual([14, 39]) ||
        !options.SupportPolicy.RejectUnresolvedCandidates ||
        options.ChallengeCompatibility.DifficultyType != 2 ||
        options.ChallengeCompatibility.WaveOrder != 8 ||
        options.NormalStages.Implemented ||
        !options.NormalStages.UnlockStateOnly ||
        options.NormalStages.LastClearLevel != 7 ||
        !options.OneActiveSeasonAtATime ||
        options.UnionRaidEnabled ||
        !options.RequireRuntimeMatchForOriginalClientExecution ||
        !HasExpectedSoloRaidRules(options.SupportPolicy.Rules))
    {
      throw new LabConfigurationException("solo_raid_configuration_invalid");
    }
  }

  private static bool HasExpectedSoloRaidRules(IReadOnlyList<SoloRaidSupportRuleOptions> rules)
  {
    if (rules.Count != 2 || rules.Any(rule => rule is null))
    {
      return false;
    }

    var elementRules = rules.Where(rule =>
        string.Equals(rule.Kind, "element_weakness", StringComparison.Ordinal)).ToArray();
    var seasonRules = rules.Where(rule =>
        string.Equals(rule.Kind, "explicit_season", StringComparison.Ordinal)).ToArray();
    if (elementRules.Length != 1 || seasonRules.Length != 1)
    {
      return false;
    }

    var elementRule = elementRules[0];
    var seasonRule = seasonRules[0];
    return
        string.Equals(elementRule.BossElement, "electric", StringComparison.Ordinal) &&
        string.Equals(elementRule.WeaknessCode, "iron", StringComparison.Ordinal) &&
        elementRule.SeasonNumber is null &&
        seasonRule is not null &&
        seasonRule.BossElement is null &&
        seasonRule.WeaknessCode is null &&
        seasonRule.SeasonNumber == 40;
  }
}
