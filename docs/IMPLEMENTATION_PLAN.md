# Implementation plan

이 계획의 최종 인수 조건은 **지원되는 Solo Raid Challenge를 원본 NIKKE UI와 실제 전투 runtime으로 실행하고, 자체 local backend가 캐릭터 상태·전투 세션·결과를 처리하는 것**입니다. lab-owned harness나 별도 대미지 시뮬레이터만으로는 완료로 판정하지 않습니다.

## Phase 0 — 계약과 경계

- 독립 저장소, Git 금지 데이터, 자체 ID, read-only source 원칙을 고정한다.
- `CharacterBuildRevision`, `RaidSnapshot`, compatibility tier 계약을 고정한다.
- `challenge-boss-support/v1`을 스키마와 검증 테스트로 고정한다.
- 원본 client 연결을 fail-closed gate로 분리한다.

완료 조건은 합성 fixture가 schema와 저장소 정책 검사를 통과하고, 시즌 14·39 및 잘못된 속성/약점 조합이 거부되는 것입니다.

## Phase 1 — 오프라인 import와 자체 ID DB

- `C:\NIKKE`를 read-only source로 여는 importer를 만든다.
- 원본 식별자는 ephemeral staging에서만 읽고 자체 UUID로 변환한다.
- 캐릭터 정의, 장비, 큐브, 소장품·애장품의 authoritative 범위와 결손을 import한다.
- 최신 Challenge chain을 따라 시즌 후보를 해소하고 admission policy를 적용한다.
- 허용 후보만 불변 `RaidSnapshot`으로 publish한다.
- 정적 데이터, 선택 bundle, behavior, timeline, runtime의 hash와 compatibility tier를 검증한다.

현재 파생 대상은 시즌 `7, 13, 26, 29, 34, 40`입니다. 시즌 39의 기존 분석 산출물은 참고·재검증 자료로만 사용할 수 있으며 publish하지 않습니다.

## Phase 2 — local backend와 캐릭터 write

Phase 2 전에 Phase 1D에서 Tier 9·10 equipment, cube, collection/favorite, console, OL option의 선택 가능한 자체 definition catalog를 완성했습니다. 이 catalog는 `V0004__combat_support_catalog.sql`을 소유합니다. Tier 1~8은 현재 account 이관·전투 검증 범위에 없으므로 게시하지 않습니다.

완료된 Phase 2A1은 자체 UUID local account/session, account combat state, character build, squad와 profile template의 불변 revision 및 `V0005__local_account_profile.sql`을 포함합니다. character와 combat-support catalog binding은 서로 독립적으로 고정하며 current profile 전환은 optimistic CAS transaction으로만 수행합니다. 단위 및 live PostgreSQL verifier를 모두 통과했습니다.

- (2A1 완료) PostgreSQL migration과 자체 합성 account/session을 구현한다.
- (2A1 완료) synchro와 console level/EXP의 불변 account combat state revision을 구현한다.
- (2A1 완료) 캐릭터 build 생성·조회·부분 수정과 revision 전환용 저장 command/store 계약을 구현한다.
- 자유 레벨, 미장착 또는 T9/T10/+0~5, 큐브 장착·해제/Lv15, 10/10/10, OL exact write, 소장품·애장품 적용 여부를 검증한다.
- (2A1 완료) 5인 squad revision을 구현한다.
- (2B 예정) 단일 active Challenge snapshot과 일반 1~7단계 Challenge 해금 상태를 구현한다.
- (2B 예정) Challenge session begin/result 계약과 재현용 trace 저장을 구현한다.
- (2A2 예정) credential-bearing legacy raw는 offline sanitizer로만 읽고, allowlist field를 source-ID-free profile draft로 변환한다.
- (2A2 예정) 별도 관리 UI는 loopback API를 통해 Save, Save As와 적용 diff를 수행한다.
- (2B 예정) runtime execution profile과 combat control profile을 전투 결과에 고정하고 requested/effective 값을 분리한다.

lab-owned harness는 이 단계에서 API·계약·DB를 자동 검증하는 test client로만 사용합니다.

## Phase 3 — 원본 client compatibility gate

- 권리자가 지원·승인한 local/test endpoint 또는 개발 client가 실제로 있는지 다시 확인한다.
- 공식 자격증명 없이 합성 local session이 가능한지 확인한다.
- endpoint/auth 변조, 주입·후킹, launcher/안티치트 우회 없이 local backend를 선택할 수 있어야 한다.
- 공식 server·telemetry outbound가 0임을 재현 가능하게 검증한다.
- client build/hash별 adapter와 runtime compatibility를 분리해 기록한다.

한 조건이라도 충족하지 못하면 `OriginalClientCompatibilityAdapter`는 계속 blocked입니다. 이 경우 Phase 1·2의 계약 검증은 진행할 수 있지만, 최종 인수 조건은 충족되지 않습니다. 자체 UI나 harness를 완성품으로 대체하지 않습니다.

## Phase 4 — 실제 UI·전투 검증

- 원본 UI에서 로컬 캐릭터·장비·큐브·OL 상태가 정확히 표시되는지 검증한다.
- 허용된 Challenge만 선택·진입 가능한지 검증한다.
- 원본 Spot runtime이 snapshot의 behavior, timeline, part, QTE, animation을 로드하는지 검증한다.
- 시즌별로 `static_exact`부터 가능한 최고 tier까지 증거를 승격한다.
- 전투 결과가 정확한 raid snapshot과 squad/build revision을 참조하는지 검증한다.
- 실패·결손·runtime 불일치는 fail closed 및 진단 가능해야 한다.

## Phase 5 — 선택적 확장

사용자가 범위를 확장한 뒤에만 Union Raid용 encounter/session/result를 추가합니다. 캠페인, 타워, 아레나, 상점, 전초기지는 계속 범위 밖입니다.

## 구현 순서상 금지 사항

- 원본 client gate를 열기 위해 release endpoint/auth 또는 보호 기능을 변조하지 않는다.
- 오래된 요약 테이블 하나만으로 Challenge identity를 정하지 않는다.
- 허용되지 않은 시즌을 임시 실행 가능 snapshot으로 만들지 않는다.
- 원본 ID·경로·파일명을 domain/API/log에 노출하지 않는다.
- runtime 근거가 부족한 시즌을 `historical_runtime_exact`로 승격하지 않는다.
- legacy crawler, 로그인 session 또는 authenticated request replay를 local backend에 이식하지 않는다.
- profile editor가 PostgreSQL, 원본 게임 파일 또는 공식 계정을 직접 수정하게 하지 않는다.
