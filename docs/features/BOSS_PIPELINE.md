# 보스 추가와 공통 실행 준비

기준: 2026-09-27 `main`의 코드와 `C:\NLL\RuntimeInputs\CommonBossExecution\profiles` 등록 상태.
작업 기록과 실패 조사 원문은 [보관 기록](#보관-기록)에 있습니다.

## 지켜야 할 규칙

- UI 요청 한 번으로 원본 근거에서 패턴·속성·QTE·실드 FX를 조립하고 공통 실행 구성까지 만듭니다.
  새 보스마다 전용 서버·스크립트·수동 전달 계획을 만드는 것은 정상 흐름이 아닙니다.
- 시즌 번호나 profile 버전만으로 부팅·음성·종료 정책을 바꾸지 않습니다. 버전 해석 뒤에는
  실제 전투 입력과 필요한 변환 유무로 처리를 고릅니다.
- 특정 속성 외 피해를 받지 않는 body·parts·QTE 패턴에는 속성 실드가 있으며, 피해 허용 조건과
  실드 FX를 함께 처리·검증합니다(2026-09-14 운영자 요구). 원본에서 조건/FX를 찾지 못하면
  결손으로 남기고 준비 완료를 거절합니다.
- 자동 조립 완료, 실행 준비 `ready`, 운영자 실게임 인수는 서로 다른 상태입니다.

## 처리 흐름

```text
관리도구 솔로 레이드 → 시즌 선택 → 미처리 시즌 [예]
  POST /admin-api/v1/boss-onboarding-jobs            (BossOnboarding.cs, 영속 job)
  → scripts/invoke-nll-boss-onboarding-job.ps1         (활성 pipeline 설정·입력 hash pin 검증)
    → invoke-nll-boss-onboarding.ps1 -CandidateOnly   (행동 트리 확보·profile 조립·FX 확보·
                                                       실드 크기 recipe·5약점 변형·후보 봉인)
    → Nll.BossNativeCandidate.ps1                     (보정 FX가 있을 때 native chunk 후보)
    → Nll.CommonBossDelivery.ps1                      (공통 전달 파일)
    → materializer --register-common-boss-database   (DB 연결 먼저 등록)
    → Nll.BossPublication.ps1                         (registry 원자 게시)
  → job completed → 시즌 카드 "processed"
실행 전: POST /admin-api/v1/execution-preparation → scripts/Nll.PhaseDPreparation.ps1
```

- 조립 worker는 게임·서버·UAC·서비스·드라이버를 호출하지 않습니다(스크립트 머리말의 계약).
- DB 등록이 실패하면 게시하지 않아 UI에서 다시 요청할 수 있고, 게시 실패 뒤 재시도는 같은
  불변 DB 연결을 재사용합니다.
- 새 게시의 admission은 `common-boss-runtime-admission/v1`입니다
  (`CommonBossRuntimeBindingStore.cs`, V0022 `common_boss_runtime_binding`).
  기존 여섯 시즌의 `challenge-boss-support/v1` 역사 snapshot은 변경하지 않습니다.
- 준비기는 profile v1/v2/v4만 수락합니다. v4의 `shieldFxPreparation`은
  `source_shield_size_candidate/v2` 계획이어야 합니다. v3은 과거 검증 전용 경로의 형식입니다.

## 코드 위치

| 책임 | 위치 |
|---|---|
| 시즌 목록·동기화·이미지 | `BossSeasonCatalog.cs`, `BossSeasonSynchronization.cs`, `scripts/sync-nll-boss-season-catalog.ps1`, `scripts/materialize-nll-boss-catalog-images.py` |
| 작업 큐·상태 | `BossOnboarding.cs`, `PowerShellBossPipelineRunner.cs` |
| 행동 트리·FX 확보 | `scripts/acquire-nll-boss-behavior.py`, `scripts/acquire-nll-boss-fx.py`, `scripts/inspect-nll-boss-behavior-assets.py` |
| profile·QTE·실드 조립 | `scripts/materialize-nll-boss-runtime-profile.py`, `scripts/nll-shield-fx-recipes.py`, `scripts/nll-shield-fx-assessment.py` |
| 5약점 변형·profile 검증 | `tools/NikkeLocalLab.PhaseD.RuntimeMaterializer/BossRuntimeVariantProfile.cs`, `BossAffinityStaticDataVariant.cs`, `BossShieldPatternDiscovery.cs` |
| native FX 적용·복구 | `NativeFxExecutionDelivery.cs`, `NativeFxRangeTransaction.cs`, `NativeFxRangeJournal.cs`, `CommonNativeFxBaseline.cs` |
| 실행 준비 | `scripts/Nll.PhaseDPreparation.ps1`, API `PhaseDPreparation.cs` |
| 계약 | [공통 보스 실행 입력·호환·상태](../contracts/COMMON_BOSS_EXECUTION.md) |

UI 파일은 `wwwroot/editor/boss-seasons.js`입니다. `user-validation.js`는 과거
`awaiting_game_validation` 상태의 검증 전용 경로를 복구·표시하기 위해 남아 있으며,
공통 경로로 처리된 시즌은 일반 시작 버튼을 사용합니다.

## 현재 등록 상태

| 시즌 | profile | 원본 속성 | 실드 | 운영자 실게임 확인 |
|---|---|---|---|---|
| 7 | v4 | 전격 | 없음 | 151에서 정상 실행 확인(2026-09-15). 152 재조립 후 별도 기록 없음 |
| 9 | v4 | 철갑 | 속성 연동 | 대기 |
| 10 | v4 | 수냉 | 속성 연동 | 기록 없음 |
| 25 | v4 | 풍압 | 속성 연동 | 대기 |
| 26 | v2 | 전격 | 없음 | 151에서 인수 완료(2026-09-06) |
| 27 | v4 | 작열 | 속성 연동 | 기록 없음 |
| 29 | v4 | 전격 | 속성 연동 | 151에서 속성 쉴드 정상 확인(2026-09-15) |
| 34 | v4 | 전격 | 속성 연동 | 대기 |
| 41 | v4 | 작열 | 속성 연동 | 대기 |

2026-09-17 152 전환 때 기존 보스를 152 원본으로 다시 조립했고 설치 직후 5약점 준비는 모두
`ready`였습니다. 준비 `ready`는 전투·FX 인수가 아닙니다.

## 알려진 결함과 남은 작업

- **S39·S42 조립 실패 수정** (2026-09-28, 소스 변경·오프라인 후보 검증만. 설치·게시·실게임 전):
  - S39 `boss_profile_shield_fx_variant_not_unique`(실제 후보 0개): 같은 이름 계열과 정확한 공통
    효과명이 모두 없을 때만, 원본 의미 문자열이 `<한정어>_<효과>`처럼 구간 단위로 공통 `fx_m_<효과>`로
    끝나는 후보(`island_immune_barrier` → `immune_barrier`)를 받습니다. 그런 후보가 둘 이상이면 계속 거절합니다.
  - S42 `boss_profile_qte_v3_discovery_invalid`: QTE 행마다 원본 속성이 다를 수 있습니다(전격 2행·수냉
    1행). 원본 보스 속성 실행은 행을 바꾸지 않고, 그 밖에는 연결된 모든 행을 목표 속성으로 바꾸되
    실제로 달라진 행만 셉니다. profile은 정렬된 원본 속성 집합만 요구하고, 행별 원본 속성은
    `recordSetSha256`와 discovery `shieldPatterns.quickTimeEvents[].elementCode`로 확인합니다.
  - 조립기의 `boss_profile_*` 코드가 포괄 코드 대신 작업 결과로 전달됩니다.
  - 남은 미확정: S42 수냉 소비 행동 트리에 QTE 노드가 없어 실제 QTE 소비 여부는 실게임 확인이
    필요합니다. [S42 조사](../archive/boss-pipeline/S42_ONBOARDING_QTE_20260922.md),
    [S39 조사](../archive/boss-pipeline/S39_ONBOARDING_FX_20260923.md)
- 시작 요청→게임 창 생성 구간(약 32초)의 추가 단축 조사는 운영자가 보류했습니다.

## 검증

CI는 source-only 검사만 실행합니다: `scripts/test-nll-boss-publication.ps1`,
`test-nll-boss-native-composition.ps1`, `test-nll-boss-profile-qte.py`,
`test-nll-shield-fx-recipes.py`, `test-nll-boss-fx-acquisition.py`,
`test-nll-boss-behavior-acquisition.py`, `test-nll-boss-onboarding-candidate.py`와
`scripts/verify-automation-boss-weakness-variant.ps1`. 실제 pack/bundle을 쓰는 검사
(`test-nll-boss-onboarding-local.ps1`, `test-nll-published-boss-preparation.ps1` 등)는 로컬에서만
실행하며 원본 자료는 커밋하지 않습니다.

## 보관 기록

- [공통 실행 통합 계획 P0~P6과 S7/S25/S9 조사](../archive/boss-pipeline/COMMON_BOSS_EXECUTION_PLAN.md)
- [이전 파이프라인 문서(151 native FX·v3 후보 경로)](../archive/boss-pipeline/BOSS_ONBOARDING_PIPELINE.md)
- 속성 실드: [패턴 조사](../archive/boss-pipeline/P2_2_ELEMENT_SHIELD_INVESTIGATION.md),
  [조건·FX 대응표](../archive/boss-pipeline/P2_2_SHIELD_CONDITION_FX_MAP.md),
  [기준 크기](../archive/boss-pipeline/P2_2_SHIELD_SIZE_REFERENCE.md),
  [실행 형식·전달](../archive/boss-pipeline/P2_3_RUNTIME_FX_BINDING.md),
  [HTTP 전달 조사](../archive/boss-pipeline/HTTP_FX_DELIVERY_INVESTIGATION.md)
- 시즌별: [S29 행동 트리](../archive/boss-pipeline/S29_BEHAVIOR_PATTERN_TRACE.md),
  [S34 실험](../archive/boss-pipeline/S34_COMMON_PIPELINE_EXPERIMENT.md),
  [시즌 목록 동기화](../archive/boss-pipeline/BOSS_SEASON_SYNC_PLAN.md),
  [과거 검증 전용 실행 안내](../archive/boss-pipeline/BOSS_NATIVE_USER_VALIDATION.md)
