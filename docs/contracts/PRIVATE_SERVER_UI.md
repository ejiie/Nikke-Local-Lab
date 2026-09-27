# Private server and original-client UI contract

2026-09-17 추가 UI 범위: 유니온 탭은 최신순 스크롤 시즌 목록과 `시즌 N 보스를 불러오시겠습니까?` 확인을 제공한다. 예를 눌렀을 때만 원본 행동 트리까지 5보스를 조립한다. 취소는 변경하지 않는다. [유니온 하드 계획](../operations/UNION_RAID_HARD_IMPLEMENTATION.md)이 이번 확장의 권위이며, 아래 과거 Phase의 Union 비지원 표시는 역사적 인수 범위다.

## 제품 정의

Nikke Local Lab의 최종 제품은 별도 게임 화면이나 독립 전투 simulator가 아닙니다. **원본 NIKKE 클라이언트가 격리된 로컬 compatibility façade에 접속하고, 원본 시즌제 클래식 Solo Raid UI·asset·전투 runtime으로 지원 Challenge를 실행하는 환경**입니다.

원본 client는 UI, asset, animation, battle simulation, damage 계산·표기의 권위입니다. Local Lab은 synthetic local account, profile/build, 선택 시즌, Challenge run identity와 durable result/trace의 권위입니다. 다음 spike는 exact commit을 고정한 외부 AGPL EpinelPS process가 original-client compatibility façade를 제공할 수 있는지 검증합니다. 현행 위험 수용과 외부 dependency 경계는 [PHASE3AR.md](PHASE3AR.md), 단계별 실행은 [PHASE3.md](PHASE3.md)를 따릅니다.

```text
original NIKKE client 150.6.9
  - original lobby and classic Solo Raid UI
  - original assets, animation, HUD and combat runtime
  - client-local damage calculation and display
                    |
                    v
external pinned EpinelPS compatibility façade
                    |
                    v
narrow Local Lab bridge (live proof 뒤 구현)
                    |
                    v
Nikke Local Lab Phase 2B
  - synthetic account/profile/build state
  - selected classic Solo Raid season and run identity
  - result/trace persistence and sidecar comparison
```

EpinelPS source, generated protocol source, certificate, patched native binary와 client patch output을 Local Lab 저장소에 복사하지 않습니다. `Nikke-Dmg-Simulator`와 lab-owned harness는 데이터 해석, 최적화와 회귀 검사용 sidecar이며 original UI/runtime을 대체하지 않습니다.

## 강제 콘텐츠 경계 — classic Solo Raid only

목표 콘텐츠는 원본 시즌제 **클래식 `SoloRaid` Challenge** 하나입니다.

`SoloRaidMuseum`은 GitHub 프로젝트가 임의로 붙인 이름이 아니라 실제 NIKKE의 별도 공식 콘텐츠입니다. 이 모드는 결과에 영향을 주는 전용 버프를 적용하므로 다음 모두에서 제외합니다.

- 기술 feasibility proof
- 시즌 선택 fallback
- 전투 parity 또는 damage 비교
- 화면 전이 acceptance
- 여섯 시즌 확장 경로

Museum에서 동일 보스 또는 비슷한 encounter가 실행되더라도 classic Solo Raid 성공으로 인정하지 않습니다. Museum API/handler가 호출되면 해당 proof는 실패입니다.

## 첫 acceptance target

첫 검증 대상은 **시즌 26 클래식 Solo Raid Challenge**입니다.

시즌 26은 client 실행 전에 다음 exact chain이 같은 client build/content set에서 완결되어야 합니다.

```text
season 26 manager
  -> preset
  -> Challenge wave
  -> monster/stat
  -> client-loadable asset/content reference
```

3B-0에서 이 chain과 current behavior/asset root를 exact하게 닫았습니다. 결과는 `ready_for_selected_manager_patch_with_timing_analysis_blocker`입니다. static/content는 통과했지만 absolute timing 분석에는 client `150.6.9` native scheduler contract가 더 필요합니다. 이는 client actual-play 성공을 뜻하지 않으며 [PHASE3B0.md](PHASE3B0.md)가 closure 권위, [PHASE3B1.md](PHASE3B1.md)가 다음 patch 계획의 권위입니다. 최신 시즌, 시즌 40 또는 Museum으로 자동 대체하지 않습니다.

첫 live acceptance 흐름은 다음과 같습니다.

```text
실행
  -> synthetic local login
  -> lobby
  -> original classic Solo Raid main
  -> season 26 Challenge ready
  -> one squad enter
  -> original battle HUD/runtime
  -> original client damage/result
```

첫 종료 조건은 **Museum 버프 없이 시즌 26의 클래식 Challenge 전투가 시작되고 원본 client result가 반환되는 것**입니다. 이 단계에서는 custom six-season lobby folder, Local Lab bridge와 최대 다섯 팀을 동시에 요구하지 않습니다.

