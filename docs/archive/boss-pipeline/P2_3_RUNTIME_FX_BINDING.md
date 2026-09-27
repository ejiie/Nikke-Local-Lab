# P2-3 공통 실행 형식과 FX 전달 연결

> 2026-09-27 보관: 작성 당시의 기록이며 현재 작업 지시가 아닙니다. 현행 문서는 [문서 색인](../../README.md)에서 찾습니다.

구체적인 구현 순서·수정 파일·멱등성/성능/설치 완료 기준은
[정상 실행의 전체 검산 제거 구현 계획](../execution/RUNTIME_FAST_PATH_IMPLEMENTATION_PLAN.md)의 R1~R6를 따른다.

**현행 성능 기준(2026-09-15 운영자 재지정):** 정상 실행/종료에서 CDB 전체 읽기는 0회로
설계한다. 최초 도입·원본 버전 교체·명시적 수리의 전체 검증과 매 실행의 작은 FX 변경
트랜잭션을 분리한다. 지속 핸들/ETW 조사 완료를 구현의 필수 선행 조건으로 두었던 아래
G1~G3 우선순위는 철회하며, 문서 끝의 「검증 범위 재설정」을 따른다. 기존 측정 사실과
실패 반례는 보존한다. 아직 이 새 기준의 코드 변경·설치는 수행하지 않았다.

2026-09-14. 운영자는 연결 후 실게임 검증을 직접 수행하기로 했다. 이번 완료 범위는
**공통 profile 조립 → 정적 변환 → 후보 봉인 → 실행별 전달 파일 생성**이다.
일반 실행 허용·native 자산 적용/복구·설치는 P2-4 이후/P4/P6에 남아 있다.
아직 UI에서 새 게임 검증을 시작할 수 있다고 안내하지 않는다.

## 형식 변경의 근거

기존 v3의 `shieldFxTransformNormalization`은 Transform 전용 보정과 고정 세 속성,
`NonTransformObjectSetSha256` 보존을 표현한다. 이번 필수 `UseScaleHelper` 변경이나
원본 재사용을 이 형식으로 표현하면 사실과 다른 보존 근거가 된다.

새 `nll/boss-runtime-variant-profile/v4`는 `shieldFxPreparation`으로 공통 recipe를 결박한다.
기존 v1/v2/v3 파일과 registry pin은 보존한다. v4는 부팅·음성 정책을 선택하는 값이 아니며,
QTE와 쉴드 FX의 필요 여부는 해당 전투 입력의 존재와 의미로 해석한다.
QTE만 있거나 쉴드만 있는 경우도 합성 검사를 통과했다.

`shieldFxPreparation` 필드:

| 필드 | 의미 |
| --- | --- |
| `contractId` | `nll/boss-shield-fx-preparation/v1` |
| `policyCode` | `source_shield_size_candidate/v2` |
| `sourceBossElementCode` | profile 원본 속성과 동일 |
| `recipeManifestSha256` | 형제 `shield-fx-preparation/recipes.receipt.json` 파일의 hash |
| `variants[]` | 모든 속성/원본 prefab mapping의 재사용·보정 결과 |
| 각 행의 `operationCode` | `reuse` 또는 `adjust_candidate` |
| `sourceBundle`, `targetBundle`, `outputBundle` | 각각 SHA-256과 byteLength. 재사용은 target=output |
| `sourceFxPrefabSetSha256`, `targetFxPrefabSetSha256` | 기존 `elementShield.fxVariants`의 같은 mapping에 결박 |

선택 행은 `(bossElementCode, sourceFxPrefabSetSha256)`로 구별한다. C# 파서는 중복·누락,
다른 source/target pin, 잘못된 원본 속성, 원본에 보정 강제, QTE 원본 속성 불일치,
허용 테이블 불일치와 과거 Transform 계획 혼입을 거절한다. JSON shape를 읽는 것만으로
자산이나 실행 허용을 승인하지 않는다.

## 생산·소비 연결

1. Python 조립기가 원본에서 recipe를 생성·저장·재생성 검증하고 v4 profile에 hash를 기록한다.
2. C# 변환기가 전체 profile 의미를 검증하고 보스 속성·조건의 FX 참조·필요한 QTE를 변환한다.
   원본 ElementTable을 보존한다. 선택 결과에 추가 FX 파일이 필요하면
   `pending_isolated_asset_overlay`로 기록한다.
3. 후보 봉인기가 profile, 5속성 변환, recipe와 보정 bundle byte를 함께 검산한다.
4. `Resolve-PhaseDBossAffinity`가 선택 결과에 `preparedShieldFx`를 전달한다. 이것은 순수 해석이며
   일반 준비기의 ready gate를 완화하지 않는다.
5. `stage-nll-execution-fx.py`는 선택 행의 target pin으로 정확한 cache 요청 경로를 찾고
   독립 실행 폴더에 원본/보정 byte와 manifest를 생성한다. 원본 재사용에는 overlay를 만들지 않는다.
   현재 전달 형식은 선택당 하나의 보정 mapping을 지원하며 여러 개이면 임의 선택하지 않는다.
6. 외부 서버의 observation reader는 exact v4 계약 쌍을 인식한다. 기존 빌드에 설치하지 않았으며
   전체 실행 허용 검사는 별도 준비기 책임이다. 작업자/준비 설정의 도구 pin 목록에도 recipe 의존성을 추가했다.

## 검증 결과와 다음 단계

- 실제 S26/S29를 같은 `invoke-nll-boss-onboarding.ps1 -CandidateOnly`로 조립하고 각각
  다섯 약점의 정적 변환 및 후보 봉인을 통과했다. 계정 DB 대신 기존 합성 seed를 사용했다.
- S29 profile SHA-256:
  `b19da0bd183eb2e07533eea04f8bfc7047e74ebfecc3249bd318b41dc7994b5e`.
