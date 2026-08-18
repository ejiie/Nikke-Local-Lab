using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;

namespace NikkeLocalLab.Raid.UnitTests;

public enum SyntheticEvidenceMutation
{
  None,
  OldV1Shape,
  BehaviorTierWithoutBehavior,
  RuntimeTierWithoutRuntime,
  RuntimeRelationMismatch,
  ObjectLengthMismatch,
  ObjectRoleMismatch,
  UnreferencedObject,
  DuplicateBundleReference,
  InvalidLocalBuildLabel,
}

internal sealed record SyntheticRaidArchiveOptions(
    bool ReverseStaticEntries = false,
    bool ReverseCompatibilityEntries = false,
    int? AmbiguousBossSeason = null,
    bool OmitS40Evidence = false,
    bool IncludeNormalPresets = true,
    bool AddUnknownElementRow = false,
    int? UnknownElementSeason = null,
    int? UnknownPartTypeSeason = null,
    int? BrokenLinkedPartSeason = null,
    int? StaticBindingMismatchSeason = null,
    RaidCompatibilityTier S40Tier = RaidCompatibilityTier.BehaviorExact,
    SyntheticEvidenceMutation EvidenceMutation = SyntheticEvidenceMutation.None);

internal sealed record SyntheticRaidArchives(MemoryStream StaticData, MemoryStream Compatibility) : IDisposable
{
  public void Dispose()
  {
    StaticData.Dispose();
    Compatibility.Dispose();
  }
}

internal static class SyntheticChallengeRaidArchives
{
  private const string EvidenceContractId = "nll/challenge-evidence-package/v2";
  private const string EvidenceManifestName = "ChallengeEvidencePackage.v2.mpk";
  private static readonly DateTimeOffset FixedZipTimestamp =
      new(2026, 1, 1, 0, 0, 0, TimeSpan.Zero);

  public static readonly int[] SupportedSeasons = [7, 13, 26, 29, 34, 40];
  public static readonly int[] AllSeasons = [7, 13, 14, 26, 29, 34, 39, 40];

  public static SyntheticRaidArchives Create(SyntheticRaidArchiveOptions? options = null)
  {
    options ??= new SyntheticRaidArchiveOptions();
    var staticEntries = new List<(string Name, byte[] Bytes)>
    {
      ("SoloRaidManagerTable.mpk", Managers()),
      ("SoloRaidPresetTable.mpk", Presets(options.IncludeNormalPresets)),
      ("WaveData.GroupDict.csv", Encoding.UTF8.GetBytes(WaveGroups())),
      ("WaveDataTable.wave_synthetic.mpk", Waves(options.AmbiguousBossSeason)),
      ("MonsterTable.mpk", Monsters(options)),
      ("ElementTable.mpk", Elements(options)),
      ("MonsterPartsTable.mpk", Parts(options))
    };
    if (options.ReverseStaticEntries)
    {
      staticEntries.Reverse();
    }

    var staticArchive = Zip(staticEntries);
    var staticArchiveSha256 = Digest(staticArchive);
    var compatibilityArchive = BuildCompatibilityArchive(staticArchiveSha256, options);
    return new SyntheticRaidArchives(staticArchive, compatibilityArchive);
  }

  public static MemoryStream CreateEmptyCompatibilityArchive() =>
      Zip([(EvidenceManifestName, EvidenceManifest(Array.Empty<EvidenceRow>()))]);

  public static MemoryStream CreateBehaviorExactCompatibility(
      Stream staticData,
      Stream behaviorJson,
      Stream behaviorBundle,
      Stream spotMonsterBundle)
  {
    var staticDigest = Digest(staticData);
    var behavior = ReadAllBytes(behaviorJson);
    var behaviorAsset = ReadAllBytes(behaviorBundle);
    var spotAsset = ReadAllBytes(spotMonsterBundle);
    var objects = new List<EvidenceObjectPayload>();
    var row = BehaviorExactRow(staticDigest, behavior, behaviorAsset, spotAsset, objects);
    var entries = new List<(string Name, byte[] Bytes)>
    {
      (EvidenceManifestName, EvidenceManifest([row]))
    };
    entries.AddRange(objects.Select(ObjectEntry));
    return Zip(entries);
  }

