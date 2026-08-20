# Implementation plan

최종 인수 조건은 **원본 NIKKE 클라이언트가 제한된 Local Lab private server에 접속하여 선언된 로비와 지원 Solo Raid Challenge를 원본 UI·asset·전투 runtime으로 실행하는 것**입니다. lab-owned harness, editor와 `Nikke-Dmg-Simulator`는 sidecar이며 최종 client를 대체하지 않습니다.

제품 UI와 서비스 정책의 권위는 [PRIVATE_SERVER_UI.md](PRIVATE_SERVER_UI.md)입니다.

## Phase 0 — 계약과 경계 — 완료

- 독립 저장소, Git 금지 데이터, 자체 ID와 read-only source 원칙을 고정했습니다.
- `CharacterBuildRevision`, `RaidSnapshot`, compatibility tier를 정의했습니다.
- `challenge-boss-support/v1`과 original-client fail-closed gate를 정의했습니다.
- Normal I~VII는 전투 없이 clear 상태만 투영하고 Challenge만 지원하는 범위를 정했습니다.

이 단계의 schema와 fixture는 역사적 완료 증거로 유지합니다. 후속 service state는 immutable `RaidSnapshot`에 역으로 넣지 않습니다.

## Phase 1 — 오프라인 catalog와 RaidSnapshot — 완료

- Phase 1A: import ledger, provenance, source read-only capability와 자체 identity
- Phase 1B: character definition/version catalog
- Phase 1C: 지원 시즌 `7, 13, 26, 29, 34, 40`의 immutable Challenge `RaidSnapshot`
- Phase 1D: Tier 9·10 equipment, cube, collection/favorite, console과 OL catalog

완료된 V0001~V0004와 compatibility tier는 그대로 유지합니다. RaidSnapshot readiness는 선언한 증거 tier의 publish readiness이지 원본 client 실행 readiness가 아닙니다.

## Phase 2A1 — local account/profile revision — 완료·재사용

- 자체 UUID `LocalAccount`와 최소 `LocalSession`
- immutable `AccountCombatStateRevision`
- immutable `CharacterBuildRevision`, 5인 `SquadRevision`과 `ProfileTemplateRevision`
- catalog exact membership, canonical hash와 readiness
- V0005 CAS Save, lineage, idempotency와 child sealing

방향 수정으로 V0005를 고치거나 완료 이력을 폐기하지 않습니다. 단일 `SquadRevision`은 한 팀의 정확한 입력이며 Solo Raid 전체 다섯 팀을 뜻하지 않습니다. `combat-semantics readiness`는 sidecar가 독립 계산에 필요한 의미의 완결성이고, 원본 client selection readiness나 Challenge run readiness와 분리합니다.

## Phase 2A2 — 관리 계층과 client-facing account projection — 완료

상태: 완료. 아래 완료 조건과 단위/live PostgreSQL gate를 모두 통과했습니다. 원본 client wire/UI 연결과 실제 전투 검증은 여전히 Phase 3·4 범위입니다.

### Offline profile ingress

- credential-bearing raw의 allowlist와 object shape를 함께 검증하는 strict offline sanitizer
- byte-canonical `nll/sanitized-profile-draft/v1`, source-free imported draft, diff와 provenance
- exact catalog preload를 쓰는 source-free CLI와 explicit level-authority policy
- raw draft와 분리된 `nll/profile-edit-candidate/v1`
- Save, Save As, local-account apply, source/base 없는 new-account create와 explicit typed rebase
- bond `0`/missing manufacturer를 원관측과 함께 Research/unresolved로 materialize하는 경로와 typed reviewed override
- identity/catalog membership/shape/coordinate/필수 level-authority 실패의 fail-closed 경계
- V0005 write와 V0006 lineage link 사이 interruption을 복구하는 immutable application intent
- loopback command API와 별도 editor

editor는 관리 sidecar이며 게임 UI를 대체하지 않습니다. Local Lab이 crawler, 공식 로그인 또는 authenticated replay를 실행하지 않습니다.

### Client-facing read model

- `LobbyPresentationRevision`: local display name, commander level과 profile presentation 선택
- `WalletRevision`: 로비에 표시할 synthetic local currency
- `ClientFeatureManifest`: supported, hidden, visible-no-op capability
- 니케 화면용 roster/build projection
- 스쿼드 화면용 저장 squad projection
- 인벤토리 화면용 **지원 전투 항목의 read-only projection**. equipment enhancement/manufacturer fact와 sparse OL `1..3` state/definition/exact value/unit을 포함합니다.
- 대원모집 `click_acknowledged_no_navigation`

