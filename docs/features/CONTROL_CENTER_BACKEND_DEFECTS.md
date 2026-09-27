# Control Center 백엔드 결함 기록

## 1. 문서 목적

이 문서는 2026-08-29~30 운영자 검수에서 확인한 Control Center의 데이터 적재, revision 조정과 실행 admission 결함을 기록한다. 화면 배치·이미지·표현 문제는 [CONTROL_CENTER_FRONTEND_DEFECTS.md](CONTROL_CENTER_FRONTEND_DEFECTS.md)에 기록한다.

## 2. 관측 요약

원인 진단 당시 로컬 계정 두 개의 current profile 내부 aggregate를 읽기 전용으로 조회한 결과는 다음과 같았다.

- `is_combat_ready = false`
- `has_complete_combat_semantics = false`
- `game_legal_readiness_status = unresolved`
- `game_legal_issue_code = draft_profile`
- 두 workspace 모두 `fetched_snapshot_uid = NULL`

적용성 수리와 admission 분리 후 두 계정의 runtime candidate는 모두 `ready`이며, 각 9,080개 값 중 unresolved는 0개다. 위 active-squad 중심 aggregate 상태는 스쿼드를 원본 게임 안에서 편성하는 실행 경로의 차단 조건이 아니다.

동시에 source-free sanitized draft와 영속 profile DB에는 다음 데이터가 존재한다.

- 레드 후드 전투력 관측값: `748,940`
- 레드 후드 장비 네 부위 오버로드 line: 총 10개
- 각 line의 option definition UID, fixed-point unscaled value와 decimal scale

따라서 `전투력 0`과 `오버로드가 비어 보임`을 동일한 데이터 적재 실패로 분류하면 안 된다. 전투력은 관측 snapshot 연결 결손이고, 오버로드는 DB 적재가 완료됐지만 presentation 의미 해석이 실패한 상태다.

## 3. 확인된 결함

### BE-001 — 저장 데이터가 준비돼도 사전 스쿼드 결손으로 실행을 차단함

- 심각도: 차단
- 현재 상태: 해결. 사실 단위 unresolved 321건 해소·설치본 수리·멱등성 검증 및 실행 admission의 잘못된 사전 스쿼드 조건 제거 완료
- 영향:
  - workspace validation이 `profile_selection_not_ready`, `profile_combat_semantics_incomplete`, `draft_profile`을 반환한다.
  - 솔로 레이드 실행 endpoint에 도달하기 전에 UI가 차단된다.
- 기대:
  - UID 가져오기 pipeline은 불완전 항목을 명시적으로 보정·확정하는 단계까지 수행하거나, 사람이 수정해야 할 정확한 항목을 반환해야 한다.
  - Control Center의 실행 admission은 저장된 runtime projection 값이 모두 `ready` 또는 `not_applicable`인지 검사한다.
  - 스쿼드·덱 편성은 원본 클라이언트에 진입한 뒤 게임 안에서 수행한다. 관리 툴이 실행 전에 임의의 5명을 선택하거나 별도 스쿼드 설정을 요구하지 않는다.
- 2026-08-30 최초 설치본 진단:
  - `뫼엥`, `뫼엥엥` 두 계정은 모두 전체 `9,080`개 값 중 ready `8,158`, not-applicable `601`, unresolved `321`로 완전히 동일하다. Save As가 원본의 미해결 사실을 손실 없이 복제한 결과다.
  - unresolved는 `bond_level_zero_semantics_unresolved` 9건과 `equipment_manufacturer_observation_missing` 312건뿐이다.
  - 호감도 9건은 `iDoll 썬`, `iDoll 오션`, `iDoll 플라워`, `솔져 E.G.`, `솔져 F.A.`, `솔져 O.W.`, `프로덕트 08`, `프로덕트 12`, `프로덕트 23`이며 모두 R 등급이다. 운영자 확인에 따라 R 니케는 호감도 시스템 자체가 없으므로 `bond_level`은 `not_applicable`이 권위 상태다. 현재 sanitizer가 관측값 `0`을 unresolved로 만든 것이 결함이다.
  - 기업 장비 312건은 91명에 걸쳐 머리 80, 몸통 81, 팔 80, 다리 71건이다. 운영자 확인에 따라 기업 판정은 9티어에서만 적용하며 오버로드 장비는 모두 기업 없음이다. 따라서 오버로드/T10의 `manufacturer_matched`는 `not_applicable`이어야 하고, 9티어만 기업 관측 또는 일치 판정을 요구해야 한다. 현재 sanitizer가 raw manufacturer code `0`을 tier 구분 없이 `equipment_manufacturer_observation_missing`으로 만든 것이 결함이다.
  - current profile의 집계 issue는 active-squad 중심의 내부 aggregate 규칙 때문에 `research_mode`, `profile_selection_unresolved`, `profile_semantics_unresolved`, `draft_profile`로 나타났다. 실제 projection value의 unresolved와 이 aggregate issue를 같은 실행 차단 조건으로 취급한 것이 결함이다.
  - 신규 import profile은 `squadCharacterUids: null`로 생성된다. 이는 원본 클라이언트 진입 뒤 스쿼드를 편성하는 정상 흐름이며 실행 전 결손으로 취급하면 안 된다.
  - 기존 workspace validation이 이 상태를 `profile_selection_not_ready`, `profile_combat_semantics_incomplete`, `draft_profile`로 해석하고 Launch를 차단한 것이 결함이다.
- 필요한 수정:
  - R 등급 양산형 9명의 호감도 capability를 exact catalog와 결박해 `not_applicable`로 materialize한다.
  - 오버로드/T10 장비의 `manufacturer_matched`를 `not_applicable`로 materialize하고, 9티어 장비에만 기업 관측·일치 검증을 적용한다.
  - runtime candidate readiness를 profile의 active squad 상태와 분리하고, projection 값의 materialization 가능성만으로 판정한다.
  - runtime DB에는 저장된 전체 로스터·장비·스킬·소장품 데이터를 반영하고, 스쿼드 선택은 원본 클라이언트에 맡긴다.
- 2026-08-30 적용성 수정:
  - sanitizer와 import materializer가 R 등급 bond 관측 `0`을 `not_applicable`로 저장한다.
  - T10/오버로드 장비의 `manufacturer_matched`는 `not_applicable`로 저장하고, T9는 exact catalog 결합으로도 판정할 수 없는 경우에만 unresolved로 남긴다.
  - T9의 별도 manufacturer code가 비어 있어도 선택 장비와 캐릭터의 exact catalog manufacturer가 ready이면 일치 여부를 계산한다. 선택 T9 장비의 exact catalog manufacturer가 `not_applicable`이면 일반 T9 무기업 장비로 확정하여 match fact도 `not_applicable`로 저장한다.
  - profile editor는 `bond_level`과 `equipment.*.manufacturer_matched`에 한정해 `controlled/not_applicable` 연산을 받으며, store/domain이 exact catalog 적용성을 재검증한다.
  - 기존 Save-As 계정은 옛 draft와 비교했을 때 캐릭터 레벨 193건, 콘솔 레벨 6건, 코어 2건, 싱크로 1건, 돌파 1건 및 오버로드 실제 수치 4건이 달랐다. 따라서 옛 draft `full_profile` 재적용은 폐기하고, 현재 revision에 적용성 309건과 오버로드 application magnitude 정상화 105건만 올리는 current-based editor repair로 교체했다.
