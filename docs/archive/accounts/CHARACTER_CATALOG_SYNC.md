# 캐릭터 목록 동기화

> 2026-09-27 보관: 작성 당시의 기록이며 현재 작업 지시가 아닙니다. 현행 문서는 [문서 색인](../../README.md)에서 찾습니다.

2026-09-16 운영자가 니케 도감의 보유 설정 옆 버튼 배치를 승인했다.

## 2026-09-19 가져오기 도구·검증 해시 교체

운영 동기화가 `import.log`의 `error:migration_history_unknown`으로 중단됐다.
캐시 pack/locale 해독은 성공했으나 활성 `characterSync.importerPath`가 9월 16일
독립 게시본을 계속 가리켰다. 그 게시본의 Persistence DLL에는 V0022까지만 들어 있었고,
현재 운영 DB는 V0027이었다. 운영 앱 업데이트와 별개인 동기화 도구의 교체 누락이었다.

최신 Import CLI 및 전체 의존 파일을 별도 고정 게시 디렉터리
`artifacts/character-sync-repair-20260919/importer/`에 만들고 V0027 포함을 확인했다.
`characterSync.importerPath`를 교체하고 게시본 DLL/실행 설정 등 26개 파일을 pin에 포함했다.
나머지 기존 도구 pin 3개는 유지했다. 활성 설정 JSON의 SHA-256도 다시 계산하여
`C:\NLL\ControlCenter\boss-pipeline.active.json`을 원자적으로 전환했다.
기존 도구와 설정은 롤백용으로 보존했다.

현재 DB를 임시 복제하여 같은 동기화 스크립트 전 구간을 실행했다.
결과는 `updated`, 신규 0명, 이미지 누락 0개이며 검증 DB는 삭제했다.
운영 DB와 운영 presentation은 이 검증에서 변경하지 않았다.
설정 교체 후에는 다음 관리도구 실행부터 적용된다. 사용자 UI 버튼 인수는 별도다.
설치·검증 영수증은 `artifacts/character-sync-repair-20260919/`에 있다.

DB schema를 추가하는 다음 배포에서도 운영 앱뿐 아니라 별도 `characterSync` Import CLI의
embedded migration 및 실제 의존 파일을 함께 확인한다. 개발용 `bin`을 직접 가리키거나
검사를 우회해 구버전 도구가 새 DB에 쓰도록 하지 않는다.

## 동작과 연결

1. `POST /admin-api/v1/characters/sync`: 관리 인증·JSON·CSRF 적용. 단일 동기화만 실행한다.
2. `scripts/sync-nll-character-catalog.ps1`: 시즌 동기화와 같은 캐시 pack을 안정된 복사본으로 읽고
   `C:\NIKKE`의 sd.bin·locale을 읽는다. 원본 파일은 수정하지 않는다.
3. materializer의 `--export-local-character-source`: 기존 로컬 pack 해석을 재사용하고
   한국어 이름·버스트와 내부 alias fingerprint를 추출한다. 게임/음성 설정을 호출하지 않는다.
4. 기존 `character-catalog-import`: 자체 UID·정의·capability를 불변 snapshot에 게시한다.
   이번 snapshot UID를 지정해 presentation을 생성한다. 공개 API에는 원본 ID/alias를 노출하지 않는다.
5. 기존 목록의 지원 정의·콘솔 등은 유지하고 캐릭터 목록만 교체한다. 기존 UID 삭제는 거부한다.
   이미 있는 초상화는 재사용, 없는 이미지만 기존 공개 공급 경로로 준비한다. 결손은 재동기화 대상이다.
6. 이미지 준비 후 presentation 파일을 원자 교체한다. 새 캐릭터는 미보유로 표시된다.
7. `모두 보유로 설정` → Save/Save As에서 선택한 catalog UID를 편집 요청에 고정한다.
   기존 보유 빌드는 보존하고 새 캐릭터만 기본 육성으로 생성한다. 다른 계정·과거 revision은 유지한다.

## 반복·실패·정리

- pack/sd.bin/locale catalog가 같고 이미지 결손이 없으면 추가 import 없이 `unchanged`다.
- import 실패·목록 감소·동시 파일 변경은 현재 목록을 유지한다. DB에 게시되었지만 선택되지 않은
  불변 catalog가 남을 수 있으며, 이는 계정 데이터 변경이 아니다.
- 작업 중 UI 편집을 지우지 않는다. 동기화 진행은 버튼과 상태줄에 표시한다.
- 이번 호출이 만든 pack/sd.bin/decoded/locale 복사본은 finally에서 정리한다.
- 활성 설정의 `characterSync`에는 도구 pin과 출력 경로를 둔다. source와 운영 비밀은 커밋하지 않는다.

## 검증

- 격리 PostgreSQL: 기존 catalog에서 추가, 새 catalog에만 있는 캐릭터 추가, 기존 빌드 전체 값 보존,
  기본 육성, 동일 저장 요청 replay, 반복 보유 추가, Save As 검사를 통과했다.
- UI: 실제 editor transport로 JSON·CSRF·목록 reload·미보유 유지·대기 편집 보존·catalog pin·실패 보존 검사.
- 실제 로컬 자료 리허설: 도감 199 → 200명, `드레이크 : 그레이트 빌런` 1명 추가, 이미지 결손 0.
  직후 재실행은 `unchanged`, 추가 0. 별도 presentation 복사본을 사용했고 운영 계정은 편집하지 않았다.
