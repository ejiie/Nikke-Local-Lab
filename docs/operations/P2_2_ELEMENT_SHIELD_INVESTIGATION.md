# P2-2 속성 제한 패턴·실드 FX 읽기 조사와 후속 계획

2026-09-14. [공통 실행 계획](COMMON_BOSS_EXECUTION_PLAN.md)의 P2-2 ①~④ 조사 결과다.
상태는 **정적 연결·공유 범위·FX 차이 확인, 미해결 연결을 포함한 상세 계획 확보**다.
P2-2 변환 구현이나 실게임 인수 완료가 아니다. 제품 코드, profile/registry, 원본 자산,
설정, 설치본은 변경하지 않았다. 별도 로컬 진단과 문서만 작성했다.

## 1. 입력과 증거 경계

- 봉인 v6 manifest SHA-256: `148ea9ae3e6a5759fd5075c7e25a2860331affc5644043a20a2869afcff8c9db`.
- 151 원본 pack SHA-256: `6ba9b5302ff355d88a998eaec568fbe7a28ea483fe30ef84c05a68f1d3deb6bc`.
- 해당 pack의 decoded archive SHA-256: `d14690756e7e8d24cf13df50a7db62a6c932c28e7a759ba6e731fdfcf1e15a5b`.
  과거 profile의 전체 source observation hash와 혼용하지 않는다. 이번 판정에는 실제
  151 archive와 대상 행 집합을 사용했다.
- 기존 `GameData`의 명시적 로컬 pack 생성자로 서명을 확인한 뒤 필요한 테이블을
  메모리에서 읽었다. downloader/전체 초기화, DB, 게임, 서버 listener를 호출하지 않았다.
- 실제 면역 함수 3개와 QTE 5개 행의 집합 hash가 checked-in S29 profile과 일치했다.
  FX 5개 및 행동 트리 bundle은 profile의 hash로 확인했다. 원본 입력의 전후 hash가 같다.
- v6가 지정한 격리 client의 내장 Unity 파일 19개도 읽었다. 이 파일들의 hash는 이번
  관측값이며, 모든 내장 자산이 별도로 봉인 검증됐다는 의미로 확대하지 않는다.

로컬 근거: `artifacts/common-boss-execution-20260914/p2-2-inspection/run-2/`의
`pattern-analysis.json`, `asset-analysis-2.json`, `client-asset-analysis.json`, `run-status.json`.
진단 소스와 실행 wrapper는 상위 `p2-2-inspection/`에 있다. 원본 ID는 보고서/로그에
출력하지 않고 메모리 안에서 대조했다. private 자산 검색 입력에는 prefab 키만 보관한다.

## 2. S29의 실제 연결표

아래 `skill_N`, `shield_N`, `qte_N`은 이번 조사에서 부여한 순번이며 원본 게임 ID나
실행 시간 순서가 아니다. 스킬의 나열 순서를 실제 행동 순서라고 해석하지 않는다.

| 대상/진입점 | 도달한 면역 함수 | 확인된 연결 |
| --- | --- | --- |
| 본체 `MonsterRecord.PassiveSkillId` | 없음 | 본체 자체의 패시브 참조 없음 |
| 주 파츠의 passive state effect | shield_1 | 패시브의 root 함수 19개 중 하나가 직접 연결 |
| skill_16의 use 함수 | shield_1 | 직접 연결; 주 파츠 패시브와 같은 함수 |
| skill_17의 use 함수 | shield_2 | 직접 연결; 별도 짧은 면역 함수 |
| skill_26의 use 함수 | shield_3 | 직접 연결; shield_1과 같은 FX 집합 |
| 나머지 parts의 패시브 | 없음 | 파츠 총 20개 중 패시브가 있는 파츠는 주 파츠 1개 |
| QTE 5개 행 | 별도 `ElementId` | 같은 prefab 1개를 참조; 아래 함수와의 시간적 연결은 미확정 |

스킬은 30개이며 use/hurt 함수 및 state effect의 함수 목록에서 `ConnectedFunction`을
추적했다. 전체 몬스터의 동일 경로에 대한 역참조 탐색에서 결손 연결은 0개였다.
이 범위 밖의 timeline 이벤트, client 코드, 독립 자산 참조까지 감사 완료한 것은 아니다.

### 조건과 FX의 관계

