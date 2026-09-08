# Phase 2A2 — offline profile ingress와 관리 read model

> 단계별 계약·검증 기준입니다. 이 문서의 과거 실행 판정과 현재 151 운영 상태를 구분합니다. 현행 진척은 [인계 요약](../HANDOFF.md), 작업 우선순위는 [안정화 계획](../STABILIZATION_PLAN.md)을 확인합니다.

상태: **완료**

Phase 2A2는 원본 게임 UI가 아니라 Local Lab을 관리하는 sidecar 계층입니다. credential-bearing raw capture에서 허용된 전투 관측만 오프라인으로 정규화하고, 자체 UID만 포함한 immutable draft를 명시적 preview/diff/write 흐름으로 Phase 2A1의 profile revision에 연결합니다. 같은 단계에서 로비에 필요한 synthetic presentation, wallet, feature capability와 제한된 roster/squad/inventory read model을 제공합니다.

이 단계의 완료는 original-client wire/UI 연결이나 실제 전투 검증을 뜻하지 않습니다. boot/lobby와 영구 Solo Raid service는 Phase 2B, operator-authorized compatibility와 시즌 26 one-team live proof/observation sealing은 Phase 3, 1~5팀 actual-play와 full runtime parity는 Phase 4 범위입니다.

## 입력 경계와 운영 진입점

Local Lab은 crawler, 브라우저 로그인, request interception 또는 authenticated replay를 실행하지 않습니다. 사용자가 저장소 밖에서 갱신한 raw capture를 read-only stream으로 한 번 읽을 수 있을 뿐입니다.

Sanitizer allowlist는 다음 payload로 제한합니다.

- roster의 character observation
- character detail의 investment, skill, 네 장비 slot, sparse OL line, cube와 collectible observation
- 같은 detail packet에 포함된 OL state-effect dictionary
- outpost의 synchro level과 정확히 아홉 console level/EXP

root account UID, token, open identifier, endpoint URL, request/response envelope, trace, social/profile/outpost 비전투 field는 결과 모델, canonical hash, DB, API, diagnostic와 log에 전달하지 않습니다. credential-bearing raw file의 hash, path, mtime과 byte length도 영속 provenance로 사용하지 않습니다.

운영 CLI 경계는 다음처럼 고정합니다.

- raw 경로는 환경 변수 `NIKKE_LAB_PROFILE_RAW`에서만 읽습니다. CLI argument, editor, HTTP upload와 raw-path API로 받지 않습니다.
- raw 파일은 repository와 runtime root 밖의 regular file이어야 하며 symlink/junction/reparse point를 fail closed 처리합니다.
- `profile-source-inspect`는 roster/detail, 네 slot, sparse OL과 아홉 console의 aggregate coverage만 출력합니다.
- `profile-draft-import`는 현재 exact character/combat-support catalog를 완전히 preload한 resolver만 사용합니다. ad-hoc SQL, name matching과 sync-over-async lookup을 허용하지 않습니다.
- import는 `--level-authority roster_observation/v1|detail_observation/v1`를 명시적으로 요구하고 transformer binary SHA-256을 provenance에 결박합니다.
- HMAC identity secret은 메모리에서만 사용하고 작업 종료 시 byte buffer를 지웁니다.
- 성공 receipt에는 Local Lab UID, catalog binding, sanitized/canonical hash와 aggregate count만 씁니다. raw path, source identifier, alias fingerprint, credential과 원문 diagnostic을 출력하지 않습니다.

## Strict raw parser와 canonical draft codec

recognized payload는 allowlist field만 고르는 느슨한 parser가 아닙니다. 선택한 packet/root/object마다 허용·필수 property, JSON kind, 정수 범위, 배열 cardinality와 좌표를 검사합니다. unknown 또는 duplicate property, 잘못된 shape/type/range, roster/detail coverage 불일치, 중복 character identity, 잘못된 slot/console 좌표와 같은 입력은 controlled aggregate diagnostic으로 실패하며 원문 값을 echo하지 않습니다.

