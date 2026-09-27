# Solo Raid 기록 영속화 및 전투 분석 설계

## 문서 상태

현재 저장 계약은 [실행 간 영속화](RUNTIME_PERSISTENCE.md)와
[2026-09-17 버전 독립 저장·로비 Quit 정정](../operations/VERSION_INDEPENDENT_RUNTIME_PERSISTENCE.md)을 따른다.
아래 build별 저장 범위 및 참여 횟수 환급 서술은 과거 구현 관측이며 현재 요구가 아니다.

**2026-09-06 요구사항 정정:** 원본 스쿼드 편성 화면의 `My Records`는 최고점과 독립된
덱별 전투 이력이다. 낮은 점수 완주와 메인 화면 Quit에서도 이미 친 덱의 구성·피해량을
보존하고 최신순으로 표시해야 한다. 아래 과거 구현의 'run 폐기'는 이력까지 삭제하는
올바른 요구사항이 아니다. 최고점 갱신 조건은 그대로 유지한다.
예시·현 코드 결함·인수 조건과 추가 해금 알림/스킨/편성/약점별 기록 과제는
[안정화 계획의 영속화 추가 정비](../STABILIZATION_PLAN.md#영속화-추가-정비--2026-09-06--미구현)에만 관리한다.
해당 추가 요구는 **미구현**이다. 기존 151/S26 실게임 검증 완료를 모든 이력 보존 완료로 확대하지 않는다.

아래 상태·구현 순서·acceptance 대기는 2026-08-31 당시 기록이다. 현재 작업 지시나
진척도는 위 안정화 계획을 따르며, 과거의 계측 추가 순서를 자동 재개하지 않는다.

- 상태: ranking wire 과잉 차감 해결 및 원본 클라이언트 acceptance 통과, 축 1 영속화 구현·오프라인 실 DB 검증·설치 DB RaidSnapshot 결박 복구 완료, 원본 클라이언트 재실행 acceptance 대기
- 대상: 원본/classic Solo Raid Challenge의 클라이언트 기록 영속화와 Control Center 전투 분석
- 작성 기준: 2026-08-31까지 확인한 실제 5덱 완주 자료, EpinelPS 저장 구조, Local Lab 실행·복구 흐름
- ranking wire 과잉 차감은 코드·합성·Static Data 검증과 실제 원본 클라이언트 acceptance까지 완료했다. 2026-08-31 v9 실제 5덱 완료 화면에서 파란 점수와 노란 `My High Score`가 모두 `24,972,784,671`로 정확히 일치했다. 이 점수 불일치 문제는 해결 완료다. 기존 411억 기록은 집계 증거만 남아 있고 원본 5덱 DB는 실행 종료 복구 과정에서 덮어써졌다. 같은 소실이 반복되지 않도록 축 1 영속화 경로를 구현했으며, 현재 남은 축 1 판정은 설치본에서 새 5덱을 완료한 뒤 게임 종료·재실행으로 확인하는 actual-client acceptance다.

## 목표와 작업 순서

작업은 두 축으로 분리한다.

1. **축 1 — 원본 클라이언트 기록 영속화**
   - 게임을 종료하고 다시 실행해도 원본 클라이언트의 Solo Raid 최고 기록과 5개 덱 기록이 유지되게 한다.
   - 클라이언트가 실제로 사용하는 compatibility 상태만 정확히 보존한다.
2. **축 2 — Control Center 상세 분석**
   - 새로 친 5덱의 캐릭터별 피해, 피해 유형, 치명타 등 원본 클라이언트 기록보다 자세한 분석 정보를 별도 UI에서 제공한다.

구현 순서는 다음과 같이 고정한다.

1. 축 1을 먼저 구현하고 재실행 영속성을 검증한다.
2. 다음 실제 5덱 실행 전에 측정 전용 계측을 추가한다.
3. 새 5덱을 완주하여 필요한 필드와 의미를 검증한다.
4. 검증된 값만 사용하여 축 2의 저장 모델과 UI를 구현한다.

축 2를 먼저 만들거나, 계측 없이 새 5덱부터 실행하면 캐릭터별 원자료를 다시 잃을 수 있다.

## 확정 UI 요구사항 — run → 덱 → 캐릭터 drill-down

Control Center의 Solo Raid 분석 UI는 Enikk.app의 Solo Raid 기록 구조를 참고하되,
시각 디자인은 현재 Control Center와 동일한 Blabla 또는 원본 NIKKE UI 기반으로
구성한다. 별도 게임풍 디자인 시스템을 새로 만들지 않는다.

필수 조회 계층은 다음과 같다.

1. **run 목록과 요약**
   - 완료한 Solo Raid Challenge 1회를 하나의 run으로 취급한다.
   - 각 run에 5개 덱의 공식 피해 합계와 덱별 공식 피해를 함께 표시한다.
   - 완료되지 않은 1~4덱 실행은 완료 run과 구분하고 합계·최고 기록에 섞지 않는다.
2. **동일 덱 구성의 피해 이력**
   - 같은 5명으로 구성된 덱의 실행 이력을 모아 피해량 목록을 제공한다.
   - 예를 들어 구성원 `a/b/c/d/e`인 덱이 서로 다른 run에서 `100`, `101`, `102`의
     공식 피해를 냈다면, 해당 덱 구성 화면에서 세 기록을 모두 조회할 수 있어야 한다.
   - 화면에는 당시 슬롯 순서와 캐릭터 snapshot을 보존하되, 같은 덱 구성으로 묶는
     canonical key의 슬롯 순서 포함 여부는 실제 UI 사용성을 확인한 뒤 확정한다.
3. **덱 상세와 캐릭터별 피해**
   - 덱을 선택하면 당시 구성원 5명을 표시한다.
   - 각 캐릭터별로 `Attack`, `Skill`, `StatFunctionAttack`의 raw/actual 피해와 검증된
     count를 조회할 수 있어야 한다.
   - 프로토콜 집계 계층이 겹칠 수 있으므로 세 값을 검증 없이 더해 단일
     `캐릭터 총딜`로 표시하지 않는다. 원본 결과와 대조해 대표값의 의미가 확정되기
     전에는 버킷별 값을 나란히 표시한다.
4. **덱 단위 공식 점수 구성**
   - 덱 공식 피해와 함께 몬스터 HP 수신 피해, 투사체 수신 피해, 파츠 파괴 보너스를
     조회할 수 있게 한다.
   - 공식 점수는 `몬스터 HP 수신 피해 - 투사체 수신 피해 + 파츠 파괴 보너스` 계약을
     사용한다.
   - 투사체 피해와 파츠 파괴 보너스는 현재 덱 단위로 정확히 관측되지만 캐릭터별
     직접 귀속 필드는 확인되지 않았다. 이벤트 수준 근거 없이 마지막 공격자나
     비율로 캐릭터에게 배분하지 않는다.

UI는 최소한 다음 이동 흐름을 제공한다.

```text
Solo Raid run 목록
→ run 상세(합계 + 5개 덱)
→ 덱 구성별 과거 피해 이력
→ 선택한 덱의 캐릭터 5명 피해 상세
```

원본 게임 식별값은 UI·일반 API의 도메인 키로 노출하지 않는다. 저장 시 Local Lab
account, season, raid snapshot, client build, run, deck와 character snapshot에 결박하고,
표시는 published character catalog의 local reference를 통해 해소한다.

### 기존 411억 관측 자료의 표시 한계

기존 공식 합계 `41,192,493,216` 실행은 run 합계, 5개 덱의 공식 피해, 덱별 몬스터
HP 피해, 투사체 피해, 파츠 파괴 보너스와 캐릭터 5명의 합산 damage-source 값까지
보존됐다. 당시 v8 관측기는 캐릭터 식별값과 캐릭터별 행을 남기지 않고 각 요청의
5명 합계만 기록했다. 이후 완전한 `SoloRaidData`와 원본 캐릭터별 요청 자료도 실행 전
DB 복구로 덮어써졌다.

따라서 기존 411억 자료로 위 UI의 run 및 덱 계층은 예시화할 수 있지만, 25명 각각의
피해량은 정확히 복원할 수 없다. 임의 분배하지 않으며 `source_not_preserved`로 표시한다.
다음 실제 5덱 실행 전에는 캐릭터별 원자료 보존 계측을 먼저 배포해야 한다.

## 확인된 기록 소실 원인

### 관측 실행

- 실행 ID: `d8fdda53-dc4f-497d-9b41-1172768ee5c4`
- 완료된 전투 결과: 5개
- 저장된 join: 5개
- 저장된 record: 5개
- 공식 합산 점수: `41,192,493,216`
- 당시 Epinel 런타임은 `ClassicSoloRaidPersistenceCoordinator`를 통해 `db.json`을 정상적으로 atomic save했다.

즉, Epinel 저장 실패나 클라이언트 캐시 문제가 아니었다.

### 실제 원인

관측용 완료 스크립트 `complete-phase3b2-epinel-solo-raid-damage-source-observer-v8-in-micron.ps1`은 실행을 마친 뒤 런타임 `db.json`을 실행 전 `db.before.bin`으로 되돌린다. 완료 영수증에도 `databaseRestored=true`가 남았다.

다음 실행을 만드는 `scripts/invoke-nll-phase-d-execution.ps1`도 이전 실행 결과가 아니라 고정된 parent baseline의 `db.json`을 다시 사용한다. 그 baseline의 `SoloRaidData`는 비어 있다.

따라서 기존 관측 lane에서는 다음 순서가 의도적으로 발생했다.

1. 실제 전투 결과를 Epinel 런타임 DB에 저장한다.
2. 관측 증거를 봉인한다.
3. 실행 전 DB를 복원하면서 전투 기록을 제거한다.
4. 다음 실행도 Solo Raid 기록이 없는 고정 baseline에서 시작한다.

이 복구 방식은 일회성 관측에는 맞지만, 클라이언트 기록 영속화 요구에는 맞지 않는다.

### 기존 411억 기록의 복구 가능 범위

집계 receipt와 관측 증거는 남아 있으므로 공식 합계와 덱별 집계 값은 확인할 수 있다. 그러나 당시의 완전한 5덱 `SoloRaidData`와 캐릭터별 원자료는 원본 DB 복구로 덮어써졌으므로 정확히 재구성할 수 없다. 추정으로 복원하지 않고 새 5덱을 다시 실행해야 한다.

## Epinel의 현재 Solo Raid 기록 구조

EpinelPS의 현재 영속 모델은 다음 구조다.

```text
SoloRaidInfo
├─ RaidId
├─ RaidOpenCount
├─ TrialCount
├─ LastDateDay
└─ SoloRaidLevels[]
   └─ SoloRaidLevelData
      ├─ RaidLevel
      ├─ RaidJoinCount
      ├─ Hp
      ├─ TotalDamage
      ├─ IsClear
      ├─ Status
      ├─ Type
      ├─ IsOpen
      └─ Logs[]
         └─ SoloRaidLogData
            ├─ Damage
            ├─ Kill
            └─ Team[]
               └─ TeamCharacterData
                  ├─ Slot
                  ├─ Csn
                  ├─ Tid
                  ├─ Lv
                  ├─ Combat
                  └─ CostumeId
```

`SoloRaidHelper.SetDamage`는 요청의 공식 `Damage`를 덱 로그의 피해량으로 저장하고, 함께 제출된 팀 구성을 기록한다.

원본 클라이언트의 기존 `NetSoloRaidLog` 계약은 `Damage`, `Team`, `Kill`만 제공한다. 캐릭터별 피해 필드가 없으므로 캐릭터별 상세 분석은 원본 클라이언트 결과 화면에 억지로 넣지 않고 Control Center 전용 데이터로 분리한다.

## 구현용 빠른 조회 지도

나중에 조사와 UI 구현을 반복하지 않도록 조회 목적별 권위 저장소와 필드 경로를
다음과 같이 고정한다. 호환성 최고 기록, 실행 중 Epinel 상태, 전투 분석 원자료는
서로 다른 계층이며 한 저장소에 모두 들어 있지 않다.

### 최고 기록과 5개 덱 기록

| 조회 목적 | 권위 위치와 필드 | 주의사항 |
|---|---|---|
| 계정·보스·build별 최고 합계 | PostgreSQL `lab_private_server.classic_solo_raid_runtime_state_revision.completed_best_total_damage` | 빠른 목록용 projection이다. 덱별 상세는 없음 |
| 완료 덱 수 | 같은 revision의 `completed_best_team_count` | 유효한 Challenge 완료는 정확히 `5`다. 빨간 `Quit`은 최고점을 갱신하지 않는다. 기존 코드는 덱 로그도 제거하지만, 이는 P-01에서 수정할 결함이며 이력 삭제 요구가 아니다 |
| 진행 중 run 여부와 완료 덱 수 | `has_open_run`, `open_team_count` | 완료 최고 기록과 별도 상태다 |
| 캡처·영속 시각 | `captured_at_utc`, `persisted_at_utc` | 실행 영수증과 대조할 때 사용한다 |
| 상태 payload 무결성 | `state_content_sha256`, `protected_payload_sha256` | payload 내용을 대신하는 피해 수치가 아니다 |
| 최고 기록의 덱별 피해와 구성 | `protected_payload`를 결박된 identity secret과 `RaidSnapshot`/client-build associated data로 복호화한 `StatePayload.Raid.SoloRaidLevels[]` | SQL에서 임의로 byte를 JSON 취급하지 않는다. `ClassicSoloRaidRuntimeState.RestoreAsync`와 같은 검증 경로 또는 별도 read-only exporter를 사용한다 |

복호화한 payload 또는 실행 중 `db.json`에서는 다음 조건과 경로로 완료 최고 기록을
찾는다.

```text
User.SelectedClassicSoloRaidManagerId
User.SoloRaidData[selectedManagerId]
  .SoloRaidLevels[]
    where RaidLevel == 8
      and Type == Trial(2)
      and IsOpen == false
      and IsClear == true
      and Status == Kill(1)

completedLevel.TotalDamage          # 5덱 공식 합계
completedLevel.Logs[i].Damage       # i번째 덱 공식 피해
completedLevel.Logs[i].Kill
completedLevel.Logs[i].Team[j]      # Slot/Csn/Tid/Lv/Combat/CostumeId
```

원본 클라이언트 wire에서는 목적을 구분한다.

- `NetUserSoloRaidInfo.TrialDamage`와 `NetSoloRaidRankingData.Damage`는 원본
  클라이언트의 ranking 해석을 위한 Common I~VII prefix가 더해진 호환 wire 값이다.
  Control Center의 공식 Challenge-local 최고 기록 원본으로 저장하지 않는다.
- `OpenTrialDamage`는 최고 기록 여부와 무관한 현재 완료 run 표시값이다.
- `/soloraid/getlogs`의 `NetSoloRaidLog.Damage`는 덱별 raw 공식 피해이며
  `Team`과 `Kill`을 함께 제공한다.

### 417억 영속 기록

2026-08-31 영속화 acceptance의 최고 기록은 `41,715,464,088`이며
`completed_best_team_count=5`로 세 번의 capture/persistence 영수증에서 확인됐다.
낮은 후속 run `5,883,263`은 이 최고 기록을 덮어쓰지 않았다. 이 기록의 암호화 payload에는
완료 level의 `Logs[5]`와 각 `Team` snapshot이 있으므로 read-only 복호화 경로를 추가하면
5개 덱의 정확한 피해와 구성을 조회할 수 있다.

이 payload에는 캐릭터별 피해 집계가 없다. 따라서 417억 기록에서 25명의 피해를 사후
복원하거나 덱 피해를 임의 배분하지 않는다.

### 캐릭터별 피해를 추출해야 하는 위치

캐릭터별 피해는 완료 후 `db.json`, PostgreSQL 최고 기록 또는 `/soloraid/getlogs`에서
추출하는 값이 아니다. 서버가 다음 route의 요청 body를 역직렬화한 직후, 정책 검증과
`SetDamageTrial` mutation이 성공한 요청에서 별도 분석 sidecar로 보존해야 한다.

```text
POST /soloraid/trial/setdamage
ReqSetSoloRaidTrialDamage
```

현재 소스의 실제 seam은 다음 순서다.

```text
SetDamageTrial.HandleAsync
  -> ReadData<ReqSetSoloRaidTrialDamage>()
  -> ClassicSoloRaidRouteExecutor.SetDamageTrial(accountId, request)
  -> SoloRaidHelper.SetDamageTrial(...)
  -> SoloRaidHelper.SetDamage(...)
```

마지막 helper는 현재 `request.Damage`와 캐릭터의 `Slot/Csn/Tid/Lv/Combat/CostumeId`만
`SoloRaidLogData`에 저장하고 나머지 anti-cheat 집계를 버린다. 따라서 분석 캡처는 요청을
읽은 직후 무조건 기록하는 방식이 아니라, route policy 통과와 성공 mutation에 결박해
정확히 한 번 저장해야 한다. retry/regroup/실패 요청은 `BattleResult`와 route 결과를 함께
남기되 완료 run 집계에서 분리한다.

캐릭터별로 보존할 실제 접근 경로는 다음과 같다.

| 의미 | 요청 필드 경로 |
|---|---|
| 덱 공식 점수 | `ReqSetSoloRaidTrialDamage.Damage` |
| 완료·retry 문맥 | `ReqSetSoloRaidTrialDamage.BattleResult` |
| 전투 시간 | `AntiCheatBattleData.BattleDuration` |
| 캐릭터 식별·슬롯 | `AntiCheatBattleData.Characters[i].Slot/Csn/Tid` |
| 당시 캐릭터 snapshot | `Characters[i].CharacterSpec` |
| 평타 raw/actual | `Characters[i].Attack.TotalDamage/TotalActualDamage` |
| 평타 횟수·치명타 | `Characters[i].Attack.AttackCount/DamageCount/CritCount/MissCount` |
| 전체 스킬 raw/actual | `Characters[i].Skill.TotalDamage/TotalActualDamage` |
| 스킬 횟수·치명타 | `Characters[i].Skill.UseCount/DamageCount/CritCount/MissCount` |
| stat-function raw/actual | `Characters[i].StatFunctionAttack.TotalDamage/TotalActualDamage` |
| stat-function 횟수 | `Characters[i].StatFunctionAttack.DamageCount` |
| 몬스터 HP raw/actual 수신 피해 | `AntiCheatBattleData.Monsters[m].Hp.TotalDamageReceived/TotalActualDamageReceived` |
| 파츠 파괴 보너스 | `Monsters[m].Hp.TotalPartsDestroyDamageReceived` |
| 투사체 피해 | `Monsters[m].Hp.TotalProjectileDamageReceived` |

`Attack`, `Skill`, `StatFunctionAttack`은 의미가 완전히 검증되기 전까지 각각 저장하고
무조건 더해 하나의 캐릭터 총딜로 만들지 않는다. 다음 실제 5덱에서 원본 결과와 대조한 뒤
대표 합계를 확정한다. `Skill`은 캐릭터별 전체 스킬 집계라서 이 필드만으로 스킬 1·스킬 2·
버스트를 분리할 수 없다. 해당 분리는 별도 battle-report/TLog에서 `SkillId`, `SkillSlot` 또는
`FunctionId`가 관측될 때 Static Data와 결합해 구현한다.

분석 저장소에는 원본 `Csn`/`Tid`를 일반 API·UI key로 노출하지 않는다. capture 시점의
launch context, local account, raid snapshot, run/deck ordinal과 local character alias에
결박하고, 원본 식별값이 필요하면 보호된 내부 mapping 경계 안에서만 사용한다.

## 공식 점수 의미와 부호 정정

### 확정 공식

관측된 각 덱과 5덱 합계에서 다음 식이 정확히 성립했다.

```text
officialDamage
= monsterHpDamageReceived
- monsterProjectileDamageReceived
+ monsterPartsDamageReceived
```

5덱 합계에 대입하면 다음과 같다.

```text
41,639,176,110
- 451,829,298
+   5,146,404
= 41,192,493,216
```

즉, `ReqSetSoloRaidTrialDamage.Damage`는 보스가 받은 피해에서 투사체 피해를 제외하고 파츠 파괴 보너스를 더한 공식 점수다. 투사체 피해는 이미 공식 점수에서 제외되어 있다.

### 폐기된 잘못된 해석

공식 점수에서 투사체 피해를 한 번 더 빼는 계산과 그 결과인 `40,740,663,918`은 잘못된 해석이다. 이 계산은 구현·저장·UI 어디에도 사용하면 안 된다. 이 잘못된 해석을 근거로 변경한 코드는 없다.

## 결과 화면의 파란 점수와 노란 점수 불일치 — 해결 완료

### 재현된 화면과 확정된 원인

2026-08-28 실제 5덱 완료 결과 화면에서 다음 두 값이 동시에 표시됐다.

| 화면 표면 | 표시값 | 확인된 입력 의미 |
|---|---:|---|
| 파란 점수 | 35,177,379,898 | Challenge 다섯 덱의 raw 공식 점수 합 |
| 노란 `My High Score` | 34,046,598,712 | ranking wire 값을 누적 점수로 해석한 원본 클라이언트가 Common I~VII 체력 합을 차감한 결과 |
| 차이 | 1,130,781,186 | 시즌 26 Common I~VII 보스 최대 체력의 정확한 합 |

동결된 150.6.9 원본 클라이언트의 소비 경로를 조사한 결과 두 점수는 서로 다른 서버 원자료가 아니었다. `NetTrialSoloRaid.Damage` 계열은 Challenge-local raw 점수로 소비하지만, `NetSoloRaidRankingData.Damage` 계열은 Common I~VII를 포함한 누적 점수로 해석한 뒤 Common 단계 최대 체력을 차감한다. 기존 v7 서버가 동일한 raw Challenge 점수를 두 도메인에 모두 보냈기 때문에 ranking 경로에서만 `1,130,781,186`이 과잉 차감됐다.

동결 Static Data에서 선택된 시즌 26 manager의 Common I~VII를 exact closure로 해소한 값은 다음과 같다.

```text
12,445,632
+ 31,908,051
+ 66,617,715
+ 157,017,558
+ 234,073,575
+ 299,528,421
+ 329,190,234
= 1,130,781,186
```

### 기존 서버 증거가 노란 값을 포함하지 않았던 이유

당시 v7 marker 및 사후 조사에는 다음 내용이 남아 있다.

- 완료된 다섯 `trial/setdamage` 요청의 `request.Damage` 합: `35,177,379,898`
- 마지막 `trial/setdamage` 응답의 `Info.Damage`: `35,177,379,898`
- 마지막 `trial/setdamage` 응답의 `User.Damage`: `35,177,379,898`
- 직후 `/soloraid/get`의 `TrialDamage`: `35,177,379,898`
- `/soloraid/getranking`의 `Rankings[0].Damage` 및 `User.Damage`: `35,177,379,898`
- `/soloraid/getrankersquad`의 다섯 로그 합: `35,177,379,898`
- 당시 조사한 runtime `db.json`, NLL evidence, LocalLow 평문 파일에서 `34,046,598,712`는 발견되지 않음

서버·DB·평문 파일에 `34,046,598,712`가 없었던 것은 정상이다. 해당 값은 서버가 저장하거나 반환한 별도 점수가 아니라, 원본 클라이언트가 raw 값이 잘못 들어간 ranking wire 필드에서 Common prefix를 뺀 파생 표시값이었다. 따라서 raw/actual 피해, 투사체 피해, 파츠 보너스 또는 stale high score 가설은 이 고정 차이의 원인에서 제외한다.

### 수정된 필드 계약

누적값은 저장 모델이 아니라 원본 클라이언트 compatibility를 위한 wire encoding이다.

| 위치 | 값 |
|---|---|
| 런타임 DB `SoloRaidLevelData.TotalDamage` | Challenge-local raw 점수 |
| `SoloRaidLogData.Damage` 및 ranker-squad 로그 | 덱별 raw 점수 |
| `trial/setdamage`의 `NetTrialSoloRaid.Info.Damage` | 현재 Challenge-local raw 누계 |
| `NetUserSoloRaidInfo.TrialDamage` | raw 최고 기록 + Common I~VII prefix |
| `trial/setdamage`의 `NetSoloRaidRankingData.User.Damage` | raw 최고 기록 + Common I~VII prefix |
| `/soloraid/getranking`의 `Rankings[].Damage`, `User.Damage` | raw 최고 기록 + Common I~VII prefix |

prefix는 선택 manager의 Static Data에서 Common 7개와 Trial 1개의 exact closure, 단일 target, 단일 level-stat row, `HpRatio=10000`, stage-change 부재를 모두 확인한 경우에만 해소한다. 결손·중복·모호성·산술 overflow에서는 응답과 저장 mutation을 fail closed한다. 누적값은 DB에 저장하지 않으므로 재시작이나 반복 조회에서 두 번 더해지지 않는다.

수정 DLL은 `C:\NLL\Runtime\EpinelPS-SoloRaidRankingPrefix-v9`에 별도 봉인했다. v8을 덮어쓰지 않았고 Control Center는 v9를 실행별로 복제한 뒤 프로필 DB만 파생한다. 배포 receipt SHA-256은 `d360b29ca19fa36c6c1504d7b29a30d541621bf5855b45810f87e43d9e63a269`이며, 배포 중 서버·클라이언트는 실행하지 않았다.

### 원본 클라이언트 acceptance — 2026-08-31

운영자가 v9 lane으로 원본 150.6.9 클라이언트의 Solo Raid Challenge 5덱을 실제 완료했다. 최종 결과 화면에서 다음 값이 동시에 확인됐다.

- 결과 화면의 파란 총점: `24,972,784,671`
- 노란 `My High Score`: `24,972,784,671`
- 두 표면의 차이: `0`

이 결과는 raw Challenge 점수와 ranking cumulative wire encoding이 원본 클라이언트의 Common I~VII 차감 규칙을 통과한 뒤 같은 값으로 수렴함을 확인한다. 기존의 고정 과잉 차감 `1,130,781,186`은 재현되지 않았다.

### 해결 판정과 후속 과제 경계

파란 결과 점수와 노란 `My High Score`의 불일치 및 Common prefix 과잉 차감 문제는 **완전 해결**로 판정한다. 정적 closure, wire 경계 단위·직렬화 테스트, 선택 경로 `114/114`, 봉인 배포 검증과 위 실제 원본 클라이언트 결과가 이 판정의 근거다.

게임 종료·재실행 뒤 최고 기록과 5개 덱 기록이 유지되는지, 낮은 후속 점수와 높은 후속 점수를 어떻게 갱신하는지는 축 1 기록 영속화의 별도 acceptance다. 해당 후속 결과가 이 점수 불일치 해결 판정을 다시 미해결로 되돌리지는 않는다.

### 시즌 일반화 범위

v9은 시즌 26 ID나 `1,130,781,186`을 하드코딩하지 않는다. 실행 시 선택된 manager ID를 기준으로 해당 manager의 preset group을 따라가 각 Common I~VII 보스의 `LevelHp`를 합산하고, 그 실행에서만 사용할 ranking wire prefix를 계산한다. 따라서 알려진 classic Solo Raid 구조를 유지하는 다른 시즌에도 같은 수정이 적용된다.

다만 현재 원본 클라이언트 actual-play acceptance가 완료된 시즌은 시즌 26이다. 다른 시즌 또는 새 보스를 지원할 때는 다음 조건을 해당 Static Data에서 다시 통과해야 한다.

- Common I~VII 7개와 Challenge/Trial 1개의 정확한 preset closure
- Common wave order 1~7 및 Trial wave order 8
- 각 Common wave의 단일 target, 단일 level-stat row, 양수 `LevelHp`
- 전체 보스 체력 비율 `HpRatio=10000` 및 stage-change 부재
- prefix 및 wire 합산의 64-bit overflow 부재

조건이 하나라도 맞지 않으면 추정값이나 시즌 26 prefix를 재사용하지 않고 응답 mutation 전에 fail closed한다. 그러므로 다른 classic 시즌은 **구조상 일반 지원**되지만, 보스 추가 시 Static Data closure와 원본 클라이언트 점수 일치 smoke를 거쳐 그 시즌의 실증 지원 상태를 확정한다. Solo Raid Museum은 이 범위에 포함하지 않는다.

## 실제 5덱 관측값

아래 값은 `battleResult=1`인 완료 결과만 집계했으며 재시도 결과는 제외했다.

### 전체 합계

| 필드 | 값 |
|---|---:|
| 공식 요청 피해 `requestDamage` | 41,192,493,216 |
| 캐릭터 일반 공격 raw | 41,801,654,556 |
| 캐릭터 일반 공격 actual | 27,136,622,411 |
| 캐릭터 스킬 raw | 12,623,846,853 |
| 캐릭터 스킬 actual | 6,997,586,930 |
| 캐릭터 stat-function raw | 39,233,324 |
| 캐릭터 stat-function actual | 39,233,324 |
| 몬스터 HP 수신 피해 | 41,639,176,110 |
| 몬스터 HP actual 수신 피해 | 27,136,622,411 |
| 파츠 파괴 보너스 | 5,146,404 |
| 투사체 수신 피해 | 451,829,298 |
| 캐릭터 raw 구성요소 합계 | 54,464,734,733 |
| 캐릭터 actual 구성요소 합계 | 34,173,442,665 |

raw 구성요소 합계나 actual 구성요소 합계를 공식 점수로 간주해서는 안 된다. 서로 다른 계층과 의미의 값이므로 실제 결과 비교를 통해서만 UI의 기본 지표를 정한다.

### 덱별 값

| 덱 | 공식 피해 | 캐릭터 raw 합계 | 캐릭터 actual 합계 | 몬스터 HP 피해 | 몬스터 HP actual | 파츠 보너스 | 투사체 피해 |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 12,928,399,505 | 13,761,783,936 | 6,163,249,809 | 13,012,623,132 | 5,866,373,949 | 1,075,368 | 85,298,995 |
| 2 | 4,106,918,119 | 4,707,801,127 | 4,663,712,254 | 4,115,129,605 | 4,106,919,019 | 998,556 | 9,210,042 |
| 3 | 11,757,826,721 | 21,349,662,766 | 10,738,291,786 | 11,773,442,148 | 5,866,376,649 | 998,556 | 16,613,983 |
| 4 | 5,430,575,125 | 6,229,143,099 | 5,583,785,503 | 5,726,383,380 | 5,430,576,625 | 1,075,368 | 296,883,623 |
| 5 | 6,968,773,746 | 8,416,343,805 | 7,024,403,313 | 7,011,597,845 | 5,866,376,169 | 998,556 | 43,822,655 |

## 현재 확인된 피해 관련 필드

### 공식 덱 점수와 전투 문맥

- `ReqSetSoloRaidTrialDamage.Damage`: 해당 덱의 공식 점수
- `ReqSetSoloRaidTrialDamage.Team`: 해당 덱의 캐릭터 구성
- `ReqSetSoloRaidTrialDamage.BattleResult`: 완료 여부 필터
- `AntiCheatBattleData.BattleDuration`: 전투 시간
- `AntiCheatAdditionalInfo.ReportData`: 추가 opaque 보고 데이터
- 별도 `/antibot/battlereportdata` 요청:
  - `ReqBattleReportData.WaveId`
  - `ReqBattleReportData.ReportData3`

이전 SetDamage 관측에서 `AntiCheatAdditionalInfo.ReportData`의 길이는 0이었다. 그러나 별도 battle-report route가 존재할 가능성은 다음 실제 실행에서 별도로 확인해야 한다.

### 캐릭터 식별과 일반 공격

각 캐릭터는 `AntiCheatBattleData.Characters[i]`에 있으며 다음 식별 필드를 가진다.

- `Slot`
- `Csn`
- `Tid`
- `CharacterSpec`

일반 공격 집계 `Attack`에서 확인할 필드:

- `TotalDamage`
- `TotalActualDamage`
- `AttackCount`
- `DamageCount`
- `CritCount`
- `MissCount`
- `MaxDamage`, `MinDamage`
- `MaxCritDamage`, `MinCritDamage`

추가 필드로 `MaxEnemyHitCount`, `MaxAmmo`, `MinReloadTime`, `MaxChargingPercentage`, `MaxShotCountPerSeconds`가 있으나 초기 분석 UI에는 포함하지 않는다. 명확한 사용 사례가 생긴 뒤 검토한다.

### 캐릭터 스킬

스킬 집계 `Skill`에서 확인할 필드:

- `TotalDamage`
- `TotalActualDamage`
- `DamageCount`
- `CritCount`
- `MissCount`
- `MaxDamage`, `MinDamage`
- `MaxCritDamage`, `MinCritDamage`
- `UseCount`
- `MinCooldown`

현재 이 구조는 모든 스킬을 합산한 값이다. `SkillId`나 `SkillSlot`이 없으므로 이 집계만으로 스킬 1·스킬 2·버스트를 나눌 수 없다.

### 캐릭터 stat-function 공격

`StatFunctionAttack`에서 확인할 필드:

- `TotalDamage`
- `TotalActualDamage`
- `DamageCount`
- `MaxDamage`, `MinDamage`

여기에는 `CritCount`가 없다.

### 몬스터 수신 피해

`AntiCheatBattleData.Monsters[*].Hp`에서 확인할 필드:

- `TotalDamageReceived`
- `TotalActualDamageReceived`
- `TotalPartsDestroyDamageReceived`
- `TotalProjectileDamageReceived`

## 치명타를 나눌 수 있는 범위

현재 확인된 집계만으로 가능한 구분:

- 평타 치명타: `Attack.CritCount`
- 전체 스킬 합산 치명타: `Skill.CritCount`
- 평타와 스킬 각각의 `DamageCount`, `MissCount`
- 평타와 스킬 각각의 최대·최소 치명타 피해

현재 불가능하거나 아직 검증되지 않은 구분:

- 스킬 1·스킬 2·버스트 각각의 치명타 횟수
- 스킬 1·스킬 2·버스트 각각의 피해량
- 치명타 피해 총합
- stat-function 공격의 치명타 횟수

`CritCount / DamageCount`는 후보 비율일 뿐이다. 두 필드의 이벤트 단위가 동일하다는 사실을 실제 전투에서 검증하기 전에는 확정된 치명타율로 표시하지 않는다.

## Static Data로 가능한 것과 불가능한 것

캐릭터 Static Data에는 다음 기본 매핑이 있다.

- `UltiSkillId`
- `Skill1Id`와 `Skill1Table`
- `Skill2Id`와 `Skill2Table`

`SkillInfoRecord`에는 `Id`, `GroupId`, `SkillLevel` 등의 정의가 있다. 따라서 런타임 이벤트에 `SkillId`나 대응 가능한 `FunctionId`가 존재한다면 Static Data를 이용해 그 이벤트를 스킬 1·스킬 2·버스트로 라벨링할 수 있다.

그러나 Static Data 자체는 이미 하나로 합산된 런타임 `Skill` 피해를 다시 쪼갤 수 없다. 다음 연결을 가진 이벤트 수준 자료가 필요하다.

```text
공격자 Csn/Tid
→ SkillId 또는 FunctionId
→ raw/actual 피해
→ 치명타 여부
→ 대상 종류(보스/파츠/투사체)
```

또한 애장품은 `FavoriteItemSkillGroupData.FavoriteSkillId`와 `SkillChangeSlot`에 따라 스킬을 교체할 수 있다. 변신·모드 전환·추가 state effect도 고려해야 한다. 특정 캐릭터는 피해 스킬이 하나뿐이라는 식의 추정 배분은 일반 해법으로 사용하지 않는다.

## 우선 분석할 다섯 가지 미해결 항목

다음 항목이 축 2의 상세 UI 범위를 결정한다.

1. **투사체 피해의 캐릭터별 귀속**
2. **파츠 파괴 보너스의 캐릭터별 귀속**
3. **캐릭터별 공식 점수 기여량**
4. **스킬 1·스킬 2·버스트 각각의 피해 분리**
5. **수정된 raw/cumulative wire 계약의 실제 클라이언트 및 재실행 acceptance**

비율로 임의 배분하거나 raw/actual 합계를 공식 기여량으로 대신하지 않는다. 이벤트 수준 귀속 근거가 없으면 `unresolved`로 유지하고 UI에도 확정값처럼 표시하지 않는다.

## 축 1 — 클라이언트 기록 영속화 설계

### 저장 원칙

- 전체 `db.json`을 다음 실행으로 복사하지 않는다. 그러면 현재 프로필 수정이나 새 revision을 과거 런타임 DB가 덮어쓸 수 있다.
- Solo Raid compatibility에 필요한 최소 상태만 추출·보존한다.
- local account, 시즌, raid snapshot, client build, profile base revision, launch UID에 묶는다.
- 원본 게임 ID를 Local Lab의 PK/FK, 외부 API, 일반 로그에 노출하지 않는다.
- 기존 profile revision을 덮어쓰지 않는다.
- 완료된 최고 기록은 후속 profile revision과 무관하게 유지한다.
- 05:00 일일 초기화는 daily counter만 초기화하고 최고 기록과 이력은 유지한다.

### 저장 시점과 순서

1. 원본 클라이언트가 종료된 것을 확인한다.
2. 해당 실행의 Epinel 서버를 정상 정지한다.
3. 완료 복구가 `db.before.bin`으로 덮어쓰기 전에 Solo Raid 최소 상태를 추출한다.
4. Git 외부 보호 staging에 pending 상태와 hash를 기록한다.
5. 기존 완료 절차가 런타임 DB와 hosts 등 transient 상태를 복구한다.
6. Control Center PostgreSQL을 사용할 수 있게 한다.
7. transaction, CAS, idempotent upsert로 상태를 영속화한다.
8. 영속화가 성공한 뒤에만 실행을 `completed`로 표시한다.

구현된 coordinator·watcher·고아 실행 복구기는 캡처 및 PostgreSQL 영속화가 확인된 뒤에만 launch context와 실행 상태를 `completed`로 전환한다. 암호화 pending은 두 terminal 문서가 기록된 뒤에만 삭제한다. terminal 기록 뒤 cleanup이 실패하면 pending을 남기므로 결과를 잃지 않고 exact replay할 수 있다. rollback은 active pointer, pointer contract/run root, `db.before.bin`, 복원 후 SHA-256을 모두 증명한 경우에만 성공으로 인정한다. 증명이 하나라도 없거나 watcher handoff가 완료되지 않으면 상태를 `started`로 유지해 다음 실행을 fail closed하고, Admin 시작 시 active pointer 또는 pending/capture/persistence evidence를 회수한다. watcher process 생성 직후에는 coordinator가 mutable runtime ownership을 넘겨 같은 DB와 hosts를 동시에 복구하지 않는다.

### 다음 실행에 적용

1. 현재 선택된 profile revision으로 새로운 런타임 profile을 materialize한다.
2. 같은 account/season/build/raid snapshot에 속한 Solo Raid 상태만 merge한다.
3. 다른 profile 필드는 건드리지 않는다.
4. hash, length, binding, state version을 확인한 뒤 fail closed로 적용한다.

부분 진행 중인 1~4덱 세션은 동일 account와 동일 profile base revision에서만 재개한다. revision이 다르면 조용히 버리거나 강제로 이어 붙이지 않고 명시적 mismatch로 중단한다.

### 구현된 저장 모델

`V0013__phase_d_classic_solo_raid_runtime_state.sql`은 adapter-private aggregate, immutable revision, idempotent operation ledger를 추가한다.

논리 키와 메타데이터:

- Local Lab account UUID
- season key
- state schema version
- client build identity
- raid snapshot identity
- profile base revision
- launch UID
- opaque payload의 SHA-256와 byte length
- 생성·갱신 시각
- pending/applied/quarantined operation 상태

compatibility payload는 원본 ID를 domain column으로 풀어내지 않고 AES-GCM으로 보호한 제한된 opaque `BYTEA`로 보관한다. account revision set, 시즌, 실제 raid snapshot, client build와 executable hash를 인증된 associated data에 포함한다. payload는 일반 API·로그·Git 산출물에 노출하지 않는다.

기존 `V0007`의 `challenge_run`을 그대로 재사용하기는 어렵다. 해당 모델은 미리 선언된 Local Lab `SquadRevision`을 전제로 하지만, 실제 스쿼드는 사용자가 원본 게임 안에서 선택한다. 클라이언트 실행 결과에서 팀 구성을 캡처해 기록하는 별도 adapter 경계가 필요하다.

### 실패와 복구

권장 실패 코드:

- `phase_d_raid_state_capture_failed`
- `phase_d_raid_state_shape_invalid`
- `phase_d_raid_state_binding_mismatch`
- `phase_d_raid_state_persist_failed`
- `phase_d_raid_state_cas_conflict`
- `phase_d_active_raid_profile_revision_mismatch`

영속화가 실패하면 증거와 pending 상태를 삭제하지 않는다. 다음 시작 시 같은 launch UID와 request hash로 DB operation을 exact replay하고, 다른 요청이 같은 UID를 재사용하거나 stale head를 제출하면 quarantine한다. 기존 persistence receipt만으로 성공을 신뢰하지 않고 매번 DB operation 결과를 다시 확인한다. 고아 실행을 복구할 때도 rollback보다 캡처·검증·quarantine이 먼저다. 오래된 실행이 최신 기록을 덮어쓸 수 없도록 CAS와 launch ordering을 적용한다. 이미 저장된 완료 최고점보다 낮거나 비어 있는 완료 상태는 `completed_best_regression_quarantined`로 격리하고 현재 head를 유지한다.

### 2026-08-31 구현 및 오프라인 검증

- 현재 서울 raid day에 유효한 effective boot가 있으면 그 exact directory의 실제 시즌 26 snapshot을 선택한다. 현재 설치처럼 boot/directory가 아직 없을 때는 시즌 `[7,13,26,29,34,40]`을 정확히 한 번씩 포함하는 유일한 imported catalog만 허용한다. catalog가 없거나 둘 이상이면 fail closed하며 미래 예약 snapshot, 고정 fixture, selected-manager assessment UID를 snapshot identity로 사용하지 않는다.
- 새 profile을 먼저 materialize한 뒤 같은 account/season/snapshot/build에 묶인 최소 Solo Raid 상태만 복원한다.
- 완료된 최고 기록과 확정된 `1..5`덱 로그는 후속 profile revision에도 유지한다. 진행 중 open run만 동일 profile revision set에서 복원하며, 불일치하면 완료 기록은 보존하고 open run만 폐기한다.
- Epinel 종료 뒤 transient DB rollback 전에 최소 상태를 캡처하고, Git 외부 launch evidence에 AES-GCM pending과 hash receipt를 남긴다.
- watcher와 orphan recovery 모두 동일한 DB exact-replay 경로를 사용한다. receipt, pending, account, snapshot, executable, request/result hash가 모두 맞아야 완료된다.
- PostgreSQL 17 disposable cluster에서 V0013 포함 migration 13개 적용과 즉시 재적용 0개를 확인했다. 최초 advance, 동일 요청 replay, unchanged, 후속 revision, stale-head quarantine, 과거와 같은 content hash로 돌아가는 새 revision, 완료 최고점 역행 quarantine가 모두 통과했다.
- runtime materializer와 persistence project는 경고·오류 없이 빌드됐다. PowerShell 5.1 parser 3개, artifact safety 5개, migration 정적 검사 2개가 통과했다.
- 봉인 v9 baseline `db.json`을 읽는 캡처 smoke에서 원본 SHA-256은 변하지 않았고, 인증 request hash를 포함한 capture receipt와 암호화 pending만 생성됐다.
- `C:\NLL` 설치본에는 최종 fail-closed recovery 보강 application repair `8af0487d-e497-4053-ab6b-5a14f0a3bb89`로 새 Admin API, runtime materializer, orphan recovery를 반영했다. 이어진 cold-start installation smoke `e13993e3-fc59-49e9-a787-f92b81ee8000`가 계정 2개, loadable workspace 2개, candidate 값 9,080개, unresolved 0개, runtime cold 복귀를 확인했다. Admin API는 기동 시 embedded migration 전체를 checksum 검증 후 적용하므로 V0013도 이 startup gate를 통과했다. 설치 앱·materializer·orphan recovery SHA-256은 repair 영수증과 각각 exact match이며, repair와 smoke 모두 공식 `C:\NIKKE`를 수정하지 않았다.
- 후속 actual-client 실행에서 `request_json_invalid`가 관측됐으나 외부 요청 문제는 아니었다. coordinator의 미설정 watcher 시각이 빈 문자열로 직렬화되고 내부 상태 `JsonException`이 요청 오류로 마스킹된 2차 결함이었다. JSON `null` 직렬화·legacy 빈 문자열 호환·내부 상태 전용 오류 분리를 적용한 뒤 실제 차단 원인 `phase_d_raid_state_operational_binding_missing`을 확인했다.
- 설치 DB에는 raid catalog와 시즌 26 snapshot이 모두 0개였다. 봉인 StaticData의 정식 raid import를 수행한 repair `9b387312-dbc1-4826-998b-696f1924ebd3`이 catalog와 시즌 26 snapshot을 각각 정확히 1개 게시했고 boot/directory는 0개로 유지했다. DB 발급 시즌 26 snapshot UID는 `fc801119-003f-4d00-9fa0-09918b13608a`, content SHA-256은 `75e2a181e34e65246ce46fdd7d382d278d283685e1b47ac7f8da8790293166cb`이다.
- 수정된 installation smoke `4333eb70-47fc-46ad-9622-ab18135172be`는 계정 2개, loadable workspace 2개, candidate 값 9,080개, unresolved/reason 0개와 위 시즌 26 binding exact match를 확인했다. smoke는 DB를 수정하거나 게임을 시작하지 않았으며 종료 뒤 PostgreSQL·포트·임시 실행 폴더는 모두 cold/empty였다. 이 검증은 actual-client 기록 영속성 acceptance를 대신하지 않는다.
- 원본 클라이언트에서 새 5덱을 완료한 뒤 종료·재실행하는 acceptance는 아직 수행하지 않았다. 따라서 아래 인수 조건을 통과하기 전에는 축 1을 actual-client 해결 완료로 승격하지 않는다.

### 축 1 인수 조건

- 5덱을 완주한 뒤 게임을 종료하고 같은 계정으로 다시 실행한다.
- 총점, 5개 로그, 각 덱 팀 구성, 랭킹/대표 스쿼드 표시가 동일하다.
- 한 번 더 종료·재실행해도 동일하다.
- 이후 더 낮은 점수는 기존 최고 기록을 내리지 않는다.
- 이후 더 높은 점수는 정상적으로 최고 기록을 갱신한다.
- 05:00 daily reset 후 최고 기록은 남고 daily counter만 정책대로 초기화된다.
- 서로 다른 local account 사이에 기록이 섞이지 않는다.
- profile revision 변경이 Solo Raid 기록을 지우지 않고, Solo Raid 상태가 profile 값을 되돌리지도 않는다.
- 중간 crash/pending 상태를 다음 시작에서 복구할 수 있다.
- 결과 화면, Battle Records, 로비, 랭킹, DB가 위에서 확정할 점수 표면 계약과 일치한다.

## 다음 5덱 전에 추가할 측정 전용 계측

이 계측은 분석 UI 구현이 아니라 원자료 보존 장치다. 원본 응답, 공식 점수, 클라이언트 기록을 절대 변경하지 않는다.

### 필수 캡처

- `battleResult=1`인 완료 요청만 분석 집계 대상으로 채택
- 요청 순서, 덱 ordinal, route, correlation time
- 공식 덱 `Damage`
- `Team`과 캐릭터 `Slot`, `Csn`, `Tid`, `CharacterSpec`
- `BattleDuration`
- 캐릭터별 `Attack`, `Skill`, `StatFunctionAttack`의 raw/actual 피해
- 캐릭터별 가능한 count: damage, crit, miss, attack/use
- 몬스터 HP raw/actual 수신 피해
- 파츠 파괴 보너스
- 투사체 피해
- `ReportData`와 `ReportData3`의 존재 여부, 길이, hash
- `trial/setdamage` 응답의 `Info.Damage`, `User.Damage`, `TotalUserCount`, `RaidJoinCount`, `Status`
- `/soloraid/get`, `/soloraid/getranking`, `/soloraid/getrankersquad`의 점수 필드와 호출 순서
- 완료 직전·직후와 Confirm 전·후의 DB 최소 상태 및 클라이언트 화면 점수

`BattleDuration`은 초기 분석 지표로 명확히 유용하다. 자동 전투 여부, 스위치 횟수, 탄약·재장전·차지, HP·회복 등은 현재 초기 UI 요구에서 제외한다.

opaque report bytes의 내부 확인이 필요하다면 별도 결정 후 Git 외부의 보호된 `C:\NLL` evidence root에만 저장한다. 인증 정보, 헤더, 전체 요청, 공식 traffic, replay 가능한 자료는 저장하지 않는다. 저장 전 보안 경계와 payload 필요성을 다시 승인·점검한다.

## 축 2 — Control Center 상세 분석 설계

축 2는 compatibility 상태와 분리된 PostgreSQL 분석 모델을 사용한다. 원본 클라이언트의 `NetSoloRaidLog`를 변경하지 않는다.

검증 후 초기 UI에서 제공할 후보:

- 전체 공식 점수
- 덱별 공식 점수와 전체 점수 대비 비중
- 덱별 `BattleDuration`
- 캐릭터별 raw/actual 피해
- 캐릭터별 평타·전체 스킬·stat-function 구성
- 평타와 전체 스킬의 crit/damage/miss count
- 의미가 검증된 경우에만 치명타율 후보와 DPS

다음 값은 근거가 확보되기 전까지 표시하지 않는다.

- 캐릭터별 공식 점수 기여량
- 캐릭터별 투사체 피해
- 캐릭터별 파츠 파괴 보너스
- 스킬 1·스킬 2·버스트 개별 피해와 개별 치명타

raw와 actual 중 어느 값을 기본 피해 지표로 보여줄지도 새 실제 결과와의 대조 후 결정한다. 두 값을 합산하거나 하나를 공식 점수처럼 취급하지 않는다.

## 구현 전 최종 결정 게이트

- 축 1 payload의 정확한 최소 shape와 versioning
- 완료 실행과 partial 실행의 분리 저장 여부
- account/season/raid/build/profile binding의 canonical 형식
- 낮은 점수·높은 점수·동점 기록 갱신 규칙의 원본 클라이언트 일치 여부
- `ReportData3`의 실제 존재와 피해 귀속·스킬 분리에 관한 앞의 네 항목에 대한 유용성
- opaque report bytes 보존 필요성과 보안 승인
- Static Data와 런타임 이벤트를 잇는 `SkillId`/`FunctionId`의 실제 관측 가능성
- 치명타 count의 정확한 이벤트 단위

파란 점수와 노란 점수의 입력 필드 및 Common prefix 변환은 v9 wire 계약과 2026-08-31 원본 클라이언트 actual play로 해결됐으므로 더 이상 이 결정 게이트의 `unresolved` 항목이 아니다. 기록의 재실행 수명 주기와 최고 기록 갱신 규칙은 위에 남은 축 1 영속화 항목에서 별도로 다룬다.

검증되지 않은 항목은 추정값으로 채우지 않고 `unresolved` 또는 `not_applicable`로 보존한다.
