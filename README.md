# Nikke Local Lab

원본 NIKKE 클라이언트에 필요한 기능만 공급하는 개인용 local private server 프로젝트입니다. 최종 실행 환경은 원본 전투 UI·asset·animation·전투 runtime과 damage 표시를 권위로 유지하고, 선언한 로비는 approved presentation variant를 사용하며, Local Lab이 synthetic local session, profile, lobby capability, 지원 Solo Raid Challenge 상태와 결과를 공급하는 구조입니다.

별도 editor, lab-owned harness와 `Nikke-Dmg-Simulator`는 import·계약 검사·최적화·결과 대조용 sidecar입니다. 어느 것도 원본 client나 실제 전투 runtime을 대체하지 않습니다.

## 현재 상태

**Phase 2A1·Phase 2A2와 Phase 2B source-free private-server backend/harness를 완료했고, Phase 3은 3A~3E 수직 단계로 분할했습니다.** 3A evidence audit는 완료했지만 승인 route/build/outbound 증거가 없어 현재 verdict는 `blocked_insufficient_evidence`입니다. strict importer, 관리 API/editor, V0006 기반을 유지하며 V0007 boot/lobby/Solo Raid 서비스까지 단위 및 live PostgreSQL gate로 검증했습니다.

- Phase 1A: import ledger, read-only source와 identity/provenance 경계
- Phase 1B: immutable character catalog
- Phase 1C: 지원 시즌 `7, 13, 26, 29, 34, 40`의 Challenge RaidSnapshot
- Phase 1D: Tier 9·10 equipment, cube, collection/favorite, console과 OL catalog
- Phase 2A1: 자체 account/session, account-state·character-build·5인 squad·profile revision과 V0005 CAS 저장
- Phase 2A2: strict offline profile ingress, source-free draft/editor candidate, 관리 API/editor, lobby·wallet·feature·roster·squad·inventory projection과 V0006
- Phase 2B(완료): synthetic boot/session/context, 6-season directory, KST 05:00 daily state, runtime/control revision과 1~5팀 Challenge run/result를 위한 V0007·loopback API·harness

완료된 V0001~V0006은 방향 수정 뒤에도 그대로 재사용합니다. Phase 2B는 V0007 additive schema로만 확장합니다. 승인 증거가 준비되면 Phase 3B transport부터 3C boot/session, 3D lobby/season, 3E Challenge handoff를 순서대로 진행하며, 실제 플레이와 damage/HUD/result 검증은 Phase 4입니다.

완료된 2A2 기반은 [docs/PHASE2A2.md](docs/PHASE2A2.md), 완료된 Phase 2B 계약은 [docs/PHASE2B.md](docs/PHASE2B.md), Phase 3 분할과 현재 no-go 판정은 [docs/PHASE3.md](docs/PHASE3.md)와 [docs/PHASE3A.md](docs/PHASE3A.md)를 따릅니다.

## 제품 UI

### 시작

    실행 -> 로딩 -> 로컬 접속 -> 메인 로비

### 로비

유지:

- profile, commander level과 합성 local 재화
- 중앙 lobby character/background와 원본 Live2D
- 하단 니케·스쿼드·로비·인벤토리·대원모집

제거:

- 광고·pass·notice banner
- 기존 좌우 shortcut과 social/event 메뉴
- cash shop, shop, Outpost, Ark와 Operation card

좌측 기존 shortcut 영역에는 지원 시즌을 모두 나열하는 Solo Raid folder를 둡니다. 대원모집은 click feedback만 유지하고 page transition은 하지 않는 controlled no-op입니다. 고정 widget 제거·재배치와 season folder는 서버 응답만으로 된다고 가정하지 않으며 승인된 client presentation variant가 필요합니다.

전체 명세는 [docs/PRIVATE_SERVER_UI.md](docs/PRIVATE_SERVER_UI.md)를 따릅니다.

## Solo Raid 제품 고정 정책 — Phase 2B backend 계약

```text
supported mode          = Challenge only
Normal I..VII combat    = unsupported
Normal last clear       = 7
Challenge unlocked      = true by default
supported seasons       = 7, 13, 26, 29, 34, 40
season availability     = permanent
seasonEndsAt            = null
Quick Battle            = unsupported
daily reset timezone    = Asia/Seoul
daily reset local time  = 05:00:00
```

여섯 시즌은 lobby directory에 동시에 표시하고 사용자가 고른 한 시즌만 현재 client context와 battle session에 고정합니다. season expiry와 공식 global ranking/reward delivery를 구현하지 않습니다.

Challenge 한 run은 1~5개의 5인 squad를 순차적으로 사용할 수 있으며 run 전체에서 character를 재사용할 수 없습니다. Phase 2A1의 `SquadRevision`은 한 팀이므로 multi-team run aggregate는 Phase 2B에서 additive migration으로 구현합니다.

