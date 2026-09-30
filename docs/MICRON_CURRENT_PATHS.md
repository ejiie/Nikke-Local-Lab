# Micron current path authority

Verified against the filesystem on 2026-09-27. Update this file whenever a selection pointer, client lane or
backup location changes; older receipts keep their historical paths.

## Current host

The active project OS is the Micron Windows installation and the operator profile is `C:\Users\nlloperator`.
Samsung remains a separately bootable general-purpose/game OS; its mounted `E:` volume is not an input or runtime
dependency of the Micron project lane.

Operator clarification on 2026-09-05: Micron **already is the separate experimental OS** for this compatibility lane.
Do not repeatedly request designation of Micron as an experimental OS. Per-run recovery, exact client/runtime pins,
scoped hosts/trust changes and process-tree isolation remain mandatory; this role statement alone does not certify that
a particular run passed those gates.

## Authoritative paths

| Role | Exact path | Mutation authority |
|---|---|---|
| Official current NIKKE installation | `C:\NIKKE` | The official launcher installs and updates it. Local Lab/EpinelPS tools may read approved inputs but must not patch it or use it as a private-server execution target. |
| Selected client | `C:\NLL\Clients\NIKKE-152.8.11-ResourceProbe` | Sealed 2026-09-17 (1,082 files / 20,890,819,394 bytes). The approved Epinel DLL and client-local certificate overlay are applied only to this clone. |
| Selected runtime bundle | `C:\NLL\Runtime\PhaseD152-v1` | Selected by `C:\NLL\ControlCenter\runtime-selection.private.json`. Current manifest `bundle.private.json` SHA-256 `2596c8b74616bcac688a34d5120f58ffe615a6b74669a754b097bf583731f091` (2026-09-30 boss pipeline install); each install re-seals it, so match the latest installation receipt rather than an older hash. |
| Retained 151 runtime bundles | `C:\NLL\Runtime\PhaseD151-v10`, `C:\NLL\Runtime\PhaseD151-v9` | Not selected. `PhaseD152-v1` pins v10 as `parentManifest`, and v10 pins v9, so neither may be deleted. A 151 rollback also needs the 151 client restored from D: and matching app/registry/pipeline/firewall selection. |
| Removed 151 client | `C:\NLL\Clients\NIKKE-151.8.5-ResourceProbe` (absent) | Verified archive: `D:\NikkeLocalLab\Backups\client-151-archive-20260917-01\NIKKE-151.8.5-ResourceProbe` (1,244 files / 20,430,992,968 bytes). Restore to the original C: path before selecting any 151 runtime; never execute the D: copy. |
| Removed 150 client | `C:\NLL\Clients\NIKKE-150.6.9-Physical` (absent) | Verified archive: `D:\NikkeLocalLab\Backups\client-150-archive-20260912-01\NIKKE-150.6.9-Physical` (39,504 files / 27,264,219,735 bytes). Archival only. |
| Independent cube-localization repair input | `C:\NLL\RuntimeInputs\CubeLocale-150-v1` | Two hash-pinned locale inputs for the cold Control Center repair; independent of any client tree. |
| Common boss registry | `C:\NLL\RuntimeInputs\CommonBossExecution\profiles` | `registry.json` lists seasons 7, 9, 10, 25, 26, 27, 29, 34, 39, 41. Written only by the boss publication step. |
| 152 native FX baseline and journal | `C:\NLL\RuntimeInputs\CommonBossExecution\native-fx-152.8.11` | Registered once at the 152 installation. Normal launch/cleanup use range transactions; do not rescan the whole store or reset the journal. |
| Retained 151 native FX baseline | `C:\NLL\RuntimeInputs\CommonBossExecution\native-fx` | Inactive since the 152 selection; keep unchanged and never reuse it for 152. |
| Control Center | `C:\NLL\ControlCenter` | Installed app, on-demand native PostgreSQL data (`postgresql\data`, port 55433), DPAPI secrets, session and state. Created only by the reviewed Phase D installer. |
| Active boss pipeline configuration | `C:\NLL\ControlCenter\boss-pipeline.active.json` | Re-sealed 2026-09-30 after the S1 merge; points to repository `artifacts/boss-pipeline-pinfix-20260930/configuration.installed.private.json`, SHA-256 `26ef4c9b54a4a6292b0d7c842ec6d6e03e2f25f968a5ef9d8a4ad89b76e39c80`. The native catalog tool remains in `artifacts/boss-pipeline-install-20260930/catalog-tool/`. Both Git-ignored folders are active dependencies and must be retained. Before installation, compare every configuration `path/sha256` and `<x>Path/<x>Sha256` pair. |
| BattleLog storage | `C:\ProgramData\NikkeLocalLab\BattleLogs`, `BattleAnalysis`, `Diagnostics` | Private ACL. No automatic deletion. |
| PostgreSQL 17 runtime | `C:\NLL\Runtime\PostgreSQL-17-native` | See [Windows PostgreSQL](operations/WINDOWS_NATIVE_POSTGRESQL_RUNTIME.md). |
| Active repository | `C:\Users\nlloperator\Documents\Github\Nikke-Local-Lab` | Normal source workspace. |
| Operator launcher | Desktop `NLL 지휘관 관리 도구.lnk` | The repair/smoke launcher source is `scripts/NLL-Phase-D-Repair-And-Smoke.cmd`; its former Desktop copy is absent. |
| Recovery backups | `D:\NikkeLocalLab\Backups` | Backup/Golden/checkpoint storage, not an active runtime. |
| Samsung-mounted game installation | `E:\NIKKE` | Out of scope on Micron. Do not read, update, copy from, or bind scripts to it. |

`C:\NIKKE` is **mutable official-current**, not the immutable Local Lab baseline. Immutability belongs to a separately
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
- FxProbe and UserValidation experiment clients were removed on 2026-09-15
  ([storage audit](archive/stabilization/PROJECT_STORAGE_AUDIT_20260914.md)).
- Earlier docs said v10's `server\cache` was a junction to v9. On 2026-09-27 it is a regular directory; the
  v9/v10 dependency is the manifest parent pin above.
