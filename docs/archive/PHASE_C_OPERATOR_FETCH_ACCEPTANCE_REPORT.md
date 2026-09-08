# Phase C 실제 operator fetch acceptance 보고서

> 보관 기록: 2026-09-06 문서 정리 때 이동했습니다. 본문의 ‘현재·다음·미완료’는 작성 당시 기준입니다. 현행 안내는 [문서 색인](../README.md)과 [현재 경로](../MICRON_CURRENT_PATHS.md)를 따릅니다.

## 결론

2026-08-29에 실제 로컬 credential-bearing 캡처, 운영자가 지정한 완전 진행 `NKSD_TRIGGER_*` 템플릿과 exact StaticData 입력을 읽기 전용으로 사용해 다음 경로를 검증했다.

`fresh raw capture + stable progression template → FetchedProgressionObservation/v2 → canonical sanitized draft → FetchedAccountSnapshot/v1 → local account 생성 → local edit → fetched diff → account_state_only 선택 적용 → 동일 캡처 재비교`

최신 최종 실행은 통과했다. source synchro level `773`을 로컬에서 `774`로 변경했을 때 fetched draft가 정확히 한 건의 차이를 검출했고, 선택 적용 뒤 `773`으로 복원했으며, 같은 캡처를 두 번째 observation으로 등록했을 때 diff는 `0`이었다. progression sidecar도 같은 snapshot UID와 정확한 capture timestamp에 결박되어 등록됐다.

backend/service/DB acceptance는 완료됐다. 남은 항목은 다음과 같다.

- `StageClearHistorys`는 legacy source에서 관측되지 않아 `unavailable`로 남는다.
- profile draft의 unresolved 항목 때문에 snapshot은 여전히 `incomplete`다.
- Control Center 브라우저 UI를 직접 조작한 acceptance는 수행하지 않았다.
- commander level의 lobby projection과 선택 적용은 검증하지 않았다.

최신 최종 verdict는 `phase_c_operator_fresh_same_capture_progression_acceptance_passed`다.

## 입력과 비변경 경계

- 실제 credential-bearing 캡처는 read-only 입력으로만 열었다.
- raw path, raw hash, 공식 user identifier, credential, token과 session은 source-free artifact와 receipt에 저장하지 않았다.
- exact StaticData pack은 read-only로 열고 importer가 요구하는 archive를 임시 메모리/임시 파일 경계에서만 복호했다.
- 임시 decoded StaticData archive는 종료 시 삭제했다.
- Windows-native PostgreSQL 17 disposable cluster만 사용했고 종료 뒤 `postgres` process와 listener가 모두 `0`임을 확인했다.
- Golden, Micron game runtime, client, hosts와 공식 서비스는 수정하거나 실행하지 않았다.
- 공식 outbound request는 수행하지 않았다.

## 실제 관측 범위

| 항목 | 관측값 |
|---|---:|
| roster | 193 |
| character detail | 193 |
| snapshot character | 193 |
| equipment character | 193 |
| missing character | 0 |
| console | 9 |
| equipment coordinate | 772 |
| overload line | 638 |
| equipped equipment | 486 |
| bond ready | 184 |
| bond unresolved | 9 |
| equipment manufacturer match ready | 174 |
| equipment manufacturer match unresolved | 312 |
| import warning | 6 |

roster/detail/equipment-character 개수와 character UID closure는 일치했다. 다만 과거 client UI에서 관측한 `198`과 이 캡처의 `193` 차이는 임의 보정하지 않았다. 새 fetch에서 다시 관측해야 한다.

최신 snapshot completeness는 `incomplete`이며 reason code는 다음 두 개다.

- `profile_import_not_write_ready`
- `stage_clear_historys_unavailable`

`can_materialize_local_account_profile=true`와 `is_local_account_profile_write_ready=false`는 모순이 아니다. 전자는 unresolved 사실을 보존한 research-mode local profile을 만들 수 있다는 뜻이고, 후자는 모든 필드가 game-legal ready 상태는 아니라는 뜻이다.

## 발견한 문제와 처리 결과

### 1. 영구 operator 설정 부재

초기 환경에는 `NIKKE_LAB_HOME`, raw input, DB connection, identity secret에 대한 process/user/machine 설정이 없었고 영구 PostgreSQL instance도 실행 중이 아니었다.

