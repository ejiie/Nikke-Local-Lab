# Phase 3B-2 Wave 0 — disposable preflight and reference-run contracts

## 현재 판정

상태: **`contract_scaffold_only`**

현재 이 문서가 확정하는 것은 disposable 환경의 첫 Wave 0을 어떤 입력, 관측, 실패 우선순위와
rollback 조건으로 판정할지뿐입니다.

- disposable VM/별도 OS measured preflight receipt: 없음; checked-in artifact는 blocked/not-executed 합성 fixture뿐
- client `150.6.9` VM copy hash 검증: 미실행
- EpinelPS build/listener/outbound runtime 관측: 미실행
- measured reference-run receipt와 원본 client loading/login/lobby 관측: 없음; checked-in artifact는
  blocked/not-executed 합성 fixture뿐
- classic Solo Raid 시즌 26 화면·전투·result 관측: 없음
- `GetLogs` client compatibility 관측: 없음
- rollback 실행 증거: 없음
- Wave 0 aggregate verdict: `not_evaluated`

따라서 이 문서는 `GO`를 발행하지 않으며, `ready_for_3c`, `reference_run_passed`,
`original_client_result_observed_one_team` 또는 runtime parity를 주장하지 않습니다.
[PHASE3B1.md](PHASE3B1.md)의 `ready_for_isolated_season26_reference_run`은 Wave 0에 들어갈 수 있는
external selected-manager 입력의 판정이지, 이 문서의 VM/client proof가 이미 존재한다는 뜻이 아닙니다.

## 권위와 범위

이 문서는 Phase 3B-2 **Wave 0 한 번**의 preflight와 reference run 계약에 대한 사람용 단일 권위입니다.
목표는 snapshot 가능한 disposable VM/별도 OS에서 synthetic local account 하나와 client 하나로 다음
최소 전이를 관측하는 것입니다.

```text
local loading/login
  -> lobby
  -> original classic Solo Raid main/ready
  -> season 26 Challenge open
  -> first five-member squad enter
  -> original battle runtime
  -> one-team client damage/result return
```

Wave 0은 다음을 소유하지 않습니다.

- Local Lab Phase 2B run/context/profile/squad revision과의 durable bridge 또는 correlation
- 다섯 팀 전체 clear, regroup, next-team, raid-wide aggregate와 recovery parity
- Local Lab 또는 server가 계산한 damage/result
- native scheduler의 절대 frame/ms timing과 full HUD/ESC/frame telemetry parity
- 다른 시즌, Normal, Practice, Fast Battle/Quick Battle 또는 `SoloRaidMuseum`
- custom multi-season lobby, 배포, 공식 계정 또는 공식 traffic replay

Wave 0의 direct client observation은 후속 3C/3D의 identity sealing과 Phase 4의 1~5팀 parity를
대체하지 않습니다. Lab harness receipt는 이 문서의 original-client evidence로 승격하지 않습니다.

## 동결된 machine contract ID

Wave 0의 machine contract ID는 다음 두 개뿐입니다.

| 역할 | contract ID | 의미 |
|---|---|---|
| live preflight | `nll/season26-classic-live-preflight/v1` | client 시작 전 환경·pin·build·network·backup과 client-start admission |
| reference run | `nll/season26-classic-reference-run/v1` | 원본 client transition, 한 팀 result, GetLogs, rollback과 aggregate verdict |

두 contract의 사람용 절차와 Git 밖 canonical observation manifest에서 다음 section/observation code를
사용합니다. 이 값들은 독립된 contract ID나 machine receipt의 새 top-level property가 아닙니다.

| code | 소유 contract | 의미 |
|---|---|---|
| `wave0_envelope` | 양쪽 | 같은 Wave 0 identity와 predecessor receipt 결박 |
| `preflight_receipt` | live preflight | cold environment와 server-start/client-cold 관측 |
| `reference_run_receipt` | reference run | original-client transition과 한 팀 result 관측 |
| `getlogs_observation` | reference run | classic `GetLogs` 사용 여부와 wire outcome |
| `rollback_receipt` | reference run | 종료·실패 뒤 복원과 primary-install 불변 검증 |
| `aggregate_verdict` | reference run | evidence strength, dominant failure와 다음 단계 금지/허용 판정 |

