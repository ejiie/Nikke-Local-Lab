# 시즌 34 공통 파이프라인 실험

2026-09-15. **행동 트리·FX 자동 확보·크기 대응에 이어 등록 FX→실행 검사 연결 누락을 수정했다.**
후속 자동화·설치 상태는 아래 구현 기록을 따른다. 실게임 확인은 운영자가 담당한다.
작업 상태의 권위는 [공통 실행 계획](COMMON_BOSS_EXECUTION_PLAN.md)이다.

## 요구와 범위

운영자는 S26/S29에서 정비한 공통 파이프라인을 시즌 34로 시험하도록 지시했다.
게임 실행은 운영자가 담당한다. 추가 32.4초 시작 지연 조사는 후속으로 미뤘다.
이번에는 시즌별 부팅·음성·종료 예외를 추가하지 않았다.

설치 앱의 `FilesystemBossOnboardingService.StartAsync`를 호출하고, 실행 중인 앱의
기존 worker가 같은 영속 job queue를 처리하게 했다. HTTP 요청이나 UI 버튼 클릭을
수행했다고 주장하지 않는다. 별도 job 파일을 만들어 통과시키지 않았다.

- 대상: S34 앨트루이아 [Z.E.U.S.], 원본 보스 속성 전격, 기본 약점 철갑.
- 실제 job: `a0c2d52a-25b9-4d0a-bea2-8902b4c3014c`.
- 요청 2026-09-15 18:11:38 KST, 실패 18:11:56 KST.
- UI 결과 `boss_pipeline_failed`, worker 내부 결과 `boss_onboarding_behavior_closure_not_unique`.
- 실패 job은 보존했다. registry에는 S34를 publish하지 않았다.

## 확인한 결손

### 1. 원본의 비활성 행동 노드까지 일괄 거절

원본 행동 트리 참조는 하나이며 정확히 하나의 자산에 연결된다. 원본 시작 노드는 활성이고,
전체 typed node 341개 중 6개가 비활성이다. 두 개는 `DetachedTasks` 안에 있다.
341은 전체 직렬화 그래프의 집계이며 실제 실행되는 노드 수가 아니다.

기존 inspector와 profile assembler는 비활성 노드가 하나라도 있으면 거절한다.
onboarding은 inspector의 오류 출력을 버리고 성공 결과가 0개여도 ‘유일하지 않음’으로
보고한다. 실제 원인은 `boss_behavior_graph_invalid`였다.

수정 후보는 활성 시작 노드를 검사하고 비활성 자식·분리 노드를 원본 그대로 보존한다.
정확한 자산 참조·bundle hash·전체 canonical graph hash 결합은 유지한다. 실패 0개와
복수 성공도 구분한다. 후보의 합성 검사 20개가 통과했고 S34 행동 트리 검사를 통과했다.

초기 실험에서는 후보를 설치하지 않고, 설치 pipeline이 고정한 기존 pin과 byte 단위로
일치하도록 세 스크립트를 복원했다. 당시 변경 후보는
`artifacts/common-pipeline-s34-20260915/behavior-fix-candidate.patch`와 receipt로 보존했다.

**운영자의 후속 1번 착수 지시에 따라 실제 소스와 설정에 반영했다.**
`inspect-nll-boss-behavior-assets.py`는 활성 시작 노드와 정확한 원본 자산을 검사하고,
`materialize-nll-boss-runtime-profile.py`는 비활성 노드 수가 0이어야 한다는 조건을
제거했다. `invoke-nll-boss-onboarding.ps1`은 행동 검사 실패 0개와 복수 성공을 구분하고
확인된 검사 오류 코드를 유지한다. UI의 바깥쪽 일반 오류 표시는 변경하지 않았다.

- S26: 924개 노드, 비활성 0개. 이전 검사기와 새 검사기의 receipt bytes 일치.
- S29: 759개 노드, 비활성 0개. 이전 receipt bytes 및 설치된 그래프 hash 일치.
- S34: 341개 노드, 비활성 6개. 이전 검사기의 오거절 재현 후 새 검사기 통과.
  canonical graph hash `8c2347e2ab2f7f7eaa2c4e6a8c114ec0839426eaccc272592b2dca4a94a531f4` 보존.

