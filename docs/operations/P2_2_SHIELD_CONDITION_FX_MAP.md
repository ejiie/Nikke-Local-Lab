# P2-2 속성 쉴드의 조건 출처와 표시 연결 조사

2026-09-14. 운영자는 후속 탐색의 초점을 **보스 속성 변경 시 속성 쉴드의 피해 허용 조건과
표시를 함께 일치시키는 데 필요한 정보**로 재확인했다. [행동 트리 대조](S29_BEHAVIOR_PATTERN_TRACE.md)의
전체 전투 흐름·사라짐 피해 판정 조사는 이 목적에 필요한 연결 근거로 한정한다.
이번 작업은 추가 원본 읽기와 계획 정비이며 변환 구현·설치·실게임 인수 완료가 아니다.

후속 조사에서 **공용 FX는 Transform 외에도 크기 보조 설정과 입자 스케일 설정이 다르며,
풍압에는 기존 대응 범위 밖의 활성 입자 객체가 있음**을 확인했다. 현재 Transform 복사 검사의
성공을 FX 적합성으로 승격할 수 없다. 일반 Body 상속과 QTE 조건·표시의 실제 client 소비는
정적 입력 연결까지만 확인했으며, 소비 함수 미식별과 후속 판정 기준은 6~8절에 기록한다.

## 1. 현재 확보한 조건 → 대상 → 표시 대응표

| 패턴 | 조건 입력·적용 대상에서 확인한 사실 | 표시 연결에서 확인한 사실 | 남은 핵심 확인 |
| --- | --- | --- | --- |
| 소환 속성 쉴드 | 주 파츠 Body의 패시브에 shield_1. `ImmuneOtherElement`, `User/Self`, 비율 값이며 명시 속성 ID 필드는 아님 | shield_1의 원본 prefab 슬롯과 부착점은 앞선 5속성 FX 조사에서 결박 | 실제 허용 속성이 현재 보스 속성을 따르는지와 변환 후 기존 발생·해제 보존 |
| 일반 쉴드 동반 저지 | skill_26 → shield_3. 저지 스킬 skill_3/28은 각각 BreakObject 3개, `CancelType=BreakCol`. 실제 대상 여섯 개 모두 Body collider | shield_3은 shield_1과 같은 쉴드 FX. 저지 대상 GameObject에는 Transform·CapsuleCollider만 있음 | 일반 BreakCol의 피해 조건이 Body의 속성 제한을 상속하는지; 별도 표시 생성 경로가 추가 속성 입력을 요구하는지 |
| 별도 QuickTimeEvent | qte_1~5의 명시적 `ElementId`. 각 GroupId → collider preset 22행 → prefab index가 모두 연결됨 | 같은 QTE prefab에 39개 collider 데이터와 배경·시작·성공·실패 연출 참조. `_default`는 collider 기본값 | `ElementId`가 실제 피해 허용과 속성 표시 양쪽에 전달되는 소비 경로 |

위 표의 '확인'은 원본 행·자산 참조의 대조다. `ImmuneOtherElement`의 현재 보스 속성 상속이나
QuickTimeEvent `ElementId`의 client 소비까지 실행 검증한 것으로 확대하지 않는다.
serialized 자산에서 속성 필드를 찾지 못했다는 사실도 '속성 처리 불필요'의 근거로 사용하지 않는다.

## 2. 일반 저지는 QuickTimeEvent 행과 다른 입력 경로

- skill_3과 skill_28의 `MonsterSkillRecord`에는 각각 서로 다른 BreakObject 이름 3개가 있다.
- 각 이름은 확보한 모델 bundle에서 GameObject 하나에 정확히 대응한다. 해당 객체의
  컴포넌트는 Transform과 CapsuleCollider다. 독립적인 FX renderer는 이 객체들에 없다.
- 여섯 Collider가 모두 `MonsterPartsPrefabData._colliderDatas`에 있으며 `PartsType=Body`로
  결박된다. 이 Body는 정적 파츠 테이블의 주 파츠이자 피해 허용 대상과 일치한다.