이번 acceptance는 이 상태를 변경하지 않고 disposable PostgreSQL, process-local DB password와 process-local identity secret으로 수행했다. 운영용 Control Center를 반복 실행하려면 별도의 명시적 configuration bootstrap이 필요하다.

### 2. repository runtime overlap guard

처음 runtime root를 repository 아래 임시 디렉터리로 두었을 때 `repository_runtime_overlap` guard가 실행을 거부했다. 이는 결함이 아니라 raw/runtime artifact가 repository에 들어오는 것을 막는 정상 안전장치다.

acceptance harness의 runtime root를 OS temp의 acceptance UID 전용 디렉터리로 옮겼다.

### 3. StaticData 입력 형식 불일치

보유한 exact 입력은 Epinel runtime용 encrypted `StaticData.pack`이지만 Phase 1 character/combat-support importer는 decoded ZIP archive를 입력 계약으로 요구했다. pack을 그대로 주면 각각 `archive_invalid`, `archive_decode_invalid`가 발생했다.

별도 decoded archive는 보존되어 있지 않았다. 따라서 로컬 EpinelPS의 이미 검증된 StaticData decoder를 acceptance harness에서 호출해 exact decoded byte length와 SHA-256을 검증한 뒤 임시 archive로만 전달했다. archive는 매 실행 종료 시 삭제한다.

남은 구조적 과제는 importer 앞에 `pack → verified archive` adapter를 정식 pipeline stage로 만들고, 현재 harness 내부 reflection 의존을 versioned contract로 승격하는 것이다.

### 4. CLI 단계 간 sanitized draft handoff 부재

기존 `profile-draft-import`는 sanitized draft를 PostgreSQL에만 저장했지만 다음 `fetched-account-snapshot-materialize`는 canonical sanitized draft 파일을 요구했다. 따라서 CLI 두 단계를 독립적으로 조합할 수 없었다.

`profile-draft-import --output-draft`를 추가했다. 출력은 runtime root 내부의 새 파일만 허용하고, reparse·overwrite를 거부하며 canonical source-free draft만 내보낸다. 콘솔에는 경로 대신 `sanitized_draft_exported=true`만 출력한다.

### 5. `core_level` not-applicable 의미 손실

첫 계정 생성은 `profile_character_cap_invalid`로 실패했다. 처음에는 roster 수 문제로 오인할 가능성이 있었지만 capability 종류별 집계를 추가해 실제 원인을 관측했다.

정확한 원인은 카탈로그에서 `core_level=not_applicable`인 character 29개를 importer materializer가 모두 `Ready(0)`으로 변환한 것이었다. 수치 `0`은 같아도 상태 의미가 다르므로 DB의 catalog-bound validator가 거부한 것이 맞다.

수정 후 materializer는 sanitized draft에 결박된 exact character catalog snapshot에서 `core_level=not_applicable` UID 집합을 읽고 다음과 같이 투영한다.

- catalog `not_applicable` → `LocalProfileFact.NotApplicable()`
- catalog `ready` → 관측된 `core_level`을 `LocalProfileFact.Ready(value)`

임의로 모든 `0`을 not-applicable로 처리하지 않는다. 따라서 core가 적용 가능한 character의 실제 `0`과 적용 불가능 character를 구분한다.

### 6. incomplete snapshot current-pointer NULL 처리 결함

계정 생성과 local edit가 통과한 다음 snapshot 등록 결과를 읽을 때 `InvalidCastException: Column is null`이 발생했다.

`workspace.fetched_snapshot_uid = snapshot.uid` SQL 비교식은 workspace current pointer가 NULL이면 PostgreSQL의 3-valued logic에 따라 NULL을 반환한다. 저장소는 이를 non-null Boolean으로 읽고 있었다.

비교식을 `COALESCE(comparison, FALSE)`로 수정했다. incomplete snapshot은 감사 이력과 명시적 diff 입력으로는 등록되지만 current workspace snapshot은 되지 않는 기존 정책을 그대로 보존한다.

### 7. sandbox PostgreSQL 실행 제한

일반 sandbox token에서는 native PostgreSQL bootstrap/start가 권한 오류로 실패했다. 승인된 non-sandbox 실행에서는 정상 동작했다. 실패 실행에서도 cleanup이 수행되어 process와 listener는 `0`이었다.

이는 application의 PostgreSQL 호환성 실패가 아니라 Codex sandbox token과 native child-process/DPAPI 경계 문제다. 자동화에서는 이 단계가 승인된 local execution을 필요로 함을 명시해야 한다.

