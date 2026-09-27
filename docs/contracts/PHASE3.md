# Phase 3 — operator-authorized original-client local compatibility

> 단계별 계약·검증 기준입니다. 이 문서의 과거 실행 판정과 현재 운영 상태를 구분합니다. 현행 상태는 [인계 요약](../HANDOFF.md), 남은 작업은 [다음 작업](../NEXT_STEPS.md)을 확인합니다.

## 상태와 목적

Phase 3의 현행 목표는 **격리된 로컬 환경에서 원본 NIKKE 클라이언트의 클래식 `SoloRaid` 화면과 전투 runtime을 사용해 시즌 26 Challenge를 실행하는 것**입니다. 별도 simulator나 `SoloRaidMuseum`으로 대체하지 않습니다.

기존 Phase 3A의 `blocked_insufficient_evidence`는 당시의 **권리자 승인 증거 우선 정책**에 따른 정확한 역사적 판정으로 보존합니다. 공개 선행 구현의 존재를 권리자의 명시적 허가로 해석하지는 않지만, 프로젝트 운영자가 비배포·로컬 전용 호환성 실험을 명시적으로 선택했으므로 그 판정을 기술 작업의 영구 중단 조건으로 사용하지 않습니다. 현행 정책과 재개 근거의 단일 권위는 [PHASE3AR.md](PHASE3AR.md)입니다.

현재 상태는 다음과 같습니다.

- Phase 2B source-free backend/harness: 완료
- Phase 3A approval-first evidence audit: 완료 / 역사적 `blocked_insufficient_evidence`
- Phase 3A-R operator-authorized rebaseline: `ready_for_local_compatibility_spike`
- Phase 3B-0 시즌 26 static/runtime closure: 완료 / `ready_for_selected_manager_patch_with_timing_analysis_blocker`
- Phase 3B-1 selected-manager: 완료 / `ready_for_isolated_season26_reference_run`
- EpinelPS 기반 external compatibility façade: selected-manager·active-run pin·19-route policy와 focused test 완료
- Phase 3B-2 Wave 0: preflight/reference-run source-free 계약 scaffold 완료 / blocked·not-executed 합성 fixture만 존재
- 시즌 26 원본 Solo Raid live proof: 미실행

## 채택할 구조

EpinelPS는 reviewed commit `28b2f5413a0a1e3521a11ae162f91851335c8b40`을 고정한 **별도 AGPL-3.0 checkout과 별도 process**로 취급합니다. 대상 client build는 `150.6.9`입니다. EpinelPS source, generated protocol source, 인증서, native compatibility binary와 patch output을 이 저장소에 복사하지 않습니다. 필요한 변경은 외부 checkout의 명시적 patch queue 또는 별도 fork에서 관리하고, Local Lab에는 source-free contract와 provenance만 남깁니다.

```text
snapshot-capable disposable VM / separate OS
  └─ pinned client copy
        |
        v
external pinned EpinelPS process
        |
        v
narrow loopback bridge (후속 단계)
        |
        v
existing Local Lab Phase 2B state and PostgreSQL
```

첫 live proof에서는 EpinelPS를 가능한 한 upstream 그대로 실행하여 client compatibility 자체를 먼저 확인합니다. Local Lab bridge는 이 proof를 통과한 뒤에만 추가합니다. 이 순서는 Phase 2B를 폐기한다는 뜻이 아니라, transport 문제와 Local Lab 통합 문제를 분리해 실패 원인을 좁히기 위한 것입니다.

## 콘텐츠 경계

- 목표 화면은 원본 시즌제 **클래식 `SoloRaid`**입니다.
- `SoloRaidMuseum`은 실제 게임의 별도 공식 콘텐츠이며 결과에 영향을 주는 전용 버프가 있으므로 지원·검증·fallback 경로에서 제외합니다.
- Museum에서 전투가 열린다는 사실을 클래식 Solo Raid 성공으로 인정하지 않습니다.
- 첫 검증 시즌은 **시즌 26**입니다. 다른 시즌이나 최신 manager로 자동 대체하지 않습니다.
- 시즌 26을 열 수 없으면 controlled blocked 결과를 남기고, Museum이나 시즌 40으로 우회하지 않습니다.

