# 정상 실행의 CDB 전체 검산 제거 구현 계획

> 2026-09-27 보관: 작성 당시의 기록이며 현재 작업 지시가 아닙니다. 현행 문서는 [문서 색인](../../README.md)에서 찾습니다.

작성: 2026-09-15. 상태: **R1~R5 구현·자동 검사 완료. R6 v9 설치·준비 실측·설치 후 자동 검사 완료, 운영자 실게임 시간·재실행 확인 대기**.
요구 근거: 운영자는 정상 실행과 멱등성이 확보되면 속도를 우선하고, 매번 6.6GB를 읽는
검증은 제거하도록 명확히 했다. [검증 범위 재설정](../boss-pipeline/P2_3_RUNTIME_FX_BINDING.md)을 구현한다.
기존 측정은 [집중 조사](RUNTIME_FAST_PATH_OBSERVATION.md)에 보존한다.

## 목표와 범위

- **정상 시작/종료에서 CDB 전체 읽기 0회.** Stage는 CDB 내용 검산 없이 작은 실행 입력을
  구성하며 적용/원복은 선택한 FX 조각만 읽고 쓴다. 다른 함수/프로세스에 전체 읽기를
  옮기는 방식은 완료로 인정하지 않는다.
- 이미 정상인 원본 쉴드, 세 보정 쉴드의 크기·참조·피해 조건은 그대로 사용한다.
  속성/시즌별 실행 예외 없이 동일한 트랜잭션을 적용한다.
- 최초 설치/원본 교체 검증 및 수리는 별도 작업이다. 정상 시작 뒤에 숨겨 실행하지 않는다.
  검증된 기준 설치의 신원·버전과 작은 변경 기록을 재사용하며, 앱 재시작만으로 전체를 재검산하지 않는다.
- 게임 실행 내내 유지하는 writer 핸들, ETW, USN, oplock, HTTP 대체 전달을 필수 조건으로
  추가하지 않는다. 작은 쓰기 동안의 독점 접근과 기존 공통 실행/종료 소유권은 유지한다.
- 현재 ResourceProbe를 사용한다. 삭제한 FxProbe/UserValidation이나 새 전체 client/CDB
  복제본을 만들지 않는다. DB 재설계·저장소 추가 삭제·게임 DLL/음성 변경은 범위 밖이다.

## 구현 지점

| 현행 코드 | 문제 | 변경 |
| --- | --- | --- |
| `CommonBossDelivery.Stage` | `UserValidationStoreTransaction.Prepare`가 전체 원본/후보를 계산 | 선택 조각·기준 설치·실행 신원만 결박하는 새 manifest 생성 |
| `CommonNativeFx.Execute`의 apply | 전체 Prepare 재호출과 쓰기 후 전체 Hash, 이미 marker가 있으면 재시도 거절 | 작은 조각 상태와 영속 작업 기록으로 적용/재시도 |
| `CommonNativeFx.Execute`의 restore | 전체 투영 검증·전체 Hash, marker가 없어도 전체 SHA | 작은 조각 복구·반복 복구, 시작되지 않은 작업의 원본 조각 확인 |
| `ExecutionAssetRetirement` | native 실행 v1만 구분하여 소비 | 명시적 v2 경로 추가, 같은 Job 종료/실행 결박을 유지 |
| watcher/API/UI | 실제 게임 종료 후에도 `started`가 오래 표시, 단계별 시간 부족 | 종료·복구·저장 단계의 증거와 시간을 표시 |

위 파일 위치는 `tools/NikkeLocalLab.PhaseD.RuntimeMaterializer/`,
`src/NikkeLocalLab.Automation/`, `scripts/watch-nll-phase-d-execution.ps1`,
`src/NikkeLocalLab.Admin.Api/`다. 기존 `UserValidationStoreTransaction`의 전체 검증 계약을
이름만 유지한 채 약화하지 않는다. 새 범위 트랜잭션을 명시적으로 만들고 신규 실행이 사용한다.

## R1. 변경 계약과 상태 전이 확정

`docs/contracts/COMMON_BOSS_EXECUTION.md`에 신규 빠른 경로를 구분하여 정의한다.
`nll/common-native-fx-execution/v2`와 그 적용/퇴역 receipt를 함께 설계한다.
필요한 입력은 기준 설치의 버전/신원, 물리 파일 식별자·길이, profile/recipe/후보 봉인,
실행 UID, 조각별 위치·동일 길이·원본/목표 내용 hash다.

기준 설치의 원본 전체 hash는 출처로 남길 수 있지만 매 실행의 측정값으로 보고하지 않는다.
`CandidateStoreSha256`를 실행 시 계산할 요구는 제거한다. receipt는 검증 범위를
`patched_ranges`로 명시하고, 전체 파일을 검사했다는 기존 v1 의미를 재사용하지 않는다.
처음 v2를 도입할 때 필요한 기준 등록/전체 확인은 명시적 설치 작업으로 처리한다.

동일 store의 변경 소유 슬롯을 실행 UID와 결박한다. 별도 서비스는 만들지 않고 기존
coordinator/cleanup의 직렬화와 영속 상태를 활용한다. 실행별 기록만으로 다른 실행과의
충돌을 판단할 수 없다면 최소한의 공통 store 상태 파일을 둔다.

상태는 `prepared → applying → applied → restoring → restored`다. 쓰기 전에 원복 입력과
의도를 영속화하고, 실제 byte를 확인한 뒤 완료 상태를 원자적으로 기록한다. 적용 완료와
게임 실행 성공은 별개다. 상태 파일이 말하는 내용과 실제 조각이 충돌하면 성공으로 넘기지 않는다.

**완료 조건:** 정상/중단/재시도의 판정표와 v1/v2 receipt 의미를 확정하고 synthetic fixture로
검증한다. 현재 설치 파일과 과거 봉인 receipt는 수정하지 않는다.

## R2. 작은 조각 트랜잭션 구현

