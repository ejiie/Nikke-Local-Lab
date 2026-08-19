# Nikke Local Lab

개인 로컬 환경에서 NIKKE 전투 데이터를 보관하고, 재현 가능한 캐릭터 빌드와 제한된 Solo Raid Challenge snapshot으로 검증하기 위한 독립 실험 프로젝트입니다.

최종 인수 조건은 **원본 NIKKE UI와 실제 전투 runtime이 허용된 local backend를 사용해 선택된 Challenge를 실행하는 것**입니다. lab-owned harness는 importer·계약·API를 검증하는 개발 도구이며 최종 결과물을 대체하지 않습니다.

현재 단계는 **Phase 2A1 완료**입니다. Phase 1의 정적 catalog와 Challenge snapshot 위에 자체 UUID local account/session, 불변 account-state·character-build·squad·profile revision과 V0005 원자적 PostgreSQL 저장을 통합했습니다. `scripts/verify-phase2a1.ps1`의 단위 gate와 `-Integration` PostgreSQL gate를 모두 통과했습니다. credential-bearing raw sanitizer, loopback API/editor와 원본 리테일 클라이언트 호환 계층은 아직 구현하지 않습니다.

## 현재 확정 범위

- 캐릭터 정적 정의와 수정 가능한 전투 빌드를 분리합니다.
- 빌드는 불변 revision으로 저장하며 전투 결과가 정확한 revision을 참조합니다.
- 기본 프리셋은 `combat-max/v1`이며 캐릭터 레벨은 명시적으로 자유 설정합니다.
- 장비 기본값은 전 부위 Tier 10, 강화 Level 5입니다.
- 큐브는 자유롭게 장착·해제하며, 장착 시 기본 Level 15입니다. 큐브 종류는 사용자가 선택하기 전까지 추측하지 않습니다.
- Solo Raid는 Challenge만 모델링합니다. 일반 1~7단계는 해금 상태 stub일 뿐 플레이할 수 없습니다.
- 지원 정책은 `전격 보스 + 철갑 약점`에서 시즌 14·39를 제외하고 시즌 40을 별도 포함합니다.
- 현재 스냅샷의 지원 시즌은 `7, 13, 26, 29, 34, 40`입니다.
- Raid snapshot은 정적 artifact와 source-ID-free 파츠·스킬 관계를 항상 고정하고, behavior, timeline, asset bundle, client runtime 근거는 호환성 tier가 보장하는 범위까지만 고정합니다.
- 시즌 7·13·26·29·34는 behavior bundle byte가 없어 `static_exact`이며 `behavior_unresolved` warning을 보존합니다.
- 시즌 40은 behavior와 선택 NAPS bundle 근거가 있어 `behavior_exact`입니다. timeline은 partial이고 runtime은 미해소이므로 더 높은 tier로 승격하지 않습니다.
- 원본 게임 ID는 import staging 또는 Git 비추적 compatibility map에서만 해석하고 도메인/API에는 자체 ID만 사용합니다.
- 전투 보조 catalog는 Tier 9·10 장비 24개, 큐브 17종, 범용 소장품 12종, 전용 애장품 21종, 콘솔 9좌표와 표준 OL 9종을 자체 definition/version으로 게시합니다.
- OL은 15개 이산 값과 확률 band를 보존합니다. 동일 장비 내 중복 옵션 정책만 근거가 없어 unresolved이며, 연구용 exact-value write는 이를 이유로 막지 않습니다.
- profile은 character와 combat-support catalog snapshot/dataset/manifest를 각각 고정하며 같은 dataset이라고 가정하지 않습니다.
- 합성 account state는 synchro와 9개 console level/EXP fact를, character build는 네 장비 slot·희소 OL 1..3·cube·단일 collection/favorite 선택을 불변 revision으로 보존합니다.
- draft profile은 squad 없이 저장할 수 있습니다. 원본 client 전투 readiness는 ready account state와 정확히 다섯 개의 selection-ready build revision을 가진 squad에서 성립하고, Local Lab 단독 계산 readiness는 별도 combat-semantics 축으로 판정합니다. `game-legal`은 알려진 합법 좌표를 selection 검증에 추가하는 mode이며 독립 combat-semantics 완료 주장이 아닙니다.
- `C:\NIKKE`의 원본은 읽기 전용입니다. 복호·파생 데이터는 Git 외부 런타임 경계에서만 저장하며 Git에 넣지 않습니다.

원본 리테일 클라이언트 연결은 현재 **차단 상태**입니다. 공식적으로 지원·승인된 로컬/테스트 경로가 확인되기 전에는 endpoint/auth 변조, 공식 로그인·토큰 재사용, 주입·후킹, 안티치트 우회를 사용하지 않습니다. 이 gate가 해제되지 않으면 최종 인수 조건은 미달 상태로 남습니다.

세부 범위는 [docs/SCOPE.md](docs/SCOPE.md), Phase 1D 결과는 [docs/PHASE1D.md](docs/PHASE1D.md), Phase 2A1 결과는 [docs/PHASE2A1.md](docs/PHASE2A1.md), 실행 게이트는 [docs/FEASIBILITY_GATES.md](docs/FEASIBILITY_GATES.md), profile 계약은 [docs/PROFILE_EXECUTION_DOMAIN.md](docs/PROFILE_EXECUTION_DOMAIN.md), 전체 단계는 [docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md), 바로 다음 작업은 [docs/NEXT_STEPS.md](docs/NEXT_STEPS.md), push→merge 자동화는 [docs/GITHUB_AUTOMATION.md](docs/GITHUB_AUTOMATION.md)를 참고합니다.

## 저장소 정책 확인

    pwsh -NoProfile -File scripts/verify-repository.ps1 -Mode working -AllowRemote
    pwsh -NoProfile -File scripts/verify-phase0-contract.ps1
    pwsh -NoProfile -File scripts/verify-phase1a.ps1
    pwsh -NoProfile -File scripts/verify-phase2a1.ps1
    pwsh -NoProfile -File scripts/verify-actions-contract.ps1

PostgreSQL 통합 검사는 폐기 가능한 `nikke_local_lab_test` DB를 준비하고 loopback 전용 `NIKKE_LAB_TEST_DB`와 `NIKKE_LAB_TEST_RESET_TOKEN=allow-phase1a-disposable-schema-reset`을 설정한 뒤 `scripts/verify-phase2a1.ps1 -Integration`으로 실행합니다. 자세한 안전 경계는 [docs/PHASE1A.md](docs/PHASE1A.md), [docs/PHASE1D.md](docs/PHASE1D.md), [docs/PHASE2A1.md](docs/PHASE2A1.md)를 따릅니다. GitHub Actions는 합성 fixture만으로 Windows 단위 검사와 PostgreSQL 17 통합 검사를 수행합니다. 실제 최신 StaticData와 private profile 입력은 Git이나 CI에 넣지 않습니다.
