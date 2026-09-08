# Phase 3B-2 리소스 기반 구조 변경 대응 계획

> 보관 기록: 2026-09-06 문서 정리 때 이동했습니다. 본문의 ‘현재·다음·미완료’는 작성 당시 기준입니다. 현행 안내는 [문서 색인](../README.md)과 [현재 경로](../MICRON_CURRENT_PATHS.md)를 따릅니다.

## 2026-09-05 실행 상태 갱신

운영자는 151 업데이트 대응 구현 착수를 승인했고, 첫 실제 클라이언트 검증은 **현재 설치된 한국어 음성**으로 선택했습니다. 현재 경로 권위는 `../MICRON_CURRENT_PATHS.md`이며 아래의 Samsung-cold/계획만 허가 문구는 8월 28일 당시 이력입니다. 새 작업의 상세 근거·구현·검증·미해결 조건은 [RESOURCE_COMPATIBILITY_151_PROGRESS.md](RESOURCE_COMPATIBILITY_151_PROGRESS.md)를 따릅니다. 공식 설치본은 읽기 전용으로 조사하며, 기존 150 실행본과 운영 DB를 151로 덮어쓰지 않습니다. 아직 151 actual-play 또는 4/7 해결 완료를 주장하지 않습니다.

## 목적과 근거

2026-08-28 운영자가 제공한 공식 개발자 노트 발췌문에 따르면, 2026년 9월 초 업데이트에서 게임의 **리소스 기반 구조**가 변경될 예정입니다. 향후 부분 다운로드를 지원하기 위한 기반 작업이며, 모든 이용자에게 한 차례 전체 리소스 재다운로드가 발생합니다. 공지는 인게임 리소스 자체가 바뀌는 것이 아니라 리소스 관리 로직과 구조가 바뀐다고 설명합니다.

이 문서는 해당 업데이트가 현재 Phase 3B-2 로컬 compatibility lane에 미칠 수 있는 영향을 기록하고, 업데이트 공개 뒤 추측 없이 재검증하기 위한 계획입니다. 지금 리소스를 다시 취득하거나 현재 runtime을 변경하는 실행 문서가 아닙니다.

## 결정

1. 현재 실제 플레이가 확인된 client build `150.6.9`와 관련 Golden·detached checkpoint는 **불변 대조군**으로 보존합니다.
2. 9월 이후 build는 기존 lane을 덮어쓰지 않고 별도의 **resource-structure migration lane**에서 다룹니다.
3. 공지 하나만으로 API·전투·도메인 구현 전체를 폐기하거나 재작성하지 않습니다.
4. 새 구조의 실제 파일과 client 동작을 관측하기 전에는 경로, 컨테이너 형식, catalog 규칙 또는 부분 다운로드 단위를 추정하지 않습니다.
5. 새 lane은 검증을 통과하기 전까지 Golden으로 승격하지 않으며 기존 D: Golden을 수정하지 않습니다.

## 영향 범위

| 영역 | 기본 판단 | 업데이트 뒤 필요한 조치 |
|---|---|---|
| cache 디렉터리와 파일 배치 | 높은 영향 가능성 | 전체 topology와 member manifest 재측정 |
| `.cat`/`.nds`, SAUS, catalog와 native-cache 연결 | 높은 영향 가능성 | 경로·참조·서명·magic·revision 관계 재확인 |
| content version map과 locale 경로 | 높은 영향 가능성 | `locale/revision` 매핑과 exact pair 재탐색 |
| startup preflight의 파일 수·길이·SHA-256 | 반드시 영향 | 신규 build 기준으로 별도 생성 |
| local static 공급과 cache junction | 구조에 따라 영향 | 기존 표현을 재사용하지 말고 새 topology에 맞춰 검증 |
| static data extraction | 조건부 영향 | 포맷·ID·schema 변화가 관측될 때만 재추출 |
| client bootstrap/API protocol | 조건부 영향 | 별도의 protocol 변화가 관측될 때만 독립 조사 |
| Solo Raid 도메인·정책·서버 route | 원칙적으로 재사용 | 실제 contract 변화가 있을 때만 수정 |
| Regroup `BattleResult=6` 비소모 semantics | 보존 | 새 build에서 회귀 관측만 수행 |
| Normal I~VII clear, Challenge open, daily policy | 보존 | projection 결과만 회귀 확인 |
| 사용자 progression DB 모델 | 원칙적으로 보존 | client 응답 schema 변화가 있을 때만 migration 검토 |

리소스 구조 변경과 같은 시점에 client build나 protocol도 별도로 바뀔 수 있습니다. 그런 변화가 관측되더라도 리소스 공지의 직접 결과라고 단정하지 않고 별도 원인으로 분리합니다.

## migration gate

### Gate 0 — 현재 기준선 동결

- client build `150.6.9`의 현재 도구, server DLL, clean baseline DB, cache 관련 manifest와 actual-play 증거를 보존합니다.
- 기존 full Golden과 detached checkpoint의 해시를 다시 기록하되 내용을 다시 결박하거나 수정하지 않습니다.
- 현재 해결되지 않은 점수 UI 차이는 리소스 구조 변경과 혼합하지 않고 기존 lane의 별도 결손으로 남깁니다.

### Gate 1 — Samsung-cold 읽기 전용 inventory

