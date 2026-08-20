# Phase 3 — approved original-client adapter

## 상태와 목적

Phase 3은 하나의 대형 adapter 작업이 아니라 다섯 개의 중단 가능한 수직 단계로 진행합니다. 현재는 3A 증거 감사를 완료했고 판정은 `blocked_insufficient_evidence`입니다. 따라서 3B 이후 코드는 아직 시작하지 않습니다.

Phase 3의 목표는 승인된 local/test client 경로에서 Local Lab의 source-free backend 상태를 원본 UI에 연결하는 것입니다. stock retail client 우회, 공식 credential 또는 protocol replay, endpoint/auth 변조, injection·hooking·memory patch, launcher·anti-cheat 우회는 어떤 단계에서도 허용하지 않습니다.

각 단계는 별도 branch를 사용하고, 그 안의 각 batch를 focused commit과 gate로 닫습니다. 한 단계에 여러 batch/commit이 있을 수 있습니다. 종료 조건을 통과하지 못하면 그 자리에서 멈추며, 뒤 단계 구현으로 증거 부족을 덮지 않습니다.

## 3A — 승인 경로 증거와 실행 가능성 감사

예상 작업 시간은 저장소 감사 기준 `0.5~1.5시간`입니다. 외부 승인 취득 시간은 포함하지 않습니다.

진입 조건:

- Phase 2B unit/live gate 통과
- `originalClientCompatibility.enabled=false`, `status=blocked` 유지
- client 실행, 네트워크 연결 또는 adapter 구현 없이 기존 증거만 읽기

종료 결과는 둘 중 하나입니다.

- `ready_for_phase3b`: 권리자가 지원·승인한 local/test route, exact build closure, synthetic-session 경계와 official outbound-zero 검증 계획이 모두 확인됨
- `blocked_insufficient_evidence`: 하나 이상의 필수 증거가 없으며 3B 이후를 시작하지 않음

UI variant의 존재 여부도 여기서 capability로 감사하지만 실제 presentation 구현은 3D가 소유합니다. 상세 판정과 재개 조건은 [PHASE3A.md](PHASE3A.md)를 따릅니다.

## 3B — 승인된 local transport와 handshake

조건부 예상은 `2~4시간`입니다. 3A가 `ready_for_phase3b`일 때만 의미가 있습니다.

진입 조건:

- 승인 범위와 exact client build/content closure 고정
- 지원되는 selector/interface와 wire contract 제공
- client process tree 전체의 외부 egress를 차단·관측할 격리 환경 준비

종료 조건:

- 지원된 경로로 Local Lab adapter handshake에 도달
- build/content mismatch를 연결 전에 fail closed
- synthetic local session만 사용하고 공식 identity/session material은 사용하지 않음
- client/launcher/관련 child process의 외부 egress를 차단하고 official server·telemetry 연결·전송이 0임을 재현
- build-local compatibility value는 Git 비추적 local binding 안에서만 사용

wire interception/replay나 endpoint/auth 변경이 필요하면 즉시 blocked로 돌아갑니다.

## 3C — Boot와 synthetic session 수직 슬라이스

조건부 예상은 `3~5시간`입니다.

진입 조건:

- 3B handshake와 격리 검증 통과
- 승인된 boot/open/connect contract와 exact adapter contract 고정

종료 조건:

- 원본 client loading에서 Local Lab boot/open/connect까지 연결
- Phase 2B의 exact application build, capability manifest와 bootstrap revision set에 결박
- profile, wallet, roster, squad와 inventory subset이 source-free wire projection으로 전달
- lost-response replay, expiry와 restart 후 재서명 경계가 기존 Phase 2B 계약과 일치
- raw client reference, 경로, 공식 ID와 credential이 domain/API/log/fixture에 없음

## 3D — Lobby와 season presentation 수직 슬라이스

승인된 presentation variant가 이미 존재할 때 조건부 예상은 `4~8시간`입니다. 새 variant 설계·승인이 필요하면 별도 discovery 뒤 재견적합니다.

진입 조건:

- 3C 통과
- 고정 prefab 재배치를 허용하는 승인된 presentation path 확인
- exact build에 결박된 Git 비추적 presentation binding 준비

종료 조건:

