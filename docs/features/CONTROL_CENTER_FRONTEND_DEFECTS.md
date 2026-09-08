# Control Center 프런트엔드 결함 기록

## 1. 문서 목적

이 문서는 2026-08-29~30 운영자 검수에서 확인한 Control Center 프런트엔드 결함을 백엔드 결함과 분리해 기록한다. 화면의 기준은 운영자가 제공한 블라블라 계정 관리·니케 도감 화면이다. `비슷한 자체 디자인`은 인수 기준이 아니며, 이후 프런트 작업은 **블라블라 화면을 그대로 복제한다는 관점**에서 진행한다.

백엔드 데이터·revision·실행 준비 상태 문제는 [CONTROL_CENTER_BACKEND_DEFECTS.md](CONTROL_CENTER_BACKEND_DEFECTS.md)에 기록한다.

## 2. 인수 기준

1. 니케 목록과 상세 화면의 시각·정보 구조는 운영자가 제공한 블라블라 화면을 기준으로 한다.
2. 이미지도 다른 공개 데이터베이스의 저해상도 대체물을 사용하지 않고 블라블라가 표시하는 고화질 소스를 사용한다.
3. 화면에 내부 UID, raw field code, JSON 또는 불명확한 generic label을 노출하지 않는다.
4. 값이 로드되지 않은 상태와 실제 값 `0`을 구분한다.
5. 한 번의 `Save`는 사용자가 보는 하나의 원자적 작업이어야 하며 저장 중 중복 입력을 받지 않는다.

## 3. 확인된 결함

### FE-001 — 블라블라 기준 미준수와 임의 이미지 소스 사용

- 심각도: 차단
- 현재 상태: 캐릭터 이미지·도감 레이아웃 수정 및 설치본 반영 완료, 운영자 시각 재검수 대기
- 관측:
  - 캐릭터 이미지는 블라블라가 아니라 공개 Nikke-DB L2D 자료에서 가져왔다.
  - 보스 이미지는 Enikk 자료를 사용했다.
  - UI는 블라블라 화면을 직접 재현하지 않고 별도의 카드 디자인으로 근사했다.
  - 현재 캐릭터 이미지는 확대 시 화질이 크게 저하된다.
- 기대:
  - 블라블라의 고화질 이미지와 화면 구성을 기준으로 presentation asset과 layout을 전면 교체한다.
  - 기존 `presentation-assets/characters` 이미지는 인수 대상으로 승격하지 않는다.
- 2026-08-30 수정:
  - 공식 블라블라 Shifty's Pad 번들의 normal-resource URL 생성 규칙을 구현했다.
  - `character/ko/nikke_list_v2.json`과 공식 `mi_image` 논리 경로를 사용한다.
  - 193명 전원을 `sg-tools-cdn.blablalink.com`의 256×512 PNG로 다시 materialize했다.
  - 이름이 같은 두 `사쿠라`는 희귀도·클래스·기업·무기군으로 결정적으로 구분한다.
  - 캐릭터 카드와 상세 화면은 블라블라의 정보 배치와 비율을 기준으로 교체했다.
  - 인증된 Shifty's Pad 화면에서 실제 사용 중인 속성·무기군·버스트·클래스·돌파·코어·탭 UI 이미지를 관측하고 25개 로컬 presentation asset으로 materialize했다.
  - 설치본에는 캐릭터 193개, UI 25개, 장비 24개, 소장품·애장품 33개 이미지를 포함했다.
  - 보스 썸네일은 아직 별도 공개 출처를 사용하므로 캐릭터 이미지와 같은 완료 판정에 포함하지 않는다.
  - receipt에 `official_blablalink_shiftys_pad_mi_image` authority와 256×512 규격을 기록한다.

### FE-002 — 니케 도감 카드의 정보 배치 불일치

- 심각도: 높음
- 현재 상태: 설치본 수정 완료, 운영자 시각 재검수 대기
- 블라블라 기준 카드 구조:
  - 좌상단: 속성, 무기군, 버스트 타입
  - 좌하단: 싱크로 레벨
  - 우하단: 캐릭터 이름
  - 캐릭터 이름 위: 돌파·코어 강화 연출
