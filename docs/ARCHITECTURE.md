# Architecture direction

Phase 0에서는 경계만 고정하며 구현은 다음 단계부터 시작합니다.

    C:\NIKKE (read-only)
            |
            v
    Offline importer -> ephemeral staging -> identity mapper
            |                                  |
            +------------ provenance ----------+
                               |
                 +-------------+-------------+
                 v                           v
          Character catalog            RaidSnapshot store
                 |                           |
                 +-------------+-------------+
                               v
                          PostgreSQL
                               |
                      local catalog API
                               |
              admin UI / lab-owned test harness
                               |
               Challenge session orchestrator
                               |
                    combat validation result

## 예정 모듈

- `Import.Formats`: MemoryPack/NKDB/UnityFS 등 범용 reader
- `Import.Sources`: 로컬 게임 경로 read-only adapter
- `Provenance`: snapshot, hash, diff, import 상태
- `Identity`: 자체 ID와 비공개 source alias 경계
- `Domain.Character`: 캐릭터 정의와 빌드 revision 계약
- `Domain.Raid`: Challenge encounter, RaidSnapshot, 활성 시즌
- `Compatibility`: tier 평가와 Git 비추적 mapping adapter
- `Persistence`: 자체 ID와 versioned schema
- `Api`: 조회·write API
- `Challenge.Session`: Challenge-only entry와 결과 수집
- `Harness`: 프로젝트 소유 test client

## 비활성 gated lane

원본 리테일 클라이언트 adapter는 주 실행 경로에 포함하지 않습니다.

    original retail client
      --[supported and authorized interface; currently blocked]-->
    disabled OriginalClientCompatibilityAdapter
      --> local API

gate가 모두 해제된 경우에만 별도 adapter로 추가하며, domain과 importer가 이 adapter에 의존하면 안 됩니다. 이 adapter는 공식 인증 protocol replay 또는 추측 구현으로 만들지 않습니다.

기존 `Nikke-Dmg-Simulator`의 엔진과 직접 결합하지 않습니다. 필요해질 때 중립 DTO/package 계약으로만 연결합니다.
