# Security boundary

## 허용

- 로컬 디스크에 이미 존재하는 게임 파일의 읽기 전용 분석
- 자체 생성한 합성 계정과 자체 ID 기반 데이터
- loopback에서 실행되는 API와 관리 UI
- 계약 검증용으로 프로젝트가 소유한 test harness
- 운영자가 명시적으로 승인한 비배포·개인 로컬 compatibility 연구
- exact build/content hash를 고정한 snapshot 가능한 disposable VM/별도 OS와 `127.0.0.1`-only Local Lab/EpinelPS process
- commit `28b2f5413a0a1e3521a11ae162f91851335c8b40`에 pin한 public EpinelPS source의 read-only 감사와 별도 local checkout 실행
- disposable VM/OS에서만 수행하는 system hosts/root CA 변경과, client-local certificate bundle/native compatibility shim 변경. 사전 backup, 원본·적용 SHA-256, 변경 목록과 검증 가능한 rollback이 필수

## 제외

- 공식 서버·공식 API로의 자동 요청
- 공식 로그인, 계정 세션, 쿠키, 토큰 재사용
- live 공식 traffic의 가로채기, credential-bearing capture 또는 공식 session/request replay
- 게임 프로세스 메모리 읽기·쓰기, 코드 주입, 후킹
- 주 설치본 또는 공식 서비스 접속을 위한 anti-cheat/launcher/publisher 보호 기능의 우회·무력화
- `C:\NIKKE` 주 설치본, 공식 account state 또는 공식 진행도의 수정
- manifest에 없는 native binary, certificate 또는 prebuilt selector의 실행
- public/LAN bind, internet port forwarding 또는 제3자 접속
- Local Lab, EpinelPS fork, client/asset, certificate, selector 또는 patched binary의 배포

## 원본 클라이언트 게이트

`C:\NIKKE` 주 설치본과 공식 계정 경로는 계속 연결 대상이 아닙니다. 원본 client compatibility live 실험은 [PHASE3AR.md](PHASE3AR.md)의 `ready_for_local_compatibility_spike` lane에서 exact `150.6.9` snapshot 가능한 disposable VM/별도 OS로만 시작합니다. 단순 디렉터리 복제본은 정적 검산용입니다. lab-owned test harness는 backend 계약 검사 도구이고 최종 인수 조건을 대체하지 않습니다.

Phase 3A의 `blocked_insufficient_evidence`는 당시 rights-holder-approved route 정책 아래의 유효한 역사적 판정입니다. 공개 EpinelPS prior art와 운영자의 local-only risk 결정은 그 판정을 삭제하거나 `ready_for_phase3b`로 바꾸지 않습니다. 대신 modified-local lane을 별도로 열며, 공개 저장소를 Shift Up의 승인·묵인 증거로 해석하지 않습니다. 권리자 승인은 `not_claimed`, 법적 상태는 `not_determined`입니다.

modified-local lane의 허용은 무제한 client 변경 허가가 아닙니다. system hosts/root CA 변경은 disposable VM/OS로 한정하고 client-local certificate bundle과 pinned native shim은 적용 전·후 exact hash, backup과 rollback을 봉인합니다. client, launcher, EpinelPS/server와 관련 child process 전체의 non-loopback 통신을 실행 전에 차단하며 차단 검증이 실패하면 시작하지 않습니다. primary install hash drift, 공식 credential 발견, 예상하지 않은 외부 연결 또는 rollback 불능은 즉시 stop 조건입니다.

첫 live spike의 목표는 original/classic Solo Raid의 시즌 26 Challenge입니다. 공식 `SoloRaidMuseum`은 결과에 영향을 주는 별도 buff가 있으므로 요청·화면·handler·fallback을 사용하지 않습니다. 3B-0 exact content closure와 3B-1 selected-manager patch는 통과했지만 disposable live proof는 아직 통과하지 않았습니다. 3B-1은 첫 request 전 synthetic account에 selection을 명시 저장하고 active run을 불변 pin하며, wire `Trial`을 Challenge로 허용하고 Museum·Normal·Practice·FastBattle/Quick을 범위 밖으로 둡니다. 후속 gate가 실패해도 Museum이나 다른 시즌으로 자동 전환하지 않습니다. 상세는 [PHASE3B1.md](PHASE3B1.md)를 따릅니다.

## 네트워크 기본값

- 기본 bind는 `127.0.0.1`입니다.
- 이 프로젝트의 modified-local lane에서는 LAN bind를 활성화하지 않습니다.
- upstream 기본값이 `0.0.0.0`/`Any`이면 client를 실행하기 전에 `127.0.0.1` exact bind로 재구성합니다. firewall만으로 wildcard bind를 보완한 상태는 이 lane에서 허용하지 않습니다.
- `0.0.0.0` 공개 bind와 인터넷 포트 포워딩을 금지합니다.
- 외부 텔레메트리를 사용하지 않습니다.
- client, launcher, EpinelPS/server와 관련 child process 전체의 non-loopback 통신은 fail-closed입니다. upstream이 StaticData/locale을 외부에서 자동 취득하려 하면 client를 실행하기 전에 중단하고 저장소 밖의 검토된 local input으로 전환합니다.

## Phase 1A source 보장 범위

`C:\NIKKE` 자체 ACL은 동일 사용자 프로세스의 모든 쓰기를 차단하지 않습니다. Phase 1A의 보장은 OS 전체 불변이 아니라 다음 capability 경계입니다.

- source adapter는 `FileMode.Open`과 `FileAccess.Read`만 사용하고 쓰기 API를 노출하지 않습니다.
- rooted path, traversal, UNC/device path, ADS, source/repository/runtime overlap을 거부합니다.
- source root와 파일 경로의 junction, symlink, reparse point를 fail closed 처리합니다.
- source 예외의 실제 경로와 원문을 ledger 또는 CLI 오류에 전달하지 않습니다.
- 동시 로컬 공격자가 경로 검증과 파일 open 사이에 junction을 교체하는 상황은 Phase 1A threat model 밖입니다. 더 강한 보장이 필요하면 제한 계정/토큰과 handle 기반 final-path 검증을 별도 gate로 추가합니다.

PostgreSQL 연결은 loopback host만 허용하고 `Include Error Detail=true`와 다중/원격 host를 거부합니다. connection string과 비밀번호는 출력하거나 ledger에 저장하지 않습니다.
