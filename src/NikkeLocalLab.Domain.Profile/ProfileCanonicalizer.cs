using System.Globalization;
using NikkeLocalLab.Domain.CombatSupport;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Domain.Profile;

public static class ProfileCanonicalizer
{
  public const string AccountCombatStateContractId = "nll/account-combat-state-content/v1";
  public const string CharacterBuildContractId = "nll/character-build-content/v1";
  public const string SquadContractId = "nll/squad-content/v1";
  public const string ProfileTemplateContractId = "nll/profile-template-content/v1";

  public static string ToCanonicalText(AccountCombatStateRevisionContent content)
  {
    ArgumentNullException.ThrowIfNull(content);
    var lines = new List<string> { content.Cubes.Count == 0
        ? AccountCombatStateContractId : "nll/account-combat-state-content/v2" };
    AppendBinding(lines, content.DatasetBinding);
    lines.Add($"validation-mode={ProfileCanonicalCodes.ValidationMode(content.ValidationMode)}");
    lines.Add($"synchro-level={Fact(content.SynchroLevel, Integer)}");
    lines.Add($"consoles.count={Integer(content.Consoles.Count)}");
    for (var index = 0; index < content.Consoles.Count; index++)
    {
      var console = content.Consoles[index];
      var prefix = $"consoles.{Integer(index)}";
      lines.Add($"{prefix}.coordinate={ProfileCanonicalCodes.ConsoleCoordinate(console.Coordinate)}");
      AppendSupportReference(lines, $"{prefix}.definition", console.Definition);
      lines.Add($"{prefix}.level={Fact(console.Level, Integer)}");
      lines.Add($"{prefix}.experience={Fact(console.Experience, Long)}");
    }

    if (content.Cubes.Count > 0)
    {
      lines.Add($"cubes.count={Integer(content.Cubes.Count)}");
      for (var index = 0; index < content.Cubes.Count; index++)
      {
        var cube = content.Cubes[index];
        var prefix = $"cubes.{Integer(index)}";
        AppendSupportReference(lines, $"{prefix}.definition", cube.Definition);
        lines.Add($"{prefix}.level={Integer(cube.Level)}");
      }
    }

    return string.Join('\n', lines);
  }

  public static string ToCanonicalText(CharacterBuildRevisionContent content)
  {
    ArgumentNullException.ThrowIfNull(content);
    var lines = new List<string> { CharacterBuildContractId };
    AppendBinding(lines, content.DatasetBinding);
    lines.Add($"materialization-policy={ProfileCanonicalCodes.MaterializationPolicy(content.MaterializationPolicy)}");
    lines.Add($"validation-mode={ProfileCanonicalCodes.ValidationMode(content.ValidationMode)}");
    AppendCharacterReference(lines, "character-definition", content.CharacterDefinition);
    lines.Add($"investment.character-level={Integer(content.Investment.CharacterLevel)}");
    lines.Add($"investment.limit-break={Fact(content.Investment.LimitBreak, Integer)}");
    lines.Add($"investment.core-level={Fact(content.Investment.CoreLevel, Integer)}");
    lines.Add($"investment.bond-level={Fact(content.Investment.BondLevel, Integer)}");
    lines.Add($"skills.skill-1={Fact(content.Skills.Skill1, Integer)}");
    lines.Add($"skills.skill-2={Fact(content.Skills.Skill2, Integer)}");
    lines.Add($"skills.burst={Fact(content.Skills.Burst, Integer)}");
    lines.Add($"equipment.count={Integer(content.Equipment.Count)}");
    for (var index = 0; index < content.Equipment.Count; index++)
    {
      var equipment = content.Equipment[index];
      var prefix = $"equipment.{Integer(index)}";
      lines.Add($"{prefix}.slot={ProfileCanonicalCodes.EquipmentSlot(equipment.Slot)}");
      lines.Add($"{prefix}.slot-uid={Uid(equipment.EquipmentSlotUid)}");
      lines.Add($"{prefix}.attachment={ProfileCanonicalCodes.AttachmentKind(equipment.AttachmentKind)}");
      lines.Add($"{prefix}.reason={equipment.ReasonCode ?? "not_applicable"}");
      if (equipment.Definition is { } definition)
      {
        AppendSupportReference(lines, $"{prefix}.definition", definition);
      }
      else
      {
        lines.Add($"{prefix}.definition=not_applicable");
      }

      lines.Add($"{prefix}.tier={Fact(equipment.Tier, Integer)}");
      lines.Add($"{prefix}.enhancement-level={Fact(equipment.EnhancementLevel, Integer)}");
      lines.Add($"{prefix}.manufacturer-match={Fact(equipment.ManufacturerMatch, Boolean)}");
      lines.Add($"{prefix}.overload-lines.count={Integer(equipment.OverloadLines.Count)}");
      for (var lineOrdinal = 0; lineOrdinal < equipment.OverloadLines.Count; lineOrdinal++)
      {
        var line = equipment.OverloadLines[lineOrdinal];
        var linePrefix = $"{prefix}.overload-lines.{Integer(lineOrdinal)}";
        lines.Add($"{linePrefix}.line-index={Integer(line.LineIndex)}");
        AppendSupportReference(lines, $"{linePrefix}.option-definition", line.OptionDefinition);
        lines.Add($"{linePrefix}.option-type={Fact(line.OptionType, ProfileCanonicalCodes.OverloadOptionType)}");
        lines.Add($"{linePrefix}.unit={Fact(line.Unit, ProfileCanonicalCodes.ValueUnit)}");
        lines.Add($"{linePrefix}.application-value={Exact(line.ApplicationValue)}");
      }
    }

    lines.Add($"cube.attachment={ProfileCanonicalCodes.AttachmentKind(content.Cube.AttachmentKind)}");
    lines.Add($"cube.reason={content.Cube.ReasonCode ?? "not_applicable"}");
    if (content.Cube.Definition is { } cubeDefinition)
    {
      AppendSupportReference(lines, "cube.definition", cubeDefinition);
    }
    else
    {
      lines.Add("cube.definition=not_applicable");
    }

    lines.Add($"cube.level={Fact(content.Cube.Level, Integer)}");
    lines.Add($"collectible.kind={ProfileCanonicalCodes.CollectibleKind(content.Collectible.Kind)}");
    if (content.Collectible.Definition is { } collectibleDefinition)
    {
      AppendSupportReference(lines, "collectible.definition", collectibleDefinition);
    }
    else
    {
      lines.Add("collectible.definition=not_applicable");
    }

    lines.Add($"collectible.level={Fact(content.Collectible.Level, Integer)}");
    lines.Add($"collectible.reason={content.Collectible.ReasonCode ?? "not_applicable"}");
    return string.Join('\n', lines);
  }

