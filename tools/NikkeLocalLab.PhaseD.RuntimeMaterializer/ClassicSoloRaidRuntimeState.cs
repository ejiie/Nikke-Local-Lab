using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using EpinelPS;
using EpinelPS.Models;
using Newtonsoft.Json;
using Npgsql;
using NikkeLocalLab.Persistence.PostgreSql;

internal sealed record ClassicSoloRaidRestoreProjection(
    bool StateAvailable,
    bool StateRestored,
    Guid? HeadRevisionUid,
    string? StateContentSha256,
    long? CompletedBestTotalDamage,
    int CompletedBestTeamCount,
    int OpenTeamCount,
    bool OpenRunRestored,
    bool OpenRunDiscardedForProfileRevisionMismatch,
    bool LegacyPartialCompletionDiscarded)
{
  public string? InheritedCompletedRecordFromBuild { get; init; }
  public Guid? InheritedSourceRevisionUid { get; init; }
}

internal static class ClassicSoloRaidRuntimeState
{
  private const string CaptureContractId = "nll/phase-d-classic-solo-raid-state-capture/v1";
  private const string PayloadContractId = "nll/classic-solo-raid-runtime-state/v1";
  private const string PersistenceContractId =
      "nll/phase-d-classic-solo-raid-state-persistence/v1";
  private static readonly byte[] ProtectedPayloadMagic = "NLLSRP01"u8.ToArray();

  internal static bool IsCaptureMode(IReadOnlyDictionary<string, string> options) =>
      options.TryGetValue("capture-solo-raid-state", out var value) && value == "true";

  internal static bool IsPersistMode(IReadOnlyDictionary<string, string> options) =>
      options.TryGetValue("persist-solo-raid-state", out var value) && value == "true";

  internal static bool IsVerifyBindingMode(IReadOnlyDictionary<string, string> options) =>
      options.TryGetValue("verify-solo-raid-binding", out var value) && value == "true";

  internal static async Task VerifyOperationalBindingAsync(
      IReadOnlyDictionary<string, string> options)
  {
    var connectionString = ReadEnvironment(
        options,
        "connection-string-env",
        "phase_d_database_environment_missing");
    var accountUid = RequiredGuid(options, "account-uid");
    var seasonNumber = RequiredPositiveInteger(options, "season-number");
    await using var dataSource = NpgsqlDataSource.Create(connectionString);
    var binding = await ResolveOperationalBindingAsync(
        dataSource,
        options,
        accountUid);
    var receipt = new
    {
      schemaVersion = 1,
      contractId = "nll/phase-d-classic-solo-raid-binding-verification/v1",
      verifiedAtUtc = DateTimeOffset.UtcNow,
      accountUid = binding.LocalAccountUid,
      seasonNumber = binding.SeasonNumber,
      raidSnapshotUid = binding.RaidSnapshotUid,
      raidSnapshotSha256 = LowerHex(binding.RaidSnapshotSha256),
      databaseModified = false
    };
    Console.WriteLine(System.Text.Json.JsonSerializer.Serialize(receipt, JsonOptions()));
  }

  internal static Task<ClassicSoloRaidRuntimeOperationalBinding>
      ResolveOperationalBindingAsync(
          NpgsqlDataSource dataSource,
          IReadOnlyDictionary<string, string> options,
          Guid accountUid)
  {
    var store = new ClassicSoloRaidRuntimeStateStore(dataSource);
    return store.ResolveOperationalBindingAsync(
        accountUid,
        RequiredPositiveInteger(options, "season-number"));
  }

