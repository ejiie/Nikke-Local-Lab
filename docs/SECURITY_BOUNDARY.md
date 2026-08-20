# Security boundary

## 허용

- 로컬 디스크에 이미 존재하는 게임 파일의 읽기 전용 분석
- 자체 생성한 합성 계정과 자체 ID 기반 데이터
- loopback에서 실행되는 API와 관리 UI
- 계약 검증용으로 프로젝트가 소유한 test harness
- 사용자가 명시적으로 활성화한 사설망의 lab-owned client
- 권리자가 제공·지원·승인하고 build/hash와 허용 범위가 고정된 local/test compatibility client 및 UI variant

## 제외

- 공식 서버·공식 API로의 자동 요청
- 공식 로그인, 계정 세션, 쿠키, 토큰 재사용
- 패킷 가로채기 또는 공식 프로토콜 replay
- 게임 프로세스 메모리 읽기·쓰기, 코드 주입, 후킹
- 안티치트 우회 또는 무력화
- 원본 리테일 클라이언트의 서버 주소·인증 흐름 변조
- launcher 또는 publisher handshake의 비활성화

## 원본 클라이언트 게이트

원본 리테일 클라이언트는 `docs/FEASIBILITY_GATES.md`의 모든 조건이 충족되기 전까지 연결 대상이 아닙니다. 현재 실제 연결이 허용된 client는 lab-owned test harness뿐이지만, 이는 backend 계약 검사용 임시 수단이며 최종 인수 조건을 대체하지 않습니다. 기술적으로 가능한 경로와 프로젝트 정책상 허용된 경로를 혼동하지 않습니다.

gate가 열리면 승인된 원본 client가 최종 실행 경로가 되고 harness는 계속 자동 테스트에만 사용됩니다. gate가 열리지 않으면 최종 인수 상태는 `blocked`입니다.

stock retail client를 임의로 private server에 연결하는 경로와 승인된 isolated local/test compatibility client는 같은 것이 아닙니다. 전자는 계속 제외합니다. 후자는 Phase 3A에서 권한·route/build 증거가 `ready_for_phase3b`로 판정된 뒤에만 승인 범위의 격리 평가 연결을 시작할 수 있습니다. 제품 활성화는 wire, presentation, outbound와 runtime integrity gate를 모두 통과한 뒤에만 허용합니다.

승인된 presentation variant가 고정 lobby widget 제거·재배치, multi-season folder, permanent season 표시와 controlled no-op을 소유할 수 있습니다. 원본 asset이나 patch output은 Git에 넣지 않으며 빈 응답, protocol 오류, memory patch 또는 hooking을 UI 제어 수단으로 사용하지 않습니다.

## 네트워크 기본값

- 기본 bind는 `127.0.0.1`입니다.
- LAN은 설정에서 명시적으로 활성화해야 합니다.
- LAN 활성화 시 사용자가 관리하는 기기, 정확한 사설 IP, 허용 CIDR을 지정하고 local authentication을 먼저 활성화합니다.
- `0.0.0.0` 공개 bind와 인터넷 포트 포워딩을 기본 금지합니다.
- 외부 텔레메트리를 사용하지 않습니다.
- 공식 outbound는 fail-closed입니다. 차단을 검증하지 못하면 원본 client 실행을 시작하지 않습니다.

## Phase 1A source 보장 범위

`C:\NIKKE` 자체 ACL은 동일 사용자 프로세스의 모든 쓰기를 차단하지 않습니다. Phase 1A의 보장은 OS 전체 불변이 아니라 다음 capability 경계입니다.

- source adapter는 `FileMode.Open`과 `FileAccess.Read`만 사용하고 쓰기 API를 노출하지 않습니다.
- rooted path, traversal, UNC/device path, ADS, source/repository/runtime overlap을 거부합니다.
- source root와 파일 경로의 junction, symlink, reparse point를 fail closed 처리합니다.
- source 예외의 실제 경로와 원문을 ledger 또는 CLI 오류에 전달하지 않습니다.
- 동시 로컬 공격자가 경로 검증과 파일 open 사이에 junction을 교체하는 상황은 Phase 1A threat model 밖입니다. 더 강한 보장이 필요하면 제한 계정/토큰과 handle 기반 final-path 검증을 별도 gate로 추가합니다.

PostgreSQL 연결은 loopback host만 허용하고 `Include Error Detail=true`와 다중/원격 host를 거부합니다. connection string과 비밀번호는 출력하거나 ledger에 저장하지 않습니다.
