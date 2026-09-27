# 속성 쉴드 기준 크기와 자동화 입력

2026-09-14. 운영자가 재확인한 목표는 **전격·수냉은 그대로 사용하고, 공용 세 속성의 쉴드를
그 기준 크기에 맞추며, 우월 코드 피해 제한을 유지하는 것**이다. 내부 계층·회전·수명·Timeline의
동일성은 별도 인수 요구사항이 아니다. 이 문서는 크기 기준과 출처를 기록한다.

## 확인한 기준

S29 전용 전격·수냉 FX를 원본 bundle에서 다시 읽었다. 두 자산의 **위치·배율·입자 크기 모듈·
크기 helper·renderer 크기 설정·mesh/bounds 참조**가 일치한다. 회전은 원본 값으로 기록하되
위 크기 입력의 동등성 hash에서는 제외했다. 이는 화면 전체나 shader의 동일성 판정이 아니다.

| 기준 위치/필드 | 전격·수냉에서 확인한 값 | 적용 범위 |
| --- | --- | --- |
| prefab root `m_LocalScale` | `(1, 1, 1)` | prefab 내부 기준 좌표계 |
| 크기 부모(anchor) `m_LocalScale` | **`(7.25, 7.25, 7.25)`** | 유지·파괴 그룹의 공통 부모 |
| anchor `m_LocalPosition` | **`(0, 1.25, 0)`** | prefab root 기준 배치 |
| `FxHelper.UseScaleHelper` | **`0`** | 크기표 사용 비활성 설정 |
| `UseWeaponScaleHelper`, `UseFocusHelper` | `0`, `0` | 추가 보조 기능 비활성 설정 |
| 유지 그룹 `m_LocalScale` | 기본 `(0.1, 0.1, 0.1)` | animation이 참조하는 그룹 |
| 유지 그룹 `m_LocalPosition` | `(0, 0, 0.5)` | anchor 기준 배치 |
| 유지 그룹 아래 branch `m_LocalScale` | `(12, 12, 6)` | 비균일 배율 |
| 유지 쉴드 mesh 입자 3개의 local scale | 각각 약 `(4.52, 4.52, 4.52)` | 개별 입자 Transform |
| 위 3개 입자의 `InitialModule.startSize` | constant `1.5`, `size3D=false` | 입자 자체 크기 |
| 위 3개 입자의 `scalingMode` | raw `0` | 부모 배율 포함 여부를 결정하는 입력 |
| 위 renderer의 `m_RenderMode` / `m_MaxParticleSize` | raw `4` / `10` | mesh 렌더링 입력; `10`을 반경으로 해석하지 않음 |

**직접적인 보스 크기 조정 기준은 anchor의 7.25 배율과 1.25 높이 오프셋이다.** 다만 이것만을
실제 쉴드 반경으로 부르지는 않는다. 위 하위 배율, 입자 크기와 원본 mesh를 함께 기준으로 보존한다.
전체 14개 Transform과 파괴 쪽의 크기 입력도 아래 참조 receipt에 기록되어 있다.

원본의 크기표에는 Huge 항목 값 `3`이 있지만 `UseScaleHelper=0`이다. 따라서 기준 크기에
무조건 `3`을 추가로 곱하지 않는다. 몬스터의 `ModelSize=Huge`를 원본 쉴드의 실제 배율이라고
대체하지도 않는다. 공용 FX의 helper가 켜져 있는 점은 후속 보정 시 중복 배율을 피할 확인 항목이다.

