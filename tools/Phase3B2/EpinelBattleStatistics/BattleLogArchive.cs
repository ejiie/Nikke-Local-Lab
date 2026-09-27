using System.Security.Cryptography;
using System.Text.Json;
using NikkeLocalLab.BattleLog;

namespace EpinelPS.Database;

// Persistent local archive, independent of the temporary 10-report diagnostic session.
public static class BattleLogArchive
{
    public static void Save(byte[] raw, RaidDamageObservation observation, BattleLogCharacter[] identities)
    {
        if (raw.Length == 0 || raw.Length > BattleLogProjectileDecoder.MaximumRawBytes) return;
        var root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
            "NikkeLocalLab", "BattleLogs", observation.AccountUid.ToString("D"));
        for (string? p = root; p is not null; p = Path.GetDirectoryName(p))
            if (Directory.Exists(p) && (File.GetAttributes(p) & FileAttributes.ReparsePoint) != 0)
                throw new IOException("battle_archive_path_invalid");
        Directory.CreateDirectory(root);
        var name = Path.Combine(root, observation.BattleUid.ToString("D"));
        WriteOnce(name + ".private.bin", raw);
        WriteOnce(name + ".private.json", JsonSerializer.SerializeToUtf8Bytes(new {
            observation.BattleUid, observation.AccountUid, observation.ClientBuild, observation.Mode,
            Sha256 = Convert.ToHexString(SHA256.HashData(raw)).ToLowerInvariant(), Identities = identities,
            observation.ProjectileAnalysis
        }));
    }
    private static void WriteOnce(string path, byte[] bytes)
    {
        if (File.Exists(path))
        {
            if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0 ||
                !SHA256.HashData(File.ReadAllBytes(path)).AsSpan().SequenceEqual(SHA256.HashData(bytes)))
                throw new IOException("battle_archive_conflict");
            return;
        }
        var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            using (var file = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            { file.Write(bytes); file.Flush(true); }
            File.Move(temporary, path);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}