Challenge unlock UI state와 run admission은 다른 개념입니다. `challengeUnlocked=true`는 항상 유지하지만, checked-in 기본 `challenge-operational-policy/unresolved/v1`은 일일 횟수·소비 시점·05:00 경계·counter scope·Mock Battle·local ranking을 추측하지 않고 새 run만 fail closed 합니다. 여섯 축을 모두 지정한 configured policy는 초기 빈 DB bootstrap에서 현재 raid day로 고정할 수 있고, 운영 중 admin 변경은 다음 raid day로만 예약합니다.

## 정확성 경계

- 원본 client가 전투 simulation, damage 계산·표기, HUD, animation과 result rendering의 권위입니다.
- Phase 2B backend는 `lab_harness_observation/v1`만 수락하고 계산하지 않은 팀별 관측값과 합계 정합성을 저장합니다. 이 receipt는 original-client damage 증거가 아닙니다.
- 최종 damage 권위는 계속 `original_client_runtime`이며 `originalRuntimeObservationStatus=blocked_by_gate`입니다. Phase 4 observation adapter가 실제 client observation을 별도 versioned provenance로 매핑하기 전에 harness receipt를 이름만 바꿔 승격하지 않습니다.
- RaidSnapshot `ready`는 선언한 evidence tier의 publish readiness입니다. 원본 runtime exact를 뜻하지 않습니다.
- 현재 시즌 7·13·26·29·34는 `static_exact`, 시즌 40은 `behavior_exact` 상한입니다.
- 실제 일치는 Phase 4에서 `(client build, season, raid snapshot)`별로 사용자가 플레이하고 검증합니다.

## 완료 기반과 후속 확장

유지:

- 자체 UUID/HMAC identity와 provenance
- character/combat-support/raid catalog
- account state, build, 5인 squad와 profile revision
- CAS Save, lineage, idempotency와 V0001~V0005 checksum

완료 및 후속:

- Phase 2A2: strict raw/canonical codec, source-free CLI, sanitized draft와 별도 editor candidate, typed rebase/override, explicit new-account create, lobby presentation, wallet, feature manifest, lossless equipped-combat inventory projection과 loopback editor/API
- Phase 2B(완료): boot/lobby service, permanent season directory, selected season, 05:00 KST daily state, runtime/control profile, 1~5팀 Challenge run/result와 lab-owned harness
- Phase 3A(감사 완료/blocked): 승인 route·exact build·synthetic session·outbound-zero evidence gate
- Phase 3B~3E: 승인된 transport, boot/session, lobby/season presentation과 Challenge handoff
- Phase 4: 원본 client 실제 플레이와 telemetry/result 검증

세부 계획은 [docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md), 바로 다음 작업은 [docs/NEXT_STEPS.md](docs/NEXT_STEPS.md)를 참고합니다.

## 보안·데이터 경계

원본 리테일 client 연결은 현재 [blocked](docs/FEASIBILITY_GATES.md)입니다. 지원·승인된 local/test route와 presentation capability, 합성 session, 공식 outbound zero가 입증되기 전에는 활성화하지 않습니다. 공식 credential, protocol replay, endpoint/auth 변조, 주입·후킹, launcher/보호 기능 우회를 사용하지 않습니다.

`C:\NIKKE`는 read-only source입니다. 원본·복호물·asset·실계정 raw와 runtime DB는 Git 밖에 두며 source ID는 domain/API/log에 노출하지 않습니다.

## 검증

    pwsh -NoProfile -File scripts/verify-repository.ps1 -Mode working -AllowRemote
    pwsh -NoProfile -File scripts/verify-phase0-contract.ps1
    pwsh -NoProfile -File scripts/verify-phase1a.ps1
    pwsh -NoProfile -File scripts/verify-phase2a1.ps1
    pwsh -NoProfile -File scripts/verify-phase2a2.ps1
    pwsh -NoProfile -File scripts/verify-phase2b.ps1
    pwsh -NoProfile -File scripts/verify-phase3a.ps1
    pwsh -NoProfile -File scripts/verify-actions-contract.ps1

Phase 3A 계약만 빠르게 반복할 때는 `scripts/verify-phase3a.ps1 -ContractOnly`를 사용합니다. branch 완료 전에는 option 없이 실행해 완료된 Phase 2B baseline도 함께 확인합니다. PostgreSQL 통합 검사는 폐기 가능한 `nikke_local_lab_test` DB에서 loopback `NIKKE_LAB_TEST_DB`와 reviewed reset token을 설정한 뒤 `scripts/verify-phase2b.ps1 -Integration`으로 실행합니다. 실제 게임 source, private profile, original client와 asset은 Git이나 CI에 넣지 않습니다.