Checked-in schema와 fixture는 이 두 ID의 source-free shape와 fail-closed 상태를 고정합니다. 현재 fixture는
계약 scaffold를 검증하기 위한 blocked/not-executed 합성 자료일 뿐이며 disposable VM에서 측정한 ready
preflight, client transition, battle/result 또는 rollback evidence가 아닙니다. Verifier가 schema와 이 합성
fixture를 통과시켜도 live readiness나 reference-run 성공으로 승격하지 않습니다. 호환되지 않는 의미 변경은
기존 ID를 재사용하지 않고 `/v2`로 분리합니다.

- live preflight [schema](../contracts/season26-classic-live-preflight.schema.json)와
  [blocked fixture](../tests/fixtures/synthetic/season26-classic-live-preflight.blocked.json):
  `verdict=blocked_preflight_incomplete`, `measuredEvidence.statusCode=not_measured`
- reference-run [schema](../contracts/season26-classic-reference-run.schema.json)와
  [not-executed fixture](../tests/fixtures/synthetic/season26-classic-reference-run.not-executed.json):
  `verdict=not_executed_contract_scaffold_only`, `execution.statusCode=not_executed`
- [contract verifier](../scripts/verify-phase3b2.ps1): 두 fixture의 schema/source-free/pin/fail-closed shape를
  검사하지만 disposable environment 또는 client를 실행하지 않음

## 외부 dependency pin chain

Wave 0은 다음 외부 EpinelPS chain 전체가 exact하게 일치할 때만 같은 대상이라고 판정합니다.

```text
reviewed upstream base
  28b2f5413a0a1e3521a11ae162f91851335c8b40
    -> Phase 3B-1 integration
       92a6ca228aeb580988907b96189b2857dff2c62d
         -> Phase 3B-2 local-only preflight seal
            e32e5f900775974d5736e7fb2b50f8c62638a004
              -> preflight hardening HEAD
                 4f7bd5b5eb2b9a6e03af503f1c09adc4c4f7f16f
                   -> Git tree
                      ce353eeebee3c76672e483c6f735bb27f0227815
```

필수 pin 규칙은 다음과 같습니다.

1. commit ancestry는 위 순서를 만족해야 합니다.
2. hardening HEAD의 tree object는 exact
   `ce353eeebee3c76672e483c6f735bb27f0227815`여야 합니다.
3. checkout은 tracked/untracked 변경이 없는 clean 상태여야 하며 submodule 또는 generated input이 있으면
   별도로 exact pin을 기록합니다.
4. 실행 binary와 runtime input은 hardening HEAD에서 documented toolchain으로 새로 build/검산한 byte여야
   하며 commit/tree 일치만으로 binary provenance를 추정하지 않습니다.
5. target client는 exact build `150.6.9`와 3B-0/3B-1 target observation에 결박되어야 합니다.
6. 위 preflight/hardening commit과 tree는 외부 AGPL checkout의 pin입니다. Local Lab source에 포함됐거나
   source-free receipt만으로 복원 가능하다고 주장하지 않습니다.

어느 commit ancestry나 tree가 다르면 preflight `blocked_external_pin_drift`, build artifact/client/runtime input
또는 target observation이 다르면 `blocked_runtime_input_mismatch`로 STOP합니다.
다른 commit, prebuilt binary, 최신 manager 또는 다른 시즌으로 자동 대체하지 않습니다.

## Wave 0 실행 단위

한 Wave 0은 다음 identity를 시작 전에 고정하고 실행 중 바꾸지 않습니다.

- lab-owned random live-preflight `assessmentUid`와 reference-run `assessmentUid`
- reference-run `preflightBinding`의 exact preflight assessment UID/SHA-256/verdict 결박
- disposable VM/OS snapshot identity의 비가역 digest
- client build/content manifest digest
- external commit/tree와 server build artifact digest
- reviewed locale/runtime input manifest digest
- synthetic account observation digest
- target binding contract `nll/season26-classic-target-observation/v1`과 trusted digest
- firewall/listener policy digest
- change/backup/rollback manifest digest

