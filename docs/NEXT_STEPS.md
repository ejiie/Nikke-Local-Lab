# Next steps

최종 목표는 허용된 원본 NIKKE UI와 실제 전투 runtime이 local backend에 연결되어 지원 Challenge를 실행하는 것입니다. 다음 작업은 이 목표에 직접 필요한 순서만 포함합니다.

## 1. Phase 1A — 프로젝트 골격과 import ledger — 완료

- .NET 8 solution과 모듈 경계를 생성했습니다.
- PostgreSQL migration runner와 local configuration loader를 구현했습니다.
- `%LOCALAPPDATA%\NikkeLocalLab` runtime root 경계를 초기화합니다.
- `source_artifact`, `dataset_snapshot`, membership, `import_run`, `import_diagnostic` schema를 구현했습니다.
- source read-only capability와 repository 밖 runtime/staging 경계를 테스트합니다.
- source, dataset, extractor, request, output hash의 canonical 규칙을 구현했습니다.

완료 기준: 합성 source fixture를 import해 자체 UUID snapshot을 만들고, source path·원본 ID·복호물이 DB API와 Git에 나타나지 않아야 합니다.

## 2. Phase 1B — 캐릭터 catalog importer — 완료

- CharacterDefinition과 snapshot version을 import한다.
- 돌파·코어, 호감도, 장비, 큐브, 스킬, 소장품·애장품 applicability를 정규화한다.
- 결손값은 `unresolved`, 미지원은 `not_applicable`로 분리한다.
- authoritative maximum을 `combat-max/v1` factory가 해소할 수 있게 만든다.

완료 기준: 합성 캐릭터와 실제 local snapshot을 같은 domain contract로 검증하되 실제 데이터는 Git 밖에 남아야 합니다.

구현 결과:

- CharacterDefinition/version과 combat-max/v1 도메인 계약을 구현했습니다.
- StaticData와 sd.bin을 같은 immutable dataset으로 관찰하는 strict reader를 구현했습니다.
- source alias는 private HMAC registry로 격리하고 공개 entity/version에는 lab UUID만 사용합니다.
- ledger 완료와 catalog publish를 한 PostgreSQL transaction으로 묶었습니다.
- 실제 설치본에 전체 캐릭터 StaticData가 없음을 확인했으며, 보관된 과거 pack과 현재 config의 혼합 입력은 검증 전용으로만 취급합니다.

## 3. Phase 1C — Challenge snapshot importer — 완료

- manager→Challenge preset→wave group→wave→target/spawn monster의 authoritative chain과 element/weakness를 최신 StaticData에서 해소합니다.
- 정규화한 파츠 관계와 스킬 슬롯 개수·순서는 자체 UUID/ordinal로 `RaidSnapshot v2`에 저장합니다. 스킬 정의 identity와 효과 semantics 정규화는 후속 단계입니다.
- 호환성 tier가 요구하는 증거만 강제합니다. `static_exact`은 미해소 상위 근거를 warning으로 공개하고, `behavior_exact`부터 behavior와 선택 bundle을 요구하며, runtime-exact tier는 runtime·scheduler·관련 clock 근거까지 요구합니다.
- V0003 migration은 import ledger 완료와 immutable snapshot 게시를 한 transaction으로 처리합니다.
- 합성 fixture/CI, canonical hash, rollback 및 source-ID-free receipt를 검증했습니다.
- 최신 실제 StaticData는 원본을 변경하지 않는 local smoke로 읽었으며, 정책상 시즌 `7, 13, 26, 29, 34, 40` 여섯 개만 publish 대상임을 확인했습니다.

현재 증거 상한:

| 시즌 | 최대 tier | 보존하는 결손 근거 |
|---:|---|---|
| 7, 13, 26, 29, 34 | `static_exact` | behavior bundle byte 미확보: `behavior_unresolved` |
| 40 | `behavior_exact` | timeline partial: `timeline_unresolved`; runtime 미평가: `runtime_not_evaluated` |

완료 기준 충족: 여섯 시즌만 publish하며 같은 입력의 canonical hash는 결정적입니다. 여기서 완료는 importer, V0003 원자적 publish, 합성 CI와 실제 read-only smoke의 완료를 뜻합니다. 원본 client 실행, 완전한 timeline, 현재 runtime exact 또는 역사 runtime exact를 뜻하지 않습니다.

## 4. Phase 1D — 전투 보조 catalog — 완료

- Tier 9·10 장비 24개, cube 17종, collection 12종, favorite 21종, console 9종과 OL option 9종을 자체 definition/version으로 publish한다.
- 9개 console 좌표별 source-derived 연속 Level 범위와 level당 flat stat 기여를 정규화한다.
- OL 15개 이산 값과 확률 band를 보존하고, 근거가 없는 동일 옵션 중복 정책만 `unresolved`로 분리한다.
- V0004 migration은 import ledger 완료와 immutable catalog publish를 한 transaction으로 처리한다.
- profile editor가 선택할 수 있는 source-ID-free reference를 제공한다.
- cube·collection·favorite의 item/level 선택은 ready이지만 별도 skill-definition catalog는 아직 없으므로 skill effect semantics는 명시적으로 unresolved다.

