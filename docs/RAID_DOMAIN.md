# Solo Raid Challenge domain contract

## 지원 범위

`SoloRaidChallenge`만 지원합니다. 일반 솔로 레이드 1~7단계는 전투 콘텐츠로 구현하지 않으며 Union Raid는 비활성 확장 지점입니다. published 지원 시즌은 만료되지 않는 local content이며 사용자는 lobby season directory에서 언제든 선택할 수 있습니다.

## Boss admission policy

정책 ID는 `challenge-boss-support/v1`입니다.

판정 순서는 다음과 같습니다.

1. 시즌 14와 시즌 39는 명시적으로 제외한다.
2. 시즌 40은 속성·약점과 무관한 별도 규칙으로 포함한다.
3. 나머지는 보스 속성이 `electric`이고 약점 코드가 `iron`인 경우만 포함한다.
4. authoritative Challenge chain을 완전히 해소하지 못한 후보는 publish하지 않고 import 진단으로 남긴다.

현재 snapshot에서 전격·철갑 조건을 만족하는 시즌은 `7, 13, 14, 26, 29, 34, 39`입니다. 제외 정책과 시즌 40 별도 포함을 적용한 현재 파생 allowlist는 다음과 같습니다. 이 목록은 특정 dataset의 결과이며 config의 별도 실행 제한 목록이 아닙니다. 다음 dataset에서는 같은 정책으로 다시 계산합니다.

| 시즌 | 보스 | admission |
|---:|---|---|
| 7 | 울트라 | `electric_weak_to_iron` |
| 13 | 인디빌리아 | `electric_weak_to_iron` |
| 26 | 프로비던스 | `electric_weak_to_iron` |
| 29 | 마더웨일 전격 변종 | `electric_weak_to_iron` |
| 34 | 앨트루이아 | `electric_weak_to_iron` |
| 40 | 사치스러운 거미 | `season_40_explicit` |

시즌 14와 시즌 39는 데이터가 존재하거나 분석돼 있어도 `excluded_by_policy`이며 `RaidSnapshot`을 publish하거나 활성화하지 않습니다.

원본 element ID, weak-element ID, preset, wave, monster, spot, asset ID는 ephemeral staging 또는 Git 비추적 compatibility map에만 존재합니다. 도메인에는 `electric`, `iron`, `wind`, `fire` 같은 정규화 enum과 자체 UUID만 저장합니다.

## Normal-stage unlock state

Challenge 해금 선행조건 호환이 필요할 때 local session state에서 다음 합성 상태를 제공합니다.

    implemented = false
    lastClearLevel = 7
    challengeUnlocked = true

이 상태는 `RaidSnapshot`의 불변 provenance가 아니므로 snapshot에 저장하지 않습니다. 일반 단계의 raid session, battle entry, result, reward를 만들 권한도 없습니다. 원본 client gate가 해제되기 전에는 이 값을 원본 client에 전달하지 않으며 공식 계정·서비스 진행도 우회에 사용하지 않습니다.

Normal I~VII가 이미 clear된 compatibility state이므로 Quick Battle은 지원하지 않습니다. quick-battle availability, request, reward와 persistence를 만들지 않으며 client projection은 관련 button을 숨기거나 controlled unavailable로 처리합니다.

`difficultyType=2`와 `waveOrder=8`은 Challenge adapter의 고정 compatibility selector이며 도메인 entity ID가 아닙니다.

## RaidSnapshot

`RaidSnapshot` v2는 지원 정책을 통과하고 선언한 호환성 tier의 publish 준비가 끝난 특정 시즌 Challenge를 위한 불변 증거 묶음입니다. 어떤 근거가 필수인지는 tier에 따라 다릅니다. 정적 근거만 완결된 후보도 결손을 warning으로 공개하면 `static_exact` snapshot으로 게시할 수 있습니다. 지원 정책이나 선언한 tier의 필수 근거를 충족하지 못한 후보는 별도 import diagnostic으로 남기며 이 schema로 직렬화하지 않습니다.

- 자체 `raid_snapshot_uid`
- 자체 `challenge_encounter_uid`, `boss_variant_uid`, `dataset_snapshot_uid`
- dataset snapshot에 결박된 source-free compatibility binding marker의 자체 `compatibility_map_uid`
- 사용자-facing `season_number`
- `challenge-boss-support/v1` admission rule과 정규화 속성/약점
- 정적 데이터 artifact UID와 SHA-256
- 자체 part UID, 정규화 part type/비율/flag/link로 표현한 파츠 관계
- 자체 skill-slot UID와 ordinal로 표현한 스킬 슬롯 점유·순서. Phase 1C는 스킬 정의 identity나 runtime semantics까지 정규화했다고 주장하지 않습니다.
- tier에 따라 선택 asset bundle artifact UID, 역할, SHA-256과 set hash
- tier에 따라 behavior와 timeline artifact UID 및 SHA-256
- tier에 따라 client runtime build UID, local label, SHA-256
- behavior tick, render frame, fixed update, wall clock 및 scheduler의 resolved/unresolved 근거
- compatibility tier와 runtime relation
- provenance readiness와 warning