- 2026-08-30 설치본 수리 결과:
  - 최초 321건 중 R 호감도 9건과 T10/오버로드 기업 300건을 `not_applicable`로, legacy 오버로드 application value 105건을 exact magnitude 보존 상태로 정규화했다.
  - 남은 12건은 두 계정 모두 같은 T9 일반 장비였고, exact 선택 장비 version의 manufacturer가 `not_applicable`임을 확인하여 계정별 12건씩 새 immutable revision에 기록했다. 결과 revision 번호는 각각 3과 8이며 기존 revision을 덮어쓰지 않았다.
  - 최종 runtime projection은 두 계정 모두 값 9,080개, ready 8,158개, not-applicable 922개, unresolved 0개다.
  - 동일 수리를 재실행한 영수증은 두 계정을 `alreadyResolved=true`, `databaseModified=false`로 기록했다. 따라서 적용성 수리는 멱등적이다.
  - T9 일반 무기업 장비를 신규 import에서도 `not_applicable`로 materialize하는 코드까지 설치본에 반영했고, application repair 및 cold-start smoke가 통과했다.
  - profile aggregate 내부의 active-squad readiness는 보존하되 Control Center 실행 admission의 권위로 사용하지 않는다. runtime candidate·workspace·계정 목록의 운영자용 준비 상태는 값이 모두 `ready`/`not_applicable`이면 `ready`가 된다.
  - 원본 클라이언트가 게임 안에서 편성할 스쿼드를 Control Center가 미리 생성하거나 자동 선택하지 않는다.
  - 배포 후 설치 스모크는 계정 2개와 workspace 2개를 모두 읽었고 대표 candidate가 값 9,080개, unresolved 0개, reason 0개, `ready`임을 확인했다. 후속 계정별 검사는 두 계정 모두 `squadConfigured=false`인 채 candidate `ready`와 reason 0개임을 확인했다.
- 테스트 공백 원인:
  - sanitizer 단위 테스트가 manufacturer code `0`과 bond level `0`을 unresolved로 만드는 현행 동작을 성공 조건으로 고정했다. 잘못된 의미 규칙을 테스트가 탐지한 것이 아니라 오히려 보존했다.
  - 신규 import profile의 `squadCharacterUids: null`은 원본 클라이언트가 인게임에서 편성하기 위한 정상 상태다. 테스트가 profile aggregate의 active-squad readiness와 runtime DB materialization readiness를 구분하지 않아 잘못된 Launch 차단을 발견하지 못했다.
  - 종전 설치 smoke는 candidate status를 `ready`뿐 아니라 `unresolved`도 정상으로 허용해 잘못된 Launch 차단을 놓쳤다. 현재 smoke는 값 존재, status `ready`, unresolved 0개, reason 0개를 모두 강제한다.
  - 실제 플레이가 부족했던 것이 아니다. 이전 Codex 작업 기록과 physical 영수증에는 원본 클라이언트에서 5개 덱을 모두 완주한 실행이 여러 차례 남아 있다. v5는 `raidJoinCount=5`, `recordCount=5`, `totalDamage=31,145,048,111`을, 후속 v6는 5덱 합계 `42,742,049,325`를, v8은 5덱 합계 `16,220,800,876`과 `battle_result / success` completion을 확인했다.
  - 다만 이 actual-play들은 physical Micron의 detached EpinelPS v5~v8 lane에서 수행됐다. 대화 기록상 Control Center Phase D 개발은 그 뒤에 착수됐으므로, 당시에는 현재의 `UID import → PostgreSQL profile → runtime candidate → materializer` 경로 자체가 존재하지 않았다. 따라서 actual-play는 원본 클라이언트 전투·5덱 세션·결과 처리 runtime의 강한 증거이지만, 나중에 추가된 Control Center 계정 import 및 profile 승격 pipeline의 end-to-end 검증은 아니다.
  - 결함의 본질은 “게임을 실제로 시험하지 않음”이 아니라 검증 추적성 단절이다. 이미 검증된 EpinelPS runtime lane과 새 Control Center SQL profile lane을 동일 계정 UID·profile revision·runtime candidate hash로 연결하는 통합 인수 테스트가 추가되지 않았다.

### BE-002 — incomplete fetched snapshot을 workspace 관측 출처로 연결하지 않음

- 심각도: 높음
- 현재 상태: UI용 최신 관측 read path 수정·설치 완료, admission pointer 분리는 유지
- 현재 snapshot:
  - roster `193`
  - detail `193`
  - equipment `193`
  - missing `0`
  - completeness `incomplete`
  - reason: `profile_import_not_write_ready`, `progression_summary_missing`
- 원인:
  - `PostgreSqlFetchedAccountSnapshotStore`는 completeness가 정확히 `complete`일 때만 `account_workspace.fetched_snapshot_uid`를 갱신한다.
  - 이 때문에 전투력처럼 정상 수집된 read-only 관측값까지 workspace에서 접근할 수 없게 된다.
- 기대:
  - `latest observed snapshot`과 `admission-authoritative complete snapshot` pointer를 분리한다.
  - 일부 completeness 결손이 있어도 정상 수집된 component는 UI read model에서 사용할 수 있어야 한다.
  - 운영자 지시 전까지 progression은 상수이므로 `progression_summary_missing`이 캐릭터·장비 관측 pointer 갱신을 막아서는 안 된다.
- 2026-08-30 수정:
  - `GetLatestForAccountAsync`와 `/accounts/{accountUid}/fetched-snapshots/latest`를 추가했다.
  - 이 경로는 completeness와 무관한 UI 관측 전용이며 `account_workspace.fetched_snapshot_uid`의 admission 권위를 변경하지 않는다.

### BE-003 — 전투력 관측값이 current profile read model에 보존되지 않음

- 심각도: 높음
- 현재 상태: 최신 관측 read model 수정·설치 완료, 실제 화면 재검수 대기
- 관측:
  - sanitized import draft의 `roster_combat_power_observation`과 `detail_combat_power_observation`에는 값이 존재한다.
  - materialized current character build에는 전투력 observation field가 없다.
  - UI는 workspace의 fetched snapshot pointer에 의존하는데 BE-002로 pointer가 NULL이다.
- 기대:
  - 전투력을 불변 build 계산값으로 오인하지 않고 source-tagged observation으로 보존한다.
  - current profile projection 또는 별도 account observation read model에서 character UID별 최신 관측값과 captured time을 제공한다.
  - Save As도 원본 계정의 관측 provenance를 잃지 않고 복사 또는 명시적으로 참조한다.
- 2026-08-30 수정:
  - current workspace에 authoritative fetched pointer가 없을 때 최신 snapshot의 roster 전투력을 우선하고 detail을 보조로 읽는다.
  - Save As child에 자체 snapshot이 없으면 parent account의 최신 snapshot을 조회한다. snapshot 소유권을 위조하거나 admission pointer를 복사하지 않는다.

### BE-004 — 통합 Save를 조정하는 단일 backend contract가 없음

- 심각도: 차단
- 현재 상태: 수정·PostgreSQL 통합 검증·설치 완료, 실제 계정 저장 재검수 대기
- 관측:
  - 프런트가 profile, lobby, wallet과 account label을 서로 다른 API 호출로 순차 저장한다.
  - profile head promotion trigger가 lobby head를 자동 전진시킨다.
  - profile save 응답에는 새 lobby head가 포함되지 않아 다음 lobby CAS가 stale ETag로 실패한다.
- 기대:
  - `Save`용 aggregate command를 추가하여 입력 head set 전체를 검증하고 새 profile/lobby/wallet/workspace head set을 한 receipt로 반환한다.
  - exact operation UID replay 시 동일 aggregate receipt를 반환한다.
  - 부분 성공 후 재개할 때 이미 반영된 child write와 남은 write를 구분한다.
