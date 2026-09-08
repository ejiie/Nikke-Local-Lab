# 151 local resource provider — implementation checkpoint

> 보관 기록: 2026-09-06 문서 정리 때 이동했습니다. 본문의 ‘현재·다음·미완료’는 작성 당시 기준입니다. 현행 안내는 [문서 색인](../README.md)과 [현재 경로](../MICRON_CURRENT_PATHS.md)를 따릅니다.

## Current native checkpoint — stock reversal passes 4/7; MAC failure persists (2026-09-06 KST)

Stock-preserving reversal `09f13ed2-8d55-4f4b-80a2-2ec56127b70a` restores 4/7
passage without clearing or downloading resources, then reproduces the prior
Server Sync failure: `ResEnterServer` succeeds and 11 post-login MAC verification
errors follow. The candidate deployment is strongly implicated in the earlier
restart, but the internal native trigger is not yet established. The new
preparation path blocks that candidate before staging; original-DLL mode and
historical recovery remain available. An isolated 25-value version/size/capability
comparison finds no differences among stock, clean rebuild and local-key rebuild;
it is not a full native compatibility proof. The MAC problem remains unresolved.
See [execution evidence](RESOURCE_COMPATIBILITY_151_PROGRESS.md).

Follow-up offline checks find identical deployed 150/151 ASodium and server-native
libraries. Synthetic tests with the real deployed wrapper pass 14 checks each for
stock and unmodified-source rebuilt client DLLs, including negative MAC/AAD tests.
The rejected peer-substitution candidate changes all client KX calls, not just
Epinel's. A separately sealed rebuild-only v4 control is prepared to separate
that semantic change from rebuilding itself. Its UAC dispatch was cancelled and
no runtime or system changes started; it is not a completed correction or native
acceptance. The original candidate remains blocked. See the progress
document for the exact control identity and subsequent outcome.

## Prior native checkpoint — local-key candidate restarts at 4/7 (2026-09-06 KST)

The subsequent clean, source-built local-key DLL trial
`09146989-65e5-4e44-bc30-2dabd8c9470c` starts the client but fails earlier:
`DownloadPatch - Initialize failed` twice, followed by `RestartUnit`, matching
the operator's report. It never reaches post-login encrypted requests, so the
previous MAC failure is **not verified fixed**. Server file manifests and voice
selection match the prior run; only the DLL differs among pinned client files.
Mutable resource state remains a possible confounder. No specific resource file
or integrity sub-check has yet been identified as the new failure's cause.

Temporary changes are independently verified restored, and full official-source
pre/post inventories match. The subsequent stock-preserving comparison is recorded
above; do not promote the replacement library or infer native acceptance from synthetic
checks. See the [current execution evidence](RESOURCE_COMPATIBILITY_151_PROGRESS.md).

## Prior native checkpoint — stock 4/7 passed; Server Sync blocked (2026-09-06 KST)

Assessment `4e4a256c-3527-443d-a88e-56ca7c946720` reached the actual client window.
The operator confirmed **4/7 passage** and supplied a screenshot of the subsequent
`Server Sync [2/2] / Failed to load` failure. The missing version-header fix is
native-verified for this KO Minimal run, not every resource/voice configuration.
No related-service guard abort occurred in this attempt.

Existing logs record successful resource discovery, static-data loading and
`ResEnterServer`. Later HTTP 500 responses correspond to 11 server-side
`CryptographicException` failures: `Verification of MAC stored in cipher text
failed`, in `PacketDecryption.DecryptOrReturnContentAsync` before handler dispatch.
The immediate blocker is encrypted post-login request processing. The exact
key/session/envelope/additional-data mismatch is **not yet determined**; MAC
verification must not be disabled to continue.

