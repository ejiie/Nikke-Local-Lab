# Windows Native PostgreSQL Runtime

## 결정

NLL의 Windows local 개발·통합 시험은 PostgreSQL 17 native Windows binary를 사용한다. Docker Desktop, WSL2, Hyper-V와 Docker VMM은 local database runtime으로 사용하지 않는다.

이 결정은 게임을 실행하는 물리 OS에서 가상화 backend가 예약하거나 사용하는 RAM·CPU와 background process를 제거하기 위한 것이다. NLL에서 과거 사용한 disposable Hyper-V 연구 lane과 Docker Desktop의 자체 VM은 목적이 다르지만, 둘 다 현재 local acceptance/runtime 의존성에서는 제외한다.

GitHub Actions의 PostgreSQL service container는 CI runner 안의 격리된 검증 구현이므로 유지한다. 이 문서는 Windows local host만 규정한다.

## 설치 계약

- major version: PostgreSQL 17
- distribution: PostgreSQL Windows 다운로드 페이지가 안내하는 EDB Windows x64 binary ZIP
- installation root: `C:\NLL\Runtime\PostgreSQL-17-native`
- Windows service registration: 금지
- machine/user `PATH` 영구 변경: 금지
- database data: installation root와 분리
- bind address: `127.0.0.1` only
- local port: `55432`
- authentication: test process가 만든 전용 local credential; repository와 receipt에 비밀번호를 기록하지 않음
- source archive와 extracted executable의 SHA-256을 detached installation receipt에 기록
- 설치·실행 binary와 DB data는 Git에 추가하지 않음

설치는 같은 version/hash가 이미 있으면 재사용하고, 다른 content가 target directory에 있으면 덮어쓰지 않고 fail closed한다. archive는 임시 directory에 다운로드하고 전체 추출·version 검증이 끝난 뒤 installation root로 같은 volume rename한다.

## 실행 계약

### Ephemeral acceptance

Phase별 PostgreSQL integration test는 다음 순서로 실행한다.

1. 고유 임시 data directory 생성
2. `initdb`로 disposable cluster 생성
3. `listen_addresses=127.0.0.1`, port `55432`와 작은 local-test resource limit 적용
4. `pg_ctl start` 뒤 readiness 확인
5. 이름에 `test`가 포함된 disposable database 생성
6. `NIKKE_LAB_TEST_DB`와 reset token을 child test process scope에만 전달
7. migration과 focused integration test 실행
8. `finally`에서 `pg_ctl stop -m fast`
9. port listener와 `postgres.exe` 잔존 0 확인
10. credential을 포함하지 않은 source-free receipt 생성

시험 실패 시에도 server 종료가 cleanup보다 먼저 실행된다. `immediate` shutdown은 사용하지 않는다.

### Persistent Control Center development

Control Center 개발용 data cluster가 필요하면 Micron project data 영역에 별도로 둘 수 있지만 PostgreSQL은 사용자가 Control Center를 실행한 동안에만 시작한다. auto-start service나 scheduled task를 만들지 않는다. Save/Save As data와 runtime projection candidate가 안전하게 flush된 뒤 PostgreSQL을 내릴 수 있어야 한다.

Phase D의 구현 경로는 `C:\NLL\ControlCenter\postgresql\data`, loopback port `55433`이다. database password와 identity HMAC secret은 `C:\NLL\ControlCenter\secrets`에 `nlloperator` CurrentUser DPAPI byte로 보관하고 해당 디렉터리 ACL은 운영자·SYSTEM·Administrators로 제한한다. Control Center launcher가 시작할 때만 복호화된 값을 자식 process 환경으로 전달하며 종료 시 process 환경에서 제거한다.

2026-08-29 영속 cluster와 DPAPI secret 설치는 완료했다. installation smoke와 실제 Control Center launcher는 native `pg_ctl` stdout을 `Out-Null`을 포함한 PowerShell pipeline에 넣지 않는다. Windows에서는 시작된 postgres 자식이 그 pipe handle을 상속해 wrapper 종료를 지연시킬 수 있기 때문이다. 실제 최초 launcher에서도 PostgreSQL만 기동되고 Admin API 전에 멈추는 현상을 관측했으며 start/stop 양쪽 pipeline을 제거한 repair UID `608b5bc2-09ef-4c55-8366-1013e77608f2`로 교정했다. smoke/launcher는 native 출력을 직접 흘리고 `postmaster.pid`, process와 listener가 모두 사라진 cold 상태를 별도로 검증한다.

최종 installation smoke UID `1b6beb08-a5db-4741-b71f-064271a45b21`에서 PostgreSQL과 Admin API 기동, DPAPI 2개, one-time admin session과 인증 조회가 통과했다. 종료 뒤 `postgres.exe=0`, `postmaster.pid=false`, database/admin listener가 모두 closed였고 persistent DB mutation은 없었다. receipt는 `C:\NLL\ControlCenter\source-free\installation-smoke\1b6beb08-a5db-4741-b71f-064271a45b21\smoke.receipt.json`, SHA-256은 `cfcfcc793472a6ce240d98529ea71b023e0b35625dc5caa5ddc281e43d816c65`다.