Control Center를 정상 종료하고 세 source pin만 갱신한 새 설정을 활성화한 뒤 같은 앱을
재시작했다. 기존 job history·registry·앱 바이너리·v9 bundle·runtime selection을 보존했다.
새 설정 SHA-256은 `dd4162cdef91cb98909b47a725213228725dd3026a05eca188a404601b4a3ff5`다.

실제 설치 backend queue 재시도 job `184ff99a-dbc0-45d5-ae74-a0204267895c`는
19:08:53 KST에 요청되어 행동 receipt를 생성했다. 19:09:11 KST에 다음 조립 단계에서
멈췄으며, 같은 입력으로 `boss_profile_shield_fx_asset_not_unique`를 재현했다.
**1번 수정 직후 이 job의 실패는 2번 원본 FX 공급 결손이었다.** 후속 해결 결과는 아래를 따른다.

### 2. 필요한 원본 FX를 확보하는 단계 부재

기존 서버 cache에는 **S34 보스 원본이 참조하는 전격 FX**와 **조립기가 수냉으로 속성을
변경할 때 사용할 후보로 고른 게임 공용 FX**가 없었다. S34 원본의 수냉 변종이나
전용 수냉 FX를 발견했다는 뜻이 아니다. 조립기는 원본과 같은 계열의 목표 속성 FX를
먼저 찾고, 없으면 `globalShieldFxCandidates`의 공용 후보를 고른다(`sourceKindCode=common`).
수냉을 따로 언급한 이유는 다른 세 속성의 공용 후보와 달리 서버 cache에 없었기 때문이다.
기존 `resolve_bundles`는 파일명 검색만 하며 0개와 복수 개를 같은 오류로 보고한다.

봉인된 ResourceProbe의 embedded/inner catalog에서 실제 주소·내부 키·의존 bundle을
대조하고 outer catalog/index와 해당 chunk를 통해 두 payload를 읽었다. catalog와
index pin 및 chunk hash를 검증했다. 전체 CDB hash는 다시 읽지 않았다.

| 추출한 게임 자산과 역할 | bytes | SHA-256 |
| --- | ---: | --- |
| S34 원본 전격 FX | 1,218,944 | `028c9279ce137c964ffd9bf5a9bff4ca23b09288218a00d350570f1c69055da9` |
| 속성 변경용 공용 수냉 후보 | 1,216,496 | `27c32c990ae60a9c2d16f79595f4fb62ac22e264128d03a74d583a49e2af8953` |

추출은 진단용이며 제품 파이프라인에 자동 연결된 상태가 아니다. 기존 자산 네 개와
합쳐 6,428,664 bytes의 별도 진단 cache를 만들었다. 원본·서버 cache는 변경하지 않았다.
초기 진단은 공용 세 속성을 기존 서버 cache에서, 위 두 자산을 현재 native catalog에서
읽었다. 후속 조사에서는 원본 전격과 공용 네 속성 모두를 같은 151.8.5 native catalog와
store에서 다시 확보했다. 다섯 입력의 catalog 결합과 payload 확보는 확인했지만,
cache 우선 조회·결손 시 client 확보를 제품 파이프라인에 연결하는 작업은 남아 있다.

### 3. 크기 보정 대상은 찾지만 서로 대응시키지 못함

자산을 공급한 공통 조립기는 `boss_onboarding_shield_preparation_review_required`로
멈췄다. 원본 전격은 `reuse`, 수냉·작열·풍압·철갑은 `unresolved`였다.

| 관측 | 전격 원본 | 선택된 나머지 FX |
| --- | ---: | ---: |
| Transform | 17 | 각각 14 |
| ParticleSystem / Renderer | 10 / 10 | 각각 10 / 10 |
| 크기 보정 대상 선택 | 7개 노드, 성공 | 각각 7개 노드, 성공 |
| UseScaleHelper | 0 | 1 |
| 전체 대응기의 일치 노드 | 기준 | 각각 1개 |