## 실행 환경과 시작 흐름

첫 compatibility proof는 primary 설치본이 아닌 snapshot 가능한 disposable VM/별도 OS에서 실행합니다.
단순 client 디렉터리 복제본은 정적 closure와 client-local 파일 검산에만 사용할 수 있고 system
hosts 또는 root CA trust를 바꾸는 live 환경으로 사용하지 않습니다.

- official account, cookie, token 또는 session을 사용하지 않음
- synthetic local account만 사용
- client, launcher, EpinelPS/server와 관련 child process 전체의 non-loopback 통신 차단·관측
- 모든 local service는 `127.0.0.1`에만 bind; wildcard/LAN/public bind, port forwarding과 배포 없음
- VM/OS hosts·root CA와 client-local compatibility file을 바꾸기 전에 exact before hash와 backup 기록
- 성공·실패 뒤 적용 변경을 되돌릴 수 있는 rollback manifest 유지

사용자-facing 상위 흐름은 `실행 -> 로딩 -> 로컬 접속 -> 로비`입니다. external compatibility façade가 담당하는 wire/local certificate/native compatibility 세부는 원본 client와 Local Lab domain 사이에 격리합니다. 공개 upstream의 존재를 권리자의 명시적 승인으로 표현하지 않습니다.

## Classic selected-season projection

Phase 2B의 canonical state는 account/session별 `SelectedRaidSeason`이며 한 client context와 한 run은 정확히 한 `RaidSnapshot`에 결박됩니다. Original classic Solo Raid 화면도 한 시점에는 이 선택된 시즌 하나만 투영합니다.

reviewed EpinelPS commit의 classic helper에는 명시적 선택이 없는 manager-dependent 조회가 최대/latest manager를 사용할 수 있는 경로가 있습니다. 이는 시즌 26 open 이후 Challenge level, preset, boss state, damage 또는 close/result가 다른 manager로 이동할 위험을 만듭니다.

따라서 외부 compatibility layer는 account별 `SelectedSoloRaidManager` 또는 동등한 단일 선택 source를 가져야 합니다. 이 선택은 listener 시작 전 account-specific startup binding에서만 write-once 설정하고 client request는 변경하지 않습니다.

- main/open state
- Challenge level과 preset 조회
- Challenge enter
- boss HP/damage/state
- close/result
- 재접속 또는 run resume

Pre-characterization route policy는 `6 selected Challenge + 1 GetLogs gate + 10 controlled unsupported + 2 manager-independent`입니다. External account selection과 열린 EpinelPS run은 exact manager를 pin하며 client request로 바뀌지 않습니다. Local Lab client context와 `RaidSnapshot` 결박은 3C가 소유합니다. 미선택·결손·mismatch는 latest fallback 없이 route-specific controlled failure와 zero mutation입니다.

## 메인 로비

### 첫 compatibility proof

첫 시즌 26 proof에서 로비의 역할은 synthetic local login 뒤 원본 classic Solo Raid 화면으로 정상 이동할 수 있게 하는 것입니다. 기존 로비 widget을 모두 제거하거나 custom six-season folder를 만드는 작업은 이 proof의 선행조건이 아닙니다. 미지원 live-service action은 façade가 제공하는 안전한 hidden/disabled/no-op 범위만 사용하고, timeout·빈 화면·protocol 오류를 UI 구현으로 인정하지 않습니다.

### 최종 Local Lab presentation 목표

시즌 26 end-to-end와 shadow bridge가 안정화된 뒤 다음 presentation을 별도 단계로 재평가합니다.

유지 목표:

- 좌상단 profile portrait, commander level과 local display name
- synthetic local wallet 표시
- 중앙 lobby character/background와 원본 animation
- 하단 `니케`, `스쿼드`, `로비`, `인벤토리`, `대원모집`

`대원모집`은 눌림/click feedback 뒤 navigation이 없는 controlled no-op입니다.

감춤 목표:

- 홍보 banner와 공지 bar
- Messenger/event/More 등 live-service shortcut
- 알림, 우편, 친구, Union, Shop, Outpost와 미지원 대형 card

고정 prefab 재배치나 custom folder가 필요하면 external client presentation patch 범위와 rollback을 별도로 설계합니다. 서버의 빈 응답으로 우연히 숨기지 않습니다.

## 시즌 선택 UI의 단계적 계약

Phase 2B directory v1의 지원 시즌은 `7, 13, 26, 29, 34, 40`입니다. 하지만 여섯 시즌 custom folder를 첫 client proof와 결합하지 않습니다.

1. 시즌 26 proof에서는 Local Lab admin/sidecar 또는 external façade config가 selected season을 명시합니다.
2. classic Solo Raid 화면은 선택된 시즌 하나만 표시·실행합니다.
3. 시즌 26 end-to-end 뒤 나머지 시즌을 하나씩 static closure와 live proof에 추가합니다.
4. 여섯 시즌 선택 UI가 필요하면 sidecar selector와 in-client folder 중 더 작은 안전한 surface를 별도 결정합니다.