  private static MemoryStream BuildCompatibilityArchive(
      string staticArchiveSha256,
      SyntheticRaidArchiveOptions options)
  {
    if (options.EvidenceMutation == SyntheticEvidenceMutation.OldV1Shape)
    {
      return Zip([(EvidenceManifestName, OldV1Manifest())]);
    }

    var rows = new List<EvidenceRow>();
    var objects = new List<EvidenceObjectPayload>();
    if (!options.OmitS40Evidence)
    {
      var behavior = Encoding.UTF8.GetBytes("{\"synthetic\":\"behavior-40\"}");
      var behaviorBundle = Encoding.UTF8.GetBytes("synthetic-behavior-bundle-40");
      var spotBundle = Encoding.UTF8.GetBytes("synthetic-spot-monster-bundle-40");
      var row = options.S40Tier is RaidCompatibilityTier.AssetExactRuntimeCurrent or
          RaidCompatibilityTier.HistoricalRuntimeExact ||
          options.EvidenceMutation is SyntheticEvidenceMutation.RuntimeRelationMismatch or
              SyntheticEvidenceMutation.InvalidLocalBuildLabel
          ? RuntimeExactRow(
              staticArchiveSha256,
              options.S40Tier == RaidCompatibilityTier.HistoricalRuntimeExact
                  ? RaidCompatibilityTier.HistoricalRuntimeExact
                  : RaidCompatibilityTier.AssetExactRuntimeCurrent,
              behavior,
              behaviorBundle,
              spotBundle,
              objects)
          : BehaviorExactRow(staticArchiveSha256, behavior, behaviorBundle, spotBundle, objects);

      row = ApplyMutation(row, options, objects);
      if (options.StaticBindingMismatchSeason == 40)
      {
        row = row with { StaticArchiveSha256 = Digest(Encoding.UTF8.GetBytes("different-static-archive")) };
      }

      rows.Add(row);
    }

    var entries = new List<(string Name, byte[] Bytes)>
    {
      (EvidenceManifestName, EvidenceManifest(rows))
    };
    entries.AddRange(objects.Select(ObjectEntry));
    if (options.EvidenceMutation == SyntheticEvidenceMutation.UnreferencedObject)
    {
      var bytes = Encoding.UTF8.GetBytes("unreferenced-object");
      entries.Add(($"objects/bundle/{Digest(bytes)}.bin", bytes));
    }

    if (options.ReverseCompatibilityEntries)
    {
      entries.Reverse();
    }

    return Zip(entries);
  }

  private static EvidenceRow ApplyMutation(
      EvidenceRow row,
      SyntheticRaidArchiveOptions options,
      IList<EvidenceObjectPayload> objects)
  {
    switch (options.EvidenceMutation)
    {
      case SyntheticEvidenceMutation.None:
      case SyntheticEvidenceMutation.UnreferencedObject:
        return row;
      case SyntheticEvidenceMutation.BehaviorTierWithoutBehavior:
        return row with
        {
          Tier = "behavior_exact",
          Behavior = null,
          Runtime = null,
          RuntimeRelation = "not_evaluated",
          Timelines = Array.Empty<TimelineReference>(),
          ClockClaims = UnresolvedClockClaims(),
          Scheduler = UnresolvedScheduler()
        };
      case SyntheticEvidenceMutation.RuntimeTierWithoutRuntime:
        return row with
        {
          Tier = "asset_exact_runtime_current",
          RuntimeRelation = "current_runtime_match",
          Runtime = null,
          Timelines = Array.Empty<TimelineReference>(),
          ClockClaims = UnresolvedClockClaims(),
          Scheduler = UnresolvedScheduler()
        };
      case SyntheticEvidenceMutation.RuntimeRelationMismatch:
        return row with { RuntimeRelation = "historical_runtime_match" };
      case SyntheticEvidenceMutation.ObjectLengthMismatch:
        return row with
        {
          Behavior = row.Behavior! with { ByteLength = row.Behavior.ByteLength + 1 }
        };
      case SyntheticEvidenceMutation.ObjectRoleMismatch:
        {
          var behaviorIndex = objects.ToList().FindIndex(static value => value.Kind == "behavior");
          objects[behaviorIndex] = objects[behaviorIndex] with { Kind = "bundle" };
          return row;
        }
      case SyntheticEvidenceMutation.DuplicateBundleReference:
        return row with { Bundles = row.Bundles.Concat([row.Bundles[0]]).ToArray() };
      case SyntheticEvidenceMutation.InvalidLocalBuildLabel:
        return row with { Runtime = row.Runtime! with { LocalBuildLabel = "C:/private/raw/999999" } };
      default:
        throw new ArgumentOutOfRangeException(nameof(options));
    }
  }

