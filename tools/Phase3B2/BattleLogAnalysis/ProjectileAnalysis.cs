using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;

namespace NikkeLocalLab.BattleLog;

public sealed record BattleLogCharacter(int Ordinal, long StaticId, long? TabDamage);
public sealed record ProjectileCharacter(int Ordinal, long ProjectileDamage, long ExcludedDamage);
public sealed record ProjectileAnalysis(string Status, string LogSha256, string Version,
    IReadOnlyList<ProjectileCharacter> Characters)
{
  public const string CurrentVersion = "projectile-damage/v1";
}

// Source identifiers exist only in the decoder's private input. Output uses observation ordinals.
public static class BattleLogProjectileDecoder
{
  public const int MaximumRawBytes = 8 * 1024 * 1024;
  private const int MaximumExpandedBytes = 32 * 1024 * 1024;
  private const string SupportedSchema = "4dfe46bb75c87bcb5d88ac2aaff046f917a08c633587cd64411dd97c4ebbf965";
  private sealed record Schema(string Name, string[] Fields, int Extra);
  internal sealed record Entry(string Name, Dictionary<string, long> Values, int Index, int Tick, long Time);

  public static ProjectileAnalysis Analyze(byte[] raw, IReadOnlyList<BattleLogCharacter> characters, long? reportedTotal)
  {
    var hash = Convert.ToHexString(SHA256.HashData(raw)).ToLowerInvariant();
    ProjectileAnalysis Fail(string status) => new(status, hash, ProjectileAnalysis.CurrentVersion, []);
    if (raw.Length == 0) return Fail("missing");
    if (raw.Length > MaximumRawBytes) return Fail("oversize");
    try
    {
      if (characters.Count == 0 || characters.Any(c => c.TabDamage is null or < 0) || reportedTotal is null or < 0)
        return Fail("statistics_missing");
      if (characters.Select(c => c.StaticId).Distinct().Count() != characters.Count ||
          characters.Select(c => c.Ordinal).Distinct().Count() != characters.Count) return Fail("identity_ambiguous");
      var entries = Decode(raw);
      var entities = entries.Where(e => e.Name == "Entity").Select(e => e.Values).ToArray();
      var shapes = entries.Where(e => e.Name == "HurtShape").Select(e => e.Values).ToArray();
      var owners = new Dictionary<long, long>();
      foreach (var spawn in entries.Where(e => e.Name == "ProjectileSpawn"))
      {
        var v = spawn.Values;
        if (owners.TryGetValue(v["projectile"], out var old) && old != v["owner"]) return Fail("identity_ambiguous");
        owners[v["projectile"]] = v["owner"];
      }
      Dictionary<string, long> Entity(long index) => index >= 0 && index < entities.Length
          ? entities[(int)index] : throw new InvalidDataException("reference_invalid");
      var byEntity = new Dictionary<long, int>();
      foreach (var c in characters)
      {
        var matches = Enumerable.Range(0, entities.Length).Where(i =>
            entities[i]["kind"] == 1 && entities[i]["staticId"] == c.StaticId).ToArray();
        if (matches.Length != 1) return Fail("identity_unresolved");
        byEntity[matches[0]] = c.Ordinal;
      }
      long Root(long entity)
      {
        var visited = new HashSet<long>();
        while (owners.TryGetValue(entity, out var owner))
        {
          if (!visited.Add(entity)) throw new InvalidDataException("owner_cycle");
          entity = owner;
        }
        _ = Entity(entity);
        return entity;
      }
      var enemyProjectiles = owners.Keys.Where(p => Entity(Root(p))["kind"] == 2).ToHashSet();
      var damage = characters.ToDictionary(c => c.Ordinal, _ => 0L);
      foreach (var e in entries.Where(e => e.Name == "CommonHurtEvent"))
      {
        var v = e.Values;
        var shapeIndex = v["shape"];
        if (shapeIndex < 0 || shapeIndex >= shapes.Length) return Fail("reference_invalid");
        var shape = shapes[(int)shapeIndex];
        _ = Entity(shape["target"]);
        if (!enemyProjectiles.Contains(shape["target"])) continue;
        if (v["damage"] < 0) return Fail("damage_invalid");
        if (!byEntity.TryGetValue(Root(shape["caster"]), out var ordinal)) return Fail("caster_unresolved");
        damage[ordinal] = checked(damage[ordinal] + v["damage"]);
      }
      if (damage.Values.Aggregate(0L, (sum, x) => checked(sum + x)) != reportedTotal) return Fail("projectile_total_mismatch");
      if (characters.Any(c => damage[c.Ordinal] > c.TabDamage)) return Fail("damage_invalid");
      return new("ready", hash, ProjectileAnalysis.CurrentVersion, characters.Select(c =>
          new ProjectileCharacter(c.Ordinal, damage[c.Ordinal], checked(c.TabDamage!.Value - damage[c.Ordinal]))).ToArray());
    }
    catch (NotSupportedException) { return Fail("unsupported_schema"); }
    catch (Exception ex) when (ex is InvalidDataException or EndOfStreamException or OverflowException or
        ArgumentException or KeyNotFoundException or IndexOutOfRangeException)
    { return Fail("invalid_log"); }
  }

