# 현재 아키텍처

기준: 2026-09-27 `main`, 선택 client 152.8.11, runtime `PhaseD152-v1`, 운영 DB schema V0028.
정확한 설치 경로와 선택 포인터는 [MICRON_CURRENT_PATHS.md](MICRON_CURRENT_PATHS.md)를 따릅니다.

## 구성

```text
Control Center (WinForms/WebView2 shell, tools/NikkeLocalLab.ControlCenter.Desktop)
  └─ Admin API + editor UI (src/NikkeLocalLab.Admin.Api, loopback 전용)
       ├─ PostgreSQL 17 (C:\NLL\ControlCenter\postgresql\data, 127.0.0.1:55433)
       │    계정·빌드·프로필 revision, 레이드 기록·통계, 보스 실행 연결, 유니온 상태
       ├─ 보스 추가 job ─ scripts/*.ps1·*.py + materializer        → features/BOSS_PIPELINE.md
       └─ 게임 실행 ─ coordinator/runner/watcher (scripts/)       → features/EXECUTION_LIFECYCLE.md
            ├─ RuntimeMaterializer (tools/NikkeLocalLab.PhaseD.RuntimeMaterializer): 실행용 Epinel DB·FX·영속화
            ├─ 로컬 EpinelPS 서버 (.external checkout + patches/*.patch, bundle에 봉인된 빌드)
            ├─ LocalBootstrap (tools/Phase3B2/LocalBootstrap)
            └─ 원본 NIKKE 복제본 (C:\NLL\Clients\NIKKE-152.8.11-ResourceProbe)
```

- 관리도구는 실행 준비와 데이터 공급만 맡습니다. 전투 계산·HUD·결과 표시는 원본 runtime이 담당합니다.
- 관리 PostgreSQL은 게임 실행 중에도 켜 둡니다(2026-09-18 이후). 유니온 API가 실행 중 같은 DB transaction을 씁니다.
- 로컬 EpinelPS는 저장소에 vendor하지 않습니다. NLL 변경은 `patches/`의 patch와 manifest로 재현하고, 실행 bundle이
  서버 DLL과 source manifest를 hash로 고정합니다.
- 과거에 계획했던 상시 loopback shadow bridge는 현행 경로가 아닙니다.

## 기능별 문서

| 기능 | 문서 |
|---|---|
| 보스 추가·5약점 변형·실드 FX·실행 준비 | [BOSS_PIPELINE](features/BOSS_PIPELINE.md) |
| 시작·종료·복구·영속화 | [EXECUTION_LIFECYCLE](features/EXECUTION_LIFECYCLE.md) |
| 계정·니케·가져오기·동기화 | [ACCOUNTS](features/ACCOUNTS.md) |
| 유니온 레이드 하드 | [UNION_RAID](features/UNION_RAID.md) |
| 레이드 기록·딜표·BattleLog 분석 | [RAID_RECORDS](features/RAID_RECORDS.md) |

## 소스 구조

| 경로 | 내용 |
|---|---|
| `src/NikkeLocalLab.Domain.*` | 캐릭터·전투 보조·레이드·프로필·로컬 게임 상태·private server 도메인 |
| `src/NikkeLocalLab.Import.*` | StaticData/sd.bin catalog reader, 계정 raw sanitizer, Import CLI |
| `src/NikkeLocalLab.Application*` | import·프로필 관리·private server 응용 계층 |
| `src/NikkeLocalLab.Persistence.PostgreSql` | migration V0001~V0028과 모든 PostgreSQL 저장소 |
| `src/NikkeLocalLab.Admin.Api` | 관리 API와 `wwwroot/editor` UI |
| `src/NikkeLocalLab.PrivateServer.Api` | Phase 2B source-free lab API(harness 계약 검사용) |
| `src/NikkeLocalLab.Automation*` | pipeline manifest, 파일 inventory, 실행 자산 overlay·retirement |
| `src/NikkeLocalLab.Identity`, `Provenance`, `Configuration` | 자체 UUID/HMAC, hash·manifest, fail-closed 설정 |
| `tools/` | materializer, Control Center desktop/bootstrap, BattleLog 분석, 계정 수집기(`AccountCollector`), Phase 3B-2 보조 도구 |
| `scripts/` | 실행 coordinator·runner·watcher, 보스/유니온 파이프라인, 설치·복구, 검증 gate(`verify-*.ps1`) |
| `patches/` | 로컬 EpinelPS에 적용하는 NLL 변경(유니온 하드, 딜표 수집, 모의전 분석, 영속화, 로비 Quit 등) |
| `contracts/`, `config/`, `tests/` | JSON Schema, 예시 설정, source-free 보스 registry(`config/boss-runtime-variants`: S26·S29 역사 기준이며 운영 registry는 `C:\NLL\RuntimeInputs\CommonBossExecution\profiles`), 단위·통합·UI 검사와 합성 fixture |

