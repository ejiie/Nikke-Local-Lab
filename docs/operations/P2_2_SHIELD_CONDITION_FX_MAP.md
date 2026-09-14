# P2-2 속성 쉴드의 조건 출처와 표시 연결 조사

2026-09-14. 운영자는 후속 탐색의 초점을 **보스 속성 변경 시 속성 쉴드의 피해 허용 조건과
표시를 함께 일치시키는 데 필요한 정보**로 재확인했다. [행동 트리 대조](S29_BEHAVIOR_PATTERN_TRACE.md)의
전체 전투 흐름·사라짐 피해 판정 조사는 이 목적에 필요한 연결 근거로 한정한다.
이번 작업은 추가 원본 읽기와 계획 정비이며 변환 구현·설치·실게임 인수 완료가 아니다.

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
