# Private server and original-client UI contract

## 제품 정의

Nikke Local Lab의 최종 제품은 별도 게임 화면이나 독립 전투 시뮬레이터가 아닙니다. **원본 NIKKE 클라이언트가 제한된 로컬 사설 서버에 접속하고, 원본 전투 UI·asset·전투 runtime을 권위로 사용해 지원 기능만 실행하는 환경**입니다. 로비는 아래에 선언한 approved presentation variant를 사용하므로 retail lobby를 픽셀 단위로 그대로 보존한다는 뜻은 아닙니다.

이 문서는 제품 목표의 규범 계약입니다. Phase 2A2와 Phase 2B source-free boot/lobby/season/daily/Challenge backend·lab-owned harness는 완료했습니다. original-client wire/presentation adapter와 실제 전투 runtime 연계는 계속 blocked입니다. 구현 순서는 [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md), 실행 가능성은 [FEASIBILITY_GATES.md](FEASIBILITY_GATES.md)를 따릅니다.

    original NIKKE client
      - original lobby, character views and battle HUD
      - original assets, animation and combat runtime
      - client-local damage calculation and display
                    |
                    v
    approved client compatibility boundary
                    |
                    v
    Nikke Local Lab private server
      - synthetic local session and account state
      - profile, roster, build and inventory projection
      - supported Solo Raid season directory and Challenge state
      - battle admission, attempt state, result and trace persistence

`Nikke-Dmg-Simulator`와 lab-owned harness는 데이터 해석, 최적화, 회귀 검사와 결과 대조를 위한 sidecar입니다. 둘 중 어느 것도 원본 클라이언트 화면이나 최종 전투 runtime을 대체하지 않습니다.

## 시작 흐름

사용자-facing 상위 흐름은 다음으로 고정합니다.

    실행 -> 로딩 -> 로컬 접속 -> 메인 로비

실제 client build가 별도의 launcher/resource 검사 화면을 요구하면 공식 outbound가 없는 승인된 offline/local-test route로 Gate A를 통과한 경우에만 그 화면을 유지합니다. Local Lab은 공식 계정 인증을 모방하지 않고 자체 local session만 발급합니다. 지원·승인된 client route가 확인되기 전에는 이 흐름을 원본 리테일 client에서 실행하지 않습니다.

Phase 2B lab API의 access token은 process-local HMAC key로 서명합니다. 같은 process에서 같은 Open operation을 replay하면 최초 token byte를 재사용하지만, restart 뒤에는 영속 session/context/issued/expires를 복원해도 token이 재서명될 수 있습니다. 이 lab contract는 original-client 인증 packet을 모방하지 않습니다.

## 메인 로비

### 유지

- 좌상단 profile portrait, 지휘관 level과 local display name
- 상단 재화 표시. 값은 Local Lab 합성 account state가 공급합니다.
- 중앙 lobby character, background와 원본 Live2D/animation
- 하단 `니케`, `스쿼드`, `로비`, `인벤토리`, `대원모집`

`대원모집`은 원본 눌림 효과와 click feedback을 유지할 수 있지만 page transition은 하지 않는 controlled no-op입니다. timeout, 빈 화면, network 오류로 표현하지 않습니다.

### 제거

- pickup과 pass를 포함한 모든 홍보 banner
- 공지 이동 bar
- 좌측 기존 stack 전체: Messenger, TTS, Costume Pick, Trail Marker, event와 More shortcut
- 우상단 알림, 우편과 전체 메뉴
- 우측 친구, Union, Event shortcut
- Cash Shop, Shop, Outpost/Outpost Defense
- Ark, Operation/작전출격을 포함한 나머지 대형 lobby card

서버 feature state로 안전하게 숨길 수 있는 항목은 서버에서 닫습니다. 고정 prefab의 빈 공간 재배치, click handler no-op 또는 아래 season folder처럼 원본 구조에 없는 표현은 승인된 client UI variant가 소유합니다. 빈 응답이나 오류를 이용해 우연히 숨기지 않습니다.

### Solo Raid folder

