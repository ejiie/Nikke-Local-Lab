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

다음 Phase 2B에서는 boot/lobby private-server service, permanent multi-season directory, `Asia/Seoul` 05:00 daily state, 1~5팀 Challenge run/result를 구현합니다.

후속 모듈은 `SoloRaid.Service`, `Challenge.Session`, wire/presentation `OriginalClientCompatibilityAdapter`로 분리합니다. 단일 `SquadRevision`은 한 팀이고 multi-team run aggregate가 아닙니다. 원본 client adapter는 최종 목표에 필수지만 현재 disabled이며 harness와 editor는 이를 대체하지 않습니다.