한 account에 client 하나, account당 active classic run 최대 하나만 허용합니다. Server 또는 client 재시작,
snapshot 복원, pin 변경, manifest 변경이나 failure 뒤 재시도는 같은 실행의 연장이 아니라 새 assessment
pair입니다. 실패 원인을 고치기 위해 여러 변경을 한 번에 적용하지 않습니다.

## Preflight contract

### P0 — cold environment admission

Server나 client process를 시작하기 전에 다음을 모두 확인합니다.

- snapshot·복원이 가능한 disposable Windows VM/별도 OS이며 단순 디렉터리 복제본이 아님
- `C:\NIKKE` 주 설치본은 실행·수정 대상이 아니고 before digest가 기록됨
- VM 내부 disposable client가 exact `150.6.9` build/content manifest와 일치함
- synthetic local account만 준비되어 있고 official credential, cookie, session과 token이 없음
- 외부 pin chain, clean tree, toolchain, build artifact와 네 개의 reviewed locale/runtime input이 exact
- server의 `--headless --local-only` 또는 동등한 fail-closed local-only 설정이 effective함
- client, launcher, server와 관련 child process 전체에 non-loopback deny가 적용되고 관측 seam이 준비됨
- local endpoint는 `127.0.0.1` exact bind만 허용되며 wildcard/LAN/public bind와 port forwarding이 없음
- hosts, root CA, client-local certificate bundle과 native shim의 before length/SHA-256, backup과 rollback
  순서가 Git 비추적 manifest에 존재함
- original/decoded data, certificate private key, patched binary, raw binding과 VM snapshot의 Git/CI 유입
  경로가 없음

전부 통과하면 `GO_SERVER_START` 후보가 됩니다. 이 시점에도 client 시작은 허용하지 않습니다.

### P1 — server-start / client-cold admission

Server만 먼저 시작한 뒤 client를 시작하기 전에 다음을 직접 관측합니다.

- HTTP `80`과 HTTPS `443`의 effective listener가 필요한 경우 모두 `127.0.0.1` exact bind
- wildcard, LAN 또는 예상 밖 listener 수 `0`
- official asset/locale auto-fetch, Git update와 interactive update surface가 비활성
- startup 동안 non-loopback connection attempt와 successful connection 모두 `0`
- target binding 재계산이 3B-1 trusted observation과 일치
- synthetic account bootstrap은 listener 이전 write-once/validate-only 규칙을 지켰고 selection/runtime
  mutation 또는 latest fallback이 `0`
- active run 상태가 없거나 exact resumable target 하나이며 quarantine/multiple/wrong-mode/non-8 상태가 없음
- server log와 receipt에 raw account, manager ID, credential, local path 또는 decoded payload가 노출되지 않음

전부 통과하고 P0 receipt와 P1 observation이 같은 pin/manifest에 결박될 때만 `GO_CLIENT_START`를 발행할 수
있습니다. 이 GO는 exact preflight assessment와 그 digest에 결박된 reference-run assessment 한 번에만
유효합니다.

## Reference-run contract

### 전이 관측

Client 시작 뒤 다음 transition을 순서대로 한 번씩 좁게 관측합니다.

| 순서 | 필수 관측 | 통과 의미 |
|---:|---|---|
| 1 | local loading/login | official identity 없이 synthetic local flow가 계속됨 |
| 2 | lobby | 원본 client lobby가 치명적 transport 오류 없이 표시됨 |
| 3 | classic Solo Raid main/ready | Museum이 아닌 시즌제 `SoloRaid` 화면 |
| 4 | season 26 Challenge open | selected target, `Trial` wire, Challenge level `8`이 같은 active pin을 사용 |
| 5 | first squad enter | 첫 5인 squad가 같은 pin으로 원본 battle scene에 handoff |
| 6 | original battle runtime | 원본 animation/behavior/parts/HUD 경로가 시작되고 server/sidecar 대체 계산 없음 |
| 7 | one-team client result | 아래의 한 팀 result 의미를 만족 |

