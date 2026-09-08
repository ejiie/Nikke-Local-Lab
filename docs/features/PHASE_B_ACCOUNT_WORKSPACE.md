# Phase B Account Workspace

## 목적

Phase B는 이름 있는 여러 local account를 한 화면에서 관리하고, 기존 immutable profile revision 체계 위에서 `Save`와 `Save As`를 구분하며, 선택 account를 실행 단계가 소비할 수 있는 candidate로 내보내는 단계다. 이 단계는 official account, credential, live traffic, Micron runtime 또는 Golden을 변경하지 않는다.

## 저장 모델

`lab_profile.account_workspace`는 게임 상태가 아니라 관리 metadata다.

- `local_account_id`: 기존 local account의 UID
- `workspace_uid`: 관리 workspace 식별자
- `account_label`: `계정_1` 같은 사용자 표시 이름
- `save_as_parent_account_uid`: 복제 출처 추적용 UID
- `fetched_snapshot_uid`, `last_fetched_at_utc`: Phase C용 nullable 자리
- `last_execution_result_code`: Phase D용 nullable 자리

실제 닉네임, 지휘관·싱크로·console 수치, 니케 투자·스킬·장비·오버로드·소장품은 기존 revision graph에만 저장한다. label 변경은 game revision을 만들지 않고, game edit는 label history를 덮어쓰지 않는다.

## 동작

### Save

현재 account UID와 expected profile revision을 함께 보낸다. 서버는 preview hash와 validation을 확인한 뒤 같은 account에 새 immutable revision을 추가한다. 다른 account에는 영향을 주지 않는다.

### Save As

현재 편집 결과와 새 `accountLabel`을 보낸다. 서버는 새 local account UID를 만들고, 원본 account UID를 `save_as_parent_account_uid`로 기록하며, 새 account의 첫 revision을 같은 transaction에서 생성한다. 이후 원본과 복제본은 서로 다른 optimistic-concurrency head와 revision history를 가진다.

Phase C fetch 연결 이후에는 profile만 복제하고 observation 출처를 잃는 동작을 허용하지 않는다. `V0014`부터 aggregate Save As operation은 시작 시점의 유효 fetched snapshot UID를 operation ledger에 고정하고, child account에는 `account_observation_provenance_binding`의 immutable reference만 남긴다. 원본 snapshot row의 account 소유권과 admission용 workspace pointer는 복제하지 않는다. 원본 account가 나중에 다시 fetch되어도 이미 생성된 child의 observation은 바뀌지 않으며, 연속 Save As도 같은 원본 snapshot provenance를 이어받는다.

### Runtime projection candidate

export는 실행 자체가 아니다. 선택 account workspace, current profile revision, account-state revision과 canonical profile values를 묶고 deterministic SHA-256을 계산한다. Phase D의 launch context가 이 candidate를 입력으로 고정하게 된다.

S-03 소스 정비부터 workspace/profile/readiness와 실행용 lobby는 한 RepeatableRead view에서
읽는다. Phase D는 `GetRuntimeProjectionSnapshotAsync`의 candidate/lobby 묶음을 소비하며,
기존 두 실행 JSON의 wire 형식은 유지한다. 목록의 readiness도 목록에 표시한 exact profile
revision으로 계산한다. 읽기 중 head가 전진해도 이미 고정한 묶음의 일부를 최신값으로 바꾸지 않는다.

다단계 workspace Save의 child commit만 보이는 상태는 실행 준비 완료가 아니다. snapshot 시점에
해당 계정의 Save가 pending이면 export/launch는 `409 account_workspace_save_pending`으로
종료하고 실행 파일·프로세스를 만들지 않는다. Save As는 deterministic profile child operation으로
생성된 정확한 계정만 대상으로 하며 원본·형제 복제본을 차단하지 않는다. 정상 완료 또는 같은 요청의
복구 후 새 snapshot을 읽는다. 편집·복구용 조회는 유지하고 pending 이력을 자동 삭제하지 않는다.
이 경계 자체는 Save 전체를 하나의 transaction으로 만들거나 배포·실게임 검증을 대신하지 않는다.

### 다단계 Save 조정·복구 — S-07 소스 정비

`AccountWorkspaceSaveCoordinator`가 단계 순서를, `WorkspaceSaveStages`가 기존 writer 연결을,
`PostgreSqlAccountWorkspaceSaveStore`가 DB 잠금·claim·checkpoint·완료 기록을 맡는다.
기존 child operation UID 도출 규칙, 요청 hash, revision, CAS, no-op 및 완료 receipt는 유지한다.
초기 조정기 분리에는 migration이 없었다. 후속 UI 복구는 V0018의 요청 보존 테이블만 추가하며,
기존 revision을 재작성하거나 여러 child transaction을 하나로 합치지 않는다.