OL은 장비 slot 네 개와 line `1..3`의 고정 좌표로 정규화합니다. `{1, 3}` 같은 hole을 보존하고 line을 압축하거나 재번호화하지 않습니다. option reference는 반드시 **같은 detail packet**의 state-effect dictionary와 exact catalog legal-value member에서 해소합니다. 다른 packet의 같은 source reference를 대신 사용하지 않습니다.

Draft wire identifier는 `nll/sanitized-profile-draft/v1`입니다. decoder는 다음을 모두 재검증합니다.

- canonical property set/order와 byte representation
- unknown/duplicate property 부재
- size, depth, collection count와 character/catalog cap
- 자체 UID, controlled code, exact decimal과 fact shape
- raw sanitizer, catalog rebase, reviewed override 중 알려진 transformer profile
- schema/transformer/options/payload hash와 파생 readiness의 재계산 결과

따라서 generic serializer shape, 앞뒤 whitespace를 포함한 non-canonical JSON, 변조된 hash/readiness와 editor candidate를 sanitized draft로 읽지 않습니다. `Decode(Encode(draft))`는 같은 canonical byte를 만들어야 하며 DB에는 이 strict round-trip을 통과한 payload만 저장합니다.

## 관측, level authority와 readiness

Roster와 detail의 level은 서로 다른 관측입니다. 다음 세 값을 항상 별도 보존합니다.

- `RosterLevelObservation`
- `DetailLevelObservation`
- `ResolvedBattleLevel`

기본 `ResolvedBattleLevel`은 `unresolved(level_authority_not_selected)`입니다. 두 관측이 같아도 암묵적으로 하나를 고르지 않습니다. `full_profile` 또는 `builds_only`를 materialize하는 preview/write와 신규 계정 생성은 `roster_observation/v1` 또는 `detail_observation/v1`를 명시해야 하며, 선택 뒤에도 두 원관측을 삭제하지 않습니다. 대상 build를 바꾸지 않는 `account_state_only` apply는 `unresolved/no_apply` level policy를 허용할 수 있습니다.

미해결은 다음 두 부류로 분리합니다.

### 보존 가능한 의미 미해결

- raw bond observation `0`의 의미가 확정되지 않음
- 장비 manufacturer observation이 없음

이 두 경우에는 관측값과 controlled reason을 그대로 보존합니다. 다른 identity, catalog member와 좌표가 완전하고 build level authority가 선택됐다면 draft의 `CanMaterializeLocalAccountProfile`은 `true`일 수 있습니다. 다만 `IsLocalAccountProfileWriteReady`는 `false`이며, materialized V0005 build는 `research` validation과 해당 field의 `unresolved` fact를 가져 selection/game-legal readiness가 낮아집니다. 이를 `0` 또는 `false`로 바꾸지 않습니다.

사용자가 실제 근거를 검토했다면 bond level 또는 equipment manufacturer-match에 한정된 typed reviewed override를 새 immutable derived draft로 만들 수 있습니다. override는 원관측과 원 reason을 유지하고, `user_reviewed_override` 또는 `original_client_verified_override` reason과 canonical provenance를 추가합니다. 임의 field를 문자열로 덮어쓰는 범용 escape hatch는 아닙니다.

### Materialization 차단 실패

- character 또는 combat-support alias가 missing/ambiguous/catalog-mismatch 상태
- exact catalog snapshot member, definition/version 또는 typed rebase mapping이 없음
- roster/detail identity·coverage, 장비 slot, OL line, console coordinate 또는 payload shape가 불일치
- same-packet OL state-effect와 legal value를 해소할 수 없음
- 확인된 type/range/cap/catalog 관계 위반
- build를 교체하면서 level authority를 선택하지 않음

이 경우 `CanMaterializeLocalAccountProfile=false`이거나 sanitizer 자체가 실패하며 profile write command를 만들지 않습니다. 보존 가능한 의미 미해결과 identity/shape 무결성 실패를 같은 `unresolved` 규칙으로 취급하지 않습니다.

## Immutable derivation과 provenance

영속 provenance는 source-free 정보만 포함합니다.

- sanitized payload SHA-256과 allowlist schema fingerprint
- transformer identifier/version/binary hash/options hash
- exact dual-catalog snapshot/dataset/manifest binding
- import timestamp와 immutable predecessor/rebase 관계

