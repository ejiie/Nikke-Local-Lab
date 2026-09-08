# Phase 2B — private-server state와 Challenge 실행

> 단계별 계약·검증 기준입니다. 이 문서의 과거 실행 판정과 현재 151 운영 상태를 구분합니다. 현행 진척은 [인계 요약](../HANDOFF.md), 작업 우선순위는 [안정화 계획](../STABILIZATION_PLAN.md)을 확인합니다.

상태: 완료

Phase 2B는 원본 NIKKE client에 연결될 **source-free local backend 계약**과 이를 검증하는 lab-owned harness를 구현합니다. 원본 client wire, lobby prefab 또는 실제 전투 runtime을 흉내 낸다고 주장하지 않습니다. 그 연결은 [PHASE3AR.md](PHASE3AR.md)의 operator-authorized disposable-local 경계와 [FEASIBILITY_GATES.md](FEASIBILITY_GATES.md)를 따릅니다. Phase 3B-2가 시즌 26 one-team live proof를, Phase 3C/3D가 최소 observation adapter와 exact identity sealing을 소유하며, Phase 4는 이를 1~5팀·full telemetry/recovery parity로 확장합니다.

## 불변 범위

- published season directory v1은 season `7, 13, 26, 29, 34, 40`의 exact `RaidSnapshot` 여섯 개입니다.
- 모든 directory member는 permanent이고 `seasonEndsAt=null`입니다.
- 한 account/session client context와 한 Challenge run은 정확히 한 selected season snapshot에 결박됩니다.
- Normal I~VII는 전투 없이 `lastClearLevel=7`인 unlock compatibility state만 제공합니다.
- Challenge는 기본 개방 상태입니다.
- Normal battle/Quick Battle의 실행·reward·persistence는 만들지 않으며, lab API의 해당 guard route는 상태 검증 뒤 controlled unsupported만 반환합니다.
- operational day는 instant를 `Asia/Seoul`로 변환하고 5시간을 뺀 local date입니다. 경계는 매일 `05:00:00`입니다.
- profile/build, selected season, published snapshot, runtime/control revision과 영구 result는 daily rollover로 변경하지 않습니다.
- original-client adapter와 presentation adaptation은 계속 blocked입니다.

## 추측하지 않는 운영 정책

정규 seasonal Solo Raid의 공개 자료에는 하루 3회 같은 일반 규칙이 알려져 있어도, 영구 여섯 시즌을 동시에 여는 Local Lab에 그대로 복사하면 새로운 의미가 생깁니다. 다음 축은 하나의 immutable, versioned `ChallengeOperationalPolicy`로 명시적으로 설정될 때만 admission-ready입니다.

- daily entry limit
- entry consumption point
- 05:00을 가로지르는 active run 처리
- counter가 season별인지 directory 전체 공유인지
- Mock Battle capability
- local ranking capability

configured policy가 수락하는 controlled value는 다음과 같습니다.

| 축 | 허용 값 | 핵심 의미 |
|---|---|---|
| daily entry limit | `1..1000000` | lab 자원 상한이며 공식 횟수를 암묵 복사하지 않음 |
| consumption point | `run_opened`, `first_team_entered`, `run_closed` | 첫 team enter는 ordinal 1에서만 소비; `run_closed`는 전투가 시작된 run의 abandon/recovery 정책도 일관되게 적용 |
| active run at reset | `pin_opening_raid_day`, `reject_post_boundary_progress` | pin은 05:00 후에도 opening day에 close/소비; reject는 post-boundary progress를 막지만 abandon/recovery는 허용 |
| counter scope | `per_season`, `shared_across_directory` | exact snapshot별 또는 six-season directory 공유 |
| Mock Battle | `unsupported`, `lab_owned_only` | lab-owned mock만 quota 검사/소비에서 제외 |
| local ranking | `unsupported`, `local_records_only` | 공식 ranking이 아닌 Local Lab record만 허용 |

checked-in 기본 설정은 `challenge-operational-policy/unresolved/v1`이고 모든 축이 `unresolved`입니다. 이 상태에서도 boot, lobby projection, directory 조회, season 선택과 `challengeUnlocked=true` 투영은 가능하지만 Challenge begin은 controlled `policy_unresolved`로 fail closed합니다. 운영자가 여섯 축과 versioned policy ID를 모두 명시하면 같은 source-free 구성 경계가 configured policy를 수락하지만, 일부 필드만 채우거나 기존 policy ID의 의미를 바꾸는 입력은 거부합니다. 예약된 `challenge-operational-policy/unresolved/v1` ID를 `configured`로 재사용하는 구성도 거부하며, configured policy는 자신의 새 non-reserved versioned ID를 가져야 합니다.