| 함수 | 공통 조건 | 적용 관련 필드 | FX |
| --- | --- | --- | --- |
| shield_1 | `ImmuneOtherElement`, `FunctionValueType=Percent`, value=10000, target=`Self` | `OnSpawnMonster`, `IsCheckMonster`; 긴 duration 값 | prefab 슬롯 1개 |
| shield_2 | 위와 동일한 면역 유형·비율·target | `OnStart`; `DurationType=TimeSec`, duration 값 1 | prefab 슬롯 0개 |
| shield_3 | 위와 동일한 면역 유형·비율·target | `OnStart`; 긴 duration 값 | shield_1과 동일한 prefab 및 부착점 |

`FunctionValue`는 여기서 속성 ID가 아니라 비율 형식의 값이다. 보스 속성 변경을 이유로
이 값을 바꾸지 않는다. 이 데이터는 동적 속성 결박 해석의 근거지만 client의 실제 피해
판정까지 증명하지는 않는다. 별도 명시 속성이 고정된 패턴은 각 필드의 의미를 확인해야 한다.

**함수마다 FX 슬롯이 있어야 한다는 검사는 도입하면 안 된다.** 원본에 이미 FX 슬롯이
없는 shield_2가 있다. 운영자의 요구는 특수 패턴 전체의 속성 조건과 실드 FX를 함께
처리하라는 것이다. shield_2가 어떤 표시 중에 적용되는지, 적용/해제 순서가 무엇인지는
추가 연결 증거가 필요하다. 가까운 순번이나 같은 함수 유형만으로 shield_1/3에 붙이지 않는다.

대상 함수 폐쇄 집합에는 다른 일반 면역·피해 감소 유형도 있었다. 이름에 `Immune`이나
`Reduction`이 포함됐다는 이유로 모두 속성 제한으로 분류하지 않는다. 현재 탐색기가
특정 유형을 찾지 못했다고 곧바로 `none`으로 판정하는 방식도 일반화 시 보완해야 한다.

## 3. 공유 범위와 QTE

- 세 면역 함수는 각각 같은 모델의 몬스터 3개가 참조했다. 다른 모델 참조는 0개이고,
  해당 Challenge wave에서 spawn되는 참조 몬스터는 1개였다.
- QTE 5개 행도 각각 같은 모델의 몬스터 3개를 참조했다. 세 몬스터의 원본 속성과 QTE
  속성이 모두 일치했다. QTE 각 행에는 group 참조 1개가 있다.
- 따라서 '참조가 여러 개면 무조건 거절'은 S29 원본을 잘못 거절한다. 반대로 같은 모델이라는
  사실만으로 모든 다른 사용처의 의미가 같다고 가정하지 않는다. 실행에 포함되는 대상과
  공유 대상 집합을 별도로 결박하고, 그 밖의 소비자 영향을 검증해야 한다.
- 봉인된 행동 트리의 graph hash가 profile과 일치했다. 정적 구조에 `QuickTimeEvent`
  노드 5개, `TimelineSkill` 노드 28개가 있다. QTE 노드는 `Int32_quickTimeId`, timeline
  노드는 animation 목록을 사용한다. 노드 수 일치만으로 QTE 행과 일대일 연결을 확정하지 않는다.
- cache bundle 파일명 검색 및 선택 client의 내장 자산 19개에 대한 정확한 GameObject 이름
  검색으로 QTE prefab을 찾지 못했다. 이것은 자산 결손 판정이 아니다. 묶음 bundle 안의
  container key, catalog/동적 로딩 경로 등 이 검색이 다루지 않은 경로가 남아 있다.

현재 QTE 변환기는 선택된 행의 `ElementId`만 바꾸며 다른 serialized 필드 보존을 검사한다.
그러나 `ElementId`가 실제 QTE 피해 조건과 표시 양쪽에 어떻게 전달되는지는 미해결이다.
본체 실드용 FX를 QTE에 대입하거나 prefab geometry를 바꾸는 근거는 확보되지 않았다.

## 4. 속성별 FX 비교

동일한 원본 전격 bundle을 기준으로 기존 변환기의 대응점 탐색만 실행했다. 저장·보정은
하지 않았다. 모든 bundle에 Transform은 14개였지만, 기존 탐색기가 대응시키는 범위는
속성에 따라 다르다. 이 비교는 자산 전체 의미나 렌더링 적합성 증명이 아니다.

| 실행 보스 속성 | 기존 출처 | 대응점 수 | 값이 다른 대응점 수 | 확인된 차이 |
| --- | --- | --- | --- | --- |
| 전격 | boss_specific | 14 | 0 | 기준 원본 |
| 수냉 | boss_specific | 14 | 1 | 파괴 연출 하위 Transform의 rotation만 다름; root/anchor 동일 |
| 작열 | common | 14 | 4 | anchor 위치·scale, 파괴 연출 하위 위치/rotation/scale |
| 풍압 | common | 13 | 6 | anchor와 loop/broken state, 파괴 연출 하위 값; 일부 대응 범위 차이 |
| 철갑 | common | 14 | 4 | anchor 위치·scale, 파괴 연출 하위 위치/rotation/scale |

