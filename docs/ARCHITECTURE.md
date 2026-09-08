# 현재 아키텍처

기준: 2026-09-06, 운영자가 실게임 검증한 151 / S26 경로.
정확한 설치 경로·선택 bundle은 [MICRON_CURRENT_PATHS.md](MICRON_CURRENT_PATHS.md)를 따릅니다.

## 실제 실행 흐름

```text
관리도구 / Admin API
  ├─ PostgreSQL: 계정·프로필·로비·revision 조회와 저장
  └─ 실행 요청
       → coordinator: 계정 candidate + bundle + boss variant 확인
       → materializer: 실행용 Epinel DB 구성
       → PostgreSQL 중지 → bootstrap / Epinel / 원본 NIKKE 실행
       → 종료 watcher 또는 orphan recovery
       → 레이드 pending 캡처 → transient 상태 복원
       → PostgreSQL 재시작 → 영속화 / replay / CAS → 종료 상태
```

현행 경로는 과거에 계획했던 상시 loopback shadow bridge와 다릅니다.
관리도구의 역할은 실행 준비와 데이터 공급이며, 전투 계산·HUD·결과 표시는 원본 runtime이 담당합니다.

## 구현 위치

| 책임 | 현재 코드 |
|---|---|
| 실행 API·상태 조회·복구 요청 | [PhaseDExecution.cs](../src/NikkeLocalLab.Admin.Api/PhaseDExecution.cs) |
| 준비·기동 조정 | [invoke-nll-phase-d-execution.ps1](../scripts/invoke-nll-phase-d-execution.ps1) |
| 실행별 고정 실행기(기본 전환, 실게임 인수 전) | [Runner 입력](../scripts/Nll.PhaseDRunnerContract.ps1), [코드 봉인](../scripts/Nll.PhaseDRunnerSeal.ps1), [고정 entry](../scripts/invoke-nll-phase-d-runner.ps1) |
| bundle 선택·검증 | [Nll.PhaseDRuntimeBundle.ps1](../scripts/Nll.PhaseDRuntimeBundle.ps1) |
| 계정·전투 데이터 변환 | [RuntimeMaterializer/Program.cs](../tools/NikkeLocalLab.PhaseD.RuntimeMaterializer/Program.cs) |
| 종료 감시·복구 | [watcher](../scripts/watch-nll-phase-d-execution.ps1), [orphan recovery](../scripts/recover-nll-phase-d-orphaned-execution.ps1) |
| 계정 Save / Save As 순서 조정(미배포 소스) | [AccountWorkspaceSaveCoordinator.cs](../src/NikkeLocalLab.Persistence.PostgreSql/AccountWorkspaceSaveCoordinator.cs) |
| 저장 단계와 기존 writer 연결(미배포 소스) | [WorkspaceSave.cs](../src/NikkeLocalLab.Persistence.PostgreSql/PostgreSqlProfileManagementService.WorkspaceSave.cs) |
| Save claim·checkpoint·계정별 DB 잠금 | [PostgreSqlAccountWorkspaceSaveStore.cs](../src/NikkeLocalLab.Persistence.PostgreSql/PostgreSqlAccountWorkspaceSaveStore.cs) |
| Save 원문 보존·읽기 전용 복구 조회(미배포 소스) | [요청 codec](../src/NikkeLocalLab.Application.ProfileManagement/WorkspaceSaveRecovery.cs), [recovery store](../src/NikkeLocalLab.Persistence.PostgreSql/PostgreSqlAccountWorkspaceSaveStore.Recovery.cs) |
| 레이드 기록 영속화 | [ClassicSoloRaidRuntimeStateStore.cs](../src/NikkeLocalLab.Persistence.PostgreSql/ClassicSoloRaidRuntimeStateStore.cs) |

S-05는 2026-09-09 cold 확인 후 데이터 JSON과 고정 Start/Complete를 사용하는 `parameterized/v1`을
기본으로 전환했습니다. legacy는 다음 실행의 명시적 rollback 용도로만 남습니다. 새 경로는 watcher/recovery도 실행별 사본에 결박하므로
실행 도중 저장소의 다음 버전과 혼용하지 않습니다. 계약 검사와 비실행 준비 검사 통과를
실게임 인수로 승격하지 않습니다. 기본 전환·기존 template 의존 제거 gate는 안정화 계획에 있습니다.

## 관리도구 UI 재사용

다른 프로젝트에 가져갈 화면 소스는 `src/NikkeLocalLab.Admin.Api/wwwroot/editor/`의
`index.html`, `editor.css`, `editor.js`입니다. HTML/CSS는 레이아웃·카드·탭 표현을,
JavaScript는 DOM 렌더링과 현재 Admin API 호출을 함께 담고 있습니다. 독립 UI 라이브러리는
아니므로 다른 프로젝트에서는 API·계정 상태·실행 제어 연결을 교체해야 합니다.