원본 content ID, 파일명, 설치 경로는 snapshot JSON과 API에 포함하지 않습니다.

published snapshot은 `readiness.status=ready`이고 non-null `compatibility_map_uid`를 가져야 합니다. 이 UID는 현재 원본 ID가 들어 있는 map 파일을 가리키지 않고, 정확한 dataset snapshot과 compatibility contract를 결박하는 source-free marker입니다. 여기서 ready는 **선언한 tier의 데이터·provenance를 게시할 준비가 됐다**는 뜻이지, 원본 client에서 전투를 실행할 수 있거나 더 높은 tier가 해소됐다는 뜻이 아닙니다. admission의 정규화 속성·약점은 authoritative import 결과이며, JSON이 자기 주장만으로 원천 관계를 증명한다고 보지 않습니다. 원본 client adapter에 필요한 raw mapping은 gate 해제 뒤 정확한 dataset에서 Git 밖으로 재생성하고 별도 검증해야 합니다.

`localBuildLabel`은 lab DB 안에서만 쓰는 별칭이며 원본 build 식별자나 파일명을 복사하는 필드가 아닙니다.

선택 bundle이 없으면 `selected_asset_bundles`는 비어 있고 `asset_bundle_set_sha256`은 null입니다. bundle이 하나 이상이면 set hash도 반드시 존재합니다. `asset_bundle_set_sha256`은 선택 bundle SHA-256을 소문자로 정규화하고 중복 제거·사전식 정렬한 뒤, LF(`\n`) 하나로 연결한 UTF-8 byte열의 SHA-256입니다. 마지막 LF는 붙이지 않습니다. importer와 validator는 저장값을 재계산합니다.

## 시즌 directory와 선택된 실행 시즌

`AvailableRaidSeasonDirectory`는 모든 published 지원 `RaidSnapshot`의 source-free user-facing season number, boss display metadata와 readiness를 나열합니다. 이 목록은 lobby의 Solo Raid folder가 소비하며 여러 시즌을 동시에 포함합니다.

`SelectedRaidSeason`은 account/session별로 사용자가 directory에서 선택해 현재 클래식 Solo Raid 화면과 다음 session에 투영할 단 하나의 published `RaidSnapshot`을 가리키는 가변 포인터입니다. snapshot과 directory member는 불변이며 선택 변경만 새 실행 context를 나타냅니다. Phase 2A2 config 계약의 canonical invariant는 `oneSelectedSeasonPerClientContext=true`이고, Phase 2B가 이 포인터와 선택 상태를 실제 service에 구현했습니다.

지원 정책을 통과하지 못한 snapshot은 directory나 선택 포인터의 대상이 될 수 없습니다. v1 directory는 review된 시즌 7·13·26·29·34·40으로 고정하며 새 admission candidate를 자동 노출하지 않습니다. 새 시즌은 evidence review와 directory contract version 변경 뒤에만 추가합니다. 모든 member는 `SeasonAvailability=permanent`, `seasonEndsAt=null`인 영구 local content이며 종료·만료 job이 없습니다. 원본 UI가 역사 시즌 browser를 제공한다고 가정하지 않고, lobby season folder는 승인된 client UI variant가 소유합니다.

## 일일 Challenge 상태

Challenge attempt state는 시즌 수명과 분리합니다.

- 권위 timezone: `Asia/Seoul`
- reset local time: 매일 `05:00:00`
- reset 대상: daily entry counter와 명시적으로 daily인 Challenge state
- 유지 대상: published snapshot, active-season 선택, profile/build, 최고 local record와 과거 result

process timezone, UTC calendar date 또는 서버 시작 시각으로 daily boundary를 대신하지 않습니다. 해당 instant가 속한 KST reset window를 계산해 idempotent하게 새 daily state를 엽니다.

daily entry limit, entry 소비 시점, active run이 05:00을 가로지를 때의 처리, 여섯 시즌 counter의 `per_season`/`shared_directory` 범위, Mock Battle과 local ranking은 하나의 immutable versioned `ChallengeOperationalPolicy`로 결박합니다. 어느 한 축이라도 `unresolved`이면 directory와 season 선택은 유지하되 새 Challenge run admission은 fail closed합니다. checked-in 기본 정책은 `challenge-operational-policy/unresolved/v1`이며 제품 동작값을 추측하지 않습니다.

공식 global ranking, 공식 reward mail과 시즌 종료 정산은 범위 밖입니다. 결과 화면에 ranking을 투영할 경우 자체 local record contract만 사용합니다.