동일 canonical payload는 idempotent reuse합니다. 새 capture의 변경은 새 draft와 diff를 만들며 기존 local edit를 자동 덮어쓰지 않습니다.

Catalog rebase는 target character/combat-support binding과 reviewed **typed source-free UID mapping**을 명시적으로 받습니다. 이름·표시 문자열·source ID로 자동 매칭하지 않으며, 참조한 모든 definition이 target snapshot의 exact member인지 확인한 뒤 semantic option, readiness와 canonical hash를 다시 계산합니다. preview hash를 확인한 뒤에만 predecessor를 가진 새 rebase draft를 저장합니다.

Raw sanitized draft와 editor candidate는 서로 다른 계약입니다.

- raw/rebase/reviewed-override 결과만 `nll/sanitized-profile-draft/v1` codec과 raw provenance를 사용합니다.
- scalar editor preview는 `nll/profile-edit-candidate/v1`의 canonical operation 문서로 저장합니다.
- editor candidate는 exact account/base profile revision과 `0..512`개의 정렬된 typed operation을 결박합니다. 같은 `(fieldCode, subjectUid)` 좌표의 중복은 거부합니다.
- diff row는 sanitized draft 또는 editor candidate 중 정확히 하나를 참조합니다.
- editor operation에 없는 validation mode, materialization policy, origin, `not_applicable`와 unresolved reason은 exact base에서 그대로 보존합니다. 예외적으로 `bond_level`과 `equipment.*.manufacturer_matched`는 `controlled/not_applicable` 연산을 지원하며, R 등급 호감도와 T10/오버로드 기업 비적용 여부를 exact catalog로 다시 검증한 뒤에만 저장합니다.
- 모든 operation을 좌표별로 staging한 뒤 각 immutable aggregate를 한 번만 구성합니다. 입력 순서에 따른 last-write-wins를 허용하지 않습니다.

빈 editor operation preview는 no-change `Save As` clone에 사용할 수 있습니다. 같은 account의 `Save`가 current content와 같으면 Phase 2A1의 canonical current revision을 재사용합니다.

## Preview, write와 신규 account 생성

모든 write는 `operationUid`, immutable candidate/draft UID와 hash, preview diff SHA-256 및 expected current revision을 명시합니다. HTTP command는 이 expected revision을 `If-Match`에도 결박합니다. stale revision, 바뀐 draft/candidate 또는 달라진 preview hash는 덮어쓰지 않고 controlled conflict로 실패합니다.

- `Save`: editor candidate를 같은 account의 새 immutable revision 또는 canonical reuse로 적용합니다.
- `Save As`: exact source/base와 candidate를 새 Local Lab account/profile revision 1로 복제합니다.
- `Apply`: `full_profile`, `builds_only`, `account_state_only` 중 명시한 scope만 기존 Local Lab account에 적용합니다.
- `Create from import`: target account가 없는 별도 create-preview/create command입니다. `full_profile`과 explicit level authority만 허용하며 V0005 `CreateAsync`로 최초 LocalAccount/profile revision을 만듭니다. 기존 account apply/save-as에 암묵적으로 overload하지 않습니다.
- `Rebase`: typed target catalog binding과 explicit mapping으로 새 sanitized draft를 만들 뿐 기존 current profile을 자동 변경하지 않습니다.

build 집합을 바꿀 때 기존 squad의 다섯 character UID가 모두 새 profile에 남아 있을 때만 squad를 보존합니다. 하나라도 빠지면 잘못된 squad를 추측해 고치지 않고 제거합니다.

### V0005/V0006 application recovery

Profile write와 V0006 lineage link 사이의 process 종료가 untracked profile revision을 영구히 남기면 안 됩니다. application 계약은 다음 순서를 사용합니다.

1. exact candidate/draft와 sealed diff를 확인합니다.
2. `application_uid`, request hash, application kind, diff와 예정된 V0005 `profile_write_operation_uid`를 immutable application intent로 먼저 저장합니다.
3. 같은 operation UID로 V0005 CAS/Create write를 실행합니다.
4. write operation의 source/result topology를 검증한 뒤 completed application row를 seal합니다.
5. 같은 request replay는 completed row를 재사용합니다. intent만 있고 V0005 write가 이미 끝난 경우에는 그 exact write를 찾아 application link를 복구합니다. request hash, diff, kind 또는 topology가 다르면 fail closed합니다.