- 현재 결함:
  - 아이콘 대신 한글 첫 글자와 별도 badge를 사용한다.
  - 이름, 전투력, 레벨과 돌파 표시 위치가 블라블라와 다르다.
  - 카드 비율·crop·overlay가 기준 화면과 다르다.
- 기대:
  - 카드 anatomy, icon rail, 하단 gradient, 텍스트 정렬과 돌파 연출을 기준 화면과 동일하게 구성한다.
- 2026-08-30 수정:
  - 공식 카드 비율인 10:18을 적용하고 portrait가 카드 전체를 채우게 했다.
  - 좌상단 rail을 `속성 → 무기군 → 버스트` 순서로 고정했다.
  - 좌하단을 `LV.`/싱크로 레벨, 우하단을 돌파·코어 연출/이름 순서로 재배치했다.
  - 별도 전투력 행과 우상단 burst badge를 제거했다.
  - 속성·무기군·버스트, 돌파 별, 코어 강화와 클래스 표시는 인증된 블라블라 화면에서 확인한 실제 이미지 자산을 사용한다.

### FE-003 — 니케 상세 화면의 블라블라 구조 미준수

- 심각도: 높음
- 현재 상태: 설치본 수정 완료, 운영자 시각 재검수 대기
- 관측:
  - 장비·스킬·소장품 탭의 정보 밀도와 visual hierarchy가 기준 화면과 다르다.
  - 장비 아이콘과 옵션 효과가 임시 도형·generic control로 표현된다.
  - 돌파 설정도 블라블라의 별·코어 강화 표현 대신 일반 select로 노출된다.
- 기대:
  - 상단 캐릭터 성장 패널, 탭, 장비 카드, 장비 능력치, 오버로드 효과, 스킬과 소장품 화면을 블라블라 구조로 재작성한다.
  - 큐브 설정 탭은 계속 제외한다.
- 2026-08-30 수정:
  - 돌파를 3개 별 이미지 선택기로, 코어 강화를 evolve badge 기반 stepper로 교체했다.
  - 장비 24개와 소장품·애장품 33개의 실제 WebP 자산을 정적 데이터의 resource path에서 해소해 로컬 설치본에 포함했다.
  - 장비·스킬·소장품 탭 mask와 장비/오버로드 행의 정보 위계를 인증된 상세 화면 기준으로 조정했다.

### FE-004 — 통합 Save가 stale lobby ETag를 사용

- 심각도: 차단
- 현재 상태: aggregate endpoint 연결·회귀 검증·설치 완료, 실제 계정 저장 재검수 대기
- 재현:
  1. 콘솔 또는 니케 profile 값을 변경한다.
  2. `Save`를 누른다.
  3. `local_game_lobby_revision_conflict`가 간헐적으로 표시된다.
- 원인:
  - `saveEverything()`은 `saveProfile()` 뒤에 `saveLobby()`를 호출한다.
  - profile promotion DB trigger는 이 사이에 lobby head를 새 revision으로 교체한다.
  - 프런트는 교체 전 `state.lobbyRevisionUid`를 `If-Match`로 다시 전송한다.
- 추가 결함:
  - `run()`은 저장 중 Save 버튼을 잠그지 않아 중복 클릭 race를 허용한다.
- 기대:
  - profile 저장 뒤 lobby head/ETag를 재조회하거나 백엔드의 통합 저장 endpoint를 사용한다.
  - 저장 중 관련 버튼을 잠그고 완료·실패 후 한 번만 복구한다.
  - conflict 뒤에는 무조건 최신 head를 다시 읽고 사용자 입력을 보존한다.
- 2026-08-30 수정:
  - `saveEverything()`의 profile → lobby → wallet → label 순차 호출을 제거하고 단일 workspace Save/Save As 요청으로 교체했다.
  - 요청은 화면이 읽은 workspace/profile/lobby/wallet head 전체를 전송하며, 성공 뒤 서버가 반환한 계정 UID로 전체 상태를 다시 읽는다.
  - 네 Save 버튼을 요청 완료까지 함께 잠가 중복 클릭을 차단한다.
  - 네트워크 중단 시 operation UID를 유지하므로 같은 요청은 백엔드의 pending receipt에서 이어진다.

