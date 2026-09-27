# Micron current path authority

## Current host

As of 2026-08-29, the active project OS is the Micron Windows installation and
the operator profile is `C:\Users\nlloperator`. Samsung remains a separately
bootable general-purpose/game OS; its mounted `E:` volume is not an input or
runtime dependency of the Micron project lane.

Operator clarification on 2026-09-05: Micron **already is the separate experimental
OS** for this compatibility lane. This is confirmation of the existing role,
not a new one-off exception for 151. Do not repeatedly request designation of
Micron as an experimental OS. Per-run recovery, exact client/runtime pins, scoped
hosts/trust changes and full process-tree non-loopback blocking remain mandatory;
this role statement alone does not certify that a particular run passed those gates.

## Authoritative paths

| Role | Exact path | Mutation authority |
|---|---|---|
| Official current NIKKE installation | `C:\NIKKE` | The official launcher may install and update it. Local Lab/EpinelPS tools must not patch it or use it as a private-server execution target. |
| Removed 150 client / original restore target | `C:\NLL\Clients\NIKKE-150.6.9-Physical` | Removed on explicit operator approval at 2026-09-12 12:42 KST after cold and full source/backup re-verification. Path is absent, not an active runtime. Restore here only if 150 rollback is requested. |
| Verified 150 archival copy | `D:\NikkeLocalLab\Backups\client-150-archive-20260912-01\NIKKE-150.6.9-Physical` | 39,504 files / 27,264,219,735 bytes, full manifest equality reverified before C: source removal. Backup retained. Archival only; no direct D: execution. |
| Independent cube-localization repair input | `C:\NLL\RuntimeInputs\CubeLocale-150-v1` | Two private, exact hash-pinned locale inputs for the cold Control Center repair. Independent of the old client tree; never committed. |
| Retired 151 client / restore target | `C:\NLL\Clients\NIKKE-151.8.5-ResourceProbe` | Removed after 152 installation and full D: backup verification on 2026-09-17. This path is absent. Restore the verified 151 archive here before selecting any retained 151 runtime; never execute the D: backup directly. |
| Verified 151 archival copy | `D:\NikkeLocalLab\Backups\client-151-archive-20260917-01\NIKKE-151.8.5-ResourceProbe` | 1,244 files / 20,430,992,968 bytes; source and backup SHA-256 matched for every file before C: removal. Manifest and restore instructions are in the parent backup directory. See `artifacts/apply-152-20260917/archive-151.receipt.json`. |
| Selected 152 Control Center client | `C:\NLL\Clients\NIKKE-152.8.11-ResourceProbe` | Installed and selected on 2026-09-17 14:53 KST after sealing all 1,082 original files / 20,890,819,394 bytes. Existing approved Epinel DLL and client-local certificate overlay applied only to this clone. Epinel resource response plus local latest-655 and 14 native catalog/signature files installed; operator confirmed the subsequent startup passed. Version-independent persistence and lobby Quit were subsequently installed; their actual-play acceptance remains separate. See `operations/CLIENT_152_COMPATIBILITY_ASSESSMENT.md`. |
| Retired FX experiment client | `C:\NLL\Clients\NIKKE-151.8.5-FxProbe-b5773fbb-214e-41b8-8c47-79257318fbe7` | Removed on operator cleanup instruction on 2026-09-15. Historical trial/rollback records remain; this path is absent and is not a current input. See `operations/PROJECT_STORAGE_AUDIT_20260914.md`. |
| Retired user-validation experiment client | `C:\NLL\Clients\NIKKE-151.8.5-UserValidation-6d0c2fbd-edb4-4d07-a6dd-5f32218e9a85` | Removed on operator cleanup instruction on 2026-09-15. Current v9 and retained v8/v6 use ResourceProbe. An old app configuration backup still names the retired experimental delivery; replaying that old experiment requires recreating its client. |
| Active repository | `C:\Users\nlloperator\Documents\Github\Nikke-Local-Lab` | Normal source workspace. |
| Local runtime/evidence/tool root | `C:\NLL` | Local Lab runtime procedures and sealed rollback contracts only. |
| Phase D persistent Control Center | `C:\NLL\ControlCenter` | On-demand native PostgreSQL data, DPAPI-protected local secrets, published loopback Admin app and source-free bootstrap receipt. It is created only by the reviewed Phase D installer and is not a Golden backup. |
| Active boss pipeline configuration | `C:\NLL\ControlCenter\boss-pipeline.active.json` | On 2026-09-19 points to repository `artifacts/battlelog-capture-20260919/path-fix/configuration.installed.private.json`, SHA-256 `f3d40cccbcb555f0c9436cad8c04c20c849bcc137ffbc59411911aab6872221f`. Adds bounded opt-in BattleLog diagnostics in CommonApplicationData with startup readiness, skip-status and byte-length logging. Boss images prefer Enikk then exact local bundles; all 42 current seasons cached from Enikk. Retains the repaired V0027 character-sync importer and all 152 runtime/raid inputs. Prior configurations remain available for rollback. See `artifacts/battlelog-capture-20260919/path-fix/installation.receipt.json`. |
| Selected Phase D 152 runtime bundle | `C:\NLL\Runtime\PhaseD152-v1` | Selected by `C:\NLL\ControlCenter\runtime-selection.private.json` on 2026-09-17. Manifest SHA-256 `183a95b87fb8bfb3cced21d4d38d7a9d8d01e728e6a8e0c9343eda01ff80fd6e`. Independent server cache, 152 pack/locales, shared profile v4 handling, immutable DB binding, version-independent raid and account-preference heads with original per-revision execution provenance. Union startup corrections accepted for lobby entry; Hard API lifecycle installed on 2026-09-18: `artifacts/union-api-20260917/installation.receipt.json` (eight files, schema 25, all 100 existing tables unchanged; protobuf/DB checks passed, original-client Hard battle acceptance pending). Earlier Union installation: `artifacts/union-raid-20260917/installation.receipt.json` (schema 24, all 97 existing tables unchanged; three local accounts joined NLL level 3; no Union season selected until UI confirmation). Union Hard catalog covers source seasons 24–45 with original behavior-only assembly; original-client Union UI/battle acceptance remains pending. Lobby Quit consumes an attempt at 0–4 teams without counting a completion; five teams count one completion. User acceptance of these latest changes is pending. |
| Retained Phase D 151 runtime bundle | `C:\NLL\Runtime\PhaseD151-v10` | Replaced by PhaseD152-v1 on 2026-09-17. Retained for rollback/history; not selected. v9 remains a dependency because v10's cache junction points to `v9\server\cache`; do not delete v9. A rollback requires restoring the 151 client from D: plus matching app/registry/pipeline/firewall selection, not merely switching this pointer. Prior selection and current upgrade backups are in `artifacts/apply-152-20260917/`. |
| Common boss registry | `C:\NLL\RuntimeInputs\CommonBossExecution\profiles` | Selected by PhaseD152-v1. S7/9/10/25/26/27/29/34 use rebuilt 152 profiles and common delivery; S41 was added through the UI backend pipeline on 2026-09-17. Old immutable profile files remain for history. Source-free repository registry remains separate. |
| Selected 152 physical FX baseline and journal | `C:\NLL\RuntimeInputs\CommonBossExecution\native-fx-152.8.11` | Registered once at 152 installation on 2026-09-17. Normal launch/cleanup use range transactions; do not rescan the whole store or reset the journal. |
| Retained 151 physical FX baseline and journal | `C:\NLL\RuntimeInputs\CommonBossExecution\native-fx` | R6 registered the 151 ResourceProbe store once on 2026-09-15. Inactive after the 152 selection; retained unchanged with historical range-transaction state. Do not reset it or reuse it for 152. |
| Phase D repair/smoke launcher | `C:\Users\nlloperator\Desktop\NLL Phase D Repair and Smoke.cmd` | Applies the reviewed app/start repair under UAC, then runs DPAPI/PostgreSQL/Admin API cold-start smoke. It does not update D: backup or game Golden. |
| Recovery backup authority | `D:\NikkeLocalLab\Backups` | Backup/Golden/checkpoint storage, not an active runtime. |
| Samsung-mounted game installation | `E:\NIKKE` | Out of scope on Micron. Do not read, update, copy from, or bind current scripts to it. |