`apply|rebase`는 같은 account/base에서 같은 account result로, `save_as`는 source/base에서 다른 account result로, `create`는 source/base가 없는 새 account result로만 연결됩니다. pending intent는 삭제하거나 다른 write에 재사용하지 않습니다. live PostgreSQL 검사는 intent 직후와 V0005 write 직후의 interruption을 각각 재현하여 replay가 중복 revision 없이 하나의 completed application으로 수렴하는지 확인해야 합니다.

Profile write 뒤 기존 lobby revision의 `validated_profile_revision`도 stale 상태로 남기지 않습니다. profile current-pointer 승격과 같은 PostgreSQL transaction의 trigger가 같은 lobby content를 새 profile에 재검증하고 새 lobby revision으로 승격합니다. ready lobby character가 새 roster에 없거나 재검증에 실패하면 profile write 전체를 원자적으로 rollback하므로 별도 pending lobby 상태를 만들지 않습니다. 같은 V0005 operation replay는 profile pointer가 다시 바뀌지 않아 lobby revision도 중복 생성하지 않습니다.

## Client-facing local state와 bootstrap

V0001~V0005를 수정하지 않고 V0006 additive migration으로 다음 aggregate를 추가합니다.

- `LobbyPresentationRevision`: NFC local display name, commander level, lobby character와 lab-owned presentation selection
- `WalletRevision`: 정확히 synthetic `jewel`, `credit` 두 nonnegative balance
- `ClientFeatureManifest`: route별 `supported|hidden|visible_no_op|not_supported`
- `SanitizedProfileDraft`, `ProfileEditCandidate`, diff, application intent와 completed application ledger

프로필 아이콘·프레임·배경은 원본 asset을 복사한 값이 아니라 lab-owned selection UID입니다. Phase 3의 build-pinned local compatibility adapter가 client-local asset reference로 변환하기 전에는 `presentation_binding_unresolved`일 수 있습니다.

신규 profile 생성과 lobby/wallet/feature initialization은 별도 명시적 command입니다. bootstrap query가 값을 조용히 생성하거나 임의 default를 선택하지 않습니다. initialization은 exact current profile과 published feature manifest를 조건으로 lobby와 wallet revision 1을 한 번 생성하고, operation replay만 idempotent하게 허용합니다.

Bootstrap은 current profile/account-state, lobby, wallet, feature manifest, roster/build, optional squad와 inventory subset을 하나의 `revisionSetSha256`에 결박합니다. lobby가 검증한 profile revision과 current profile이 다르면 성공 응답을 만들지 않습니다.

Inventory는 `equipped_combat_items_v1` read-only subset이며 `isCompleteInventory=false`입니다. 공식 계정 inventory나 official instance UID를 복제하지 않습니다. 그래도 current profile의 전투 입력을 축약해서는 안 되므로 다음을 lossless하게 투영합니다.

- equipment: slot/state, lab-owned projection UID, definition/version, enhancement fact와 manufacturer-match fact
- OL: 각 slot의 line `1..3` present/absent state, option definition, exact unscaled value/scale와 unit
- cube와 collection/favorite: state/kind, definition/version와 level fact

Roster와 squad도 문자열 summary가 아니라 자체 UID와 exact build/squad revision을 가진 typed projection으로 반환합니다.

## Loopback 관리 API와 editor

관리 API는 `127.0.0.1`에만 bind하고 LAN 및 official outbound를 허용하지 않습니다. 정적 editor는 같은 origin에서 제공하며 CDN, inline script/style, raw file upload와 raw path API를 사용하지 않습니다.

Browser admin session은 게임 `LocalSession`과 분리합니다.