- 두 스킬은 `CancelType=BreakCol`, `BreakObjectHpRaito=5` 원시값, 빈 ControlParts,
  ControlGauge=0, ShowBreakableTime=false, IsUsingTimeline=true다. 이 값들은 보존 대상이다.
- 모델의 `MonsterTimeLineData.aniNumberLists`에서도 두 스킬을 찾았다. 두 데이터가 같은
  `modelDirector`와 같은 PlayableAsset을 참조한다. 서로 다른 저지 대상 집합을 같은 연출로
  사용하는 구조이며, 스킬마다 별도의 QTE prefab이 있다고 추정하지 않는다.

따라서 **직접 QuickTimeEvent 행만 발견해 전체 속성 제한 저지를 조사했다고 판정하면 안 된다.**
공통 탐색기는 `MonsterSkillRecord.BreakObject`와 `CancelType`에서 일반 저지 대상을 찾고,
원본 모델의 collider/Body 소유 관계를 따라가야 한다. 다만 발견 경로가 다르다는 이유로
별도 속성 변환을 반드시 추가하는 것도 잘못이다. Body 속성 제한을 상속하는 것으로 확인되면
기존 본체 조건·쉴드 FX 변환에 연결하고 collider·시간·취소 조건을 그대로 보존한다.

## 3. QTE prefab의 실제 저장 경로와 collider preset

기존 v6 cache에는 번들 6개(행동 트리 1개, 쉴드 FX 5개)만 있었다. 이전 파일명 검색과
내장 Unity 파일의 GameObject 이름 검색은 이 QTE의 실제 저장 경로를 다루지 못했다.
이번에는 격리 client의 embedded/inner 자산 catalog에서 주소와 내부 자산 키·bundle
의존성을 연결하고 outer chunk catalog/index를 통해 실제 payload를 읽었다.

| 대상 | catalog/자산 대조 결과 |
| --- | --- |
| 모델 주소 | 두 catalog 모두 자산 항목 2개, 각각 의존성 33개. 내부 자산 키는 서로 대응하지만 bundle 의존성 전체 동일성을 주장하지 않음 |
| 모델 payload | 선택 CDB에서 한 항목을 읽었고 Unity container의 내부 키와 일치. 다른 모델 항목은 필요한 chunk가 선택 store에 없어 미해결 |
| QTE 주소 | 두 catalog의 내부 자산 키가 일치. 각각 의존성 5개. 실제 QTE bundle의 container와 대조 성공 |
| QTE 공통 참조 | preset `_default`의 외부 파일과 객체를 실제 공통 의존 bundle에 대조 성공 |

모델의 미해결 항목이 실제 선택 품질에 필요한지, 실행 실패를 일으키는지는 평가하지 않았다.
다른 설치본으로 전환하거나 다운로드·복구하지 않았다. 기존 FX 전용 resolver의 '자산 주소와
내부 키 동일, remote bundle 하나' 가정을 모델 전체 탐색에 그대로 적용할 수 없음도 확인했다.
원본 데이터별 다중 자산/의존성을 구분하는 공통 탐색이 필요하며, 실행 허용 검사를 완화할 근거는 아니다.

실제 QTE 구성은 다음과 같다.

- `QuickTimeEvent.GroupId`가 선택하는 `QTEColPresetTable` 행은 각 QTE당 22개다.
  유형은 Break 4개와 Counter 18개이며, 서로 다른 collider index 22개를 사용한다.
- `QuickTimePresetPrefabData._colliderDatas`에는 index가 중복되지 않는 39개 항목이 있다.
  원본 다섯 QTE의 22개 index가 각각 정확히 하나의 항목으로 연결된다.
- prefab collider의 필드는 `_index`, `_timeLimit`, `_colType`, `_order`, `_connect`,
  `_delayTime`, `_firstCol`, `_collider`다. QTEColPresetTable에도 별도 ElementId 필드는 없다.
- `_default`가 가리키는 자산의 클래스는 `QuickTimeColliderPrefabData`다. collider 참조는
  비어 있고 기본 필드 값은 0/빈 목록이다. **속성별 FX 모음이라고 해석하면 안 된다.**