## 3A — approval-first evidence audit — 역사적 완료

상세 기록은 [PHASE3A.md](PHASE3A.md)에 보존합니다. 당시 제출된 증거만으로 권리자 승인 route를 입증하지 못했으므로 `blocked_insufficient_evidence`였고, 그 verdict를 `ready_for_phase3b`로 소급 변경하지 않습니다.

checked-in schema, blocked fixture와 verifier도 해당 정책 시점의 감사 증거입니다. 현행 local compatibility lane을 열기 위해 과거 fixture에 근거 없는 승인 진술을 채워 넣지 않습니다.

## 3A-R — operator-authorized local compatibility rebaseline

예상 시간: `1.5~2.5시간`

종료 조건:

- 역사적 승인 판정과 현행 운영자 선택을 서로 다른 verdict로 기록
- EpinelPS upstream URL, license, exact commit과 대상 client build를 외부 dependency record로 고정
- snapshot 가능한 disposable VM/별도 OS, synthetic local account, `127.0.0.1` exact bind, 전 process tree non-loopback 차단, backup/rollback 경계 확정
- 원본 또는 patched artifact가 Git/CI에 들어가지 않는 경계 확정
- 클래식 Solo Raid 전용 및 Museum 제외를 모든 Phase 3 문서에 일관되게 반영
- 완료 시점에는 시즌 26 static closure와 live proof가 아직 미완료였음을 명시

3A-R은 기술적 성공 판정이 아닙니다. 그 뒤 3B-0 static/content closure는 별도 gate로 완료했으며, 3A-R의 역사적 의미나 verdict를 소급 변경하지 않습니다. 정확한 3B-0 결과는 [PHASE3B0.md](PHASE3B0.md)를 따릅니다.

## 3B-0 — 시즌 26 static/runtime closure

상태: **완료 / `ready_for_selected_manager_patch_with_timing_analysis_blocker`**

Exact pinned upstream과 대상 client data에서 다음 chain을 완결했습니다.

```text
season 26 manager
  -> preset
  -> Challenge wave
  -> monster and stat
  -> client-loadable asset/content reference
```

확인 결과:

- pinned upstream pack과 인접 local reference pack의 필수 entry `7/7`가 byte-identical
- selected season row `6/6`가 exact
- focused behavior/timeline artifact는 prior local reference archive에서 생성했으며, target의 시즌 26 monster-skill row `15/15` exact decode와 complete monster-parts entry byte equality로 equivalence를 검증
- exact classic manager → Challenge preset → wave → 단일 boss/model/stat → current behavior/asset root가 unique하게 닫힘
- behavior graph `917` nodes와 active cast site `109`개가 exact join
- graph는 conditional/random/part-aware ordered flow이며 고정된 한 줄 순서가 아님
- active skill type `14`개 중 `7`개가 exact Timeline marker를 가지며 AttackMarker는 `9`개
- event timing `7`개와 client `150.6.9` native scheduler contract가 미해소되어 absolute frame/ms timing 분석은 계속 blocked
- Git에는 raw ID/path/member 목록 대신 source-free digest와 controlled result만 기록

static/content 축은 `ready_for_selected_manager_patch`이고 timing 분석 축만 `analysis_blocked_native_scheduler_rebind_required`입니다. timing blocker는 content/runtime 실행 실패 판정이 아니므로 3B-1을 차단하지 않습니다. Phase 1C의 published 시즌 26 `static_exact` snapshot은 focused artifact가 `promotion_eligible=false`이므로 승격하지 않습니다. 상세 evidence, 플레이어용 패턴 요약과 공개 영상 trace의 구분은 [PHASE3B0.md](PHASE3B0.md)가 단일 권위입니다.

## 3B-1 — classic selected-manager patch와 focused test

