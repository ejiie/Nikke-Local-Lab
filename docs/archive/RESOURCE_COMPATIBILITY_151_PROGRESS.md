# Resource compatibility 151 — implementation progress

> 보관 기록: 2026-09-06 문서 정리 때 이동했습니다. 본문의 ‘현재·다음·미완료’는 작성 당시 기준입니다. 현행 안내는 [문서 색인](../README.md)과 [현재 경로](../MICRON_CURRENT_PATHS.md)를 따릅니다.

## Status and authority (2026-09-06)

### Closed — operator confirmed actual-game validation (2026-09-06)

After the Control Center integration below, the operator reported actual-game
validation complete and explicitly closed the resource-change response. Keep the
working 151/Epinel DLL combination unchanged. This is operator-reported acceptance;
no new automated runtime observation receipt was produced. It does not close the separately
deferred S29 profile mismatch or certify every voice-pack/weakness combination.
The current work is [backend stabilization](../STABILIZATION_PLAN.md), not additional
resource/DLL experimentation. The following checkpoint records preparation as it
stood before that operator acceptance.

### Deployment checkpoint — Control Center selects 151 for S26 (2026-09-06)

The operator requested connecting the existing Control Center to the successful
151/Epinel DLL combination, preserving progression, and carrying forward completed
150 best records only. The operator separately approved completing S26 first;
the pre-existing S29 v3 profile versus registered v2 digest mismatch is deferred.
Neither that profile nor its registry digest was changed by this integration.

Activation completed at the private verification root
`C:\NLL\Staging\PhaseD151Verification-0fe0d21a-4028-4f85-8df1-aae3b0ec1a72`.
`C:\NLL\ControlCenter\runtime-selection.private.json` now selects
`C:\NLL\Runtime\PhaseD151-v4\bundle.private.json`, SHA-256
`e004065e22fa4a21be28d009cff338cc0cf47a0ee02163c45a8b51dbf5c73b35`.
Independent active-bundle validation passed: exact 151 executable/GameAssembly,
unchanged Epinel DLL, local certificate overlay, and 22 scoped outbound blocking
rules. The official installation was not a write target; the 150 executable and
DLL hashes remain unchanged. No game was started by the installer.

The earlier successful probe used a separate synthetic account. Its missing
tutorial/story progress was not the intended Control Center behavior. Normal
151 execution now retains the existing selected-account materialization and
existing local progression seed, rather than copying the probe database or
registering another account. A before/after progression hash covers tutorial,
campaign, scenario, field, side-story and outpost completion fields. Read-only
database preparation preserved 40 tutorial groups and 611 completed scenarios.
This does not automatically mark newly added 151 content as completed.

Raid inheritance uses the same account, season and raid snapshot, with exact
150/151 executable bindings. An existing 151 head takes precedence. If absent,
the completed 150 best is decrypted with its original binding, validated and
projected into the new run without modifying the 150 source. Open runs and daily
counters are not inherited. The new version starts with no expected 151 head;
normal completion persistence creates a separate 151 revision. The S26 check
restored a completed best of **62,372,457,781**, with no open run. There was no
production record write during installation.

The versioned bundle changes runtime/data/bootstrap paths, not the provided DLL
implementation or the HTTP pipeline. Existing start/completion/rollback and
selected-account UI flows remain in use. Server blocking is owned by the same
per-run firewall group that existing completion removes. The clone-only DLL and
certificate overlay has original backups and pins in the bundle manifest;
installation creates the active selection pointer only after validation succeeds.
To reverse this deployment, first ensure all related runtimes are cold, then
remove that selection pointer, restore the two manifest-bound originals and
remove only `NLL PhaseD 151 Client Isolation`. Preserve all account and raid DBs.

Checks: materializer/bootstrap builds, 12 synthetic migration checks, read-only
S26/S29 data projection and S26 full coordinator `-ValidateOnly` passed. Generated
start/completion scripts parse. This is **not** a 151 battle or visible-progression
acceptance result: the next operator test is Control Center → S26 → lobby/progress
and a completed battle. S29 launch remains blocked by its deferred profile mismatch.
Full 2A1/2A2/2B verification was attempted but stopped at pre-existing whitespace
errors in `src/NikkeLocalLab.Automation.Cli/Program.cs`; no integration pass is
claimed from those attempts. Do not archive the 150 lane yet: native acceptance
and retirement of remaining legacy path/seed/rollback dependencies are pending.

### Previous checkpoint — unchanged Epinel DLL initializes successfully (2026-09-06)

The operator explicitly directed using the existing Epinel-provided DLL after
being informed that its load-time thread searches and modifies GameAssembly
memory. That decision supersedes the agent-written blanket prohibition for this
exact isolated trial; see `../SECURITY_BOUNDARY.md`. No new injection/patch code is
being authored. The previous 150 deployment uses this same provided DLL.

The v5 observation mode pins only that 358,400-byte upstream file, SHA-256
`54ee18f5ee3d16fea8bb6c3407a880727aa3b848f6a55908e6bf90f8635e5662`.
This is not the source-built 1.0.22 candidate. Its 609 versus stock 756 exports
and an earlier helper-process fault are not, alone, proof of game incompatibility.
The unchanged Epinel HTTP pipeline, resources, Korean Minimal preferences,
bounded initialization, external blocking and rollback remain in place.

The v5 trial `6cebd498-5b56-4eb5-95cd-488e40de418d` actually ran from
`05:23:28Z` to `05:27:40Z`. The operator reported that it works. Existing logs
corroborate passage beyond the earlier failure stages: zero DownloadPatch
initialization failures, zero RestartUnit mentions, one ResEnterServer and five
ResSyncTrigger mentions. The server log has zero MAC mentions, zero cryptographic
exceptions and zero cache misses. The 271,759-byte player log is preserved privately,
SHA-256 `b70a71b54202b9a950f9420fdff4cad4b4275e162655670731ef3a4223b38848`.

The server file manifest and requested Korean Minimal preferences matched the
stock reversal. The Epinel DLL exposes all 12 native crypto symbols identified
in the client analysis; its total export count alone was not a valid reason to
reject this trial. The source-built replacement was unnecessary for this observed
initialization result. Use the unchanged Epinel-provided DLL as the successful
151 initialization reference (`-UseEpinelProvided`); default stock mode remains
an explicit comparison tool, not the demonstrated working launch configuration.
Do not infer an exact internal patch target or full gameplay acceptance from this
result. Control Center integration, raid gameplay and complete migration are not
validated by this bounded initialization trial.

Runner cleanup and independent checks confirm original 151 DLL, certificate
bundle, hosts, voice preferences, trust and owned firewall rules were restored;
no client/server process survives. The 150 DLL remains unchanged. The official
source before/after inventories match all 1,061 files / 20,430,766,727 bytes,
canonical digest `5aa9a3e94e29ccc26c4b157f0108c9f3c8f4e02a85028035bbb2dc2720e53da0`.
Both full manifests are retained create-only with this assessment.

Focused checks pass: Epinel provenance admission 15 (6 negative cases), existing
key/baseline admission 39 (29 negative cases), HTTP-layer removal/package checks
56. Repository policy (7,710 files), Phase 0, historical 3A/3B0/3B1/3B2 contracts
and Actions pass. Full 2A1/2A2/2B integration remain blocked by pre-existing
`AccountImportExecution.cs:112–113` whitespace errors; these unrelated files
were not changed. No new product feature or cryptographic implementation was added.

### Previous checkpoint — rebuilt DLL violates client file-integrity contract

The 4/7 restart now has a concrete static explanation in addition to the native
stock/rebuild controls: the client assembles `sodium.dll` and
`/Plugins/x86_64/` character by character, reads that file, computes a managed
SHA-256 digest, and compares it with a 32-byte initialized constant. Its caller
branches to an unsuccessful initialization result when this check returns false.
Matching exports, version strings and cryptographic outputs cannot satisfy a
file-identity check for a different build.

Evidence, all from read-only analysis of the sealed 151 GameAssembly (SHA-256
`23b64ef22957356bfb3f02096a8fd59c5e2b6426bafb44520acd7fcd12a060ed`):

- The relevant routine has no user arguments, checks a hash self-test and a
  negative signature self-test, constructs the DLL path, and then performs the
  file-hash comparison. Its managed hash implementation has a 256-bit result,
  eight-word state, 64-byte block, the eight standard SHA-256 initialization
  constants and the SHA-256 small-sigma operations.
- Direct caller analysis connects its Boolean result to the failed-initialization
  branch. This is disk disassembly, not a live instruction trace or a memory dump.
  The expected 32-byte constant has not been extracted; do not claim its raw value
  was compared directly in an offline test.
- The DLL path is assembled from individual characters. Earlier zero-match ASCII
  or UTF-16 searches for `sodium.dll` therefore did not exclude this check. The
  relevant compiled methods reside in the executable `il2cpp` PE section, not
  just `.text`.

The consumed rebuild-only control `f11f627d-eb6e-4956-a06f-fda5d88d3ba6`
actually ran on the approved retry, `03:41:27Z`–`03:45:40Z`. It reproduces
`DownloadPatch - Initialize failed` and `RestartUnit` before `ResEnterServer`.
The 38,140-byte player log is now retained create-only in that private assessment;
SHA-256 `0339d9b45f4b5b40592848f2d63bc7be8fa365fc72f0841472e5ead504e6c49e`.
The earlier UAC cancellation below is historical and is **not** the final outcome.
The server manifest and Korean Minimal preference inputs match the stock reversal.
Runner completion means bounded execution/cleanup completed, not client success.
Independent rollback checks restored the original DLL, hosts, certificate bundle,
voice preferences and trust/firewall state; the full official-source post-inventory
still matched the reviewed 1,061-file / 20,430,766,727-byte baseline.