  internal static async Task CaptureAsync(IReadOnlyDictionary<string, string> options)
  {
    var sourcePath = RequiredPath(options, "source-db");
    var pendingPath = RequiredPath(options, "pending-payload");
    var receiptPath = RequiredPath(options, "receipt");
    Require(File.Exists(sourcePath), "phase_d_raid_state_source_missing");
    Require(!File.Exists(pendingPath) && !File.Exists(receiptPath),
        "phase_d_raid_state_capture_output_exists");
    var binding = ReadBinding(options);
    var launchUid = RequiredGuid(options, "launch-context-uid");
    var expectedHead = OptionalGuid(options, "expected-head-revision-uid");
    var secret = ReadIdentitySecret(options);
    try
    {
      var core = JsonConvert.DeserializeObject<CoreInfo>(await File.ReadAllTextAsync(sourcePath)) ??
          throw new InvalidOperationException("phase_d_raid_state_source_invalid");
      Require(core.Users.Count == 1, "phase_d_raid_state_source_user_cardinality_invalid");
      var payload = Extract(core.Users[0]);
      ValidatePayload(payload);
      var clear = Encoding.UTF8.GetBytes(JsonConvert.SerializeObject(payload, Formatting.None));
      try
      {
        var contentSha256 = SHA256.HashData(clear);
        var protectedPayload = Protect(clear, secret, AssociatedData(binding));
        try
        {
          var metrics = ProjectMetrics(payload);
          var capturedAtUtc = DateTimeOffset.UtcNow;
          var protectedPayloadSha256 = SHA256.HashData(protectedPayload);
          var requestCapture = new ClassicSoloRaidRuntimeStateCapture(
              StoreKey(binding),
              launchUid,
              expectedHead,
              new byte[32],
              binding.AccountRevisionSetSha256,
              protectedPayload,
              protectedPayloadSha256,
              contentSha256,
              metrics.StatePresent,
              metrics.HasOpenRun,
              metrics.CompletedBestTotalDamage,
              metrics.CompletedBestTeamCount,
              metrics.OpenTeamCount,
              metrics.RaidDateDay,
              capturedAtUtc);
          var requestSha256 =
              ClassicSoloRaidRuntimeStateStore.ComputeRequestSha256(requestCapture);
          var receipt = new CaptureReceipt(
              1,
              CaptureContractId,
              capturedAtUtc,
              launchUid,
              binding.AccountUid,
              LowerHex(binding.AccountRevisionSetSha256),
              binding.SeasonNumber,
              binding.RaidSnapshotUid,
              LowerHex(binding.RaidSnapshotSha256),
              binding.ClientBuildCode,
              LowerHex(binding.ClientExecutableSha256),
              expectedHead,
              LowerHex(requestSha256),
              protectedPayload.Length,
              LowerHex(protectedPayloadSha256),
              LowerHex(contentSha256),
              metrics.StatePresent,
              metrics.HasOpenRun,
              metrics.CompletedBestTotalDamage,
              metrics.CompletedBestTeamCount,
              metrics.OpenTeamCount,
              metrics.RaidDateDay,
              LowerHex(SHA256.HashData(await File.ReadAllBytesAsync(sourcePath))),
              false);
          var pendingEnvelope = new PendingEnvelope(
              1,
              "nll/phase-d-classic-solo-raid-state-pending/v1",
              receipt,
              Convert.ToBase64String(protectedPayload));
          await WriteAtomicJsonAsync(pendingPath, pendingEnvelope);
          await WriteAtomicJsonAsync(receiptPath, receipt);
          Console.WriteLine(System.Text.Json.JsonSerializer.Serialize(receipt, JsonOptions()));
        }
        finally
        {
          CryptographicOperations.ZeroMemory(protectedPayload);
        }
      }
      finally
      {
        CryptographicOperations.ZeroMemory(clear);
      }
    }
    finally
    {
      CryptographicOperations.ZeroMemory(secret);
    }
  }