빈 DB의 초기 bootstrap은 source-free 구성으로 선택한 exact unresolved 또는 configured policy를 **현재 raid day**의 revision 1로 활성화합니다. 영속 activation head가 이미 있으면 restart config가 그 이력을 조용히 덮어쓰지 않습니다. 운영 중 admin 경계는 여섯 축이 완전한 새 immutable policy를 먼저 publish하고 current activation revision CAS를 검증한 뒤 **다음 raid day**로만 전환을 예약합니다. 같은 policy UID/ID에 다른 content를 연결하지 않습니다.

Mock Battle은 Quick Battle과 다른 operational-policy 축입니다. configured `unsupported`는 mock run을 거부하고, `lab_owned_only`는 Phase 2B harness에서만 mock run을 허용합니다. lab-owned mock은 daily quota가 이미 다 소비됐어도 열 수 있고 open/enter/close/abandon 어느 전이에서도 daily entry를 소비하지 않습니다. 이 계약은 Phase 3 UI에 Mock Battle button을 표시할 수 있다는 증거가 아닙니다. Quick Battle은 policy와 무관하게 항상 unsupported입니다.

## Boot와 client context

Phase 2A1 `LocalSession`과 Phase 2A2 bootstrap revision set을 재사용합니다. Phase 2B client context는 다음 exact revision을 고정합니다.

- local account와 active local session
- profile template revision과 roster/build/squad projection
- lobby presentation, wallet와 inventory-subset revision set
- Phase 2B feature/capability manifest와 그 manifest가 결박한 operational policy
- selected season directory revision과 `RaidSnapshot`

같은 `operationUid`의 lobby 진입을 재시도할 때는 context가 봉인한 profile/account-state/lobby/wallet/feature/squad component로 당시 bootstrap을 복원합니다. 이후 account current head가 바뀌어도 새 상태로 대체하지 않으며, 저장된 revision-set SHA를 다시 계산해 일치하지 않으면 fail closed합니다.

runtime execution과 combat control은 client context의 수명과 독립적으로 관리합니다. Solo Raid state는
현재 profile revision의 UID/hash/readiness를 admission candidate로 보여 주며, Challenge open이 선택한
runtime/control revision을 현재 head와 다시 대조한 뒤 run binding에 exact하게 고정합니다. 따라서
관리자 설정 변경이 일반 lobby context를 무효화하지 않지만, 과거 설정 revision으로 새 run을 여는
것도 허용하지 않습니다.

Phase 2B manifest는 immutable `nll/client-feature-manifest/v2`와 exact operational policy를 함께 pin합니다. v2는 기존 lobby route 의미를 유지하면서 `lobby.solo_raid`, `solo_raid.directory`, `solo_raid.challenge`를 지원하고 Normal/Quick Battle은 미지원으로 둡니다. backend Solo Raid directory와 Challenge state가 지원됨을 표시하되, original-client adapter와 선언 lobby presentation은 blocked로 별도 표시합니다. Phase 2A2 v1 manifest 이력이나 기존 account의 current manifest를 수정하지 않습니다.

## Season directory와 daily state

Directory publication은 여섯 snapshot의 season number, snapshot UID, snapshot content hash와 안정된 표시 순서를 exact하게 봉인합니다. 이름이나 source ID만으로 member를 연결하지 않습니다. loading context는 선택 없이 directory를 읽을 수 있지만 connect에는 exact `selectedRaidSnapshotUid`가 필수이며 season 7이나 첫 ordinal을 암묵 기본값으로 고르지 않습니다. 선택 변경은 새 immutable selection revision 또는 동등한 CAS-protected history를 남기며 다른 session의 context를 암묵 변경하지 않습니다.

`raidDayKey` 계산은 process timezone, UTC calendar date 또는 process start 시각에 의존하지 않습니다. 각 `(account, policy, counter scope key, raidDayKey)`는 독립 daily aggregate를 가지며 서로 다른 day 사이에 predecessor를 만들지 않습니다. rollover는 target day aggregate를 request transaction 안에서 lazy하고 idempotent하게 여는 동작이며 downtime 뒤 첫 요청과 동시 요청에서도 같은 daily state 하나만 열어야 합니다. `pin_opening_raid_day` run은 05:00 뒤에도 이전 day aggregate를 소비할 수 있고 새 day aggregate의 current pointer를 건드리지 않습니다.

## Runtime execution과 combat control

