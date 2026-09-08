# Nikke Local Lab

> 보관 기록: 2026-09-06 문서 정리 때 이동했습니다. 본문의 ‘현재·다음·미완료’는 작성 당시 기준입니다. 현행 안내는 [문서 색인](../README.md)과 [현재 경로](../MICRON_CURRENT_PATHS.md)를 따릅니다.

원본 NIKKE 클라이언트에 필요한 기능만 공급하는 개인용 local private server 프로젝트입니다. 목표 실행 환경은 원본 전투 UI·asset·animation·전투 runtime과 damage 표시를 권위로 유지하고, Local Lab이 synthetic local session, profile, lobby capability, 지원 Solo Raid Challenge 상태와 결과를 공급하는 구조입니다.

별도 editor, lab-owned harness와 `Nikke-Dmg-Simulator`는 import·계약 검사·최적화·결과 대조용 sidecar입니다. 어느 것도 원본 client나 실제 전투 runtime을 대체하지 않습니다.

## 현재 상태

**Phase 2A1·Phase 2A2, Phase 2B source-free private-server backend/harness, Phase 3B-0 시즌 26 static/runtime closure와 Phase 3B-1 selected-manager patch를 완료했습니다.** 승인 우선 정책으로 수행한 기존 Phase 3A 감사의 역사적 verdict는 `blocked_insufficient_evidence`이며 그 fixture와 검증기는 그대로 보존합니다. 이후 정책을 재기준화한 3A-R은 공개 선행 구현을 기술적 feasibility 근거로 받아 `ready_for_local_compatibility_spike`를 판정했습니다. 3B-1 verdict는 `ready_for_isolated_season26_reference_run`입니다. 이는 권리자 승인 주장이나 client actual-play 완료가 아닙니다. 현재 checked-in production composition은 계속 fail closed입니다.

- Phase 1A: import ledger, read-only source와 identity/provenance 경계
- Phase 1B: immutable character catalog
- Phase 1C: 지원 시즌 `7, 13, 26, 29, 34, 40`의 Challenge RaidSnapshot
- Phase 1D: Tier 9·10 equipment, cube, collection/favorite, console과 OL catalog
- Phase 2A1: 자체 account/session, account-state·character-build·5인 squad·profile revision과 V0005 CAS 저장
- Phase 2A2: strict offline profile ingress, source-free draft/editor candidate, 관리 API/editor, lobby·wallet·feature·roster·squad·inventory projection과 V0006
- Phase 2B(완료): synthetic boot/session/context, 6-season directory, KST 05:00 daily state, runtime/control revision과 1~5팀 Challenge run/result를 위한 V0007·loopback API·harness
- Phase 3A(역사적 완료): 승인 우선 gate에서 `blocked_insufficient_evidence`
- Phase 3A-R(문서 재기준화 완료): pinned external EpinelPS process와 disposable local 환경을 사용하는 시즌 26 compatibility spike 진입 판정
- Phase 3B-0(완료): 시즌 26 manager → Challenge preset/wave → 단일 boss/model/stat → current behavior/asset root exact closure; absolute timing 분석은 별도 blocker
- Phase 3B-1(완료): account-authoritative selected manager, immutable active-run pin과 최종 `7 selected Challenge + 10 unsupported + 2 independent` route policy

완료된 V0001~V0007은 방향 수정 뒤에도 그대로 재사용합니다. 바로 다음 단계는 client `150.6.9`를 고정한 disposable 환경에서 **시즌 26 프로비던스의 원본 시즌제 `SoloRaid`** reference run을 수행하는 3B-2입니다. 남은 조건부 engineering estimate는 `2~4시간`이며 VM 준비와 사용자/client 대기는 제외합니다. Reference run 성공 뒤에만 Local Lab bridge와 observation/result 결박을 구현합니다.

완료된 2A2 기반은 [docs/PHASE2A2.md](../contracts/PHASE2A2.md), 완료된 Phase 2B 계약은 [docs/PHASE2B.md](../contracts/PHASE2B.md)를 따릅니다. 기존 3A 판정은 [docs/PHASE3A.md](../contracts/PHASE3A.md), 새 정책·upstream pin은 [docs/PHASE3AR.md](../contracts/PHASE3AR.md), 완료된 시즌 26 closure와 패턴 판정은 [docs/PHASE3B0.md](../contracts/PHASE3B0.md), 완료된 selected-manager patch와 receipt는 [docs/PHASE3B1.md](../contracts/PHASE3B1.md), 전체 단계는 [docs/PHASE3.md](../contracts/PHASE3.md)가 권위입니다.

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

시즌 26 수직 proof가 통과한 뒤 custom presentation을 별도로 재평가합니다. 여섯 시즌 선택 UI가 필요하면 sidecar selector와 좌측 Solo Raid folder 중 더 작은 안전한 surface를 선택합니다. in-client folder, 고정 widget 제거·재배치, 대원모집 controlled no-op은 아직 확정 구현이 아니며 별도로 검증된 client presentation variant가 있을 때만 채택합니다.

전체 명세는 [docs/PRIVATE_SERVER_UI.md](../contracts/PRIVATE_SERVER_UI.md)를 따릅니다.

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

`SoloRaidMuseum`은 실제 게임의 별도 콘텐츠이며 별도 buff가 전투 결과에 영향을 주므로 구현·대체·fallback 대상에서 제외합니다. 첫 live 검증은 시즌 26의 클래식 `SoloRaid`만 사용하며, 실행 불가 시 Museum으로 우회하지 않습니다.