- 근거와 설치/회귀 검사 결과: `artifacts/character-sync-20260916/`.
- 신규 니케의 실제 게임 사용은 이 도감 동기화 검사에 포함하지 않는다.

## 설치

- 필수 회귀 gate 8개, UI 16개, 격리 DB 2개, HTTP 인증/JSON/CSRF 검사와 실제 worker의
  `unchanged` 응답 확인이 통과했다. 잘못된 source 경로에서도 기존 목록 해시가 유지됐다.
- 운영자가 관리도구를 닫은 뒤 앱 패키지와 `characterSync` 활성 설정을 적용했다.
  첫 설치 보조 스크립트의 null backup 경로 오류는 자동 복구 후 실제 backup 경로로 수정·재적용했다.
- 앱 적용/반복 적용/복구/반복 복구를 별도 복사본에서 검증했다. 현재 앱과 보스 게시물·운영 목록·
  계정은 분리해 보존한다. 관리도구를 다시 열고 버튼을 눌러 실제 도감을 갱신한다.

### 설치 후 시작 실패 수정

운영자의 실제 실행에서 `desktop_start_failed`가 발생했다. API 로그는 `admin_start_failed`였다.
실제 composition은 `UnmappedMemberHandling.Disallow`로 `characterSync`를 읽는데,
`CharacterCatalogSyncOptions`가 root/scriptPath/scriptSha256 3개만 선언한 채 설치 설정은
materializerPath/importerPath/gameConfigArchivePath/presentationPath/toolPins까지 포함해
첫 추가 필드부터 `JsonException`이 발생했다. 기존 worker probe가 일반 Web JSON 옵션으로
해석한 뒤 worker만 실행해 이 시작 경로 결함을 잡지 못했다.

options에 전체 8개 필드와 tool pin 형식을 선언했다. 실제 composition과 같은 엄격한
JSON 옵션에 전체 설정을 넣는 합성 회귀 검사는 수정 전 실패, 수정 후 통과했다.
API DLL/PDB 두 파일만 백업·교체했으며 활성 설정과 계정은 변경하지 않았다.
실제 설치된 desktop을 재시작해 API HTTP 200, 동기화 버튼이 포함된 HTML 제공과
계정 설정·니케 관리·솔로 레이드 메뉴 표시를 확인했다. 초기화 오류/준비 중 안내는 없었다.
필수 gate 8개도 모두 통과했다. 근거: `artifacts/character-sync-startup-fix-20260916/`.

### 동기화 직후 상세 화면과 자동 저장

운영자는 동기화로 추가된 니케 상세가 Save 전까지 이름/이미지 미확인으로 표시되는 현상을
보고하고 동기화 결과의 자동 저장을 요청했다. 서버의 catalog/presentation은 이미 동기화
호출 안에서 영속화되고 있었다. 클라이언트가 카드만 다시 그린 채 상세 편집용 select의
options를 갱신하지 않아 새 UID 선택이 빈 값이 되고, 상세 제목/초상화가 빈 값으로 덮였다.
Save는 우연히 전체 편집기를 다시 그려 문제를 숨겼다.

동기화 성공 시 전체 니케 선택 목록과 열려 있는 상세를 갱신하도록 수정했다. 자동 저장된
정보가 Save 없이 즉시 반영되며, 미보유 상태와 기존 대기 편집은 유지한다. `모두 보유로 설정`의
계정 저장 의미는 변경하지 않는다. 실제 select 동작을 재현하는 회귀 검사는 수정 전 실패,
후 통과했으며 실제 브라우저의 동기화 → 새 카드 → 상세 경로도 확인한다.
근거: `artifacts/character-sync-detail-fix-20260916/`.

### 2026-09-19 계정 조회 후 불필요한 레벨 편집 제거

동기화 뒤 나타난 변경 88건은 카탈로그 동기화가 아니라 계정 로드에서 개별
`character_level`을 `synchro_level`과 같게 만드는 UI 편집 생성이 원인이었다.
계정 조회와 편집 취소에서는 이 변환을 제거했다. Save 준비에서도 저장된 싱크로
값과 입력이 같으면 개별 레벨을 변경하지 않는다. 카드·상세의 표시 레벨은 계속
싱크로 값을 따른다. 사용자가 싱크로 값을 변경하면 기존처럼 레벨 편집을 생성하며,
원래 값으로 되돌리면 이 동작이 생성한 편집만 되돌리고 별도 편집은 보존한다.

실제 editor.js를 사용하는 합성 검사 19건이 통과했다. 개별 레벨 1인 캐릭터 88명과
싱크로 782를 둔 계정 로드 → 카탈로그 동기화 → Save 준비에서 레벨 편집 0건,
표시 레벨 782와 저장된 개별 레벨 1 유지, 명시적 변경·복원·취소를 확인했다.
설치된 JS를 백업·교체하고 SHA-256 일치를 확인했다. 기존 창에는 이전 JS가 남아
있으므로 다시 열어야 적용된다. 계정 DB는 변경하지 않았다.

Phase 3A/3B-0/3B-1/3B-2 contract-only 및 Actions 계약 검사는 통과했다.
전체 gate는 NuGet 취약성 정보 조회 실패(NU1900)로 중단되어 전체 통과를 주장하지 않는다.
사용자의 실제 UI 확인은 별도이다. 근거: `artifacts/sync-pending-edits-20260919/`.
