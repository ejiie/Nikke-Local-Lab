# 문서 색인

현재 안내를 읽을 때는 아래 ‘먼저 볼 문서’만 입구로 사용합니다.
상세 계약은 관련 작업 때 참조하고, 날짜별 실험 기록은 보관 폴더에서 찾습니다.
에이전트의 필수 읽기 순서·불변 규칙은 [AGENTS](../AGENTS.md)를 유지합니다.

## 먼저 볼 문서

| 문서 | 역할 |
|---|---|
| [HANDOFF](HANDOFF.md) | 확인된 상태와 보류 사항만 짧게 정리 |
| [STABILIZATION_PLAN](STABILIZATION_PLAN.md) | 현재 점검 결과·정비 순서·검사 상태의 단일 작업 목록 |
| [NEXT_STEPS](NEXT_STEPS.md) | 현재 작업 목록으로 연결하는 입구 |
| [ARCHITECTURE](ARCHITECTURE.md) | 실제 실행·저장 구조 |
| [MICRON_CURRENT_PATHS](MICRON_CURRENT_PATHS.md) | 현행 OS·설치본·bundle·백업 경로 |
| [SCOPE](SCOPE.md) | 제품 범위 |
| [SECURITY_BOUNDARY](SECURITY_BOUNDARY.md) | 보안 경계와 운영자 승인 |
| [DATA_POLICY](DATA_POLICY.md) | 데이터 취급·저장 경계 |
| [DECISIONS](DECISIONS.md) | 결정 이력 — 당시의 미정·후속 항목은 현재 작업 목록과 구분 |

## 기능별 참고

- [보스 추가 파이프라인](features/BOSS_ONBOARDING_PIPELINE.md)
- [백엔드 결함 이력](features/CONTROL_CENTER_BACKEND_DEFECTS.md)
- [프런트엔드 결함 이력](features/CONTROL_CENTER_FRONTEND_DEFECTS.md)
- [계정 workspace / Save](features/PHASE_B_ACCOUNT_WORKSPACE.md)
- [레이드 영속화·분석 필드](features/SOLO_RAID_PERSISTENCE_AND_ANALYTICS.md)
- [실행 간 영속화 P-01~P-09·실게임 확인 순서](features/RUNTIME_PERSISTENCE.md)

결함 기록의 오래된 우선순위나 당시 ‘미완료’ 문구는 현행 상태 선언이 아닙니다.
현재 우선순위는 안정화 계획을, 개별 결함의 원인·수정 근거는 BE/FE 항목을 확인합니다.

## 운영 절차

- [안정화 변경 후 직접 테스트할 순서](operations/STABILIZATION_ACCEPTANCE.md)
- [신규 보스·보정 FX 사용자 실게임 검증](operations/BOSS_NATIVE_USER_VALIDATION.md)
- [Windows PostgreSQL](operations/WINDOWS_NATIVE_POSTGRESQL_RUNTIME.md)
- [계정 fresh capture 경로·절차](operations/PHASE_C_FRESH_CAPTURE_PATHS.md)
- [향후 용량 정리 후보](operations/STORAGE_CLEANUP_AUDIT.md)
- [검증·GitHub Actions](operations/GITHUB_AUTOMATION.md)
- [150 클라이언트 D: 보관 이전](operations/CLIENT_150_ARCHIVE.md)

용량 정리 문서는 후보 목록이며 이번 문서 정리에서 client·DB·runtime 파일을 삭제하지 않았습니다.

## 상세 계약

데이터·출처·게이트:

- [캐릭터·빌드](contracts/DOMAIN.md)
- [레이드](contracts/RAID_DOMAIN.md)
- [프로필·실행](contracts/PROFILE_EXECUTION_DOMAIN.md)
- [원본 UI](contracts/PRIVATE_SERVER_UI.md)
- [식별자·출처](contracts/IDENTITY.md)
- [호환성 게이트](contracts/FEASIBILITY_GATES.md)
- [저장소·외부 코드 출처](contracts/REPOSITORY_ORIGIN.md)

