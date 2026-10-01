# 게임 실행·종료·복구와 영속화

기준: 2026-09-27 `main`. 선택 runtime은 `C:\NLL\Runtime\PhaseD152-v1`
([경로 권위](../MICRON_CURRENT_PATHS.md)). 과거 설계·조사 원문은 [보관 기록](#보관-기록)에 있습니다.

## 실행 흐름

```text
관리도구 시작 버튼 → POST /admin-api/v1/executions        (PhaseDExecution.cs)
  → scripts/invoke-nll-phase-d-execution.ps1               (coordinator)
     계정 revision·선택 bundle·보스 준비·DB 연결 확인 → 실행용 Epinel DB materialize
     → hosts 적용 → PostgreSQL 실행 확인(중지하지 않음)
     → 실행별 Windows Job 생성 → 공유 프로그램 차단 활성화
     → 봉인된 runner로 bootstrap / Epinel / 원본 NIKKE 시작 (준비 기한 300초)
     → watch-nll-phase-d-execution.ps1 인계 → 상태 started
  게임 종료 → watcher
     → Job 종료·서버 로그 보존·실행 FX 원복 → runner completion (기한 180초)
     → hosts 원복 → 물리 정리 checkpoint(공유 차단 원복 포함)
     → PostgreSQL 실행 확인(중단 상태일 때만 시작) → 레이드 진행 저장 → 상태 completed
  정상 종료 증거가 없으면 → recover-nll-phase-d-orphaned-execution.ps1
```

- 관리 PostgreSQL은 2026-09-18부터 게임 실행 중에도 켜 둡니다. 유니온 API가 초기 조회·입장·
  편성·결과를 같은 영속 DB transaction으로 처리하기 때문입니다(`Assert-PhaseDPostgresRunning`,
  `Ensure-PhaseDPostgresRunning`). 모든 시즌·모드에 같은 수명주기를 적용합니다.
- 실행 코드는 `nll/phase-d-runner-input/v3`, `nll/phase-d-runner-bundle/v2`로 실행마다 봉인됩니다.
  watcher는 그 사본에 결박됩니다. v1/v2 복구는 봉인 사본에 위임하고, v3 복구는 기존 봉인 전체를 검증한 뒤
  설치된 복구 코드를 사용합니다. L1 전 `resourcePreflightRequired` 입력은 봉인 사본에 위임합니다.
  과거 실행의 봉인 파일은 수정하지 않습니다.
- 기한 초과는 강제 종료·자동 원복이 아니라 소유권 증거를 보존한 비종결 상태입니다.
- 실행 완료(`completed`)는 정리·저장 완료이며 5덱 완주를 뜻하지 않습니다.

## 2026-09-30 L1 코드 변경 (운영 설치 전)

- 새 실행은 선택 bundle과 v3 Job 입력만 사용합니다. 150 실행·resource transport preflight,
  v1/v2 PID 기반 정지·자동 rollback, 무-bundle 과거 복구 분기를 제거했습니다.
  materializer가 사용하는 기존 seed DB와 그 pin, 현재 음성 선택의 읽기 전용 기록은 유지합니다.
- 착수 시 실행 119개 중 bundle 없는 51개가 모두 유효한 closed 기록과 state hash를 가지며
  pending 증거가 없었습니다. 열린 무-bundle 실행은 0개였습니다. 기존 봉인 bundle의
  복구 dispatch와 사본은 유지하고, 현재 코드에서 무-bundle 복구는 거절합니다.
- progress event는 그 단계의 시작입니다. `intervalMilliseconds`는 다음 단계가 시작할 때
  직전 event에 채우는 해당 단계의 소요 시간이며, 현재 단계는 0입니다. UI의 현재 단계 경과는
  `occurredAtUtc`부터 계산합니다. 중복·늦은 단계 알림은 시작 시간을 바꾸지 않습니다.
  `cumulativeMilliseconds`는 요청부터 단계 시작까지이며 입장·종료 판정에는 사용하지 않습니다.
- 기존 실행 한 건의 timestamp로 환산하면 `fx_stage`는 15.073초에서 0.567초,
  `health_observation`은 18.728초에서 31.691초가 됩니다. 기존 기록 자체는 고치지 않았으며,
  이는 표시 의미의 수정 예시입니다. 시작 시간 단축이나 설치 후 실게임 측정 결과가 아닙니다.
- 디렉터의 앱 패키지 교체와 변형 유무별 실제 시작·종료·저장 확인이 남아 있습니다.

## 2026-10-01 시작 실패 정리·복구 (코드 변경, 설치 전)

- Job 생성 뒤 시작 pointer 게시 전에 실패해도 FX 정리를 먼저 실행합니다. 미적용 FX는 before 범위를
  확인하고 기존 `retired.json`에 `restored`, `bytesWritten=0`을 기록합니다. 이어 hosts/DB 원복 확인,
  공유 격리 원복을 포함한 물리 정리 checkpoint, PostgreSQL 확인을 수행합니다.
- v3 자동 복구는 named Job의 Win32 2(not found)에 한해서 기록된 runtime·child 신원의 종료를 모두
  확인하고 정리를 계속합니다. 살아 있는 신원, PID 재사용, 빈 child reservation, 권한 오류는 차단합니다.
  Job을 다시 만들거나 receipt만으로 종료를 추정하지 않으며 기존 `job-zero/v1`·정리 receipt를 사용합니다.
- 봉인된 과거 v3 실행에도 수정이 적용되도록 설치된 recovery와 현재 선택 bundle에 pin된 materializer를
  사용합니다. materializer도 기존 실행의 코드·FX·종료 pin을 검증합니다. FX retirement worker는 직접 실행하고
  자신의 정확한 PID·시각·경로만 소비자 예외로 인정하며 이전 worker는 부모의 종료 검사에서 배제하지 않습니다.
- 포인터가 없는 복구는 runtime DB가 봉인한 기준 해시 그대로인 경우에만 rollback으로 인정합니다.
  운영 설치와 기존 비종결 실행의 자동 `rolled_back`·공유 규칙 원복 확인은 디렉터의 인수 단계입니다.

## 코드 위치

| 책임 | 위치 |
|---|---|
| 실행 API·상태 조회 | `src/NikkeLocalLab.Admin.Api/PhaseDExecution.cs`, `PhaseDExecutionEndpoints.cs`, `PhaseDLifecycle.cs`, `PhaseDExecutionProgress.cs` |
| coordinator | `scripts/invoke-nll-phase-d-execution.ps1` |
| 봉인 runner | `scripts/Nll.PhaseDRunnerContract.ps1`, `Nll.PhaseDRunnerSeal.ps1`, `Nll.PhaseDRunnerStart.ps1`, `Nll.PhaseDRunnerComplete.ps1`, `invoke-nll-phase-d-runner.ps1` |
| bundle 선택 | `scripts/Nll.PhaseDRuntimeBundle.ps1`, `C:\NLL\ControlCenter\runtime-selection.private.json` |
| Job·프로세스 신원 | `scripts/Nll.PhaseDJob.ps1`, `Nll.PhaseDJob.cs`, `Nll.PhaseDProcessIdentity.ps1`, `Nll.PhaseDChildProcess.ps1` |
| 공유 프로그램 차단 | `scripts/Nll.PhaseDSharedIsolation.ps1` |
| 종료·복구 | `scripts/watch-nll-phase-d-execution.ps1`, `recover-nll-phase-d-orphaned-execution.ps1` |
| 계정·전투 자료 변환, 저장 | `tools/NikkeLocalLab.PhaseD.RuntimeMaterializer/` (`ClassicSoloRaidRuntimeState.cs`, `RuntimePreferencesPersistence.cs`, `NativeFxExecutionDelivery.cs`) |
| 영속 저장소 | `src/NikkeLocalLab.Persistence.PostgreSql/ClassicSoloRaidRuntimeStateStore.cs` |

## 시작 입력 검증 (WP-L2, 설치 전)

- UI 준비 조회의 binding SHA는 Start 요청의 필수 입력이며 coordinator가 현재 준비 결과와 한 번 대조합니다.
  API는 준비 PowerShell을 다시 실행하지 않고 같은 계정 snapshot의 헤더와 candidate/lobby 파일을 전달합니다.
- 실행 시 runtime bundle은 파일 존재·길이와 승인 sodium DLL·client exe·인증서·선택 manifest SHA를 확인합니다.
  설치·선택·수리는 `Read-PdRuntimeBundle -FullVerification`(overlay 적용 전에는 `-BeforeActivation`)으로 전체 SHA를 확인합니다.
- 보스 전달은 시작 때 stage 한 번으로 검사합니다. descriptor·seal·profile SHA와 artifact 길이를 대조하며,
  `byteLength`가 없는 이전 onboarding seal의 artifact는 재봉인 없이 시작 때도 SHA로 확인합니다. 명시적 delivery 검증은 기본 전체 SHA입니다.
- runner/watcher/recovery는 진입 시 봉인을 검증하고 해당 프로세스에서 spec을 보관합니다. coordinator는 직접 만든 bundle을 씁니다.
  이후 Job 소속·same-Job zero·receipt·checkpoint 검사는 계속 수행합니다.
- 기본 차단 규칙 확인과 확장 규칙 생성·확인은 coordinator가 runner child 생성 전에 수행합니다.
  부분 적용과 child 생성 전 실패도 기존 Job 종료 증명 뒤 원복합니다.

위 변경은 source-only 검사 대상입니다. 앱·materializer·runtime bundle 및 보스 전달 입력의 재봉인·설치,
원본 runtime 실행과 시간 측정은 별도이며 기존 실게임 완료 기록을 대체하지 않습니다.

## 시작 관찰 제거 (WP-L3, 설치 전)

- bootstrap receipt와 client PID 확인 뒤 시작 receipt/pointer를 바로 게시합니다. 새 시작 계약
  `nll/phase3b2-epinel-solo-raid-ranking-prefix-start/v10`은 30초 관찰 완료·표본 수·최소 표본/시간·
  성공 외부 연결 0 필드를 갖지 않습니다. 화면 로딩이나 전투 성공을 뜻하지 않습니다.
- watcher는 인계 직후와 이후 약 30초마다 client/server/bootstrap의 검증된 신원에 속한
  Established non-loopback 연결 수를 기존 `startup.measurement.json`에 기록합니다.
  이 파일의 `samples` 배열은 이제 실행 중 표본이며 빈 배열은 관측 전 종료를 뜻합니다. 표본 사이의 연결을 모두
  관측했다는 증거는 아니며, 시작 전 차단과 실행 내내 차단 유지가 네트워크 격리를 담당합니다.
- 외부 연결을 발견하거나 조회가 실패하면 기존 Job 중지·복구 경로로 들어갑니다.
  검증된 client handle의 종료 대기는 즉시 풀리므로 30초 이내 종료도 정상 정리·저장으로 이어집니다.
- 과거 봉인 bundle/receipt는 수정하지 않습니다. 기존 `health_observation` 진행 기록은 역사 표시로
  유지합니다. 설치 후 variant 유무별 실제 시작·종료·저장과 시간 단축 확인은 남아 있습니다.

## 실행 중 변경과 원복

- **hosts**: 실행 전 기준선을 백업하고 종료 때 복원합니다.
- **공유 프로그램 차단**: 공식 `C:\NIKKE` 프로그램 15개와 공유 ACE 서비스 규칙은 평소 비활성이고,
  실행 Job 생성 뒤 첫 게임 프로세스 전에 켭니다. 종료·실패·복구 checkpoint에서 실제 프로세스·
  서비스 종료를 확인한 뒤 이전 상태로 돌립니다. 로컬 복제본 차단 규칙 6개는 항상 켜 둡니다.
- **실행 FX**: 보정 FX가 필요한 약점만 native chunk store에 범위 transaction(v2)으로 적용·원복합니다.
  원본 기준은 client 설치 때 한 번 등록하고(`native-fx-152.8.11`), 정상 실행·종료에서는 전체 파일을
  다시 읽지 않습니다.
- **음성 설정**: 공통 경로는 현재 음성 선택을 읽어 실행 기록에 남길 뿐 쓰지 않습니다
  (`Get-NllVoiceResourceSelection`, `voicePreferencesChanged = false`).

## 영속화 규칙

- 레이드 기록의 범위는 계정 + 시즌 + 선택 약점입니다. snapshot·client build·exe는 각 저장 revision의
  출처이며 기록을 나누는 키가 아닙니다(V0023). client를 바꿔도 같은 논리 head를 이어 씁니다.
- 실전과 모의전은 그 안에서 분리합니다. 최고점은 실전 5덱 완주의 strict improvement만 인정합니다.
- 로비 Quit: 0~4덱이면 완주로 치지 않고 참여 기회 1회를 소모합니다. 5덱 완료는 완주 1회와 참여
  기회 1회입니다. 중복 Quit은 추가로 소모하지 않습니다(`patches/epinel-lobby-quit-attempt-consumption.patch`).
- 덱 결과는 접수 transaction에서 run UID·ordinal·시각·구성 snapshot과 함께 append-only로 남깁니다.
  약점 없는 과거 기록은 `unresolved`로 보존하고 현재 약점에 소급하지 않습니다.
- 편성·착용 스킨·로비·BGM·프로필 꾸미기·알림·배지(P-02~P-09)는 계정 단위 설정 revision입니다.
  실행 준비 때 head를 pin하고 종료 회수는 CAS로 저장하며, 충돌은 격리합니다.
- 종료·복구는 원복 전에 pending을 보존하고 저장 성공 뒤에만 실행 DB·hosts를 기준선으로 되돌립니다.

## 알려진 결함과 남은 작업

- **빠른 시작·재부팅 후 자동 복구**: 2026-10-01 코드가 Job not-found와 기록된 신원 종료를 확인하는
  복구를 추가했습니다. 설치 후 빠른 시작/일반 재부팅 및 복구 중 재종료의 실제 환경 검증은 남아 있습니다.
  PID 재사용·권한 오류·불완전 신원은 계속 unresolved입니다. 2026-09-22 수동 복구 기록을 소급 변경하지 않습니다.
  [복구 기록](../archive/execution/SHUTDOWN_RECOVERY_20260922.md)
- **전체 프로필 영속성**: 위 P-02~P-09 외의 프로필 아이콘·프레임·칭호 등 저장 항목 전체의 capture/restore
  대조가 남아 있습니다(운영자 우선순위 2).
- 공식 게임을 별도 Windows 계정에서 실행하는 운영 방향은 정해졌지만, 그 계정에서의 실행 결과는
  기록되지 않았습니다. [격리 계획](../archive/execution/USER_STORAGE_ISOLATION_PLAN.md)

## 보관 기록

- [P-01~P-09 영속화 구현](../archive/execution/RUNTIME_PERSISTENCE.md),
  [버전 독립 영속성·로비 Quit](../archive/execution/VERSION_INDEPENDENT_RUNTIME_PERSISTENCE.md)
- [빠른 실행 R1~R6 구현](../archive/execution/RUNTIME_FAST_PATH_IMPLEMENTATION_PLAN.md),
  [관측 조사](../archive/execution/RUNTIME_FAST_PATH_OBSERVATION.md),
  [실행 전 검사 정비](../archive/execution/VALIDATION_PREFLIGHT_PLAN.md)
- [공유 프로그램 차단](../archive/execution/SHARED_PROGRAM_ISOLATION.md),
  [재부팅 후 수동 복구](../archive/execution/SHUTDOWN_RECOVERY_20260922.md)
- [안정화 S-01~S-10 기록](../archive/stabilization/STABILIZATION_PLAN.md)