- 실제 전달 검사는 세 보정 overlay 생성과 두 원본 재사용을 확인했다. 원본 pack을 동시에
  읽던 검사에서 일시적 접근 실패가 발생하여 후속 검사를 순차 실행했고 통과했다.
  중단된 출력은 재사용하지 않았다. 최종 출력은 `delivery-final-*`다.
- C# 실제 파서의 합성 21개 사례, Python profile 결박·전달 검사, PS 순수 선택 검사를 수행했다.
  수냉 원본에서 전격 하나만 보정하는 합성 전달도 통과하여 고정 세 속성 목록에 의존하지 않음을 확인했다.

로컬 증거는 `artifacts/common-boss-execution-20260914/p2-3-binding/`에 있다.
`candidate-26`, `candidate-29`, `delivery-check.receipt.json`을 기준으로 사용한다.
실게임 완료, 피해 판정의 실제 소비, native cache 적용 또는 설치를 주장하지 않는다.

다음은 P2-4/P2-5의 일반 준비·공통 서버 산출물·실행 전달 통합이다. 이어 P4의 native 자산
적용/복구와 P6 설치가 끝나면 운영자가 화면 크기와 우월 코드 피해 제한을 직접 검증한다.
기존 S29 전용 validation 경로를 단순히 v4 허용으로 확장해 정상 공통 실행 경로로 대체하지 않는다.

## 2026-09-15 공통 설치 연결 후속

위 문단은 P2-3 시점 상태다. 후속 구현은 일반 준비기·coordinator·공통 Job에 연결했다.
`CommonBossDelivery`가 후보/recipe/native 출처를 검증하고, `CommonNativeFx`는 기존
byte-range transaction으로 격리 복제본의 선택 FX만 적용·복구한다. 새 보스용 서버 빌드나
별도 시작 스크립트를 요구하지 않는다. UI는 delivery가 검증된 profile을 일반 준비/시작으로
연결한다. 새 설정에서 과거 `userValidationDelivery`는 사용하지 않으며 과거 복구 도구는 보존한다.

설치 산출물과 검증 근거는 `artifacts/common-boss-execution-20260914/install/`에 둔다.

| 항목 | 고정 근거 |
| --- | --- |
| 공통 후보 bundle | `C:\NLL\Runtime\PhaseD151-v8\bundle.private.json`, SHA-256 `ebf9338714d678a5d5bc88396a259627c878a33b4b36f2ff65296a78781213c7` |
| 기존 복구 기준 | v6 bundle·기존 S26 profile·계정 DB·client/shim/certificate pin 보존 |
| 공통 registry | `C:\NLL\RuntimeInputs\CommonBossExecution\profiles`; S29 profile hash는 위 P2-3과 동일 |
| S29 전달 descriptor | `delivery-29/delivery.private.json`, SHA-256 `841b5e82982f2a1a7f9b9dcd37cfaa031187a803fe99ff71bb2bea7de119a423` |
| native 조각 출처 | `native-1/native-chunks`, receipt SHA-256 `b63aff118831c6b450392042e5138b1719098b75d2578349c45397a680e837c7` |
| pipeline 설정 | `pipeline/configuration.private.json`, SHA-256 `b5229b57edb23d2dae5c3cc93ecdb5a5b63b4ce65b65f2b056eb0aa77127ec47` |
| 관리도구 패키지 | `app-package/sealed-package`, manifest SHA-256 `5d41939217488b635cb2f524468fe81296704be760eafb0b0d2b4298d5f34009` |

v7은 materializer 직접 호출에 필요한 의존 DLL 결손을 발견한 미활성 후보다. v8에서
공통 의존 파일을 봉인해 해결했다. 기존 client를 다시 복제하지 않았다.

설치 전 검증에서 S26/S29의 10개 약점 준비가 ready였고, 실제 coordinator의 S26 1개와
S29 5개 입력은 기존 계정/진행도를 읽기 전용 DB로 해소해 `validated_not_started`를 반환했다.
세 보정은 native 원본에서 recipe를 다시 계산해 HTTP 후보의 변경 필드/크기 입력과 대조했다.
작열/철갑은 2개 객체, 풍압은 3개 객체만 변경하며 나머지 byte/offset은 보존했다.
관리도구 패키지는 전체 적용/복구·재시도·추가 파일 퇴역 검사를 통과했다.

리허설 실패도 보존한다. 첫 적용 뒤 PowerShell .NET callback의 함수 scope 해소 오류를
발견해 봉인된 파일 집합을 데이터로 캡처하고 동일 Job/파일/런타임 목록을 재검증하도록 수정했다.
두 번째는 리허설만 상대경로를 종료 증거에 기록해 C# 경로 검증에서 거절됐다. 리허설 입구를
절대경로로 정규화했다. 각 실패 뒤 게임/서버가 없는 유지보수 잠금에서 정확한 원본 조각과
전체 store 투영 검증으로 복구했다. `rehearsal-recovery*.receipt.json`은 독립 cold 복구 증거이며
동일 Job 종료 증거로 위장하지 않는다. 원본 store SHA-256은
`0745db76654f7d7059ae6777d0572520e23e825590c8a4fb3207f81bf58bf792`다.

공통 합성 Job 검사도 보강했다. PS7 JSON의 DateTime 값은 문자열 재변환으로 정밀도를 잃지
않고 원래 프로세스 시작 시각의 UTC tick으로 비교한다. callback·인계·재시도·종료를
WinPS5와 PS7에서 검사하며 기존 봉인 실행 파일은 수정하지 않는다.

전체 약 6.6GB store의 반복 검증은 기존 HTTP overlay 복구의 60초보다 오래 걸릴 수 있었다.
공통 복구의 제한을 적용과 같은 300초로 맞췄다. 시간 초과는 종료 증거가 아니며 재시도 전에
기존 복구 프로세스의 정확한 신원과 종료를 확인한다. 해시 검증을 줄여 통과시키지 않는다.

