# Micron current path authority

Verified against the filesystem on 2026-09-27; official install row updated 2026-10-15, selection rows 2026-10-16. Update this file whenever a
selection pointer, client lane or backup location changes; older receipts keep their historical paths.

## Current host

The active project OS is the Micron Windows installation and the operator profile is `C:\Users\nlloperator`.
Samsung remains a separately bootable general-purpose/game OS. On 2026-10-15 the operator designated the official
installation on its `E:` volume (`E:\NIKKE`) as the official-current source for Micron; `C:\NIKKE` no longer exists.
Nothing else on `E:` is an input or runtime dependency of the Micron project lane.

Operator clarification on 2026-09-05: Micron **already is the separate experimental OS** for this compatibility lane.
Do not repeatedly request designation of Micron as an experimental OS. Per-run recovery, exact client/runtime pins,
scoped hosts/trust changes and process-tree isolation remain mandatory; this role statement alone does not certify that
a particular run passed those gates.

## Authoritative paths

| Role | Exact path | Mutation authority |
|---|---|---|
| Official current NIKKE installation | `E:\NIKKE` | Operator designation 2026-10-15 (`C:\NIKKE` was removed). The official launcher (`E:\NIKKE\Launcher`) installs and updates it. Local Lab/EpinelPS tools may read approved inputs and copy it into a new sealed clone, but must not patch it or use it as a private-server execution target. Its programs are the shared block-only firewall targets. |
| Selected client | `C:\NLL\Clients\NIKKE-152.8.13-ResourceProbe` | Sealed 2026-10-15 from `E:\NIKKE` (1,132 files / 18,900,314,878 bytes, no Korean voice store); selected by the 2026-10-16 installation, which applied the approved Epinel DLL and client-local certificate overlay to this clone only. |
| Selected runtime bundle | `C:\NLL\Runtime\PhaseD152-v2` | Selected by `C:\NLL\ControlCenter\runtime-selection.private.json`. Manifest SHA-256 `5c542bd2e0131387a6cc880534f775a1e3b7e1c9d4b913643cd571d48780f930` after the local resource guidance was supplied (2026-10-16); each install re-seals it, so match the latest receipt rather than an older hash. |
| Retained 152.8.11 client and runtime | `C:\NLL\Clients\NIKKE-152.8.11-ResourceProbe`, `C:\NLL\Runtime\PhaseD152-v1` | Not selected; kept for rollback until the 152.8.13 real-game check. `PhaseD152-v2` pins v1 as `parentManifest`, so v1 may not be deleted. A rollback also needs the v1 selection, registry, pipeline activation and firewall programs (backups in the installation folder). |
| 152.8.13 boss pipeline inputs | `C:\NLL\RuntimeInputs\BossPipeline\152.8.13-v1` | Native FX input plan and catalog tool pinned by the active pipeline configuration. Keep while it is active. |
| 152.8.13 installation folder | Repository `artifacts/apply-152.8.13-20261015/` (Git-ignored) | Rebuilt boss deliveries pinned by the registry, the active configuration (`runtime/configuration.private.json`), receipts and rollback backups. Active dependency; keep. |
| Client update staging | `C:\NLL\Staging\ClientUpdates\<build>-<date>` | Plan file (`client-update.plan.json`), evidence and server publish of each update ([client update order](operations/CLIENT_UPDATE.md)). |
| Retained 151 runtime bundles | `C:\NLL\Runtime\PhaseD151-v10`, `C:\NLL\Runtime\PhaseD151-v9` | Not selected. `PhaseD152-v1` pins v10 as `parentManifest`, and v10 pins v9, so neither may be deleted. A 151 rollback also needs the 151 client restored from D: and matching app/registry/pipeline/firewall selection. |
| Removed 151 client | `C:\NLL\Clients\NIKKE-151.8.5-ResourceProbe` (absent) | Verified archive: `D:\NikkeLocalLab\Backups\client-151-archive-20260917-01\NIKKE-151.8.5-ResourceProbe` (1,244 files / 20,430,992,968 bytes). Restore to the original C: path before selecting any 151 runtime; never execute the D: copy. |
| Removed 150 client | `C:\NLL\Clients\NIKKE-150.6.9-Physical` (absent) | Verified archive: `D:\NikkeLocalLab\Backups\client-150-archive-20260912-01\NIKKE-150.6.9-Physical` (39,504 files / 27,264,219,735 bytes). Archival only. |
| Moved Samsung→Micron migration staging | `C:\NLL\Migrations\SamsungToMicron` (absent) | Archive: `D:\NikkeLocalLab\Backups\migration-SamsungToMicron-v1\265861b9-9ff0-4e01-b409-7ce97c53aad1` (223,086 files / 129,838,692,663 bytes, private ACL kept). Archival only; no runtime, script or configuration reads it. |
| Independent cube-localization repair input | `C:\NLL\RuntimeInputs\CubeLocale-150-v1` | Two hash-pinned locale inputs for the cold Control Center repair; independent of any client tree. |
| Common boss registry | `C:\NLL\RuntimeInputs\CommonBossExecution\profiles` | `registry.json` lists seasons 7, 9, 10, 25, 26, 27, 29, 34, 39, 41, 42 (rebuilt for 152.8.13). Written only by the boss publication step. |
| 152.8.13 native FX baseline and journal | `C:\NLL\RuntimeInputs\CommonBossExecution\native-fx-152.8.13` | Registered once at the 152.8.13 installation. Normal launch/cleanup use range transactions; do not rescan the whole store or reset the journal. |
| Retained 152.8.11 native FX baseline | `C:\NLL\RuntimeInputs\CommonBossExecution\native-fx-152.8.11` | Inactive since the 152.8.13 selection; keep unchanged for a rollback. |
| Retained 151 native FX baseline | `C:\NLL\RuntimeInputs\CommonBossExecution\native-fx` | Inactive since the 152 selection; keep unchanged and never reuse it for 152. |
| Control Center | `C:\NLL\ControlCenter` | Installed app, on-demand native PostgreSQL data (`postgresql\data`, port 55433), DPAPI secrets, session and state. Created only by the reviewed Phase D installer. |
| Active boss pipeline configuration | `C:\NLL\ControlCenter\boss-pipeline.active.json` | Activated 2026-10-16 by the 152.8.13 installation; points to repository `artifacts/apply-152.8.13-20261015/runtime/configuration.private.json`, SHA-256 `8500388472ab1a4f143e47c9828f0c69fa6aa0b38653774f76e71a399bddf778` (repository head `99e0b11`). Before the next installation, compare every configuration `path/sha256` and `<x>Path/<x>Sha256` pair (`scripts/client-update/check-nll-config-pins.py`). Earlier configurations stay in their Git-ignored folders for retained season catalog revisions. |
| BattleLog storage | `C:\ProgramData\NikkeLocalLab\BattleLogs`, `BattleAnalysis`, `Diagnostics` | Private ACL. No automatic deletion. |
| PostgreSQL 17 runtime | `C:\NLL\Runtime\PostgreSQL-17-native` | See [Windows PostgreSQL](operations/WINDOWS_NATIVE_POSTGRESQL_RUNTIME.md). |
| Active repository | `C:\Users\nlloperator\Documents\Github\Nikke-Local-Lab` | Normal source workspace. |
| Operator launcher | Desktop `NLL 지휘관 관리 도구.lnk` | The repair/smoke launcher source is `scripts/NLL-Phase-D-Repair-And-Smoke.cmd`; its former Desktop copy is absent. |
| Recovery backups | `D:\NikkeLocalLab\Backups` | Backup/Golden/checkpoint storage, not an active runtime. |
| Former official installation | `C:\NIKKE` (absent) | Removed before 2026-10-15. Older receipts and the 152.8.11 firewall rules name it; it is provenance only. |

