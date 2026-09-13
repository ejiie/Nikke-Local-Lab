# Security boundary

## 허용

- 로컬 디스크에 이미 존재하는 게임 파일의 읽기 전용 분석
- 자체 생성한 합성 계정과 자체 ID 기반 데이터
- loopback에서 실행되는 API와 관리 UI
- 계약 검증용으로 프로젝트가 소유한 test harness
- 운영자가 명시적으로 승인한 비배포·개인 로컬 compatibility 연구
- 아래의 환경별 좁은 정적 입력 수집 예외에 한정된, runtime-cold 인증 없는 HTTPS asset-CDN 요청
- exact build/content hash를 고정한 snapshot 가능한 disposable VM/별도 OS와 `127.0.0.1`-only Local Lab/EpinelPS process
- commit `28b2f5413a0a1e3521a11ae162f91851335c8b40`에 pin한 public EpinelPS source의 read-only 감사와 별도 local checkout 실행
- disposable VM/OS에서만 수행하는 system hosts/root CA 변경과, client-local certificate bundle/native compatibility shim 변경. 사전 backup, 원본·적용 SHA-256, 변경 목록과 검증 가능한 rollback이 필수

## 제외

- 아래 정적 catalog 수집 예외를 벗어난 공식 서버·공식 API 자동 요청
- 공식 로그인, 계정 세션, 쿠키, 토큰 재사용
- live 공식 traffic의 가로채기, credential-bearing capture 또는 공식 session/request replay
- 게임 프로세스 메모리 읽기·쓰기, 코드 주입, 후킹
- 주 설치본 또는 공식 서비스 접속을 위한 anti-cheat/launcher/publisher 보호 기능의 우회·무력화
- Local Lab/EpinelPS에 의한 공식-current `C:\NIKKE`, 공식 account state 또는 공식 진행도의 수정
- manifest에 없는 native binary, certificate 또는 prebuilt selector의 실행
- public/LAN bind, internet port forwarding 또는 제3자 접속
- Local Lab, EpinelPS fork, client/asset, certificate, selector 또는 patched binary의 배포

## 원본 클라이언트 게이트

### 2026-09-13 중단된 FX 실험의 ACE-ADVT 정상 중지 원복 승인

운영자는 중단된 실행 `4ee1395c-78ff-4df5-8429-c5d3f6b257bd`에서 새로 실행된
`ACE-ADVT` 하나를 Windows 정상 중지 요청으로 원래 `Stopped`/`Manual` 상태로
복원하도록 “그렇게 하십쇼”로 승인했다. 게임과 ACE 사용자 모드 서비스가 종료된
상태에서 정확한 드라이버 경로·SHA-256을 확인하고 SCM의 정상 중지/상태 조회만
사용한다. 드라이버 SHA-256은 `0986239726d91e276881dfb24e78498b77073b80f56fb8c34afe53621d14649b`다.
이미 실행 중이던 `ACE-BASE`는 변경하지 않는다. 강제 언로드·바이너리/ACL/시작 유형
변경이나 보호 로직 수정은 허용하지 않는다. 정상 중지 실패는 실패로 보존하며,
사전 드라이버 상태와 대상 종료가 확인된 뒤 해당 실행의 임시 방화벽만 제거한다.
이 원복 승인은 새 실험의 임의 드라이버 실행·중지 허가로 확대하지 않는다.

### 2026-09-13 FX 격리 실험의 관리자 실행·서비스 별도 관리 승인

운영자는 “관리자 실행을 유지하고, 서비스까지 포함해 격리를 관리”하도록 승인했다.
이 새 실험 방식에서는 게임을 일반 권한으로 강제하지 않으며, 정확히 고정한
`AntiCheatExpert Protection` 서비스의 SCM 관리 실행을 별도 수명주기로 관측한다.
아래 2026-09-12 비활성화 방식과 과거 봉인/실패 기록은 변경하지 않는다.

- Micron 실험 OS와 독립 151 사본을 사용한다. S26 기존 실게임 인수는 완료 상태로
  유지한다. 운영자가 실행 거부 이력을 확인한 VM은 이번 대안에서 제외한다.