### 8. progression과 commander level의 적용 경로 결손

현재 실제 캡처에는 stage/main-quest/scenario progression summary가 없어 `progression_summary_missing`이 발생했다. `CompletedScenarios`, `MainQuestData`, `ContentsOpenUnlocked`, `StageClearHistorys`, `Triggers`를 fetch snapshot에 병합하는 작업이 남아 있다.

기본 계정 관측의 commander level은 snapshot에 표현할 수 있지만 현재 selective import의 `account_state_only`는 synchro level과 console을 대상으로 한다. commander level은 lobby presentation revision의 필드이므로 fetched snapshot에서 lobby diff/apply로 연결하는 별도 명시적 projection이 필요하다. 이번 acceptance는 이 기능이 있는 것처럼 주장하지 않고 synchro level로 차이 검출·복원을 검증했다.

### 9. fresh refetch 미실행

마지막 zero-diff는 snapshot UID와 capture time을 새 observation으로 만들되 동일 canonical sanitized draft를 사용한 결과다. 즉 idempotent source comparison을 검증한 것이지, 외부 source가 실제로 변하지 않았음을 새 네트워크 fetch로 증명한 것은 아니다.

따라서 `freshExternalRefetchPerformed=false`를 receipt에 명시했다.

## 실행 이력

| acceptance UID | 결과 | 관측된 단계 |
|---|---|---|
| `bcf5154e-ca44-450a-b3a5-ed9efaf5c888` | failed | sandbox PostgreSQL start 제한 |
| `bfde8acb-8ca7-42df-a11b-d5039cebdf76` | failed | account create의 capability mismatch |
| `ed12bd9e-4b31-46ea-804b-8480b4e2168d` | failed | source-free draft/snapshot 보존 후 같은 mismatch 재현 |
| `071ddf2a-d587-42fa-a50d-0a7f946021dd` | failed | `core_level:not_applicable:29`로 원인 확정 |
| `777be34a-4547-40a7-a195-4ef97aff9b92` | failed | incomplete snapshot current-pointer NULL 결함 확정 |
| `f470fdd1-785e-483e-a6c5-9c839a34c631` | passed | 동일 캡처 diff/apply/recompare 완료, fresh refetch pending |

실패 receipt도 삭제하지 않았다. 실패가 어떤 경계에서 발생했는지 재현 가능한 source-free 감사 이력으로 보존한다.

## 최종 acceptance 증거

artifact root:

`artifacts/automation/phase-c-operator/f470fdd1-785e-483e-a6c5-9c839a34c631/`

| 파일 | byte length | SHA-256 |
|---|---:|---|
| `sanitized-profile.draft.json` | 430496 | `f0803b74fea24e83df07a88080fcecc11c5a23bc3837c78a8a87ce72dc11afb3` |
| `fetched-account.snapshot.json` | 283870 | `fdc3e56356d3a87497cbb0522e6c42d51c84dfc9fbd341c71857495382a94ebb` |
| `operator-acceptance.receipt.json` | 973 | `3a57c6c678a9423be0057df280e677478780b10dfe9dc5d93aeffc7242b1527f` |
| `orchestration.receipt.json` | 875 | `bf0728a67863bd0b608e7aedd0a4402696b7e9076c67c6172649e8c1b99f9673` |

수정 후 기존 complete/incomplete current-pointer 정책을 별도 합성 live PostgreSQL acceptance로 다시 검증했다.

- live acceptance UID: `f0d38b3e-9082-434c-acf6-d12e4fa1ea82`
- live receipt SHA-256: `5dbd17f5f0d4f643e4d5426a47eab85d078f10e2a0ddbbdae79e35201a521e02`
- final Phase C verification UID: `37c64522-9cf7-4104-842c-28ede8b11b94`
- final verification receipt SHA-256: `9a3f616ebfe9f787bc07278066e7720885f4697155e698883ec86b6d646105d9`
- final verification verdict: `phase_c_operator_same_capture_verified_fresh_refetch_pending`

최종 operator receipt의 핵심 관측값은 다음과 같다.

- source synchro level: `771`
- local edit synchro level: `772`
- detected diff count: `1`
- selected apply restored source value: `true`
- same-capture second observation diff count: `0`
- fresh external refetch performed: `false`
- cleanup verified: `true`
- Golden modified: `false`
- game runtime modified: `false`