### FE-005 — 전투력 미관측 상태를 숫자 0으로 표시

- 심각도: 높음
- 현재 상태: 원인 확정
- 관측:
  - 레드 후드의 sanitized draft 전투력 관측값은 `748,940`이다.
  - `state.combatPowerByCharacter`에 값이 없을 때 UI가 `(map.get(uid) || 0)`을 사용한다.
  - 따라서 데이터 연결이 끊긴 상태가 실제 전투력 `0`처럼 표시된다.
- 기대:
  - 전투력 출처를 current profile 또는 연결된/latest fetched observation에서 명시적으로 받는다.
  - 값이 없으면 `미확인`으로 표시하고 `0`을 생성하지 않는다.
  - 정렬도 미확인 값을 실제 0과 구분한다.
- 2026-08-30 수정:
  - UI의 `값 없음 → 0` 대체를 제거하고 결손은 `미확인`으로 표시한다.
  - admission-authoritative snapshot pointer가 없어도 최신 source-free 관측 snapshot의 roster/detail 전투력을 읽는 별도 read path에 연결했다.
  - Save As 계정은 자체 관측이 없을 때 parent 계정의 최신 관측을 read-only로 참조한다.

### FE-006 — 오버로드 옵션 이름·표시·저장 단위 오류

- 심각도: 높음
- 현재 상태: 표시 수정 완료. 옵션 변경 시 저장 단위 오류 후속 수정·검증 중
- 관측:
  - DB에는 레드 후드의 네 장비에 총 10개 오버로드 line과 정확한 값이 저장되어 있다.
  - presentation catalog의 아홉 option 이름이 모두 `오버로드 옵션` fallback으로 생성된다.
  - 저장 값은 `ratio` 단위인데 UI는 `0.0970`을 `%` 기호와 바로 결합한다. 기대 표시는 `9.70%`다.
  - option select가 실제 공격력·우월코드·차지 속도 등의 의미를 식별할 수 없다.
  - 후속 검수에서 옵션 종류를 바꾸면 프런트가 presentation-only 단위 `percent`를 저장 operation에 넣어 catalog의 정규 단위 `ratio`와 충돌하고 `profile_overload_unit_mismatch`로 Save가 실패했다.
- 기대:
  - option definition을 실제 한국어 효과명으로 해석한다.
  - `ratio`는 표시 시 100을 곱하고 저장 시 정확한 fixed-point 값으로 되돌린다.
  - 현재 선택값, option tier와 최고 수치 연출을 블라블라 화면과 동일하게 표시한다.
- 2026-08-30 수정:
  - DB에 보존된 `option_type_code`를 presentation exporter가 직접 읽어 아홉 실제 한국어 효과명으로 투영한다.
  - wire projection에 저장 단위 `ratio`, 표시 단위 `percent`, 변환 배수 `100`을 명시했다.
  - 15개 legal value의 정확한 ordinal을 기준으로 `level-1`부터 `level-15`까지 색을 선택한다.
  - 로그인된 블라블라의 `라피 : 레드 후드` 장비를 다시 관측해 9·12·13·14·15단계가 섞인 실제 행을 확인했다.
  - 1~11단계는 검은 글자 `#141416`, 12~14단계 값은 cyan `#00B5FF`, 15단계는 검은 배경 `#141416`과 cyan 값 `#00B5FF`로 고정한다.
  - 장비 위에는 네 부위 오버로드 옵션 합계를 블라블라처럼 검은 글자와 회색 배경 `#E4E4E9`로 표시한다. 합계 행은 개별 단계 색을 적용하지 않는다.
  - 장비 한 부위의 옵션 세 줄은 가로 3열이 아니라 `장비 이미지 → 장비 능력치 → 장비 효과` 구조 안에서 수직으로 쌓는다.
  - 옵션 종류 변경 시 저장 operation의 unit은 `ratio`로 고정하고, `%`와 ×100 변환은 화면 표시에만 사용한다.
  - 차지 속도·명중률도 UI와 프로필에서는 양수 application magnitude로 표시·저장한다. 원본 카탈로그의 signed raw 부호는 presentation 값으로 노출하지 않는다.