설치 상태의 최종 권위는 `installation.receipt.json`이다. 파일이 없으면 활성화 미완료다.
게임은 운영자가 실행하며 5속성의 크기·색상·우월 코드 피해 제한 및 종료 후 재실행을 확인한다.
S29 추가 속성의 실게임 인수, 일반 저지의 Body 제한 실제 소비 등은 자동 검사로 대체하지 않는다.

**설치 완료:** `installation.receipt.json`을 발행했고 활성 v8 선택 포인터 SHA-256은
`678517591df02c34356fa8c646d9aaa43ee525cca9fd4adf2d7d193b9401c626`이다.
`native-lifecycle-3.receipt.json`은 세 보정의 적용/원복/반복 원복 성공을 기록한다.
`installed-readback.receipt.json`에서 설치된 API의 S26/S29 일반 카드와 활성 포인터 기준
S26 준비 및 S29 5약점 준비 ready를 확인했다. 서버/게임은 시작하지 않았다.
필수 repository/Phase 0/완료 Phase/Phase 3B/Actions 및 약점 변형 검사는 `gates-final/`에 있다.

관리도구 설치 계획은 `app-delivery/plan.private.json`이며 hash는
`512a467f290bdb97ab329671221e1d8bc53fccbffe33485c216ad564d662ab7c`다.
원복이 필요하면 게임/관리도구 종료 후 같은 설치 폴더의 `restore-common-installation.ps1`을
명시적으로 실행한다. v6 선택 포인터를 먼저 원자적으로 복원한 후 기존 app 전달기의
restore를 호출한다. 원복 입력은 `runtime-selection.before.json`, `app-delivery/before/`,
`app-package/sealed-package`이며 검사되지 않은 경로/다른 현재 hash는 거절한다.
원복 명령은 준비했지만 새 설치를 실제로 되돌리지는 않았다. GitHub commit/push는 보류한다.

## 2026-09-15 시작 지연 원인 조사

운영자의 시작 지연 신고로 기존 실실행 증거를 읽었다. 게임 재실행·설정 변경·무거운 파일
재해싱은 하지 않았다. 원시 근거와 계산은
`artifacts/common-boss-execution-20260914/startup-investigation-20260915/timeline.json`에 있다.
이 표는 **API가 실행 상태를 최초 기록한 시점 이후**다. 클릭부터 그 이전의 API 준비/계정 조회
시간과 실제 창 표시 시각은 계측되지 않았다. 프로세스 생성 시각은 보관된 OS 시작 시각이며,
중간 단계는 증거 파일 생성 시각으로 근사했다. UI 열은 Job 인계 완료까지이며 화면 polling은
추가 최대 약 3초다. 약점과 보스 속성을 혼동하지 않는다.

| UI 약점 | 실제 보스 속성/FX | 실행 기록(KST) | 게임 프로세스 생성 | 시작 완료 인계 |
| --- | --- | --- | --- | --- |
| 철갑 | 전격 원본 | 07:11:29 | 28.35초 | 77.43초 |
| 전격 | 수냉 원본 | 07:58:14 | 27.61초 | 70.57초 |
| 수냉 | 작열 보정 | 08:03:47 | 125.03초 | 169.27초 |

보정 실행의 세부 구간은 입력/정적 데이터 생성 11.97초, 생성 후 runner 진입 44.71초,
runner 진입 후 서버 생성 60.39초, 서버 후 게임 생성 7.96초다. 비교 원본 실행은 각각
11.91/3.73/4.30/7.67초다. 추가 약 97초 중 약 41초가 native 준비, 약 56초가 native 적용
구간 증가와 일치한다. 범위별 독립 Stopwatch 기록이 없어 이 차이를 정밀 CPU 계측으로
주장하지 않지만, 동일 runner 소스 hash와 실제 apply marker 시각·호출 구조가 원인을 뒷받침한다.

직접 원인은 이번 공통 전달 연결의 전체 store 중복 해시다. 보정 조각은 24,153byte인데,
6,574,364,321byte store에 다음을 실행한다.

1. `CommonBossDelivery.Stage`가 매 실행 `UserValidationStoreTransaction.Prepare`를 호출한다.
   전체를 한 번 읽으며 current/original/candidate 세 SHA-256을 계산한다.
2. `CommonNativeFx.Apply`의 기존 transaction이 같은 Prepare를 다시 수행한다.
3. 쓰기 후 전체 candidate SHA-256을 다시 계산한다.

따라서 게임 시작 전에 전체 파일 읽기 3회분(약 19.7GB), SHA 계산 7회분(약 46.0GB)이
발생한다. 이미 원본과 동일함을 검사하는 Prepare의 current/original 계산도 중복이다.
변경 범위 보호 목적은 필요하지만, 게시 단계에 둘 수 있는 안정된 후보 hash 계산까지
매 실행 준비에서 반복한 배치가 시작 지연을 만들었다. 전달 기능 검사 통과만으로
시작 성능까지 충분하다고 본 이전 설치 판단은 부족했다.

별도 UI 지연도 존재한다. 게임 생성 뒤 bootstrap의 SAIL 확인에 약 8~14초,
runner의 `thirty_second_interactive_health_observation`에 약 33초,
신원 확인/Job 인계에 수초를 쓴 후에야 `started`를 기록한다.
관측 자체는 30초이고 정상 응답·로컬 통신을 확인한다. 이것은 게임 생성 전 지연의 원인이
아니며, 화면의 시작 완료 표시를 추가로 늦추는 원인이다. 실제 첫 화면/입력 가능 시점은 미계측이다.

후속 개선 순서:

