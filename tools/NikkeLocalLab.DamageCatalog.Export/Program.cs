using System.IO.Compression;
using System.Security.Cryptography;
using System.Text.Json;
using EpinelPS.Data;
using MemoryPack;

if (args.Length != 3) throw new ArgumentException("usage: static-data.zip client-build output.json");
using var zip = ZipFile.OpenRead(args[0]);
async Task<T[]> Read<T>(string name)
{
    using var input = zip.GetEntry(name)!.Open();
    return await MemoryPackSerializer.DeserializeAsync<T[]>(input) ?? throw new InvalidDataException();
}
var characters = await Read<CharacterRecord>("CharacterTable.mpk");
var shots = await Read<CharacterShotRecord>("CharacterShotTable.mpk");
var skills = (await Read<CharacterSkillRecord>("CharacterSkillTable.mpk")).ToDictionary(x => x.Id);
var functions = (await Read<FunctionRecord>("FunctionTable.mpk")).ToDictionary(x => x.Id);
var states = (await Read<StateEffectRecord>("StateEffectTable.mpk")).ToDictionary(x => x.Id);
var favorites = (await Read<FavoriteItemRecord>("FavoriteItemTable.mpk")).Where(f => f.NameCode > 0).ToLookup(f => f.NameCode);
var result = new List<object>();
foreach (var character in characters)
{
    var origins = new Dictionary<(string Kind, int Id), HashSet<string>>();
    var roots = new List<(string Slot, int Root, string? Kind)> {
        ("skill1", character.Skill1Id, null), ("skill2", character.Skill2Id, null), ("burst", character.UltiSkillId, null) };
    // Alternative favorite-item skills are source mappings, not a claim that the item was equipped.
    // A source is attributed only when that exact skill/function occurs in the battle log.
    foreach (var change in favorites[character.NameCode].SelectMany(f => f.FavoriteitemSkillGroupData))
    {
        var slot = change.SkillChangeSlot switch { 1 => "skill1", 2 => "skill2", 3 => "burst", _ => null };
        var kind = change.SkillTable.ToString() switch { "StateEffect" => "state", "CharacterSkill" => "skill", "Function" => "function", _ => null };
        if (slot is not null && kind is not null) roots.Add((slot, change.FavoriteSkillId, kind));
    }
    foreach (var (slot, root, rootKind) in roots)
    {
        var pending = new Queue<(string Kind, int Id)>();
        var visited = new HashSet<(string, int)>();
        // Cover each level's explicit rows, not the account's current skill level.
        for (var level = 0; level < 10 && root > 0; level++)
        {
            var id = root + level;
            if (rootKind is null or "state" && states.ContainsKey(id)) pending.Enqueue(("state", id));
            else if (rootKind is null or "skill" && skills.ContainsKey(id)) pending.Enqueue(("skill", id));
            else if (rootKind is null or "function" && functions.ContainsKey(id)) pending.Enqueue(("function", id));
        }
        while (pending.TryDequeue(out var node))
        {
            if (!visited.Add(node)) continue;
            if (visited.Count > 10000) throw new InvalidDataException("skill_graph_limit");
            if (!origins.TryGetValue(node, out var labels)) origins[node] = labels = [];
            labels.Add(slot);
            void Functions(IEnumerable<int> ids) { foreach (var id in ids) if (functions.ContainsKey(id)) pending.Enqueue(("function", id)); }
            if (node.Kind == "state" && states.TryGetValue(node.Id, out var state))
                Functions(state.UseFunctionIdList.Concat(state.HurtFunctionIdList).Concat(state.Functions.Select(x => x.Function)));
            if (node.Kind == "skill" && skills.TryGetValue(node.Id, out var skill))
                Functions(skill.BeforeUseFunctionIdList.Concat(skill.BeforeHurtFunctionIdList).Concat(skill.AfterUseFunctionIdList).Concat(skill.AfterHurtFunctionIdList));
            if (node.Kind == "function" && functions.TryGetValue(node.Id, out var function))
            {
                Functions(function.ConnectedFunction);
                if (function.FunctionType == FunctionType.UseCharacterSkillId && skills.ContainsKey((int)function.FunctionValue))
                    pending.Enqueue(("skill", (int)function.FunctionValue));
            }
        }
    }
    result.Add(new { character.Id, BaseShot = character.ShotId,
        Origins = origins.Where(x => x.Key.Kind != "state").Select(x => new { x.Key.Kind, x.Key.Id, Slots = x.Value.Order().ToArray(),
            EffectKind = x.Key.Kind == "skill" ? skills[x.Key.Id].SkillType.ToString() : functions[x.Key.Id].FunctionType.ToString() }).ToArray() });
}
var catalog = new { ClientBuild = args[1], SourceSha256 = Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(args[0]))).ToLowerInvariant(),
    Characters = result, Shots = shots.Select(s => new { s.Id, FireType = s.FireType.ToString() }).ToArray(),
    Skills = skills.Values.Where(s => (s.SkillType == CharacterSkillType.ChangeWeapon && s.SkillValueData.Length > 2) ||
            (s.SkillType == CharacterSkillType.AutoFireWeapon && s.SkillValueData.Length > 1))
        .Select(s => new { s.Id, ReplacementShot = s.SkillValueData[s.SkillType == CharacterSkillType.ChangeWeapon ? 2 : 1].SkillValue,
            WeaponKind = s.SkillType == CharacterSkillType.ChangeWeapon ? "replacement" : "automatic" }).ToArray(),
    Enhancements = functions.Values.Where(f => f.FunctionType == FunctionType.StatPenetration &&
        f.TimingTriggerType.ToString() == "OnPelletHitNum" && f.DurationType.ToString() == "Shots" && f.TimingTriggerValue > 0)
        .Select(f => new { f.Id, PelletThreshold = f.TimingTriggerValue }).ToArray() };
await File.WriteAllTextAsync(args[2], JsonSerializer.Serialize(catalog));
Console.WriteLine(JsonSerializer.Serialize(new { characters = result.Count, shots = shots.Length }));