모든 조각의 위치/길이/비중첩/전후 hash와 현재 byte를 **첫 쓰기 전에** 확인한다.
동일 핸들로 지정 범위만 적용하거나 복구하고, flush 후 같은 범위를 다시 읽어 확인한다.
정상 작업량은 CDB 전체 크기가 아니라 변경 조각 합계에 비례해야 한다.

| 현재 상태/요청 | 동작 |
| --- | --- |
| 동일 실행, 원본 조각 → 적용 | 적용 의도 영속화 후 목표 조각 쓰기·검산 |
| 동일 실행, 이미 목표 조각 → 적용 재시도 | 일치하는 소유권/작업 기록 확인 후 중복 쓰기 생략 |
| 동일 실행, 적용/원복 도중 중단 | 유효한 사전 기록이 있고 각 byte가 봉인한 전후 값에 속하면 요청 방향으로 수렴 |
| 동일 실행, 이미 원본 조각 → 복구 재시도 | 반복 복구 완료; 불필요한 쓰기 생략 |
| 미적용 prepared 작업 → 종료 | 원본 조각 확인 후 쓰기 없이 종료 |
| 다른 실행이 store를 소유 | 새 적용/원복 거절; 기존 실행 복구 완료 후 재요청 |
| 완료한 이전 실행의 늦은 cleanup | 이전 완료 증거로 응답하거나 stale 요청 거절; 새 실행의 조각을 읽어 판정/원복하지 않음 |
| 신원/길이 불일치, 원복 입력 결손, 제3의 byte | 첫 쓰기 전 거절하고 복구 필요로 표시. 무조건 원본 덮어쓰기 금지 |

혼합 byte는 동일 작업의 사전 기록이 있을 때만 알려진 중단 상태로 취급한다.
이 규칙이 임의 외부 변경의 원인을 증명하는 것은 아니다. 조각 밖 byte는 읽거나 쓰지 않으며
그 범위의 현재 무결성을 이번 트랜잭션이 보증했다고 주장하지 않는다.

**완료 조건:** 정상 왕복·중복 적용/복구·부분 쓰기·기록 직전/직후 종료·stale 요청·동시
소유 충돌을 검증한다. 쓰기 거절 사례는 실제 쓰기 0회여야 한다.

## R3. Stage·runner·cleanup의 공통 연결

Stage에서 v2 manifest와 작은 원본/목표 조각만 생성한다. native 보정이 없는 입력은
기존처럼 FX 트랜잭션 자체를 만들지 않는다. 적용은 서버/게임 시작 전, 원복은 기존
Job 종료 증거 확인 후에 실행한다. Cold/파일 신원/실행 UID/목표 속성 결박을 유지한다.

새 reader는 v1/v2를 명시적으로 분기한다. 신규 v2 실행에서 오류가 나면 조용히 v1 전체
검산으로 fallback하지 않는다. 과거 v1 실행은 그 실행의 봉인 helper/계약으로 복구한다.
v2에 대한 cleanup·Job checkpoint·receipt pin 소비자도 함께 수정하여 의미를 일치시킨다.

**완료 조건:** 정상 coordinator→apply→restore 전체에서 CDB 범위 밖 읽기/쓰기 0.
전격·수냉 원본 재사용과 세 보정 입력, S26 및 새 보스를 표현하는 합성 profile에 동일 경로 적용.
새 보스 전용 준비/복구 스크립트가 필요하지 않아야 한다.

## R4. UI 상태와 시간 계측

실행 허용을 결정하는 기존 상태와 사용자에게 보여 줄 진행 단계를 구분한다. 기존 잠금과
상태 소유 주체를 사용하며 준비/적용/게임 프로세스 생성/게임 종료/FX 복구/진행도 저장을
실제 증거에 따라 갱신한다. 게임 프로세스 생성과 화면 로딩 완료를 같은 시각으로 보고하지 않는다.

게임 종료가 확인되면 다음 UI 조회에서 「게임 실행 중」을 끝내고 실제 남은 처리만 표시한다.
시작 버튼은 FX 복구·진행도 저장 완료 후 활성화한다. 30초 건강 관측은 화면에 별도로
반영하며 그 대기를 성능 개선으로 계산하거나 표시만 빨라진 것을 실제 시작 단축으로 보고하지 않는다.

측정점은 UI 요청 전후, API 준비/계정 snapshot, Stage, native apply, 서버/게임 생성,
게임 종료, restore, 진행도 저장, 최종 재실행 가능이다. 누적 시간과 구간 시간을 함께 남긴다.

**완료 조건:** 종료 후 정상 경로에서 다음 상태 poll(현재 최대 약 3초)에 실행 종료 표시.
실패/복구 필요는 성공/완료로 표시하지 않으며, 중복 버튼 요청도 기존 실행 소유권으로 직렬화한다.

## R5. 기능·성능 회귀 검증

1. 조각 트랜잭션 단위 검사: 위 R2 판정표와 매 byte/조각 경계의 중단 주입.
2. 읽기/쓰기 계량 Stream 검사: 작은 파일과 논리 길이가 큰 가상 Stream에 동일 조각을
   배치하고 범위 밖 접근 시 즉시 실패. 검사 때문에 새 6.6GB 디스크 파일을 만들지 않는다.
3. 공통 통합 검사: 다섯 속성, 원본 재사용, 서로 다른 profile/실행 UID, S26 회귀,
   이전 실행 cleanup과 다음 실행의 충돌, 앱 재시작 후 알려진 작업 재개.
4. 저장소가 요구하는 repository/Phase 0/2A1/2A2/2B/3A/3B0/3B1/3B2/Actions gate와
   영향받은 API/UI 검사를 실행한다. 실게임 증거를 합성 검사로 대체하지 않는다.