향후 in-client folder를 채택하면 다음 source-free display contract를 사용할 수 있습니다.

```text
[솔로 레이드]
├─ 시즌 7 — 울트라
├─ 시즌 13 — 인디빌리아
├─ 시즌 26 — 프로비던스
├─ 시즌 29 — 마더웨일 전격 변종
├─ 시즌 34 — 앨트루이아
└─ 시즌 40 — 사치스러운 거미
```

이 folder는 optional presentation feature이며 classic `SoloRaid` 실행 context만 바꿉니다. Museum 화면으로 navigation하지 않습니다. 이름만으로 snapshot을 연결하지 않고 exact published snapshot과 external build-local binding을 사용합니다.

## Solo Raid 고정 서비스 정책

### Normal과 Challenge

- 지원 전투 모드는 `challenge` 하나입니다.
- Normal I~VII battle session, reward와 result API는 구현하지 않습니다.
- synthetic local account의 unlock projection은 `lastClearLevel=7`, `challengeUnlocked=true`입니다.
- 이 값은 공식 account 진행도를 복사하거나 변경하지 않습니다.

### 시즌 수명

- published 지원 시즌은 종료되지 않는 local content입니다.
- `SeasonAvailability=permanent`, `seasonEndsAt=null`이며 만료 job이 없습니다.
- timer 표현이 필요하면 `상시` 또는 안전한 hidden state를 사용하고 먼 미래 fake timestamp를 저장하지 않습니다.

### 일일 상태

- 권위 timezone은 IANA `Asia/Seoul`, reset은 매일 `05:00:00`입니다.
- reset은 daily attempt state에만 적용하고 profile/build, selected season, snapshot과 영구 result는 유지합니다.
- entry limit, 소비 시점, reset을 가로지르는 run, counter scope, Mock Battle과 local ranking은 exact `ChallengeOperationalPolicy`가 모두 해소된 경우에만 새 run admission에 사용합니다.
- checked-in unresolved policy는 화면·선택·unlock을 유지하고 새 run만 fail closed합니다.

### Quick Battle, ranking과 reward

- Quick Battle은 지원하지 않습니다.
- official global ranking, reward mail과 live-service economy를 모방하지 않습니다.
- 필요한 경우 Local Lab record만 별도 contract로 표시합니다.
- Mock Battle은 operational policy상 별도 capability지만 classic first proof에는 포함하지 않습니다.

## 서버와 client의 책임

| 책임 | Local Lab / external façade | Original client |
|---|---|---|
| synthetic local account와 profile/build | Local Lab authoritative; façade가 wire projection | 표시 |
| classic selected season/manager | Local Lab selection, façade의 exact build-local binding | 한 시즌의 기존 Solo Raid UI 표시 |
| Normal clear와 Challenge unlock | Local Lab state, façade projection | 기존 unlock UI 표시 |
| daily reset 05:00 KST | Local Lab authoritative | 남은 state 표시 |
| Challenge run identity와 durable result | Local Lab; live proof 전에는 façade standalone | 기존 화면 흐름 소비 |
| 전투 simulation, damage, HUD와 animation | 계산하지 않고 observation만 수신 | authoritative |
| Museum exclusion | Museum route를 연결하지 않음 | classic `SoloRaid`만 사용 |
| custom lobby presentation | 후속 optional patch/config | 채택 시 표시 |

## 구현 게이트

1. Phase 2B source-free backend/harness는 완료했습니다.
2. 역사적 Phase 3A는 approval-first 정책에서 `blocked_insufficient_evidence`였습니다.
3. Phase 3A-R은 operator-authorized local-only lane을 `ready_for_local_compatibility_spike`로 열었지만 기술 성공을 주장하지 않습니다.
4. 3B-0은 시즌 26 manager부터 client behavior/asset root까지 static/content closure를 완료했고 timing-analysis blocker를 분리했습니다.
5. 3B-1은 external EpinelPS에서 첫 request 전 저장한 account별 classic selection과 실행 중 불변 active-run pin을 분리하고, wire `Trial` Challenge를 허용하면서 Museum 비호출을 검증했습니다. External focused test는 `63/63`이며 client-visible 동작은 3B-2에서 처음 확인합니다.
6. 3B-2는 disposable 환경에서 시즌 26 one-team battle/result를 검증합니다.
7. 그 뒤에만 Local Lab shadow bridge, result identity, 1~5팀과 나머지 시즌을 확장합니다.

각 gate가 실패하면 그 단계에서 controlled blocked verdict를 남깁니다. Museum이나 다른 시즌을 사용해 시즌 26 gate를 통과한 것으로 표시하지 않습니다. profile/build와 실행 입력의 상세 경계는 [PROFILE_EXECUTION_DOMAIN.md](PROFILE_EXECUTION_DOMAIN.md)를 따릅니다.