| Native control | 4/7 | Later encrypted server synchronization |
|---|---|---|
| Original DLL, including reversal | passes | 11 MAC failures after EnterServer |
| Unmodified-source rebuilt DLL | initialization failure / restart | not reached |
| Local-peer-substitution rebuilt DLL | initialization failure / restart | not reached |

This rules out peer substitution as a necessary cause of the earlier restart.
The rebuild changes the file checked by the original client. Compiler/build
differences need not change any cryptographic calculation to break that contract.
This finding does **not** resolve or explain away the separate post-login MAC
failure. Keep the stock DLL for that investigation; do not disable the client's
integrity/signature checks, substitute success returns or restore HTTP observers.
No additional native run or runtime/product code change was made during this pass.

Supplementary offline characterization:

- `tools/compare_resource_crypto_primitives.py`: 307 synthetic cases match between
  stock and baseline, both with and without an explicit `sodium_init` call in
  separate test processes. Includes split SHA/Blake2 hashing and noncanonical
  signature rejection. This is bounded coverage, not full native ABI acceptance.
- `tools/inspect_crypto_import_callsites.py`: public native-symbol references and
  bounded relative-call candidates; candidates were checked with disk disassembly.
- Windows version-resource fields, export names/ordinals and measured ABI values
  match. Linker versions differ (14.44 versus 14.51), but no compiler defect was
  demonstrated.
- The 79 resource `.nds` files have one common 32-byte prefix. Exploratory
  public-key-prefix/suffix interpretations of seven outer pairs produced no valid
  signature; they are not a format decoder or signature-validity result. Static
  reading instead shows a prefix comparison before the detached signature check.
  These inconclusive candidates are not the basis of the DLL-integrity finding.

Next diagnostic direction: preserve the original DLL and investigate the separate
post-login envelope/key contract on the local-server side using existing logs and
offline synthetic tests. Do not keep rebuilding/replacing the client crypto DLL,
clear resource caches, change voice language or download resources as an attempted
fix for this file-integrity failure. The stock reversal already demonstrates 4/7
passage; it does not demonstrate successful lobby entry.

Post-investigation checks: repository policy passes (7,709 reviewed files), as do
Phase 0, 3A/3B0/3B1/3B2 contract-only checks and the Actions contract. All five new
offline Python tools parse successfully. Full 2A1/2A2 and 2B `-Integration` still
stop in their prerequisite failure chain, consistent with the pre-investigation
baseline; no live PostgreSQL or native gameplay acceptance is claimed. The tools
and this record are diagnostic additions, not a product/runtime fix.

### Historical native checkpoint — stock reversal passes 4/7; MAC failure reproduced

This checkpoint supersedes the earlier **auth-only / not-started** statements
below; those paragraphs describe historical runs, not current readiness.

#### Follow-up: deployed cryptography comparison and rebuild-only control

The deployed 150 and 151 `ASodium.dll` files are byte-identical, as are their
server-native `libsodium.dll` files. A new isolated test,
`scripts/test-nll-resource-server-crypto.ps1`, uses those deployed components,
synthetic random keys and the actual client DLL. All 14 checks pass, including
directional key agreement, JSON key serialization/restoration, bidirectional
encryption, default wrapper key retention and wrong-key/AAD/tamper rejection.
The same checks also pass with `-UseSourceBaseline`. This rules out the tested
offline wrapper/direction/serialization failures; it does not prove the native
client's live envelope, AAD or peer key matches Epinel.

Read-only disassembly of the stock client library confirms that its client KX
entry uses the peer supplied by its caller. The rejected candidate substitutes
the local peer on **every call**, without distinguishing Epinel from other callers.
That broad semantic change is established; whether it causes DownloadPatch's
failure remains unresolved. No game process memory was inspected or modified.
The optional serialized-asset field scan is inconclusive: most relevant typetrees
are unavailable and the installed `global-metadata.dat` is empty. A zero-match
scan must not be reported as proof that no client peer-key field exists.

A v4 **unmodified-source rebuild control**, assessment
`f11f627d-eb6e-4956-a06f-fda5d88d3ba6`, is staged and input-inspected. Its UAC
dispatch returned Windows operation-cancelled; the runner/client/server did not
start. Plan SHA-256:
`a078cc09bc77797cb104570cf808bc468e4db571aeae39d12b808aaee1af3ad3`.
It admits only the already sealed baseline DLL (SHA-256
`e42dd6eda126ce4fe5e65254d9dd77b2ec86545513ec4c5db0fd7c4cd754b8ba`),
built without the peer-substitution macro. Server/resource/KO Minimal inputs,
24-program outbound isolation, service guard, runtime deadlines and exact
rollback remain unchanged. Default v2 still preserves stock; the known-regressing
v3 candidate remains blocked, including mixed-switch requests. Expanded admission
checks pass 39 checks / 29 negative cases, and HTTP-layer removal checks pass 56.
No MAC bypass, HTTP observer reintroduction, resource download or gameplay change
is part of this control. Native outcome and migration acceptance remain pending.

The control's pre-run official-source inventory again matches all 1,061 reviewed
files / 20,430,766,727 bytes and digest
`5aa9a3e94e29ccc26c4b157f0108c9f3c8f4e02a85028035bbb2dc2720e53da0`.
Post-cancellation checks at `02:38:34Z` verify all three planned mutation targets
still have their original pins, both voice preferences are unchanged, no run
marker or mutation/exec receipt exists, and no owned firewall rule remains.
`uac-cancelled.receipt.json` records this **not-started** result privately. No
rollback was needed or performed. Do not label the nullable process-id dispatch
output as successful launch; a future approved attempt must recheck all inputs
and refresh the before-inventory evidence first.

Post-change verification: repository policy passes with access to all reviewed
files (7,704 files); Phase 0, 3A/3B0/3B1/3B2 contract-only and Actions checks pass.
Header checks pass 117, and the repeated 25-value ABI comparison remains equal.
Full 2A1, 2A2 and 2B `-Integration` invocations still exit through their common
prerequisite failure chain; no PostgreSQL integration acceptance is claimed.
The isolated synthetic tests and prepared native control do not replace those
gates or the missing original-client runtime acceptance.

#### Stock reversal: two failure stages separated (2026-09-06 KST)

Assessment `09f13ed2-8d55-4f4b-80a2-2ec56127b70a` ran from `01:50:03Z` to
`01:54:14Z` with the original DLL preserved. The operator supplied another
`Server Sync [2/2] / Failed to load` screenshot. The client again passes
`DownloadPatch`, requests `ResStaticDataPackInfoMpk` at line 138 and succeeds at
`ResEnterServer` at line 894. The server reproduces **11 MAC verification failures**
in the same pre-handler decryption path, with zero cache-miss messages. This is
not a newly missing catalog or a repaired synchronization flow.

The stock → local-key candidate → stock sequence strongly implicates the candidate
deployment in the earlier 4/7 restart; resource cache removal was not needed to
restore 4/7 passage. It does **not** distinguish the source rebuild, changed peer
binding, or another native validation path as the precise internal trigger.
`scripts/test-nll-resource-native-abi.ps1` additionally compares 25 public version,
CPU capability and size-returning values for stock, unmodified-source rebuild and
local-key rebuild in isolated test processes. All values match (version 1.0.22,
ABI 26.4 included). This excludes the measured simple size/version mismatches,
not every ABI, semantic or native-client compatibility difference.

New preparation rejects `-UseLocalKeyBinding` with
`resource_native_key_library_native_regression` before staging anything. Default
stock preparation and historical v3 rollback support remain intact; build/test
artifacts and sealed evidence are preserved. The rejected candidate is not a
completed fix. Further work must resolve the post-login key/session contract and
the candidate's earlier initialization failure without disabling authentication,
MAC checks, client protections or isolation.

The runner and independent file/preferences/firewall checks confirm cleanup.
Current client logs and ABI observations are retained privately under this
consumed stock assessment. Full official-source post-run comparison matches the
1,061-file / 20,430,766,727-byte before inventory and digest
`5aa9a3e94e29ccc26c4b157f0108c9f3c8f4e02a85028035bbb2dc2720e53da0`.
The expanded admission test passes 25 checks / 17 negative cases, including
rejection of the native-regressing candidate. HTTP-layer removal/package checks
(56), header staging checks (117), and repository policy with the existing
approved remote enabled (7,702 files) also pass. Phase 0, historical 3A/3B0/3B1/3B2
contract-only and Actions checks pass. Full 2A1/2A2/2B-integration/3A/3B0/3B1
invocations fail through their common prerequisite chain; this does not certify
PostgreSQL integration. The pre-existing baseline failures are separate from the
focused checks above and were not repaired in this task. The comparison is also
preserved as create-only `comparison-outcome.private.json` with original log pins.
No lobby/gameplay or complete migration acceptance is claimed.

#### Local-key native retest: earlier restart, not a confirmed MAC fix (2026-09-06 KST)