Windows 실행 창은 `tools/NikkeLocalLab.ControlCenter.Desktop/`의 WinForms/WebView2
shell입니다. 현재 사용자·관리자·설치 경로 검사와 Windows SDK 참조를 포함하므로
다른 PC의 범용 실행기로 그대로 배포하지 않습니다. 로컬 전용 아이콘이 없는 소스 checkout은
기본 아이콘을 사용합니다. 이 게시 작업은 운영 설치본을 재빌드하거나 바꾸지 않습니다.

게임 이미지와 `presentation.json`은 Git에 포함하지 않습니다. 필요한 캐릭터 썸네일과
돌파·코어 강화 이미지는 다음 도구로 **이미 설치된 파일에서만** 별도 로컬 폴더에 복사합니다.

```powershell
./scripts/export-nll-ui-reuse-assets.ps1 `
    -EditorRoot 'C:\NLL\ControlCenter\app\wwwroot\editor' `
    -OutputRoot '<새로운 절대 경로>'
```

출력은 `assets/characters/<lab-uid>.png`, `assets/ui/star-empty.png`,
`star-filled.png`, `evolve.png`와 로컬 전용 `manifest.private.json`입니다.
manifest는 이름·이미지 경로·검산 hash만 포함하고 계정·로스터·성장 상태를 복사하지 않습니다.
한계돌파는 별 세 개의 채움 상태로, 코어 강화는 `evolve.png` 위에 `1`~`6` 또는
`MAX`(7)를 텍스트로 얹어 표시합니다. 숫자별 코어 이미지는 별도 파일이 아닙니다.
이 이미지 묶음은 원본 게임 자료이므로 GitHub·Actions·release 업로드 대상이 아닙니다.

## 보존할 데이터·검증 경계

- 계정·빌드·스쿼드·프로필은 자체 식별자와 immutable revision을 사용합니다.
- Save의 CAS, operation replay, Save As의 provenance를 유지합니다.
- 실행 중 파생 DB와 장기 보존할 PostgreSQL 기록을 구분합니다. 종료 복원 전에 pending 기록을 보존합니다.
- run의 완료·포기와 client 프로세스 종료는 서로 다른 사건입니다.
- source-free harness 계약과 실제 NIKKE runtime 관측은 별도입니다. 한쪽 검사를 다른 쪽 성공으로 표시하지 않습니다.
- 선택된 bundle/보스/리소스의 불일치는 실행 전에 드러나야 합니다. 검사를 삭제해 맞추지 않습니다.

## 안정화 대상

1차 점검에서 조회·복구·시작 잠금의 결합, 분리된 revision 읽기, 문자열 치환 실행기,
다단계 Save의 조정 집중과 일부 테스트의 동작 검증 부족을 확인했습니다.
소스 정비에서는 실행 snapshot 묶음과 Save 전담 조정기를 분리했습니다. 계정별 workspace
저장 경합을 DB에서 거절하고 기존 child receipt로 복구하며, 단일 거대 transaction으로 바꾸지 않습니다.
신규 claim과 원래 요청은 V0018에서 함께 보존합니다. editor는 같은 창에서 원래 요청을 재전송하고,
새 창에서는 조회 후 사용자가 명시적으로 복구합니다. 재시도 preview·최신 revision 재지정은 하지 않습니다.
원문 없는 구형 pending은 그대로 보존하며 자동 수선하지 않습니다.
위 소스 정비는 설치본에 아직 배포하지 않았습니다.
근거·미확인 위험·정비 순서는 [STABILIZATION_PLAN.md](STABILIZATION_PLAN.md)에만 관리합니다.
이 문서의 흐름도는 현행 설명이지 정비 구현 완료 선언이 아닙니다.

## 상세 계약과 과거 설계

- [프로필·실행](contracts/PROFILE_EXECUTION_DOMAIN.md), [레이드](contracts/RAID_DOMAIN.md),
  [원본 UI 경계](contracts/PRIVATE_SERVER_UI.md)
- [계정 workspace](features/PHASE_B_ACCOUNT_WORKSPACE.md), [레이드 영속화·분석](features/SOLO_RAID_PERSISTENCE_AND_ANALYTICS.md)
- [Phase별 상세 계약](README.md#상세-계약), [이전 아키텍처·미래 설계](archive/ARCHITECTURE_2026-09-06.md)

과거 설계는 재검토 근거로 보존하며, 현재 잘 동작하는 DLL·실행 경로를 그 설계에 맞추기 위해 임의 변경하지 않습니다.
