# 문서 색인

현행 문서는 아래 목록뿐입니다. 날짜별 작업 기록·조사·과거 계획은 [보관 기록](#보관-기록)으로 옮겼습니다.
에이전트의 필수 읽기 순서와 불변 규칙은 [AGENTS](../AGENTS.md)를 따릅니다.

## 먼저 볼 문서

| 문서 | 역할 |
|---|---|
| [HANDOFF](HANDOFF.md) | 현재 상태와 운영자 확인 기록 |
| [NEXT_STEPS](NEXT_STEPS.md) | 남은 작업의 유일한 목록 |
| [ARCHITECTURE](ARCHITECTURE.md) | 구성 요소·소스 구조 |
| [MICRON_CURRENT_PATHS](MICRON_CURRENT_PATHS.md) | 설치본·실행 lane·선택 포인터·백업 경로의 권위 |

## 정책

| 문서 | 역할 |
|---|---|
| [SCOPE](SCOPE.md) | 제품 범위, 빌드 기본값, Challenge 규칙 |
| [SECURITY_BOUNDARY](SECURITY_BOUNDARY.md) | 보안 경계와 운영자 승인 |
| [DATA_POLICY](DATA_POLICY.md) | 데이터 취급·저장 위치·게시 경계 |
| [DECISIONS](DECISIONS.md) | 결정 이력과 남은 미정사항 |

## 기능 (현재 동작)

- [보스 추가와 공통 실행 준비](features/BOSS_PIPELINE.md)
- [게임 실행·종료·복구와 영속화](features/EXECUTION_LIFECYCLE.md)
- [계정·니케 관리와 가져오기](features/ACCOUNTS.md)
- [유니온 레이드 하드](features/UNION_RAID.md)
- [레이드 기록·딜표·BattleLog 분석](features/RAID_RECORDS.md)

## 운영 절차

- [검증 gate·GitHub Actions](operations/GITHUB_AUTOMATION.md)
- [Windows PostgreSQL](operations/WINDOWS_NATIVE_POSTGRESQL_RUNTIME.md)
- [공식 client 업데이트 적용 순서](operations/CLIENT_UPDATE.md)
- [계정 fresh capture 경로(Phase C)](operations/PHASE_C_FRESH_CAPTURE_PATHS.md)

## 참고 자료

BattleLog 해석: [전체 해설·62종·240필드](reference/battlelog/BATTLE_LOG_GUIDE.md),
[확정 범위 감사](reference/battlelog/BATTLE_LOG_CERTAINTY_AUDIT.md),
[무기·샷건](reference/battlelog/BATTLE_LOG_WEAPON_ANALYSIS.md),
[스노우 화이트 교체 무기](reference/battlelog/BATTLE_LOG_ULTRA_WEAPON_OBSERVATION.md),
[라피 발사·효과 분해](reference/battlelog/BATTLE_LOG_RAPI_WEAPON_OBSERVATION.md).

## 계약

데이터·출처·게이트: [캐릭터·빌드](contracts/DOMAIN.md), [레이드](contracts/RAID_DOMAIN.md),
[프로필·실행](contracts/PROFILE_EXECUTION_DOMAIN.md), [공통 보스 실행](contracts/COMMON_BOSS_EXECUTION.md),
[원본 UI](contracts/PRIVATE_SERVER_UI.md), [식별자·출처](contracts/IDENTITY.md), [호환성 게이트](contracts/FEASIBILITY_GATES.md),
[저장소·외부 코드 출처](contracts/REPOSITORY_ORIGIN.md).

Phase별 완료 계약과 역사적 검증 기준: [1A](contracts/PHASE1A.md), [1B](contracts/PHASE1B.md), [1C](contracts/PHASE1C.md),
[1D](contracts/PHASE1D.md), [2A1](contracts/PHASE2A1.md), [2A2](contracts/PHASE2A2.md), [2B](contracts/PHASE2B.md),
[3](contracts/PHASE3.md), [3A](contracts/PHASE3A.md), [3A-R](contracts/PHASE3AR.md), [3B-0](contracts/PHASE3B0.md),
[3B-1](contracts/PHASE3B1.md), [3B-2](contracts/PHASE3B2.md). `scripts/verify-phase*.ps1`가 이 문서들을 검사하므로 경로를
바꾸지 않습니다. Phase 3의 `blocked/not-executed` fixture는 보존할 역사적 계약이며 운영자 실게임 결과와 바꿔 해석하지 않습니다.

## 보관 기록

삭제하지 않고 현행 안내에서 분리한 원인·실험·계획 이력입니다. 본문의 "현재", "다음 실행", 과거 경로와 기한은 작성 당시
기준이며 실행 지시가 아닙니다. 보류된 기능 요구도 들어 있으므로 보관을 요구 폐기로 해석하지 않습니다.

| 폴더 | 내용 |
|---|---|
| [archive/boss-pipeline](archive/boss-pipeline/) | 공통 실행 통합 P0~P6, 속성 실드 조사, S7·S9·S25·S29·S34·S39·S42 기록, 시즌 동기화 |
| [archive/execution](archive/execution/) | 영속화 P-01~P-09, 버전 독립 영속성, 빠른 실행 R1~R6, 공유 프로그램 차단, 재부팅 복구, 사용자 저장소 격리 |
| [archive/raid-records](archive/raid-records/) | 딜표 수집·공식 확정, 기록 연결, 피해 구성 v1~v3, 통계 구현 계획 |
| [archive/union](archive/union/) | 유니온 하드 구현·결함 수정, 유니온 중심 계정 UI |
| [archive/accounts](archive/accounts/) | 계정 workspace/Save 설계, 캐릭터 목록 동기화 |
| [archive/client](archive/client/) | 152 호환성 조사·설치, 150 보관 |
| [archive/stabilization](archive/stabilization/) | 안정화 계획 S-01~S-10, 실 테스트 체크리스트, 관리도구 결함 이력, 용량 감사 |
| [archive/](archive/) 최상위 | 2026-09-06·09-27 인계, 이전 다음 단계·프로젝트 소개, 과거 구현 계획·아키텍처·기능 로드맵, 151 리소스·Phase 3B-2 기록, 계정 fetch 인수, Samsung→Micron 이관 |

`archive/IMPLEMENTATION_PLAN.md`, `archive/PHASE3B2_*` 일부는 검사·봉인 스크립트가 경로를 참조하므로 옮기지 않습니다.

## 문서 관리 기준

- 현재 상태는 HANDOFF, 남은 작업은 NEXT_STEPS 한 곳에서만 갱신합니다. 같은 목록을 다른 문서에 중복하지 않습니다.
- `features/` 문서는 현재 동작·코드 위치·알려진 결함만 담습니다. 날짜별 조사·설치 기록은 `archive/<주제>/`에 둡니다.
- 원인·승인·rollback·migration 근거는 삭제하지 않고 보관합니다.
- 문서를 옮기면 Markdown 링크, AGENTS, 검사/봉인 스크립트의 문서 경로를 함께 갱신합니다. 저장소 정책 검사
  (`scripts/verify-repository.ps1`)는 `data`, `runtime`, `cache`, `logs`, `artifacts` 같은 이름의 디렉터리를 추적 경로에 허용하지
  않으므로 폴더 이름을 고를 때 확인합니다.