Assessment `09146989-65e5-4e44-bc30-2dabd8c9470c` was actually launched under
operator UAC approval, `01:37:25Z`–`01:41:37Z`. The operator reported returning to
the initial screen during 4/7. The existing client log confirms two
`ERROR DownloadPatch - Initialize failed` exceptions (lines 138 and 273), each
followed by `RestartUnit`. `LoadCatalogs`, `PostCatalogSetup` and `IntegrityCheck`
timing entries precede the failure; those timing labels alone do not establish
which internal check failed. The asynchronous stack includes sound initialization
but does not establish that an audio file is missing.

The run never reaches `ResEnterServer` or the encrypted post-login requests.
Absence of a MAC exception in this run is therefore **not evidence of a MAC fix**.
The observed client exits with code 0 at `01:38:31Z`; this is distinct from the
earlier isolated legacy-DLL test-process faults. No new server cache miss is
recorded. No resource download, cache removal or HTTP diagnostic layer was added.

Manifest comparison against the stock 4/7-pass assessment finds identical server
file entries and voice selection. Among the 48 pinned client files, only
`sodium.dll` differs. This makes the new library a candidate cause, not a proven
one: mutable cache state was not reset or equivalently snapshotted before both
runs. The exact reason for `DownloadPatch` returning failure remains unresolved.

The runner reports isolation and cleanup verified. Independent checks confirm
restored original DLL/CA/hosts pins, both voice preferences and zero owned firewall
rules. Full reviewed official-source pre/post inventories match 1,061 files /
20,430,766,727 bytes and digest
`5aa9a3e94e29ccc26c4b157f0108c9f3c8f4e02a85028035bbb2dc2720e53da0`.
The private client log is retained under this consumed assessment. Native lobby
and gameplay acceptance remain unverified; the candidate must not be promoted.

A stock-preserving reversal run, assessment
`09f13ed2-8d55-4f4b-80a2-2ec56127b70a`, was freshly staged and UAC dispatched.
Its plan digest is `48282dad8fd27ae41b742dbfbc3657d8c605d59589364391cf6fd2d647e99097`.
It retains the server package, KO Minimal selection and existing cache; it does
not install either replacement DLL. Its before-source inventory is the freshly
completed preceding post-run scan, with explicit comparison provenance. An initial
UAC dispatch used an absent standard PowerShell path and did not start; dispatch
was corrected to the resolved installed PowerShell 7 executable. Its subsequent
native outcome is recorded above. Do not reuse either consumed run's plan for a
new execution.

#### Prior preparation: clean local-key library built; native retest pending (2026-09-06 KST)

The operator requested detailed comparison, correction and actual relaunch.
Comparison found byte-equivalent normalized 150/151 `PacketDecryption`,
`EncryptionMiddleware`, `AuthController`, `LobbyHandler` and server key declarations.
The existing Epinel key-exchange source explicitly binds the client operation to
the local server public key. The stock-preserving 151 resource-observation lane
omitted that compatibility binding. The current wire responses do not supply a
replacement server public key. This is a concrete deployment-contract mismatch,
not evidence that 151 changed the AEAD algorithm. Native confirmation is pending.

- An isolated synthetic test using the pinned stock library verifies valid local
  client/server keys and cross-direction agreement; using another synthetic peer
  reproduces MAC rejection. No official identity, session or traffic is used.
- The historical 1.0.18 compatibility DLL has 609 exports versus stock 1.0.22's
  756. Its separate test-process initialization also faulted in `USER32.dll`.
  It was not installed or reused in the new client plan. Windows recorded test
  process faults only; those are not new game-client crashes or a solved cause
  of every historical shutdown. Further legacy execution was removed from the test.
