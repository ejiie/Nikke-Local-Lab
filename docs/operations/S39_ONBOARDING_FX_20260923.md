# 시즌 39 FX 후보 선택 실패 조사

2026-09-23. 실패 재현과 원인 확인 기록이다. 수정·설치·실게임 완료 기록이 아니다.

## 관측 및 재현

- 작업 `de08f4fc-5df0-4482-bd51-0b64e29eb73f`가 FX 확보 단계에서 실패했다.
- UI/작업의 외부 코드는 `boss_onboarding_fx_acquisition_failed`다.
- 같은 원본 discovery를 실제 `acquire-nll-boss-fx.py`의 `requested_names`에
  전달하면 `boss_profile_shield_fx_variant_not_unique`가 재현된다.
- 번들 내보내기 전에, `resolve_shield`가 속성별 FX 이름을 선택하면서 실패한다.
- S39에서 수집한 QTE 원본 속성은 전격 한 종류다. 이번 실패 지점은 S42의
  `require_v3_qte` 검사와 다르다.

## 이름 판별의 결손

`materialize-nll-boss-runtime-profile.py`의 `semantic_stems`는 `fx_` 다음
한 구간만 제거한다. S39 원본에서 얻은 의미 문자열은 `island_immune_barrier`로
남고, 공통 실드 후보는 `immune_barrier`다. 두 문자열의 완전 일치 조건 때문에
공통 후보가 선택되지 않는다.

| 보스 속성 | 동일 이름 계열 후보 | 현재 조건의 공통 후보 | 별도 확인한 공통 immune-barrier 후보 |
| --- | ---: | ---: | ---: |
| 작열 | 0 | 0 | 1 |
| 수냉 | 0 | 0 | 1 |
| 풍압 | 0 | 0 | 1 |
| 전격 | 1 | 0 | 1 |
| 철갑 | 0 | 0 | 1 |

즉 이번 `not_unique`는 중복이 아니라 후보 0개를 뜻한다. 공통 함수 테이블에
후보가 없는 문제도 아니다. 다만 후보가 존재한다는 사실만으로 원본과 크기·구조가
호환된다고 판정하지 않는다. 후보 선택 수정 이후에도 기존 자산 결박·실드 크기·
변경 범위·5속성 구성 검사가 필요하다.

이 이름 분리와 공통 후보 완전 일치 조건은 Git 기록상 `c05fc1c` (PR #12),
2026-09-08 21:40:24 KST부터 현재까지 그대로다. 최근 S42 조사에서 추가한 조건이
아니다. 그렇다고 공통 파이프라인이 모든 보스를 지원한다는 뜻은 아니다.

## 범위 정정

S39와 S42는 둘 다 미해결이지만 실패 단계가 다르다. S42 원본/QTE만의 문제로
전체 추가 실패를 설명할 수 없다. S39는 기존 공통 FX 선택기의 입력 이름 처리
범위가 부족한 사례로 확인했다. 시즌 번호 예외나 검증 생략으로 해결하지 않는다.

제품 코드·활성 설정·설치본은 이 조사에서 변경하지 않았다.
로컬 증거는 `artifacts/season39-onboarding-20260923/reproduction.json` 및
`common-candidate-counts.json`이다. 원본 식별자가 있는 discovery는 private
자료로 유지한다.
