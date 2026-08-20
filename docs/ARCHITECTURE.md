# Architecture direction

최종 실행 경로는 원본 NIKKE client의 UI·asset·전투 runtime이 제한된 Local Lab private server를 사용하는 구조입니다. backend는 게임을 다시 렌더링하거나 damage를 대신 계산하지 않고 local session, profile projection, lobby capability, Solo Raid 상태와 결과를 공급합니다. Phase 2A1에서 자체 local account/profile revision 저장을, Phase 2A2에서 strict offline ingress와 관리/client-facing projection을 완료했으며, Phase 2B source-free private-server backend/harness까지 단위 및 live PostgreSQL gate로 완료했습니다.

    C:\NIKKE (read-only)
            |
            v
    Offline importer -> ephemeral staging -> identity mapper
            |                                  |
            +------------ provenance ----------+
                               |
                 +-------------+-------------+-------------+
                 v                           v             v
          Character catalog        Combat-support       RaidSnapshot
                                    catalog              store
                 |                           |             |
                 +-------------+-------------+-------------+
                               v
                          PostgreSQL
                               |
             account/build/squad/profile revisions
                               |
                 lobby/profile/wallet projection
                 season catalog + selected season
                 daily raid state + Challenge run
                               |
                     Local Lab private server
                         /           \
                        v             v
        lab-owned contract harness    OriginalClientCompatibilityAdapter
              (test only)                  (disabled until gates pass)
                                               |
                                  presentation/wire adapter
                                               |
                                               v
                               original NIKKE UI + battle runtime

lab-owned harness는 importer, API, revision, admission, 결과 계약을 검증하는 sidecar입니다. 최종 사용자 실행 경로나 원본 전투 검증의 대체물이 아닙니다.

## Phase 2A1·Phase 2A2 완료 기반

- `Identity`: 자체 UUID와 HMAC source identity 경계
- `Provenance`: source/dataset/extractor/request canonical hash
- `Application`: path-free import coordinator와 ledger port
- `Configuration`: fail-closed config와 runtime root
- `Import.Sources`: 읽기 전용 source capability
- `Domain.Character`: immutable 캐릭터 정의·버전과 combat-max/v1
- `Import.CharacterCatalog`: strict StaticData/sd.bin reader와 정규화
- `Domain.CombatSupport`: Tier 9·10 장비, cube, collection/favorite, console, OL definition/version과 canonical manifest
- `Import.CombatSupportCatalog`: strict StaticData reader와 source-ID-free 전투 보조 candidate
- `Domain.Raid`: Challenge admission policy, 정적 파츠와 ordered monster-skill slot 관계, evidence tier, RaidSnapshot v2
- `Import.RaidCatalog`: strict Challenge FK chain과 typed behavior/bundle/timing evidence reader
- `Domain.Profile`: 자체 local account/session, account combat state, character build, squad와 profile template revision
- `Persistence.PostgreSql`: import ledger, 세 catalog publish와 V0005 profile CAS/revision persistence
- `Import.Cli`: config-check/init/migrate 및 세 catalog inspect/import 진입점

Phase 2A2 모듈도 단위 및 live PostgreSQL gate로 완료했습니다.

- `Import.Profile`: strict credential-bearing raw parser, canonical sanitized draft codec, typed catalog rebase와 reviewed override
- `Domain.LocalGameState`: immutable lobby presentation, wallet와 feature manifest contract
- `Application.ProfileManagement`: profile edit/import/create/rebase command, typed bootstrap와 read model port
- `Persistence.PostgreSql`: V0006 local state, sanitized draft와 별도 editor candidate, diff/application intent·recovery와 profile-management composition
- `Admin.Api`: loopback-only command API, process-local admin session과 no-CDN/no-inline editor
- `Import.Cli`: source-free `profile-source-inspect`와 `profile-draft-import`

Phase 2B는 다음 모듈을 구현했고 단위 및 live PostgreSQL gate로 검증했습니다.

