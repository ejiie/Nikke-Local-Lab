# Phase 3B-0 — 시즌 26 static/runtime closure

> 단계별 계약·검증 기준입니다. 이 문서의 과거 실행 판정과 현재 151 운영 상태를 구분합니다. 현행 진척은 [인계 요약](../HANDOFF.md), 작업 우선순위는 [안정화 계획](../STABILIZATION_PLAN.md)을 확인합니다.

## 판정

상태: **완료 / `ready_for_selected_manager_patch_with_timing_analysis_blocker`**

이 판정은 두 축을 의도적으로 분리합니다.

- static/content closure: `ready_for_selected_manager_patch`
- absolute timing analysis: `analysis_blocked_native_scheduler_rebind_required`

따라서 시즌 26 클래식 Solo Raid의 선택 manager patch인 3B-1은 시작할 수 있습니다. 다만 전체 패턴을 절대 battle frame 또는 millisecond 순서표로 확정하는 분석은 아직 완료되지 않았습니다. 이 timing blocker는 content 결손이나 client runtime 실행 실패 판정이 아니며, 3B-2 reference run 성공 또는 runtime parity를 미리 주장하지도 않습니다.

검증 범위는 client build `150.6.9`, [pinned EpinelPS commit](https://github.com/EpinelPS/EpinelPS/tree/28b2f5413a0a1e3521a11ae162f91851335c8b40), 원본 시즌제/classic `SoloRaid`의 시즌 26 Challenge입니다. `SoloRaidMuseum`과 그 전용 buff는 입력·fallback·교차 검증에서 모두 제외했습니다.

## Static/content closure

Git 밖의 read-only local evidence에서 다음 관계를 같은 대상 content set에 대해 닫았습니다.

```text
season 26 manager
  -> Challenge preset (difficultyType=2, waveOrder=8)
  -> Challenge wave
  -> single spawned boss and model/stat relation
  -> current behavior and client asset roots
```

| 검사 | 결과 |
|---|---|
| upstream/client pin | EpinelPS가 선언한 client build와 local target build가 일치 |
| pack revision drift | pinned upstream pack과 인접 local reference pack의 필수 entry `7/7` byte-identical |
| selected season rows | 3B-0에 필요한 selected row `6/6` exact |
| behavior equivalence | 시즌 26 monster-skill row `15/15` exact decode, complete monster-parts entry byte-identical |
| manager → preset | exact·unique; Challenge selector가 `difficultyType=2`, `waveOrder=8`로 닫힘 |
| preset → wave | exact·unique |
| wave → boss/model/stat | 실제 spawn되는 단일 boss 관계가 exact·unique |
| behavior/content roots | 현재 client catalog에서 exact하게 해소 |
| fallback | 최신 manager, 다른 시즌, Museum 대체 없음 |

Focused behavior/timeline artifact는 pinned target pack에서 새로 생성한 것이 아니라 인접한 prior local reference archive에서 생성했습니다. 대신 target pack과의 equivalence bridge를 별도로 닫았습니다. 필수 chain entry `7/7` byte equality, selected row `6/6` equality, 시즌 26 monster-skill row `15/15` exact decode와 complete monster-parts entry byte equality를 확인했으므로 prior artifact의 graph를 target content에 적용할 수 있습니다. 이를 target pack에서 직접 재생성한 artifact라고 표현하지 않습니다.

pack 비교는 전체 원본 archive를 같다고 추정한 것이 아닙니다. 이 gate에 필요한 entry를 역할별로 좁혀 byte equality와 selected-row equality를 각각 확인했습니다. source-free receipt에는 controlled role, 개수, byte length와 비가역 digest만 남기며 원본 ID, member name, local path, 복호 byte와 salt를 기록하지 않습니다. upstream build·resource pin은 공개 [`gameconfig.json`](https://github.com/EpinelPS/EpinelPS/blob/28b2f5413a0a1e3521a11ae162f91851335c8b40/EpinelPS/gameconfig.json)을 기준으로 합니다.

## 시즌 26 패턴 순서 판정

시즌 26에는 **순서가 있습니다.** 다만 하나의 고정된 선형 스크립트가 아니라 조건·랜덤 선택·파츠 상태를 포함한 ordered behavior graph입니다.

정적 graph에서 확인한 범위는 다음과 같습니다.

- behavior node `917`개를 exact하게 해소
- active cast site `109`개를 skill reference에 모두 exact join
- root shape는 `Repeater -> Sequence`
- `Sequence`, `Selector`, `RandomSelector`, `Parallel`, 조건 분기와 repeater 보존
- HP/phase, target, 파츠 생존 상태와 색상 파츠 조건에 따라 일부 경로가 달라짐
- 고정 seed나 관측 영상 한 편의 실행 순서를 전체 규칙으로 승격하지 않음

플레이어가 읽을 수 있는 상위 흐름은 다음처럼 요약할 수 있습니다.

```text
초반 색상 파츠·방향/대상 분기 패턴군
  -> 공중 전환
  -> 파츠/대상 조건이 있는 charge-laser 패턴군
  -> 여섯 expansion-part 판정과 연계 공격
  -> 일부 순서가 달라진 후반 반복 구간
```

이 요약은 graph의 phase/block 관계를 사람이 읽기 쉽게 축약한 것입니다. 각 전투의 완전한 한 줄 순서나 절대 시각을 뜻하지 않습니다.

## 공개 영상에서 관측한 trace와 graph의 구분

공개 영상·가이드는 graph를 만든 원천이 아니라 **사람이 보는 모션과 graph block을 대응시키는 교차 검증 자료**로만 사용했습니다.

- [skyjlv 시즌 26 가이드](https://www.youtube.com/watch?v=Rpu_ExBdEaQ): 한 공개 trace에서 `0:58` 접근·연속 swipe, `1:07` 강공격, `1:14` 색상 파츠 시작, `2:08` 예측 가능한 색상 순서 설명, `3:05` 여섯 expansion part, `3:20` 순서가 조금 달라진 후반 반복을 확인할 수 있습니다.
- [SpeedsonCH 5-team run](https://www.youtube.com/watch?v=FMqQogd_mU8): 서로 다른 팀의 여러 실행 trace를 비교하는 보조 자료입니다.
- [Vortex 시즌 26 guide](https://vortexgaming.io/en/postdetail/513962)와 [Bahamut 공략](https://forum.gamer.com.tw/C.php?bsn=36390&snA=18621): 여섯 외부 파츠 판정, 실패 시 전멸 계열 결과와 후반 phase 전환을 교차 확인합니다.
- [Enikk season 26 reference](https://enikk.app/soloraid/26): 공격/스킬 의미를 사람이 읽는 label로 대조하는 보조 자료입니다.

한 영상은 조건과 random selector 중 실제로 선택된 trace 하나만 보여 줍니다. 따라서 영상의 모션 순서를 모든 분기의 exact total order로 간주하지 않았고, 반대로 정적 graph만으로 animation callback의 절대 발동 시각을 추측하지 않았습니다.

## Timing analysis blocker

현재 focused extraction의 timing coverage는 다음과 같습니다.

| 항목 | 결과 |
|---|---:|
| active skill type | 14 |
| exact Timeline marker가 있는 skill | 7 |
| exact AttackMarker | 9 |
| exact event timing 미해소 | 7 |
| └ active runtime callback / exact route 없음 | 5 |
| └ route는 있으나 exact attack marker 없음 | 2 |

또한 client `150.6.9`에 맞는 native scheduler contract가 아직 없습니다. 그러므로 behavior order와 cast relation은 exact여도, 모든 event를 battle start 기준 절대 frame/ms로 변환하는 표는 아직 만들 수 없습니다.

이 blocker의 영향은 다음처럼 제한합니다.

- 3B-1 selected-manager patch 진입: 차단하지 않음
- 3B-2 disposable reference run: content 결손으로 차단하지 않음
- 전 패턴의 절대 timing 표 및 scheduler parity 주장: 차단
- 실제 battle에서 animation/QTE/part/timing 검증: 3B-2와 후속 runtime telemetry에서 계속 수행

## Classic route audit와 3B-1 handoff

Pinned EpinelPS의 classic Solo Raid handler `19`개를 manager 선택 관점에서 분류했습니다.

| 분류 | 수 | 의미 |
|---|---:|---|
| request가 manager를 전달 | 6 | 요청값을 사용할 수 있으나 열린 context/run과의 일관성 검사가 필요 |
| latest-manager fallback | 9 | 시즌 26에서 더 최신 manager로 이동할 수 있어 patch 필요 |
| manager 미사용 | 4 | 현행 구현 분류이며 `Enter` 두 경로는 3B-1에서 run pin 검증 대상으로 승격 |

따라서 3B-0의 content closure만으로 EpinelPS가 시즌 26을 end-to-end 유지한다고 볼 수 없었습니다. 위 `19/6/9/4`는 baseline 코드의 manager 사용 방식이고, 당시 3B-1 pre-characterization policy는 `6 selected Challenge + 1 GetLogs gate + 10 controlled unsupported + 2 manager-independent`였습니다. 후속 3B-1은 account별 selected manager bootstrap과 active-run pin을 구현해 최종 `7/10/2`와 focused test `63/63`으로 완료됐습니다. 상세 결과는 [PHASE3B1.md](PHASE3B1.md)를 따릅니다.

3B-0 시점의 3B-1~3B-2 조건부 estimate `5~9시간`은 역사값입니다. 3B-1 완료 뒤 남은 3B-2 estimate는 `2~4시간`이며 disposable VM 준비와 사용자/client 가용 시간은 포함하지 않습니다.

## Phase 1C snapshot과의 관계

이 focused diagnostic은 Phase 1C가 게시한 시즌 26 `static_exact` RaidSnapshot을 수정하거나 `behavior_exact`로 승격하지 않습니다.

- 기존 published snapshot과 V0003 이력은 불변입니다.
- focused behavior/timeline artifact는 `promotion_eligible=false`입니다.
- 3B-0 verdict는 exact target build에서 다음 compatibility 작업을 시작할 수 있는지에 대한 별도 실행 준비 판정입니다.
- 향후 snapshot tier를 올리려면 Phase 1C의 정식 evidence publication 경로와 invariant를 별도로 통과해야 합니다.

## Source-free machine contract

사람이 읽는 이 문서와 별도로 다음 source-free artifact가 같은 판정을 봉인합니다.

- [closure schema](../../contracts/season26-classic-solo-raid-closure.schema.json)
- [ready assessment](../../tests/fixtures/evidence/season26-classic-solo-raid-closure.ready.json)
- [evidence boundary manifest](../../tests/fixtures/evidence/manifest.json)
- [contract verifier](../../scripts/verify-phase3b0.ps1)

Assessment는 exact dependency/target pin, static closure, behavior/timing coverage, fallback 금지, 다음 단계 requirement와 역할별 비가역 관측값만 포함합니다. 원본 game ID, member name, local path, 복호 row와 asset byte는 포함하지 않습니다.

```powershell
pwsh -NoProfile -File scripts/verify-phase3b0.ps1 -ContractOnly
```

## 완료 의미

3B-0 완료로 확정한 것은 다음 두 가지입니다.

1. 시즌 26의 classic manager부터 current behavior/asset root까지 content chain이 닫혀 3B-1을 진행할 수 있습니다.
2. 패턴은 조합 가능한 ordered graph지만 완전히 고정된 선형 순서가 아니며, absolute timing은 native scheduler contract와 runtime 관측이 더 필요합니다.

3B-0 시점에 미완료였던 external selected-manager patch는 3B-1에서 완료했습니다. 아직 완료하지 않은 것은 disposable client 실행, 원본 battle/result, Local Lab bridge와 original-runtime observation sealing이며 [PHASE3.md](PHASE3.md)의 3B-2 이후 exit gate가 소유합니다.
