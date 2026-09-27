# Phase 2A1 — local account와 전투 profile revision

> 단계별 계약·검증 기준입니다. 이 문서의 과거 실행 판정과 현재 운영 상태를 구분합니다. 현행 상태는 [인계 요약](../HANDOFF.md), 남은 작업은 [다음 작업](../NEXT_STEPS.md)을 확인합니다.

> 상태: 완료. 아래 완료 조건과 단위/PostgreSQL gate를 모두 통과한 revision입니다.

Phase 2A1은 정적 catalog를 실제 전투 입력 상태로 조합하는 저장 기반을 만듭니다. 모든 계정과 revision은 Local Lab이 발급한 자체 UUID만 사용합니다. 이 단계는 공식 계정 정보를 읽거나 쓰지 않으며, credential-bearing raw sanitizer와 관리 UI는 Phase 2A2 범위입니다.

## 구현 범위

- 합성 `LocalAccount`와 최소 `LocalSession`
- 불변 `AccountCombatStateRevision`
- 논리 `CharacterBuild`와 불변 `CharacterBuildRevision`
- 다섯 슬롯의 불변 `SquadRevision`
- account state와 build 집합을 묶는 불변 `ProfileTemplateRevision`
- optimistic concurrency를 사용하는 원자적 current-pointer 교체
- `V0005__local_account_profile.sql`

HTTP admin credential, source-free sanitized import, Save As UI, 다른 account에 적용하는 diff와 offline raw sanitizer는 Phase 2A2에서 이 기반 위에 구현합니다. portable export는 구체적인 소비자와 배포 경계가 정해질 때까지 후속 범위로 남깁니다.

## LocalAccount와 LocalSession

`LocalAccount`는 무작위 lab UUID와 생성 시각만으로 식별합니다. 실제 account UID, open identifier, nickname, cookie, token 또는 공식 session 식별자는 저장하지 않습니다.

`LocalSession`은 local account를 선택하는 최소 수명 계약입니다. 자체 session UUID, 발급·만료·폐기 시각만 보존하며 공식 인증 semantics를 모방하지 않습니다. loopback API용 local credential 발급은 Phase 2A2에서 별도 비밀 경계로 추가합니다.

이 session의 만료는 local login/session 수명이며 Solo Raid season expiry가 아닙니다. 지원 Raid season은 후속 service 계약에서 permanent로 제공하므로 두 수명을 결합하지 않습니다.

## AccountCombatStateRevision

계정 전체 전투 상태는 캐릭터 build에 복제하지 않습니다.

- synchro level
- 정확히 아홉 개 console definition/version 참조와 level
- 선택적인 console progress EXP 관측
- character와 combat-support catalog의 각 snapshot UID, dataset UID와 manifest hash
- validation mode, edit provenance, canonical content hash와 readiness

console level은 `0..definition maximum`입니다. Level 0은 기여가 없는 명시적 상태입니다. 각 definition의 최대치는 source snapshot에서 해소하며 580이나 680을 코드에 고정하지 않습니다. `game-legal`에서는 선택한 level 좌표의 minimum synchro도 account synchro와 대조합니다. EXP는 상태를 가진 fact로 저장하며, unresolved여도 level이 해소됐다면 전투 stat readiness를 막지 않지만 lossless profile 복원 readiness와는 분리해 표시합니다.

두 catalog binding은 snapshot UID, dataset UID와 manifest hash를 함께 고정합니다. v1 catalog manifest는 의미 내용은 인증하지만 PostgreSQL이 발급한 version UID 자체를 포함하지 않으므로, exact version-membership evidence는 임의 public factory로 만들 수 없습니다. `Domain.Profile`은 opaque evidence의 구조와 사용만 소유합니다. trusted PostgreSQL store가 catalog snapshot row, dataset/manifest 일치, definition/version membership FK와 content hash를 확인한 뒤에만 내부 evidence를 발급하며, 일반 profile 생성 경로는 이 evidence를 요구합니다.

