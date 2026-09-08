# 작업 인계

최종 갱신: 2026-09-08. 이 문서는 짧은 현황 요약이며, 상세 기록을 계속 덧붙이는 로그가 아닙니다.
작업 전 읽기 순서·불변 규칙은 [AGENTS](../AGENTS.md), 문서 위치는 [색인](README.md)을 따릅니다.

## 확인된 현재 상태

- 운영자가 관리도구 → **151 / S26 실게임 검증 완료**를 확인했습니다. 리소스 대응은 종료했습니다.
- 기존 진행도와 150 완주 최고 기록을 이어받는 경로를 유지합니다.
- 검증된 Epinel DLL·실행 조합을 불필요하게 다시 변경하지 않습니다.
- 활성 OS는 Micron입니다. 저장소·client·bundle·백업의 정확한 위치는 [현재 경로](MICRON_CURRENT_PATHS.md)만 기준으로 합니다.
- 위 완료는 운영자의 실게임 확인이며, 새 자동 관측 receipt나 모든 보스·음성·약점 조합의 검증을 뜻하지 않습니다.

## 지금 할 작업

[안정화 계획](STABILIZATION_PLAN.md)의 회귀 검사·실행 생명주기·저장 일관성·성능 측정을 진행합니다.
1차 구조 점검은 끝났지만 전체 파일 검토, DB 무결성 검사와 최적화 구현은 남아 있습니다.
확인된 현행 흐름은 [아키텍처](ARCHITECTURE.md)에 있습니다.

S-03의 실행 입력 snapshot에 이어 S-07의 Save 순서 조정기와 단계 adapter를 분리했습니다.
claim만 남은 재시도의 검증 누락과 다른 저장의 끼어들기를 재현·보강했습니다. 완료된 child는
exact replay하고, 실행 중 경합은 즉시 거절하며 pending을 임의로 삭제하지 않습니다.
후속 소스는 UI의 preview 없는 exact 재시도와 V0018의 원래 요청 영속 보존을 추가했습니다.
신규 pending은 창을 다시 열어도 조회 후 명시적으로 이어 저장하고, 원문 없는 구형 pending은
자동 삭제·추정 복원하지 않습니다. 완료 receipt 조회와 Save As source/복제본 구분을 유지합니다.
운영자 승인으로 원문 없는 구형 pending 3행만 정리한 뒤, **준비된 앱 파일 15개와 V0018을 운영에
적용**했습니다. 현재 스키마는 **18**, 정상 Save 75건·pending 0건이며 관리도구와 DB는 정상 종료했습니다.
기존 132개 테이블은 migration 이력 외 행/시퀀스가 동일하고, 시험용 Save/복제 계정은 운영 DB에 만들지 않았습니다.
격리 DB의 실제 HTTP/editor 화면에서 Save 응답 유실 exact 재전송, Save As 원본 보존,
서버·창 재시작 후 신규 pending 복구를 검증했습니다. 설치 WebView2에서는 Windows 접근성 API로
계정·콘솔·큐브·니케·레이드 화면 조회와 저장 버튼 활성화를 확인했습니다. 운영 화면의 Save 클릭과
실게임은 제외했습니다. 클라이언트·Epinel DLL·선택 설정·제품 소스는 이번 배포에서 변경하지 않았습니다.
배포 전후 단위 453개·UI 행동 10개·폐기 PostgreSQL 105개와 전체 계약 검사를 통과했습니다.
세부 검증 결과와 정확한 복원 경로는 안정화 계획을 따릅니다. 실게임 인수는 별도로 남아 있습니다.
배포 직전 복원 기준은 **정리 후 스키마 17·pending 0건 백업**이며, 적용 후 스키마 18 cold 백업도 D:에
보존했습니다. 예전 pending 3건 백업을 현재 배포 기준선으로 혼용하지 않습니다.

후속 UI 요청으로 완료 이력만 있는 ‘저장 상태’ 패널을 숨겼습니다. 처리 중·pending·같은 창의
재시도 안내는 유지하며, 설치본 `editor.js` 1개만 반영했습니다. 다음 관리도구 열기부터 적용됩니다.
이 변경은 단위 453개·UI 행동 12개·계약 검사를 통과했고 DB·클라이언트·DLL은 변경하지 않았습니다.
이번 UI 수정에서는 PostgreSQL 통합 검사를 다시 실행하지 않았습니다.

