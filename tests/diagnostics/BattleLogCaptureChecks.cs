using EpinelPS;
using EpinelPS.Database;
using Google.Protobuf;
using System.Text.Json;

// Run against the candidate server assembly, with synthetic blobs and an isolated directory.
var root = Path.Combine(Path.GetTempPath(), "nll-battlelog-test-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(root);
int checks = 0;
void Check(bool value) { if (!value) throw new Exception("battlelog_check_" + checks); checks++; }
var now = DateTimeOffset.UtcNow;
var session = new BattleLogDiagnostics.Session(Guid.NewGuid(), now.AddHours(1), 10);
var directory = Path.Combine(root, session.SessionUid.ToString("D"));
RaidDamageObservation Observation() => new() { BattleUid = Guid.NewGuid(), AccountUid = Guid.NewGuid(), Mode = "union_hard_practice" };
void Enable() => File.WriteAllBytes(Path.Combine(root, "capture.json"), JsonSerializer.SerializeToUtf8Bytes(session));
try
{
    Check(BattleLogDiagnostics.CheckReadiness(root, now) == "config_missing_or_inaccessible");
    string? diagnostic = null;
    Check(!BattleLogDiagnostics.Capture(root, new(), Observation(), now, code => diagnostic = code));
    Check(diagnostic == "config_missing_or_inaccessible");
    Enable();
    Check(BattleLogDiagnostics.CheckReadiness(root, now) == "ready");
    Check(Directory.GetFiles(root, "*.probe").Length == 0);
    Check(BattleLogDiagnostics.CheckReadiness(root, now.AddHours(2)) == "config_invalid");
    var record = Observation();
    var report = new NetAntiCheatBattleData { BattleLog = ByteString.CopyFromUtf8("synthetic-event"), BattleDuration = 180 };
    Check(BattleLogDiagnostics.Capture(root, report, record, now));
    var blob = Path.Combine(directory, record.BattleUid + ".private.bin");
    Check(File.ReadAllText(blob) == "synthetic-event");
    Check(!BattleLogDiagnostics.Capture(root, report, record, now, code => diagnostic = code));
    Check(diagnostic == "duplicate");
    var receipt = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(directory, record.BattleUid + ".json")));
    Check(receipt.RootElement.GetProperty("statusCode").GetString() == "captured");
    Check(receipt.RootElement.GetProperty("byteLength").GetInt32() == 15);
    Check(!receipt.RootElement.TryGetProperty("accountUid", out _));
    Check(!JsonSerializer.Serialize(record).Contains("synthetic-event"));
    foreach (var (data, status) in new (NetAntiCheatBattleData?, string)[] {
        (null, "report_missing"), (new(), "empty"),
        (new() { BattleLog = ByteString.CopyFrom(new byte[BattleLogDiagnostics.MaximumBytes + 1]) }, "oversize_not_saved") })
    {
        var item = Observation();
        Check(BattleLogDiagnostics.Capture(root, data, item, now));
        using var saved = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(directory, item.BattleUid + ".json")));
        Check(saved.RootElement.GetProperty("statusCode").GetString() == status);
        Check(!File.Exists(Path.Combine(directory, item.BattleUid + ".private.bin")));
    }
    Check(!BattleLogDiagnostics.Capture(root, report, Observation(), now.AddHours(2)));
    while (Directory.GetFiles(directory, "*.json").Length < 10)
        Check(BattleLogDiagnostics.Capture(root, new(), Observation(), now));
    Check(!BattleLogDiagnostics.Capture(root, report, Observation(), now, code => diagnostic = code));
    Check(diagnostic == "limit_reached");
    session = session with { SessionUid = Guid.NewGuid() }; Enable();
    var collision = Observation();
    var collisionDirectory = Path.Combine(root, session.SessionUid.ToString("D"));
    Directory.CreateDirectory(collisionDirectory);
    var existing = Path.Combine(collisionDirectory, collision.BattleUid + ".private.bin");
    File.WriteAllText(existing, "must-retain");
    bool rejected = false;
    try { BattleLogDiagnostics.Capture(root, report, collision, now); } catch (IOException) { rejected = true; }
    Check(rejected && File.ReadAllText(existing) == "must-retain");
    // The capture path is optional: ordinary projection remains numeric only.
    var projected = RaidDamageObservation.Capture(new(), report, Guid.NewGuid(), "union_hard_practice", 1, 1, 1, 1, 0, 0, now);
    Check(!JsonSerializer.Serialize(projected).Contains("synthetic-event"));
    Console.WriteLine(JsonSerializer.Serialize(new { status = "passed", checks, syntheticOnly = true }));
}
finally { Directory.Delete(root, true); }