  public static string ToCanonicalText(SquadRevisionContent content)
  {
    ArgumentNullException.ThrowIfNull(content);
    var lines = new List<string> { SquadContractId };
    AppendBinding(lines, content.DatasetBinding);
    lines.Add($"members.count={Integer(content.Members.Count)}");
    for (var index = 0; index < content.Members.Count; index++)
    {
      var member = content.Members[index];
      var prefix = $"members.{Integer(index)}";
      lines.Add($"{prefix}.slot-index={Integer(member.SlotIndex)}");
      AppendBuildReference(lines, $"{prefix}.build", member.BuildRevision);
    }

    return string.Join('\n', lines);
  }

  public static string ToCanonicalText(ProfileTemplateRevisionContent content)
  {
    ArgumentNullException.ThrowIfNull(content);
    var lines = new List<string> { ProfileTemplateContractId };
    AppendBinding(lines, content.DatasetBinding);
    AppendAccountReference(lines, "account-combat-state", content.AccountCombatStateRevision);
    lines.Add($"builds.count={Integer(content.BuildRevisions.Count)}");
    for (var index = 0; index < content.BuildRevisions.Count; index++)
    {
      AppendBuildReference(lines, $"builds.{Integer(index)}", content.BuildRevisions[index]);
    }

    lines.Add($"active-squad.present={Boolean(content.ActiveSquadRevision is not null)}");
    if (content.ActiveSquadRevision is { } squad)
    {
      AppendSquadReference(lines, "active-squad", squad);
    }

    return string.Join('\n', lines);
  }

  public static Sha256Digest ComputeContentHash(AccountCombatStateRevisionContent content) =>
      Sha256Digest.ComputeUtf8(ToCanonicalText(content));

  public static Sha256Digest ComputeContentHash(CharacterBuildRevisionContent content) =>
      Sha256Digest.ComputeUtf8(ToCanonicalText(content));

  public static Sha256Digest ComputeContentHash(SquadRevisionContent content) =>
      Sha256Digest.ComputeUtf8(ToCanonicalText(content));

  public static Sha256Digest ComputeContentHash(ProfileTemplateRevisionContent content) =>
      Sha256Digest.ComputeUtf8(ToCanonicalText(content));

  private static void AppendBinding(ICollection<string> lines, ProfileDatasetBinding binding)
  {
    AppendCatalogBinding(lines, "catalog.character", binding.CharacterCatalog);
    AppendCatalogBinding(lines, "catalog.combat-support", binding.CombatSupportCatalog);
  }

