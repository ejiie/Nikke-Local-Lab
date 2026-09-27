# 공통 보스 실행 입력·호환·상태 계약

2026-09-14 P1. [통합 계획](../operations/COMMON_BOSS_EXECUTION_PLAN.md)의 공통 입력 경계다.
실행기는 기존 wire와 수명주기를 재사용한다. P2-3에서 Transform 외 크기 입력과 원본 기반
recipe 결박이 필요해 profile v4를 추가했다. 문서·합성 검사만으로 설치나 실게임 인수를 주장하지 않는다.

## 입력 책임과 기존 계약

| 책임 | 재사용할 입력 | 검증 책임 |
| --- | --- | --- |
| UI 요청 | `BossOnboardingRequest`: operation, season, catalog hash | API가 요청 신원·재시도·중복을 검증 |
| 보스의 의미 | `BossRuntimeVariantProfile` | 원본 manager/Challenge·skill/behavior·속성·QTE/FX 참조와 각 버전 shape 검증 |
| 계정/진행도 | 기존 runtime candidate, account revision, raid snapshot | 선택 revision을 고정하며 보스 추가가 계정을 새로 만들지 않음 |
| 실행 준비 | `nll/phase-d-preparation/v1`, preparation binding | 요청·profile·bundle의 일치 및 필요한 입력이 준비됐는지 판정 |
| 실행 | 기존 LaunchContext와 `nll/phase-d-runner-input/v1..v3` | 공통 생성기가 완전한 입력을 생성·검증한 뒤 봉인 |
| 선택적 FX | 기존 `executionFx` 및 별도 변경/복구 manifest | 동일 profile·weakness·실행 신원 결박과 실제 전달 증거 필요 |
| 결과/복구 | 기존 Job/완료/복구 영수증 | 게임 종료·소유 자원 복구와 게임/FX 인수 결과를 별도로 판정 |

공통 입력은 사용자 음성 값을 변경할 명령을 포함하지 않는다. 계정·실행 디렉터리·
검증/운영 정책은 명시적 입력이며 시즌 번호로 다른 부팅기를 선택하는 근거가 아니다.
새 계정 요청과 기존 계정 선택은 구분한다. 검증 계정이 필요한 경우에도 같은 실행기에
명시적으로 전달하며 보스 추가의 기본 동작으로 계정 초기화/신규 등록을 하지 않는다.

## 독립된 두 버전 축

| 축 | 현재 해석 | 유지할 경계 |
| --- | --- | --- |
| profile v1 | 기존 기본 속성 변형, 실드 없음 | 기존 봉인 profile을 그대로 읽음 |
| profile v2 | skill/behavior closure 및 선택적 속성 실드 | 형식/내용 검증 후 의미 입력으로 사용 |
| profile v3 | 현재 QTE와 FX transform 정보를 함께 표현 | 현재 지원 범위만 정확히 수락; version 숫자로 부팅을 선택하지 않음 |
| profile v4 | 원본 속성 기반 크기 recipe·재사용/보정 자산 결박 | 전체 의미·후보 봉인·전달 descriptor 검증 필요; 같은 공통 실행기 사용 |
| runner input v1 | 기존 실행 입력 | 과거 봉인 실행/복구 호환 유지 |
| runner input v2 | weakness가 추가된 실행 입력 | profile 버전과 독립 |
| runner input v3 | weakness, Job nonce, 선택적 executionFx | 모든 보스가 동일 수명주기로 사용 가능 |

profile의 schemaVersion/contractId는 정확한 쌍이어야 한다. profile v3를 runner v3와
동일시하거나, runner v3가 profile v3/FX의 실행 수락을 입증한다고 해석하지 않는다.
profile의 이미 존재하는 검증을 생략하거나 버전 표기를 낮춰 호환시키지 않는다.

## 공통 생성기와 결박 규칙 — P1 구현

`New-PhaseDRunnerSpecification`이 제공된 필드로 기존 wire 계약을 선택한다.

- weakness가 없고 lifecycle/FX 필드도 없으면 기존 v1, weakness만 있으면 기존 v2다.
- jobNonce 또는 executionFx가 있으면 두 필드와 weakness가 모두 있어야 한다. 누락은
  `phase_d_runner_input_invalid`이며 조용히 버리거나 v1/v2로 낮추지 않는다.
