# BattleLog 확정 감사와 남은 근거

후속 [울트라 실전 관측](BATTLE_LOG_ULTRA_WEAPON_OBSERVATION.md)에서 실제 교체 무기·관통 4타격·샷건 코어 혼재를 확인했다. **같은 틱의 계산/적용을 역순으로 묶는 방식은 관통에서 부위를 뒤바꾼다.** 후속 표본에서는 부위·피해량까지 일치하는 유일 후보만 연결했다. 아래 최초 표본의 수치는 유지하며 모든 전투에 대한 보장으로 읽지 않는다.

2026-09-19. 통계 UI를 정하기 전에, 기존 실전 로그와 로컬 원본 정적 데이터로 확정할 수 있는 범위를 조사했다. 필드별 전체 설명은 [BattleLog 해설](BATTLE_LOG_GUIDE.md), 기존 TAB/결과창 공식과 저장 계약은 [개인별 대미지 수집](RAID_DAMAGE_CAPTURE.md)을 따른다.

후속 [사거리·무기 교체·샷건 조사](BATTLE_LOG_WEAPON_ANALYSIS.md)에서 두 참고 저장소와 로컬 152 설정을 대조했다. 기존 ChangeWeapon 5건은 전투 종료의 동일 무기 기록이며, 실제 교체 사례로 세지 않는다. 새 다단히트 전투는 운영자의 분석 요청을 기다린다.

## 이번 조사의 결론

**피해·회복·버스트·스킬·광폭화의 여러 미확정을 해소했다. 모든 내부 의미까지 확정한 상태는 아니다.** 실제 계산 결과가 기록된 필드와, 그 결과를 재현하기 위해 추정한 식을 구분해야 한다.

| 자료 범위 | 확인한 내용 |
|---|---|
| 실전 표본 | 기존에 확보한 152.8.11 솔로 레이드 Challenge 완주 1개. 현재 로컬 수집 폴더에 추가 독립 표본은 없음 |
| 전체 해석 | 168,842개 레코드, 정의 62종, 고정 필드 240개, 추가 능력치 키 12개 |
| 실제 발생 | 46종·202개 고정 필드. 16종·38개 필드는 정의만 있고 미발생 |
| 값 변화 | 발생한 202개 필드 중 72개는 값이 한 종류. 이것만으로 미확정이라는 뜻은 아니지만 다른 값의 동작 근거는 없음 |
| 대미지 계산 | 30,608건, 서로 다른 계산 인자 조합 1,009종. 동일 조합은 항상 동일한 결과 |
| 공식 식별 한계 | 계산 인자 36개 중 22개가 고정. 고정 인자의 다른 값·분기·적용 순서는 이 표본만으로 식별 불가 |

조사는 기존 파일의 오프라인 분석이다. 새 전투·클라이언트 변경·설치·DB 변경·통계 UI 구현은 하지 않았다. 솔로/유니온 요청에 같은 bytes 필드가 존재하는 사실을 다른 모드의 내부 이벤트 검증 완료로 확대하지 않는다.

## 확정 수준을 읽는 법

- **직접 확인**: 헤더/본문에 실제로 기록됐거나, 정확한 키로 로컬 원본 테이블에 연결한 사실.
- **표본 내 관계 확인**: 명시한 대상과 건수에서 전부 성립하는 관계. 다른 빌드·상황까지 일반화하지 않음.
- **강한 후보**: 근거는 있지만 오차·동일 결과의 대안·단일 사례 등으로 내부 계약을 확정하지 못함.
- **미확정**: 필요한 값이나 구분 근거가 없음. 0, false 또는 이름이 비슷한 enum으로 메우지 않음.

이 구분은 필드 전체에 단일 점수를 주기 위한 것이 아니다. 예를 들어 `sourceId`가 0이라는 사실은 직접 확인했어도, 그때 실행된 보스 스킬 이름은 미확정이다.

## 피해와 HP 반영 경로

다음 세 종류를 합산하면 같은 공격을 중복 집계한다.