성능 합격 기준은 정상 CDB 전체 읽기 0회, 범위 밖 내용 읽기/쓰기 0, 조각 크기에 비례하는
작업량이다. 정상 적용/원복 각각 작은 조각 전후 확인을 기본으로 **읽기 최대 2B, 쓰기 최대 B**를
목표로 잡는다(B는 선택 조각 byte 합계). 중단 복구의 추가 범위 재확인은 별도 계수한다.
기존 24,153B 조각 사례라면 정상 연산당 CDB 읽기는 약 48KB 수준이며 전체 6.6GB와 무관하다.
이 byte 예산은 구현 검사로 확인할 목표이지 측정 완료 수치가 아니다.

별도 process 기동 포함/미포함 시간을 나누고 반복 표본 수와 p50/p95를 기록한다.
정상 준비 및 FX 적용/원복 각각 p95 5초 이내를 우선 목표로 하며, 실제 시작 총시간이
여전히 길면 관측된 공통 구간 순으로 추가 최적화한다. 현재 비보정 실행 약 28초와 비슷한
수준으로 돌아갈 여지는 있지만 총 시작 시간을 미리 보장하지 않는다.

## R6. 설치와 운영자 확인

전체 검사 통과 후 현재 설치를 보존한 새 공통 bundle을 만들고, 정확한 포인터·파일 pin과
원복 명령을 준비한다. 운영자가 확인한 정상 v8을 덮어쓰지 않는다. 기존 레지스트리/조립기에
새 계약을 연결하되 필요한 배포 파일만 갱신하고 계정·음성·FX 조립 결과를 바꾸지 않는다.

설치 전 미완료 실행이 없음을 확인하고, 설치 후 S26/다섯 속성 준비 검사를 수행한다.
새 기준 등록을 사용하는 **실제 전체 준비 경로**도 반복 측정해 p50/p95와 표본 수를 남긴다.
R5의 합성 Stage/범위 트랜잭션 측정을 전체 준비 경로의 5초 목표 달성으로 대신하지 않는다.
게임은 운영자가 실행한다. 원본 FX 1종과 보정 FX 1종으로 시작/종료 시간과 재실행을 먼저
확인하고, 나머지 보정 FX 및 S26을 확인한다. 기존 전체 쉴드 인수를 자동으로 무효화하지 않는다.
설치 후 중단 복구 검사에 실제 client 강제 종료가 필요하다면 정상 확인과 분리해 명시적으로 계획한다.

완료는 구현·자동 검사·설치·운영자 실제 실행 확인을 구분하여 기록한다.
Git 커밋/push는 기존 운영자 지시대로 나중에 한다.

## 착수 순서

**R1 → R2 → R3 → R4 → R5 → R6.** 첫 구현 단위는 R1/R2이며, 변경 계약과 작은 조각
트랜잭션을 먼저 완성한다. R3 이후에야 실행 경로의 성능이 바뀌며 R6 이전에는 설치 완료로
안내하지 않는다. 긴 ETW/HTTP/provider 조사로 다시 우회하지 않는다.

## R1/R2 구현 기록 — 2026-09-15

- [v2 계약](../../contracts/COMMON_BOSS_EXECUTION.md)에 설치 기준·작은 변경 입력·영속 상태·receipt의
  의미를 명시했다. `CandidateStoreSha256` 없이 `patched_ranges` 범위만 보고한다.
- `tools/NikkeLocalLab.PhaseD.RuntimeMaterializer/NativeFxRangeTransaction.cs`와
  `NativeFxRangeJournal.cs`를 추가했다. `Prepare`는 CDB를 열지 않고 원복 조각을 영속화한다.
  공통 store 잠금, 원자 상태 게시, 파일 신원/길이·모든 조각 검산, 적용/복구, 재시도를 구현했다.
- 완료 receipt와 소유 슬롯 해제를 같은 상태 파일 교체에 포함했다. 늦은 이전 cleanup은
  `Historical=true`로 과거 완료를 반환하며 새 실행의 CDB를 열지 않는다. 완료한 실행의 원복
  byte는 공통 journal에서 제거하고 작은 완료 receipt만 보존한다.
- 기존 `UserValidationStoreTransaction` v1 코드는 변경하지 않았다. 공통 실행기 Stage/apply/
  cleanup 역시 아직 v1을 사용한다. 이번 코어 검사 결과를 설치된 게임 시작/종료 시간으로
  보고하지 않는다.

집중 검사: `NativeFxRangeTransactionTests` **87개**, 기존 v1 **69개**, 합계 **156개 통과**.
12B 두 조각의 매 byte 중단 위치 0~12 × 적용/복구 중단 × 양방향 재개 52개 조합,
각 상태의 저장 직전/직후 실패 10개, 서로 다른 실행의 충돌·이전 cleanup, 신원/입력 결손,
제3의 byte·flush/readback 실패, 실제 작은 파일의 독점 핸들·재개를 포함한다.
논리 길이가 큰 Stream은 선택 byte만 메모리에 보유하고 범위 밖 접근을 즉시 실패시킨다.
검사 때문에 큰 CDB나 client 복제본을 생성하지 않는다.

| 24,153B 합성 조각, CDB 논리 길이 100,000B / 6,574,364,321B | CDB 읽기 | CDB 쓰기 |
| --- | --- | --- |
| Prepare | 0B, 파일 열기 0회 | 0B |
| 정상 적용 / 정상 복구 각각 | 48,306B | 24,153B |
| 중복 적용 | 24,153B | 0B |
| 완료한 실행의 반복 복구 | 0B, 파일 열기 0회 | 0B |

조각 밖 변경은 읽거나 복구하지 않고 보존하는 것을 확인했다. 이 표는 트랜잭션 코어의
계량 결과이며 process 기동·실제 디스크 시간 p50/p95나 UI 구간 성능을 측정한 값이 아니다.
검사 로그와 TRX: `artifacts/runtime-fast-path-20260915/`.

