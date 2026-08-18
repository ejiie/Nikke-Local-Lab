# Architecture direction

Phase 0에서는 경계만 고정하며 구현은 다음 단계부터 시작합니다.

```text
C:\NIKKE (read-only)
        |
        v
Offline importer -> ephemeral staging -> identity mapper
        |                                  |
        +------------ provenance ----------+
                           |
                           v
                       PostgreSQL
                           |
                    local catalog API
                           |
                 admin UI / test client
                           |
                 combat validation runtime
```

## 예정 모듈

- `Import.Formats`: MemoryPack/NKDB/UnityFS 등 범용 reader
- `Import.Sources`: 로컬 게임 경로 adapter
- `Provenance`: snapshot, hash, diff, import 상태
- `Domain`: 캐릭터 정의와 빌드 revision 계약
- `Persistence`: 자체 ID와 versioned schema
- `Api`: 조회·write API
- `Combat`: 이후 전투 검증 runtime

기존 `Nikke-Dmg-Simulator`의 엔진과 직접 결합하지 않습니다. 필요해질 때 중립 DTO/package 계약으로만 연결합니다.
