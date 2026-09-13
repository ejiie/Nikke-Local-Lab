# Backend stabilization — current work plan

## 현재 인수 작업 — 2026-09-12

운영자 요청: 직접 하는 실 테스트를 제외한 안정화 후속 작업을 완료하고 테스트 순서·합격
기준을 제공한다. **제품 소스 `1cf8784`의 전체 자동 검사·설치 반영·설치 API smoke를 완료**했다.
단위 486개·격리 PG 112개·계약/서식/build 통과와 실제 계정 2개의 읽기·정상 종료를 확인했다.
이후 운영자가 "모두 정상 동작을 확인했다"고 보고하여 직접 하는 WebView2/원본 Challenge 인수도 완료했다.
운영자의 별도 승인으로 GitHub 원격을 비공개로 전환하고 API 재확인해 소스 게시 차단을 해제했다.
정확한 receipt·실패 점검의 수정·백업 범위는 [HANDOFF](HANDOFF.md)의 최신 절에 기록한다. 아래 날짜별 발견/‘남음’은
그 시점 이력이며 이 절과 최신 인계보다 우선하지 않는다.

- S-08: bounded revision-readiness cache로 반복 목록 조회의 full-profile 재구성을 제거한다.
  최초 조회/실행 export는 hash-verified aggregate를 유지한다. 256개 제한, account/revision/hash
  분리, Save 경합, 새 서비스 및 eviction을 합성 PostgreSQL에서 검증한다.
- S-08 측정: 50/100계정의 명시적 ANALYZE 전후와 dense(모든 캐릭터 4장비·각 OL 3줄) fixture를
  비교한다. PDH의 물리 디스크 전체 raw 누적 byte 차이는 **호스트 전체 disk-stack I/O**이며
  해당 DB/요청에 단독 귀속하거나 SSD NAND write로 표현하지 않는다. PostgreSQL buffer와 구분한다.
- S-09: 준비 300초 / 완료 180초 / pg_ctl wrapper 90초. pg_ctl 자체 `-w/-t`는 보존한다.
  사전 identity reservation → PID/start/path 기록 → exact-child wait 순서다. 기한 초과는
  강제 종료·동시 rollback을 하지 않고 `started`/controlled failure를 유지한다. 재실행 복구는
  기록된 모든 자식의 종료를 확인하며 누락/변조/PID reuse는 fail closed한다. 사용자가 실제로
  플레이하는 동안 watcher가 client를 기다리는 것은 이 준비/완료 기한과 구분한다.
- S-09 desktop: stdout/stderr 동시·bounded drain, 시작/navigation 예외 관측, 시작/페이지/스크립트
  기한, 실패 exit code, 중복 종료 방지, 늦은 host의 stop signal 보존. stop을 만든 desktop/test가
  host 종료 확인 후 해당 signal만 지운다. UI/게임은 합성 프로세스 검사와 별도 인수다.
- S-09 감사: 운영 DB를 켜지 않은 cold backup 복제본에서 스키마/체크섬, head/lineage/Save 결과
  소유자/provenance/암호화 payload hash를 확인했다. 배포 전 감사 `cb9ea3de443649e7ba92fd3153073f7b`는
  schema 18, Save operation 102개, DB pending·암호화 pending 0개, 검사 불일치 0개다.
  복제본 종료와 원본/백업 파일 hash 일치를 검증했다. 실 DB의 행을 정리하거나 추정 복원하지 않았다.
  설치 smoke 후 감사 `912d47e8331645abb69eefb14e2cbef1`에서도 같은 스키마·operation 수와 pending/불일치 0개를 확인했다.
- 잔여 코드 검토의 종료 범위는 importer 입력 크기/정규화/controlled error, domain revision·collection
  불변성, automation inventory/state transition, desktop 시작·종료와 해당 회귀 검사다.
  automation inventory의 root/ancestor reparse 우회를 닫고 같은 hash의 외부 파일도 거부한다.
  프로젝트 전체 모든 줄의 형식적 증명/무결함 인증을 주장하지 않는다.
- S-10: 현재 인수 상태, 날짜별 발견 기록과 Phase 역사 명세를 구분하고 단일
  [실 테스트 체크리스트](operations/STABILIZATION_ACCEPTANCE.md)로 연결한다.

P-01~P-09, S29/신규 보스/실드/150 보관 이동은 이 안정화 완료 요청에 자동 포함하지 않는다.
소스 게시와 실제 Actions 결과는 [GitHub 자동화](operations/GITHUB_AUTOMATION.md)의 비공개 경계를 따른다.

## S29와 공통 파이프라인 — 2026-09-12 착수

운영자는 S29 수정과 공통 파이프라인 개선을 함께 진행하고, 이후 완전 자동화를 목표로
하도록 요청했다. **아래 QTE 데이터 변환은 1차 구현이며 S29 전체 수정·활성화 완료가 아니다.**
2026-09-13 운영자 지시로 **실게임 실행·화면/전투 인수는 운영자 담당**, 그 외 구현·
오프라인/자동 검사·UI/API·검증용 배포·CI/병합은 에이전트 담당이다. 기존 S26 인수를
다시 요구하지 않고 새 보정 FX/신규 시즌의 사용자 검증과 구별한다.

- [x] S29-QTE-01: v3 프로필의 해시·행 수·몬스터 참조 수에 맞는 QTE만 선택하여 보스 속성과
  함께 변환한다. 기존 QTE prefab/그룹/제한 시간/초기 애니메이션/랜덤 설정과 다른 행은
  직렬화 바이트 단위로 보존한다. 재패킹·복호화 후에도 변경 범위를 다시 검증한다.
- [x] PIPE-QTE-01: 구형 프로필로 속성 QTE를 누락한 변형을 만들거나 v1/v2에 v3 필드를
  끼워 넣는 것을 거부한다. 현재 v2 assembler는 QTE discovery 결손/적용 대상을 발견하면
  `boss_profile_qte_discovery_missing` / `boss_profile_qte_v3_pipeline_required`로 중단한다.
  **v3 자동 조립을 구현한 것으로 간주하지 않는다.**
- [x] 합성 QTE 37개, Python assembler 검사 4개(결손/변조 세부 사례 포함), 봉인된 151
  입력의 S26/S29 각각 5약점 오프라인 왕복 검사를 통과했다. S29 비기본 약점은 QTE 5행,
  기본 철갑 약점은 0행 변경이며 ElementTable 및 원본 입력은 보존한다.
- [ ] S29-FX-02: 쉴드 FX 크기/위치 보정을 실행별 격리 자산에 적용하고 실제 client 전달,
  hash pin·복구·실행 후 정리를 연결한다. 현재 derived runtime의 cache junction은 부모와
  공유하므로 그 경로에 보정 bundle을 덮어쓰지 않는다.
  - [x] FX-CANDIDATE-01: v3 프로필 pin으로 원본 FX와 보정 결과를 대조하여 독립 후보를
    생성·봉인한다. 원본 사본과 대상 밖 Transform/비-Transform 객체를 보존하며, 후보의
    보정 파일만 복구한다. 전체 사전 검사, 중단된 복구 재시도, 중복 요청·junction·hardlink·
    변조 차단을 포함한다. 실제 로컬 FX 3종의 예상 해시 재현·복구 2회·복구된 후보 재사용
    거부와 설치 v6 96개 pin 보존을 확인했다. **client 전달/설치 rollback은 아직 아니다.**
  - [x] FX-HTTP-01: 후보 전체 재검증 후 실행별 독립 사본·private route manifest를 봉인한다.
    정확한 raw HTTP 경로, 전체/range/HEAD 응답, 실행 binding, 사용 중 정리 차단과 종료 후
    사본 정리·중단 재시도를 구현했다. 합성 staging 9개·신규 .NET 19개 및 실제 151 FX 3종
    HTTP/정리 검사가 통과했다. 공유 cache/설치 v6 96개 pin은 불변이다.
    **아직 설치 Epinel 경로에 연결하지 않았으며 원본 client 수신·캐시/CRC·화면 증거가 아니다.**
  - [ ] FX-RUNTIME-02: 새 외부 Epinel 후보에 source-linked HTTP 모듈을 연결하고 전체 실행
    process tree 종료 후 정리를 coordinator에 결박한다. 원본 client 기존 캐시와 catalog
    검증을 조사하여 격리 전달 방식을 확정한다. 구 설치본/공유 junction을 덮어쓰지 않는다.
    - [x] 외부 후보 연결: 독립 Epinel 후보 빌드, 시작 환경 6개/실행 binding과 오류 시
      원본 fallback 차단, host 종료 후 transport 해제를 구현했다. 신규 합성 12개와 실제
      후보 DLL의 FX 3종 HTTP·기존 static-pack handler·검사 사본 정리를 검증했다.
    - [x] 151 카탈로그 1차 조사: 내장/core patch 각각 26,491 bundle 항목에서 현재 FX
      파일명 exact 일치는 3종 모두 0이다. hash suffix를 제외한 이름은 각각 1개지만
      이를 같은 자산으로 승인하지 않는다. 151의 `type_rowid,is_local` 스키마는 구 150의
      hash/CRC 구조와 다르다. **카탈로그/클라이언트 수정과 native 전달 성공은 아니다.**
    - [x] 151 오프라인 자산 재결박: 기존 내부 키를 내장/core 카탈로그 양쪽에서 exact 조회하고
      동일 dependency 관계·설치 청크 hash/offset·로컬 의존 번들·추출 후 내부 키를 확인했다.
      전기 원본 포함 4개 모두 기존 byte와 다르며 새 151 FX 3종의 Transform 4/6/4개를 보정했다.
      합성 카탈로그/청크 203개·Python 63개와 실제 입력 검사가 통과했다. 설치/등록은 불변이다.
    - [ ] 실행별 native 청크/캐시 전달과 검증/rollback. 현재 재결박은 오프라인 후보이며
      원본 client 수신·렌더링 증거가 아니다. CIDX trailer 계산 규칙은 해소됐지만 구 HTTP 경로나
      파일명 suffix 교체로 대체하지 않는다. 추가 디스크 정적 조사에서도 실제 local provider
      경로·수정 카탈로그 서명 수락 경로가 미해소다. 원래 `.nds` 재사용을 검증 성공으로
      표시하지 않으며, 새 native 패치 없이 전달을 입증하지 못한 상태다.
      - [x] 오프라인 고정 길이/청크 도구와 독립 저장소 사본: 151 FX 3종의 모든 객체,
        정확한 청크 참조·압축 길이와 원복 byte를 검증한다. 6.57GB 독립 사본의 전체 hash
        A→B→A·원복 2회·원복된 후보 거절을 확인했다. 기존 digest는 보정 byte와 불일치하며
        **설치/실행 연결·native 수락을 뜻하지 않는다.** 상세와 pin은 보스 파이프라인/인계 참조.
    - [x] 전체 트리 종료/정리 **소스 경로**: 새 runner input v3/bundle v2, 생성 시점 Job
      소속, watcher ready/commit, 같은 살아 있는 Job의 잔류 0 확인과 종료 receipt,
      completion/rollback gate 및 선택적 FX 정리 명령을 연결한다. 구 v1 봉인은 유지한다.
      비정상 lease는 독점 접근·실행/manifest/proof pin·실제 Job 조회 후에만 복구한다.
      신규 회귀 검사는 실제 Windows API와 합성 프로세스/자산만 사용한다.
      **설치 배포·native 전달/복구 인수는 아니다.** 현재 coordinator의 FX binding은 null이며
      S29 차단을 유지한다. 모든 소유자 crash로 Job 증거가 소실된 경우에는 자동 복구를
      성공 처리하지 않는다. Job의 생명주기 관리와 전체 비루프백 통신 차단도 별도 조건이다.
- [x] PIPE-V3-02 후보 경로: discovery → 원본 행동 트리 closure → QTE 포함 v3 후보 조립 →
  FX 보정 → 5속성 검증을 `-CandidateOnly` 공통 명령으로 연결했다. 후보와 실행 admission을
  분리하고 새 출력 폴더만 허용한다. 합성 12개(실제 PowerShell 실패/재시도 검사 포함),
  실제 151 입력 S29/S26 10개 속성 후보와 FX 3종을 검증했다. 설치/registry는 불변이다.
- [ ] PIPE-PUBLISH-03: 후보 이후 실제 전달/복구 gate, 프로필·registry 게시 원자성,
  job API와 같은 시즌 중복 요청·조회·재시도 상태를 구현한다. 현 후보 receipt를 UI의
  최종 가져오기 성공이나 실행 가능 상태로 승격하지 않는다.
- [ ] S29-ADMIT-03: 위 조건을 갖춘 새 번들로 v3 preparation/coordinator/receipt 검증을
  함께 갱신한 후 등록 pin과 활성화를 진행한다. 현재 S29 v3 draft/v2 registry 불일치와
  실행 차단은 유지하며 S26/v6 설치를 변경하지 않는다.
- [ ] UI-RAID-01: 아래 시즌 선택/예·아니오/완료 팝업 흐름을 job API와 연결한다.
- [ ] 운영자 실게임 인수: S29 패턴·QTE·5약점·속성 쉴드의 전투 동작을 확인한다.
  데이터 왕복 성공이나 UI 완료 팝업으로 실제 전투 인수를 대체하지 않는다.

재현 명령과 로컬 증빙은 [보스 파이프라인](features/BOSS_ONBOARDING_PIPELINE.md)의
현재 자동 후보 단계 절을 따른다. 원본 pack·bundle·DB는 커밋하지 않는다.

## 보스 파이프라인 후속 TODO — 시즌 선택 UI (2026-09-12)

운영자는 S29/보스 추출 파이프라인 후속 작업에 아래 UI 변경도 포함하도록 요청했다.
**요구사항/TODO 등록이며 아직 UI 구현·배포·실게임 검증을 완료한 것이 아니다.**
첨부된 현재 화면은 카드와 속성 선택 UI의 시각적 참고이며, 세 보스를 계속 나란히
노출하라는 요구가 아니다. 이 목록은 완료된 안정화·영속화 인수와 별도로 관리한다.

### UI-RAID-01 — 시즌 목록과 선택 보스 설정 화면 분리

- [ ] 솔로 레이드에 `[시즌 선택]` 버튼을 제공한다. 누르면 별도의 시즌 선택 창/화면으로
  이동하여 **시즌 1부터 현재 시즌까지** 탐색할 수 있게 한다. 현재 시즌 번호는 고정 상수가
  아니라 검증된 시즌 목록의 출처·기준 시점으로 해소한다. 로컬 입력이 최신인지 확인되지
  않으면 그 상태를 표시하고, 결손 시즌의 보스·약점은 추정하여 채우지 않는다.
- [ ] 시즌 선택 창의 각 카드에는 **`SEASON N`·보스 사진·보스명·기본 약점 속성**을 표시한다.
  기본 약점은 그 시즌 원본 데이터의 값이다. 사용자가 실행 약점을 변경해도 목록의 기본
  약점 표시는 바꾸지 않는다. 같은 보스라도 시즌별 패턴이 다르므로 이름/사진 기준으로
  합치지 않고 시즌별 항목과 정확한 manager/preset/behavior 결박을 유지한다.
- [ ] 정보 처리가 완료된 시즌 카드를 누르면 해당 시즌의 보스 설정 화면으로 이동한다.
  이 화면에는 **선택한 보스 카드 하나와 5속성 선택 UI만** 보스 설정 영역에 표시한다.
  예를 들어 S26 선택 시 프로비던스 카드만 남기고 마더 웨일·앨트루이아 카드는 숨긴다.
  다른 보스를 흐리게 표시하거나 disabled 카드로 남겨두는 방식으로 대체하지 않는다.
- [ ] 정보 처리가 되지 않은 시즌 카드를 누르면 다음 확인 팝업을 표시한다.
  첫 줄은 `Season N 보스`, 다음 줄은 `{boss.name}을 불러오시겠습니까?`이며
  `[예]`와 `[아니오]` 버튼을 제공한다. 이름은 해당 시즌의 검증된 표시 이름을 사용한다.
- [ ] `[예]`를 누르면 확인 팝업을 즉시 닫고 공통 파이프라인으로 보스 데이터·스킬·
  원본 행동 트리 조립, 5속성 변형과 속성 쉴드/QTE 처리를 시작한다. 작업 중에는
  처리 상태를 표시하고 같은 시즌의 중복 요청을 방지한다. 화면 이동이 중복 작업을
  만들거나 완료 결과를 잃게 하지 않는다. 실제 처리·필수 검증 완료 후 완료 알림
  팝업을 띄우고 그 시즌을 정보 처리 완료 상태로 갱신한다. 완료 알림 자체가 게임을
  실행하거나 실게임 인수를 완료 처리하지 않는다.
- [ ] `[아니오]`를 누르면 확인 팝업만 닫는다. 가져오기 요청·작업 생성·등록 변경을 하지 않는다.
  처리 실패·결손·차단은 완료 팝업으로 표시하지 않고 실패/차단 이유와 재시도 가능 상태를
  구분한다. 다음 카드 클릭은 검증된 처리 완료 상태에 따라 보스 설정 화면으로 연결한다.
- [ ] 선택 보스 화면은 첨부 화면의 카드·약점 선택 구성을 활용하되, 시즌 번호와 기본 약점을
  확인할 수 있게 하고 **실행용 현재 선택 약점**을 별도로 표시한다. 작열·수냉·풍압·전격·철갑
  다섯 선택지를 제공한다. 여기서 5속성은 현재 제품의 실행 전 약점 선택을 의미하며,
  진행 중인 전투의 속성을 즉시 변경하는 기능으로 확장하지 않는다.
- [ ] 시즌 목록으로 돌아가 다른 시즌을 선택할 수 있게 한다. 선택 변경 시 보스 카드·시즌·
  약점 설정·준비 판정이 같은 시즌을 참조하도록 하고, 이전 시즌의 준비 완료 표시를
  재사용하지 않는다. 계정 선택·최근 실행·상태 확인·시작 기능은 기존 실행 조건을 유지한다.
- [ ] 목록에 보이는 것, 정보 처리가 완료된 것, 현재 실행 가능한 것을 구분한다. 미처리/
  처리 중/실패 항목은 상태를 표시하고 기존 보스 가져오기 후속 흐름과 연결한다.
  등록된 프로필이라도 drift·리소스 결손·계정 미선택이면 이유를 표시하고 시작을 차단한다.
  시즌 1~현재의 **목록 확대가 모든 시즌의 실행 허용이나 자동 publish를 뜻하지 않는다.**

완료 검사:

- [ ] 시즌 목록은 첫 시즌과 현재 시즌을 포함하며, 같은 보스의 서로 다른 시즌이 별개로 보인다.
- [ ] 각 목록 카드의 기본 약점은 실행용 약점을 바꾸거나 목록으로 돌아와도 원본 값으로 유지된다.
- [ ] 처리 완료 S26 선택 시 상세 화면의 보스 카드는 정확히 하나이며, S29/S34 카드는 보이지 않는다.
- [ ] 미처리 시즌 클릭 시 시즌·이름·예/아니오 팝업이 맞고, 아니오는 요청 없이 닫기만 한다.
- [ ] 예를 누르면 확인 팝업이 닫히고 정확히 한 작업이 생성된다. 성공 시에만 완료 팝업과
  처리 완료 상태를 표시하며, 실패/중복 클릭/화면 이동/재조회는 거짓 완료나 중복 작업을 만들지 않는다.
- [ ] 5속성 선택과 시즌 재선택 시 표시·요청·준비 결과가 일치하고 늦게 도착한 이전 응답은 무시된다.
- [ ] 미처리/처리 실패/프로필 불일치/계정 미선택을 준비 완료 또는 실행 가능으로 표시하지 않는다.
- [ ] UI 자동 검사 후 운영자가 목록 이동·한 카드 표시·약점 선택을 확인한다. 보스 스킬·QTE·
  속성 실드의 runtime 인수는 별도의 파이프라인 검증이며 화면 구현으로 대체하지 않는다.

파이프라인의 기존 구현 및 역사적 S29 결과는
[보스 추가 파이프라인](features/BOSS_ONBOARDING_PIPELINE.md)을 참조한다.
현재 S29의 v3/등록 v2 불일치와 QTE·실드 보정 연결은 별도 선행 과제이며, 이 UI TODO로
기존 등록 해시·실행 허용·원본 asset·설치본을 변경하지 않는다.

## 상태와 범위 — 2026-09-06

운영자가 **관리도구 → 151 → S26 실게임 검증 완료**를 보고했고 리소스 변화 대응을 종료했다.
검증된 Epinel DLL과 실행 설치본은 유지한다. S29의 기존 v3/v2 불일치, 신규 보스,
실드 확장, 분석 UI 등 기능 작업을 이번 안정화와 섞지 않는다.
2026-09-06 추가로 확정한 원본 `My Records` 이력 및 접속 간 상태 보존 요구는 아래
영속화 미완료 과제로 관리한다. 별도 분석 UI 신설이나 이 문서 변경만으로 구현을 승인·완료한 것은 아니다.

1차 점검 산출물은 **구조 점검과 정비 계획**이며, 당시 제품 코드·SQL migration·운영 DB·
설치본은 수정하지 않았다. 이후 별도 승인으로 서식 수정과 아래 실행 생명주기 1차 소스 정비를 진행했다. 운영 DB 전체 무결성,
전체 파일 완독, 성능 개선 또는 안정화 완료를 주장하지 않는다.

### 서식 수정 당시 검사 기준선 — 2026-09-06

- `AccountImportExecution.cs`와 `Automation.Cli/Program.cs`의 서식 진단 35건을 해소했다.
  Roslyn으로 변경 전후 토큰과 공백·줄바꿈을 제외한 trivia를 대조해 로직·문자열·주석 보존을 확인했다.
- 전체 solution 서식 검사, Phase 2A1·2A2·2B 단위 검사 체인, 자동화 단위 검사가 통과했다.
  중복 실행을 제외한 단위 테스트는 409개이며, 저장소·Phase 0·3A/3B0/3B1/3B2 계약·Actions 검사도 통과했다.
- PostgreSQL 통합 검사는 전용 `NIKKE_LAB_TEST_DB`와 reset token이 미설정이므로 미실행이다.
  운영 DB·설치본·DLL·실행 로직은 변경하지 않았다. 아래 서식 실패 기록은 수정 전 이력이다.

### 1차 점검 당시 조사 범위와 아직 남은 조사

- `src/tests/scripts/tools/docs/config/contracts`에서 생성 `bin/obj/node_modules`,
  SDK 캐시와 package lock을 제외한 주요 코드/SQL/JSON/문서 목록: **827개, 258,453줄**.
- 별도 목록: PowerShell **322개**, Markdown **49개**. 크기는 조사 순서를 정하는
  지표이지 그 자체로 결함 판정이 아니다.
- 상세 추적: Admin 실행 서비스 → coordinator → materializer → watcher/recovery,
  workspace Save/Save As 조정, profile 조회·candidate export, 레이드 영속 store,
  관련 SQL 제약·테스트·현행 및 과거 운영 문서.
- 다음 조사: 나머지 importer/domain/automation/desktop 메서드 단위 검토,
  외부 Epinel 서버의 실제 사용 경로와 패치 출처 대조, 운영 DB 읽기 전용 무결성·용량
  검사, 폐기 가능한 DB에서의 동시성/중단 재현, 성능 측정. 아직 완료로 표시하지 않는다.
- 원본 asset, 계정 raw, 인증 정보, DB dump, 대용량 세션 기록을 통째로 열거나 복제하지 않는다.

## 현재 실제 실행 구조

```text
관리도구 / Admin API
  ├─ PostgreSQL의 profile·workspace 조회/Save
  └─ 실행 요청 → PowerShell coordinator
       ├─ bundle + boss profile 선택 / candidate → 파생 Epinel DB
       ├─ PostgreSQL 중지 → 기존 native bootstrap / Epinel / NIKKE
       └─ 종료 watcher 또는 orphan recovery
            → 레이드 pending 캡처 → transient 복원
            → PostgreSQL 재시작 → exact replay / CAS → terminal 상태
```