- preset에는 `_QuickTimeBG`, `_director`, `_StartAsset`, `_SuccessAsset`, `_FailAsset` 참조가
  있다. 확보한 prefab·기본 collider 데이터에는 명시 속성 입력 필드가 발견되지 않았다.

따라서 현재 직접 확인된 특수 QTE 속성 입력은 QuickTimeEvent 행의 ElementId다.
이 값이 표시 생성에도 쓰이는지는 아직 미해결이다. 배경·결과 연출 참조가 존재한다는 것만으로
속성별 쉴드 표시까지 해소했다고 판정하지 않는다. 본체 실드 FX를 QTE prefab에 복사하거나
collider preset의 순서·시간·위치를 바꿀 근거도 없다.

## 4. 변환 목록을 확정하기 위한 다음 집중 조사

아래 항목의 후속 원본 읽기 결과는 6~8절에 있다. 동일한 필드 부재 검색을 반복하기보다,
확보한 연결·미해결 소비 지점과 FX 보정 경계를 기준으로 후속 작업을 선택한다.

1. **일반 BreakCol → Body 속성 제한 연결:** 이 경로의 피해 조건 소비 지점을 확인한다.
   현재 보스 속성/Body 쉴드 상속이면 추가 고정 속성 필드를 만들지 않는다. 별도 고정값이
   확인될 때만 그 필드를 변환 후보에 넣는다.
2. **QuickTimeEvent.ElementId → 조건·표시 연결:** 생성되는 collider/표시의 소비 지점과
   속성별 연출 참조를 확인한다. prefab의 필드 부재로 처리를 생략하지도, 임의 자산 변형을
   추가하지도 않는다. 연결이 해결될 때까지 공동 변환 완료 판정은 보류한다.
3. **본체 FX 적합성:** 이미 결박한 원본 전격과 목표 속성 후보에서 부착점·크기·표시를
   비교한다. 수냉 전용의 하위 회전 차이와 풍압의 대응 범위는 재사용/보정/미해결로 구분한다.
4. **공유 범위와 보존 검사:** 실제 변경할 조건·FX 참조를 확정한 뒤 다른 소비자 영향을
   확인한다. 일반 저지의 BreakObject/CancelType, 특수 QTE의 preset, 원본 순서·시간·해제
   동작은 속성 변경에 불필요한 변경이 없는지 검증한다.

사라짐 구간의 평타/스킬 피해 차이, 그로기 전체 의미, 이동 좌표의 상세 재구성은 현재
독립적인 우선 조사 항목에서 제외한다. 속성 쉴드 조건·표시에 영향을 주는 근거가 확인될
때만 범위를 다시 연결한다. 구현은 기존 공통 파이프라인에서 실제 패턴 입력으로 선택하며,
S29 또는 profile 버전 전용 실행 정책을 추가하지 않는다.

## 5. 근거와 한계

입력은 앞선 151 v6 pack과 profile, 기존 해시 고정 native export plan 및 catalog 도구다.
새로 읽은 bundle은 다음과 같다. 원본 자산은 커밋하지 않는다.

| 역할 | 바이트 수 | SHA-256 |
| --- | --- | --- |
| 모델 | 39636480 | `6111ee1f635b9c7ce766ab870a7b2bdc5057ccd62e5f6279875887f11b6e90b7` |
| QTE | 7774912 | `f045a779d1ec1e4840fd6e3e555d5dc57bb1b5ef4c250ae43178f207e3375f8b` |
| QTE collider 기본값 | 7744 | `b8e8bbdab4788a0f44ded423484324ce77dfbfa1c9b3cf83fb541e3bd6890f2e` |

근거는 ignored `artifacts/common-boss-execution-20260914/p2-2-inspection/` 아래에 있다.
`shield-run-1/`의 catalog 보고서, `owned-export*.json`, `shield-component-details.json`,
`qte-default-analysis.json`, `shield-asset-link-checks-2.json`과
`shield-run-3/shield-condition-inputs.json`, `condition-type-fields.json`, `run-status.json`을 함께 읽는다.
실제 v6 타입의 필드 목록에서도 QTE의 ElementId와 일반 스킬/collider preset의 별도 Element 필드
부재를 확인했다. 이전 run-2의 행 연결 결과와 일치한다.

