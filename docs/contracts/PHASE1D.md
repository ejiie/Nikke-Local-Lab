# Phase 1D — 전투 보조 catalog

> 단계별 계약·검증 기준입니다. 이 문서의 과거 실행 판정과 현재 151 운영 상태를 구분합니다. 현행 진척은 [인계 요약](../HANDOFF.md), 작업 우선순위는 [안정화 계획](../STABILIZATION_PLAN.md)을 확인합니다.

Phase 1D는 계정 소유 상태가 아니라 profile editor와 전투 입력이 참조할 정적 정의를 게시합니다. 입력은 사용자가 보관한 `StaticData` archive 하나이며, 원본은 read-only source adapter로만 읽습니다. 원본 ID, 로컬 경로, locale key와 복호 row는 도메인·DB receipt·로그·Git에 남기지 않습니다.

## 구현 범위

현재 editor와 계정 이관에 필요한 정의만 포함합니다.

- 장비: Tier 9와 Tier 10만, 전투 클래스 3종 × 4부위 × 2티어의 24개 정의
- 큐브: 17종, 각 Level 1~15 좌표
- 범용 소장품: 무기 6종 × 희귀도 2종의 12개 정의, Level 0~15
- 전용 애장품: 적용 캐릭터가 명확한 21개 정의, Level 0~2
- 콘솔: 공용 1종, 클래스 3종, 기업 5종의 9개 좌표와 snapshot별 연속 Level 범위
- 오버로드: 표준 Tier 10 장비가 참조하는 9종 옵션과 각 15개 이산 값

Tier 1~8 장비와 class-all 내부 row는 게시하지 않습니다. 장비가 없는 슬롯은 별도 Tier 0 정의가 아니라 `null`/미장착 상태입니다. Phase 2 importer가 이 범위 밖 장비를 만나면 임의의 T9/T10으로 치환하지 않고 controlled `unsupported` 결과를 냅니다.

## 정규화 계약

### 장비

장비 정의는 부위, 전투 클래스, 티어, source table join으로 정규화한 강화 grade, 최대 강화 Level 5, 두 개의 유효 flat stat과 세 개 option-line 좌표를 보존합니다. 원본 `grade_core_id`와 T9→T10 성장 대상 ID는 FK 검증에만 사용하고 공개 도메인·DB에는 저장하지 않습니다. `None/0` padding stat은 의미 없는 no-op이므로 공개 도메인에서 제거합니다. Tier 9 option line은 비활성이며, Tier 10 option line의 발동 확률은 순서대로 100%, 50%, 30%입니다.

제조사 일치 여부와 각 물리 장비 copy의 소유 상태는 definition이 아닙니다. Phase 2 build revision이 자체 UUID와 제조사 일치 상태를 소유하며, 공식 장비 instance UID를 복사하지 않습니다.

### 큐브·소장품·애장품

큐브는 장착하지 않은 상태와 definition 선택을 분리합니다. Level 1~15 및 level별 skill coordinate를 보존하며, editor 기본값은 선택된 큐브의 Level 15입니다.

범용 소장품은 무기 적용 관계를, 전용 애장품은 private alias registry를 거쳐 기존 lab-owned character UID와의 관계를 저장합니다. 범용 소장품과 전용 애장품을 한 캐릭터에게 동시에 더하지 않습니다. level별 stat과 skill-slot level 좌표는 source 순서를 보존합니다.

Phase 1D는 별도 skill-definition/effect catalog를 만들지 않습니다. 따라서 cube·collection·favorite의 item 선택과 level 좌표는 profile-ready지만 skill effect identity/semantics는 명시적으로 `unresolved`이며, 완전한 전투 semantics로 표시하지 않습니다. 원본 client는 dataset에 고정된 item definition을 통해 자체 skill을 로드하고, 독립 계산용 정규화는 후속 단계에서 추가합니다.

### 콘솔

각 console definition은 source snapshot에서 확인한 합법 Level `1..MaximumLevel`과 level별 요구 synchro 좌표를 저장합니다. 보존된 Aug13 snapshot은 680, 이전 snapshot은 580이지만 이를 전역 상수나 노드 간 동일성 규칙으로 만들지 않습니다. Level 0은 기여가 없는 계정 상태로 표현하며 별도 source row를 만들지 않습니다. stat은 level row마다 새 값을 추측하지 않고 definition에 있는 레벨당 flat 계수로 계산합니다.

