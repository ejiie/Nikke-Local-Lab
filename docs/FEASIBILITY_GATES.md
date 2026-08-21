# Original-client local compatibility feasibility gates

## 현재 결론

최종 제품 목표는 원본 NIKKE UI·asset·전투 runtime을 사용하는 제한 기능 local private server입니다. 실행 정책은 rights-holder-approved route가 먼저 있어야 한다는 과거 전제에서, 운영자가 승인한 비배포·개인 로컬 modified-client compatibility 연구로 재기준화했습니다.

현재 경로별 상태는 다음과 같습니다.

- `primary_install_or_official_account_route`: `blocked`
- `historical_rights_holder_approved_route`: `blocked_insufficient_evidence`
- `operator_authorized_disposable_local_route`: `ready_for_local_compatibility_spike`
- `classic_solo_raid_season_26`: `ready_for_isolated_season26_reference_run`
- `season26_absolute_timing_analysis`: `analysis_blocked_native_scheduler_rebind_required`
- `solo_raid_museum`: `excluded_by_product_contract`
- `custom_lobby_presentation`: `deferred/not_evaluated`

Phase 3A의 `blocked_insufficient_evidence`는 당시 정책과 제출 증거에 대한 올바른 역사적 결과이며 수정하거나 성공으로 재해석하지 않습니다. [PHASE3AR.md](PHASE3AR.md)는 public EpinelPS commit `28b2f5413a0a1e3521a11ae162f91851335c8b40`, target client `150.6.9`와 사용자의 local-only risk 결정을 근거로 별도의 modified-local lane을 엽니다.

공개 구현은 original client와 local server 사이의 기술적 실행 가능성을 강하게 뒷받침하지만 Shift Up의 승인·묵인·비제재 보장은 아닙니다. 권리자 승인은 `not_claimed`, 법적 상태는 `not_determined`로 기록합니다. 이 연구는 배포·제3자 접속·공식 계정·상업 이용을 허용하지 않습니다.

Phase 0~2B의 domain, importer, private-server API와 harness 결과는 그대로 보존합니다. Phase 2B boot의 `resultObservationContractId=lab_harness_observation/v1`과 `finalDamageAuthority=original_client_runtime` 분리도 변하지 않습니다. harness receipt는 Gate B·D의 original-client observation이 아닙니다.

## Gate A — disposable local compatibility environment

Gate A는 법적 허가를 판정하는 gate가 아니라, 사용자가 선택한 로컬 연구를 주 설치본·공식 계정·외부망과 분리하는 실행 안전 gate입니다.

### Spike 진입 조건

1. 운영 목적이 개인·비상업·비배포·로컬 전용으로 기록되어 있습니다.
2. EpinelPS source는 위 exact commit에 pin하고 license, source provenance와 실행 binary SHA-256을 기록합니다. prebuilt binary를 source와 동일하다고 추측하지 않습니다.
3. target NIKKE client는 exact `150.6.9` build/content-set으로 봉인한 snapshot 가능한 disposable VM/별도 OS 안의 copy입니다. 단순 디렉터리 복제본은 정적 검산에만 쓰고 system hosts/root CA를 바꾸는 live proof에는 사용하지 않습니다. `C:\NIKKE` 주 설치본은 read-only이고 사전·사후 hash를 비교합니다.
4. official account, cookie, token, session, credential-bearing capture를 준비하거나 사용하지 않습니다. Local Lab synthetic dummy account만 사용합니다.
5. system hosts와 root CA 변경은 disposable VM/OS 안에서만 허용합니다. client-local certificate bundle과 reviewed native compatibility shim도 각 변경에 원본 backup, 적용 전·후 hash, 적용 순서와 rollback 검증이 있어야 합니다.
6. client, launcher, EpinelPS/server와 관련 child process 전체는 loopback으로만 통신합니다. 모든 local service를 `127.0.0.1`에만 bind하고 wildcard/LAN/public bind와 port forwarding을 금지하며 official service/telemetry outbound를 차단·관측할 계획이 있습니다.
7. 원본·복호물·asset·generated data·certificate/private key·patched binary·client-local mapping을 Git, CI artifact, log 또는 remote에 넣지 않습니다.

한 조건이라도 충족하지 못하면 client를 시작하지 않습니다. `ready_for_local_compatibility_spike`는 위 준비를 시작할 수 있다는 판정이지, 실제 transport·outbound·rollback 검증이 이미 통과했다는 뜻이 아닙니다.

### Spike 종료 조건