각 transition은 `observed`, `not_observed`, `controlled_failure` 중 하나와 순서 번호, monotonic offset,
source-free evidence digest를 남깁니다. 원본 screenshot/video, raw payload와 decoded content는 Git에 넣지
않고 Git 밖 evidence의 byte length/digest만 tracked receipt에 남깁니다.

Museum route, stage 또는 buff sentinel이 한 번이라도 관측되면 기술적으로 battle이 열려도 성공이 아닙니다.
최신 manager나 다른 시즌도 fallback으로 인정하지 않습니다.

### `one-team client result`의 정확한 의미

Wave 0의 `one-team client result`는 **첫 5인 squad 한 팀의 battle attempt가 원본 client runtime에서 끝나고,
그 client가 산출·표시한 team damage/result가 classic Challenge wire로 돌아온 것을 직접 관측했다**는 뜻입니다.

이 판정을 발행하려면 다음이 모두 필요합니다.

- result 직전까지 build, target selection과 immutable active-run pin이 변하지 않음
- original client battle/result 화면 또는 동등한 원본 result presentation이 직접 관측됨
- target `SetDamageTrial` 또는 pinned 구현이 사용하는 동등한 classic result transition이 정확한 open run에
  도달함
- client presentation의 team result와 local server가 수신한 result가 일치함을 Git 밖 comparator로 확인
- tracked receipt에는 실제 damage value 대신 `client_server_result_match=true`, 양쪽 source-free digest와
  byte length만 기록
- server, Local Lab과 sidecar가 damage를 재계산·보정하거나 client 값을 대체하지 않음
- Museum invocation/buff, latest fallback, cross-manager write와 cross-account mutation이 모두 `0`

이 의미는 다음을 포함하지 않습니다.

- EpinelPS의 다섯 번째 team damage가 만드는 raid terminal 또는 raid clear
- 다섯 팀 aggregate, next-team/regroup와 close/recovery parity
- Local Lab Phase 2B result observation 또는 UUID run correlation
- 모든 HUD 수치, frame timing, QTE/part behavior와 scheduler parity의 완료
- 다른 build·시즌·squad에 대한 일반화

따라서 한 팀 result를 관측해도 evidence strength는 `original_client_result_observed_one_team`을 넘지 않으며,
3C/3D나 Phase 4 완료로 승격하지 않습니다.

## `GetLogs` observation contract

3B-1은 classic `GetLogs`의 target Trial projection을 선택 route에 포함했지만 client compatibility는 3B-2까지
미검증으로 남겼습니다. Wave 0은 `GetLogs`를 result authority가 아닌 별도 보조 관측으로 기록합니다.

`getlogs_observation` section의 필수 outcome enum은 다음과 같습니다.

- `not_requested_by_client`: 이 실행에서 client request가 관측되지 않음
- `requested_target_projection_accepted`: target Trial projection이 반환되고 client가 다음 예상 transition을 계속함
- `requested_controlled_denial_accepted`: wire-valid denial 뒤 client가 안전하게 계속하거나 닫힘
- `requested_shape_or_transport_failure`: response shape/transport가 client flow를 깨뜨림
- `requested_wrong_target_or_mutation`: 다른 manager/mode/account read·write 또는 예상 밖 persistence mutation

모든 outcome은 request의 transition 위치, 호출 횟수, target binding match, active-pin match, response-shape
digest, client-visible continuation과 mutation count를 Git 밖 canonical observation set에 남깁니다. Tracked
machine receipt는 이 set의 member count/byte length/digest를 `execution.canonicalManifest`로만 결박하고 GetLogs
raw outcome을 새 top-level property로 추가하지 않습니다. Raw request/response, manager ID, log entry 내용과
account identity는 기록하지 않습니다.

