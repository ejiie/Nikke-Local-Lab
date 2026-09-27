# Phase 3B-2 — disposable preflight and reference-run contracts

> 단계별 계약·검증 기준입니다. 이 문서의 과거 실행 판정과 현재 운영 상태를 구분합니다. 현행 상태는 [인계 요약](../HANDOFF.md), 남은 작업은 [다음 작업](../NEXT_STEPS.md)을 확인합니다.

## 현재 판정

상태: **`contract_scaffold_only`**

Wave 0 contract scaffold는 완료됐습니다. 현재 진행 대상인 Wave 1은 disposable 환경의 measured
preflight이며, 실제 client reference run은 Wave 2입니다. 이 문서는 두 실행 wave가 어떤 입력, 관측,
실패 우선순위와 rollback 조건으로 판정될지를 함께 고정합니다.

| delivery wave | 범위 | client 실행 |
|---|---|---|
| Wave 0 | schema, verifier, blocked/not-executed 합성 fixture | 없음 |
| Wave 1 | P0 cold admission과 P1 server-start/client-cold measured preflight | 없음 |
| Wave 2 | exact Wave 1 receipt에 결박된 isolated original-client reference run과 rollback | 있음 |

기존 machine section code `wave0_envelope`는 Wave 0 scaffold에서 동결된 wire 이름이므로 변경하지 않습니다.
그 이름이 Wave 1·2의 측정이 이미 끝났다는 뜻은 아닙니다.

- disposable VM/별도 OS measured preflight receipt: 없음; checked-in artifact는 blocked/not-executed 합성 fixture뿐
- client `150.6.9` VM copy hash 검증: 미실행
- EpinelPS build/listener/outbound runtime 관측: 미실행
- measured reference-run receipt와 원본 client loading/login/lobby 관측: 없음; checked-in artifact는
  blocked/not-executed 합성 fixture뿐
- classic Solo Raid 시즌 26 화면·전투·result 관측: 없음
- `GetLogs` client compatibility 관측: 없음
- rollback 실행 증거: 없음
- Wave 1 measured-preflight verdict: `not_evaluated`
- Wave 2 reference-run aggregate verdict: `not_evaluated`

따라서 현재 checked-in evidence는 `GO`를 발행하지 않으며, `ready_for_3c`, `reference_run_passed`,
`original_client_result_observed_one_team` 또는 runtime parity를 주장하지 않습니다.
[PHASE3B1.md](PHASE3B1.md)의 `ready_for_isolated_season26_reference_run`은 Wave 1에 들어갈 수 있는
external selected-manager 입력의 판정이지, 이 문서의 VM/client proof가 이미 존재한다는 뜻이 아닙니다.

## 권위와 범위

이 문서는 Phase 3B-2 **Wave 1 measured preflight 한 번과 그 receipt에 결박된 Wave 2 reference run** 계약에 대한 사람용 단일 권위입니다.
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

Phase 3B-2 Wave 1·2는 다음을 소유하지 않습니다.

- Local Lab Phase 2B run/context/profile/squad revision과의 durable bridge 또는 correlation
- 다섯 팀 전체 clear, regroup, next-team, raid-wide aggregate와 recovery parity
- Local Lab 또는 server가 계산한 damage/result
- native scheduler의 절대 frame/ms timing과 full HUD/ESC/frame telemetry parity
- 다른 시즌, Normal, Practice, Fast Battle/Quick Battle 또는 `SoloRaidMuseum`
- custom multi-season lobby, 배포, 공식 계정 또는 공식 traffic replay

Wave 2의 direct client observation은 후속 3C/3D의 identity sealing과 Phase 4의 1~5팀 parity를
대체하지 않습니다. Lab harness receipt는 이 문서의 original-client evidence로 승격하지 않습니다.

## 동결된 machine contract ID

Wave 0에서 동결한 assessment contract ID는 다음 두 개뿐입니다.