  private static void AppendCatalogBinding(
      ICollection<string> lines,
      string prefix,
      ProfileCatalogBinding binding)
  {
    lines.Add($"{prefix}.snapshot-uid={Uid(binding.CatalogSnapshotUid)}");
    lines.Add($"{prefix}.dataset-snapshot-uid={Uid(binding.DatasetSnapshotUid)}");
    lines.Add($"{prefix}.manifest-sha256={binding.CatalogManifestSha256}");
  }

  private static void AppendCharacterReference(
      ICollection<string> lines,
      string prefix,
      CharacterDefinitionReference reference)
  {
    lines.Add($"{prefix}.character-uid={Uid(reference.CharacterUid)}");
    lines.Add($"{prefix}.version-uid={Uid(reference.DefinitionVersionUid)}");
    lines.Add($"{prefix}.dataset-snapshot-uid={Uid(reference.DatasetSnapshotUid)}");
    lines.Add($"{prefix}.content-sha256={reference.ContentSha256}");
  }

  private static void AppendSupportReference(
      ICollection<string> lines,
      string prefix,
      CombatSupportDefinitionReference reference)
  {
    lines.Add($"{prefix}.definition-uid={Uid(reference.DefinitionUid)}");
    lines.Add($"{prefix}.version-uid={Uid(reference.DefinitionVersionUid)}");
    lines.Add($"{prefix}.dataset-snapshot-uid={Uid(reference.DatasetSnapshotUid)}");
    lines.Add($"{prefix}.kind={CombatSupportCanonicalCodes.DefinitionKind(reference.Kind)}");
    lines.Add($"{prefix}.content-sha256={reference.ContentSha256}");
  }

  private static void AppendBuildReference(
      ICollection<string> lines,
      string prefix,
      CharacterBuildRevisionReference reference)
  {
    lines.Add($"{prefix}.build-uid={Uid(reference.CharacterBuildUid)}");
    lines.Add($"{prefix}.revision-uid={Uid(reference.RevisionUid)}");
    lines.Add($"{prefix}.character-uid={Uid(reference.CharacterUid)}");
    lines.Add($"{prefix}.content-sha256={reference.ContentSha256}");
    lines.Add($"{prefix}.selection-readiness={ProfileCanonicalCodes.Readiness(reference.Readiness)}");
    lines.Add($"{prefix}.combat-semantics-readiness={ProfileCanonicalCodes.Readiness(reference.CombatSemanticsReadiness)}");
  }

  private static void AppendAccountReference(
      ICollection<string> lines,
      string prefix,
      AccountCombatStateRevisionReference reference)
  {
    lines.Add($"{prefix}.state-uid={Uid(reference.AccountCombatStateUid)}");
    lines.Add($"{prefix}.revision-uid={Uid(reference.RevisionUid)}");
    lines.Add($"{prefix}.content-sha256={reference.ContentSha256}");
    lines.Add($"{prefix}.combat-readiness={ProfileCanonicalCodes.Readiness(reference.Readiness)}");
    lines.Add($"{prefix}.full-fidelity-readiness={ProfileCanonicalCodes.Readiness(reference.FullFidelityReadiness)}");
  }

  private static void AppendSquadReference(
      ICollection<string> lines,
      string prefix,
      SquadRevisionReference reference)
  {
    lines.Add($"{prefix}.squad-uid={Uid(reference.SquadUid)}");
    lines.Add($"{prefix}.revision-uid={Uid(reference.RevisionUid)}");
    lines.Add($"{prefix}.content-sha256={reference.ContentSha256}");
    lines.Add($"{prefix}.selection-readiness={ProfileCanonicalCodes.Readiness(reference.Readiness)}");
    lines.Add($"{prefix}.combat-semantics-readiness={ProfileCanonicalCodes.Readiness(reference.CombatSemanticsReadiness)}");
  }

  private static string Fact<T>(ProfileFact<T> fact, Func<T, string> formatter)
      where T : struct => fact.Status switch
      {
        ProfileFactStatus.Ready => $"ready:{formatter(fact.RequireValue())}",
        ProfileFactStatus.Unresolved => $"unresolved:{fact.ReasonCode}",
        ProfileFactStatus.NotApplicable => "not_applicable",
        _ => throw new ArgumentOutOfRangeException(nameof(fact))
      };

  private static string Exact(CombatSupportExactValue value) =>
      $"{value.UnscaledValue.ToString(CultureInfo.InvariantCulture)}e-{value.DecimalScale.ToString(CultureInfo.InvariantCulture)}";

  private static string Integer(int value) => value.ToString(CultureInfo.InvariantCulture);