`RuntimeExecutionProfileRevision`은 client/runtime build, compatibility evidence, FPS/fixed-delta/time-scale와 `multiplayer_enabled=false`를 포함한 실행 의미의 requested/effective fact를 보존합니다. `CombatControlProfileRevision`은 `MaxPerShotCorrect`, 조준과 auto combat/burst처럼 관측·제어 가능한 전투 설정의 requested/effective fact를 보존합니다.

Lab harness는 unresolved profile을 보존할 수 있지만 original-client execution 또는 golden parity admission은 필요한 fact와 exact revision binding이 모두 해소됐을 때만 허용합니다. unsupported option을 조용히 기본값으로 바꾸지 않습니다.

관리자 인증/CSRF 경계는 다음 source-free endpoint를 제공합니다.

- `POST /admin-api/v1/private-server/accounts/{accountUid}/runtime-execution-profile/preview`
- `PUT /admin-api/v1/private-server/accounts/{accountUid}/runtime-execution-profile`
- `POST /admin-api/v1/private-server/accounts/{accountUid}/combat-control-profile/preview`
- `PUT /admin-api/v1/private-server/accounts/{accountUid}/combat-control-profile`

모든 scalar fact는 `{statusCode,value,reasonCode}` 또는 `{statusCode,valueCode,reasonCode}` triplet입니다. `ready`는 value만, `unresolved`는 reason만, `not_applicable`은 둘 다 null이어야 합니다. effective readback은 `effectiveReadbackStatusCode=provided|not_observed`와 effective object 존재 여부가 정확히 일치해야 합니다. original runtime build도 `ready`일 때 exact build UID/SHA, `unresolved`일 때 controlled reason만 허용합니다. runtime graphics는 `anti_aliasing_enabled`, `anti_aliasing_step`, `battle_animation_physics_flags`, `battle_effect_quality`, `default_quality_level`, `graphic_option_mode`, `mesh_quality`, `post_process_flags`, `spine_resolution`, `texture_quality`, `volumetric_fog_quality`의 exact 11개 집합입니다. 저장 요청은 `operationUid`, `profileUid`, full content가 필요하고 최초 생성은 `If-None-Match: *`, 변경은 현재 revision UID의 quoted `If-Match`를 사용합니다.

## Challenge run 상태기계

한 run은 다음 순서를 따릅니다.

```text
open
  -> team 1 enter
  -> lab-harness observation receipt
  -> regroup 또는 close
  -> team 2..5 enter/receipt
  -> result
```

- run open 시 account, client context, raid day, operational policy, profile, selected snapshot, runtime/control revision을 exact하게 pin합니다.
- 한 team은 기존 immutable 5인 `SquadRevision` 하나를 사용합니다.
- run에는 순서가 고정된 1~5개 team만 들어갑니다.
- 모든 team을 통틀어 character definition과 build revision 재사용을 금지합니다.
- enter/receipt/regroup/close command는 operation UID와 canonical request hash로 idempotent합니다.
- 이전 team receipt 없이 다음 team을 열거나, 이미 사용한 squad/character를 재사용하거나, 닫힌 run에 result를 덧붙이는 요청은 controlled fail-closed입니다.

## Damage와 result 권위

전투 damage는 backend나 `Nikke-Dmg-Simulator`가 계산하지 않습니다. Phase 2B에서는 source code와 크기가 아직 확정되지 않은 original wire integer를 가장하지 않고 `nonnegative_integer_decimal/v1` canonical digit string으로 lab observation을 운반합니다. 저장소는 exact nonnegative integer와 checked cumulative sum을 보존합니다. 현재 78자리 damage와 receipt당 64개 segment 제한은 DB/메모리 자원 경계를 위한 lab transport 상한이며 게임 수치 상한을 주장하지 않습니다.

각 team segment는 observation source, accepted damage, profile/squad/build/snapshot/runtime/control revision, 시작·종료 instant, telemetry digest와 controlled warning을 보존합니다. backend가 계산하는 값은 동일 run 안의 accepted team damage 합계뿐이며, 이는 combat simulation이 아니라 receipt 정합성 검산입니다. Phase 3C/3D의 최소 one-team adapter가 실제 client observation을 별도 versioned contract로 매핑하기 전에는 `original_runtime` 증거로 승격하지 않습니다.

## PostgreSQL

V0001~V0006은 checksum 이력으로 변경하지 않습니다. V0007은 additive schema로 다음을 소유합니다.

- immutable Phase 2B feature manifest/directory/operational policy
- account/session client context와 selected season history
- KST operational-day daily state와 rollover ledger
- runtime execution/control profile revision
- Challenge run, ordered team binding, observation segment와 result
- idempotent command operation ledger와 exact revision/FK topology

