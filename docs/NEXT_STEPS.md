# Next steps

최종 목표는 원본 NIKKE client가 제한된 Local Lab private server에 접속하여 지원 Solo Raid Challenge를 원본 UI·asset·전투 runtime으로 실행하는 것입니다. Phase 2B source-free backend/harness, Phase 3B-0 시즌 26 static/runtime closure와 Phase 3B-1 selected-manager patch를 완료했습니다. Phase 3B-1의 `ready_for_isolated_season26_reference_run`은 유지되지만, Phase 3B-2는 Wave 0 contract scaffold만 완료했으며 checked-in 환경 판정은 blocked preflight와 not-executed reference run입니다. 다음은 client를 시작하지 않는 Wave 1 measured preflight이고, 그 receipt에 결박된 실제 client reference run은 Wave 2입니다. approval-first Phase 3A의 `blocked_insufficient_evidence`는 역사 기록으로 보존하지만 현행 기술 작업을 차단하지 않습니다.

바로 다음 기술 목표는 **[PHASE3B2.md](PHASE3B2.md)의 preflight 계약을 실제 disposable 환경 측정으로 채워 ready 판정을 봉인한 뒤, client build `150.6.9`에서 시즌 26의 원본 클래식 `SoloRaid` Challenge를 단일 팀으로 실행하는 것**입니다. 공식 별도 모드인 `SoloRaidMuseum`은 결과에 영향을 주는 전용 버프가 있으므로 고려·fallback·acceptance 대상에서 제외합니다. 자세한 rebaseline은 [PHASE3AR.md](PHASE3AR.md), selected-manager 완료 결과는 [PHASE3B1.md](PHASE3B1.md), 제품 계약은 [PRIVATE_SERVER_UI.md](PRIVATE_SERVER_UI.md), 전체 단계는 [PHASE3.md](PHASE3.md)와 [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md)를 따릅니다.

## 2026-08-27 actual-play checkpoint

위의 초기 Wave 설명 이후 physical Micron lane에서 원본 client `150.6.9`의 시즌 26 클래식 Challenge 실제 전투 진입까지 도달했습니다. v5 marker-only 관측으로 Regroup의 실제 `BattleResult=6`을 확인했고, 기존 비소모 retry `4`와 분리했습니다. Regroup 두 번 뒤에도 join/record/damage delta는 모두 `0`이며 Challenge 재진입이 가능했습니다. 최종 inspector verdict는 `observed_regroup_6_is_non_consuming_and_reentry_safe`입니다.

이 checkpoint는 중요한 actual-play 진척이지만 전체 Phase 3B-2 완료는 아닙니다. 다음 순서는 다음과 같습니다.

1. **완료:** 기존 D: full Golden을 덮어쓰지 않는 detached v5 checkpoint `e40c70a0-16a3-4a83-9d30-b16f368ce73a`를 봉인했습니다. Seal receipt SHA-256은 `e69ee9020abf5c77fc61f433ae56729d36c82c10289b385ee1bdde30604e3753`입니다.
2. Regroup이 아닌 실제 전투 완주 한 건의 result/result-screen/backend state를 관측합니다.
3. 완주 결과가 닫힌 뒤 다음 팀 전이와 1~5팀 aggregate를 별도 Phase 4 증거로 확장합니다.
4. 마지막에 Phase 2B shadow bridge와 original-runtime result authority 경계를 연결합니다.

Museum, Quick Battle, Normal/Union Raid runtime은 계속 범위 밖입니다. v4, Micron lobby Golden과 기존 D: full Golden은 불변 대조군으로 유지합니다.

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

Phase 2B result transport는 `lab_harness_observation/v1`입니다. backend는 damage를 계산하지 않고 exact 팀별 receipt와 누적 합계만 검산합니다. boot의 최종 권위는 `original_client_runtime`, 관측 상태는 `blocked_by_gate`로 남으며 Phase 3C/3D의 최소 one-team observation adapter가 실제 client mapping을 봉인하기 전에 이 harness receipt를 original-runtime 증거로 승격하지 않습니다.

private-server access token은 process-local signing key를 사용합니다. 같은 process의 같은 Open operation replay는 exact token byte를 재사용하지만, restart 후에는 영속 session/context/time을 복원하더라도 새 process key로 재서명할 수 있습니다.

## 완료 — 3A-R 문서·정책 rebaseline

상태: 문서·정책 재기준화 완료 / `ready_for_local_compatibility_spike`. 실제 compatibility 실행은 아직 시작하지 않았습니다. 문서 작업 실적은 약 `1.5~2.5시간`입니다.

- Phase 3A의 `blocked_insufficient_evidence`를 당시 approval-first 정책의 역사적 결과로 보존
- 공개 upstream을 권리자 승인 증거로 표현하지 않으면서 operator-authorized local-only lane을 별도로 정의
- EpinelPS reviewed commit `28b2f5413a0a1e3521a11ae162f91851335c8b40`, AGPL 외부 process 경계와 client `150.6.9` 고정
- snapshot 가능한 disposable VM/별도 OS, dummy local account, `127.0.0.1` exact bind, 전 process tree non-loopback block와 backup/rollback 계약 정렬
- classic `SoloRaid` only, Museum 제외와 시즌 26 first proof를 전 문서에 반영

이 단계가 끝나도 client compatibility가 입증된 것은 아닙니다.

## 완료 — 3B-0 시즌 26 static/runtime closure

상태: `ready_for_selected_manager_patch_with_timing_analysis_blocker`

다음 exact chain을 client 실행 전에 닫았습니다.

```text
season 26 manager
  -> preset
  -> Challenge wave
  -> monster/stat
  -> client-loadable asset/content
```