회귀 결과: 작업 전후 repository/Phase 0/2A1·2A2·2B 단위 검사/3A·3B0·3B1·3B2 역사 계약/
Actions 계약 통과. 2A1·2A2는 `verify-phase2b.ps1`의 선행 검사 체인으로 실행했다.
작업 후 별도 합성 PostgreSQL 통합 **114개**와 DB 재시작 checkpoint·정리까지 통과했고,
.NET 10 공통 materializer 빌드도 경고/오류 0개다. 최초 DB 실행은 sandbox token으로
pg_ctl이 실패하여 기존 합성 검사 스크립트를 sandbox 밖에서 재실행했다. 운영 DB는 사용하지 않았다.
DB 결과는 `artifacts/stabilization/lifecycle-postgresql/0e16b762a4ad4e13a40d98509371301a/receipt.json`에
보존했다. 실제 설치·게임 실행·commit/push는 수행하지 않았다.

R1/R2 완료 당시 다음 단위인 R3에서는 설치 기준 등록·물리 store별 고정 journal 선택·동일 핸들의 파일 신원·cold/
Job 종료 검사·실행 manifest/receipt pin을 실제 공통 경로에 결박한다. v1 복구를 보존하고,
오류 때 전체 CDB 검산으로 자동 fallback하지 않는다.

## R3 구현 기록 — 2026-09-15

`CommonBossDelivery.Stage` → `NativeFxExecutionDelivery` → 범위 코어를 공통 적용/종료에
연결했다. `CommonNativeFx`, `ExecutionAssetRetirement`, `Nll.PhaseDJob.ps1`의 dispatch와
퇴역/checkpoint 소비자도 v2를 구분한다. 기존 v1 계약·봉인 helper 복구는 보존했다.
공유된 작은 파일 pin/읽기 함수는 `CommonDeliveryFiles.cs`로 옮겨 같은 코드로 검사한다.

Stage의 전체 CDB Prepare와 후보 전체 SHA 계산을 제거했다. Stage는 원복 조각과
manifest만 영속화하며, store 소유권은 적용 직전 또는 미적용 종료에 확보한다. 준비 실패가
슬롯을 남기지 않게 한 선택이다. v2의 실제 FileStream은 버퍼를 꺼 선택 조각 주변의
1MiB 선행 읽기도 방지한다. 전체 검산은 별도 설치 등록 명령에만 있고 정상 경로에서 호출하지 않는다.

`CommonNativeFxBaseline`은 등록·journal 경로를 모든 profile/bundle에 공통으로 고정한다.
새 설치 등록 명령과 정상 준비기의 작은 등록 확인을 추가했다. 등록·설치 자체는 R6이며
이번에는 실행하지 않았다. 따라서 활성 v8의 실제 시작/종료 시간은 아직 바뀌지 않았다.

집중 검사 **199개 통과**: 신규 공통 전달 43개, R2 87개, 기존 v1 69개.
서로 다른 합성 profile(26/29/41 라벨) × 다섯 약점 15개 조합, 원본 재사용의 null 전달,
준비 후 취소, Job/pin 검사 실패 지점 10개, 잘못된 manifest/조각/등록·journal 경로,
서로 다른 실행의 충돌, 과거 cleanup, 종료 증거·검증 범위 위조 거절을 포함한다.
이 라벨은 실제 시즌 자산/전투 인수나 실제 coordinator 전체 실행을 대신하지 않는다.
현재 설치와 게임을 사용하지 않고 공통 전달 함수를 직접 호출한 합성 검사다.

6,574,364,321B 논리 CDB의 60B 두 조각으로 Stage 열기/읽기 0회, 정상 적용·복구 각각
읽기 120B/쓰기 60B, 늦은 과거 cleanup의 열기/읽기/쓰기 0을 확인했다. 범위 밖 접근은
검사 Stream에서 즉시 실패한다. 이 수치는 CDB Stream 요청량이며 OS 캐시/디스크 물리 I/O나
실제 process 기동 시간을 측정한 값이 아니다. 큰 파일 복사본은 생성하지 않았다.

Windows Job 검사 **55개 통과**에는 v2 퇴역/checkpoint 소비자용 새 메타데이터 검사 10개가
포함된다. .NET 10 materializer 빌드는 경고/오류 0개다. 작업 전후 repository/Phase 0/
2A1·2A2·2B 단위/3A·3B0·3B1·3B2 역사 계약/Actions 계약도 통과했다. 별도 합성 PostgreSQL
통합 **114개**와 DB 재시작 checkpoint·정리까지 통과했다. 결과와 로그는
`artifacts/runtime-fast-path-r3-20260915/`에 보존한다. DB 증거는
`artifacts/stabilization/lifecycle-postgresql/5c7968af2a344d08a4588f174f22b1a2/receipt.json`이다.
설치 기준 결손 및 코어의 거절 사유는 관리된 `phase_d_` 진단 코드로 전달한다.
실제 설치·baseline 등록·게임 실행·commit/push는 수행하지 않았다.
다음 구현 단위는 R4의 UI 상태와 구간 계측이다.

## R4 구현 기록 — 2026-09-15

실행의 `draft/validated/started/completed/failed/rolled_back` 및 소유권 판정은 유지했다.
진행 표시·계측만 실행 폴더의 `execution-progress.json`
(`nll/phase-d-execution-progress/v1`)으로 분리했다. 기존 API의 `progress` 필드로 전달하며,
UI는 같은 3초 조회에서 종료·정리 단계를 표시한다. `progress.ready`만으로 버튼을 활성화하지
않는다. 실제 FX 복구와 PostgreSQL 진행도 저장 후 기존 terminal 상태가 게시되어야 한다.