  private static EvidenceRow BehaviorExactRow(
      string staticArchiveSha256,
      byte[] behavior,
      byte[] behaviorBundle,
      byte[] spotBundle,
      IList<EvidenceObjectPayload> objects)
  {
    var behaviorReference = AddObject(objects, "behavior", behavior);
    var behaviorBundleReference = AddObject(objects, "bundle", behaviorBundle);
    var spotBundleReference = AddObject(objects, "bundle", spotBundle);
    return new EvidenceRow(
        SeasonNumber: 40,
        StaticArchiveSha256: staticArchiveSha256,
        Tier: "behavior_exact",
        RuntimeRelation: "not_evaluated",
        Behavior: behaviorReference,
        Timelines: Array.Empty<TimelineReference>(),
        Bundles:
        [
          new BundleReference(
              behaviorBundleReference.Sha256,
              behaviorBundleReference.ByteLength,
              ["behavior"]),
          new BundleReference(
              spotBundleReference.Sha256,
              spotBundleReference.ByteLength,
              ["model", "timeline", "animation"])
        ],
        Runtime: null,
        ClockClaims: UnresolvedClockClaims(),
        Scheduler: UnresolvedScheduler(),
        WarningCodes: ["timeline_unresolved", "runtime_not_evaluated"]);
  }

  private static EvidenceRow RuntimeExactRow(
      string staticArchiveSha256,
      RaidCompatibilityTier tier,
      byte[] behavior,
      byte[] behaviorBundle,
      byte[] spotBundle,
      IList<EvidenceObjectPayload> objects)
  {
    var behaviorReference = AddObject(objects, "behavior", behavior);
    var behaviorBundleReference = AddObject(objects, "bundle", behaviorBundle);
    var spotBundleReference = AddObject(objects, "bundle", spotBundle);
    var timelineReference = AddObject(
        objects,
        "timeline",
        Encoding.UTF8.GetBytes("synthetic-runtime-exact-timeline"));
    var runtimeReference = AddObject(
        objects,
        "runtime",
        Encoding.UTF8.GetBytes("synthetic-runtime-binary"));
    var runtimeRelation = tier == RaidCompatibilityTier.HistoricalRuntimeExact
        ? "historical_runtime_match"
        : "current_runtime_match";
    return new EvidenceRow(
        SeasonNumber: 40,
        StaticArchiveSha256: staticArchiveSha256,
        Tier: tier == RaidCompatibilityTier.HistoricalRuntimeExact
            ? "historical_runtime_exact"
            : "asset_exact_runtime_current",
        RuntimeRelation: runtimeRelation,
        Behavior: behaviorReference,
        Timelines:
        [
          new TimelineReference(
              timelineReference.Sha256,
              timelineReference.ByteLength,
              ["behavior_tick", "render_frame"])
        ],
        Bundles:
        [
          new BundleReference(
              behaviorBundleReference.Sha256,
              behaviorBundleReference.ByteLength,
              ["behavior"]),
          new BundleReference(
              spotBundleReference.Sha256,
              spotBundleReference.ByteLength,
              ["model", "timeline", "animation"])
        ],
        Runtime: new RuntimeReference(
            runtimeReference.Sha256,
            runtimeReference.ByteLength,
            tier == RaidCompatibilityTier.HistoricalRuntimeExact
                ? "synthetic-historical"
                : "synthetic-current"),
        ClockClaims:
        [
          ResolvedClock("behavior_tick", behaviorReference.Sha256),
          ResolvedClock("render_frame", timelineReference.Sha256),
          ResolvedClock("fixed_update", runtimeReference.Sha256),
          ResolvedClock("wall_clock", runtimeReference.Sha256)
        ],
        Scheduler: new SchedulerClaim(
            "static_analysis",
            ["behavior_tick", "render_frame", "fixed_update", "wall_clock"],
            [timelineReference.Sha256, runtimeReference.Sha256],
            null),
        WarningCodes: Array.Empty<string>());
  }

