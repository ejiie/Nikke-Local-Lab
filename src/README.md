# Source layout

Phase 1B까지 다음 모듈을 구현했습니다.

- `NikkeLocalLab.Identity`: 자체 UUID와 HMAC 기반 source identity 격리
- `NikkeLocalLab.Provenance`: SHA-256, canonical dataset manifest, extractor/request fingerprint
- `NikkeLocalLab.Application`: path-free import coordinator와 ledger port
- `NikkeLocalLab.Configuration`: fail-closed 설정, runtime root와 경로 경계
- `NikkeLocalLab.Import.Sources`: capability-level read-only source adapter
- `NikkeLocalLab.Persistence.PostgreSql`: checksummed migration과 import ledger
- `NikkeLocalLab.Import.Cli`: config-check, runtime init, migration composition root
- `NikkeLocalLab.Domain.Character`: 자체 ID CharacterDefinition/version과 combat-max/v1
- `NikkeLocalLab.Import.CharacterCatalog`: strict StaticData/sd.bin character catalog reader

다음 단계에서 `Domain.Raid` Challenge snapshot importer를 추가합니다. 이후 API, Challenge session, harness를 순서대로 확장합니다.

원본 client adapter는 최종 목표에 필수지만 현재 disabled입니다. harness는 이를 대체하지 않습니다.