원본 pack/설정/profile 및 catalog/index의 전후 hash를 확인했고 읽은 chunk의 digest를
검증했다. CDB 전체 파일 hash를 새로 계산한 것은 아니다. catalog는 읽기 전용 메모리 DB로
조회했고 계정 DB·게임·서버 listener는 사용하지 않았다. 연구용 진단과 ignored 자산 추출본,
문서만 작성했으며 제품 코드·설정·설치본·원본 자산을 변경하지 않았다.

## 6. 일반 저지와 QTE 소비 경로의 확인 범위

### 일반 저지

두 `MonsterTimeLineData.skillOption`이 참조하는 실제 `MonsterSkillOption.effectLists`는
모두 빈 목록이다. 해당 스킬의 별도 속성 옵션이 이 목록에 들어 있다는 근거는 없다.
실제 v6 `MonsterPartsRecord`에도 ElementId 필드는 없으며, 발견된 보스 함수 closure에는
이름에 `BreakCol`이 들어가는 함수가 없다. 이는 이미 결박한 여섯 Body collider 및 본체
`ImmuneOtherElement`와 함께 **Body 조건 상속을 검증할 후보 경로**를 좁힌 결과다.

그러나 collider 소유와 실제 피해 판정 순서는 다른 사실이다. 저지 판정이 본체의 속성 면역보다
앞서 처리되는지, 면역 판정 뒤 저지 HP가 감소하는지를 현재 자료로 확정하지 못했다.
`DmgReductionExcludingBreakCol` 같은 enum 항목의 존재/선택 closure 내 부재도 이 순서를
증명하지 않는다. 따라서 일반 저지에 새 ElementId를 만들거나, 상속 완료로 표시하지 않는다.

### QTE

원본 다섯 QTE의 ElementId → 실제 ElementTable 행을 추가 대조했다. 모두 보스 원본 속성
전격(`Electronic`)이며, 그 행의 `WeakElementId`는 철갑(`Iron`)이다. `ElementIcon` 참조도
존재하고 다섯 행의 참조 hash가 같다. **QTE ElementId는 허용 공격 속성을 직접 적은 필드라고
단정하면 안 된다.** 보스 속성, 그에 대한 약점, 화면에 사용하는 아이콘의 소비를 구분해야 한다.

현재 C# 변환기는 선택 약점에 해당하는 보스 속성 행을 구한 뒤 Monster.ElementId와
QuickTimeEvent.ElementId를 같은 목표 행으로 바꾼다. 이는 데이터 전달 사실이며, client가
그 값으로 약점 피해 허용과 표시를 함께 생성한다는 실행 증거는 아니다. ElementIcon 참조가
있다는 이유만으로 QTE가 그 아이콘을 사용한다고 판정하지 않는다. QTE prefab/preset에
고정 속성 필드가 없다는 앞선 결과도 이 소비 증명을 대신하지 않는다.

### 정적 소비 함수 탐색의 한계

동일 hash로 봉인된 151 GameAssembly를 디스크에서 읽어 확인했다. 설치된
`nikke_Data/il2cpp_data/Metadata/global-metadata.dat`는 실제 0바이트다. GameAssembly의
ASCII/UTF-16 검색에서 위 조건·QTE·저지 관련 여섯 타입/필드명은 발견되지 않았다.
`il2cpp_init` 문자열과 실행 가능한 `il2cpp` section은 있으나, 이것으로 해당 게임 메서드를
특정할 수는 없다. 확인한 기존 소스·진단 경로에서도 이를 결박할 151 메서드 매핑은 확보하지 못했다.