- 고정 후보 store hash는 후보 조립/게시 시 봉인하고 실행 준비에서는 실행 신원·조각을 결박한다.
  적용 직전 현재 전체 원본 검증, 독점 핸들, 변경 범위 검증, 쓰기 후 결과 검증은 유지한다.
- transaction의 동일 원본 SHA 중복 계산을 제거할 수 있는지 합성 부분 쓰기/외부 변경 검사로 확인한다.
- 프로세스 생성과 관측 완료를 UI 상태에서 구분한다. 관측을 삭제하거나 조기에 완료로 위장하지 않는다.
- API 요청 수신부터 준비·복사·변형·FX 준비·적용·서버·게임 생성·관측 종료의 실제 소요 시간을
  별도 기록한다. 단순 timeout 증가나 변경 시각만 믿는 성공 캐시는 최적화로 삼지 않는다.

이번 조사는 원인 식별과 기록까지다. 실행 코드·활성 설치·현재 게임은 변경하지 않았다.

## 2026-09-15 종료 후 실행 중 표시·재실행 지연 조사

종료 후에도 실행 중 표시와 시작 버튼 잠금이 지속된다는 신고를 기존 완료 실행으로 대조했다.
같은 조사 폴더의 `exit-timeline.json`에 계산을 보존한다. bootstrap 종료 영수증은 실제
`client.WaitForExitAsync()` 뒤 작성되며 초 단위다. Job 0은 정확한 프로세스 집합 종료 증거다.
창이 닫힌 시각과 브라우저가 마지막 응답을 그린 시각은 기록되지 않았다.

| UI 약점/실제 FX | 종료→Job 0 | FX 원복 | 종료→backend completed |
| --- | --- | --- | --- |
| 철갑/전격 원본 | 약 1.31초 | 없음 | 약 10.10초 |
| 전격/수냉 원본 | 약 0.71초 | 없음 | 약 9.40초 |
| 수냉/작열 보정 | 약 1.11초 | 약 59.94초 | 약 72.15초 |

보정 실행의 KST 시각은 게임 종료 08:10:16, Job 0 08:10:17, FX 복구 자식 시작
08:10:20, 원복 영수증 08:11:20, completed 기록 08:11:28이다. 원복 후 완료까지는
약 8초였다. 이 실행은 실패/timeout 없이 `private_delivery_retired`와 `completed`로 끝났다.
확인한 보정 실행은 약 72초이며, 신고한 더 긴 대기 전체를 이 한 사례로 단정하지 않는다.

두 원인을 분리한다.

1. **종료 후 실제 작업 지연:** watcher는 게임 종료를 OS 핸들로 대기하고 곧바로 Job을
   정리한다. 이어 `Invoke-PhaseDExecutionFxCleanup`이 `CommonNativeFx.Restore`를 호출한다.
   transaction은 6.6GB store 전체에서 current/original/candidate SHA를 계산하고 조각을
   원복한 뒤 전체 원본 SHA를 다시 계산한다. 읽기 2회분·해시 4회분이 해당 60초의 주 작업이다.
   이후 runtime DB/hosts/firewall 복구, PostgreSQL 재시작과 진행도 저장을 순서대로 완료한다.
2. **상태 표현 결손:** `watch-nll-phase-d-execution.ps1`은 위 정리가 모두 성공한 뒤에야
   `execution-state.json`을 `completed`로 바꾼다. 중간에는 `started`가 남는다.
   UI의 `humanStatus`는 이를 “게임 실행 중”으로 표시하고 `updateRaidActions`는 버튼을 잠근다.
   따라서 게임 프로세스가 이미 종료됐어도 복구 작업을 실행 중인 게임처럼 표시한다.

상태 GET은 DB 질의/게임 재실행 없이 파일을 읽는다. 정상 UI polling 간격은 3초,
읽기 오류 뒤 재시도는 5초다. 이번 기록에서 분 단위 대기를 설명하는 것은 복구 구간이며,
단순 UI polling 간격이나 300초 timeout까지 무조건 대기하는 동작이 아니다.

후속 개선은 시작 지연 정비와 함께 수행한다. 종료 감지 즉시 “종료 정리 중”과 단계/경과 시간을
표시하고, 복구와 진행도 저장이 끝나면 완료·재실행 가능으로 바꾼다. 다음 실행의 허용은
원복 완료 증거 뒤로 유지한다. 복구 해시는 부분 쓰기와 무관한 외부 변경을 거절하는 의미를
보존하면서 중복 계산을 줄인다. 기존 성공/부분 실패/재시도·복구 실패 경로를 함께 검증한다.
이번에는 관측·문서만 추가했으며 실행 코드나 설치를 변경하지 않았다.

## 속성 쉴드 사용자 확인과 시작·종료 성능 개선안

2026-09-15 운영자는 “속성 쉴드 처리에는 문제 없어”라고 확인했다. 이 확인은 운영자의
실게임 관측이며 합성 검사를 승격한 결과가 아니다. 개별 패턴별 상세 측정 결과를 임의로
추가하지 않는다. 후속 범위는 시작/종료 지연과 상태 표시이며 FX 크기·색상·참조·피해 조건은
변경 대상이 아니다. 아래는 계획이며 구현/재설치는 아직 하지 않았다.

### F1. 기준 계측과 상태 표시

API 요청 수신, 실행 등록, 준비/복사/변형, native 준비/적용, 서버/게임 생성, 초기 관측,
종료 감지/Job 정리, FX 원복, 상태 저장 완료를 단조 시계의 구간 시간으로 기록한다.
가능하면 stream 읽기 byte와 hash 처리 byte를 함께 기록해 코드 변경의 효과를 검증한다.
기존 조사 수치를 기준선으로 사용하고 계측만을 위해 사용자 게임 실행을 반복 요구하지 않는다.