- 완전한 lifecycle 입력은 v3다. executionFx는 명시적 null일 수 있다. 이는 해당 실행에
  전달된 FX 참조가 없다는 뜻이며 profile이 요구하는 FX를 생략해도 된다는 뜻이 아니다.
- executionFx가 있으면 기존 네 필드의 shape/hash를 검증하고 profileSha256과 weakness가
  바깥 실행 입력과 정확히 일치해야 한다. 다른 보스/profile의 FX를 끼울 수 없다.
- 생성된 결과를 호출자가 나중에 v3로 바꾸던 코드를 제거했다. coordinator는 nonce와
  명시적 null FX를 생성기에 전달한다. 반환 시 이미 검증된 완전한 입력이어야 한다.
- 시즌 번호를 바꿔도 생성기·engineCode·동일 bundle의 bootstrap 선택은 바뀌지 않는다.

이 생성기는 파일/게임을 읽거나 실행하지 않는다. profile 해석·내용 검증과 준비기는
각각의 증거를 확인해야 하며, shape가 맞는 실행 입력 자체는 실행 허가가 아니다.
과거 봉인 파일은 수정하지 않는다. 새 helper는 신규 실행 구성에 봉인하며 기존 복구는
그 실행에 봉인된 helper와 증거를 사용한다.

## P2-4/P2-5 공통 준비와 native 전달

선택 bundle의 `commonBossRegistryRoot`는 별도 봉인 registry를 가리킬 수 있다. 현재 허용한
로컬 경계는 `C:\NLL\RuntimeInputs\CommonBossExecution\profiles`이며, 미지정 시 기존 registry다.
registry와 선택 bundle은 준비 binding에 함께 결박한다. S26 기존 profile은 보존한다.
v4는 `nll/common-boss-delivery/v1` descriptor가 있어야 하며, 준비기는 실제 C# 의미 검증과
후보·recipe·native 조각 출처 검증을 수행한다. 버전 숫자만 허용하는 완화가 아니다.

조립 작업자는 같은 검증·publisher로 descriptor와 profile을 게시한다. 선택 속성이 원본 FX
재사용이면 추가 native 전달은 없다. 보정이 필요하면 coordinator가 실행별
`nll/common-native-fx-execution/v1` manifest와 원본/보정 조각을 만들고 기존 `executionFx`에
결박한다. profile·약점·후보 봉인·실행 UID가 일치해야 한다.

적용은 기존 공통 Job 내부에서 서버/게임 시작 전에 수행한다. 복구는 그 동일한 Job의
프로세스 수 0과 봉인된 종료 증거를 확인한 외부 소유자가 수행한다. 독점 파일 핸들,
원본/후보 전체 store 해시, 변경 범위와 조각 해시를 확인하고 기존 byte-range transaction을
사용한다. 새 Job 생성이나 영수증만으로 종료를 추정하지 않는다. 원본 재사용은 이 작업이 없다.
음성 설정을 쓰는 명령이나 시즌별 bootstrap 분기는 추가하지 않는다.

위 전체 store 검산은 **기설치 v1 계약**이다. 신규 빠른 경로 v2는 아래 범위 검증 계약을
사용한다. v1 reader나 과거 봉인 receipt의 의미를 바꾸는 것으로 v2를 구현하지 않는다.

## 정상 실행의 범위 검증 v2 — R1/R2

2026-09-15 운영자 요구에 따라 정상 실행/종료에서 전체 CDB 검산을 제거한다.
`nll/common-native-fx-execution/v2`의 조각 트랜잭션 코어는 다음 입력을 결박한다.

| 입력 | 의미 |
| --- | --- |
| `ExecutionUid` | 실행의 불변 UID. 완료한 UID를 새 적용에 재사용하지 않음 |
| `Baseline.InstallationId`, `Version` | 명시적 설치 검증에서 등록한 기준 설치와 버전 |
| `Baseline.Store.VolumeId`, `FileId`, `Length` | 실제 열린 독점 핸들에서 확인할 물리 파일 식별자와 길이 |
| `Baseline.OriginalSha256` | 설치 당시 원본의 출처. 이번 실행의 전체 측정값이 아님 |
| `ProfileSha256`, `RecipeSha256`, `CandidateSealSha256` | 선택 전투 입력, FX 조립 recipe, 후보 봉인 결박 |
| `Ranges[]` | offset, 동일 길이 Before/After, 각 내용 SHA-256. 원복 byte를 포함 |

