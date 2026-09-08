# 151 resource comparison and verification — 2026-09-05

> 보관 기록: 2026-09-06 문서 정리 때 이동했습니다. 본문의 ‘현재·다음·미완료’는 작성 당시 기준입니다. 현행 안내는 [문서 색인](../README.md)과 [현재 경로](../MICRON_CURRENT_PATHS.md)를 따릅니다.

Historical comparison checkpoint. The raw checksum gap recorded below was
subsequently resolved for all 189 installed selected files with fixed 128-KiB
seeded SpookyHash blocks. See [provider follow-up](RESOURCE_COMPATIBILITY_151_PROVIDER.md).
The original observations below are retained as provenance, not current blockers.
Native route/version binding and index-trailer semantics remain unresolved.

## Scope and verdict

Operator requested comparison and validation after the approved two-file cold
acquisition. This pass reads the official-current installation, the previously
captured native log, and those acquired files. It adds offline diagnostic/test
code only. No additional CDN request, official install mutation, preferences edit,
runtime deployment, process launch, hosts/CA change or production DB write was performed.

**Installed Korean Minimal / SD chunk payload is internally consistent. Native
151 compatibility and resolution of 4/7 are not yet verified.** The acquired mutable
version header is not yet bound to the installed catalog identities.

See [implementation progress](RESOURCE_COMPATIBILITY_151_PROGRESS.md) for acquisition
digests, static-pack signature/parser validation and the earlier regression gates.

## Evidence provenance

- Read-only source: official-current patch storage under the current Micron paths.
  Frozen 150 remains a separate control, never mixed into this result.
- Historical native log: `Player-prev.log`, events on 2026-09-03; SHA-256
  `5f2cff1dc82419d43666a6b5471d1e34a82dc261e9067c93a84eba1145a1c931`.
  This is not the later failing 150 `Player.log` and not a new local runtime test.
- Seven installed outer catalog pairs pass bounded NKDB parsing and SQLite
  integrity/schema checks. Schema SHA-256:
  `b709086885a5dcb4eec098a810c80f5f2901bd5c07997a3f8d56f21436b37f85`.
- Group counts and body/signature fingerprints are reproducible with
  `ResourceCatalogPreflight inspect-patch-groups <role> <directory>`.
  Source-free local observation: ignored
  `artifacts/resource-migration/installed-patch-groups-observation.json`.
  It contains the initial group/quality measurements, not a native admission receipt.
- Original asset keys, original numeric IDs, raw/decrypted bytes and private
  acquisition URLs are not included in this document or checked-in fixtures.

## Metadata and payload are separate

The native log records `Fetching catalogs: projects=7` at line 185 and completion
for seven projects at line 193, before voice selection completes. Subsequent plans
continue to use seven projects while changing the selected group count.

Therefore the observed 151 model is:

1. Metadata closure: `core`, `dp`, `fd`, `saus`, `ko`, `en`, `ja` outer catalogs.
2. Base payload closure: Required plus independent LOD/texture/spine quality groups.
3. Voice payload closure: selected language Required, with Add for the larger scope.

Seven projects do **not** mean seven voice downloads. An English/Japanese catalog
without its payload is normal for the observed Korean selection. The four/five/six
group counts are global labels, not numbers of selected projects.

| Role | Observed group labels (normalized case) |
|---|---|
| core | `required`, `requiredquality_lod_hd/sd`, `requiredquality_texture_hd/sd` |
| dp | `required`, `requiredquality_spine_hd/sd`, `requiredquality_texture_hd/sd` |
| fd | `required`, `requiredquality_lod_hd` |
| saus | `required` |
| ko / en / ja | `<language>_required`, `<language>_add` |

`Minimal` describes voice download scope, not playback volume. LOD, texture and
spine quality are additional axes. Do not assume that changing voice scope should
change graphics quality, or that all HD and SD payloads must exist simultaneously.

## Exact comparisons with historical native plans

