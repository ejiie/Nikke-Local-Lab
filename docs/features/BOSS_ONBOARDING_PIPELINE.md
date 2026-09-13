# Solo Raid boss onboarding pipeline

## 2026-09-13: season UI and offline worker composition

The operator owns actual-game acceptance. Existing 151/S26 acceptance stays closed.
The new season picker and durable import API are implemented and installed in the
Control Center with a hash-bound pipeline activation, following PR #25's complete CI.
Authorized enikk.app PNGs are available locally for 39 seasons (37 unique contents).
S19 and the current live season remain unresolved. Per-execution native delivery and
rollback remain pending; offline candidate creation is not completion. Installing
the app/configuration did not start the app, worker, game or operating database.

- A hash-bound local catalog lists seasons 1 through the largest known static-data
  season. Exact Challenge manager/preset/target and localized names resolve 39 of
  the 40 local snapshot slots; S19 stays unresolved. The current live season is
  not inferred. Each card retains its default weakness independently of the five
  selectable execution weaknesses.
- Processed cards open a single-card detail. Unprocessed cards ask Yes/No; No
  closes without a request, Yes closes before starting the durable job. Polling
  distinguishes completion from runtime-delivery/validation waits and failures.
  Authenticated API access and POST CSRF protection remain mandatory.
- `prepare-nll-boss-pipeline.ps1` creates a NEW private configuration under artifacts,
  verifies the selected bundle, and seals tool/data inputs. It neither installs nor
  enables a worker. The synthetic `boss-variant-discovery-seed.json` contains no account
  data and leaves manager selection unset for exact unique profile resolution.
- `NLL_BOSS_PIPELINE_CONFIG_PATH` plus `NLL_BOSS_PIPELINE_CONFIG_SHA256` explicitly
  compose the catalog and worker at app startup. Absent configuration fails closed.
  The worker uses creation-time Windows Job assignment, kill-on-close, no breakaway,
  a bounded timeout, persisted request identity and distinct retry output directories.
- Optional pinned native inputs connect the common candidate to native export,
  equal-length layout and verified chunk packaging. A real S29 local service/worker
  invocation passed this chain, restart replay and cold-tool verification. The
  original store/registry remained unchanged. The result is still
  `awaiting_runtime_delivery`; original chunk digests do not match modified bytes.
- The S29 draft/profile-pin mismatch continues to block execution. A fresh import
  can discover new content without trusting the mismatched draft's metadata or
  silently updating its old admission pin. Only validated v2 profiles may use the
  separate immutable-file/atomic-registry legacy publisher.
- Existing pinned v1 profiles remain visible as processed, matching the execution
  preparation reader; the verified S26 is v1. A real installed-DLL HTTP check found
  that the initial v2-only catalog reader hid S26. The app was restored, this reader
  was corrected with mixed-v1/v3 regression tests, and a newly sealed app package was
  installed and rechecked. The publisher's v2-only rule and S29 execution block did
  not change. See the handoff for the second delivery plan and rollback baseline.

`tools/NikkeLocalLab.BossPipeline.Checks` runs only with an explicit private config,
config SHA and season; `--inspect-job <job-uid>` checks an existing receipt chain
without launching another worker. Source CI builds it but never supplies original
data. Synthetic publication, queue, UI, process and failure checks are separate
from user-game acceptance. See [current handoff](../HANDOFF.md) for exact evidence.

The additional user approval permits ACE-ADVT automatic startup and normal SCM stop
after the user-launched validation's complete user-mode scope is cold. The opt-in
`Nll.NativeFxManagedDriver.ps1` validates both exact driver identities/hashes, preserves
ACE-BASE, refuses dependent-service stops, and retains failure on denial/timeout/drift.
The historical strict baseline guard is unchanged. Its synthetic checks run without
real service/driver operations; this helper alone is not a prepared gameplay launcher.