  internal static async Task PersistAsync(IReadOnlyDictionary<string, string> options)
  {
    var pendingPath = RequiredPath(options, "pending-payload");
    var captureReceiptPath = RequiredPath(options, "capture-receipt");
    var persistenceReceiptPath = RequiredPath(options, "receipt");
    Require(File.Exists(pendingPath), "phase_d_raid_state_pending_input_missing");
    var pendingDocument = await File.ReadAllBytesAsync(pendingPath);
    var pendingDocumentSha256 = LowerHex(SHA256.HashData(pendingDocument));
    var envelope = System.Text.Json.JsonSerializer.Deserialize<PendingEnvelope>(
        pendingDocument, JsonOptions()) ??
        throw new InvalidOperationException("phase_d_raid_state_pending_payload_invalid");
    Require(envelope.SchemaVersion == 1 &&
            envelope.ContractId == "nll/phase-d-classic-solo-raid-state-pending/v1",
        "phase_d_raid_state_pending_payload_invalid");
    var capture = envelope.Capture;
    ValidateCaptureReceipt(capture);
    if (File.Exists(captureReceiptPath))
    {
      var separateReceipt = System.Text.Json.JsonSerializer.Deserialize<CaptureReceipt>(
          await File.ReadAllTextAsync(captureReceiptPath), JsonOptions());
      Require(separateReceipt == capture, "phase_d_raid_state_capture_receipt_mismatch");
    }
    else
    {
      await WriteAtomicJsonAsync(captureReceiptPath, capture);
    }
    var captureReceiptSha256 = LowerHex(SHA256.HashData(
        await File.ReadAllBytesAsync(captureReceiptPath)));
    var binding = BindingFrom(capture);
    byte[] protectedPayload;
    try { protectedPayload = Convert.FromBase64String(envelope.ProtectedPayloadBase64); }
    catch (FormatException)
    {
      throw new InvalidOperationException("phase_d_raid_state_pending_payload_invalid");
    }
    Require(protectedPayload.Length == capture.ProtectedPayloadByteLength &&
            LowerHex(SHA256.HashData(protectedPayload)) == capture.ProtectedPayloadSha256,
        "phase_d_raid_state_pending_payload_invalid");
    var secret = ReadIdentitySecret(options);
    try
    {
      var clear = Unprotect(protectedPayload, secret, AssociatedData(binding));
      try
      {
        Require(LowerHex(SHA256.HashData(clear)) == capture.StateContentSha256,
            "phase_d_raid_state_content_hash_mismatch");
        var payload = JsonConvert.DeserializeObject<StatePayload>(Encoding.UTF8.GetString(clear)) ??
            throw new InvalidOperationException("phase_d_raid_state_payload_invalid");
        ValidatePayload(payload);
        Require(ProjectMetrics(payload) == MetricsFrom(capture),
            "phase_d_raid_state_capture_metrics_mismatch");
      }
      finally
      {
        CryptographicOperations.ZeroMemory(clear);
      }

      var connectionString = ReadEnvironment(options, "connection-string-env",
          "phase_d_database_environment_missing");
      await using var dataSource = NpgsqlDataSource.Create(connectionString);
      var store = new ClassicSoloRaidRuntimeStateStore(dataSource);
      var captureRow = new ClassicSoloRaidRuntimeStateCapture(
          StoreKey(binding),
          capture.LaunchContextUid,
          capture.ExpectedHeadRevisionUid,
          new byte[32],
          binding.AccountRevisionSetSha256,
          protectedPayload,
          FromHex(capture.ProtectedPayloadSha256),
          FromHex(capture.StateContentSha256),
          capture.StatePresent,
          capture.HasOpenRun,
          capture.CompletedBestTotalDamage,
          capture.CompletedBestTeamCount,
          capture.OpenTeamCount,
          capture.RaidDateDay,
          capture.CapturedAtUtc);
      var requestSha256 = ClassicSoloRaidRuntimeStateStore.ComputeRequestSha256(captureRow);
      Require(LowerHex(requestSha256) == capture.RequestSha256,
          "phase_d_raid_state_request_hash_mismatch");
      captureRow = captureRow with { RequestSha256 = requestSha256 };
      var result = await store.PersistAsync(captureRow);
      var persistenceReceipt = new
      {
        schemaVersion = 1,
        contractId = PersistenceContractId,
        persistedAtUtc = DateTimeOffset.UtcNow,
        launchContextUid = capture.LaunchContextUid,
        accountUid = capture.AccountUid,
        accountRevisionSetSha256 = capture.AccountRevisionSetSha256,
        seasonNumber = capture.SeasonNumber,
        raidSnapshotUid = capture.RaidSnapshotUid,
        raidSnapshotSha256 = capture.RaidSnapshotSha256,
        clientBuildCode = capture.ClientBuildCode,
        clientExecutableSha256 = capture.ClientExecutableSha256,
        expectedHeadRevisionUid = capture.ExpectedHeadRevisionUid,
        pendingPayloadSha256 = pendingDocumentSha256,
        captureReceiptSha256,
        protectedPayloadSha256 = capture.ProtectedPayloadSha256,
        requestSha256 = LowerHex(requestSha256),
        stateContentSha256 = capture.StateContentSha256,
        resultCode = result.ResultCode,
        headRevisionUid = result.HeadRevisionUid,
        resultStateContentSha256 = LowerHex(result.ResultStateContentSha256),
        stateAdvanced = result.StateAdvanced,
        quarantined = result.Quarantined,
        exactReplay = result.ExactReplay,
        pendingPayloadDeleted = false,
        rawSourceIdentifierPersistedAsColumn = false
      };
      await WriteAtomicJsonAsync(
          persistenceReceiptPath,
          persistenceReceipt,
          replaceExisting: true);
      Console.WriteLine(System.Text.Json.JsonSerializer.Serialize(
          persistenceReceipt, JsonOptions()));
      var allowQuarantined = options.TryGetValue("allow-quarantined", out var value) &&
          value == "true";
      Require(!result.Quarantined || allowQuarantined,
          "phase_d_raid_state_persistence_quarantined");
    }
    finally
    {
      CryptographicOperations.ZeroMemory(secret);
      CryptographicOperations.ZeroMemory(protectedPayload);
    }
  }

