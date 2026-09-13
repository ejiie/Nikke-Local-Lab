# 공통 보스 실행 입력·호환·상태 계약

2026-09-14 P1. [통합 계획](../operations/COMMON_BOSS_EXECUTION_PLAN.md)의 공통 입력 경계다.
기존 계약을 재사용하며 새로운 wire 버전이나 별도 실행 프레임워크를 도입하지 않는다.
이 문서와 합성 검사 통과만으로 S29 실행 또는 보정 FX 전달을 활성화하지 않는다.

## 입력 책임과 기존 계약

| 책임 | 재사용할 입력 | 검증 책임 |
| --- | --- | --- |
| UI 요청 | `BossOnboardingRequest`: operation, season, catalog hash | API가 요청 신원·재시도·중복을 검증 |
| 보스의 의미 | `BossRuntimeVariantProfile` | 원본 manager/Challenge·skill/behavior·속성·QTE/FX 참조와 각 버전 shape 검증 |
| 계정/진행도 | 기존 runtime candidate, account revision, raid snapshot | 선택 revision을 고정하며 보스 추가가 계정을 새로 만들지 않음 |
| 실행 준비 | `nll/phase-d-preparation/v1`, preparation binding | 요청·profile·bundle의 일치 및 필요한 입력이 준비됐는지 판정 |
| 실행 | 기존 LaunchContext와 `nll/phase-d-runner-input/v1..v3` | 공통 생성기가 완전한 입력을 생성·검증한 뒤 봉인 |
| 선택적 FX | 기존 `executionFx` 및 별도 변경/복구 manifest | 동일 profile·weakness·실행 신원 결박과 실제 전달 증거 필요 |
| 결과/복구 | 기존 Job/완료/복구 영수증 | 게임 종료·소유 자원 복구와 게임/FX 인수 결과를 별도로 판정 |

공통 입력은 사용자 음성 값을 변경할 명령을 포함하지 않는다. 계정·실행 디렉터리·
검증/운영 정책은 명시적 입력이며 시즌 번호로 다른 부팅기를 선택하는 근거가 아니다.
새 계정 요청과 기존 계정 선택은 구분한다. 검증 계정이 필요한 경우에도 같은 실행기에
명시적으로 전달하며 보스 추가의 기본 동작으로 계정 초기화/신규 등록을 하지 않는다.

## 독립된 두 버전 축

| 축 | 현재 해석 | 유지할 경계 |
| --- | --- | --- |
| profile v1 | 기존 기본 속성 변형, 실드 없음 | 기존 봉인 profile을 그대로 읽음 |
| profile v2 | skill/behavior closure 및 선택적 속성 실드 | 형식/내용 검증 후 의미 입력으로 사용 |
| profile v3 | 현재 QTE와 FX transform 정보를 함께 표현 | 현재 지원 범위만 정확히 수락; version 숫자로 부팅을 선택하지 않음 |
| runner input v1 | 기존 실행 입력 | 과거 봉인 실행/복구 호환 유지 |
| runner input v2 | weakness가 추가된 실행 입력 | profile 버전과 독립 |
| runner input v3 | weakness, Job nonce, 선택적 executionFx | 모든 보스가 동일 수명주기로 사용 가능 |

profile의 schemaVersion/contractId는 정확한 쌍이어야 한다. profile v3를 runner v3와
동일시하거나, runner v3가 profile v3/FX의 실행 수락을 입증한다고 해석하지 않는다.
profile의 이미 존재하는 검증을 생략하거나 버전 표기를 낮춰 호환시키지 않는다.

## 공통 생성기와 결박 규칙 — P1 구현

`New-PhaseDRunnerSpecification`이 제공된 필드로 기존 wire 계약을 선택한다.

- weakness가 없고 lifecycle/FX 필드도 없으면 기존 v1, weakness만 있으면 기존 v2다.
- jobNonce 또는 executionFx가 있으면 두 필드와 weakness가 모두 있어야 한다. 누락은
  `phase_d_runner_input_invalid`이며 조용히 버리거나 v1/v2로 낮추지 않는다.
- 완전한 lifecycle 입력은 v3다. executionFx는 명시적 null일 수 있다. 이는 해당 실행에
  전달된 FX 참조가 없다는 뜻이며 profile이 요구하는 FX를 생략해도 된다는 뜻이 아니다.
- executionFx가 있으면 기존 네 필드의 shape/hash를 검증하고 profileSha256과 weakness가
  바깥 실행 입력과 정확히 일치해야 한다. 다른 보스/profile의 FX를 끼울 수 없다.