## 다음 작업

1. commander level을 fetched basic info에서 lobby presentation diff/apply로 연결한다.
2. unresolved bond 9건과 equipment manufacturer match 312건을 operator review/override 대상으로 표시한다.
3. Control Center 브라우저 UI에서 register → diff preview → selective apply를 직접 검증한다.
4. 현재 roster/detail `193`과 과거 UI `198` 차이는 임의 보정하지 않고 다음 독립 fetch에서 다시 관측한다.
5. `StageClearHistorys`를 별도 관측할 수 있는 source가 확인될 때만 `unavailable`을 해소한다.

## 2026-08-29 progression v2 후속 구현

`FetchedProgressionObservation/v1`의 네 개 aggregate만으로는 `StageClearHistorys`와 `Triggers`를 표현하거나 관측값과 정적 파생값을 구분할 수 없었다. v1 호환성을 유지한 채 `FetchedProgressionObservation/v2`를 추가했다.

v2는 `CompletedScenarios`, `MainQuestData`, `ContentsOpenUnlocked`, `StageClearHistorys`, `Triggers`를 고정 구성요소로 가지며 각 구성요소에 `observed`, `derived`, `unavailable` 상태, evidence code, item count, canonical entry hash를 기록한다. 원본 ID는 저장하지 않고 local identity secret으로 파생한 source-free UUID만 저장한다.

보존된 2026-08-26 source를 read-only로 처리한 결과는 다음과 같다.

| dataset | provenance | count |
|---|---|---:|
| `CompletedScenarios` | `derived` static scenario closure | 611 |
| `MainQuestData` | `observed` trigger + reward attestation | 595 |
| `ContentsOpenUnlocked` | `derived` static unlock projection | 73 |
| `StageClearHistorys` | `unavailable` | null |
| `Triggers` | `observed` selected trigger cache | 4786 |

main quest reward claimed count는 595다. candidate의 main quest 및 trigger UID closure가 private source와 정확히 일치하지 않으면 materialization은 중단한다. source-free artifact에서 `questId`, `conditionId`, raw path, credential 관련 필드가 남지 않았음을 검사했다.

이 자료는 8월 29일 account snapshot보다 사흘 이전의 capture이므로 같은 snapshot에 병합하지 않았다. v2 sidecar의 `snapshotUid`가 account snapshot UID와 다르면 CLI가 거부하도록 검증했고 실제 cross-capture 결박 시도도 exit code 1로 거부됐다. historical read-only acceptance UID는 `1d689f54-4d8b-453f-b0f0-ef0ded6133eb`이다.

따라서 현재 snapshot의 상태는 그대로다. `progression_summary_missing`을 실제로 해소하려면 새 account fetch와 동일 시점에 progression source를 다시 관측해야 한다. Golden, game runtime, DB와 공식 서비스는 이 작업에서 변경하거나 실행하지 않았다.

회귀 검증은 ProfileImport 40개, Admin API 25개, migration shape 2개 시험과 editor JavaScript 문법 검사를 모두 통과했다. Phase C verification UID는 `68396a89-b272-4cc7-a39b-52b260b9c332`, receipt SHA-256은 `a71b52e5b268cd18cdf83581e1d257faf35fb4eb3bc1c83f53e8192c00cd2715`다.

## 2026-08-29 progression v2 저장·Control Center 후속 구현

`V0010__fetched_progression_observation.sql`은 canonical v2 observation을 parent fetched snapshot UID에 1:1로 결박해 보관한다. 테이블은 source-free 다섯 flag를 모두 `false`로 강제하고, capture time·completeness·component 집계·canonical JSON/SHA-256을 immutable하게 저장한다. 이 migration은 profile/account game revision을 갱신하지 않는다.

Admin API와 Control Center에는 선택적인 `FetchedProgressionObservation/v2` 입력을 추가했다. 서비스는 다음 조건을 모두 통과한 경우에만 snapshot과 같은 transaction으로 저장한다.

- canonical byte 재인코딩 일치
- snapshot UID 및 `capturedAtUtc` exact match
- snapshot v1 summary의 main-quest hash/count, completed-scenario count, contents-open count parity
- v2 detailed reason code가 snapshot completeness에 보존됨
- raw source/path/hash, official identifier, credential/session 비영속