```text
DamageFormula.damage   : 계산 단계의 결과
CommonHurtEvent.damage  : 공통 피해 처리 단계의 결과
OnEntityGetDamage      : 일부 경로의 수신 처리 / HP 반영
```

**`isDamageApplied=false`를 ‘피해 없음’으로 해석하면 안 된다.** false인 공통 피해 7,789건 중 7,788건이 같은 틱의 수신 사건에 공격자·대상·피해량이 일치해 연결된다. 수신 사건 쪽에서는 미연결이 0건이다. 남은 공통 피해 1건은 종류 미확정인 `Entity.kind=8` 대상이며, 단순히 마지막 프레임이 잘려서 사라진 사건도 아니다.

초기 능력치와 일반 오브젝트 HP를 읽고, 변경된 능력치 키만 갱신하면서 다음 규칙으로 HP를 재구성했다.

```text
CommonHurtEvent, isDamageApplied=true:
    HP = max(0, HP − damage)

OnEntityGetDamage:
    HP = max(0, HP − actual)

CharacterTakeHeal:
    expectedActualHeal = min(heal, max(0, MaxHP − HP))
    HP = min(MaxHP, HP + actualHeal)
```

- `CharacterTakeHeal` **12,621건 모두** `actualHeal == expectedActualHeal`이었다. 캐릭터 대상 12,599건과 종류 5 오브젝트 대상 22건을 포함한다.
- 초기 HP를 추적할 수 있던 수신 피해 **7,745건 모두** `actual == min(damage, 직전HP)`였다. 보스 7,705건·방벽 40건이다.
- 수신 피해 중 투사체 43건은 초기 HP 자료가 없어 위 상한식을 검증한 대상에서 제외했다.
- 이 HP 재구성의 성공은 아직 종류가 확인되지 않은 사건이나 다른 빌드까지 동일 처리임을 보장하지 않는다.

따라서 회복의 `heal`은 부족 HP로 제한하기 전 수치, `actualHeal`은 그 제한 뒤 유효 회복량으로 읽을 수 있다. 이 표본에서 둘의 차이는 유효 HP 증가에 쓰이지 않은 회복량이다. 시전자별 회복은 `caster`, 받은 회복은 `target`으로 나눈다.

별도의 `StatisticsTakeHeal` 5건은 초기화 틱의 종류 5 오브젝트 대상이며 `heal=actual`이다. 모두 같은 시각의 `ObjectInit`에 연결되지만 그 `hp`와 값이 다르다. **전투 중 회복 집계에 무조건 추가하거나 `CharacterTakeHeal`의 대체 값으로 쓰지 않는다.** 이 초기 통계 경로의 목적과 종류 5의 정식 이름은 미확정이다.

## 계산값과 명중 판정

같은 틱·공격자·대상의 가장 최근 미소비 계산을 공통 피해에 대응시킨 30,563쌍 중 30,439쌍은 피해가 일치한다. 나머지 124쌍은 모두 면역 플래그와 함께 공통 피해가 0이다. 틱이 다른 45건은 스킬 지연 피해이며, 22건은 동일한 값의 후보가 여러 개라 타격별 인과 연결을 유일하게 확정하지 못했다.

| 판정 | 같은 틱 대응 30,563쌍에서 확인한 관계 |
|---|---|
| 코어 | isCoreHit와 isCore가 같음. true 23,982건은 코어 계수 비중립, false 6,581건은 중립 |
| 유효 사거리 | true 10,125건은 사거리 계수 비중립, false 20,438건은 중립 |
| 브레이크 | true 75건은 breakRate 비중립, false 30,488건은 중립 |
| 치명타 | true 8,271건은 치명타 계수 비중립. false인데 비중립인 23건은 모두 면역으로 공통 피해가 0인 사건. 면역 이후 플래그와 이전 계산 계수를 구분 |

코어 두 필드가 이번에 같다는 것은 두 필드의 내부 역할이 항상 같다는 뜻이 아니다. 브레이크의 발동 조건, 관통 보유와 실제 관통 판정, 저항·무시 플래그의 전체 분기는 별도 근거가 필요하다.

