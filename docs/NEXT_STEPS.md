# 다음 작업

최종 갱신: 2026-09-27. 남은 작업의 **유일한 목록**입니다. 현황은 [HANDOFF](HANDOFF.md), 기능별 세부는 `features/` 문서를
따릅니다. 항목을 끝내면 여기서 지우고 해당 기능 문서에 결과를 반영합니다. 과거 목록(안정화 S-01~S-10, P0~P6, UI-RAID-01 등)은
[보관 기록](archive/stabilization/STABILIZATION_PLAN.md)에 있으며, 그 미체크 항목 중 아래에 없는 것은 이후 작업으로 대체됐습니다.

## 구현 (에이전트)

| # | 작업 | 완료 조건 | 문서 |
|---|---|---|---|
| 1 | S42 조립 실패: QTE 원본 속성 혼합(`boss_profile_qte_v3_discovery_invalid`) | 시즌 예외 없이 discovery/변환/검증 의미 확정, 기본 속성·5약점·실제 변경 행 수·무관 행 보존 검사, 원래 오류 코드가 UI까지 전달 | [BOSS_PIPELINE](features/BOSS_PIPELINE.md) |
| 2 | S39 조립 실패: FX 이름 판별이 접두 한 구간만 제거해 공통 실드 후보 0개 | 공통 후보 선택 뒤에도 자산 결박·크기·변경 범위·5속성 검사 통과, 기존 등록 보스 recipe 출력 불변 | [BOSS_PIPELINE](features/BOSS_PIPELINE.md) |
| 3 | 빠른 시작·재부팅 후 실행 상태 자동 복구 | Job 부재를 same-Job 증명으로 위장하지 않는 재시작 복구 계약, 빠른 시작/일반 재부팅/PID 재사용/권한 거부/FX 유무/복구 중 재종료 검사 | [EXECUTION_LIFECYCLE](features/EXECUTION_LIFECYCLE.md) |
| 4 | 전체 프로필 영속성(운영자 우선순위 2) | 프로필 아이콘·프레임·칭호·스킨·꾸미기·설정 등 저장 항목 전체의 capture/restore 대조와 누락 구현, client 버전 전환 후에도 마지막 상태 유지 | [EXECUTION_LIFECYCLE](features/EXECUTION_LIFECYCLE.md) |
| 5 | 레이드 분석 후속: 타임라인, 크리·코어·사거리, 버스트 구간, 행동 시간표 | 기존 표본의 다단히트·지연 발사·지연 폭발 재현, 한 피해의 중복 분류 없음, 긴 로그 범위 조회 | [RAID_RECORDS](features/RAID_RECORDS.md) |
| 6 | 유니온 탭의 보스별 기록 패널 | 유니온 mode 기록을 5보스별로 조회, 솔로와 공통 조회 계층 사용 | [RAID_RECORDS](features/RAID_RECORDS.md) |
| 7 | 분석 작업 큐와 BattleLog 보존 정책 | 결과 수신 시 동기 분석 대신 복구 가능한 큐, 용량 관리·정리 정책 | [RAID_RECORDS](features/RAID_RECORDS.md) |
| 8 | 캐릭터 목록 동기화 후 얼굴 초상화 자동 생성 | 동기화가 `raid_portrait_assets.py` 결과까지 갱신하거나 결손을 표시 | [ACCOUNTS](features/ACCOUNTS.md) |
| 9 | 저장소 점검·정리·최적화 | 운영자 지시대로 공통 실행 통합 이후 수행. 현재 참조·복구 필요성을 다시 확인하며 과거 용량 후보 조사를 삭제 승인으로 보지 않음 | [용량 후보](archive/stabilization/PROJECT_STORAGE_AUDIT_20260914.md) |

참고: CI의 Windows 검증 job은 제한 15분 중 약 12분을 씁니다(run `36324475337`). 검사를 추가할 때 시간 여유를 확인합니다.

## 운영자 확인 대기

에이전트가 게임을 실행하지 않습니다. 결과는 시즌·약점·실패 시점과 화면 증상으로 전달합니다.

- 152에서 S9·S25·S34·S41의 전투·실드 FX·종료 후 기록 복원(S10·S27은 확인 기록 없음).
- 버전 독립 영속성과 로비 Quit 규칙(0~4덱 참여만 소모, 5덱 완주 1회).
- 유니온 하드 전 구간: 보스 선택 → 편성 → 입장 → 완료/중도 종료 → 남은 HP·횟수 → 기록·랭킹 → 재실행 복원 → 연습전 비반영.
- 새 서버의 솔로 모의전 수집(새 덱·5명 통계·원문 저장)과 피해 구성 v3 화면.
- 실계정 가져오기/동기화 저장 완료, Import CLI 교체 뒤 캐릭터 목록 동기화.
- 2026-09-22 재부팅 복구 이후 게임 재실행.
- 공식 게임을 별도 Windows 계정에서 실행(격리 방향 결정 후 실행 결과 기록 없음).

## 보류 (운영자 결정)

- 시작 요청→게임 창 생성 구간(약 32초)의 추가 단축 조사.
- 새 기능 구상: [기존 기능 로드맵](archive/FOLLOWUP_AUTOMATION_BOSS_ACCOUNT_ROADMAP.md). 보관은 요구 폐기가 아닙니다.

## 미정 결정

[DECISIONS](DECISIONS.md)의 "남은 미정사항"을 따릅니다. 미정값은 임의 기본값으로 채우지 않고 `unresolved`로 둡니다.