Windows-native PostgreSQL `17.11` live acceptance에서 snapshot `3`, sidecar `1`, current pointer `1`을 관측했다. sidecar projection은 available/derived/unavailable `2/2/1`, scenario `3`, main quest completed/reward `2/2`, content `1`, stage history `null`, trigger `2`였고 API 재조회와 일치했다. 잘못된 snapshot UID sidecar는 거부됐으며 replay는 idempotent했다. acceptance UID는 `d3aff07f-6551-4351-bcf1-b01fdcd60923`, receipt SHA-256은 `fdf73809641f983db66e3fba5eef0689cb48db08554387ad38698f34f2d73bc3`다.

첫 sandbox 실행은 PostgreSQL restricted-token 재실행 실패(`error code 87/3`)로 start 단계에서 중단됐고 자동 cleanup 뒤 process/listener `0`을 확인했다. 승인된 일반 사용자 실행은 통과했으며 종료 후에도 process/listener `0`이었다. Golden, Micron runtime, client, hosts와 공식 서비스는 변경하거나 실행하지 않았다.

이 결과는 v2 저장 경로가 준비됐다는 뜻이다. 2026-08-26 historical progression을 2026-08-29 current snapshot에 합쳤다는 뜻은 아니다. 실제 `progression_summary_missing` 해소는 fresh account fetch와 progression fetch를 같은 capture UID·시각으로 다시 수집한 뒤 수행한다.

V0010 저장 guard, ProfileImport `40`, Admin API `25`, migration shape `3`, editor JavaScript와 live receipt를 포함한 종합 verification UID는 `bf04bd42-a1fa-43d4-86d3-a73752984821`다. receipt SHA-256은 `55a8eaa8e000dccaf676a474c9a5f65d86148b52528b872be7a04cec105d3e32`이며 verdict는 `phase_c_operator_same_capture_verified_fresh_refetch_pending`이다.

## 2026-08-29 fresh same-capture 입력 gate와 orchestration

fresh refetch를 단순히 “새 파일로 보임”으로 판정하지 않는다. `test-nll-phase-c-same-capture-inputs.ps1`은 client/runtime가 cold인 시각에 `PhaseCSameCaptureRequest/v1`을 먼저 만들고, 다음 두 입력이 모두 그 요청 시각 이후에 생성됐을 때만 진행한다.

- 운영자가 별도로 생성한 account raw fetch
- 그 raw 안의 계정 표식과 정확히 하나만 대응하는 `NKSD_TRIGGER_*` archive

검사는 raw/trigger path·hash·공식 user identifier를 receipt에 남기지 않는다. raw의 `GetUserProfileBasicInfo` shape, trigger freshness와 1:1 계정 대응, parent progression seal, parent Golden DB, exact StaticData pack, runtime cold를 한 번에 검사한다. Local Lab은 공식 로그인, fetch 또는 client 실행을 자동화하지 않는다.

현재 Micron 상태를 새 요청 UID `0fec2eb5-c27d-4d4d-a9d6-06252c16574e`로 검사한 결과는 `same_capture_inputs_blocked`다. 차단 이유는 정확히 다음 세 개다.

- `raw_fetch_predates_request`
- `trigger_archive_missing`
- `fresh_trigger_archive_match_not_unique`

초기 gate에는 입력 기본 경로 결함이 두 개 있었다. LocalLow를 `com.proximabeta`로 잘못 지정해 `trigger_archive_missing`을 허위 판정했고, raw fetch도 collector의 실제 출력이 아닌 이관 폴더의 오래된 복사본을 보고 있었다. 실제 trigger 경로는 `C:\Users\nlloperator\AppData\LocalLow\com_proximabeta\NIKKE`이며, 그 안의 `NKSD_TRIGGER_84_286780812096507422`는 존재하지만 마지막 기록 시각이 2026-08-28이라 현재 2026-08-29 capture request보다 오래됐다. `getFromBlaLink.py`의 실제 raw 출력은 `C:\Users\nlloperator\Database\raw\nikke_full_scroll_result.json`이며 fresh fetch 전에는 아직 존재하지 않는다. 두 기본 경로를 바로잡은 뒤의 차단 사유는 fresh raw 및 fresh matching trigger가 아직 요청 이후에 생성되지 않았다는 것으로 한정된다. parent progression seal SHA-256 `c4d5239f…`, parent DB `c103b44b…`, StaticData pack `8c0dfdca…`, runtime cold는 계속 통과한다.