즉, 쉴드 표면을 구성하는 mesh emitter 가지 자체는 모두 유일하게 찾았다. 그러나
현재 보정기는 경로에서 산출한 노드 키와 부모 키가 동일해야 하므로 대응이 성립하지 않는다.
`full_hierarchy_correspondence_unresolved` 등의 이유가 남고 파생 FX는 생성하지 않았다.
**노드 수 차이는 화면상의 쉴드 모양이나 크기가 다르다는 실게임 관측이 아니다.**
S34의 기준은 원본 전격 FX다. 수냉을 포함한 나머지 네 속성은 공용 후보의 크기 적합성·
필요한 보정을 확인해야 하며 현재 모두 `unresolved`다. S29에서 확인한 수냉·전격 재사용을
속성 이름만으로 S34에 적용하지 않는다.

### 후속 확인: S34의 속성별 원본 지원과 크기 기준

2026-09-15 읽기 전용 조사. **선택된 151.8.5 데이터·클라이언트 기준으로 전격은 S34
원본 재사용, 수냉·작열·풍압·철갑은 공용 FX에 원본 크기 입력을 반영하는 방향이 맞다.**
현재 조립기의 선택 결과뿐 아니라 원본 참조와 catalog 및 실제 bundle을 대조했다.

- S34의 `ImmuneOtherElement` 함수가 연결하는 원본 쉴드 FX는 전격 한 개다.
  전체 속성 쉴드 함수 후보 85개에서도 같은 보스 쉴드 계열은 전격만 확인했다.
- embedded/inner catalog 각각에서 S34 FX 계열 키 28개를 확인했다. 해당 속성
  쉴드 계열의 전격 주소는 하나이며 나머지 네 속성의 전용 주소는 발견하지 못했다.
  반면 네 속성의 공용 주소는 모두 존재하고 현재 client에서 각각 추출에 성공했다.
- 별도의 무색상 phase02 쉴드 자산도 있다. 정적 테이블의 문자열 참조 검사 및 S34
  행동 트리 직접 참조 검사에서는 연결을 찾지 못했고, 속성 제한 함수의 참조도 없다.
  그 역할은 `unresolved`로 보존하며 다른 속성의 전용 쉴드로 간주하지 않는다.

| 대상 | 사용할 자산 | 크기 가지의 기준 Transform localScale (x/y/z) | UseScaleHelper |
| --- | --- | --- | ---: |
| 전격 | S34 원본 재사용 | 각각 약 5.8 | 0 |
| 수냉·작열·풍압·철갑 | 각 속성 공용 FX + 원본 기준 크기 보정 | 각각 약 1.05 (보정 전) | 1 |

위 Transform은 쉴드 표면 가지와 조상으로 선택한 7개 크기 노드 중 root의 직계 자식인
유일한 기준 노드다. 수치는 화면상의 최종 반경이 아니다. helper와 하위 크기 입력도
함께 작용하므로 단순히 `5.8 / 1.05`를 곱하면 완료된다고 판정하지 않는다.
기존 cache의 공용 세 속성은 현재 client 추출본과 검사한 크기 입력이 일치했다.
이는 bundle 전체 bytes의 동일성을 뜻하지 않는다.

**원본 지원 범위와 보정 필요성은 확인했고, 네 속성의 보정 구현·설치·실게임 확인은
아직 미완료다.** 원본 쉴드가 없는 보스에 이 처리를 추가하거나, 다른 보스에도 전격만
재사용하도록 고정하는 근거로 사용하지 않는다.

## 다음 구현 순서

1. **완료:** 행동 트리 수정, 세 source pin 갱신·설정 활성화, S26/S29 회귀 및 S34 실제 queue 재검증.
2. 발견된 FX 참조에서 선택 catalog와 원본 store까지 따라가는 공통 자산 공급 단계를
   조립 앞에 연결한다. 추출은 보스 추가·입력 교체 때 하고 매 게임 실행에 넣지 않는다.
   자산 결손·중복·catalog 불일치를 구분한다.
3. 이미 선택된 쉴드 표면 7개 노드의 component·mesh·부모 역할을 대조해 유일한 대응을
   증명한다. 크기에 쓰이는 Transform/particle/helper 입력만 옮기며 목표의 색·회전·
   애니메이션·활성 상태는 보존한다. 이름이나 시즌 번호로 대응을 강제하지 않는다.
4. S26/S29 회귀 및 S34 5속성 후보·native 전달·공통 준비 검사 후, 새 설정을 봉인해
   같은 UI backend queue에서 다시 시도한다. 이후 운영자가 원본 UI와 실게임을 확인한다.

