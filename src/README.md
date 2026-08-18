# Source layout

Phase 1D까지 다음 모듈을 구현했습니다.

- `NikkeLocalLab.Identity`: 자체 UUID와 HMAC 기반 source identity 격리
- `NikkeLocalLab.Provenance`: SHA-256, canonical dataset manifest, extractor/request fingerprint
- `NikkeLocalLab.Application`: path-free import coordinator와 ledger port
- `NikkeLocalLab.Configuration`: fail-closed 설정, runtime root와 경로 경계
- `NikkeLocalLab.Import.Sources`: capability-level read-only source adapter
- `NikkeLocalLab.Persistence.PostgreSql`: checksummed migration, import ledger, 원자적 character/combat-support/raid catalog publish
- `NikkeLocalLab.Import.Cli`: config-check, runtime init, migration 및 세 catalog inspect/import composition root
- `NikkeLocalLab.Domain.Character`: 자체 ID CharacterDefinition/version과 combat-max/v1
- `NikkeLocalLab.Import.CharacterCatalog`: strict StaticData/sd.bin character catalog reader
- `NikkeLocalLab.Domain.CombatSupport`: Tier 9·10 장비, cube, collection/favorite, console, OL definition/version
- `NikkeLocalLab.Import.CombatSupportCatalog`: strict StaticData 전투 보조 catalog reader
- `NikkeLocalLab.Domain.Raid`: Challenge 지원 정책, immutable RaidSnapshot v2와 evidence tier
- `NikkeLocalLab.Import.RaidCatalog`: strict Challenge FK chain과 source-ID-free evidence reader

다음 단계에서는 빌드/프로필 revision API와 Challenge session을 추가한 뒤 harness 및 허용된 원본 client adapter를 순서대로 확장합니다.

원본 client adapter는 최종 목표에 필수지만 현재 disabled입니다. harness는 이를 대체하지 않습니다.