1. 완료된 동일 operation/request는 저장 당시 receipt를 그대로 replay한다.
2. 계정별 PostgreSQL advisory transaction lock으로 **workspace Save/Save As 호출끼리** 조정한다.
   진행 중인 같은 계정 요청은 중복 요청도 `409 account_workspace_save_in_progress`로 즉시 거절한다.
   첫 요청 종료 후 **동일 operation UID와 동일 요청 내용**으로 재시도한다. 다른 계정은 계속 저장 가능하다.
3. 새 요청은 기존 pending Save가 없는지와 expected workspace/profile/lobby/wallet/label을
   먼저 검사한다. 이 사전 검사에서 거절한 새 요청은 pending row를 남기지 않는다.
4. 기존 claim만 있고 profile child의 commit 증거가 없으면 사전 검사를 다시 한다.
   profile child가 이미 commit됐다면 기존 writer의 exact replay로 다음 단계를 이어간다.
   실행 취소·예외에도 DB 잠금은 해제하되, 이미 남긴 pending 기록을 지우지는 않는다.
5. 중단된 Save를 새 operation으로 덮어쓰려 하면 `409 account_workspace_save_pending`이다.
   Save As가 만든 정확한 child도 보호하며 원본·형제 계정의 launch는 기존 S-03 정책을 유지한다.
   Save As의 source에서 또 다른 workspace Save/Save As를 시작하는 것은 기존 copy 복구 후 허용한다.
6. observation은 최초 resolution의 UID를 유지한다. 복구 사이 source에 새 fetch가 생겨도
   copy의 provenance를 최신 것으로 바꾸지 않는다.

#### 기존 pending 작업 처리 경계

- 같은 UID라도 요청 내용이 달라지면 `account_workspace_save_operation_reuse_mismatch`로 거절한다.
- 원래 요청을 보존한 경우에만 exact replay한다. profile 미commit 상태에서 head가 달라졌거나,
  별도 writer가 후속 revision을 만든 경우에는 해당 revision conflict/superseded 오류를 유지한다.
  오래됐다는 이유로 pending을 삭제·완료 처리하거나 expected revision을 최신값으로 바꾸지 않는다.
- **V0018 이전 pending에는 원문을 소급 생성하지 않는다.** 원문이 없으면
  `original_request_required`로 표시하고 이어 저장 버튼을 제공하지 않는다. claim·child receipt·
  current head를 읽기 전용 대조한 후 별도 절차/승인이 필요하다. 원문을 따로 보유한 경우의
  기존 exact Save API와 완료 receipt 재조회는 유지한다.
- 이 lock은 개별 profile/lobby/wallet API, import, 직접 SQL까지 포괄하는 전역 writer lock이
  아니다. 그 경로와의 경쟁은 기존 CAS를 따르며, 모든 writer의 원자성 확보로 해석하지 않는다.

#### UI 재시도와 요청 영속 보존 — 2026-09-07 미배포 소스

- 신규 claim과 `lab_profile.account_workspace_save_request`의 원문을 같은 transaction에 쓴다.
  원문 보존에 실패하면 claim도 남지 않으며 어떤 child writer도 실행하지 않는다.
- 원문은 `nll/account-workspace-save-envelope/v1`의 canonical UTF-8 JSON(최대 16 KiB)이다.
  operation/source/kind/hash, 원래 expected revision, candidate 참조, label/lobby/wallet 입력을
  보존한다. 전체 프로필 복제본·원본 게임 ID·인증정보는 넣지 않는다. DB FK/checksum과 변경 금지
  trigger로 묶고, 읽을 때 canonical 재인코딩 및 기존 요청 hash까지 대조한다.
- 같은 창의 Save/Save As 재시도는 최초 body/operation UID/If-Match를 그대로 전송한다.
  preview·입력 수집·Save As 이름 요청을 다시 하지 않는다. 처리 중 중복 클릭과 편집을 막는다.
  결과 불명 시 요청을 유지하며, claim이 없다고 다시 확인된 명확한 4xx만 편집을 다시 허용한다.
- 계정 열기는 pending과 최근 완료 receipt의 **조회만** 한다. 원문은 브라우저에 반환하지 않고
  브라우저 영구 저장소에도 쓰지 않는다. 새 창의 ‘원래 요청 이어서 저장’은 UID/hash만 보내며
  서버가 보존한 원문으로 기존 조정기를 호출한다. 시작/조회 시 자동으로 쓰거나 복구하지 않는다.
- 완료 receipt만 있으면 ‘저장 상태’ 패널은 표시하지 않는다. 저장 처리 중·pending·결과 불명인
  같은 창의 재시도 요청이 있을 때는 안내와 기존 편집 보호를 유지한다. 완료 이력은 삭제하지 않는다.
- Save As의 미완성 복제본에서도 원본 source의 같은 operation을 복구한다. 형제 계정의 pending은
  노출하지 않는다. 원문 손상은 `request_invalid`, source/hash 불일치는 거절로 남기며 추정 보정하지 않는다.