| Plan / inferred selection | Native download bytes | Native insert bytes |
|---|---:|---:|
| Four groups: SD base, no voice payload selected | 17,237,428,884 | 16,508,003,399 |
| Five groups: SD base + Korean Required | 19,259,017,741 | 18,528,584,172 |
| Six groups: SD base + English Required/Add | 21,133,209,449 | 20,402,776,157 |

Selection names are inferred from catalog arithmetic, not printed as names in the
log. Evidence supporting the inference:

- Five minus four groups: **2,021,588,857 download / 2,020,580,773 insert bytes**,
  exactly the Korean Required catalog values. The 1,008,084-byte difference is
  the Korean raw catalog/signature pair.
- Six minus four groups: **3,895,780,565 download / 3,894,772,758 insert bytes**,
  exactly English Required plus Add. It is not Korean Full, whose catalog-derived
  download/insert values are 3,807,346,503 / 3,806,338,419.
- Among eight HD/SD base combinations, all-SD compressed bytes equal the native
  base insert bytes: **16,508,003,399**.
- The subsequently completed native insert total equals the current physical
  chunk stores, excluding each 256-byte store header: **18,528,584,172 bytes**.
- Exact hash-set comparison, not just aggregate length, matches that SD base plus
  Korean Required selection: missing, extra and wrong-length selected chunks are
  all zero for the five installed roles.

Limit: summing selected base compressed chunks and raw sizes gives
17,198,478,989 bytes, **38,949,895 below** the logged base download plan. The same
residual remains in both voice comparisons. The seven outer catalog pairs total
66,270,988 bytes and do not explain it by simple addition. Transport planning
overhead/range behavior is **unresolved**, not assumed. The tool's
`coldDownloadBytes` means a catalog-derived logical byte sum, not a verified native
network transfer estimate. Voice deltas and all insert totals match exactly.

The base-only plan demonstrates a planner state without voice payload. It does
not prove the persistent no-audio preference encoding, successful gameplay in
that state, or permission to silently use it when the selected audio is missing.

## Full installed chunk verification

Each installed catalog-referenced chunk was checked for index bounds and length,
compressed SpookyHash V2-128, zstd decoding and decoded length. No decoded chunk
corpus was persisted. Verification reads one bounded chunk at a time.

| Role | Installed and verified chunks | Compressed payload bytes |
|---|---:|---:|
| core | 245,093 | 6,574,364,065 |
| dp | 135,746 | 7,865,280,800 |
| fd | 44,960 | 2,048,652,400 |
| saus | 279 | 19,706,134 |
| ko | 28,416 | 2,020,580,773 |
| Total | **454,494** | **18,528,584,172** |

All five roles have zero index entries unreferenced by their outer catalog.
Unselected HD or Add files can share some chunks with the selected groups. Their
partial availability is not evidence of corruption. English and Japanese payloads
are absent; this is not a Korean selection failure.

Limits: the index trailer algorithm remains unresolved, and these checks do not
verify detached catalog-signature authenticity or certify an executable/runtime.

## Raw references and Korean inner catalog

All **189** raw files of the five installed roles exist at the catalog-declared
hash filename plus extension, with matching lengths: core 2, dp 2, fd 2, saus 181,
ko 2. Filename generation from MD5/SpookyHash of the logical key did not explain
the observed names; the catalog hash does. Raw resolution must require a unique,
well-shaped reference and exact file length, never guess among loose files.

For the raw content itself, whole-file SpookyHash matches 106 entries. The other
83 remain **unresolved**; neither MD5 nor the tested decoded-NKDB SpookyHash rule
established their digest semantics. A matching filename/length is not proof of
cryptographic content integrity. SHA-256 observations are available for sealing
a local copy but do not substitute for understanding a native content hash.

Korean inner catalog linkage:

- Outer body SHA-256:
  `e2f96da2d1393d67ae7a374887a3291e4027f327647b81125b89c04b8828525c`.
- Inner body SHA-256:
  `7f9b128fe73e3309ffa81466da1beb0d471bb6656eb3314873df3907af70f1a2`.