## 대미지 공식: 관측 영역은 좁혔지만 완전 확정은 아님

36개 입력값을 모두 기록한 조합 1,009종 각각에서 계산 결과는 하나였다. 이 표본에서 같은 입력 조합에 추가 무작위 피해 편차가 나타나지는 않았다. 이것만으로 게임 전체의 난수 사용을 부정하지 않는다.

로컬 입력값의 합산·곱셈·정밀도·반올림 후보를 대조했다. 최종 정밀도/순서 후보 1,152종 중 최상위 후보는 다음과 같다. `Bits` 필드는 float32로 재해석한 실수이며, 아래 식은 미관측 항들을 생략한 **관측 영역 재현식**이다.

```text
base = (attack − defence)
       × damageRatio × statDamageRatio × chargeDamageRate

B = float32(1)
criticalDamageRate, coreDamageRate, burstDamageRate, bonusRangeRate 순서로:
    B = float32(B + float32(rate − 1))

extra = breakRate + addDamageRate − 1

candidate = max(1, round(
    base × B × extra
    × (1 − damageReductionRate)
    × (1 − defenceRatioRate)
    × elementRate
))
```

비교 스크립트의 `round`는 ties-to-even이다. 이 반올림 정책 자체가 원본과 동일하다고 확정한 것은 아니다. 표시된 float32 연산 외의 후보 계산은 Python의 배정밀도를 사용했다.

| 재현 결과 | 값 |
|---|---:|
| 정확히 일치한 서로 다른 입력 조합 | 978 / 1,009 |
| 정확히 일치한 계산 사건 | 30,490 / 30,608 |
| 남은 차이 | 31조합·118사건 |
| 최대 절대 오차 | 4 |
| 조합별 예측−기록 오차 | +1: 16조합, −1: 14조합, +4: 1조합 |

독립 전투로 검증한 공식이 아니라 **같은 표본으로 선택하고 평가한 후보**다. 1,009조합을 홀수/짝수로 나눈 후행 집계도 독립 검증으로 부르지 않는다. 유사한 정밀도 후보가 같은 결과를 내며, 작은 잔여 오차를 임의 보정값으로 없애지 않았다.

확보한 해석상의 개선은 다음과 같다.

- 치명타·코어·풀 버스트·사거리 계수는 각각 통째로 곱하기보다 초과분을 더한 묶음이 관측값을 잘 설명한다.
- breakRate와 addDamageRate도 초과분을 더하는 묶음으로 좁혔다.
- `defenceRatioRate`는 방어력 수치에 곱할 비율로 이름 붙이면 오해를 부른다. 이 후보에서는 최종 피해의 별도 감소 인자 `(1−값)`에 해당한다.
- 실제 대미지 집계의 권위는 기록된 원본 결과다. 후보 재계산값으로 저장된 실제 대미지를 덮어쓰지 않는다.

아래 22개는 표본 전체에서 고정값이라, 다른 값에서의 효과·순서·분기와 기본값의 보편성을 확정할 수 없다.

| 고정값 | 계산 인자 |
|---|---|
| 1 | shotCount, categoryRate, resistRate, coreShotDamageRateChange, singleBurstDamageRate, projectileDamageRate, partsDamageRate, instantAllBurstDamageRate, sequentialAttackDamageRate, penetrationDamageRate, defIgnoreDamageRate, durationDamageRate, barrierDamageRate, projectileExplosionDamageRate, stickyProjectileCollisionDamageRate |
| 0 | damageReductionValue, defIgnoreRatio, defIgnoreValue, changeDefIgnoreDamageRate, shareDamageIncreaseRate, isFixationHp, isImmuneMainHp |

float 인자의 `Bits` 접미사는 이 표에서 생략했다. 곱셈 인자가 늘 1이면 식의 어느 위치에서 곱했는지 구분할 수 없다. 값이 늘 0인 분기도 실행 결과만으로 복원할 수 없다.

## 능력치 단위와 기록 순서