| 기록점 | 기록 주체·근거 |
| --- | --- |
| UI 요청 직전/응답 수신 | `editor.js`의 UTC 두 시각 및 `performance.now()` 차이. 해당 실행 상세 JSON의 `uiRequestTiming`에 유지 |
| API 준비/계정 snapshot | `PhaseDExecution.cs`에서 호출 경계 기록. 초기 승인 응답과 파일에 포함 |
| Stage/실행 환경 준비 | 공통 coordinator의 Stage 진입 및 반환 경계 |
| native apply/서버 생성 | runner의 적용 진입, 서버 Start 호출 및 검증한 Process.StartTime |
| 리소스/게임 생성 | 기존 리소스 검사 진입, bootstrap 시작, SAIL receipt 후 살아 있는 게임의 Process.StartTime |
| 30초 관찰/실행 중 | 기존 30초 health 구간 진입 및 통과. 화면 준비 완료 증거로 사용하지 않음 |
| 게임 종료 | watcher의 프로세스 identity 확인 및 WaitForExit 반환/이미 종료 확인. 느린 정리 전 게시 |
| 정리/FX 복구/환경 복구 | Job 종료, 공통 FX cleanup, completion 호출 직전 |
| DB 재시작/진행도 저장 | pg_ctl과 기존 persistence 호출 경계 |
| 최종 완료 | 저장 후 finalizing, 기존 terminal 게시 및 pending 제거 후 ready |

`events[]`는 `stageCode`, `occurredAtUtc`, `observedAtUtc`, `cumulativeMilliseconds`,
`intervalMilliseconds`를 남긴다. 누적은 API 요청 수신 기준, 구간은 직전 기록의 발생 시각과
차이다. 각 단계의 소요 시간은 그 진입과 다음 단계 진입의 차이로 읽는다. 게임 생성 시각은
receipt 수신 뒤 Process.StartTime을 소급 기록하므로 관측 시각과 구분한다. 종료 시각은
**watcher가 확인한 시각**이며 kernel ExitTime이나 화면 소멸 시각을 측정한 것으로 취급하지 않는다.
늦게 도착한 기록의 음수 차이는 0으로 제한하며 원래 UTC 두 시각을 함께 보존한다.
UI의 요청 후 누적 시간에는 게임 플레이 시간이 포함된다. 이를 시작 지연으로 합산하지 않는다.

진행 기록은 기존 `execution-state.lock`을 이용해 원자 교체한다. 표시용 잠금 대기는
최대 250ms이며 오류는 실행·복구를 중단하지 않는다. 입장 상태 쓰기의 기존 10초 제한은
유지한다. 최고 진행 단계는 되돌리지 않으므로 늦은 시작 기록이 종료를 실행 중으로 바꾸지
못한다. 누락된 과거 계약은 기존 표시, 손상된 기록은 진행 정보 확인 필요로 표시하고 GET이나
입장 상태를 바꾸지 않는다. 최대 128개 이벤트/128KiB를 읽으며 새 상주 프로세스는 없다.
UI 요청 계측은 해당 페이지 메모리와 상세 JSON에 있으며 새로고침 후 복원하지 않는다.
서버 단계 기록은 실행 폴더에 보존된다. 세션을 넘어 성능 표본을 수집할 때는 두 자료를 함께 저장한다.

소스·합성 검사의 범위다. 활성 v8을 설치 갱신하지 않았으며 실제 시작·종료 단축 또는
실게임에서 3초 내 UI 반영을 측정 완료했다고 주장하지 않는다. 해당 설치·측정은 R5/R6에 남는다.

**R4 구현·자동 검사 완료.** API 단위 562개(신규 진행 조회 7개 포함), 실행 상태 UI 9개,
기존 lifecycle UI 검사, runner Start/Complete·Job·공유 상태·복구 DB 회귀가 통과했다.
새 `test-nll-phase-d-progress.ps1`은 WinPS5와 PS7에서 실제 원자 파일 쓰기·동시 두 writer·
늦은 시작 기록·잠금 경합·손상 기록·watcher 종료 확인 코드를 합성 입력으로 검사했다.
identity 불일치 시 종료 기록이 게시되지 않고 입장 상태 파일이 그대로임도 확인했다.
이 검사는 기존 `verify-phase2a2.ps1`의 Windows gate에 연결했다.

repository/Phase 0/2A1·2A2·2B 단위/3A·3B0·3B1·3B2 역사 계약/Actions 계약 최종 검사 통과.
별도 합성 PostgreSQL 통합 114개와 재시작 checkpoint·종료·정리도 통과했다. 증거는
`artifacts/stabilization/lifecycle-postgresql/5257ef4bb9e342f5bfa4be0ea20ca1c5/receipt.json`이다.
작업 중 실패 로그와 최종 재검사 로그를 `artifacts/runtime-fast-path-r4-20260915/`에 보존했다.
Phase 2B의 최종 결과 파일은 `final-verify-phase2b.ps1.log`다.
계측 때문에 바뀐 테스트 입력/함수 의존을 보완했고 기존 cleanup 실패·잠금 단언은 유지했다.
게임·운영 DB·음성·속성 쉴드·활성 v8 설치는 변경하지 않았으며 commit/push도 하지 않았다.
다음 단계는 R5의 공통 기능·성능 회귀 검증이다.

## R5 오프라인 회귀·성능 기록 — 2026-09-15

R2/R3의 기존 byte 중단·publication 실패·잘못된 입력 거절·5약점/서로 다른 profile·과거
cleanup/새 실행 충돌 검사를 재사용한다. 기존 199개(범위 코어 87, 공통 전달 43, v1 회귀 69)는
작은 Stream과 **6,574,364,321B 논리 길이의 가상 Stream**에서 범위 밖 접근을 즉시 거절한다.
R5 때문에 큰 CDB 파일이나 client 복사본을 만들지 않는다.

기존 `NikkeLocalLab.Materializer.BehaviorChecks`에 `--native-fx` 모드를 추가했다.
`NativeFxRangeTransaction`, `NativeFxRangeJournal`, `NativeFxExecutionDelivery`,
`CommonDeliveryFiles`의 제품 소스를 직접 링크한다. 별도 구현의 속도를 측정하지 않는다.
다만 설치 등록·물리 파일 identity·Job 검사는 합성 adapter이고 원본 runtime 전체를 실행하지 않는다.