- 사전 서비스 상태는 `Manual`/`Stopped`/PID 0이고 이름·실행 경로·LocalSystem 계정·
  실행 파일 hash와 종속성에 결박한다. 실행 중에는 `Manual`을 유지하며 ACE 서비스의
  정확한 SCM PID/생성 시각/실행 파일을 확인한다. 다른 서비스나 임의 프로그램의
  Job 이탈을 허용하는 포괄적 예외가 아니다.
- 서비스 실행 파일도 시작 전 외부 통신 차단에 포함한다. 서비스의 Job 외 실행은
  통신 허용이 아니며, 게임/서버/부트스트랩의 기존 Job 소속·종료 검사는 유지한다.
- 종료 시 먼저 게임 Job 잔류 0을 확인하고 해당 서비스에 정상 중지를 요청한다.
  필요하면 기존 임시 비활성화 승인을 종료 구간에만 사용하여 재시작을 막고,
  서비스 PID와 관련 프로세스의 종료 확인 후 `Manual`/`Stopped`로 복원한다.
  Job 종료, 서비스 종료, 전체 대상 종료, 설정 원복은 구분된 증거로 기록한다.
- 중지 거부·기한 초과·미해소 신원 또는 잔류는 복구 성공으로 처리하지 않는다.
  살아 있는 대상의 차단을 해제하지 않고 별도 복구 필요 상태를 보존한다.
- 서비스 ACL/보호 로직/바이너리, 기존 승인 DLL, 공식 설치본, 운영 DB/선택 v6와
  공유 캐시는 변경하지 않는다. 기존 커널 드라이버는 읽기 전용으로 사전·사후
  상태를 기록하며 중지·언로드·패치하지 않는다. 추가 드라이버 변경이나 통신
  허용은 이 서비스 관리 승인에 포함되지 않는다.

### 2026-09-12 FX 격리 실험의 단일 서비스 임시 변경 승인

운영자는 시스템 공유 서비스이므로 같은 OS의 다른 게임 실행에 영향을 줄 수 있다는
설명을 받은 뒤, `AntiCheatExpert Protection`의 시작 유형을 151 격리 실험 중에만
`Manual` → `Disabled`로 바꾸고 모든 실험 프로세스 종료 후 `Manual`로 복원하는
것을 승인했다. 이 승인은 해당 서비스 하나의 시작 설정에만 적용한다.

- 변경 전 서비스는 `Stopped`/PID 0/`Manual`이어야 하며 이름·실행 경로·계정 및
  실행 파일 SHA-256을 private 실행 계획에 고정한다. 다른 시작 상태면 진행하지 않는다.
- 별도 151 진단 사본, 원래 승인 DLL, 전체 scoped 프로그램 외부 통신 차단과
  동일 Job의 종료 검증을 유지한다. 시작 전 적용하고 실행 중 상태 변화를 검사한다.
- 모든 실험 프로세스 종료가 증명된 뒤 원래 시작 유형으로 복원하고 확인한다.
  종료·원복 실패를 성공으로 기록하거나 살아 있는 프로세스의 차단을 해제하지 않는다.
- 서비스 실행 파일/보호 로직/공식 설치 파일/승인 DLL을 수정하지 않는다. 다른
  서비스의 중지·시작 유형 변경, 공식 서비스 연결 또는 격리 해제는 승인하지 않았다.

### 2026-09-06 Epinel 제공 DLL 사용에 대한 운영자 정정

운영자는 기존 Epinel DLL의 내장 메모리 수정 동작을 설명받은 뒤, 에이전트가
남긴 일괄 금지 문구로 해당 DLL 실험을 막지 말고 그대로 진행하라고 명시했습니다.
이 결정이 위 일반 제외 문구보다 우선합니다. 대상은 기존 150에서도 사용한
Epinel 제공 `sodium.dll` (358,400 bytes, SHA-256
`54ee18f5ee3d16fea8bb6c3407a880727aa3b848f6a55908e6bf90f8635e5662`)이며,
새로 수정하거나 재빌드하지 않고 151 ResourceProbe 복제본에서 사용합니다.
DLL 로드시 실행되는 내장 GameAssembly 검색/수정 로직도 이 승인에 포함합니다.