## CharacterBuildRevision

논리 build는 current revision을 가리킬 뿐 전투값을 직접 소유하지 않습니다. 수정할 때마다 revision number와 UUID를 새로 발급합니다. account state, build, squad와 profile template revision은 각각 자신의 `origin`(`UserEdit`, `CombatMaxV1`, `OfflineSanitizedImport`, `Rebase`), UTC `materializedAt`과 exact predecessor UID를 보존합니다. mixed explicit/combat-max build를 한 profile에 함께 둘 수 있으므로 origin은 profile 전역 값이 아니라 각 build revision에 속하고, account-state/squad/template revision도 각각 별도 origin을 갖습니다. Domain factory는 revision 1/후속 revision의 predecessor 유무 형태를 검사하고, 정확한 동일 aggregate predecessor와 `current + 1` 여부는 trusted store의 Save transaction과 V0005 제약이 강제합니다.

새 content를 materialize할 때 command가 공급한 origin과 시각을 그 새 revision에 기록합니다. 반대로 current content와 canonical hash가 같은 반복 Save는 새 metadata-only revision을 만들지 않고 기존 revision을 재사용하므로, 기존 revision의 최초 materialization provenance를 유지합니다. origin이나 시각만 바꾸기 위해 같은 content를 덮어쓰는 동작은 지원하지 않습니다.

- character entity와 정확한 character definition version/catalog snapshot
- 명시적인 battle character level
- 일반 limit-break stage와 core level
- bond level
- Skill 1, Skill 2, Burst level
- `head`, `torso`, `arms`, `legs` 네 장비 slot
- 선택적인 cube 장착과 level
- collection 또는 favorite 한 경로의 선택·level, 혹은 미적용/미해소 상태
- default policy, validation mode, edit provenance, canonical content hash와 readiness

장비 slot은 미장착이거나 Phase 1D catalog의 Tier 9 또는 Tier 10 definition을 참조합니다. 장착 장비의 강화는 `0..5`이며 각 slot identity가 필요할 때도 Local Lab 자체 UUID만 사용합니다. 공식 inventory instance UID는 import하지 않습니다.

`combat-max/v1`은 생성 시점의 character와 combat-support catalog에서 다음 값을 실제 정수와 UUID로 한 번 materialize합니다.

- character level은 사용자 명시값
- 지원되는 최대 limit break/core, bond
- 캐릭터 전투 클래스와 네 부위에 맞는 Tier 10/+5 장비
- 10/10/10 skills
- cube는 종류를 추측하지 않고 미장착
- 적용 가능한 전용 favorite가 정확히 하나면 그 최대 좌표, 아니면 무기 일치 최고 rarity generic collection의 최대 좌표
- OL line은 비어 있음

과거 revision은 catalog 갱신으로 자동 rebase하지 않습니다.

readiness는 하나로 뭉치지 않습니다. `selection`은 원본 client에 넘길 definition과 수치가 모두 고정됐는지, `combat semantics`는 Local Lab이 선택된 효과를 독립적으로 계산할 만큼 의미를 정규화했는지를 나타내는 별도 축입니다. `research`와 `game-legal`은 별도 readiness 축이 아니라 선택 검증 mode입니다. `game-legal`은 catalog가 입증한 합법 좌표·이산 값을 selection 결과에 추가 검증하지만, 그 자체로 독립 combat semantics가 완전하다고 주장하지 않습니다. Phase 1D에서 아직 정규화하지 않은 cube·collection·favorite skill semantics는 `selection`을 막지 않지만 `combat semantics`를 `unresolved`로 유지합니다.