`GetLogs`만 성공해도 battle/result 증거가 되지 않습니다. `not_requested_by_client`이면 one-team result의 직접
관측을 무효화하지 않지만 `GetLogs` compatibility는 계속 `not_observed`입니다.
`requested_controlled_denial_accepted`도 denial compatibility만 증명하며 target projection 성공으로 승격하지
않습니다. `requested_shape_or_transport_failure`가 필수 client flow를 막으면 STOP하고,
`requested_wrong_target_or_mutation`은 즉시 STOP합니다. 이 두 경우 reference-run machine verdict는 실제
관측에 따라 `runtime_blocked_season_26`을 사용하고, `blockingReasonCodes`에 GetLogs-specific controlled
reason을 남깁니다. 환경 침해나 Museum 관측이 함께 있으면 아래의 더 높은 verdict가 우선합니다.

## Evidence strength

Aggregate receipt의 `evidence_strength`는 실제로 완료한 가장 강한 관측 하나만 사용합니다.

| strength | 필요한 증거 | 주장할 수 없는 것 |
|---|---|---|
| `contract_scaffold_only` | 문서·schema와 blocked/not-executed 합성 fixture만 존재 | measured environment, client 또는 runtime proof 전부 |
| `preflight_source_free_attested` | P0/P1과 pin·listener·egress·backup receipt 통과 | client launch, UI와 battle/result |
| `original_client_transition_observed` | preflight 뒤 client transition 1개 이상 직접 관측 | battle/result 완료와 runtime parity |
| `original_battle_runtime_started` | target classic Challenge의 first squad battle scene 시작 | client result, clear와 telemetry parity |
| `original_client_result_observed_one_team` | 한 팀 result의 모든 필수 조건과 rollback 통과 | raid clear, 1~5팀 parity, Local Lab sealing |

실패가 발생해도 이미 얻은 낮은 strength의 사실은 보존할 수 있지만 aggregate verdict를 성공으로 올리지
않습니다. Static/source-free test, server log만의 추정, harness와 공개 영상은 direct client observation strength를
발행할 수 없습니다.

## Source-free receipt fields

Tracked receipt에는 두 checked-in machine schema가 허용하는 source-free field군만 사용합니다. 현재
blocked/not-executed 합성 fixture의 값이나 schema-valid 임의 값은 measured ready/live evidence로 간주하지
않습니다.

### 공통 field군

- `schemaVersion`, 동결된 `contractId`, lab-owned `assessmentUid`, UTC `assessedAtUtc`와 `verdict`
- exact `target`과 위 다섯 외부 pin을 가진 `externalLineage`
- `prohibitedMaterial`, `blockingReasonCodes`, `nextStepRequirementCodes`

### Live-preflight 전용 field군

- `environment`: disposable/snapshot/system-trust/primary-install/synthetic-account 상태
- `runtimeInputs`: client build, external lineage, reviewed input `4/4` 상태와 source-free manifest
- `networkIsolation`: process-tree scope, exact loopback bind, non-loopback egress와 IPv4/IPv6/DNS/TCP/UDP coverage
- `mutationRollback`: hosts, root CA, client certificate bundle, native shim의 backup/rollback 준비 상태
- `measuredEvidence`: `statusCode`, observation count와 canonical manifest
- `remainingBoundary`: reference run, original battle/result와 3C/3D/Phase 4가 아직 검증되지 않았다는 경계

Ready preflight를 표현할 수 있는 machine verdict는
`ready_to_start_isolated_season26_reference_run` 하나이며, `measuredEvidence.statusCode=measured_complete`와
필수 exact/prepared source-free manifest가 함께 있어야 합니다. 현재 합성 fixture는 이 조건을 만족하지 않습니다.

### Reference-run 전용 field군

- `preflightBinding`: ready preflight의 assessment UID, receipt SHA-256과 exact verdict
- `execution`: executed interval, environment-violation flag, observation count와 canonical manifest
- `classicRouteBoundary`: classic/season 26/Challenge/Trial 관측과 latest/alternate/Museum negative sentinel
- `originalClientResult`: authority `original_client_runtime`, battle/HUD/damage/result 상태,
  server-recalculation/harness 미사용과 source-free result digest