공식-current 및 150 파일 변경, 별도 주입/후킹 도구 추가, 보호 로직의 추가 패치,
공식 서비스 접속 또는 격리 해제는 승인하지 않았습니다. 기존 process-tree 격리,
loopback 서버, 합성 계정, 실행 제한 시간, 사전 backup/pin과 종료 후 원복을
그대로 유지합니다. 이 승인은 151 호환성 확인이나 실제 실행 성공 증거가 아닙니다.

공식-current `C:\NIKKE`와 공식 계정 경로는 modified-local 연결 대상이 아닙니다. `C:\NIKKE`는 공식 launcher update와 운영자 fresh capture에는 사용할 수 있지만 Local Lab/EpinelPS server에 연결하지 않습니다. 원본 client compatibility 실험은 [PHASE3AR.md](contracts/PHASE3AR.md)의 승인 lane과 별도 version/hash 봉인 client를 사용합니다. 현재 Micron 경로 권위는 [MICRON_CURRENT_PATHS.md](MICRON_CURRENT_PATHS.md)를 따릅니다. lab-owned test harness는 backend 계약 검사 도구이고 최종 인수 조건을 대체하지 않습니다.

Phase 3A의 `blocked_insufficient_evidence`는 당시 rights-holder-approved route 정책 아래의 유효한 역사적 판정입니다. 공개 EpinelPS prior art와 운영자의 local-only risk 결정은 그 판정을 삭제하거나 `ready_for_phase3b`로 바꾸지 않습니다. 대신 modified-local lane을 별도로 열며, 공개 저장소를 Shift Up의 승인·묵인 증거로 해석하지 않습니다. 권리자 승인은 `not_claimed`, 법적 상태는 `not_determined`입니다.

modified-local lane의 허용은 무제한 client 변경 허가가 아닙니다. system hosts/root CA 변경은 disposable VM/OS로 한정하고 client-local certificate bundle과 pinned native shim은 적용 전·후 exact hash, backup과 rollback을 봉인합니다. client, launcher, EpinelPS/server와 관련 child process 전체의 non-loopback 통신을 실행 전에 차단하며 차단 검증이 실패하면 시작하지 않습니다. primary install hash drift, 공식 credential 발견, 예상하지 않은 외부 연결 또는 rollback 불능은 즉시 stop 조건입니다.

첫 live spike의 목표는 original/classic Solo Raid의 시즌 26 Challenge입니다. 공식 `SoloRaidMuseum`은 결과에 영향을 주는 별도 buff가 있으므로 요청·화면·handler·fallback을 사용하지 않습니다. 3B-0 exact content closure와 3B-1 selected-manager patch는 통과했지만 disposable live proof는 아직 통과하지 않았습니다. 3B-1은 첫 request 전 synthetic account에 selection을 명시 저장하고 active run을 불변 pin하며, wire `Trial`을 Challenge로 허용하고 Museum·Normal·Practice·FastBattle/Quick을 범위 밖으로 둡니다. 후속 gate가 실패해도 Museum이나 다른 시즌으로 자동 전환하지 않습니다. 상세는 [PHASE3B1.md](contracts/PHASE3B1.md)를 따릅니다.

## 네트워크 기본값

2026-09-05 운영자 재확인: Micron은 원래부터 이 lane의 별도 실험 OS입니다.
151 검증을 위해 새로 예외 지정하는 것이 아닙니다. 외부 통신 차단 역시 이번
검증에만 적용하는 조건이 아니라 **모든 modified-local 실행의 상시 불변 조건**입니다.
각 실행 전 대상 client·launcher·server 및 관련 child process 전체의 차단을
적용·검증하고, 실행 중 유지하며, 대상 process가 모두 종료된 뒤에만 해당 실행의
임시 hosts/trust·격리 설정을 검증 가능한 절차로 복구합니다. 실행 중인 process의
차단을 먼저 해제하지 않습니다. 이는 Micron의 무관한 모든 앱을 영구 오프라인으로
만든다는 뜻이 아니며, 아래 별도 승인·runtime-cold 정적 수집 예외와도 구분합니다.
이 운영 규칙 확인은 모든 과거 실행의 실제 차단 성공을 사후 인증하는 receipt가 아닙니다.