기존 좌측 shortcut 영역은 다음 source-free season directory로 교체합니다.

    [솔로 레이드]
    ├─ 시즌 7 솔로레이드
    │  (울트라)
    ├─ 시즌 13 솔로레이드
    │  (인디빌리아)
    ├─ 시즌 26 솔로레이드
    │  (프로비던스)
    ├─ 시즌 29 솔로레이드
    │  (마더웨일 전격 변종)
    ├─ 시즌 34 솔로레이드
    │  (앨트루이아)
    └─ 시즌 40 솔로레이드
       (사치스러운 거미)

season number와 encounter identity는 published `RaidSnapshot`에 결박합니다. 보스 localized 표시명, icon과 lobby presentation은 snapshot이 현재 완전하게 소유하지 않으므로 Phase 3의 Git 비추적 client-presentation binding 또는 별도 lab-owned presentation version으로 해소합니다. 원본 ID를 public API에 노출하거나 이름만으로 snapshot을 연결하지 않습니다. directory에는 여러 시즌을 동시에 표시할 수 있지만, 클래식 Solo Raid 화면에 투영되는 실행 context는 사용자가 선택한 **한 시즌**입니다. canonical state는 account/session 소유 `SelectedRaidSeason`입니다. Phase 2A2 config가 `oneSelectedSeasonPerClientContext`를 선언했고 Phase 2B service는 exact snapshot 선택·CAS history·context/run pinning을 구현하며, season 7이나 첫 ordinal을 기본으로 추측하지 않습니다.

v1 published directory는 정확히 시즌 `7, 13, 26, 29, 34, 40`입니다. 새 dataset에서 admission candidate가 발견돼도 자동 노출하지 않으며 evidence review, catalog revision과 명시적 directory version 변경 뒤에만 추가합니다. 자세한 snapshot·선택 계약은 [RAID_DOMAIN.md](RAID_DOMAIN.md)를 따릅니다.

## Solo Raid 화면

시즌 선택 뒤에는 신규 `SoloRaidMuseum` 화면을 재구현하지 않고 원본 시즌제 `SoloRaid` 화면을 우선 사용합니다.

    season selection
      -> Solo Raid main
         -> Challenge ready page
            -> squad edit / challenge entry
               -> original battle HUD
                  -> regroup and next squad when applicable
                     -> result and local record

Mock Battle은 Quick Battle과 다른 operational-policy 축입니다. configured `unsupported`에서는 닫히고, `lab_owned_only`에서는 Phase 2B harness mock run만 daily quota를 우회하고 절대 소비하지 않는 계약으로 허용합니다. 이 backend capability만으로 원본 ready page의 button을 지원한다고 보지 않으며, Phase 3 presentation/wire 검증을 통과한 경우에만 UI에 노출합니다.

원본 client에 존재하는 boss 정보, stage 정보, 편성, 전투 진입, 재정비, 결과, 보상과 ranking view는 가능한 범위에서 그대로 유지합니다. Local Lab이 지원하지 않는 live-service 기능은 아래 정책에 따라 명시적으로 닫습니다.

## 고정 서비스 정책

### Normal과 Challenge

- 전투 모드는 `challenge`만 지원합니다.
- Normal I~VII 전투 session, 보상과 결과 API는 구현하지 않습니다.
- 모든 local account의 기본 unlock projection은 `lastClearLevel=7`입니다.
- 따라서 `challengeUnlocked=true`가 기본이며 별도의 Normal clear 작업을 요구하지 않습니다.
- 이 값은 공식 account 진행도를 복사하거나 변경하는 값이 아니라 합성 local session의 UI compatibility state입니다.

### 시즌 수명

- published 지원 시즌은 종료되지 않는 영구 local content입니다.
- `SeasonAvailability=permanent`이고 `seasonEndsAt=null`이며 만료 job을 만들지 않습니다.
- 원본 UI가 종료 timer를 필수로 요구하면 승인된 client variant가 `상시` 또는 timer 숨김으로 표현합니다. 임의의 먼 미래 시각을 가짜 종료 시각으로 저장하지 않습니다.
- 시즌 선택은 directory에서 언제든 바꿀 수 있으며 과거 시즌이라는 이유로 잠그지 않습니다.

### 일일 상태