- `Domain.PrivateServer`: fixed Solo Raid capability, permanent six-season directory, KST raid day, operational policy, runtime/control revision과 Challenge run state machine
- `Application.PrivateServer`: boot/session/context, lobby/Solo Raid projection, policy/profile/run command port
- `Persistence.PostgreSql`: V0007 directory/selection/daily/profile/run/result aggregate, immutable operation ledger와 recovery
- `PrivateServer.Api`: loopback-only boot/connect/lobby/Solo Raid/Challenge lab contract과 process-local access-token 서명
- `Admin.Api`: 여섯 축 operational policy와 runtime/control profile의 authenticated preview/save/activation 경계
- `PrivateServer.UnitTests`, `PrivateServer.Api.UnitTests`, PostgreSQL integration harness: backend 계약 검증

## Phase 3 후속 경계

- `Import.Formats`: 후속 전투 실행에 필요한 추가 NKDB/UnityFS reader
- `CompatibilityEvidence`: 3A source-free verdict와 Git 밖 local evidence attestation 경계
- `OriginalClientTransport`: 3B exact-build preflight, supported selector와 handshake
- `OriginalClientBootAdapter`: 3C boot/session/account bootstrap projection
- `OriginalClientPresentationAdapter`: 3D lobby와 explicit season selection binding
- `OriginalClientChallengeAdapter`: 3E main/ready/open/first-team handoff
- `OriginalClientBattleObservationAdapter`: Phase 4 observation, regroup/next-team, close/result와 telemetry boundary

현재 3A verdict는 `blocked_insufficient_evidence`이며 위 runtime module은 생성·활성화하지 않습니다. shared adapter contract는 한 writer가 소유하고 각 수직 슬라이스는 별도 branch, 각 batch는 focused commit으로 닫습니다.

## 데이터와 실행 상태 분리

`RaidSnapshot`은 불변 데이터·asset·runtime provenance만 담습니다. 다음 가변 또는 presentation 상태는 snapshot 밖에 둡니다.

- 모든 published 시즌을 나열하는 directory와 account/session별 selected season
- permanent availability와 normal-stage clear/Challenge unlock projection
- KST raid day와 daily attempt state
- lobby profile, wallet와 feature capability
- original client gate 상태
- local session 및 battle execution 상태
- 현재 client build에 대한 runtime admission

이 분리로 gate 또는 구현 상태가 바뀌어도 과거 snapshot의 hash와 의미가 변하지 않습니다.

## 원본 client gated lane

원본 client adapter는 최종 목표의 필수 경로이지만 현재는 disabled입니다.

    original NIKKE client
      --[supported and authorized local/test interface only]-->
    wire + presentation compatibility adapter
      --> Local Lab private server

gate가 모두 해제된 경우에만 활성화합니다. domain, importer, persistence는 adapter에 의존하지 않으며 adapter는 자체 ID와 client compatibility reference 변환, 그리고 승인된 UI variant의 presentation binding만 담당합니다. 공식 인증 protocol replay, 추측 auth, endpoint 변조, 프로세스 주입 또는 보호 기능 우회로 만들지 않습니다.

원본 client의 기존 Solo Raid 화면을 상태로 채우는 것과 lobby의 고정 widget을 제거·재배치하는 것은 다른 capability입니다. 기존 기능 flag가 처리할 수 없는 season folder, permanent 표시, Quick Battle 제거와 Recruit no-op은 승인된 presentation adapter가 없으면 blocked입니다.

gate가 해제되지 않으면 개발 가능한 계층은 계속 검증하되 제품의 최종 인수 상태는 `blocked`로 남습니다.

기존 `Nikke-Dmg-Simulator`는 optional oracle/optimizer sidecar입니다. versioned source hash와 normalized exchange contract로만 결과를 주고받으며, 원본 client runtime의 전투·damage·HUD 권위를 대체하지 않습니다. sidecar 계산 readiness와 original-client execution readiness를 섞지 않습니다.

## Phase 2B backend/harness 경계

Private-server API의 boot 응답은 현재 관측 계약 `lab_harness_observation/v1`, 최종 damage 권위 `original_client_runtime`, 원본 runtime 관측 상태 `blocked_by_gate`를 별도 필드로 보존합니다. Phase 2B backend는 harness damage를 계산하지 않고 exact decimal receipt와 팀별 합계만 검산합니다. Phase 4 `OriginalClientBattleObservationAdapter`는 이 receipt를 이름만 바꿔 승격하지 않고 실제 client observation mapping을 새 versioned provenance로 추가해야 합니다.

