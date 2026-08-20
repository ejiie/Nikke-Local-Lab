# Phase 3B-1 — classic Solo Raid selected-manager patch

## 상태와 판정

상태: **완료 / `ready_for_isolated_season26_reference_run`**

3B-0의 static/content 판정은 계속 `ready_for_selected_manager_patch`이고, absolute timing 축은
`analysis_blocked_native_scheduler_rebind_required`입니다. 이 문서는 pinned EpinelPS에서 시즌 26 선택을
classic Solo Raid Challenge의 전체 요청 흐름에 유지하기 위한 구현 계획입니다. 실제 client 실행은 다음
3B-2가 소유합니다.

구현과 필수 test를 모두 통과하여 다음 판정을 발행했습니다.

```text
ready_for_isolated_season26_reference_run
```

통합된 external branch는 base `28b2f5413a0a1e3521a11ae162f91851335c8b40` 위의
`92a6ca228aeb580988907b96189b2857dff2c62d`입니다. Release rebuild는 기존 경고 `22`, 오류 `0`,
selected-manager/lifecycle test `58/58`과 dispatch isolation test `5/5`가 통과했습니다. Source-free
[receipt](../tests/fixtures/evidence/season26-classic-selected-manager.ready.json)와
[schema](../contracts/season26-classic-selected-manager.schema.json)는 `scripts/verify-phase3b1.ps1`로 검증합니다.
이 판정은 원본 client 실행, battle/HUD/result 또는 Local Lab bridge 완료를 뜻하지 않습니다.

## 목적과 비목표

목적은 synthetic local account가 **Museum이 아닌 시즌 26 원본 classic Solo Raid Challenge**를 선택했을 때,
EpinelPS의 모든 selection-sensitive route가 최신 시즌으로 이동하지 않고 같은 선택과 active run을 사용하게
하는 것입니다.

이번 단계에서 하지 않는 일은 다음과 같습니다.

- 원본 client, launcher, hosts, CA 또는 native compatibility shim 실행
- 실제 battle, damage, HUD와 result 검증
- Local Lab Phase 2B DB 또는 run aggregate와의 bridge
- client `150.6.9` native scheduler와 미해소 event timing 분석
- Museum, Normal, Practice, Fast Battle 또는 다른 시즌 지원 추가
- custom lobby, six-season folder, multi-team runtime parity

EpinelPS 내부의 `Trial` 명칭은 제외 대상이 아닙니다. Pinned 구현에서 `SoloRaidType.Trial=2`와 `Trial` route가
classic Challenge wire lane을 운반하므로 handler 이름이 아니라 UI mode와 Challenge preset 의미로
분류합니다. 명시적으로 제외할 콘텐츠는 Museum, Normal과 Practice입니다.

## 고정 입력과 작업공간