### FE-007 — 솔로 레이드 `상태 확인` 버튼의 의미와 활성 조건 오류

- 심각도: 중간
- 현재 상태: 원인 확정
- 관측:
  - 버튼 문구는 계정 실행 가능 상태를 검사하는 것처럼 보인다.
  - 실제로는 이미 생성된 `launchContextUid`를 poll하는 기능이다.
  - run 생성 전에는 비활성화되어 계정 readiness 문제를 확인할 수 없다.
- 기대:
  - 계정 readiness 확인과 실행 상태 poll을 서로 다른 기능·문구로 분리한다.
  - 차단 시 내부 reason code가 아닌 사람이 이해할 수 있는 수정 항목을 제공한다.

### FE-008 — 장비 강화 레벨이 기본 능력치 표시에 반영되지 않음

- 심각도: 높음
- 현재 상태: 수정·설치본 검증 완료
- 원인:
  - presentation catalog는 `ItemEquipTable`의 0강 기본 능력치만 문자열로 내보냈다.
  - 프런트는 `equipment.*.enhancement_level`을 편집했지만 능력치 렌더링에는 사용하지 않았다.
- 권위와 계산:
  - 장비 강화 좌표 `0..5`는 고정 런타임의 `ItemEquipExpTable`에서 정의별로 검증한다.
  - 강화 1단계마다 0강 기본 능력치의 10%를 가산한다.
  - 표시값은 `round_half_up(baseStat × (1 + enhancementLevel × 0.10))`으로 정수 반올림한다.
  - 예: 0강 `공격력 6,014 / 체력 49,181`은 +5에서 `공격력 9,021 / 체력 73,772`다.
- 수정:
  - presentation에 `baseValue`, `maximumEnhancementLevel=5`, `enhancementStatIncreaseBasisPointsPerLevel=1000`을 명시한다.
  - 강화 입력 변경 시 네 부위의 표시 능력치를 즉시 다시 계산한다.
  - Playwright visual acceptance가 0강 값과 +5 기대값을 별도로 계산해 DOM 결과와 일치하는지 검사한다.

### FE-009 — 목록의 한계돌파·코어 강화 표기와 조작 순서 오류

- 심각도: 높음
- 현재 상태: 수정·설치·시각 검증 완료 (2026-08-30)
- 관측:
  - 상세 화면에는 별과 코어 badge가 표시되지만 목록은 실제 성장 상태와 다르게 보일 수 있다.
  - 기존 목록은 `0코강`도 evolve badge로 표시했다. 인증된 블라블라 목록의 `이브`처럼 한계돌파가 3 미만인 니케에는 코어 badge가 없어야 한다.
  - 기존 상세 조작은 한계돌파와 코어 강화를 서로 독립된 값처럼 변경했다.
- 권위 규칙:
  - 성장 순서는 `0돌 → 1돌 → 2돌 → 3돌 → 1코강 … → 7코강(MAX)`인 하나의 연속 축이다.
  - 코어 강화가 1 이상이면 한계돌파 별 세 개는 반드시 모두 채워진다.
  - 전체 니케 목록에서는 코어 강화 badge를 1코강부터만 표시한다. 0코강은 별 세 개만 표시한다.
- 수정:
  - 상세의 코어 강화 `−/+`를 0~10 연속 성장축으로 바꾼다. 0돌에서 `+`를 누르면 먼저 별 세 개가 차고 네 번째 입력에서 1코강이 된다.
  - `−`는 반대 순서로 코어 강화를 먼저 낮춘 뒤 한계돌파를 낮춘다.
  - 별을 직접 선택하면 해당 한계돌파 단계로 이동하고 코어 강화는 0으로 초기화한다.
  - 목록은 별 세 개를 항상 표시하되 현재 돌파까지만 채우고, 코어 badge는 `core_level >= 1`일 때만 추가한다.