상태: **완료 / `ready_for_isolated_season26_reference_run`**

통합 external commit: `92a6ca228aeb580988907b96189b2857dff2c62d`

Pinned EpinelPS의 baseline route 감사값 `19 = request manager 6 + latest fallback 9 + manager 미사용 4`를 보존했습니다. 최종 policy는 GetLogs Trial projection을 포함한 `7 selected Challenge + 10 controlled unsupported + 2 manager-independent`입니다. Challenge wire의 `Trial` route는 허용하고 Museum·Normal·Practice와 `FastBattle`/Quick 경로는 범위 밖입니다.

첫 `/get`과 `Trial` open 전에 synthetic account에 selection을 명시적으로 bootstrap하고, account selection과 immutable active-run pin을 분리했습니다. Latest fallback 제거, JsonDb restart 복원, per-request handler factory, account-keyed transition serialization과 adversarial decoy test까지 포함한 단일 권위는 [PHASE3B1.md](PHASE3B1.md)입니다. Release rebuild 오류 `0`, focused test `63/63`을 통과했습니다.

종료 조건:

- 계정별 선택 manager가 시즌 26으로 명시적으로 설정됨
- classic manager-dependent route가 모두 같은 선택 source를 사용함
- external account selection과 열린 EpinelPS run이 exact manager를 pin하고 client route로 바뀌지 않음
- manager 미선택·결손·불일치는 최신값 fallback 없이 controlled failure
- `/soloraidmuseum/**` 또는 동등 Museum handler가 호출되지 않음을 focused test로 고정
- patch와 test는 외부 AGPL 작업공간에 있고 이 저장소에는 source-free pin/receipt만 남음
- 모든 MUST test 통과 뒤에만 `ready_for_isolated_season26_reference_run`을 발행

## 3B-2 — isolated live season 26 proof

예상 시간: `2~4시간`

현재 Wave 0에서는 실행 전·후를 분리하는 두 source-free 계약과 전용 verifier만 고정했습니다. Checked-in fixture는 각각 `blocked_preflight_incomplete`, `not_executed_contract_scaffold_only`이며 measured ready receipt나 actual-client 성공 증거가 아닙니다. 판정 우선순위, 증거 강도와 GO/STOP/rollback 절차의 단일 권위는 [PHASE3B2.md](PHASE3B2.md)입니다.

진입 조건:

- 3B-0 closure와 3B-1 focused test 통과
- primary 설치본과 분리된 snapshot 가능한 disposable VM/OS 준비. 단순 디렉터리 복제본은
  정적 검산용일 뿐 system hosts/root CA를 바꾸는 live proof 환경으로 사용하지 않음
- official credential이 없는 synthetic local account 준비
- client, launcher, EpinelPS/server와 관련 child process 전체의 non-loopback 통신 차단·관측 준비
- 모든 local service의 `127.0.0.1` exact bind 확인
- VM/OS의 hosts·root CA와 client-local compatibility file의 before hash, backup과 rollback manifest 준비

검증 흐름:

```text
launch
  -> local synthetic login
  -> lobby
  -> original classic Solo Raid
  -> season 26 Challenge ready
  -> one squad enter
  -> original battle runtime
  -> client damage/result
```

종료 조건은 **시즌 26의 원본 클래식 Solo Raid Challenge가 Museum 버프 없이 실제 전투를 시작하고 원본 client result를 반환하는 것**입니다. Museum 화면, 다른 시즌, lab harness damage 또는 server-calculated result로는 통과하지 않습니다.

실패 시 exact transition과 controlled reason을 남기고 disposable 환경을 rollback합니다. primary 설치본을 이어서 수정하거나 여러 우회책을 한꺼번에 적용하지 않습니다.

## 3C — one-season shadow bridge

초기 조건부 예상: `3~6시간`; 3B-2 뒤 재견적

3B-2가 통과한 뒤 external façade와 Phase 2B 사이에 좁은 loopback bridge를 추가합니다. 첫 버전은 시즌 26 한 개만 대상으로 client-visible state와 Local Lab run identity를 shadow 결박합니다.