- upstream: [EpinelPS/EpinelPS](https://github.com/EpinelPS/EpinelPS)
- base commit: `28b2f5413a0a1e3521a11ae162f91851335c8b40`
- target client: `150.6.9`
- target content: 3B-0 source-free closure가 봉인한 시즌 26 classic Challenge chain
- code 작업 위치: 별도 AGPL-3.0 checkout/fork 또는 외부 patch queue
- Local Lab 저장 범위: public pin, source-free patch/test observation, verdict와 문서

EpinelPS source, generated protocol source, game data, decoded cache, certificate, private key, native binary와
patch output을 Local Lab 저장소에 복사하지 않습니다. Source-free receipt는 외부 AGPL source 제공 의무를
대체한다고 주장하지 않습니다.

선택 admission은 “catalog에 존재하는 manager”가 아니라 **3B-0 target observation에 결박된 단 하나의
시즌 26 manager**입니다. Raw target ID는 Git 비추적 local runtime binding으로 주입하고, tracked receipt에는
그 binding과 target observation의 일치 digest만 기록합니다. 다른 known manager도 3B-1에서는 지원하지 않습니다.

## 현재 결함과 route 의미

3B-0에서 확인한 현재 구현 분류는 다음과 같습니다.

| 현행 분류 | 수 | handler |
|---|---:|---|
| request manager | 6 | `Open`, `Close`, `ClosePractice`, `CloseTrial`, `GetLogs`, `FastBattle` |
| latest fallback | 9 | `GetInfo`, `GetLevel`, `GetLevelPractice`, `GetLevelTrial`, `OpenPractice`, `OpenTrial`, `SetDamage`, `SetDamagePractice`, `SetDamageTrial` |
| manager 미사용 | 4 | `Enter`, `EnterTrial`, `GetPeriod`, `GetRanking` |

이 `19/6/9/4`는 **현재 코드가 manager를 읽는 방식**에 대한 역사적 감사값입니다. 목적 상태의 의미 분류는
다릅니다.

- `Enter`, `EnterTrial`은 선택과 active run을 검증해야 하므로 selection-sensitive로 승격합니다.
- `GetPeriod`, `GetRanking`만 manager-independent로 유지합니다.
- 따라서 구현 전 policy는 `6 selected Challenge + 1 GetLogs characterization gate + 10 controlled unsupported +
  2 manager-independent`입니다. B1a가 GetLogs를 selected target read 또는 controlled unsupported 중 하나로
  확정한 뒤 최종 합계가 `7/10/2` 또는 `6/11/2`가 됩니다.
- wire 이름이 `Trial`인 Challenge handler는 시즌 26 selection/run을 사용하는 목표 경로입니다.

목표 route policy는 endpoint마다 하나로 고정합니다.

| 목표 policy | handler | 결과 |
|---|---|---|
| selected Challenge | `GetInfo`, `GetLevelTrial`, `OpenTrial`, `EnterTrial`, `SetDamageTrial`, `CloseTrial` | target selection, `SoloRaidType.Trial`과 Challenge `raidLevel=8`만 read/write |
| characterization gate | `GetLogs` | current response에는 `PeriodResult`가 없고 Normal/Practice만 읽으므로 target Trial projection 또는 wire-valid controlled denial을 B1a에서 결정; client compatibility는 3B-2까지 미검증 |
| controlled unsupported | `Open`, `Close`, `GetLevel`, `Enter`, `SetDamage`, `OpenPractice`, `ClosePractice`, `GetLevelPractice`, `SetDamagePractice`, `FastBattle` | route별 기존 controlled failure, zero mutation |
| manager-independent read | `GetPeriod` | resolver·selection mutation 없음 |
| manager-independent empty | `GetRanking` | current empty/no-op response shape를 B1a에서 고정; resolver·selection mutation과 `BanResult.Banned` 오용 없음 |

특히 Challenge의 `OpenTrial`은 manager ID를 받지 않고 현재 `0`을 latest-manager resolver로 전달합니다.
`GetInfo`도 첫 `open` 전에 호출될 수 있으므로 `/open` 요청값만 저장하는 방식으로는 해결할 수 없습니다.
시즌 26 선택은 **첫 classic Solo Raid 요청 전에 account별로 명시적으로 bootstrap**되어야 하며, `0`이나
`Keys.Max()`를 선택 의미로 사용하지 않습니다.

확인한 upstream 구현 지점은 다음과 같습니다.

- `EpinelPS/Models/UserModel.cs`: baseline의 account와 manager-keyed `SoloRaidData`에 patch가 nullable selected-manager를 추가
- `EpinelPS/Models/DbModels.cs`: manager/run별 Solo Raid 상태와 open 상태
- `EpinelPS/Database/JsonDb.cs`: 전체 user state를 `db.json`에 serialize/load
- `EpinelPS/LobbyServer/Soloraid/*.cs`: 위 19개 classic handler
- `EpinelPS/LobbyServer/Soloraid/SoloRaidHelper.cs`: current `Keys.Max()`/zero fallback의 중심
- `EpinelPS/Commands/Handler/SelectUser.cs`, `SetLevel.cs`: account lookup/update 방식만 참고하며 running interactive CLI 자체는 재사용하지 않음
- `EpinelPS/LobbyServer/LobbyMessage.cs`, `LobbyHandler.cs`: request identity와 handler dispatch

## 선택 상태와 active run pin

3B-1 v1은 EpinelPS가 현재 제공하는 안정된 권위 단위에 맞춰 account-scoped로 제한합니다. Bootstrap은
running interactive command가 아니라 **listener를 열기 전 startup phase**에서만 실행합니다.

```text
pre-listener startup binding
  -> account SelectedClassicSoloRaidManager       null -> exact target write-once
       -> request/session view                     account 선택을 읽기만 함
            -> ActiveClassicSoloRaidRun manager    enter/open 시 불변 pin
```

필수 불변조건은 다음과 같습니다.

- 선택은 global/static이 아니라 account별 nullable state입니다.
- Listener 시작 전에 startup binding이 Git 비추적 environment/config input에서 synthetic account와 raw manager를
  읽습니다. Account가 존재하고 selection이 null일 때만 exact target을 write-once 저장합니다. Same-target replay는
  idempotent하고 non-null overwrite는 거부합니다. Runtime selection mutation seam은 만들지 않습니다.
- B1a는 patch보다 먼저 `nll/season26-classic-target-observation/v1` canonicalization spec을 작성합니다. Fixed role
  order, 포함 field와 type, invariant decimal/string encoding, UTF-8/LF framing, duplicate·missing-row 거부를 고정하고,
  3B-0이 봉인한 target archive와 6/6 selected-row closure에서 독립적으로 expected binding digest를 생성해
  source-free evidence에 추가합니다. 이 spec과 reviewed digest가 없으면 B1b로 진행하지 않습니다.
- Bootstrap은 EpinelPS `GameData`의 선택 manager→Challenge chain에서 같은 versioned observation을 직접
  재계산해 reviewed expected digest와 비교합니다. Raw ID나 caller-supplied digest를 신뢰하지 않습니다. Known
  non-target, forged digest, higher decoy와 legacy non-target selection도 route-specific controlled failure와 zero
  mutation입니다.
- client request는 account 선택을 덮어쓰지 않습니다. Request manager가 있는 route는 선택·run pin과의 일치만
  검증합니다.

### 동결된 target binding contract

B1a의 선행 계약은 [machine-readable schema](../contracts/season26-classic-target-observation.schema.json)로
동결했습니다. 이는 3B-0의 `staticdata_archive_target` observation과 exact six-row closure에서 재계산한
source-free binding이며 raw manager/preset/wave/monster/model/stat ID나 row payload를 저장하지 않습니다.

- contract: `nll/season26-classic-target-observation/v1`
- canonicalization: `role_path_type_value_tsv_lf/v1`
- role order: `manager -> challenge_preset -> wave -> monster -> model -> stat_enhance`
- role line count: `3 / 13 / 13 / 96 / 12 / 12`; header 포함 총 `150`
- canonical byte length: `6684`
- trusted SHA-256: `ed3a8682d0bbb2b49394db1c862da74a8c44cab097188cad3d5b5851dc5f50ba`

외부 patch는 operator가 넘긴 raw manager ID에서 EpinelPS `GameData` chain을 직접 풀어 같은 bytes를 만들고
위 digest와 비교합니다. Expected digest를 caller input으로 받지 않으며 missing/duplicate row, Challenge가 아닌
preset, target/spawn 교집합이 정확히 하나가 아닌 wave, model/stat linkage 불일치는 bytes 생성 전에 거부합니다.
Schema의 field order, enum-underlying-int32, array count/item framing과 string 제한이 유일한 canonical 규칙입니다.
- Route policy를 resolver와 모든 read/write보다 먼저 평가합니다. Unsupported route는 target selection이
  있어도 resolver, helper, reward와 persistence에 진입하지 않습니다.
- manager resolution 우선순위는 `active run pin -> request/account selection consistency -> account selection`이며,
  어느 단계에도 latest fallback이 없습니다.
- target lifecycle은 `selected -> OpenTrial의 atomic (manager, Trial, raidLevel=8) pin -> EnterTrial 검증`에서
  두 branch로 나뉩니다. 정상 branch는 `SetDamageTrial`을 누적하고 pinned 구현의 다섯 번째 team damage가
  `IsOpen=false/IsClear=true` terminal을 만듭니다. 중도 종료 branch는 open 상태에서 `CloseTrial`을 호출합니다.
  Terminal 뒤 `CloseTrial`이 도착하면 B1a에서 고정한 idempotent denial/zero-mutation이어야 합니다. 모든 Trial
  request는 `raidLevel=8`을 강제합니다. 전체 manager/level
  state에서 active pin은 정확히 `0` 또는 `1`이어야
  하며, 복수 open, wrong mode/level 또는 selected-vs-open mismatch는 route-specific controlled failure와
  zero mutation입니다.
- active run의 manager는 불변이며 runtime account selection 변경은 항상 거부합니다.
- stable session/context ID가 없는 현재 upstream에서는 session override를 만들지 않습니다. 같은 account의
  session은 구분할 수 없고 같은 account selection/run을 공유합니다. 보장 가능한 것은 account당 하나의 active
  classic run이며, 3B-2 operator constraint는 한 account에 client 하나입니다.
- account 선택은 기존 JsonDb persistence seam에 저장하여 restart 뒤 exact 복원합니다. 과거 user row에 필드가
  없으면 nullable missing으로 복원하고 controlled failure합니다.
- 기존 manager-keyed `SoloRaidData`와 level `IsOpen`을 active run pin으로 우선 재사용하고, 중복된 두 번째
  run store는 만들지 않습니다. Selection resolver가 open `(manager, mode, level)`을 exact 검증합니다.
- restart 뒤 active state가 exact target lifecycle로 복원되지 않거나 복수/wrong-mode open이면
  `quarantined_non_resumable`로 판정합니다. 17개 manager-policy-covered route와 새 `OpenTrial`은 route-specific
  controlled failure와 zero mutation이며, `GetPeriod`와 `GetRanking`은 계속 selection-independent입니다. 자동
  clear나 latest manager 복구는 없습니다. 3B-1에서는 quarantined row를
  수선하는 명령을 만들지 않고 disposable synthetic account를 기존 local account-admin flow로 폐기·재생성해야
  합니다. 재생성 전에는 새 run을 만들지 않습니다.
- selection 없음, unknown/stale manager, request mismatch와 cross-account access는 stable failure response와
  zero mutation을 보장합니다. 단순 exception 후 success response를 반환하는 기존 패턴은 허용하지 않습니다.

3B-1에서는 target build/content identity가 process pin으로 고정됩니다. Local Lab의 UUID context/run과 연결하는
작업은 3C 전에는 하지 않습니다.

현재 handler registry는 route마다 mutable `LobbyMessage` instance를 재사용합니다. 각 instance가 request별
context와 `UserId`를 보유하므로 동시 요청에서 account identity가 섞일 수 있습니다. Account isolation을
주장하기 전에 registry를 handler `Type`/factory로 바꾸어 dispatch마다 새 instance를 만들고, classic Solo Raid의
selection/open/damage/close/save transition을 account key로 직렬화합니다. 이 패치는 multi-client server 전체의
thread safety나 session isolation을 완성한다는 뜻이 아닙니다. Same-account request는 구분하지 않고 하나의
account state machine으로 직렬화하며, 한 client/account는 3B-2의 operator 제약입니다.

`JsonDb.Save()`는 전체 user collection을 하나의 `db.json`에 serialize/write하므로 account lock만으로는 충분하지
않습니다. Selected-manager와 classic Solo Raid mutation은 process-wide classic-persistence coordinator 안에서
`classic mutation -> snapshot -> temp file -> atomic replace`까지 직렬화합니다. 3B-1은 coordinator를 거치지
않는 기존 server-wide writer까지 안전하다고 주장하지 않습니다. 3B-2에서는 다른 mutating route를 비활성화하고
synthetic account/client 하나만 사용합니다. 더 넓은 server persistence 직렬화는 별도 prerequisite입니다.

## 구현 batch

### B1a — baseline과 characterization — `0.25~0.5시간`

1. 별도 checkout을 exact base commit에 고정하고 license와 clean worktree를 확인합니다.
2. restore/build 명령과 toolchain version을 기록하고 수정 전 baseline을 통과시킵니다.
3. 위 19개 handler의 파일, request shape, UI mode, Challenge preset 의미와 write side effect를 manifest로
   고정합니다.
4. `Trial`이 classic Challenge를 운반하는 경로와 Museum/Normal/Practice 경계를 characterization test로
   먼저 고정합니다.
5. 외부 tree에 기존 test seam이 없거나 baseline build가 실패하면 구현에 들어가지 않고 재견적합니다.
6. route별 failure-capability manifest를 만듭니다. `PeriodResult`를 가진 response는 기존
   `SoloRaidPeriodResult.Failure=1`을 사용하고 새 wire enum을 발명하지 않습니다.
7. `GetLogs`와 `GetRanking` response에는 `PeriodResult`가 없으므로 `BanResult.Banned`를 selection failure로
   오용하지 않습니다. GetLogs target Trial projection 또는 wire-valid denial을 입증하지 못하면 stop하며,
   GetRanking은 current empty/no-op response를 characterization합니다. Client compatibility는 3B-2까지 주장하지
   않습니다.
8. `nll/season26-classic-target-observation/v1`의 exact role/field/type/framing spec과 expected digest를 3B-0의
   sealed target archive·selected-row closure에서 생성해 review합니다. Caller input으로 expected digest를 받거나
   manager ID만 hash하지 않으며, 이 binding artifact가 없으면 stop합니다.

### B1x — dispatch isolation prerequisite — `0.5~0.75시간`

1. Singleton handler registry를 handler type/factory로 바꾸어 request마다 새 `LobbyMessage` instance를 만듭니다.
2. Mutable request context와 `UserId`가 concurrent account A/B 사이에서 섞이지 않는 characterization test를
   먼저 red→green으로 닫습니다.
3. Classic Solo Raid transition을 account key로 직렬화하고 competing open에서 active pin 하나만 생성되게 합니다.
4. Process-wide classic-persistence coordinator가 classic mutation, snapshot과 temp-file atomic replace를 한
   경계로 직렬화하게 합니다. 기존 다른 writer와의 global consistency는 주장하지 않습니다.
5. 이 변경이 Solo Raid 밖 dispatch에 광범위한 회귀를 만들면 별도 `3B-1x` gate로 분리하고 재견적합니다.

### B1b — selection resolver와 persistence — `0.5~0.75시간`

1. `User`에 nullable `SelectedClassicSoloRaidManagerId` 또는 동등한 필드를 추가합니다.
2. Listener 시작 전 account-specific binding phase를 추가합니다. Target raw ID와 synthetic account identity는
   Git 비추적 environment/config input에서 받고, canonical target observation을 재계산합니다. `(selection=null,
   active run 없음)`만 target을 새로 저장합니다. `(selection=target, active run 없음 또는 exact resumable target
   run)`은 validate-only idempotent success로 처리합니다. Selection mismatch, non-target, malformed/quarantined
   active state 또는 이미 시작된 listener에서는 no mutation으로 실패합니다. Raw value를 stdout/log에 출력하지
   않고 새 저장이 필요한 경우에만 classic-persistence coordinator로 atomic 저장합니다.
3. pure resolver를 만들어 selection 없음·unknown·known non-target·mismatch를 typed result로 반환하게 합니다.
4. 기존 JsonDb serialize/reload에서 exact selection이 복원되는지 검증합니다.
5. 기존 manager-keyed Solo Raid state와 open level을 active run pin으로 재사용하고 `0/1/>1` uniqueness와
   exact Trial/Challenge-level shape를 검사합니다.

### B1c — route wiring — `0.5~0.75시간`

1. legacy latest-fallback 9개 중 selected Challenge 4개는 central resolver로 교체하고 Normal/Practice 5개는
   helper/resolver 전에 거부합니다.
2. request-manager 6개 중 `CloseTrial`과 B1a가 target projection으로 확정한 `GetLogs`만 request와
   account/run pin의 exact 일치를 검증합니다. `Open`, `Close`, `ClosePractice`, `FastBattle`과 denial outcome의
   `GetLogs`는 resolver 전에 거부합니다.
3. `EnterTrial`은 selected manager와 active-run pin을 검증하고 Normal `Enter`는 resolver 전에 거부합니다.
4. 위 route policy table대로 Challenge/Trial 6개와 B1a에서 확정한 GetLogs outcome만 허용하고
   Normal/Practice/Fast Battle 10개는 route-specific controlled failure와 zero mutation으로 고정합니다.
5. `GetPeriod`는 manager-independent read, `GetRanking`은 manager-independent controlled empty/no-op으로
   고정합니다.
6. Museum dispatcher 호출을 금지합니다.
7. `SetDamage*`는 exact open run이 없을 때 level/run을 새로 만들지 않고 zero mutation으로 실패합니다.
8. `GetInfo`, `GetLevelTrial`과 허용된 GetLogs가 daily counter를 reset/mutate하면 같은 target validation과
   classic-persistence coordinator 안에서 atomic save하고 rollover/restart test를 통과시킵니다.

### B1d — adversarial focused tests — `0.75~1.5시간`

새 `tests/EpinelPS.SelectedManager.Tests` 또는 동등한 focused project를 solution에 추가하고 아래 MUST matrix를
parameterized test로 구현합니다. 한 route씩 복제한 느슨한 happy-path test보다 동일한
decoy와 mutation probe를 17개 manager-policy-covered route에 반복 적용합니다.

### B1e — evidence와 handoff — 완료

1. external integration commit을 exact base에 결박했습니다.
2. Local Lab에 source-free receipt schema, assessment, manifest와 `verify-phase3b1.ps1`을 추가했습니다.
3. verifier는 3B-0 gate를 먼저 실행하고 route/test/fallback/persistence 결과를 검증합니다.
4. workflow와 pre-commit의 최상위 gate를 3B-1로 전환했습니다.
5. 남은 3B-2 engineering estimate는 `2~4시간`이며 VM 준비와 사용자/client 대기는 제외합니다.

위 batch 합 `2.75~4.75시간`에 cross-batch integration contingency `0.25시간`을 포함한 합계 조건부 견적은
`3~5시간`입니다. B1a/B1x에서 test scaffold, generated protocol 변경, 별도 DB migration,
full-server-only seam 또는 광범위 dispatch 회귀가 발견되면 5시간 안에 억지로 합치지 않고 dispatch prerequisite와
`3B-1a resolver/route`, `3B-1b persistence/restart`로 다시 분할합니다.

## MUST test matrix

| 축 | 필수 검증 |
|---|---|
| route completeness | legacy `19/6/9/4`, target `6 allowed / 1 GetLogs gate / 10 unsupported / 2 independent`; B1a 뒤 final count 누락·중복 0 |
| latest decoy | 시즌 26 target보다 큰 decoy가 있어도 허용된 Challenge/Trial route는 target만 read/write하고 decoy access 0 |
| target admission | B1a에서 canonical role/field/type/framing과 expected digest를 sealed 3B-0 target evidence로 먼저 고정; GameData에서 재계산해 비교하고 known non-target·forged supplied digest 거부 |
| failure capability | 19개 route별 exact response code/transport outcome 고정; `GetLogs`에 `BanResult.Banned` 오용 0 |
| unsupported routes | route policy table의 Normal, Practice, Fast Battle은 모두 route-specific controlled failure와 zero mutation |
| missing/invalid | selection 없음, unknown/stale selection, request mismatch 모두 route-specific controlled failure와 zero mutation |
| account isolation | account A의 target 선택과 account B의 missing/다른 선택이 서로 보이거나 변경되지 않음 |
| same-account scope | session isolation은 unavailable; 모든 request가 account selection/run을 공유하고 client route는 selection을 바꾸지 않음 |
| pre-listener bootstrap | `listener_not_started=true`; null/no-run→target write-once, same-target+no-run 또는 exact resumable active-run replay는 validate-only idempotent, mismatch/quarantine/runtime overwrite 거부 |
| run lifecycle | open/enter 뒤 five-damage terminal branch와 pre-terminal close branch 분리; terminal 뒤 close denial/no-mutation; 복수/wrong-mode/non-8/mismatch 실패 |
| enter semantics | `Enter`, `EnterTrial`이 selection/run mismatch에서 run을 만들지 않음 |
| Challenge wire | `Trial*` Challenge route가 시즌 26을 사용하고 이름만으로 차단되지 않음 |
| Museum boundary | Museum dispatcher, stage와 buff sentinel 관측 0 |
| retry/reconnect | retry와 reconnect가 selection을 바꾸거나 cross-manager write를 만들지 않음 |
| restart | same-target+exact active run은 validate-only bootstrap 뒤 exact 복원; malformed state는 quarantine하고 17 manager-policy-covered route zero mutation, independent 2 route는 resolver 비호출, disposable account 재생성 전 새 open 거부 |
| manager-independent | `GetPeriod` read와 `GetRanking` empty/no-op가 resolver·selection mutation 없이 동작 |
| request isolation | handler factory가 request마다 다른 instance를 만들고 concurrent account A/B의 `UserId`·selection이 섞이지 않음 |
| account serialization | competing same-account open에서 정확히 한 active pin만 생성되고 혼합 상태 없음 |
| classic persistence | coordinator를 거친 classic A/B mutation의 atomic replace와 lost update 0; global server-wide 보장은 주장하지 않음 |
| damage precondition | exact open run 전에 `SetDamage*`를 호출하면 level/run/damage를 만들지 않고 실패 |
| ordered Challenge chain | decoy 상태에서 one-team partial `GetInfo -> GetLevelTrial -> OpenTrial -> EnterTrial -> SetDamageTrial`, five-team terminal branch와 별도 pre-terminal `CloseTrial` branch가 모두 같은 target 사용 |
| rollover persistence | selected target의 daily counter mutation만 atomic save/reload되고 decoy와 다른 account는 불변 |
| negative control | resolver가 decoy/latest를 반환하도록 test double을 바꾸면 matrix가 실제로 red가 됨 |

`latest_fallback_after=0`은 legacy 9개 callsite의 정적 제거만 뜻하지 않습니다. 17개 manager-policy-covered route의
동적 read/write와 side effect에서 decoy 관측이 0이어야 합니다.

## SHOULD와 DEFER

시간이 남으면 다음을 추가합니다.

- active run restart exact resume와 duplicate damage/terminal-close의 기존 idempotency 회귀
- catalog/content revision drift가 열린 run을 새 content로 바꾸지 않는지
- handler별 resolver 호출과 zero-mutation coverage 계측

다음 항목은 3B-1에서 미룹니다.

- disposable VM, client launch, hosts/CA/native shim과 battle/result — 3B-2
- Local Lab bridge와 durable identity correlation — 3C/3D
- 1~5팀, regroup, recovery와 full telemetry — Phase 4
- 다른 시즌, custom lobby, Museum/Normal/Practice 지원
- native scheduler와 절대 timing
- upstream PR, 배포 또는 법적 결론

## Stop / 재견적 조건

다음 중 하나가 발생하면 현재 batch를 중단하고 receipt에 reason을 남깁니다.

- exact pinned base가 documented toolchain으로 restore/build되지 않음
- Challenge wire `Trial`과 별도 mode의 의미를 characterization으로 고정하지 못함
- pre-listener selection bootstrap에 generated protocol, 새 executable 또는 광범위 host lifecycle 변경이 필요함
- 기존 JsonDb와 호환되는 nullable account persistence가 불가능함
- stable failure response를 만들 test seam이 없고 handler가 exception을 success로 축약함
- `GetLogs`에 target projection 또는 wire-valid controlled denial을 입증하지 못함
- classic Solo Raid mutation의 temp-file atomic replace 경계를 만들지 못함
- route matrix에 미감사 handler가 추가되거나 legacy count가 달라짐
- target client/content pin이 3B-0과 달라짐
- Museum, 다른 시즌 또는 latest fallback 없이는 test를 통과할 수 없음

첫 네 항목 중 persistence/test seam만 큰 경우에는 `3B-1a`와 `3B-1b`로 분리해 다시 견적합니다. Client 실행이나
Local Lab bridge를 끌어와 3B-1의 실패를 덮지 않습니다.

## Source-free receipt 계획

구현 완료 시 Local Lab receipt에는 다음만 기록합니다.

- contract/schema version, public upstream URL과 base/patch pin
- target client/content observation digest, `binding_algorithm=nll/season26-classic-target-observation/v1`,
  matched 3B-0 observation role와 `recomputed_match=true`
- legacy route audit `19/6/9/4`, pre-characterization policy `6/1/10/2`와 final post-patch policy count
- `trial_wire_semantics=classic_challenge`
- excluded capability `museum`, `normal`, `practice`
- selection scope `account`, `session_isolation=not_available_account_scoped`, session override `false`, single-active-run policy
- `bootstrap_execution_mode=prelisten_startup`, `listener_not_started`, runtime selection mutation count `0`,
  `active_pin_uniqueness`와 `active_run_restart_outcome`
- route-policy/failure-capability manifest digest, GetLogs wire outcome와
  `getlogs_client_compatibility=unverified_until_3b2`, GetRanking empty outcome, zero-mutation case count
- `trial_level_guard=8`, `classic_solo_raid_persistence_serialized`, rollover persistence result
- `per_request_handler_instance`, `account_transition_serialized`, concurrent identity mix count
- focused test case/count/result, `latest_fallback_after=0`, Museum invocation `0`, `negative_control_detected`
- external patch/test digest, toolchain과 aggregate verdict

원본 manager/raid ID, row/payload, local path, credential/token, certificate/key, decoded byte와 patched binary는
기록하지 않습니다.

외부 checkout에서 계획한 기본 검증 명령은 다음과 같습니다. B1a가 실제 toolchain과 solution shape를 먼저
확인하며, 명령이 다르면 이유와 exact replacement를 receipt에 기록합니다.

```powershell
dotnet restore EpinelPS.sln
dotnet build EpinelPS.sln -c Release --no-restore
dotnet test EpinelPS.sln -c Release --no-build
git diff --check
```

Focused static gate는 classic handler subtree의 `Keys.Max()`와 `GetRaidId()` 잔존 0, Museum reference 0,
tracked target raw ID 0을 검증합니다. Local Lab의 `verify-phase3b1.ps1`은 기존
`verify-phase3b0.ps1`을 선행 호출한 뒤 완료 receipt와 route/test 봉인을 검증합니다.

## 완료 의미와 3B-2 handoff

3B-1 완료는 **외부 pinned EpinelPS가 synthetic account의 시즌 26 선택을 classic Challenge route와 active run에
일관되게 유지하며 최신 시즌이나 Museum으로 이동하지 않는다**는 뜻입니다.

아직 원본 client가 이 route에 접속하거나 battle/result를 반환했다는 뜻은 아닙니다. 3B-1 receipt가
`ready_for_isolated_season26_reference_run`일 때만 [PHASE3.md](PHASE3.md)의 3B-2 disposable reference run으로
진행합니다.