코어가 복사·검산한 위 입력을 직렬화하여 `PlanSha256`으로 결박한다. 내용 hash는 작은
입력에만 적용하며 `CandidateStoreSha256`는 요구하지 않는다. 조각은 오름차순·비중첩이고
header 256B 뒤에 있어야 한다. 최대 32개, 각 16MiB, 합계 64MiB로 기존 쓰기 경계를 유지한다.
비교 전에 입력 배열을 복사하여 호출자가 배열을 바꿔도 검산한 원복 값이 바뀌지 않게 한다.

기준 등록은 설치 작업의 `RegisterVerifiedBaseline`에서만 허용한다. 기존 등록은 덮어쓰지
않고, 정상 Prepare/Execute에서 상태 파일이 없거나 깨졌으면 빈 store로 자동 초기화하지 않는다.
공통 coordinator가 **물리 store마다 하나의 고정 journal 경로**를 정한다. 실행 UID별로
서로 다른 journal을 선택하는 것은 금지다. 경로/ACL·reparse·hardlink 경계, 같은 핸들의 실제
파일 식별자, cold/Job 종료 증거, 봉인 manifest와 선택 속성 검증은 공통 호출자의 책임이다.
코어 자체의 성공은 게임 실행 허가가 아니며 아래 R3의 공통 호출자가 이 경계를 확인한다.

`nll/common-native-fx-range-ledger/v2`는 활성 실행 하나와 완료한 실행의 작은 receipt만
저장한다. 활성 작업의 원복 byte와 `PlanSha256`을 함께 저장하고, 완료 시 원복 byte를 ledger에서
제거한다. 별도 서비스는 만들지 않는다. 고정 lock 파일의 `FileShare.None`으로 읽기부터
최종 게시까지 직렬화한다. lock 파일을 매번 지워 재생성하지 않는다. 같은 디렉터리 임시 파일에
새 상태를 쓰고 disk flush 후 원자 교체한다. 완료 기록과 소유 슬롯 해제는 **같은 교체**에 포함한다.
완료 receipt를 보관하므로 이전 실행의 늦은 cleanup은 새 CDB를 열지 않고 과거 완료를 반환한다.
이 보존 기록을 정상 실행 중 전체 원복 조각의 누적 보관으로 확대하지 않는다.

| 영속 상태 | 허용하는 현재 조각 | 적용/복구 요청 |
| --- | --- | --- |
| prepared | 모두 Before | applying 후 적용 / restoring 후 쓰기 없는 종료 |
| applying | 매 byte가 해당 Before 또는 After | 요청 방향으로 수렴 |
| applied | 모두 After | 중복 쓰기 없는 적용 확인 / restoring 후 원복 |
| restoring | 매 byte가 해당 Before 또는 After | 호출자의 실행 허용 조건 아래 요청 방향으로 수렴 |
| restored 완료 기록 | 이번에 CDB를 열거나 읽지 않음 | 적용 거절 / 과거 완료 receipt 재전달 |
| 다른 UID 소유, 입력 불일치, 결손 기록 | 검사 권한 없음 | CDB를 열기 전에 거절 |
| 파일 신원/길이 불일치, 범위 결손·겹침·잘못된 hash, 제3의 byte | 부적합 | 첫 쓰기 전 거절 |

혼합 상태는 applying/restoring 사전 기록이 있을 때만 허용한다. prepared/applied와 실제
byte가 모순되면 조용히 중단 복구로 해석하지 않는다. 모든 조각을 첫 쓰기 전에 확인하고,
의도를 영속화한 뒤 필요한 조각만 쓴다. flush 후 선택 범위를 읽어 완료를 판정한다.
이미 목표 값인 재시도도 이전 쓰기의 flush 직전 중단 가능성을 고려하여 flush를 수행한다.
조각 밖 byte는 읽지도 쓰지도 않으며 그 현재 무결성을 보증하지 않는다. 알려진 전후 값에
속한다는 판정만으로 외부 변경 주체나 전원 손실 시 저장 장치의 동작을 입증하지 않는다.

