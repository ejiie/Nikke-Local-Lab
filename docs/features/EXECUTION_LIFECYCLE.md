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
  watcher/recovery도 그 사본에 결박되어 저장소의 다음 버전과 섞이지 않습니다.
- 기한 초과는 강제 종료·자동 원복이 아니라 소유권 증거를 보존한 비종결 상태입니다.
- 실행 완료(`completed`)는 정리·저장 완료이며 5덱 완주를 뜻하지 않습니다.

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

- **빠른 시작·재부팅 후 자동 복구**: 게임을 켠 채 Windows를 종료하면 Job이 사라져 기존 same-Job 증명이
  불가능하고(`phase_d_job_owner_unresolved`) 새 실행이 `phase_d_runtime_not_cold`로 막힙니다. 2026-09-22에는
  해당 실행 한 건만 운영자 승인 하에 수동 복구했습니다. Job 부재를 위장하지 않는 별도 재시작 복구 계약과
  빠른 시작/일반 재부팅/PID 재사용/권한 거부/FX 적용 여부/복구 중 재종료 검증이 필요합니다.
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
