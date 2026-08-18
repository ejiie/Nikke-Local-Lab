# Phase 1C — Solo Raid Challenge snapshot importer

Phase 1C는 최신 StaticData에서 지원 정책을 만족하는 Solo Raid Challenge를 찾고, 확보한 증거 범위에 맞는 `RaidSnapshot v2`를 자체 ID로 게시하는 오프라인 경로입니다. 공식 인증·네트워크, 게임 프로세스, 런처, endpoint 변경 또는 보호 기능에는 접근하지 않습니다.

## 완료 상태

Phase 1C의 구현·검증 범위는 완료됐습니다.

- Challenge authoritative chain과 정적 관계를 읽는 importer
- 증거 완결성에 따른 `static_exact`/`behavior_exact`/runtime-exact invariant
- source-ID-free `RaidSnapshot v2` canonical JSON과 hash
- V0003 immutable PostgreSQL schema와 import ledger를 포함한 원자적 publish
- 합성 source, schema, domain, importer, canonicalization, persistence를 검사하는 CI
- 최신 실제 StaticData를 변경하지 않고 읽은 local smoke

이 완료 선언은 원본 client 실행, local session backend, 완전한 battle-frame timeline 또는 현재·역사 runtime exact를 포함하지 않습니다.

## 입력과 authoritative chain

StaticData importer는 다음 관계를 순서대로 해소합니다.

    SoloRaidManager
      → Challenge preset (difficultyType=2, waveOrder=8)
      → wave group
      → wave
      → target이면서 실제 spawn되는 단일 monster
      → element/weakness, parts, skills, spot behavior

시즌 14·39는 명시적으로 제외합니다. 나머지는 `electric` 보스이면서 `iron` 약점일 때 포함하고, 시즌 40은 별도 명시 규칙으로 포함합니다. chain이나 정적 필수값이 모호하면 추측하지 않고 diagnostic으로 남깁니다.

Behavior evidence는 시즌별로 독립 평가합니다. behavior와 선택 bundle byte가 없는 시즌도 정적 근거가 완결됐다면 warning을 포함한 `static_exact`로 게시할 수 있습니다. evidence archive에 원본 경로·파일명·content ID를 공개 계약으로 넘기지 않으며, 실제 byte와 digest는 Git 밖의 로컬 증거 경계에 둡니다.

Importer는 읽기 전후 source 길이와 SHA-256을 관찰합니다. 관찰 중 입력이 바뀌거나 StaticData 자체의 구조·필수 참조가 일치하지 않으면 게시하지 않습니다. 선택 evidence가 다른 StaticData에 결박된 경우 그 evidence로 상위 tier를 게시하지 않으며, 정적 근거가 독립적으로 완결된 시즌만 controlled warning과 함께 `static_exact`로 후퇴할 수 있습니다.

## 자체 ID와 정규화

공개 snapshot에는 다음만 남습니다.

- snapshot, dataset, encounter, boss variant, dataset-scoped compatibility binding marker의 lab-owned UUID
- user-facing season number와 정규화 element/weakness
- static artifact의 lab-owned UID와 SHA-256
- part별 lab-owned UID, ordinal, semantic type code, exact integer ratio, flag, 자체 UID link
- skill slot별 lab-owned UID와 ordinal. 현재 importer는 슬롯 개수·순서만 보존하며 skill definition identity와 효과 semantics는 후속 정규화 대상입니다.
- 선언한 tier에 필요한 behavior, bundle, timeline, runtime/timing provenance
- compatibility/readiness warning code

manager, preset, wave, monster, spot behavior, part, skill의 원본 key는 import staging에서만 사용합니다. JSON, domain, DB receipt 또는 CLI 요약에는 원본 ID, 파일명, 설치 경로를 넣지 않습니다.

## Tier별 게시 규칙

| tier | publish에 필요한 근거 | 허용되는 미해소 항목 |
|---|---|---|
| `static_exact` | static artifact, 정규화 파츠, 스킬 슬롯 개수·순서, 한 개 이상의 evidence warning | skill definition/effect semantics, behavior, bundle, timeline, runtime, clock/scheduler |
| `behavior_exact` | static 근거, behavior artifact, 하나 이상의 선택 bundle과 set hash | partial/empty timeline, runtime과 clock/scheduler |
| `asset_exact_runtime_current` | behavior 근거, current runtime match, runtime reference, resolved scheduler와 관련 clock 근거 | 역사 runtime 동일성 |
| `historical_runtime_exact` | behavior·asset·timing과 해당 시즌 역사 runtime match | 입증 범위 밖 플랫폼/build |

