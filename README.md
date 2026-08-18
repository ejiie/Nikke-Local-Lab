# Nikke Local Lab

개인 로컬 환경에서 NIKKE 전투 데이터를 보관하고, 재현 가능한 캐릭터 빌드와 제한된 Solo Raid Challenge snapshot으로 검증하기 위한 독립 실험 프로젝트입니다.

최종 인수 조건은 **원본 NIKKE UI와 실제 전투 runtime이 허용된 local backend를 사용해 선택된 Challenge를 실행하는 것**입니다. lab-owned harness는 importer·계약·API를 검증하는 개발 도구이며 최종 결과물을 대체하지 않습니다.

현재 단계는 **Phase 1B 완료**입니다. Phase 1A의 import ledger와 read-only source 경계 위에 CharacterDefinition/version 도메인, 엄격한 StaticData와 sd.bin reader, 자체 ID catalog, combat-max/v1 해석기 및 원자적 PostgreSQL publish를 구현했습니다. 서버 API와 원본 리테일 클라이언트 호환 계층은 아직 구현하지 않습니다.

## 현재 확정 범위

- 캐릭터 정적 정의와 수정 가능한 전투 빌드를 분리합니다.
- 빌드는 불변 revision으로 저장하며 전투 결과가 정확한 revision을 참조합니다.
- 기본 프리셋은 `combat-max/v1`이며 캐릭터 레벨은 명시적으로 자유 설정합니다.
- 장비 기본값은 전 부위 Tier 10, 강화 Level 5입니다.
- 큐브는 자유롭게 장착·해제하며, 장착 시 기본 Level 15입니다. 큐브 종류는 사용자가 선택하기 전까지 추측하지 않습니다.
- Solo Raid는 Challenge만 모델링합니다. 일반 1~7단계는 해금 상태 stub일 뿐 플레이할 수 없습니다.
- 지원 정책은 `전격 보스 + 철갑 약점`에서 시즌 14·39를 제외하고 시즌 40을 별도 포함합니다.
- 현재 스냅샷의 지원 시즌은 `7, 13, 26, 29, 34, 40`입니다.
- Raid snapshot은 정적 데이터, behavior, timeline, asset bundle, client runtime의 근거와 호환성 등급을 함께 고정합니다.
- 원본 게임 ID는 import staging 또는 Git 비추적 compatibility map에서만 해석하고 도메인/API에는 자체 ID만 사용합니다.
- `C:\NIKKE`의 원본은 읽기 전용입니다. 복호·파생 데이터는 Git 외부 런타임 경계에서만 저장하며 Git에 넣지 않습니다.

원본 리테일 클라이언트 연결은 현재 **차단 상태**입니다. 공식적으로 지원·승인된 로컬/테스트 경로가 확인되기 전에는 endpoint/auth 변조, 공식 로그인·토큰 재사용, 주입·후킹, 안티치트 우회를 사용하지 않습니다. 이 gate가 해제되지 않으면 최종 인수 조건은 미달 상태로 남습니다.

세부 범위는 [docs/SCOPE.md](docs/SCOPE.md), Phase 1B 계약은 [docs/PHASE1B.md](docs/PHASE1B.md), 실행 게이트는 [docs/FEASIBILITY_GATES.md](docs/FEASIBILITY_GATES.md), Challenge 계약은 [docs/RAID_DOMAIN.md](docs/RAID_DOMAIN.md), 전체 단계는 [docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md), 바로 다음 작업은 [docs/NEXT_STEPS.md](docs/NEXT_STEPS.md), push→merge 자동화는 [docs/GITHUB_AUTOMATION.md](docs/GITHUB_AUTOMATION.md)를 참고합니다.

## 저장소 정책 확인

    pwsh -NoProfile -File scripts/verify-repository.ps1 -Mode working -AllowRemote
    pwsh -NoProfile -File scripts/verify-phase0-contract.ps1
    pwsh -NoProfile -File scripts/verify-phase1a.ps1
    pwsh -NoProfile -File scripts/verify-phase1b.ps1
    pwsh -NoProfile -File scripts/verify-actions-contract.ps1

PostgreSQL 통합 검사는 폐기 가능한 `nikke_local_lab_test` DB를 준비하고 loopback 전용 `NIKKE_LAB_TEST_DB`와 `NIKKE_LAB_TEST_RESET_TOKEN=allow-phase1a-disposable-schema-reset`을 설정한 뒤 `scripts/verify-phase1b.ps1 -Integration`으로 실행합니다. 자세한 안전 경계는 [docs/PHASE1A.md](docs/PHASE1A.md)와 [docs/PHASE1B.md](docs/PHASE1B.md)를 따릅니다. GitHub Actions는 Windows 단위 검사와 PostgreSQL 17 통합 검사를 모두 통과해야 병합합니다. 정책 검사는 실제 Git 추적 대상과 합성 fixture를 검사하며 `.gitignore`만 믿지 않습니다.
