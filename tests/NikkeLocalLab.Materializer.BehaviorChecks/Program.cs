using System.Collections;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.Loader;
using System.Text.Json;

if (args.FirstOrDefault() is "--native-fx" or "--native-fx-step")
  return NativeFxProcessChecks.Run(args);

// The local gate supplies a freshly built, pinned tool. Never invoke its entry
// point, GameData constructor/parser, server, database or original client.
// Reflection is only the adapter to private compiled types; assertions inspect
// actual output objects, not source text or a duplicate projection algorithm.
if (args.Length != 1) return 2;
var failures = new List<string>();
var passed = 0;
try
{
  var path = Path.GetFullPath(args[0]);
  var resolver = new AssemblyDependencyResolver(path);
  AssemblyLoadContext.Default.Resolving += (context, name) =>
  {
    var resolved = resolver.ResolveAssemblyToPath(name);
    return resolved is null ? null : context.LoadFromAssemblyPath(resolved);
  };
  var assembly = AssemblyLoadContext.Default.LoadFromAssemblyPath(path);
  var program = assembly.GetType("Program", throwOnError: true)!;
  var materialize = program.GetMethods(BindingFlags.Static | BindingFlags.NonPublic)
      .Single(method => method.Name.Contains("g__Materialize|", StringComparison.Ordinal));
  var epinel = Assembly.Load("EpinelPS");

  void Case(string name, Action<Fixture> test)
  {
    try { test(new Fixture(epinel, materialize)); passed++; }
    catch { failures.Add(name); } // Do not emit reflected values, IDs or raw exceptions.
  }

  foreach (var tier in new[] { 9, 10 })
    foreach (var matched in new[] { "true", "false", "not_applicable" })
      Case($"equipment_t{tier}_{matched}_all_slots", f =>
      {
        f.EquipAll(tier, matched);
        f.Run();
        var items = f.Items.Cast<object>().Where(item => Fixture.Number(item, "Csn") == 1).ToArray();
        Fixture.Check(items.Length == 4);
        for (var slot = 0; slot < 4; slot++)
        {
          var item = items.Single(item => Fixture.Number(item, "Position") == slot);
          Fixture.Check(Fixture.Number(item, "Corp") == (tier == 9 && matched == "true" ? 3 : 0));
          Fixture.Check(Fixture.Number(item, "Level") == 5 && Fixture.Number(item, "Count") == 1);
        }
        var roundTrip = f.RoundTripUser();
        Fixture.Check(Fixture.List(roundTrip, "Items").Cast<object>()
            .Where(item => Fixture.Number(item, "Csn") == 1)
            .All(item => Fixture.Number(item, "Corp") == (tier == 9 && matched == "true" ? 3 : 0)));
      });
  Case("equipment_existing_identity_and_stale_corp", f =>
  {
    f.EquipAll(10, "true");
    f.AddItem(501, 1, 0, 77, 2, corp: 3);
    f.Run();
    var item = f.Items.Cast<object>().Single(item => Fixture.Number(item, "Isn") == 77);
    Fixture.Check(Fixture.Number(item, "Corp") == 0 && Fixture.Number(item, "Level") == 5);
  });
  Case("equipment_unequip_removes_awakening_only_for_slot", f =>
  {
    f.AddItem(501, 1, 0, 77, 5);
    f.AddAwakening(77, 701, 0, 0);
    f.AddItem(501, 99, 0, 88, 5);
    f.Run();
    Fixture.Check(f.Items.Cast<object>().All(item => Fixture.Number(item, "Isn") != 77));
    Fixture.Check(f.Items.Cast<object>().Any(item => Fixture.Number(item, "Isn") == 88));
    Fixture.Check(Fixture.List(f.User, "EquipmentAwakenings").Count == 0);
  });
  Case("equipment_missing_mapping_rejected", f =>
  {
    f.EquipAll(10, "true"); f.Support.Clear();
    f.Rejected("phase_d_equipment_mapping_missing");
  });
  Case("equipment_unresolved_manufacturer_rejected", f =>
  {
    f.EquipAll(9, "true"); f.Value("equipment.head.manufacturer_matched", status: "unresolved");
    f.Rejected("phase_d_candidate_coordinate_missing");
  });
  Case("overload_sparse_slots_and_exact_state_effect", f =>
  {
    f.EquipAll(10, "not_applicable");
    foreach (var line in new[] { 1, 3 })
    {
      f.Value($"equipment.head.overload.{line}.state", code: "present");
      f.Value($"equipment.head.overload.{line}.definition", reference: Fixture.OptionUid);
      f.Value($"equipment.head.overload.{line}.value", unscaled: 123, scale: 2);
    }
    f.Run();
    var option = Fixture.Get(Fixture.List(f.User, "EquipmentAwakenings")[0]!, "Option");
    Fixture.Check(Fixture.Number(option, "Option1Id") == 701 && Fixture.Number(option, "Option2Id") == 0 &&
        Fixture.Number(option, "Option3Id") == 701);
  });
  Case("overload_unknown_exact_value_rejected", f =>
  {
    f.EquipAll(10, "not_applicable");
    f.Value("equipment.head.overload.1.state", code: "present");
    f.Value("equipment.head.overload.1.definition", reference: Fixture.OptionUid);
    f.Value("equipment.head.overload.1.value", unscaled: 124, scale: 2);
    f.Rejected("phase_d_overload_value_mapping_missing");
  });
  Case("cube_missing_inventory_defaults_to_fifteen", f =>
  {
    f.Run(); Fixture.Check(f.Cubes.Length == 2 && f.Cubes.All(item => Fixture.Number(item, "Level") == 15));
  });
  Case("cube_legacy_duplicates_keep_max_level_and_assignments", f =>
  {
    f.AddItem(601, 0, 5, 10, 4, assigned: [41]);
    f.AddItem(601, 0, 5, 11, 12, assigned: [42, 41]);
    f.Run();
    var cube = f.Cubes.Single(item => Fixture.Number(item, "ItemType") == 601);
    Fixture.Check(Fixture.Number(cube, "Isn") == 10 && Fixture.Number(cube, "Level") == 12);
    Fixture.Check(Fixture.List(cube, "CsnList").Cast<long>().Order().SequenceEqual(new long[] { 41, 42 }));
  });
  Case("cube_account_level_wins_and_replay_does_not_duplicate", f =>
  {
    f.Owned(7, 8); f.AttachCube(1, 7); f.AttachCube(2, 7);
    f.AddItem(601, 0, 5, 10, 4, assigned: [41]);
    f.AddItem(601, 0, 5, 11, 7, assigned: [42]);
    f.Run(); f.Run();
    var cube = f.Cubes.Single(item => Fixture.Number(item, "ItemType") == 601);
    Fixture.Check(Fixture.Number(cube, "Level") == 7 && Fixture.Number(cube, "Isn") == 11);
    Fixture.Check(Fixture.List(cube, "CsnList").Cast<long>().Order().SequenceEqual(new long[] { 1, 2, 41, 42 }));
    Fixture.Check(f.Cubes.Length == 2);
    var restored = Fixture.List(f.RoundTripUser(), "Items").Cast<object>()
        .Single(item => Fixture.Number(item, "ItemType") == 601);
    Fixture.Check(Fixture.List(restored, "CsnList").Count == 4 && Fixture.Number(restored, "Level") == 7);
  });
  Case("cube_unequip_preserves_other_character", f =>
  {
    f.AddItem(601, 0, 5, 10, 8, assigned: [1, 41]); f.Run();
    Fixture.Check(Fixture.List(f.Cubes.Single(item => Fixture.Number(item, "ItemType") == 601), "CsnList")
        .Cast<long>().SequenceEqual(new long[] { 41 }));
  });
  Case("cube_missing_definition_rejected", f =>
  {
    f.AttachCube(1, 7); f.Support.Remove(Fixture.CubeA); f.Rejected("phase_d_cube_mapping_missing");
  });
  Case("cube_partial_account_inventory_rejected", f =>
  {
    f.Value("account_cube_level", Fixture.CubeA, integer: 7);
    f.Rejected("phase_d_account_cube_inventory_incomplete");
  });
  Case("cube_account_level_out_of_range_rejected", f =>
  {
    f.Owned(16, 8); f.Rejected("phase_d_account_cube_inventory_invalid");
  });
  Case("cube_missing_level_row_rejected", f =>
  {
    f.Owned(7, 8); f.Table("ItemHarmonyCubeLevelTable").Clear();
    f.Rejected("phase_d_account_cube_inventory_invalid");
  });
  Case("independent_accounts_do_not_share_inventory", f =>
  {
    f.Owned(7, 8); f.Run();
    var other = new Fixture(epinel, materialize); other.Run();
    Fixture.Check(other.Cubes.All(item => Fixture.Number(item, "Level") == 15));
    Fixture.Check(f.Cubes.Any(item => Fixture.Number(item, "Level") == 7));
  });
}
catch { failures.Add("harness_setup"); }
Console.WriteLine(JsonSerializer.Serialize(new { passed, failed = failures.Count, failures, syntheticOnly = true }));
return failures.Count == 0 ? 0 : 1;

