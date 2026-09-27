# S29 행동 트리와 속성 제한 패턴 대조

2026-09-14. [P2-2 읽기 조사](P2_2_ELEMENT_SHIELD_INVESTIGATION.md)의 B 후속 결과다.
운영자가 설명한 전투 순서를 기존 원본 행동 트리·스킬·함수·QTE 행과 대조했다.
**정적 분기 연결은 확인했지만 client의 함수 교체 규칙, 타임라인 내부 이벤트,
피해 판정 구현까지 확인한 것은 아니다.** 제품 코드나 자산 변환은 하지 않았다.

## 1. 관찰과 조사 기준

운영자의 관찰은 다음과 같다. 독립적인 실게임 재검증 결과로 승격하지 않는다.

1. 파츠 투사체 발사 후 잡몹 소환과 속성 쉴드가 발생한다.
2. 필드의 잡몹을 모두 처치하면 소환 구간의 쉴드가 사라진다.
3. 별도 속성 쉴드·QTE 구간에서 QTE 성공 시 그로기로 전환한다.
4. 이후 보스가 사라지는 특수 저지가 있다. 평타형 피해에는 면역이고 지속딜·분배딜·순차딜
   같은 스킬류 피해는 들어간다. QTE 성공 시 복귀·그로기로 전환한다.
5. 앞서의 속성 쉴드·QTE 구간 등이 반복된다.

봉인된 v6 pack·설정과 profile을 전후 hash로 검사했다. 행동 트리는 기존 profile의
bundle hash `4adb06ddb6b325a64c536377c5f7554c26b89524af920f0bf9e4208f9935819a`와
graph hash `0a5211cdce3c95aabe33fa29d19d4a0507889630ae462913163d84047cf51abf`에 일치했다.
읽기 진단은 관리자 권한 없이 승인된 사용자 접근 권한으로 완료했다.

`skill_N`, `shield_N`, `qte_N`은 앞선 조사와 동일한 로컬 순번이다. `node_N`도 진단이
부여한 순번이며 원본 ID가 아니다. graph의 759개 Type 항목에는 Shared 변수 객체도
포함된다. 759개 모두 실행 task라고 해석하지 않는다. disabled 항목은 없었다.

## 2. 행동 트리에서 확인한 구간

| 관찰 구간 | 정적 연결 | 해석의 한계 |
| --- | --- | --- |
| 초기 투사체 | 초기 이동과 병렬인 가지에 `AttackV3`의 skill_4/5 → skill_12/13 → skill_14/15 쌍이 있음. 해당 스킬들의 `FireType=ProjectileCurveV2` | 실제 발사 파츠·소켓과 발사 프레임은 자산 연결을 더 확인해야 함 |
| 잡몹 소환 | 다음 구간의 timeline 경로에 skill_8 → skill_9 → skill_10이 있으며 모두 `FireType=Calling`. 주 파츠 패시브가 shield_1을 보유 | 소환과 쉴드의 프레임상 동시성은 미검증 |
| 일반 속성 쉴드·QTE 후보 | 초기 구간에서 skill_27 → skill_26 → 결과 분기. skill_26은 긴 shield_3을 적용. 결과 검사는 `TimelineSkill(skill_3, BooleanFailueCheck=true)`와 Inverter를 사용 | QTE 이벤트 자체는 이 노드에 직접 기록되지 않음. timeline 내부 이벤트 확인 필요 |
| 사라짐 특수 저지 후보 | 별도 `RandomSelector`의 다섯 대안 각각에 QuickTimeEvent와 병렬 위치 이동, 이후 복귀 이동·결과별 timeline이 존재 | 공간 좌표의 실제 화면 위치와 일반 공격/스킬 피해 허용 판정은 미검증 |
| 이후 반복 | 위 특수 저지 후보 뒤의 별도 `repeatForever=true` 하위 트리에 투사체·소환과 skill_1 → skill_26 → 결과 분기가 있음. 결과 검사는 skill_28 timeline | 트리 분기와 반복 범위를 확인한 것이며 모든 상황의 실행 순서를 실측한 것은 아님 |