The separate `NativeFxUserValidationBootstrap` consumes a strict user-owned plan and
full independent client inventory. It does not register a new tutorial account.
Its offline inspect option cannot authenticate or start the game; startup additionally
requires an elevated token, the exact controller Job, a fresh plan-bound isolation
receipt, and the current ACE-ADVT authorization. Empty client files and literal spaces/
parentheses are preserved with exact hashes; runtime inputs cannot be empty. A data-only
receipt is not OS proof. `Complete-FxValidationManagedScope` sequences service stop,
scope checks, shared setting/input restoration, exact driver restoration, and only then
isolation release. Failure stops subsequent steps. The preparing/controller/delivery
composition is still pending; no ready-for-gameplay state is published by this work.

> 상태 참고 (2026-09-06): 아래 S29 결과는 당시 admission 기록입니다. 현재 S29의 profile v3/등록 v2 불일치는 별도 보류이며, 151 실게임 완료는 S26 기준입니다. [안정화 계획](../STABILIZATION_PLAN.md)을 함께 확인합니다.

> 2026-09-13 현재: 운영자가 관리자 실행과 ACE 서비스 별도 관리를 승인했다. 새 실험은
> 보정 FX를 적용하기 전에 ACE-ADVT 드라이버 상태 변화로 중단됐다. 후속 명시 승인과
> 정상 중지로 사전 드라이버 상태를 복원하고 hosts/음성/서비스 원복 및 임시 방화벽
> 0개·관련 프로세스 0개를 확인했다. 이 cold 원복은 기존 S26 인수 및 native FX/새
> 자동 수명주기 인수와 구별한다. 최신 복구 상태는 [인계](../HANDOFF.md)를 따른다.

## CIDX trailer rule resolved — 2026-09-12

### Reusable offline delivery tools — 2026-09-13

The operator now owns actual-game execution/visual/combat testing. The agent must
finish implementation and non-game verification without restarting a native trial.
Existing S26 acceptance remains complete. These new tools keep native admission
`not_assessed`; no success receipt authorizes changing an installation or DLL.

- `materialize-nll-native-fx-layout.py`: consumes the hash-pinned native candidate;
  copies only equal-size changed Transform payloads into their original positions;
  verifies every object, directory and unchanged byte layout before a final seal.
  Unknown compression/encryption/content-digest formats fail closed.
- `ResourceCatalogPreflight stage-native-fx-chunks`: binds that seal to the exact
  original catalog/store/index and assembles all original chunks with digest checks.
  Only singly referenced chunks may change (reuse twice even in one file is rejected).
  Zstd + skippable padding preserves compressed size and round-trips to the corrected
  bytes. It writes before/after chunks and a private offset manifest into a NEW output,
  rechecks all inputs, then seals a source-free receipt. It never changes an index,
  catalog or source store, and explicitly records `oldChunkDigestsMatch=false`.
- `materialize-nll-native-fx-store.py`: creates an independent OFFLINE store copy,
  changes only those pinned ranges, and verifies whole-file hashes. Restore rebuilds
  the original bytes in a separate partial, validates its full hash and atomically
  replaces only that owned copy. Completed partial replacements can resume; unknown
  partials/copies and stale locks are retained and rejected. This tool is not a live
  client installer, a Job retirement proof, or a native runtime acceptance gate.

All original bundles/chunks/private manifests remain ignored local artifacts. Only
tool source, documentation and directly authored synthetic fixtures belong in Git.
The previous private feasibility receipts are unchanged; new outputs have new seals.

Source-only checks:

```powershell
python -B scripts/test-nll-native-fx-layout.py
python -B scripts/test-nll-native-fx-store.py
```

An offline fixed-layout alternative now preserves each original fire/wind/iron
bundle's metadata, object offsets and byte length while reproducing every object
payload of the previously verified Transform-only overlay. Each changes one
non-shared catalog chunk. Exact-length Zstd payloads with skippable padding round
trip to the corrected content; **their original chunk digests do not match**.
No client/CDB/index write or native acceptance has occurred. A pinned disk-only
read candidate connects lookup/size checks to ZSTD_decompress, but its full FX
provider chain and interaction with the separate digest-validation path remain
unverified. See the [current handoff](../HANDOFF.md) and private source-free
`fixed-layout-13ab6671de4844539b02715a5847095e.receipt.json`; this does not relax
native admission or permit reusing an original digest as modified-byte evidence.