이는 과거 설계도의 “향후 loopback shadow bridge”와 동일한 구현이 아니다.
현재 동작을 먼저 명세하고, 미래 설계에 맞추기 위해 정상 동작을 임의로 바꾸지 않는다.

## 1차 발견 사항

`확인`은 현 소스/실행한 검사로 확인한 구조 또는 결과다. `위험`은 그 구조에서 가능한
실패 경로로, 운영 환경 재현이나 데이터 손상 사실과 구분한다.

### S-01 / 높음 — 시작·조회·복구의 책임과 대기가 결합됨

- 확인: `src/NikkeLocalLab.Admin.Api/PhaseDExecution.cs:130,214,245,252,355`.
  Start와 GET이 동일 `_launchGate`를 잡고, GET도 전체 실행의 orphan 복구를 호출한다.
  시작/복구 자식 프로세스 대기는 `CancellationToken.None`이며 별도 기한이 없다.
- 위험: 자식 준비/복구가 멈추면 상태 조회까지 대기한다. HTTP 취소로 안전한 복구를
  중단하지 않는 의도는 보존해야 하지만, 이것이 무기한 요청 대기를 요구하지는 않는다.
- 방향: 장기 작업의 소유권을 요청 수명과 분리하고, 조회는 저장된 상태만 반환한다.
  하나의 lifecycle owner가 준비·시작·종료·영속화·복구 전이를 기록한다.
  단계별 기한과 안전한 실패/복구 경로를 함께 둔다. 단순 잠금 삭제는 하지 않는다.

### S-02 / 높음 — 과거 상태 파일 하나가 다른 실행의 조회까지 막을 수 있음

- 확인: `PhaseDExecution.cs:280,301,449`의 전체 디렉터리 순회에서 각 상태를 즉시
  역직렬화하며, 손상된 한 파일의 예외를 항목 단위로 격리하지 않는다. GET도 이 순회를 탄다.
- 위험: 다른 계정 또는 과거 실행의 손상 상태 때문에 현재 실행 조회·시작이 실패할 수 있다.
  기록이 늘면 상태 폴링의 I/O도 함께 증가한다.
- 방향: active 실행 색인과 과거 기록 조회를 분리한다. 손상 기록을 진단 가능하게 보존하고
  정상 과거 기록 조회는 제공한다. **소유권을 확인할 수 없는 active 기록은 계속 시작을
  막는다**. 손상 파일 무시 후 실행하는 식으로 안전 장치를 제거하지 않는다.

### S-03 / 높음 — snapshot 읽기가 상위 조정 단계에서 다시 분리됨

- 확인: `PostgreSqlProfileManagementService.cs:114,424,4580`에서 workspace head,
  readiness용 current profile, candidate 값용 current profile을 별도 호출로 읽는다.
  개별 `PostgreSqlLocalAccountProfileStore.GetCurrentAsync:215`에는 RepeatableRead가
  있지만 이들 전체를 묶는 snapshot은 아니다. API의 lobby 조회도 별도다.
- 위험: Save와 Launch/Export가 겹치면 이전 head와 이후 값이 섞인 candidate를 만들
  여지가 있다. 이는 동시성 재현 대상이며 **DB 손상이나 실제 발생을 확정한 것은 아니다**.
- 방향: 하나의 read snapshot 또는 명시적으로 고정한 immutable revision set에서
  candidate/lobby를 만든다. 동시 Save를 끼워 넣어 서로 다른 revision 혼합이 없음을 검증한다.
- 소스 정비: workspace/profile/readiness/lobby를 한 RepeatableRead로 읽고 실행 API가
  묶음 하나를 소비하도록 변경했다. 목록 readiness는 표시한 immutable profile revision을 읽는다.
  다단계 Save 중간 commit은 별도의 pending 검사로 막으며, 편집·복구용 조회는 유지한다.
  완료 범위와 검증 결과는 아래 S-03 검사 절을 따른다. 운영 DB 손상이나 설치본 수정은 주장하지 않는다.

### S-04 / 높음 — 버전·보스 선택의 판단 지점이 여러 곳임

- 기존 결함: API는 registry의 enabled만, coordinator는 별도의 hash/schema를 검사했다.
  S29 v3 파일과 v2 등록값 불일치로 UI 표시와 실행 가능 여부가 어긋났다.
- 2026-09-08 소스 1차 반영: `Nll.PhaseDPreparation.ps1`이 registry의 단일 enabled 항목,
  경로 경계, profile hash/schema/속성 FX, 선택 bundle과 적용된 파일 pin을 판정한다.
  UI의 CSRF 보호 POST 준비 명령과 Start 및 coordinator가 같은 함수를 사용한다.
  외부 응답은 `nll/phase-d-preparation/v1`의 8개 source-free 필드뿐이며, 실제 경로·profile은
  반환하지 않는다. 상태 GET은 프로세스를 만들지 않는다. 준비 명령의 읽기 전용 자식은 숨김 실행,
  90초 제한·취소·출력 상한을 가지며 게임/실행 소유자와 구분한다.
- UI는 확인 중/차단/확인 완료를 구분하고 오래된 응답과 조회 실패로 시작을 허용하지 않는다.
  Start는 캐시 없이 다시 검사하고 registry/profile/selection/manifest 해시와 선택 속성의
  binding을 coordinator에서 재확인한다. 실제 실행의 계정 snapshot·coldness·firewall·asset
  closure 검사는 유지한다. 구성 `ready`는 실게임 성공 또는 실행 허가 전체를 뜻하지 않는다.
- 151 bundle을 입력 존재 검사보다 먼저 선택해 불필요한 150 client/도구 선행 검사를 없앴다.
  **과거 seed DB·부모 도구·출처 pin 의존은 아직 남아 있다. 150 폴더 이동 승인이 아니다.**
  S26/151 준비 통과, S29는 `phase_d_boss_variant_profile_drifted`로 차단됨을 읽기 전용 확인했다.
  S29 profile/registry와 151-v5/Epinel DLL을 변경하지 않았다.

### S-05 / 높음 — 실행 코드의 문자열을 다른 코드의 인터페이스로 사용함

#### 본격 전환 승인 — 2026-09-08

운영자가 1차 변경 후 계정/약점 준비 표시, S29 차단, 로비 전 종료, S26 1덱 완주,
종료 후 저장/재실행을 직접 확인하고 문제가 없다고 보고했다. 이는 해당 설치 조합의
운영자 인수이며 새 자동 actual-play receipt나 S29/모든 전투 조합의 성공이 아니다.
이후 아래 1~6의 구현을 승인했다. 진행 상태는 실제 gate 완료만 반영한다.

1. 기준선 고정: 부모 v9 원문이 아니라 현재 최종 파생 start/completion을 기준으로 삼는다.
2. 데이터 전용 실행 입력 계약 및 부작용 없는 부정/행동 검사를 먼저 추가한다.
3. 고정 Start/Complete 실행기를 구현하고 기존 경로를 기본값으로 유지하며 대조한다.
4. 실행별 입력/코드 closure를 봉인하고 coordinator/watcher/recovery와 연결한다.
5. cold 상태에서 검증된 조합을 적용하고 조기 종료/1덱 완주/저장/재실행을 운영자가 인수한다.
6. 인수 뒤 활성 경로의 부모 템플릿 읽기/치환 의존을 제거한다. 과거 실행 복구와 rollback 자료는 보존한다.

종료 순서는 runtime stop → pending capture → transient restore → management DB start →
exact persistence → terminal state → pending cleanup이다. 실패 후 legacy 자동 재실행은 없다.
실행 도중에는 실행기 버전을 바꾸지 않는다. 복원은 정리 완료 후 다음 실행부터 적용하며,
실행기 rollback을 이유로 운영 DB를 과거 상태로 되돌리지 않는다.
새 진단 HTTP 계층, client/server DLL 변경, 리소스/음성 정책 변경, P-01~P-09,
S29 repin, 150 폴더 이동은 제외한다. 기존 seed DB/출처 의존은 코드 템플릿 의존과 구분한다.
현재: **1~6 전환 구현 및 운영자 실게임 인수 완료.** 2026-09-09 cold 확인 후 새 기본
`parameterized/v1`로 실행했고 운영자가 조기 종료, S26 1덱 완주/결과창, 저장/재실행에
문제없음을 확인했다. 이후 활성 coordinator의 부모 start/completion 경로·hash·읽기,
legacy 선택 분기와 문자열 생성/저장을 제거했다. 과거 실행 복구와 자료는 보존한다.
`-RunnerEngine legacy/v1`은 이제 거절한다. rollback은 현재 실행 정리가 끝난 cold 상태에서
검증된 소스 revision/로컬 checkpoint를 명시적으로 복원해 **다음 실행**에만 적용한다.
자동 fallback과 운영 DB rollback은 없다.

- 기준선은 운영자가 인수한 실행의 최종 `Start-PhaseD-Derived.ps1` / `Complete-PhaseD-Derived.ps1`다.
  SHA-256은 각각 `0d322821ef27fa2dc9069b004ea4f48cbc3835da072a8d3931ca5ef2d9e2ff74`,
  `588cd7d0f531eba76761c21c5bd5986f8cf001ee60b9dbe3904da1cf4dff046c`이며 로컬
  `artifacts/stabilization/2026-09-08-s05-runner/baseline/`에만 보존한다. 계정 입력이 포함된
  실제 파생 스크립트를 Git에 넣지 않는다. CI에는 시작 receipt/pointer/failure와 완료 후처리의
  의미 토큰 hash만 고정했다. 이것은 전체 실게임 동등성 증명이 아니다.
- `Nll.PhaseDRunnerContract`는 37개 명시 필드만 받는다. 스크립트 원문·추가 필드·미지 버전,
  문자열 boolean, 경로/해시 형식 오류를 거절한다. secret은 환경변수 이름만 참조한다.
  150 preflight 도구 hash는 EXE 단독 hash가 아니라 기존 **전체 tool-set digest**를 유지한다.
- `Nll.PhaseDRunnerStart/Complete`는 고정 함수이며 코드 문자열을 생성하지 않는다.
  사용되지 않던 opt-in HTTP 진단 분기는 새 입력에 노출하지 않고 receipt의 not-requested 값은
  유지한다. bootstrap 보조 프로세스는 숨겨진 창으로 실행한다. 원본 게임 창은 대상이 아니다.
- `tools/runner/`에 입력 JSON, 보스 profile 사본, 실행/종료/복구와 공통 helper를 실행별로
  복사하고 `runner.bundle.json`에 hash를 봉인한다. runtime의 EXE/DLL/deps/runtimeconfig도
  대조한다. 기존 `launch-context → tool.manifest` 결박에 bundle hash를 추가했다.
  watcher는 해당 사본을 사용하고 recovery는 실행별 사본으로 먼저 분기한다. 변경·누락된
  새 bundle을 legacy로 분류하지 않는다. 공개된 `parameterized/v1`의 closure 계약은 나중에
  임의로 재정의하지 않으며 다음 변경은 과거 실행을 읽을 수 있는 별도 버전으로 다룬다.
- 검사: 입력/4조합 mapping 61개, 코드 봉인 31개, 전체 Start/Complete 합성 행동 28개,
  시작 의존성 20개, 실제 coordinator 분기, legacy/봉인 watcher 각각 4종 종료 순서.
  실제 파생 기준선 의미 토큰 대조와 기존 identity/rollback/recovery 검사를 함께 유지한다.
- 로컬 S26/151 준비 검사는 작열·전격으로 실행했다. 새 bundle/input을 구성하고 `ValidateOnly`
  이후 종료했으며 실제 Start/Complete 또는 게임을 실행하지 않았다. 두 경우 모두 속성 파생
  데이터 사용 조합이다. 계정 연결은 read-only였고 hosts 변경 없음·관리 DB 재종료를 확인했다.
  근거: `artifacts/stabilization/s05-local-preparation/8c71021b5f6a49be94c51ec6c6cb39fd/receipt.json`.
- 변경 후 전체 단위 476개, Save UI 12개/실행 상태 UI 6개와 repository/Phase 0/Phase 2B까지의
  baseline/Phase 3A·3B-0·3B-1/3B-2 contract/약점/Actions 검사를 통과했다.
  폐기 PostgreSQL 105개도 통과하고 stop/restart checkpoint 및 임시 cluster 제거를 확인했다.
  근거: `artifacts/stabilization/lifecycle-postgresql/667820ac1bd44d91b03f6a780ac320b4/receipt.json`.
  후보 소스 사본은 `artifacts/stabilization/2026-09-08-s05-runner/candidate-source/`에 보존한다.
  위 오프라인 검증 당시에는 기본 실행기 전환과 실게임 시작을 하지 않았다. client/Epinel DLL, 운영 계정 데이터,
  스키마, 음성 설정은 바꾸지 않았다.

5의 운영자 인수 및 6의 마감 근거:

- 새 실행기 실행 `83738086-22d9-47ce-b9b0-e5532f2b317b`,
  `fd92ef41-c9a2-4f6d-898d-9a9a2cf98e68`, `e89c8df5-4bee-45bc-8095-0530e535a525`는
  모두 bundle 검증·terminal `completed`·영속화·pending/active pointer 정리·runtime 종료를 확인했다.
  자동 receipt의 관측 단계는 `startup_only`, completed-result 관측은 0이다. **완주·결과창·
  Save·재진입의 인수 근거는 운영자 보고**이며 자동 전투 관측 증거로 바꾸지 않는다.
- 실검증된 고정 실행기/종료/복구 및 공통 helper **12개 파일은 byte 변경 없이 유지**했다.
  세 실행의 봉인을 다시 검증하고 현재 소스와 같은 hash임을 확인했다. 과거 legacy 실행도
  기존 분류로 읽힌다. 실행별 과거 복구 코드를 현재 코드로 덮어쓰지 않는다.
- `Nll.PhaseDRuntimeBundle.ps1`에는 bundle 읽기/검증만 남긴다. 문자열 변환 함수는
  기존 `Nll.PhaseDLaunchTools.ps1`의 역사 비교/복원 adapter로 모았으며 활성 경로가 import하지 않는다.
  CI는 옛 합성 golden을 보존하면서 현행 데이터 mapping 4조합, legacy/미지 엔진 거절,
  부모 템플릿 의존 부재와 실패 시 무재시도를 별도로 검사한다. seed DB/서버 출처 pin은 유지한다.
- 제거 후 실제 S26/151 작열·전격의 **기본 경로** `ValidateOnly`도 통과했다.
  계정 read-only, 게임/hosts 변경 없음, 관리 DB 재종료를 확인했다.
  근거: `artifacts/stabilization/s05-local-preparation/822035f7b4ab4132aa474c794e778972/receipt.json`.
- 마감 검사: 단위 476개, Save UI 12개/실행 상태 UI 6개, runner 계약/봉인/행동/4조합 mapping,
  기존 종료·복구 검사, 전체 repository/Phase/약점/Actions 및 변경 C# 서식 검사가 통과했다.
  폐기 PostgreSQL 105개와 재시작 checkpoint/최종 제거도 통과했다.
  근거: `artifacts/stabilization/lifecycle-postgresql/90d7ad95c473432e813deed69f0cd864/receipt.json`.
  최초 검사 `0faf09b1080444088bb706afad8ad2fd`는 105개 통과 후 30초 종료 제한을 넘어
  재시작 gate가 실패했지만 finally 정리는 완료됐다. 기존 테스트 옵션 `-ShutdownTimeoutSeconds 60`으로
  재검증해 통과했으며 운영 코드의 timeout을 변경하지 않았다. 운영 계정 쓰기/스키마 변경은 없다.

아래는 1차 분리 당시의 결함·전환 이력이며 현행 미완료 판정이 아니다.

- 기존 결함: coordinator의 다중 `.Replace()`와 `Nll.PhaseDRuntimeBundle.ps1`은
  과거 start/completion 소스의 특정 문자열,
  hash 및 들여쓰기 anchor를 치환해 새 실행기를 만든다.
- 영향: 부모 스크립트의 기능과 무관한 텍스트 변경도 새 실행을 깨뜨릴 수 있다.
  현재 exact-match 검사는 잘못된 변형을 막지만 구조적 결합 자체를 없애지는 않는다.
- 방향: 현재 파생 출력의 동작 테스트를 먼저 고정한 뒤 versioned 실행 입력을 받는 공통
  runner로 옮긴다. 부모 파일을 한꺼번에 정리하거나 현재 DLL을 재구현하지 않는다.
- 2026-09-08 1차 분리: `Nll.PhaseDLaunchTools.ps1`은 명시된 31개 입력과 schema/contract를
  받는 순수 adapter다(`nll/phase-d-launch-tools-input/v1`). account/revision/raid 값도
  상위 scope에서 몰래 읽지 않고 명시적으로 전달한다. coordinator는 상태 staging과 파일 저장을
  소유하고, adapter는 생성 문자열만 반환한다. 잘못된 입력 계약·중복 anchor는 거절한다.
- 변경 전 coordinator와 150/151 × static-data variant 유무 4조합의 start/completion 출력이
  byte-equivalent임을 합성 fixture 및 실제 hash-pinned 부모 템플릿으로 각각 확인했다.
  합성 출력의 고정 hash와 구문·분기·따옴표 검사를 Windows 기본 회귀 gate에 넣었다.
- 당시에는 치환을 adapter 내부에 격리한 1차 분리만 완료했고 부모 템플릿 의존이 남아 있었다.
  이후 위 1~6을 거쳐 현행 고정 실행기로 전환했다. 기존 템플릿 파일 자체는 삭제하지 않았다.

S-04/S-05 이번 검증 근거: `artifacts/stabilization/2026-09-08-preparation-contract/`.
최초 소스/오프라인 검증에는 설치 앱 배포·실게임·운영 DB 수정을 포함하지 않았다.
최종 단위 **476개**(Admin 114), 폐기 PostgreSQL **105개**와 stop/start·정리,
저장 UI 12개·준비/생명주기 UI·기존 종료 복구 검사·전체 계약·변경 C# 서식이 통과했다.
실제 S26/151의 5개 약점 구성은 모두 준비 판정을 통과했고 S29는 기존 불일치로 차단했다.
후보 앱과 설치본의 차이는 Admin DLL/PDB/editor JS/HTML **4개뿐**이었다.
`verification.json`에 소스·후보·설치본 대조와 실제 부모 템플릿 출력 동등성을 고정했고,
`package.json`과 `installed-before/`, `before/`에 다음 배포 검토·복원용 근거를 남겼다.

2026-09-08 운영자 **“1번 진행”** 승인으로 위 4개 파일을 설치했다. 설치된 351개 파일 중
나머지 347개는 hash가 동일하며, source pin과 선택 bundle·서버 DLL·client 실행 파일·hosts·
관리도구 시작/종료 script도 변경하지 않았다. 배포 직전 앱 4개와 적용 소스, 대응 coordinator/
bundle helper before를 `D:\NikkeLocalLab\Backups\preparation-app-20260908-<배포 UID>`에 보존했다.
정확한 경로·hash는 같은 artifact 폴더의 `installed.json`을 따른다. 배포 전후 단위·UI·전체 계약
gate를 재통과했다(`deploy-baseline.log`, `deploy-final.log`). 설치 조합의 관리도구 화면 검증은
별도 receipt로 기록하며, 게임 실행·S29 repin·운영 DB migration·S-05 전체 runner 전환은 하지 않는다.

설치 화면에서 운영자는 S29의 기존 drift 차단과 **계정 선택 후 S26/철갑 준비 완료·시작 버튼 활성화**를
확인했다. 계정 미선택 때 S26 구성은 ready인데 하단 문구만 ‘확인 중’으로 남는 별도 UI 분기를
동작 테스트로 재현했다. 구성 확인 뒤 workspace가 없으면 ‘계정을 선택하세요’로 안내하도록
editor JS만 보정했으며, 계정 미선택 시작 차단은 유지한다. `account-prompt-installed.json`에
첫 4파일 배포 이후 JS의 추가 hash·백업을 별도로 기록한다. 원래 후보/검증 봉인은 덮어쓰지 않는다.
현재 열린 창은 강제로 새로고침하거나 종료하지 않으며 보정 문구는 다음 관리도구 실행에 적용된다.
UIA 자동 검사는 텍스트 판독/라디오 컨트롤 패턴 문제로 전체 행렬을 완료하지 못했으므로 자동
실기 UI 통과로 주장하지 않는다. 구성 5약점·UI 행동 합성 검사와 운영자 화면 확인을 구분한다.
추가 문구 보정의 전체 회귀 결과는 `deploy-prompt-final.log`를 따른다. 실게임은 미실행이다.

계정 선택 후에도 최근 실행 이력을 읽고 약점을 바꾸면 ‘확인 중’이 남는 후속 결함을 확인했다.
terminal `launchProjection`이 있으면 준비 완료 문구를 갱신하지 않던 분기가 원인이었다.
상태 제목·설명·시작 버튼의 표시 책임을 `updateRaidActions` 한 곳으로 모았다. 현재 선택의
준비 결과를 제목에, 과거 완료/실패 결과를 보조 설명에 표시하며 실행 이력과 context는 지우지 않는다.
진행 중 요청·draft/validated/started·복구 오류의 경고/차단/폴링을 우선 유지한다.
새 동작 검사 6개는 terminal 3종×5약점, 이력/준비 응답 순서, 계정 미선택/검증 실패,
실행/복구, 요청 중, 차단/조회 실패/오래된 응답을 검사한다. 수정 전 5개 실패·1개 통과를 확인했고
수정 후 6개와 기존 저장 UI 12개·생명주기 검사를 통과했다. 이 검사를 Phase 2A2 gate에 추가했다.
배포·검증 근거는 `artifacts/stabilization/2026-09-08-raid-status-summary/`를 따른다.
설치 변경 대상은 editor JS 하나이며 DLL·DB·리소스·실행 프로토콜은 변경하지 않는다.
위 JS 단독 배포를 완료했고 나머지 설치 파일 350개와 기존 경계 pin이 동일함을 확인했다.
변경 전후 단위 476개·저장 UI 12개·새 상태 UI 6개·생명주기·전체 계약 gate가 통과했다.
정확한 JS hash·D: 백업 위치는 해당 폴더의 `installed.json`에 보존한다. 열린 창을 강제로
재시작/새로고침하지 않았으며, 보정 후 실제 설치 UI 확인과 실게임 인수를 자동 검사로 대체하지 않는다.

### S-06 / 높음 — 회귀 검사의 일부가 동작 대신 구현 문자열에 결박됨

- 최초 점검: GET/Start와 T10 검사가 구현 문자열에 결박되어 있었다. 이후 실행 상태 검사는
  가짜 runtime/owner와 실제 임시 파일을 사용하는 행동 검사로 전환했다. 2026-09-11에는
  T10 기업·큐브 중복 선택의 문자열 검사를 제거하고 아래 실제 변환 출력 검사로 대체했다.
  남은 정적 검사를 모두 행동 검사로 전환했다는 뜻은 아니다.
- 확인: materializer/151 bootstrap/desktop은 기본 solution 밖의 별도 빌드 대상이다.
  CI의 기본 solution green이 배포 조합 전체의 실행 가능성을 보장하지 않는다.
- 방향: 정적 정책 검사는 보조로 유지하고, 순수 변환 fixture와 가짜 process/clock/file
  adapter를 사용하는 행동 테스트, 폐기 DB의 failure-injection 테스트를 주 회귀선으로 둔다.
  원본 데이터 없이 가능한 CI 검사와 pinned 외부 runtime을 요구하는 로컬 검사를 분리한다.

#### S-06 장비·큐브 행동 검사와 별도 빌드 경계 (2026-09-11)