| 역할 | contract ID | 의미 |
|---|---|---|
| live preflight | `nll/season26-classic-live-preflight/v1` | client 시작 전 환경·pin·build·network·backup과 client-start admission |
| reference run | `nll/season26-classic-reference-run/v1` | 원본 client transition, 한 팀 result, GetLogs, rollback과 aggregate verdict |

Wave 1의 Git-external P0/P1 관측을 deterministic stream으로 검증하기 위한 보조 contract는
`nll/season26-classic-live-preflight-observation-set/v1`입니다. 이는 세 번째 assessment verdict가 아니며,
18개 고정 role의 source-free local evidence shape와 ordinal JSON/LF canonicalization만 소유합니다.

두 contract의 사람용 절차와 Git 밖 canonical observation manifest에서 다음 section/observation code를
사용합니다. 이 값들은 독립된 contract ID나 machine receipt의 새 top-level property가 아닙니다.

| code | 소유 contract | 의미 |
|---|---|---|
| `wave0_envelope` | 양쪽 | 동결된 wire 이름; 같은 Wave 1/2 assessment pair와 predecessor receipt 결박 |
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

- live preflight [schema](../../contracts/season26-classic-live-preflight.schema.json)와
  [blocked fixture](../../tests/fixtures/synthetic/season26-classic-live-preflight.blocked.json):
  `verdict=blocked_preflight_incomplete`, `measuredEvidence.statusCode=not_measured`
- reference-run [schema](../../contracts/season26-classic-reference-run.schema.json)와
  [not-executed fixture](../../tests/fixtures/synthetic/season26-classic-reference-run.not-executed.json):
  `verdict=not_executed_contract_scaffold_only`, `execution.statusCode=not_executed`
- live-preflight observation-set [schema](../../contracts/season26-classic-live-preflight-observation-set.schema.json)와
  [합성 fixture](../../tests/fixtures/synthetic/season26-classic-live-preflight-observation-set.valid.json):
  18개 role와 canonicalization의 positive/negative control일 뿐 실제 environment 측정이 아님
- [contract verifier](../../scripts/verify-phase3b2.ps1): tracked 합성 fixture를 항상 검사하고, 두 external path를
  함께 명시하면 Git-external observation set과 ready candidate의 exact digest binding도 검사함
- [preflight sealer](../../scripts/seal-phase3b2-preflight.ps1): 이미 측정된 Git-external observation set만 받아
  external ready candidate를 생성·검증하며 입력을 수집하거나 server/client를 시작하지 않음

## 외부 dependency pin chain

Wave 1은 다음 외부 EpinelPS chain 전체가 exact하게 일치할 때만 같은 대상이라고 판정합니다.

```text
reviewed upstream base
  28b2f5413a0a1e3521a11ae162f91851335c8b40
    -> Phase 3B-1 integration
       92a6ca228aeb580988907b96189b2857dff2c62d
         -> Phase 3B-2 local-only preflight seal
            e32e5f900775974d5736e7fb2b50f8c62638a004
              -> preflight hardening HEAD
                 4f7bd5b5eb2b9a6e03af503f1c09adc4c4f7f16f
                   -> measured target-projection HEAD
                      6473a41fcdbc7cb4cb5919c31f9b2d1f04b4b5b6
                         -> local-only HTTP/3 disable hardening
                            9d22e68d069ec3d832bc3ece084952906c169d79
                              -> local-only asset-cache log hardening
                                 519c3db51ec24ca19307e93e85acde7885928a72
                                   -> Git tree
                                      b9e8bfb1b1e065427a48d40cb2bcf2f30215436a
```

필수 pin 규칙은 다음과 같습니다.

1. commit ancestry는 위 순서를 만족해야 합니다.
2. local-only asset-cache log hardening HEAD의 tree object는 exact
   `b9e8bfb1b1e065427a48d40cb2bcf2f30215436a`여야 합니다.
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

## Wave 1/2 실행 단위

한 Wave 1은 다음 identity를 시작 전에 고정하고, 결박된 Wave 2가 끝날 때까지 바꾸지 않습니다.