- Inner schema SHA-256:
  `a03049b57e60d833ad12b5ec8aeee589ce74ce9523eeab77c9f697139813d447`.
- All **2,052** inner `FileInfoEntity.RelativePath` values resolve to outer
  `files_chunktype.key` values; all expected sizes match original chunk-size sums.
- Required: **1,266 / 1,266** files have all chunks installed.
- Add: **786** files, none complete; one has shared installed chunks.
- `ko_required` / `ko_add` belong to the outer patch grouping. They are not the
  inner catalog's 1,856 asset labels and must not be joined by that assumption.

This verifies names, aggregate sizes and chunk coverage; contiguous file-offset
validation and complete-file digest/provider semantics are separate gates.

## Unresolved version and transport binding

The acquired version header reports `151.8.b16` in the existing eight-line envelope.
Installed catalogs were captured on September 3, while the mutable header was
fetched on September 5. No verified hash-to-revision binding was found in the
catalog metadata, retained pre-update `.lcv.dat`, or inspected startup assets.
`TableVersion` is not established as a server resource-version identifier.

Relevant startup script types include the new PatchSession/RawPatcher machinery;
script type presence is not a concrete runtime configuration value. Some startup
objects lack readable type trees. No process memory extraction was attempted.

The Epinel candidate still exposes the four resource-host response fields. Its
successful build and static-pack parsing do not establish the exact new catalog,
raw and pak/chunk request routes or response semantics. `ResourceCoreVersion`
therefore remains `unresolved`; do not insert a guessed header or reuse 150 data.

## Consequences for the reusable implementation

1. Use a versioned transport/layout profile. Keep legacy selected-catalog logic
   separate from 151's all-project outer metadata closure.
2. Represent metadata projects, voice language, voice scope and graphics-quality
   groups independently. Resolve the native plan's group union with deduplication.
3. Bind the exact build/header/catalog body+signature identities and the effective
   static/boss overlay. A date, directory name, role name or matching schema alone
   does not establish this binding.
4. Build a local-only provider from verified raw references and selected chunk
   coverage. Preserve the observed raw/inner/outer layering and fail closed on
   absent references, unknown format, changed digests or unresolved selection.
5. Test Korean/English/Japanese Minimal/Full, base-only/no-audio contract, independent
   quality selections, shared chunks, catalog-only languages, upgrades and drift.
   Do not globally demand all voice or all quality payloads.
6. After version/transport contracts are resolved, seal a separate 151 client lane,
   then perform the operator-selected Korean native startup/lobby/battle/result/
   restart checks. Until that point this is offline evidence only.

## Regression checks for this pass

- Offline diagnostic tests: **52 passed**, including 13 new synthetic tests for
  group union/deduplication, empty/unknown/SQL-looking selections, exact coverage,
  raw mapping and missing/truncated/ambiguous/path-invalid catalog references.
- Existing Automation tests: **28 passed**.
- Synthetic resource preflight and the 13 bounded-acquisition plan checks passed
  without game/network activity from those synthetic tests.
- Repository policy: **7,153 files passed** from the canonical checkout path.
  Phase 0, Phase 3A and Phase 3B0/1/2 contract-only gates and Actions contract passed.
- Full Phase chain was attempted: sandbox NuGet metadata access failed first;
  the normal-permission retry passed restore/build, then reached the same existing
  whitespace gate failures in `AccountImportExecution.cs` and Automation CLI
  `Program.cs`. Live PostgreSQL integration was not reached. No unrelated formatting
  was changed to conceal that baseline failure.
- Read-only startup-asset inspection reran successfully with bounded output; it
  identified script types but did not resolve a concrete version binding.
- At the end, all seven outer catalog body/signature pairs were rehashed against
  the initial observations: **zero changed pairs**. The scoped process check
  found no NIKKE, NIKKE launcher or Epinel process running.
- No production code, deployment or account changes are implied by diagnostic
  helper additions. Existing Phase D published binaries have not been replaced.