현재 model을 완전한 원본 inventory라고 주장하지 않습니다. 원본 client가 inventory instance를 요구하면 공식 identity를 복사하지 않고 별도 lab-owned instance projection을 versioning합니다.

### 완료 조건

- 한 bootstrap read model이 profile, wallet, roster, squad, inventory subset과 feature manifest를 같은 revision set에 결박합니다.
- sanitizer와 API에 raw ID, 경로, credential과 공식 session이 없습니다.
- editor write는 새 immutable revision 또는 canonical idempotent reuse입니다.
- semantic unresolved와 materialization-blocking integrity failure가 분리되고 raw draft/editor candidate가 교차 사용되지 않습니다.
- 최초 account create와 V0005/V0006 interruption recovery, profile write 뒤 lobby revalidation을 live PostgreSQL에서 검증합니다.
- loopback Host/Origin/session/CSRF/strict-JSON/body-cap security와 source-free CLI receipt를 검증합니다.
- 이 단계는 원본 client wire/UI 연결 완료로 판정하지 않습니다.

## Phase 2B — private server boot, lobby와 영구 Solo Raid service

상태: 완료. source-free backend/harness가 아래 계약을 구현했고 `scripts/verify-phase2b.ps1` 단위/live PostgreSQL gate를 모두 통과했습니다. Phase 2B는 original-client wire/presentation/runtime 인수를 포함하지 않습니다.

### 2B1. Boot와 lobby service

- `실행 -> 로딩 -> 로컬 접속 -> 로비`를 위한 synthetic bootstrap/session 계약
- profile, wallet, roster, squad, inventory subset과 feature manifest 응답
- 미지원 route의 controlled hidden/no-op/not-supported 결과
- client build와 contract version 고정

### 2B2. Season directory와 daily state

- 모든 published 지원 시즌을 나열하는 `RaidSeasonCatalog`
- account/session별 `SelectedRaidSeason`
- 한 client 실행 context와 battle session에는 정확히 한 season snapshot 고정
- `NormalCombatCapability=unsupported`
- Normal I~VII clear, `lastClearLevel=7`, `challengeUnlocked=true`
- `SeasonAvailability=permanent`, `seasonEndsAt=null`
- `QuickBattleCapability=unsupported`
- `Asia/Seoul` 매일 `05:00:00` daily boundary

`raidDayKey`는 해당 instant를 KST로 바꾸고 5시간을 뺀 local date로 계산합니다. DB timestamp는 UTC로 저장하고 lazy idempotent rollover를 권위로 사용합니다. scheduler는 보조일 뿐입니다. attempt quota, 소비 시점과 05:00을 가로지르는 진행 중 run 처리는 별도 versioned policy로 확정하며 임의로 공식 기본값을 복사하지 않습니다.

checked-in 기본은 여섯 축이 모두 `unresolved`인 `challenge-operational-policy/unresolved/v1`입니다. 이 상태에서도 boot/lobby/directory/season selection과 Challenge unlock projection은 유지하지만 새 run은 fail closed합니다. 빈 DB의 초기 bootstrap은 여섯 축을 모두 명시한 configured policy를 현재 raid day에 활성화할 수 있고, 이후 관리자 전환은 CAS를 사용해 다음 raid day에만 예약합니다.

### 2B3. Challenge run

- exact raid snapshot, account state와 client/runtime/control profile admission
- 한 run에 순차적으로 1~5개 `SquadRevision` 결박
- run 전체에서 character 중복 금지
- open, team enter, `lab_harness_observation/v1`, regroup, close/result 상태기계
- 팀별 damage와 누적 damage, 사용 revision, telemetry와 warning 보존
- mock battle 지원 여부와 local ranking/result projection을 별도 capability로 versioning

원본 damage는 client runtime의 권위값입니다. Phase 2B backend는 original wire integer를 가정하지 않고 lab harness가 전달한 canonical nonnegative decimal receipt와 동일 run의 팀별 합계만 검증·저장합니다. boot는 `finalDamageAuthority=original_client_runtime`과 `originalRuntimeObservationStatus=blocked_by_gate`를 별도로 보존하며, Phase 3 adapter 전에 harness receipt를 original-runtime 증거로 승격하지 않습니다.

### 완료 조건