제품 코드를 변경하지 않고 `tests/NikkeLocalLab.Materializer.BehaviorChecks`를 추가했다.
검사기는 .NET 8 소스만으로 빌드되며, 로컬에서만 SDK 10으로 새로 빌드한 materializer와
기존 151 bundle이 봉인한 참조 DLL 10개를 사용한다. reflection은 private 컴파일 함수·타입에
연결하기 위한 좁은 adapter다. 변환 알고리즘을 테스트에 복제하지 않는다.
`GameData`의 파일 읽기 생성자·parser와 CLI 진입점은 호출하지 않으며, 메모리에 직접 만든
합성 catalog/user/candidate를 실제 `Materialize`에 전달한다. 실제 Newtonsoft serializer의
왕복 후에도 장비 기업 값·공유 큐브 참조가 유지되는지 확인한다.

| 분류 | 이번 처리 / 검증 |
|---|---|
| T9/T10 기능 | 4부위 × true/false/not-applicable, stale 기업 값, 기존 instance 유지, 미장착 정리 |
| OL 기능 | sparse 1/3번 줄·정확한 state-effect 값, 결손 mapping 거절 |
| 큐브 기능 | 신규 기본 15, 기존 최고 레벨, 계정 레벨 권위, 공유 참조·중복 통합·재실행, 해제, 계정 분리 |
| 결손 입력 | 장비/큐브 mapping, unresolved 기업, 불완전 보유 목록, 범위 초과·레벨 row 결손 거절 |
| 정책 정적 검사 | 공식 경로·외부 통신·원본 자료 노출 금지 등의 보조 검사는 유지 |
| 남은 기능 정적 검사 | 진행도/기록 캡처와 복구 순서의 일부 source guard는 기존 PG/runner 행동 검사와 함께 유지. 전부 동적 검증됐다고 간주하지 않음 |
| CI | checker locked restore/build/format를 Phase 2A2에 연결. 외부 DLL 없이 실제 변환을 실행했다고 표시하지 않음 |
| 로컬 gate | `test-nll-materializer-behavior.ps1`: bundle/ref 사전·사후 hash, 21개 행동 검사, 선택적 mutation control, materializer/151 bootstrap/desktop 별도 빌드 |

로컬 사용은 아래와 같다. expected hash는 검토된 기존 bundle의 봉인값이며 검사 실행 중에
자동으로 새 pin으로 갱신하지 않는다. 외부 참조가 없거나 pin이 다르면 실패한다.

```powershell
./scripts/test-nll-materializer-behavior.ps1 `
    -BundlePath '<검토된 로컬 bundle.private.json>' `
    -ExpectedBundleSha256 '<봉인된 SHA-256>' -MutationChecks
```

21개 통과. 생성한 복사본에서만 T10 기업 분기와 미보유 큐브 기본값을 각각 잘못 바꾼
negative control 2개도 예상 행동 검사에서 실패했다. 운영 source는 전후 hash가 동일하다.
별도 3개 빌드는 경고/오류 0이며 실행·배포하지 않았다. 151 bootstrap은 자체 global.json이
없어 일반 디렉터리에서 SDK 8을 선택하는 문제가 확인되어, **검사 스크립트**가 기존
materializer global.json의 SDK 10을 선택하도록 했다. repository SDK나 부트스트랩 코드는 변경하지 않았다.
소스 변경 이후 도구 배포 전에는 이 로컬 gate를 다시 통과해야 하며 CI green으로 대체하지 않는다.

검증 근거: `artifacts/stabilization/s06/509555d81dbf4e06911609478886522e/receipt.json`.
검사 대상은 in-memory 변환과 직렬화다. CLI의 전체 candidate admission, 파일 쓰기 원자성,
원본 client UI/전투, 원본 데이터 전체 catalog closure의 새로운 증거는 아니다. 운영 DB,
client DLL/리소스, 기존 실행기·설치본과 S29 pin은 변경하지 않았다.

수정 전 전체 기준선에서 `ExactChildExitDoesNotWaitForInheritedOutputHandles`가 자식 준비
5초 제한에 1회 실패했으며, 동일 검사 단독 재실행은 통과했다. 제품 timeout/종료 코드는
바꾸지 않았고 이 관측을 변환기 실패와 혼동하지 않는다. 변경 후 전체 실행에서는 해당 검사를
포함해 .NET 단위 검사 **475개**가 모두 통과했다. 문자열 전용 T10 Fact 1개를 21개 행동
검사로 대체하여 기존 단위 합계 476에서 475가 되었으며, 기능 검증을 단순 삭제한 것이 아니다.

**이번 S-06 범위 마감:** repository/Phase 0, Phase 3B-1이 호출하는 전체 baseline chain
(Phase 2A1/2A2/2B 및 역사적 Phase 3A/3B-0), Phase 3B-2 contract-only, boss variant,
Actions contract, JS 저장 12개·상태 6개와 lifecycle UI, Windows 실행기 회귀를 통과했다.
checker locked restore/build/format와 `git diff --check`도 통과했다. PostgreSQL **105개** 및
stop/restart checkpoint·cleanup 확인은 아래 독립 폐기 DB receipt로 확인했다.
`artifacts/stabilization/lifecycle-postgresql/2c2d98dfad76452da9d6f32bf710c691/receipt.json`
(`testExitCode=0`, `cleanupVerified=true`, `postgresqlRestartCheckpointVerified=true`).
운영 DB와 원본 client는 실행하지 않았다. 모든 source guard의 행동 검사 전환이나 새로운
실게임 검증을 완료했다는 뜻은 아니다. 다음은 아래 S-08의 **측정**이며 최적화 적용은 그 후다.

### S-07 / 중간 — Save의 복구 가능한 다단계 작업이 거대 service에 집중됨

- 확인: `PostgreSqlProfileManagementService.cs:164`의 aggregate Save는 profile,
  lobby, wallet, label, provenance, 최종 receipt를 여러 호출로 조정한다.
  `PostgreSqlAccountWorkspaceSaveStore.cs:29`의 claim transaction은 개별 단계 전에 끝난다.
- 이것은 의도된 pending/child-operation replay 구조이지 단순히 transaction이 없다는
  결함이 아니다. 이미 해결한 Save/Save As를 다시 설계 없이 바꾸지 않는다.
- 위험/방향: 동일 operation 중복·서로 다른 operation 경합·각 child 완료 직후 중단을
  먼저 재현한다. 조정 상태/단계와 저장소 구현을 분리하되 immutable revision, CAS,
  exact replay와 Save As의 고정 observation provenance는 유지한다.
- 추가 확인(생명주기 2차 폐기 DB 검사): `TypedSquadInventoryLobbyRevalidationAndApplicationRecoveryAreDurable`
  의 무변경 Preview에서 `account_cube_level`이 absent → 15 diff로 나타나 `Assert.Empty`가 실패한다.
  후속 대조에서 **구형 테스트 fixture와 현행 큐브 정책의 불일치**로 확인했다. 실제 관리도구의
  import/Save As 생성은 큐브를 먼저 보완한다. 저수준 store가 보존한 구형 빈 inventory의 최초
  보완은 명시적 diff/새 revision이며, 보완 후 저장은 무변경이어야 한다. 두 경우를 분리해 검증했다.
  이 결과로 S-03의 다중 snapshot 문제나 S-07 전체 조정 경계가 해결된 것은 아니다.

### S-08 / 중간 — 반복 전체 조회와 비대한 조정/매핑 파일

- 현행 재확인(2026-09-11): `PostgreSqlProfileManagementService.ListAccountsAsync`는
  목록의 각 계정에 `WithRuntimeMaterializationReadinessAsync`를 순차 호출한다.
  후자는 해당 계정·revision의 `GetRevisionAsync` 결과를 매핑해 readiness를 계산한다.
  frontend `editor.js`의 `listAccounts()`는 목록을 받은 뒤 계정별 lobby를 `Promise.all`로
  요청한다. 실제 SQL 수·비용은 아직 미측정이다.
- export는 현재 `ReadAccountSnapshotAsync(forRuntime: true)`를 사용한다. 과거 `:424`의
  재조회 지적을 현행 결함으로 단정하지 않고 snapshot 내부 호출부터 다시 계측한다.
- 최초 구조 지표: profile store 5,384줄, profile service 4,739줄, materializer entrypoint
  1,642줄. 과거 줄 수이며 재작성 필요나 속도 저하의 증거로 사용하지 않는다.
- 방향: 계정 수/로스터 수/이력 수별 SQL 횟수·읽기량·p50/p95를 측정한다.
  immutable revision을 key로 하는 읽기 모델/캐시와 필요한 summary batch 조회를 검토한다.
  저장 검증을 생략하거나 임의 TTL 캐시로 stale revision을 허용하지 않는다.

#### S-08 측정 계획 (2026-09-11, 아래에 1차 부분 결과)

당초 준비 범위는 측정 계획 확정까지였다. 이후 1차 측정은 아래에 별도로 기록한다.
제품 cache/batch/index 변경이나 운영 DB 측정은 하지 않았다.
첫 실행은 다음 순서로 진행하고, 근거 없이 대형 파일 분리·전체 재작성으로 확대하지 않는다.

1. **재현 fixture와 기준선 고정.** 현행 migration과 직접 만든 합성 account/profile/lobby를
   폐기 PostgreSQL에 구성한다. 기존 lifecycle 테스트의 분리 port·명시적 reset 승인 token·
   finally 정리 절차를 재사용하고 운영 접속 문자열은 거절한다. commit + working diff hash,
   SDK/PG 버전, fixture seed/hash, 장비·전원 조건, 실행 설정을 receipt에 기록한다.
2. **첫 측정: 계정 목록.** 서비스 `ListAccountsAsync`와 API 목록 응답을 각각 측정한다.
   UI 전체 비용은 목록 + 계정별 lobby fan-out 완료까지 별도로 측정한다. 서비스 단독 시간을
   UI 응답 시간으로 표시하지 않는다. HTTP 수, SQL 수, 반환 행 수/응답 byte 수, process
   allocation과 p50/p95를 기록한다. SQL 계측은 테스트 전용 Npgsql 진단 또는 폐기 DB 통계로
   연결하고 원문 query parameter·계정 payload는 로그에 남기지 않는다.
3. **규모 행렬.** 계정 수 1/10/50/100(계정당 roster 50, revision history 10 고정)을 먼저
   비교한다. 이어 계정 10 고정에서 roster 5/50/200, history 1/10/100을 각각 한 축씩 바꾼다.
   빈 DB·빈 roster·결손 revision은 성능 표와 분리된 정확성 검사다. 입력 규모에 따른 비용
   증가와 고정 비용을 구분하며 처음부터 모든 축의 Cartesian product를 실행하지 않는다.
4. **반복 규칙.** Release 빌드, 다른 회귀/빌드와 동시 실행하지 않는다. 프로세스 재시작 후
   최초 요청 10회와 동일 프로세스 warm-up 5회 뒤 50회 요청 × 3묶음을 분리한다.
   여기서 cold는 process-cold이며 OS/DB cache flush를 뜻하지 않는다. timeout/error는 별도
   개수로 남기고 좋은 샘플만 골라내지 않는다. p95는 정렬된 표본의 nearest-rank로 계산한다.
   원시 시간 표본도 보존한다. 물리 disk 읽기 byte와 반환 payload byte는 혼용하지 않는다.
5. **두 번째 측정.** 계정 선택/workspace, runtime candidate export, revision history를 같은
   fixture에서 측정한다. SQL·JSON 매핑·파일 읽기의 구간별 비용을 구분한다. 실행기 및 게임
   launch는 제외한다. 결손/오류 응답의 동작은 정상 응답 성능과 별도로 검증한다.
6. **변경 선택과 검증.** 가장 큰 반복 비용 한 곳만 batch projection 등으로 줄이는 안을
   먼저 제안한다. cache가 필요하면 account + immutable revision + projection/schema/catalog
   버전 등 실제 입력 의존성을 키에 포함한다. mutable head pointer 자체는 오래 재사용하지
   않는다. 계정 전환·revision 변경·동시 save/read·프로세스 재시작·누락 revision에서 이전
   데이터가 섞이지 않고, 기존 계약과 일치하는 snapshot 또는 명시적 conflict를 반환해야 한다.

측정 종료 조건: fixture/환경이 고정된 원시 표본과 집계표, 호출별 SQL/HTTP 비용,
정확성 결과, 상위 병목 후보와 근거를 남긴다. 예산/실행 환경 한계로 생략한 셀은 명시한다.
최적화안은 같은 조건 전후 3묶음 모두의 p50/p95·읽기 비용을 비교하며, 반복 변동보다 작은
차이는 개선으로 주장하지 않는다. SQL 수 감소만으로 전체 응답 개선을 주장하지 않는다.
정확성 실패나 timeout 증가가 있으면 채택하지 않는다. 유의미한 병목이 없으면 **변경 없음**도
정상 결론이다. 상세 출력은 ignored `artifacts/stabilization/s08/`에, 합성·source-free 요약만
이 문서에 남긴다. 실제 사용자 계정·원본 ID·게임 자료를 fixture나 commit에 포함하지 않는다.

#### S-08 1차 기준선 — 계정 1/10개 (2026-09-11)

**완료 범위:** 계정 1/10개, 각 roster 50명·서로 다른 profile revision 10개.
각 규모에서 service 목록, HTTP 목록, HTTP 목록+로비, workspace, export, history의 6경로를
warm-up 5회 후 50회 × 3묶음 측정했다. 총 **1,800개 원시 표본**을 보존했다.
50/100개 계정, roster/history 축, process-cold, 물리 I/O 및 UI DOM 렌더링은 미측정이다.
S-08 전체 완료나 성능 개선을 주장하지 않는다. 제품 코드는 변경하지 않았다.

아래 시간은 각 50회 묶음의 p50/p95 **세 값의 최소~최대**(ms)다. 하나의 합쳐진 p95가 아니다.
명령 수는 Npgsql `CommandExecutionCompleted` 이벤트 수이며 SQL 문장 수, transaction 제어를
포함한 모든 wire 왕복 수, 실제 disk read 수와 구별한다. `SELECT 1` 하나가 정확히 1회로
집계되는지 사전 검증했고, 원문 SQL·parameter·계정 payload는 출력하지 않았다.

| 경로 | 계정 1개 p50 / p95 ms | 계정 10개 p50 / p95 ms | 명령 수 1개 → 10개 |
|---|---|---|---|
| service 계정 목록 | 75.33~77.94 / 78.98~83.01 | 826.50~829.99 / 836.33~842.77 | 311 → 3,101 |
| HTTP 계정 목록 | 75.06~76.32 / 76.93~81.23 | 825.18~829.20 / 834.09~837.93 | 311 → 3,101 |
| HTTP 목록 + 모든 로비 | 75.86~79.48 / 80.39~82.00 | 838.65~840.85 / 847.83~850.03 | 313 → 3,121 |
| 단일 계정 workspace | 73.98~74.75 / 76.09~78.20 | 80.75~81.83 / 82.79~87.31 | 311 → 311 |
| 단일 계정 export | 80.82~82.49 / 84.81~85.60 | 86.17~86.44 / 87.97~91.62 | 315 → 315 |
| 단일 계정 history | 0.767~0.777 / 0.784~0.793 | 1.103~1.137 / 1.144~1.185 | 1 → 1 |

환경: .NET SDK 8.0.407, PostgreSQL 17.11, 12 logical processors,
최고 성능 전원 정책, loopback의 별도 cluster(shared_buffers 64MB, work_mem 2MB,
max_connections 40). Release 빌드이며 측정 중 다른 회귀/빌드를 실행하지 않았다.
초기 기준선은 Npgsql 기본 pool 상한 100에서 동시 로비 요청 최대 10개를 사용했다.
후속 도구는 큰 규모에서 cluster 상한 40을 넘지 않도록 pool 상한을 32로 제한하고 summary에
기록한다. 변경 전후 비교 시 같은 상한으로 다시 측정하며 이 설정 차이를 숨기지 않는다.
반환 객체 수·HTTP body byte·process 전체 allocation도 표본에 있지만 SQL 반환 행 수,
물리 disk byte 또는 특정 함수만의 allocation으로 해석하지 않는다. HTTP 묶음은 실제
AdminApiHost의 bootstrap/session을 사용하며 editor의 요청 구조를 재현하지만 DOM/WebView는 아니다.
초기 부분 중단 실행에는 runtime/OS 상세 요약이 남지 않았다. 후속 정상 종료 도구는 이를
summary에 기록하며, smoke 실행의 상세 버전을 앞선 기준선에 소급하여 붙이지 않는다.
fixture는 기존 research profile 생성기를 재사용한다. 첫 캐릭터의 head에 sparse OL이 있고
나머지 장비는 미장착, 콘솔에는 unresolved 항목이 있어 실제 계정의 ready 상태/모든 장착
조합을 대표하지 않는다. 명령 수와 호출 구조는 확인했지만 실계정 지연 시간을 단정하지 않는다.
fixture의 의미 값은 고정하고 UUID는 실행마다 새로 만들었다. 요청 크기와 DB의 실제 profile
revision 개수를 검증했다. 초기 fixture의 필수 wallet 누락과 동일 내용 revision 재사용 때문에
멈춘 3회의 setup 실행은 성능 표본에서 제외하고 실패/정리 receipt는 보존했다.

근거 디렉터리:
`artifacts/stabilization/lifecycle-postgresql/650529e6076a42fc874d4827729a0d86/`.
`s08-1-50-10.json`, `s08-10-50-10.json`의 각 6경로 × 150개 완료 표본만 유효하다.
`s08-environment.json`에 당시 HEAD/working diff/fixture source와 실행 DLL hash·전원·SDK를
기록했다. 당시 실행은 전체 행렬을 시작했으나 위 두 규모를 저장한 뒤 소유한 측정 child만
중단했다. 따라서 상위 receipt는 **testExitCode=-1**이며 전체 성공으로 재분류하지 않는다.
`cleanupVerified=true`, `postgresqlRestartCheckpointVerified=true`로 DB 정리는 확인했다.
50개 계정 fixture 이후 데이터나 미완성 표본을 결과에 섞지 않았다.

**원인 대조:** `PostgreSqlLocalAccountProfileStore.ReadVerifiedProfileAsync`는 receipt와
profile을 읽고 `VerifyAggregateProjection`을 수행한다. 그 아래 다음 반복이 있다.

- `ReadBuildReceiptsAsync` → 캐릭터별 `ReadEquipmentSlotReceiptsAsync`: R회
- `ReadBuildWritesAsync` → 캐릭터별 `ReadEquipmentWritesAsync`: R회
- `ReadEquipmentWritesAsync` → 각 4부위의 `ReadOverloadLinesAsync`: 4R회

관측값은 계정 수 A, roster R에 대해 목록 **1 + A × (10 + 6R)**와 맞는다.
R=50의 A=1/10에서 실측한 것이며 다른 규모의 실측을 대신하지 않는다.
로비 추가 비용(계정당 2명령)보다 profile 내부 6R 반복이 먼저 확인된 개선 후보다.

**다음 변경 후보(미적용):** 동일한 account/revision 및 RepeatableRead transaction 안에서
장비 slot receipt·equipment·overload를 batch로 읽고 정렬/결손 검증을 유지한다.
`VerifyAggregateProjection`, canonical hash 검증, workspace pending-save 거절과 snapshot
revision 일치 검증은 제거하지 않는다. 캐시는 먼저 도입하지 않는다. 우선 한 반복 구간만
바꿔 기존 결과와 동치인지 확인한 뒤 같은 fixture 전후 수치를 비교한다.
첫 최소 변경 후보는 캐릭터의 4개 equipment state에 대한 overload 조회를 1회로 묶는 것이다.
다른 읽기가 같다면 R=50/A=1의 명령 수는 산술상 311→161이 예상되지만 아직 측정값이 아니다.
0/1/3개 OL 줄, 미장착, sparse 줄 순서, 결손 참조, T10 기업 없음 및 다른 계정/revision의
행이 섞이지 않음을 실제 출력으로 대조해야 한다. 전체 profile batch는 그 다음 후보로 둔다.
계정 전환·동시 save/read·결손 데이터에 대한 새 변경의 회귀 검사는 적용 단계에서 필수다.

재실행 절차(소스 전용, 기존 정상 runtime/게임 종료 후):

```powershell
dotnet restore tests/NikkeLocalLab.ReadBenchmarks --locked-mode
dotnet build tests/NikkeLocalLab.ReadBenchmarks -c Release --no-restore
./scripts/test-nll-lifecycle-postgresql.ps1 -MeasureAccountReads -ShutdownTimeoutSeconds 60
```

기본은 계정 1/10의 focused 범위다. `-ReadMeasurementScope full`은 위 8개 warm 규모를
장시간 실행하며, `smoke`는 1계정/5명/1revision에서 도구 연결만 확인하고 기준선으로 사용하지
않는다. 실행 중 출력 디렉터리에 `stop-after-cell` 파일을 만들면 다음 완료 규모를 저장한 뒤
`stopped_after_cell`로 정상 종료한다. cold/DOM/disk 측정을 이 옵션들이 수행하지는 않는다.
CI는 도구 locked restore/build/format와 percentile/counter 자체 검사만 수행하며 성능 회귀의
합격/불합격을 시간 임계값으로 정하지 않는다. 운영 DB·설치본·게임 DLL은 입력 대상이 아니다.

도구 검증: percentile/counter 소스 자체 검사와 Release 빌드/format를 통과했다. 최종 pool 상한
32를 포함한 smoke의 receipt는
`artifacts/stabilization/lifecycle-postgresql/8b077715861c4823bb4cfe5a71149231/receipt.json`이며
exit 0·restart checkpoint·cleanup을 확인했다. smoke의 시간 값은 위 기준선에 섞지 않았다.
측정 옵션이 없는 기존 PostgreSQL 통합 **105개**도 다시 통과했다.
근거: `artifacts/stabilization/lifecycle-postgresql/5a239dfe2e14493aac0cc6d8aab9a326/receipt.json`.
소스 측정기는 기존 합성 fixture의 private helper에 reflection으로 연결하지만 production
조회 알고리즘을 복제하지 않고 실제 service/store/AdminApiHost를 호출한다. 운영 client나
Epinel runtime을 시작하지 않는다. 새 최적화의 성능/동치 검증은 아직 수행하지 않았다.

#### S-08 최소 overload batch — 2026-09-11

운영자의 구현·테스트 요청으로 캐릭터별 네 장비의 overload 읽기를 한 번으로 묶었다.
`ReadBuildOverloadLinesAsync`는 이미 고정된 build revision ID와 같은 connection/transaction을
사용하고, equipment state ID별로 분리한 줄을 기존 equipment projection에 전달한다.
줄 순서·signed Int64·decimal scale·빈 장비를 보존하며 `VerifyAggregateProjection`과
기존 hash/shape 검증, pending-save 거절 및 snapshot 경계를 변경하지 않았다.
제품 변경은 profile store 한 파일이다. 캐시·인덱스·migration·설치본 변경은 없다.

추가한 `PostgreSqlOverloadReadTests`는 저장 receipt의 hash만 비교하지 않고 입력 write와
재조회한 전체 canonical hash 및 장비/줄의 모든 필드를 직접 비교한다. 여러 캐릭터·부위의
0/1/3줄과 sparse 1/3, 서로 다른 option UID, signed Int64 극값 근처와 scale 0/9,
T10 기업 not-applicable, 강화값 unresolved, 미장착/미해결 장비를 포함한다.
RepeatableRead snapshot을 고정한 뒤 다른 연결에서 OL 변경을 commit하고 기존 snapshot과
새 current/과거 revision/다른 계정/새 data source의 조회가 각각 맞는지 확인한다.
없는 option UID의 저장은 거절하고 current/operation receipt가 바뀌지 않음을 확인한다.
누락·타계정 revision은 null이다. 이 검사는 DB 제약을 우회한 손상 row의 사후 검증을
새로 구현했다는 뜻이 아니다.

