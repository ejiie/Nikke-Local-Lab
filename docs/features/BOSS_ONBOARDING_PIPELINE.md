# Solo Raid boss onboarding pipeline

> 상태 참고 (2026-09-06): 아래 S29 결과는 당시 admission 기록입니다. 현재 S29의 profile v3/등록 v2 불일치는 별도 보류이며, 151 실게임 완료는 S26 기준입니다. [안정화 계획](../STABILIZATION_PLAN.md)을 함께 확인합니다.

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

The common Python assembler still produces v2. It now requires an explicit closed
no-QTE discovery. Missing discovery fails with `boss_profile_qte_discovery_missing`;
nonempty or inconsistent discovery fails with `boss_profile_qte_v3_pipeline_required`
**before writing a candidate**, instead of discarding QTE and publishing incomplete
five-affinity support. Automatic v3 assembly is the next pipeline stage.

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

Still pending: automatic v3 candidate assembly; isolated shield-FX transform overlay
and original-client delivery/rollback; preparation/coordinator v3 admission; atomic
publication and job API; the season-selection UI. Never copy derived FX through the
current runtime cache junction because it shares the parent cache. S29's draft/pin
mismatch stays blocked until the complete replacement path is verified.

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

## Admission flow

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
