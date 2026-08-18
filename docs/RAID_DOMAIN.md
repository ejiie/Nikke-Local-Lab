# Solo Raid Challenge domain contract

## 지원 범위

`SoloRaidChallenge`만 지원합니다. 일반 솔로 레이드 1~7단계는 전투 콘텐츠로 구현하지 않으며 Union Raid는 비활성 확장 지점입니다.

## Normal-stage unlock stub

lab-owned test harness가 Challenge 해금 선행조건을 재현해야 하는 경우에만 다음 합성 상태를 제공합니다.

    implemented = false
    lastClearLevel = 7

이 stub은 일반 단계의 raid session, battle entry, result, reward를 만들 권한이 없습니다. API와 domain service는 `mode=challenge` 외의 전투 요청을 거부합니다. 원본 client gate가 해제되기 전에는 이 값을 원본 client에 전달하지 않으며 공식 계정·서비스 진행도 우회에 사용하지 않습니다.

`difficultyType=2`와 `waveOrder=8`은 Challenge adapter의 고정 compatibility selector이며 도메인 entity ID가 아닙니다. 원본 preset, wave, monster, spot, asset ID는 ephemeral staging 또는 Git 비추적 compatibility map 밖으로 나오지 않습니다.

## RaidSnapshot

`RaidSnapshot`은 특정 시즌 Challenge를 재현하기 위한 불변 증거 묶음입니다.

- 자체 `raid_snapshot_uid`
- 자체 `challenge_encounter_uid`와 `dataset_snapshot_uid`
- 자체 `boss_variant_uid`
- Git 비추적 local map을 가리키는 자체 `compatibility_map_uid`
- 사용자-facing `season_number`
- 고정 mode `challenge`
- 정적 데이터 artifact UID와 SHA-256
- 선택 asset bundle artifact UID, 역할, SHA-256과 set hash
- behavior와 timeline artifact UID 및 SHA-256
- client runtime build UID, local label, SHA-256
- compatibility tier와 runtime relation
- validation status, blocking reason, warning

원본 content ID, 파일명, 설치 경로는 snapshot JSON과 API에 포함하지 않습니다.

`localBuildLabel`은 lab DB 안에서만 쓰는 별칭이며 원본 build 식별자나 파일명을 복사하는 필드가 아닙니다.

`asset_bundle_set_sha256`은 선택 bundle SHA-256을 소문자로 정규화하고 중복 제거·사전식 정렬한 뒤, LF(`\n`) 하나로 연결한 UTF-8 byte열의 SHA-256입니다. 마지막 LF는 붙이지 않습니다. importer와 validator는 저장값을 재계산합니다.

## 활성 시즌

`ActiveRaidSeason`은 현재 UI에 노출할 단 하나의 `RaidSnapshot`을 가리키는 가변 포인터입니다. snapshot 자체는 불변입니다.

과거 시즌 선택은 snapshot 활성 포인터를 바꾸는 관리 작업이며, 원본 UI가 역사 시즌 browser를 제공한다고 가정하지 않습니다.

## 호환성 등급

| tier | 보장하는 범위 | 보장하지 않는 것 |
|---|---|---|
| `static_exact` | 보스, 속성, 파츠, 스킬 등 정적 관계가 snapshot과 일치 | behavior와 timing |
| `behavior_exact` | 정적 관계와 behavior graph/task 연결이 일치 | runtime scheduler와 animation callback의 완전 일치 |
| `asset_exact_runtime_current` | 선택 asset과 현재 runtime build/hash 및 검증된 scheduler 의미가 일치 | 해당 시즌 당시 역사 runtime과의 동일성 |
| `historical_runtime_exact` | 해당 시즌 당시 runtime, 관련 asset, behavior, timing 근거가 함께 고정 | 근거에 포함되지 않은 플랫폼·build |

과거 asset을 현재 runtime에서 실행한 결과는 `historical_runtime_exact`가 아닙니다.

호환성 tier와 실행 가능 여부는 별개입니다. `RaidSnapshot.execution.enabled`는 lab-owned harness에서 해당 snapshot을 실행할 수 있는지만 뜻합니다. 원본 리테일 클라이언트 연결은 별도 `OriginalClientGate`가 통제하며, snapshot이 `ready` 또는 `execution.enabled=true`여도 그 gate가 blocked이면 원본 client 실행은 허용되지 않습니다.

## 전투 결과

전투 결과는 최소한 다음 참조를 가져야 합니다.

    (raid_snapshot_uid, dataset_snapshot_uid, squad_revision_uid[])

결과에는 계산된 damage뿐 아니라 사용한 compatibility tier와 validation warning을 함께 보존합니다.