`C:\NIKKE` is therefore **mutable official-current**, not the immutable Local
Lab baseline. Immutability belongs to a separately named, version/hash-sealed
copy under `C:\NLL\Clients`. An official update must never be redirected to the
frozen Phase3B2 lane.

## Official update and fresh-capture sequence

2026-09-18 00:36 KST: the Control Center startup wrapper and repository common
execution scripts were updated to keep PostgreSQL available during game runtime.
The completion/recovery path reuses a running cluster and starts only a stopped
one. Runtime bundle/server hashes and the operating DB schema/data are unchanged.
Receipt: `artifacts/union-db-lifecycle-20260918/installation.receipt.json`.
Original-client acceptance of the InitSuccess correction remains pending.

1. Preserve the verified 150 D: archive and its original rollback evidence.
   Its former C: path is absent; do not restore it merely for an official update.
2. Before the official launcher updates `C:\NIKKE`, preserve the current
   official tree under a new versioned name if an exact pre-update baseline is
   required. Do not overwrite the Phase3B2 derived lane.
3. Let the official launcher update only `C:\NIKKE`.
4. Start the official client from `C:\NIKKE`, enter the matching account/lobby
   context, allow the fresh `NKSD_TRIGGER_*` archive to be written, and close
   the client normally.
5. Run the Phase C same-capture gate only after the official client and all
   Local Lab runtimes are cold.