- lab-owned random live-preflight `assessmentUid`와 reference-run `assessmentUid`
- reference-run `preflightBinding`의 exact preflight assessment UID/SHA-256/verdict 결박
- disposable VM/OS snapshot identity의 비가역 digest
- client build/content manifest digest
- external commit/tree와 server build artifact digest
- reviewed locale/runtime input manifest digest
- synthetic account observation digest
- target binding contract `nll/season26-classic-target-observation/v2`과 trusted digest
- firewall/listener policy digest
- change/backup/rollback manifest digest

한 account에 client 하나, account당 active classic run 최대 하나만 허용합니다. Server 또는 client 재시작,
snapshot 복원, pin 변경, manifest 변경이나 failure 뒤 재시도는 같은 실행의 연장이 아니라 새 assessment
pair입니다. 실패 원인을 고치기 위해 여러 변경을 한 번에 적용하지 않습니다.

Phase 3B-1의 `nll/season26-classic-target-observation/v1` receipt와 schema는 당시의 source-free
역사 증거로 보존합니다. 실제 `150.6.9` decoded archive 검산에서는 원본 wave 전체가 118 canonical
line인 반면 v1 wave role은 13 line으로 고정되어 실측 입장에 사용할 수 없었습니다. v2는 exact target
monster와 그 monster를 포함하는 spawn만 source-relative order로 투영하여 150 line, 6689 bytes,
SHA-256 `095eebce4f244f9326aa558302318f85547697b165eb6458735527bd2b0f6d10`으로 재계산합니다.
v1 receipt를 소급 수정하거나 v2 성공으로 승격하지 않습니다.

## Preflight contract

### P0 이전 — exact static catalog acquisition gate

물리 OS P2에서 client가 `4/7` catalog resource 단계에 도달했지만 exact local `core`/`dp`/`fd` catalog pair가 없어서 종료되는 경우, 운영자가 승인한 별도 Samsung 콜드 수집 lane을 사용할 수 있습니다. 이 gate는 client reference run이나 P1 server measurement가 아니며 다음 순서를 고정합니다.

1. Samsung Windows가 system/boot disk이고 Micron Windows가 offline data disk인지 확인합니다.
2. client, launcher, EpinelPS/server와 physical bootstrap process가 모두 없는 cold 상태를 확인합니다.
3. Git-external request manifest에 exact `catalog.db`/`.nds` 여섯 URI만 기록하고 그 SHA-256을 운영자가 승인합니다.
4. redirect·proxy·cookie·credential 없이 system-default TLS hostname validation으로 static asset CDN GET 여섯 회만 수행합니다.
5. 세 body의 `NKDB` magic, 세 signature의 96-byte shape, member byte length/SHA-256과 canonical manifest를 검증해 Samsung `Sealed` root에 둡니다.
6. sealed byte를 Epinel의 NKDB parser로 해석해 role host token이 정확히 하나인 remote bundle closure를 계산하고 provider metadata와 `RuntimePath` row를 제외합니다.
7. Micron `naps`의 exact identity+length member는 Samsung protected cache로 복사하고, 결손 또는 size mismatch member만 동일 host의 exact HTTPS GET으로 획득합니다.
8. 전체 member의 declared length와 canonical SHA-256 manifest를 봉인한 뒤에만 Micron staging으로 복사합니다.

수집기는 server/client를 시작하지 않고 materialization 완료 전에는 Micron을 수정하지 않습니다. URL, 상대 경로, catalog와 bundle byte는 Git에 들어가지 않으며 source-free receipt만 생성합니다. 실제 Micron P0/P1에서는 `official asset/locale auto-fetch=false`와 non-loopback success `0`을 계속 요구합니다. Catalog가 exact remote path로 지시하지 않은 resource·locale, API 또는 telemetry 요청은 이 gate로 허용되지 않습니다.