- 변경 전 전체 PostgreSQL 105개: `lifecycle-postgresql/36cb70a20c0940eeb1c8395bea5dd9f8`.
- 새 동치 검사 2개를 **기존 읽기 코드**에서도 통과: `lifecycle-postgresql/eec005299d9e467cb1c85fbd648e969e`.
- 변경 후 전체 PostgreSQL 107개 통과: `lifecycle-postgresql/47882ab342d0403a92d723e389b1bf59`.
- 최종 migration/reset 정적 계약이 새 partial 파일의 분리된 호출을 거절해 기존 reset
  소유 파일의 공용 초기화 helper로 연결했다. 제품 코드는 그대로이며 영향받는 2개 검사를
  다시 통과했다: `lifecycle-postgresql/931f20e5c8684bcab3ce4695d7d1aebd`.
  최초 계약 실패는 `s08-batch/commit-validation-reset-guard-failed.log`에 보존한다.

위 경로는 모두 ignored `artifacts/stabilization/` 아래의 합성 검사 근거다.
각 실행의 test exit 0, 재시작 checkpoint 및 최종 cleanup을 확인했다.
처음 샌드박스 실행은 PostgreSQL restricted-token 생성 오류로 시작하지 못했으며
`lifecycle-postgresql/affd774020c74dba9660fae555414a68`에 실패·정리 receipt를 보존했다.
같은 검증기를 샌드박스 밖에서 실행해 위 결과를 얻었고 검사 조건을 완화하지 않았다.
경로 별칭(junction)에서의 repository-root 검사 실패는 동일 저장소의 실제 경로에서 해소했다.

**같은 조건의 전후 측정:** 계정 1/10개, roster 50, history 10, 각 6경로 × 150회로
전후 각각 1,800개 표본이다. warm-up 5회와 50회 × 3묶음, SDK 8.0.407/PG 17.11,
최고 성능 전원 정책/12 logical processors, cluster 설정 및 pool 상한 **32**가 같다.
과거 pool 상한 100인 1차 표를 비교 기준으로 재사용하지 않았다. 측정 중 다른 빌드·회귀
검사는 실행하지 않았다. 아래는 묶음별 p50/p95 세 값의 최소~최대(ms)이며 합친 p95가 아니다.

| 계정 | 경로 | p50 전 → 후 ms | p95 전 → 후 ms | DB 명령 전 → 후 |
|---:|---|---|---|---|
| 1 | service 목록 | 77.54~78.20 → 51.16~51.82 | 80.84~85.37 → 51.92~57.86 | 311 → 161 |
| 1 | HTTP 목록 | 75.60~77.14 → 51.71~51.90 | 80.08~81.17 → 52.90~55.46 | 311 → 161 |
| 1 | HTTP 목록+로비 | 77.34~77.75 → 51.45~51.62 | 81.22~82.83 → 52.81~53.40 | 313 → 163 |
| 1 | workspace | 78.10~78.43 → 55.71~56.28 | 79.46~79.71 → 56.60~56.94 | 311 → 161 |
| 1 | export | 81.93~83.51 → 60.38~60.90 | 84.79~86.95 → 61.12~62.93 | 315 → 165 |
| 1 | history | 0.77~0.78 → 0.77~0.77 | 0.79~0.88 → 0.78~0.78 | 1 → 1 |
| 10 | service 목록 | 822.36~825.31 → 530.01~550.04 | 829.67~837.24 → 552.89~556.83 | 3,101 → 1,601 |
| 10 | HTTP 목록 | 817.69~824.74 → 550.23~552.47 | 823.71~830.04 → 555.83~556.72 | 3,101 → 1,601 |
| 10 | HTTP 목록+로비 | 832.74~833.35 → 561.20~562.62 | 843.89~845.89 → 568.38~587.12 | 3,121 → 1,621 |
| 10 | workspace | 83.95~84.14 → 55.39~55.65 | 84.83~85.52 → 56.18~56.53 | 311 → 161 |
| 10 | export | 87.96~89.08 → 60.19~60.44 | 90.46~94.43 → 61.34~62.04 | 315 → 165 |
| 10 | history | 1.08~1.11 → 1.07~1.10 | 1.12~1.17 → 1.11~1.14 | 1 → 1 |

service 목록 p50은 묶음별 약 **33~36%** 감소했다. 변경 대상 5경로의 모든 묶음에서
p50/p95가 개선됐으며, 가장 느린 변경 후 p95도 가장 빠른 변경 전 p95보다 낮았다.
history는 조회 변경이 없으며 작은 시간 차이를 최적화 효과로 주장하지 않는다.
전후 오류/timeout은 0이고 모든 경로의 반환 객체 수·HTTP 요청 수·body byte가 같다.
Npgsql 완료 이벤트로 센 명령 수는 SQL 문장 수·물리 I/O와 구분한다.
실측한 두 규모의 목록 명령 수는 `1 + A × (10 + 6R)`에서 `1 + A × (10 + 3R)`로 줄었다.

- 변경 전: `lifecycle-postgresql/a3b6fd195b4947d5a666901b53619089`.
- 변경 후: `lifecycle-postgresql/98fab86e7dbf4260b956c8c67848f6f8`.
- 각 `s08-summary.json`, 규모별 원시 JSON, `s08-environment.json`의 fixture/assembly hash와
  `receipt.json`을 보존했다. 두 실행 모두 `passed_selected_scope`, exit 0, 재시작·정리 확인이다.
- 단위·UI·runner·Phase/약점/Actions 마감 검사 출력은 `s08-batch/commit-validation.log`,
  별도 자동화 단위 41개 통과는 `s08-batch/after-automation.log`에 보존한다.

이 최소 batch는 합성 입력의 동치·성능 검증을 통과한 소스 변경이다. 운영 설치에 배포하지
않았고 운영 DB·client·Epinel DLL은 변경하지 않았다. 기존 fixture의 제한과 50/100계정,
roster/history 축 확장, process-cold·물리 I/O·DOM 측정은 남아 있어 S-08 전체 완료는 아니다.
후속 최적화는 전체 profile batch를 별도 변경으로 검토하고 같은 검증 경계를 유지한다.

#### S-08 프로필 revision batch — 2026-09-11

운영자의 후속 착수 승인으로 slot receipt·equipment·overload를 각각 **선택한 profile
revision 전체에서 한 번** 읽도록 변경했다. 제품 변경은 `PostgreSqlLocalAccountProfileStore.cs`
한 파일이며 API·writer·migration·인덱스·캐시는 변경하지 않았다.

세 조회 모두 `profile_template_revision_build`의 exact profile revision membership으로
범위를 제한한다. 여러 profile에서 같은 build revision을 재사용할 수 있으므로 current
account/build 포인터나 다른 profile의 membership을 대신 읽지 않는다. 슬롯/장비는 build
revision ID, overload는 equipment state ID로 묶고 기존 build ordinal·slot code·sparse line
순서를 유지한다. equipment definition의 LEFT JOIN, 같은 connection/transaction과
cancellation token, 기존 constructor·hash·aggregate 검증은 보존한다. 빈 roster는 추가
장비 조회 없이 반환한다. receipt 조회를 사용하는 Create/Save 및 과거 operation replay도
별도의 hydration이나 새 transaction을 만들지 않는다.

`PostgreSqlProfileBatchReadTests`의 새 3개 검사는 기존 overload 부분 검사와 함께 전체
입력 write의 canonical hash·직렬화된 필드, receipt identity/lineage/readiness/issue와
네 slot의 UID·순서를 대조한다. 부분 build 변경과 unchanged revision 공유, roster 제거/
재추가·입력 순서 정규화, squad 제거/순서 변경/복원, 빈 roster 및 복원, 고정 RepeatableRead
동안 다른 연결의 Save, 과거/현재/타계정/결손 revision과 새 data source를 검사한다.
최신 Save 이후 과거 Create/Save 및 GetByOperation replay가 당시 receipt를 반환하고
current membership을 바꾸지 않는지도 확인한다. 기존 aggregate 검증을 개별 hydrated
장비 payload의 완전 재해시 검증으로 확대 해석하지 않는다.

변경 전 근거(모두 ignored `artifacts/stabilization/` 아래):

- 전체 PostgreSQL **107개**: `lifecycle-postgresql/4594c5d2ce6e4813a90a06eed132eccd`.
- 새 3개 검사를 **기존 reader에서 통과**: `lifecycle-postgresql/f8fface6ce954189831f9d1f3139e2dd`.
- 변경 전 1/10계정 측정 **1,800표본**, 오류 0:
  `lifecycle-postgresql/50c9e41de54644419f391a5ca67b78b6`.
- 각 실행의 exit 0·재시작 checkpoint·cleanup 확인. 사전 repository/Phase 0/완료된
  Phase 2B 및 3A·3B-0·3B-1 chain/3B-2·약점·Actions 검사는
  `s08-profile-batch/before-*.log`에 보존했다.

변경 후 전체 PostgreSQL **110개**가 통과했다:
`lifecycle-postgresql/8db4e6a6965b40949ea110517d829723`. exit 0·재시작 checkpoint·cleanup을
확인했고, 별도 자동화 단위 41개도 통과했다(`s08-profile-batch/after-automation.log`).
독립 read-only diff 검토에서도 schema scope·column ordinal·정렬·reader 수명·replay의
수정 필요 사항은 발견되지 않았다. 이 검토를 실제 runtime 검증으로 대신하지 않는다.

**동일 조건 전후 비교:** 기존 합성 fixture의 1/10계정·roster 50·history 10에서 각각
6경로 × 150회, 전후 각 **1,800표본**을 비교했다. warm-up 5회 뒤 50회 × 3묶음이며
pool 상한 32, SDK 8.0.407, PG 17.11, 12 logical processors, 최고 성능 전원 정책과
cluster 설정(shared_buffers 64MB, work_mem 2MB, max_connections 40), fixture source hash가
동일하다. 측정 중 다른 빌드·회귀 검사는 실행하지 않았다. 이전 최소 batch의 수치를 재활용하지
않고 이 작업의 직전 reader로 다시 측정했다. 아래는 묶음별 p50/p95의 최소~최대(ms)다.

| 계정 | 경로 | p50 전 → 후 ms | p95 전 → 후 ms | DB 명령 전 → 후 |
|---:|---|---|---|---|
| 1 | service 목록 | 52.27~52.53 → 11.61~13.20 | 53.41~56.17 → 12.49~14.58 | 161 → 14 |
| 1 | HTTP 목록 | 52.37~53.17 → 11.82~11.97 | 53.65~53.99 → 12.65~12.98 | 161 → 14 |
| 1 | HTTP 목록+로비 | 53.42~54.05 → 12.66~13.10 | 54.78~54.96 → 13.38~14.15 | 163 → 16 |
| 1 | workspace | 50.81~51.11 → 11.06~11.17 | 51.64~52.29 → 11.89~12.10 | 161 → 14 |
| 1 | export | 55.83~56.13 → 15.52~15.84 | 56.84~57.77 → 16.34~17.33 | 165 → 18 |
| 1 | history | 0.75~0.77 → 0.75~0.76 | 0.78~0.84 → 0.79~0.82 | 1 → 1 |
| 10 | service 목록 | 543.98~548.71 → 110.77~111.72 | 551.00~603.60 → 112.16~123.68 | 1,601 → 131 |
| 10 | HTTP 목록 | 547.44~548.47 → 110.83~112.63 | 552.25~558.77 → 112.75~120.54 | 1,601 → 131 |
| 10 | HTTP 목록+로비 | 561.73~564.45 → 124.88~138.26 | 566.05~576.32 → 132.01~152.80 | 1,621 → 151 |
| 10 | workspace | 55.40~56.16 → 13.91~13.98 | 56.43~57.50 → 14.73~14.86 | 161 → 14 |
| 10 | export | 61.09~61.34 → 18.51~18.66 | 62.27~63.63 → 19.48~20.73 | 165 → 18 |
| 10 | history | 1.06~1.09 → 0.87~0.93 | 1.11~1.13 → 1.05~1.13 | 1 → 1 |

변경 대상 5경로의 모든 세 묶음에서 p50/p95가 개선됐다. service 목록 p50은 약 75~80% 감소했다.
history는 조회 변경이 없으므로 시간 차이를 최적화 효과로 주장하지 않는다.
모든 대응 표본의 반환 객체 수·HTTP body byte·HTTP 요청 수가 같다. 목록 명령 수는
실측 범위에서 `1 + A × (10 + 3R)`에서 `1 + 13A`로 줄었으며 모든 표본에서 같은 수를
확인했다. 이는 Npgsql completed-command 이벤트 수이지 SQL 문장·전체 wire 왕복·물리
disk read 수가 아니다. payload 처리 비용까지 roster 크기와 무관해졌다는 뜻도 아니다.

**변경 후 warm 행렬 완료:** 위 두 셀을 포함한 기존 `full`의 8조건 × 6경로 × 150회,
총 **7,200표본**을 보존했다. 변경 전 1,800표본을 합한 이번 측정 총계는 9,000개다.
변경 후 근거는 `lifecycle-postgresql/ab74b126d47e4458966f3ee64ecb3b56`이며
`s08-summary.json`의 `passed_selected_scope`, 오류 0, receipt의 exit 0·재시작 checkpoint·
cleanup을 확인했다. 모든 표본의 group/iteration 개수와 순서, 유한한 비음수 시간 및
명령 수도 검산했다. 아래는 service 목록의 대표 표이며 각 조건의 나머지 다섯 경로,
HTTP byte/요청 수와 process 전체 allocation은 같은 디렉터리의 원시 JSON에 있다.

| 계정 | roster | history | service 목록 p50 ms | p95 ms | DB 명령 |
|---:|---:|---:|---|---|---:|
| 1 | 50 | 10 | 11.61~13.20 | 12.49~14.58 | 14 |
| 10 | 50 | 10 | 110.77~111.72 | 112.16~123.68 | 131 |
| 50 | 50 | 10 | 851.64~862.24 | 861.20~1082.31 | 651 |
| 100 | 50 | 10 | 1174.81~1186.40 | 1196.20~1230.69 | 1,301 |
| 10 | 5 | 10 | 99.19~99.57 | 100.81~344.85 | 131 |
| 10 | 200 | 10 | 231.14~233.42 | 245.35~445.08 | 131 |
| 10 | 50 | 1 | 113.14~114.20 | 114.18~115.73 | 131 |
| 10 | 50 | 100 | 165.26~167.39 | 168.02~169.32 | 131 |

전체 행렬에서 목록은 `1 + 13A`, 목록+로비는 `1 + 15A`, 단일 workspace/export/history는
각각 14/18/1명령이었다. roster 5/50/200 및 history 1/10/100에서 profile 내부 반복 조회가
늘어나지 않음을 확인했지만 응답 시간은 고정되지 않는다. roster 5/200 조건의 첫 묶음에서
p95 344.85/445.08ms의 변동도 보존했고 원인을 GC·cache 등으로 추측하지 않았다.
이력 100 조건도 같은 131명령에서 p50이 높아, 후속 원인 분석에는 query plan·구간별 CPU/
allocation·I/O 근거가 더 필요하다. 이번에 새 인덱스나 캐시를 추가할 근거로 단정하지 않는다.

큰 규모에는 변경 전 대응 표본이 없으므로 그 규모의 개선율을 추정하지 않는다. fixture는
첫 캐릭터 head의 두 sparse OL과 나머지 미장착 장비를 주로 사용하므로 dense/ready 장비를
갖춘 실제 계정 전체를 대표하지 않는다. 빈 roster/결손 참조는 정확성 검사이며 성능 셀이
아니다. process-cold·DOM·물리 I/O·SQL 반환 행 수 측정은 여전히 후속이다. 따라서 이
profile batch와 warm 행렬은 완료했지만 S-08 전체 완료나 운영 지연 보장을 주장하지 않는다.

단위·UI·runner·Phase/약점/Actions 마감 검사 출력은
`s08-profile-batch/commit-validation.log`, working-tree 정책 검사는
`s08-profile-batch/after-repository.log`에 보존한다. 설치본·운영 DB·게임·Epinel DLL 변경,
실제 게임 실행 및 remote push는 없다.

#### S-08 process-cold 계측 — 2026-09-11

운영자 승인 범위는 **측정기 보강과 1/10계정 최초 요청 검증**이다. 제품 조회·Save·schema·
cache·index는 변경하지 않는다. 기존 warm fixture 생성·검증은 부모 프로세스에만 두고,
서비스 목록, HTTP 목록, HTTP 목록+로비 세 경로를 각기 새 자식 프로세스에서 한 번 실행한다.
각 경로·규모마다 10회이며 총 60개 프로세스다. roster 50/history 10과 pool 상한 32를 유지한다.
50/100계정, 다른 roster/history 축과 workspace/export/history의 cold는 이 범위에 포함하지 않는다.

측정 경계:

- **시작 시간**: 부모의 process start 호출 직전부터 신원·fixture binding을 검증한 ready 수신까지.
  .NET 시작, 서비스/계측기 구성, IPC를 포함한다. HTTP 경로는 loopback AdminApiHost 시작과
  process-local 인증 bootstrap도 포함한다. 운영 설치 앱 전체의 startup 시간이 아니다.
- **첫 조회 시간**: 자식의 단일 서비스 호출 또는 HTTP 조회 graph 실행 직전부터 응답 소비와
  count/account/revision 검증까지. HTTP+로비는 첫 목록 응답 후 로비 fan-out을 포함한 한 graph이며,
  각 로비를 별개의 cold 요청으로 부르지 않는다. 브라우저·DOM·WebView 렌더링은 포함하지 않는다.
- 자식은 data source를 만들되 사전 SELECT/probe/preload/fixture 조회를 하지 않는다.
  ready에 DB completed-command 0회와 측정 operation 0회를 기록한다. 첫 DB 연결은 측정 구간에서
  열고 `default_transaction_read_only=on`을 적용한다. 부모의 fixture reset 권한과 분리한다.
- PostgreSQL은 규모당 fixture를 부모에서 생성·검산한 상태다. trial마다 OS/DB cache를 flush하거나
  PostgreSQL을 재시작하지 않는다. 이 수치는 process-cold이지 disk-cold가 아니다.
- UUID trial, PID+UTC 시작 시각, exact fixture hash와 account→profile revision 집합을 표본에 결박한다.
  결과는 Npgsql completed-command 수, process 전체 allocation, 반환 객체·HTTP byte/요청 수를 보존한다.
  명령 수는 SQL statement/반환 행 수/물리 I/O가 아니며 HTTP allocation은 서버와 측정 client를 합친 값이다.
- 시작/조회 60초, child exit 15초, HTTP client 30초의 자원 제한을 둔다. 오류·timeout·신원 불일치·
  중복 결과·비정상 exit를 성공으로 치환하지 않는다. 매 시도 뒤 원시 표본을 저장하고 직접 시작한
  Process만 종료·확인한다. 정리 불명 상태에서는 다음 fixture reset을 중단한다.
- 통계는 성공 표본만 사용하되 시도/성공/오류/timeout 개수를 함께 표시하고 실패 표본도 보존한다.
  nearest-rank p95는 표본 10개에서 최댓값이다. 시간 임계값을 CI 성능 합격선으로 사용하지 않는다.

실행 명령(기존 runtime/게임 종료 후, 소스 전용):

```powershell
dotnet build tests/NikkeLocalLab.ReadBenchmarks -c Release --no-restore
dotnet tests/NikkeLocalLab.ReadBenchmarks/bin/Release/net8.0/NikkeLocalLab.ReadBenchmarks.dll --self-test
./scripts/test-nll-lifecycle-postgresql.ps1 -MeasureAccountReads -ReadMeasurementScope cold-smoke -ShutdownTimeoutSeconds 60
./scripts/test-nll-lifecycle-postgresql.ps1 -MeasureAccountReads -ReadMeasurementScope cold -ShutdownTimeoutSeconds 60
```

`cold-smoke`는 1계정/roster 5/history 1에서 경로당 한 번인 연결 검사이며 기준선과 섞지 않는다.
기존 `focused/full/smoke`는 계속 warm 옵션이다. `stop-after-cell`은 cold에서도 완료 규모 뒤 멈추며
`stopped_after_cell`을 남긴다. 측정 환경 receipt에는 새 C# 파일을 포함한 source hash와 실행 DLL hash를
기록한다. CI의 기존 `--self-test`는 DB 없는 순수 판정 검사와 12개 자식 프로세스 성공/실패/timeout
검사만 실행하고 실제 PostgreSQL 성능 측정은 하지 않는다.

**실측 결과:** `lifecycle-postgresql/e2dfb5cfe69042d88d385a83d4f9987c`의 본 측정은
`passed_selected_scope`, 60/60 성공·오류 0·timeout 0이다. 전체 표본의 서로 다른 PID+시작 시각과
trial UID, 6경로·규모 조합 × 순서가 고정된 10표본, 개별 파일과 summary 동등성, fixture SHA-256,
ready의 사전 명령/operation 0, 유한한 비음수 지표와 nearest-rank 통계를 독립 재계산했다.
`artifacts/stabilization/s08-process-cold/raw-verification.log`에 검산 결과를 남겼다.

| 계정 | 경로 | 시작 p50/p95 ms | 첫 조회 p50/p95 ms | DB 명령 |
|---:|---|---:|---:|---:|
| 1 | service 목록 | 175.33 / 206.00 | 283.75 / 304.54 | 14 |
| 1 | HTTP 목록 | 474.52 / 494.40 | 297.70 / 302.86 | 14 |
| 1 | HTTP 목록+로비 | 473.58 / 495.51 | 313.57 / 320.32 | 16 |
| 10 | service 목록 | 174.29 / 175.44 | 432.51 / 439.88 | 131 |
| 10 | HTTP 목록 | 472.20 / 474.51 | 446.35 / 557.70 | 131 |
| 10 | HTTP 목록+로비 | 473.94 / 476.45 | 620.86 / 646.02 | 151 |

모든 표본에서 명령 수는 warm 때의 목록 `1 + 13A`, 목록+로비 `1 + 15A`와 같다.
첫 조회 지연은 따뜻해진 프로세스와 다르지만 JIT·첫 DB 연결·SQL·매핑 각각의 기여율을 측정한 것은
아니다. HTTP client까지 같은 새 프로세스에 있으므로 실제 외부 브라우저의 cold 지연으로 일반화하거나
warm 대비 제품 성능 저하율로 표현하지 않는다. 10계정 HTTP 목록의 최대 557.70ms도 제외하지 않았다.
50/100계정 및 다른 read 경로의 cold, query plan·구간별 CPU/할당·반환 행 수·물리 I/O·DOM 측정은 남았다.
따라서 이번 focused process-cold 계측은 완료하되 S-08 전체 종료나 운영 지연 보장을 주장하지 않는다.

연결 검사 receipt는 cold smoke `599700e748714955b05f80dc0acc23a3`(3표본), 기존 warm smoke
`926e3f76072548b291440514638b0280`(12표본)이며 본 측정과 통계를 섞지 않는다. 두 smoke와 본 측정의
exit 0·DB 재시작 checkpoint·cleanup을 확인했다. 변경 전 PostgreSQL 110개 통과 근거는
`37658ac2bbd84ec09f4064c9bb40b5d2`다. 초기 기준선 restore의 NuGet 접근 제한 `NU1900`과 그 상태를
읽은 첫 PG 검사 실패도 `s08-process-cold/before-*.log`에 보존했다. 감사/경고 옵션을 끄지 않고
정상 권한의 locked restore 후 재실행했으며, 실패한 첫 폐기 DB도 checkpoint/cleanup을 확인했다.
마감 검사는 단위 **475개**, cold 계측기의 DB-free 자식 프로세스 **12개** 및 순수 negative 검사,
UI/실행기·Phase 0~2B·Phase 3A/3B0/3B1·3B2 scaffold·약점·Actions 계약과 build/format를 통과했다.
변경 후 PostgreSQL **110/110** 및 restart checkpoint/cleanup 근거는
`lifecycle-postgresql/ef959c43eec7485fb1af55236f48526e`다. 검사 로그는
`s08-process-cold/after-gates.log`, `after-postgresql.log`와 `commit-validation.log`에 보존한다.
제품 소스·운영 DB·설치본·게임·Epinel DLL 변경과 remote push는 없다.