UI는 게임 생성 직후 “게임 실행 중·초기 확인 중”, 종료 감지 직후 “종료 정리 중”으로 구분한다.
기존 30초 관측은 유지하며 표시 때문에 중복 watcher나 별도 소유자를 만들지 않는다.
서버의 재실행 허용은 원복/저장 완료 증거 이후로 유지한다. 표시를 위한 진행 정보와
실행 허용 상태를 분리해 과거 봉인 실행·실패·복구 호환을 보존한다.

### F2. 고정 후보 계산을 조립/게시 시점으로 이동

현재 매 시작 Stage에서 계산하는 속성별 전체 candidate store hash를 원본 native 조각을
검증하는 조립 단계에서 한 번 계산·봉인한다. 결박은 원본 store hash/길이, profile·recipe·
조각의 위치/길이/전후 hash, 목표 속성과 후보 전체 hash를 포함한다. 현재 전달 v1에는
이 필드가 없으므로 생산/소비 계약을 명시적으로 확장하고 v1/과거 실행 복구는 보존한다.
보스 profile v4와 정상 bootstrap 선택은 그대로다. 새 보스도 공통 조립기에서 자동 생성한다.

실행 Stage는 봉인된 descriptor를 검증하고 실행 신원·원본/보정 조각을 묶는다.
현재 mutable store가 원본인지 여부는 다음 F3의 적용 직전 검사가 판정한다. 오래된 성공값이나
파일 크기/mtime만으로 현재 무결성을 승인하지 않는다. 원본 store 또는 조각이 바뀌면
기존 후보 봉인은 재사용할 수 없다.

### F3. 정상 적용·정상 복구와 부분 실패 복구의 계산 분리

| 경로 | 목표 처리 | 정상 전체 SHA 계산 횟수 |
| --- | --- | --- |
| 시작 | 동일 독점 핸들로 현재 전체 원본 hash와 선택 조각 확인 → 원복 신원 영속화 → 조각 적용 → 전체 후보 hash 확인 | 준비 포함 기존 7회분 → 2회분 |
| 정상 종료 | 현재 전체 hash가 봉인 후보와 일치하고 조각도 일치함을 확인 → 원본 조각 복구 → 전체 원본 hash 확인 | 기존 4회분 → 2회분 |
| 이미 원복됨 | 현재 전체 hash가 봉인 원본과 같으면 반복 원복 성공 처리 | 1회분 |
| 부분 적용·부분 복구 등 미완료 | 정상 후보/원본 어느 쪽과도 다를 때 기존 범위별 전후 byte 검사와 전체 투영 검증 사용 | 기존 정밀 복구 의미 유지 |

빠른 정상 경로에서도 조각·전체 후보 hash가 같은 검증된 조립 결과에 결박돼야 한다.
원본/후보 어느 쪽도 아닌 파일은 부분 쓰기라고 추정하지 않는다. 기존 복구 검증이 범위 밖
변경이나 제3의 byte를 발견하면 쓰기 없이 거절한다. 같은 독점 핸들과 Job 종료 증거,
재시도 소유권, 쓰기 후 전체 검증을 유지한다. 실제 partial-write 복구는 느려도 정확성을 우선한다.

### F4. 검증·설치와 시간 목표

정상 적용/종료, 원복 후 재시도, 중간 쓰기 중단, 범위 밖 변경, 잘못된 후보/원본/조각 결박,
동시에 실행하려는 요청, 복구 실패 후 UI 표시를 검사한다. 세 보정 FX와 두 원본 재사용,
S26 회귀를 확인하고, 기존 백업을 보존한 새 설치에서 측정한다. 게임은 운영자가 실행한다.

현 관측의 단일 전체 hash 약 14초를 단순 적용하면 1차 잠정 목표는 보정 실행의 프로세스 생성
125초 → 약 55~65초, 종료 후 재실행 가능 72초 → 약 35~45초다. 이는 성능 보장이 아니라
검증할 예상치이며 캐시/디스크/CPU 조건에 따라 달라진다. 아직 전체 검증 두 번이 남으므로
몇 초 내 시작/복구를 약속하지 않는다. 측정 후 남은 준비·복사·서버 부팅 병목을 추가로 정비한다.
예상만큼 개선되지 않으면 원인을 다시 계측하며 검사 생략이나 timeout 증가로 완료 처리하지 않는다.

진행 순서는 F1 → F2/F3 → F4다. F1 표시 개선만으로 성능 개선 완료를 선언하지 않는다.
저장소 정리·최적화 중 파일 삭제는 기존 지시대로 P2~P6 완료 이후 별도 수행한다.

## 전체 파일 검사를 정상 실행에서 제외하는 방안 조사 — 2026-09-15

운영자는 위 55~65초/35~45초도 길다고 지적하고 구조적 단축 조사를 요청했다.
**F2/F3의 해시 횟수 축소는 중간 개선안으로 남기며, 다음 구현 순서는 아래 G1~G3 판정이
우선한다.** 현재 쉴드가 정상이라는 인수와 기존 공통 실행 요구는 유지한다.
이번에는 소스/과거 증거/공식 문서를 조사하고 작은 합성 파일만 시험했다. 게임 실행,
client/catalog/CDB 변경, journal 설정 변경, 서비스 추가, 새 설치는 수행하지 않았다.

### 결론과 대안 비교