- 일일 경계의 권위 timezone은 IANA `Asia/Seoul`입니다.
- reset local time은 매일 `05:00:00`입니다.
- 서버는 각 instant를 KST calendar date와 reset boundary로 변환해 attempt counter를 계산합니다. process local timezone이나 단순 UTC date를 사용하지 않습니다.
- reset은 Challenge 일일 attempt와 그 밖에 명시적으로 daily로 분류된 local state에만 적용합니다. profile/build, 최고 기록, 시즌 선택과 published snapshot은 변경하지 않습니다.
- entry limit·소비 시점, active run의 reset 처리와 여섯 시즌 counter 공유 범위는 `ChallengeOperationalPolicy`가 모두 해소됐을 때만 입장에 사용합니다. checked-in `unresolved` 정책에서는 값을 추측하지 않고 새 run만 controlled unavailable로 둡니다.
- 빈 DB의 초기 configured policy는 여섯 축을 모두 명시한 경우 현재 raid day에 효력을 가질 수 있습니다. 운영 중 admin 전환은 current activation revision CAS를 요구하고 다음 raid day로만 예약합니다.

### Quick Battle

- Quick Battle은 지원하지 않습니다.
- Normal 전투가 없고 I~VII가 이미 clear된 compatibility state이므로 Quick Battle endpoint, reward와 persistence를 만들지 않습니다.
- 원본 UI의 Quick Battle button은 숨기거나 disabled/no-op으로 투영하며 호출 실패로 표현하지 않습니다.

### Ranking과 보상

공식 global ranking과 공식 reward delivery는 지원하지 않습니다. 원본 result/ranking view를 유지해야 할 때는 Local Lab의 자체 record만 표시하며 공식 player, guild, mail 또는 reward economy를 모방하지 않습니다. 구체적인 local ranking 범위는 Phase 2B 계약에서 versioning합니다.

## 서버와 client의 책임

| 책임 | Local Lab server | Original client / approved UI variant |
|---|---|---|
| local account, profile, currency와 build 상태 | authoritative | 표시 |
| 지원 season directory와 선택 상태 | authoritative | folder/list 표시와 navigation |
| Normal clear stub과 Challenge unlock | authoritative | 기존 unlock UI에 투영 |
| daily reset 05:00 KST | authoritative | 남은 횟수 표시 |
| season end 없음 | authoritative | timer 숨김 또는 `상시` 표시 |
| Challenge attempt, used characters, boss HP/누적 damage | Phase 2B에서 harness receipt·persistent aggregate를 검증; Phase 4 observation adapter가 client observation을 별도 provenance로 수락 | 기존 Solo Raid 화면과 전투에 투영하고 damage를 산출 |
| 전투 simulation, damage 계산·표기, animation과 HUD | damage를 계산하지 않고 result/trace만 수신·보존 | authoritative runtime |
| 고정 lobby widget 제거·재배치 | feature state 제공 | approved UI variant |
| Recruit no-op | capability를 unsupported로 선언 | click 후 page transition 차단 |

## 구현 게이트

원본 client 안에 이미 있는 Solo Raid view와 서버 상태를 연결하는 작업, 그리고 로비 season folder/UI 정리는 서로 다른 gate입니다.

1. Phase 2B는 원본 client 없이 private-server state machine과 API를 `lab_harness_observation/v1`로 검증했고 최종 단위/live PostgreSQL gate를 통과했습니다.
2. Phase 3A는 client 실행 없이 승인 route/build/outbound 증거와 UI variant capability를 감사합니다. 현재 verdict는 `blocked_insufficient_evidence`입니다.
3. 3B는 transport/handshake, 3C는 boot/session/account projection, 3D는 lobby/season presentation, 3E는 Challenge ready/open/first-team handoff를 각각 검증합니다.
4. Phase 4는 원본 client에서 실제 battle/HUD/damage, regroup/result와 runtime integrity를 사용자가 직접 검증합니다.

지원·승인된 client route 또는 UI variant가 없으면 서버 개발 결과를 보존하되 최종 제품 상태는 `blocked`입니다.

profile/build와 실행 입력의 상세 경계는 [PROFILE_EXECUTION_DOMAIN.md](PROFILE_EXECUTION_DOMAIN.md)를 따릅니다.