`CriticalDamage / 10,000`은 캐릭터의 비중립 치명타 계산 계수 8,302건을 모두 설명했다. 직전 능력치와 맞는 8,271건 외에, 종전에 남겨 둔 **31건은 같은 틱 뒤에 출력된 StatChanged 값과 전부 일치**했다.

공격력도 직전 값과 다른 132건 중 128건은 같은 틱 뒤의 갱신과 맞는다. 보스 공격 4건은 전부 초기 공격력과 같지만, 초기값을 사용하는 정확한 경로는 아직 미확정이다. 방어력 차이 15건 중 4건은 같은 틱 갱신과 맞고, 나머지 11건은 17~73ms 떨어진 값과 대응하지만 정확한 샘플링 시점은 확정하지 못했다.

`StatDamageRatio / 10,000`은 30,608건 중 30,602건이 직전 능력치와 일치했다. 나머지 6건은 모두 보스의 계산이며, 4건은 이전 기록값과 같고 효과 원천 2건은 일치하는 능력치 기록을 찾지 못했다. 보정/샘플링 경로를 확정하기 전까지 예외로 남긴다. 해당 타격의 실제 계산 입력은 `DamageFormulaShape` 자체에 있으므로, 직전 능력치에서 다시 만들어 대체할 필요는 없다.

원본 효과 `FunctionValueType=Percent`의 대미지 405건은 모두 `damageRatio == FunctionValue / 10,000`과 실수 허용오차 0.00001 안에서 맞았다. `CriticalRatio`, `NormalCriticalRatio`, `Attention`, 피해/회복 공유 통계까지 같은 근거로 모두 확정했다고 확대하지 않는다.

## 버스트·스킬·광폭화

### 게이지

로컬 `ConfigBattleTable`의 `burst_energy_max`가 **1,000,000**이다. `BurstCharge.value / 10,000`은 게이지의 퍼센트포인트 상당량이다. value는 현재 게이지 잔량이 아니라 발생한 증가량이다.

14번의 버스트 1단계 진입 모두, 직전까지의 증가량 합은 상한 미만이고 **같은 틱에 뒤따라 출력된 충전 사건까지 포함하면 상한 이상**이었다. 로그 출력 순서가 충전 원인→단계 변경 순서와 같지 않을 수 있다.

풀 버스트 중에도 충전 사건이 기록된다. 상한 초과분·버스트 중 발생량을 모두 실제 게이지에 수용됐다고 더하면 안 된다. 현재 게이지 UI의 완전 재현과 게이지 발생 기여량은 별개다.

### 스킬 코드

원본 CharacterSkill 9개 행에 사용 92건 모두 연결했다. CharacterTable의 스킬 기준값은 1레벨 값이므로 SkillInfo.SkillLevel을 적용해 비교했다. 기존 로컬 `SkillLevelUpHelper`의 `baseSkillId + level − 1` 계산과도 대응한다.

| 로그 skillType | skillIndex | 확인한 경로 | 사용 건수 |
|---:|---|---|---:|
| 1 | 2 | CharacterTable.Skill2Id의 해당 레벨 | 11 |
| 2 | 4/5/7 | FunctionTable.UseCharacterSkillId가 호출하는 추가 스킬 정의에 연결 | 39 |
| 3 | 3 | 같은 캐릭터의 버스트 단계 전환과 순서대로 일대일 연결 | 42 |

버스트 42건의 사용 기록은 대응 단계 전환보다 68~86ms 앞섰다. 그중 35건은 기본 UltiSkillId의 레벨별 값에도 직접 대응한다. 나머지 7건을 기본값과 다르다는 이유로 버스트에서 제외할 필요는 없지만, 스킬 교체/변형의 정확한 선택 조건은 아직 미확정이다.

정적 `CharacterSkillTable.SkillType`은 SetBuff·InstallBarrier·InstantNumber 같은 실행 효과 종류이고, 위 로그 코드와 다른 체계다. 같은 숫자라는 이유로 정적 enum 이름을 붙이면 안 된다. skillType=2의 정적 호출 관계는 확인했지만 매 사용의 호출 Function 인스턴스를 유일하게 특정한 것은 아니다.