- The clean build uses the official [libsodium 1.0.22 release](https://github.com/jedisct1/libsodium/releases/tag/1.0.22-RELEASE),
  commit `77e1ce5d6dee871c49ef211222ba18ef0c486bda`. Only the conditional local-peer
  binding in `crypto_kx_client_session_keys` differs from that source. The reusable
  source-only patch is `patches/libsodium-local-peer-binding.patch`; the source
  checkout/license and generated public-key binding remain local. No legacy
  binary code, process injection, hooking, protection changes or new HTTP layer
  are incorporated. Server-side authentication and MAC checks are unchanged.
- `scripts/build-nll-resource-key-compat.ps1` builds baseline and local variants,
  validates source/patch identity, exact **756-name export equality** against stock
  and baseline, and rejects specified process/window/network imports. The first
  export inspection failed because the parser did not accept PDB symbol suffixes;
  the corrected inspection confirms no actual function deficit.
- `scripts/test-nll-resource-key-agreement.ps1 -CheckCandidate`: **15 checks pass**,
  including candidate initialization, local peer substitution, unchanged server
  key-exchange behavior, encrypted round trip, wrong-peer and tamper rejection.
  `scripts/test-nll-resource-key-admission.ps1`: **23 checks pass**, including 16
  negative receipt cases. Header staging 117 and HTTP-removal/package 56 checks
  remain passing; historical 3A/3B0/3B1/3B2 and Actions contracts pass. The full
  baseline still fails existing unrelated whitespace in Admin/Automation sources;
  PostgreSQL integration is not claimed passed by this attempt.
- The candidate DLL SHA-256 is
  `01c569e72ad2ead6567a9f69a733551875f6d00f36674ffd312ca15388a59889`.
  Build receipt digest: `cd26d9a1f59c95efffd4a0128a4ea241eaac77b1d23dd850e96e639a255ad9d8`.
  The reviewed source patch digest is
  `4330442a750237485de429f7be750c3d88156dfd039b248e1c765390361f5508`.
- Default preparation remains stock-preserving v2. Explicit `-UseLocalKeyBinding`
  creates v3 with exactly one extra mutation target: the separate clone's
  `sodium.dll`. Exact DLL/build/test pins, original backup and rollback are sealed
  before launch; all 48 bootstrap client-file pins include the applied DLL digest.
  The runner and standalone recovery retain cold-state, complete program blocking,
  related-service abort, loopback-only listeners, fixed deadline and original-file
  restoration. No arbitrary DLL switch is accepted. Old sealed plans are untouched.
- Fresh assessment `09146989-65e5-4e44-bc30-2dabd8c9470c`, native plan digest
  `3eb93f3268b2364040c26fd56cabdbc118c4cd88428be5a31d605817b74ce65c`, passed
  `-InspectInputs` without starting client/server or applying configuration.
  Runner digest: `07af125c2fc86e9b4def85a2a149d3b5559587f9b966268e06a240b9be599513`.

At that preparation checkpoint the new library was **built and staged, not installed or
native-verified**. The next step was the operator-visible UAC run and existing-log
comparison of `ResEnterServer` → encrypted requests → lobby synchronization.

#### Native retest: header fix passed; post-login packet decryption fails (2026-09-06 KST)

The operator authorized actual launch and confirmed **4/7 passage**. Their new
screenshot shows `Server Sync [2/2]`, progress 50, and `Failed to load`, rather
than the earlier `Catalogue resource path upgrade` error. Assessment
`4e4a256c-3527-443d-a88e-56ca7c946720` is now **consumed**; its native plan digest
is `d95822fcc326fe1a3c114978bc07abb8eac2f0a920fd537e45305a36299e757c`.

- Execution lasted `2026-09-06T00:53:49Z`–`00:58:01Z`; native handoff was recorded
  at `00:54:15Z`. The `NIKKE` window was independently observed responding. The
  related-service abort did not recur. No guard, service configuration, native
  library or server implementation was changed for this retry.
- Existing server logs show the normal resource handler sending the cached file,
  with zero cache-miss messages in this run. Client-log line 130 records resource
  discovery success; lines 140–142 record static-data download/table loading.
  The operator's screenshot supplies native 4/7-pass evidence. No diagnostic HTTP
  observer was restored, and no unavailable request-count metric is inferred.
- `ResEnterServer` succeeds at client-log line 894. Subsequent
  `ReqUserOnlineStateLog`, `ReqGetJupiterProductList` and `ReqGetNow` requests fail
  with HTTP 500. The visible failure follows `InitializeEnterLobby` /
  `GetServerDailyResetHour`.
- The server records **11** `CryptographicException` occurrences, first at
  server-log line 220: `Verification of MAC stored in cipher text failed`.
  The stack is `PacketDecryption.DecryptOrReturnContentAsync` →
  `EncryptionMiddleware.Invoke`. The candidate source locates the failing AEAD
  call at `EpinelPS/Utils/PacketDecryption.cs:48`, before request-handler dispatch.
  A successful lookup precedes that call, so this exception is not the explicit
  invalid-token branch; it does not prove that the selected session/key is correct.
- **Immediate failure:** authenticated post-login packet decryption, not another
  missing version header. The logs do not distinguish key agreement/direction,
  session binding, envelope/nonce parsing or additional-data encoding. The exact
  mismatch remains unresolved. MAC validation must not be disabled to continue.
- The retained private client log is 468,948 bytes, SHA-256
  `8d292f8d4e2e660222834833a629d276736cd005209335cc067260aea9e21bfc`.
  Raw logs remain under this assessment; no session/key values or payload bytes
  are copied into this document.
- The receipt reports `bounded_initialization_run_completed`, native handoff,
  isolation/cleanup verified, no failure/cleanup error and no production DB changes.
  This is not successful lobby/gameplay acceptance. Independent checks confirmed
  original hosts/client-CA pins, stock native pin, both voice preferences and zero
  owned firewall rules. Full reviewed official-source pre/post inventories match:
  1,061 files / 20,430,766,727 bytes, digest
  `5aa9a3e94e29ccc26c4b157f0108c9f3c8f4e02a85028035bbb2dc2720e53da0`.

Next: compare the existing 150/151 local server key agreement, `ResEnterServer`
session binding and encrypted-envelope contracts using synthetic fixtures. Keep
authentication/MAC checks intact; do not restore HTTP inspection, capture official
traffic, acquire more resources or patch the client. No new-error code fix was
implemented in this retest. This KO Minimal 4/7 passage does not establish all
language/volume/quality combinations, full provider closure or battle acceptance.

#### Retest attempt: stopped before client handoff by related-service admission (2026-09-06 KST)

The operator authorized relaunch and the UAC runner was dispatched for the new
header-containing assessment `55f33a10-9a6f-49e4-b65e-984502a09d48`. This attempt
is now **consumed**, not `staged_not_started`; a later retry requires fresh staging.
It does not provide a native result for the header fix.

- Execution ran `2026-09-06T00:37:31Z`–`00:37:58Z`. Synthetic server authentication
  reached the existing handlers, but no `bootstrap-start.receipt.json` was written.
  `clientHandoffObserved=false`; no 4/7/header-request outcome was measured.
- The existing bounded-run guard detected `ACE-Service64.exe` at `00:37:56Z`.
  The private role receipt identifies `installed_related_service`, zero-based
  program index 15, PID 19828 and parent PID 1332. Read-only parent lookup resolved
  that parent to `services.exe`. This is a related service, not evidence that the
  operator started the official launcher. The exact initiating service caller is
  not established by that parent relationship.
- The controlled failure retains the broader historical code
  `resource_native_official_launcher_spawned`, at stage `native_observation`.
  Status is `native_observation_incomplete`, not a resource-header failure or a
  successful game launch. No service configuration, native compatibility library
  or guard predicate was changed to continue execution.
- The runner reports isolation and cleanup verified, no cleanup error and no
  production DB mutation. Independent follow-up confirmed restored hosts/client-CA
  file pins, stock native-library pin, both original voice preference values and
  zero firewall rules owned by this assessment. The related service was stopped
  at follow-up; no new service configuration change was made.
- The reviewed official-source pre-run inventory matched 1,061 files /
  20,430,766,727 bytes and digest
  `5aa9a3e94e29ccc26c4b157f0108c9f3c8f4e02a85028035bbb2dc2720e53da0`.
  The post-run scan matched that same full reviewed inventory and digest exactly.
  Private pre/post inventories were retained in this assessment. Repository policy
  and all 56 HTTP-removal/source/package checks also passed after the attempt.

At this historical attempt, the last client-observed result remained the earlier
3/7-pass / 4/7-header-404 run and the preparation fix was **native-unverified**. Do not
reuse this consumed plan, automatically ignore the related service, restore the
removed HTTP inspection layer or infer new acquisition authority from the abort.

#### Implementation: version header staged and sealed; native retest pending (2026-09-06 KST)

The operator authorized the correction identified below. The missing-header
preparation fix is implemented, tested and staged in a **new** 151 assessment.
No server/game process or UAC execution was started during this implementation.
The last actual native result remains 3/7 passed / 4/7 blocked until a retest.

- `scripts/Nll.ResourceHeader.ps1` is an offline preparation helper, not an HTTP
  layer. It derives the header path from effective resource base, platform and
  data-pack selector; no build, selector or voice language is embedded in that
  transformation. The existing `/prdenv` route and reviewed local ports are
  explicit compatibility boundaries, not an arbitrary filesystem/download API.
- The helper verifies the pinned acquisition-receipt hash, its request hash,
  build/source-config identity, exact original metadata URI, successful acquisition,
  size and original byte digest. Only the serving port may differ from the
  acquisition URI (443/8443). Redirect/credential/proxy flags, malformed paths,
  traversal, query strings and reparse paths are rejected before copying.
- Authentication preparation now copies the original header bytes create-only
  into the normal cache before sealing. Existing sealed runtimes cannot be patched
  through this helper. Both authentication and native preparation require exactly
  one matching header pin and re-read its contents before writing their manifests.
  Existing runtime inventory/hash verification then protects that declared file.
- No normal Epinel handler, server DLL, authentication semantics, diagnostic
  removal boundary, client file, voice preference, hosts/trust state or production
  DB was changed. Preparation generated rollback *files* but did not apply them.
  No additional download occurred, and no catalog/payload binding was invented.

Validation: **117 synthetic preparation checks**, **56 HTTP-removal/source/package
checks**, and **177 existing focused tests** passed. Coverage includes two synthetic
build/selectors/platforms, unchanged header paths across KO/EN/JA/no-audio selection
fields, local serving ports, exact byte preservation, missing/duplicate/drifted
pins, corrupted/empty/oversized/missing inputs, invalid acquisition bindings,
reparse/traversal paths and prevention of overwriting a sealed runtime. These
selection tests cover the header's independence from voice settings, not native
no-audio preference encoding or full voice payload readiness.

Historical staging (subsequently consumed by the attempt above):

- Assessment: `55f33a10-9a6f-49e4-b65e-984502a09d48`; preparation status was `staged_not_started`.
- Native plan SHA-256:
  `b3a7e4c828b6727e2537f36bd054aa0073c9adc32716eebe1594cd4c7cf3af91`.
- Runner SHA-256 (unchanged):
  `8a410070d84e0523a82a448d64546db828346ded3a49c44e4180993015a46770`.
- Server DLL SHA-256 (unchanged removal build):
  `c4f34958798acfab0b81bbc6a46b82e2b91c695fdafb740815cfcc4b2407c892`.
- All **76 runtime file pins** match; the runtime-manifest digest matches the
  native plan. The normal handler's resolved header file exists, is **139 bytes**,
  and matches `df1d7403a5a24f16fb5eb59ba436c1f04236b691f95ef30634f22b92ed306856`.
- The plan retains KO Minimal, 48 client pins, 8 owned program pins and 16
  block-only program pins; `diagnosticHttpLayerPresent=false`.
- Evidence and runtime are under the existing private `ResourceProbeRuns` and
  `EpinelPS-151-ResourceProbe` roots, keyed by this assessment. Earlier attempts
  were preserved, not modified or re-sealed. The Control Center's 150 production
  target and the future D: archive remain unchanged.

Next: request UAC for the **new assessment**, perform the operator-visible native
retest, and inspect existing logs for the next result. A successful offline copy
is not an observed HTTP 200, 4/7 completion, catalog-version match or lobby/battle
acceptance. The subsequent `151.8.b16`/installed-catalog binding and 151 chunk
provider integration remain unresolved; no additional acquisition is authorized
by this staging change.

#### Offline investigation: first 4/7 failure identified (2026-09-06 KST)

The operator requested investigation only. No code/configuration/resource changes,
native relaunch, HTTP interception or network acquisition were performed. The
remaining failure in assessment `b6b2616c-5e44-420d-ba1a-e67a8fd1e19b` is now
localized to **missing version-header delivery**, before outer-catalog loading.
This identifies the first blocker; it is not a claim that all 4/7 work is solved.

Evidence correlation:

- The current private `Player.log` is 38,827 bytes, last written
  `2026-09-05T17:10:51Z`, SHA-256
  `a90719095e19a524ffb3a6985cd50237c71b83ac66343cde0d87c8b0d921ac63`.
  Its resource root is the separate 151 clone. Line 130 records successful
  `ResGetResourceHosts2`; line 131 reports `GetVersionAsync` failure for the
  version-header request; line 145 reports HTTP **404**. The stack reaches
  `ContentVersion2.GetVersionAsync` and `DownloadPatch.InitializeAsync`.
  No `Fetching catalogs:` event appears in this attempt's log.
- The request is the effective `ResourceBaseURL`, with `{Platform}` resolved to
  `StandaloneWindows64`, followed by `pck/latest-{ResourceDataPackVersion}.txt`.
  Here the selector is `653`. The recorded hosts plan maps that request's host
  to loopback; the existing server log enters `/prdenv/{**all}`, then records
  one `local_only_asset_cache_request` and one `local_only_asset_cache_miss`.
  The prior ablation's retained private client log has the **same failed URI**.
  Private origin paths/header values are not copied into this document.
- `AssetDownloadUtil.DownloadOrGetFileAsync` normalizes the path and calls
  `Program.GetCachePathForPath`: `<runtime>/cache/<request-path>`. That exact
  file is absent, although its parent exists. With outbound disabled, the
  existing handler returns null and `HandleReq` sets **404**. The actual cache
  contains only one static pack and four server locale files; the sealed runtime
  manifest contains no version header.
- The requested object was already acquired under the prior two-object approval:
  the private acquisition request contains this exact URI, and the receipt records
  `version_metadata`, HTTP 200, **139 bytes**. Local `version-metadata.txt` still
  matches SHA-256
  `df1d7403a5a24f16fb5eb59ba436c1f04236b691f95ef30634f22b92ed306856`.
  Offline parsing confirms seven roles and core revision `151.8.b16`.

The preparation gap is in `scripts/prepare-nll-resource-probe-auth-smoke.ps1`:
it verifies this metadata and extracts its core revision into configuration,
but stages only the static pack and locale files into the cache. Native preparation
reuses that staging, changes the resource port to 443, and repins the files; it
does not supply the omitted header. Removing the diagnostic observer did not
automatically make its former resource-serving responsibility part of the normal
resource path. The missing responsibility must not be restored as an HTTP filter.

Proposed correction, **not implemented**:

1. Derive the header cache destination from effective build/platform/resource-host
   configuration and data-pack selector. Verify the approved acquisition request,
   original bytes and digest; stage the file create-only before sealing a fresh
   runtime. Do not hard-code build 151, selector 653, a language or an origin path.
2. Add offline preparation tests for the normal handler's exact path resolution,
   file presence, byte identity and manifest inclusion. Missing or mismatched
   declared startup inputs must be detected before a native run, without adding
   request authentication/header rewriting or restoring the removed observer.
3. Verify the resulting header response separately from subsequent catalog/payload
   delivery. The acquired September 5 `151.8.b16` header is not yet proven to match
   the September 3 installed catalogs. Preserve that unresolved binding; the 151
   chunk provider is still not registered in the normal Epinel resource path.
4. Keep all seven outer metadata roles separate from payload selection. Resolve
   KO/EN/JA, Minimal/Full, base-only/no-audio and independent graphics qualities
   through their selected groups. Catalog-only unselected languages do not imply
   that all language payloads must be downloaded. Native no-audio preference
   encoding remains a separate unresolved detail.

The identified header fix needs **no additional download**. Any later need for
new outer catalogs or payloads is outside the earlier two-object approval. Neither
the official-current installation nor the 150 production lane should be changed.
The current first failure does not establish a voice-pack, SQLite, chunk-decoding
or resource-content corruption fault: those later stages were not reached.

#### Latest native retest: permanent-removal build reaches 4/7 (2026-09-06 KST)

The operator requested a relaunch of the removal build, approved UAC and supplied
a screenshot confirming **G151.8.5 / 4/7 / Catalogue resource path upgrade /
System Error**. Assessment `b6b2616c-5e44-420d-ba1a-e67a8fd1e19b` uses a freshly
staged v2 plan (SHA-256
`e61533add58feb4fc2b4c45bde22156e8e531a30cde810186570f9680cd23c32`) and the
published removal DLL identified below. No further code/resource changes were made.

- Original Epinel handlers were the only HTTP dispatch path;
  `diagnosticHttpLayerPresent=false`. KO Minimal, 48 native file pins, 8 owned
  executable pins and 16 block-only program pins were retained.
- The run spanned 2026-09-05 17:10:08–17:14:20 UTC. The synthetic SDK authentication
  and Sail handoff completed at 17:10:35 UTC and one client process started.
  The official launcher was not started; no anti-cheat substitution was applied.
- The screenshot confirms **3/7 passed; 4/7 still blocked** in the permanent-removal
  build, not only the previous temporary ablation. Existing private server logs
  contain one `local_only_asset_cache_miss`. Exact requested catalog binding is
  still unresolved. No per-route status/traffic count is inferred from the absent
  removed observer; v2 correctly reports `requestCount=null / not_collected`.
- The bounded run ended with `failureCode=null`, `isolationVerified=true` and
  `cleanupVerified=true`; hosts/trust/client-CA/preferences were restored and owned
  processes stopped. `bounded_initialization_run_completed` does not mean the
  loading error was fixed: native admission remains `not_evaluated`, gameplay
  unvalidated and production DB unmodified.
- The reviewed official-source pre/post inventories match: 1,061 files /
  20,430,766,727 bytes, digest
  `5aa9a3e94e29ccc26c4b157f0108c9f3c8f4e02a85028035bbb2dc2720e53da0`.
  Remaining firewall rules owned by this attempt: zero. Repository/Phase 0/
  Phase 3A/3B0/3B1/3B2/Actions contract checks passed; the full baseline before
  and after again stopped at the same unrelated pre-existing formatting errors.

Next investigation remains offline correlation of the 4/7 request/resource binding
against installed 151 catalogs and the local provider. Do not restore diagnostic
HTTP filtering, guess a replacement version/language, enable runtime CDN fetching,
or interpret this observation as permission to acquire additional catalog objects.

#### Prior implementation checkpoint: diagnostic HTTP layer permanently removed (2026-09-06 KST)

The operator authorized permanent removal after the ablation below. This is now
implemented and published in the **separate 151 candidate**, not merely disabled
by a flag. No native game/server run or UAC launch was performed in this change.

- Removed `ResourceProbeExecution.HandleAsync`, extra request/auth/header/route
  filtering, header rewriting, `SetLocalStartupAuthorization`, dispatch recording,
  both dispatch modes and the embedded resource observer adapter. The candidate
  no longer references the resource-preflight project. No replacement observation
  middleware or runtime event subscriber was added. Existing private server logs
  remain available for offline analysis; they are not public/source-free receipts.
- The full HTTP registration block is identical to the existing 150-based server.
  Eight startup/auth/encryption/resource-handler source files are unchanged in
  content (normalizing checkout line endings). Original Epinel authentication
  remains; removing the extra filter does not disable it.
- Preserved sealed inventory/hash checks, fresh synthetic DB/account context,
  loopback binding, local-only/no-download mode, native-library pins, scoped
  outbound blocking, process safety checks, time bounds and rollback. These are
  process/environment boundaries, not HTTP interception. Gameplay remains outside
  this initialization experiment's scope; it is no longer claimed to be blocked
  by a diagnostic route allowlist.
- New server/native plans and auth preparation receipts use **v2**. Current
  launch scripts reject v1 plans, and server deserialization rejects removed or
  unknown fields. There is no guarded/passthrough fallback. Historical sealed
  runtimes/receipts are retained unchanged for evidence; standalone recovery
  accepts v1 and v2 solely to restore prior attempts.
- New preparation reads `artifacts/resource-probe-151/epinel-server-v2`, a clean
  publish directory without the old observer DLL/dependencies. EpinelPS.dll SHA-256:
  `c4f34958798acfab0b81bbc6a46b82e2b91c695fdafb740815cfcc4b2407c892`.
  Future execution requires fresh staging, not re-running an old UAC command or
  replacing binaries inside a sealed runtime. The Control Center's 150 production
  target and the official-current installation were not changed.
- The v2 execution receipt uses `requestCount=null`, `not_collected` and existing
  private logs as its HTTP evidence source. No missing observer count is reported
  as zero traffic. `bounded_initialization_run_completed` means handoff + bounded
  process completion + cleanup only, never 4/7/lobby/battle acceptance.

Validation: **177 focused tests**, **26 native-helper checks** (including fresh
synthetic HKCU round trips), and **56 source/packaging/PowerShell checks** passed.
Obsolete tests that demanded the removed request filter were removed/replaced;
the new tests cover absence of HTTP entry points, rejected legacy fields and
preserved plan/inventory/configuration boundaries. Candidate publish succeeded
with existing upstream warnings. The two TLS tests require the normal Windows
crypto/loopback test context; both passed there, not in the restricted sandbox.
The full baseline restored/built but again stopped on pre-existing whitespace
errors in Admin.Api `AccountImportExecution.cs` and Automation.Cli `Program.cs`;
downstream live PostgreSQL gates were not reached. This is not a full-baseline pass.
Phase 0, Phase 3A/3B0/3B1/3B2 contract-only, Actions contract and repository policy
(7,179 files) passed. Portable .NET 10 locked restore also passed after the baseline.

Removed source files have a local recovery copy under
`artifacts/diagnostic-layer-removal-backup-e30d52bf59a948b9b928af2e70ae5ae0`;
that copy is not compiled or selected for execution. Standalone opt-in offline/
synthetic resource tools remain separate and are not invoked by native preparation.
At this implementation-only checkpoint, **4/7 catalog binding/provider delivery
remained unresolved** and the last native observation was the ablation below.
The subsequent permanent-removal retest is recorded above.

#### Prior native test: middleware ablation passed 3/7 (2026-09-06 KST)

The operator explicitly requested excluding the diagnostic request layer as the
experimental variable. Assessment `5699cca5-7bf3-4747-a701-275371862509` used the
opt-in, manifest-pinned `legacy_pipeline_passthrough` mode. It delegates each
request unchanged to existing Epinel, does not invoke the resource observer or
its own admission/authentication checks, and records bounded source-free outcomes
only. The unchanged application still owns authentication/response semantics;
this is not a global authentication-disable switch or production default.

- Relative to the prior staged native attempt, all 48 native file pins, bootstrap
  executables/libraries, server configuration, KO Minimal selection, duration and
  block-only program hashes matched. Only the server DLL changed among server
  manifest files. Each attempt still generates a new assessment, synthetic
  account/key and empty DB; historical credentials or DBs were not reused. The
  launcher also gained passive program-role/PID evidence, without changing its
  existing abort predicate. This comparison isolates the request-layer factor
  at that level; it does not identify one particular rejected header rule as the
  sole defect or establish literal whole-process byte identity across runs.
- Execution was 2026-09-05 15:48:34–15:52:45 UTC. The original 151 clone completed
  the Sail handoff. The operator's screenshot shows **4/7 / Catalogue resource
  path upgrade / System Error**. The client log records completed world-registry,
  server-info and version-check initialization.
- World-registry, sentry parameters, server information, version check and
  resource-host discovery returned **200**. The latter four carried
  `authorizationShape=other_nonempty`; no header value was recorded. Therefore
  treating every nonempty startup header as a fresh SDK PASETO token is not
  supported by this observation. The actual other-header semantics/provenance
  remain unresolved; do not infer it is an official credential or broaden normal
  authenticated routes to accept arbitrary tokens.
- Twelve passive dispatch outcomes were recorded; the last was an `other` request
  with 404, alongside `local_only_asset_cache_miss`. This establishes a subsequent
  resource failure, not exact catalog/version closure. Resource-observer request
  count is intentionally zero in passthrough mode and must not be interpreted as
  no resource traffic.
- The execution receipt reports `legacy_pipeline_probe_completed`, isolation
  and cleanup verified, no production DB mutation and no gameplay acceptance.
  The native request-filter regression is demonstrated; 4/7, lobby and battle
  readiness are still unresolved. The bootstrap separately mislabels its expected
  180-second cancellation as an unexpected Sail-stage failure; the completed
  handoff and independent cleanup receipt disambiguate this known reporting issue.
- The full official-current pre/post scan matched exactly for this attempt:
  1,061 files / 20,430,766,727 bytes, SHA-256 manifest digest
  `5aa9a3e94e29ccc26c4b157f0108c9f3c8f4e02a85028035bbb2dc2720e53da0`.
  This comparison uses the already-reviewed post-report-removal source state;
  it does not erase the earlier two-file history. The client log was preserved
  only in this assessment's protected private directory. Final owned rule count
  was zero; repository working-tree policy passed (7,183 files).

At this earlier checkpoint the operator asked whether to remove the diagnostic layer completely. The
recommended architecture is to remove its active request filtering/resource
interception from normal execution, retain non-interfering observations and move
preflight/isolation/pin/rollback checks outside request dispatch. Permanent removal
was not yet implemented at that checkpoint; only the explicit ablation had run.
The guarded default described here is superseded by the v2 implementation above.
Focused tests: **211 passed**; native-helper tests including synthetic HKCU
round trips: **26 passed**. Candidate publish and portable locked restore passed.
The full baseline chain again stopped at pre-existing Admin.Api/Automation.Cli
whitespace errors; live PostgreSQL downstream gates were not reached. Phase 0,
Phase 3A/3B0/3B1/3B2 contract-only and Actions contract checks passed.

#### Prior 3/7 observations

- Assessment `2e47603a-7968-4076-86af-b877039ebf68` started the separate
  G151.8.5 clone with its stock native library. Synthetic local login and the
  Sail pipe/shared-memory handoff succeeded; the official launcher was not run.
- All 24 scoped program outbound blocks were verified before launch. The bounded
  run finished with `cleanupVerified=true`: owned processes stopped, temporary
  hosts/client CA/system trust/preferences restored and owned rules removed.
- The operator observed **3/7 World Registry Requesting / Unable to connect**.
  The private observer captured one GET of the startup route configuration and
  returned 404. The resource-host middleware had incorrectly captured this
  non-resource request before Epinel's existing local world-registry handler.
  Client fallback subsequently reported a socket access denial; external blocking
  must not be relaxed to work around this local routing error.
- Source now separates the canonical startup route-config GET from resource
  observation. Unknown resource paths still cannot reach legacy asset handlers.
  **184 focused tests pass**, including the actual middleware dispatch order,
  malformed/non-registry rejection and metadata dispatch. Native retest
  `f62909a6-2a41-4ec9-8e41-92fa1da7d5b2` reached the local world-registry
  handler and the operator observed **World Registry Complete**. The subsequent
  `ReqGetSentryParams` failed with **403**, before resource observation (0 resource
  requests). Automatic isolation/cleanup both verified again.
- The next diagnostic revision admits only the two missing startup handlers
  (sentry parameters and server information), handles credential-free empty bearer
  markers, and accepts a nonempty bearer only on the narrow startup allowlist
  after validation with the fresh server key and synthetic SDK account store.
  Arbitrary/official credentials, cookies, proxy authorization, gameplay and batch
  requests remain rejected. A bounded source-free dispatch receipt records which
  guard/route branch ran, not header values. Assessment
  `91f89df0-fe2c-4d3a-9080-3d610406c059` then confirmed `startup_sentry /
  nonempty_authorization / 403`; cookies were absent, world-registry returned
  200 and cleanup verified. Resource observation remained empty.
- The follow-up aligns prefix handling with existing Epinel: either `Bearer
  v4.local...` or raw `v4.local...` must undergo the same cryptographic/fresh-account
  verification. Prefix shape alone never admits a token. Decision receipts now
  include controlled shape labels, not token bytes. **203 focused tests pass**;
  the raw-token revision's native measurement is pending.
- The bootstrap's expected diagnostic deadline was recorded as TaskCanceledException
  in this run; it is not evidence of a Sail handoff failure. The completed start
  receipt and independent runner cleanup receipt remain the relevant evidence.

#### Follow-up safety stop (reviewed 2026-09-06)

- The operator requested UAC again after being away. Assessment
  `bdb9bedd-2e54-4a28-941f-ad3e27bd3a6c` ran from 2026-09-05 14:53:09 to
  14:53:31 UTC and stopped with `resource_native_official_launcher_spawned`.
  Its receipt records `isolationVerified=true`, `cleanupVerified=true`,
  `clientHandoffObserved=false` and zero resource requests. Local synthetic SDK
  authentication reached the server, but no completed native handoff/startup
  authorization measurement was recorded. The raw-token revision remains unverified.
- The failure label is broader than its name: the runner checks all 16 pinned
  block-only programs, including the installed protection-service executable,
  not just the official launcher. The operator explicitly confirmed that they
  approved only UAC and did not separately launch NIKKE or its official launcher.
- Windows Service Control Manager recorded an unexpected termination of
  AntiCheatExpert Protection at 14:53:28 UTC, during the abort/cleanup window.
  This is evidence of service activity, not proof of which process requested
  startup, which program triggered the guard, or whether termination preceded
  cleanup. The guard did not retain the matched PID/path index. Do not attribute
  this event to a user-initiated official launch or claim the originating process
  is established. The subsequent service state was stopped and the assessment's
  firewall-rule count was zero.
- Do not repeat this executed assessment or relax isolation/protection checks.
  Before another approved native attempt, diagnostic evidence should distinguish
  the matched program role/index, PID, parent PID and creation/observation times
  without recording command lines, tokens or unrelated process inventories.
  At that checkpoint neither instrumentation nor a further attempt had been
  performed. The later explicit ablation above added passive program observations
  and completed a new attempt without changing the stop condition.
- A post-run official-current integrity comparison found 1,061 of the original
  1,063 files remaining. The only missing members were two old CrashSight report
  files, totaling 4,504 bytes. Recomputing the baseline manifest without those
  two members exactly matched the complete post-scan digest: all remaining
  relative paths, lengths and SHA-256 hashes were unchanged. The cause of report
  removal is unresolved; no reports were restored or their contents inspected.
  Do not describe the entire official tree as unchanged or silently rebaseline
  the sealed clone on this basis. Production DB and the frozen 150 lane were not
  modified by this diagnostic.

Earlier native attempt `8e610a53-78a1-4667-a01f-5921269f637f` failed before server
or game startup because PowerShell unrolled a binary registry value into object[].
The helper now passes byte[] directly to Registry.SetValue; **21 synthetic helper
checks pass**, including isolated temporary-HKCU round trips. A later standalone
recovery receipt verified complete restoration of that attempt; its original
failure receipt is retained unchanged.

**Still unfinished:** exact native resource/version binding, connected verified
151 payload provider, user loading/lobby/S26/result/restart acceptance, Control
Center integration and eventual 150 archival. No additional CDN catalogs were
acquired, no production DB was changed and no 150 client was moved. This 3/7
diagnosis does not establish that the original 4/7 resource issue is resolved.

Validation boundary: the full post-change Phase 3B2 chain, retried with normal
dependency access, passes restore/build and stops at the previously recorded
whitespace violations in Admin.Api account import and Automation.Cli. Downstream
live PostgreSQL gates were not reached. Repository policy (7,181 files), Phase 0,
Phase 3A/3B0/3B1/3B2 contract-only and Actions contract checks passed. An interim
candidate publish propagated win-x64 into shared build lock state; portable locks
were restored and subsequent candidate publishes use a separate obj lock-file
path. A portable locked restore passed afterwards. None of these checks certifies
native lobby, resources or battle acceptance.

### Earlier checkpoints

Latest measured continuation: the separate **151 server/auth-only smoke passed**
under assessment `1dea34a2-1e91-4048-aca7-1b66ce3f712e`. Two exact-program outbound
block rules were verified before startup; a fresh synthetic account completed
local TLS authentication, the server stopped at its 60-second limit, and owned
process/rule cleanup was verified. **170 focused tests pass.** The IP-prefix
rejection and incorrect leaf-as-root TLS trust discovered during preparation were
corrected without system trust changes. See the newest provider checkpoint.
No game, hosts/CA/preferences change, production DB mutation, 150 archive or native
resource acceptance occurred. Statements below that no 151 server had started
describe earlier checkpoints; the only new execution is this bounded auth smoke.

Newest continuation: the separate metadata-only route observer and private
staging/inspection path are implemented. **136 focused tests pass**, including
real synthetic loopback TLS and listener cleanup. The actual private plan is
staged and inspected, but its listener, Epinel 151 and the native client have
**not** been started. See the latest provider checkpoint for the plan digest and
the outstanding native-start technical gates. The operator clarified that Micron
already is the separate experimental OS; the redundant designation question is
withdrawn. Full process-tree external blocking remains mandatory for every local
compatibility run, not only this 151 test. Exact native routes, installed-version
binding and the six-task goal are still unverified.

Implementation authorized by the operator after the diagnosis/plan-only phase.
First native test: **installed Korean audio**. `Minimal` is the minimum download
scope, independent of voice playback volume, mute, and UI language. Preferences
have not been changed yet. No 151 client/server launch, UAC deployment, official
installation mutation, production DB change, or Golden promotion was performed.

Current result: **offline implementation and partial validation; native launch
still blocked on unresolved resource inputs/contracts**. This is not a 4/7 fix
acceptance receipt. The source checkout alias resolves to the canonical Micron
repository; current paths are defined in `../MICRON_CURRENT_PATHS.md`.

Latest comparison: [151 installed-catalog verification](RESOURCE_COMPATIBILITY_151_COMPARISON.md).
The native 151 log fetches **all seven project catalogs**, then selects payload
groups separately. Installed chunks exactly match Korean Minimal plus SD quality.
The legacy selected-language catalog rule must not be promoted into a 151 policy.

Follow-up implementation authorized by the operator (“해당 작업 착수”): see
[151 local provider implementation](RESOURCE_COMPATIBILITY_151_PROVIDER.md).
Selection/binding types, installed-selection preflight, sealed raw reads, verified
compressed pak ranges and an exact-path loopback HTTP handler are implemented.
No native routes, actual acquisition receipt or runtime launch are admitted yet.

Latest follow-up under the operator's tasks 1–6 goal: all **189 installed selected
raw checksums** now verify with fixed 128-KiB seeded SpookyHash blocks. The previous
83 large-file mismatches were an algorithm/chunking mismatch, not established
installation corruption. Index trailers and exact native route/version binding
are still unresolved. A staging-only clone planner passed eight synthetic checks
and produced a read-only ~19.03-GiB plan. The operator subsequently approved the
copy: 1,063 files / 20,430,771,231 bytes are now copied and fully hash-verified at
`C:\NLL\Clients\NIKKE-151.8.5-ResourceProbe`. Its receipt reports
`sealed_offline_clone`, **not native readiness**. See the provider checkpoint for
receipt identity, the 92-test result and exact scope. No runtime has been deployed
or launched.
The subsequent read-only startup inspection also followed MonoScript references
for unnamed instances (34 files, 3,058 resolved headers); the current target filter
found no configuration instances. This is not evidence of absence and does not
resolve native request paths. The separate 151 probe's bootstrap, isolation and
rollback preparation still precede actual UAC/startup.

**Later operator decision:** the approximately 19-GiB clone was explicitly approved
after clarifying that it reuses installed 151 files. The pinned clone operation is
complete, not native-ready. The operator approved D: archival of the old 150
copy only after completion of the 151 validation goal and removal of active 150
path dependencies. See the latest provider checkpoint; earlier pending-approval
statements in older checkpoints describe the pre-approval state. No D: move was
performed. The existing 150 copy currently measures 25.39 GiB; its active path
dependencies must be retired before archival.

## Separate causes and observations

- The latest failing 150 run reports SQLite malformed / catalog not initialized
  for its Korean SAUS catalog during `DownloadAssetCatalogs`. The matching legacy
  cache directory lacks that body/signature pair. Common SAUS is not corrupt.
- The previous start procedure did not pass its optional local-resource preflight
  parameters; cleanup completion was not evidence of successful resource loading.
- Current measured voice preferences are `en` / `Minimal` (UI also `en`). Why that
  failing run requested `ko` is **unresolved**; do not assert that current settings
  were necessarily the same at the failure time, or silently change them.
- Updated official-current storage is `com.shiftup.patch/<role>/catalog.ndb` plus
  `.nds`, `raw`, and `chunk/store.cdb[.idx]`. It is not the legacy `locale/revision`
  layout. Copying a new catalog into an old directory does not establish compatibility.
- The retained `.lcv.dat` predates the update. It cannot establish a 151 version map.

## Implemented source components

| Component | Implemented behavior | Remaining limit |
|---|---|---|
| `ResourceSelection` / `ResourceBinding` / `ResourceClosurePlan` | Language × download scope; build/client/server/config/static/layout fingerprints; unresolved payload refuses admission | Not native 151 authority; needs independent all-project metadata and payload/quality selection |
| `LegacyVersionHeader` | Exact required roles, duplicate/truncated/path-invalid metadata rejected | Applies only to proven legacy header format |
| `ResourceCatalogPreflight` | NKDB pair shape, bounded expansion, in-memory read-only SQLite, schema/references, sealed legacy body/signature fingerprints | Pair fingerprints are not cryptographic verification of `.nds` authenticity |
| `ChunkStoreReader` | Shared read-only CIDX/CBLB parser, physical bounds/overlap checks, compressed SpookyHash V2-128 and zstd output-length checks | Index trailing 16-byte meaning remains unresolved; no native index rewrite |
| `ChunkStoreProbe` | Sample or all-installed verification, per-group complete/absent/partial counts; no raw asset IDs emitted | Missing optional groups are not labelled installation corruption |
| `ChunkFileAssembler` | Reconstruct one catalog member into a new private artifact, validating chunk hashes and contiguous file offsets | Diagnostic, not generic production asset-provider admission |
| Phase D resource helper / execution script | Mandatory selected-catalog check before runtime/hosts mutation; loopback TLS body/signature checks before client bootstrap; receipt/tool/prefs drift checks | Catalog check only, not full payload readiness; parent binding does not subsume derived boss/static overlays |
| Separate Epinel 151 candidate | Port pinned upstream schema/config changes while retaining current local modifications; acquired 151 pack passes offline parsing | Not deployed; acquired metadata is not yet bound to installed catalogs |
| Runtime materializer | Single-element list pattern accepts old `List<int>` and new `int[]` | Successful build is not native battle validation |
| `PatchResourcePlan` / `PatchResourceBinding` | Seven metadata roles independent of voice and LOD/texture/spine; exact seven-pair identity comparison; effective overlay/header/receipt hashes included | Actual origin-to-installed version proof still absent; constructors are not provenance verification |
| `PatchVersionMetadata` | Preserves root revision, per-role revision **and publication**, and exact original SHA-256 | Does not infer native URL templates |
| 151 local source / HTTP handler | Sealed original raw/catalog bytes; verified compressed pak ranges; exact path lookup, GET/HEAD, bounded single-range response, loopback-only | Unregistered and undeployed; native route/range/TLS contract remains unresolved |

Loopback check bypasses DNS routing using a physical `127.0.0.1:443` connection,
retains the expected TLS hostname/certificate validation, rejects redirects, and
does not allow an official outbound fallback. Its separate success receipt is
`resource-loopback-preflight.receipt.json`; historical optional preflight booleans
must not be reinterpreted as performed checks. No-audio remains explicitly
`resource_no_audio_contract_unresolved`, not a fallback for missing voice files.

## New Korean installation evidence

The chunk catalog schema has seven tables: `chunks`, `chunk_file_map`,
`files_chunktype`, `files_rawtype`, `groups_chunktype`, `groups_rawtype`, `paks`.
Schema digest: `b709086885a5dcb4eec098a810c80f5f2901bd5c07997a3f8d56f21436b37f85`.
Original numeric IDs and keys remain local; they are not new domain identifiers.

| Observation | Result |
|---|---:|
| Korean catalog chunks | 53,311 |
| Installed Korean chunks | 28,416 |
| Installed chunks passing compressed hash and decompression checks | 28,416 |
| `ko_required` complete files | 1,266 / 1,266 |
| `ko_add` files | 786: 785 absent, 1 partially represented by available chunks |
| Common SAUS chunks passing all checks | 279 / 279 |
| English/Japanese payload | Catalogs present, payload absent |

The later native-log comparison establishes an exact match between the Korean
Required payload and the four-to-five-group plan delta, including both download
and insert bytes. Installed base payload also exactly matches SD quality groups.
Shared chunks can partially cover an unselected group; partial optional coverage
alone is not proof of an interrupted download. English/Japanese **catalogs** are
fetched by native startup; their **payloads** need not be installed for Korean.
The full no-audio preference/runtime contract is still unresolved.

CIDX v1 observations: 12-byte header, count × 28-byte entries, 16-byte trailer.
Entries contain hash, physical CDB offset and compressed length; catalog pak offsets
are a different coordinate space. CBLB v1 has a 256-byte header. All installed
Korean/common compressed chunk hashes match zero-seeded SpookyHash V2-128. MD5 and
xxHash128 probes did not match. The hash implementation is isolated to this tool
(`System.Data.HashFunction.SpookyHash` 2.0.0, locked dependencies), not the domain.

The one common chunked file was reconstructed from verified chunks. It is a
**UnityFS bundle**, not StaticData.pack; it must not be used as the missing static
pack. Its 19,706,135-byte private diagnostic artifact has SHA-256
`bdd83cf8be0424bd875cbdf2112eae36087fec0a0b7ee86059672939fff0bed4` and remains ignored.
No bulk asset extraction was performed.

## Epinel candidate and regression evidence

Git-external detached candidate: `.external/EpinelPS-151-candidate`. Original
`.external/EpinelPS` working changes are preserved. Candidate is based on local
`b9a0d9be2bb2d20c0103f37ef57ede4068bfff1e` plus the existing local working diff,
then the schema/version changes from pinned upstream
[`d4866f7fe37c3d1ab6a56515cb50a5cdf090d9d5`](https://github.com/EpinelPS/EpinelPS/commit/d4866f7fe37c3d1ab6a56515cb50a5cdf090d9d5).

- Candidate build: passed (22 warnings inherited from external code).
- SelectedManager tests: **118 passed**.
- HandlerIsolation: **4 passed / 2 failed**. Resource-host test hardcodes 150
  mappings; handler-discovery test expects 19 serialized handlers but observes 20.
  The local 150 baseline was subsequently rerun: **5 passed / 1 failed**, with the
  identical 19-versus-20 handler count failure. It is therefore pre-existing, not
  introduced by the 151 schema port. Do not edit expectations merely to make the
  gate green; retain explicit tests for both version profiles.
- Materializer builds against current local 150 DLL and candidate 151 DLL: passed.
  Building against the older parent-v9 DLL fails due to a pre-existing target-
  observation constructor difference, not the new ElementId list-pattern change.
- Automation tests: **28 passed**.
- Catalog/transport/bounded decoder/shared chunk-reader tests: **39 passed**.
- Synthetic PowerShell gate: passed without reading real preferences or starting
  a game/database. Tests cover receipt/tool drift, voice drift, evidence, ordering
  and script parsing. This does not replace real loopback TLS/native tests.
- Full post-change `verify-phase3b2.ps1` chain: blocked at pre-existing whitespace
  errors in `Admin.Api/AccountImportExecution.cs` and `Automation.Cli/Program.cs`;
  downstream live PostgreSQL gates were not reached. The attempted pre-change
  chain also hit sandbox NuGet connectivity; retrying post-change with dependency
  access reached the formatting failure. No unrelated formatting was changed.
- Post-change Phase 0, Phase 3A and Phase 3B0/1/2 contract-only checks and Actions
  contract check: passed. The checked-in historical blocked/not-executed receipts
  retain their original meaning; these checks do not certify native play.

## Remaining gates / next safe work

1. Bind acquired 151 version metadata to the installed catalog identities before
   promoting it into effective runtime configuration. Acquisition and pack parsing
   are now complete (see below); native resource transport remains separate.
   Do not reuse the 150 static pack/version header. Candidate `ResourceCoreVersion`
   deliberately remains `unresolved` until the observed header and installation
   are bound; the CDN `latest` response is mutable and is not evidence that all
   resources installed earlier have the same revision.
2. Turn the observed all-project metadata plus language × Minimal/Full × quality
   payload model into a version-specific contract. Raw filename mapping and the
   installed Korean Minimal/SD chunk set are now verified. No-audio preferences,
   raw content digest semantics, index trailer and native transport still need
   resolution. Seal each verified source set; no unqualified ready verdict.
3. Bind the **effective** server/static/boss overlay, not only the parent runtime,
   into the launch contract; implement the 151 local resource transport strategy.
4. Re-run both old/new version-profile and handler tests. Full repository baseline
   is a separate gate from focused tests; record any existing failure rather than
   changing unrelated source.
5. Prepare a distinct 151 client under `C:\NLL\Clients`, compatibility binary
   verification, source/copy hashes and rollback manifest. Never target `C:\NIKKE`.
6. Apply the operator-selected Korean setting with explicit backup/isolation,
   then request UAC for the prepared local deployment when needed. Observe startup,
   lobby, S26 battle, result, restart persistence and cleanup in order. Until then
   native play and 4/7 resolution remain **not verified**.

Do not reset accounts/raid records, migrate production DB speculatively, stop
unrelated processes, download all languages, or promote this candidate to Golden.

## Approved cold acquisition and offline pack inspection (2026-09-05)

Operator reply “당연하지!” explicitly approved the separate Micron-cold collection
of the candidate-config static pack and version metadata. The bounded collector
is `scripts/invoke-nll-version-input-acquisition.ps1`; it checks the config digest
and target build, writes an exact two-member private request manifest before GET,
uses certificate/hostname validation with no proxy/redirect/cookies/credentials,
and checks client/launcher/Epinel processes and runtime listeners before and after.
Only new files under Git-external `C:\NLL\Staging\ResourceVersionInputs` were made.
No official installation, frozen client, existing cache, preferences, hosts, CA,
runtime executable, or DB was changed. No server/client was started.

| Input | Bytes | SHA-256 |
|---|---:|---|
| Candidate config used for acquisition | — | `4e588fd4c51953d5eb99e6ec2def8bada6130458b8cdef35538ca58321f07d2e` |
| Private request manifest | — | `24d9779df0f5a52a1f725306563b68d50ce202550a91a4686574c48f9700ab88` |
| Static pack | 17,265,408 | `6ba9b5302ff355d88a998eaec568fbe7a28ea483fe30ef84c05a68f1d3deb6bc` |
| Version metadata | 139 | `df1d7403a5a24f16fb5eb59ba436c1f04236b691f95ef30634f22b92ed306856` |

Both exact requests returned HTTP 200. Raw paths and response bytes remain private.
The version metadata retains the eight-line legacy envelope and reports core
`151.8.b16`; this is an acquired observation, **not yet an installation binding**.

`RuntimeMaterializer --inspect-static-pack` uses only an explicit local pack path
and pinned config/pack digests, not the Epinel download entry point. The external
parser verified the embedded RSA signature. Offline inspection: **0 parse errors,
0 missing tables, 241 populated tables**. Character/equipment/cube/monster table
counts were 1,963 / 124 / 17 / 2,187; Solo Raid manager/preset counts were 41 / 320.
Decoded archive SHA-256 is
`d14690756e7e8d24cf13df50a7db62a6c932c28e7a759ba6e731fdfcf1e15a5b`.
Decoded contents were not written to disk or emitted in the inspection receipt.

The same candidate materializer resolved both S26 and S29 static boss graphs with
zero unresolved reason codes. Asset/behavior/FX catalog closure is still pending;
this does not certify native boss behavior or shield appearance.

Collector plan validation: **13 synthetic checks passed**, including changed
config/build, alternative host, HTTP, credentials, port, query, fragment, traversal
and malformed version selectors. These tests perform no network or install writes.

Post-acquisition checks reran successfully: Automation 28 tests, catalog tool 39
tests, synthetic resource preflight, strict header inspection, and rejection of
an incorrect static-pack SHA-256. The inspection materializer builds against
both the existing 150 and separate 151 reference DLLs.

The new source-free catalog profile is now admitted by repository policy only
under a closed JSON schema (hashes and controlled fields, no raw paths/URLs/IDs).
The existing profile and four forbidden-field negative cases were checked.
Canonical-path repository policy with the already-authorized private remote
passed, as did Phase 0, Phase 3B0/1/2 contract-only checks and Actions checks.
The full Phase verification chain was attempted again and stopped at the same
pre-existing whitespace failures; live PostgreSQL integration was not reached.

## Reproducible focused checks

- `dotnet test tests/NikkeLocalLab.Automation.UnitTests -c Release`
- In `tools/Phase3B2/ResourceCatalogPreflight.Tests`: `dotnet test -c Release`
- `pwsh -NoProfile -File scripts/test-nll-resource-preflight.ps1`
- `pwsh -NoProfile -File scripts/test-nll-version-input-acquisition.ps1`
- `inspect-version-header <local-metadata-file>` validates the bounded eight-line
  envelope without claiming it matches installed catalogs.
- `RuntimeMaterializer --inspect-static-pack true --static-pack <local-pack>
  --game-config <local-config> --expected-pack-sha256 <digest>
  --expected-config-sha256 <digest>` performs the offline pack inspection.
- The preflight tool was published to ignored `artifacts/phase-d/resource-preflight`.
  It requires the pinned .NET 10 SDK and local external parser/SQLite/zstd build
  dependencies. Runtime game files and databases are not created by these tests.
- `inspect-install <role> <directory>` samples three installed chunks;
  `verify-installed <role> <directory>` checks every installed catalog-referenced
  chunk. Neither command declares native readiness or fills missing resources.
- `inspect-patch-groups <role> <directory>` compares distinct group-selected chunks
  and raw byte counts, eight base-quality combinations, and the observed SD/Required
  selection against the exact installed hash set. It is diagnostic, not a default
  that changes user quality settings.
- `inspect-linked-role <role> <directory>` resolves inner catalogs from outer raw
  references and compares remote member names/lengths/installed coverage privately.
- `inspect-installed-raw <role> <directory> <header>` tests filename/content-digest
  hypotheses read-only. Unknown digests remain unresolved; raw keys are not emitted.
- The new diagnostic commands are built locally, not deployed into the existing
  Phase D published tool. Focused tool tests now pass **52/52**, including 13 new
  group-deduplication, exact-set, missing/truncated/ambiguous/path-invalid tests.
- Legacy `en/minimal` catalog preflight passed; legacy `ko/minimal` failed with
  `resource_catalog_body_missing` for `ko`. This is deliberately distinct from
  the installed **151** Korean payload verification; builds must not be mixed.
