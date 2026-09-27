using System.Security.Cryptography;
using System.Text.Json;

namespace EpinelPS.Database;

// Opt-in, bounded diagnostic files only. Never persist this blob in account DBs
// or print it, the complete request, credentials or source identifiers.
public static class BattleLogDiagnostics
{
    public const int MaximumBytes = 8 * 1024 * 1024;
    public static string Root => Path.Combine(Environment.GetFolderPath(
        Environment.SpecialFolder.CommonApplicationData), "NikkeLocalLab", "Diagnostics", "BattleLog");
    private static int readinessReported;

    public sealed record Session(Guid SessionUid, DateTimeOffset ExpiresAtUtc, int MaximumReports);

    public static void ReportReadinessOnce()
    {
        if (Interlocked.Exchange(ref readinessReported, 1) != 0) return;
        try
        {
            Console.WriteLine($"NLL_BATTLE_LOG_READY/v1 status={CheckReadiness(Root, DateTimeOffset.UtcNow)}");
        }
        catch (Exception) { Console.WriteLine("NLL_BATTLE_LOG_READY/v1 status=unavailable"); }
    }

    public static string CheckReadiness(string root, DateTimeOffset now)
    {
        Plain(root);
        var marker = Path.Combine(root, "capture.json");
        Plain(marker);
        if (!File.Exists(marker)) return "config_missing_or_inaccessible";
        if (new FileInfo(marker).Length > 4096) return "config_invalid";
        var session = JsonSerializer.Deserialize<Session>(File.ReadAllBytes(marker));
        if (session is null || session.SessionUid == Guid.Empty || session.MaximumReports is < 1 or > 10 ||
            session.ExpiresAtUtc <= now || session.ExpiresAtUtc > now.AddDays(7)) return "config_invalid";
        var probe = Path.Combine(root, Guid.NewGuid().ToString("N") + ".probe");
        using var file = new FileStream(probe, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.DeleteOnClose);
        file.WriteByte(0);
        file.Flush(true);
        return "ready";
    }

    public static void TryCapture(NetAntiCheatBattleData? report, RaidDamageObservation observation)
    {
        try
        {
            void Status(string code) => Console.WriteLine(
                $"NLL_BATTLE_LOG_DIAGNOSTIC/v1 status={code} reportPresent={report is not null} byteLength={report?.BattleLog.Length.ToString() ?? "missing"}");
            if (observation.AccountUid == Guid.Empty) { Status("account_unbound"); return; }
            Capture(Root, report, observation, DateTimeOffset.UtcNow, Status);
        }
        catch (Exception) { Console.WriteLine("NLL_BATTLE_LOG_DIAGNOSTIC_FAILED/v1"); }
    }

    public static bool Capture(string root, NetAntiCheatBattleData? report,
        RaidDamageObservation observation, DateTimeOffset now, Action<string>? statusChanged = null)
    {
        bool Skip(string code) { statusChanged?.Invoke(code); return false; }
        Plain(root);
        var enabled = Path.Combine(root, "capture.json");
        if (!File.Exists(enabled)) return Skip("config_missing_or_inaccessible");
        Plain(enabled);
        if (new FileInfo(enabled).Length > 4096) return Skip("config_oversize");
        var session = JsonSerializer.Deserialize<Session>(File.ReadAllBytes(enabled));
        if (session is null || session.SessionUid == Guid.Empty || session.MaximumReports is < 1 or > 10 ||
            session.ExpiresAtUtc <= now || session.ExpiresAtUtc > now.AddDays(7) ||
            observation.BattleUid == Guid.Empty) return Skip("config_or_battle_invalid");
        var directory = Path.Combine(root, session.SessionUid.ToString("D"));
        Plain(directory);
        Directory.CreateDirectory(directory);
        var lockPath = Path.Combine(directory, "capture.lock");
        Plain(lockPath);
        using var gate = new FileStream(lockPath, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
        var receiptPath = Path.Combine(directory, observation.BattleUid.ToString("D") + ".json");
        Plain(receiptPath);
        if (File.Exists(receiptPath)) return Skip("duplicate");
        if (Directory.EnumerateFiles(directory, "*.json").Take(session.MaximumReports).Count() >= session.MaximumReports)
            return Skip("limit_reached");
        var blob = report?.BattleLog;
        var length = blob?.Length;
        var status = report is null ? "report_missing" : length == 0 ? "empty" :
            length > MaximumBytes ? "oversize_not_saved" : "captured";
        string? hash = null;
        string? leaf = null;
        if (status == "captured")
        {
            hash = Convert.ToHexString(SHA256.HashData(blob!.Span)).ToLowerInvariant();
            leaf = observation.BattleUid.ToString("D") + ".private.bin";
            var path = Path.Combine(directory, leaf);
            Plain(path);
            // A crash after the blob but before its receipt can be completed
            // only when the exact same bytes are already present.
            if (File.Exists(path))
            {
                if (new FileInfo(path).Length != length ||
                    Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path))).ToLowerInvariant() != hash)
                    throw new IOException("battle_log_diagnostic_collision");
            }
            else
            {
                using var file = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None);
                file.Write(blob.Span);
                file.Flush(true);
            }
        }
        var receipt = JsonSerializer.SerializeToUtf8Bytes(new {
            contractId = "nll/private-battle-log-diagnostic/v1", statusCode = status,
            battleUid = observation.BattleUid, mode = observation.Mode, season = observation.Season,
            bossStep = observation.BossStep, clientBuild = observation.ClientBuild,
            reportPresent = report is not null, byteLength = length, sha256 = hash, fileName = leaf,
            capturedAtUtc = now, battleDuration = report?.BattleDuration
        });
        var temporary = receiptPath + "." + Guid.NewGuid().ToString("N") + ".tmp";
        using (var file = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
        { file.Write(receipt); file.Flush(true); }
        File.Move(temporary, receiptPath);
        statusChanged?.Invoke(status);
        return true;
    }

    private static void Plain(string path)
    {
        if (!Path.IsPathFullyQualified(path) || path.StartsWith(@"\\") ||
            path[Path.GetPathRoot(path)!.Length..].Contains(':')) throw new IOException("battle_log_path_invalid");
        for (string? current = Path.GetFullPath(path); current is not null; current = Path.GetDirectoryName(current))
            if ((File.Exists(current) || Directory.Exists(current)) &&
                (File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
                throw new IOException("battle_log_reparse_forbidden");
    }
}
