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
| Selected 151 Control Center client (S26 first) | `C:\NLL\Clients\NIKKE-151.8.5-ResourceProbe` | On 2026-09-06 the operator confirmed actual-game validation after the existing-account integration and closed resource-change work. Keep the unchanged Epinel DLL and manifest-backed clone-only certificate overlay. S29 remains separately deferred. See `archive/RESOURCE_COMPATIBILITY_151_PROGRESS.md`. |
| Active repository | `C:\Users\nlloperator\Documents\Github\Nikke-Local-Lab` | Normal source workspace. |
| Local runtime/evidence/tool root | `C:\NLL` | Local Lab runtime procedures and sealed rollback contracts only. |
| Phase D persistent Control Center | `C:\NLL\ControlCenter` | On-demand native PostgreSQL data, DPAPI-protected local secrets, published loopback Admin app and source-free bootstrap receipt. It is created only by the reviewed Phase D installer and is not a Golden backup. |
| Selected Phase D 151 runtime bundle | `C:\NLL\Runtime\PhaseD151-v6` | Selected on 2026-09-12 by `C:\NLL\ControlCenter\runtime-selection.private.json` for P-01~P-09 persistence. Schema 21 and the matching Control Center app are installed. v5 remains intact; original client/native/certificate/firewall pins are unchanged. See `features/RUNTIME_PERSISTENCE.md` for verification and operator acceptance status. Contains pinned server/bootstrap/materializer files, not a replacement account DB. Do not move or modify an active bundle. |
| Phase D repair/smoke launcher | `C:\Users\nlloperator\Desktop\NLL Phase D Repair and Smoke.cmd` | Applies the reviewed app/start repair under UAC, then runs DPAPI/PostgreSQL/Admin API cold-start smoke. It does not update D: backup or game Golden. |
| Recovery backup authority | `D:\NikkeLocalLab\Backups` | Backup/Golden/checkpoint storage, not an active runtime. |
| Samsung-mounted game installation | `E:\NIKKE` | Out of scope on Micron. Do not read, update, copy from, or bind current scripts to it. |

`C:\NIKKE` is therefore **mutable official-current**, not the immutable Local
Lab baseline. Immutability belongs to a separately named, version/hash-sealed
copy under `C:\NLL\Clients`. An official update must never be redirected to the
frozen Phase3B2 lane.

## Official update and fresh-capture sequence

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