fresh gate 통과 뒤에는 `invoke-nll-phase-c-operator-fetch-acceptance.ps1 -SameCaptureInputReceiptPath ...`가 gate를 즉시 재검사하고 다음 작업을 한 흐름으로 수행한다.

1. raw와 matching trigger archive에서 private progression source를 D: backup에 read-only 추출
2. parent progression Golden DB와 exact StaticData로 candidate를 임시 생성
3. 같은 snapshot UID로 `FetchedProgressionObservation/v2` materialize
4. 그 observation의 capture time을 account draft/snapshot에도 사용
5. `--progression-observation`으로 account snapshot과 v2 sidecar를 같은 transaction에 등록
6. 기존 local edit → fetched diff → selective apply → source 복귀 acceptance 재실행
7. disposable candidate/decoded StaticData/PostgreSQL을 정리

위 문단은 최초 fail-closed 상태의 역사 기록이다. 이후 운영자 판단에 따라 `NKSD_TRIGGER_*`는 이미 충분히 진행된 콘텐츠 해금 템플릿으로 분류했고, raw fetch만 fresh일 때 명시적으로 선택한 stable progression template을 재사용할 수 있도록 gate v2를 추가했다. 아래 최신 acceptance가 이 초기 차단 상태를 대체한다.

## 2026-08-29 stable progression template 최종 acceptance

완전 진행 archive `NKSD_TRIGGER_84_286780812096507422`를 운영자가 명시적으로 선택한 progression template으로 사용했다. freshness는 `reused_stable_progression`, 결박은 `operator_selected_progression_template`으로 receipt에 기록되며 자동 UID 일치로 위장하지 않는다. raw account fetch는 요청 이후의 fresh 입력이고 runtime은 cold였다.

첫 전체 실행에서는 progression 관측 materialization까지 성공했지만 account snapshot 결박이 `fetched_progression_observation_invalid`로 중단됐다. 원인은 데이터 completeness가 아니었다. extraction receipt의 원문 시각 `2026-08-29T08:18:52.977509...Z`를 PowerShell `ConvertFrom-Json`이 `DateTime`으로 만든 뒤 래퍼가 다시 `[string]`으로 변환하면서 문화권 기본 문자열이 소수 초를 버렸다. account snapshot에는 `08:18:52.000000Z`, progression sidecar에는 `08:18:52.977509Z`가 전달되어 exact capture-time binding이 실패했다.

래퍼는 이제 `([DateTimeOffset]$sourceReceipt.extractedAtUtc).ToUniversalTime()`으로 원래 tick을 보존한다. CLI도 canonical byte, snapshot UID, capture time 불일치를 서로 다른 오류 코드로 구분한다. 잘린 시각 재현은 `fetched_progression_observation_capture_time_mismatch`로 실패했고, 원래 소수 초를 사용한 동일 재현은 snapshot materialization에 성공했다.

최종 acceptance UID는 `02b8e6d4-c702-4103-97e3-f6659b3f6b76`이다. 관측 결과는 다음과 같다.

- roster/detail/snapshot character: `193/193/193`
- progression available/derived/unavailable: `2/2/1`
- completed scenarios: `611`
- main quests completed/reward claimed: `587/587`
- contents-open UI state: `71`
- selected unlock/progression triggers: `4773`
- `StageClearHistorys`: `unavailable`
- source/local-edit synchro level: `773/774`
- diff count: `1`, 선택 적용 뒤 source value 복원: `true`
- 같은 캡처 두 번째 observation diff: `0`
- PostgreSQL integration test: `1/1` passed
- 종료 후 postgres process/listener: `0/0`
- Golden/game runtime modified: `false/false`

artifact root는 `artifacts/automation/phase-c-operator/02b8e6d4-c702-4103-97e3-f6659b3f6b76/`이다.

| 파일 | byte length | SHA-256 |
|---|---:|---|
| `sanitized-profile.draft.json` | 430528 | `b699a7f5fefa026ccf3425042d34084e44ed9e10cbac7d7128164edc5a9e6596` |
| `fetched-account.snapshot.json` | 283965 | `e18e7b6e0e71cc62e16a958341063676688e4aeebf32f3c7463361221c5fa329` |
| `fetched-progression.observation.json` | 766906 | `54c739bbaafddb6b70f9de1e33c9e43619607499a8238f8feccf4e4fbcd9112e` |
| `operator-acceptance.receipt.json` | 1055 | `fcd7a81309e050572df36eadadf171686bf35e8c43347b463249fe8745c2afd1` |
| `orchestration.receipt.json` | 1124 | `85c5f17c06129f3543975a457f2a37ed7a224b717ed2f6ffe1a9ab8b5792943a` |