- 공용: Level당 HP +450
- 클래스 3종: Level당 DEF +5, HP +750
- 기업 5종: Level당 ATK +25, DEF +5

### 오버로드

Tier 10 option-slot FK가 직접 선택하는 표준 group만 사용합니다. 9개 옵션마다 15개 이산 값을 값 순서와 확률 band까지 보존합니다. 단순 `min/max` 범위로 축약하지 않습니다. 표시 퍼센트와 engine ratio는 동일 raw basis-point 값에서 명시적 scale로 변환하며, 차지 속도와 명중률은 source 부호와 사용자 표시 magnitude를 구분합니다.

동일 장비에서 같은 옵션 종류를 중복할 수 있는지 여부는 현재 정적 데이터로 확정되지 않았습니다. 따라서:

- 연구 모드는 사용자가 지정한 임의 exact decimal 값을 허용합니다.
- source가 입증한 line 수·옵션 종류·이산 값은 검증할 수 있습니다.
- 중복 옵션 정책만 `unresolved`로 남기며 추측으로 거부하지 않습니다.

OL 잠금 상태, 재설정 이력과 비용은 사용자 범위에서 제외합니다.

## 저장과 identity

`V0004__combat_support_catalog.sql`은 immutable definition entity/version, private source alias, catalog snapshot과 child 좌표를 저장합니다. ledger 완료와 catalog 게시를 한 transaction으로 처리합니다. 같은 source alias와 같은 domain content는 entity/version을 재사용하고, 새 dataset은 새 catalog snapshot을 만듭니다.

전용 애장품의 적용 캐릭터는 Phase 1B character catalog가 먼저 게시되어 있어야 해소됩니다. 두 importer는 같은 local HMAC identity binding을 사용하지만 원본 character key 자체는 DB·receipt·API에 저장하지 않습니다. 대응하는 lab-owned character가 없으면 임의 생성하지 않고 게시를 중단합니다.

계정 raw의 OL line은 정규화된 옵션명이 아니라 source effect reference를 담을 수 있으므로, 표준 135개 legal value에는 private HMAC alias를 추가로 둡니다. 이 alias는 raw reference를 자체 OL definition과 roll level로 바꾸는 importer 전용 lookup이며 도메인·receipt·API에는 노출하지 않습니다.

DB와 receipt의 catalog manifest hash는 `Domain.CombatSupport` canonical manifest와 정확히 같아야 합니다. 표시명은 locale이 없으면 `unresolved`여도 selection readiness를 막지 않습니다. source readiness와 완전한 전투/game-legal semantics readiness는 별도 상태입니다.

## Phase 2 입력과의 경계

개인 계정 JSON은 Phase 1D 입력이 아닙니다. 사용자가 외부에서 수동 갱신한 raw capture는 Phase 2A2의 offline allowlist sanitizer가 읽습니다. Local Lab은 crawler를 실행하거나 공식 로그인/API replay를 수행하지 않습니다.

Sanitizer는 raw reference를 이 catalog와 character catalog에 ephemeral하게 join한 뒤 자체 UUID만 출력합니다. 미장착 inventory 전체, OL lock/reset history와 공식 장비 instance UID는 가져오지 않습니다. 장착 상태, 4부위별 OL `(slot, line, type, value, unit)`, 큐브·소장품/애장품, 콘솔과 synchro만 새 immutable revision으로 옮깁니다.

## 완료 검증

- 합성 archive로 strict MemoryPack/ZIP/FK/좌표/unknown-enum 경계를 검사합니다.
- 같은 입력은 결정적인 candidate/domain/catalog hash를 만듭니다.
- PostgreSQL integration은 최초 게시, 재사용, rollback, identity-key mismatch, child graph sealing과 source-ID-free receipt를 검사합니다.
- 보관된 실제 snapshot은 별도 read-only local smoke로만 검사하며 원본·복호물·개인 데이터를 Git/Actions에 넣지 않습니다.
- 실제 profile write, Save/Save As와 raw sanitizer는 Phase 2A1/2A2 범위입니다.