  internal static async Task<ClassicSoloRaidRestoreProjection> RestoreAsync(
      User user,
      NpgsqlDataSource dataSource,
      byte[] identitySecret,
      IReadOnlyDictionary<string, string> options,
      Guid accountUid,
      ClassicSoloRaidRuntimeOperationalBinding operationalBinding,
      byte[] currentProfileRevisionSetSha256)
  {
    Require(operationalBinding.LocalAccountUid == accountUid &&
            operationalBinding.SeasonNumber ==
                RequiredPositiveInteger(options, "season-number") &&
            operationalBinding.RaidSnapshotUid != Guid.Empty &&
            operationalBinding.RaidSnapshotSha256.Length == 32,
        "phase_d_raid_state_operational_binding_invalid");
    var binding = new Binding(
        accountUid,
        currentProfileRevisionSetSha256,
        operationalBinding.SeasonNumber,
        operationalBinding.RaidSnapshotUid,
        operationalBinding.RaidSnapshotSha256,
        RequiredControlledCode(options, "client-build-code"),
        RequiredSha256(options, "client-executable-sha256"));
    var store = new ClassicSoloRaidRuntimeStateStore(dataSource);
    var head = await store.GetHeadAsync(StoreKey(binding));
    var sourceBinding = binding;
    var inheritedCompletedRecord = false;
    if (head is null && binding.ClientBuildCode == "build_151.8.5" &&
        LowerHex(binding.ClientExecutableSha256) ==
            "36fa20306d010087cdb336bbbb8a6718013d4a16838178045b1270af631b1732")
    {
      // Operator-approved 150 -> 151 transition, same account/season/snapshot.
      // Existing 151 state always wins. Read the immutable old head using its
      // original authenticated binding; never overwrite or relabel that row.
      sourceBinding = binding with
      {
        ClientBuildCode = "build_150.6.9",
        ClientExecutableSha256 = FromHex(
            "2cfaa12b7d708aa6a741faee17c3ac14d8e9cd6be1b5e4e773ee1535b6ddaa30")
      };
      head = await store.GetHeadAsync(StoreKey(sourceBinding));
      inheritedCompletedRecord = head is not null;
    }
    if (head is null)
    {
      return new ClassicSoloRaidRestoreProjection(
          false, false, null, null, null, 0, 0, false, false, false);
    }

    var clear = Unprotect(head.ProtectedPayload, identitySecret, AssociatedData(new Binding(
        binding.AccountUid,
        head.SourceProfileRevisionSetSha256,
        binding.SeasonNumber,
        binding.RaidSnapshotUid,
        binding.RaidSnapshotSha256,
        sourceBinding.ClientBuildCode,
        sourceBinding.ClientExecutableSha256)));
    try
    {
      Require(CryptographicOperations.FixedTimeEquals(
              SHA256.HashData(clear), head.StateContentSha256),
          "phase_d_raid_state_content_hash_mismatch");
      var payload = JsonConvert.DeserializeObject<StatePayload>(Encoding.UTF8.GetString(clear)) ??
          throw new InvalidOperationException("phase_d_raid_state_payload_invalid");
      var legacyPartialCompletion =
          head.CompletedBestTeamCount is >= 1 and <= 4;
      ValidatePayload(payload, allowLegacyPartialCompletion: legacyPartialCompletion);
      var storedMetrics = ProjectMetrics(payload);
      Require(storedMetrics.StatePresent == head.StatePresent &&
              storedMetrics.HasOpenRun == head.HasOpenRun &&
              storedMetrics.CompletedBestTotalDamage == head.CompletedBestTotalDamage &&
              storedMetrics.CompletedBestTeamCount == head.CompletedBestTeamCount &&
              storedMetrics.OpenTeamCount == head.OpenTeamCount &&
              storedMetrics.RaidDateDay == head.RaidDateDay,
          "phase_d_raid_state_head_metrics_mismatch");
      if (legacyPartialCompletion)
      {
        payload.Raid!.SoloRaidLevels.RemoveAll(static level =>
            level.RaidLevel == 8 && (int)level.Type == 2 &&
            !level.IsOpen && level.RaidJoinCount is >= 1 and <= 4);
        ValidatePayload(payload);
      }
      var metrics = ProjectMetrics(payload);
      if (inheritedCompletedRecord)
      {
        if (metrics.CompletedBestTeamCount != 5)
        {
          return new ClassicSoloRaidRestoreProjection(
              false, false, null, null, null, 0, 0, false, false, legacyPartialCompletion);
        }
        RuntimeCompletedRaidMigration.KeepCompletedOnly(payload.Raid!);
        ValidatePayload(payload);
        metrics = ProjectMetrics(payload);
      }
      var openRunDiscardedForProfileRevisionMismatch = false;
      if (!payload.StatePresent)
      {
        return new ClassicSoloRaidRestoreProjection(
            true, false, head.RevisionUid, LowerHex(head.StateContentSha256),
            null, 0, 0, false, false, legacyPartialCompletion);
      }

      var profileMatches = CryptographicOperations.FixedTimeEquals(
          head.SourceProfileRevisionSetSha256, currentProfileRevisionSetSha256);
      if (!profileMatches && metrics.HasOpenRun)
      {
        // A partial Challenge run is profile-bound, but a completed five-team
        // best is not. Apply the same state transition as the lobby Quit action:
        // discard exactly the open Trial and release its open counter while
        // retaining the closed best record for the new profile revision.
        var removedOpenRuns = payload.Raid!.SoloRaidLevels.RemoveAll(static level =>
            level.RaidLevel == 8 && (int)level.Type == 2 && level.IsOpen);
        Require(removedOpenRuns == 1 && payload.Raid.TrialCount > 0,
            "phase_d_active_raid_profile_revision_mismatch");
        payload.Raid.TrialCount--;
        ValidatePayload(payload);
        metrics = ProjectMetrics(payload);
        Require(!metrics.HasOpenRun,
            "phase_d_active_raid_profile_revision_mismatch");
        openRunDiscardedForProfileRevisionMismatch = true;
      }
      user.SelectedClassicSoloRaidManagerId = payload.SelectedManagerId;
      user.SoloRaidData[payload.SelectedManagerId!.Value] = payload.Raid!;
      return new ClassicSoloRaidRestoreProjection(
          true,
          true,
          inheritedCompletedRecord ? null : head.RevisionUid,
          inheritedCompletedRecord ? null : LowerHex(head.StateContentSha256),
          metrics.CompletedBestTotalDamage,
          metrics.CompletedBestTeamCount,
          metrics.OpenTeamCount,
          metrics.HasOpenRun,
          openRunDiscardedForProfileRevisionMismatch,
          legacyPartialCompletion)
      {
        InheritedCompletedRecordFromBuild = inheritedCompletedRecord ? sourceBinding.ClientBuildCode : null,
        InheritedSourceRevisionUid = inheritedCompletedRecord ? head.RevisionUid : null
      };
    }
    finally
    {
      CryptographicOperations.ZeroMemory(clear);
    }
  }