일반 `explicit/v1`, `OfflineSanitizedImport`, `Rebase` draft에서는 equipment, cube, collection 또는 favorite definition이 확인됐지만 level 하나만 결손인 부분 관측을 전체 미해결 선택으로 축약하지 않습니다. 선택된 자체 definition/version은 유지하고 level만 reason code를 가진 fact로 `unresolved` 왕복하며, selection과 game-legal readiness를 낮춥니다. 확인된 mismatch나 cap 초과는 계속 fail closed입니다. `combat-max/v1`은 최대값 근거가 없을 때 정의를 임의 선택하지 않으므로 기존 resolver와 같이 해당 선택 전체를 `unresolved`로 materialize합니다.

core는 적용 가능한 character snapshot 최대값으로 해소합니다. 장비 기업 일치 여부는 명시적 선택이나 근거가 없으면 `unresolved`이며 임의로 true를 만들지 않습니다. 기존 Phase 1B character catalog의 unresolved equipment placeholder는 사용하지 않고, Phase 1D의 role×slot Tier 9·10 grid에서 정확한 definition version을 선택합니다.

### OL exact write

장비별 OL line은 고정 좌표 `1..3`의 unique subset입니다. `{1, 3}`처럼 중간 빈 line을 허용하며 삭제 후 뒤 line을 당기지 않습니다. 각 line은 source-ID-free option definition 또는 정규화 option type, exact decimal의 unscaled integer와 scale, unit을 보존합니다.

`research` mode는 9종 표준 option의 임의 exact 값을 허용합니다. `game-legal` mode는 Phase 1D의 15개 이산 값과 line applicability를 검증할 수 있지만, 정적 근거가 없는 same-kind duplicate policy는 거부 규칙으로 추측하지 않습니다.

## SquadRevision

Squad는 정확히 다섯 개 ordered slot을 갖습니다. 각 slot은 같은 local account의 서로 다른 character와 그 정확한 build revision을 참조합니다. 중복 character, 다른 account의 build, profile에 포함되지 않은 build 또는 catalog가 맞지 않는 build는 거부합니다.

Squad도 다섯 build의 selection readiness와 standalone combat-semantics readiness를 별도로 집계합니다. 따라서 원본 client용 입력으로 선택 가능한 squad와 Local Lab 단독 계산에 필요한 의미가 모두 준비된 squad를 혼동하지 않습니다.

전투 session은 나중에 squad current pointer가 아니라 정확한 `squad_revision_uid`와 다섯 `build_revision_uid`를 고정합니다.

## ProfileTemplateRevision과 Save

Profile template revision은 한 account combat state revision, build revision 집합과 선택적인 squad revision을 하나의 불변 view로 묶습니다. 편집 중 draft는 squad 없이 저장할 수 있지만 original-client combat-ready profile은 account 전투 상태와 정확히 다섯 명의 selection-ready squad를 가져야 합니다. Local Lab 단독 계산의 완결성은 별도 `combat semantics` 상태로 보존합니다. account state의 combat readiness와 console EXP를 포함한 full-fidelity readiness도 서로 독립입니다.

`Save`는 사용자가 읽은 expected profile revision을 조건으로 다음 동작을 한 PostgreSQL transaction에서 수행합니다.

1. 변경된 account-state/build/squad revision을 새로 삽입한다.
2. 새 profile template revision과 membership을 만든다.
3. child graph와 canonical hash를 검증한다.
4. expected current revision이 그대로일 때만 account current pointer를 새 revision으로 교체한다.

expected revision이 바뀌었다면 덮어쓰지 않고 controlled conflict를 반환합니다. 이미 publish된 revision과 child row는 UPDATE, DELETE, 뒤늦은 INSERT를 모두 거부합니다.

## 데이터 경계

Phase 2A1 테스트는 직접 만든 합성 UUID와 값만 사용합니다. 최신 private account JSON은 실제 값을 fixture로 복사하지 않고 다음 coverage 조건을 검토하는 데만 사용합니다.

- roster/detail level의 별도 관측 가능성
- 4 equipment slot과 고정 OL line 1..3
- 장착 cube와 collection/favorite
- synchro와 9 console level/EXP