- **52개 process 중단/복구 조합:** 두 조각 합계 12B의 모든 byte 경계 0~12에서 적용/복구를
  중단하고, 각각 적용/복구 방향으로 새 process에서 재개한다. 부분 쓰기는 flush한 뒤
  `Environment.Exit(73)`으로 finally/Dispose 없이 끝낸다. journal을 재생성하거나 초기화하지
  않는다. 이 검사는 process 종료 후 복구이며 저장 장치 전원 손실을 입증하지 않는다.
- **15개 profile/약점 조합:** 26/29/41의 합성 profile 라벨 × 5약점을 실제 64KiB 합성 파일과
  별도 process에서 실행한다. 약점 `electric/iron`은 대상 보스 속성 `water/electric`의 원본
  재사용을 나타낸다. 적용 직후 목표 byte, 복구 후 전체 작은 파일의 원본 일치, 반복 cleanup의
  실제 열기/읽기/쓰기 0을 확인한다. 실제 시즌 41 데이터나 전투 인수를 주장하지 않는다.
- 계량 Stream은 실제 FileStream(bufferSize 1)에 전달하기 전에 범위를 확인하고 요청 byte를
  집계한다. Flush는 디스크 flush로 전달한다. 정상 적용/복구는 합계 24,153B의 두 조각에
  읽기 **48,306B**, 쓰기 **24,153B**, 열기 1회이며 Stage는 모두 0이다.
- 비교용 합성 파일 생성·기준 등록·원본 hash·작은 파일 전체 정답 비교는 시간 측정 밖이다.
  측정한 Stage/적용/복구 안에는 제품 코드의 작은 입력 검증·journal·receipt 게시·flush가
  포함된다. CDB 내용의 정상 전체 읽기나 범위 밖 내용 접근은 없다. 물리 SSD I/O 계수가 아니다.

최종 측정은 `artifacts/runtime-fast-path-r5-20260915/measurement-2/receipt.json`이다.
각 행 30회, 총 240개 표본이며 p50/p95는 정렬 후 nearest-rank 방식이다. 동일 process는
warm-up 1회 후 실행한다. 새 process의 함수 시간은 JIT 등의 영향을 포함하며, process 포함
시간은 부모가 Process.Start 직전부터 종료까지 잰 값이다. Windows 10.0.26200 / .NET 8.0.14,
같은 호스트의 필수 회귀·합성 DB 검사와 겹친 측정이다. 독점 CPU나 OS cold-cache 결과가 아니다.

| 처리 | 같은 process 함수 p50/p95 (ms) | 새 process 함수 p50/p95 (ms) | process 기동 포함 p50/p95 (ms) |
| --- | --- | --- | --- |
| 보정 조각 Stage | 18.95 / 25.01 | 48.59 / 60.64 | 185.92 / 222.25 |
| 적용 | 44.80 / 51.62 | 96.23 / 124.50 | 233.61 / 313.13 |
| 복구 | 42.37 / 44.59 | 91.44 / 119.32 | 229.63 / 311.62 |
| 원본 재사용 Stage | 2.93 / 3.39 | 10.32 / 13.35 | 150.24 / 181.37 |

측정된 합성 공통 전달 작업은 process 포함 **모든 표본이 5초 미만**이다. .NET 10 실제
materializer의 전체 기동·공통 준비기·registry/profile/candidate 검사·Job/게임/DB 수명주기는
이 숫자에 포함되지 않는다. 특히 R3에서 기준 등록을 R6으로 미뤘으므로 새 설치 기준을 요구하는
전체 준비 `ready` 경로의 p95 5초 목표는 **미측정**이다. 설치/기준 등록 뒤 R6에서 측정한다.
이 선후관계를 숨기거나 합성 Stage 시간을 전체 준비 시간으로 승격하지 않는다.

재실행 명령은 빌드 후 다음 형태다. 출력 디렉터리는 존재하지 않는 새 경로여야 한다.

```powershell
dotnet tests/NikkeLocalLab.Materializer.BehaviorChecks/bin/Release/net8.0/NikkeLocalLab.Materializer.BehaviorChecks.dll --native-fx <새 절대 출력 경로> 30
```

전체 경계/조합 검사는 `verify-phase2a2.ps1`에도 연결하며 CI에서는 시간 표본만 5회로 줄인다.
실험 중 생성한 합성 작업 폴더는 완료 후 제거하고 receipt/작은 실행 로그만 남긴다.
R4의 진행 기록 검사는 250ms 잠금 상한에서 표시 기록을 생략할 수 있는데도 동시 기록을
항상 17개로 가정하던 단언을 정비했다. 동시 원자 기록과 순차 종료→늦은 시작의 비역행을
각각 확인하며 기존 실행 잠금이나 250ms 상한을 변경하지 않았다.

**R5 오프라인 검증 완료:** repository/Phase 0/2A1·2A2·2B 단위/3A·3B0·3B1·3B2 역사 계약/
Actions 계약 최종 검사가 통과했다. API 단위 562개, 기존 UI 9개, 새 process 검사와 기존
runner/Job/공유 상태 검사를 포함한다. 정비한 진행 기록 검사는 WinPS5와 PS7 모두 통과했다.
별도 합성 PostgreSQL 통합 114개와 재시작 checkpoint·종료·정리도 통과했다. DB 증거는
`artifacts/stabilization/lifecycle-postgresql/df541e646a184b52baa05d99b4da047b/receipt.json`이다.
소스·검사기 assembly·측정 receipt SHA-256은 `measurement-provenance.json`, 최종 전체 검사
로그는 같은 R5 폴더의 `after-*`다. 초기 실패 로그는 보존한다. 사용한 합성 작업 폴더는
제거했으며 두 번의 30회 계측과 로그·출처 기록은 약 150KiB다.

