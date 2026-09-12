# Solo Raid boss onboarding pipeline

> 상태 참고 (2026-09-06): 아래 S29 결과는 당시 admission 기록입니다. 현재 S29의 profile v3/등록 v2 불일치는 별도 보류이며, 151 실게임 완료는 S26 기준입니다. [안정화 계획](../STABILIZATION_PLAN.md)을 함께 확인합니다.

## Current automatic candidate stage — 2026-09-12

The common command now supports **`-CandidateOnly`**. It discovers the selected
season afresh, closes its original behavior tree, assembles v2 (closed no-QTE) or
v3 (elemental QTE), regenerates the isolated FX candidate, checks all five StaticData
round trips and writes `onboarding-verified-candidate.receipt.json` last. Its contract
is `nll/boss-onboarding-verified-candidate/v1`; status is
`verified_candidate_pending_runtime_delivery`, with runtime admission `not_assessed`.
There is no registry write, admission receipt, operating DB/server/client start or
installed-cache write in this lane. **Do not use this receipt as a UI import-success
or launch authorization until the delivery/publication/job contracts are implemented.**

The v3 assembler uses fresh discovery QTE hashes and derives the three FX transform
plans from actual local asset bytes; it does not copy the checked-in S29 draft.
Only the currently proved electric-source, boss-specific water/electric and common
fire/wind/iron, single-bundle family is supported. Other families fail closed rather
than guessing geometry. The separate FX candidate stage regenerates those derived
pins and verifies every transform boundary. Byte-backed UnityPy readers avoid leaving
Windows file handles open when the temporary owned probe directory is removed.

Final checks bind profile/discovery/behavior hashes, season and profile codes,
source/derived pack hashes, exact QTE and table-change counts, unchanged ElementTable,
and each selected FX mapping. Changed FX-bearing function counts must be positive
and within the closed shield set: S29 has three closed shield functions but only two
FX-bearing rows change. The compiled materializer additionally proves the exact row
boundary. All original behavior/five-FX asset pins and the isolated overlays are
rechecked at completion. Source pack/config/read-only seed/materializer/tool/registry
pins are compared before and after work.

Each candidate requires a new output directory; an existing success or partial failure
cannot be reused. Reparse ancestors and cache/registry/source-directory overlap are
rejected. A retry uses a new directory. Private discovery is deleted in `finally` on
both success and failure. This is single-output isolation, **not yet cross-request job
deduplication or atomic profile/registry publication**. Without `-CandidateOnly`, the
legacy v2 publication path is unchanged and still rejects elemental QTE; an additional
guard prevents v3 from entering that publication path.

Verification:

- 12 source-free Python test methods, including real PowerShell orchestration against
  synthetic tool outputs: partial five-variant failure, invalid QTE/FX, source drift,
  retry, duplicate output rejection, registry preservation and private cleanup.
- S29 and S26 fresh discovery→assembly→five-variant candidate runs, **10 local-data
  variants and three isolated FX overlays**, passed in
  `artifacts/boss-onboarding-checks/91e8c23bd7b546d09aeec5877741c756/receipt.json`.
  S29 candidate profile SHA-256 is
  `0c754f0c5910f569ff5ba5e61ab75b370d492c3d1b7cb1f8c0f7357406fa6bf7`.
  All 96 installed v6 pins, read-only seed and tracked registry/profile files remain
  unchanged. Initial failed attempts were not sealed and did not publish anything.
- Existing 29 FX synthetic tests and real FX create/verify/restore twice passed again;
  local receipt `artifacts/shield-fx-checks/16cad47968eb456d940758d3d2e30748/receipt.json`
  confirms the byte-backed reader reproduces all three prior expected bundle hashes.
- Windows and Linux CI run the source-free tests only. Local game files are never CI inputs.

Reproduce with a freshly built current-source materializer (same build instructions as
`test-nll-boss-qte-materializer.ps1`), the reviewed local Python/UnityPy installation,
and explicit sealed local inputs:

```powershell
pwsh -NoProfile -File scripts/test-nll-boss-onboarding-local.ps1 `
  -BundlePath C:\NLL\Runtime\PhaseD151-v6\bundle.private.json `
  -ExpectedBundleSha256 148ea9ae3e6a5759fd5075c7e25a2860331affc5644043a20a2869afcff8c9db `
  -MaterializerPath <current-source-offline-materializer> `
  -StaticDataPackPath <bundle-pinned-pack> -SourceDatabasePath <read-only-local-seed> `
  -PythonPath <local-python-executable> -UnityPyRoot <local-unitypy-directory>