  private static StatePayload Extract(User user)
  {
    var selected = user.SelectedClassicSoloRaidManagerId;
    if (!selected.HasValue)
    {
      Require(user.SoloRaidData.Count == 0, "phase_d_raid_state_selection_missing");
      return new StatePayload(1, PayloadContractId, false, null, null);
    }
    if (selected.Value <= 0)
    {
      throw new InvalidOperationException("phase_d_raid_state_selection_invalid");
    }
    if (!user.SoloRaidData.TryGetValue(selected.Value, out var raid) || raid is null)
    {
      Require(user.SoloRaidData.Count == 0, "phase_d_raid_state_selection_invalid");
      return new StatePayload(1, PayloadContractId, false, null, null);
    }
    Require(user.SoloRaidData.Count == 1 && raid.RaidId == selected.Value,
        "phase_d_raid_state_selection_invalid");
    var completedBest = raid.SoloRaidLevels
        .Where(static level => level.RaidLevel == 8 && (int)level.Type == 2 &&
            !level.IsOpen && level.IsClear && (int)level.Status == 1 &&
            level.RaidJoinCount == 5 && level.Logs.Count == 5)
        .OrderByDescending(static level => level.TotalDamage)
        .ThenByDescending(static level => level.Logs.Count)
        .FirstOrDefault();
    var openTrials = raid.SoloRaidLevels
        .Where(static level => level.RaidLevel == 8 && (int)level.Type == 2 && level.IsOpen)
        .ToArray();
    Require(openTrials.Length <= 1, "phase_d_raid_state_open_level_invalid");
    var minimal = new SoloRaidInfo
    {
      RaidId = raid.RaidId,
      RaidOpenCount = raid.RaidOpenCount,
      TrialCount = raid.TrialCount,
      LastDateDay = raid.LastDateDay,
      SoloRaidLevels = []
    };
    if (completedBest is not null) minimal.SoloRaidLevels.Add(CloneLevel(completedBest));
    if (openTrials.Length == 1) minimal.SoloRaidLevels.Add(CloneLevel(openTrials[0]));
    return new StatePayload(1, PayloadContractId, true, selected, minimal);
  }

  private static void ValidatePayload(
      StatePayload payload,
      bool allowLegacyPartialCompletion = false)
  {
    Require(payload.SchemaVersion == 1 && payload.ContractId == PayloadContractId,
        "phase_d_raid_state_payload_invalid");
    if (!payload.StatePresent)
    {
      Require(payload.SelectedManagerId is null && payload.Raid is null,
          "phase_d_raid_state_payload_invalid");
      return;
    }
    var raid = payload.Raid;
    if (payload.SelectedManagerId is not > 0 || raid is null ||
        raid.RaidId != payload.SelectedManagerId ||
        raid.RaidOpenCount < 0 || raid.TrialCount < 0 || raid.LastDateDay < 0 ||
            raid.SoloRaidLevels.Count > 2)
    {
      throw new InvalidOperationException("phase_d_raid_state_payload_invalid");
    }
    var levelKeys = new HashSet<(int RaidLevel, int Type, bool Open)>();
    foreach (var level in raid.SoloRaidLevels)
    {
      Require(level.RaidLevel == 8 && (int)level.Type == 2 &&
              level.RaidJoinCount is >= 0 and <= 5 &&
              level.Hp >= 0 && level.TotalDamage >= 0 &&
              level.Logs.Count <= 5 &&
              levelKeys.Add((level.RaidLevel, (int)level.Type, level.IsOpen)),
          "phase_d_raid_state_level_invalid");
      if (level.IsOpen)
      {
        Require(!level.IsClear && (int)level.Status == 0 &&
                level.RaidJoinCount <= 4 &&
                level.Logs.Count == level.RaidJoinCount,
            "phase_d_raid_state_open_level_invalid");
      }
      else
      {
        Require(level.IsClear && (int)level.Status == 1 &&
                (allowLegacyPartialCompletion
                    ? level.RaidJoinCount is >= 1 and <= 5
                    : level.RaidJoinCount == 5) &&
                level.Logs.Count == level.RaidJoinCount,
            "phase_d_raid_state_completed_level_invalid");
      }
      foreach (var log in level.Logs)
      {
        Require(log.Damage >= 0 && log.Team.Count <= 5,
            "phase_d_raid_state_log_invalid");
        var slots = new HashSet<int>();
        foreach (var member in log.Team)
        {
          Require(member.Slot is >= 0 and <= 5 && slots.Add(member.Slot) &&
                  member.Csn > 0 && member.Tid > 0 && member.Lv >= 0 &&
                  member.Combat >= 0 && member.CostumeId >= 0,
              "phase_d_raid_state_team_invalid");
        }
      }
    }
  }