현재 Git-external 실측에서는 exact six-member acquisition과 Micron offline staging까지 완료됐습니다.
Acquisition receipt SHA-256은
`87d22ab630bea3851ad3af6b8a2b3be009c7f49b9320529186261bb38c24ae92`, deployment receipt SHA-256은
`27ec27253b56fae39967a5714a315a862908a268a62a7083d45f85df9de592f6`입니다. 세 body는 모두 in-memory
NKDB decrypt 뒤 SQLite header/schema를 통과했고 raw decrypted DB는 저장하지 않았습니다. 전체 catalog
초기 resource closure의 `40,281` 집계는 provider metadata와 `RuntimePath` row를 원격 객체로 오인했으므로
권위 집계로 사용하지 않습니다. Epinel native path mapping으로 재계산한 결과는 catalog row 40,281개 중
remote materialization member 40,097개와 non-remote row 184개입니다. Remote set은 local exact 34,618개,
missing 5,450개, size mismatch 29개이며 전체 declared byte length는 38,987,622,630입니다. 이 전체 closure가
Samsung에서 봉인되기 전에는 Micron retry를 수행하지 않습니다.

첫 Micron retry 진입은 catalog member 결손이 아니라 stale preparation state 때문에 client/server 시작 전에
fail-closed됐습니다. 이전 자동 복구 뒤 base `hosts`와 extension firewall 0개가 관측됐지만 기존 preparation
receipt는 applied `hosts`와 extension firewall 1개를 요구했습니다. Failure receipt SHA-256은
`03a6021e6d84d83ad967b5ce4cb6e74abfc01d28fa902ed45aa4182769fdcc76`입니다. Exact-catalog retry는 소비되지
않았으며, Samsung offline repair deployment receipt SHA-256
`59721268949df5cb2cb553f54f673f2987ec5fb3eb45aa4f83f1df8ec20ed52d`가 이 한 상태에서만 P2-v2 hosts/firewall을
재적용하도록 wrapper를 보강했습니다. 이 repair는 physical client와 six-member catalog set을 변경하지 않습니다.

재무장 뒤 실제 실행은 six-member catalog 6/6을 exact로 검증했지만 `4/7`에서 다시 종료됐습니다. Client
`Player.log`의 exact failed URI와 server request-stage의 단일 `asset_prdenv` 404를 함께 검산한 결과, 첫 결손은
catalog body가 아니라 같은 PCK root의 `latest-651.txt`였습니다. Assessment UID는
`29083a6a-3f4e-4eec-a57a-4d28b1459524`, run-start SHA-256은
`4481b1186a9b17fbe06c70bcf2639860439423a76b300e2309710cfe55d4f10f`입니다. Raw Player.log는 Git이나
Samsung 보호 evidence에 복사하지 않았습니다.

Samsung offline follow-up은 설치 client의 3,775-byte `.lcv.dat`와 pinned `gameconfig.json`에서 투영된
8-line/no-terminal-LF header를 exact 139 bytes, SHA-256
`5914cb58fd2146fe761ab531ecb4e321300527186a54b455e59de962ff6c044a`로 Micron local cache에 배치했습니다.
Repair receipt SHA-256은 `38f757559f5e70f9f185bc54b4917aab5c538ad9a0500e7d05fddff1e55f7c4d`입니다. 실패
실행의 DB는 baseline SHA-256
`c103b44b7bc3dc4f1a317fd272253e2c8d827ca3ff174f07e0ecb6dfc298e194`로 복원됐고 SQLite runtime member는
0개입니다. Active pointer/retry consumption은 삭제 전 run root에 원본 digest로 보존됐으며 exact catalog
6개는 변경하지 않았습니다. 시작 gate는 catalog+header 합성 closure를 검증하고, completion은 과거 latest
pointer를 충돌로 보지 않고 새 run evidence에 보존한 뒤 갱신합니다. 이 변경은 공식 outbound/API/login을
사용하지 않으며 `5/7` 이후 resource closure를 선결 주장하지 않는 단일 follow-up retry만 허용합니다.

### P0 — cold environment admission

Server나 client process를 시작하기 전에 다음을 모두 확인합니다.