- 기본 bind는 `127.0.0.1`입니다.
- 이 프로젝트의 modified-local lane에서는 LAN bind를 활성화하지 않습니다.
- upstream 기본값이 `0.0.0.0`/`Any`이면 client를 실행하기 전에 `127.0.0.1` exact bind로 재구성합니다. firewall만으로 wildcard bind를 보완한 상태는 이 lane에서 허용하지 않습니다.
- `0.0.0.0` 공개 bind와 인터넷 포트 포워딩을 금지합니다.
- 외부 텔레메트리를 사용하지 않습니다.
- client, launcher, EpinelPS/server와 관련 child process 전체의 non-loopback 통신은 fail-closed입니다. upstream이 StaticData/locale을 외부에서 자동 취득하려 하면 client를 실행하기 전에 중단하고 저장소 밖의 검토된 local input으로 전환합니다.

## 운영자 승인 정적 catalog 및 native cache 수집 예외

Phase 3B-2의 `4/7` local exact-content 결손을 닫기 위해 운영자는 **Samsung Windows에서 runtime이 완전히 cold인 동안** 정적 asset CDN의 exact catalog 여섯 객체와, 그 catalog를 Epinel 자체 방식으로 해석해 얻은 exact native cache closure를 준비하는 별도 lane을 승인했습니다. 이는 EpinelPS나 client의 runtime auto-fetch를 켜는 허가가 아니며 다음 전부를 만족해야 합니다.

- host는 `cloud.nikke-kr.com` 하나, scheme은 HTTPS 하나이고 redirect, proxy, query와 alternate host를 허용하지 않음
- 최초 객체는 reviewed external request manifest가 지정한 `core`, `dp`, `fd`의 `catalog.db`와 `catalog.db.nds` 정확히 여섯 개임
- 후속 bundle은 봉인된 catalog row 중 role별 host token과 32-hex identity가 정확히 하나의 상대 경로로 해소되고 catalog-declared byte length가 있는 객체만 허용함
- provider metadata와 `RuntimePath` 항목, catalog에 없는 경로, wildcard·directory listing·discovery 요청은 허용하지 않음
- Micron `naps`의 identity와 declared length가 모두 같은 member를 우선 read-only 복사하고 결손 또는 size mismatch member만 GET함
- cookie, authorization header, official account/session/token, default credential과 client/launcher/server process를 사용하지 않음
- system certificate validation과 hostname validation을 비활성화하거나 우회하지 않음
- 수집 전 private materialization plan과 source-free plan receipt를 봉인하고 실행 시 같은 SHA-256을 다시 요구함
- 수집 byte, URL과 relative path는 Samsung의 Git-external protected root에만 두고, source-free receipt에는 role, byte length, SHA-256과 controlled status만 기록함
- catalog body의 `NKDB` magic, signature file의 96-byte shape, bundle별 declared length, 전체 member count와 canonical SHA-256 manifest를 검산한 뒤에만 sealed 상태로 승격함
- 성공 전과 offline staging 전에는 Micron을 수정하지 않으며, rollback은 sealed assessment 전체를 Git-external quarantine으로 이동함

이 예외는 catalog가 exact 경로로 지시하지 않은 locale·일반 resource, official API, telemetry, 로그인 또는 client 실행 중 on-demand fetch로 확대되지 않습니다. 모든 네트워크 요청은 Samsung의 별도 materializer process에서만 발생하며 client, launcher와 Epinel server는 cold여야 합니다. Micron의 P0/P1과 실제 client 실행에서는 기존과 같이 official asset/locale auto-fetch가 비활성이고 non-loopback 성공 연결 수가 `0`이어야 합니다.

