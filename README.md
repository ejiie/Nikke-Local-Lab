# Nikke Local Lab

개인 로컬 환경에서 NIKKE 전투 데이터를 보관하고 재현 가능한 캐릭터 빌드로 검증하기 위한 독립 실험 프로젝트입니다.

현재 단계는 **Phase 0: 저장소·계약·데이터 경계 고정**입니다. 아직 서버, 데이터베이스, 공식 클라이언트 호환 계층은 구현하지 않습니다.

## 현재 확정 범위

- 캐릭터 정적 정의와 수정 가능한 전투 빌드를 분리합니다.
- 빌드는 불변 revision으로 저장하며 전투 결과가 정확한 revision을 참조합니다.
- 기본 프리셋은 `combat-max/v1`입니다.
- 원본 게임 ID는 import staging에서만 해석하고 도메인/API에는 자체 ID만 사용합니다.
- `C:\NIKKE`와 모든 원본·복호·파생 게임 데이터는 읽기 전용 로컬 입력이며 Git에 넣지 않습니다.

세부 범위는 [docs/SCOPE.md](docs/SCOPE.md), 데이터 경계는 [docs/DATA_POLICY.md](docs/DATA_POLICY.md), 빌드 계약은 [docs/DOMAIN.md](docs/DOMAIN.md)를 참고합니다.

## 저장소 정책 확인

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/verify-repository.ps1 -Mode working
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/verify-phase0-contract.ps1
```

정책 검사는 실제 Git 추적 대상과 합성 fixture를 검사합니다. `.gitignore`만 믿지 않습니다.
