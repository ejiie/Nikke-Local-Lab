# Next steps

최종 목표는 원본 NIKKE client가 제한된 Local Lab private server에 접속하여 선언된 로비와 지원 Solo Raid Challenge를 원본 UI·asset·전투 runtime으로 실행하는 것입니다. Phase 2B source-free backend/harness는 완료했고 Phase 3은 3A~3E의 작은 수직 단계로 분할했습니다. 바로 다음 판정은 3A evidence audit이며 현재 `blocked_insufficient_evidence`입니다. 자세한 제품 계약은 [PRIVATE_SERVER_UI.md](PRIVATE_SERVER_UI.md), 단계별 계약은 [PHASE3.md](PHASE3.md)와 [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md)를 따릅니다.

## 완료 기반

### Phase 1A — import foundation

- 자체 UUID/HMAC identity, provenance와 path-free import ledger
- checksummed PostgreSQL migration과 read-only source capability
- loopback/network/repository data boundary

### Phase 1B — character catalog

- immutable character definition/version과 catalog manifest
- character capability, maximum과 `combat-max/v1` seed
- source alias 격리와 atomic publish

### Phase 1C — Challenge RaidSnapshot

- authoritative Challenge chain과 `challenge-boss-support/v1`
- 지원 시즌 `7, 13, 26, 29, 34, 40`
- immutable `RaidSnapshot v2`, source-free part/skill-slot 관계와 evidence tier

현재 증거 상한은 시즌 7·13·26·29·34가 `static_exact`, 시즌 40이 `behavior_exact`입니다. 이는 service availability나 원본 runtime exact를 뜻하지 않습니다.

### Phase 1D — combat-support catalog

- Tier 9·10 equipment 24개
- cube, collection/favorite, console과 OL definition/version
- profile selection readiness와 독립 combat semantics readiness 분리

### Phase 2A1 — account/profile/build revision

- 자체 local account와 최소 session
- immutable account state, character build, 5인 squad와 profile template
- catalog exact membership, CAS Save, lineage, idempotency와 V0005 sealing
- 부분 관측의 field-level unresolved 무손실 보존

방향 수정 뒤에도 V0001~V0005와 위 도메인은 그대로 재사용합니다. 단일 squad는 한 팀이며 Solo Raid 한 run의 최대 다섯 팀 aggregate가 아닙니다.

## 완료 — Phase 2A2 관리 계층과 client-facing read model

상태: 완료. 아래 완료 기준과 `scripts/verify-phase2a2.ps1` 단위/live PostgreSQL gate를 모두 통과했습니다.

### 구현

- credential-bearing raw의 strict allowlist/shape parser와 canonical `nll/sanitized-profile-draft/v1` codec
- source-free `profile-source-inspect`/`profile-draft-import`, imported draft와 diff
- raw sanitized draft와 분리된 `nll/profile-edit-candidate/v1`
- Save, Save As, apply, explicit new-account create와 typed rebase command API/editor
- bond `0`/missing manufacturer의 Research unresolved materialization과 typed reviewed override
- identity/catalog membership/shape/coordinate/level-authority failure의 fail-closed 경계
- lobby local display name, commander level과 profile presentation revision
- synthetic wallet revision
- roster/build, 저장 squad와 manufacturer/sparse-OL exact 값을 포함한 제한된 inventory read-only projection
- 화면별 `supported|hidden|visible_no_op|not_supported` feature manifest
- V0005 write와 V0006 application link 사이 interruption을 복구하는 immutable intent/ledger

하단 UI의 초기 지원 범위는 다음과 같습니다.

| 화면 | backend 범위 |
|---|---|
| 니케 | roster와 build 조회 |
| 스쿼드 | 저장된 5인 squad 조회·선택 |
| 로비 | lobby bootstrap으로 복귀 |
| 인벤토리 | Local Lab 지원 전투 항목만 read-only projection |
| 대원모집 | click acknowledgement 후 navigation 없음 |

현재 2A1이 보유한 장착 상태와 definition catalog를 원본 전체 inventory라고 부르지 않습니다. 필요한 lab-owned inventory instance projection은 별도 version으로 추가합니다.

### 완료 기준