- host가 한 번만 전달하는 256-bit bootstrap code는 짧은 수명과 제한된 시도 횟수를 가지며 성공 후 재사용할 수 없습니다. 현재 production composition은 시작 프로세스의 로컬 운영자 터미널(`stderr`)에 한 번만 표시하며 redirect·수집·영속 log 저장을 지원하지 않습니다.
- 교환된 process-local admin session은 HttpOnly, `SameSite=Strict` cookie를 사용하고 영속 credential로 저장하지 않습니다.
- write는 exact loopback remote/local address와 Host/port, exact Origin, antiforgery header/cookie, strict JSON content type와 body-size cap을 검사합니다.
- JSON은 duplicate property, trailing/noncanonical integer와 계약 밖 field를 fail closed 처리합니다.
- profile/local-state mutation은 `operationUid`와 endpoint별 `If-Match`를 요구합니다. candidate/draft를 적용하는 command는 expected candidate/draft hash와 preview diff hash도 함께 검증합니다.
- 응답에는 CSP, no-store, nosniff, frame/embedding 제한과 same-origin isolation header를 적용합니다.
- 오류는 controlled code와 trace UID만 반환하며 DB exception, connection string, path, raw value와 stack trace를 response/log에 넣지 않습니다.

Editor는 source-free draft UID의 observation/value/issue와 diff만 조회합니다. 여러 typed edit operation을 한 preview에 넣을 수 있고, create/apply/rebase는 각각 별도 preview hash를 확인한 뒤 실행합니다. editor는 PostgreSQL을 직접 수정하지 않으며 원본 NIKKE lobby/니케/스쿼드/인벤토리/Solo Raid 화면의 대체 UI가 아닙니다.

portable profile export는 현재 Phase 2A2 완료 범위가 아닙니다. 구체적인 소비자와 배포 경계가 정해지기 전에는 source-free Save As, sanitized draft import와 immutable rebase만 제공합니다.

## 완료 조건

- synthetic raw에서 allowlist만 남고 credential canary, path, source ID와 alias fingerprint가 public surface·DB·log에 없습니다.
- strict raw parser와 canonical codec이 unknown/duplicate/noncanonical/tampered payload를 controlled failure로 거부합니다.
- 현재 read-only raw smoke가 roster/detail coverage, 네 slot, sparse OL, same-packet state effect와 아홉 console을 손실 없이 통과합니다.
- 두 explicit level policy가 결정적인 서로 다른 materialization을 만들고, build를 바꾸는 unresolved authority는 write되지 않습니다.
- R 등급의 bond 관측 `0`은 `not_applicable`로 materialize합니다. T10/오버로드 장비의 manufacturer는 `not_applicable`입니다. T9에서 별도 manufacturer code가 비어 있어도 선택 장비와 캐릭터의 exact catalog manufacturer가 모두 ready이면 일치 여부를 계산합니다. 선택 T9 장비의 catalog manufacturer가 `not_applicable`이면 일반 무기업 장비로 확정하고 match fact도 `not_applicable`로 저장하며, 이 catalog 결합까지 불가능할 때만 Research/unresolved로 보존합니다. 기존 revision의 잘못된 적용성 fact는 current-based editor candidate로 새 immutable revision을 만들어 보정합니다.
- identity/catalog membership/shape/coordinate/range 실패는 profile write 전에 fail closed합니다.
- raw sanitized draft와 editor candidate가 codec, provenance, table reference와 replay에서 교차 사용되지 않습니다.
- create-preview/create가 빈 DB의 최초 LocalAccount/profile을 source/base 없는 typed lineage로 만듭니다.
- V0006 CAS/idempotency, immutable child sealing, typed rebase, application interruption recovery와 lobby revalidation을 live PostgreSQL에서 검증합니다.
- bootstrap이 같은 revision set의 profile/lobby/wallet/feature/roster/squad/inventory를 반환하고 inventory가 manufacturer/OL exact 값을 손실하지 않습니다.
- loopback API security negative test와 editor no-CDN/no-inline/no-raw contract가 통과합니다.
- source-free `profile-draft-import` receipt와 operation replay가 통과합니다.
- Phase 2A1과 기존 catalog/unit/PostgreSQL 검사가 회귀 없이 통과합니다.

이 revision은 위 단위 gate와 V0001~V0006 전체 live PostgreSQL integration gate를 모두 통과해 Phase 2A2 완료로 판정했습니다. portable profile export, private-server boot/Solo Raid runtime, original-client wire/UI adapter와 실제 damage/HUD/result 플레이 검증은 완료 범위에 포함하지 않습니다.