실제 raw key, UID, path, payload hash, token, URL과 개인 build 값은 source, fixture, DB migration, log 또는 Actions에 들어가지 않습니다.

PostgreSQL은 exact catalog-member FK, account 소유 관계, revision lineage, child 개수와 sealing을 강제합니다. level cap, OL 이산 값, readiness와 canonical content hash 같은 도메인 의미는 `PostgreSqlLocalAccountProfileStore`가 Domain.Profile로 재투영해 검증하는 단일 publication boundary가 소유합니다. Domain canonicalizer를 PL/pgSQL로 복제하지 않으며 애플리케이션 밖의 직접 table write는 지원 API가 아닙니다.

## 완료 조건

- 현재 content와 다른 write만 다음 revision을 만들고, 동일한 current content의 반복 저장은 기존 revision을 재사용한다. 과거 content로 되돌리는 write는 새 revision을 만들며 이전 revision hash와 child graph는 항상 불변이다.
- stale expected revision의 Save가 원자적으로 실패한다.
- build는 정확히 네 장비 slot, squad는 정확히 다섯 unique character를 강제한다.
- sparse OL line, cube 장착/해제, collection/favorite 배타성, console Level 0과 선택적 EXP가 손실 없이 왕복한다.
- 선택된 definition은 알지만 enhancement/cube/collectible level만 결손인 일반 draft가 definition을 잃지 않고 field-level `unresolved` reason과 함께 왕복한다.
- catalog에 없는 definition/version, 다른 dataset/account 또는 범위 밖 Tier/level은 fail closed다.
- original-client combat readiness와 standalone combat-semantics readiness가 독립적으로 왕복된다.
- DB, receipt, synthetic fixture와 로그에 raw ID·실계정 값·path·credential이 없다.
- 합성 단위 검사와 PostgreSQL integration이 Windows/Linux Actions에서 통과한다.

이 revision은 위 조건과 `scripts/verify-phase2a1.ps1`, `scripts/verify-phase2a1.ps1 -Integration`을 모두 통과해 Phase 2A1 완료로 판정했습니다.

## Private-server 방향 재감사

원본 client에 제한 기능 private server를 제공하는 제품 방향으로 재감사한 결과, Phase 2A1의 domain과 V0005를 수정하거나 폐기할 필요는 없습니다.

그대로 재사용하는 항목:

- 자체 account/session identity와 catalog binding
- account combat state, character build와 immutable revision
- 5인 `SquadRevision`과 profile template
- selection/combat-semantics readiness 분리
- CAS Save, lineage, idempotency와 child sealing

후속 단계가 additive migration으로 보완할 항목:

- local display profile, wallet, feature manifest와 제한된 inventory projection
- 여러 permanent 지원 season과 account/session별 selected season
- Normal I~VII clear, Challenge 기본 개방과 Quick Battle unsupported projection
- `Asia/Seoul` 05:00 operational day와 daily state
- 한 Challenge run에 순차 결박되는 1~5개 squad와 팀 간 character 중복 금지
- original-client observed 팀별 damage, 누적 result와 execution segment

현재 `SquadRevision`은 정확한 한 팀이지 Solo Raid 전체 lineup이 아닙니다. `ProfileTemplateRevision`의 active squad와 combat readiness도 최대 다섯 팀 Challenge run의 준비 완료를 뜻하지 않습니다. 기존 migration V0001~V0005는 checksum 이력으로 보존하고 위 상태는 V0006 이후 새 schema에서 구현합니다.

Phase 2A1 시점에는 season expiry, Quick Battle 또는 daily reset 구현이 없어 되돌릴 로직도 없었습니다. 후속 Phase 2A2 config 계약은 `lastClearLevel=7`, `challengeUnlocked=true`, `seasonAvailability=permanent`, `quickBattle=unsupported`, `dailyReset=asia-seoul-0500/v1`을 명시적으로 고정했습니다. 이 설정에 대응하는 runtime state machine과 API 구현은 Phase 2B 범위입니다.