- `rollback`: primary-install 불변, mutation rollback과 canonical manifest
- `downstreamBoundaries`: Local Lab shadow bridge, 3C/3D/Phase 4, multi-team/runtime telemetry parity가 모두
  별도 미검증이라는 경계

성공을 표현할 수 있는 machine verdict는 `verified_isolated_season26_original_client_result` 하나이며 exact
preflight binding, completed execution, verified classic boundary, verified original-client result와 verified rollback이
모두 필요합니다. `getlogs_observation`은 Git 밖 execution observation set의 member role이며 tracked receipt에는
`execution.observationCount`와 `execution.canonicalManifest`의 member count/byte length/SHA-256으로만 결박합니다.

각 canonical manifest는 contract ID, canonicalization code, member count, canonical byte length와 SHA-256만
포함합니다. Raw observation 자체나 GetLogs outcome을 machine receipt의 새 top-level property로 추가하지 않습니다.

Tracked receipt에는 raw game/account/manager/raid/preset/wave/monster/asset ID, raw damage value, request/response,
decoded row, original screenshot/video, local path, hostname, user name, credential/token, certificate/key, firewall rule
내용, binary 또는 client snapshot을 넣지 않습니다. 이러한 local evidence가 필요하면 Git 밖에 보관하고 receipt에는
비가역 digest와 최소 provenance만 남깁니다.

## Controlled failure precedence

한 실행에서 여러 실패가 보이면 첫 trigger와 세부 reason을 Git 밖 observation set 및
`blockingReasonCodes`에 보존하고, machine `verdict`는 아래의 안전 우선순위에서 가장 높은 항목으로 정합니다.

| 우선순위 | machine verdict | 적용 contract와 예 |
|---:|---|---|
| 1 | `blocked_environment_violation` | 양쪽; official credential/connection, non-loopback success, wildcard bind, primary-install drift, manifest 밖 binary/process |
| 2 | `blocked_rollback_failure` | reference run; hosts/CA/bundle/shim/firewall/snapshot 복원 또는 사후 검증 실패 |
| 3 | `blocked_external_pin_drift` | live preflight; external commit ancestry/tree 불일치 |
| 4 | `blocked_runtime_input_mismatch` | live preflight; server build, client/content/target 또는 reviewed runtime input 불일치 |
| 5 | `blocked_museum_route_observed` | reference run; Museum route/stage/buff 관측 |
| 6 | `runtime_blocked_season_26` | reference run; target route/pin/transport/UI/battle runtime 또는 flow-breaking GetLogs 실패 |
| 7 | `blocked_original_result_missing` | reference run; battle은 시작했지만 one-team original-client result가 없거나 검증되지 않음 |

Rollback failure는 먼저 발생한 runtime 실패를 지우지 않지만 최종 안전 판정을 지배합니다. 어떤 controlled
failure도 exception을 success response로 축약하거나, 빈 성공 receipt를 만들거나, Museum/최신 시즌/공식
서비스로 fallback하는 근거가 될 수 없습니다.

`blocked_preflight_incomplete`와 `not_executed_contract_scaffold_only`는 현재 합성 scaffold의 fail-closed 상태이며
실행 중 실패를 관측했다는 뜻이 아닙니다. Route-integrity, latest/alternate fallback, transport/bootstrap,
classic UI와 GetLogs 세부 원인은 별도 machine verdict를 발명하지 않고 위 verdict와 controlled
`blockingReasonCodes` 조합으로 보존합니다.

## GO, STOP과 rollback gate

### GO 규칙

GO는 누적이며 앞 gate를 모두 통과해야 합니다.

1. `GO_SERVER_START`: P0 전 항목 통과와 preflight receipt seal
2. `GO_CLIENT_START`: P1 전 항목 통과, exact loopback listener와 non-loopback count `0`
3. `GO_REFERENCE_RUN`: loading/login/lobby까지 official identity 없이 도달하고 pin·process tree가 계속 exact
4. `GO_RESULT_OBSERVATION`: classic season 26 Challenge와 first squad enter가 같은 active pin을 사용
5. `GO_POST_RUN_REVIEW`: one-team client result 관측 뒤 더 이상의 team/open mutation 없이 client/server 종료