최종 verdict는 `phase_c_operator_fresh_same_capture_progression_acceptance_passed`다. `progression_summary_missing`은 해소됐으며 남은 incompleteness reason은 `profile_import_not_write_ready`, `stage_clear_historys_unavailable` 두 개다.

최종 회귀 verification UID는 `59a08290-e832-41ed-819f-dd75d1c6d290`, receipt SHA-256은 `61aa2608a840e1cba763f2b6d7f5c3329e56fb2c7e9f1ac37338f9659301a6ad`다. ProfileImport `40`, Admin API `25`, migration/shape `3` 시험이 모두 통과했으며 verification verdict는 `phase_c_operator_fresh_same_capture_progression_verified`다.

## 2026-08-29 commander projection 및 Control Center 브라우저 최종 acceptance

`FetchedAccountSnapshot/v1`의 basic-info에서 display name과 commander level을 projection에 노출했다. 별도 lobby diff/apply 경로는 `commander_level`, `display_name` 중 운영자가 선택한 필드만 비교·적용한다. diff는 대상 account, exact lobby revision, 선택 필드와 source 값을 SHA-256으로 결박한다. 적용 시 예상 diff hash와 revision이 모두 같아야 하며, 선택하지 않은 display name과 profile icon/frame, lobby character/background selection은 그대로 보존한다.

서비스/PostgreSQL acceptance에서 실제 source commander level `896`을 읽고 local lobby를 `897`로 만든 뒤 diff `1`건을 관측했다. `commander_level`만 선택 적용한 결과 `896`으로 복귀했고 나머지 lobby 필드는 바뀌지 않았다.

같은 경로를 실제 Control Center와 Playwright Chromium에서 다시 수행했다. `로그인 → account/local-state load → 896→897 저장 → 세 source-free 파일 등록 → commander diff preview → 선택 적용`이 통과했다. 첫 브라우저 시도에서 canonical snapshot, sanitized draft와 progression observation을 합친 POST가 약 1.48 MiB인데 Admin API 기본 상한이 1 MiB여서 `request_body_too_large` 및 `net::ERR_CONNECTION_RESET`이 발생했다. localhost Admin API의 기존 검증 가능 상한인 4 MiB로 기본값을 올렸고, 4 MiB 초과 차단은 유지했다.

최종 acceptance UID는 `f42acebe-6d82-4cc1-839f-e90b98406b4f`다.

- Control Center에서 snapshot 등록: `true`
- source/local commander: `896/897`
- commander diff: `1`
- selected apply: `true`
- unselected lobby fields preserved: `true`
- browser: `playwright_chromium`, headless
- browser receipt SHA-256: `ad40db35edee3458d0c55a1374e32ae89fb29cc143956f73542f8818efe8f902`
- screenshot SHA-256: `15073ae4637f65bd418dd8babd0c201dc1deb151bbbcced0de545b6f0e74f452`
- 종료 후 PostgreSQL process/listener: `0/0`
- Golden/game runtime modified: `false/false`

artifact root는 `artifacts/automation/phase-c-operator/f42acebe-6d82-4cc1-839f-e90b98406b4f/`다. 이 acceptance로 commander lobby projection과 실제 Control Center 등록·diff·선택 적용이라는 마지막 두 운영자 인수 항목을 닫는다. `StageClearHistorys`는 source unavailable로 계속 정직하게 보존하지만, 운영자가 별도로 확정한 stable progression template 재사용 조건과 충돌하지 않는다. Phase C의 다음 단계는 재구현이 아니라 Phase D 실행 프로그램이다.

최종 종합 verification UID는 `c4b9c6ec-3ca5-4c34-b4b9-e786b8be107f`, receipt SHA-256은 `5b2048681bbb2baa4707f50a9d50aa878131e305155f047cfaffcdcc0735e26b`다. ProfileImport `40`, Admin API `26`, migration/shape `3`, editor JavaScript, commander projection, 브라우저 receipt/screenshot hash 결박을 모두 통과했으며 verdict는 `phase_c_completed`다.