  private static ClockClaim ResolvedClock(string basis, string digest) =>
      new(basis, "static_analysis", [digest], null);

  private static IReadOnlyList<ClockClaim> UnresolvedClockClaims() =>
  [
    new("behavior_tick", "unresolved", Array.Empty<string>(), "not_evaluated"),
    new("render_frame", "unresolved", Array.Empty<string>(), "not_evaluated"),
    new("fixed_update", "unresolved", Array.Empty<string>(), "not_evaluated"),
    new("wall_clock", "unresolved", Array.Empty<string>(), "not_evaluated")
  ];

  private static SchedulerClaim UnresolvedScheduler() =>
      new(
          "unresolved",
          ["behavior_tick", "render_frame", "fixed_update", "wall_clock"],
          Array.Empty<string>(),
          "not_evaluated");

  private static ArtifactReference AddObject(
      IList<EvidenceObjectPayload> objects,
      string kind,
      byte[] bytes)
  {
    var reference = new ArtifactReference(Digest(bytes), bytes.LongLength);
    objects.Add(new EvidenceObjectPayload(kind, reference.Sha256, bytes));
    return reference;
  }

  private static (string Name, byte[] Bytes) ObjectEntry(EvidenceObjectPayload payload) =>
      ($"objects/{payload.Kind}/{payload.Sha256}.bin", payload.Bytes);

  private static byte[] EvidenceManifest(IReadOnlyCollection<EvidenceRow> rows)
  {
    using var stream = new MemoryStream();
    using var writer = new BinaryWriter(stream, Encoding.UTF8, leaveOpen: true);
    Object(writer, 2);
    WriteString(writer, EvidenceContractId);
    writer.Write(rows.Count);
    foreach (var row in rows)
    {
      Object(writer, 12);
      writer.Write(row.SeasonNumber);
      WriteString(writer, row.StaticArchiveSha256);
      WriteString(writer, row.Tier);
      WriteString(writer, row.RuntimeRelation);
      WriteString(writer, row.Behavior?.Sha256);
      writer.Write(row.Behavior?.ByteLength ?? 0);

      writer.Write(row.Timelines.Count);
      foreach (var timeline in row.Timelines)
      {
        Object(writer, 3);
        WriteString(writer, timeline.Sha256);
        writer.Write(timeline.ByteLength);
        WriteStringArray(writer, timeline.ClockBases);
      }

      writer.Write(row.Bundles.Count);
      foreach (var bundle in row.Bundles)
      {
        Object(writer, 3);
        WriteString(writer, bundle.Sha256);
        writer.Write(bundle.ByteLength);
        WriteStringArray(writer, bundle.Roles);
      }

      Object(writer, 3);
      WriteString(writer, row.Runtime?.Sha256);
      writer.Write(row.Runtime?.ByteLength ?? 0);
      WriteString(writer, row.Runtime?.LocalBuildLabel);

      writer.Write(row.ClockClaims.Count);
      foreach (var claim in row.ClockClaims)
      {
        Object(writer, 4);
        WriteString(writer, claim.Basis);
        WriteString(writer, claim.Resolution);
        WriteStringArray(writer, claim.EvidenceObjectSha256);
        WriteString(writer, claim.ReasonCode);
      }

      Object(writer, 4);
      WriteString(writer, row.Scheduler.Resolution);
      WriteStringArray(writer, row.Scheduler.RelatedClockBases);
      WriteStringArray(writer, row.Scheduler.EvidenceObjectSha256);
      WriteString(writer, row.Scheduler.ReasonCode);
      WriteStringArray(writer, row.WarningCodes);
    }

    return stream.ToArray();
  }