2026-09-07 후속 실기동에서 종료 감시기 인계 전 실패가 발생해 `started`와
`phase_d_emergency_rollback_failed`가 남고 관리 DB도 중지됐습니다. 운영자 요청으로
현재 실행 `5140655a-5b0a-4003-a6e0-5276811fc4ee`만 복구했습니다. 경로·시작 시간이
일치하는 잔류 Epinel 서버를 종료하고, 기존 orphan recovery로 데이터를 capture/replay한 뒤
`completed`, pending 없음, hosts 기준선 복원, PostgreSQL `SELECT 1` 성공을 확인했습니다.
복구 전 cold DB 2,201개 파일과 실행 데이터 백업은
`D:\NikkeLocalLab\Backups\stale-execution-5140655a-20260907-02`에 보존했습니다.
이 복구 시점에는 제품 코드·클라이언트·DLL을 변경하지 않았고 게임도 재실행하지 않았습니다.
당시 최초 예외의 정확한 native 오류는 아직 확정하지 않았습니다.

후속 승인으로 **종료 후 상태 고착 재발 경로를 수정하고 설치에 반영**했습니다.
프로세스 capture/wait는 제한 권한 handle을 쓰고, 서버 신원을 먼저 보존합니다. client와
coordinator/watcher가 없을 때 증명된 단일 잔류 서버만 정리하며, rollback 후 pending 유무와
관계없이 관리 DB를 준비합니다. 최초 실패 원인을 cleanup 오류와 분리 보존하고, active 실패는
‘실행 상태 확인 필요’로 표시합니다. 신원 불명 상태의 새 실행 차단은 유지합니다.
설치 파일 351개 중 Admin DLL/PDB/editor JS **3개만 교체**했고 의존 DLL·asset은 보존했습니다.
실행 스크립트 5개는 저장소의 동일 source hash로 소비합니다. 단위 **459개**(Admin 97 포함),
저장 UI 12개·lifecycle UI, 변경 C# 서식·전체 계약 검사가 통과했습니다. 폐기 PG **105/105**와
실제 stop/start checkpoint 보존·정리를 확인했습니다(최종 receipt `2c20c3d9720c495da5628fe8d6d312d9`).
첫 PG 실행은 테스트 통과 후 종료 30초를 초과했고, 기존 60초 옵션으로 재검증해 통과했습니다.
검증 근거·설치 파일 hash·D: 백업 경로는
`artifacts/stabilization/2026-09-07-lifecycle-recurrence/`에 있습니다. 앱 before backup과
수정 후 스크립트를 혼용해 전체 rollback이라고 부르지 않습니다.
현재 관리도구·PG·게임은 종료 상태입니다. 이번 코드/앱 반영에서 운영 DB·클라이언트·Epinel DLL은
변경하지 않았습니다. 당시 **실게임 종료 후 재실행 인수와 Solo Raid 참가 데이터의 null 예외는
남았습니다.** 이후 JoinData 인수와 종료 복구 보강은 아래 후속 상태를 따릅니다.

후속 `JoinData` 수정 요청으로 날짜 초기화와 기존 run 재개 조건을 분리했습니다. 오늘의
`TrialCount=0`이어도 구조가 유효한 기존 Trial은 새 생성·횟수 차감 없이 재개하고, 직접
Trial 진입도 일일 초기화를 적용합니다. 이미 저장된 상태는 별도 DB 보정 없이 읽습니다.
진행 중 run·사용 덱·딜·기존 최고 기록의 보존과 재시작/protobuf 응답을 검증했습니다.
회귀 16개 포함 selected-manager **134/134**, Local Lab 단위 418개·저장 UI 12개·전체
계약 검사가 통과했습니다. 별도 handler 검사에는 수정 전부터 있던 실패 2건이 그대로
남아 있습니다(리소스 버전 key, classic handler 개수). PostgreSQL 통합 검사는 다시
실행하지 않았습니다. 서버 DLL 정적 대조에서는 메서드 113,438개 중 관련 4개 본문만
변경됐습니다. 재적용 가능한 소스·합성 검사 패치는 `patches/epinel-classic-solo-raid-rollover.patch`입니다.
관리도구의 선택은 **PhaseD151-v5**로 반영했고 v4 96개 파일 중 DLL·source manifest
2개만 달라졌습니다. v4와 선택 파일 백업은 `D:\NikkeLocalLab\Backups\join-data-rollover-20260907-v4`,
검사·배포 receipt는 `artifacts/stabilization/2026-09-07-join-data-fix/`에 있습니다.
운영 DB·게임 클라이언트 DLL·리소스·rollback 코드는 변경하지 않았으며 게임도 실행하지
않았습니다. 이후 운영자가 **실게임 덱 완주를 확인**했습니다. 이를 5덱 전체·모든 조합의
인수로 확대하지 않으며, 검증된 v5 서버와 게임 DLL은 유지합니다.