Static/content 축은 `ready_for_selected_manager_patch`입니다. pinned upstream pack과 인접 local reference pack의 필수 entry `7/7`, selected season row `6/6`를 exact하게 대조했고, manager → Challenge preset → wave → 단일 boss/model/stat → current behavior/asset root를 닫았습니다. Focused behavior/timeline artifact 자체는 prior local reference archive에서 생성했으며, target의 시즌 26 monster-skill row `15/15` exact decode와 complete monster-parts entry byte equality로 equivalence를 검증했습니다. 최신 manager, 다른 시즌과 Museum fallback은 사용하지 않았습니다.

시즌 26에는 패턴 순서가 있지만 고정된 한 줄 script는 아닙니다. exact behavior graph는 node `917`개와 active cast site `109`개를 가지며 조건·random selector·파츠 상태에 따라 분기합니다. active skill type `14`개 중 `7`개가 exact Timeline marker를 가지며 AttackMarker는 `9`개입니다. event timing `7`개와 client `150.6.9` native scheduler contract가 미해소이므로 absolute frame/ms timing 분석만 blocked입니다. focused evidence는 `promotion_eligible=false`이므로 Phase 1C의 published 시즌 26 `static_exact` tier를 올리지 않습니다. 상세와 공개 영상 trace의 구분은 [PHASE3B0.md](PHASE3B0.md)를 따릅니다.

## 완료 — 3B-1 external selected-manager patch와 focused test

상태는 **완료 / `ready_for_isolated_season26_reference_run`**입니다.

통합 external commit은 `92a6ca228aeb580988907b96189b2857dff2c62d`입니다.

EpinelPS classic Solo Raid의 max/latest-manager 선택 동작을 account별 explicit selection으로 바꿨습니다. Baseline 감사값 `19/6/9/4`를 보존하고 최종 policy를 `7 selected Challenge / 10 controlled unsupported / 2 manager-independent`로 고정했습니다. Listener 시작 전에 startup binding으로 synthetic account의 target을 write-once 저장하고, JsonDb restart 복원과 immutable active-run pin을 구현했습니다.

`B1a baseline/characterization -> B1x dispatch isolation -> B1b resolver/persistence -> B1c route wiring -> B1d adversarial tests -> B1e source-free receipt`를 모두 완료했습니다. Wire `Trial`은 classic Challenge 경로로 유지하고 Museum·Normal·Practice·FastBattle/Quick은 범위 밖입니다. Release rebuild 오류 `0`, focused test `63/63`이며 상세 receipt는 [PHASE3B1.md](PHASE3B1.md)를 따릅니다.

## 다음 1 — isolated season 26 live proof

예상 `2~4시간`입니다.

```text
disposable launch
  -> synthetic local login
  -> lobby
  -> original classic Solo Raid
  -> season 26 Challenge ready
  -> one squad battle
  -> original client result
```

primary 설치본과 공식 계정을 사용하지 않습니다. snapshot 가능한 disposable VM/별도 OS에서만 system hosts와 root CA를 바꿉니다. client-local native compatibility 변경은 before hash, backup과 rollback manifest를 먼저 만들고, client, launcher, EpinelPS/server와 관련 child process 전체의 non-loopback 통신을 차단·관측합니다. 모든 local service는 `127.0.0.1`에만 bind합니다.

첫 exit gate는 **Museum 버프 없이 시즌 26 클래식 Challenge 전투가 시작되고 client result를 반환하는 것**입니다. 3A-R을 시작할 때의 총견적 `6.5~12.5시간`은 역사적 초기값이고, 3B-1 완료 뒤 현재 남은 3B-2 engineering estimate는 `2~4시간`입니다.

## 이후 — shadow bridge와 확장

3B live proof 뒤에만 진행하고 다시 견적합니다.

1. 시즌 26 external façade ↔ Phase 2B shadow bridge: 초기 `3~6시간`
2. 시즌 26 open/enter/observation/result end-to-end sealing: 초기 `4~7시간`
3. 나머지 시즌 `7, 13, 29, 34, 40` 확장: 시즌 26 성공 뒤 시즌별 재견적
4. 1~5팀, regroup/result/recovery와 runtime integrity: Phase 4에서 별도 재견적

bridge는 먼저 read-compare/shadow mode로 시작합니다. Local Lab은 exact account/snapshot/squad/build/runtime/control identity와 durable run state를 보존하고, damage 계산의 권위는 원본 client에 둡니다. 한 시즌씩 별도 closure/proof batch로 닫으며 Museum을 fallback으로 사용하지 않습니다.

## 이후 — Phase 4 1~5팀 actual-play와 runtime parity

- Phase 3C/3D에서 봉인한 one-team original-runtime observation provenance/adapter의 1~5팀 확장
- exact build/context/snapshot/squad/build/runtime/control pinning
- observation → regroup → next-team → close/result wire와 ESC/frame telemetry
- 실행 → 로딩 → 로컬 접속 → 로비
- profile/재화와 lobby keep/remove/replace 명세
- 니케·스쿼드·인벤토리 core projection
- 각 지원 시즌의 클래식 Solo Raid 선택과 Challenge 즉시 개방
- 1~5팀 전투, 사용 캐릭터 잠금과 재정비
- 원본 HUD/ESC 누적 damage와 result
- backend 팀별/누적 result 일치
- 05:00 KST rollover
- 시즌별 scene, behavior, QTE, part, animation과 timing
- `SoloRaidMuseum` 및 Museum 전용 버프 미사용

사용자가 custom presentation을 채택한 경우에만 Recruit no-op, season countdown/Quick Battle button 부재, widget 재배치와 six-season folder를 별도 acceptance로 추가합니다. 이 optional presentation의 부재는 core actual-play acceptance를 막지 않습니다.

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