이는 **소비 경로가 없다는 결론이 아니라 현재 정적 자료로 소비 함수를 특정하지 못했다는 한계**다.
150 분석기의 기존 RVA를 151에 재사용하지 않았고, 게임 실행·메모리 읽기·후킹으로 확대하지 않았다.
두 질문은 `unresolved`로 유지한다. 같은 입력을 재검색한 결과를 완료 증거로 누적하지 않는다.

## 7. 목표 속성 FX 적합성의 추가 사실

다섯 원본 bundle 모두 Transform 14개, ParticleSystem/Renderer 각 10개다. 부착 함수의
기존 socket/target은 보존하면서 자산 내부의 다음 차이를 별도로 다뤄야 한다.

| 비교 축 | 전격·수냉 전용 | 작열·풍압·철갑 공용 | 판정에 미치는 영향 |
| --- | --- | --- | --- |
| anchor 로컬 위치/배율 | Y=1.25, 균일 배율 7.25 | Y≈0.2, 균일 배율≈1.05 | 같은 부착점이라도 자산 내부 크기·중심이 다름 |
| `FxHelper.UseScaleHelper` | 0 | 1 | Transform만 맞춰도 보조 크기 정책은 남음 |
| `ScaleHelper.FxSizeByValues` | 별도 크기표, 현재 helper 비활성 | 전용과 다른 크기표, helper 활성 | 실제 소비 방식까지 포함해 크기 적합성을 판단해야 함 |
| 대응되는 파괴 입자 하나의 `scalingMode` | 원시값 1 | 원시값 0 | 같은 Transform이 같은 입자 범위를 보장하지 않음 |
| 입자·렌더러 | 속성별 색상 처리 | 초기 크기·일부 회전/수명·최대 표시 크기 등 추가 차이 | 모든 차이를 오류로 간주해 원본 전격 값으로 덮어쓰지 않음 |

S29 모델의 실제 `MonsterModel.Size`는 Huge(4)이고 양쪽 크기표의 SizeType=4 항목은 3이다.
다만 이 숫자 대응만으로 실행 시 반드시 3배 확대된다고 확정하지 않는다. helper의 호출·적용
순서는 확인하지 못했다. `PoolSetting.MaxPlayCount`도 전용 2/공용 30으로 다르지만, 이 차이를
속성 쉴드 크기 보정에 포함하거나 전용 값으로 복사할 근거는 없다.

**수냉:** 전체 Transform 대응 14개와 부모 관계를 확인했고, root/anchor 및 FxHelper 설정이
전격과 같다. 입자 설정 비교에서 남은 차이는 시작 RGB와 ColorModule 활성 여부다.
대응 renderer의 수치 설정도 같으며 로컬 mesh/material payload를 함께 대조했다. 원본에서
관측된 파괴 입자 하나의 로컬 회전 차이는 유지한다. 이 결과는 **수냉 전용 자산을 변형 없이
재사용하는 후보 판정**을 지지한다. 텍스처·shader 의존성 전체나 실제 렌더링 동일성의 증명은 아니다.

**풍압:** 원본 전격의 파괴 가지 직속 입자 하나와 이름이 대응되지 않는다. 풍압의 14번째
Transform은 단순 누락 목록이 아니라 **root 직속 입자 객체**다. anchor 밖에 있고
GameObject 활성, `playOnAwake=true`, emission 활성, ParticleSystem과 Renderer를 가진다.
원본 전격의 빠진 입자와 같은 역할이라고 추정할 수 없다. anchor 배율을 복사해도 이 객체에는
그 계층 배율이 전달되지 않는다. 기존 도구의 이름 교집합 13쌍/최소 10쌍 검사는 이 객체를
검사 범위 밖에 둔 채 성공할 수 있다. 역할 근거 없이 이 객체를 삭제하거나 부모·크기를 바꾸지 않는다.

애니메이션도 비교했다. 전격/철갑은 generic binding 13개의 clip 하나, 작열/풍압은 binding
1개의 clip 하나, 수냉은 각각 13개/1개인 clip 둘을 포함한다. 이 clip들은 읽기 쉬운 curve 목록이
비어 있으나 generic binding은 남아 있다. 곡선 목록 부재를 회전/활성 상태가 변하지 않는다는
증거로 사용하지 않는다. 색상별 수명·소리·애니메이션 차이는 기본 보존 대상이다.

