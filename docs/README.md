# 문서 색인

현재 안내를 읽을 때는 아래 ‘먼저 볼 문서’만 입구로 사용합니다.
상세 계약은 관련 작업 때 참조하고, 날짜별 실험 기록은 보관 폴더에서 찾습니다.
에이전트의 필수 읽기 순서·불변 규칙은 [AGENTS](../AGENTS.md)를 유지합니다.

## 먼저 볼 문서

실제 기록 연결: [솔로 모의전 수집·개인별 차감 딜표·초상화](operations/RAID_RECORDS_LIVE.md) — V0028 설치, 기존 로그 4건 분석, 실제 DB/API 확인과 실게임 확인 범위.

현재 통계 작업: [레이드 개인별 대미지 수집](operations/RAID_DAMAGE_CAPTURE.md) — 확정된 TAB/총 대미지 공식, 원본 통계 보존 및 덱 기록과 개인별 대미지 FK 연결.

통계 UI 초안: [보스별 모의전·실전 기록 패널](operations/RAID_RECORDS_UI_PROTOTYPE.md) — 속성별 필터와 덱 상세 미리보기. 실제 DB 조회·BattleLog 분석 연결은 다음 단계.

통계 구현 계획: [기록 조회부터 효과·행동 분석까지](operations/RAID_ANALYTICS_IMPLEMENTATION_PLAN.md) — 현재 저장 범위, 상세 화면·지표, 로그 지속 보존과 5단계 완료 조건.

상세 분석 첫 구현: [캐릭터별 피해 구성](operations/RAID_DAMAGE_COMPOSITION.md) — 전용 페이지, 투사체 제외 기본값, 평타·교체 무기·효과 분해, 미분류 및 버전별 로컬 분석 보존.

BattleLog 읽기: [전체 해설·62종·240필드 사전](operations/BATTLE_LOG_GUIDE.md) — 공격·투사체·버스트·효과·보스 행동, 참조 연결, 수치 단위 및 확인/미확정 구분.

BattleLog 심화 조사: [확정 감사와 남은 근거](operations/BATTLE_LOG_CERTAINTY_AUDIT.md) — 피해/회복 HP 재구성, 버스트 단위, 스킬 연결, 대미지 공식의 재현 범위와 미확정 사유.

BattleLog 무기 조사: [사거리·무기 교체·샷건](operations/BATTLE_LOG_WEAPON_ANALYSIS.md) — 두 참고 저장소와 로컬 152 대조, 기본 구간 예외, 교체 스킬 출처, 펠릿 분석의 현재 범위.

BattleLog 후속 실전: [울트라 교체 무기·관통·샷건](operations/BATTLE_LOG_ULTRA_WEAPON_OBSERVATION.md) — 스노우 화이트 1발·4부위, 버스트 출처와 피해 시점 분리, 샷건 코어 혼재, 계산/적용 연결 보완.

BattleLog 라피 실전: [발사 조건·교체 발사체](operations/BATTLE_LOG_RAPI_WEAPON_OBSERVATION.md) — 패시브 101회, 버스트별 발동 간격, 탄약 증감량의 한계, 생성 이후 피해 귀속, 충돌·폭발 308타격과 효과별 계수 대조.

현재 계정 UI 작업: [유니온 중심 계정 관리](operations/UNION_ACCOUNT_WORKSPACE.md) — 계정 생성·선택·가져오기/동기화 및 등록 멤버 표시.

현재 기능 작업: [유니온 레이드 하드 도입](operations/UNION_RAID_HARD_IMPLEMENTATION.md) — 시즌 선택, 5보스 원본 행동 트리 조립, NLL 소속 및 하드 개방 준비.

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
- [버전 독립 DB 영속성과 로비 Quit 정비](operations/VERSION_INDEPENDENT_RUNTIME_PERSISTENCE.md)

결함 기록의 오래된 우선순위나 당시 ‘미완료’ 문구는 현행 상태 선언이 아닙니다.
현재 우선순위는 안정화 계획을, 개별 결함의 원인·수정 근거는 BE/FE 항목을 확인합니다.

## 운영 절차

- [보스 자동 추가·공통 실행 경로 통합 계획](operations/COMMON_BOSS_EXECUTION_PLAN.md)
- [공식 프로그램 차단의 실행 수명주기](operations/SHARED_PROGRAM_ISOLATION.md)
- [공식 클라이언트와 NLL 사용자 저장소 격리 계획](operations/USER_STORAGE_ISOLATION_PLAN.md)
- [공식 152 업데이트와 NLL 151 호환성 조사](operations/CLIENT_152_COMPATIBILITY_ASSESSMENT.md)
- [시즌 목록 동기화·설치본 입력 조사](operations/BOSS_SEASON_SYNC_PLAN.md)
- [캐릭터 목록 동기화·보유 저장 연결](operations/CHARACTER_CATALOG_SYNC.md)
- [S34 공통 파이프라인 실험·결손·후속 작업](operations/S34_COMMON_PIPELINE_EXPERIMENT.md)
- [P2-2 속성 제한 패턴·실드 FX 조사와 상세 계획](operations/P2_2_ELEMENT_SHIELD_INVESTIGATION.md)
- [S29 행동 트리·소환·쉴드·특수 QTE 경로 대조](operations/S29_BEHAVIOR_PATTERN_TRACE.md)
- [P2-2 속성 쉴드 조건 출처·대상·표시 대응표](operations/P2_2_SHIELD_CONDITION_FX_MAP.md)
- [속성 쉴드 기준 크기·출처·자동화 입력](operations/P2_2_SHIELD_SIZE_REFERENCE.md)
- [P2-3 공통 실행 형식·FX 전달 연결](operations/P2_3_RUNTIME_FX_BINDING.md)
- [실행·종료 단축 미확정 구간 집중 조사](operations/RUNTIME_FAST_PATH_OBSERVATION.md)
- [정상 실행의 CDB 전체 검산 제거 구현 계획](operations/RUNTIME_FAST_PATH_IMPLEMENTATION_PLAN.md)
- [HTTP 보정 FX 전달 가능성·원본 로더 조사](operations/HTTP_FX_DELIVERY_INVESTIGATION.md)
- [프로젝트 전체 용량 정리 후보 — 2026-09-14](operations/PROJECT_STORAGE_AUDIT_20260914.md)
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
- [공통 보스 실행 입력·호환·상태](contracts/COMMON_BOSS_EXECUTION.md)
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