- 검증:
  - 설치본 Playwright acceptance에서 0코강 badge가 표시되지 않고, 양수 코어 badge는 실제 수치만 표시됨을 확인했다.
  - 0돌에서 `+` 네 번의 결과는 `limit_break=3`, `core_level=1`이고, 이어서 `−` 네 번의 결과는 `limit_break=0`, `core_level=0`이다.
  - 목록 코어 badge는 공통 `span` 색·여백 규칙에서 분리했다. 설치본 계산값은 글자색 `rgb(255, 255, 255)`, 상단 여백 `0px`, 마지막 별과의 수직 중심 오차 `0px`다.
  - 후속 시각 산출물은 `artifacts/phase-d/frontend-visual-core-badge-alignment-final/nikke-catalog.png`와 같은 폴더의 `growth-equipment-observation.json`에 보존한다.

### FE-010 — 미보유 니케가 도감에서 누락됨

- 심각도: 중간
- 현재 상태: 수정·설치·시각 검증 완료 (2026-08-30)
- 원인:
  - 목록의 입력 집합을 presentation character catalog가 아니라 current profile에 `character_level` row가 있는 UID만으로 만들었다.
- 수정:
  - presentation exporter도 계정의 `character_build`가 아니라 최신 `character_catalog_snapshot_member` 전체를 읽는다. 따라서 현재 계정이 보유하지 않은 catalog member도 브라우저에 도달한다.
  - 목록 입력은 전체 presentation character catalog로 고정한다.
  - `character_level` row 존재 여부를 현재 로컬 계정의 보유 표시 기준으로 사용한다.
  - 보유 니케를 먼저 전투력순으로 정렬하고 미보유 니케를 그 뒤에 이름순으로 표시한다.
  - 미보유 portrait는 grayscale 처리하고 `미보유` badge를 표시한다. 결손 레벨을 숫자 `0`으로 위장하지 않는다.
  - 목록 count는 `보유 N / 전체 M`으로 표시한다.
- 검증:
  - 최신 catalog 199명과 character asset 199개가 설치본에 함께 배포됐고 asset 누락은 0개다.
  - 시각 acceptance fixture에서 `보유 198 / 전체 199`와 미보유 카드 1개를 확인했다. 이 fixture 수치는 렌더링 검사용이며 실제 계정의 보유 수를 뜻하지 않는다.

### FE-011 — 장비 아이콘에서 장착 장비를 선택할 수 없음

- 심각도: 높음
- 현재 상태: 수정·설치·시각 검증 완료 (2026-08-30)
- 원인:
  - 장비 아이콘은 정적인 이미지였고 `equipment.<slot>.definition` 편집 UI가 사용자 화면에 없었다.
  - presentation equipment 정의에 티어·부위·클래스 좌표가 없어 이름 문자열로 추정하지 않고 후보를 제한할 수 없었다.
- 수정:
  - presentation exporter가 고정 정적 데이터에서 `tier`, `slotCode`, `combatClassCode`를 명시한다.
  - 장비 아이콘을 누르면 해당 니케 클래스와 해당 부위에 맞는 `9티어`, `10티어` 두 후보만 이미지·이름과 함께 표시한다.
  - 선택 시 `equipment.<slot>.definition`을 교체한다.
  - 9티어 선택 시 기업 일치 상태를 해제하고 오버로드 세 줄을 `absent`로 전환한다. 10티어 선택 시 기업 일치 상태를 활성화한다.
  - raw 장비 ID나 내부 UID는 사용자에게 표시하지 않는다.
- 검증:
  - 설치본에서 머리 장비 아이콘을 눌렀을 때 선택 니케의 클래스·머리 부위에 맞는 `9티어`, `10티어` 두 후보만 표시됐다.
  - 9티어 후보 선택 뒤 effective profile의 장비 tier가 9로 바뀌는 것을 확인했다.

### FE-012 — 목록 카드의 과도한 검은 하단 overlay

- 심각도: 중간
- 현재 상태: 수정·설치·시각 검증 완료 (2026-08-30)
- 관측:
  - 첫 블라블라 근사 구현의 검은 사선 overlay가 portrait 하단을 과도하게 가렸다.
- 운영자 결정:
  - 검은 overlay를 제거하고 portrait를 더 많이 노출한다.
  - 레벨·이름·돌파 표시는 반투명한 밝은 footer 위의 검은 글자로 바꾼다.
  - 미보유 카드도 검은 덮개 대신 밝은 회색 footer와 portrait grayscale로 구분한다.