`readiness.status=ready`는 선언한 tier의 snapshot이 publish 가능하다는 뜻입니다. 상위 tier가 준비됐거나 원본 client 전투가 가능하다는 뜻이 아닙니다.

## 최신 실제 데이터 결과

최신 StaticData read-only smoke에서 정책을 통과한 publish 대상은 정확히 여섯 시즌입니다.

| 시즌 | 보스 | 현재 최대 tier | 근거 상태 |
|---:|---|---|---|
| 7 | 울트라 | `static_exact` | behavior bundle byte 미확보, `behavior_unresolved` |
| 13 | 인디빌리아 | `static_exact` | behavior bundle byte 미확보, `behavior_unresolved` |
| 26 | 프로비던스 | `static_exact` | behavior bundle byte 미확보, `behavior_unresolved` |
| 29 | 마더웨일 전격 변종 | `static_exact` | behavior bundle byte 미확보, `behavior_unresolved` |
| 34 | 앨트루이아 | `static_exact` | behavior bundle byte 미확보, `behavior_unresolved` |
| 40 | 사치스러운 거미 | `behavior_exact` | behavior와 선택 NAPS bundle 확보; partial timeline `timeline_unresolved`; runtime 미평가 `runtime_not_evaluated` |

시즌 40의 partial timeline은 증거로 보존할 수 있지만 runtime scheduler와 모든 clock basis를 완결하지 않습니다. 따라서 `asset_exact_runtime_current`나 `historical_runtime_exact`로 승격하지 않습니다.

## PostgreSQL 게시

V0003은 immutable RaidSnapshot과 다음 provenance를 저장합니다.

- snapshot identity, admission, compatibility tier와 runtime relation
- static artifact, source-ID-free part 관계와 ordered monster-skill slot 점유
- 선택 bundle set, behavior, timeline, runtime 및 timing evidence
- compatibility/readiness warning
- dataset membership과 canonical content hash

Import ledger 완료와 여섯 snapshot 게시를 한 transaction으로 처리합니다. 동일 request는 기존 publish 결과를 재사용하고, 중간 실패·hash 불일치·tier invariant 위반은 전체 transaction을 rollback합니다. 활성 시즌 포인터와 실제 session 실행은 이 단계의 범위가 아닙니다.

## 검증

    pwsh -NoProfile -File scripts/verify-phase0-contract.ps1
    pwsh -NoProfile -File scripts/verify-phase1c.ps1
    pwsh -NoProfile -File scripts/verify-phase1c.ps1 -Integration
    pwsh -NoProfile -File scripts/verify-repository.ps1 -Mode working -AllowRemote

합성 검사는 실제 게임 content나 계정 데이터를 사용하지 않습니다. `raid-snapshot.static-exact.json`은 behavior/runtime가 비어 있어도 warning이 있는 정적 snapshot을 허용하고, 근거 없이 상위 tier로 바꾸면 거부되는 계약을 고정합니다. 상위 runtime tier 합성 fixture는 schema와 persistence invariant 검사용일 뿐 실제 시즌의 증거 등급을 주장하지 않습니다.

실제 smoke는 로컬 최신 StaticData와 Git 비추적 evidence만 read-only로 사용합니다. 그 결과·원본 경로·source key·복호물은 CI나 저장소에 넣지 않습니다.

## 남은 경계

- Phase 1D에서 equipment, cube, collection/favorite, console, OL option catalog를 게시합니다.
- Phase 2에서 account/profile/build write와 Challenge session backend를 구현합니다.
- 원본 client gate는 계속 blocked입니다. 지원·승인된 local/test route 없이 원본 실행 파일, 인증, endpoint 또는 보호 기능을 변경하지 않습니다.
- `compatibility_map_uid`는 이 단계에서 raw ID map 파일을 뜻하지 않습니다. 원본 client adapter용 매핑은 gate 해제 후 정확한 dataset으로 Git 밖에서 재생성·검증합니다.
- 역사 시즌의 완전한 behavior/timeline/runtime 근거를 추가로 확보하면 새 evidence로 tier를 재평가하되, 현재 snapshot을 근거 없이 승격하지 않습니다.