The bounded run completed with isolation/cleanup verified and no production DB
mutation. Independent checks verified restored file pins, voice preferences and
zero owned firewall rules. Full reviewed official-source pre/post inventories
match (1,061 files / 20,430,766,727 bytes). This assessment is consumed; lobby and
gameplay acceptance remain unverified. No crypto fix, client patch, extra download
or HTTP diagnostic layer was added. See
[native evidence and next investigation](RESOURCE_COMPATIBILITY_151_PROGRESS.md#native-retest-header-fix-passed-post-login-packet-decryption-fails-2026-09-06-kst).

## Prior retest attempt — related-service stop before client handoff (2026-09-06 KST)

The operator-authorized relaunch of header-containing assessment
`55f33a10-9a6f-49e4-b65e-984502a09d48` stopped before recorded client handoff.
The existing guard detected `ACE-Service64.exe`, classified in the private
receipt as `installed_related_service`, with `services.exe` as its parent.
The historical error code is `resource_native_official_launcher_spawned`, but
this evidence does not identify an operator-started official launcher.

Cleanup and isolation were verified; independent checks found restored file pins
and voice settings and zero owned firewall rules. The complete reviewed official
source pre/post inventories matched (1,061 files / 20,430,766,727 bytes).
No guard, service configuration
or native library was modified. This assessment is consumed and must not be
relaunched. The header fix has **no new native 4/7 result**; see the
[retest evidence](RESOURCE_COMPATIBILITY_151_PROGRESS.md#retest-attempt-stopped-before-client-handoff-by-related-service-admission-2026-09-06-kst).

## Prior implementation — missing header staged; native retest pending (2026-09-06 KST)

The operator-authorized preparation fix is implemented. An offline common helper
derives the header cache path from configuration, verifies the pinned acquisition
record and bytes, copies create-only and checks exact manifest membership before
sealing. Authentication and native preparation both use it. No HTTP filter or
observer was restored; the published server DLL and normal handlers are unchanged.

117 synthetic preparation checks, 56 removal/source/package checks and 177 existing
focused tests passed. Fresh assessment `55f33a10-9a6f-49e4-b65e-984502a09d48`
contains the 139-byte header at the normal handler's resolved path; all 76 runtime
pins matched. At that preparation checkpoint it was **staged, not started**. No additional download, client/OS
configuration change or production DB mutation occurred. Native 4/7 success and
later catalog/payload delivery remain unverified. See the current
[implementation and retest handoff](RESOURCE_COMPATIBILITY_151_PROGRESS.md#implementation-version-header-staged-and-sealed-native-retest-pending-2026-09-06-kst).

## Prior investigation — version header missing from runtime cache (2026-09-06 KST)

At this investigation checkpoint the first 4/7 failure was identified, not yet fixed. The client log
records successful resource-host discovery followed by HTTP 404 while reading
`latest-{ResourceDataPackVersion}.txt` (selector 653). The corresponding file is
absent from the normal Epinel cache and runtime manifest. Preparation reads the
already acquired **139-byte** metadata to set the core revision but never stages
it for the normal resource handler. The acquisition URI and hash match; another
download is not needed to correct this omission.

The proposed fix is configuration-derived, hash-verified, create-only staging
before runtime sealing, with offline path/manifest tests. It must not reinstate
the removed HTTP inspection layer. The later header-to-installed-catalog binding,
seven-role metadata closure and selected voice/quality payload delivery remain
separate unresolved gates. No code, runtime resources, configuration, network or
native execution was changed during this investigation. See the detailed
[evidence and proposed correction](RESOURCE_COMPATIBILITY_151_PROGRESS.md#offline-investigation-first-47-failure-identified-2026-09-06-kst).

## Latest native retest — 3/7 passes, 4/7 remains blocked (2026-09-06 KST)

The operator reran the permanent-removal build using a fresh v2 plan and confirmed
**G151.8.5 / 4/7 / Catalogue resource path upgrade / System Error** by screenshot.
Assessment `b6b2616c-5e44-420d-ba1a-e67a8fd1e19b` completed synthetic authentication
and native handoff without the diagnostic HTTP layer. Existing server logs record
one local cache miss; the exact catalog binding remains unresolved. The bounded
run ended with isolation and cleanup verified and no production DB changes.
There was no additional code change, acquisition or provider implementation in
this retest. See [native progress](RESOURCE_COMPATIBILITY_151_PROGRESS.md).

## Prior implementation — diagnostic HTTP layer removed (2026-09-06 KST)

Permanent removal is implemented and published in the separate 151 candidate.
The extra HTTP filter, header rewriting, resource interception adapter and
guarded/passthrough option are gone, including the candidate's observer project
dependency. Existing Epinel request handling/authentication and private logs remain;
no new HTTP observer was installed. Sealed files, fresh synthetic stores, no-fetch
loopback operation, scoped program isolation, deadline and rollback are unchanged.

New preparation selects the clean `epinel-server-v2` artifact and v2 plans; old
plans cannot execute through current launch scripts. Historical recovery remains
supported without rewriting old evidence. Request counts are unavailable (`null`),
not zero; bounded completion is not a claim of loading success. Validation:
177 focused tests, 26 native-helper checks and 56 source/packaging checks passed;
publish succeeded. The full baseline still encounters unrelated existing whitespace
errors. See [current progress](RESOURCE_COMPATIBILITY_151_PROGRESS.md) for details.

At this implementation-only checkpoint the build had not yet been run with the
client. The subsequent native retest above confirms 3/7 passes while **4/7 resource
delivery remains unresolved**.
This change does not implement missing catalogs, admit other languages through
guessed bindings, update the Control Center's 150 target or archive either client.

## Prior native checkpoint — diagnostic middleware ablation (2026-09-06 KST)

The operator-authorized `legacy_pipeline_passthrough` experiment completed
**3/7** and reached **4/7 / Catalogue resource path upgrade / System Error**.
Sentry/server-info/version-check/resource-host responses were 200; a subsequent
local resource request returned 404/cache miss. Isolation and rollback verified.
See the latest [native progress](RESOURCE_COMPATIBILITY_151_PROGRESS.md) for
matched inputs, the twelve passive dispatch observations and the interpretation
boundary. This proves the active diagnostic layer obstructed initialization; it
does not resolve resource binding/provider delivery or certify lobby/battle.

The opt-in mode bypasses only diagnostic HTTP intervention: existing Epinel
handling remains, along with loopback/no-fetch configuration, fresh synthetic
stores, pinned clone, whole-program blocking, deadline and rollback outside HTTP
dispatch. Resource-observer request count zero is expected because that observer
does not serve or reject requests in this experiment. At that checkpoint permanent
removal was recommended but not yet implemented; the v2 change above supersedes
that pending status. Tests at the ablation checkpoint: 211 focused
and 26 native-helper checks passed. Earlier checkpoints below retain their
historical meaning and do not supersede this result.

## Prior checkpoint — native startup diagnostics (2026-09-05)

See [current native progress](RESOURCE_COMPATIBILITY_151_PROGRESS.md#status-and-authority-2026-09-06)
for the authoritative ordered observations. The separate 151 clone has now been
started under bounded full-program isolation, using stock sodium.dll, temporary
scoped client/system trust and KO Minimal preferences, followed by verified rollback.
This supersedes the older **no native execution** statements below, but is not
resource-provider, lobby or battle acceptance.

The first measured 3/7 failure exposed a dispatch-order defect: the resource
observer returned 404 for the same-host startup route configuration. The corrected
middleware reached Epinel's local world-registry handler in the next run. The
follow-up failed with 403 on startup sentry parameters before any resource request.
The next revision separates the missing startup handlers and credential-free vs
cryptographically verified local startup authentication, with bounded decision
receipts. A retest confirmed rejection of a nonempty authorization header (not a
cookie); it did not resolve the 403. The next revision supports both existing
Epinel local-token prefix forms with identical verification and records only a
controlled header-shape label. **203 focused tests pass**; this revision's native
measurement is pending. The latest UAC retry stopped on a block-only-program
guard before completed native handoff. Its misleading `official_launcher_spawned`
label also covers the protection-service executable; the operator confirmed no
separate official launch. An ACE termination event coincides with cleanup, but
the exact guard match and startup origin were not captured. Isolation and cleanup
verified; no further native retry or guard relaxation followed. See the progress
document's 2026-09-06 safety-stop review.
Unknown resource paths still receive empty 404 responses; no legacy asset fallback
or additional CDN acquisition was enabled.

The prior prelaunch registry byte-array failure was fully recovered by a later
recovery receipt; original failure receipts are not rewritten. Current evidence
must consider that subsequent recovery rather than treating the old false cleanup
flag as a still-active mutation. The official-current/150 trees and production DB
were not intentional mutation targets; no client has been archived. A later
official-current hash audit found two old CrashSight report files missing (4,504
bytes); all other 1,061 baseline files matched exactly. Removal origin is
unresolved, so full-tree immutability is not claimed. The frozen 150 lane and
production DB were not modified by the diagnostic.

## Prior checkpoint — isolated server/auth smoke passed (2026-09-05)

The operator resumed the goal and requested the UAC prompt again. The bounded
**server/auth-only** smoke now passes; this is not native resource or battle
admission. No game or official launcher was started.

- `ProbeServerLocales` resolves four required server locale files from the installed
  chunk-layout catalog's raw references. It checks exact length, catalog-declared
  seeded-block SpookyHash, independent SHA-256 and NKDB shape, then copies original
  bytes into a new private staging directory. It does not substitute a voice pack
  or register native resource routes. Duplicate/missing/invalid references fail closed.
- The separate 151 Epinel candidate links `ResourceProbeExecution`. Probe mode
  requires a fresh GUID runtime, pinned complete file inventory and explicit
  arguments; inherited raid configuration and existing DB/start markers are rejected.
  It clears external configuration sources, selects a new local SQLite DB, allows
  only synthetic SDK authentication and bounded startup discovery routes, and
  stops after 60 seconds. Production and frozen-150 server binaries were not changed.
- `ResourceProbeBootstrap` reuses the existing source-built bootstrap's local
  authentication contract behind a separate build flag. The measured mode creates
  one new synthetic account and exits before game/Sail IPC startup. HTTP physically
  connects to `127.0.0.1:443` with exact SDK-host admission, hostname validation,
  redirects/proxy/cookies disabled and a custom **public issuing CA** trust store.
  It does not add that CA to either Windows trust store.
- `prepare-nll-resource-probe-auth-smoke.ps1` stages only already-local pinned inputs,
  a new random synthetic context and manifests with protected ACLs. Every attempt
  uses a new assessment; failed artifacts/DBs are retained, not reset or reused.
- `invoke-nll-resource-probe-auth-smoke.ps1` verifies its own/preparation hashes,
  requires elevation and cold scoped runtimes, installs two exact-program outbound
  block rules and verifies their ActiveStore filters **before** starting either
  process. It retains blocking until both owned processes are proven stopped and
  removes only that assessment's rules. This two-program proof does not certify
  native client/launcher/child-process isolation.

Measured successful assessment: `1dea34a2-1e91-4048-aca7-1b66ce3f712e`, under
`C:\NLL\Staging\ResourceProbeRuns`. Its `auth-execution.receipt.json` reports
`local_auth_smoke_passed`, `isolationVerified=true`,
`localSyntheticAuthAccepted=true`, `cleanupVerified=true`, `clientStarted=false`,
`hostsChanged=false`, `systemTrustChanged=false`, `productionDbModified=false`,
and `nativeAdmission=not_evaluated`. Execution was 12:21:20–12:22:26 UTC.
The pinned server/bootstrap inventories contain 75 and 8 files respectively.

Two preparation defects were found and corrected during these bounded attempts:

1. Windows rejected the hand-built IP exception ranges with `0x80070057` before
   server startup. Exact-program rules now block `Any` destination; physical
   loopback TLS authentication was measured successfully while those rules were
   active. Do not weaken the rule to permit external resource fallback.
2. The initial custom trust configuration incorrectly used the server leaf as its
   issuing root. Equal Subject/Issuer display names did not establish self-signing.
   Offline chain verification succeeds against the existing pinned public CA,
   and the corrected bootstrap uses that CA. New tests reject an end-entity as
   trust authority and verify a synthetic issued leaf without system trust/downloads.

The first direct bundled-PowerShell UAC request returned Windows cancellation.
After the operator requested another prompt, the built-in Windows PowerShell
elevation entry point successfully started the reviewed PowerShell 7 script.
Do not report a successful dispatch when Start-Process throws or returns no PID.

Validation: **170 focused tests pass**; the new bootstrap publishes successfully,
and the legacy physical bootstrap also builds with zero warnings/errors. The full
Phase 3B2 chain again passes restore/build and stops at pre-existing whitespace
failures in `Admin.Api/AccountImportExecution.cs` and `Automation.Cli/Program.cs`.
It does not establish downstream live PostgreSQL integration. No unrelated source
was reformatted, no Git commit/push was made, and the old client was not moved to D:.
Post-checkpoint repository policy passed for 7,177 files; Phase 0, Phase 3A,
Phase 3B0/1/2 contract-only gates and Actions contract checks also passed. Ignored
UnityPy-directory access warnings remain distinct from checks of source files.

Next gate: prepare and verify the separate native observation run's full program
closure/isolation, exact client binary and compatibility-input pins, preference
backup/KO selection, scoped hosts/trust changes and rollback before requesting its
UAC. The route observer has not been launched against the game. Native routes,
origin-to-installed catalog binding, 4/7 resolution, S26/result, restart persistence
and the six-task goal remain unfinished. Earlier checkpoints below are historical
and their statements that no server was started are superseded only by this
**auth-only** result, not by a native success claim.

## Prior checkpoint — bounded route observer (2026-09-05)

The operator requested continuation after the approved clone. Added a separate
metadata-only diagnostic listener, not a deployed resource provider or game server:

- `ResourceRouteProbe`: exact pinned version-metadata bytes only; all other
  accepted paths receive an empty 404. GET/HEAD, exact hostname/port, physical
  IPv4 loopback, canonical paths and bounded requests are mandatory. No proxy,
  redirect, download, catalog projection, static pack or battle response exists.
- Private observations contain method, path, parsed byte-range coordinates,
  conditional-header **names** and planned status. Authentication/cookie-bearing
  requests, query strings and bodies are rejected before recording. Raw header
  values and response contents are not logged. Path-bearing JSONL is private,
  size/count bounded and create-only; its public summary contains counts/hash only.
- `ResourceRouteProbeHost`: a separate `127.0.0.1:8443` TLS listener with an
  immutable private plan, input hashes, certificate validity/SAN checks and a
  15–300-second bound. Environment/appsettings endpoint sources are cleared.
  Port 8443 is a **diagnostic choice**, not evidence of the native origin port.
  The original 150 server dispatch and published binaries were not changed.
- `prepare-nll-resource-route-probe.ps1` stages already-local inputs only. It
  uses a new GUID directory outside Git with protected operator/SYSTEM/admin ACL,
  a pinned private plan, a source-free preparation receipt and cleanup inventory.
  It does not download, launch or change an existing client, DB, preferences,
  hosts file or certificate trust store.

Actual staging assessment: `988a0ae1-6df4-4e98-96b5-41c45aa86403`, beneath
`C:\NLL\Staging\ResourceProbeRuns`. Plan SHA-256:
`397f315717649db2411e1099b47244c5c9e6a89481a85918889a45133e0028aa`.
`inspect-route-probe` verified these inputs and returned
`probe_inputs_verified_not_started`. The staged metadata retains the previously
acquired hash; the local test PFX fingerprint is
`2f330431fa83c68ae7a613cd0c7a1f35c51d54a66771c75073035c52a8e545df`.
Private key bytes remain outside Git. No production-plan listener, Epinel 151 or
native client has been started. There are no native request observations yet.

Validation: **136 focused tests passed**, including actual synthetic loopback TLS,
exact metadata/404 behavior, certificate hostname rejection, listener shutdown,
private-log bounds and plan/path/hash/limit rejection. Windows Schannel did not
accept the initial ephemeral key implementation; the host now imports a temporary
default key container without `PersistKeySet`, disposes it after use, and does not
add a certificate to a trust store. The TLS tests required normal Windows crypto
API access outside the restricted shell. This is not original-client evidence.
The full Phase 3B2 chain was rerun and again reached the pre-existing whitespace
failures in `Admin.Api/AccountImportExecution.cs` and `Automation.Cli/Program.cs`;
unrelated source was not reformatted and downstream PostgreSQL gates were not
established by that run.
Repository policy passed (7,159 inspected files), as did Phase 0, Phase 3A and
Phase 3B0/1/2 contract-only checks and the Actions contract. Git emitted existing
access warnings for ignored local UnityPy tool directories; these are not a scan
or approval of private dependencies. No commit, push or runtime deployment occurred.

### Native-start boundary — experimental-OS role clarified

Read-only inspection found no loopback hosts entries for the tested resource,
SDK-authentication and lobby hosts, and no matching local test root in either
CurrentUser or LocalMachine Root. The historical physical/Phase D scripts apply
system hosts (and the historical setup applies root trust); they also depend on
old 150/E: receipts and must not be rerun as a 151 preparation.

Current `../contracts/PHASE3AR.md` / `../SECURITY_BOUNDARY.md` permit system hosts/root-CA changes
only in a recoverable disposable VM/separate OS, not merely because a client
directory was cloned. The operator clarified on 2026-09-05 that Micron **already
is that separate experimental OS**; the previous request to designate it again
was unnecessary and is withdrawn. Samsung remains separately bootable and D: is
the recovery boundary. No new or one-off relaxation of network policy is granted.

Full client/launcher/server process-tree non-loopback blocking is required for
**every** modified-local run: verify before launch, maintain through execution,
and never remove protection while owned processes remain alive. Temporary
hosts/trust restoration is per-run cleanup, not permission for later runtimes to
access official services. Separately approved runtime-cold acquisition is a
different lane; ordinary unrelated OS applications are not globally offline.

Continue current-path recovery verification, pinned bootstrap and isolated
server/DB preparation, KO preference backup and a reviewed UAC launch under the
existing experimental-OS authority. These technical gates are still required;
the cleared designation question was not proof of native readiness. The six-task
goal and D: archival remain open. No native run occurred during this clarification.

## Authority and status (2026-09-05)

Operator approved proceeding with the remaining work after the installed-catalog
comparison. This checkpoint implements reusable offline/provider components and
tests, not a native launch receipt. The 150 runtime, official-current install,
preferences, production DB, hosts, certificates and Golden are unchanged.

**Native integration is blocked** on exact 151 request-route evidence and a
proven origin metadata-to-installed catalog binding. Neither is synthesized from
directory names, matching schemas or the word `latest`.

## Operator-approved clone completed (2026-09-05)

After clarification that the approximately 19-GiB requirement is a local copy of
the installed 151 program and resources, not a new download, the operator explicitly
approved creation. The pinned clone operation completed successfully under a new
private assessment. The older approval-pending notes below are historical
checkpoints. Native startup remains unexecuted.

- Destination: `C:\NLL\Clients\NIKKE-151.8.5-ResourceProbe`.
- 1,063 files; 20,430,771,231 bytes / 19.03 GiB.
- Status: `sealed_offline_clone`; source-before, source-after and copy manifests
  all match plan SHA-256
  `8a16269cf67ece658aa148278e19aa5a1616eb0afeb5957bc834bad5d5db3b6b`.
- Private assessment: `48d40519-177e-4acf-a4d4-1bcac40bb230` under
  `C:\NLL\Staging\ResourceProbeClones`; source manifest and rollback contract
  remain there. Success-receipt SHA-256:
  `7bcb8ffd64bb20e0f5db8cfa80fb27263e8e159c1fcf9bb1b2a98213b08f2081`.
- Per-file copy hashes and the complete post-copy source/copy hashes passed.
  The operation ended successfully with scoped runtimes cold. No download,
  game/server launch, compatibility patch, preference, hosts, certificate, DB,
  frozen-150 mutation or D: move was performed.
- `nativeAdmission=not_evaluated`, `clientStarted=false`. The directory build
  label is still an operator-requested candidate label, not independent proof of
  native version/resource binding. Do not point the old 150 bootstrap at this copy.

Rechecks: 8 clone-plan synthetic checks, 92 provider tests, 41 Automation tests,
repository policy and Phase 0 / 3A / 3B0 / 3B1 / 3B2 contract-only / Actions checks
passed. The full chain again stopped at the same 35 whitespace diagnostics in
the two previously documented source files, before live PostgreSQL verification.

The operator also approved archiving the existing 150 copy on D: **after** the
151 goal's native startup, S26/result, persistence and cleanup checks are complete.
Before that archive, remove active 150 path dependencies (including Control Center
cube-localization repair inputs), copy to a new versioned backup location, verify
the complete file manifest and preserve a restore-to-original-C-path procedure.
Only then remove the C: copy within that approved scope. This does not authorize
moving official `C:\NIKKE`, production DB, unrelated backups or the 150 lane now.
Read-only archive sizing found 39,504 regular files / 27,264,219,735 bytes
(25.39 GiB), with no reparse entries. Re-measure and hash at the actual archive
time; this size observation alone is not an archive or restore verification.

Next: prepare a separately pinned 151 probe bootstrap/server and its isolation,
local trust, exact metadata-only responses, bounded request observations and
rollback checks. Existing 150 scripts are not valid 151 launch admission. Request
the necessary UAC only after that preparation; actual request paths, origin
catalog comparison and the six-step native acceptance goal are still unfinished.

## Implemented components

| Component | Behavior / invariant |
|---|---|
| `PatchResourcePlan` | Fixed observed profile `shiftup_patch_v1`; all seven outer metadata projects; separate voice scope and three graphics quality axes; deterministic selection digest |
| `PatchResourceBinding` | Exactly seven unique role/body/signature identities on both sides; installed/acquired pairs must match; binds header, acquisition receipt, effective overlay, runtime and plan digests |
| `PatchVersionMetadata` | Exact original metadata SHA-256, root revision and each project's revision plus publication selector; preserves information omitted by the legacy convenience parser |
| Legacy `ResourceClosurePlan` | Explicitly rejects chunk layout rather than certify it with the five-catalog rule |
| `PatchInstallPreflight` | Checks all seven catalogs, selected groups, chunk hash-set presence and lengths, selected raw references; distinguishes missing optional/selected resources |
| `SealedResourceFile` | Read-only handle, expected length/SHA-256, no reparse path, no overwrite or legacy NKDB-to-SQLite conversion; bounded reads |
| `ChunkStoreReader` | Verified compressed-byte read in addition to decoded read; serialized shared handle/decompressor access |
| `VirtualPakReader` | Maps catalog pak coordinates to verified compressed CDB chunks; handles partial/cross-chunk ranges; rejects holes, overlaps, unknown/missing chunks and oversized ranges |
| `LocalPatchEndpoint` | Exact registered paths only; GET/HEAD and bounded explicit single byte range; local and remote address must be `127.0.0.1`; expected host; no credentials, filesystem discovery or outbound fallback |

All types added for 151 are separate from existing 150 request dispatch. The HTTP
handler is in the local tool assembly and **not registered in Epinel or Phase D**.
No production listen/serve command has been added. Actual native paths must come
from a reviewed private manifest, not guesses or user-controlled path-to-disk joins.

`PatchResourceBinding` compares immutable identities, but accepting a supplied
acquisition-receipt digest is not verification of the receipt or publisher origin.
The future native integration must validate the complete private acquisition
evidence before construction. There is currently no actual installed-set binding
instance certified for launch, and no API that turns these constructors into a
`ready` state. Raw digest semantics were resolved in the follow-up below;
index-trailer semantics and publisher/version binding remain separate gates.

## Follow-up: raw checksums resolved; isolated route probe awaiting approval

Operator asked to complete tasks 1–6 and to ask at approval boundaries. The goal
remains active; no task is marked native-complete by the work below.

The earlier **83 raw checksum mismatches** all occur above 128 KiB. Their observed
rule is SpookyHash V2-128 in fixed **131,072-byte blocks**, using the previous
128-bit result as the next block's two little-endian seeds. It is not one
SpookyHash over the concatenated file. This single rule verifies **189/189**
installed selected raw files, including the 106 shorter files. No decoder,
re-encryption, input modification or alternate asset was needed.

- `SegmentedSpookyHash` fills complete blocks even when a stream returns short
  reads, rejects truncation and clears its working buffer.
- `SealedResourceFile` can require both a separately pinned SHA-256 and the raw
  checksum declared by its catalog. Re-hashing a corrupted copy with SHA-256
  cannot satisfy an unchanged catalog checksum.
- `verify-patch-raw` uses the same seven-role / voice / quality selection as
  `patch-preflight`, but verifies every selected raw checksum. Korean Minimal /
  all-SD returns 189 verified, selected presence true, **nativeAdmission blocked**.
- `IndexDigestProbe` remains read-only research. Whole and segmented SpookyHash,
  MD5, several prefix boundaries, and a separate SDK xxHash128 check do not explain
  the five index trailers. No guessed algorithm was promoted to the index reader.
  A checksum match is not a detached-signature/publisher authenticity proof.

Exact native routes were not established by the additional bounded disk-string,
retained-log, startup metadata and public source inspection. To avoid guessed CDN
requests, a question was sent asking to bring forward a **separate local-only
request-observation clone**. Approval has not yet been received in this checkpoint.
The proposed probe is not a full-play admission: it must not supply unbound game
content, access official accounts, or enable an outbound resource fallback.

`scripts/new-nll-resource-probe-clone.ps1` is staging-only. Its default invocation
reads and hashes the allowlisted program/patch trees without creating a clone.
Execution additionally requires approval, exact executable/assembly pins, the
same complete plan digest, cold runtimes, a new destination, no reparse points,
sufficient space, source/copy/post-source hashes and a private rollback manifest.
Failures retain an unadmitted partial clone; no automatic deletion is performed.
Launcher state, logs/dumps, preferences and old `.lcv.dat` are excluded. It never
starts a game or changes production DB, hosts, trust, or preferences.

Read-only plan result:

- 1,063 files; 20,430,771,231 bytes (about 19.03 GiB).
- Plan SHA-256: `8a16269cf67ece658aa148278e19aa5a1616eb0afeb5957bc834bad5d5db3b6b`.
- Requested destination: `C:\NLL\Clients\NIKKE-151.8.5-ResourceProbe` (not created).
- The build in its name is an operator-requested candidate label, **not** native
  version proof. PE ProductVersion reports the Unity engine; exact native build,
  metadata and catalog binding remain separate. Binary pins prevent silently
  copying a changed executable under the same label.

Follow-up focused checks: **92 provider/tool tests**, **41 Automation tests** and
**8 synthetic clone-plan checks** passed. The complete before/after chains again
stopped at the previously documented formatting failures, not at a new native
failure; live PostgreSQL was not reached. Post-change repository policy checked
7,173 files. Phase 0, Phase 3A/3B0/3B1/3B2 contract-only, Actions and existing
resource/acquisition synthetic checks passed. All seven source catalog pairs
retain their earlier hashes. No 151 runtime was deployed or launched, no additional
CDN object was collected, and the frozen 150 and official-current trees were not modified.

Reproduction: `verify-patch-raw <patch-root> <metadata> ko minimal sd sd sd`;
`inspect-index-digest <role-directory>`; `scripts/test-nll-resource-probe-clone.ps1`.
The collector's original two-object permission still does not authorize the
fourteen catalog objects; that approval and exact request evidence remain required.

### Additional read-only startup inspection

The earlier name-only startup inspection could miss unnamed MonoBehaviour
instances. The diagnostic helper now optionally resolves their MonoScript
references across explicitly supplied startup files, checking both asset name and
managed class name. It does not inject type trees, read process memory or run the
client. Any bounded raw-object observation contains only hashes, lengths and
recognized version literals, never original bytes or request URLs.

With `--follow-script-types`, 34 installed startup serialized files yielded 3,058
resolved script headers but no matching configuration instances under the current
name/type filter. This closes a limitation of the earlier inspection, **not** a
proof that no configuration exists: renamed types, runtime-created settings and
other storage remain possible. Exact routes/version selectors remain unresolved.
The proposed clone still has not been created and its approval is still pending.

## Selection behavior verified against the installation

All cases use the installed all-SD base. No settings were changed.

| Selection | Metadata projects | Selected payload presence | Distinct remaining selection issue |
|---|---:|---|---|
| Korean Minimal | 7 | Complete | None at the presence/length level |
| English Minimal | 7 | Incomplete | 29,386 voice chunks and two raw files absent |
| Korean Full | 7 | Incomplete | 24,895 additional voice chunks absent |
| Base-only / no voice | 7 | Complete | Native no-audio preference contract unresolved |

English/Japanese catalog-only state does not fail a Korean plan. Existing Korean
payload is not counted as a failure for an English/base-only plan merely because
it lies outside the selection. Unselected payload is never treated as a substitute
for selected missing payload.

Every case still reports `nativeAdmission=blocked`, with version binding and
native transport unresolved. `selectedPayloadPresenceResolved` is deliberately
distinct from cryptographic closure, native compatibility and actual-play success.
The inspection command exits zero on a successfully produced assessment, even
when admission is blocked; callers must never interpret its exit code as readiness.

Actual pak-coordinate reads succeeded for **15 samples across five installed
roles**. Output includes only lengths and SHA-256, no original IDs/keys or bytes.
The earlier full 454,494-chunk inspection remains the separate full payload test;
15 samples do not claim full native request/range closure.

## HTTP behavior and explicit limits

- Exact catalog/raw GET returns original bytes; HEAD returns no body.
- A valid explicit `bytes=start-end` request returns 206 with matching
  Content-Range/Content-Length. Pak responses require a range, capped at 16 MiB,
  and are fully verified before success headers/body are committed.
- Raw/catalog responses stream in bounded blocks from a presealed read handle.
- Unknown route: 404. Noncanonical/query path: 400. Non-loopback/wrong-host or
  credential-bearing request: 403. Other method: 405. Unsupported range: 416.
  Unresolved conditional request handling: 412. Missing/corrupt source: 503
  before response start, otherwise connection abort; no successful partial body.
- Suffix, open-ended, multi-range, conditional ETag/If-Range semantics and ranges
  spanning unavailable pak bytes are **not** claimed supported. Observe the native
  contract before extending them; no silent whole-pak fallback or zero padding.
- Server bind, certificates/TLS, target executable safety and version mapping are
  not proven by this handler. Existing native gates remain mandatory.

## Tests and reproduction

- Tool/provider tests: **82 passed** (52 existing + 30 added). Includes exact-set
  and source integrity regressions, chunk concurrency, pak range boundaries,
  HTTP rejection behavior and a real **synthetic-only temporary loopback HTTP**
  round trip. Listener was stopped in `finally`; no original runtime used it.
- Automation tests: **41 passed** (28 existing + 13 added), covering all three languages in Minimal/Full, base-only state,
  all eight graphics quality combinations, exact catalog sets, metadata publication
  retention, binding drift and rejection of chunk layout by the legacy closure.
- Framework references use the installed .NET 10 ASP.NET shared framework. No new
  third-party NuGet package was added. Locked restore was rerun after adding these
  references so test runtime configuration includes the framework.
- Repository policy: **7,161 files passed**. Phase 0, Phase 3A and Phase 3B0/1/2
  contract-only gates, Actions, synthetic resource preflight and the 13 acquisition
  plan tests passed. The full chain was attempted both before and after changes:
  restore/build passed but the same pre-existing whitespace issues in
  `AccountImportExecution.cs` and Automation CLI `Program.cs` stopped it before
  live PostgreSQL integration. New source was not used to conceal that baseline.

Commands, using the existing pinned tool build:

```text
patch-preflight <patch-root> <metadata-file> <ko|en|ja|none> <minimal|full|none> <lod:sd|hd> <texture:sd|hd> <spine:sd|hd>
verify-pak-samples <role> <role-directory>
```

Tests: `dotnet test tests/NikkeLocalLab.Automation.UnitTests -c Release`; from
`tools/Phase3B2/ResourceCatalogPreflight.Tests`, `dotnet test -c Release`.
Original material stays outside Git; fixtures are synthetic. Published runtime
binaries have not been replaced by these local test builds.

## Required next evidence, not yet authorized acquisition

1. Establish exact native outer-catalog/raw/pak route templates and version
   selectors from trustworthy offline/native configuration or reviewed code.
   Local startup assets, the retained log and public-source search have not yet
   supplied those templates. Do not probe guessed CDN paths.
2. Once exact paths are evidenced, obtain origin catalog **seven pairs / fourteen
   objects** tied to the preserved metadata revision/publication selectors and
   compare their hashes with the installed pairs. This would require an additional
   operator-approved cold static-CDN acquisition; the existing authorization covers
   only StaticData.pack and version metadata, not these fourteen objects.
3. Seal the complete private request/response provenance; bind the effective 151
   server/static/boss overlay and verified installed set. A mismatch must remain
   blocked and must not trigger silent cache replacement or full-language download.
4. Wire the proven private route manifest into a separately sealed 151 lane, then
   perform real local TLS and operator-selected Korean native launch validation.

Do not enable runtime auto-fetch, alter official-current files, copy arbitrary
catalogs into 150 cache paths or fill `ResourceCoreVersion` with a guess.
