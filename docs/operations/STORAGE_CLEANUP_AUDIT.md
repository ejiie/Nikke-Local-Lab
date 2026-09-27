# Local storage cleanup audit

> Current inventory: [2026-09-14 project-wide storage audit](PROJECT_STORAGE_AUDIT_20260914.md).
> The following September 1 sizes and paths are historical; do not apply them as a current deletion list.

## Status

This document records deferred cleanup candidates measured on 2026-09-01.
Nothing under `C:\NLL` was deleted during the audit. Apply these candidates only
when local disk pressure returns, after a fresh size and process audit.

The measured size of `C:\NLL` was approximately 77.14 GB.

## Approved deferred cleanup set

The following non-overlapping set can recover approximately 9.78 GB without
removing the sealed client, the canonical native cache, versioned runtime lanes,
the persistent database, or successful repair receipts.

### Receipt-backed repair scratch exporters

- Target shape:
  `C:\NLL\ControlCenter\staging\application-repairs\<repair-uid>\presentation-exporter`
- Selection: only repair directories that have the matching
  `C:\NLL\ControlCenter\source-free\application-repairs\<repair-uid>\repair.receipt.json`.
- Measured count: 36 exporter directories among 40 receipt-backed repair
  directories.
- Measured recoverable size: approximately 5.792 GB.
- Reason: `repair-nll-phase-d-control-center-application.ps1` creates each
  `presentation-exporter` by copying prepared materializer output and pinned
  runtime files for a single repair execution. It is scratch build input, not
  the durable source-free receipt or the installed application.
- Preserve the sibling `before` directory and the matching source-free receipt.

### Repair directories without a completed receipt

- Target shape:
  `C:\NLL\ControlCenter\staging\application-repairs\<repair-uid>`.
- Selection: the matching source-free directory does not contain
  `repair.receipt.json`.
- Measured count: 20 repair directories.
- Measured recoverable size: approximately 3.561 GB.
- This value includes approximately 3.217 GB of `presentation-exporter` data and
  approximately 0.344 GB of other incomplete repair staging data.
- Delete the whole unmatched repair directory rather than counting its exporter
  a second time.
- A source-free directory can exist without `repair.receipt.json`; directory
  existence alone is not proof of a completed repair.

### Rebuildable EpinelPS test and selector outputs

The following `bin` and `obj` outputs are ignored by Git and can be regenerated
from source when their tests or tools are needed again:

- `C:\NLL\EpinelPS\tests\EpinelPS.HandlerIsolation.Tests\bin`
- `C:\NLL\EpinelPS\tests\EpinelPS.HandlerIsolation.Tests\obj`
- `C:\NLL\EpinelPS\tests\EpinelPS.SelectedManager.Tests\bin`
- `C:\NLL\EpinelPS\tests\EpinelPS.SelectedManager.Tests\obj`
- `C:\NLL\EpinelPS\ServerSelector.Desktop\bin`
- `C:\NLL\EpinelPS\ServerSelector.Desktop\obj`
- `C:\NLL\EpinelPS\ServerSelector\bin`
- `C:\NLL\EpinelPS\ServerSelector\obj`
- `C:\NLL\EpinelPS\EpinelPS.Analyzers\bin`
- `C:\NLL\EpinelPS\EpinelPS.Analyzers\obj`
- `C:\NLL\EpinelPS\EpinelPS\obj`

Measured recoverable size: approximately 0.43 GB. Do not include the main
`EpinelPS\bin` directory in this cleanup class.

## Do not delete as build output

### Canonical EpinelPS native cache

Do not delete:

`C:\NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64\cache`

Its measured size was approximately 36.35 GB. Although it is under `bin`, it is
the canonical native cache used directly by the local compatibility runtime.
The 11 versioned EpinelPS runtime lanes under `C:\NLL\Runtime` point to it with
NTFS junctions; they are not 11 physical copies of the cache. Deleting or
cleaning the main output directory wholesale would break those lanes and many
checked-in start, repair, rollback, and verification scripts.

Do not run a blanket recursive deletion or broad clean against:

`C:\NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64`

The same runtime root also contains the current executable, database files, and
other compatibility state referenced by operational scripts.

### Other preserved data

Do not treat the following as disposable build duplicates:

- `C:\NLL\Clients\NIKKE-150.6.9-Physical` — sealed physical-client baseline,
  approximately 25.39 GB.
- `C:\NLL\Runtime` — versioned patched/observed runtime lanes and their logs,
  approximately 2.14 GB. Similar dependency files are intentional evidence and
  regression snapshots.
- `C:\NLL\ControlCenter\postgresql`, `state`, `session`, and `secrets` — local
  persistence and protected runtime state.
- Receipt-backed `application-repairs\<repair-uid>\before` directories — rollback
  images. They occupied approximately 2.18 GB across all measured repairs and
  require a separate retention decision rather than build-output cleanup.
- `C:\NLL\Backups`, `Evidence`, and source-free receipts.

## Execution guardrails

Before applying the deferred cleanup:

1. Stop Control Center, EpinelPS, PostgreSQL, and any repair/materializer process.
2. Recalculate sizes and repair-to-receipt matching; do not rely only on the
   counts in this document because new repairs can be created later.
3. Resolve every target to an absolute path and fail closed if it is outside the
   exact roots documented above.
4. Never recursively delete `C:\NLL`, `C:\NLL\EpinelPS`, the main EpinelPS
   `win-x64` output root, or `C:\NLL\ControlCenter` as a whole.
5. Delete receipt-backed `presentation-exporter` children and unmatched repair
   roots as two disjoint sets to avoid double-counting.
6. Verify that the sealed client, canonical cache junction targets, runtime
   lanes, database/state, `before` rollback images, and source-free receipts
   still exist after cleanup.

## Previously completed host cleanup

The storage incident that prompted this audit was primarily outside `C:\NLL`:

- 28 closed forked sub-agent session files were deleted from the Codex session
  store, recovering approximately 84.545 GB. The active parent session was
  preserved.
- Docker Desktop was uninstalled because the NLL Windows local runtime uses
  native PostgreSQL and does not depend on Docker Desktop, WSL2, or its VM.

These completed actions are historical context, not recurring cleanup
instructions. Never delete the active Codex session or an entire Codex session
store as part of the `C:\NLL` cleanup procedure.