코어 결과 `nll/common-native-fx-range-receipt/v2`는 `ExecutionUid`, `PlanSha256`,
`State`(applied/restored), `ValidationScope=patched_ranges`, `SelectedBytes`, `BytesRead`,
`BytesWritten`을 가진다. 반복 종료의 `Historical=true`는 **과거 완료의 재전달**이며,
그 receipt의 byte 수를 이번 요청의 I/O로 합산하지 않는다. 일반 정상 적용/복구는 선택 합계 B에
대해 읽기 2B 이하/쓰기 B 이하이고, 중복 적용·미적용 종료는 읽기 B/쓰기 0이다.
R3의 실행별 적용/퇴역 wrapper는 이 결과와 봉인 manifest·기존 Job/termination 증거를 결박해야
한다. 범위 receipt만으로 기존 프로세스 종료 검사나 게임 실제 실행 완료를 대체하지 않는다.

구현은 `NativeFxRangeTransaction.cs`, `NativeFxRangeJournal.cs`다. 아래 R3에서 신규 공통
실행 경로에 연결했다. 기존 설치 v8은 v1을 사용하며 변경하지 않았다. 설치 및 실게임
성능 개선 완료는 [R4~R6](../operations/RUNTIME_FAST_PATH_IMPLEMENTATION_PLAN.md)를 따른다.

### R4 실행 진행 표시 — 2026-09-15