sealed class Fixture
{
  public const string CubeA = "b365db3c-eed1-4d63-b7e9-a8a9cfe12a75";
  public const string CubeB = "1398e29c-e119-470e-8ba6-05ea53255444";
  public const string OptionUid = "8133d067-5a78-446e-99c6-45d0944ee07c";
  const string EquipmentUid = "b33c9cc7-1efc-409c-aa20-ed3483252f0c";
  readonly Assembly epinel;
  readonly MethodInfo method;
  readonly object data;
  readonly Dictionary<(string, string), object> values = [];
  readonly Dictionary<string, int> characters = [];
  public readonly Dictionary<string, int> Support = new() { [EquipmentUid] = 501, [CubeA] = 601, [CubeB] = 602 };
  public object User { get; }
  public IList Items => List(User, "Items");
  public object[] Cubes => Items.Cast<object>().Where(item => Number(item, "Csn") == 0 &&
      Number(item, "ItemType") is 601 or 602).ToArray();
  static string Subject(int index) => index == 1 ? "08d7100e-94f0-4cc2-9791-37af69ca1a23" : "98106bfb-d693-4c19-8c1a-9ef44494f898";

  public Fixture(Assembly epinel, MethodInfo method)
  {
    this.epinel = epinel; this.method = method;
    var dataType = epinel.GetType("EpinelPS.Data.GameData", true)!;
    data = RuntimeHelpers.GetUninitializedObject(dataType); // Constructor opens a pack: deliberately never called.
    foreach (var name in new[] { "CharacterTable", "ItemEquipTable", "ItemHarmonyCubeTable",
        "ItemHarmonyCubeLevelTable", "FavoriteItemTable", "EquipmentOptionTable", "RecycleResearchStats" })
    {
      var field = dataType.GetField(name)!;
      field.SetValue(data, Activator.CreateInstance(field.FieldType));
    }
    dataType.GetField("_instance", BindingFlags.Static | BindingFlags.NonPublic)!.SetValue(null, data);
    User = Activator.CreateInstance(epinel.GetType("EpinelPS.Models.User", true)!)!;
    Row("CharacterTable", 101, ("Id", 101), ("NameCode", 201), ("GradeCoreId", 1), ("IsVisible", true), ("Corporation", 3));
    characters[Subject(1)] = 201;
    Row("ItemEquipTable", 501, ("Id", 501), ("ItemRare", 10));
    foreach (var id in new[] { 601, 602 })
    {
      Row("ItemHarmonyCubeTable", id, ("Id", id), ("LocationId", 5), ("LevelEnhanceId", id));
      for (var level = 1; level <= 15; level++)
        Row("ItemHarmonyCubeLevelTable", id * 100 + level, ("Id", id * 100 + level), ("LevelEnhanceId", id), ("Level", level));
    }
    var option = Row("EquipmentOptionTable", 700, ("Id", 700));
    var effectType = epinel.GetType("EpinelPS.Data.StateEffectList", true)!;
    var effects = (IList)Activator.CreateInstance(typeof(List<>).MakeGenericType(effectType))!;
    var effect = Activator.CreateInstance(effectType)!; Set(effect, "StateEffectId", 701); effects.Add(effect);
    Set(option, "StateEffectList", effects);
    Value("synchro_level", "", integer: 400);
    Character(1);
  }