`challenge-operational-policy/unresolved/v1`은 checked-in 기본이며 Challenge unlock을 닫지 않고 새 run admission만 fail closed합니다. 빈 DB의 초기 configured policy는 현재 raid day에 활성화할 수 있지만, 이후 admin 전환은 다음 KST 05:00 raid day에만 효력이 발생합니다. client context는 선택 season과 exact profile/lobby/wallet/feature/squad revision set을 고정하고, runtime/control head는 run open에서 다시 대조한 뒤 run에 고정합니다.

Private-server bearer token은 process-local HMAC key로 서명합니다. 같은 process에서 같은 Open operation을 replay하면 최초 token byte까지 재사용하지만, restart 뒤에는 영속 session/context/issued/expires를 복원해도 새 process key로 token이 재서명될 수 있습니다. durable signing key나 restart 간 token byte 동일성은 Phase 2B 계약이 아닙니다.

## Profile and execution lane

    credential-bearing legacy raw
              |
      strict offline sanitizer
              |
    canonical source-free draft ------ typed rebase/reviewed override
              |                                      |
              +----------------------+---------------+
                                     v
                          preview diff / create diff
                                     |
      profile edit candidate --------+
        (separate contract)           |
                                     v
    AccountCombatStateRevision + CharacterBuildRevision
                                     |
                   V0005 write + V0006 recoverable lineage
                                     |
                          loopback command API
                                     |
                          standalone profile editor

legacy crawler와 로그인/replay 코드는 이 경로에 포함하지 않습니다. editor는 DB를 직접 수정하지 않으며 Save/Save As마다 새 revision을 만듭니다.

완료된 2A1 경계는 `AccountCombatStateRevision + CharacterBuildRevision + SquadRevision + ProfileTemplateRevision`입니다. 완료된 2A2는 이 저장 계약 위에 credential-bearing raw sanitizer, loopback API와 editor를 구현했습니다. raw/rebase/override의 `nll/sanitized-profile-draft/v1`과 scalar editor의 `nll/profile-edit-candidate/v1`은 서로 다른 immutable aggregate이며 diff는 둘 중 하나만 참조합니다.

2A2는 별도 `LobbyPresentationRevision`, `WalletRevision`, feature manifest와 제한된 inventory read model도 추가합니다. 이 값은 combat profile과 다른 변경 주기를 가지므로 `LocalAccount` row나 build revision에 덧붙이지 않습니다. inventory는 전체 보유 inventory가 아니라 current profile의 equipment manufacturer/OL exact value를 포함한 `equipped_combat_items_v1` lossless subset입니다. 단일 `SquadRevision`은 한 팀을 나타내며, Challenge 한 run의 1~5팀과 팀 간 캐릭터 중복 금지는 2B aggregate가 소유합니다.

Import materialization은 보존 가능한 의미 미해결과 무결성 실패를 분리합니다. bond `0` 의미와 missing manufacturer observation은 Research/unresolved로 저장하고 readiness를 낮출 수 있지만, identity/catalog membership/shape/coordinate 또는 필요한 build-level authority 실패는 write 전에 차단합니다. target account가 없는 최초 profile은 별도 create-preview/create topology로만 생성합니다.

V0006 application intent는 V0005 write 전에 exact diff와 예정 operation UID를 고정합니다. process 종료 뒤 replay는 기존 V0005 operation과 topology를 검증하여 completed application을 복구하며, 다른 request가 같은 UID를 재사용하면 fail closed합니다. profile write 뒤 lobby validation도 새 current profile에 맞게 revalidate하여 bootstrap revision set을 stale 상태로 남기지 않습니다.

실행 시에는 `RaidSnapshot`, account state, squad/build, runtime execution profile과 combat control profile을 함께 고정합니다. target FPS와 실제 frame pacing은 다른 값이며 전투 telemetry가 실제 render frame·behavior tick·wall-clock을 별도로 기록합니다.