  private static string Long(long value) => value.ToString(CultureInfo.InvariantCulture);

  private static string Boolean(bool value) => value ? "true" : "false";

  private static string Uid(EntityUid value) => value.ToString();
}

public static class LocalSessionCanonicalizer
{
  public const string ContractId = "nll/local-session/v1";

  public static string ToCanonicalText(LocalSession session)
  {
    ArgumentNullException.ThrowIfNull(session);
    return string.Join(
        '\n',
        ContractId,
        $"session-uid={session.LocalSessionUid}",
        $"account-uid={session.LocalAccountUid}",
        $"issued-at-utc={session.IssuedAtUtc.ToString("O", CultureInfo.InvariantCulture)}",
        $"expires-at-utc={session.ExpiresAtUtc.ToString("O", CultureInfo.InvariantCulture)}",
        $"status={ProfileCanonicalCodes.LocalSessionStatus(session.Status)}",
        $"status-recorded-at-utc={session.StatusRecordedAtUtc.ToString("O", CultureInfo.InvariantCulture)}");
  }

  public static Sha256Digest ComputeHash(LocalSession session) => Sha256Digest.ComputeUtf8(ToCanonicalText(session));
}

public static class LocalAccountCanonicalizer
{
  public const string ContractId = "nll/local-account/v1";

  public static string ToCanonicalText(LocalAccount account)
  {
    ArgumentNullException.ThrowIfNull(account);
    return string.Join(
        '\n',
        ContractId,
        $"account-uid={account.LocalAccountUid}",
        $"created-at-utc={account.CreatedAtUtc.ToString("O", CultureInfo.InvariantCulture)}");
  }

  public static Sha256Digest ComputeHash(LocalAccount account) =>
      Sha256Digest.ComputeUtf8(ToCanonicalText(account));
}

public static class ProfileCanonicalCodes
{
  public static string ValidationMode(ProfileValidationMode value) => value switch
  {
    ProfileValidationMode.Research => "research",
    ProfileValidationMode.GameLegal => "game-legal",
    _ => throw new ArgumentOutOfRangeException(nameof(value))
  };

  public static string MaterializationPolicy(CharacterBuildMaterializationPolicy value) => value switch
  {
    CharacterBuildMaterializationPolicy.ExplicitV1 => "explicit/v1",
    CharacterBuildMaterializationPolicy.CombatMaxV1 => CombatMaxV1ProfileResolver.PolicyId,
    _ => throw new ArgumentOutOfRangeException(nameof(value))
  };

  public static string CollectibleKind(CharacterCollectibleSelectionKind value) => value switch
  {
    CharacterCollectibleSelectionKind.Detached => "detached",
    CharacterCollectibleSelectionKind.GenericCollection => "generic-collection",
    CharacterCollectibleSelectionKind.Favorite => "favorite",
    CharacterCollectibleSelectionKind.NotApplicable => "not-applicable",
    CharacterCollectibleSelectionKind.Unresolved => "unresolved",
    _ => throw new ArgumentOutOfRangeException(nameof(value))
  };

  public static string AttachmentKind(ProfileAttachmentKind value) => value switch
  {
    ProfileAttachmentKind.Attached => "attached",
    ProfileAttachmentKind.Detached => "detached",
    ProfileAttachmentKind.Unresolved => "unresolved",
    _ => throw new ArgumentOutOfRangeException(nameof(value))
  };

  public static string LocalSessionStatus(LocalSessionStatus value) => value switch
  {
    Profile.LocalSessionStatus.Active => "active",
    Profile.LocalSessionStatus.Expired => "expired",
    Profile.LocalSessionStatus.Revoked => "revoked",
    _ => throw new ArgumentOutOfRangeException(nameof(value))
  };

  public static string Readiness(ProfileReadiness value) => value switch
  {
    ProfileReadiness.Ready => "ready",
    ProfileReadiness.Unresolved => "unresolved",
    ProfileReadiness.Invalid => "invalid",
    _ => throw new ArgumentOutOfRangeException(nameof(value))
  };

  public static string EquipmentSlot(CombatSupportEquipmentSlot value) =>
      CombatSupportCanonicalCodes.EquipmentSlot(value);

  public static string ConsoleCoordinate(CombatSupportConsoleCoordinate value) =>
      CombatSupportCanonicalCodes.ConsoleCoordinate(value);

  public static string OverloadOptionType(CombatSupportOverloadOptionType value) =>
      CombatSupportCanonicalCodes.OverloadOptionType(value);

  public static string ValueUnit(CombatSupportValueUnit value) =>
      CombatSupportCanonicalCodes.ValueUnit(value);
}