### 광폭화

`BerserkStepUp.value`는 표본에서 **누적 보스 피해 임계값**으로 확인했다. 첫 단계는 0. 나머지 8회 모두 `직전 누적 피해 < value ≤ 다음 타격 포함 누적 피해`였고 해당 타격과 전환이 같은 틱이다. value를 실제 그 시점 피해 합계나 단일 타격량으로 저장하면 잘못된 의미가 된다.

`stageLv`가 단계에 따라 변하는 사실은 확인했지만 레벨이 능력치에 적용되는 내부 위치까지 이 값만으로 확정하지 않는다.

## 그 밖에 좁힌 항목

| 항목 | 현재 판정 |
|---|---|
| 보스 sourceId | 2개 문맥 모두 0. 다른 테이블의 유효 ID를 놓친 경우가 아니라 원천 식별값이 없는 기록. 보스 공격자 식별과 원천 스킬 식별은 구분 |
| 파츠 파괴 | 2건 모두 해당 보스 모델의 MonsterPartsTable에 있는 PartsType=Weapon01과 일치. 파츠 행 ID와 혼동 금지 |
| MonsterInitResource.category1 | 모델의 CategoryType1과 다르고 MonsterGeneration과도 다름. 세대/상위 분류로 임의 명명하지 않음 |
| MonsterInitResource.category2 | 모델의 Grade=Boss와 같은 값이지만 1종의 모델뿐. enum 대응은 후보이며 CategoryType2와는 다름 |
| 자세 코드 2 | 탄약 사용 31,165건·차지 시작 130건 모두 이 상태. 사격/차지 상태라는 관측 확보 |
| 자세 코드 0 | 재장전 시작 188건에서 관측. 재장전 전용/엄폐 상태라고 단정할 수 없음 |
| summonType=9 | 제거 29건 모두 캐릭터 소유의 kind=3 개체. 보스 투사체가 아님. 정식 소환물 종류는 미확정 |
| Generic | 1001/1002는 같은 틱의 58쌍, 74000/74001은 각각 135건. 코드명 없이 구체적 행동으로 확정할 수 없음 |
| drawIndexDelta | 범위와 변동은 확인. 이름만으로 난수 시드/발사 수/프레임 수로 치환 불가 |

## 미발생 16종·38필드

이 항목은 형식과 필드 이름을 해석했지만 실제 동작이 검증됐다고 표시할 수 없다.

| 이벤트 | 고정 필드 수 |
|---|---:|
| DispelledFunction | 3 |
| ResurrectionCharacter | 3 |
| AddedCharacterDecoy | 2 |
| ChangeAutoMode | 2 |
| CharacterDead | 2 |
| MonsterDestroy | 3 |
| MonsterStun | 1 |
| MonsterSkillInterruptionEvent | 3 |
| MonsterBTInterruptionEvent | 1 |
| MonsterDash | 1 |
| MonsterJump | 1 |
| StatisticsTakeDamage | 4 |
| ArenaRoundHeader | 2 |
| FunctionDamageBasis | 5 |
| ChangedFunctionRemainTime | 3 |
| DurationValueChange | 2 |
| 합계 | 38 |

사망·부활·자동 모드 변경·저지·아레나 등의 이벤트가 이번 전투에 없었다는 것은 게임에서 쓰지 않는 필드라는 뜻이 아니다. 추가 실게임을 이번 작업의 완료 조건으로 요구하지 않는다.

## 남은 미확정과 이를 해소할 근거