완료 기준: profile write가 raw ID나 추측값 없이 모든 전투 보조 항목을 자체 UID로 해소할 수 있어야 합니다.

## 5. Phase 2A1 — account/profile/build revision

- 합성 local account/session을 구현한다.
- synchro와 console level/EXP를 `AccountCombatStateRevision`으로 구현한다.
- 자유 character level과 immutable build revision을 구현한다.
- 미장착 또는 Tier 9·10/+0~5 네 부위, 큐브 장착·해제 및 자유 레벨, 스킬 10/10/10을 구현한다.
- OL 4×3 line의 exact decimal 추가·교체·삭제를 구현한다.
- 소장품·애장품 max/default와 N/A를 구현한다.
- 5인 squad revision을 구현한다.

완료 기준: 모든 write가 새 revision을 만들고 과거 전투 결과의 참조가 변하지 않아야 합니다. 최신 계정 JSON은 필드 coverage와 local acceptance에 사용하되 raw ID·개인값을 fixture나 Git에 넣지 않습니다.

## 6. Phase 2A2 — offline import와 profile editor

- credential-bearing raw에서 허용된 전투 필드만 읽는 offline sanitizer를 구현한다.
- Save, Save As, local account apply diff를 loopback API와 별도 editor에 구현한다.
- 사용자가 별도로 갱신한 최신 raw를 네트워크 없이 다시 읽는 refresh command를 구현한다.

완료 기준: raw의 장착 상태와 OL `(slot, line, type, value, unit)`가 source-ID-free draft로 무손실 변환되고, 재가져오기가 local edit를 자동 덮어쓰지 않아야 합니다. Local Lab은 외부 crawler를 실행하지 않습니다.

## 7. Phase 2B — execution profile과 Challenge session backend

- 단일 active supported season을 선택한다.
- 일반 1~7단계는 `lastClearLevel=7` 해금 상태만 제공한다.
- Challenge begin, squad binding, result, trace 저장 계약을 구현한다.
- unsupported season과 runtime mismatch를 fail closed 처리한다.
- target FPS/fixed delta/time scale, graphics와 combat-control profile을 session에 고정한다.
- graphics/FPS/VSync/resolution과 PC `UsePcAimSync`, 조준 보조·조건부 강도, 감도, `MaxPerShotCorrect`를 필수 입력으로 검증한다.
- auto combat과 auto burst는 optional로 두고 수동 전투 readiness와 분리한다.
- 원본 ESC UI의 client-local 누적 damage 경로를 보존하고 관측 snapshot과 현재 setting revision을 저장한다. mid-battle 변경은 요청 frame과 effective resume frame을 구분해 execution segment로 기록한다.
- 요청 설정과 실제 frame-time telemetry를 분리해 기록한다.
- harness로 API/DB 계약만 자동 검증한다.

완료 기준: 지원 snapshot과 ready squad만 session을 시작할 수 있고 결과가 정확한 snapshot/build revision을 참조해야 합니다.

계정 JSON은 roster/build/console seed에 사용합니다. 그래픽 품질, FPS, VSync, 해상도, 마우스 동기화, 조준 보정과 ESC 누적 damage/segment는 JSON에 없으므로 별도 runtime setting adapter와 실제 실행 관측이 필요합니다.

## 8. Phase 3 — Original client gate 재감사

- 권리자가 지원·승인한 local/test route의 존재를 재확인한다.
- 합성 session과 공식 outbound zero를 입증한다.
- endpoint/auth 변조, 공식 자격증명, 주입·후킹, 보호 기능 우회 없이 연결 가능해야 한다.

gate가 열리지 않으면 adapter는 blocked이고 최종 인수 조건은 미달입니다. 자체 UI나 harness로 대체하지 않습니다.

## 9. Phase 4 — 실제 전투 검증

- 원본 UI의 캐릭터 상태와 squad 표시를 검증한다.
- 여섯 Challenge의 scene, behavior, animation, QTE, parts를 실제 runtime에서 검증한다.
- 전투 결과와 서버 저장 결과를 교차검증한다.
- 시즌별 compatibility tier를 증거에 따라 승격한다.

## 보류

Union Raid는 위 흐름이 안정화되고 사용자가 다시 범위를 확장한 뒤 시작합니다. 캠페인, 타워, 아레나, 상점, 전초기지는 계속 제외합니다.

## 바로 다음 작업

다음 구현 commit은 **Phase 2A1 account/profile/build revision**입니다. 최신 계정 capture에서 확인한 실제 필드 shape를 source-free 합성 fixture로 재현하고, 자체 UUID 기반 account state와 immutable build/squad revision을 구현합니다.