Phase별 완료 계약과 역사적 검증 기준:

- [PHASE1A](contracts/PHASE1A.md)
- [PHASE1B](contracts/PHASE1B.md)
- [PHASE1C](contracts/PHASE1C.md)
- [PHASE1D](contracts/PHASE1D.md)
- [PHASE2A1](contracts/PHASE2A1.md)
- [PHASE2A2](contracts/PHASE2A2.md)
- [PHASE2B](contracts/PHASE2B.md)
- [PHASE3](contracts/PHASE3.md)
- [PHASE3A](contracts/PHASE3A.md)
- [PHASE3AR](contracts/PHASE3AR.md)
- [PHASE3B0](contracts/PHASE3B0.md)
- [PHASE3B1](contracts/PHASE3B1.md)
- [PHASE3B2](contracts/PHASE3B2.md)

Phase 3의 `blocked/not-executed` fixture는 보존할 역사적 계약입니다.
운영자가 확인한 151 / S26 실게임 결과와 서로 바꿔 해석하지 않습니다.

## 보관 기록

아래 문서는 삭제한 것이 아니라 현재 안내에서 분리한 원인·실험·계획 이력입니다.
본문의 ‘현재’, ‘다음 실행’, 과거 OS 경로와 기한은 작성 당시 기준이며 자동 실행 지시가 아닙니다.
보류된 기능 요구도 포함되어 있으므로 보관을 요구사항 폐기로 해석하지 않습니다.

- [Samsung → Micron 이관](archive/SAMSUNG_TO_MICRON_MIGRATION.md)
- [151 리소스 대조](archive/RESOURCE_COMPATIBILITY_151_COMPARISON.md)
- [151 대응·최종 배포·검증 이력](archive/RESOURCE_COMPATIBILITY_151_PROGRESS.md)
- [151 provider 실험 이력](archive/RESOURCE_COMPATIBILITY_151_PROVIDER.md)
- [리소스 구조 변경 대응 계획](archive/PHASE3B2_RESOURCE_STRUCTURE_MIGRATION_PLAN.md)
- [150 locale/catalog 수집 이력](archive/PHASE3B2_LOCALE_CATALOG_ACQUISITION.md)
- [초기 Epinel 최소 통합 계획](archive/PHASE3B2_EPINEL_MINIMAL_PLAN.md)
- [Trial/Practice 복구 이력](archive/PHASE3B2_SOLO_RAID_TRIAL_PRACTICE_RECOVERY_PLAN.md)
- [진행도 복원 계획](archive/PHASE3B2_USER_PROGRESSION_RECONSTRUCTION_PLAN.md)
- [계정 fetch 인수 기록](archive/PHASE_C_OPERATOR_FETCH_ACCEPTANCE_REPORT.md)
- [보류·기존 기능 로드맵](archive/FOLLOWUP_AUTOMATION_BOSS_ACCOUNT_ROADMAP.md)
- [과거 Phase별 구현 계획](archive/IMPLEMENTATION_PLAN.md)
- [이전 프로젝트 소개](archive/PROJECT_OVERVIEW_2026-09-06.md)
- [이전 인계 전체 기록](archive/HANDOFF_2026-09-06.md)
- [이전 다음 단계 기록](archive/NEXT_STEPS_2026-09-06.md)
- [이전 아키텍처·미래 설계](archive/ARCHITECTURE_2026-09-06.md)

## 문서를 다시 불리지 않는 기준

- 상태·다음 할 일은 HANDOFF와 안정화 계획의 기존 항목을 갱신합니다.
- 원인과 수정 결과는 해당 기능/결함 항목에 기록하고 다른 문서에서는 링크합니다.
- 새 문서는 별도의 지속적인 책임이 있을 때만 만들고 이 색인에 연결합니다.
- 원인·승인·rollback·migration 근거는 삭제하지 않습니다. 오래된 실행 로그는 보관 기록으로 분리합니다.
- 문서 이동 시 Markdown 링크, AGENTS와 검사/봉인 스크립트의 문서 경로를 함께 갱신합니다.