- 2026-08-30 수정:
  - `PUT /accounts/{accountUid}/workspace`와 `POST /accounts/{accountUid}/workspace/save-as`를 추가해 profile, lobby, wallet, account label을 단일 명령으로 조정한다.
  - workspace/profile/lobby/wallet head와 기존 account label을 쓰기 전에 함께 검증한다.
  - root operation UID에서 고정 child operation UID를 파생하고 `account_workspace_save_operation`에 pending/completed 상태와 최종 head receipt를 보존한다.
  - profile promotion 뒤 DB trigger가 만든 최신 lobby revision을 한 번만 결박하므로 stale lobby ETag를 재사용하지 않는다.
  - 중간 중단 시 completed child operation은 exact replay하고 남은 단계만 계속한다. 완료 operation 재전송은 동일 profile/lobby/wallet revision set을 반환한다.
  - 폐기 가능한 loopback PostgreSQL에서 profile promotion, lobby revalidation, wallet/label 저장, exact replay와 Save As 초기화를 함께 검증했다.
  - 2026-08-30 설치 repair가 성공하여 새 API와 `V0011__account_workspace_save.sql`을 `C:\NLL\ControlCenter`에 배포했다.
  - 후속 installation smoke에서 새 설치본·PostgreSQL·관리 API 기동, 일회성 인증, 계정 2개의 workspace load를 확인했고 실패는 0건이었다. 검사는 계정 값을 변경하지 않았으며 runtime은 다시 cold 상태로 복귀했다.

### BE-005 — Save As가 fetch observation 연결을 보존하지 않음

- 심각도: 높음
- 현재 상태: 코드 수정·설치·DB migration 검증 완료, 실제 Save As 화면 재검수 대기
- 관측:
  - 새 account workspace 생성 시 `fetched_snapshot_uid`와 `last_fetched_at_utc`는 항상 NULL로 시작한다.
  - Save As는 profile revision을 복제해도 source observation 연결을 함께 전달하지 않는다.
- 기대:
  - Save As 계약에 `copy observation provenance` 동작을 명시한다.
  - snapshot row 자체를 새 계정 소유로 위조하지 않고, source snapshot에서 파생된 별도 observation binding 또는 immutable provenance reference를 생성한다.
- 2026-09-01 수정:
  - `V0014__save_as_observation_provenance.sql`을 추가했다. Save As operation은 profile 복제 전에 source 계정의 유효 observation snapshot UID를 `account_workspace_save_operation`에 한 번만 해소하여 고정한다.
  - 새 계정에는 `account_observation_provenance_binding`의 immutable reference만 생성한다. 원본 `fetched_account_snapshot.target_local_account_id`와 `account_workspace.fetched_snapshot_uid`는 복제하거나 변경하지 않는다.
  - operation 재시도는 처음 고정한 snapshot UID를 재사용하며, Save As 뒤 source 계정에 더 최신 fetch가 생겨도 child의 관측 출처는 바뀌지 않는다.
  - Save As를 연속 수행하면 직접 source가 가진 immutable binding을 이어받아 같은 원본 snapshot UID를 보존한다.
  - 기존 Save As 계정은 V0014 적용 시 parent chain에서 가장 가까운 유효 observation을 `legacy_parent_fallback/v1` binding으로 한 번만 고정한다. 당시 유효 observation이 없었던 계정도 NULL binding으로 기록하여 이후 parent fetch를 암묵적으로 따라가지 않는다.
  - aggregate Save As receipt에 `observationSourceSnapshotUid`를 추가하여 호출자가 어떤 observation provenance가 결박됐는지 확인할 수 있게 했다.
  - 고급 진단 영역에 남아 있던 profile-only Save As 버튼도 통합 workspace Save As로 연결하여 UI에서 provenance binding을 우회하지 못하게 했다.
  - PostgreSQL integration 시나리오에는 exact replay, snapshot 소유권 보존, source의 후속 fetch로부터 child 격리, 연속 Save As provenance 계승 검사를 추가했다.
  - 권한 없이 가능한 persistence/integration project build는 경고·오류 0건, migration shape test는 3/3, Admin API unit test는 40/40으로 통과했다. 전체 solution build는 제한된 실행 환경에서 NuGet vulnerability index에 접근하지 못한 `NU1900`만 발생했고 Save As 관련 project build에는 코드 오류가 없었다.
  - disposable PostgreSQL acceptance `fbb49fa0-5ad5-438b-9fa9-92cb9aff27e3`가 focused integration test 1/1과 연속 Save As binding 관측 `2/2`, 동일 원본 snapshot `1`, provenance kind `save_as/v1` 2건을 확인했다. 종료 뒤 PostgreSQL process와 55432 listener는 모두 0이었다.
  - application repair `aced2c33-510b-4a4b-9b65-cde678b83d01`로 최신 Admin API와 embedded V0014 migration을 `C:\NLL\ControlCenter`에 반영했다. 설치 DLL은 prepared artifact와 SHA-256 exact match다.
  - installation smoke `e0fbe9cb-d607-47af-bdfd-f3b5d560749e`가 계정 2개, loadable workspace 2개, workspace failure 0, candidate 9,080개·unresolved 0개, authenticated account read와 시즌 26 binding을 확인했다. 종료 시 PostgreSQL, Admin API, game runtime은 cold 상태로 복귀했다.

### BE-006 — 오버로드 option semantic label projection 결손

- 심각도: 높음
- 현재 상태: 수정·설치 완료, 실제 화면 재검수 대기
- 확인된 정상 항목:
  - current profile DB의 네 장비 `overload_line_count`는 각각 `3, 3, 2, 2`다.
  - 총 10개 line의 definition과 legal fixed-point 값이 존재한다.
  - presentation catalog에는 option definition 9개와 각 15개 legal value가 존재한다.
- 결손:
  - option description locale 해석이 실패하여 아홉 definition 모두 `오버로드 옵션` fallback으로 내려간다.
  - API가 `ratio`와 표시용 percent 의미를 함께 제공하지 않아 프런트가 잘못 표시한다.
- 기대:
  - presentation exporter는 공격력, 방어력, 명중률, 차지 속도, 차지 대미지, 최대 장탄 수, 우월코드 대미지 등 실제 효과명을 제공한다.
  - wire contract에는 저장 단위(`ratio`)와 표시 단위(`percent`) 및 정확한 변환 규칙을 명시한다.
- 2026-08-30 수정:
  - exporter가 `overload_option_definition_detail.option_type_code`를 legal-value alias와 같은 version으로 결합한다.
  - 설치본 presentation에서 아홉 정의가 공격력, 방어력, 최대 장탄, 크리티컬 확률·대미지, 차지 대미지·속도, 우월코드 대미지, 명중률로 각각 확인됐다.
  - 모든 정의에 `storedUnitCode=ratio`, `displayUnitCode=percent`, `ratioToDisplayMultiplier=100`을 기록했다.

### BE-007 — UID 가져오기가 개별 detail 레벨을 전투 레벨로 선택함

- 심각도: 높음
- 현재 상태: 원인 확정, 수정 반영
- 원인:
  - Control Center의 자동 가져오기 pipeline이 `detail_observation/v1`을 고정 선택했다.
  - 실제 수집본에서 detail 레벨은 `1`, roster 레벨은 계정의 싱크로 레벨이므로 모든 니케가 `Lv. 1`로 materialize됐다.