각 GO는 자동으로 다음 단계를 시작하라는 뜻이 아니라 exact preflight/reference assessment pair에서 다음
좁은 transition을 관측할 수 있다는 뜻입니다. GO 조건이 실행 중 깨지면 즉시 STOP합니다.

### 즉시 STOP 조건

- official credential 요청·발견·사용 또는 official endpoint/telemetry 연결 성공
- 예상 밖 non-loopback connection, wildcard/LAN listener, port forwarding 또는 제3자 접속
- primary install 접근/변경, pin/content/build/input drift 또는 manifest 밖 binary/process
- Museum request/screen/stage/buff, 최신 manager, 다른 시즌, Normal/Practice/Fast Battle fallback
- selection/run pin mismatch, multiple active run, wrong mode/level, cross-account/manager mutation
- client crash, uncontrolled exception, transport/UI/runtime/result 실패로 다음 transition을 신뢰할 수 없음
- evidence 경계 위반, raw secret/original content의 tracked/log 출력 또는 rollback 가능성 상실

STOP 뒤에는 같은 실행에서 우회 patch를 추가하거나 공식 경로를 시험하지 않습니다. Process를 종료하고
local evidence를 source-free하게 seal한 뒤 rollback으로 이동합니다.

### Rollback contract

Rollback은 성공·실패와 관계없이 모든 Wave 0의 필수 마지막 단계입니다.

1. client, launcher, server와 관련 child process가 모두 종료됐음을 확인합니다.
2. active synthetic run/state를 manifest가 정한 disposable 절차로 닫거나 snapshot과 함께 폐기합니다.
3. hosts, root CA, client certificate bundle과 native shim을 역순으로 복원하고 before digest와 비교합니다.
4. firewall, listener와 local routing 변경을 복원하고 non-loopback/public listener가 남지 않았음을 확인합니다.
5. disposable VM/OS snapshot을 복원하거나 quarantine하며 재사용 가능 여부를 명시합니다.
6. `C:\NIKKE` 주 설치본의 after digest가 before와 일치함을 확인합니다.
7. certificate private key, patched output, raw log/evidence와 snapshot이 Git/CI/remote에 유입되지 않았음을
   재검사합니다.

하나라도 검증할 수 없으면 reference-run `verdict=blocked_rollback_failure`,
`rollback.statusCode=failed`로 종료하고 VM/OS를 quarantine합니다. 이 상태에서는 후속 단계를 승인하지
않습니다.

## Wave 0 종료 판정

성공 후보는 다음을 모두 만족해야 합니다.

- P0/P1과 외부 pin chain이 exact
- process tree의 non-loopback/official connection success `0`
- original classic Solo Raid 시즌 26 Challenge의 첫 squad battle runtime 직접 관측
- Museum/latest/다른 시즌/server-calculated result `0`
- `one-team client result`의 모든 조건 충족
- reference-run `preflightBinding`이 ready preflight의 assessment UID/SHA-256/verdict에 exact하게 연결됨
- rollback이 완전히 검증되고 primary install이 불변

그때의 machine verdict는 `verified_isolated_season26_original_client_result`, 사람용 evidence strength는 Wave 0
한정 `original_client_result_observed_one_team`입니다. 후속 3C 설계를 검토할 증거가 생긴다는 뜻일 뿐
자동으로 Phase 3 완료 또는 Local Lab integration 성공이 되지 않습니다.

현재는 이 조건을 실행한 measured receipt가 하나도 없고 checked-in evidence는 blocked/not-executed 합성
fixture뿐이므로 최종 상태를 다시 다음처럼 고정합니다.

```text
status=contract_scaffold_only
checked_in_evidence=blocked_not_executed_synthetic_only
preflight.verdict=blocked_preflight_incomplete
preflight.measuredEvidence.statusCode=not_measured
reference.verdict=not_executed_contract_scaffold_only
reference.preflightBinding.statusCode=unbound
reference.execution.statusCode=not_executed
reference.originalClientResult.statusCode=not_observed
reference.rollback.statusCode=not_started
```