DB는 exact member FK, account/session ownership, one-current pointer, immutable lineage, ordered 1..5 team, run-wide character uniqueness, monotonic state transition, canonical observation shape와 result sealing을 방어합니다. semantic readiness를 DB가 추론하지는 않지만 relational bypass로 불가능한 graph를 만들 수 없어야 합니다.

## 구현 모듈

- `NikkeLocalLab.Domain.PrivateServer`: capability/directory/policy/day/profile/run/result 불변 계약과 state machine
- `NikkeLocalLab.Application.PrivateServer`: boot, context, selection, lobby, policy, profile, run command/query port
- `NikkeLocalLab.Persistence.PostgreSql`: V0007 bootstrap/context/history/daily/profile/run/recovery 저장
- `NikkeLocalLab.PrivateServer.Api`: loopback-only strict lab API와 process-local bearer-token 경계
- `NikkeLocalLab.Admin.Api`: operational policy와 full runtime/control fact preview/save/activation
- `NikkeLocalLab.PrivateServer.UnitTests`, `NikkeLocalLab.PrivateServer.Api.UnitTests`, PostgreSQL integration tests: lab-owned contract harness

## API와 harness

Phase 2B API는 loopback 전용 lab-owned contract입니다. strict JSON, exact Host/Origin, process-local admin/session separation, bounded body, operation UID, CAS와 controlled `{code, traceId}` 오류 원칙을 Phase 2A2에서 이어받습니다.

동일 `operationUid`의 Open replay는 같은 API process lifetime 안에서 최초 session/context/issued/expires와 HMAC token을 exact 재사용합니다. process restart 뒤에도 persisted session/context/time은 복원하지만 process-local signing key가 바뀌면 token은 재서명될 수 있으며, restart 간 token byte 동일성과 durable signing key는 Phase 2B 범위 밖입니다. 이 token은 original-client 인증 packet이 아니며 공식 credential을 사용하지 않습니다.

boot는 `resultObservationContractId=lab_harness_observation/v1`, `finalDamageAuthority=original_client_runtime`, `originalRuntimeObservationStatus=blocked_by_gate`를 서로 다른 필드로 제공합니다. 즉 harness receipt의 출처와 최종 대미지 권위를 혼동하지 않으며 Phase 3C/3D one-team observation adapter/identity gate 전에 original-runtime 관측을 주장하지 않습니다. Phase 4는 그 계약의 multi-team/runtime parity 확장입니다.

지원 surface:

- boot/connect/bootstrap
- season directory read와 selected-season CAS
- fixed Normal-clear/Challenge-open/no-Quick projection
- policy/readiness read
- 관리자 인증 경계의 여섯 축 policy publish/next-day activation과 full runtime/control fact preview/save
- Challenge open/read-resume, team enter, observation receipt, regroup, close/result와 abandon
- 소유 session이 만료·폐기된 active run의 same-account CAS recovery-abandon
- Normal/Quick guard route의 controlled unsupported와 Recruit의 visible no-op result

API path와 JSON은 original NIKKE endpoint 또는 packet shape가 아닙니다. harness green은 backend 계약 증거일 뿐 원본 client 호환 증거가 아닙니다.

## 완료 gate

- `scripts/verify-phase2b.ps1`이 완료된 `verify-phase2a2.ps1`을 먼저 호출한 뒤 Phase 2B domain/API unit을 검증합니다.
- 같은 script가 private-server/admin 두 host의 config → controlled policy → runtime initial-policy composition을 static guard로 고정합니다.
- `MigrateAsync`를 사용하는 모든 integration test가 `lab_private_server` schema를 reset하는지 static guard로 검증합니다.
- `scripts/verify-phase2b.ps1 -Integration`이 동일 gate에 V0001~V0007 live PostgreSQL integration project를 추가합니다.
- locked restore와 Release build가 warning/error 없이 통과합니다.
- 기존 Phase 0~2A2 unit/live PostgreSQL gate가 회귀 없이 통과합니다.
- Phase 2B domain/application/API tests가 fixed directory, unresolved policy, KST boundary, ordered team와 canonical damage를 검증합니다.
- live PostgreSQL에서 six-member directory, session-isolated selection, 04:59:59.999/05:00:00 rollover, downtime/concurrency, policy fail-closed, 1~5팀 uniqueness, command replay, result sealing과 direct-SQL negative를 검증합니다.
- security test가 loopback-only, strict JSON, body cap, source-ID/path/credential-free response와 unsupported route를 검증합니다.
- repository policy, format, Actions contract와 `git diff --check`가 통과합니다.
- 완료 상태에서도 original-client boot/UI/battle 일치를 선언하지 않습니다.