R6에 남은 것은 새 bundle/기준 등록·선택 포인터 설치, 실제 전체 준비 경로의 반복 측정,
운영자의 게임 시작/종료·쉴드·진행도/재실행 확인이다. 활성 v8·게임·음성·운영 DB를 변경하지
않았으며 commit/push도 하지 않았다. 전체 준비 p95 및 실제 게임 총시간의 개선은 아직 미확인이다.

## R6의 30초 관찰 검토 — 2026-09-15

운영자의 질문에 대한 결론은 **게임 실행에 고정 30초 대기는 필요하지 않다**이다.
현재 `Nll.PhaseDRunnerStart.ps1`은 서버 준비와 SAIL/bootstrap receipt, 실제 게임 프로세스
생성을 확인한 **뒤** 30초 동안 세 프로세스 생존·클라이언트 Responding·비 loopback TCP
연결을 반복 조사한다. 따라서 이 구간이 게임 프로세스 생성 자체를 지연시키지는 않지만,
시작 receipt 확정과 coordinator의 종료 watcher 인계를 지연시킨다. 이 구간에서 사용자가
게임을 종료하면 정상 종료 인계 전에 시작 실패 경로로 들어갈 수도 있다.

이 시간은 화면 로딩 완료나 이후 전체 실행의 안정성을 입증하지 않는다. 외부 연결 차단은
기존 방화벽 규칙의 역할이며 유한 표본 관찰이 그 차단을 대신하지 않는다. 정상 경로는 이미
확인한 서버/bootstrap 준비·게임 process identity와 필수 격리 검사를 근거로 종료 watcher에
즉시 인계하는 방향이 맞다. 30초 표본 수집이 필요하면 별도 진단으로 제공한다.

이번 R6에서는 R1~R5를 검증한 상태로 설치하며 고정 관찰 동작을 아직 변경하지 않는다.
후속 변경은 공통 runner 한 곳에서 수행하고, 기존 start/v9 receipt의
`thirtySecondMeasurementCompleted`, 최소 표본 수/경과 시간 필드를 사실에 맞는 새 계약으로
정비한다. sleep만 없애고 30초 측정 성공을 기록해서는 안 된다. coordinator 인계 직전 종료,
bootstrap 실패, network 검사 실패, watcher 생성 실패의 cleanup/소유권 회귀를 함께 확인한다.
시즌·보스·약점별 예외는 추가하지 않는다. 변경 뒤에도 게임 생성과 화면 로딩 완료는 구분한다.

## R6 설치·실측 기록 — 2026-09-15

v8을 보존한 `C:\NLL\Runtime\PhaseD151-v9`를 설치했다. 기존 서버/bootstrap/cache를 그대로
복사하고 공유 .NET 10 방식의 materializer 네 파일만 교체했다. 새 6.6GB CDB 복사본은 만들지
않았다. UI/API의 R4 진행 표시도 함께 설치했다. 기존 보스 registry, 보스 추가 작업 이력 경로,
계정·음성·FX 조립 결과는 유지했다. 작업 파일과 private 증거는
`artifacts/runtime-fast-path-r6-20260915/`에 보관한다.

| 설치 권위 | SHA-256 |
| --- | --- |
| 새 v9 bundle | `a5507bf96c5dd3402215e47d7b2e40194b66052791df41f953f3ed6dcd829cc2` |
| 설치된 runtime selection | `d151bcb163a57a5c8988ef8d220a1b9876ef3847b86ef05918fd773e7955170f` |
| 원복 v8 bundle | `ebf9338714d678a5d5bc88396a259627c878a33b4b36f2ff65296a78781213c7` |
| 원복 selection | `678517591df02c34356fa8c646d9aaa43ee525cca9fd4adf2d7d193b9401c626` |
| 최종 앱 delivery plan | `7883cfb2380e1c008e6528f733d2e469d04d179e12f6a5a0eda8bd95c8444535` |
| 공통 baseline registration | `ca4d234aaea2ecefdd71442a387d7754a214901100b866b6b7a3cc8e97670168` |

현재 selection은 `C:\NLL\ControlCenter\runtime-selection.private.json`이다. 활성 pipeline은
같은 artifact 루트의 `pipeline-preserved-history/configuration.private.json`을 가리킨다.
초기 생성된 `pipeline/`과 `delivery/`는 미설치 준비 이력이며 최종 계획은 `delivery-final/`이다.
버전 갱신 때문에 기존 UI 보스 추가 이력이 사라지지 않도록 jobsRoot를 유지해 다시 봉인했다.

설치 직전 운영 실행 기록 60건이 모두 terminal이고 살아 있는 game/server/controller,
active-run pointer, pending payload가 없음을 확인했다. maintenance lock과 앱 pending 표식으로
적용을 보호했다. 앱 전체의 적용→재적용→복구→재복구 예행 검사가 통과했으며, v8 selection과
앱 before 파일을 남겼다. 설치 뒤 전체 앱 inventory·시작 스크립트·pipeline activation·bundle·
client/shim/certificate·기존 outbound 차단 핀을 다시 확인했다. 시스템 차단 규칙은 변경하지 않았다.

**최초 등록:** 원본 `store.cdb` 6,574,364,321B의 기존 SHA-256을 한 번 읽어 확인했다.
약 **47.34초**, CDB 쓰기 0B였다. 등록과 journal은
`C:\NLL\RuntimeInputs\CommonBossExecution\native-fx` 아래의 작은 두 파일이다.
정상 준비/적용/종료에서 이 등록 명령을 다시 실행하지 않는다.

**실제 준비 반복 측정:** 새 pwsh 기동부터 `get-nll-phase-d-preparation.ps1` 반환까지 측정했다.
실제 선택 포인터·bundle/profile/delivery 핀·materializer 검증·baseline 등록 확인을 모두 포함한다.
계정 snapshot·coordinator Stage·DB/서버/게임 기동은 별도 구간으로 포함하지 않는다.
각 조합 20회, 총 120회 모두 `ready`다. warm-up 제외 없이 첫 표본도 포함했고 nearest-rank를
사용했다. 전용 CPU나 OS cold-cache 실험은 아니다.