- exact local account, selected raid snapshot, squad/build/runtime/control revision pinning
- classic open/enter/result transition과 Phase 2B state transition 대응
- 시즌 26 한 팀용 최소 `OriginalClientBattleObservationAdapter`와 별도 versioned provenance를 구현해 original client damage/result를 보존
- backend나 simulator가 damage를 다시 계산해 client 값으로 대체하지 않음
- transport raw value는 bridge 내부 Git 비추적 binding에만 존재

처음에는 client 성공을 방해하지 않는 shadow/read-compare mode로 시작합니다. 매핑과 replay/idempotency가 검증된 뒤에만 Local Lab을 durable state authority로 승격합니다.

## 3D — season 26 end-to-end sealing

초기 조건부 예상: `4~7시간`; 3C 뒤 재견적

- 시즌 26 run open, first-team enter, observation, close/result의 exact identity 결박
- 실패·재접속·operation replay와 controlled abandon/recovery
- original HUD/ESC damage와 Local Lab receipt 대조
- 실행 profile과 telemetry segment 보존
- Museum handler 호출 없음과 classic manager pin 회귀 검사

3C/3D가 소유하는 것은 시즌 26 one-team 최소 adapter와 identity sealing입니다. Phase 4는 이 계약을 새 이름으로 다시 만들지 않고 1~5팀, regroup/next-team, full ESC/frame telemetry와 recovery parity로 확장합니다.

## 3E — 나머지 지원 시즌 확장

예상: 시즌 26 end-to-end 뒤 시즌별 별도 재견적

- 시즌 `7, 13, 29, 34, 40`을 각각 3B-0과 같은 closure gate로 추가
- 한 시즌씩 별도 batch와 exit verdict로 닫음
- 어떤 시즌도 Museum으로 대체하지 않음
- exact client build가 바뀌면 dependency pin과 closure를 다시 평가

최대 다섯 팀, run-wide character 중복 금지, regroup/next-team/result와 runtime integrity 안정화는 Phase 4가 소유합니다.

## 작업 단위와 시간 제한

- 한 batch는 한 evidence question 또는 한 observable screen transition만 소유합니다.
- 조사 checkpoint는 `60~90분`, 구현 batch는 최대 `2~4시간`으로 제한합니다.
- 각 단계 종료 시 실제 소요와 새 불확실성을 반영해 뒤 단계만 재견적합니다.
- shared bridge contract와 실제 client 환경은 각각 한 writer/한 operator가 직렬 소유합니다.
- 병렬 작업은 외부 dependency audit, source-free tests, 문서와 static closure처럼 상태가 겹치지 않는 lane에 한정합니다.
- 첫 live proof 전에는 Local Lab 통합이나 여섯 시즌 UI를 함께 구현하지 않습니다.

3A-R 착수 시 첫 go/no-go 총견적은 3A-R부터 3B-2까지 `6.5~12.5시간`이었습니다. 3B-1을 완료한 현재 남은 3B-2 조건부 engineering estimate는 `2~4시간`입니다. VM 준비, 다운로드와 사용자/client 가용 시간은 포함하지 않습니다. 3B-2를 통과하기 전에는 전체 통합 일정을 확정값으로 취급하지 않습니다.

## 완료 의미

Phase 3A-R 문서 완료, 3B-0 static closure와 3B-1 external patch test를 통과해도 Phase 3 전체가 완료된 것은 아닙니다. 현재 남은 3B-2 조건부 engineering estimate는 `2~4시간`이고, 최초 3A-R 포함 총견적 `6.5~12.5시간`은 역사적 초기값입니다. Phase 3 완료는 시즌 26이 Local Lab identity와 결박된 원본 클래식 Solo Raid 경로로 end-to-end 실행되고, 이후 선택한 지원 시즌 확장 범위까지 각 exit gate가 통과했음을 뜻합니다. 실제 parity 수준은 `(client build, season, raid snapshot)`별 증거로 남깁니다.
