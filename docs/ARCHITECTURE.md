# Architecture direction

최종 실행 경로는 원본 UI와 실제 전투 runtime이 local backend를 사용하는 구조입니다. Phase 1B에서는 아래 경로 중 캐릭터 import/domain/catalog publish까지 구현했습니다.

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
                         local backend
                         /           \
                        v             v
        lab-owned contract harness    OriginalClientCompatibilityAdapter
              (test only)                  (disabled until gates pass)
                                               |
                                               v
                               original NIKKE UI + battle runtime

lab-owned harness는 importer, API, revision, admission, 결과 계약을 검증하는 sidecar입니다. 최종 사용자 실행 경로나 원본 전투 검증의 대체물이 아닙니다.

## 구현된 Phase 1B 모듈

- `Identity`: 자체 UUID와 HMAC source identity 경계
- `Provenance`: source/dataset/extractor/request canonical hash
- `Application`: path-free import coordinator와 ledger port
- `Configuration`: fail-closed config와 runtime root
- `Import.Sources`: 읽기 전용 source capability
- `Domain.Character`: immutable 캐릭터 정의·버전과 combat-max/v1
- `Import.CharacterCatalog`: strict StaticData/sd.bin reader와 정규화
- `Persistence.PostgreSql`: import ledger와 원자적 character catalog publish
- `Import.Cli`: config-check/init/migrate 및 character catalog inspect/import 진입점

## 후속 예정 모듈

- `Import.Formats`: Challenge에 필요한 NKDB/UnityFS reader
- `Domain.Raid`: Challenge encounter, admission policy, RaidSnapshot, 활성 시즌
- `Compatibility`: tier 평가와 Git 비추적 mapping adapter
- `Api`: 조회·write API
- `Challenge.Session`: Challenge-only entry와 결과 수집
- `Harness`: 프로젝트 소유 contract/integration test client
- `OriginalClientCompatibilityAdapter`: gate 통과 후에만 활성화되는 원본 client 경계

## 데이터와 실행 상태 분리

`RaidSnapshot`은 불변 데이터·asset·runtime provenance만 담습니다. 다음 가변 상태는 snapshot 밖에 둡니다.

- active season pointer
- normal-stage unlock stub
- original client gate 상태
- local session 및 battle execution 상태
- 현재 client build에 대한 runtime admission

이 분리로 gate 또는 구현 상태가 바뀌어도 과거 snapshot의 hash와 의미가 변하지 않습니다.

## 원본 client gated lane

원본 client adapter는 최종 목표의 필수 경로이지만 현재는 disabled입니다.

    original NIKKE client
      --[supported and authorized local/test interface only]-->
    OriginalClientCompatibilityAdapter
      --> local backend

gate가 모두 해제된 경우에만 활성화합니다. domain, importer, persistence는 adapter에 의존하지 않으며 adapter는 자체 ID와 client compatibility reference의 변환만 담당합니다. 공식 인증 protocol replay, 추측 auth, endpoint 변조, 프로세스 주입 또는 보호 기능 우회로 만들지 않습니다.

gate가 해제되지 않으면 개발 가능한 계층은 계속 검증하되 제품의 최종 인수 상태는 `blocked`로 남습니다.

기존 `Nikke-Dmg-Simulator` 엔진과 직접 결합하지 않습니다. 필요한 정적 분석 결과는 출처 hash를 가진 import 입력으로만 다루고, 실행 엔진을 완제품 대체물로 사용하지 않습니다.