- snapshot·복원이 가능한 disposable Windows VM/별도 OS이며 단순 디렉터리 복제본이 아님
- official-current `C:\NIKKE`는 이 modified-local run의 실행·수정 대상이 아니며 Local Lab 비변경 기준이 기록됨
- VM 내부 disposable client가 exact `150.6.9` build/content manifest와 일치함
- synthetic local account만 준비되어 있고 official credential, cookie, session과 token이 없음
- 외부 pin chain, clean tree, toolchain과 fresh build artifact가 exact
- server-cold `--local-only` 시작에 필요한 reviewed `StaticData.pack`이 별도 필수 runtime input으로 exact
- 네 개의 reviewed locale input이 exact; 이 4개 count에 `StaticData.pack`을 합산하지 않음
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
- `--local-only`에서는 HTTP/3가 비활성이고 UDP `443` listener 수가 `0`
- wildcard, LAN 또는 예상 밖 listener 수 `0`
- official asset/locale auto-fetch, Git update와 interactive update surface가 비활성
- startup 동안 non-loopback connection attempt와 successful connection 모두 `0`
- target binding 재계산이 3B-1 trusted observation과 일치
- synthetic account bootstrap은 listener 이전 write-once/validate-only 규칙을 지켰고 selection/runtime
  mutation 또는 latest fallback이 `0`
- active run 상태가 없거나 exact resumable target 하나이며 quarantine/multiple/wrong-mode/non-8 상태가 없음
- server log와 receipt에 raw account, manager ID, credential, local path 또는 decoded payload가 노출되지 않음

최초 실측에서 TCP `80/443`은 IPv4 loopback이었지만 Kestrel/MsQuic의 UDP `443` 소켓이 IPv6 wildcard
`::`로 관측되어 P1을 실패-폐쇄했습니다. 이 결과를 loopback 성공으로 해석하지 않습니다. 외부 hardening
`9d22e68d069ec3d832bc3ece084952906c169d79`부터 local-only HTTPS는 HTTP/1.1+2만 허용하며, P1은
HTTP/3 비활성 및 UDP `443` listener `0`을 요구합니다. 일반 모드의 upstream HTTP/3 동작은 보존합니다.

후속 P1에서 local cache hit가 `Game is requesting <absolute-path>`로 기록되어 log-safety gate가
실패-폐쇄됐습니다. `519c3db51ec24ca19307e93e85acde7885928a72`부터 local-only asset cache 요청은
`local_only_asset_cache_request` controlled code만 기록하며 일반 upstream 모드의 기존 요청 로그는
보존합니다. P1은 `localOnlyAssetCachePathLoggingEnabled=false`와 local path value `0`을 함께 요구합니다.

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

Wave 2의 `one-team client result`는 **첫 5인 squad 한 팀의 battle attempt가 원본 client runtime에서 끝나고,
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
미검증으로 남겼습니다. Wave 2는 `GetLogs`를 result authority가 아닌 별도 보조 관측으로 기록합니다.

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

Assessment receipt에는 두 checked-in machine schema가 허용하는 source-free field군만 사용합니다. 현재
저장소 정책상 직접 만든 합성 fixture만 track하므로 measured ready candidate와 그 raw observation set은
Git 밖에 둡니다. blocked/not-executed 합성 fixture의 값이나 schema-valid 임의 값은 measured ready/live
evidence로 간주하지 않습니다. 향후 measured receipt를 track하려면 먼저 `AGENTS.md`의 private-remote
허용 범위를 명시적으로 변경해야 합니다.

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

Assessment receipt에는 raw game/account/manager/raid/preset/wave/monster/asset ID, raw damage value, request/response,
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

### Source-built Sail ABI local bootstrap admission

공식 launcher가 disposable client의 reviewed P0 certificate/native shim mutation을 pre-launch integrity
검사에서 거부해도 그 검사를 patch, hook, injection 또는 repair로 우회하지 않습니다. Client가 아직 시작되지
않았고 exact failure receipt와 rollback checkpoint가 있을 때만 다음의 별도 admission을 검토할 수 있습니다.