- bootstrap read model이 profile/wallet/roster/squad/inventory subset을 정확한 revision에 결박합니다.
- raw ID, path, credential과 공식 session이 API·DB·log·fixture에 없습니다.
- import refresh가 local edit를 자동 덮어쓰지 않습니다.
- semantic unresolved는 Research/readiness false로 보존되고 identity/catalog/shape/authority failure는 materialization 전에 차단됩니다.
- raw draft와 editor candidate가 codec/provenance/storage에서 교차 사용되지 않습니다.
- source/base 없는 create-preview/create가 빈 DB의 최초 LocalAccount/profile을 명시적으로 만듭니다.
- typed rebase/override가 원관측과 exact catalog binding을 보존하고 이름 기반 자동 매칭을 하지 않습니다.
- V0005/V0006 interruption replay가 중복 revision 없이 completed application과 유효한 lobby validation으로 수렴합니다.
- inventory subset이 enhancement/manufacturer와 OL `1..3` state/definition/exact value/unit을 손실하지 않습니다.
- loopback admin security, source-free CLI와 V0006 전체를 `scripts/verify-phase2a2.ps1 -Integration`으로 검증합니다.
- editor는 관리 sidecar이고 원본 게임 UI를 대체하지 않습니다.

## 완료 — Phase 2B private server backend/harness

상태: 완료. `scripts/verify-phase2b.ps1`의 단위 및 live PostgreSQL integration gate가 모두 통과했습니다. original-client adapter/UI/runtime 인수는 이 완료 범위에 포함하지 않습니다.

### Boot와 lobby

- synthetic local session bootstrap
- profile/wallet/roster/squad/inventory/feature manifest projection
- 미지원 route의 controlled no-op/not-supported 처리

### 영구 season directory

- 여섯 published 지원 시즌을 동시에 나열
- account/session별 selected season
- 한 client context와 battle session에는 정확히 한 snapshot 고정
- 모든 시즌 permanent, `seasonEndsAt=null`

### 고정 Solo Raid 상태

```text
NormalCombatCapability = unsupported
NormalLastClearLevel = 7
ChallengeUnlocked = true
QuickBattleCapability = unsupported
SeasonAvailability = permanent
DailyResetZone = Asia/Seoul
DailyResetLocalTime = 05:00:00
```

Normal battle/reward/Quick Battle route를 만들지 않습니다. 05:00 KST reset은 operational day key와 lazy idempotent rollover로 구현하고, profile, season selection, snapshot과 영구 record는 초기화하지 않습니다.

### Challenge run

- exact raid/account/build/runtime/control admission
- 한 run에 1~5개 5인 squad를 순차 결박
- run 전체 character 재사용 금지
- open → enter → `lab_harness_observation/v1` receipt → regroup/next team → result
- 팀별 result와 누적 damage, 사용 revision과 telemetry 저장

일일 attempt quota, 소비 시점, 05:00을 가로지르는 진행 중 run, mock battle과 local ranking 표시 범위는 별도 versioned policy로 확정합니다. 사용자가 정하지 않은 값을 공식 기본값이라는 이유만으로 고정하지 않습니다.

checked-in 기본은 여섯 축이 모두 미해소인 `challenge-operational-policy/unresolved/v1`입니다. 이 정책은 boot/lobby/directory/season selection과 `challengeUnlocked=true`를 유지하면서 새 run admission만 `policy_unresolved`로 fail closed합니다. 빈 DB bootstrap에서 여섯 축을 모두 명시한 configured policy를 주입하면 현재 raid day에 초기 활성화할 수 있지만, 이후 admin policy 전환은 다음 raid day에만 효력을 가집니다.

### 완료 기준

- 신규 local account에서 Challenge unlock projection이 즉시 열리고, 실제 run admission은 exact configured operational policy를 따릅니다.
- season expiry와 Quick Battle이 없습니다.
- 04:59:59/05:00:00 KST 경계와 동시 rollover가 결정적입니다.
- 최대 다섯 팀과 팀 간 중복 금지, result revision pinning이 검증됩니다.
- harness green은 original-client 완료로 표시하지 않습니다.