  private static SoloRaidLevelData CloneLevel(SoloRaidLevelData level) =>
      JsonConvert.DeserializeObject<SoloRaidLevelData>(
          JsonConvert.SerializeObject(level, Formatting.None)) ??
      throw new InvalidOperationException("phase_d_raid_state_level_clone_failed");

  private static StateMetrics ProjectMetrics(StatePayload payload)
  {
    if (!payload.StatePresent)
    {
      return new StateMetrics(false, false, null, 0, 0, null);
    }
    var levels = payload.Raid!.SoloRaidLevels;
    var completed = levels
        .Where(static level => level.RaidLevel == 8 && (int)level.Type == 2 &&
            !level.IsOpen && level.IsClear && (int)level.Status == 1)
        .OrderByDescending(static level => level.TotalDamage)
        .ThenByDescending(static level => level.Logs.Count)
        .FirstOrDefault();
    var open = levels.Where(static level => level.IsOpen).ToArray();
    return new StateMetrics(
        true,
        open.Length != 0,
        completed?.TotalDamage,
        completed?.Logs.Count ?? 0,
        open.Length == 0 ? 0 : open.Max(static level => level.RaidJoinCount),
        payload.Raid.LastDateDay);
  }

  private static StateMetrics MetricsFrom(CaptureReceipt receipt) => new(
      receipt.StatePresent,
      receipt.HasOpenRun,
      receipt.CompletedBestTotalDamage,
      receipt.CompletedBestTeamCount,
      receipt.OpenTeamCount,
      receipt.RaidDateDay);

  private static Binding ReadBinding(
      IReadOnlyDictionary<string, string> options,
      Guid? knownAccountUid = null,
      byte[]? knownProfileRevisionSetSha256 = null)
  {
    var accountUid = knownAccountUid ?? RequiredGuid(options, "account-uid");
    var profile = knownProfileRevisionSetSha256 ??
        RequiredSha256(options, "account-revision-set-sha256");
    return new Binding(
        accountUid,
        profile,
        RequiredPositiveInteger(options, "season-number"),
        RequiredGuid(options, "raid-snapshot-uid"),
        RequiredSha256(options, "raid-snapshot-sha256"),
        RequiredControlledCode(options, "client-build-code"),
        RequiredSha256(options, "client-executable-sha256"));
  }

  private static Binding BindingFrom(CaptureReceipt receipt) => new(
      receipt.AccountUid,
      FromHex(receipt.AccountRevisionSetSha256),
      receipt.SeasonNumber,
      receipt.RaidSnapshotUid,
      FromHex(receipt.RaidSnapshotSha256),
      receipt.ClientBuildCode,
      FromHex(receipt.ClientExecutableSha256));

  private static ClassicSoloRaidRuntimeStateKey StoreKey(Binding binding) => new(
      binding.AccountUid,
      binding.SeasonNumber,
      binding.RaidSnapshotUid,
      binding.RaidSnapshotSha256,
      binding.ClientBuildCode,
      binding.ClientExecutableSha256);

  private static byte[] AssociatedData(Binding binding) => Encoding.UTF8.GetBytes(string.Join('\n',
      PayloadContractId,
      binding.AccountUid.ToString("D"),
      LowerHex(binding.AccountRevisionSetSha256),
      binding.SeasonNumber.ToString(CultureInfo.InvariantCulture),
      binding.RaidSnapshotUid.ToString("D"),
      LowerHex(binding.RaidSnapshotSha256),
      binding.ClientBuildCode,
      LowerHex(binding.ClientExecutableSha256)) + "\n");

  private static byte[] Protect(byte[] clear, byte[] secret, byte[] associatedData)
  {
    var key = DeriveProtectionKey(secret);
    var nonce = RandomNumberGenerator.GetBytes(12);
    var tag = new byte[16];
    var cipher = new byte[clear.Length];
    try
    {
      using var aes = new AesGcm(key, tag.Length);
      aes.Encrypt(nonce, clear, cipher, tag, associatedData);
      var result = new byte[ProtectedPayloadMagic.Length + nonce.Length + tag.Length + cipher.Length];
      ProtectedPayloadMagic.CopyTo(result, 0);
      nonce.CopyTo(result, ProtectedPayloadMagic.Length);
      tag.CopyTo(result, ProtectedPayloadMagic.Length + nonce.Length);
      cipher.CopyTo(result, ProtectedPayloadMagic.Length + nonce.Length + tag.Length);
      return result;
    }
    finally
    {
      CryptographicOperations.ZeroMemory(key);
      CryptographicOperations.ZeroMemory(nonce);
      CryptographicOperations.ZeroMemory(tag);
      CryptographicOperations.ZeroMemory(cipher);
      CryptographicOperations.ZeroMemory(associatedData);
    }
  }

