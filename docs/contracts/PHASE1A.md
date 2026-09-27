# Phase 1A foundation

> 단계별 계약·검증 기준입니다. 이 문서의 과거 실행 판정과 현재 운영 상태를 구분합니다. 현행 상태는 [인계 요약](../HANDOFF.md), 남은 작업은 [다음 작업](../NEXT_STEPS.md)을 확인합니다.

## 완료 범위

Phase 1A는 실제 게임 내용을 해석하지 않고 import 기반을 구현합니다.

- .NET SDK `8.0.407` 고정
- 자체 UUID와 HMAC source identity encoder
- path-free source artifact와 dataset manifest hash
- extractor contract, semantic options, import request, output manifest hash 분리
- PostgreSQL checksummed migration runner
- import ledger와 안전한 diagnostic code
- `%LOCALAPPDATA%\NikkeLocalLab` 또는 `NIKKE_LAB_HOME` runtime root
- capability-level read-only, path-opaque source adapter
- 합성 fixture import와 동일 snapshot 재사용 검증

## Import ledger

`source_artifact`는 SHA-256, byte length, controlled kind, 자체 UUID만 저장합니다. `dataset_snapshot`은 canonical source manifest hash를 저장하고 membership table이 artifact를 연결합니다. `import_run`은 extractor/version/contract/options/request/output hash와 결과 상태를 보존합니다. `import_diagnostic`에는 severity, 사전 등록된 stage/code, count만 허용합니다.

다음 값은 schema에 존재하지 않습니다.

- source path와 file name
- 원본 game ID
- decoded byte/payload
- exception message와 stack trace
- 자유 형식 diagnostic JSON

## Canonical hashing

dataset 입력 manifest는 UTF-8, LF, 마지막 LF 없음으로 직렬화합니다. artifact는 role, controlled kind, lowercase SHA-256, invariant byte length 순으로 정렬합니다. extractor fingerprint와 semantic options hash는 dataset hash와 분리하며, 세 값을 다시 import request hash로 결합합니다.

동일 byte와 동일 semantic 계약은 기존 artifact/snapshot UID를 재사용하지만 모든 실행은 새 import run UID를 가집니다. 같은 request가 다른 output hash를 만들면 재현성 오류로 거부합니다.

## CLI

    dotnet run --project src/NikkeLocalLab.Import.Cli -- config-check --config config/appsettings.example.json --repository-root <repo>
    dotnet run --project src/NikkeLocalLab.Import.Cli -- init --config config/appsettings.example.json --repository-root <repo>
    dotnet run --project src/NikkeLocalLab.Import.Cli -- migrate --config config/appsettings.example.json --repository-root <repo>

`migrate`는 `NIKKE_LAB_DB`의 loopback PostgreSQL 연결만 허용합니다. CLI는 성공 코드 또는 통제된 오류 코드만 출력하며 경로, connection string, exception 원문을 출력하지 않습니다.

## 검증

    pwsh -NoProfile -File scripts/verify-phase1a.ps1

실 PostgreSQL 검증:

    $env:NIKKE_LAB_TEST_DB = '<loopback test database>'
    $env:NIKKE_LAB_TEST_RESET_TOKEN = 'allow-phase1a-disposable-schema-reset'
    pwsh -NoProfile -File scripts/verify-phase1a.ps1 -Integration

reset token은 기본 `nikke_local_lab_test` 일회성 DB의 `lab_import`/`lab_meta` schema 삭제를 명시적으로 허용합니다. 로컬 병렬 검증은 `NIKKE_LAB_TEST_EXPECTED_DATABASE`에 `nikke_local_lab_` prefix의 전용 disposable DB 이름을 명시하고 connection string의 DB와 정확히 일치할 때만 같은 reset을 허용합니다. GitHub Actions는 기본 DB 이름을 유지하며 Windows 경로/단위 검사와 digest-pinned PostgreSQL service에서 합성 파일 → path-opaque adapter → extractor → coordinator → PostgreSQL 전체 경로 검사를 모두 통과해야 자동 병합합니다.

## 명시적 한계

read-only adapter는 이 코드가 쓰기 capability를 갖지 않도록 만드는 경계입니다. 같은 OS 사용자로 실행되는 임의의 다른 코드를 막는 ACL sandbox는 아닙니다. 실제 게임 data extractor, CharacterDefinition, Challenge snapshot publish는 각각 Phase 1B와 1C 범위입니다.