Subsequent native format experiment: replacing only the exact installed inner
catalog with its unchanged decoded SQLite bytes is **not an accepted route**.
Trial `7b6d16b1-5ab1-4849-9df4-1f28d1f7815c` produced five OS requests (one read)
for that file and four malformed-database log lines naming its exact path. A
successful lobby response in the same run must not mask the catalog rejection.
The automatic cleanup also failed on OS process-identity lookup; a separate UAC
cold recovery restored the declared catalog and scoped settings without claiming
a surviving Job or physical FX retirement. See the current [handoff](../HANDOFF.md).
The source-free summary is
`artifacts/native-fx-runtime-20260912/format-trial-70ce2b78998641d489294a1a52e29210.receipt.json`.
No corrected FX, new native patch, catalog signature acceptance or A→B→A runtime
success is claimed.

The exact 151 CIDX reader accumulates a zero-initialized `Hash128`: append the
12-byte header once, then each 28-byte record separately, then compare the stored
16-byte trailer. Each append uses SpookyHash v2 with the preceding result's two
little-endian 64-bit halves as seeds. A single streaming hash, or uniform 28-byte
segmentation starting at byte zero, is a different algorithm.

Disk-only instruction-boundary checks bind the header, record loop, shared state,
trailer comparison and `UnityEngine.Hash128::ComputeFromPtr` call in the pinned
151 image. The rule matches all five installed indices (core/dp/fd/saus/ko),
454,494 records in total; all before/after SHA-256 pins agree. Reproduction is
`artifacts/native-delivery-static-20260912/check-index-trailers.ps1`; its immutable
source-free receipt is `index-rule-6efbc882c822441ea75e8c6846455440.receipt.json`
(SHA-256 `325a5333e3fcdd6112950acc60577d78e2b3e7835e8a55704ae680f4229c3b09`).
No native DLL was loaded, no index/catalog was rewritten, and no game was started
by this inspection. The earlier blocker receipt remains historical and unchanged.

`ChunkIndexDigest` and the offline reader now report
`spooky_header12_records28_seeded_verified` only for a matching trailer.
Mismatching trailers remain explicitly uncertified in the offline extraction
path; this is not native admission. The 23 new synthetic cases cover explicit
two-record seed chaining, empty indices, malformed dimensions/version/counts,
field changes, wrong segmentation and corrupt/whole-file-hash trailers. All 226
ResourceCatalogPreflight tests pass, including the real local TLS synthetic test
outside the restricted key-storage sandbox. No system trust certificate is added.

**Still incomplete:** a consistent execution-local catalog/chunk delivery route,
modified catalog acceptance, corrected FX native loading/rendering and A→B→A
restoration. Resolving the index checksum does not solve catalog signatures or
authorize changing the approved DLL. Old candidate receipts are not rewritten;
a new export can record the stronger index result under a new seal.

## Native delivery blockers and whole-tree retirement — 2026-09-12

The following is the earlier inspection/lifecycle checkpoint. The CIDX checksum
item below is superseded by the resolved rule above; the native delivery gates
are not otherwise promoted.

The follow-up request covers the remainder of native delivery/rollback and the
entire process-tree cleanup integration. **Do not mark native delivery complete.**
Bounded disk-only inspection of the exact 151 assembly and approved, unchanged
sodium found a signature failure/error branch, not proof that modified catalogs
are accepted. The installed metadata file is empty. Asset API strings and the
`is_local` database column are not a resolved native provider call chain.

The private reproduction helper and source-free result are under
`artifacts/native-delivery-static-20260912/`. Input pins were rechecked; two
negative controls rejected pin/instruction drift. No target DLL was loaded and
no game, DB, network, catalog replacement or native binary patch was performed.
Three gates remain:

- `native_local_provider_path_unresolved`: the exact local path and effective
  embedded/core catalog/cache precedence are not established.