- 수정:
  - 자동 가져오기의 authority를 `roster_observation/v1`로 변경했다.
  - Control Center 편집기에서는 니케 개별 레벨을 직접 편집하지 않고 현재 계정의 설정된 싱크로 레벨을 전 니케에 일괄 적용한다.
  - Phase D runtime materializer도 캐릭터별 원본 level coordinate의 존재·정수성은 계속 검증하되, 실제 EpinelPS `CharacterModel.Level`에는 계정의 `SynchroDeviceLevel`을 전원 동일하게 투영한다.
  - 기존 저장본은 다음 `Save`에서 immutable profile revision으로 일괄 보정한다.
- 검증:
  - 설치 후 source-free materialization receipt `e9fc3443-3d85-4cab-81d7-7b0c75eb4fae`에서 싱크로 773, 캐릭터 193명, 싱크로 불일치 0명을 확인했다.
  - 이 검사는 원본 DB를 수정하지 않았고 파생 DB를 보존하지 않았으며 원본 클라이언트를 실행하지 않았다.

### BE-008 — 데스크톱 관리 세션이 작업 도중 만료됨

- 심각도: 높음
- 현재 상태: 로그로 원인 확정, 수정 반영
- 관측:
  - 서버 시작·bootstrap 교환 뒤 약 30분이 지나 `admin_session_required`가 반복됐다.
  - 화면 하단의 `Account load 실패`는 계정 데이터 load 실패가 아니라 인증 cookie 만료 응답이었다.
- 원인:
  - process-local 관리 세션의 고정 수명이 30분이었고 데스크톱 host에는 재인증 또는 갱신 경로가 없었다.
- 수정:
  - 로컬 데스크톱 작업 세션을 12시간 inactivity 기준 sliding session으로 변경했다.
  - 유효한 admin API 요청마다 서버 세션과 HttpOnly cookie 만료 시각을 함께 갱신한다.
  - 세션은 여전히 loopback 전용이고 Control Center server process 종료 시 소멸한다.

### BE-009 — application repair completion이 정상 export를 실패로 판정함

- 심각도: 중간
- 현재 상태: 원인 확정, 수정·설치 완료
- 관측:
  - Windows PowerShell 5.1에서 redirected self-contained exporter를 `Start-Process -PassThru`로 실행한 뒤 `WaitForExit()`와 `Refresh()`를 호출해도 `ExitCode`가 `$null`로 남았다.
  - 같은 실행에서 `presentation.json`, support-asset receipt, 장비 24개와 소장품 33개 이미지는 모두 생성됐고 stderr는 비어 있었다.
  - 기존 gate의 `$presentationExitCode -eq 0`이 거짓이 되어 `phase_d_application_repair_presentation_export_failed`를 잘못 발생시켰다.
- 수정:
  - child process exit code는 nullable advisory 관측값으로 receipt에 남긴다.
  - completion 권위는 presentation contract, 캐릭터·콘솔 cardinality, support-asset contract, 파일 개수와 source-free 표식 검증의 전부 통과로 변경했다.
  - 설치본 smoke에서 repair와 runtime cold 복귀가 다시 통과했다.

### BE-010 — 카탈로그 raw 부호를 프로필 application value로 잘못 저장함

- 심각도: 차단
- 현재 상태: 코드·설치본·영속 프로필 정상화 완료
- 원인:
  - exact catalog는 `source_raw_value`와 `engine_fraction`을 의도적으로 분리한다. 차지 속도와 명중률의 source raw는 음수지만, 런타임 option ID 매핑에 쓰는 `engine_fraction`은 양수 magnitude다.
  - import sanitizer가 resolver의 양수 `ApplicationValue` 대신 `SourceRawValue`를 sanitized line에 기록했다.
  - profile materializer가 차지 속도·명중률 definition을 별도 집합으로 분류해 magnitude를 다시 음수로 만들었다.
  - game-legal 검증도 양수 `engine_fraction`이 아니라 signed `source_raw_value`와 프로필 값을 비교했다.
- 영향:
  - UI에서 차지 속도와 명중률이 음수로 표시됐다.
  - Phase D runtime materializer는 `engine_fraction_unscaled_value`로 option ID를 찾으므로 음수 프로필 값은 `phase_d_overload_value_mapping_missing`을 일으킬 수 있었다.
- 불변 경계:
  - `source_raw_value`: 원본 카탈로그 증거이며 부호를 그대로 보존한다.
  - profile `ApplicationValue`: 양수 fixed-point magnitude만 저장한다.
  - runtime materializer: 양수 `engine_fraction`으로 exact legal value와 option ID를 결합한다. 클라이언트/서버 효과 부호 의미는 option ID가 담당한다.
- 2026-08-30 수정·검증:
  - sanitizer는 `ApplicationValue == abs(SourceRawValue)`와 scale `4`를 강제하고 양수 application value를 그대로 전달한다.
  - profile materializer는 legacy signed input도 magnitude로 정규화하며, store/domain game-legal 검증은 `engine_fraction`과 비교한다.
  - 프로필·import 단위 테스트 86개, 일회용 PostgreSQL의 application magnitude legal-set 테스트와 import/editor 경계 테스트가 통과했다.
  - 설치된 두 계정에서 음수 오버로드 값 `105 + 103 = 208`개를 각각 새 immutable revision으로 정상화했다. 결과 revision 번호는 `4`, `17`이며 기존 revision overwrite는 없었다.
  - 복구 직후 두 계정 모두 음수 오버로드 잔존 `0`, runtime candidate unresolved `0`을 확인했고 게임 runtime은 시작하지 않았다.

### BE-011 — Phase D bootstrap lane 불일치와 PostgreSQL 재시작 대기

- 심각도: 차단
- 현재 상태: 원인 확정, coordinator·watcher 수정, 회귀 테스트 및 설치 cold smoke 완료. 실제 클라이언트 재실행 대기
- 관측:
  - 실행 `19f6a25b-e952-4f2d-941f-5bc22f8701ab`은 materialization과 prelaunch validation을 통과한 뒤 `physical_bootstrap_and_sail_observation / bootstrap_exited_before_receipt`로 종료됐다.
  - 클라이언트와 bootstrap은 시작되지 않았고 outer hosts는 clean baseline SHA-256 `565955a47a890e8090a2987a234ba05e2624c84a587ba86e8648f912678984b9`로 복구됐다.
  - 실행 상태 파일은 실패 직후에도 약 3분간 `validated`에 머문 뒤 PostgreSQL이 다시 종료될 때에야 `failed`로 바뀌었다.
- 원인:
  - sealed `PhysicalBootstrap-v2`는 evidence lane으로 `p2-client-start-v1` 또는 `p2-client-start-v2`만 허용하며, 다른 값은 receipt directory 생성 전 exit code `64`로 종료한다.
  - coordinator가 실행별 격리를 위해 `phase-d-client-start-<launch-context-uid>`를 전달했으나, 실행별 격리는 bootstrap이 생성하는 assessment UID로 이미 보장된다. 허용되지 않은 lane 이름을 추가한 것이 직접 원인이다.
  - 실패 복구의 `pg_ctl start ... | Out-Null` pipeline은 Windows에서 postgres descendant가 pipeline handle을 상속하게 했다. `pg_ctl`이 종료돼도 PowerShell pipeline이 PostgreSQL 종료까지 닫히지 않아 coordinator와 HTTP 응답·상태 기록이 함께 지연됐다.
- 수정:
  - coordinator는 `BootstrapEvidenceLane`을 sealed contract의 `p2-client-start-v2`로 고정한다. 실행별 디렉터리는 기존 assessment UID를 사용하며 공유하거나 덮어쓰지 않는다.
  - coordinator와 completion watcher의 PostgreSQL start/stop은 pipeline을 사용하지 않고 `Start-Process -Wait -PassThru`로 `pg_ctl` PID만 기다린다.
  - 실패 상태는 DB 재시작 전에 먼저 원자적으로 기록하고, 재시작 실패가 발생하면 `phase_d_control_center_database_restart_failed`로 다시 갱신한다.