python -B scripts/test-nll-boss-onboarding-candidate.py
```

Next: isolated original-client FX delivery with execution-specific rollback/cleanup,
then v3 preparation/coordinator admission and atomic publication/job API, followed by
the requested season-selection and Yes/No/completion UI. **S29 remains blocked**;
the old registry pin and installed v6 have not been promoted or changed.

## Current QTE stage — 2026-09-12

S29 repair and common onboarding improvements are now in progress. This is a
**source-only first stage, not S29 activation or a completed automatic pipeline**.
The materializer consumes the existing v3 QTE contract, validates the source row
digests/counts and changes only `ElementId` in target-linked QTE records. It checks
every other serialized field, all foreign rows and the encrypted pack round trip.
Receipts distinguish pending isolated FX overlay from prefab-reference changes and
explicitly leave runtime admission `not_assessed`.
Legacy profiles cannot silently leave elemental QTE unchanged when making a variant,
and v1/v2 profiles cannot carry v3-only fields outside their table allowlist.

At the QTE-only checkpoint the common Python assembler produced only v2. It required an explicit closed
no-QTE discovery. Missing discovery fails with `boss_profile_qte_discovery_missing`;
nonempty or inconsistent discovery fails with `boss_profile_qte_v3_pipeline_required`
**before writing a candidate**, instead of discarding QTE and publishing incomplete
five-affinity support. That default v2 guard is preserved; automatic candidate-only v3
assembly is now completed in the newer stage above.

Verification completed locally against the pinned 151/v6 dependencies:

- 37 compiled synthetic QTE behavior checks (five elements, legacy handling,
  source drift, foreign-row changes, immutable fields, count and table boundaries).
- Four Python unittest methods, including missing/malformed discovery subcases.
- Ten real local-data round trips: S26 and S29, each with all five weakness codes.
  S29 changes five QTE records for each non-default weakness; the default iron
  weakness changes none. S26 QTE remains untouched. Source/bundle hashes remain equal.
- These local checks are separate from source-only CI and original-client gameplay.

Reproduce with PowerShell 7 and the installed .NET 10 SDK (restore the local
materializer's locked dependencies first if its `obj` directory is absent):

```powershell
pwsh -NoProfile -File scripts/test-nll-boss-qte-materializer.ps1 `
  -BundlePath C:\NLL\Runtime\PhaseD151-v6\bundle.private.json `
  -ExpectedBundleSha256 148ea9ae3e6a5759fd5075c7e25a2860331affc5644043a20a2869afcff8c9db
python -B scripts/test-nll-boss-profile-qte.py
```

`-OfflineVariants` additionally requires explicit `-SourceDatabasePath` and
`-StaticDataPackPath`; the static pack and config must be pinned in that bundle.
Outputs go to a new ignored `artifacts/boss-qte-checks/<run>/` directory. The verified
local run is `a04c06ffc1b24d64ab78f03ae8aafede/receipt.json`. No operating PostgreSQL,
server or client is started, and no selected bundle/profile registry is updated.

Still pending after the newer candidate stage: original-client shield-FX delivery and
installed execution rollback; preparation/coordinator v3 admission; atomic
publication and job API; the season-selection UI. Never copy derived FX through the
current runtime cache junction because it shares the parent cache. S29's draft/pin
mismatch stays blocked until the complete replacement path is verified.

## Current isolated FX candidate stage — 2026-09-12

`materialize-nll-shield-fx-candidate.py` consumes an explicitly hash-pinned v3 profile
and read-only local cache. This is an **offline candidate stage, not full profile
admission, a delivery router or an installation updater**. Automatic v3 assembly now
calls this tool in the separate candidate-only stage above.
It resolves electric source and fire/wind/iron target bundles by exact length/hash,
copies their bytes into a new independent output folder and runs the existing
Transform materializer on those copies. Derived hashes, lengths and all six evidence
fields must equal the profile. Non-Transform objects, unmatched Transform bytes and
every matched Transform field except local position/rotation/scale remain unchanged.
Ambiguous transform identities, children, branches or leaf names fail closed.

The immutable, source-free `manifest.json` is written last, only after every candidate
file and original input passes verification. An interrupted creation has no manifest
and cannot be reused; keep it for diagnosis and use a new output folder on retry.
No source asset paths or identifiers are written into the manifest. The private copied
profile/source/backup/overlay files stay in ignored artifacts; never upload the folder.

`verify` and `restore` both require the caller's exact manifest SHA-256 and check its
profile binding and fixed role/path inventory. Restore preflights all backups, overlays
and partial files before replacing anything. It **only** restores this candidate's
three overlay files from its own pinned backups, not any installed/shared/client cache.
Unknown bytes, path substitution, symlinks/junctions, hard links and concurrent operations
are rejected. Interrupted replacements may resume from original/derived pinned states
and a pinned partial file. Foreign partial files are retained and rejected. A lock left
by a killed process is not automatically removed: establish that the owner stopped
before diagnosing it; the tool never assumes a stale lock permits concurrent mutation.

The manifest records the initial seal, not mutable readiness. After restore, `verify`
must fail (`shield_fx_candidate_overlay_drifted`). A consumer must run verification,
not infer readiness from the manifest's existence or `statusCode`. Every result keeps
`runtimeAdmissionStatusCode=not_assessed`. No candidate is registered or auto-started.

Source-only checks (no UnityPy/game inputs) run on both CI operating systems:

```powershell
python -B scripts/test-nll-shield-fx-candidate.py
python -B scripts/test-nll-actions-merge.py
```

The FX suite has 29 tests with mutation subcases, including interrupted create/restore,
idempotent recovery, drift, write isolation and transform boundaries. The separate Git
test uses a disposable synthetic repository to reproduce a non-fast-forward merge with
no global identity and verify the command-local bot identity fix without making a commit.

Reproduce all three actual local FX variants, verify, restore twice and reject the
restored candidate with the reviewed local UnityPy installation (observed version 1.25.3):

```powershell
pwsh -NoProfile -File scripts/test-nll-shield-fx-local.ps1 `
  -BundlePath C:\NLL\Runtime\PhaseD151-v6\bundle.private.json `
  -ExpectedBundleSha256 148ea9ae3e6a5759fd5075c7e25a2860331affc5644043a20a2869afcff8c9db `
  -PythonPath <local-python-executable> -UnityPyRoot <local-unitypy-directory>
```