위 순서는 초기 결손 확인 때의 계획이다. 후속 구현 결과는 다음 절을 따른다.

## FX 자동화 구현·검증 — 2026-09-15

- `acquire-nll-boss-fx.py`를 보스 추가 경로에 연결했다. 기존 서버 cache를 먼저 확인하고,
  결손은 원본 함수에서 선택한 FX 이름→embedded/inner catalog의 동일 내부 키→
  의존 bundle→local chunk 순서로 확보한다. 시즌별 이름·수작업 자산 목록을 넣지 않는다.
  기존 cache의 정확한 bytes/hash는 조립 시 고정하고, 보정 대상은 native 전달 단계에서
  현재 client 원본으로 재생성·대조한다. 기존 cache를 현재 build의 원본과 같다고 단정하지 않는다.
- native에서 확보한 자산은 입력 catalog/plan과 payload hash에 결합한 별도 cache에
  완성 후 게시한다. 재요청은 이 cache를 재사용한다. 손상된 cache는 덮어쓰지 않고
  실패하며, 정상 게임 시작·종료 경로에는 확보 작업이나 전체 CDB 검증을 추가하지 않았다.
- 쉴드의 7개 크기 노드는 부모 경로 이름이 달라도 가지 구조, mesh, 보존할 크기 곡선으로
  대응한다. 중복 역할은 크기 입력이 서로 동등할 때만 허용하며, 모호하거나 mesh가 다른
  경우는 보정하지 않는다. 기존에 대응됐던 S29 경로와 recipe 정책은 유지한다.
- 실제 S34는 **전격 원본 재사용, 나머지 네 속성 보정**을 생성했다. 수냉·작열·철갑은
  기준 위치·배율·`UseScaleHelper`의 3개 필드, 풍압은 하위 위치를 포함한 4개 필드를
  변경했다. 원본의 크기 입력과 저장 후 재로딩 결과가 일치하며, 색·회전·활성 상태·
  애니메이션·음성 등 허용 범위 밖의 필드와 bytes 보존 검사를 통과했다.
- 실제 S26은 FX 확보·보정 없이 5속성 조립을 통과했다. S29는 전격·수냉 재사용과
  나머지 세 속성 보정을 유지했다. 세 보스 모두 같은 공통 실행 준비 검사 5속성을
  통과했고, S29/S34는 native 고정 배치·변경 조각 생성까지 통과했다.
- 합성 검사는 FX recipe 14개, 확보 수명주기 6개, catalog/조각 관련 56개,
  native 조립 실패·복구 경계 14개를 포함한다. 기존 행동/QTE·후보 봉인·실행 전달
  회귀와 작업 전후 8개 상위 gate도 통과했다. 새 확보 검사를 CI 양쪽 검증 작업에 연결했다.
  이전 합성 도구의 `-B` 처리 누락과 profile pin fixture 누락, 이미 지원하는 두 속성을
  거절해야 한다던 오래된 조각 검사도 현행 계약에 맞췄다.

증거: `artifacts/s34-fx-automation-20260915/`의 `candidate-26`, `candidate-29-v3`,
`candidate-34-final` 및 각 `-delivery`, `common-delivery.receipt.json`, `before-gates`,
`after-gates`에 있다. 보정 후 원본 Unity runtime에서의 시각·피해 조건 인수는 별도다.

### 설치 및 실제 등록 결과

앱을 정상 종료하고 6개 source pin과 새 catalog 도구를 반영한 pipeline 설정을 활성화했다.
설정 SHA-256은 `438253e077e5821c0e408481b0ce2c291f1c8950b97742b732d7d92e1ad211c2`,
검증된 입력은 656개다. 앱 바이너리·v9 bundle·runtime selection은 변경하지 않았다.