- 검증:
  - Admin API 단위 테스트 `33/33`, PowerShell 5.1·7 parser, 잘못된 dynamic lane과 `pg_ctl | Out-Null` 정적 부재 검사가 통과했다.
  - application repair `cb3061df-190a-439b-9a48-0f0c58709a18`과 installation smoke `716572b0-70d0-4e6e-90e0-9e757a08ba13`이 통과했다.
  - smoke는 계정 2개, workspace 실패 0개, candidate 값 9,080개, unresolved 0개와 runtime cold 복귀를 확인했으며 게임 runtime은 시작하지 않았다.

### BE-012 — 고아 실행 상태·세션 파일·자식 프로세스가 다음 실행을 차단함

- 심각도: 차단
- 현재 상태: 수정·설치·stale-session 포함 생명주기 smoke 완료
- 관측:
  - 실제 NIKKE, EpinelPS, PhysicalBootstrap과 80/443 listener가 모두 없는 상태에서도 실행 `5547c970-bd96-4623-b685-57de97bb1235`의 `execution-state.json`이 `started`로 남아 `phase_d_runtime_not_cold`가 발생했다.
  - 강제 종료 뒤 `session.json`이 남으면 설치 시작 스크립트는 PID 생존 여부를 보지 않고 `control_center_already_running`을 반환했다.
  - 데스크톱 종료 대기 시간이 끝난 경우 UI만 닫히고 host PowerShell, Admin API dotnet 또는 PostgreSQL이 남을 수 있었다.
  - `Start-Process -Wait`로 실행한 `pg_ctl start`는 Windows에서 PostgreSQL descendant까지 기다려 세션 생성 전에 시작 스크립트를 정지시킬 수 있었다.
- 수정:
  - Phase D coordinator는 completion watcher PID와 exact start time을 별도 identity 문서와 실행 상태에 기록한다.
  - 새 실행 전 active state가 있으면 실제 runtime/watcher identity를 먼저 검사한다. 모두 죽은 경우에만 파생 DB, active pointer, hosts와 firewall을 보수적으로 원복하고 `rolled_back / phase_d_orphaned_execution_recovered`로 닫는다.
  - 실제 runtime이나 exact watcher가 살아 있으면 자동 복구하지 않고 계속 fail closed한다.
  - Control Center session은 host PowerShell과 Admin API dotnet의 PID·exact start time을 함께 pin한다. 둘 다 살아 있으면 중복 실행을 거부하고, host가 죽고 admin만 남았거나 PID가 모두 죽은 stale session만 자동 회수한다.
  - 데스크톱 정상 종료는 stop-signal 뒤 completion watcher까지 기다린다. 90초 종료 실패 시 설치된 Stop 스크립트로 exact admin session과 전용 PostgreSQL을 정리하며, 이 복구도 실패하면 창을 닫지 않는다.
  - PostgreSQL 제어는 `Start-Process -Wait` 대신 `System.Diagnostics.Process`로 `pg_ctl.exe` 자신의 PID만 기다린다.
- 복구·검증:
  - 고아 실행 `5547c970-...`은 실제 runtime process 0, hosts backup hash 일치 상태에서 `rolled_back`으로 닫혔고 active execution은 0개가 됐다.
  - application repair 및 installation smoke가 통과했다.
  - 설치본 생명주기 receipt `057179ec-90e4-4ac1-9b68-e0fad14fb4c6`은 stale session 자동 회수, host/admin identity pinning, stop-signal 정상 종료, session 제거와 55433/17878 cold 복귀를 확인했다.

### BE-013 — EpinelPS가 1000 초과 캐릭터 레벨을 기동 시 전원 강제 보정함

- 심각도: 높음
- 현재 상태: 2026-09-18 사용자 요청에 따라 실행 서버 상한 1000→1200 수정. 아래 1400은 과거 원본 범위 조사 기록이며 현재 요구 상한은 1200이다. 서버 시작 및 API 응답의 1200 보존, 1201→1200 제한 검사 통과. 설치 완료 후 사용자가 싱크로 정상 작동을 확인했다. [현재 작업](../operations/UNION_RAID_HARD_IMPLEMENTATION.md) 참조.
- 관측:
  - 실행 `5547c970-...`의 runtime candidate는 캐릭터 193명 전부 `character_level=1101`이다.
  - materializer가 만든 `db.json`도 193명 전부 1101을 보존한다.
  - EpinelPS `JsonDb.ValidateDb()`에는 `Level > 1000`이면 1000으로 바꾸는 hard-coded validation이 있다.
  - 같은 실행의 server stdout에는 `cannot be above 1000, setting to 1000` 경고가 정확히 193건 기록됐다. 따라서 특정 캐릭터가 아니라 보유 193명 전원에 동일 보정이 적용됐다.
  - 이 보정은 `JsonDb.Save()` 뒤 in-memory validation에서 수행되므로 디스크 `db.json`은 1101인데 실행 중 응답은 1000인 이중 상태를 만든다.
  - 현재 static level data는 1~1400을 제공하므로 1000 hard cap은 현 데이터 범위와 불일치한다.
- 판정:
  - Control Center가 저장 단계에서 1000으로 바꾼 것이 아니다. 저장·materialization은 싱크로 1101을 정확히 유지했고, EpinelPS 기동 단계가 전원 1000으로 강제 보정했다.
  - 이번 점검에서는 서버 코드를 임의로 바꾸지 않았다. 후속 수정 시 hard-coded 1000을 static level data의 확인된 최대치로 결박하고, 기동 전후 193명 레벨 exact equality를 admission test로 추가해야 한다.
  - 싱크로 773 계정에서도 니케 목록과 Solo Raid 편성이 동일하게 비는 것이 재현됐다. 이 두 UI 결함의 원인은 BE-013이 아니라 BE-014다.
- 1400 상한 사전 검증:
  - 봉인된 `StaticData.pack`의 실제 `CharacterLevelTable`을 EpinelPS `GameData`로 직접 읽은 결과 key 수 1,400개, 최소 1, 최대 1,400, 중간 결손 0개였다.
  - 1001·1101·1400은 모두 존재하고 1401은 존재하지 않는다.
  - `SynchroLevelUp`은 `TryGetValue(current + 1)` 실패 시 반환하고, `SynchroDeviceOneClick`도 `TryGetValue(lv + 1)` 실패 시 중단하며, `SynchroOneClick`은 table 최대 key로 target을 clamp한다. 따라서 1400에서 1401을 직접 index하는 경로는 확인되지 않았다.
  - 결론적으로 현 build에서는 hard cap을 1000에서 1400으로 올리는 것이 static-data 범위와 일치한다. 다만 immutable pinned runtime DLL의 hash가 바뀌므로 기존 v8을 덮어쓰지 않고 새 runtime lane과 새 hash admission을 만들어 배포해야 한다.

### BE-014 — 오버로드 부모 옵션 ID를 StateEffectId로 잘못 materialize해 클라이언트 목록 구성이 중단됨