- 적용된 모든 변경과 effective listen endpoint가 manifest와 일치합니다.
- synthetic dummy account만으로 local handshake에 도달합니다.
- process tree 전체에서 예상한 loopback flow만 관측되고 official service/telemetry 전송은 0입니다.
- 실패·종료 뒤 hosts, CA와 client-local native file rollback을 검증합니다.
- 주 설치본 hash와 상태가 바뀌지 않았습니다.

예상하지 않은 외부 연결, official identity 요청, primary-install 변경, manifest 밖 binary load 또는 rollback 실패가 발생하면 즉시 `blocked_environment_violation`으로 중단합니다.

## Gate B — original/classic Solo Raid wire contract

private-server state가 원본 client 화면을 정상 구동하려면 다음이 입증돼야 합니다.

- boot/loading과 synthetic local-session bootstrap에 필요한 request/response contract
- profile, wallet, roster, squad와 inventory subset projection
- classic `SoloRaid` manager 선택과 Challenge state projection
- Challenge open, first-team enter와 original battle scene handoff
- original-client observation receipt, regroup, next-team, close/result state machine
- unsupported route의 controlled no-op/not-supported 처리

첫 live target은 시즌 26입니다. Phase 3B-0에서 다음 chain을 exact `150.6.9` target content set에 대해 닫았습니다.

```text
season 26 manager
  -> preset
  -> Challenge wave
  -> monster/stat
  -> required client asset
```

Static/content 결과는 `ready_for_selected_manager_patch`입니다. behavior graph `917` nodes와 active cast site `109`개도 exact하게 해소됐지만, event timing `7`개와 client `150.6.9` native scheduler contract는 미해소입니다. 이는 absolute timing 분석 blocker이지 content/runtime 실행 실패 판정은 아닙니다. 상세는 [PHASE3B0.md](PHASE3B0.md)를 따릅니다.

선택된 manager는 첫 classic request 전에 account별로 명시 저장되고 open·Trial/Challenge 조회·enter·damage·close/result 전 경로에서 일관되어야 합니다. pinned classic handler의 legacy 감사값은 `19/6/9/4`이고, pre-characterization policy는 `6 selected Challenge / 1 GetLogs gate / 10 controlled unsupported / 2 manager-independent`입니다. Latest fallback과 session override가 남아 있으면 이 조건은 통과하지 않습니다. 암묵적 최신 시즌 선택은 성공으로 인정하지 않으며, 다른 시즌이나 Museum으로 바꾸지 않습니다. 상세 patch/test 계획은 [PHASE3B1.md](PHASE3B1.md)를 따릅니다.

wire adapter는 lab-owned UID와 client-local content reference를 Git 비추적 compatibility binding에서 변환합니다. 이 transient value를 domain PK/FK, public API, log와 fixture에 노출하지 않습니다. public EpinelPS handler를 reference로 사용할 수 있지만 live 공식 traffic을 새로 가로채거나 credential-bearing official request/session을 replay하지 않습니다.

## Gate C — classic Solo Raid presentation

첫 proof에 필요한 presentation은 original/classic `SoloRaid` main, Challenge ready, squad entry와 battle handoff입니다. official `SoloRaidMuseum`은 결과에 영향을 주는 별도 buff가 있으므로 다음 모두를 금지합니다.

- `/soloraidmuseum/**` 요청 또는 handler 사용
- Museum 화면·stage·buff를 classic Solo Raid 결과의 대용으로 사용
- 시즌 26 chain 실패 시 Museum으로 fallback
- Museum 결과를 golden/client-runtime 검증으로 수락

초기 시즌 26 proof는 custom six-season lobby folder를 요구하지 않습니다. 직접 고정한 selected manager를 classic Solo Raid 화면에 투영해 Gate B·D를 먼저 확인합니다. 이후 multi-season folder, permanent 표시, Quick Battle 제거와 Recruit no-op 같은 custom presentation은 별도 단계에서 다음을 입증합니다.

- server-driven flag로 안전하게 숨길 수 있는 요소와 client variant가 필요한 고정 widget 구분
- 시즌 `7, 13, 26, 29, 34, 40` 중 사용자가 명시적으로 고른 한 시즌만 classic screen context에 투영
- 오류·timeout·빈 응답이나 memory patch를 UI 구현으로 사용하지 않음

custom presentation path가 없더라도 시즌 26 classic vertical proof와 core product acceptance를 차단하지 않습니다. multi-season folder·widget 재배치·Recruit no-op 같은 **custom presentation 자체의 acceptance만** 사용자가 해당 기능을 채택하고 검증할 때까지 `deferred/not_evaluated`입니다.

## Gate D — original battle runtime integrity