  private static byte[] Unprotect(byte[] protectedPayload, byte[] secret, byte[] associatedData)
  {
    Require(protectedPayload.Length >= 53 &&
            protectedPayload.AsSpan(0, ProtectedPayloadMagic.Length)
                .SequenceEqual(ProtectedPayloadMagic),
        "phase_d_raid_state_protected_payload_invalid");
    var key = DeriveProtectionKey(secret);
    var nonce = protectedPayload.AsSpan(8, 12).ToArray();
    var tag = protectedPayload.AsSpan(20, 16).ToArray();
    var cipher = protectedPayload.AsSpan(36).ToArray();
    var clear = new byte[cipher.Length];
    try
    {
      using var aes = new AesGcm(key, tag.Length);
      aes.Decrypt(nonce, cipher, tag, clear, associatedData);
      return clear;
    }
    catch (CryptographicException)
    {
      CryptographicOperations.ZeroMemory(clear);
      throw new InvalidOperationException("phase_d_raid_state_protected_payload_invalid");
    }
    finally
    {
      CryptographicOperations.ZeroMemory(key);
      CryptographicOperations.ZeroMemory(nonce);
      CryptographicOperations.ZeroMemory(tag);
      CryptographicOperations.ZeroMemory(cipher);
      CryptographicOperations.ZeroMemory(associatedData);
    }
  }

  private static byte[] DeriveProtectionKey(byte[] secret) => HMACSHA256.HashData(
      secret,
      Encoding.UTF8.GetBytes("nll/phase-d-classic-solo-raid-runtime-state-key/v1"));

  private static byte[] CaptureRequestSha256(CaptureReceipt capture)
  {
    var canonical = string.Join('\n',
        capture.ContractId,
        capture.LaunchContextUid.ToString("D"),
        capture.AccountUid.ToString("D"),
        capture.AccountRevisionSetSha256,
        capture.SeasonNumber.ToString(CultureInfo.InvariantCulture),
        capture.RaidSnapshotUid.ToString("D"),
        capture.RaidSnapshotSha256,
        capture.ClientBuildCode,
        capture.ClientExecutableSha256,
        capture.ExpectedHeadRevisionUid?.ToString("D") ?? "none",
        capture.ProtectedPayloadByteLength.ToString(CultureInfo.InvariantCulture),
        capture.ProtectedPayloadSha256,
        capture.StateContentSha256,
        capture.CapturedAtUtc.ToUniversalTime().ToString("O", CultureInfo.InvariantCulture)) + "\n";
    return SHA256.HashData(Encoding.UTF8.GetBytes(canonical));
  }

  private static void ValidateCaptureReceipt(CaptureReceipt receipt)
  {
    Require(receipt.SchemaVersion == 1 && receipt.ContractId == CaptureContractId &&
            receipt.LaunchContextUid != Guid.Empty && receipt.AccountUid != Guid.Empty &&
            IsLowerHexSha256(receipt.AccountRevisionSetSha256) &&
            receipt.SeasonNumber > 0 && receipt.RaidSnapshotUid != Guid.Empty &&
            IsLowerHexSha256(receipt.RaidSnapshotSha256) &&
            IsControlledCode(receipt.ClientBuildCode) &&
            IsLowerHexSha256(receipt.ClientExecutableSha256) &&
            IsLowerHexSha256(receipt.RequestSha256) &&
            receipt.ProtectedPayloadByteLength is >= 53 and <= 1_048_576 &&
            IsLowerHexSha256(receipt.ProtectedPayloadSha256) &&
            IsLowerHexSha256(receipt.StateContentSha256) &&
            IsLowerHexSha256(receipt.SourceDatabaseSha256) &&
            (!receipt.HasOpenRun || receipt.StatePresent) &&
            receipt.CompletedBestTotalDamage is null or >= 0 &&
            receipt.CompletedBestTeamCount is >= 0 and <= 5 &&
            receipt.OpenTeamCount is >= 0 and <= 4 &&
            !receipt.RawSourceIdentifierWrittenToReceipt,
        "phase_d_raid_state_capture_receipt_invalid");
  }

  private static byte[] ReadIdentitySecret(IReadOnlyDictionary<string, string> options)
  {
    var value = ReadEnvironment(options, "identity-secret-env",
        "phase_d_identity_environment_missing");
    try
    {
      var secret = Convert.FromBase64String(value);
      Require(secret.Length >= 32, "phase_d_identity_secret_invalid");
      return secret;
    }
    catch (FormatException)
    {
      throw new InvalidOperationException("phase_d_identity_secret_invalid");
    }
  }

  private static string ReadEnvironment(
      IReadOnlyDictionary<string, string> options,
      string option,
      string failureCode)
  {
    var name = RequiredText(options, option);
    Require(name.Length is >= 3 and <= 64 && name[0] is >= 'A' and <= 'Z' &&
            name.All(static character => character is >= 'A' and <= 'Z' or >= '0' and <= '9' or '_'),
        failureCode);
    var value = Environment.GetEnvironmentVariable(name);
    Require(!string.IsNullOrWhiteSpace(value), failureCode);
    return value!;
  }

  private static string RequiredPath(IReadOnlyDictionary<string, string> options, string name) =>
      Path.GetFullPath(RequiredText(options, name));

  private static string RequiredText(IReadOnlyDictionary<string, string> options, string name)
  {
    Require(options.TryGetValue(name, out var value) && !string.IsNullOrWhiteSpace(value),
        "phase_d_required_option_missing");
    return value!;
  }