재시작한 설치 backend에 요청한 job `66896692-4f35-4f13-913f-afd4e4fb1dab`는
20:10:00 KST 요청→20:13:01 KST **`completed`**, 보스 운영 상태 **`enabled`**로 끝났다.
공용 세 속성은 기존 cache에서, 결손 두 자산은 client에서 자동 확보했다. 후보 조립,
5속성 정적 변환, native 조각 생성, 공통 실행 구성 생성, registry 게시까지 같은 worker가
처리했다. 약 181초는 이번 보스 등록 준비 시간이며 게임 시작 시간이 아니다.
게시 profile SHA-256은 `0eace81da5d090722eef0c59b6ac9dda6c5820e1eddc3c94b9a51ce00c42935a`다.
새 S34 항목을 제외하고 재직렬화한 registry의 hash가 작업 전과 같아 기존 S26/S29 항목의
보존도 확인했다. 게임은 실행하지 않았으며 **S34 5속성의 실제 화면·피해 조건 확인은 남았다.**

설치·등록 근거는 작업 폴더의 `apply-installation.receipt.json`, `request.receipt.json`,
`final.receipt.json`에 있다. 중간 실패·대체 실험의 불필요한 파생 bytes 약 183.6MB는
삭제했고 JSON 근거와 최종 검사·설치 입력은 보존했다.

파이프라인만 복구할 때는 앱과 게임을 정상 종료한 뒤 작업 폴더의
`install-or-restore.ps1 -Mode restore -PlanPath <작업 폴더>/installation-plan.post-publication.private.json -ExpectedPlanSha256 ee3314fabc67010a2a8a489c7f4dc90a3b0ce39eebdd95cae3b3a13ac206ef9c`
를 사용한다. 소스와 activation을 함께 복구하며 게시된 registry와 실행 구성은 보존한다.
추가 등록·파일 변경으로 pin이 달라졌다면 덮어쓰지 않고 중단한다. 원격 commit·push는 하지 않았다.

## 2026-09-15 등록 FX와 실제 실행 검사 연결 누락 수정

운영자의 실행 `0eed0103-68ec-4d4b-b32d-789a4011a3b3`은 20:20:14 KST,
S34 / 약점 `iron`(보스 전격)에서 `phase_d_boss_shield_fx_asset_closure_invalid`로 실패했다.
등록은 성공했지만 coordinator의 FX 원본 검사는 여전히 `runtime/cache`만 검색했다.
새 자동 확보기는 전격 원본·공용 수냉을 client에서 읽어 등록 후보의 `acquired-fx/`에
봉인하므로 두 파일이 이전 서버 cache에 있어야 한다는 전제는 성립하지 않는다.
이전의 3보스×5속성 **delivery 검증은 실제 coordinator 전체 준비를 대체하지 못했다.**

`Assert-PhaseDCacheArtifactIdentity`에 게시된 common delivery→candidate seal→
`acquired-fx`의 정확한 hash 연결을 전달한다. 확보 기록이 있으면 해당 seal에 들어 있는
선택 원본의 경로·길이·hash를 검사한다. 선언된 파일이 없거나 달라지면 cache로 우회하지
않고 거절한다. 확보 기록 이전의 S26/S29 구성은 기존 cache 경로를 유지한다.
보정 FX의 native 전달 검증·staging은 기존 공통 materializer가 계속 담당한다.
시즌 분기, cache 복사, 원본 client 변경, 전체 CDB 재검증을 추가하지 않았다.

운영자가 선택한 UI 처리도 반영했다. `Season 34 · …` 목록은 기본으로 닫힌
**불러오기 이력** 안에 두고, 진행 상태·완료 알림·기존 이력 데이터는 유지한다.

- coordinator의 실제 resolver 합성 검사 15건: 5속성의 cache 결손/확보 파일 사용,
  변조·길이·descriptor/seal/profile 결합·경로 이탈·누락 거절과 이전 cache 회귀.
  `verify-automation-boss-weakness-variant.ps1`에 연결해 상위 회귀에서도 실행한다.
- 설치된 S26/S29/S34 × 5약점 **15건 모두 실제 coordinator `-ValidateOnly` 통과**.
  실패 실행의 candidate/lobby 입력을 재사용하고 DB 연결은 읽기 전용으로 제한했다.
  static-data 변환·materialization·FX staging·runner 준비까지 `validated_not_started`다.
- 기존 시즌 선택 JS 7건 통과. Headless Edge에서 기본 접힘·마우스 펼침·키보드 접힘·
  상태 표시와 이력 3개 보존을 확인했다. UI 시험은 합성 이력을 사용했다.