2026-09-18부터 공통 실행기는 관리 PostgreSQL을 게임 실행 중에도 유지한다. 유니온 API가 초기 정보 조회·입장·편성·결과를 같은 영속 DB transaction으로 처리하기 때문이다. coordinator는 지정 cluster가 실행 중인지 확인하며, completion/실패 복구는 실행 중이면 그대로 재사용하고 중단 상태일 때만 재기동한다. 모든 시즌/모드에 같은 수명주기를 적용한다. 관리도구 종료 시에도 게임·시작 coordinator·종료 watcher가 DB를 사용 중이면 종료하지 않는다. DB는 기존처럼 loopback에서만 수신한다.

이전 v8 절차는 파생 DB 생성 후 관리 PostgreSQL을 중단하고 게임 종료 후 재기동하여 전투 중 메모리를 줄였다. 해당 절차에 런타임 직접 DB 접근 API를 추가하면서 InitSuccess HTTP 500 회귀가 발생했다. 과거 절차를 현재 실행 요구로 사용하지 않는다. 수정과 검사·설치 상태는 [유니온 하드 기록](../archive/union/UNION_RAID_HARD_IMPLEMENTATION.md)을 따른다.

## 게임 실행 preflight

게임 실행 전 다음 조건을 모두 확인한다.

- Docker Desktop backend process와 Docker VM이 실행 중이지 않음
- WSL2/Hyper-V database backend를 사용하지 않음
- ephemeral acceptance cluster(port `55432`)의 `postgres.exe`, `pg_ctl.exe`와 listener가 없음
- 이전 acceptance의 disposable data directory가 active marker를 갖고 있지 않음

하나라도 만족하지 않으면 game launch를 시작하지 않고 정확한 process/port를 보고한다. 관리 cluster(port `55433`)는 위 조건의
대상이 아니며 2026-09-18부터 게임 실행 중에도 켜 둔다. DB가 내려간 뒤에도 binary와 data file은 디스크에 남을 수 있으며 이는
RAM을 점유하지 않는다.

## 제거와 rollback

native runtime 제거는 PostgreSQL이 완전히 종료되고 installation receipt의 exact root가 확인된 경우에만 수행한다. persistent data cluster는 runtime binary와 별도 대상으로 취급하며 명시적 backup/삭제 요청 없이는 제거하지 않는다.

Docker Desktop과 기존 Docker VHDX 제거는 native PostgreSQL 설치와 별도 작업이다. container/image 보존 필요성을 먼저 감사한 뒤 수행하며 이 문서는 자동 삭제 권한을 부여하지 않는다.

## 설치 관측 — 2026-08-29

현재 Windows 환경을 PATH, Windows service와 표준·NLL runtime 경로에서 재검사한 결과 PostgreSQL 설치본은 없었다. 다음 native runtime을 설치했다.

- version: PostgreSQL `17.11`
- root: `C:\NLL\Runtime\PostgreSQL-17-native`
- selected archive members: `bin`, `lib`, `share`와 license 문서; pgAdmin·StackBuilder 제외
- archive byte length: `340719294`
- archive SHA-256: `6eabdf00d2893713b75db4336a23c3fdf505f056e217ec6e2e95d901750cfea3`
- `postgres.exe` SHA-256: `4125c1e963072d929f6468a449ad184b26d3be7d97cae3181c3d613dace49c8d`
- version observation: `postgres (PostgreSQL) 17.11`
- Windows service count: `0`
- machine/user PATH modification: `false`
- post-install `postgres.exe` count와 port `55432` listener count: 각각 `0`
- installation receipt: `C:\NLL\Runtime\PostgreSQL-17-native\nll.installation.receipt.json`

EDB archive의 개별 `postgres.exe` Authenticode 상태는 `NotSigned`였고 같은 이름의 SHA-256 sidecar URL도 제공되지 않았다. 따라서 위 archive hash는 PostgreSQL Windows 공식 다운로드 페이지가 안내한 EDB HTTPS URL에서 최초 취득한 byte를 local pin한 값이지 upstream 서명 검증 결과가 아니다. 후속 재설치는 이 pinned length/hash와 다르면 fail closed한다.

설치는 `scripts/install-nll-native-postgresql17.ps1`로 재현한다. target이 이미 존재하면 덮어쓰지 않으며, 검증된 staging tree를 같은 volume directory rename으로 배치한다. 설치 확인을 위해 실행했던 Docker Desktop은 backend가 뜨지 않은 상태에서 종료했고, 종료 후 Docker Desktop/backend/build process count는 모두 `0`으로 확인했다.

## 첫 live acceptance 관측 — 2026-08-29

`scripts/invoke-nll-phase-b-live-acceptance.ps1`가 Phase B account workspace focused integration test를 ephemeral cluster에서 실행해 통과했다.

- acceptance UID: `57535125-f0b3-4467-8695-c85c954a20d7`
- database: `nikke_local_lab_phase_b_test`
- address/port: `127.0.0.1:55432`
- Docker/Windows service: 사용 안 함
- 종료 후 PostgreSQL process/listener/disposable directory: 모두 `0`
- verdict: `phase_b_live_acceptance_passed`

Windows에서 `pg_ctl start` 출력을 PowerShell pipeline에 연결하면 spawned `postgres`가 stdout pipe handle을 상속해 pipeline EOF가 오지 않을 수 있다. 따라서 acceptance script는 `pg_ctl`을 pipeline 없이 직접 호출하고, readiness와 cleanup은 시간 제한이 있는 loopback TCP probe로 확인한다.
