using System.Globalization;
using System.Text.RegularExpressions;
using EpinelPS.Data;

internal static class CubePresentation
{
  internal static object Build(GameData data, ItemHarmonyCubeRecord cube, string uid)
  {
    if (!Guid.TryParse(uid, out _) || cube.HarmonycubeSkillGroup.Count == 0)
      throw new InvalidOperationException("phase_d_cube_presentation_identity_invalid");
    var levels = data.ItemHarmonyCubeLevelTable.Values
        .Where(row => row.LevelEnhanceId == cube.LevelEnhanceId && row.Level is >= 1 and <= 15)
        .OrderBy(row => row.Level).Select(row =>
        {
          if (row.SkillLevels.Count == 0 || row.SkillLevels[0].SkillLevel < 1)
            throw new InvalidOperationException("phase_d_cube_presentation_skill_unresolved");
          var skill = data.skillInfoTable.Values.Single(item =>
              item.GroupId == cube.HarmonycubeSkillGroup[0].SkillGroupId &&
              item.SkillLevel == row.SkillLevels[0].SkillLevel);
          return new
          {
            level = row.Level,
            primaryEffect = FormatEffect(LocaleNameResolver.Resolve(skill.DescriptionLocalkey, "ko"),
                skill.DescriptionValueList.Select(value => value.DescriptionValue ?? "").ToArray()),
            primarySkillName = LocaleNameResolver.Resolve(skill.NameLocalkey, "ko"),
            primarySkillLevel = row.SkillLevels[0].SkillLevel
          };
        }).ToArray();
    if (levels.Length != 15 || !levels.Select(row => row.level).SequenceEqual(Enumerable.Range(1, 15)))
      throw new InvalidOperationException("phase_d_cube_presentation_levels_incomplete");
    return new
    {
      definitionUid = uid, kindCode = "cube",
      displayName = LocaleNameResolver.Resolve(cube.NameLocalkey, "ko"),
      displayOrder = cube.Order,
      imagePath = $"/editor/assets/cubes/{uid}.webp",
      weaponCode = (string?)null, favoriteCharacterUid = (string?)null,
      stats = Array.Empty<object>(), levels
    };
  }

  internal static string FormatEffect(string template, IReadOnlyList<string> values)
  {
    var text = Regex.Replace(template, @"\{description_value_(\d{2})\}", match =>
    {
      var index = int.Parse(match.Groups[1].Value, CultureInfo.InvariantCulture) - 1;
      if (index < 0 || index >= values.Count || string.IsNullOrWhiteSpace(values[index]))
        throw new InvalidOperationException("phase_d_cube_presentation_effect_unresolved");
      return values[index];
    });
    text = Regex.Replace(text, "<[^>]*>", "").Replace("■ 전투 시작 시\n", "", StringComparison.Ordinal)
        .Replace("■ ", "", StringComparison.Ordinal).Replace("[", "", StringComparison.Ordinal)
        .Replace("]", "", StringComparison.Ordinal).Trim();
    if (string.IsNullOrWhiteSpace(text) || text.Contains('{') || text.StartsWith("Locale_", StringComparison.Ordinal))
      throw new InvalidOperationException("phase_d_cube_presentation_effect_unresolved");
    return text;
  }
}