근거: `artifacts/s34-launch-fix-20260915/`의 `coordinator-rehearsal/receipt.json`,
`ui-check.receipt.json`, `history-closed.png`, `history-open.png`와 전후 gate 기록.
coordinator는 앱이 참조하는 저장소 경로에서 갱신하고, 설치 UI는 기존 파일 hash를
확인하여 `index.html`만 백업·교체한다. 설치 확인은 `installation.receipt.json`을 따른다.
runtime selection·v9 bundle·게시 registry·pipeline activation과 앱 바이너리는 보존한다.
설치 완료 후 파일 hash 일치와 위 보존 항목을 확인했다. 전후 8개 상위 회귀 gate도
모두 통과했다. 기존 pipeline 입력 656개가 모두 일치한다(`installed-inputs.receipt.json`).
리허설의 복제 runtime/tools 30개 폴더는 검사 후 정리하고 JSON·manifest·로그는 보존했다.
해당 실행 준비 복제본은 재사용하지 않으며, 반복 검사는 새 출력 폴더에서 실행한다.
게임은 실행하지 않았으며 **실제 게임 시작과 S34 5속성 전투 인수는 운영자 확인 대기**다.
커밋·push는 하지 않는다.

## 증거와 보존

비공개 실험 자료는 `artifacts/common-pipeline-s34-20260915/`에 있다.
`request.receipt.json`, `behavior-diagnostic/disabled-summary.json`,
`fx-export/owned-export.json`, `behavior-diagnostic/size-scope.json`,
`candidate-with-assets/shield-pattern-fx-assessment.receipt.json`이 각 관측을 뒷받침한다.
원본 이름·키·자산 bytes가 있는 private 파일은 커밋하지 않는다.

후속 속성 지원 조사는 `artifacts/s34-fx-support-audit-20260915/`에 있다.
`static-support.receipt.json`, `catalog-support.receipt.json`,
`reference-support.receipt.json`, `behavior-reference.receipt.json`이 참조 범위를 기록한다.
`export.receipt.json`과 `native-size-comparison.receipt.json`이 같은 client에서 확보한
다섯 원본 입력과 크기 비교를 기록한다. 이 조사에서는 제품 코드·설치 설정·client를
변경하지 않았으며 파생 FX 생성이나 게임 실행도 하지 않았다.

실험 전 repository/Phase 0/Phase 2B(2A1·2A2 포함)/Phase 3A·3B0·3B1·3B2/Actions
계약은 모두 통과했다. 문서 반영 후 동일한 8개 상위 gate도 모두 통과했다
(`before-gates/`, `after-gates/required-gates.receipt.json`). 수정 후보 검사 20개,
기존 소스 복원 후 해당 검사 17개가 통과했다. 현행 pipeline의 입력 pin 655개와
runtime selection·bundle hash도 일치한다(`final-state.receipt.json`).
초기 실험에서는 운영 PostgreSQL이 실행 중이므로 별도 live PostgreSQL gate를 재실행하지 않았다.

후속 1번 수정 근거는 `artifacts/s34-behavior-fix-20260915/`에 있다.
`original-trees.receipt.json`, `apply-installation.receipt.json`, `final.receipt.json`이
원본 보존·설정 설치·실제 queue 재검증을 구분한다. 합성 행동/FX 검사 20개와 8개 상위
회귀 gate가 통과했다. 앱 종료 중 별도 합성 DB에서 PostgreSQL integration 114개,
runtime persistence adapter 41개도 통과했고 restart checkpoint·임시 DB 정리를 확인했다.
PG 증거는 `artifacts/stabilization/lifecycle-postgresql/f60d5fadfb4247ae876a001d32bb0214/`다.

복구는 앱과 게임을 정상 종료한 뒤 해당 작업 폴더의 `install-or-restore.ps1 -Mode restore -ExpectedPlanSha256 97c69f4103a48eb7bbb3277b1f2748d3a2e577ee27054896b6d468b82ecc7344`로
수행한다. 작업 후 다른 수정이 생기면 덮어쓰지 않고 거절한다. 복구 시 1번 오거절도 돌아온다.
원본·음성 설정·운영 계정 내용·앱 바이너리·runtime selection·bundle·registry는 변경하지
않았다. 커밋·push·게임 실행은 하지 않았다.