QTE ID는 해시 대조로 원본 행과 직접 연결했다. animation은 트리의 `Shot_XX`와
`MonsterSkillRecord.SkillAniNumber`의 `ShotXX` 표기를 대응시켰다. 이 표기 대응으로
TimelineSkill 28개와 AttackV3 19개의 참조가 모두 선택 보스의 스킬에 연결됐다.
client enum 변환 구현까지 검증했다는 의미는 아니다. 스킬 배열의 순번만으로 매핑하지 않았다.

### 소환 쉴드의 유지·해제 후보

shield_1은 `OnSpawnMonster`, `StatusTriggerType=IsCheckMonster`, status 값 2,
`StatusTriggerStandard=None`, `KeepingType=Off`, `LimitValue=1`이다.
행동 트리의 초기·반복 소환 구간에는 각각 `CheckMonsterCount(min=2, max=100)`가 있고,
검사 결과에 따라 내부 변수와 파츠 복구 가지가 달라진다. 보스의 정적
`Nonetarget`과 `Functionnonetarget`은 모두 `Normal`이다.

이는 **보스 외 몬스터의 생존과 연결된 쉴드**라는 관찰에 부합하는 근거다. 그러나
IsCheckMonster의 비교 연산, 집계 대상에 보스·특수 파츠가 포함되는지, KeepingType의
조건 재평가/해제 의미는 client 코드에서 확인하지 못했다. '2는 잡몹 두 마리' 또는
'잡몹 0이면 자동 해제 확정'으로 번역하지 않는다. `CheckMonsterCount` 노드에서
shield_2로 직접 이어지는 호출도 이번 트리에서 발견되지 않았다.

### 짧고 FX 없는 함수의 역할

세 쉴드는 **동일한 비영 GroupId**를 공유한다.

| 함수 | Level | DurationValue 원시값 | FX 슬롯 | 실제 호출 위치 |
| --- | --- | --- | --- | --- |
| shield_1 | 1 | 9999999 | 1 | 주 파츠 패시브; skill_16에도 참조되지만 트리의 직접 attack/timeline 호출은 없음 |
| shield_2 | 10 | 1 | 0 | skill_17을 통해 일반 쉴드 결과 분기의 양쪽 종료 경로에서 호출 |
| shield_3 | 1 | 9999999 | 1 | 초기·반복 구간의 skill_26에서 호출 |

초기 결과 Selector의 한 가지는 Inverter로 skill_3 결과를 검사한 뒤 skill_25,
파츠 복구, skill_17 호출을 병렬로 배치한다. 다른 가지는 skill_17을 호출한다.
반복 구간도 skill_28 결과 검사 후 같은 구조를 사용한다. skill_17 호출은 총 4개이며
진단 노드 node_126/130/640/644다. shield_3 적용은 node_117/631에서 확인했다.

따라서 shield_2는 사라짐 구간의 별도 무표시 쉴드보다는 **동일 그룹의 높은 레벨·짧은
지속시간으로 기존 쉴드를 종료시키는 전환 함수 후보**다. 호출 위치까지는 확인됐지만
GroupId/Level에 따른 교체·중첩과 만료 규칙이 미검증이므로 해제 구현으로 확정하지 않는다.
duration 원시값 1도 client 단위 변환 확인 없이 1초라고 쓰지 않는다.
FX가 없다는 이유로 누락 자산을 보충하거나 이 함수를 삭제하면 안 된다.

## 3. 직접 QTE 다섯 개는 하나의 특수 구간의 대안

QuickTimeEvent 노드 node_226/254/282/310/338은 qte_1~5에 각각 직접 연결됐다.
모두 node_220의 **동일 RandomSelector 아래 다섯 자식 가지**에 있다. 다섯 QTE 행이
존재한다는 이유로 일반 쉴드까지 포함한 다섯 연속 단계를 뜻한다고 해석하면 안 된다.
이 선택기는 뒤의 지속 반복 하위 트리(node_436) 바깥에 있다.

다섯 대안은 다음 구조를 공유한다. 위치 참조는 로컬 별칭 P/Q로만 표기한다.

- QuickTimeEvent와 병렬인 다른 가지에서 P 위치로 이동한다.
- QTE task 반환 경로에 따라 결과 변수에 0 또는 1을 쓴다.
- 변수 0 경로는 Q 위치로 돌아온 뒤 skill_18 timeline을 실행한다.
- 변수 1 경로도 Q로 돌아오고 skill_25 timeline을 실행한다.
- 각 QTE 행의 속성은 원본 보스와 같고 prefab 참조도 같다. 행의 원시 시간 필드도 서로 같다.

