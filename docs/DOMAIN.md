# Character build domain contract

## 개체 분리

### CharacterDefinition

특정 데이터 snapshot에서 읽은 캐릭터 정적 정의입니다. 자체 `character_uid`를 사용하며 이름·클래스·무기·속성 등의 버전 정보를 참조합니다. 원본 ID는 포함하지 않습니다.

### CharacterBuild

사용자가 이름을 붙여 관리하는 논리적 빌드입니다. 현재 revision을 가리키지만 실제 전투 입력값을 직접 소유하지 않습니다.

### CharacterBuildRevision

전투에 사용되는 불변 snapshot입니다. 수정 요청은 기존 revision을 갱신하지 않고 새 revision을 만듭니다.

전투 결과는 반드시 다음 쌍을 참조합니다.

```text
(dataset_snapshot_uid, build_revision_uid)
```

## 기본값 해소

`combat-max/v1`은 빌드 생성 정책입니다. `max`라는 문자열을 전투 시점마다 다시 계산하지 않습니다.

1. 생성 시점의 dataset snapshot을 고정합니다.
2. 캐릭터별 최대값을 조회합니다.
3. 해소한 정수·decimal 값을 revision에 materialize합니다.
4. 근거 snapshot과 default policy를 함께 저장합니다.
5. 데이터 업데이트 후 변경이 필요하면 명시적인 rebase로 새 revision을 만듭니다.

## 오버로드 write

오버로드는 장비 부위별 ordered line으로 저장합니다.

```text
(equipment_slot, line_index, option_type, exact_value, unit)
```

- 줄 추가·교체·삭제를 지원합니다.
- `exact_value`는 부동소수점이 아니라 decimal 문자열 또는 정수 스케일로 왕복합니다.
- `research` 모드는 연구용 자유 입력을 허용합니다.
- 향후 `game_legal` 모드에서 공식 타입·범위·중복 규칙을 별도로 검증합니다.
- 자유 입력이라도 타입과 단위가 불명확한 값은 warning을 남깁니다.

## 상태 표현

- `unresolved`: 필요한 데이터나 사용자 선택이 아직 없음
- `not_applicable`: 해당 캐릭터에 개념 자체가 적용되지 않음
- `invalid`: 값이 계약 또는 선택한 validation mode를 위반함
- `ready`: 전투 입력에 필요한 값이 모두 확정됨

`unresolved`와 `not_applicable`을 숫자 0으로 치환하지 않습니다.