Phase 2B result transport는 `lab_harness_observation/v1`입니다. backend는 damage를 계산하지 않고 exact 팀별 receipt와 누적 합계만 검산합니다. boot의 최종 권위는 `original_client_runtime`, 관측 상태는 `blocked_by_gate`로 남으며 Phase 4 observation adapter 전에 이 harness receipt를 original-runtime 증거로 승격하지 않습니다.

private-server access token은 process-local signing key를 사용합니다. 같은 process의 같은 Open operation replay는 exact token byte를 재사용하지만, restart 후에는 영속 session/context/time을 복원하더라도 새 process key로 재서명할 수 있습니다.

## 다음 1 — Phase 3A evidence gate 해소

3A source-free 감사와 기계 검증 계약은 완료했습니다. 현재 저장소에는 다음 증거가 없으므로 3B 이후는 시작하지 않습니다.

- 권리자가 지원·승인한 local/test route와 current scope
- exact approved client executable/content-set closure
- supported selector/interface와 boot handshake contract
- synthetic-session-only enforcement plan
- client/launcher/child process 전체를 포함한 outbound-isolation verification plan

이 다섯 항목이 저장소 밖 local evidence vault에서 검토되어 assessment가 `ready_for_phase3b`가 되면 다음 작은 batch로 진행합니다. 실제 synthetic-session enforcement와 outbound-zero 관측은 3B가 소유합니다. approved lobby presentation variant는 `ready_for_phase3b` 조건이 아니지만 3D를 시작하기 전에는 별도로 확인해야 합니다.

1. **3B transport/handshake** — exact build preflight, supported selector, isolated outbound-zero
2. **3C boot/session** — loading, boot/open/connect, account bootstrap
3. **3D lobby/season** — keep/remove/replace UI, six-season folder, explicit selection, permanent/no Quick/Recruit no-op
4. **3E Challenge handoff** — main/ready, run open, first-team enter, original runtime 직전 경계

현재 3B~3E 견적은 `N/A (blocked)`입니다. 승인·stable build·supported wire·approved UI variant가 모두 제공된 경우의 조건부 합계는 안정화 포함 `14~27시간`이며, 각 구현 batch는 최대 `2~4시간`과 한 commit으로 닫습니다. 자세한 판정과 시간 단축 규칙은 [PHASE3A.md](PHASE3A.md)를 따릅니다.

서버 feature flag와 승인된 client UI variant의 역할을 화면 요소별로 증명합니다. exact lobby variant가 없으면 3D는 blocked입니다.

## 다음 2 — Phase 4 사용자 실플레이 검증

- 별도 versioned original-runtime observation provenance/contract와 adapter
- exact build/context/snapshot/squad/build/runtime/control pinning
- observation → regroup → next-team → close/result wire와 ESC/frame telemetry
- 실행 → 로딩 → 로컬 접속 → 로비
- profile/재화와 lobby keep/remove/replace 명세
- 니케·스쿼드·인벤토리, Recruit no-op
- 여섯 시즌 선택과 Challenge 즉시 개방
- season countdown/Quick Battle 부재
- 1~5팀 전투, 사용 캐릭터 잠금과 재정비
- 원본 HUD/ESC 누적 damage와 result
- backend 팀별/누적 result 일치
- 05:00 KST rollover
- 시즌별 scene, behavior, QTE, part, animation과 timing

완료 판정은 전역 boolean이 아니라 `(client build, season, raid snapshot)`별 증거로 남깁니다.

## Phase 2A1 영향 요약

수정하지 않는 것:

- V0001~V0005와 적용된 migration checksum
- identity/provenance와 세 catalog
- `RaidSnapshot`, account state, build, 5인 squad와 profile revision
- CAS/lineage/idempotency와 기존 canonical hash

후속 additive migration으로 추가한 것:

- lobby presentation, wallet, feature manifest와 inventory subset
- permanent season directory와 selected season
- KST operational day와 daily state
- 1~5팀 Challenge run/result와 execution segment

Phase 2A2 config 계약에는 이미 `oneSelectedSeasonPerClientContext`, `challengeUnlocked=true`, `lastClearLevel=7`, permanent/no-quick/05:00 KST가 명시되어 있습니다. Phase 2B V0007/state machine/API는 이 확정 의미와 별도 operational-policy 권위를 구현하며 V0001~V0006 checksum을 바꾸지 않습니다.