  private static byte[] OldV1Manifest()
  {
    using var stream = new MemoryStream();
    using var writer = new BinaryWriter(stream, Encoding.UTF8, leaveOpen: true);
    writer.Write(0);
    return stream.ToArray();
  }

  private static byte[] Managers() => Table(AllSeasons, static (writer, season) =>
  {
    Object(writer, 3);
    writer.Write(100_000 + season);
    writer.Write(10_000 + season);
    writer.Write(season);
  });

  private static byte[] Presets(bool includeNormal)
  {
    var rows = AllSeasons.SelectMany(season => includeNormal
        ? new[] { (Season: season, Difficulty: 1), (Season: season, Difficulty: 2) }
        : new[] { (Season: season, Difficulty: 2) }).ToArray();
    return Table(rows, static (writer, row) =>
    {
      Object(writer, 19);
      writer.Write(200_000 + (row.Season * 10) + row.Difficulty);
      writer.Write(10_000 + row.Season);
      writer.Write(row.Difficulty);
      writer.Write(0);
      writer.Write(400);
      writer.Write(0);
      writer.Write(row.Difficulty == 2 ? 8 : 1);
      writer.Write(row.Difficulty == 2 ? Stage(row.Season) : Stage(row.Season) + 1);
      writer.Write(400);
      writer.Write(1);
      writer.Write(400);
      writer.Write(400);
      writer.Write(true);
      WriteString(writer, "synthetic-name");
      WriteString(writer, "synthetic-description");
      WriteString(writer, "synthetic-small-image");
      WriteString(writer, "synthetic-image");
      writer.Write(0);
      writer.Write(0);
    });
  }

  private static byte[] Waves(int? ambiguousSeason) => Table(AllSeasons, (writer, season) =>
  {
    var boss = Boss(season);
    var ambiguous = season == ambiguousSeason;
    Object(writer, 20);
    writer.Write(Stage(season));
    WriteString(writer, "wave_synthetic");
    writer.Write(17);
    writer.Write(0);
    writer.Write(180);
    WriteString(writer, string.Empty);
    writer.Write(ambiguous ? 2 : 1);
    writer.Write(false);
    writer.Write(false);
    WriteString(writer, string.Empty);
    WriteString(writer, string.Empty);
    WriteString(writer, string.Empty);
    writer.Write(0);
    writer.Write(0);
    WriteString(writer, string.Empty);
    WriteInt64Array(writer, ambiguous ? [boss, boss + 500] : [boss]);
    writer.Write(1);
    Object(writer, 3);
    WriteString(writer, "synthetic-path");
    writer.Write(-1);
    writer.Write(ambiguous ? 2 : 1);
    WriteWaveMonster(writer, boss);
    if (ambiguous)
    {
      WriteWaveMonster(writer, boss + 500);
    }

    writer.Write(0);
    writer.Write(0);
    writer.Write(1);
  });

  private static byte[] Monsters(SyntheticRaidArchiveOptions options) => Table(AllSeasons, (writer, season) =>
  {
    Object(writer, 33);
    writer.Write(Boss(season));
    WriteInt32Array(
        writer,
        [season == options.UnknownElementSeason ? 600_001 : season == 40 ? 300_001 : 400_001]);
    writer.Write(Model(season));
    writer.Write(0);
    WriteString(writer, "synthetic-name");
    WriteString(writer, "synthetic-appearance");
    WriteString(writer, "synthetic-description");
    writer.Write(false);
    for (var field = 0; field < 11; field++)
    {
      writer.Write(field == 0 ? 10_000 : 0);
    }

    WriteString(writer, Spot(season));
    WriteString(writer, Spot(season));
    WriteString(writer, Spot(season));
    for (var field = 0; field < 8; field++)
    {
      writer.Write(0);
    }

    writer.Write(0);
    writer.Write(3);
    for (var skill = 0; skill < 3; skill++)
    {
      Object(writer, 3);
      writer.Write(700_000 + (season * 10) + skill);
      WriteInt32Array(writer, [skill]);
      WriteInt32Array(writer, [skill + 1]);
    }

    writer.Write(230_000);
  });