6. Treat the updated build as a new candidate. Do not silently repoint the
   existing `150.6.9` Local Lab lane or its receipts to it.

## Migration status

Samsung-to-Micron final delta and Micron live materialization have completed.
The active code, Codex state, raw-input locations, tools, evidence, runtime and
client lane are now the Micron `C:` paths above. D: remains the recovery
boundary. Historical migration staging and Samsung paths in older receipts are
provenance only and must not be interpreted as current execution paths.

The historical `C:\Recovered_OldSSD\NLL_PreWipe_20260822` source on Samsung was
removed by the operator after the verified migration. This does not authorize
cleanup of unrelated Samsung applications or `E:\NIKKE`.

## 150 archive (approved 2026-09-05; completed 2026-09-12)

The operator renewed the archive request while testing persistence in 151.
The selected v6 bootstrap/client use 151 and have no 150 client reference or runtime
reparse dependency. The two cube-localization repair inputs were independently
preserved and pinned; the repair script no longer reads the old client directory.
Historical 150 bootstrap/fallback code and sealed receipts remain historical, not
permission to silently change the current 151 selection.

Full source-before/source-after/destination manifests match SHA-256
`7afd6f48e14301b1cfb7ffe9bc50c339cfe5b49b440130196cccdcd64b448d7d`.
The historical copy receipt remains `copy_verified_source_retained`. After the
operator confirmed testing and explicitly approved removal, coldness and both full
manifests were reverified. The separate `retirement.receipt.json` records
`archived_source_removed` at 2026-09-12 12:42 KST. The C: source is absent and D:
backup retained; current 151/v6 pins and selection passed unchanged.
Preserve the original rollback evidence and restore the original C: path if 150
rollback is requested. This does not authorize D: execution, old-receipt edits,
official-install movement, or removal of shared historical runtime/seed folders.
See [CLIENT_150_ARCHIVE](operations/CLIENT_150_ARCHIVE.md).