- `modified_catalog_signature_acceptance_unresolved`: an original NDS signature
  is not evidence that modified bytes are valid. The approved DLL's existing
  load-time effect on this exact call chain is unresolved.
- `native_chunk_index_trailer_unresolved`: the chunkstore alternative also needs
  a valid CIDX trailer and consistent new chunk/catalog mappings. It cannot use
  the old trailer as a claimed checksum for changed bytes.

The lifecycle implementation is independent of those gates. New runner input v3
and bundle v2 bind a random per-execution Job nonce. The start PowerShell is
assigned atomically during Windows process creation; server/bootstrap/client
descendants inherit that Job. Breakaway is not enabled and the last owner handle
closing kills members. Coordinator, watcher, completion and PostgreSQL control
workers remain outside. Watcher ready/commit handoff retains a live handle.
Microsoft documents the [creation-time Job list](https://devblogs.microsoft.com/oldnewthing/20230209-00/?p=107812)
and [Job inheritance/limits](https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects).

Termination success alone is insufficient: cleanup consumes an immutable,
execution/bundle/nonce-bound zero-process receipt and queries the **same live
kernel Job**, while retaining its handle. Missing jobs are never recreated as
proof. If all owners crash and that evidence is lost, recovery stays fail closed;
it does not restore isolation or erase leases based on absent PIDs. Jobs do not
provide network isolation, and externally delegated process creation (such as
WMI/service creation) is not silently included in a Job inheritance claim.
Existing whole-tree non-loopback admission requirements remain separate.

Physical cleanup and subsequent PostgreSQL replay are different phases. Once
physical cleanup is verified and durably checkpointed while the Job is still
owned, a later PG/persistence failure may retry **only database replay/pending
cleanup** using those pinned completion/rollback records. It cannot repeat
runtime writes, hosts restoration, firewall removal or FX lease adoption without
live Job proof. This prevents a closed, already-cleaned Job from making pending
state permanently unrecoverable. Before handoff commit the coordinator retains
cleanup responsibility and must prove the exact waiting watcher's exit before
taking over; a published commit, including an uncertain write outcome, belongs
to the watcher.

The optional input `executionFx` binds the HTTP delivery manifest, candidate,
profile and weakness. Its root is fixed at `runtime/execution-fx`. Current
coordinator preparation leaves it null: this change does not admit the old
HTTP manifest as native 151 delivery. Unbound delivery folders are rejected.
The sealed materializer's `--retire-execution-fx` mode rechecks code/input pins,
opens the Job with query-only access, checks zero members and calls
`ExecutionAssetOverlay.RetireAfterProcessTreeExit`. Ordinary `Retire` still
rejects abandoned leases. The recovery entry point requires exclusive access to
a zero-byte lease and binds sticky `.recovery` intent to the termination receipt
hash before removing either of its two hash-checked private copies. Interrupted
cleanup can retry that exact proof; it cannot reopen the delivery route.

The installed v6, operating DB, approved sodium and S29 admission block remain
unchanged. No native-load/render/rollback acceptance is claimed by these
synthetic lifecycle checks. The pre-existing offline native candidate remains
available for a future resolved native delivery path.

Focused local checks passed: Automation 83 cases (9 new lease recovery cases),
actual Windows Job 44, capture/failure/replay ordering 38, and actual Job-bound
FX retirement 9 both through the library and through the built materializer
CLI. Python regression checks remain 63. The installed v6's 96 file pins and
selection/registration were rechecked unchanged; the local preservation receipt
is `artifacts/job-retirement-preservation-f8e265fa86484700a275a8d99d263e2e.json`.

## Exact 151 native FX binding — 2026-09-12

**Completed: offline native payload binding and regenerated 151 FX candidates.
Not completed: execution-local native cache delivery or client acceptance.**
This closes the filename-identity question from the previous section, not the
entire FX-RUNTIME-02 or the user's item 1 native-delivery objective.

`AddressableFxBinding` resolves the exact internal AssetBundle container key
(including opaque keys) through `keys → key_entries → entries → provider →
dependency key`. Both approved embedded and core addressable catalogs must agree.
No stem, case-insensitive, latest-version or alternate-season fallback is used.
For the three corrected FX, the catalog points to one remote bundle each, plus
two/three/two local dependencies for fire/wind/iron. The remote internal ID is a
bundle key, not the old HTTP URL. It exactly matches `files_chunktype.key` in the
installed core patch catalog. Local dependencies are read from StreamingAssets.

`ResourceCatalogPreflight export-native-fx <private-plan> <plan-sha256> <new-output>`
reuses the bounded NKDB/SQLite reader and verified chunk-store reader. It checks
outer→inner catalog pairing, pinned catalog/signature/index bytes, exact file
membership, contiguous offsets, compressed chunk hashes, bounded decompression,
and local dependency presence/UnityFS shape. Missing joins, duplicate identities,
multiple remote owners, provider mismatch and malformed paths fail closed.
The native index trailer algorithm remains **unresolved**; a pinned index SHA
and verified individual chunks prove this offline extraction, not publisher
authenticity, a writable native-cache format or runtime acceptance.

`scripts/stage-nll-native-fx.py` verifies the previous isolated FX candidate,
reads its internal container keys without dereferencing preload dependencies,
builds a private export plan, then checks the extracted bundles' internal keys
and bytes independently. It transforms the new native electric/fire/wind/iron
inputs using the existing Transform-only round-trip validator. Tool inventory,
input plan and old candidate are checked again; a final receipt is written last.
Interrupted directories are preserved and cannot be reused. These outputs are
not consumable as an admitted execution or as the previous HTTP route manifest.

Real input results: all four native original bundles differ from the previous
cache candidates. The three target native bundle lengths are 1,215,712 / 1,217,520 /
1,216,544 bytes; corrected output lengths are 1,215,712 / 1,217,536 / 1,216,544.
Matched transforms remain 14/13/14, changed transforms 4/6/4. Other serialized
objects and unmatched transforms are preserved. Two runs reproduced identical
derived hashes. Final local evidence:
`artifacts/native-fx-checks/eaca08be4a964de5b6d41125666d029f/candidate/receipt.json`
and sibling `verification.json` (96 installed v6 pins, selection and boss registry
preserved). No game, Epinel Main or operating DB was started.

Reproduce with a freshly built `tools/Phase3B2/ResourceCatalogPreflight` (.NET 10)
and the stage script's pinned input-plan/tool/old-candidate arguments. The base
plan uses `contractId=nll/native-fx-export-plan/v1`, `embedded`, `inner`, `outer`
objects with `body`/`signature` `{path,sha256}` pins, `chunkRoot`, `localBundleRoot`
and `indexSha256`; it must not supply `assets`. All paths/plans/bindings/game bytes
remain ignored private inputs. Do not send them to Actions. Local synthetic
catalog/chunk tests passed 203 cases (26 new); Python tests passed 63 (8 new), with
the new source-only orchestration tests wired into both CI jobs. .NET 10 external
decoder/chunk tests remain a local gate, not a claim that CI has game inputs.

**Next:** establish an isolated execution's native bundle/cache delivery and
verification/rollback without modifying shared caches or reusing stale HTTP
identities. Then finish full-process-tree retirement, v3 admission/new bundle,
atomic publication/jobs and requested UI. S29 remains blocked and installed v6
remains selected. Do not mark this offline receipt as import success or actual play.

## External Epinel FX mount and native-catalog finding — 2026-09-12

The transport is now source-linked into a **separate, uninstalled Epinel candidate**.
`patches/epinel-execution-fx-mount.patch` applies to the existing modified 151
source snapshot without overwriting it. The local copy is `.external/EpinelPS-fx-candidate`;
the build is `artifacts/epinel-fx-integration/server`. Neither the installed v6
server nor the older source-manifest-pinned checkout was modified.

`ExecutionAssetOverlayStartup` requires all six `EPINELPS_EXECUTION_FX_*` inputs:
ROOT, MANIFEST_SHA256, EXECUTION_CODE, CANDIDATE_SHA256, PROFILE_SHA256 and WEAKNESS_CODE.
No inputs means inert; partial/blank configuration, non-headless/non-local execution,
official outbound, binding/hash drift or a root other than the independent runtime's
fixed `execution-fx` child fail before serving. Errors contain no private route/path.
Mounting precedes static-file/encryption/legacy routes. Invalid/closed FX requests
never fall through to original bytes. Host disposal precedes overlay disposal;
**server exit alone never retires the private copies**.

Twelve new startup/middleware cases passed (74 automation cases total). The external
candidate built successfully. The explicit local `EpinelFxProbe` loads that built
DLL, mounts its actual startup middleware and encryption/asset handler, and checks
whole/range/HEAD/invalid/POST/closed responses plus the unchanged static-pack handler.
It does **not** invoke Epinel Main, game/DB startup, native bootstrap or installed
ports. All three real corrected FX inputs passed, with 96 installed pins and the
registry/profile preserved. The source-only CI builds/formats this probe on SDK 8;
actual external inspection requires runtime 10 and pinned local inputs.
Final local receipt: `artifacts/epinel-fx-checks/e1e2d66538cc423c8264b5503786129f/receipt.json`.
The preserved source/candidate comparison covered 745 source/project files; only
`Program.cs` and `EpinelPS.csproj` differ, plus the explicitly source-linked Lab code.

Read-only inspection found a **native binding gap**, not a CRC fix:

- Both the 151 embedded and core patch addressable catalogs contain 26,491 bundle
  entries. Their measured `entry_data` schema is `type_rowid, is_local`, not the
  historical 150 hash/CRC/bundle-size layout. Do not reuse the old catalog editor.
- For each of the three FX routes, exact bundle-leaf matches are **zero in both
  catalogs**. Removing the conventional hash suffix finds one name-stem hint each,
  but this is not an exact asset identity or permission to substitute its bytes.
- Therefore an Epinel HTTP response cannot yet establish native request/acceptance.
  Native provider selection, the corresponding 151 bundle bytes and payload/cache
  validation remain unresolved. No catalog, cache, client or hash suffix was patched.

Reproduction: build the independent patched Epinel source; build
`tools/PhaseD/EpinelFxProbe` and run `scripts/test-nll-epinel-fx-local.ps1` with the
candidate server/DLL pin, unretired S29 candidate/seal, approved bundle/pack,
reviewed Python, built probe/SHA and the two exact local `CatalogPaths`.
The script creates fresh runtime copies, pins inputs before/after, and retires only
its probe-owned delivery copies after the synchronous no-child probe exits. A
catalog inspection exit code of zero means the inspection ran, **not admission**.
Private catalog scratch copies and route manifests are not CI/Git inputs.

**Remaining FX-RUNTIME-02 work:** resolve exact 151 catalog → provider → bundle
closure and a separate native-cache delivery strategy; then bind production
retirement to the coordinator's entire process-tree exit evidence, including crash
leases. Existing three named process identities do not by themselves prove arbitrary
descendant exit. No active coordinator was changed or v3 launch enabled in this step.
S29 remains blocked; v3 admission, atomic publication/jobs and UI remain downstream.

## Previous execution-local FX transport component — 2026-09-12

**Completed: isolated staging, a source-linked HTTP component and private-copy
retirement. Not completed: mounting that component in the installed Epinel server,
coordinator process-tree cleanup or native-client cache/catalog/rendering proof.**
S29 remains blocked and installed v6/profile/registry pins are unchanged. This is
not final UI import success or v3 execution admission.

`stage-nll-execution-fx.py` takes an explicitly pinned verified candidate, source
pack/cache, execution code and selected weakness. It re-verifies the complete old
seal against current profile/discovery/behavior, all five packs/receipts and the
live FX candidate; existence of a historical success receipt is insufficient.
For a transformed target (fire/wind/iron boss element), it requires exactly one
original cache request path for the pinned bundle. Duplicate hash-identical aliases
are rejected rather than picking the first. The output must be new and outside
the candidate/cache/source directory. Original and derived bytes are independent
copies; `manifest.private.json` is written last. No-overlay targets explicitly
return `execution_fx_overlay_not_required`, without creating a directory.

The private manifest (`nll/execution-fx-delivery/v1`) contains the exact request
path and must remain ignored with all game bytes. The public staging receipt
contains only codes, counts and hashes. Never publish the private delivery folder.

`ExecutionAssetOverlay.Open` validates the manifest SHA and expected execution,
candidate-seal, profile and weakness bindings before serving anything. Official
outbound must be disabled. Reparse ancestors/members, incorrect inventories,
invalid pins, missing/changed assets, oversized files and retired folders fail
closed. The component loads bounded, hash-checked bytes once and gives each HTTP
response its own copy; changing a file after Open cannot change served bytes.
`ExecutionAssetOverlayHttp` uses the **raw target**, exact case-sensitive paths,
GET/HEAD and range support. Queries, escapes, traversal and malformed paths return
a controlled failure, not an original-cache fallback. The bridge sets `no-store`;
that HTTP directive is **not proof of Unity's native cache behavior**.

Open holds an exclusive `.lease` reservation until Dispose. A second owner or
Retire is blocked while it exists. Dispose closes the route and clears its buffer.
Retire validates all remaining fixed private members before creating sticky
`.retiring` intent, deletes only `original.bundle` and `overlay.bundle`, and retains
the manifest plus source-free retirement tombstone. It is idempotent and can resume
known partial cleanup after a managed failure; unknown bytes/members are preserved
and rejected. Hard process termination leaves a lease and is **not auto-recovered**.
Never delete it merely because a PID appears stale. No installed file was replaced,
so this rollback design needs no write through the parent's cache junction. The
retirement API does not prove the full execution process tree has exited; the
future coordinator must supply that separate lifecycle gate. Retired execution
copies can be regenerated from the unchanged candidate in a new directory.

Verification: nine synthetic staging methods and 19 new .NET cases (62 automation
cases total), including real loopback HTTP whole/range/HEAD delivery, query rejection,
execution binding, reparse paths, active/unclean leases, partial cleanup and retired
reopen rejection. CI uses only synthetic bytes, never local game files. The separate
probe source is built/formatted in the existing Phase 2A2 chain.

The real 151 S29 candidate
`artifacts/boss-onboarding-checks/ddb6c057109846c0831c3bdc5f7cf993/season-29`
was rechecked and all three corrected FX bundles passed loopback HTTP byte/range/HEAD
checks, active retirement rejection, retirement twice and retired reopen rejection.
Receipt: `artifacts/execution-fx-checks/213e97bb4e134b7abd48eb11a9be9ad6/receipt.json`.
All 96 installed pins and tracked registry/profile files remained unchanged. Only
the six newly staged private bundle copies were deleted; candidates/backups remain.
No Epinel server, operating DB, original client, hosts or firewall was changed.

```powershell
python -B scripts/test-nll-execution-fx.py
dotnet test tests/NikkeLocalLab.Automation.UnitTests -c Release
pwsh -NoProfile -File scripts/test-nll-execution-fx-local.ps1 `
  -BundlePath <sealed-v6-bundle> -ExpectedBundleSha256 <approved-bundle-sha> `
  -CandidateRoot <unrestored-verified-S29-candidate> `
  -CandidateSealSha256 <exact-candidate-seal-sha> `
  -StaticDataPackPath <bundle-pinned-pack> -PythonPath <reviewed-python>
```

The following was the next integration gate at this earlier checkpoint; the mount
and catalog findings above supersede that part: source-link into a **new external Epinel
candidate**, bind startup to the selected execution and dispose after request
draining; connect retirement only after the coordinator's exact process-tree exit
gate. Keep the old installed server/source manifests untouched. Inspect the native
client's existing-cache/catalog hash/CRC behavior before selecting an isolated
cache strategy; an HTTP GET proof alone cannot show the client requested or accepted
derived bytes. Only then advance preparation/coordinator v3 admission, atomic
publication/job API and season-selection UI.

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
