# Source layout

완료된 Phase 2A1에는 다음 모듈이 포함됩니다. 단위 및 live PostgreSQL gate로 검증했습니다.

- `NikkeLocalLab.Identity`: 자체 UUID와 HMAC 기반 source identity 격리
- `NikkeLocalLab.Provenance`: SHA-256, canonical dataset manifest, extractor/request fingerprint
- `NikkeLocalLab.Application`: path-free import coordinator와 ledger port
- `NikkeLocalLab.Configuration`: fail-closed 설정, runtime root와 경로 경계
- `NikkeLocalLab.Import.Sources`: capability-level read-only source adapter
- `NikkeLocalLab.Persistence.PostgreSql`: checksummed migration, catalog publish와 V0005 local profile CAS/revision 저장
- `NikkeLocalLab.Import.Cli`: config-check, runtime init, migration 및 세 catalog inspect/import composition root
- `NikkeLocalLab.Domain.Character`: 자체 ID CharacterDefinition/version과 combat-max/v1
- `NikkeLocalLab.Import.CharacterCatalog`: strict StaticData/sd.bin character catalog reader
- `NikkeLocalLab.Domain.CombatSupport`: Tier 9·10 장비, cube, collection/favorite, console, OL definition/version
- `NikkeLocalLab.Import.CombatSupportCatalog`: strict StaticData 전투 보조 catalog reader
- `NikkeLocalLab.Domain.Raid`: Challenge 지원 정책, immutable RaidSnapshot v2와 evidence tier
- `NikkeLocalLab.Import.RaidCatalog`: strict Challenge FK chain과 source-ID-free evidence reader
- `NikkeLocalLab.Domain.Profile`: 자체 local account/session, account state, character build, squad와 profile template revision

Phase 2A2에서는 다음 모듈을 구현했고 단위 및 live PostgreSQL gate로 검증했습니다.

- `NikkeLocalLab.Import.Profile`: strict raw parser, canonical sanitized draft codec, typed catalog rebase와 reviewed bond/manufacturer override
- `NikkeLocalLab.Domain.LocalGameState`: lobby presentation, synthetic `jewel|credit` wallet과 feature manifest
- `NikkeLocalLab.Application.ProfileManagement`: typed edit/import/create/rebase command와 bootstrap/read-model port
- `NikkeLocalLab.Persistence.PostgreSql`: V0006 local state, 별도 sanitized draft/editor candidate, diff, recoverable application intent/ledger와 inventory projection
- `NikkeLocalLab.Admin.Api`: loopback-only API, process-local admin session과 no-CDN/no-inline editor
- `NikkeLocalLab.Import.Cli`: aggregate-only `profile-source-inspect`와 source-free `profile-draft-import`

Import는 bond `0`/missing manufacturer 같은 보존 가능한 의미 미해결을 Research fact로 materialize하고 readiness를 낮출 수 있지만 identity/catalog/shape/coordinate/level-authority failure는 write 전에 차단합니다. 빈 DB의 최초 profile은 target account가 없는 explicit create-preview/create command로만 생성합니다. raw `nll/sanitized-profile-draft/v1`과 editor `nll/profile-edit-candidate/v1`은 서로 바꿔 읽지 않습니다.

Phase 2B source-free backend/harness는 구현을 완료했고 단위 및 live PostgreSQL gate로 검증했습니다.

- `NikkeLocalLab.Domain.PrivateServer`: fixed Solo Raid capability, six-season directory, KST raid day, operational policy, runtime/control revision과 1~5팀 Challenge state machine
- `NikkeLocalLab.Application.PrivateServer`: boot/session/context, lobby/Solo Raid, policy/profile/run command/query port
- `NikkeLocalLab.Persistence.PostgreSql`: V0007 private-server bootstrap, exact context history, selection/daily/profile/run/result/recovery
- `NikkeLocalLab.PrivateServer.Api`: loopback-only strict JSON lab API, process-local HMAC bearer token과 controlled unsupported/no-op route
- `NikkeLocalLab.Admin.Api`: 여섯 축 Challenge policy publish/next-day activation과 full runtime/control fact preview/save

checked-in `challenge-operational-policy/unresolved/v1`은 Challenge unlock projection을 유지하면서 새 run만 fail closed합니다. 여섯 축을 모두 명시한 configured policy는 빈 DB의 초기 raid day에 활성화할 수 있고, 이후 admin 전환은 다음 raid day로만 예약합니다. 단일 `SquadRevision`은 한 팀이고 multi-team run aggregate가 아닙니다.

Phase 2B는 `lab_harness_observation/v1`만 수락하고 damage를 계산하지 않습니다. 최종 권위는 `original_client_runtime`이지만 현재 원본 runtime observation은 `blocked_by_gate`입니다. 같은 process의 같은 Open operation replay는 exact token byte를 재사용하지만 restart 간 token byte 동일성은 보장하지 않습니다.

후속 제품 경계는 Phase 3B transport, 3C boot/session, 3D lobby/season presentation과 3E Challenge handoff로 분리한 `OriginalClientCompatibilityAdapter`입니다. 3A evidence audit verdict가 `blocked_insufficient_evidence`이므로 adapter는 현재 disabled이며 harness와 editor는 이를 대체하지 않습니다.