1. public bootstrap source의 exact HEAD/tree와 clean checkout을 고정합니다.
2. game-owned shared-memory/plugin ABI와 named pipe에 필요한 최소 native output만 source build합니다.
3. Lab-owned managed bootstrap은 합성 local auth, exact client path와 Sail ABI handoff만 수행합니다.
4. official launcher executable, downloader/repair surface, ACE substitute, `HelperDll.dll`, `UnityInit.dll`과
   process memory read/write, injection, hook API는 build·stage·run에서 모두 제외합니다.
5. source/artifact manifest, firewall program rule, backup·rollback과 snapshot을 P0의 새 assessment에
   결박하고 P1을 다시 측정합니다.
6. ready receipt는 `clientBootstrapModeCode=source_built_sail_abi_local_bootstrap`인 Git 밖 projection에서
   생성하며 official launcher가 실행되지 않았음을 별도 negative sentinel로 유지합니다.
7. Client start는 VM의 interactive console에서 한 번만 수행하고, local account/auth acceptance,
   shared-memory creation, named-pipe connection과 `nikke.exe` start receipt가 모두 생겨야 다음 transition을
   관측합니다.

이 lane은 launcher/ACE protection bypass가 아니며, original client runtime 자체의 성공을 미리 주장하지
않습니다. Client가 ABI 연결 전에 종료되거나 manifest 밖 process가 나타나면
`runtime_blocked_season_26`으로 STOP하고 같은 assessment에서 다른 start 방법을 재시도하지 않습니다.

Hyper-V assessment에서 원본 client가 process 생성 직후 virtual environment 실행을 자체 거부하고 Sail
named pipe에 연결하지 않은 경우에는 content/runtime 호환성 실패와 구분해
`runtime_blocked_virtualized_environment`로 STOP합니다. 이 판정은 `clientProcessCreationObserved=true`,
`originalClientRuntimeEntered=false`, `referenceRunExecuted=false`를 함께 기록합니다. Hypervisor 감지를
숨기거나 client/ACE를 patch·hook·inject하지 않고, source-free 실패 증거를 추출한 뒤 exact P0 checkpoint를
복원합니다. 다음 실행 환경은 같은 VM의 다른 bootstrap이 아니라 snapshot/rollback 가능한 별도 물리 Windows
OS여야 합니다.

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

Rollback은 성공·실패와 관계없이 모든 Wave 2의 필수 마지막 단계입니다.

1. client, launcher, server와 관련 child process가 모두 종료됐음을 확인합니다.
2. active synthetic run/state를 manifest가 정한 disposable 절차로 닫거나 snapshot과 함께 폐기합니다.
3. hosts, root CA, client certificate bundle과 native shim을 역순으로 복원하고 before digest와 비교합니다.
4. firewall, listener와 local routing 변경을 복원하고 non-loopback/public listener가 남지 않았음을 확인합니다.
5. disposable VM/OS snapshot을 복원하거나 quarantine하며 재사용 가능 여부를 명시합니다.
6. official-current `C:\NIKKE`가 Local Lab에 의해 변경되지 않았고 frozen target의 after digest가 rollback 계약과 일치함을 확인합니다.
7. certificate private key, patched output, raw log/evidence와 snapshot이 Git/CI/remote에 유입되지 않았음을
   재검사합니다.

하나라도 검증할 수 없으면 reference-run `verdict=blocked_rollback_failure`,
`rollback.statusCode=failed`로 종료하고 VM/OS를 quarantine합니다. 이 상태에서는 후속 단계를 승인하지
않습니다.

## Wave 2 종료 판정

성공 후보는 다음을 모두 만족해야 합니다.

- P0/P1과 외부 pin chain이 exact
- process tree의 non-loopback/official connection success `0`
- original classic Solo Raid 시즌 26 Challenge의 첫 squad battle runtime 직접 관측
- Museum/latest/다른 시즌/server-calculated result `0`
- `one-team client result`의 모든 조건 충족
- reference-run `preflightBinding`이 ready preflight의 assessment UID/SHA-256/verdict에 exact하게 연결됨
- rollback이 완전히 검증되고 primary install이 불변

그때의 machine verdict는 `verified_isolated_season26_original_client_result`, 사람용 evidence strength는 Wave 2
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