- 운영자가 명시적으로 허가한 뒤 새 client build와 executable SHA-256을 기록합니다.
- 전체 다운로드 완료 상태의 resource root, 파일 수, content byte length와 source-free manifest를 생성합니다.
- 기존 build와 새 build의 최상위 directory topology, 확장자 분포, version map, catalog와 locale revision 위치를 비교합니다.
- 이 단계에서는 Micron, D: Golden, 기존 cache와 runtime을 변경하지 않습니다.

### Gate 2 — 구조 분류

관측 결과를 다음 중 하나로 분류합니다.

- `path_or_partition_only`: 내용 형식은 같고 경로 또는 분할 단위만 변경
- `container_or_catalog_changed`: container, catalog, signature 또는 version map 형식 변경
- `content_identity_changed`: required asset ID, revision 또는 참조 관계 변경
- `protocol_change_observed`: resource 계층과 별개로 bootstrap/API contract 변화 관측
- `unresolved`: 증거가 부족하여 분류 불가

`unresolved` 상태에서는 새 runtime lane을 만들지 않습니다.

### Gate 3 — source-free closure 재검증

- 시즌 26 classic Solo Raid Challenge에 필요한 manager → preset → wave → monster/stat → client asset closure를 새 구조에서 다시 해소합니다.
- 필요한 locale catalog body/signature pair, resource magic, byte length와 SHA-256을 확인합니다.
- 부분 다운로드가 실제 제공될 경우 required closure가 어떤 download group에 속하는지 관측합니다.
- `SoloRaidMuseum`, Quick Battle, Normal/Union Raid runtime은 계속 대상에서 제외합니다.

### Gate 4 — 파생 transport/bootstrap lane

- Golden 도구를 수정하지 않고 신규 build 전용 파생 start/completion 도구를 만듭니다.
- 새 cache 위치, local static 공급, version projection과 preflight만 최소 변경합니다.
- 공식 로그인·계정·session·token, live traffic 가로채기/replay, injection·hooking·memory patch는 사용하지 않습니다.
- 새 lane 실패 시 기존 `150.6.9` lane으로 되돌아갈 수 있어야 합니다.

### Gate 5 — 실제 플레이 회귀 검증과 승격

- 로비 진입, classic Solo Raid 메뉴, Challenge 전투 진입, Regroup 비소모, 완주와 재진입을 순서대로 검증합니다.
- resource missing, catalogue path, system error와 partial member가 모두 없어야 합니다.
- actual-play 성공과 completion 정리가 확인된 뒤에만 새 detached checkpoint를 D:에 추가합니다.
- 기존 full Golden은 덮어쓰지 않습니다. 새 Golden 승격은 운영자의 별도 승인 사항입니다.

## 수집할 증거

- client version과 executable SHA-256
- resource root topology와 주요 directory 이름
- 전체 file count, content byte length, partial member count
- source-free member manifest SHA-256
- content version map의 위치·길이·SHA-256
- `.cat`/`.nds` 또는 이를 대체한 새 pair의 역할·길이·SHA-256
- SAUS/catalog/native-cache 참조 관계
- locale code와 revision code의 실제 매핑
- required 시즌 26 asset closure의 resolved/unresolved 목록
- startup, server, client와 completion의 cold-state receipt

원본 파일, 복호물, bundle, DB, 계정 자료와 credential은 저장소에 커밋하지 않습니다. Git에는 source-free manifest, 계약, 검사 코드와 합성 fixture만 남깁니다.

## 현재 보존 지점

리소스 구조 변경 공지 전 현재 lane을 보존한 detached v8 checkpoint는 다음과 같습니다.

- 경로: `D:\NikkeLocalLab\Backups\phase3b2-season26-challenge-damage-observer-v8-checkpoint-v1\9ce052ed-3f9d-4674-9025-b3852b51a2fe`
- receipt SHA-256: `d1b3339d6f3a1ddb9f57843d0d684e22ccc83fa5e1276f2cff49a99d85f3e506`
- manifest SHA-256: `4fbbe7132de0ed0d489bdae6f647a0dc98c4559328de057fd4f4dc891dc9b26e`
- 기존 full Golden seal SHA-256: `e4c1f9af044387f1624a828421800b29c9a0aa4c015f4e82f3534f70484ea613`
- 기존 v5 detached seal SHA-256: `e69ee9020abf5c77fc61f433ae56729d36c82c10289b385ee1bdde30604e3753`

v8 checkpoint는 리소스 구조 변경 전 비교 지점이지 새 Golden이 아닙니다. 이 불변 checkpoint에는 당시 unresolved였던 score UI discrepancy도 역사 상태 그대로 보존하며 v9 수정을 backport하지 않습니다. 현재 권위인 v9 lane에서는 manager별 Common prefix wire encoding으로 이 문제가 수정됐고, 2026-08-31 시즌 26 원본 클라이언트 actual play에서 파란 총점과 노란 `My High Score`가 모두 `24,972,784,671`로 일치해 해결 완료 판정을 받았습니다.

## 작업 재개 조건

다음 조건이 모두 충족될 때 이 계획의 실행을 시작합니다.

1. 9월 리소스 구조 변경이 포함된 client build가 실제 배포되었습니다.
2. 운영자가 해당 build의 오프라인 inventory와 migration 분석을 명시적으로 승인했습니다.
3. Samsung-cold에서 새 리소스를 확보하고 Micron은 offline·runtime-cold 상태입니다.
4. 현재 `150.6.9` Golden과 D: backup의 무결성이 먼저 확인되었습니다.

현재 허가된 작업은 이 계획을 문서화하는 것까지입니다. 다운로드, cache 변경, 신규 lane 배포, client/server 실행은 수행하지 않습니다.