  private static Guid RequiredGuid(IReadOnlyDictionary<string, string> options, string name)
  {
    Require(Guid.TryParse(RequiredText(options, name), out var value) && value != Guid.Empty,
        "phase_d_raid_state_binding_invalid");
    return value;
  }

  private static Guid? OptionalGuid(IReadOnlyDictionary<string, string> options, string name)
  {
    var text = RequiredText(options, name);
    if (text == "none") return null;
    Require(Guid.TryParse(text, out var value) && value != Guid.Empty,
        "phase_d_raid_state_binding_invalid");
    return value;
  }

  private static int RequiredPositiveInteger(
      IReadOnlyDictionary<string, string> options,
      string name)
  {
    Require(int.TryParse(RequiredText(options, name), NumberStyles.None,
                CultureInfo.InvariantCulture, out var value) && value > 0,
        "phase_d_raid_state_binding_invalid");
    return value;
  }

  private static byte[] RequiredSha256(
      IReadOnlyDictionary<string, string> options,
      string name)
  {
    var text = RequiredText(options, name);
    Require(IsLowerHexSha256(text), "phase_d_raid_state_binding_invalid");
    return FromHex(text);
  }

  private static string RequiredControlledCode(
      IReadOnlyDictionary<string, string> options,
      string name)
  {
    var value = RequiredText(options, name);
    Require(IsControlledCode(value), "phase_d_raid_state_binding_invalid");
    return value;
  }

  private static bool IsControlledCode(string value) =>
      value.Length is >= 1 and <= 64 && value[0] is >= 'a' and <= 'z' &&
      value.All(static character =>
          character is >= 'a' and <= 'z' or >= '0' and <= '9' or '.' or '_' or '-');

  private static bool IsLowerHexSha256(string value) =>
      value.Length == 64 && value.All(static character =>
          character is >= '0' and <= '9' or >= 'a' and <= 'f');

  private static byte[] FromHex(string value) => Convert.FromHexString(value);
  private static string LowerHex(byte[] value) => Convert.ToHexString(value).ToLowerInvariant();

  private static async Task WriteAtomicBytesAsync(string path, byte[] value)
  {
    Directory.CreateDirectory(Path.GetDirectoryName(path)!);
    var temporary = path + ".partial-" + Guid.NewGuid().ToString("N");
    await File.WriteAllBytesAsync(temporary, value);
    File.Move(temporary, path);
  }

  private static async Task WriteAtomicJsonAsync(
      string path,
      object value,
      bool replaceExisting = false)
  {
    Directory.CreateDirectory(Path.GetDirectoryName(path)!);
    var temporary = path + ".partial-" + Guid.NewGuid().ToString("N");
    await File.WriteAllTextAsync(
        temporary,
        System.Text.Json.JsonSerializer.Serialize(value, JsonOptions()) + "\n",
        new UTF8Encoding(false));
    File.Move(temporary, path, replaceExisting);
  }

  private static System.Text.Json.JsonSerializerOptions JsonOptions() => new()
  {
    PropertyNamingPolicy = System.Text.Json.JsonNamingPolicy.CamelCase,
    PropertyNameCaseInsensitive = true,
    WriteIndented = true
  };

  private static void Require(bool condition, string code)
  {
    if (!condition) throw new InvalidOperationException(code);
  }

  private sealed record Binding(
      Guid AccountUid,
      byte[] AccountRevisionSetSha256,
      int SeasonNumber,
      Guid RaidSnapshotUid,
      byte[] RaidSnapshotSha256,
      string ClientBuildCode,
      byte[] ClientExecutableSha256);

  private sealed record StatePayload(
      int SchemaVersion,
      string ContractId,
      bool StatePresent,
      int? SelectedManagerId,
      SoloRaidInfo? Raid);

  private sealed record StateMetrics(
      bool StatePresent,
      bool HasOpenRun,
      long? CompletedBestTotalDamage,
      int CompletedBestTeamCount,
      int OpenTeamCount,
      int? RaidDateDay);

  private sealed record PendingEnvelope(
      int SchemaVersion,
      string ContractId,
      CaptureReceipt Capture,
      string ProtectedPayloadBase64);

  private sealed record CaptureReceipt(
      int SchemaVersion,
      string ContractId,
      DateTimeOffset CapturedAtUtc,
      Guid LaunchContextUid,
      Guid AccountUid,
      string AccountRevisionSetSha256,
      int SeasonNumber,
      Guid RaidSnapshotUid,
      string RaidSnapshotSha256,
      string ClientBuildCode,
      string ClientExecutableSha256,
      Guid? ExpectedHeadRevisionUid,
      string RequestSha256,
      int ProtectedPayloadByteLength,
      string ProtectedPayloadSha256,
      string StateContentSha256,
      bool StatePresent,
      bool HasOpenRun,
      long? CompletedBestTotalDamage,
      int CompletedBestTeamCount,
      int OpenTeamCount,
      int? RaidDateDay,
      string SourceDatabaseSha256,
      bool RawSourceIdentifierWrittenToReceipt);
}