- 여섯 시즌이 동시에 영구 directory에 존재하고 선택만 한 시즌입니다.
- Challenge unlock projection은 신규 local account에서 즉시 열리며 Normal/Quick Battle 실행 route가 없습니다. Challenge run admission은 exact configured policy를 따릅니다.
- 04:59:59와 05:00:00 KST 경계, downtime 후 lazy reset과 동시 요청 idempotency를 검증합니다.
- 최대 다섯 팀과 run-wide 중복 금지, revision pinning과 결과 idempotency를 검증합니다.
- harness가 API/DB 계약을 통과해도 원본 client 완료로 표기하지 않습니다.

private-server access token 서명 key는 process-local입니다. 같은 API process의 같은 Open operation replay는 최초 token byte를 exact 재사용하지만, process restart 후에는 영속 session/context/issued/expires를 복원해도 token이 새 key로 재서명될 수 있습니다. durable signing key와 restart 간 token byte 동일성은 Phase 2B 범위가 아닙니다.

## Phase 3 — 승인된 original-client adapter와 선언 UI

### 3A. Compatibility gate

- 지원·승인된 local/test client route 또는 권리자가 제공한 개발·테스트 client 확인
- 공식 credential 없는 synthetic local session
- 공식 server와 telemetry outbound zero
- exact client build/hash와 adapter contract 고정
- endpoint/auth 변조, 주입·후킹, launcher/보호 기능 우회 없음

### 3B. Wire와 presentation adapter

- lab-owned UID와 client-local content reference의 Git 비추적 compatibility binding
- private-server bootstrap/profile/raid state를 원본 client wire shape에 투영
- 고정 lobby widget 숨김·재배치 capability 확인
- 좌측 multi-season folder, 영구 시즌 표시와 Quick Battle 제거
- Recruit click feedback 후 navigation 차단
- 원본 classic Solo Raid main/ready/battle/regroup/result view 연결

서버 응답만으로 고정 prefab을 재배치할 수 있다고 가정하지 않습니다. 승인된 UI override/variant 경로가 없으면 exact lobby 요구는 `blocked`입니다.

### 3C. End-to-end gate

- 실행부터 로비까지 공식 outbound 없이 도달
- 선언한 profile/wallet와 keep/remove/replace UI 일치
- season 선택 뒤 원본 Solo Raid 화면 진입
- 원본 battle runtime과 결과 화면 복귀

client build/hash가 바뀌면 route, presentation과 runtime compatibility를 모두 재평가합니다.

## Phase 4 — 사용자 실플레이 및 원본 runtime 검증

- 실행·로딩·로컬 접속·로비를 실제로 확인합니다.
- 니케·스쿼드·인벤토리와 Recruit no-op을 확인합니다.
- 여섯 시즌 선택, Normal I~VII clear, Challenge 즉시 개방, season timer/Quick Battle 부재를 확인합니다.
- 1~5팀 순차 전투, 사용 캐릭터 잠금과 재정비를 확인합니다.
- 원본 HUD/ESC damage, 팀별 result와 최종 누적 damage가 backend receipt와 일치하는지 확인합니다.
- 05:00 KST daily rollover를 경계 전후로 확인합니다.
- scene, behavior, QTE, part, animation과 timing을 `(client build, season, raid snapshot)`별로 증명합니다.

현재 증거 상한은 시즌 7·13·26·29·34가 `static_exact`, 시즌 40이 `behavior_exact`입니다. Phase 4 실플레이 이전에 여섯 시즌 모두 실제 runtime과 100% 같다고 선언하지 않습니다.

## 선택적 후속

사용자가 범위를 확장한 뒤에만 Union Raid나 다른 콘텐츠를 추가합니다. 상점, 모집, 캠페인, 타워, 아레나, Outpost와 공식 live-service economy는 계속 범위 밖입니다.

## 금지 사항

- 별도 simulator 또는 harness를 최종 원본-client 검증으로 대체하지 않습니다.
- backend가 원본 HUD damage를 재계산해 공급한다고 주장하지 않습니다.
- `RaidSnapshot ready`를 original-client/runtime exact와 동일시하지 않습니다.
- 한 `SquadRevision`을 다섯 팀 Challenge run 전체로 취급하지 않습니다.
- Normal clear 상태를 이유로 Quick Battle이 자동으로 사라진다고 가정하지 않습니다.
- 먼 미래 timestamp를 permanent season으로 사용하지 않습니다.
- 원본 ID, 경로, credential과 asset을 domain/API/log/Git에 노출하지 않습니다.