- 검증:
  - 설치본 card footer의 계산된 배경은 흰색 기반 반투명 gradient이며 기존 검은 RGB 배경값이 없음을 자동 검사와 screenshot으로 확인했다.

### FE-013 — 애장품 후보 범위·불필요한 해금 안내·스탯 라벨

- 심각도: 중간
- 현재 상태: 수정·설치·시각 검증 완료 (2026-08-30)
- 관측:
  - 기존 소장품 selector는 무기군만 검사하여 같은 무기군을 쓰는 다른 니케의 애장품까지 표시했다.
  - 소장품 카드 하단에 편집에 필요하지 않은 `애장품 해금 조건` 안내 상자가 항상 표시됐다.
  - 장비와 소장품의 공통 능력치 라벨이 `공격`, `방어`로 축약됐다.
- 수정:
  - presentation exporter가 애장품의 전용 니케 원본 식별값을 process-local alias로 역결박하고, 브라우저에는 로컬 `favoriteCharacterUid`만 제공한다. 원본 숫자 코드는 presentation에서 제거한다.
  - selector는 일반 소장품은 동일 무기군으로, 애장품은 `favoriteCharacterUid === subjectUid`인 정의로만 제한한다.
  - 해금 조건 안내 상자와 관련 CSS를 제거한다.
  - 정적 능력치 projection의 공통 라벨을 `공격력`, `방어력`으로 변경한다.
- 검증:
  - 설치본의 애장품 21개는 모두 유효한 로컬 니케 UID에 결박됐고 결손·원본 숫자 코드 노출은 0개다.
  - 헬름에는 전용 애장품 `낡은 나침반`만 표시되고, 애장품이 없는 아스카에는 애장품 후보가 0개임을 확인했다.
  - 해금 안내 상자는 0개이고 소장품 스탯은 `공격력 4,736 · 방어력 1,002 · 체력 147,250`으로 표시됐다.
  - 산출물은 `artifacts/phase-d/frontend-visual-collection-favorite-labels/collection-filter-observation.json`, `nikke-detail-collection.png`, `nikke-detail-favorite-filter.png`에 보존한다.

### FE-014 — 애장품 기본 능력치의 SR 소장품 15레벨 결박

- 심각도: 높음
- 현재 상태: 수정·설치·시각 검증 완료 (2026-08-30)
- 관측:
  - 애장품의 공격력·방어력·체력은 해당 무기군 SR 소장품 15레벨과 같아야 한다.
  - 기존 화면은 동일 무기군 소장품 중 `level=15`와 내부 `grade` 최댓값만 사용했다. R과 SR의 15레벨 행이 모두 `grade=3`이라 정의 순서에 따라 R 수치가 선택될 수 있었다.
- 수정:
  - presentation에 원본 rarity를 로컬 표기인 `r`·`sr`·`ssr`로 투영한다.
  - 애장품 화면은 동일 무기군이면서 `rarityCode=sr`, `level=15`인 유일한 좌표의 공격력·방어력·체력을 고정 기본 능력치로 사용한다.
  - 좌표가 없거나 중복이면 다른 등급 수치를 추정하지 않고 `능력치 정보 없음`으로 fail closed한다.
- 검증:
  - 설치본에서 애장품 표시값과 동일 무기군 SR 소장품 15레벨 표시값의 완전 일치를 자동 검사한다.
  - 여섯 무기군 모두 SR 정의와 15레벨 좌표가 각각 정확히 1개이며, 설치본에서 헬름의 애장품은 `공격력 9,688 · 방어력 2,058 · 체력 301,800`으로 SR 15레벨과 일치했다.
  - 산출물은 `artifacts/phase-d/frontend-visual-favorite-sr15/collection-filter-observation.json`, `nikke-detail-favorite-filter.png`에 보존한다.

### FE-009~014 설치본 검증 산출물

- 자동 관측값: `artifacts/phase-d/frontend-visual-growth-equipment-installed-199/growth-equipment-observation.json`
- 목록 화면: `artifacts/phase-d/frontend-visual-growth-equipment-installed-199/nikke-catalog.png`
- 장비 선택 화면: `artifacts/phase-d/frontend-visual-growth-equipment-installed-199/nikke-detail-equipment-picker.png`
- 설치 상태: `C:\NLL\ControlCenter\app\wwwroot\editor\presentation.json` 199명, `assets/characters` PNG 199개