### S-08 후속 진단·DOM·확장 cold — 2026-09-11

운영자의 **“1~2 진행”** 범위는 S-08 후속 계측과 안정화 잔여 점검이다. P-01~P-09,
운영 DB 보정, 설치 앱 배포, 실게임 재실행은 이번 범위가 아니다. 이 절은 위 focused cold
60표본의 후속이며 과거 수치와 통계 모집단을 합치지 않는다.

재실행은 `test-nll-lifecycle-postgresql.ps1 -MeasureAccountReads`의 `-ReadMeasurementScope`
`diagnostic`, `dom`, `cold-full`을 사용한다. 사전에 ReadBenchmarks Release 빌드가 필요하며,
측정 중 build/test를 병행하지 않는다. 모든 DB는 loopback 55432의 새 합성 폐기 cluster다.
기존 pending, 공식 계정·클라이언트·게임 서버를 입력으로 쓰지 않는다.

#### 실제 쿼리 진단 및 합성 DB 성장

`lifecycle-postgresql/f0634e4819d04e49a38d21065823886f`에서 8조건 × 6구간 × 3회,
**144개 진단 표본과 2,997개 실제 명령의 EXPLAIN 재실행**을 완료했다. 구간은 summary rows,
단일 current profile 복원, service 목록/workspace/export/history다. 각 구간은 서로 중첩하므로
시간을 더하거나 차감해 순수 매핑 비용이라고 부르지 않는다.