- 심각도: 차단
- 현재 상태: 원인 확정, materializer 수정·설치 및 773 candidate 회귀 완료, original-client 재검수 대기
- 관측:
  - 실행 `787ceb17-2bc6-45cd-829b-8b449ba01ab0`은 싱크로 773이며, 서버의 `/v1/character/get`과 `/v1/character/synchrodevice/get` 응답은 모두 성공했다. runtime DB에도 캐릭터 193명이 존재한다.
  - 원본 클라이언트 `Player.log`는 니케 화면과 `TeamSetCommonRaid` 양쪽에서 `StateEffectTable[TableId], TableId=1007001`을 기록했다.
  - 두 stack trace 모두 `NKCharacterViewData.get_CombatPower()`에서 시작해 전투력 정렬 중 예외가 발생한다. 서버가 빈 roster를 반환한 것이 아니라, 한 캐릭터의 전투력 계산 예외가 전체 목록 구성을 중단한 것이다.
  - 문제 DB의 `EquipmentAwakenings`에는 `1007001`이 12건 있으며 옵션 ID 전체가 `100xxxx` 계열이다. 실제 original-client 5덱 완주 기준 DB에는 `1007001`이 없고, 오버로드 옵션은 `700xxxx` 계열의 state-effect ID다.
- 원인:
  - `BuildMappings()`는 source alias를 `stateEffect.StateEffectId`로 지문 대조한 뒤, 반환값으로 해당 효과 ID가 아니라 부모 `EquipmentOption.Id`를 저장했다.
  - EpinelPS의 장비 각성·옵션 변경 로직과 클라이언트의 `NetEquipmentAwakeningOption` 계약은 구체적인 `StateEffectId`를 요구한다. 부모 옵션 ID는 클라이언트 `StateEffectTable`에 없으므로 전투력 계산이 실패한다.
- 수정:
  - overload 값 매핑 결과를 `option.Id`에서 `stateEffect.StateEffectId`로 교체했다.
  - materialization 종료 전에 모든 비영(非零) 오버로드 ID가 pinned static data의 state-effect 집합에 속하는지 검사하고, 아니면 `phase_d_overload_state_effect_mapping_invalid`로 실행 전 차단한다.
  - presentation catalog 검증도 부모 옵션 dictionary key 조회가 아니라 state-effect membership 확인을 사용한다.
- 검증:
  - materializer Release 빌드는 경고·오류 0건이며 `PhaseDArtifactSafetyTests`가 통과했다.
  - application repair와 cold-start installation smoke가 통과했고, 설치 artifact의 materializer DLL hash가 새 빌드와 일치한다.
  - source-free 회귀 receipt `cec2f0bb-df73-4373-bc4d-24320eff0567`은 동일한 773 candidate에서 캐릭터 193명, 장비 각성 300개, 채워진 오버로드 옵션 638개를 materialize했다. 부모 옵션 ID shape는 0건이며 state-effect admission을 통과했다.
  - 회귀 검사는 원본 DB를 수정하지 않았고 파생 DB·비밀을 보존하지 않았으며 원본 클라이언트를 실행하지 않았다. 최종 인수는 원본 클라이언트 니케 목록과 Solo Raid 편성 재검수다.

### BE-015 — Control Center Stop 오류가 NIKKE·서버·부트스트랩 잔존을 구분하지 않음

- 심각도: 중간
- 현재 상태: 현상·직접 원인 확인, 메시지 세분화 미적용
- 관측:
  - 운영자가 NIKKE를 종료한 뒤에도 Stop이 `control_center_stop_game_still_running`을 반환했다.
  - 당시 NIKKE PID는 이미 없었고 파생 실행의 EpinelPS PID 9164가 남아 있었다.
  - Stop 스크립트는 `nikke`, `EpinelPS`, `NikkeLocalLab.Phase3B2.PhysicalBootstrap` 중 하나라도 존재하면 동일한 failure code를 사용한다. 따라서 서버 잔존을 게임 잔존처럼 표시한다.
  - 파생 실행의 exact completion script로 EpinelPS·부트스트랩을 닫고 hosts·방화벽을 원복한 뒤 Stop과 repair가 정상 진행됐다.
- 후속:
  - failure code를 client/server/bootstrap별로 분리하고 exact PID·start-time 기반 recovery action을 UI에 표시한다.
  - desktop host 종료 시 WebView child가 DLL lock을 유지하는 경우도 별도 `desktop_webview_still_running`으로 구분한다.

### BE-016 — 시작 스크립트가 서버 descendant까지 기다려 completion watcher를 만들지 못함

- 심각도: 차단
- 현재 상태: 직접 원인 수정·정적 회귀 완료, 설치본 실제 실행 재검수 대기
- 관측:
  - 실행 `0dec3aa5-7a59-45e5-a296-3226ada7f07b`은 NIKKE가 기동한 뒤에도 상태가 `validated`에 머물렀고 `completion-watcher.identity.json`, watcher PID와 client PID가 모두 기록되지 않았다.
  - 운영자가 NIKKE를 종료해도 화면은 계속 `솔로 레이드 실행 진행 중…`으로 남았다.
- 원인:
  - coordinator의 `Invoke-PhaseDChildScript`가 `Start-Process -Wait`로 파생 start PowerShell을 실행했다.
  - Windows의 이 대기는 start PowerShell이 만든 EpinelPS·bootstrap·NIKKE descendant까지 기다릴 수 있다. 따라서 start receipt를 읽고 completion watcher를 만드는 다음 문장에 도달하지 못했다.
- 수정:
  - 파생 스크립트 stdout/stderr redirection은 exact child PowerShell 내부에서 수행한다.
  - coordinator는 `Start-Process -PassThru`로 얻은 exact child `Process`에 직접 `WaitForExit()`하고 그 exit code만 읽는다. EpinelPS·bootstrap·NIKKE descendant의 수명은 completion watcher가 별도로 추적한다.
  - 회귀 검사는 coordinator에서 OS-level `Start-Process -Wait` redirection 조합이 사라지고 exact process wait가 남는 것을 고정한다.
- 검증:
  - exact-child smoke receipt `939f545f-12ae-4ecb-8aeb-81c076f80cb4`은 시작 PowerShell 종료 직후 descendant가 계속 살아 있고 exact identity로 분리되는 것을 확인했으며, 테스트 descendant는 검사 직후 종료했다.
  - application repair `1b57b79c-f7e4-4308-bbc0-5bfa4c12a99c`과 installation smoke `1d25bef5-d6f0-4474-9fc6-d1793758df6f`이 통과했다. smoke 종료 시 game runtime과 active execution은 cold 상태였다.
- 복구:
  - 위 실행의 파생 completion을 수행해 EpinelPS, bootstrap, active pointer, hosts와 방화벽을 정리했다. 현재 NIKKE·EpinelPS·bootstrap process와 active execution pointer는 없다.
  - 기존에 정지돼 있던 coordinator와 수동 completion이 경합해 해당 과거 state는 `failed / phase_d_emergency_rollback_failed`로 닫혔다. 이는 새 exact-child 경로의 정상 종료 판정이 아니라 고아 실행 수동 복구 이력이다.

### BE-017 — 완료 복구가 Solo Raid 런타임 DB를 실행 전 baseline으로 되돌려 기록을 소실함

- 심각도: 차단
- 현재 상태: 원인 확정, 코드·PostgreSQL 실통합·설치본 migration 및 cold smoke 완료, 원본 클라이언트 재실행 acceptance 대기
- 관측:
  - 실제 5덱 완료 뒤 EpinelPS는 `ClassicSoloRaidPersistenceCoordinator`를 통해 `db.json`을 정상 저장했다.
  - 완료 스크립트가 이후 런타임 DB를 `db.before.bin`으로 복원했고, 다음 실행도 Solo Raid 상태가 비어 있는 고정 parent baseline에서 시작했다.
  - 따라서 `[완주 → 게임 종료 → 재실행]` 뒤 최고 기록과 5개 덱 기록이 사라졌다. 원인은 Epinel save 실패나 클라이언트 cache가 아니라 Local Lab transient rollback 순서였다.