후속 종료 복구 수정은 진단 app log/marker가 모두 없을 때 `not_observed`를 남기고 정상
cleanup을 계속하도록 합니다. 전투 관측 성공을 만들지 않고, 기존 잘못된 marker와 명시적
전투 검증 실패는 계속 거절합니다. 동일 시작 시각의 이미 종료된 kernel handle은 경로를
다시 요구하지 않고 정리하며, live 신원 검사와 PID 재사용 차단은 유지합니다. cleanup의
rollback/hosts/DB 실패는 최초 원인과 별도 파일에 남깁니다. 적용 범위는 저장소 실행 스크립트
3개와 새 순수 완료-template helper뿐이며 설치 앱·DB·v5 bundle·원본 완료 도구는 바꾸지 않습니다.
검증·복원 근거는 `artifacts/stabilization/2026-09-07-completion-recovery/`와 안정화 계획을
따릅니다. 이후 운영자가 **“문제 없다”로 확인하고 S-04/S-05 착수를 승인**했습니다.
이를 모든 보스·속성·종료 시점의 인수로 확대하지 않습니다.

현재 S-04/S-05는 1차 전환입니다. 보스·속성·bundle 구성 판정을 UI 준비 명령,
Start와 coordinator가 공유하고, 실행문 생성부는 명시적 versioned 입력을 받는 순수 adapter로
분리했습니다. S26/151 구성은 통과하고 S29 기존 불일치는 차단합니다. 부모 템플릿과의
출력 동등성은 합성 및 실제 고정 템플릿의 4조합에서 확인했습니다. 상세·남은 검증은
[안정화 계획 S-04/S-05](STABILIZATION_PLAN.md)를 따릅니다. 2026-09-08 운영자 “1번 진행” 승인으로
**설치 앱 4개 파일을 반영**했고 나머지 347개 파일을 보존했습니다. 백업·hash는 로컬
`artifacts/stabilization/2026-09-08-preparation-contract/installed.json`을 따릅니다.
저장소 coordinator도 새 helper를 읽으므로 앱/스크립트 복원 세트를 혼용하지 않습니다.
공통 parameterized runner로의 완전 전환과 실게임 인수는 아직 남아 있습니다.
운영자 화면에서 계정 선택 후 S26/철갑 준비 완료와 S29 기존 불일치 차단을 확인했습니다.
계정 미선택 시 ‘확인 중’이 남는 UI 문구는 동작 테스트로 재현·수정했으며 editor JS만 추가
반영했습니다(`account-prompt-installed.json`). 열린 창의 계정 선택은 유지하며 다음 관리도구
실행부터 ‘계정을 선택하세요’로 안내합니다. 전체 UIA 자동 행렬 통과나 새 실게임 성공은 주장하지 않습니다.
후속으로 계정 선택 후 최근 실행 이력이 있는 경우의 ‘확인 중’ 고착도 재현·수정했습니다.
현재 준비 상태를 제목으로, 과거 완료/실패 결과를 보조 설명으로 표시하고 live 실행/복구 경고는
우선합니다. 새 동작 검사 6개를 Phase 2A2 gate에 추가했으며, editor JS 단독 배포 근거는
`artifacts/stabilization/2026-09-08-raid-status-summary/`에 둡니다. 실게임 로직·DB 변경은 없습니다.

## 별도 보류

- S29 profile v3와 registry v2 불일치, 미완료 속성 실드 확장
- 신규 보스와 전투 분석 UI 등 기능 추가
- 150 client의 D: 이동: 남은 C: 150 실행 의존성 제거와 검증 후에만 진행

## 상세 근거

- [151 대응·배포·검증 이력](archive/RESOURCE_COMPATIBILITY_151_PROGRESS.md)
- [백엔드 결함 이력](features/CONTROL_CENTER_BACKEND_DEFECTS.md)
- [솔로레이드 영속화·분석 필드](features/SOLO_RAID_PERSISTENCE_AND_ANALYTICS.md)
- [이전 인계 전체 기록](archive/HANDOFF_2026-09-06.md)

과거 문서의 ‘다음 실행’, 오래된 OS 경로, 당시 blocked 판정을 현재 작업 지시로 재사용하지 않습니다.