- 시즌 26 classic Solo Raid에서 원본 battle scene, Spot behavior, animation, QTE, parts와 HUD가 로드됩니다.
- Museum 전용 buff·stage modifier가 없음을 route와 runtime observation으로 확인합니다.
- client의 damage calculation/display path를 Local Lab이나 sidecar simulator가 대체하지 않습니다.
- runtime execution/control profile의 requested/effective 값과 frame telemetry가 일치합니다.
- result가 exact client build, season 26 manager/raid snapshot, account, squad/build와 execution revision을 참조합니다.
- client build/content closure 또는 EpinelPS pin이 바뀌면 Gate A~D를 다시 평가합니다.

Gate D의 시즌 26 one-team 최소 observation contract와 identity sealing은 Phase 3C/3D가 소유하고, 1~5팀·regroup·telemetry·recovery parity 확장은 Phase 4가 소유합니다. handshake나 battle scene 진입만으로 damage/result integrity를 통과했다고 표시하지 않습니다.

3B-0은 conditional/random/part-aware behavior order를 정적으로 닫았지만 모든 event의 absolute battle frame/ms를 닫지 않았습니다. 이 timing 분석 gap은 3B-2 live observation과 후속 scheduler/telemetry parity에서 검증하며, 정적 graph를 actual runtime integrity로 승격하지 않습니다.

## 현재 evidence 상태

| 항목 | 상태 | 현재 판정 |
|---|---|---|
| private-server domain/API/harness | `backend_complete` | Phase 2B V0007·loopback API·harness 단위/live PostgreSQL gate 통과 |
| Normal clear/Challenge unlock contract | `backend_complete` | `lastClearLevel=7`, Challenge 기본 open, Normal run unsupported 검증 |
| permanent season/no Quick Battle/05:00 KST | `backend_complete` | six-member directory·no-expiry·KST day state 검증 |
| Phase 2B damage observation | `harness_only` | `lab_harness_observation/v1`; 최종 권위는 original runtime |
| Phase 3A rights-holder-approved assessment | `blocked_insufficient_evidence` | 역사적 판정; 승인 route/build/outbound evidence 없음 |
| public EpinelPS prior art | `confirmed_and_pinned` | exact commit은 기술적 reference이며 권리자 승인 증거가 아님 |
| operator-authorized disposable lane | `ready_for_local_compatibility_spike` | 실제 environment/outbound/rollback은 3B에서 검증 필요 |
| stock primary-install route | `blocked` | 실행·수정 대상 아님 |
| target client build | `static_content_attested` | `150.6.9` content closure 통과; disposable environment/runtime은 미검증 |
| season 26 classic chain | `ready_for_selected_manager_patch` | manager/preset/wave/boss/model/stat/behavior/asset root exact closure |
| season 26 pattern timing | `analysis_blocked_native_scheduler_rebind_required` | event timing `7`개와 native scheduler contract 미해소; content/runtime 실행 verdict가 아님 |
| classic selected-manager routes | `ready_for_isolated_season26_reference_run` | 완료; legacy `19/6/9/4`, final `7/10/2`, focused test `63/63`, latest/Museum fallback 0 |
| Solo Raid Museum | `excluded` | 별도 buff가 결과에 영향을 주므로 사용하지 않음 |
| custom multi-season lobby | `deferred` | first classic season 26 proof 뒤 평가 |
| original runtime compatibility | `not_evaluated` | Gate D actual play 필요 |

## 완료 판정

[PHASE3AR.md](PHASE3AR.md)의 rebaseline, [PHASE3B0.md](PHASE3B0.md)의 완료된 closure, [PHASE3B1.md](PHASE3B1.md)의 완료된 selected-manager receipt와 [PHASE3.md](PHASE3.md)의 수직 단계를 따릅니다. 다음 go/no-go는 다음 한 문장으로 고정합니다.

> Exact `150.6.9` disposable client가 synthetic dummy account로 original/classic season 26 Solo Raid Challenge에 진입하고, Museum route/buff 없이 original battle runtime과 result를 반환한다.

Gate A의 준비만 통과한 상태는 제품 완료가 아닙니다. Gate B의 classic season 26 wire, Gate C의 Museum exclusion, Gate D의 actual runtime/result를 차례로 증명해야 합니다. 실패하더라도 Phase 0~2B 결과와 Phase 3A 역사 판정은 보존합니다.

Phase 2B operational policy와 Gate A~D는 별개입니다. checked-in `challenge-operational-policy/unresolved/v1`에서는 Challenge UI가 open이어도 새 run admission이 fail closed합니다. live proof 전에는 여섯 운영 축을 모두 명시한 configured non-reserved policy가 필요합니다.