이는 관찰된 사라짐·복귀 특수 저지와 부합한다. 다만 **task의 Success/Failure와 화면의
QTE 성공/실패가 동일한 방향이라고 가정할 수 없다.** 이 client의 QuickTimeEvent 반환
규칙과 skill_18/25 timeline 의미를 확인하기 전에는 변수 0/1을 성공/실패로 이름 붙이지 않는다.
skill_25가 일반 결과 분기와 특수 QTE의 한 결과 분기에 공통 등장한다는 점은 그로기
관찰과 대조할 추가 단서다. 이름이나 발사 유형만으로 그로기라고 확정하지 않는다.

## 4. 평타형 피해 면역은 아직 별도 조사 축

특수 구간에는 위치 이동과 파츠 상태 조정이 있지만, 선택 함수 집합과 트리에서
'일반 공격만 금지하고 지속딜·분배딜·순차딜은 허용'하는 판정을 직접 확인하지 못했다.
일반 DamageReduction과 DamageShareLowestPriority 함수는 발견됐지만 그 존재만으로
이 구간의 피해 규칙이라고 지정할 수 없다. 정적 파츠 20개 중 피해 허용 파츠는 8개이며
나머지 12개는 `IsPartsDamageAble=false`지만, 이것도 특수 구간에서의 동적 판정을 대신하지 않는다.

위치 이동/표시/충돌 대상에서 벗어나는 효과인지, 별도 피해 종류 필터인지, 둘 다인지
미해결이다. **속성 쉴드 조건과 피해 전달 방식의 제한을 합치지 않는다.** 모든 스킬 피해가
허용된다고 확대하거나 QTE ElementId 변경으로 이 제한까지 조정됐다고 주장하지 않는다.

## 5. P2-2 구현 전 남은 확인 순서

운영자의 초점 재확인과 [조건·표시 추가 조사](P2_2_SHIELD_CONDITION_FX_MAP.md)를 반영한 현행 순서다.
일반 저지는 BreakObject/BreakCol → Body collider로 연결됐고 QTE prefab의 실제 저장 경로도
확인했다. 전체 전투 흐름의 재구성보다 다음 속성 쉴드 연결을 우선한다.

1. 일반 BreakCol이 Body 쉴드의 속성 제한을 상속하는지 확인한다.
2. 특수 QuickTimeEvent.ElementId가 실제 조건·표시 양쪽으로 전달되는지 확인한다.
3. 원본/목표 속성 FX의 부착점·크기·표시 적합성과 필요한 보정만 판정한다.
4. 변환할 조건·FX의 공유 범위를 확인하고 기존 발생·유지·해제 및 저지 입력 보존을 검증한다.

skill_18/25의 그로기 의미, 사라짐 구간의 전체 피해 분류, P/Q 좌표 상세는 독립적인 우선
조사에서 제외한다. 속성 쉴드 조건·표시에 영향을 주는 근거가 나올 때만 다시 연결한다.
GroupId/Level/KeepingType도 속성 변경 후 기존 쉴드 동작을 보존하는 데 필요한 범위로 조사한다.

## 6. 로컬 근거와 검증

ignored `artifacts/common-boss-execution-20260914/p2-2-inspection/`의
`behavior-run-1/behavior-topology-2.json`이 경로·부모·자식과 해시화된 원본 참조를 보존한다.
`behavior-readable.json`은 표기 대응을 추가한 파생 자료이고,
`behavior-run-2/behavior-bindings.json`, `pattern-analysis.json`, `run-status.json`이
최종 테이블 읽기 결과다. 초기 진단의 0 참조를 행 참조로 해석하지 않도록 보완했으며
최종 결과는 0을 `not_applicable_zero`로 구분한다.

`behavior-run-2/findings-check.json`에서 QTE 5개 결박, 같은 RandomSelector의 대안 구조,
animation 47개 표기 대응, 동일 쉴드 그룹, 양쪽 종료 분기 4개 호출, 반복 범위를 검사했다.
원본 pack/설정/profile과 행동 bundle 전후 hash는 같다. 진단 실행에 게임·DB·서버 listener를
사용하지 않았고 제품 코드·설정·자산·설치본은 변경하지 않았다. 이 검사는 원본 client
실행 증거나 피해 판정 인수 검사를 대신하지 않는다.