Unity [scalingMode 문서](https://docs.unity3d.com/ScriptReference/ParticleSystemScalingMode.html)는
Hierarchy가 부모를 포함한 배율을, Local이 자체 Transform 배율만 사용한다고 설명한다.
이는 배율 입력을 함께 보존하는 해석 근거다. 실제 client에서의 생성 이후 변경이나 화면 크기를
측정한 증거는 아니다. 이번 receipt의 좌표계는 `prefab_local`, 실제 월드 크기는 `not_measured`다.

## 출처와 연결 경로

```text
sourceAffinity.bossElementCode
  → shieldPatterns.conditions: FX가 있는 함수
  → fxPrefabSetKey + fxAttachmentKey
  → fxVariants[].mappings[].sourceFxPrefabSetSha256
  → 목표 속성의 targetFxPrefabSetSha256
  → assetBundles[]의 sha256 / byteLength
  → 원본 prefab root → anchor → 입자 Transform / ParticleSystem / renderer / mesh
```

- S29 원본 속성은 `electric`, 비교 기준은 운영자가 지정한 전용 `water`다.
  도구의 원본 선택은 `sourceAffinity.bossElementCode`에서 한다. 전격을 코드에 고정하지 않는다.
- FX가 있는 두 함수는 같은 prefab set과 부착점으로 연결된다. FX 없는 짧은 면역 함수도 별도로
  기록하며 크기 보정 대상 FX를 새로 만들지 않는다.
- 연결하는 키는 **함수의 `fxPrefabSetKey`와 mapping의 `sourceFxPrefabSetSha256`**다.
  profile 최상위의 집계 hash인 `elementShield.sourceFxPrefabSetSha256`와 혼동하지 않는다.
- `fxAttachmentKey`는 `FxTarget01/FxSocketPoint01`부터 일반·Full·Arena의 일곱 슬롯을
  순서대로 결박한 hash다. 두 FX 함수의 첫 슬롯 enum 값은 `(2, 2)`, 나머지는 0이다.
  크기 보정으로 부착 대상/socket을 바꾸지 않는다. enum의 실제 부착 Transform 행렬은 미측정이다.
- source discovery의 `sourceStaticDataSha256`는 decoded static archive hash다. 저장된
  `StaticData.pack` 파일 자체의 hash와 구분한다. 기존 profile은 자산 mapping 입력으로 사용하며
  이번 참조 생성이 profile의 설치·실행 승인을 뜻하지 않는다.

| 출처 | SHA-256 |
| --- | --- |
| 기존 profile 파일 | `e99f0f9441cf2fb110be3df69ba976756e931750c4479fb7c3b1e43ad87f1878` |
| decoded static archive | `d14690756e7e8d24cf13df50a7db62a6c932c28e7a759ba6e731fdfcf1e15a5b` |
| 원본 FX prefab set | `308e6f49d8bfa043d8bb22226f10fc711f28aed98e312bda1a573debe7b35b5e` |
| 두 FX 함수의 부착점 | `ccc4ab86f4140f5a6db2fd25bd693b51b85f69fe9a96c6dade499d41904992c4` |
| 전격 bundle / 534,632 bytes | `bebc94976943391dd031aa55a6e40103889ca3d7ca223e722ae611cce2a22315` |
| 수냉 bundle / 537,593 bytes | `5245e2dcf36fb3e28540a040b686dbec558bf16ab148e1af2d1dff68d6388e68` |
| 두 자산의 공통 크기 입력 hash | `d165b49f5a9840358cdd525df89b6d1c775c322ca69bceeb56f685f48dcb097b` |

## 재생성 및 파이프라인 사용

[`inspect-nll-shield-size-reference.py`](../../scripts/inspect-nll-shield-size-reference.py)는 읽기 전용
참조 생성기다. `--profile`, `--source-discovery`, `--cache`, `--unitypy-root`, `--output`을 받고
추가 비교 자산은 `--compare-element water`처럼 명시한다. 이 비교 인자는 해당 보스의 검증된
기준을 선택하는 입력이며, 모든 보스가 수냉 기준을 가진다고 가정하지 않는다.

출력 계약은 `nll/boss-shield-size-reference/v1`이다. 원본 profile/discovery와 추출 도구의 hash,
함수별 prefab/부착점 연결, bundle pin, node/parent hash와 크기 입력을 함께 보존한다.
원본 이름/객체 ID/포인터를 출력하지 않으며, 기존 출력 덮어쓰기나 cache 내부 출력은 거절한다.
원본 파일은 전후 hash로 확인한다. 파생 bundle은 생성하지 않는다.

최종 로컬 출력은
`artifacts/common-boss-execution-20260914/p2-2-size-reference/reference-final.receipt.json`이다.
실제 이름이 필요한 자산 resolver는 기존 private discovery를 별도로 사용한다. 역할을 표시한
위 표의 root/anchor/유지 그룹은 설명용 이름이며, 미래 소비자가 원본 이름이나 형제 순서만으로
객체를 선택하는 규칙으로 사용하지 않는다.

후속 자동화는 이 **크기 참조**와 공용 목표 자산을 받아 필요한 배율만 보정한다. 목표 색상과
연출은 유지한다. 유지 그룹의 기본 0.1 배율은 재생 입력이기도 하므로, 실제 유지 구간은
기존 조사에서 연결한 root Director → Timeline → Animator → clip을 참조한다. 재생 길이·
회전·수명을 원본과 같게 만드는 작업을 추가 인수 조건으로 삼지 않는다.

다음 확인은 세 공용 FX가 이 기준 크기를 재현하는지다. 실제 게임에서는 동일한 보스·부착점·
카메라와 쉴드 유지 상태에서 전용 기준과 비교하고 우월 코드 피해 제한을 확인한다. 화면 지름,
부착 후 월드 배율과 runtime의 동적 변경은 이번 정적 기준값과 구분해 기록한다.

## 세 공용 속성의 크기 보정 결과

2026-09-14 후속 구현. 공통 recipe 정책을 `source_shield_size_candidate/v2`로 갱신했다.
쉴드 mesh 입자만으로 구성된 유일한 branch와 root까지의 부모를 찾아 **7개 노드의 크기 입력**을
대조한다. 전체 prefab의 파괴 연출 계층이 같아야 한다는 이전 조건은 크기 보정에서 제거했다.
선택 부분의 대응과 mesh는 검증하며, 결손·중복·다른 mesh를 배율 복사로 통과시키지 않는다.
보스/속성별 하드코딩이나 고정 node hash로 대상을 고르지 않는다.

| 목표 속성 | 원본 대비 변경 | 검산 결과 |
| --- | --- | --- |
| 작열 | anchor 배율 `1.05 → 7.25`, 높이 `0.2 → 1.25`, `UseScaleHelper: 1 → 0` | 3개 필드 변경; 선택 크기 입력 일치 |
| 풍압 | 위 3개 + 유지 그룹 z 위치 `0.49999988 → 0.5` | 4개 필드 변경; 선택 크기 입력 일치 |
| 철갑 | 작열과 같은 3개 필드 | 선택 크기 입력 일치 |
| 전격·수냉 | 변경 없음 | 원본 bundle byte/pin 재사용 |

하위 쉴드 배율·입자 크기·mesh는 이미 기준과 같았다. 비활성화된 helper의 크기표도 덮어쓰지
않았다. 풍압의 root 직속 입자, 파괴 연출의 개별 설정, 색상·재질·회전·animation·Timeline·음성은
보존했다. 공통 부모 배율이 파괴 그룹에도 전달되는 것은 원본 구조에 따른 결과이며, 개별 파괴
입자의 크기나 수명을 전용 자산과 같게 만들지는 않는다.

실제 파생 bundle 3개는 Git 밖 `C:\NLL\RuntimeInputs\ShieldSize-20260914-v2`에 만들었다.
`recipes.receipt.json`은 원본/목표/파생 pin, 선택 노드, 변경 필드의 전후 hash, 보존 경계 hash를
담는다. 기존 공통 조립기가 사용하는 `prepare → deliver → verify_delivery`로 생성하고 원본에서
재생성해 대조했다. UnityPy의 메모리 typetree 캐시에 기대지 않고 저장 후 재로딩한 byte를 검산한다.
작업 receipt는 `artifacts/common-boss-execution-20260914/p2-2-three-element-size/candidate-check.receipt.json`이다.

이번 변경은 FX 크기에 한정된다. 기존 `ImmuneOtherElement` 조건, Body/parts의 연결, QTE
`ElementId`와 ElementTable의 우월 코드 관계는 수정하지 않았다. 크기 보정으로 피해 판정을
새로 구현하거나 전체 속성 피해를 허용하지 않는다. **실게임 우월 코드 피해 제한과 화면 크기는
아직 미검증**이며, 다음은 P2-3에서 이 공통 recipe를 실행 구성/전달에 연결하는 작업이다.
현재 설치본에는 적용하지 않았다. 과거 v3 전용 Transform 후보를 이번 결과 대신 소비하지 않는다.