| 시즌 / 선택 약점 | p50 (ms) | p95 (ms) | 최대 (ms) |
| --- | ---: | ---: | ---: |
| S26 / 수냉 | 1276.56 | 1370.42 | 1393.43 |
| S29 / 작열 | 1757.16 | 1803.08 | 2066.66 |
| S29 / 수냉 | 1750.36 | 1807.23 | 1811.07 |
| S29 / 풍압 | 1752.38 | 1796.06 | 1875.40 |
| S29 / 전격 | 1749.37 | 1809.52 | 1844.68 |
| S29 / 철갑 | 1755.65 | 1796.62 | 1805.47 |

준비 p95 5초 목표를 충족했다. 측정은 활성화 전의 **동일한 v9 selection 바이트**로 수행했다.
설치 후에는 활성 selection을 통해 S26/S29 각각 다섯 약점, 총 10개 조합을 추가 확인했다.
이 결과를 게임 화면 로딩 시간이나 전체 실행 요청 시간으로 해석하지 않는다.

**실제 coordinator/조각 연결:** 기존 계정 DB에 명시적 읽기 전용 연결을 사용해 S26 수냉과
S29 다섯 약점의 `ValidateOnly` 여섯 조합이 `validated_not_started`로 통과했다. 이후 DB를
종료하고 기존 Job 증명을 사용해 세 보정 FX를 실제 ResourceProbe에 적용→복구→반복 복구했다.
세 조합 모두 `nll/common-native-fx-retired/v2`, `validationScope=patched_ranges`, `restored`를
확인했다. 원본 재사용의 두 약점은 execution FX가 없다.

| 선택 약점 → 보스 속성 | 변경 범위 (B) | 원복 읽기 (B) | 원복 쓰기 (B) |
| --- | ---: | ---: | ---: |
| 작열 → 풍압 | 23,563 | 47,126 | 23,563 |
| 수냉 → 작열 | 24,153 | 48,306 | 24,153 |
| 풍압 → 철갑 | 26,393 | 52,786 | 26,393 |

이 수치는 v2 FileStream 요청량이며 SSD의 물리 I/O 계수가 아니다. 각 조합의 Job 생성,
적용, 종료 증명, 복구와 반복 복구를 모두 합친 예행 검사 시간은 9/8/8초였다. 개별 적용/복구
p95나 실제 게임 종료 시간으로 사용하지 않는다. 원본 전체 재검산으로 원복을 판정하지 않았다.

원복은 관리도구와 게임이 종료되고 미완료 실행/복구가 없는 상태에서 다음 명령으로 수행한다.
selection을 v8로 되돌린 뒤 봉인한 기존 앱/시작 스크립트/pipeline을 복구한다. 성공한 baseline
등록은 삭제하지 않으며 v8은 이를 사용하지 않는다. source pin이 이후 변경되면 자동으로 거절하므로
핀 검사를 해제하지 말고 해당 원복 패키지의 출처를 확인한다.

```powershell
pwsh -NoProfile -File "C:\Users\nlloperator\Documents\Github\Nikke-Local-Lab\artifacts\runtime-fast-path-r6-20260915\install-or-restore.ps1" -Mode restore
```

**남은 인수:** 운영자가 원본 FX 한 약점과 보정 FX 한 약점으로 시작/종료·재실행·진행도 보존을
먼저 확인한다. 필요 시 나머지 보정 FX와 S26을 확인한다. 기존 쉴드 정상 인수는 유지한다.
게임은 실행하지 않았고 새 설치의 실게임 시간·화면·진행도 인수를 대신 주장하지 않는다.
고정 30초 관찰은 위 검토대로 아직 남아 있다. commit/push는 하지 않았다.

**설치 후 회귀 완료:** Phase 0, Phase 2B가 포함하는 Phase 2A1/2A2 단위·UI·공통
runner/Job/복구 검사, Phase 3A/3B0/3B1/3B2 역사 계약, repository/Actions 계약을 확인했다.
API 562개를 포함한 전체 단위 경로가 통과했다. 별도 합성 PostgreSQL 통합 114개,
새 v9 materializer의 실제 capture·persist·restore 합성 검사 41개와 DB 재시작 checkpoint,
종료·임시 cluster 정리도 통과했다. DB 증거는
`artifacts/stabilization/lifecycle-postgresql/b2cd681e72c949c28e15f5e036b3ef78/receipt.json`과
같은 폴더의 `runtime-persistence.receipt.json`이다. 운영자 계정의 실게임 진행도 인수를
이 합성 결과로 대신하지 않는다.

초기 repository 검사는 기존 origin이 있는 환경에 필요한 `-AllowRemote` 누락으로 실패해
해당 옵션으로 재검사했다. push나 원격 접속을 수행한 것은 아니다. 이미 통과한 단위 경로를
역사 계약에서 다시 실행하다가 `UserValidationExecutionTests` 합성 fixture 삭제의
`.ui-action.lock` 공유 위반이 한 번 관측됐다. 해당 클래스 18개를 별도로 3회 재검사해 모두
통과했으며 오류는 재현되지 않았다. 원인 확정이나 제품 코드 수정으로 해결했다고 주장하지 않는다.
중복 dispatcher/그 자식 검사만 종료하고 역사 단계의 지원 옵션 `-ContractOnly`로 모두
확인했다. 초기 실패/중지 로그는 보존하며 최종 근거는 R6 폴더의
`final-verification.receipt.json`으로 구분한다. 설치에 사용한 소스 snapshot은
`source-provenance.private.json`이며 서명된 build attestation은 아니다.

미사용 self-contained 초기 publish 153,182,281B는 R6 artifact 경계를 확인한 뒤 제거했다.
선택한 공유-runtime 빌드, v8 및 봉인한 app rollback 파일은 보존했다.