- 원본 lobby 도달과 keep/remove/replace UI 계약 일치
- 시즌 `7, 13, 26, 29, 34, 40`의 folder/list 표시
- 기본 시즌 추측 없이 사용자가 한 시즌을 명시적으로 선택
- permanent 표시, Quick Battle 제거/disabled, Recruit feedback 후 no-navigation
- 오류, timeout 또는 빈 payload를 UI 구현으로 취급하지 않음

## 3E — Challenge admission과 battle handoff

조건부 예상은 `3~6시간`입니다.

진입 조건:

- 3D 통과
- configured operational policy와 exact snapshot/profile/squad/runtime/control revision 준비
- 승인된 Challenge main/ready/open/enter wire contract 고정

종료 조건:

- 선택 시즌의 원본 Solo Raid main/ready 화면 연결
- exact run open과 첫 5인 squad enter
- context, snapshot, squad, build, runtime/control revision pinning 확인
- Normal과 Quick Battle은 controlled unsupported 유지
- original battle runtime으로 넘기기 직전의 handoff 경계까지 도달
- Phase 4를 바로 이어서 실행하지 않으면 열린 run을 controlled abandon/recovery로 terminal 처리하여 active slot을 남기지 않음

operational policy가 unresolved이면 3E는 시작 전에 blocked입니다. 실제 battle scene/HUD/damage, versioned observation receipt, regroup와 후속 팀, close/result/local record adapter와 실플레이 검증은 Phase 4 소유입니다. Phase 2B `lab_harness_observation/v1` receipt를 original-runtime 증거로 이름만 바꾸지 않습니다.

## feasibility gate 매핑

Gate A~D와 3A~3E는 일대일 단계가 아닙니다.

| Feasibility gate | 담당 단계 |
|---|---|
| Gate A — approved isolated route | 3A에서 권한·route 적격성을 판정하고 3B에서 transport와 outbound-zero를 재검증 |
| Gate B — client wire | 3B handshake, 3C boot/session, 3D directory/selection, 3E Challenge open/first-team enter, Phase 4 observation/regroup/next-team/close/result |
| Gate C — presentation | 3A에서 승인 capability 존재를 확인하고 3D에서 구현·검증 |
| Gate D — original runtime integrity | 요구 증거는 3A에서 목록화하되 실제 통과는 Phase 4 |

Phase 3 완료는 3A~3E 종료 조건을 뜻합니다. Gate B의 actual damage/result 항목과 Gate D의 runtime integrity는 Phase 4 실제 플레이 증거가 있어야 최종 통과합니다.

## 작업 단위와 시간 제한

- 3A의 승인 증거 확인을 첫 `30분` fail-fast checkpoint로 둡니다.
- 이후 batch는 한 evidence question 또는 한 observable screen transition만 소유하고 `60~90분` 안에 결론을 냅니다.
- 구현 batch는 최대 `2~4시간`이고 한 focused commit으로 닫습니다. branch는 단계당 하나를 사용합니다.
- shared adapter contract는 한 agent만 편집하고 client 실행도 한 담당자만 직렬 수행합니다. 나머지는 disjoint test/docs 또는 read-only audit에 한정합니다.
- focused contract test는 매 batch 실행하고 전체 baseline gate는 3C와 3E 종료 시 실행합니다.
- exact build/content manifest가 바뀌면 즉시 3A를 다시 엽니다.
- 먼저 사용자가 명시적으로 고른 한 시즌으로 transport를 검증한 뒤 같은 contract로 여섯 시즌을 data-driven 검증합니다. 어떤 시즌도 기본값으로 추측하지 않습니다.

승인 route, stable exact build, supported wire/presentation 자료와 준비된 격리 환경이 모두 제공된 뒤의 Phase 3B~3E 및 안정화 engineering time은 조건부로 약 `14~27시간`입니다. 승인·provider 대기, discovery spike, local evidence/build-closure 준비, 격리 환경 구축, 사용자/client 가용 시간과 Phase 4 actual-play parity는 포함하지 않습니다. 현재처럼 승인 증거가 없는 상태에서는 3B~3E 일정은 `N/A (blocked)`이며, 시간을 투입해 우회 구현하는 선택지는 없습니다.