- 생성된 결과를 호출자가 나중에 v3로 바꾸던 코드를 제거했다. coordinator는 nonce와
  명시적 null FX를 생성기에 전달한다. 반환 시 이미 검증된 완전한 입력이어야 한다.
- 시즌 번호를 바꿔도 생성기·engineCode·동일 bundle의 bootstrap 선택은 바뀌지 않는다.

이 생성기는 파일/게임을 읽거나 실행하지 않는다. profile 해석·내용 검증과 준비기는
각각의 증거를 확인해야 하며, shape가 맞는 실행 입력 자체는 실행 허가가 아니다.
과거 봉인 파일은 수정하지 않는다. 새 helper는 신규 실행 구성에 봉인하며 기존 복구는
그 실행에 봉인된 helper와 증거를 사용한다.

## 변환 요구와 준비 상태

변환은 검증된 profile의 의미에 따라 선택한다. 기본 약점/속성과 같은 입력이면 불필요한
변경을 만들지 않는다. 속성 실드·QTE는 실제 관련 참조, FX는 실제 대상 자산과 필요한
transform 변경으로 결정한다. `not_required`는 근거가 있는 불필요 상태이며 `unresolved`와
다르다. 결손을 null/변경 없음으로 바꾸지 않는다.

| 기존 상태 | 의미 | 그 상태만으로 주장할 수 없는 것 |
| --- | --- | --- |
| queued/running | 자동 처리 요청/실행 중 | 산출물 검증 완료 |
| awaiting_runtime_delivery | 오프라인 후보 검증, 전달 준비 미완료 | 게임 시작 가능 |
| awaiting_game_validation | 전달/실행 구성이 결박됐고 사용자 검증 대기 | 전투·FX 인수 완료 |
| preparation ready | 해당 준비 계약이 확인한 입력 일치 | 실제 전투 성공 |
| failed/blocked/unresolved | 해당 단계 실패/결손 | 이전 성공값으로 대체된 성공 |

기존 completed는 그 receipt 계약이 정의하는 완료만 뜻한다. 오프라인 게시/조립의
completed를 원본 runtime 인수로 확대하지 않는다. 표시 상태는 시즌 이름이 아니라
증거에서 계산한다. 과거 상태 레코드를 일괄 rewrite하지 않는다.

## P2 이후 이관해야 하는 확인된 제약

- 일반 준비기는 여전히 profile v1/v2까지만 수락한다. v3 지원을 붙일 때 profile 검증,
  원본 참조, 실행별 변경/복구 manifest와 준비 상태를 함께 연결해야 한다.
- 별도 UserValidation 서버에 있는 profile 지원을 공통 서버로 이관해야 한다.
- `materialize-nll-shield-fx-candidate.py`는 원본 속성 전격 및 세 보정 역할을 고정한다.
  `BossRuntimeVariantProfile.ValidateV3QteAndShieldTransform`도 같은 세 역할을 고정한다.
  현재 profile v3를 모든 보스/QTE/FX 조합을 표현하는 일반 계약이라고 주장할 수 없다.
- 조립기는 QTE를 발견하면 v3 및 FX normalization을 함께 요구한다. QTE만 필요한 보스,
  FX만 필요한 보스, 다른 원본 속성과 다른 보정 대상 집합의 표현/소비를 공통으로 정리한다.
  호환 가능한 확장인지 실제 wire 변경이 필요한지는 이 실제 필드 결손을 근거로 결정한다.
- 검증용 전달 reader의 v3 한정과 별도 실행 경로는 P2~P5 이관 대상이다. 필요한 증거
  검사를 삭제하는 대신 공통 준비/전달로 옮긴다. 이번 P1은 이를 실행 가능으로 바꾸지 않는다.

## 검증

- 기존 runner 70개 검사와 별도로 세 시즌 × 다섯 약점 × 기존 wire/FX 유무 조합 60개,
  lifecycle 필드 누락 3개, 교차 profile/weakness·결손·추가 필드·잘못된 hash/nonce 6개를
  같은 생성기/검증기로 검사했다. 새 검사 69개는 PS7과 WinPS5에서 통과했다.
- 실제 coordinator 매핑을 합성 입력에 적용하는 기존 routing 4개 검사가 통과했다.
- API 상태/준비/profile 버전 focused 33개가 통과했다. S26/S29/S34 모두 오프라인 증거만
  있으면 전달 대기에 머물고, 증거 없는 게임 준비 상태 승격은 거절한다.
- 위 시즌 숫자는 일반성 합성 검사 입력이다. 실제 S34 데이터 closure나 게임 실행을
  검증했다는 뜻이 아니다. 저장소 전체 검사 결과는 해당 커밋의 로컬/Actions 로그로 확인한다.
