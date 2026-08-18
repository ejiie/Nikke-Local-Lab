# Source layout

Phase 0에는 실행 코드가 없습니다. 다음 단계에서 모듈 경계를 확정한 뒤 프로젝트를 생성합니다.

예정 경계:

- `Domain`: CharacterDefinition/Build/Revision
- `Application`: use case와 write transaction
- `Persistence`: PostgreSQL, migration, custom identity
- `Import`: local-only source adapter와 staging
- `Api`: loopback-first HTTP API