| 대안 | 확인한 사실 | 판정 |
| --- | --- | --- |
| 작은 HTTP FX만 공급 | 기존 전체/range/HEAD 모듈과 합성 전달 검사가 있음. 현재 모듈은 정확한 `.bundle` 요청을 처리함 | native 게임이 해당 요청으로 보정 FX를 소비하는 연결은 미입증. 즉시 교체 불가 |
| 작은 native 파일/별도 catalog로 공급 | 원본 catalog→pak/chunk→CDB 범위 읽기와 CIDX 계산은 해석됨 | client의 local provider/우선순위와 변경 catalog 수락은 별도 미해결. 범위 reader가 존재한다는 사실만으로 game overlay 지원이라 할 수 없음 |
| USN 값만 비교해 전체 hash 생략 | 이번 합성 시험에서 내용이 바뀌어도 file USN이 같은 사례 재현 | 열린 writer가 있는 구간의 단독 무결성 증거로 사용 금지 |
| 변경을 통제하는 핸들을 계속 유지하고 작은 조각만 적용/원복 | 합성에서 호환 reader 허용, 다른 writer/rename 차단, 소유자의 작은 쓰기 성공 | 현재 native FX를 보존할 수 있는 우선 검증 후보. 실제 게임의 접근/공유 옵션 호환이 선결 조건 |
| oplock으로 변경 시 준비 무효화 | Windows의 캐시 일관성 기능은 존재 | 차선 연구 후보. break/취소/부분 쓰기/소유권 전이 시험 전에는 실행 권한으로 사용하지 않음 |

### A. HTTP/native 별도 전달 경로에서 확인한 한계

- `tools/PhaseD/AssetDelivery/ExecutionAssetOverlayHttp.cs`는 `.bundle` 요청을 처리하고
  `Cache-Control: no-store`를 응답한다. `ExecutionAssetOverlayStartup.cs`는 명시적 환경
  입력으로 이 모듈을 연결할 수 있다. 추가 조사에서 별도 `.external/EpinelPS-fx-candidate`에
  실제 연결과 middleware 검사 성공 기록을 확인했다. 앞서 조사한 151 기반 후보와 다른
  미설치 후보이며, 공통 runner는 native 조각 적용 경로를 사용한다. 서버 연결만으로
  게임의 로딩 선택이 바뀌지 않는다.
- `ResourceCatalogPreflight/VirtualPakReader.cs`와 `ChunkStoreReader.cs`는 오프라인 도구다.
  파일 범위를 추출할 수 있어도 원본 client의 native provider를 대체하는 구현은 아니다.
- 과거 `format-trial-70ce2b78998641d489294a1a52e29210.receipt.json`은 plain SQLite
  catalog 투영이 native loader에서 거절됐음을 기록한다. 모든 대체 경로가 불가능하다는
  증거는 아니지만 catalog만 간단히 교체하면 된다는 근거도 없다.
- `BOSS_ONBOARDING_PIPELINE.md`의 과거 미해결 사항 중 CIDX 규칙은 이후 해결됐다.
  그러나 local provider 경로/선택 우선순위와 변경 catalog 서명 수락을 그것으로 해결한 것은 아니다.
  현재 성공한 고정 길이 native 조각 적용은 이 별도 전달 기능을 입증하지 않는다.
- 앞으로 이 대안을 선택하려면 정확한 FX 요청/로딩 경로와 실제 보정 byte 소비를 확인해야 한다.
  `is_local` 필드·API 문자열·HTTP 200·`no-store`만으로 성공 처리하지 않는다.
  정상 게임 캐시 삭제, 무관한 catalog 변경, DLL 패치로 우회를 만들지 않는다.

**포크한 HTTP 집중 조사:** [HTTP 보정 FX 조사](HTTP_FX_DELIVERY_INVESTIGATION.md)에서
native loader의 bool→VFS stream/로컬 파일 분기를 8개 함수·41개 instruction으로
연결했다. 예전 HTTP 파일명은 현재 native 키와 세 경우 모두 다르다. 확인한 로더 분기에
HTTP 다운로드 호출이 없어 서버만 변경하는 직접 HTTP 방식은 채택 근거가 없다.
전체 런타임 경로와 bool의 SQL 열 이름 결박은 미확정이며, 모든 HTTP 방식의 불가능을
뜻하지 않는다. 작은 로컬 파일 분기는 별도 대안으로 구분한다.

### B. USN/핸들 합성 시험 결과

기존 `UserValidationGenerationPrototype.cs`는 전체 hash 준비 후 물리 파일/볼륨 identity,
USN/journal 범위/boot identity를 비교한다. 과거 4KiB 20회 측정은 메타데이터 재검증만
sub-ms였으며 전체 게임 실행 성능이 아니다. 또한 Verify 반환 시 핸들을 닫으므로 이후
소비까지의 변경 통제를 제공하지 않는다. 그 prototype을 그대로 실행기에 붙여서는 안 된다.

이번 근거는 조사 폴더의 `probe-generation-boundary.ps1`, `generation-boundary.log`,
`synthetic-generation-*/receipt.json`, `read-sharing-compatibility.receipt.json`이다.
첫 비승격 journal 조회는 접근 거절됐고, 기존 승인된 관리자 진단으로 합성 시험을 완료했다.
기존 실패 출력은 성공 결과로 바꾸지 않았다.

| 시험 | 관측 |
| --- | --- |
| 첫 writer를 연 상태에서 쓰고 기준 USN 확보 → 다른 writer로 별도 위치 수정 | 내용 hash 변경=true, file USN 동일=true |
| ReadWrite 소유 핸들 + FileShare.Read 유지 | FileShare.ReadWrite를 허용하는 read-only reader 성공 |
| 위 핸들 유지 중 별도 write/rename | 모두 거절 |
| 위 핸들 소유자의 작은 범위 쓰기 | 성공 |
| 위 핸들 유지 중 FileShare.Read만 지정한 read-only reader | 거절 |