`execution-progress.json` (`nll/phase-d-execution-progress/v1`)은 UI 표시와 구간 계측용이다.
API projection의 선택 필드 `progress`로 전달하며 실행 입장·복구·완료 권위가 아니다.
원래 상태가 active이면 진행 기록의 `ready`에도 재실행을 허용하지 않는다. 게임 종료가
확인되면 watcher가 느린 정리 전에 기록하고 UI는 다음 조회에서 종료·복구·저장을 표시한다.
게임 생성 시각과 기존 30초 health 관찰은 화면 준비 완료 시각과 구분한다.
기존 state lock에서 짧게 기다려 원자 게시하며 늦은 시작 기록은 종료 표시를 되돌리지 않는다.
진행 기록 손상·결손은 기존 입장 상태나 정리를 변경하지 않는다. 필드·측정점·증거 한계는
[R4 구현 기록](../operations/RUNTIME_FAST_PATH_IMPLEMENTATION_PLAN.md#r4-구현-기록--2026-09-15)을 따른다.
설치 전 소스 변경이며 기존 활성 v8과 실게임 성능 인수를 대신하지 않는다.

### R3 공통 실행 연결 — 2026-09-15

- `CommonBossDelivery.Stage`는 기존 profile/recipe/후보 검증 후 `NativeFxExecutionDelivery.Stage`를
  호출한다. 선택한 조각이 없으면 기존처럼 null이며 추가 전달을 만들지 않는다. Stage는
  CDB를 열거나 읽지 않는다. 실행별 원본/목표 조각, 기준 등록 pin과 `RangePlanSha256`을
  v2 manifest에 봉인한다. 이 hash는 작은 트랜잭션 입력의 hash이고 후보 CDB hash가 아니다.
- **Stage에서 store 소유 슬롯을 예약하지 않는다.** coordinator가 Job을 만들기 전에
  준비가 실패해도 슬롯이 남지 않도록, 실제 적용/미적용 종료 직전에 코어 Prepare를 호출한다.
  이미 완료한 실행의 cleanup은 동일 PlanSha256인 완료 기록을 통과시키고 코어가 과거 완료를
  반환한다. 새 UID의 재사용이나 다른 소유자의 복구를 허용하는 옵션이 아니다.
- `CommonNativeFx`와 `ExecutionAssetRetirement`는 v1/v2를 명시적으로 구분한다.
  v1은 기존 전체 검산·복구 의미를 보존한다. v2는 새 범위 코어만 호출하며 오류 시 v1으로
  낮추지 않는다. 실제 파일의 volume/file ID·길이는 동일 독점 핸들에서 확인한다.
  v2의 FileStream 버퍼 크기는 1로 설정하여 관리 코드의 1MiB 선행 읽기를 없앤다.
- 기존 봉인 runner/runtime code, 정확한 Job 소유권·프로세스 종료·cold 검사는 유지한다.
  변경 의도 및 완료 게시 전에도 해당 검사를 호출한다. 실행 manifest·기준 pin과 작은
  조각이 어긋나면 CDB를 읽거나 쓰기 전에 거절한다. 검사가 쓰기 후 실패하면 완료로
  게시하지 않고 applying/restoring 상태를 남겨 동일 입력으로 복구한다.
- `applied.json`은 `nll/common-native-fx-applied/v2`, `retired.json`은
  `nll/common-native-fx-retired/v2`다. 각각 manifest pin과 범위 receipt를 포함하며 퇴역은
  `terminationReceiptSha256`도 결박한다. 원자 게시하며 재시도는 기존 완료 파일을 보존한다.
  실제 게임 인수를 주장하지 않는다. 과거 receipt가 없고 ledger만 완료돼도 재생성할 수 있다.
- `Nll.PhaseDJob.ps1`은 v2 퇴역의 계약·UID·manifest/plan/termination hash·범위·I/O 예산을
  확인한 뒤 기존 cleanup checkpoint에 파일 hash를 봉인한다. checkpoint replay도 같은 의미를
  확인하며 v1의 `storeSha256`를 v2 성공 근거로 받아들이지 않는다. Job이 없어진 뒤의
  checkpoint는 기존처럼 DB/pending replay만 허용하며 물리 복구를 다시 실행하지 않는다.

설치 기준 등록은 `CommonNativeFxBaseline`의 별도 `--register-common-native-fx-baseline`
명령이다. 원본 store 경로·길이·hash, installation ID와 client version을 명시적으로 받아
cold와 독점 핸들에서 **설치 시 전체 hash 한 번**을 확인한다. 기존 등록을 덮어쓰거나
정상 실행에서 자동 생성하지 않는다. 운영 설치는 기존 maintenance 잠금과 미완료 실행
정리 조건을 함께 충족해야 한다. 이번 R3에서는 이 명령을 실제 client에 실행하지 않았다.

현재 등록 권위는 `C:\NLL\RuntimeInputs\CommonBossExecution\native-fx\baseline.private.json`,
동일 store의 모든 profile/bundle이 공유할 journal은 그 디렉터리의
`store-state.private.json`이다. 호출자가 다른 journal 경로를 지정하여 소유권을 우회하지
못하도록 실제 adapter에서 고정한다. 등록 pin은 실행 manifest에 봉인하며
현재 ResourceProbe 이외의 파일을 새로 허용하지 않는다. 원본 교체·수리는 별도 설치 작업이다.
정상 준비기의 `--require-native-fx-baseline`은 보정 조각이 있을 때만 작은 등록을 확인하고,
후보 게시의 오프라인 검증은 설치 등록을 필요로 하지 않는다. 단계별 의미를 구분한다.

## 공통 보스 게시와 운영 DB 연결 (2026-09-15)

운영자의 공통 파이프라인 요구에 따라 새 게시에는 `common-boss-runtime-admission/v1`을
사용한다. 기존 여섯 시즌의 역사적 admission 정책과 `lab_raid` snapshot을 변경하지 않는다.
봉인된 profile·후보·전달 자산 검증 뒤, 공통 작업자가 운영 DB 연결을 등록하고 파일을
게시해야 `completed`를 반환한다. DB 등록 실패 시 catalog가 처리 완료로 바뀌지 않아
UI에서 새 요청으로 재시도할 수 있다. DB 등록 뒤 파일 게시가 실패한 경우에는 불변 DB
연결을 재사용한다. 작업자가 DB 서버나 게임을 시작하지는 않는다.

`lab_private_server.runtime_raid_snapshot`은 실행 시 사용하는 snapshot 식별 권위다.
V0022 마이그레이션은 기존 snapshot의 숫자 키·UUID·hash를 그대로 이관하고 진행도 FK만
연결한다. 이후 기존 경로로 생성된 snapshot도 trigger로 같은 식별자를 연결한다.
새 공통 snapshot은 별도 음수 내부 키 공간을 사용하여 기존 양수 키와 충돌하지 않는다.
`common_boss_runtime_binding`은 profile hash와 시즌·원본 hash·후보 hash·snapshot 연결을
불변 레코드로 저장한다. 원본 게임 ID는 이 연결의 PK/FK로 사용하지 않는다.

원본 지문은 검증된 profile의 시즌, 선택 manager 관측, Challenge 선택자, 원본 속성,
skill closure, 행동 조립, QTE 속성 근거에서 계산한다. 선택 약점과 생성 FX는 제외한다.
같은 원본의 재조립·FX 변경은 같은 snapshot을 재사용하며, 원본 지문 변경은 새 snapshot을
만든다. 기존 snapshot과 계정·약점별 기록은 남겨 둔다. 최초 도입 시 같은 시즌의 기존
snapshot이 정확히 하나라면 그 식별자를 채택하며, 후보가 여러 개면 추정하지 않고 중단한다.
전달 파일이 없는 기존 profile의 도입도 검증된 기존 snapshot 채택만 허용한다.

게시 등록은 시즌별 transaction 잠금으로 직렬화하고 snapshot과 profile 연결을 원자적으로
저장한다. 동일 입력·동시 재요청은 동일 식별자로 수렴하며 중간 실패는 고아 snapshot을
남기지 않는다. 같은 profile hash에 다른 원본/시즌을 붙이는 요청은 거절한다.

UI 실행 준비와 coordinator는 선택 profile hash의 DB 연결을 읽기 전용으로 확인한다.
미등록이면 `phase_d_raid_state_operational_binding_missing`으로 시작 전에 차단한다.
실제 materializer도 동일 연결을 사용한다. profile 없는 과거 계약 검사의 기존 조회 규칙은
유지한다. DB 연결 완료는 게임 실행·전투·종료 후 기록 복원의 실게임 인수를 뜻하지 않는다.

## 변환 요구와 준비 상태

변환은 검증된 profile의 의미에 따라 선택한다. 기본 약점/속성과 같은 입력이면 불필요한
변경을 만들지 않는다. 2026-09-14 운영자가 명시한 도메인 요구에 따라 특정 속성 외 피해를
받지 않는 body·parts·QTE 등의 특수 패턴에는 예외 없이 속성 실드가 존재한다. 대상별
피해 허용 속성 조건과 실드 FX 조정을 함께 처리·검증해야 하며, QTE의 조건만 바꿔서는
준비 완료가 아니다. 조건 또는 FX 연결의 결손은 `unresolved`로 남긴다.

원본은 `sourceAffinity.bossElementCode`에 보존하고, 실행 보스 속성은 선택 약점과 기존
상성 규칙에서 계산한다. FX는 `elementShield.fxVariants[].bossElementCode` 및
`mappings[].sourceKindCode`와 실제 자산/참조 근거를 함께 확인한다. 현재 S29는 전격·수냉
모두 `boss_specific`이고 작열·풍압·철갑은 `common`이다. 이 분포를 공통 도구에 고정하지
않으며, 원본 보스 속성 하나로 사용 가능한 보스 전용 FX 전체를 대신하지 않는다.

특수 패턴의 FX 선택·참조 조정·적합성 검증은 필수다. 기존 FX가 조건과 대상에 이미
적합하다는 근거가 있으면 추가 바이너리 변형 없이 재사용할 수 있다. `boss_specific`
표기만으로 적합하다고 단정하지 않는다. 추가 transform 변경 불필요와 FX 처리 생략은
구분한다. `not_required`는 해당 추가 변경 등의 불필요가 입증된 범위에만 사용하며,
필수 조건/FX 결손을 null이나 변경 없음으로 바꾸지 않는다.

2026-09-16 크기 recipe는 원본과 대상의 계층 깊이가 다른 경우에도 제한된 좌표 프레임
대응을 지원한다. 대상 emitter 앞에만 있는 순수 Transform은 원본 비교 모델에 단위 변환을
삽입하여 대응하고 대상의 위치·크기를 보정한다. 자산의 실제 계층·회전·색·시간·활성화는
보존한다. 추가 component나 비단위 회전이 있는 프레임, 불일치 mesh와 모호한 크기는
계속 미해결로 남긴다. 파생 프레임 근거와 변경 필드를 recipe에 기록하고 native export에서
재계산하여 동일성을 확인한다. 정적 크기 일치가 실제 게임 렌더링 인수를 대신하지 않는다.

| 기존 상태 | 의미 | 그 상태만으로 주장할 수 없는 것 |
| --- | --- | --- |
| queued/running | 자동 처리 요청/실행 중 | 산출물 검증 완료 |
| awaiting_runtime_delivery | 오프라인 후보 검증, 전달 준비 미완료 | 게임 시작 가능 |
| awaiting_game_validation | 전달/실행 구성이 결박됐고 사용자 검증 대기 | 전투·FX 인수 완료 |
| preparation ready | 해당 준비 계약이 확인한 입력 일치 | 실제 전투 성공 |
| failed/blocked/unresolved | 해당 단계 실패/결손 | 이전 성공값으로 대체된 성공 |

기존 completed는 그 receipt 계약이 정의하는 완료만 뜻한다. 오프라인 게시/조립의
completed를 원본 runtime 인수로 확대하지 않는다. 표시 상태는 시즌 이름이 아니라
증거에서 계산한다. 과거 상태 레코드를 일괄 rewrite하지 않는다.

## P2 이후 이관해야 하는 확인된 제약

P2-1에서는 기존 준비기에 순수 해석 함수 `Resolve-PhaseDBossAffinity`를 연결했다.
내부 `plan.affinity`는 원본 속성/약점과 선택 약점을 구분하며 전체 FX 매핑과 선택한
원본/대상 FX를 보존한다. 출처는 mapping 단위로 유지한다. 공개 wire 계약은 변경하지
않았으며, 이 선택 결과는 자산 적합성이나 runtime admission 증거가 아니다.

- 일반 준비기는 여전히 profile v1/v2까지만 수락한다. v3 지원을 붙일 때 profile 검증,
  원본 참조, 실행별 변경/복구 manifest와 준비 상태를 함께 연결해야 한다.
- 별도 UserValidation 서버에 있는 profile 지원을 공통 서버로 이관해야 한다.
- `materialize-nll-shield-fx-candidate.py`는 원본 속성 전격 및 세 보정 역할을 고정한다.
  `BossRuntimeVariantProfile.ValidateV3QteAndShieldTransform`도 같은 세 역할을 고정한다.
  현재 profile v3를 모든 보스/QTE/FX 조합을 표현하는 일반 계약이라고 주장할 수 없다.
- 조립기는 QTE를 발견하면 v3 및 고정된 FX normalization을 함께 요구한다. 일반화 대상은
  body·parts·QTE의 속성 제한 패턴에 연결된 조건과 FX의 표현/소비 및 추가 transform
  필요성 판단이다. 앞서 적었던 'QTE만 필요한 보스 / FX만 필요한 보스'의 독립 완료 구분은
  철회한다. 속성 실드 조건과 FX를 함께 검증하는 요구는 유지하며 다른 원본 속성·기존
  전용 FX·보정 대상 집합을 지원한다. 호환 확장이나 wire 변경은 실제 표현 결손으로 결정한다.
- 검증용 전달 reader의 v3 한정과 별도 실행 경로는 P2~P5 이관 대상이다. 필요한 증거
  검사를 삭제하는 대신 공통 준비/전달로 옮긴다. 이번 P1은 이를 실행 가능으로 바꾸지 않는다.

## 검증

- 기존 runner 70개 검사와 별도로 세 시즌 × 다섯 약점 × 기존 wire/FX 유무 조합 60개,
  lifecycle 필드 누락 3개, 교차 profile/weakness·결손·추가 필드·잘못된 hash/nonce 6개를
  같은 생성기/검증기로 검사했다. 새 검사 69개는 PS7과 WinPS5에서 통과했다.
- 실제 coordinator 매핑을 합성 입력에 적용하는 기존 routing 4개 검사가 통과했다.
- API 상태/준비/profile 버전 focused 33개가 통과했다. S26/S29/S34 모두 오프라인 증거만
  있으면 전달 대기에 머물고, 증거 없는 게임 준비 상태 승격은 거절한다.
- 위 시즌 숫자는 일반성 합성 검사 입력이다. 실제 S34 데이터 closure나 게임 실행을
  검증했다는 뜻이 아니다. 저장소 전체 검사 결과는 해당 커밋의 로컬/Actions 로그로 확인한다.