- 수정:
  - V0013에 account/season/실제 raid snapshot/client build별 aggregate, immutable state revision, idempotent operation ledger를 추가했다.
  - 새 실행은 현재 profile을 먼저 materialize한 뒤 최소 Solo Raid 상태만 복원한다. 완료 기록은 profile revision 변경 뒤에도 유지하고, 진행 중 open run만 동일 revision set에서 복원한다.
  - client와 Epinel 종료 뒤 rollback 전에 최소 상태를 AES-GCM pending으로 캡처한다. PostgreSQL 영속화가 증명된 뒤에만 실행을 terminal로 닫고, 두 terminal 문서 이후에만 pending을 삭제한다.
  - coordinator·watcher·orphan recovery의 모든 rollback 경로는 active pointer, pointer contract/run root, `db.before.bin`, 복원 후 SHA-256을 증명해야 한다. 증명 실패, watcher handoff 중단, 또는 replay 대기 evidence가 있으면 실행 상태를 `started`로 유지해 다음 launch를 막고 재시작 recovery가 exact replay 또는 검증된 rollback을 완료한다. watcher ownership 이전 후 coordinator는 같은 runtime, hosts, PostgreSQL을 동시에 복구하지 않는다.
  - watcher와 orphan recovery는 기존 receipt만 신뢰하지 않고 DB exact replay를 항상 실행한다. request/binding/payload/result hash와 CAS head가 일치해야 완료한다.
  - 낮거나 비어 있는 완료 최고점이 이미 저장된 최고점을 덮으려 하면 `completed_best_regression_quarantined`로 격리한다.
- 검증:
  - PostgreSQL 17 disposable cluster에서 V0013 포함 migration 13개 적용, 재적용 0, 최초·후속 revision, exact replay, unchanged, stale-head quarantine, 과거 content hash 재등장, 완료 최고점 역행 quarantine를 모두 확인했다.
  - persistence 및 runtime materializer 빌드는 경고·오류 0건이다. PowerShell parser 3개, artifact safety 5개, migration 검사 2개가 통과했다.
  - 봉인 v9 baseline 캡처 smoke는 source DB SHA-256 불변과 인증 request hash가 있는 암호화 pending 생성을 확인했다.
  - 최종 application repair `8af0487d-e497-4053-ab6b-5a14f0a3bb89`로 설치 앱, materializer, fail-closed orphan recovery를 반영했고, installation smoke `e13993e3-fc59-49e9-a787-f92b81ee8000`가 새 Admin API 기동, embedded migration checksum gate, 계정 2개와 workspace 2개, candidate 9,080개·unresolved 0개, runtime cold 복귀를 확인했다. 설치 앱·materializer·orphan recovery 해시는 repair 영수증과 exact match이며 공식 설치본 변경은 없었다.
  - 실제 원본 클라이언트에서 새 5덱을 완료한 뒤 종료·재실행하는 acceptance는 아직 수행하지 않았다. 이 acceptance 전에는 actual-client 해결 완료로 승격하지 않는다.
  - 2026-09-01 시즌 29 실행을 1덱 뒤 닫은 동작은 뒤늦게 **Solo Raid 메인 화면 상단의 빨간 `Quit`**으로 확인됐다. 따라서 당시 이를 “운영자가 정상 확정한 부분 완료”로 판정해 V0015에서 `1..5`덱 완료를 허용한 것은 잘못된 의미 해석이었다. 고아 실행 `67709853-0d9e-4ba8-8fad-5c0c57b561e1`의 `13,026,486,951` 승격도 유효한 최고 기록이 아니라 폐기돼야 할 run을 영속화한 결함 증거로 재분류한다.
  - 정상 Challenge 완료는 5번째 `setdamage`에서 이미 `RaidJoinCount=5`, `Logs.Count=5`, `IsClear=true`, `IsOpen=false`로 확정된다. `/soloraid/trial/close`는 이와 별개의 Quit/abandon 경로이므로 열린 Trial과 그 부분 로그만 제거하고, 기존 5덱 최고 기록은 유지하도록 수정했다.
  - 캡처·신규 PostgreSQL revision은 다시 정확히 5덱인 완료 기록만 받는다. V0016의 `NOT VALID` 제약은 V0015 역사 row를 삭제·변조하지 않으면서 신규 partial 완료 삽입을 차단한다. legacy 1~4덱 head는 복원 시 클라이언트에 투영하지 않고, 다음 유효 캡처가 정상 head로 전진할 수 있게 했다.
  - EpinelPS 선택 manager 테스트 118/118, Admin API 집중 테스트 11/11, migration 정적 검사 5/5와 보스 약점 변형 자동화 계약 검사가 통과했다.
  - 최종 application repair `b90701cb-e527-492f-8ef1-b43f649bed8f`가 V0016과 수정된 EpinelPS/Admin API/materializer를 설치했다. EpinelPS DLL SHA-256은 `a364b9211efc1b60d23efc50075e101b0212f09b96a311b167743d01583939e6`, source manifest SHA-256은 `0ebd23987384fde1537b88efcfdd5b19fc18176f185d9cd1e9fa743914d24bbf`로 준비본·설치본이 일치한다.
  - 후속 Raid Catalog repair `188b0c4a-709b-418d-8d3d-f407d0db869c`와 cold installation smoke `32921fbc-cfab-48d2-af7e-5b8b89a53149`가 성공했다. smoke는 계정 2개·workspace 2개·candidate 9,080개·unresolved 0개, Solo Raid binding, 종료 후 runtime cold와 공식 설치본 불변을 확인했다.
  - 남은 acceptance는 원본 클라이언트에서 `[1~4덱 진행 → 이 화면 상단 빨간 Quit → 재진입]` 시 이번 run이 없고 기존 5덱 최고 기록이 유지되는지, 그리고 별도로 5덱 완주 기록이 재실행 뒤 유지되는지 확인하는 것이다.

### BE-018 — 실행 상태 JSON 오류가 실제 RaidSnapshot 결박 누락을 가림

- 심각도: 차단
- 현재 상태: 원인 확정, 코드·설치 DB 수리·binding 검증·cold installation smoke 완료. BE-017의 원본 클라이언트 재실행 acceptance 대기
- 관측:
  - Control Center 실행은 처음에 `request_json_invalid`를 반환했다.
  - 해당 요청 본문은 정상이며, coordinator 소유 `execution-state.json`의 선택 시각 필드가 JSON `null` 대신 빈 문자열로 기록된 것이 2차 오류였다.
  - 빈 문자열 호환을 추가한 뒤 실제 최초 오류 `phase_d_raid_state_operational_binding_missing`이 드러났다.
  - 읽기 전용 설치 DB 감사 결과는 계정 2개, migration 13개 적용 상태였지만 raid catalog 0개, 시즌 26 snapshot 0개, boot revision 0개, season directory 0개였다.
- 원인:
  - PowerShell의 nullable 문자열 인자를 그대로 cast하면서 미설정 `watcherProcessStartedAtUtc`가 `""`로 직렬화됐다. 내부 상태 문서의 `JsonException`도 전역 요청 JSON 오류 처리기가 가로채 외부 요청 문제처럼 표시했다.
  - Phase D 배포가 character/support/profile catalog만 적재하고 권위 있는 `raid-catalog-import`를 누락했다. V0013 runtime aggregate는 실제 `lab_raid.raid_snapshot` FK를 요구하므로 catalog가 없는 DB에서는 영속 상태 key를 만들 수 없다.
  - 과거 launch context의 selected-manager assessment UID와 target-observation digest는 실제 RaidSnapshot UID/SHA가 아니다. 이를 placeholder로 재사용하거나 시즌 26 값을 하드코딩하는 방식은 폐기했다.