  void Character(int index)
  {
    if (index == 2)
    {
      Row("CharacterTable", 102, ("Id", 102), ("NameCode", 202), ("GradeCoreId", 1), ("IsVisible", true), ("Corporation", 3));
      characters[Subject(2)] = 202;
    }
    foreach (var field in new[] { "character_level", "limit_break", "core_level", "bond_level", "skill_1_level", "skill_2_level", "burst_level" })
      Value(field, Subject(index), integer: field == "character_level" ? 123 : 0);
    foreach (var slot in new[] { "head", "torso", "arms", "legs" })
      Value($"equipment.{slot}.state", Subject(index), code: "unequipped");
    Value("cube.state", Subject(index), code: "unequipped");
    Value("collection.kind", Subject(index), code: "detached");
  }

  public void Value(string field, string? subject = null, string status = "ready", long? integer = null,
      bool? boolean = null, string? reference = null, string? code = null, long? unscaled = null, int? scale = null)
  {
    subject ??= Subject(1);
    values[(field, subject)] = new
    {
      FieldCode = field,
      SubjectUid = subject == "" ? null : subject,
      Status = status,
      IntegerValue = integer,
      BooleanValue = boolean,
      ReferenceUid = reference,
      ControlledValue = code,
      UnscaledValue = unscaled,
      DecimalScale = scale,
      ReasonCode = (string?)null
    };
  }
  public void EquipAll(int tier, string matched)
  {
    Set(Table("ItemEquipTable")[501]!, "ItemRare", tier);
    foreach (var slot in new[] { "head", "torso", "arms", "legs" })
    {
      Value($"equipment.{slot}.state", code: "equipped");
      Value($"equipment.{slot}.definition", reference: EquipmentUid);
      Value($"equipment.{slot}.enhancement_level", integer: 5);
      Value($"equipment.{slot}.manufacturer_matched", status: matched == "not_applicable" ? matched : "ready",
          boolean: matched == "not_applicable" ? null : matched == "true");
      for (var line = 1; line <= 3; line++) Value($"equipment.{slot}.overload.{line}.state", code: "absent");
    }
  }
  public void Owned(int first, int second)
  {
    Value("account_cube_level", CubeA, integer: first); Value("account_cube_level", CubeB, integer: second);
  }
  public void AttachCube(int index, int level)
  {
    if (index == 2) Character(2);
    Value("cube.state", Subject(index), code: "equipped");
    Value("cube.definition", Subject(index), reference: CubeA);
    Value("cube.level", Subject(index), integer: level);
  }
  public void AddItem(int tid, long csn, int position, long isn, int level, int corp = 0, long[]? assigned = null)
  {
    var item = Activator.CreateInstance(epinel.GetType("EpinelPS.Models.DbItemData", true)!)!;
    foreach (var (name, value) in new (string, object)[] { ("ItemType", tid), ("Csn", csn), ("Position", position),
        ("Isn", isn), ("Level", level), ("Corp", corp), ("Count", 1) }) Set(item, name, value);
    foreach (var id in assigned ?? []) List(item, "CsnList").Add(id);
    Items.Add(item);
  }
  public void AddAwakening(long isn, int first, int second, int third)
  {
    var awakening = Activator.CreateInstance(epinel.GetType("EpinelPS.Models.EquipmentAwakeningData", true)!)!;
    Set(awakening, "Isn", isn);
    var option = Get(awakening, "Option");
    Set(option, "Option1Id", first); Set(option, "Option2Id", second); Set(option, "Option3Id", third);
    List(User, "EquipmentAwakenings").Add(awakening);
  }
  public IDictionary Table(string name) => (IDictionary)Get(data, name);
  object Row(string table, int key, params (string Name, object Value)[] fields)
  {
    var dictionary = Table(table);
    var row = Activator.CreateInstance(dictionary.GetType().GetGenericArguments()[1])!;
    foreach (var (name, value) in fields) Set(row, name, value);
    dictionary.Add(key, row); return row;
  }
  public void Run()
  {
    var parameters = method.GetParameters();
    var candidate = JsonSerializer.Deserialize(JsonSerializer.Serialize(new { Values = values.Values }), parameters[1].ParameterType);
    var lobby = JsonSerializer.Deserialize("{\"DisplayName\":\"Synthetic\",\"CommanderLevel\":10}", parameters[2].ParameterType);
    var mappings = Activator.CreateInstance(parameters[3].ParameterType, characters,
        characters.ToDictionary(pair => pair.Value, pair => pair.Key), Support,
        new Dictionary<(string, long, int), int> { [(OptionUid, 123, 2)] = 701 });
    method.Invoke(null, [User, candidate, lobby, mappings]);
  }
  public void Rejected(string code)
  {
    try { Run(); }
    catch (TargetInvocationException ex) when (ex.InnerException is InvalidOperationException failure && failure.Message == code) { return; }
    throw new InvalidOperationException("expected_rejection");
  }
  public object RoundTripUser()
  {
    // Use the actual runtime serializer, not a second test-only object model.
    var json = Assembly.Load("Newtonsoft.Json").GetType("Newtonsoft.Json.JsonConvert", true)!;
    var text = json.GetMethod("SerializeObject", [typeof(object)])!.Invoke(null, [User]);
    return json.GetMethod("DeserializeObject", [typeof(string), typeof(Type)])!.Invoke(null, [text, User.GetType()])!;
  }
  public static object Get(object target, string name) => target.GetType().GetProperty(name)?.GetValue(target) ??
      target.GetType().GetField(name)!.GetValue(target)!;
  public static IList List(object target, string name) => (IList)Get(target, name);
  public static long Number(object target, string name) => Convert.ToInt64(Get(target, name));
  static void Set(object target, string name, object value)
  {
    var field = target.GetType().GetField(name);
    var property = target.GetType().GetProperty(name);
    var type = field?.FieldType ?? property!.PropertyType;
    if (type.IsEnum) value = Enum.ToObject(type, value);
    if (field is not null) field.SetValue(target, value); else property!.SetValue(target, value);
  }
  public static void Check(bool value) { if (!value) throw new InvalidOperationException("output_mismatch"); }
}
