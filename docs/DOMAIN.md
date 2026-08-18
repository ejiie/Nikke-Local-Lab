# Character build domain contract

## 개체 분리

### CharacterDefinition

특정 데이터 snapshot에서 읽은 캐릭터 정적 정의입니다. 자체 `character_uid`를 사용하며 이름·클래스·무기·속성 등의 버전 정보를 참조합니다. 원본 ID는 포함하지 않습니다.

### CharacterBuild

사용자가 이름을 붙여 관리하는 논리적 빌드입니다. 현재 revision을 가리키지만 실제 전투 입력값을 직접 소유하지 않습니다.

### CharacterBuildRevision

전투에 사용되는 불변 snapshot입니다. 수정 요청은 기존 revision을 갱신하지 않고 새 revision을 만듭니다.

전투 결과는 반드시 다음 쌍을 참조합니다.

    (dataset_snapshot_uid, build_revision_uid)

## 기본값 해소

`combat-max/v1`은 빌드 생성 정책입니다. `max`라는 문자열을 전투 시점마다 다시 계산하지 않습니다.

1. 생성 시점의 dataset snapshot을 고정합니다.
2. 캐릭터별 최대값과 사용자가 선택한 항목을 조회합니다.
3. 해소한 정수·decimal 값을 revision에 materialize합니다.
4. 근거 snapshot과 default policy를 함께 저장합니다.
5. 데이터 업데이트 후 변경이 필요하면 명시적인 rebase로 새 revision을 만듭니다.

## 사용자 write 축

- 캐릭터 레벨은 `explicit` 정책으로 자유 설정합니다. 빌드 factory는 임의 기본 레벨을 만들지 않습니다.
- 일반 돌파 단계와 코어 레벨은 별도 필드입니다. 기본 정책은 snapshot에서 지원하는 최대값입니다.
- 호감도, 소장품, 적용 가능한 애장품은 캐릭터별 최대값을 해소합니다.
- 장비는 `head`, `torso`, `arms`, `legs` 네 부위이며 기본 Tier 10, 강화 Level 5입니다.
- 스킬은 Skill 1, Skill 2, Burst 세 축이며 기본 Level 10입니다.

## 큐브 장착

큐브는 선택 사항이며 장착/해제를 명시적으로 구분합니다.

- 미장착: `equipped=false`, `cubeUid=null`, `level=null`
- 장착: `equipped=true`, 자체 `cubeUid`, `level=1..15`
- `combat-max/v1`에서 큐브 종류를 임의 선택하지 않습니다.
- 사용자가 큐브를 장착하면 기본 Level 15를 적용하되 언제든 다른 레벨로 새 revision을 만들 수 있습니다.
- 마지막 UI 선택을 기억해야 한다면 build가 아니라 별도 preference에 저장합니다.

## 오버로드 write

오버로드는 장비 부위별 ordered line으로 저장합니다.

    (equipment_slot, line_index, option_type, exact_value, unit)

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

`readiness`는 저장된 주장값을 그대로 신뢰하지 않고 revision state와 dataset 규칙에서 다시 계산합니다.