The helper creates `artifacts/shield-fx-checks/<run>/receipt.json` and checks all 96
installed bundle pins before and after; it does not start DB/server/client or deploy.
Verified final run: `9ef9c5f5870d4d0f8c16bdd089cfe3e8`, candidate manifest SHA-256
`bc2fc7c5b88d7d0a87f10e66ccb02c3dd5e8e5a171df5daf158f82c447d11f14`.
All three derived bundle hashes equal the existing v3 profile. This is not evidence
that the original client received or displayed them; that delivery gate is still open.

## Purpose

`scripts/invoke-nll-boss-onboarding.ps1` is the common fail-closed path for adding a
Classic Solo Raid Challenge season. The operator supplies a season number and local,
sealed build inputs. The pipeline discovers the selected manager, skill closure,
behavior tree and affinity-shield closure instead of carrying a per-boss list of
original IDs.

The tracked result contains only source-free counts, contract codes and hashes.
Raw manager, monster, skill, function, behavior and prefab identifiers exist only in
an ephemeral private diagnostic under `%TEMP%`; the `finally` boundary deletes it.
The official `C:\NIKKE` installation is never an input or mutation target.

## Legacy v2 admission flow (not the v3 candidate lane)

1. `--discover-boss-content` resolves the season's unique Classic Challenge
   manager→preset→wave→target monster graph and closes skills, passives and functions.
2. `inspect-nll-boss-behavior-assets.py` tries the sealed build's behavior-bundle
   identities and admits exactly one bundle that contains every referenced
   `ExternalBehaviorTree`. It hashes the graph, task types, skill-animation, part and
   point references and rejects disabled or missing nodes.
3. `materialize-nll-boss-runtime-profile.py` assembles profile v2. For an elemental
   shield, it groups every source FX prefab set and resolves a source→target mapping
   for all five boss elements. A mapping may contain multiple FX assets and multiple
   bundles; exact boss-specific equivalents are preferred, followed by a semantic
   common-FX match.
4. The runtime materializer validates the source-free profile and produces isolated
   StaticData variants for 작열, 수냉, 풍압, 전격 and 철갑. Only the target monster's
   element reference and its closed shield-function FX prefab references may change.
5. All five round trips must pass before the profile is installed and enabled in
   `config/boss-runtime-variants/registry.json`.
6. Every actual launch rechecks the exact behavior bundle and selected shield-FX
   bundle identities in the sealed client cache before changing hosts or starting a
   process. Missing or drifted assets fail closed.
7. Server startup resolves exactly one manager whose canonical observation matches
   the selected runtime profile. It does not reuse the season-26 manager value from
   the parent launch context; zero or multiple matches fail closed before listeners.

The pipeline intentionally preserves the original behavior tree. “Behavior assembly”
means resolving and proving the complete original tree and its references; it does not
invent or simulate a boss pattern.

## Historical Season 29 result (v2; not current admission)

Season 29 Mother Whale is enabled as `season-29-mother-whale`.

- source affinity: 전격; weakness: 철갑
- monster skill relations / skill rows: 29 / 29
- passive state-effect rows: 1
- closed functions: 47 with zero missing references
- exact behavior trees: 1; nodes: 759; disabled nodes: 0
- elemental shield functions: 3; skill bindings: 3; passive bindings: 1
- five-affinity StaticData round trip: passed
- profile-driven unique startup target resolution: passed
- raw source identifiers persisted: false
- official install modified: false

Static discovery, behavior closure, profile assembly and five-affinity admission have
passed. Original-client S29 menu, shield FX and full combat remain the final acceptance
observation; automation and dry-run receipts do not replace that runtime evidence.

## Reuse boundary

Adding another season uses the same command and does not require backend code changes
when its data fits the supported contracts. Admission stops with a stable error code
when selection is ambiguous, a skill/function reference is missing, no unique behavior
asset closes the graph, an FX color family cannot be resolved, an asset identity is
absent, or a transform touches a row outside the target closure. Such a season remains
disabled until its evidence or generic contract is extended deliberately.