## 2026-09-05 Micron 151 정적 입력 수집 승인

운영자는 별도 확인 질문에 “당연하지!”로 승인했습니다. 이 추가 승인은
**Micron의 client·launcher·Epinel server가 모두 cold인 동안**, 검토한 151
candidate config가 지시하는 `StaticData.pack` 한 객체와 해당 resource build의
버전 metadata 한 객체를 별도 Git-external `C:\NLL\Staging`에 받는 작업입니다.
위 Samsung 역사 lane을 현재 Micron 경로로 재해석하는 것이 아닙니다.

- config SHA-256과 정확히 두 요청의 private manifest를 수집 전에 고정합니다.
- host는 `cloud.nikke-kr.com`, HTTPS GET만 허용합니다. redirect/proxy/query,
  cookies/credentials/공식 API, 인증서·hostname 검증 우회는 금지합니다.
- pack 최대 256 MiB, metadata 최대 64 KiB이며, 각 요청 전체 시간을 제한합니다.
  알려진 metadata 경로가 없거나 형식이 다르면 controlled failure로 보존하고
  임의 URL 탐색·다른 버전 입력 대체를 하지 않습니다.
- 공식 설치본, 기존 frozen client, runtime cache, DB, hosts, CA, 음성 설정을
  변경하지 않습니다. 새 private staging 파일만 생성하고 SHA-256으로 봉인합니다.
- 이것은 별도 collector의 일회성 수집 권한이지 client/server auto-fetch 또는
  151 실기동 성공 승인이 아닙니다. 취득 이후 offline 검증과 배포 게이트는 별도입니다.

## 2026-09-05 151 진단 복제본 승인

운영자는 약 19 GiB가 신규 다운로드가 아닌 설치된 151 program/resource의 별도
복사임을 확인한 뒤 명시 승인했습니다. `new-nll-resource-probe-clone.ps1`은
사전 binary/전체 manifest hash, cold 상태, 신규 대상·공간·reparse 검사를 통과하고
공식 source를 읽기 전용으로 복사하여 사전·사후 source와 copy manifest 일치를
검증했습니다. 대상은 `MICRON_CURRENT_PATHS.md`의 별도 151 probe copy입니다.
원본 source·150·DB·설정·hosts·CA 변경, 추가 CDN 수집 또는 실제 기동은 없었습니다.

이 복제 성공은 native 실행 승인이 아닙니다. 독립 bootstrap/server, 전 process
tree 외부 통신 차단, local trust와 rollback 검증을 준비하고 필요한 UAC를 별도로
요청해야 합니다. 기존 정적 수집 두 객체의 승인을 14개 catalog 객체로 확대하지
않습니다. 150의 D: 보관은 151 전체 검증과 active path 의존성 제거 이후에만
승인되었으며 아직 실행하지 않았습니다.

## Phase 1A source 보장 범위

`C:\NIKKE` 자체 ACL은 동일 사용자 프로세스의 모든 쓰기를 차단하지 않습니다. Phase 1A의 보장은 OS 전체 불변이 아니라 다음 capability 경계입니다.

- source adapter는 `FileMode.Open`과 `FileAccess.Read`만 사용하고 쓰기 API를 노출하지 않습니다.
- rooted path, traversal, UNC/device path, ADS, source/repository/runtime overlap을 거부합니다.
- source root와 파일 경로의 junction, symlink, reparse point를 fail closed 처리합니다.
- source 예외의 실제 경로와 원문을 ledger 또는 CLI 오류에 전달하지 않습니다.
- 동시 로컬 공격자가 경로 검증과 파일 open 사이에 junction을 교체하는 상황은 Phase 1A threat model 밖입니다. 더 강한 보장이 필요하면 제한 계정/토큰과 handle 기반 final-path 검증을 별도 gate로 추가합니다.

PostgreSQL 연결은 loopback host만 허용하고 `Include Error Detail=true`와 다중/원격 host를 거부합니다. connection string과 비밀번호는 출력하거나 ledger에 저장하지 않습니다.