## 호환성 등급

| tier | 보장하는 범위 | 보장하지 않는 것 |
|---|---|---|
| `static_exact` | 보스, 속성, 파츠와 스킬 슬롯 개수·순서가 snapshot과 일치 | 스킬 정의/효과 semantics, behavior와 timing |
| `behavior_exact` | 정적 관계와 behavior graph/task 연결이 일치 | runtime scheduler와 animation callback의 완전 일치 |
| `asset_exact_runtime_current` | 선택 asset과 현재 runtime build/hash 및 검증된 scheduler 의미가 일치 | 해당 시즌 당시 역사 runtime과의 동일성 |
| `historical_runtime_exact` | 해당 시즌 당시 runtime, 관련 asset, behavior, timing 근거가 함께 고정 | 근거에 포함되지 않은 플랫폼·build |

과거 asset을 현재 runtime에서 실행한 결과는 `historical_runtime_exact`가 아닙니다.

Tier별 publish invariant는 다음과 같습니다.

- `static_exact`: static artifact, 정규화 파츠, 스킬 슬롯 개수·순서만으로 게시할 수 있습니다. 스킬 정의/효과 semantics, behavior, bundle, timeline, runtime, timing/scheduler는 이 tier가 보장하지 않으며 `compatibility.evidenceWarnings`에 미해소 상위 근거를 반드시 기록합니다.
- `behavior_exact`: `static_exact` 범위에 더해 behavior artifact와 하나 이상의 선택 bundle 및 canonical bundle set hash가 필요합니다. timeline과 runtime은 아직 partial/unresolved일 수 있습니다.
- `asset_exact_runtime_current`: behavior/bundle에 더해 현재 runtime match, 완전한 runtime reference, resolved scheduler와 scheduler가 참조하는 모든 clock basis 근거가 필요합니다.
- `historical_runtime_exact`: 같은 runtime/timing 완결성을 해당 시즌의 역사 runtime match 근거로 입증해야 합니다.

## 최신 StaticData의 Phase 1C publish 결과

Phase 1C actual smoke는 최신 StaticData를 read-only로 읽어 정책을 다시 계산했습니다. publish 대상과 현재 증거 상한은 다음과 같습니다.

| 시즌 | 보스 | publish tier | 근거와 제한 |
|---:|---|---|---|
| 7 | 울트라 | `static_exact` | 정적 chain/관계 해소. behavior bundle byte 미확보로 `behavior_unresolved` warning |
| 13 | 인디빌리아 | `static_exact` | 정적 chain/관계 해소. behavior bundle byte 미확보로 `behavior_unresolved` warning |
| 26 | 프로비던스 | `static_exact` | 정적 chain/관계 해소. behavior bundle byte 미확보로 `behavior_unresolved` warning |
| 29 | 마더웨일 전격 변종 | `static_exact` | 정적 chain/관계 해소. behavior bundle byte 미확보로 `behavior_unresolved` warning |
| 34 | 앨트루이아 | `static_exact` | 정적 chain/관계 해소. behavior bundle byte 미확보로 `behavior_unresolved` warning |
| 40 | 사치스러운 거미 | `behavior_exact` | behavior와 선택 NAPS bundle 근거 확보. timeline은 partial(`timeline_unresolved`), runtime은 미평가(`runtime_not_evaluated`) |

따라서 시즌 40도 `asset_exact_runtime_current`나 `historical_runtime_exact`로 올리지 않습니다. 합성 fixture가 상위 tier의 schema와 persistence invariant를 시험하더라도 실제 시즌에 대한 증거 주장으로 해석하지 않습니다.

호환성 tier와 원본 client 실행 가능 여부는 별개입니다. 원본 리테일 클라이언트 연결은 동적 `OriginalClientGate`가 통제합니다.

## 전투 결과

전투 결과는 최소한 다음 참조를 가져야 합니다.

    (raid_snapshot_uid, dataset_snapshot_uid, squad_revision_uid[])

Phase 2B 결과는 `lab_harness_observation/v1`만 수락하며 사용한 snapshot, profile/squad/build, runtime/control revision과 validation warning을 함께 보존합니다. 이 값은 backend 상태기계와 저장 계약을 검증하는 합성 관측이지 original-client damage 증거가 아닙니다.

Phase 3 handoff gate를 통과한 뒤 Phase 4에서 원본 client의 `StatisticsContext`가 계산·표시한 damage가 실제 실행 결과의 권위입니다. backend는 그 관측을 별도 simulator 값으로 바꿔 화면에 공급하지 않고, 별도 versioned observation adapter/provenance로 exact session identity와 함께 수신·검증·보존해야 합니다. Phase 2B harness receipt를 `original_runtime`으로 이름만 바꿔 승격해서는 안 됩니다.
