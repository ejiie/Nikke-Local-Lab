# Solo Raid Challenge domain contract

## 지원 범위

`SoloRaidChallenge`만 지원합니다. 일반 솔로 레이드 1~7단계는 전투 콘텐츠로 구현하지 않으며 Union Raid는 비활성 확장 지점입니다.

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

이 상태는 `RaidSnapshot`의 불변 provenance가 아니므로 snapshot에 저장하지 않습니다. 일반 단계의 raid session, battle entry, result, reward를 만들 권한도 없습니다. 원본 client gate가 해제되기 전에는 이 값을 원본 client에 전달하지 않으며 공식 계정·서비스 진행도 우회에 사용하지 않습니다.

`difficultyType=2`와 `waveOrder=8`은 Challenge adapter의 고정 compatibility selector이며 도메인 entity ID가 아닙니다.

## RaidSnapshot

`RaidSnapshot` v2는 지원 정책을 통과하고 publish 준비가 끝난 특정 시즌 Challenge를 재현하기 위한 불변 증거 묶음입니다. 미해소·불완전·무효 후보는 별도 import diagnostic으로 남기며 이 schema로 직렬화하지 않습니다.

- 자체 `raid_snapshot_uid`
- 자체 `challenge_encounter_uid`, `boss_variant_uid`, `dataset_snapshot_uid`
- Git 비추적 local map을 가리키는 자체 `compatibility_map_uid`
- 사용자-facing `season_number`
- `challenge-boss-support/v1` admission rule과 정규화 속성/약점
- 정적 데이터 artifact UID와 SHA-256
- 선택 asset bundle artifact UID, 역할, SHA-256과 set hash
- behavior와 timeline artifact UID 및 SHA-256
- client runtime build UID, local label, SHA-256
- compatibility tier와 runtime relation
- provenance readiness와 warning

원본 content ID, 파일명, 설치 경로는 snapshot JSON과 API에 포함하지 않습니다.

published snapshot은 `readiness.status=ready`이고 non-null `compatibility_map_uid`를 가져야 합니다. admission의 정규화 속성·약점은 authoritative import 결과이며, JSON이 자기 주장만으로 원천 관계를 증명한다고 보지 않습니다. importer가 map과 source artifact hash를 교차검증한 뒤에만 publish합니다.

`localBuildLabel`은 lab DB 안에서만 쓰는 별칭이며 원본 build 식별자나 파일명을 복사하는 필드가 아닙니다.

`asset_bundle_set_sha256`은 선택 bundle SHA-256을 소문자로 정규화하고 중복 제거·사전식 정렬한 뒤, LF(`\n`) 하나로 연결한 UTF-8 byte열의 SHA-256입니다. 마지막 LF는 붙이지 않습니다. importer와 validator는 저장값을 재계산합니다.

## 활성 시즌

`ActiveRaidSeason`은 현재 UI에 노출할 단 하나의 published `RaidSnapshot`을 가리키는 가변 포인터입니다. snapshot 자체는 불변입니다.

지원 정책을 통과하지 못한 snapshot은 활성 포인터의 대상이 될 수 없습니다. 과거 시즌 선택은 이 포인터를 바꾸는 관리 작업이며, 원본 UI가 역사 시즌 browser를 제공한다고 가정하지 않습니다.

## 호환성 등급

| tier | 보장하는 범위 | 보장하지 않는 것 |
|---|---|---|
| `static_exact` | 보스, 속성, 파츠, 스킬 등 정적 관계가 snapshot과 일치 | behavior와 timing |
| `behavior_exact` | 정적 관계와 behavior graph/task 연결이 일치 | runtime scheduler와 animation callback의 완전 일치 |
| `asset_exact_runtime_current` | 선택 asset과 현재 runtime build/hash 및 검증된 scheduler 의미가 일치 | 해당 시즌 당시 역사 runtime과의 동일성 |
| `historical_runtime_exact` | 해당 시즌 당시 runtime, 관련 asset, behavior, timing 근거가 함께 고정 | 근거에 포함되지 않은 플랫폼·build |

과거 asset을 현재 runtime에서 실행한 결과는 `historical_runtime_exact`가 아닙니다.

호환성 tier와 원본 client 실행 가능 여부는 별개입니다. 원본 리테일 클라이언트 연결은 동적 `OriginalClientGate`가 통제합니다.

## 전투 결과

전투 결과는 최소한 다음 참조를 가져야 합니다.

    (raid_snapshot_uid, dataset_snapshot_uid, squad_revision_uid[])

결과에는 계산된 damage뿐 아니라 사용한 compatibility tier와 validation warning을 함께 보존합니다.