- 수정:
  - 실행 상태의 미설정 선택 필드는 실제 JSON `null`로 저장한다. legacy 빈 문자열은 읽기 호환하되, 손상된 coordinator 상태는 `phase_d_execution_state_invalid`로 분리해 `request_json_invalid`로 위장하지 않는다.
  - 봉인된 exact StaticData를 기존 `raid-catalog-import`로 적재해 DB가 발급한 catalog/snapshot UID와 content SHA를 사용한다.
  - operational binding은 현재 raid day의 effective boot가 있으면 그 exact directory binding을 우선한다. effective boot가 없을 때만 시즌 `[7,13,26,29,34,40]`을 정확히 한 번씩 포함하는 유일한 eligible catalog를 허용한다. 0개는 missing, 2개 이상은 cardinality invalid로 fail closed하며 최신값 추정은 하지 않는다.
  - fresh deploy에도 raid catalog import를 추가했고, 기존 설치에는 별도 idempotent data repair를 제공한다. data repair는 boot/directory를 생성하거나 수정하지 않는다.
  - 설치 smoke는 4개 app-specific materializer 파일을 host 없이 단독 실행하지 않고, build host 파일을 갖춘 격리 임시 폴더에 동일 artifact를 overlay해 검증한 뒤 폴더를 삭제한다.
- 검증:
  - repair receipt `9b387312-dbc1-4826-998b-696f1924ebd3`은 import `succeeded`, catalog `0 → 1`, 시즌 26 snapshot `0 → 1`, boot/directory `0 → 0`과 runtime cold 복귀를 기록했다.
  - 복구된 시즌 26 binding은 DB 발급 snapshot UID `fc801119-003f-4d00-9fa0-09918b13608a`, content SHA-256 `75e2a181e34e65246ce46fdd7d382d278d283685e1b47ac7f8da8790293166cb`이며 materializer의 read-only verification과 일치했다.
  - installation smoke `4333eb70-47fc-46ad-9622-ab18135172be`는 계정 2개, loadable workspace 2개, workspace 실패 0개, candidate 값 9,080개, unresolved/reason 0개, 시즌 26 binding exact match를 확인했다. smoke는 DB를 수정하거나 게임 runtime을 시작하지 않았고 종료 뒤 PostgreSQL·55433·17878·임시 materializer 폴더가 모두 cold/empty였다.
  - focused Admin tests는 8/8, artifact safety tests는 5/5, PostgreSQL integration project build는 경고·오류 0건이며 PowerShell parser가 수정 스크립트를 모두 통과했다.
  - 이 항목은 실행 전 operational binding을 해결한 것이며, BE-017의 `[새 5덱 완주 → 종료 → 재실행]` actual-client 영속성 판정을 대신하지 않는다.

### BE-019 — 정상 실행 중 상태 폴링이 `phase_d_runtime_not_cold`를 반환함

- 심각도: 높음
- 현재 상태: 원인 확정, 코드 수정·집중 테스트·설치본 repair 완료. 다음 실제 실행에서 상태 전이 재검수 대기
- 관측:
  - 2026-09-01 21:28:29 KST에 Admin API가 `phase_d_runtime_not_cold`를 반환했고 Control Center는 `Launch status 실패`로 표시했다.
  - 오류 뒤 감사 시 NIKKE·EpinelPS·부트스트랩은 모두 종료돼 있었고 관련 포트도 비어 있었다. stale 파일 자체가 직접 오류를 만든 것은 아니었다.
- 원인:
  - UI는 `started` 실행을 3초마다 GET으로 조회한다. `GetAsync()`가 조회 전에 고아 복구를 무조건 호출했고, 복구 대상 상태에서 정상 NIKKE/EpinelPS가 살아 있으면 이를 경쟁 실행과 같은 `phase_d_runtime_not_cold`로 처리했다.
  - 새 실행 POST와 상태 조회 GET에 동일한 live-runtime 정책을 사용한 것이 직접 결함이다. 종료 직후 process teardown 시간도 같은 오표시를 연장할 수 있었다.
  - 1차 수정 뒤 재발 건은 복구 스크립트 exit code `2`의 의미를 잘못 매핑한 별도 종료 경합이었다. 이 값은 runtime 생존이 아니라 exact completion watcher가 아직 살아 있다는 뜻인데 Admin API가 이를 다시 `phase_d_runtime_not_cold`로 번역했다.
- 수정:
  - 새 실행은 기존처럼 live runtime이 있으면 fail closed한다.
  - 상태 조회는 live runtime이 있으면 현재 `started` projection을 정상 반환한다. 런타임이 cold가 된 다음 폴링에서만 exact orphan reconciliation을 실행한다.
  - 자동 프로세스 종료나 이름 기반 강제 정리는 추가하지 않았다.
  - 복구 exit code `2`는 상태 GET에서 오류로 승격하지 않고 현재 projection을 반환해 다음 폴링에 재시도한다. 경쟁 start만 `phase_d_orphan_recovery_in_progress`로 fail closed하며, runtime 생존 코드와 구분한다.
- 검증:
  - `PhaseDExecutionStateTests` 5/5가 통과했고, start/status의 `failIfRuntimeActive` 정책이 각각 `true/false`인지 고정했다.
  - Release publish와 application repair가 성공했다. repair UID는 `da863ac4-4f50-4c70-a10b-7a9af275cb93`, receipt SHA-256은 `27c8fa928b78baa132d5269442a82dd1aacb7c657583ac69f2746e12f0cc8da8`이다.
  - prepared/installed Admin API DLL SHA-256은 모두 `09edc0a294b4f42e6e514dee742471e4cb83d40b34b6e10e8c562c4678afc460`으로 일치한다. repair 뒤 game runtime, 55433/17878 listener와 session은 cold 상태다.
  - exit code `2`의 watcher-active 분기까지 포함한 최종 Admin API 집중 테스트 11/11이 통과했다. application repair `b90701cb-e527-492f-8ef1-b43f649bed8f`와 installation smoke `32921fbc-cfab-48d2-af7e-5b8b89a53149` 뒤에도 NIKKE·EpinelPS·bootstrap·PostgreSQL 프로세스와 55433/17878 listener가 남지 않았다.

## 4. 백엔드 수정 우선순위

1. BE-017 영속화 변경의 원본 클라이언트 종료·재실행 acceptance
2. BE-005 Save As observation provenance의 disposable PostgreSQL·설치본 acceptance
3. BE-001 imported profile readiness 승격 경로
4. BE-002/BE-003 snapshot pointer와 combat-power observation read model 운영자 재검수
5. BE-006 오버로드 semantic label·unit projection 운영자 재검수
6. BE-014/BE-016 수정 설치 및 773 original-client 니케 목록·Solo Raid 편성·종료 재검수

## 5. 현재 판정

- 전투력 `0`: 실제 값 0이 아니라 **관측 출처 연결 실패**
- 오버로드 미표시: **DB 적재 실패가 아님**. semantic label과 단위 presentation 실패
- 과거 레이드 실행 차단: **draft profile readiness와 operational RaidSnapshot 결박 모두 해결**, 현재는 BE-017 actual-client 재실행 acceptance 대기
- Save conflict: **aggregate command와 exact replay receipt로 수정·설치 완료, 실제 계정 저장 재검수 대기**
- Solo Raid 재실행 기록 소실: **rollback 전 보호 캡처와 immutable PostgreSQL revision 구현·실 DB 검증 완료, 설치본 actual-client acceptance 대기**

위 네 항목이 해결되기 전에는 현 Control Center를 운영자용 계정 관리 도구의 완성본으로 판정하지 않는다.