- 관측: 실제 읽기 명령의 typed parameter를 Npgsql tracing callback에서 메모리에만 복사한다.
  parameter logging은 켜지 않고 SQL·매개변수·Activity tag·plan Filter/Index Cond는 저장하지 않는다.
  Npgsql 10.0.3의 [공식 tracing callback 구현](https://raw.githubusercontent.com/npgsql/npgsql/v10.0.3/src/Npgsql/NpgsqlCommand.cs)을 확인했다.
- 서비스 계측과 EXPLAIN은 분리한다. 첫 진단 표본의 SELECT를 **계측 후** read-only session에서
  재실행하며, 반환 행/버퍼 수는 그 재실행의 관측이다. 원래 요청의 SQL 반환 행으로 둔갑시키지 않는다.
- CPU·할당량은 ReadBenchmarks 프로세스 전체이고 tracing 비용을 포함한다(PG/Edge CPU는 미포함).
  Windows CPU 시계의 해상도 때문에
  짧은 구간의 0ms는 CPU 사용이 없다는 뜻이 아니다. 세 표본은 latency baseline이나 p95 보장에 불충분하다.
- 모든 replay의 최상위 shared read blocks 합은 0이었다. OS cache/physical disk bytes는 계측하지
  않았으므로 **물리 I/O는 unresolved**다. cache flush나 운영 DB 설정 변경은 하지 않았다.

| 계정/로스터/이력 | 목록 진단 평균 ms | 평균 할당 MiB | SELECT replay 실행 합 ms | 합성 lab 관계 총 MiB |
| --- | ---: | ---: | ---: | ---: |
| 1/50/10 | 14.43 | 1.12 | 1.88 | 7.57 |
| 10/50/10 | 131.76 | 11.05 | 30.81 | 10.04 |
| 50/50/10 | 1,130.77 | 55.20 | 661.32 | 20.48 |
| 100/50/10 | 1,247.91 | 110.40 | 282.29 | 33.07 |
| 10/5/10 | 102.84 | 2.57 | 13.41 | 7.88 |
| 10/200/10 | 206.18 | 39.50 | 77.05 | 17.50 |
| 10/50/1 | 124.80 | 11.05 | 28.41 | 8.93 |
| 10/50/100 | 178.55 | 11.05 | 82.52 | 21.08 |

기존 sparse/mostly-unequipped 합성 fixture를 유지했다. 장비·overload가 밀집한 실계정의 분포나
동시 운영 부하를 대표한다고 주장하지 않는다.

100계정 summary rows만 읽는 구간은 평균 1.77ms·1명령인데 전체 service 목록은 1,301명령이다.
따라서 추가 최적화 후보는 목록에서 매 계정의 프로필 전체를 복원하는 경로다. 50계정 조건에서
`build_equipment_state` 11,800행 Seq Scan/Hash Join을 포함한 plan도 관측했다. 100계정보다 작은
조건이 더 느린 구간을 단순 선형 크기 효과로 설명하지 않는다. planner/statistics·scan 선택의
기여는 추가 통제 실험이 필요하며, 이번에는 인덱스·캐시·migration을 임의 추가하지 않는다.

각 조건에서 profile revision 수 `accounts × history`, current head 계정 일치, previous revision의
계정/연속 번호를 확인했고 오류는 0이었다. 관계별 heap/index/total byte도 보존했다. V0016의
`ck_classic_solo_raid_runtime_state_revision_completed_best_shape`는 과거 immutable 행 보존 때문에
의도된 `NOT VALID`다. 처음 작성한 진단이 이를 손상으로 처리한 실패는
`lifecycle-postgresql/dc813882564e4a1a9eed2fb57449ac00`에 남기고, 역사 제약을 별도 관측값으로
구분해 재검증했다. 두 실행 모두 DB restart checkpoint와 cleanup을 확인했다.
이는 **합성 fixture 검사**이며 운영 pending의 장기 잔존, encrypted pending과 committed revision의
실제 대조 또는 전체 provenance 감사를 수행한 것은 아니다.

#### 실제 편집기 DOM 경계

`lifecycle-postgresql/deddb713f36140c1a038fd8b245026e2`에서 1/10계정 각각 3회, **6/6 통과**했다.
새 headless Edge 프로필과 실제 checked-in editor의 `refresh-accounts` handler를 사용한다.
HTTP 200, 실제 계정 UID 집합·로비 레벨·표시 가능한 DOM, 명령 16/151회를 검증했다.
Edge 버전 `152.0.4191.66`과 실행 파일 hash, editor asset hash는 receipt에 기록한다.

| 계정 | HTTP 완료 ms (3회 원시값) | HTTP→DOM 갱신 ms | 두 rAF 도달 ms (요청 시작 기준) |
| --- | --- | --- | --- |
| 1 | 153.20 / 26.90 / 45.90 | 1.60 / 1.40 / 1.90 | 160.90 / 49.10 / 66.20 |
| 10 | 310.90 / 399.10 / 168.50 | 1.50 / 2.40 / 2.90 | 324.70 / 410.40 / 181.30 |

ResourceTiming responseEnd, MutationObserver와 두 번의 requestAnimationFrame callback을 구분했다.
브라우저·호스트 startup, 전체 login/presentation catalog 흐름은 제외했다. 같은 cell의 server/service
pool은 재사용되므로 process-cold 표본과 합치지 않는다. **compositor paint·설치 WebView2·원본 게임
UI의 지연을 측정한 것은 아니다.** 외부 page 요청은 차단하고 새 프로필은 정리했으며 운영 설치본은
열지 않았다. 3회 표본의 편차를 숨기거나 DOM overhead가 항상 3ms 이하라고 보장하지 않는다.

#### 확장 process-cold 및 마감 검사

`cold-full`은 기존 8조건 모두에서 목록/HTTP 목록/목록+로비/workspace/export/history를 각 10개의
새 프로세스로 읽는다. `lifecycle-postgresql/de79bdf575af424980c98e65d1298b81`의 **480/480**이
통과했고 오류·timeout은 0이다. raw 파일/summary 일치, 서로 다른 480개 PID+시작 시각,
ready 이전 DB 명령/operation 0, fixture/source hash와 경로별 예상 명령을 독립적으로 대조했다.
startup/request p50/p95 **192개**도 원시 표본에서 재계산했다. 8조건 모두 workspace 14,
export 18, history 1명령이며 목록 `1+13A`, 목록+로비 `1+15A`다. 첫 요청과 시작 시간은
분리하고 OS/DB cache는 초기화하지 않았다. DB restart checkpoint와 cleanup도 통과했다.
독립 대조 메모는 `s08-s09-followup/receipt-audit.txt`에 보존한다.

아래 완료된 1/10/50/100계정 조건은 roster 50·history 10이다. 각 행 10표본의 nearest-rank
p95는 최댓값이며 이상치를 제외하지 않았다. startup은 첫 요청 시간에 합산하지 않았다.

| 계정 | service 목록 첫 요청 p50/p95 ms | HTTP 목록+로비 첫 요청 p50/p95 ms |
| --- | --- | --- |
| 1 | 281.19 / 296.55 | 313.51 / 317.76 |
| 10 | 431.87 / 437.85 | 624.71 / 756.18 |
| 50 | 1,533.52 / 1,548.05 | 1,792.17 / 2,083.78 |
| 100 | 1,806.29 / 1,934.28 | 2,145.82 / 2,203.31 |

마감 검사:

- 변경 전 repository/Phase 0~2B/3A/3B0/3B1/3B2 scaffold/약점/Actions 계약 통과. 변경 전
  PostgreSQL **110/110** receipt는 `ecbb7a6ed95a4f94b84c4e49c7a25f51`이다.
- 변경 후 단위 **475개**, 저장/실행 UI·runner 봉인/복구 행동·위 전체 계약 및 build/format 통과.
  계측기 DB-free 자식 **12회**, DOM helper의 loopback guard, 공통 상태/증빙 **53개**도 통과했다.
- 기존 warm smoke **12표본** receipt는 `44180ef220c044b1822afe1606f58c61`, 변경 후 PostgreSQL
  **110/110**은 `ff7829f2e59446ebbb27f9b93e17dc15`다. 두 실행 모두 restart checkpoint/cleanup을
  확인했다. 모든 receipt UID의 상위 경로는 `artifacts/stabilization/lifecycle-postgresql/`이다.
- 상세 로그는 `artifacts/stabilization/s08-s09-followup/`의 `before-gates.log`,
  `before-postgresql.log`, `diagnostic-retry.log`, `dom.log`, `cold-full.log`, `after-gates.log`,
  `after-postgresql.log`에 보존한다. 공통화 후 함수 위치에 묶인 예전 검사 실패와 테스트의 script
  import 정책 실패는 `focused-checks.log`/`admin-retry.log`에 보존했으며, 실제 공통 writer/소비자
  경로를 검사하도록 수정했다. 시스템 실행 정책이나 NuGet audit 옵션은 변경하지 않았다.

이로써 이번 소스 범위의 계측·공통화·회귀 검증을 마감한다. **S-08/S-09 전체 종료 판정은 아니다.**
물리 I/O, planner/statistics 통제 실험, 목록 read model의 추가 최적화, 설치 WebView2/실게임 인수와
아래 운영 DB·전수 리뷰 경계는 남아 있다. 이 결과를 P-01~P-09 착수나 운영 변경 승인으로 확대하지 않는다.

### S-09 / 중간 — 프로세스 identity와 복구 공통 코드가 부분적으로 다름

- 초기 점검의 PID/name-only `Stop-PinnedProcess` 지적은 **과거 상태**다. 현행은 PID·시작 시각·
  경로를 확인한 동일 native handle로 wait/stop하고, 잔류 서버도 배타적 ownership proof를 요구한다.
  2026-09-07 보강을 다시 미구현으로 취급하지 않는다.
- 2026-09-11: coordinator/watcher/recovery의 JSON 저장을 기존 봉인 member인
  `Nll.PhaseDProcessIdentity.ps1`로, pg_ctl exact-child wait를 `Nll.PhaseDChildProcess.ps1`로 공통화했다.
  JSON은 같은 디렉터리의 임시 파일을 만든 뒤 기존 파일에는 `File.Replace`, 최초 생성에는
  `File.Move`를 쓴다. 교체 실패 시 이전 JSON을 유지하고 자신의 partial만 정리한다. filesystem
  atomic replacement이지 전원 장애에 대한 fsync/durability 보장이라고 부르지 않는다.
- watcher/recovery의 Solo Raid persistence proof는 기존 `Nll.PhaseDCompletion.ps1`의 공통 함수로
  옮겼다. launch root/context를 명시적으로 받고 기존 account/revision/snapshot/build/hash 결박을
  보존한다. 대문자 result code와 malformed/empty-Guid `no_state` head가 허용되던 분기를 닫았다.
- 새 합성 행동 검사 **53개**는 실제 파일·hash·context 변조, 실패한 JSON 교체의 이전 값 보존,
  exact pg_ctl 자식의 인자/exit code와 두 소비자 wrapper를 검사한다. 예전 두 permissive predicate를
  되돌린 negative control이 잘못된 fixture를 허용하는 것도 확인했다. 소스 문자열 검사 일부는
  helper import/binding 확인만 남기고 의미 검증은 이 행동 검사와 기존 종료/복구 검사로 옮겼다.
- runner member 목록/contract version은 바꾸지 않는다. 이미 생성된 bundle은 자신의 옛 helper를
  계속 쓰며, 새 실행만 새 hash closure를 생성한다. 설치 앱 파일을 배포하지 않았지만 **설치된
  실행 경로가 저장소 스크립트를 직접 읽으므로 다음 새 실행은 이 소스를 소비할 수 있다.**
  변경 전 복원 기준은 `0d362ad`의 동일 스크립트 집합이다. 이미 봉인된 bundle과 임의 혼용하지 않는다.
- 남음: 실행/복구 단계별 timeout 및 실패 후 ownership 정책의 추가 통합. pg_ctl의 기존 `-w/-t`와
  exact-child wait를 유지했고, timeout만으로 PostgreSQL descendant를 강제 종료하지 않는다.
  운영 DB pending/provenance 대조와 실제 게임 종료 인수도 별도다.

이번 잔여 코드 점검은 프로세스·완료/복구 helper, workspace Save/CAS/provenance와 raid state의
기존 rollback/replay/경합 통합 검사, automation inventory/state-machine, desktop entry/stop 흐름을
대상으로 했다. importer/domain 전체 파일을 전수 검토했다고 표시하지 않는다. desktop의 async
시작 실패·stderr backpressure/실제 WebView2 구간은 별도 재현 검사가 더 필요하다. 이번에 desktop
설치본을 열거나 자동화된 전체 UI 인수를 수행한 것은 아니다.

### S-10 / 높음 — 현재 운영 명세와 과거 단계 기록, 빌드 기준선의 분리 부족

- 확인: `NEXT_STEPS`, `ARCHITECTURE`, `HANDOFF`, `DECISIONS` 등에 150 first proof와
  미실행/향후 bridge 문구가 남아 있었다. 일부 항목은 역사적으로 맞지만 현재 지시로 읽힐 수 있다.
- 확인: 핵심 coordinator/watcher/bundle helper/materializer entrypoint 네 경로는 이
  점검 시점 `git ls-files`에 없었다. 이는 코드 유실을 뜻하지 않지만 현재 working tree와
  커밋된 재현 기준선을 혼동하면 안 된다는 뜻이다. 임의로 stage/commit/push하지 않는다.
- 방향: 현행 명세, 결정 기록, 역사적 실행/실패 기록, 실행 runbook을 분리한다.
  source-only 변경을 검증 가능한 작은 단위로 관리하고 설치 artifact/manifest와 결박한다.

## DB에서 보존할 기반과 추가 확인 사항

- `ClassicSoloRaidRuntimeStateStore.PersistAsync:232`는 Serializable transaction,
  request hash replay, head CAS, 완료 최고점 역행 quarantine를 갖춘다. V0013에는
  revision lineage/FK/unique/check/immutable guard와 index가 있다. 이를 “스파게티”라는
  이유로 제거하거나 적용된 migration을 수정하지 않는다.
- 아직 필요한 DB 점검: pending operation 장기 잔존, head/revision/provenance 연결,
  중단·동시 Save의 복구, encrypted pending과 committed revision 대조, 성장률과 조회 계획.
- 레이드 key는 현재 account/season/snapshot/client build/executable이며 선택 약점이 없다.
  운영자는 약점별 최고점·이력 분리를 요청했다. 아래 P-05에서 설계·이관·검증 대상으로
  관리하며, 현재 구현이 분리됐다고 표시하거나 기존 기록의 약점을 추정해 이동하지 않는다.
- 프로세스 종료/복구 완료와 레이드 완주는 서로 다른 의미다. 회귀 검사에서 반드시
  분리한다. 메인 화면 Quit은 덱 수와 무관하게 최고 기록을 갱신하지 않지만,
  이미 끝난 덱의 전투 이력과 저장된 편성까지 삭제해서는 안 된다.

## 영속화 추가 정비 — 2026-09-06 요구 / 2026-09-12 구현·검증

운영자의 화면·예시로 확정한 요구와 현 소스에서 확인한 필드를 구분한다.
아래 내용은 2026-09-06 확정 요구다. 2026-09-12 P-01/P-05 → P-04 → 나머지 설정 구현을
진행했으며 새 SQL V0019~V0021, 외부 서버 source-only patch, 회수·저장·복원 검사를 추가했다.
현행 완료 범위·배포 상태·운영자 실게임 확인은 [실행 간 영속화](features/RUNTIME_PERSISTENCE.md)를
따른다. 아래의 당시 미구현 설명을 현행 코드 판정으로 사용하지 않는다.

### P-01 — 원본 My Records를 최고점과 독립된 덱별 전투 이력으로 보존

- 대상은 **원본 클라이언트의 모의전/실전 진입 후 스쿼드 편성 화면에 있는 My Records**다.
  Control Center 분석 화면만 추가하는 것으로 대체하지 않는다.
- 정상 동작 중인 랭킹 창과 모의전/실전 진입 선택 화면의 최고 합딜은 유지한다.
  실전은 5덱 완주 합계가 기존 최고점보다 높을 때만 갱신하며, 메인 화면 빨간 Quit은
  조기 완주가 아니라 포기다. 모의전 이력을 실전 최고점으로 승격하지 않는다.
- 각 덱의 유효한 전투 결과가 접수되면 구성·피해량 이력을 독립적으로 저장하고 조회에 반영한다.
  5덱 완주, 최고점 갱신, 게임 프로세스 종료까지 기다리는 조건을 붙이지 않는다.
  낮은 점수 완주와 1~4덱 후 Quit에서도 이미 접수된 이력을 지우지 않는다.
- 동일 덱으로 여러 번 친 결과도 각각 보존하며 실제 전투 시점 내림차순으로 반환한다.
  일일 상태 초기화·Quit·재기동은 이력 삭제 조건이 아니다.

운영자 인수 예시(한 보스·한 약점·실전, 배열은 전투 순서):

| run | 덱 피해량 | 합계 / 종료 | 종료 후 최고점 | 이력에 남을 건수 |
|---|---|---|---|---|
| 1 | `[20, 30, 50, 10, 15]` | 125 / 완주 | 125 | 5 |
| 2 | `[25, 35, 55, 15, 20]` | 150 / 완주 | 150 | 5 |
| 3 | `[15, 25, 45, 5, 10]` | 100 / 완주 | 150 | 5 |
| 4 | `[61]` | 61 / 메인 화면 Quit | 150 | 1 |

최종 랭킹·진입 화면은 **150**이다. My Records는 **16건**이며,
`4run: 61 → 3run: 10, 5, 45, 25, 15 → 2run: 20, 15, 55, 35, 25 → 1run: 15, 10, 50, 30, 20`
순서로 각 덱 구성을 함께 보여야 한다. 4run의 61을 완주 최고점으로 취급하지 않는다.

현 소스와 수정 경계:

- 외부 151 소스 `SoloRaidHelper.CloseSoloRaid`는 진행 level과 그 안의 `Logs`를 함께 제거한다.
  `SetDamage`는 기존 최고점 이하의 완주 run을 현재 목록에 남기지 않는다.
- `ClassicSoloRaidRuntimeState.Extract`는 완주 최고점 1개와 진행 run 최대 1개만 추출한다.
  V0013 revision은 캡처 상태 이력이지 모든 전투 이력을 보장하는 원장이 아니다.
- `/soloraid/getlogs` → `ClassicSoloRaidRouteExecutor.GetLogs` → `SoloRaidHelper.GetSoloRaidLog`도
  현재/최고 level 중심이다. `ResGetSoloRaidLogs.Logs`와 `PracticeLogs`를 해당 실전/모의전
  이력에서 생성하도록 검토한다. 응답 길이·정렬·스크롤의 클라이언트 한계는 실게임으로 확인하며,
  DB에만 보존하거나 임의로 최근 5건만 반환하고 완료로 판정하지 않는다.
- 설계는 run의 진행/완주/포기 상태, 덱별 전투·참여 캐릭터 snapshot, 최고점 참조를 분리한다.
  전투 순번·시각과 중복 접수 식별을 보존하며 재전송/복구가 이력을 중복 추가하지 않게 한다.
  기존 `challenge_run*`는 harness 전용 계약이므로 실제 전투가 이미 저장된 것으로 오해하지 않는다.
- `NetSoloRaidLog`의 현재 필드는 `Damage`, `Team`, `Kill`이다. 캐릭터별 피해 분석은 별도 과제이며,
  기존 캐릭터별 원자료 없이 추정하거나 wire 필드에 다른 의미를 억지로 넣지 않는다.

### P-02 — 콘텐츠 해금 알림의 표시 완료 상태 보존

- 관측: 로비에 다시 접속할 때 같은 콘텐츠 UNLOCK 팝업이 반복된다.
- 요구: 이미 확인한 콘텐츠의 팝업/버튼 해금 연출은 재접속 시 반복하지 않는다.
  실제 콘텐츠 해금 조건과 '해금 연출을 이미 보여줬는지'는 별개 상태다.
- 기존 필드: `User.ContentsOpenUnlocked[content].ButtonAnimationPlayed`, `PopupAnimationPlayed`.
  응답 필드는 `IsUnlockButtonPlayed`, `IsUnlockPopupPlayed`다.
  `ContentsOpenController`의 `/v1/contentsopen/set/unlock/button` 및 `/popup`은
  해당 값을 갱신하고 `JsonDb.Save()`를 호출한다. 필드 자체가 없는 것으로 단정하지 않는다.
- 확인/수정: 해당 알림 확인 요청 → runtime DB → 종료/복구 캡처 → 장기 저장 → 다음 실행 응답의
  왕복 보존을 추적한다. 기존 fetched progression observation과 접속 중 갱신 상태를 구분한다.
  모든 콘텐츠에 일괄 true를 넣거나 새 콘텐츠까지 미리 읽음 처리하는 방식은 사용하지 않는다.
- 인수: 같은 알림 확인 후 두 번 재접속해 재표시 없음. 새로 해금된 콘텐츠의 정상 알림은 유지.

### P-03 — 인게임에서 변경한 착용 스킨 보존

- 요구: A 캐릭터의 기본 스킨을 `skin_3`으로 변경한 뒤 종료·재접속하면 `skin_3`을 유지한다.
  스킨 보유 목록과 현재 착용 선택은 별개다.
- 기존 필드/경로: `User.Characters[].CostumeId`, `/character/costume/set`의 `SetCharacterCostume`.
  현재 handler는 요청의 캐릭터를 찾아 `CostumeId`를 변경하고 `JsonDb.Save()`를 호출한다.
  `User.CostumeList`는 보유 목록이며 착용 선택을 대신하지 않는다.
- 확인/수정: 캐릭터별 최신 착용 선택을 장기 보존하고, 다음 materialize에서 고정 baseline보다
  보존된 선택을 적용한다. local 캐릭터 식별자에 결박하며 runtime `Csn`이 바뀌어도 잘못 매핑하지 않는다.
  관리도구 Save/Save As와의 우선순위·revision 충돌은 구현 전에 명세하고 조용히 덮어쓰지 않는다.
- 인수: 재접속·보스/약점 전환 후 착용 유지. 다른 캐릭터/계정의 선택과 과거 전투 snapshot은 불변.

### P-04 — 솔로레이드 편성 슬롯 보존

- 관측/요구: 01~05 덱에 편성하고 전투한 뒤 클라이언트를 종료·재실행해도
  구성원과 슬롯 순서가 유지돼야 한다. 편성을 매번 빈 칸으로 초기화하지 않는다.
- 기존 경로: `User.UserTeams[type]`, `NetUserTeamData.Type`, `LastContentsTeamNumber`,
  `Teams[].TeamNumber` 및 각 팀의 구성 데이터. `/team/set`의 `SetTeam`이 변경을 저장하고,
  `/team/get`의 `GetTeamData`가 반환한다. 실제 Solo Raid 실전/모의전 type 매핑은 확인 대상이다.
- 이는 P-01의 '어떤 덱으로 얼마나 쳤는가'라는 과거 전투 이력과 다르다.
  편성을 바꿔도 과거 전투 구성은 불변이며, 전투하지 않은 편성도 보존 대상이다.
- 확인/수정: 종료 전 편성 캡처와 다음 실행 복원, 캐릭터 식별 재매핑을 검증한다.
  빈 팀으로 명시적으로 바꾼 요청과 캡처 데이터가 없는 경우를 구분한다.
  계정 간 편성을 섞지 않으며 보스/약점/모드별 편성 공유 범위는 구현 전에 명세한다.
- 사진의 `Invalid`는 원인을 확정할 증거가 아니다. 편성 복원이 진행 run의 출전 완료·재사용 제한을
  초기화하거나 미완주 run을 완주 처리하는 변경으로 이어지면 안 된다.
- 인수: 여러 팀과 슬롯 순서, 명시적 빈 슬롯, 마지막 선택 팀을 재접속 후 대조한다.
  진행 중 run 복원/새 run 시작 각각에서 기존 출전 제한 동작도 함께 검증한다.

### P-05 — 보스의 선택 약점별 최고점·My Records 분리

- 요구/설계 방향: 같은 보스라도 약점 철갑에서 세운 기록을 약점 수냉에서 표시하지 않는다.
  랭킹, 진입 화면 최고 합딜, My Records가 모두 현재 선택 약점의 같은 기록 범위를 사용해야 한다.
  여기서 기준은 UI가 선택하는 **약점 코드**이며 보스 자체 속성 코드와 혼동하지 않는다.
- 현 근거: materialization receipt에는 `raidWeaknessCode`와 boss variant 정보가 있지만,
  V0013 상태 key 및 영속 capture/store에는 선택 약점이 없다. 단순 UI 필터만으로 해결되지 않는다.
- 가능 방향: account + season/보스 식별 + 선택 약점을 기록의 논리적 범위로 고정한다.
  기존 snapshot/build/executable 출처·호환성 경계는 보존하며, 버전 간 계승을 자동으로 확대하지 않는다.
  실행 시작 때 검증한 선택을 run/전투/최고점/진행 상태에 함께 결박하고, 캡처·replay·복원·조회에도 전달한다.
  실전과 모의전 구분도 유지한다. 특정 S26/S29 전용 조건 없이 보스 공통 파이프라인에 적용한다.
- 기존 최고점 비감소 검사도 같은 약점 범위 안에서만 적용한다. 철갑 최고점이 수냉의 새 저장을
  막거나 다른 약점의 진행 run을 이어받는 일이 없어야 한다.
- 과거 기록 이관: 당시 실행 receipt 등으로 약점을 입증할 수 있을 때만 연결한다.
  알 수 없는 기록은 원본과 출처를 보존하고 약점 미확정으로 분리한다. 모든 약점에 복제하거나
  보스의 기본 약점·현재 선택을 과거 기록에 소급 대입하지 않는다. UI 표시 정책은 별도 확정한다.
- 인수: 철갑에서 최고점 150과 이력을 만든 뒤 미기록 수냉으로 진입하면 수냉은 빈 이력/미기록.
  수냉에서 100을 완주하면 수냉 최고점은 100, 철갑으로 돌아가면 150과 원래 이력만 표시한다.
  재접속, Quit, 중복 복구에서도 양쪽 기록이 섞이지 않아야 한다.

### 추가 선택 범위 — P-06~P-09만 등록

Epinel 기능 대조 후 운영자가 추가로 선택한 항목은 아래 네 가지뿐이다. P-01~P-05는 유지한다.
음악 즐겨찾기·플레이리스트 편집, 주력 니케 표시, 호감도 즐겨찾기, 추가 튜토리얼/시나리오
완료 동기화는 이번 추가 과제로 등록하지 않는다. 인게임 빌드 변경을 관리도구로 반영하는 작업과
지원 범위 밖 콘텐츠·Epinel 미완성 기능도 이번 정비 대상으로 확대하지 않는다.

### P-06 — 로비 캐릭터·배경 설정 보존

- 요구: 인게임에서 선택한 로비 캐릭터와 배경을 종료·재접속 후에도 유지한다.
- 기존 필드/경로: `User.WallpaperList`, `WallpaperBackground`,
  `/User/SetWallpaper`의 `SetWallpaper` → `JsonDb.Save()`, `GetWallpaper` 조회.
- 확인/수정: 선택된 슬롯·캐릭터·배경을 계정별로 캡처·영속화·복원한다.
  보유 목록과 실제 선택 상태를 구분하고, 고정 baseline으로 되돌리지 않는다.
- 인수: 로비 캐릭터와 배경을 각각 바꾼 뒤 두 번 재접속해 동일한 선택을 확인한다.
  다른 계정의 설정과 캐릭터 빌드·레이드 기록은 변경하지 않는다.

### P-07 — 로비·지휘관실 BGM 선택 보존

- 요구: 로비와 지휘관실에서 선택한 BGM을 위치별로 구분해 종료·재접속 후에도 유지한다.
- 기존 필드/경로: `User.LobbyMusic`, `CommanderMusic`의 `TableId`, `Type` 등 선택 상태와
  `/jukebox/set/tableid`의 `SetTableId` → `JsonDb.Save()`.
- 확인/수정: 각 위치의 실제 BGM 선택 요청·응답을 대조하고 선택을 독립적으로 보존한다.
  음악 즐겨찾기·플레이리스트 편집 전체의 영속화로 범위를 확대하지 않는다.
- 인수: 로비에 곡 A, 지휘관실에 곡 B를 선택한 뒤 재접속해 각각 A/B가 유지됨을 확인한다.

### P-08 — 프로필 꾸미기 보존

- 요구: 인게임에서 변경한 프로필 아이콘·프리즘 여부·프레임·칭호·프로필 카드 배치를 유지한다.
- 기존 필드/경로: `User.ProfileIconId`, `ProfileIconIsPrism`, `ProfileFrame`, `TitleId`,
  `ProfileCardDecoration`. `SetProfileData`, `SetUserTitleData`, `SaveDecorationLayout`에
  상태 갱신과 `JsonDb.Save()` 처리가 있다.
- 확인/수정: 꾸미기 선택·배치의 계정별 저장과 재적용을 연결한다. 보유 목록을 선택 상태로
  오해하지 않으며, 관리도구 계정명·레벨·캐릭터 빌드의 권위까지 변경하지 않는다.
- 인수: 각 항목 변경 후 재접속해 원본 프로필 화면에서 같은 표시·배치를 확인한다.

### P-09 — 배지 삭제 상태 보존

- 요구: 확인하여 지운 배지가 다음 접속에서 고정 baseline 때문에 다시 나타나지 않게 한다.
- 기존 필드/경로: `User.Badges`, `/badge/delete`의 `DeleteBadge`가 요청된 배지를 제거하고
  `JsonDb.Save()`를 호출한다. `/badge/sync`의 `SyncBadge`는 남은 배지를 반환한다.
- 확인/수정: 삭제/확인 상태를 계정별로 보존하고 재접속 시 같은 배지를 식별할 수 있는지 검증한다.
  해금 연출 완료(P-02)와 구분하며, 신규 배지를 일괄 삭제하거나 모든 알림을 읽음 처리하지 않는다.
- 인수: 배지 X를 확인·삭제하고 재접속하면 X가 다시 나타나지 않는다. 이후 새로 생긴
  배지 Y는 정상 표시되고 다른 계정의 배지는 영향을 받지 않는다.

### 공통 저장 경계와 완료 기준

- Epinel의 실행용 `db.json` 저장과 Local Lab의 접속 간 영속화는 별개다.
  기존 종료 watcher/orphan recovery의 복원 전에 승인된 상태를 안전하게 캡처하고,
  PG 재시작 후 저장·재시도·충돌 처리를 거쳐 다음 실행에 복원하는 경계를 검증한다.
- 전투별 이력은 전투 접수 시 내구성 있는 로컬 저장이 필요하다. PG가 게임 중 중지되는 현 구조에서
  종료 시점의 최고점 snapshot 하나에 모든 이력을 의존시키지 않는다. 기존 payload 용량 제한도 고려한다.
- 원본 DB 전체를 무조건 되가져오지 않는다. 해금 알림·착용·편성·전투 이력과 운영자가 선택한
  로비 캐릭터/배경·위치별 BGM·프로필 꾸미기·배지 삭제 상태만 명시적으로 허용하고 실행 중 임시 상태와
  분리한다. 신규 schema는 additive migration으로 추가하며 기존 revision을 덮어쓰지 않는다.
- 계정 격리, 원본 식별자와 local 참조 매핑, 데이터 유실/중복 없는 재접수·복구, 동시 Save 충돌을
  합성/폐기 DB 테스트로 고정한 뒤 원본 클라이언트 화면으로 인수한다. 새 진단용 HTTP 검사 계층이나
  DLL 변경을 이 요구의 전제로 끼워 넣지 않는다.

P-01~P-05 문서 등록 당시 검증: 변경 문서의 링크·앵커·공백, 저장소 정책(`-AllowRemote`), Phase 0,
Phase 3A/3B0/3B1/3B2의 `-ContractOnly`, Actions 계약은 통과했다. Phase 2A1/2A2/2B 검사 체인은
재시도했으나 NuGet 취약성 정보 조회의 네트워크 오류 `NU1900`으로 restore 단계에서 중단됐다.
기존 단위 검사 통과 이력과 이번 재검사 결과를 구분하며, 테스트 DB 미설정으로 운영 DB는 사용하지 않았다.

## 정비 순서와 종료 조건

### 승인된 구현·검증 계획 — 2026-09-06

운영자 승인 범위는 **계획 기록 → 기준선/행동 테스트 → S-09/S-01/S-02 실행 생명주기 묶음**이다.
운영자 부재 중에는 합성 데이터와 가짜 프로세스 또는 무해한 테스트 자식만 사용한다.
실게임, UAC, 설치본 배포, 운영 DB 변경, hosts/firewall 변경, DLL 교체는 실행하지 않는다.
기존 working tree의 미커밋 변경을 기준선과 구분하고 일괄 stage/commit하지 않는다.

| 순서 | 해결 방향 | 검증 및 종료 조건 |
|---|---|---|
| S-10/S-06 | 현행 소스와 검증된 설치 artifact를 구분하고, 구현 문자열을 고정한 테스트를 행동 테스트로 교체 | locked restore/build/format/unit/계약 검사 결과와 미실행 항목 기록. 수정 전 실패 재현, 수정 후 같은 테스트 통과 |
| S-09/S-01/S-02 | 요청 수명과 실행 소유권 분리, 읽기 전용 상태 조회, 독립 백그라운드 복구, 중복 시작 방지, active/history 분리 | 시작·복구 대기 중 조회 가능, HTTP 취소에도 소유권 유지, 다른 서비스 인스턴스의 경합 차단, 손상 과거 기록 격리, 불명확한 active 상태에서는 새 실행 차단 |
| S-03/S-07 | 완료된 immutable revision 묶음만 candidate/lobby 입력으로 사용하고 Save 단계 조정 분리 | 동시 Save/Launch, 단계별 중단·exact replay·CAS를 폐기 DB에서 검증. 개별 RepeatableRead만으로 다단계 Save의 완료를 보장한다고 간주하지 않음 |
| S-04/S-05 | bundle/boss 준비 결과를 단일 권위로 공급하고 문자열 치환 실행기를 명시적 입력 runner로 점진 전환 | 기존 파생 출력과 합성 동작 대조, 잘못된 hash/schema 및 S29 불일치 fail closed. 검증된 Epinel DLL 유지 |
| S-08 | 조회량·SQL 횟수·p50/p95를 측정한 뒤 batch/immutable revision cache 적용 | 계정/로스터/이력 규모별 전후 측정, stale revision 및 계정 간 데이터 혼합 없음 |

생명주기 묶음의 안전 조건:

- GET은 프로세스 실행·복구·상태 쓰기를 하지 않는다. 대신 독립 lifecycle worker가 재조정한다.
  과거 GET 복구를 제거한 뒤 stale 상태가 영구히 남는 퇴행을 허용하지 않는다.
- 시작/복구의 응답 대기는 제한하되, 시간 초과를 복구 성공이나 runtime cold로 간주하지 않는다.
  아직 실행 중인 소유자를 강제 종료하거나 잠금을 풀어 두 번째 실행을 허용하지 않는다.
- 프로세스 식별은 PID, 시작 시각, 예상 실행 파일을 대조한다. PID 재사용/경로 불일치/식별 불능은
  다른 프로세스 종료로 처리하지 않는다. 완료 전 capture → restore → PG replay/CAS 순서를 보존한다.
- 손상 이력은 정상 목록/개별 조회와 격리하되 원본을 삭제하지 않는다. 종료가 증명되지 않은 상태의
  손상·결손은 여전히 admission을 차단한다. `started`는 로비/실게임 성공 증거가 아니다.
- 자동 검사 통과와 원본 게임 인수를 구분한다. 배포·로비 전 종료·전투 종료·재실행은 운영자 복귀 후
  별도 승인된 실게임 확인으로 남긴다. P-01~P-09와 S29 작업은 이 묶음에 포함하지 않는다.

착수 기준선: NuGet 네트워크 오류를 해소한 locked restore 후 저장소·Phase 0·3A/3B0/3B1/3B2
계약·Actions·Phase 2A1/2A2/2B 체인과 자동화 단위 검사 통과(기존 단위 409개).
전용 PostgreSQL 테스트 DB/reset token 미설정으로 DB 통합은 미실행이다.

### 생명주기 묶음 1차 반영 — 소스/오프라인 검증, 배포 전

- **S-01:** `PhaseDOperationGate`가 요청 취소와 분리된 작업 및 실행 루트 파일 lease를 소유한다.
  Start는 candidate/lobby와 최초 `draft`를 저장한 뒤 launch UID를 반환하고 coordinator는 계속 진행한다.
  GET은 해당 상태만 읽으며 복구/전체 이력 탐색/실행 잠금을 사용하지 않는다.
  `PhaseDLifecycleWorker`를 실제 호스트에 등록하여 상태 폴링 없이도 5초 간격으로 재조정한다.
  응답 대기의 상한은 2분이다. 초과 시 `phase_d_operation_pending`이고, 실제 자식이 끝날 때까지
  소유권을 유지한다. 시간 초과를 `failed`/cold로 강제 변환하거나 자식/게임을 강제 종료하지 않는다.
- **S-02:** 개별 GET과 목록의 손상 파일 영향을 격리했다. 목록에서 읽을 수 없는 항목은 안전한
  오류 코드와 local launch UID로 로그를 남기고 원본은 보존한다. 개별 GET은 해당 파일의 오류를 반환한다.
  `.lifecycle-closed/<launchUid>.json`에 확인된 terminal 상태·원본 상태 hash·분류 시각을 저장하여
  종료 확인된 과거 이력과 미확인 실행을 구분한다. 미분류 손상/결손이나 모순되는 pending 증거는
  새 실행을 계속 차단한다. 정상 완료 후 남기는 capture/persistence 영수증은 pending payload와 구분한다.
  완료 기록에도 pending payload가 남았다면 기존 exact replay 경로로 재조정한다.
- **S-09:** coordinator/recovery 자식의 `starting/running/exited` 및 PID·시작 시각·예상 경로를 기록한다.
  프로세스 생성과 identity 게시 사이의 중단은 `unresolved`로 남겨 다른 복구와 경합하지 않는다.
  watcher의 client 대기·비상 종료는 동일 handle의 PID/시각/경로를 검증한다. 이미 종료된 프로세스,
  재사용 PID, 다른 경로, 누락 pin을 구분하며 확인 불가능한 프로세스를 종료하지 않는다.
  coordinator와 watcher의 짧은 상태 쓰기를 직렬화하여 완료/실패 상태가 뒤늦은 `started`로 덮이지 않게 했다.
  .NET의 원자적 JSON 쓰기는 공통 helper로 합쳤다.
- **UI 연결:** 실행/요청 진행 중 상태가 “준비 완료”로 덮이거나 시작 버튼이 다시 활성화되는 경로를 고쳤다.
  동일 요청 중복 클릭을 막고, 일시적인 상태 조회 실패 후에도 활성 실행의 폴링을 재시도한다.
  새 UI나 게임 진단 계층을 추가한 것은 아니다.

검증 결과:

- 수정 전 손상 과거 기록으로 정상 GET/목록이 실패하는 행동 테스트 2건을 재현했고 수정 후 통과했다.
- Admin 단위 검사 **69개 통과**(기준선 47개에서 **22개 추가**). 요청 취소/대기 상한, 별도 서비스
  인스턴스 경합, 실제 hosted worker의 독립 복구, live owner 보호, recovery exit 2/실패,
  손상 이력과 미확인 active의 구분, 완료 영수증 보존, pending replay, 자식 생성 실패/무해한 자식 종료를 포함한다.
- PowerShell helper의 가짜 프로세스 10개 및 상태 handoff 5개 경우 통과. 이 helper 검사는 Admin 단위
  검사 1건에 포함되어 있으므로 전체 수에 중복 가산하지 않는다. 변경된 PowerShell 파일의 parse도 통과했다.
- 네트워크/실행 서버 없는 Node 기반 UI 동작 검사와 JavaScript 구문 검사 통과.
- PowerShell 7에서 저장소·Phase 0·3A/3B0/3B1/3B2 계약·Actions·Phase 2A1/2A2/2B 검사 체인 통과.
  자동화 단위 41개를 포함한 기존 검사와 마지막 Admin 재검사 합계 **431개 통과**.
  전체 gate를 Windows PowerShell 5로 잘못 호출한 중간 시도는 도구 버전 오류였으며, 7로 재실행하여 확인했다.
- 변경 전 핵심 9개 파일의 LF 정규화 텍스트 사본을 로컬
  `artifacts/stabilization/2026-09-06-lifecycle/source-before/`에 보존했다. 이는 git commit 기준선이나
  원본 binary hash 봉인이 아니다. 소스/문서 사본뿐이며 게임 리소스·DB·계정 데이터 복제는 없다.

남은 종료 조건/제한:

- **S-09/S-01/S-02 전체 완료 또는 실게임 검증 완료로 표시하지 않는다.** 이번 결과는 첫 수직 경로의
  소스 개선과 오프라인 회귀선이다. 변경 소스와 검증된 설치 artifact가 아직 다르다.
- 새 helper를 포함한 배포 파일 집합/hash/rollback 검증 및 설치된 관리도구에서의 로비 전 종료,
  정상 종료/영속화/재실행 인수는 운영자 복귀 후 진행한다. 이번에는 UAC나 게임 실행을 요청하지 않았다.
- 장시간 자식을 강제 취소하는 단계별 복구 정책, 모든 기존 파생 start/completion 내부 helper의
  공통화, raw 이력 전체 순회를 없애는 성능 개선은 후속이다. 검증된 부모 스크립트의 문자열 치환과
  DLL은 이번에 재작성하지 않았다. 기존 상태의 미확인 손상을 임의로 terminal로 분류하지 않는다.
- 전용 PostgreSQL 통합 DB가 없어 실제 PG 중단/replay/CAS의 새 failure-injection 통합 검사는 미실행이다.
  기존 영속화 순서/검증을 유지했지만 가짜 프로세스 검사를 실제 DB·게임의 성공 증거로 대신하지 않는다.

### 생명주기 묶음 2차 — 폐기 DB 검증 및 배포 준비 점검

운영자가 관리도구 종료를 확인한 뒤, 운영 DB와 다른 임시 data directory 및 loopback
`127.0.0.1:55432`의 PostgreSQL 17.11만 사용했다. 게임/UAC/설치 변경은 실행하지 않았다.

- **S-01/S-09:** .NET runner가 정확한 자식 종료 후에도 하위 프로세스의 상속 stdout/stderr
  EOF를 기다리던 문제를 무해한 자식으로 재현했다(수정 전 8초 제한 실패).
  실제 자식 종료를 기다린 뒤 폐기용 출력 읽기만 취소한다. 게임/하위 프로세스를 종료하지 않는다.
  coordinator/watcher의 자식 실행은 `Nll.PhaseDChildProcess.ps1`로 공유하고, 예외와 명시적
  nonzero exit를 보존한다. 인수 quoting, 출력, 예외, exit code, 살아 있는 descendant를 행동 검사한다.
- **S-09:** 비상 종료는 세 프로세스의 PID·시각·경로를 모두 확인한 후 같은 handle로 수행한다.
  하나라도 불명확하면 어떤 프로세스도 종료하지 않는다. coordinator와 watcher의 실패 경로는
  rollback이 미확인일 때 hosts 복원/PG 재시작을 하지 않는다. PG/hosts 복구 실패도 terminal로
  숨기지 않고 재조정 대상으로 유지한다. 실제 catch 블록을 가짜 서비스/임시 파일로 검사한다.
- **S-06/검사 기준선:** 분산된 마이그레이션 수 기대 38곳(기존 9/15/17)을 명시적 `MigrationBaseline.Count=17`
  로 통일했다. 원본 ID 금지 검사는 허용된 local UUID·digest·byte length의 정확한 table/column/type만
  구분하며, 다른 테이블에 같은 이름을 삽입하는 거부 테스트도 포함한다. SQL migration은 변경하지 않았다.
- **폐기 DB 결과:** 전체 **59개 중 58개 통과, 1개 실패**. 남은 무변경 저장·큐브 diff는 위 S-07에
  등록했으며 전체 integration gate 통과로 표시하지 않는다. 이번 직접 관련 검사 6개는 별도 실행에서
  모두 통과했다(레이드 상태 5개 + 보안 열 검사 1개).
  추가된 레이드 테스트는 revision 삽입 뒤 SQL 실패의 전체 rollback/동일 요청 재시도,
  commit 후 응답 유실·새 connection pool의 exact replay, 경쟁 CAS와 stale 재시도를 검증한다.
  별도로 PostgreSQL을 실제 stop/start하여 합성 checkpoint 보존도 확인했다. 이는 게임이나
  운영 DB 장애 복구의 실측 증거가 아니다. 각 실행 종료 후 임시 cluster 삭제·listener/process 종료를 확인했다.
- **배포 준비 결과:** `prepare-nll-lifecycle-offline-package.ps1`은 ignored artifacts에 후보 앱·공유
  스크립트·hash와 설치된 Admin DLL/PDB/editor JS의 byte-exact 백업만 만든다. 설치 앱과 후보의
  의존 DLL 4개(Application.PrivateServer, Domain.PrivateServer, Domain.Profile, Persistence.PostgreSql)가
  다르므로 단일 Admin DLL 교체를 승인하지 않는다. 이전 source-before는 LF-normalized 참고 자료이지
  byte-exact 복구본이 아니다. 저장소 스크립트는 실행 시 직접 소비되므로 앱만 되돌리는 rollback은 불충분하다.
- **최종 오프라인 회귀선:** 단위 **435개 통과**(Admin 73, Automation 41 포함),
  solution 서식/빌드 및 저장소·Phase 0·3A/3B0/3B1/3B2 계약·Actions 검사 통과.
  앱 백업 3개는 별도 rehearsal 복사본에서 복원 hash를 검사한다. 이 앱 파일 복원 검사만으로
  미봉인 저장소 스크립트까지 포함한 전체 runtime rollback 준비가 끝난 것은 아니다.

재현 도구는 `scripts/test-nll-lifecycle-postgresql.ps1`(전체 또는 `-Filter`),
`PhaseDProcessRunnerTests`(PowerShell 행동 검사 포함)이다. 결과는
`artifacts/stabilization/lifecycle-postgresql/`의 실행별 TRX/receipt 및
`artifacts/stabilization/lifecycle-package/`의 후보 manifest에 보존한다.
운영 DB·계정 데이터·원본 클라이언트·검증된 Epinel DLL은 수정하지 않았다.

**2차 당시 배포 보류 조건:** 무변경 Save 실패 해결, 설치/소스 의존성 4개 대조 및 일치하는 배포/rollback
파일 집합 봉인, 이후 운영자 배포 승인과 실게임 인수. 후보 manifest는 `deploymentAllowed=false`이다.
S-09/S-01/S-02 전체 완료 또는 설치 적용 완료로 표시하지 않는다.

### Save 검사 기준선 복구와 DLL 대조 — 2026-09-06 후속

- **검사 전제 정리:** 큐브 보유가 확정된 fixture에서 기존 `Assert.Empty`와 profile/lobby revision
  불변 검사를 유지했다. 구형 빈 inventory는 최초 diff → 승인된 Save → 이후 무변경으로 별도 검사한다.
  레벨 1/15 보존, 새 service의 exact replay, 실제 import 생성 직후 no-op 검사를 추가했다.
  동일 긴 테스트 뒤에 가려져 있던 낡은 private 메서드 reflection 호출과 Save As 부모 계정 누락도
  수정했다. private 호출 대신 실제 Apply의 profile commit 후 application link에 SQL 실패를 주입하고,
  새 service가 같은 요청을 복구할 때 중복 revision이 생기지 않는지 검사한다.
- **결과:** 전체 폐기 PostgreSQL 검사 **62/62 통과**. PG stop/start 합성 checkpoint 및 임시 cluster
  정리도 통과했다. 중간 전체 실행에서는 공유 fixture 인수 변경 때문에 다른 reflection 소비자들이
  실패했으며, 원래 signature를 복원한 최종 실행으로 회귀를 확인했다. 실패 TRX도 보존한다.
  이번에는 제품 저장 로직·SQL migration·운영 DB를 변경하지 않았다.
- **DLL 불일치 해석:** Application.PrivateServer, Domain.PrivateServer, Domain.Profile은 비교한
  metadata table/blob/string heap과 메서드 IL이 같다. Persistence.PostgreSql도 token별 IL,
  metadata table/blob 및 포함 SQL 리소스가 같고, 정규식 생성 타입 이름 4개만 달랐다.
  빌드 MVID/PDB 정보 차이는 확인했지만 기능/ABI 변경 근거는 발견하지 못했다. 이는 byte hash
  동일성이나 전체 실행 호환성 인증이 아니므로 hash 검사를 완화하거나 Epinel DLL을 교체하지 않는다.
- **오프라인 후보:** Admin DLL/PDB/editor JS뿐 아니라 차이가 있는 의존 DLL/PDB도 포함해
  앱 파일 **11개**의 byte-exact 백업과 별도 복사본 복원 hash를 검증했다. 실행 시 읽는 저장소
  스크립트의 과거 일치 복구본은 여전히 미봉인이므로 전체 runtime rollback 완료로 간주하지 않는다.
  후보는 계속 `deploymentAllowed=false`이며 설치본에 쓰지 않았다.

상세 비교·검사 근거는 로컬 `artifacts/stabilization/2026-09-06-save-baseline/`, DB TRX/receipt는
`artifacts/stabilization/lifecycle-postgresql/`, 후보/백업은 `artifacts/stabilization/lifecycle-package/`에 있다.
### S-03 — 실행 입력 snapshot 정비 / 2026-09-06~07

- **재현:** 실제 aggregate Save와 Save As의 child commit 이후 최종 완료 기록 직전에
  SQL barrier를 걸었다. 기존 구현은 아직 pending인 대상 계정도 export했고, 새 회귀 2개가
  기대한 거절 대신 정상 반환하여 실패했다(기존 62개는 통과). 운영 DB에서의 발생 증거는 아니다.
- **변경:** workspace head·profile 값·readiness·lobby를 한 RepeatableRead로 읽고, 실행 API는
  그 묶음 하나만 소비한다. 기존 candidate/lobby 파일 형식은 유지한다. 목록의 readiness도
  표시한 immutable profile revision에 고정하며, 조회 중 큐브나 local state를 생성하지 않는다.
- **다단계 저장 경계:** MVCC만으로 Save의 여러 commit을 하나로 만들 수는 없다. 같은 snapshot에서
  미완료 Save를 확인하면 `account_workspace_save_pending`(HTTP 409)으로 실행/export를 거절한다.
  Save As는 기존 deterministic child operation으로 정확한 복제 대상만 구분하므로 원본·다른 복제본을
  함께 막지 않는다. 이 거절에서는 launch 파일이나 coordinator를 만들지 않으며 편집·복구 조회는 유지한다.
  ledger를 자동 삭제하거나 오래됐다는 이유로 완료로 간주하지 않는다.
- **검증:** Save/Save As의 완료 직전·완료 기록 실패 후 새 service의 거절, exact replay 후 허용,
  no-op revision 유지, 계정 격리, 조회의 무변경성, 읽기 도중 다른 writer가 head를 갱신한 경우를
  폐기 DB로 확인했다. 완료된 읽기 묶음은 이후 Save가 시작되어도 중간에 최신 head를 다시 읽지 않는다.
  격리 수준을 잠시 ReadCommitted로 낮춘 실패 검출 대조에서는 `runtime_projection_snapshot_conflict`로
  새 동시성 검사가 실패했고, RepeatableRead를 복원했다. 실제 OS process 중단이나 실게임 검증은 아니다.
- **최종 회귀선:** 복원한 소스의 단위 **436개**(Admin 74, Automation 41 포함), 전체 폐기 PostgreSQL
  **68/68**, 서식·빌드(경고/오류 0)·저장소·Phase 0/2A1/2A2/2B·3A/3B0/3B1/3B2·Actions 검사가 통과했다.
  이 수치는 소스/합성 검사이며 운영 DB 무결성 확인이나 관리도구 배포 후 인수를 뜻하지 않는다.
- **범위:** 제품의 Save 단계 조정·migration·실행 스크립트·운영 DB·설치 앱·Epinel DLL은 변경하지 않았다.
  source 회귀 결과와 대조 TRX는 로컬 `artifacts/stabilization/2026-09-06-runtime-snapshot/` 및
  `artifacts/stabilization/lifecycle-postgresql/`에 보존한다. 이전 오프라인 package는 이번 S-03 변경을
  포함하지 않으므로 새 배포 후보로 재사용하지 않는다.

### S-07 — workspace Save 단계 조정 / 2026-09-07

- **기준선:** S-03 이후 저장소·서식·빌드·단위·폐기 DB 검사를 먼저 통과했다. 수정 전 추가한
  단계별 복구 10개는 통과했지만 다음 두 결함은 Save/Save As 각각에서 재현됐다(14개 중 4개 실패).
  claim만 남은 재시도가 잘못된 expected lobby revision을 수락했고, 완료 직전 중단된 저장의
  대상에 다른 operation이 정상 저장됐다. 이는 합성 DB 재현이며 운영 DB를 조사한 결과는 아니다.
- **분리:** `AccountWorkspaceSaveCoordinator`는 순서·복구 분기를, `WorkspaceSaveStages`는
  기존 profile/lobby/wallet/label writer 연결을, Save store는 잠금·claim·checkpoint·완료를 맡는다.
  거대 service의 aggregate Save 본문을 이동·분리했으며 개별 writer 구현이나 wire 계약을 바꾸지 않았다.
- **보강:** 계정별 DB advisory transaction lock으로 workspace Save 호출끼리 조정한다.
  진행 중에는 같은 요청도 `account_workspace_save_in_progress`(409)이며, 종료 후 같은 UID/내용으로
  exact replay한다. 별도 pending이 남은 계정과 정확한 Save As child에는 새 operation을 허용하지 않는다.
  다른 계정은 계속 저장할 수 있다. 취소·예외 후 잠금을 반납하고 pending은 보존한다.
- **사전 검사:** 신규 요청은 검사 통과 후에만 claim을 만든다. 기존 claim은 profile child commit
  증거가 없으면 다시 검사한다. commit이 있으면 원래 child receipt/replay 경로로 복구한다.
  child UID/hash, CAS, immutable revision, no-op, observation 고정 출처를 유지한다. migration 변경은 없다.
- **검증 범위:** Save의 profile·lobby resolution·lobby·wallet·label·completion,
  Save As의 profile·initialize·provenance·completion 경계에 SQL 예외를 주입한 뒤 새 service로 복구한다.
  별도 연결 풀의 중복/경합, 취소, 다른 계정 독립 저장, revision 수·receipt 불변성,
  새 stale 요청의 무기록 거절, 복구 사이 source 재fetch 시 copy provenance 유지도 검사한다.
- **최종 회귀:** 집중 검사 **23/23**, 단위 **436개**, 전체 폐기 PostgreSQL **89/89** 통과.
  S-07 합성 DB 회귀 21개를 추가했다. 서식·빌드(경고/오류 0)·저장소·Phase 0/2A1/2A2/2B·
  3A/3B0/3B1/3B2·Actions 계약 검사도 통과했다. 근거는 로컬
  `artifacts/stabilization/2026-09-07-workspace-save/`와 `artifacts/stabilization/lifecycle-postgresql/`에 보존한다.
  첫 확장 검사에서는 새 provenance fixture의 필수 진행도 누락으로 1개가 실패했으며,
  제품 완전성 검사를 유지하고 합성 자료만 보완한 후 전체 검사를 다시 통과했다.
- **기존 pending 정책:** 원래 operation UID와 요청 내용이 있어야 복구 가능하다. hash만으로 잃어버린
  요청 payload를 재구성하거나, superseded 작업을 임의 최신 revision으로 이어붙이지 않는다.
  조정기 분리 당시 editor는 재시도 때 preview부터 호출하므로 profile child commit 뒤에는 그 단계에서
  revision conflict가 날 수 있다. **이번 복구 검증은 원래 요청을 그대로 재전송하는 backend API 기준**이다.
  요청을 잃은 경우의 durable recovery envelope와 preview 없는 UI 재시도는 아래 후속 작업으로 분리했다. 기존 pending 삭제나
  운영 DB 자동 수선은 하지 않았다. 세부 경계는 [workspace 계약](features/PHASE_B_ACCOUNT_WORKSPACE.md)에 있다.
- **한계:** 개별 profile/lobby/wallet API·import·직접 SQL을 전부 감싼 전역 writer lock은 아니다.
  실제 OS process 강제 종료 실험·운영 DB 검사·설치본 배포·실게임 인수도 수행하지 않는다.

### S-07 후속 — UI exact 재시도·요청 영속 보존 / 2026-09-07

- **기준선:** 단위 436개, 폐기 PostgreSQL 89/89 통과. 실제 editor.js를 실행하는 합성 DOM/transport로
  Save·Save As의 응답 유실을 재현했다. 변경 전 두 경우 모두 재시도 preview에서 revision conflict로 실패했다.
- **UI:** 첫 요청 body/operation UID/If-Match를 계정별로 보존하고 같은 창에서는 그대로 재전송한다.
  재시도 때 preview·입력 수집·이름 요청을 반복하지 않는다. 처리 중 중복 클릭/편집을 막으며,
  새 창은 pending·최근 완료 receipt를 조회한 뒤 사용자 버튼으로만 이어 저장한다. 원문은 브라우저에 반환하지 않는다.
- **DB/API:** V0018은 신규 claim과 같은 transaction에 canonical 요청 원문을 추가한다.
  FK·checksum·immutable trigger·원래 요청 hash 대조로 묶으며 기존 migration/revision/child writer는 유지한다.
  복구 POST는 source/operation UID와 request hash만 받아 저장 원문으로 기존 조정기를 호출한다.
  admin session/Origin/CSRF/strict JSON 경계, CAS와 Save As의 고정 provenance를 유지한다.
- **구형/비정상 상태:** 원문 없는 pending을 backfill·삭제하지 않고 `original_request_required`로 안내한다.
  손상 원문은 `request_invalid`로 막는다. 최신 revision으로 이어붙이거나 형제 계정의 작업을 대신 복구하지 않는다.
- **검증:** 신규 단위/API 17개, editor 행동 10개, 폐기 PostgreSQL 16개를 추가했다.
  기존 단계별 중단을 새 service/연결 풀에서 UID/hash만으로 복구하고, 원문 삽입 실패의 claim rollback,
  Save As 계정 격리, 중복·변조 거절, V0017→V0018 재적용과 구형 pending 보존을 검사한다.
  최종 **단위 453개·editor 행동 10개·전체 폐기 PostgreSQL 105/105** 통과. 서식·빌드(경고/오류 0),
  저장소·Phase 0/2A1/2A2/2B·3A/3B0/3B1/3B2·Actions 계약도 통과했다.
  로컬 근거는 `artifacts/stabilization/2026-09-07-workspace-retry/verification.json`이다.
- **검사 중 발견:** 첫 전체 DB 검사는 104/105였다. 기존 스키마 검사의 정확한 허용 목록에
  V0018의 local source UUID·canonical 요청 byte·checksum 3개를 명시하고, 다른 테이블의 같은 필드와
  새 테이블의 인증 필드는 계속 거절하도록 부정 테스트를 확장했다. 두 전체 실행은 테스트용 PG의
  첫 종료가 30초를 초과해 재시작 gate에서 실패했고, 후속 정리는 성공했다. 실패 receipt를 보존했다.
  테스트 runner에만 상한 60초의 명시적 대기 옵션을 추가했다(기본 30초 유지). 최종 전체 검사는
  `scripts/test-nll-lifecycle-postgresql.ps1 -ShutdownTimeoutSeconds 60`으로 정상 종료·재시작·
  체크포인트 42 보존·임시 cluster 정리까지 통과했다. 운영 실행기의 기한 변경이나 종료 지연 원인 규명은 아니다.
- **한계:** 합성 editor DOM/transport와 DB 검사는 설치된 WebView2나 실제 OS process 강제 종료 검증이 아니다.
  운영 DB 조회·migration·설치본 배포·실게임은 하지 않는다. 기존 원문 없는 pending의 자동 수선을 주장하지 않는다.

### S-07 배포 준비 — 운영 DB cold 백업·후보 대조 / 2026-09-07

- **운영 상태 확인:** 운영 PostgreSQL을 시작하지 않고 종료된 data tree를 D:의 새 private 백업
  디렉터리로 복사했다. 원본/백업 2,196파일·89,700,884 bytes의 SHA-256을 대조했다.
  별도 복원 복제본만 `127.0.0.1:55434`에서 기동해 read-only transaction으로 확인한 결과,
  스키마는 **17**, 기존 migration 17개의 checksum은 현행 소스와 모두 일치했다.
  workspace operation 78건 중 **구형 pending Save 3건**, pending Save As 0건이다.
  원본 DB migration·SQL write·pending 삭제는 하지 않았다. 복제본 종료 후 해당 임시 복제본만
  제거했고 원본/백업 파일 hash를 다시 대조했다. 실제 백업은 Git 밖에 보존한다.
- **복구 경계:** 이 3건은 V0018 전 operation이므로 새 요청 원문이 자동 생성되지 않는다.
  원래 operation UID·요청 원문과 hash가 일치하는지 별도 읽기 전용 조사한 뒤 처리한다.
  원문을 확보하지 못하면 `original_request_required`를 유지한다. latest head로 재작성하거나
  pending을 지워 새 Save를 강제로 통과시키지 않는다. 아직 세 계정의 문제라고 추정하지 않는다.
- **앱 후보:** `prepare-nll-workspace-offline-package.ps1`은 신규 ignored staging에만 publish한다.
  DLL뿐 아니라 HTML/CSS/JS와 publish 파일 전체를 대조해 추가·교체·동일을 구분하고,
  설치본에만 있는 로컬 이미지 등은 삭제하지 않는다. desktop 직접 실행에서 쓰지 않는
  IIS `web.config`의 주석 차이는 교체에서 제외한다. 변경 파일의 byte-exact before image와
  복원 리허설, 실행 때 저장소에서 읽는 스크립트·config·Import CLI의 exact baseline을 함께 봉인한다.
  데스크톱 shell, 게임/Epinel DLL, materializer와 client resource는 교체 대상이 아니다.
- **백업 도구:** `prepare-nll-workspace-cold-backup.ps1`은 고정 운영 data 경로를 읽고 새 D: 경로에만
  쓴다. reparse·운영 process/listener·postmaster marker·비정상 종료·PG pin 불일치는 거절한다.
  복제본은 독립 config와 loopback/scram 인증, read-only query를 사용하며 DPAPI 비밀번호를
  child 환경에만 전달한다. DB byte·경로별 private manifest·암호화된 secret은 Git 밖에만 둔다.
  첫 실행은 조회/정리 후 receipt 합계 계산에서 PowerShell 오류가 나 완료 봉인을 실패했다.
  집계 코드를 수정한 새 실행은 백업·복원 조회·정리·receipt까지 통과했다. 제품 저장 오류가 아니다.
  성공 근거: `artifacts/stabilization/workspace-backup/3bbbca7baf1443fc819f462fb73f8473/receipt.json`.
- **검증 경계:** 준비 전 전체 단위 453개·editor 행동 10개·폐기 PostgreSQL 105/105 및 기존 계약 검사를
  통과했다. 새 파일 포장 합성 검사 8개는 HTML/CSS/JS 포함, 추가/교체/동일, 설치 전용 파일 보존,
  hash drift·기존 목적지 덮어쓰기·junction 거절과 빈 디렉터리 복원을 검사한다.
  준비 후에도 **453·10·105/105·포장 8개**, 서식/빌드(경고·오류 0), 저장소·Phase 0/2A1/2A2/2B·
  3A/3B0/3B1/3B2·Actions 검사를 통과했다. 마지막 PG는 정상 종료·재시작·체크포인트·정리까지 통과했다.
  최종 후보 `a4de964010d5438aa7d409fc73c0ee82`는 publish 40파일 중 교체 후보 15개·추가 0개이며,
  저장소 script 361파일과 Import CLI 45파일의 현재 byte를 함께 고정했다. 이는 현행 측정 baseline이지
  해당 앱/스크립트 조합의 실게임 인수 증거는 아니다. 최종 빌드/후보/원본 DB/백업/설치본 해시 대조는
  `artifacts/stabilization/2026-09-07-workspace-deployment/verification.json`에 봉인했다.
  새 후보는 배포 허가가 아니며, 설치 후 인수와 구형 pending 3건의 원문 검토는 남아 있다.

#### 실제 적용 순서 — 2026-09-07 승인·수행

1. 구형 pending 3건은 아래의 **운영자 승인 1회성 정리**로 처리했다. 다음 배포 기준선은 정리 후
   DB(스키마 17·workspace operation 75건·pending 0건)이다. 예전 78건 snapshot을 현재 상태로
   취급하지 않는다. 조회 자체가 이어 저장하거나 계정 revision을 변경해서는 안 된다.
2. 승인 시점에 관리도구·watcher·게임·PG cold 상태, 운영 DB와 선택 pointer, 설치 앱·저장소 입력의
   현재 hash를 재검사한다. 이번 snapshot 이후 정상 저장이 있었다면 **새 백업/후보를 생성**한다.
3. 새 앱의 첫 시작이 V0018 migration을 실행한다는 점을 명시적으로 승인받는다. V0001~V0017은
   수정하지 않으며 배포 중에는 writer를 차단한다. 후보 manifest의 추가/교체 파일만 적용하고
   설치 전용 파일과 원본 client를 보존한다. 사후 hash 검사가 끝나기 전에는 앱을 열지 않는다.
4. 게임 없이 관리도구 smoke로 스키마 18, 기존 row/revision 보존, Save/Save As·exact replay,
   구형 pending 안내, 새 창의 신규 pending 복구·완료 receipt 조회를 검증한다.
   합성 DOM/DB green은 설치 WebView2의 실제 버튼 동작 확인을 대체하지 않는다.
5. 실패 시 writer와 process를 모두 종료하고 실패 시점 DB를 별도 보존한다. 원래 data를 검증된
   명시 경로로 격리한 뒤 **전체 cold 백업을 새 data 디렉터리에 복원**하고 byte hash를 대조한다.
   이번 배포로 변경한 앱/저장소 입력만 exact before image로 복구한다. 다른 사용자 변경이 있으면
   덮어쓰지 않고 중단한다. 스키마 17과 복구된 앱의 조회를 확인한 뒤에만 재시작한다.
   `DROP TABLE`이나 migration history 삭제로 downgrade하지 않으며, 구형 앱만 되돌리지 않는다.

### S-07 구형 pending 요청 조사 — 읽기 전용 / 2026-09-07

- **범위:** 앞서 봉인한 cold 백업에서 새 임시 복제본만 기동했다. 운영 DB는 기동하지 않았으며,
  조회는 `127.0.0.1:55434`의 read-only transaction으로 수행했다. 조회 후 임시 복제본을 종료·제거하고
  운영 data와 보존 백업의 파일 SHA-256 일치를 다시 확인했다. migration·요청 재실행·pending 삭제·
  앱 배포는 하지 않았다. private UUID·요청 hash·상세 조회 결과는 D:의 private 조사 폴더에만 보관한다.
- **확인된 상태:** 3건은 서로 다른 세 계정이 아니라 **같은 계정의 과거 Save 3건**이다.
  root operation에서 결정적으로 파생되는 child UID를 대조했다. 세 건 모두 프로필 적용 intent와
  candidate/diff 참조는 있지만, 프로필 write receipt·application 완료 연결·로비 write receipt·
  wallet write receipt·resolved lobby checkpoint는 없다. 즉, 변경안/검토 이력은 남았으나
  해당 Save의 프로필 반영이 커밋되기 전에 중단됐다. 최초 오류의 예외 메시지까지 확인한 것은 아니다.

| 익명 조사 건 | 프로필 / 로비 / 재화 커밋 | 이후 같은 계정의 완료된 workspace Save | 이후 별도 profile write |
|---|---|---:|---:|
| 1 | 모두 없음 | 75 | 77 |
| 2 | 모두 없음 | 53 | 54 |
| 3 | 모두 없음 | 52 | 53 |

- **원문 검색:** 로컬 artifacts, 설치 관리도구 logs/state, 관련 Legacy/Phase3b2 백업의 텍스트
  46,739파일을 root/child operation UID·root 요청 hash·연결된 candidate/diff UID/hash로 검색했다.
  일치 파일은 0개이며 64 MiB 초과로 제외된 파일도 0개다. 공식 client 리소스·바이너리 덤프·
  브라우저 메모리·대화 저장소는 조사하지 않았다. 따라서 **확인한 저장 위치에서 원문 미발견**이지,
  어디에도 원문이 존재하지 않는다고 단정한 것은 아니다. 첫 검색은 시간 제한으로 중단됐고,
  재검색 완료 결과만 근거로 삼았다.
- **복원 한계:** 구형 설치 UI는 요청 fingerprint/operation UID를 창의 메모리에만 보관했다.
  스키마 17의 root row에는 전체 요청 payload가 없다. candidate/diff는 프로필 변경안일 뿐,
  원래 계정 이름·로비 선택·재화 값·expected revision/If-Match 전체를 입증하지 못한다.
  현재 계정 값을 끼워 넣거나 과거 hash를 역으로 추정해 exact request라고 취급하지 않는다.
  이후 정상 저장이 진행됐으므로 과거 요청을 단순 재실행해 현재 계정을 덮어쓰는 것도 금지한다.
- **배포 영향:** 새 coordinator의 pending 보호와 실행 입력 snapshot의 pending 검사는 이 계정의
  신규 Save/Save As와 실행 준비를 거절한다. V0018은 원문 없는 legacy row의 payload를 만들어 주지
  않으므로 migration만으로 해결되지 않는다. 현재 설치본은 교체하지 않았으며 이 차단은 후보 코드의
  배포 시 영향이다. `pending → completed`로 위장하면 성공 receipt의 의미를 훼손하므로 사용하지 않는다.
- **당시 검토안과 후속 결정:** 별도 종료 상태·감사 테이블을 추가하는 범용 절차를 검토했으나,
  운영자는 이 3건의 복원은 불필요하다고 확인한 뒤 아래의 최소 1회성 정리를 승인했다.
  따라서 범용 종료 API/UI나 추가 migration은 구현하지 않는다. 아래 exact 대상 정리가
  이 검토안을 대체하며, 다른 pending을 자동 삭제하거나 이미 반영된 저장을 버리는 권한은 아니다.
- **근거:** `artifacts/stabilization/2026-09-07-legacy-pending/ac4edfce61674977ac827903e3e34208.json`
  및 같은 폴더의 `search.json`. 원래 요청을 확보한 건이나 자동 복구를 완료한 건은 0건이다.
- **회귀 검사:** 조사 전후 단위 453개·editor 행동 10개·폐기 PostgreSQL 105/105와 기존 저장소·
  Phase 0/2A1/2A2/2B·3A/3B0/3B1/3B2·Actions 검사를 통과했다. PG 종료·재시작·체크포인트 보존·
  정리도 통과했다. 제품 소스·설치본·운영 DB·백업·암호화 secret·선택 pointer의 불변 대조와 검사
  근거는 같은 조사 폴더의 `verification.json`에 봉인한다. 실게임은 실행하지 않았다.

### S-07 운영자 승인 1회성 pending 정리 / 2026-09-07

- **승인·범위:** 운영자가 `미완료 save 건은 살릴 필요 없어`라고 확인하고, 백업 보존·미반영 재확인·
  해당 pending만 정리·회귀 검증하는 최소안을 승인했다. 이미 조사한 동일 계정의 Save 3건만
  대상으로 했으며 제품 코드·영구 관리 기능·migration·설치 앱·실게임은 변경/실행하지 않았다.
- **적용:** 계정·operation UID·요청 SHA-256과 pending 집합을 exact 대조했다. PostgreSQL
  serializable transaction 및 업무 테이블 쓰기 잠금 아래 profile write/application·lobby/wallet
  child 미커밋을 재검사하고 **`account_workspace_save_operation`의 3행만 삭제**했다.
  모든 업무 테이블 132개를 row 내용의 SHA-256과 count로 대조하고, 시퀀스도 대조해 대상 외
  변화가 없을 때만 commit했다. candidate/diff/intent, 정상 Save 75건, current revision,
  계정 값·정상 기록은 유지했다. 성공 receipt로 위장하거나 과거 요청을 재실행하지 않았다.
- **복제본 검증:** 정리 전 실제 pending이 실행 입력 조회를 차단하는 것을 재현했다. 잘못된
  계정·hash 및 profile/lobby/wallet 반영 이력이 존재하는 5가지 부정 조건은 모두 거절했다.
  부정 검사는 rollback하고 row/시퀀스 불변을 확인했다. 복제본 정리 후에만 V0018을 적용하여
  새 무변경 Save·Save As·각 exact replay, Save As source 불변, source/복제 계정의 runtime
  snapshot 조회와 신규 pending 부재를 검증했다. 운영 DB에는 이 기능 검사의 저장이나 V0018을
  적용하지 않았다. 이는 백엔드 서비스 검증이며 설치 WebView2·실게임 버튼 검증을 뜻하지 않는다.
- **운영 결과:** 복제본에서 검증한 동일 helper/script hash로 적용했다. workspace operation은
  **78 → 75, pending은 3 → 0**, 스키마는 **17 유지**다. 삭제 전후 모든 다른 row와 시퀀스는
  동일하고, DB는 정상 종료했다. 임시 maintenance 기동 옵션은 원래 byte로 복원했다.
- **복원 가능성·현재 백업:** 기존 D: cold 백업 `workspace-pre-v18-3bbbca7baf1443fc819f462fb73f8473`
  은 그대로 보존했다. 그 아래 `cleanup-0327114a388043dc8e6e0308fd5ac5e3`에 삭제한 3행의 private
  사본, 전후 table fingerprint, `post-cleanup-cold-data`와 exact private manifest를 보관했다.
  정리 후 복사본이 다음 배포의 DB 기준선이다. 예전 백업 복원은 폐기한 3건도 다시 가져오므로
  자동 rollback 대상으로 혼용하지 않는다. 복제본 시험에 쓴 disposable data만 제거했다.
- **근거:** `artifacts/stabilization/2026-09-07-legacy-cleanup/`의 rehearsal
  `bd272b608aac472590fa1b4575f911e8.json`, 운영 적용 `0327114a388043dc8e6e0308fd5ac5e3.json`.
  helper와 시험 소스는 일회성 ignored artifact이며 자동 실행 경로에 연결하지 않았다.
- **최종 검증:** 정리 전후 단위 453개·editor 행동 10개·폐기 PostgreSQL 105/105 및 기존 저장소·
  Phase 0/2A1/2A2/2B·3A/3B0/3B1/3B2·Actions 검사를 통과했다. PG 정상 종료·재시작·체크포인트
  보존·정리도 통과했다. 제품 소스/실행 스크립트·설치 앱·암호화 secret·선택 pointer가 그대로이고,
  정리 후 cold 백업이 현재 운영 DB와 byte-exact임을 같은 폴더의 `verification.json`에 봉인한다.

**후속:** 정리 후 DB 백업과 기존 앱 후보를 재검사한 뒤 아래 별도 승인 배포를 진행했다.
위의 스키마 17·설치본 미변경은 정리 단계 종료 시점의 기록이다.

### S-03/S-07 설치 적용·관리도구 검증 / 2026-09-07

- **승인·범위:** 운영자의 다음 작업 착수 승인으로 준비된 package
  `a4de964010d5438aa7d409fc73c0ee82`의 앱 파일 **15개만 교체**했다. 추가 파일은 없으며
  설치 전용 asset과 `web.config`를 보존했다. 제품 소스·실행 스크립트·공식 설치본·151 client·
  Epinel DLL·runtime 선택·암호화 secret은 변경하지 않았다. 게임은 실행하지 않았다.
- **DB:** 정리 후 스키마 17 백업과 운영 cold tree의 byte 일치를 재확인했다. 새 앱 시작으로
  V0018을 적용해 스키마 **18**, 정상 Save **75건**, pending **0건**, 새 요청 원문 **0행**이다.
  기존 132개 테이블의 행 지문과 시퀀스를 비교해 migration 이력 외 값이 동일함을 확인했다.
  검사 세션의 시간대 차이는 UTC로 통일했다. 이는 데이터 보존 검사이며 전체 도메인 무결성 검사의 완료는 아니다.
- **격리 저장 검사:** 실제 package DLL/editor를 쓰는 별도 DB·HTTP 호스트와 Edge에서 Save·Save As를
  클릭했다. 응답만 유실시킨 Save의 body/UID/If-Match 동일 재전송, preview 재생성 없음,
  완료 receipt 단일성, Save As 원본 revision 보존을 확인했다. 복제본에만 완료 기록 실패 trigger를
  걸어 신규 pending을 만들고 제거한 뒤, 서버 process와 브라우저 창을 재시작했다. 원래 요청을
  이어 저장하여 완료했고 편집 차단도 해제됐다. 페이지 오류는 0건이다.
- **설치 화면 검사:** 실제 설치 WebView2를 Windows 접근성 API로 조회했다. 계정 2개, 콘솔 9종,
  큐브 17종, 니케 199종, 레이드 화면과 Save/Save As 활성화, pending 복구 버튼 부재를 확인했다.
  운영 화면에서 Save나 게임 시작은 누르지 않았다. 정상 창 닫기로 Admin·PG가 종료됐고 검사 포트도
  남지 않았다. 임시 CDP 연결은 성립하지 않아 UIA로 검증했으며 제품 코드는 바꾸지 않았다.
- **검증 경계:** 설치 WebView2에서의 쓰기 인수는 이번 조회 smoke에 포함되지 않는다.
  저장·복구 쓰기는 운영 계정 오염을 피하기 위해 격리 DB의 실제 editor/HTTP로만 수행했다.
  원문 없는 구형 pending 안내·변조 거절은 기존 회귀 검사 범위이며 운영에서 재생성하지 않았다.
- **백업·근거:** 배포 ID는 `bbdae48e596f48adb50ab16a42445a5b`다. 정리 전 백업 root 아래
  `install-<배포 ID>/post-v18-cold-data`와 `post-v18.manifest.private.json`을 추가했다.
  배포 직전 복원은 앞 절의 **post-cleanup-cold-data(스키마 17·pending 0)**와 앱 before image를
  함께 사용한다. 기존 backup을 덮어쓰거나 migration table을 삭제하지 않는다.
  source-free 인수 결과는 로컬 `artifacts/stabilization/2026-09-07-workspace-install/acceptance.json`,
  계정 값이 포함된 지문·시험 기록은 D:의 비공개 배포 폴더에만 있다.
- **회귀:** 설치 전후 각각 단위 **453개**, editor **10개**, 폐기 PostgreSQL **105/105** 및
  저장소·Phase 0/2A1/2A2/2B·3A/3B0/3B1/3B2·Actions 계약 gate를 통과했다. PG 정상 종료·
  재시작·체크포인트 42 보존·시험 cluster 정리도 통과했다. 최종 PG receipt ID는
  `b174604179de4eab9b38ff188b591efc`이며 같은 배포 폴더의 source-free `verification.json`에 봉인한다.
### 종료 후 ‘게임 실행 중’ 고착 재발 경로 보강 / 2026-09-07

- **사건과 한계:** 종료 watcher 인계 전 실패 뒤 `started`/`phase_d_emergency_rollback_failed`,
  잔류 Epinel 서버와 중지된 관리 DB가 남았다. 해당 실행은 별도 백업 후 기존 복구 절차로
  정리했다. 당시 최초 예외는 cleanup 실패로 가려져 있어 정확한 native 오류까지 확정하지 않는다.
- **프로세스 접근:** capture/wait에 `PROCESS_ALL_ACCESS`를 요구하던 `.Handle` 접근을 제거하고,
  조회·대기 권한만 가진 Windows handle을 유지한다. 명시적 종료에서만 종료 권한을 추가하며,
  PID·시작 시각·경로를 검증한 동일 handle을 사용한다. 게임 memory/주입/패치 기능은 없다.
- **부분 인계와 복구:** server → bootstrap → client 순으로 identity를 각각 영속화한다.
  client capture 실패가 이미 확인한 server 신원을 지우지 않는다. 실제 client/launcher/bootstrap과
  coordinator/watcher 소유자가 없을 때만 잔류 서버 복구에 진입한다. active pointer·시작 receipt
  hash·실행 경로·PID·시각이 일치하는 단일 서버만 종료한다. PID 재사용·다른 서버·증거 누락은 거절한다.
  새 실행의 전체 runtime-cold 조건은 완화하지 않았다.
- **복구 후 상태:** pending 유무와 별개로 rollback이 입증되면 관리 DB를 다시 준비한다.
  최초 실패 단계·역할·controlled code·native error를 별도 파일에 보존하고 cleanup 오류로 덮지 않는다.
  raw 예외 메시지/stack/인수는 기록하지 않는다. active 실패는 UI에서 ‘실행 상태 확인 필요’로
  표시하되, 복구 증명 전 새 실행 차단과 폴링은 유지한다.
- **소스 검증:** 단위 459개(Admin 97·Automation 41 포함), 저장 UI 12개, lifecycle UI 행동 검사,
  변경 C# 서식 검사와 저장소·Phase 0/2A1/2A2/2B·3A/3B0/3B1/3B2·Actions 계약 검사를 통과했다.
  WinPS 5에서 실제 테스트 프로세스의 제한 권한 조회·종료 대기·정확한 자식 종료도 통과했다.
  실제 coordinator/watcher 실패 블록, 부분 identity 보존, 잔류 서버 오인 종료 거절,
  DB 준비의 no-pending/pending/already-ready/start-failure 경로는 합성 검사다.
- **배포·추가 인수:** 후보는 설치본 대비 Admin DLL/PDB/editor JS 3개만 다르고 의존 DLL은 같다.
  로컬 `artifacts/stabilization/2026-09-07-lifecycle-recurrence/`에 후보·hash·검증 자료를 둔다.
  설치된 351개 파일 중 위 3개만 교체하고 나머지 파일 hash 보존을 확인했다. 적용 전 앱 파일과
  적용 후 공유 소스는 `D:\NikkeLocalLab\Backups\lifecycle-recurrence-20260907-<배포 UID>`에 보존한다.
  앱 before만 복원하면서 변경 후 저장소 스크립트를 남기는 것을 전체 rollback으로 간주하지 않는다.
  정확한 백업 위치는 같은 artifact 폴더의 `installed.json`을 따른다.
  첫 폐기 PG 실행은 105개 테스트가 통과했지만 종료 30초 제한을 넘겨 restart gate가 실패했고
  임시 DB 정리를 확인했다. 기존 60초 옵션의 재검증에서 **105/105**, stop/start checkpoint 보존,
  process/listener/임시 cluster 정리가 모두 통과했다(receipt `2c20c3d9720c495da5628fe8d6d312d9`).
  게임·Epinel DLL·계정 저장 로직·schema migration·Solo Raid 참가 null 예외는 이번 수정 범위가 아니다.
  실게임 로비 전 종료/정상 종료 후 재실행과 저장 가능 상태 복귀는 운영자 인수로 남긴다.

### 종료 완료의 진단 의존·중복 복구 오류 보강 / 2026-09-07~08

- **확인한 원인:** 현재 151 runtime은 app log가 없는데, v9 완료 template는 기존 marker가
  반드시 있어야 한다고 요구했다. 따라서 `startup_only/client_exit`도 DB/hosts 복원 전에
  실패했다. 별도로 실제 Windows 테스트 자식의 종료 handle을 보유한 채 stop을 재호출하면
  image path 조회 불가를 신원 불일치로 처리하는 문제를 재현했다. 이 별도 재현을 과거
  secondary rollback 예외의 정확한 원인이라고 소급 확정하지 않는다.
- **변경 경계:** 고정 원본 template는 그대로 두고, 이미 hash를 검증하는 파생 단계에서만
  진단 부재를 `not_observed`로 명시한다. 관측 배열은 비어 있고 classification/score/regroup/
  damage 검증을 성공으로 승격하지 않는다. 기존 marker의 다른 실행·잘못된 contract·raw
  payload 선언·손상은 계속 거절한다. 명시적 `success/battle_result` 관측 요구도 유지한다.
  runtime stop → pending capture → DB/hosts/firewall 복원 → 관리 DB 기동 → exact persistence
  → terminal state → pending 삭제 순서는 유지한다. 진단 로그를 새로 활성화하지 않는다.
- **중복 복구:** 동일 열린 handle의 시작 시각부터 확인한 후 이미 종료됐다면 경로 조회 없이
  dispose/no-op 처리한다. 경로 조회 중 종료되는 race도 처리하고, live query 예외는 native
  code를 보존한다. PID 재사용·live 경로 불일치·접근 거절과 전체 identity 선검증은 유지한다.
- **오류 보존:** coordinator/watcher의 최초 오류와 rollback/hosts_restore/database_restart
  각 단계 최초 오류를 별도로 보존한다. 재시도는 기존 기록을 덮지 않으며 raw message,
  stack, 계정 값은 남기지 않는다. 실제 복구 미입증/DB 기동 실패/persistence 실패는 계속
  `started`와 pending을 보존하여 새 실행을 차단한다.
- **검증 근거:** 수정 전 단위 418개·저장 UI 12개·전체 계약 gate가 통과했다. 수정 전 실제
  테스트 자식의 두 번째 stop 실패와 수정 후 두 번의 no-op을 확인했다. source-free 및 실제
  고정 template 각각 9개 진단/cleanup 사례, template 변조·재적용·개행 차이, 종료 race 7개,
  실제 watcher의 조기/정상 종료·DB 실패·persistence 실패 순서를 합성 검사한다. 폐기 PG
  105/105와 restart checkpoint 42 보존·정리 완료 receipt는
  `artifacts/stabilization/lifecycle-postgresql/0287e3fc7519417b88f388cd6fb71dcc/receipt.json`이다.
  최종 단위·UI·계약 결과는 아래 로컬 근거의 `final.log`/`verification.json`을 기준으로 한다.
- **적용·인수:** 설치 Start가 이 저장소를 `--repository-root`로 넘기므로 후속 실행부터
  수정된 script를 직접 사용한다. 앱 DLL·JoinData v5 서버·게임 DLL·bundle 선택·운영 DB·
  고정 원본 완료 script는 변경하지 않았다. 이전 shared script 3개와 관련 test의 before image는
  `artifacts/stabilization/2026-09-07-completion-recovery/before/`, 새 helper·검사 hash와 세부 결과는
  같은 폴더의 `verification.json`/`RESULT.md`에 보존한다. 기존 active run의 파생 script를
  뒤늦게 바꿔 끼우지 않는다. 실게임 종료 후 상태 해제·저장·재실행은 운영자 인수로 남긴다.

S-04~S-06 준비 계약 및 P-01~P-09 영속화는 계속 별도 작은 작업이다.

1. **검증 기준선 복구 — 단위 검사와 폐기 DB 62개 통과.** 서식은 별도 작은 변경으로
   정리했다. format/build/unit/integration/local-runtime 결과를 구분하고 남은 검토 목록을 유지한다.
2. **행동 회귀 테스트 선행.** 아래 행렬을 가짜 process/clock 및 폐기 DB로 자동화한다.
   기존 실제 게임 성공은 인수 기준으로 유지하며 매번 사용자가 장시간 재현하게 만들지 않는다.
3. **실행 생명주기 정리.** 조회와 복구 분리, 한 상태 변경 주체, process identity,
   단계별 기한, active/history 분리를 한 수직 경로씩 적용한다.
4. **실행 준비·버전 계약 정리.** immutable input snapshot, 단일 bundle/variant 준비 결과,
   문자열 patch 대신 명시적 runner 입력. 현 151 결과와 비교 후 전환한다.
5. **Save/DB 경계 정리.** 조정 상태와 저장/매핑 분리, 동시성·중단 지점 검증. 기존 record와
   revision은 그대로 두고 필요한 schema 변경은 additive migration만 사용한다.
   P-01~P-09의 저장 의미·출처·조회 경계를 먼저 명세하고 각 항목을 별도 작은 변경으로 검증한다.
6. **측정 기반 최적화·문서 재배치.** SQL/파일 I/O 측정 후 batch/cache를 적용한다.
   문서와 스크립트 참조 검사를 통과한 항목만 archive하며, 150 이동은 의존성 제거 뒤 별도 진행한다.

각 변경은 `현재 동작 재현 → 테스트 → 작은 변경 → 회귀 → 필요한 경우 실게임 확인`
순서로 닫는다. 실패 시 바로 이전 검증된 artifact로 돌아갈 수 있어야 한다.
단계 1~6은 계획이며 이번 점검으로 구현 완료되지 않았다.

### 우선 고정할 회귀 행렬

| 영역 | 필수 경우 |
|---|---|
| 실행 | 정상 시작/종료, 로비 전 종료, 시작 요청 중복, HTTP 연결 종료, 자식 기동 실패 |
| 복구 | watcher 지연/종료, receipt 쓰기 직후 중단, PG 재시작 실패, 재복구 exact replay |
| 상태 | 정상 실행 폴링, 종료 후 복구 중 폴링, 손상 과거 파일, PID 재사용, 이력 증가 |
| 계정 | Save 무변경/수정/중복, Save As, 각 child 직후 중단, 동시 Save/Launch |
| 점수 | `0 → 400 → 300 → 500`에서 최고점 `0 → 400 → 400 → 500`, Quit, 재기동, 05:00 |
| My Records | P-01의 4run/16건, 낮은 완주·Quit 뒤 보존, 최신순·중복 방지, 실전/모의전 분리 |
| 접속 간 상태 | 해금 알림 확인, 착용 스킨, 01~05 편성·슬롯·빈 팀, 계정 격리, Save 충돌 |
| 사용자 선택 | 로비 캐릭터/배경, 로비·지휘관실 BGM 구분, 프로필 꾸미기, 삭제 배지 미재등장·새 배지 유지 |
| 약점별 기록 | 철갑 150 / 수냉 미기록→100 / 철갑 150 복원, 합딜·My Records·진행 상태 일치 |
| 변환 | T10 기업 없음, T9 기업 판정, OL effect 참조, 큐브 계정 레벨, 진행도 유지 |
| 버전/보스 | S26 151 현행 조합, 불일치의 명확한 사전 표시, 잘못된 hash/schema, 150 기록 계승 |

## 문서 정리 — 2026-09-06

- [문서 색인](README.md)을 입구로 두고 최상단 문서를 50개에서 10개로 줄였다.
- 상세 계약 20개는 `contracts/`, 기능 참고 5개는 `features/`, 운영 절차 4개는 `operations/`로 분류했다.
- 과거·보류 계획과 기존 장문 안내 16개는 `archive/`에 보존했다. 영구 삭제하지 않았다.
- 프로젝트 README, HANDOFF, NEXT_STEPS, ARCHITECTURE는 현행 요약으로 정리했다.
  원래 내용은 보관본에 남겼으며, 현재 작업 목록은 이 계획에만 유지한다.
- AGENTS 필수 읽기 대상과 불변 규칙은 유지하고 이동 경로만 반영했다.
  검사·봉인 스크립트 5개도 문서 경로 참조만 갱신했다. 실행 로직·DB·설치본은 변경하지 않았다.
- 과거 migration·Golden/rollback 근거는 보존하며, 현재 경로와 당시 경로를 구분한다.

정리 검증: 상대 문서 링크 300개와 AGENTS의 26개 문서 경로, 변경된 스크립트의 문서 참조
12개를 확인했다. 오래된 날짜 앵커 1개를 수정했다. 스크립트 5개는 parse에 성공했고,
변경 전 내용과 대조하여 문서 경로 외 실행 로직 변경이 없음을 확인했다.
문서 정리 전후(서식 수정 전) 저장소·Phase 0·3A/3B0/3B1/3B2 계약·Actions 검사는 통과했다. Phase 2A1/2A2/2B는
변경 전후 모두 `AccountImportExecution.cs:112–113` 등 기존 WHITESPACE 오류에서 중단됐으며,
DB 통합 검사까지 통과한 것으로 표시하지 않는다.

## 1차 구조 점검 검사 결과

- 저장소 working policy, Phase 0, 3A/3B0/3B1/3B2 계약 검사, Actions 계약: 통과.
- 실제 빌드 후 `Admin.Api.UnitTests --filter FullyQualifiedName~PhaseD`: **16/16 통과**.
- Phase 2A1/2A2/2B `-Integration`: 각각 시도했으나 상위 gate의 기존
  `src/NikkeLocalLab.Automation.Cli/Program.cs:100–120` WHITESPACE 오류로 중단.
  DB 통합 검사 통과나 DB 무결성 확인으로 해석하지 않는다. 서식 실패는 실게임 실패와도 다르다.
- 현재 151 실게임 성공: **운영자 확인**. 이번 점검에서 다시 게임을 실행하거나
  새 runtime 관측 receipt를 만들어 성공을 재주장하지 않았다.