  private static byte[] Elements(SyntheticRaidArchiveOptions options)
  {
    var rows = new List<(int Id, int AttackType, int Weak)>
    {
      (100_001, 4, 200_001),
      (200_001, 5, 400_001),
      (300_001, 6, 100_001),
      (400_001, 8, 500_001),
      (500_001, 7, 300_001)
    };
    if (options.AddUnknownElementRow || options.UnknownElementSeason.HasValue)
    {
      rows.Add((600_001, 999, 100_001));
    }

    return Table(rows, static (writer, row) =>
    {
      Object(writer, 8);
      writer.Write(row.Id);
      writer.Write(row.AttackType);
      writer.Write(5_000_000 + row.AttackType);
      writer.Write(row.Weak);
      WriteString(writer, "synthetic-element-name");
      WriteString(writer, "synthetic-element-code");
      WriteString(writer, "synthetic-element-description");
      WriteString(writer, "synthetic-element-icon");
    });
  }

  private static byte[] Parts(SyntheticRaidArchiveOptions options) => Table(
      AllSeasons.SelectMany(season => new[]
      {
        (Season: season, Type: 1, Main: true),
        (Season: season, Type: 2, Main: false)
      }).ToArray(),
      (writer, row) =>
      {
        Object(writer, 23);
        writer.Write((row.Season * 100) + row.Type);
        writer.Write(Model(row.Season));
        WriteString(writer, "synthetic-part");
        writer.Write(row.Main ? 10_000 : 5_000);
        writer.Write(row.Main ? 10_000 : 2_500);
        writer.Write(10_000);
        writer.Write(false);
        writer.Write(false);
        writer.Write(0);
        writer.Write(true);
        writer.Write(
            row.Season == options.BrokenLinkedPartSeason && row.Type == 1
                ? 999_999_999
                : (row.Season * 100) + 1);
        WriteStringArray(writer, ["synthetic-weapon-object"]);
        WriteInt32Array(writer, [row.Type]);
        writer.Write(row.Season == options.UnknownPartTypeSeason && row.Type == 2 ? 999 : row.Type);
        WriteStringArray(writer, ["synthetic-part-object"]);
        writer.Write(10_000);
        writer.Write(10_000);
        writer.Write(10_000);
        writer.Write(10_000);
        WriteString(writer, string.Empty);
        writer.Write(0);
        writer.Write(row.Main);
        writer.Write(true);
      });

  private static string WaveGroups() => string.Join(
      '\n',
      new[] { "stage_id,group_id" }
          .Concat(AllSeasons.Select(season => $"{Stage(season)},wave_synthetic"))) + "\n";

  private static byte[] Table<T>(IReadOnlyCollection<T> rows, Action<BinaryWriter, T> write)
  {
    using var stream = new MemoryStream();
    using var writer = new BinaryWriter(stream, Encoding.UTF8, leaveOpen: true);
    writer.Write(rows.Count);
    foreach (var row in rows)
    {
      write(writer, row);
    }

    return stream.ToArray();
  }

  private static byte[] Table<T>(IEnumerable<T> rows, Action<BinaryWriter, T> write) =>
      Table(rows.ToArray(), write);

  private static void Object(BinaryWriter writer, byte memberCount) => writer.Write(memberCount);

  private static void WriteWaveMonster(BinaryWriter writer, long monster)
  {
    Object(writer, 2);
    writer.Write(monster);
    writer.Write(1);
  }

  private static void WriteString(BinaryWriter writer, string? value)
  {
    if (value is null)
    {
      writer.Write(-1);
      return;
    }

    if (value.Length == 0)
    {
      writer.Write(0);
      return;
    }

    var bytes = Encoding.UTF8.GetBytes(value);
    writer.Write(~bytes.Length);
    writer.Write(value.Length);
    writer.Write(bytes);
  }