## 4. 블라블라 시각 구조 분석 (2026-08-30)

### 4.1 공통 shell

- 화면은 둥근 dashboard card의 집합이 아니라 흰색 면, 얇은 회색·검은 구분선과 cyan 선택선으로 위계를 만든다.
- 큰 hero·과도한 빈 공간 대신 제목 bar, 검색 bar, filter bar, content가 짧은 간격으로 연속된다.
- 선택 control은 큰 gradient pill이 아니라 각진 사각형과 하단·좌측 cyan accent로 나타난다.
- 상세 화면의 배경은 옅은 graph-paper grid이며 content card는 작은 radius와 짧은 shadow만 사용한다.

### 4.2 니케 도감

- 공식 card component는 102×180이며 목록에서도 10:18 aspect를 유지한다.
- portrait(`mi_image`)가 카드 면을 채우고, 상태 정보는 사진 위에 겹쳐 표시한다.
- 좌상단 세로 rail은 속성·무기군·버스트 순서다.
- 로그인 화면에서 141.375×254.469px 카드의 실제 아이콘 표시 크기를 관측했다. 속성은 17.391×20.391px, 무기군은 13.188×13.188px, 버스트는 11×10.188px이며 세 이미지를 같은 정사각 크기로 강제하지 않는다.
- 블라블라 원본은 사선 검은 overlay를 사용하지만, 2026-08-30 운영자 검수 결정에 따라 Control Center에서는 이 overlay를 제거한다. 대신 portrait를 가리지 않는 얕은 밝은 footer를 사용한다.
- 좌하단은 `LV.`와 synchro level, 우하단은 돌파·코어 연출과 캐릭터 이름이다.
- 전투력은 card anatomy에 끼워 넣지 않고 목록 정렬 기준으로만 사용한다.

### 4.3 니케 상세

- 상단은 뒤로가기/title line 다음에 portrait, identity·전투력, 성장 조절 영역이 한 덩어리로 배치된다.
- 장비·스킬·소장품은 동일 폭의 각진 tab이며 선택 tab은 cyan outline과 점 pattern으로 구분한다.
- 장비 한 행은 `장비 이미지 → 기본 능력치 → 적용 효과` 순서의 읽기 흐름을 가진다.
- 오버로드 효과는 거의 검은 row 위에 표시하고 값 단계는 cyan·violet·gold accent로 구분한다.
- 큐브는 표시만 필요한 reference 화면과 달리 이 관리 도구의 편집 대상에서는 제외한다.

### 4.4 Control Center 적용 원칙

- shell도 같은 밀도·선·cyan accent 체계로 통일하고, 기존 dark sidebar SaaS layout을 유지하지 않는다.
- 내부 기능 ID와 API contract는 그대로 보존하되 사용자가 보는 명칭은 한국어로 표현한다.
- 이미지나 관측값이 없으면 low-quality fallback 또는 숫자 `0`으로 가장하지 않고 `미확인`을 표시한다.
- frontend fidelity와 backend data correctness를 분리 검증한다. 올바른 layout이 잘못된 전투력·장비 데이터를 정당화하지 않는다.

## 5. 프런트 수정 우선순위

1. FE-004 통합 Save race와 중복 클릭 방지
2. FE-005 전투력 `미확인`/실제 값 구분 및 올바른 출처 연결
3. FE-006 오버로드 효과명·수치 단위 수정
4. FE-001~003 블라블라 기준 이미지·도감·상세 화면 전면 교체
5. FE-007 레이드 상태 UX 분리

## 6. 금지되는 임시 처리

- 다른 사이트의 저해상도 이미지를 다시 대체재로 사용하지 않는다.
- 누락·미연결 값을 `0`, 빈 문자열 또는 generic label로 숨기지 않는다.
- conflict를 무조건 자동 재시도해 사용자의 동시 변경을 덮어쓰지 않는다.
- 블라블라 기준을 임의의 `유사 디자인`으로 다시 해석하지 않는다.