| 남은 항목 | 지금 확정할 수 없는 이유 | 해소에 필요한 근거 |
|---|---|---|
| 헤더 숫자·바깥 context·TickSkip 계약 | 파싱과 관측 규칙만 있음 | 로그 작성 코드/형식 명세 또는 구분 가능한 독립 표본 |
| 전체 대미지 공식·반올림 | 31조합 오차와 고정 인자 22개 | 원본 계산 경로 또는 비중립 인자가 포함된 독립 관측. 오차를 설명하는 연산 정밀도 근거 |
| 미발생 16종 | 실제 사건 없음 | 각 사건의 실제 기록 또는 작성 구현. 필드 이름만으로 완료 처리 불가 |
| Generic·condition·hitType·arrivalType·camp 등 정식 코드 | 동일 정수의 타 enum을 연결할 근거 없음 | 로그 작성부의 enum 선언/참조 또는 원인과 코드가 대응하는 자료 |
| subId·attackNode·애니메이션 번호 | 현재 사전만으로 개별 충돌체/행동 노드 연결 불가 | 해당 행동/리소스 식별 체계와 로그 필드의 직접 연결 |
| 기본 버스트 ID와 다른 7회 | 버스트 시점은 대응하지만 정의 선택 과정 미확정 | 스킬 교체/조건부 실행 경로 |
| 공격력 4건·방어력 11건·StatDamageRatio 6건 | 보스 초기 공격력/이전 능력치와의 관계는 있으나 선택 경로가 불명확 | 해당 계산 시점의 상태 선택 규칙/작성 순서. 치명타 플래그 차이 23건은 면역 사건으로 분류 완료 |
| kind=8 미연결 피해·kind=5/6·summonType=9 | 생성·소유 관계 일부만 확인 | 개체 클래스 또는 명시적 생성 경로 |
| 보스 sourceId=0인 2문맥 | 필요한 키 자체가 기록되지 않음 | 다른 연결 자료 없이는 이 필드만으로 복원 불가 |
| 지연 피해 22건의 유일한 짝 | 동일 공격자·대상·피해량의 후보가 복수 | 인과 식별자 또는 생성/소비 구현 |
| 게이지 수용량·상한 처리 | 발생량은 있지만 실제 잔량 계약 미확정 | 충전 수용/버림/리셋 구현 또는 실제 게이지 상태 기록 |
| 표본 외 모드·버전 호환성 | 내부 로그는 현재 빌드 한 전투 | 해당 헤더·본문을 직접 해석한 근거 |

현재 로컬 클라이언트의 메타데이터 파일은 비어 있고, 이미 생성된 관리 코드 덤프/심벌 자료에서도 로그 작성 구현을 확보하지 못했다. 정적 테이블의 enum 이름만 가져와 남은 코드를 채우지 않았다. 여기에 적은 근거의 필요성은 새 후킹·주입·공식 통신 작업을 수행했다는 의미가 아니다.

## 근거와 문서 검사

원본 식별값·실계정 기록은 Git 제외 `artifacts/battlelog-capture-20260919/analysis/` 및 기존 로컬 Diagnostics 파일에만 유지한다. 이 문서는 집계된 관측과 해석을 기록한다.

| 분석 산출물 | 용도 |
|---|---|
| schema-observation.private.json / events-summary.private.json | 정의·필드·발생 건수 |
| runtime-semantics.private.json | 수신 사건 대응·능력치 대조·자세/충전 발생 경로. 초기 HP 재구성 중간 결과는 아래 closure가 대체 |
| runtime-closure.private.json | HP 재구성 최종 결과·치명타 31건의 같은 틱 갱신·게이지 임계값 |
| precision-order.private.json | 공식 후보/정밀도 탐색과 최종 오차 |
| static-links.private.json | 메모리팩 원본 테이블의 관련 행만 읽은 결과. 원본 ID 포함으로 비공개 |
| authoritative-semantics.private.json | 원본 게이지 설정·파츠·판정별 계수. 초기 스킬 그룹 추정은 아래 final-links가 대체 |
| final-links.private.json | 레벨 적용 스킬 연결·추가 스킬 호출·광폭화·미발생/고정 필드 |
| last-links.private.json | 버스트 사용 42회와 단계 전환 시점·초기 회복 5건 |
| exception-links.private.json | 치명타 차이 23건의 면역 관계·보스 초기 공격력/능력치 예외·몬스터 분류 배제 |

이 문서의 표본 한계와 수치, 전체 사전의 62종·240필드·12개 능력치 키를 대조한다. 이것은 문서/분석 검사이며 제품 실행·실게임 검증 완료의 주장은 아니다.