`E:\NIKKE` is **mutable official-current**, not the immutable Local Lab baseline. Immutability belongs to a separately
named, version/hash-sealed copy under `C:\NLL\Clients`. An official update is a new candidate; follow the
[client update order](operations/CLIENT_UPDATE.md) and never silently repoint an existing lane or receipt.
Account fresh-capture paths for the older Phase C fetch are in [PHASE_C_FRESH_CAPTURE_PATHS](operations/PHASE_C_FRESH_CAPTURE_PATHS.md).

## History

- Samsung→Micron migration finished on 2026-08-29; Samsung paths in older receipts are provenance only
  ([migration record](archive/SAMSUNG_TO_MICRON_MIGRATION.md)).
- 150 was archived and its C: copy removed on 2026-09-12 after full manifest re-verification
  ([150 archive](archive/client/CLIENT_150_ARCHIVE.md)).
- 152 replaced 151 on 2026-09-17; the 151 client was archived with every file hash matched
  ([152 assessment](archive/client/CLIENT_152_COMPATIBILITY_ASSESSMENT.md)).
- 152.8.13 replaced 152.8.11 on 2026-10-16 (operator-run elevated install, local resource guidance); the 152.8.11
  client stays on C: for rollback until the real-game check ([client update order](operations/CLIENT_UPDATE.md)).
- FxProbe and UserValidation experiment clients were removed on 2026-09-15
  ([storage audit](archive/stabilization/PROJECT_STORAGE_AUDIT_20260914.md)).
- Earlier docs said v10's `server\cache` was a junction to v9. On 2026-09-27 it is a regular directory; the
  v9/v10 dependency is the manifest parent pin above.
- The finished migration staging moved from C: to D: on 2026-10-03 after every file's SHA-256 matched
  (C: free 30.6 → 145.9 GiB). Records are in the Git-ignored `artifacts/storage-cleanup-20261001/`.
