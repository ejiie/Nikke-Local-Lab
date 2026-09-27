# 버전 독립 런타임 영속성과 로비 Quit

> 2026-09-27 보관: 작성 당시의 기록이며 현재 작업 지시가 아닙니다. 현행 문서는 [문서 색인](../../README.md)에서 찾습니다.

2026-09-17 사용자 요구: 152 실행 통과 확인 후 DB 영속성을 버전에 독립적으로 유지한다.
레이드 로비 Quit은 0~4덱 완료이면 완주 0회·참여 기회 1회 소모,
5덱 완료이면 완주 1회·참여 기회 1회 소모다. 전투 중 Quit/재시도와 구분한다.

## 확인된 원인

- 레이드 aggregate는 계정·시즌·약점 외에 snapshot와 클라이언트 build/exe 해시까지 키로 사용했다.
- 복원은 특정 150→151→152 쌍만 조회했고 5덱 최고 기록이 있을 때만 이관했다.
  이관 함수는 참여 횟수·raid day를 0으로 만들었다.
- 편성 등 runtime preferences도 계정과 build/exe로 분리했다.
- `CloseSoloRaid(Trial)`은 로비에서 중단하면 `TrialCount`를 차감했다.
  `GetUserSoloRaidInfo`는 최고 기록이 없으면 참여 횟수를 응답에 넣기 전에 반환했다.

## 수정 계약

- 레이드의 계속 저장할 대상은 계정·시즌·선택 약점으로 결정한다.
  편성 등 preferences의 저장 대상은 계정으로 결정한다.
- V0023은 기존 aggregate/revision/ciphertext를 변경하지 않고 scope와 revision context를 추가한다.
  기존 여러 버전의 aggregate가 있다면 가장 최근 저장 head를 계속 사용하며 나머지도 보존한다.
  과거 분리된 payload를 임의로 합치거나 삭제하지 않는다.
- 각 revision은 암호화 당시 snapshot/build/exe를 기록한다. 복호화는 해당 출처를 사용한다.
  새 버전에서 저장한 후 옛 버전으로 돌아가도 같은 최신 head를 조회한다.
- revision CAS, operation replay, 최고 기록 후퇴 차단, 전투 이력 append-only 검사는 유지한다.
  버전 전환 때 참여 횟수·raid day·기록·편성을 초기화하지 않는다.
- profile 또는 실제 실행 입력이 달라진 열린 Trial은 abandoned로 닫고,
  이미 승인된 덱 이력과 소모한 참여 횟수는 남긴다. 05:00 초기화 정책은 별개다.
- 로비 Quit은 Open에서 소모한 참여 횟수를 환급하지 않는다. 중복 Quit은 추가 소모하지 않는다.
  완주 판정과 최고 기록은 다섯 번째 유효 덱 결과에서만 확정한다.

## 검증·설치 상태

- 외부 서버 테스트 153개 통과: 0~5덱 로비 Quit, 중복 Quit, 기존 전투 재시도 포함.
- 전체 합성 PostgreSQL 118개, 실제 암호화 capture/persist/restore 74개 통과.
- 기존 22→23 이관과 버전 간 동시 저장을 추가한 집중 PG 10개 통과.
  기존 revision 전체 내용 지문 불변과 migration 재실행 0건을 확인했다.
- 외부 수정 재현: `patches/epinel-lobby-quit-attempt-consumption.patch`와 LF 정규화 manifest.
- 저장소 필수 8개 gate 모두 통과. 기존 환급을 요구하던 source guard를 운영자 확정 규칙에 맞췄다.
- 2026-09-17 17:41 KST 설치 완료: 서버·materializer·관리도구 저장 모듈과 연결 설정 8개 파일.
  DB schema 22→23, 기존 93개 테이블의 행 수·내용 지문 불변, migration 재실행 0건.
  S41 수냉·S26 철갑 준비 검사 `ready`, PostgreSQL 정상 종료, 유지보수 잠금 해제.
- 백업: `artifacts/runtime-persistence-20260917/installation-backup/database.dump`와 `files.json`.
  백업 디렉터리는 현재 운영자·SYSTEM·Administrators로 접근을 제한했다.
- 설치 영수증: `installation.receipt.json`, `installed-preparation.receipt.json`.
  bundle SHA-256 `de97fcf0782979b760d3b4563c988663f3faa0915ea59f80eb9872e44b7466b1`.
  pipeline 설정 SHA-256 `d439bf3a7eaf212d8c64b725951ee7641117e32910779b6753f4ee65e50dcdcc`.
- 작업 증거: `artifacts/runtime-persistence-20260917/`.
- 이 수정에 대한 사용자 실게임 인수는 별도다. 앞선 152 실행 통과와 혼동하지 않는다.