현재 `materialize-nll-shield-fx-transform-variant.py`는 비 Transform 객체의 byte 보존을
검증한다. 따라서 helper/particle/renderer 차이는 의도적으로 그대로 남는다. 이 검사는
변경 범위를 지켰다는 증거로 유효하지만, **목표 FX가 보스에 맞는 크기와 표시를 갖췄다는
증거로는 불충분**하다. 단순 허용 범위 확장 대신 아래 판정 단계를 먼저 둔다.

## 8. P2-2 상세 계획에 반영할 판정과 검증

1. 조건 입력에는 Body 소유 관계, 일반 저지 경로, 명시 QTE 속성 참조와 미해결 소비 여부를
   함께 보존한다. 확인되지 않은 `inheritsBody=true` 같은 값을 합성 성공값으로 저장하지 않는다.
   목표 QTE ElementId는 기존 보스 속성 행 의미를 유지하고 선택 약점 ID를 직접 대입하지 않는다.
2. FX 적합성은 부착점, 전체 활성 입자 계층, anchor, helper, 입자 스케일/크기 및 renderer를
   포함한다. 원본과 목표의 차이를 `재사용 후보 / 보정 근거 필요 / 대응 미해결`로 구분한다.
   전격은 원본 재사용, 수냉은 전용 재사용 후보, 공용 세 속성은 추가 보정 검토 대상이다.
   풍압은 anchor 밖 객체의 역할을 해결하기 전 자동 적합 판정을 보류한다.
3. 필요한 보정을 결정할 때 대상 색상·재질·소리·수명·타임라인은 기본 보존한다. 크기 helper나
   particle 속성을 변경해야 하는 근거가 확보된 경우에만 별도 허용 필드와 전후 검사를 정한다.
   고정 전격/세 속성 조건이나 profile 버전으로 이 정책을 선택하지 않는다.
4. 남은 소비 의미와 표시 인수는 동일 151 소비 코드의 직접 근거 또는 공통 실행 경로를 통한
   운영자 실게임 관측으로 확인한다. 실게임 관측 시 쉴드 활성/해제 구간의 Body와 일반 저지를
   구분하고, 선택 약점 공격·다른 속성 공격에 따른 HP/저지 진행과 표시를 함께 기록한다.
   특수 QTE도 약점 공격의 성공 진행, 다른 속성 공격의 제한, QTE 속성 표시를 함께 확인한다.
   전격 원본 및 속성을 바꾼 동일 보스로 비교하되 공격 종류·대상·패턴 상태를 고정한다.
   이 관측은 기능적 인수이며 내부 함수 호출 순서를 증명했다고 기록하지 않는다.
5. FX는 유지/파괴 두 구간의 중심·덮는 범위·색상·잔류 입자를 확인한다. 수냉의 원본 회전은
   먼저 보존한 채 인수하고, 공용 helper의 추가 배율 및 풍압 root 직속 입자를 별도로 본다.
   실행 전제 미완료 상태에서 game gate를 완화하거나 진단 전용 시즌 실행기를 만들지 않는다.

위 4~5는 후속 실행 검증 항목이며 이번에 게임을 실행한 것이 아니다. 실제 소비가 아직
미해결이므로 P2-2의 조건·FX 공동 변환 완료로 판정하지 않는다. 공유 행 경계와 원본
패턴의 발생·해제/순서/시간 보존 요구도 그대로 적용한다.

추가 근거는 같은 ignored 조사 폴더의 `consumer-run-1/consumer-evidence.json`,
`fx-suitability-components-2.json`, `fx-suitability-comparison-2.json`,
`fx-animation-coverage.json` 및 `consumer-static-1/element-size-inputs.json`이다.
메타데이터 상태·두 빈 effectLists·FX 비교는 직접 읽은 사실이고, 실행 상속·helper 적용·QTE 표시
전달은 미해결이다. 원본 파일은 전후 hash가 일치하며 새 원본 bundle 추출은 추가하지 않았다.