  private static void WriteInt32Array(BinaryWriter writer, IReadOnlyList<int> values)
  {
    writer.Write(values.Count);
    foreach (var value in values)
    {
      writer.Write(value);
    }
  }

  private static void WriteInt64Array(BinaryWriter writer, IReadOnlyList<long> values)
  {
    writer.Write(values.Count);
    foreach (var value in values)
    {
      writer.Write(value);
    }
  }

  private static void WriteStringArray(BinaryWriter writer, IReadOnlyList<string> values)
  {
    writer.Write(values.Count);
    foreach (var value in values)
    {
      WriteString(writer, value);
    }
  }

  private static MemoryStream Zip(IEnumerable<(string Name, byte[] Bytes)> payloads)
  {
    var stream = new MemoryStream();
    using (var archive = new ZipArchive(stream, ZipArchiveMode.Create, leaveOpen: true))
    {
      foreach (var payload in payloads)
      {
        var entry = archive.CreateEntry(payload.Name, CompressionLevel.Optimal);
        entry.LastWriteTime = FixedZipTimestamp;
        using var target = entry.Open();
        target.Write(payload.Bytes);
      }
    }

    stream.Position = 0;
    return stream;
  }

  private static byte[] ReadAllBytes(Stream source)
  {
    ArgumentNullException.ThrowIfNull(source);
    if (!source.CanRead || !source.CanSeek || source.Length is <= 0 or > int.MaxValue)
    {
      throw new ArgumentException("A retained evidence stream must be non-empty, readable, and seekable.", nameof(source));
    }

    var originalPosition = source.Position;
    try
    {
      source.Position = 0;
      var result = new byte[checked((int)source.Length)];
      source.ReadExactly(result);
      return result;
    }
    finally
    {
      source.Position = originalPosition;
    }
  }

  private static string Digest(Stream source)
  {
    ArgumentNullException.ThrowIfNull(source);
    if (!source.CanRead || !source.CanSeek)
    {
      throw new ArgumentException("A digest source must be readable and seekable.", nameof(source));
    }

    var originalPosition = source.Position;
    try
    {
      source.Position = 0;
      return Convert.ToHexString(SHA256.HashData(source)).ToLowerInvariant();
    }
    finally
    {
      source.Position = originalPosition;
    }
  }

  private static string Digest(byte[] bytes) =>
      Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();

  private static int Stage(int season) => 670_000_000 + season;

  private static long Boss(int season) => 9_000_000L + season;

  private static int Model(int season) => 80_000 + season;

  private static string Spot(int season) => $"bt_synthetic_{season}";

  private sealed record ArtifactReference(string Sha256, long ByteLength);

  private sealed record TimelineReference(
      string Sha256,
      long ByteLength,
      IReadOnlyList<string> ClockBases);

  private sealed record BundleReference(
      string Sha256,
      long ByteLength,
      IReadOnlyList<string> Roles);

  private sealed record RuntimeReference(
      string Sha256,
      long ByteLength,
      string LocalBuildLabel);

  private sealed record ClockClaim(
      string Basis,
      string Resolution,
      IReadOnlyList<string> EvidenceObjectSha256,
      string? ReasonCode);

  private sealed record SchedulerClaim(
      string Resolution,
      IReadOnlyList<string> RelatedClockBases,
      IReadOnlyList<string> EvidenceObjectSha256,
      string? ReasonCode);

  private sealed record EvidenceRow(
      int SeasonNumber,
      string StaticArchiveSha256,
      string Tier,
      string RuntimeRelation,
      ArtifactReference? Behavior,
      IReadOnlyList<TimelineReference> Timelines,
      IReadOnlyList<BundleReference> Bundles,
      RuntimeReference? Runtime,
      IReadOnlyList<ClockClaim> ClockClaims,
      SchedulerClaim Scheduler,
      IReadOnlyList<string> WarningCodes);

  private sealed record EvidenceObjectPayload(
      string Kind,
      string Sha256,
      byte[] Bytes);
}
