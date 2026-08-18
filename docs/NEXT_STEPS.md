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

## 3. Phase 1C — Challenge snapshot importer

구현 순서는 다음과 같습니다.

1. 시즌 40 사치스러운 거미
2. 시즌 7 울트라
3. 시즌 13 인디빌리아
4. 시즌 26 프로비던스
5. 시즌 29 마더웨일 전격 변종
6. 시즌 34 앨트루이아

각 시즌마다 manager→Challenge preset→wave→monster→spot behavior의 authoritative chain, element/weakness, parts, behavior, timeline, selected bundle, runtime hash를 검증합니다. 시즌 14·39와 미해소 후보는 publish하지 않고 diagnostic으로 남깁니다.

완료 기준: 여섯 시즌만 `RaidSnapshot v2`로 publish되고, 같은 입력의 canonical hash가 항상 동일해야 합니다.

## 4. Phase 2A — 캐릭터 build write API

- 합성 local account/session을 구현한다.
- 자유 character level과 immutable build revision을 구현한다.
- T10/+5 네 부위, 큐브 장착·해제 및 자유 레벨, 스킬 10/10/10을 구현한다.
- OL 4×3 line의 exact decimal 추가·교체·삭제를 구현한다.
- 소장품·애장품 max/default와 N/A를 구현한다.
- 5인 squad revision을 구현한다.

완료 기준: 모든 write가 새 revision을 만들고 과거 전투 결과의 참조가 변하지 않아야 합니다.

## 5. Phase 2B — Challenge session backend

- 단일 active supported season을 선택한다.
- 일반 1~7단계는 `lastClearLevel=7` 해금 상태만 제공한다.
- Challenge begin, squad binding, result, trace 저장 계약을 구현한다.
- unsupported season과 runtime mismatch를 fail closed 처리한다.
- harness로 API/DB 계약만 자동 검증한다.

완료 기준: 지원 snapshot과 ready squad만 session을 시작할 수 있고 결과가 정확한 snapshot/build revision을 참조해야 합니다.

## 6. Phase 3 — Original client gate 재감사

- 권리자가 지원·승인한 local/test route의 존재를 재확인한다.
- 합성 session과 공식 outbound zero를 입증한다.
- endpoint/auth 변조, 공식 자격증명, 주입·후킹, 보호 기능 우회 없이 연결 가능해야 한다.

gate가 열리지 않으면 adapter는 blocked이고 최종 인수 조건은 미달입니다. 자체 UI나 harness로 대체하지 않습니다.

## 7. Phase 4 — 실제 전투 검증

- 원본 UI의 캐릭터 상태와 squad 표시를 검증한다.
- 여섯 Challenge의 scene, behavior, animation, QTE, parts를 실제 runtime에서 검증한다.
- 전투 결과와 서버 저장 결과를 교차검증한다.
- 시즌별 compatibility tier를 증거에 따라 승격한다.

## 보류

Union Raid는 위 흐름이 안정화되고 사용자가 다시 범위를 확장한 뒤 시작합니다. 캠페인, 타워, 아레나, 상점, 전초기지는 계속 제외합니다.

## 바로 다음 작업

다음 구현 commit은 **Phase 1C Challenge snapshot importer**입니다. 시즌 40부터 authoritative chain과 selected behavior/timeline/bundle/runtime provenance를 자체 RaidSnapshot으로 정규화합니다.