수냉을 '전용이므로 모든 값 동일'이라고 설명하면 틀리다. 다만 확인된 회전 차이가
의도된 색상별 파괴 연출인지 보정해야 할 차이인지는 아직 미확정이다. 차이가 있다는
이유만으로 원본 값에 덮어쓰지 않는다. 일반화된 보정은 대상에 필요한 크기·부착·표시의
일치 기준을 먼저 정하고, 보존할 색상별 연출과 구분해야 한다.

전격/수냉의 같은 prefab을 사용하는 원본 함수 후보들은 원본 부착점과 일치했다.
작열/풍압/철갑 후보는 각 6개 함수에 같은 prefab 집합이 있었고 부착점 조합은 2종이었다.
현재 변환기는 prefab 슬롯만 복사하고 **대상 함수의 기존 부착점은 유지**하므로, 후보
함수의 부착점 차이가 그대로 실행에 복사되는 버그라고 단정할 수 없다. 후보 함수의
출처와 실제 적용 대상의 부착 정책은 별도로 검증해야 한다.

## 5. 확인 결과에 따른 구현 전 상세 순서

| 순서 | 작업 | 통과 조건 |
| --- | --- | --- |
| A. 패턴 경로 보강 | 기존 discovery에 body/part/skill/QTE별 진입점과 조건·FX의 연결 근거를 보존 | 단순 함수 집합뿐 아니라 적용 대상과 연결 경로를 설명; 결손을 실드 없음으로 승격하지 않음 |
| B. S29 시간·표시 연결 해소 | 행동 트리 QTE 참조와 실제 QTE 행 연결, timeline animation과 면역 스킬의 연결, 해제 경로 추적 | shield_2의 FX 없는 구간을 원본 근거로 설명; 순번/시간 근접성으로 임의 결합하지 않음 |
| C. QTE 자산 경로 해소 | prefab 키의 실제 container/catalog/loader 경로와 속성 입력 전달 관계 확인 | 조건과 표시의 공동 변화 근거 확보; 파일명 검색 실패만으로 missing 처리하지 않음 |
| D. 공유 참조 경계 | 함수/QTE의 공유 대상과 이번 실행의 대상 범위를 결박 | 동일 보스 공유 허용 근거와 외부 영향 차단을 함께 검증; 다른 모델/다른 조건 소비자 검사 |
| E. FX 적합성 판정 | 속성별 기존 FX, 원본 부착점, anchor와 색상별 하위 연출 비교 | 재사용/필수 보정/미해결을 구분; 수냉의 rotation 및 풍압의 대응 범위 처리 근거 확보 |
| F. 공동 변환 및 검증 | 해소된 조건·참조·필요한 FX 변경을 같은 실행 입력에 결박 | 조건만/표시만 완료 불가; 허용 필드 외 변경 0; 원본 보존·왕복 검증 |

B/C/E가 미해결인 현재 상태에서는 보정 대상 목록을 자동 확대하거나 QTE 처리 완료로
표시하지 않는다. 다음 읽기 작업은 B/C이고, 그 결과로 E/F의 정확한 변경 목록을 확정한다.
wire 표현이 부족하면 필요한 연결 필드를 P2-3에서 소비자와 함께 정비한다. P2-4의 준비기
v3 허용, P3 부팅/음성, P4 실제 overlay 적용/복구, P6 실게임 인수와 구분한다.

회귀 검사는 원본처럼 일부 함수에만 FX가 있는 패턴, 재적용/해제, 동일 보스 공유/외부 공유,
body/parts/QTE의 조건·표시 불일치, 수냉 전용 FX의 연출 차이, 풍압 대응점 결손, 다섯 약점과
비전격 원본을 포함한다. 의미를 확인하지 못한 사례는 성공 fixture로 만들지 않는다.

## 6. 이번 작업의 완료 범위

- 승인된 로컬 원본의 정적 참조·역참조·행 hash 및 5속성 FX 비교 결과를 확보했다.
- 행동 트리 및 내장 자산의 읽기 결과와 검색 한계를 기록했다.
- 위 사실로 P2-2 상세 계획을 정비했다. 전체 P2-2는 진행 중이다.
- 진단용 프로그램은 별도 ignored artifacts에서만 빌드했다. 제품 변환기/실행기 변경,
  자산 변형·복제 client 추가·설치·게임 실행·설정 변경·저장소 정리 삭제는 하지 않았다.