- 실제 API는 `GET /admin-api/v1/accounts/{accountUid}/workspace/saves`와
  `POST /admin-api/v1/accounts/{sourceAccountUid}/workspace/saves/resume`이다. POST body는
  `operationUid`뿐이고 `If-Match`는 **원래 request SHA-256**이다. 기존 admin session/Origin/CSRF/
  strict JSON 검증을 그대로 적용한다. 아래 구형 API 표와 달리 이 경로가 구현 권위다.
- 검증은 실제 editor.js를 합성 DOM/transport에서 실행하고, 폐기 PostgreSQL의 단계별 중단 뒤
  새 service/connection pool로 복구한다. 실제 앱/OS 강제 종료나 실게임 인수를 대신하지 않는다.

## API

| Method | Path | 의미 |
|---|---|---|
| `GET` | `/admin/api/accounts` | account 목록과 current revision 요약 |
| `GET` | `/admin/api/accounts/{accountUid}/workspace` | workspace와 current profile binding |
| `GET` | `/admin/api/accounts/{accountUid}/revisions` | 해당 account만의 revision history |
| `PUT` | `/admin/api/accounts/{accountUid}/label` | management label 변경 |
| `GET` | `/admin/api/accounts/{accountUid}/runtime-projection-candidate` | 읽기 전용 실행 candidate export |

기존 preview, save, save-as API는 그대로 사용한다. `Save As` request에 `accountLabel`만 추가했다.

## UI 범위

- Accounts: 목록, 선택, label 변경, revision history, runtime candidate export
- General: nickname/commander binding의 기존 profile 편집과 synchro·console 전용 좌표 편집
- Nikkes: roster 좌표별 investment, skill, equipment, overload, cube, collectible 편집
- Progression: 현재 account/revision binding 표시. 실제 fetched progression은 Phase C에서 추가
- Advanced: 원래 generic coordinate editor와 import surface 유지

전용 form도 기존 edit-operation list를 만들 뿐 별도 저장 경로를 사용하지 않는다. 따라서 전용 form과 Advanced editor의 preview hash 및 validation 의미가 동일하다.

## 자동 검증

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
& 'C:\Users\zih44\Documents\Github\Nikke-Local-Lab\scripts\verify-automation-phase-b.ps1'
```

검증 항목은 다음과 같다.

1. account/workspace와 runtime candidate 계약 존재
2. V0008이 기존 game revision table을 갱신하지 않는지 확인
3. account list/workspace/history/label/export API 존재
4. Save As label·parent binding 존재
5. Admin API unit tests와 migration shape test 통과
6. editor JavaScript 문법과 unsafe DOM sink 부재

## Live PostgreSQL 승인 절차

테스트 DB 연결 문자열을 `NIKKE_LAB_TEST_DB`에 둔 환경에서 다음 integration test를 실행한다.

```powershell
$env:NIKKE_LAB_TEST_DB = '<local test PostgreSQL connection string>'
dotnet test '.\tests\NikkeLocalLab.PostgreSql.IntegrationTests\NikkeLocalLab.PostgreSql.IntegrationTests.csproj' `
    --configuration Release `
    --filter 'FullyQualifiedName~SaveAs'
```

승인 관측은 다음 순서다.

1. `계정_1`에 edit를 preview/save하고 revision head가 한 단계 증가하는지 확인
2. 동일 결과를 `계정_2`로 Save As하고 새 account UID와 parent UID를 확인
3. `계정_1`만 다시 수정하여 `계정_2`의 current revision이 변하지 않는지 확인
4. `계정_2`만 다시 수정하여 `계정_1`의 current revision이 변하지 않는지 확인
5. 두 history와 runtime projection candidate SHA-256이 서로 독립인지 확인

이 승인 전에는 Phase B를 실제 DB까지 완료됐다고 표기하지 않는다. 이 승인도 Micron runtime/Golden에는 적용하지 않는다.

## Live 승인 결과 — 2026-08-29

Windows-native PostgreSQL `17.11`의 disposable loopback cluster에서 위 focused integration test를 실행해 통과했다.

- acceptance UID: `57535125-f0b3-4467-8695-c85c954a20d7`
- verdict: `phase_b_live_acceptance_passed`
- `계정_1`: profile revision `2`, Save As parent 없음
- `계정_2`: profile revision `2`, `계정_1`을 Save As parent로 가짐
- 원본·복제본의 후속 character-level edit, current head와 runtime candidate SHA-256 독립성: 확인
- Docker/Windows service 사용: 없음
- game runtime/Golden 변경: 없음
- 종료 후 `postgres.exe`, port `55432` listener와 disposable data directory: 모두 `0`
- receipt: `artifacts/automation/phase-b-live/57535125-f0b3-4467-8695-c85c954a20d7.receipt.json`

따라서 Phase B의 실제 DB 완료 기준은 충족됐다. 다음 단계는 Phase C fetch adapter이며 Progression 탭의 실제 fetched progression 연결은 아직 수행하지 않았다.