USN은 변경 사실을 기록하지만 동일 종류의 여러 쓰기를 하나로 합칠 수 있고 변경 내용을
복원할 정보도 제공하지 않는다. 따라서 “USN이 같음”, “기록이 overwrite임”으로 특정 조각만
바뀌었다거나 변경 주체가 우리 프로세스라고 단정할 수 없다.
[Microsoft 변경 journal 설명](https://learn.microsoft.com/en-us/windows/win32/fileio/change-journal-records).

파일 공유 검사는 양방향이다. 소유자가 write 권한으로 열었다면, 게임의 read-only open도
기존 writer와 호환되는 공유 옵션을 필요로 한다. 따라서 “게임이 읽기만 하니 핸들을 유지해도
된다”는 추정은 이번 두 번째 반례로 배제한다.
[Microsoft CreateFileW 공유 규칙](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-createfilew).

현재 실제 게임의 CDB DesiredAccess/ShareAccess/쓰기·mapping 사용은 미확정이다.
과거 trace-reader/Observation.cs는 open/read 이벤트를 저장하지만 접근·공유 옵션과 write
이벤트를 보존하지 않았다. 과거 read 관측을 쓰기 없음의 증거로 사용할 수 없다.
**추가 조사:** 사용 중인 ETW create schema에는 DesiredAccess 자체가 없다. 성공/실패
open 연결, VAMap 구독, 늦은 파일 이름 연결과 System/다른 프로세스 이벤트도 필요하다.
합성 반례 및 약 1초대의 준비 검사 실측은 [미확정 구간 집중 조사](../execution/RUNTIME_FAST_PATH_OBSERVATION.md)에
기록했다. 해당 문서의 관측 범위와 G1 판정을 적용하며, 합성 observer를 바로 설치하지 않는다.

### C. 전체 읽기 없는 정상 경로의 성립 조건

우선 후보는 **검증된 파일을 공통 관리도구의 소유자가 계속 보유하며 변경을 통제하는 방식**이다.
최초 준비 때 전체 원본/후보 검산을 수행하고, 실제 파일을 검증한 시점부터 허용한 읽기와
소유자의 봉인된 조각 쓰기 외에는 변경이 발생하지 않음을 보장해야 한다.

그 조건이 성립하면 매 시작/종료에는 profile·recipe·조각 pin과 물리 identity/소유권을
확인하고 작은 전후 byte만 읽고 쓰는 경로를 검증할 수 있다. 전체 파일의 현재 hash를 다시
측정한 것처럼 보고하지 않고 **최초 검증 + 지속된 변경 통제 + 조각 검산**으로 증명한다.
원본/후보 전체 hash는 여전히 조립 결과에 결박한다. 매번 6.6GB 사본을 생성하지 않는다.

필수 경계:

- 기존 공통 관리도구/실행 수명주기에 최소한의 소유 기능을 둔다. 새 보스/버전 전용 launcher,
  Windows 서비스/드라이버나 게임 프로세스 후킹을 만들지 않는다.
- writer 핸들은 게임에 상속하지 않는다. 앱·적용기·watcher 사이의 인계에서 변경 가능한
  공백을 허용하지 않으며, 과거 receipt나 PID만으로 핸들 소유를 재구성하지 않는다.
- 실제 게임이 허용하지 않은 쓰기 또는 비호환 open을 요구하면 그 요청을 조용히 실패시키면서
  정상이라고 하지 않는다. 호환 불가로 판정하고 다른 경로를 검토한다.
- 관리도구 종료/crash, 핸들 분실, 파일 교체, 재부팅, 추적 연속성 결손 또는 예상 밖 쓰기는
  준비 무효화다. 다음 실행에서 자동으로 정상 세대로 간주하지 않는다.
- 최초/업데이트/무효화 복구에는 전체 검산을 유지한다. 준비가 무효하면 UI에 즉시 알리며
  빠른 시작 버튼 뒤에서 긴 재검사를 숨겨 실행하지 않는다.
- 소유자의 부분 쓰기 중단과 실제 파일 상태를 영속화하고, 정상 작은 조각 원복과 정밀 복구를
  구분한다. 다음 실행은 복구와 진행도 저장 완료 이후에만 허용한다.

oplock은 공유 충돌/다른 쓰기에 따른 캐시 무효화 후보지만 단순 파일 잠금과 동일하지 않다.
break 통지·응답, mapped write, 소유자 종료, 재취득 사이의 공백과 deadlock을 별도 증명해야 한다.
게임이 매번 정당하게 CDB를 수정한다면 무효화도 매번 발생할 수 있어 단축 효과가 없을 수 있다.
현 단계에서 이를 완성된 빠른 복구 계약으로 채택하지 않는다.
[Microsoft oplock 종류](https://learn.microsoft.com/en-us/windows/win32/fileio/types-of-opportunistic-locks),
[break 처리](https://learn.microsoft.com/en-us/windows-hardware/drivers/ifs/breaking-oplocks).

### 다음 작업과 중단 기준

| 순서 | 작업 | 판정 근거 |
| --- | --- | --- |
| G1 | CDB open/read/write/mapping 관측 범위 정비 후 운영자 실행에서 확인 | 정확한 client·파일 신원, 성공 open의 공유 옵션, 완료 상태/늦은 이름 연결/주체/손실 확인. 별도 근거 없는 DesiredAccess는 미확정 유지 |
| G2 | 호환 조건에 맞는 지속 핸들 소유·작은 조각 적용/원복 합성 검증 | 정상 구간 전체 파일 읽기 0, 부분 쓰기/외부 쓰기/교체/인계 중단/크래시 검출. 파일 크기와 무관한 작업량 확인 |
| G3 | G1/G2 모두 충족할 때 공통 구현·UI 계측·원복 가능한 설치 | 정상 FX 유지, 기존 소유권/실행 허용과 과거 복구 호환, 실제 시작/종료 시간 |
| 대안 전환 | 게임 접근과 지속 소유가 충돌하거나 매번 무효화 | 임의 권한/게임 설정 변경 없이 HTTP/native provider의 별도 작은 자산 경로 조사로 전환 |

G1에서 필요한 게임 실행은 운영자가 수행한다. 지금 실행 중인 게임에 차단 핸들을 시험하거나
에이전트가 게임을 새로 실행하지 않았다. 성공한 쉴드 검증을 반복 요구하기 전에 필요한 관측과
완료 기준을 구체화한다. 저장소 정리는 이 성능 조사의 부수 작업으로 진행하지 않는다.

목표는 전체 검증 유효 상태에서 **도구가 추가하는 준비 및 FX 적용/원복 각각 p95 5초 이내**로
두고, 최초 준비·원본 게임 로딩·서버 부팅·진행도 저장은 따로 보고한다. 아직 달성 수치가 아니다.
이전 원본 FX 실행의 약 28초에도 입력 준비 약 12초와 서버→게임 약 8초 등이 있으므로,
FX 전체 읽기를 제거한 뒤에는 해당 공통 구간도 계측·정비해야 한다. 게임 자체 로딩까지
합쳐 몇 초 내 실행을 보장하거나 최초 전체 검증을 다른 단계에 숨겨 성능으로 주장하지 않는다.

## 검증 범위 재설정 — 2026-09-15 운영자 요구 반영

운영자는 정상 실행과 멱등성이 확보되면 속도를 우선하며, 6.6GB 전체를 매 실행마다
검산하는 과도한 검증을 제거하도록 방향을 명확히 했다. 기존 구현이 제공하려던
「범위 밖 byte도 실행 전후 동일함을 매번 증명」은 사용자 요구로 간주하지 않는다.
우리의 변경 책임 범위와 설치 전체의 무결성 진단을 분리한다.

| 시점 | 수행할 작업 | 정상 실행 경로의 전체 CDB 읽기 |
| --- | --- | --- |
| 최초 기준 설치/새 원본 버전 도입 | 원본 검증, 버전·파일 신원과 조각 위치/길이/전후 내용 봉인 | 실행 요청 밖의 별도 준비 작업 |
| 정상 시작 | 설치 버전/변경 계획 결박 및 실행 소유권 확인 → 대상 조각 현재 내용 확인 → 필요한 조각만 적용·읽어 확인 | 0회 |
| 정상 종료 | 게임 종료 확인 → 해당 실행이 적용한 조각만 원복·읽어 확인 → 진행도 저장 후 완료 | 0회 |
| 재시도/앱 재시작 | 영속 변경 기록과 대상 조각으로 상태 조정. 앱 재시작만으로 전체 재검사하지 않음 | 정상 상태/알려진 중단 상태에서는 0회 목표 |
| 원본 교체/예상 밖 대상 내용/복구 불가/수리 요청 | 불명확한 상태에 임의 쓰기를 하지 않고 명시적 복구·진단으로 분리. 필요할 때 전체 검사 | 정상 실행 시간에 숨기지 않음 |

정상 적용/복구의 멱등성은 다음으로 증명한다.

- 같은 실행의 조각이 이미 원하는 적용 상태라면 중복 쓰기를 생략한다. 다른 실행의 잔류를
  현재 실행의 성공으로 임의 인수하지 않는다. 다른 속성 전환은 기존 변경 종료 후 처리한다.
- 이미 원본 조각이면 반복 복구를 성공 처리한다. 전후 어느 쪽도 아닌 내용은 쓰기 중단으로
  추정하지 않고, 해당 실행의 준비 기록과 복구 규칙으로 확인한다.
- 작은 원본/목표 조각과 적용 계획을 쓰기 전에 영속화한다. 부분 적용/부분 원복, receipt
  기록 직전·직후 중단, 반복 요청, 동시 시작을 합성 검사한다. 동일 작업을 다시 실행해도
  최종 상태가 같아야 한다. 파일 크기에 비례하는 검산/복사로 우회하지 않는다.
- 쓰기는 게임 실행 전과 종료 후에만 수행하며 그 짧은 작업 동안 필요한 파일 접근권과
  기존 공통 실행 소유권을 유지한다. 게임 실행 내내 writer 핸들을 보유할 요구는 추가하지 않는다.

신뢰 범위는 **검증하여 설치한 로컬 lane과 관리도구가 수행하는 작은 변경**이다.
파일 교체·길이/버전 불일치·대상 조각 불일치 등 감지된 이상은 별도로 처리하지만,
조각 밖의 임의 훼손까지 매 실행에 탐지한다는 보장은 하지 않는다. 파일 metadata나 USN을
전체 byte 검증과 동등한 증거로 보고하지 않는다. 범위를 좁힌다는 사실을 계약/receipt에도
명시하며, 측정하지 않은 현재 전체 hash를 검산 성공으로 표시하지 않는다.

다음 구현 순서는 변경 트랜잭션 계약/상태 전이 정비 → 작은 조각 적용·복구와 중단/재시도
검증 → 공통 실행 연결·시간 계측 → 원복 가능한 설치다. 모든 속성과 S26/S29에 같은
경로를 적용한다. ETW/지속 핸들/oplock은 실제 문제가 생길 때 사용할 진단 또는 대안이며
이 순서를 막는 게이트가 아니다. HTTP/별도 native provider 연구도 독립 대안으로 남긴다.

게임 배포의 참고 사례로 SteamPipe는 파일을 약 1MB 조각으로 나누고 업데이트 시 새로
생기거나 달라진 조각을 전달한다. Steam은 무결성 검사 기능도 별도로 제공한다. 이 사례는
배포·갱신·수리와 실행의 역할을 나눌 근거이며, 모든 게임이나 NIKKE의 내부 검증 주기를
확정하는 근거는 아니다.
[SteamPipe 공식 설명](https://partner.steamgames.com/doc/sdk/uploading?l=english),
[Steam 무결성 검사](https://help.steampowered.com/en/faqs/view/0C48-FCBD-DA71-93EB).
