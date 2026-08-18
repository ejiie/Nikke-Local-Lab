# Source layout

Phase 0에는 실행 코드가 없습니다. 다음 단계에서 모듈 경계를 확정한 뒤 프로젝트를 생성합니다.

예정 경계:

- `Domain.Character`: CharacterDefinition/Build/Revision
- `Domain.Raid`: Challenge admission, published RaidSnapshot, active season
- `Application`: use case와 revision/write transaction
- `Persistence`: PostgreSQL, migration, custom identity
- `Import`: local-only source adapter, ephemeral staging, import diagnostic
- `Provenance`: source/artifact/runtime hash와 compatibility tier
- `Compatibility`: Git 비추적 source mapping과 original-client gate
- `Api`: loopback-first local backend API
- `Challenge.Session`: squad entry와 result/trace 계약
- `Harness`: backend 계약·통합 테스트 전용 client
- `OriginalClientCompatibilityAdapter`: gate 통과 후 원본 UI·전투 runtime을 연결하는 최종 실행 경계

원본 client adapter는 최종 목표에 필수지만 현재 disabled입니다. harness는 이를 대체하지 않습니다.