Challenge 한 run은 1~5개의 5인 squad를 순차적으로 사용할 수 있으며 run 전체에서 character를 재사용할 수 없습니다. Phase 2A1의 `SquadRevision`은 한 팀이고, multi-team run aggregate는 Phase 2B의 additive V0007/state machine으로 구현을 완료했습니다.

Challenge unlock UI state와 run admission은 다른 개념입니다. `challengeUnlocked=true`는 항상 유지하지만, checked-in 기본 `challenge-operational-policy/unresolved/v1`은 일일 횟수·소비 시점·05:00 경계·counter scope·Mock Battle·local ranking을 추측하지 않고 새 run만 fail closed 합니다. 여섯 축을 모두 지정한 configured policy는 초기 빈 DB bootstrap에서 현재 raid day로 고정할 수 있고, 운영 중 admin 변경은 다음 raid day로만 예약합니다.

## 정확성 경계

- 원본 client가 전투 simulation, damage 계산·표기, HUD, animation과 result rendering의 권위입니다.
- Phase 2B backend는 `lab_harness_observation/v1`만 수락하고 계산하지 않은 팀별 관측값과 합계 정합성을 저장합니다. 이 receipt는 original-client damage 증거가 아닙니다.
- 최종 damage 권위는 계속 `original_client_runtime`이며 `originalRuntimeObservationStatus=blocked_by_gate`입니다. Phase 3C/3D의 최소 one-team observation adapter가 실제 client observation을 별도 versioned provenance로 매핑하기 전에 harness receipt를 이름만 바꿔 승격하지 않으며, Phase 4는 그 계약을 1~5팀과 full telemetry/recovery로 확장합니다.
- RaidSnapshot `ready`는 선언한 evidence tier의 publish readiness입니다. 원본 runtime exact를 뜻하지 않습니다.
- 현재 published RaidSnapshot에서 시즌 7·13·26·29·34는 `static_exact`, 시즌 40은 `behavior_exact` 상한입니다. 3B-0 focused 시즌 26 evidence는 `promotion_eligible=false`이므로 이 tier를 바꾸지 않습니다.
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
- Phase 3A(역사적 감사 완료/blocked): 당시 승인 우선 정책의 route·build·session·outbound evidence gate
- Phase 3A-R(재기준화 완료): 권리자 승인을 주장하지 않는 개인 로컬 실험 정책, pinned external EpinelPS와 시즌 26 classic-only 목표
- Phase 3B-0(완료): 시즌 26 static/content closure와 timing analysis blocker 분리
- Phase 3B-1(완료) 이후: disposable reference run, Local Lab shadow bridge, authority 결박과 후속 시즌 확장
- Phase 4: Phase 3C/3D one-team 관측 계약의 1~5팀 actual-play, telemetry/recovery와 runtime parity 확장

세부 계획은 [docs/IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md), 바로 다음 작업은 [docs/NEXT_STEPS.md](../NEXT_STEPS.md)를 참고합니다.

## 보안·데이터 경계

현재 저장소의 original-client adapter와 production composition은 계속 [fail closed](../contracts/FEASIBILITY_GATES.md)입니다. 3A-R은 이를 자동 활성화하지 않으며, 후속 spike에서만 공식 계정·credential과 분리된 disposable 환경으로 pinned external EpinelPS 경로를 평가합니다. 공개 EpinelPS 저장소의 존재를 Shift Up 또는 배급사의 승인·허가로 주장하지 않습니다.

`C:\NIKKE`는 계속 read-only source입니다. 실험에 필요한 client 변경, EpinelPS checkout, certificate/native compatibility material, 원본·복호물·asset·실계정 raw와 runtime DB는 disposable 환경 또는 Git 밖 local runtime에 두며 Git·CI·release에 넣지 않습니다.

## 검증

    pwsh -NoProfile -File scripts/verify-repository.ps1 -Mode working -AllowRemote
    pwsh -NoProfile -File scripts/verify-phase0-contract.ps1
    pwsh -NoProfile -File scripts/verify-phase1a.ps1
    pwsh -NoProfile -File scripts/verify-phase2a1.ps1
    pwsh -NoProfile -File scripts/verify-phase2a2.ps1
    pwsh -NoProfile -File scripts/verify-phase2b.ps1
    pwsh -NoProfile -File scripts/verify-phase3a.ps1
    pwsh -NoProfile -File scripts/verify-phase3b0.ps1
    pwsh -NoProfile -File scripts/verify-phase3b1.ps1
    pwsh -NoProfile -File scripts/verify-actions-contract.ps1

Phase 3A 계약만 빠르게 반복할 때는 `scripts/verify-phase3a.ps1 -ContractOnly`를 사용합니다. 완료된 3B-0 source-free assessment는 `scripts/verify-phase3b0.ps1`, 완료된 3B-1 selected-manager receipt는 `scripts/verify-phase3b1.ps1`로 검증합니다. branch 완료 전에는 option 없는 baseline gate도 함께 확인합니다. PostgreSQL 통합 검사는 폐기 가능한 `nikke_local_lab_test` DB에서 loopback `NIKKE_LAB_TEST_DB`와 reviewed reset token을 설정한 뒤 `scripts/verify-phase2b.ps1 -Integration`으로 실행합니다. 실제 게임 source, private profile, original client와 asset은 Git이나 CI에 넣지 않습니다.

`verify-phase3a.ps1`은 역사적 approval-first blocked contract를 계속 검증할 뿐 3A-R 이후 local spike를 실행하거나 성공으로 판정하지 않습니다. 3B-1 source-free receipt가 통과해도 disposable live proof 전에는 original-client 경로가 비활성인 것이 정상입니다.