  internal static List<Entry> Decode(byte[] raw, bool composition = false)
  {
    var r = new Reader(raw);
    var headerLength = r.Count(64 * 1024);
    var headerEnd = checked(r.Position + headerLength);
    if (headerEnd >= raw.Length) throw new InvalidDataException();
    _ = r.Unsigned(); _ = r.String(); _ = r.Unsigned();
    var statCount = r.Count(64);
    for (var i = 0; i < statCount; i++) _ = r.String();
    var schemas = new Schema[r.Count(128)];
    for (var i = 0; i < schemas.Length; i++)
    {
      var name = r.String(); var fields = new string[r.Count(128)];
      for (var j = 0; j < fields.Length; j++) fields[j] = r.String();
      schemas[i] = new(name, fields, r.Count(1));
    }
    var descriptor = string.Join("\n", schemas.Select(s => s.Name + ":" + string.Join(",", s.Fields) + ":" + s.Extra));
    if (Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(descriptor))).ToLowerInvariant() != SupportedSchema || statCount != 12)
      throw new NotSupportedException();
    if (r.Position != headerEnd) throw new InvalidDataException();
    using var input = new MemoryStream(raw, headerEnd, raw.Length - headerEnd, false);
    using var deflate = new DeflateStream(input, CompressionMode.Decompress);
    using var output = new MemoryStream();
    var buffer = new byte[65536]; int count;
    while ((count = deflate.Read(buffer)) != 0)
    {
      if (output.Length + count > MaximumExpandedBytes) throw new InvalidDataException();
      output.Write(buffer, 0, count);
    }
    r = new Reader(output.ToArray());
    var entries = new List<Entry>(); var recordCount = 0; var tick = 0; long time = 0;
    var retained = new HashSet<string> { "Entity", "HurtShape", "ProjectileSpawn", "CommonHurtEvent" };
    if (composition) retained.UnionWith(["TickClock",
      "ChangeWeapon",
      "UseCharacterSkill",
      "DamageFormula",
      "DamageFormulaShape",
      "HitContextShape",
      "Function",
      "AddedFunction",
      "AddedIterationFunction",
      "RemovedFunction",
      "DispelledFunction"]);
    while (!r.End)
    {
      if (++recordCount > 2_000_000) throw new InvalidDataException();
      var schema = schemas[r.Count(schemas.Length - 1)]; _ = r.Unsigned();
      Dictionary<string, long>? values = retained.Contains(schema.Name) ? new() : null;
      foreach (var field in schema.Fields) { var value = r.Signed(); values?.Add(field, value); }
      if (schema.Extra != 0)
      {
        var extra = r.Signed();
        if (extra < 0 || extra > statCount) throw new InvalidDataException();
        for (var i = 0; i < extra; i++)
        {
          var key = r.Signed(); if (key < 0 || key >= statCount) throw new InvalidDataException();
          _ = r.Signed();
        }
      }
      if (values is not null)
      {
        if (schema.Name == "TickClock") { tick++; time = checked(time + values["playTimeDeltaMs"]); }
        entries.Add(new(schema.Name, values, recordCount, tick, time));
      }
    }
    return entries;
  }

  private sealed class Reader(byte[] bytes)
  {
    public int Position { get; private set; }
    public bool End => Position == bytes.Length;
    public ulong Unsigned()
    {
      ulong value = 0;
      for (var shift = 0; shift < 70; shift += 7)
      {
        if (Position >= bytes.Length) throw new EndOfStreamException();
        var b = bytes[Position++];
        if (shift == 63 && b > 1) throw new InvalidDataException();
        value |= (ulong)(b & 127) << shift;
        if ((b & 128) == 0) return value;
      }
      throw new InvalidDataException();
    }
    public long Signed() { var n = Unsigned(); return unchecked((long)(n >> 1) ^ -((long)n & 1)); }
    public int Count(int max) { var n = Unsigned(); return n <= (ulong)max ? (int)n : throw new InvalidDataException(); }
    public string String()
    {
      var length = Count(4096);
      if (length > bytes.Length - Position) throw new EndOfStreamException();
      var value = new UTF8Encoding(false, true).GetString(bytes, Position, length); Position += length; return value;
    }
  }
}