Phase별 모듈 도입 이력은 [src/README.md](../src/README.md)에 있습니다.

## 관리도구 UI 재사용

다른 프로젝트에 가져갈 화면 소스는 `src/NikkeLocalLab.Admin.Api/wwwroot/editor/`의
`index.html`, `editor.css`, `editor.js`와 기능별 스크립트(`account-directory.js`, `boss-seasons.js`, `union-raid.js`,
`raid-records.js`, `raid-analysis.js`, `user-validation.js`)입니다. HTML/CSS는 레이아웃·카드·탭 표현을, JavaScript는 DOM
렌더링과 현재 Admin API 호출을 함께 담고 있습니다. 독립 UI 라이브러리는 아니므로 다른 프로젝트에서는 API·계정 상태·
실행 제어 연결을 교체해야 합니다.

Windows 실행 창은 `tools/NikkeLocalLab.ControlCenter.Desktop/`의 WinForms/WebView2 shell입니다. 현재 사용자·관리자·
설치 경로 검사와 Windows SDK 참조를 포함하므로 다른 PC의 범용 실행기로 그대로 배포하지 않습니다. 로컬 전용 아이콘이 없는
소스 checkout은 기본 아이콘을 사용합니다.

게임 이미지와 `presentation.json`은 Git에 포함하지 않습니다. 필요한 캐릭터 썸네일과 돌파·코어 강화 이미지는 다음 도구로
**이미 설치된 파일에서만** 별도 로컬 폴더에 복사합니다.

```powershell
./scripts/export-nll-ui-reuse-assets.ps1 `
    -EditorRoot 'C:\NLL\ControlCenter\app\wwwroot\editor' `
    -OutputRoot '<새로운 절대 경로>'
```

출력은 `assets/characters/<lab-uid>.png`, `assets/ui/star-empty.png`, `star-filled.png`, `evolve.png`와 로컬 전용
`manifest.private.json`입니다. manifest는 이름·이미지 경로·검산 hash만 포함하고 계정·로스터·성장 상태를 복사하지 않습니다.
한계돌파는 별 세 개의 채움 상태로, 코어 강화는 `evolve.png` 위에 `1`~`6` 또는 `MAX`(7)를 텍스트로 얹어 표시합니다.
이 이미지 묶음은 원본 게임 자료이므로 GitHub·Actions·release 업로드 대상이 아닙니다.

## 보존할 데이터·검증 경계

- 계정·빌드·스쿼드·프로필은 자체 식별자와 immutable revision을 사용합니다.
- Save의 CAS, operation replay, Save As의 provenance를 유지합니다.
- 실행 중 파생 DB와 장기 보존할 PostgreSQL 기록을 구분합니다. 종료 복원 전에 pending 기록을 보존합니다.
- run의 완료·포기와 client 프로세스 종료는 서로 다른 사건입니다.
- source-free harness 계약과 실제 NIKKE runtime 관측은 별도입니다. 한쪽 검사를 다른 쪽 성공으로 표시하지 않습니다.
- 선택된 bundle/보스/리소스의 불일치는 실행 전에 드러나야 합니다. 검사를 삭제해 맞추지 않습니다.
- 현재 잘 동작하는 DLL·실행 경로를 과거 설계에 맞추기 위해 임의 변경하지 않습니다.

과거 설계와 미래 구상: [이전 아키텍처](archive/ARCHITECTURE_2026-09-06.md),
[기능 로드맵](archive/FOLLOWUP_AUTOMATION_BOSS_ACCOUNT_ROADMAP.md).
