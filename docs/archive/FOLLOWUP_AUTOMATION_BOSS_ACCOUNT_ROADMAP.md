# 후속 자동화·보스·계정 관리 로드맵

> 보관 기록: 2026-09-06 문서 정리 때 이동했습니다. 본문의 ‘현재·다음·미완료’는 작성 당시 기준입니다. 현행 안내는 [문서 색인](../README.md)과 [현재 경로](../MICRON_CURRENT_PATHS.md)를 따릅니다.

## 1. 목표

Phase 3B-2에서 확보한 실제 client 실행 기반을 다음 세 방향으로 확장한다.

1. 일반적인 client/static-data 업데이트와 보스 추가를 반복 가능한 파이프라인으로 자동화한다.
2. 시즌 29 `Mother Whale` 변종과 시즌 34 `Altruia`를 실제 플레이 가능한 보스로 추가한다.
3. 여러 local account를 생성·불러오기·편집·저장·다른 이름으로 저장하고, 선택한 계정으로 게임을 실행하는 관리 프로그램을 만든다.

이 문서는 사용자가 직접 지정한 세 가지 후속 작업을 구현 순서로 정리한다. 9월의 리소스 기반 구조 전환은 별도 문서인 [PHASE3B2_RESOURCE_STRUCTURE_MIGRATION_PLAN.md](PHASE3B2_RESOURCE_STRUCTURE_MIGRATION_PLAN.md)에서 다룬다. 여기서 말하는 업데이트 대응은 평상시 발생하는 client build, static data, character/equipment catalog와 server contract 변화에 대한 반복 작업의 자동화다.

위 세 항목과 지정 보스·편집 필드·`getFromBlaLink.py` 사용은 사용자 요구다. 이 문서의 pipeline 단계, 계약 이름, 화면 배치와 구현 순서는 그 요구를 달성하기 위한 설계안이며 구현 과정의 관측 결과에 따라 조정할 수 있다.

## 2. 현재 재사용 가능한 기반

### 2.1 보스와 시즌

시즌 29와 시즌 34는 현재 지원 directory와 `RaidSnapshot`에 이미 포함되어 있다.

| 시즌 | 대상 | 현재 단계 | 추가로 필요한 것 |
|---|---|---|---|
| 29 | Mother Whale 전격 변종 | `static_exact` snapshot과 directory member 존재 | behavior/runtime closure, selected manager, client asset closure, actual-play 검증 |
| 34 | Altruia | `static_exact` snapshot과 directory member 존재 | behavior/runtime closure, selected manager, client asset closure, actual-play 검증 |

따라서 두 보스 모두 domain model부터 새로 만드는 작업이 아니다. 시즌 26에서 수작업으로 진행한 closure → manager → derived runtime → 실제 client 검증 절차를 파라미터화하는 것이 핵심이다.

### 2.2 계정과 니케 build

현재 코드에는 다음 데이터 구조가 이미 존재한다.

| 사용자 요구 | 현재 기반 |
|---|---|
| 계정별 닉네임·지휘관 레벨 | lobby presentation revision |
| 싱크로 레벨과 아홉 console 레벨·경험치 | account combat state revision |
| 니케 레벨·돌파·코어·호감도 | character investment revision |
| 스킬 1·스킬 2·버스트 | character skill state |
| 네 장비 슬롯, 등급·강화·manufacturer 상태 | character equipment state |
| 장비별 최대 세 줄 오버로드 옵션과 수치 | overload line state |
| 소장품·애장품 선택과 레벨 | collectible state |
| `Save` | 현재 local account에 새 immutable revision 저장 |
| `Save As` | 현재 profile을 다른 local account/revision으로 복제 |
| account/bootstrap 조회 | profile management API와 기존 editor |

가장 큰 결손은 데이터 모델보다 관리 UI, 이름 있는 다중 계정 목록, fetch 결과 병합, progression 편집·조회와 선택 계정 실행의 연결이다.

### 2.3 계정 정보 fetch 입력

첨부된 `getFromBlaLink.py`를 fetch 구현의 출발점으로 사용한다. 다음 동작은 버리지 않고 adapter 설계에 반영한다.

- 계정별 로그인 입력과 region 선택
- `CheckLogin` 확인과 명시적인 종료 코드
- `GetUserCharacters` roster 수집
- `GetUserCharacterDetails` batch 수집
- `GetUserEquipDetails` 응답 수집
- profile/basic-info를 포함한 초기 packet 수집
- roster 대비 detail 수가 부족하면 성공 결과를 덮어쓰지 않는 completeness 검사
- 영문 character dictionary와 CDN metadata 수집 기능

fetch worker와 Local Lab account 저장 core는 분리한다. `getFromBlaLink.py`는 versioned fetch artifact를 만드는 worker로 사용하고, Control Center는 그 artifact를 검증·가져온다. 이 경계 덕분에 fetch 방식이 바뀌어도 local account revision과 Save/Save As 형식은 바뀌지 않는다.

기존 `nikke_full_scroll_result.json` 처리 코드도 함께 사용한다.

- `basic_info.progress_normal_campaign`
- `basic_info.progress_hard_campaign`
- `basic_info.progress_easy_campaign`
- 지휘관 레벨과 profile 표시 정보
- roster, 캐릭터 상세, 장비 상세

스테이지·메인 퀘스트 쪽은 기존 progression 추출을 합친다.

- Normal·Hard·Story 마지막 stage
- `NKSD_TRIGGER_*`의 Campaign/Chapter/MainQuest 관련 record
- `MainQuestClear`를 `MainQuestData`로 변환하는 기존 projection
- `CompletedScenarios`, `ContentsOpenUnlocked`, tutorial과 progression projection

fetcher가 수집한 raw 결과와 Local Lab에 적용할 account snapshot은 분리한다. 한 번의 fetch에는 고유 UID, 수집 시각, source hash, roster/detail 수, completeness 상태를 붙이며, 불완전한 fetch는 직전 정상 snapshot을 교체하지 않는다.

## 3. 목표 프로그램: NLL Control Center

관리와 실행을 하나로 묶은 Windows 프로그램을 만든다. 기존 loopback Admin API와 profile editor를 확장하여 core 저장 로직을 중복 구현하지 않는다.

### 3.1 화면 구성

#### Accounts

- `계정_1`, `계정_2`, `계정_3`처럼 사용자가 지정한 local display label 목록
- 신규 계정, 복제와 이름 변경
- 현재 revision, 마지막 fetch 시각, 마지막 실행 결과 표시
- `Fetch`, `Save`, `Save As`, `Launch` 버튼

#### General

- 닉네임
- 지휘관 레벨
- 싱크로 레벨
- 아홉 console별 level/experience
- Normal·Hard·Story 진행도
- main quest와 scenario projection 요약

#### Nikkes

- 이름, rarity, weapon 등으로 roster 검색·필터
- 니케별 레벨, 돌파, 코어, 호감도
- 스킬 1·스킬 2·버스트
- 머리·몸통·팔·다리 장비의 등급과 강화
- manufacturer 일치 여부
- 오버로드 1~3번 줄의 옵션 종류와 정확한 수치
- 소장품 또는 애장품과 레벨
- 여러 니케에 동일 규칙을 적용하는 bulk edit

#### Solo Raid / Launch

- 사용할 local account 선택
- 시즌 26, 시즌 29, 시즌 34 등 publish된 보스 선택
- 실행 전 diff와 validation 결과 표시
- start 실행, client 상태 표시, client 종료 뒤 completion 실행
- 실패 시 마지막 정상 revision과 실행 receipt로 되돌리기

### 3.2 저장 의미

- `Save`: 현재 선택된 account의 expected revision을 기준으로 새 revision을 만든다.
- `Save As`: 현재 편집 결과를 새로운 account label과 account UID로 복제한다.
- `Fetch`: `getFromBlaLink.py`와 progression fetch 결과를 새 fetched snapshot으로 만들고, 현재 local account와의 diff를 보여준다. 사용자가 적용하기 전에는 current revision을 바꾸지 않는다.
- `Launch`: 선택된 account revision, selected season, runtime build와 tool manifest를 하나의 launch context로 고정한 뒤 실행한다.

저장과 실행을 분리하여 `Save`만으로 Micron runtime이 즉시 바뀌지 않게 한다. `Launch` 시 선택된 revision을 runtime DB에 투영하고, 종료 후 completion이 runtime을 정리한다.

### 3.3 다음 작업 후보와 현재 우선순위

운영자 논의 기준의 다음 작업 후보는 다음 순서로 둔다.

1. **Save As 완결**
   - 통합 `Save`는 실제 사용 확인이 끝났으므로 다시 범위를 넓히지 않는다.
   - `BE-005`의 fetch observation provenance 보존, 새 account의 독립 revision history,
     실행 candidate와 Solo Raid 상태의 account 분리를 실제 Save As 시나리오로 검증한다.
2. **추가 Solo Raid 보스**
   - 시즌 29 Mother Whale 변종을 먼저 publish·실행하고 시즌 34 Altruia로 일반성을 검증한다.
   - 시즌 26 하드코딩 제거와 boss-add pipeline을 이 단계에서 함께 진행한다.
3. **보스 선택 UX와 속성 variant 논의**
   - 클라이언트 선실행 뒤 보스를 바꾸는 warm-session 구조와 보스 속성 variant의 허용
     범위를 아래 gate로 검증한다.

이 순서는 후보이며, 보스 선택 UX를 먼저 구현했다는 뜻이 아니다.

### 3.4 보스 속성을 변경하는 기능

현재 `RaidSnapshot`은 `boss_element`, `weakness_code`, boss variant, Challenge encounter,
Static Data·asset·runtime provenance를 content hash로 묶은 immutable snapshot이다.
`challenge-boss-support/v1`은 시즌 40 예외를 제외하면 전격 보스/철갑 약점만 publish할 수
있다. 이 값은 admission metadata이자 검증 결과이지 실행 중 보스 속성을 바꾸는 knob가
아니다.

현재 원본 전투 runtime의 후보 입력에는 다음 Static Data가 함께 관여한다.

- `MonsterRecord.ElementId`
- `MonsterModelRecord.Attribute` — 시즌 29에서 실제 element와 일치하지 않는 별도 분류로
  확인됐으므로 속성 variant의 변경 knob에서는 제외한다.
- `MonsterRecord`의 energy/metal/bio resist ratio
- `MonsterStatEnhanceRecord`의 level HP/attack/defence와 level resist 값
- manager → preset → Challenge wave → monster/stat chain

어느 필드가 화면 아이콘, 약점 판정, 실제 대미지 공식의 최종 권위인지 같은 값으로
추정하지 않는다. 원본 client actual-play로 각 변경의 효과를 분리 확인해야 한다.

속성 실드가 있는 보스는 기본 속성과 실드 판정을 별도 축으로 취급한다. 현 Static Data
schema에는 `FunctionType.ImmuneOtherElement`뿐 아니라 속성별 면역·감소 함수와 barrier
면역 함수가 따로 존재한다. 또한 `MonsterRecord`와 `MonsterPartsRecord`는 각각 저항값과
`PassiveSkillId`를 가질 수 있고, monster skill은 use/hurt function ID를 통해 state effect와
function chain을 참조한다. 따라서 `MonsterRecord.ElementId`만 바꿔도 실드가 자동으로 새
속성을 따를 것이라고 선결하지 않는다.

속성 variant는 다음 세 등급으로 나눠 검증한다.

1. `affinity_only`: 시즌 26 Providence처럼 속성 실드가 없는 보스. 기본 속성·약점·저항과
   화면 표시가 함께 바뀌는지 확인한다.
2. `dynamic_shield_binding`: 실드 함수가 현재 monster element/weak element를 동적으로
   참조한다는 것이 실제 row와 actual-play에서 확인된 보스. element chain 변경 뒤 오속성
   차단과 유효 속성 관통이 함께 이동해야 한다.
3. `explicit_shield_binding`: 패시브·state effect·function value 또는 파츠 데이터에 특정
   속성이 고정된 보스. 기본 속성뿐 아니라 해당 참조 chain과 필요한 실드 표시·effect까지
   하나의 derived variant로 함께 바꿔야 한다.

실드 색상·아이콘·effect가 asset/timeline에 고정돼 있고 안전한 data-only 결박을 찾지 못한
경우에는 `asset_bound_unresolved`로 fail closed한다. 이 경우 속성 수치만 바꾼 variant는
publish하지 않는다.

따라서 결론은 다음과 같다.

- **기존 공식 variant 선택:** 가능하다. 해당 manager/static/asset closure가 있는 variant를
  새 immutable `RaidSnapshot`으로 publish하고 선택한다.
- **같은 보스의 속성을 실행 중 임의 변경:** 현 구조에서는 불가능하며 지원하지 않는다.
- **사용자 정의 속성 variant:** 기술적으로 검토할 수 있으나 단순 DB 한 칸 수정이 아니다.
  봉인된 local client lane에 derived Static Data variant를 만들고 새 snapshot·content hash·
  admission policy version·asset/runtime 검증과 rollback을 갖춰야 한다. 공식-current 설치는
  수정하지 않는다.

권장 UX는 자유 입력값이 아니라, 실제로 검증·publish된 `보스 variant` 목록에서 고르는
방식이다. HP/공격/방어/속성/약점 등 사용자 정의 knob를 허용하려면 각 knob의 원본 runtime
효과가 확인된 뒤 versioned variant editor로 별도 설계한다.

시즌 29 Mother Whale의 실제 Static Data를 우선 대조한 결과, 속성 실드는 본체 파츠의
passive state effect와 여러 monster skill이 같은 `FunctionType.ImmuneOtherElement` 함수군을
적용·재적용하는 구조다. 해당 함수군의 `FunctionValue=10000`은 면역 비율이고, 함수 row에는
허용 공격 속성 ID가 없다. 따라서 특정 속성을 function에 고정한 `explicit_shield_binding`이
아니라, 대상 monster의 현재 element/weak-element 관계를 runtime이 읽는
`dynamic_shield_binding`으로 판정한다.

단, 이 판정과 연출은 분리된다. 시즌 29의 적용·재적용 함수에는 전격 실드용 보라색 FX
prefab이 직접 결박돼 있다. 그러므로 `MonsterRecord.ElementId`를 다른 기존 element row로
바꾸면 실드가 허용하는 약점 속성은 동적으로 이동할 가능성이 높지만, FX는 자동으로 다른
색으로 바뀌지 않는다. 새 variant는 element chain과 함께 적합한 shield FX binding도
versioning해야 한다. 기능적 동적 결박은 Static Data에서 해소됐지만 최종 `ready` 판정은
원본 client actual-play로 오속성 차단·새 약점 속성 관통·FX 색상·점수 일치를 확인한 뒤
내린다.

현재 봉인 client의 Addressables catalog와 local cache를 대조한 결과, 공용
red/blue/green/purple/yellow immune-barrier prefab은 모두 key→entry→bundle로 해소되고 각
bundle byte도 local closure에 존재한다. 시즌 29 boss 전용 계열은 purple과 blue prefab이
확인됐으며 같은 FX target/socket profile을 사용한다. 따라서 pre-launch variant에서는
purple/blue는 boss 전용 prefab을 우선하고, red/green/yellow는 공용 prefab 이름만 시즌 29
적용·재적용 function row에 대입한다. `FunctionType`, value, target, socket, duration과 skill
reference는 변경하지 않는다. 공용 prefab은 S29 전용 bundle과 별도 bundle에 있으므로 선택한
색상의 bundle을 variant asset manifest에 추가하고, actual-play에서 크기·부착 위치만 확인한다.

시즌 29 속성 저지 변형의 화면 수용 조건은 다음처럼 더 좁게 고정한다. 선택 속성의 본체
실드 FX만 원본 전격 boss-specific 실드 FX의 실제 크기와 transform을 기준으로 정규화한다.
임의 배율이나 보스별 눈대중 보정값은 두지 않는다. QTE의 노랑·빨강 원, collider, 위치,
시간 제한과 animation은 원본 row 및 prefab 값을 그대로 보존한다. QTE 쪽 변경은 시즌 29
대상 monster 세 개에 결박된 `QuickTimeEventRecord` 다섯 row의 `ElementId`와 그에 따른
속성 색상·면역 판정에만 한정한다. 다른 monster/QTE row나 공용 QTE prefab의 geometry는
변경하지 않으며, target cardinality·원본 row hash·변경 필드 집합이 맞지 않으면 변형 전에
fail closed한다.

첫 actual-play 검증은 시즌 26보다 시즌 29 원본·변경 variant 비교를 우선한다. 비교 항목은
약점 UI, 본체와 파츠의 오속성 차단, 유효 속성 관통, 실드 effect, official damage와 결과
점수 일치다. 시즌 26은 이후 비실드 boss 회귀 표본으로만 사용한다.

### 3.5 클라이언트를 먼저 실행한 뒤 보스 선택

현행 방식은 다음 이유로 pre-launch 선택만 가능하다.

- 실행 coordinator와 execution-state 계약이 `seasonNumber=26`을 요구한다.
- materializer/capture 명령도 시즌 26을 launch context에 고정한다.
- Epinel의 trusted target validator는
  `ClassicSoloRaidTargetObservationContract.Season26` 하나에 고정돼 있다.
- 선택 manager는 `EPINELPS_CLASSIC_SOLO_RAID_MANAGER_ID`로 listener 시작 전에 write-once
  결박된다. listener가 시작된 뒤 같은 경로로 바꾸면 `ListenerAlreadyStarted`다.
- preflight는 Epinel/client runtime이 cold가 아니면 `phase_d_runtime_not_cold`로 거부한다.

이 때문에 현재 구조에서 클라이언트를 먼저 켜고 Control Center에서 보스만 바꾸는 것은
UI 버튼 추가로 해결되지 않는다.

다만 **Control Center에서 보스를 선택하고, 이미 실행 중인 원본 클라이언트가 Solo Raid
메뉴를 다시 열어 새 보스를 받는 방식**은 구조 개편 후 가능성이 있다. 다음 조건을 모두
충족하는 warm-session switch로 제한한다.

1. 실행 전에 지원 보스 전체의 필요한 Static Data·asset closure를 local runtime에 stage한다.
2. startup 환경변수 대신 account-scoped, revisioned `selected raid snapshot` 저장소와
   원자적 switch API를 둔다.
3. season별 trusted target validator와 ranking prefix를 선택 snapshot에서 동적으로 해소한다.
4. 보스별 최고 기록과 진행 상태를 `(account, raid snapshot, client build)`로 계속 분리한다.
5. 열린 Challenge run이 없고 클라이언트가 전투/편성 화면이 아닌 lobby에 있을 때만
   switch를 허용한다.
6. switch 뒤 `/soloraid/getperiod`, `/soloraid/get`, ranking/log 응답이 같은 selection
   revision을 사용하게 한다.
7. 원본 클라이언트가 manager를 cache한다면 Solo Raid 메뉴 재진입으로 갱신되는지 먼저
   관측하고, 갱신되지 않으면 loading/login 재진입을 요구한다. 프로세스 재시작 없이 항상
   된다고 선결 주장하지 않는다.

반면 **수정하지 않은 원본 NIKKE Solo Raid 화면 자체에 임의의 다중 시즌 보스 선택기를
추가하는 것**은 현재 protocol/UI 근거가 없다. 원본 UI는 활성 manager 하나를 전제로 하므로
이 요구는 client UI 수정 없이는 지원 가능하다고 보지 않는다. 우선 검증 대상은 원본 UI를
유지하면서 Control Center가 lobby 상태의 active boss를 바꾸는 방식이다.

## 4. 자동화 파이프라인

### 4.1 공통 pipeline engine

먼저 기존 수작업 PowerShell들을 다음 공통 단계로 추상화한다.

1. `inventory`: 입력 build, static data, catalog, server source와 runtime fingerprint 수집
2. `diff`: 직전 정상 manifest와 새 입력의 구조·schema·content 차이 분류
3. `project`: character/combat-support/raid/account projection candidate 생성
4. `validate`: static reference, canonical hash, DB round-trip와 허용 범위 검사
5. `build`: 파생 server와 start/completion tool 생성
6. `stage`: Golden을 수정하지 않고 versioned candidate lane 배치
7. `run`: 선택된 account와 boss로 단일 검증 실행
8. `complete`: 로그·DB·hosts·firewall·runtime 정리와 receipt 생성
9. `promote`: 성공 확인 뒤 현재 active candidate 포인터 갱신
10. `backup`: 실제 플레이 확인 뒤에만 D: detached checkpoint 추가

각 단계는 같은 입력에 대해 재실행 가능해야 하며, 성공 산출물이 이미 있으면 hash를 확인하고 재사용한다. 실패는 해당 단계에서 멈추며 뒤 단계를 자동 실행하지 않는다.

### 4.2 일반 업데이트 대응 pipeline

일반 업데이트마다 다음을 자동 수행한다.

1. 이전 build와 새 build의 executable, static pack, catalog와 required runtime 파일 fingerprint 비교
2. character, equipment, overload, collection/favorite, console와 raid table schema 변화 감지
3. 기존 account revision이 새 catalog에서 그대로 유효한지 검사
4. ID·definition revision이 바뀐 항목의 rebase candidate와 unresolved 목록 생성
5. 지원 보스별 snapshot/manager/asset closure 회귀 검사
6. unit, selected-manager, API, PostgreSQL과 source-free contract 검사
7. 변경된 부분만 포함한 derived runtime candidate 생성
8. 로비 → Solo Raid 메뉴 → 전투 → completion smoke test 목록 생성

자동화의 결과는 `no_change`, `compatible_rebuild`, `rebase_required`, `runtime_revalidation_required`, `blocked_unresolved` 중 하나로 분류한다. 이 분류와 정확한 diff가 Control Center의 Update 화면에 표시되게 한다.

### 4.3 보스 추가 pipeline

보스 하나를 추가할 때 season number를 입력으로 받아 다음 산출물을 만든다.

1. 해당 season의 manager, preset, Challenge wave와 monster/stat chain
2. parts, skill slots, behavior와 runtime evidence closure
3. required client asset과 locale presentation closure
4. immutable `RaidSnapshot` candidate와 content hash
5. selected-manager source patch 또는 data-driven registration
6. focused tests와 source-free receipt
7. parent Golden을 건드리지 않는 boss-specific derived lane
8. original client actual-play checklist와 completion 도구

시즌 29를 첫 파이프라인 검증 대상으로 삼고, 같은 명령과 schema로 시즌 34를 처리한다. 시즌 29 전용 하드코딩이 생기면 시즌 34에서 바로 드러나므로 두 번째 보스까지 성공해야 boss-add pipeline이 완성된 것으로 본다. 기존 시즌 26 외에 추가 publish하는 Solo Raid는 시즌 29와 시즌 34뿐이다. 과거 catalog의 시즌 7·13·40은 역사 contract/fixture 검증 대상으로만 보존하며 Control Center의 지원 boss 목록이나 새 실행 lane에 넣지 않는다.

## 5. 구현 순서

### Phase A — 요구 schema와 pipeline manifest

1. `FetchedAccountSnapshot/v1`, `AccountWorkspace/v1`, `UpdateAssessment/v1`, `BossCandidate/v1`, `LaunchContext/v1` 계약을 정의한다.
2. 현재 수작업 script의 입력·출력·receipt를 단계별 manifest로 정리한다.
3. 동일 입력 재실행, 부분 실패 재개와 rollback을 공통 pipeline state machine으로 만든다.

완료 기준은 아직 UI가 없어도 한 manifest가 현재 season 26 lane을 inventory → validate → stage 직전까지 재현하는 것이다.

#### Phase A 구현 상태 — 2026-08-28

첫 baseline은 구현·검증됐다.

- 계약: `FetchedAccountSnapshot/v1`, `AccountWorkspace/v1`, `UpdateAssessment/v1`, `BossCandidate/v1`, `LaunchContext/v1`
- 공통 실행 계약: `PipelineRunManifest/v1`, step receipt, run state와 read-only `StagePlan/v1`
- 상태 전이: 성공 receipt의 exact replay 재사용, 성공 step 산출물 drift 거부, 실패 step 재시도, dependency gate와 rollback action 명시
- 기준 manifest: D:의 시즌 26 damage-observer v8 detached checkpoint를 12개 exact member의 길이·SHA-256으로 고정
- 재현 결과: `inventoryMatched=true`, `stageReady=true`, `mutationPerformed=false`, planned/rollback action 각 3개
- 자동 검증: `scripts/verify-automation-phase-a.ps1`과 focused unit test 12개

여기서 `stageReady`는 stage를 실행했다는 뜻이 아니다. D: checkpoint를 읽기만 하여 입력과 계약을 검증했고, Micron이나 Golden을 변경하지 않은 상태에서 다음 mutation과 역순 rollback을 계획할 수 있다는 뜻이다. 따라서 Phase A의 완료 기준인 “stage 직전”까지만 충족하며, 실제 배치·실행·승격은 후속 단계의 별도 승인과 actual-play 검증 대상으로 남긴다.

### Phase B — 계정 관리 core와 UI

1. 사람이 읽을 수 있는 account label과 account 목록 API를 추가한다.
2. 기존 profile editor를 니케·장비·OL·소장품 전용 form으로 확장한다.
3. General과 progression 탭을 추가한다.
4. `Save`, `Save As`, diff preview와 validation을 UI에서 완결한다.
5. 선택된 account revision을 runtime projection candidate로 내보낸다.

완료 기준은 `계정_1`을 편집하고 `계정_2`로 Save As한 뒤 두 계정이 독립 revision history를 유지하는 것이다.

#### Phase B 구현 상태 — 2026-08-29

구현 baseline, 자동 검증 gate와 live PostgreSQL acceptance까지 완료됐다.

- `V0008__account_workspace.sql`: 기존 immutable profile/account-state revision graph를 바꾸지 않고 사람이 읽을 수 있는 account label, Save As parent와 후속 fetch/launch 상태를 별도 management metadata로 추가
- API: account 목록, workspace 조회, label 변경, 독립 revision history 조회와 선택 revision의 runtime projection candidate export
- 저장 의미: `Save`는 기존 account의 새 immutable revision을 만들고, `Save As`는 새 account UID·label을 만들며 원본 account UID를 parent로만 기록
- UI: Accounts, General, Nikkes, Progression, Advanced 탭과 `Save`, `Save As`, diff preview, validation, label 변경, revision history와 runtime candidate export
- 전용 편집: 지휘관·싱크로·console과 니케 투자·스킬·장비·오버로드·소장품 좌표를 기존 profile value/edit-operation 계약 위에서 편집하며, 별도 mutable game table을 만들지 않음
- 계약: `AccountWorkspace/v1`과 `RuntimeProjectionCandidate/v1`
- 자동 검증: Admin API 단위 시험 25개, V0008 migration shape 시험 1개, editor JavaScript 문법 검사, 전체 solution build
- 자동 검증 receipt: `nll/automation-phase-b-verification/v1`; Golden, Micron runtime, game revision mutation은 모두 0

2026-08-29에 Windows-native PostgreSQL `17.11` disposable cluster로 live 승인 시나리오를 실행했다. `계정_1` Save → `계정_2` Save As → 두 account의 서로 다른 후속 character-level edit → 양쪽 revision history와 runtime candidate 독립성 검사가 통과했다. acceptance UID는 `57535125-f0b3-4467-8695-c85c954a20d7`이며 종료 후 PostgreSQL process/listener와 disposable data는 모두 `0`이었다. Golden과 game runtime은 변경하지 않았다. 따라서 Phase B는 실제 DB 완료 기준까지 충족했다. Phase C의 외부 fetch는 아직 연결하지 않았으며 Progression 탭은 현재 revision binding만 표시한다.

Phase B 이후의 local PostgreSQL 검증은 [WINDOWS_NATIVE_POSTGRESQL_RUNTIME.md](../operations/WINDOWS_NATIVE_POSTGRESQL_RUNTIME.md)의 native Windows PostgreSQL 17 on-demand runtime을 사용한다. Docker Desktop의 Hyper-V backend, WSL2와 Docker VMM은 local acceptance 경로에서 제외한다. PostgreSQL은 Windows service로 자동 시작하지 않으며 검증 process가 시작·종료를 소유한다. 게임 실행 preflight는 Docker backend, hypervisor용 VM과 `postgres.exe`가 실행 중이면 fail closed한다.

### Phase C — fetch 통합

1. `getFromBlaLink.py` 출력을 versioned raw fetch result로 정리한다.
2. roster/detail/equipment/basic-info를 `FetchedAccountSnapshot/v1`로 변환한다.
3. 기존 stage/main-quest/progression 추출 결과를 같은 snapshot에 병합한다.
4. fetch completeness, 중복 캐릭터, 누락 장비와 catalog mismatch를 검사한다.
5. 현재 account와 fetched snapshot의 field-level diff를 표시하고 선택 적용한다.

완료 기준은 fetch한 한 계정의 모든 roster detail 수가 일치하고, 적용 뒤 다시 fetch했을 때 의도한 local edit와 source 값의 차이를 정확히 구분하는 것이다.

#### Phase C 기반 구현 상태 — 2026-08-29

source-free snapshot 생성·보관·검토·선택 적용의 기반과 live PostgreSQL acceptance까지 구현했다. 이 상태는 Phase C 전체 완료가 아니라, 운영자 fetch를 안전하게 받아들이기 위한 기반 완료다.

- 계약: `FetchedAccountSnapshot/v1`, 요약 호환용 `FetchedProgressionObservation/v1`, 다섯 progression dataset과 각 provenance를 표현하는 `FetchedProgressionObservation/v2`를 추가했다. snapshot은 계정 기본 관측, progression 요약, 9종 console, 니케 build, 장비·오버로드, cube와 소장품 좌표 및 completeness를 표현한다.
- 원본 경계: credential-bearing fetch JSON은 read-only 입력으로만 열며 path, raw hash, 공식 user identifier, token·session과 알 수 없는 원본 필드를 snapshot·receipt·DB에 남기지 않는다. source fingerprint는 raw JSON이 아니라 canonical sanitized draft에 대해서만 계산한다.
- 실제 로컬 표본의 read-only coverage 관측: roster `193`, detail `193`, equipment coordinate `772`, console `9`로 내부 개수는 일치했다. 이후 client 화면에서 보인 `198`과의 차이는 임의 보정하지 않고 다음 운영자 fetch에서 재관측할 항목으로 남겼다.
- completeness: roster/detail/build/equipment 개수 불일치, 중복 character, display name·commander level·progression 결손, catalog resolution 문제와 write readiness를 reason code로 보존한다. incomplete/failed snapshot도 감사 이력에는 저장할 수 있지만 현재 account fetch pointer를 교체하지 않는다.
- 저장소: PostgreSQL `V0009__fetched_account_snapshot.sql`에 immutable snapshot table과 account-scoped current pointer를, `V0010__fetched_progression_observation.sql`에 snapshot UID를 PK/FK로 공유하는 immutable v2 progression sidecar를 추가했다. complete snapshot만 current가 되며, snapshot과 sidecar의 같은 입력 replay는 idempotent하다.
- 선택 적용: fetched snapshot은 canonical sanitized draft에 연결되고 기존 `/import-drafts/{draftUid}/diff`와 `/apply`를 그대로 사용한다. 별도 mutable game table이나 우회 write 경로를 만들지 않았다.
- Control Center: source-free snapshot JSON과 canonical sanitized draft JSON, 선택적인 canonical `FetchedProgressionObservation/v2`를 함께 등록하고 completeness를 확인한 뒤 기존 field-level diff/selective apply 화면으로 이어지는 API와 UI를 추가했다. sidecar가 있으면 snapshot UID·capture time·네 summary field와 reason-code 포함 관계를 서비스에서 검증한 뒤 같은 transaction으로 저장한다.
- CLI: `fetched-progression-observation-materialize`가 legacy private source와 선택 derived candidate를 읽기 전용으로 정규화하고, `fetched-account-snapshot-materialize`가 snapshot UID가 정확히 일치하는 v2 sidecar만 canonical snapshot directory에 hash 결박한다. raw payload 자체는 복사하지 않는다.
- live acceptance: Windows-native PostgreSQL `17.11` disposable cluster에서 complete current 전환, incomplete current 보존, 선택 diff, idempotent replay와 v2 sidecar의 원자적 저장·재조회·cross-snapshot 거부를 확인했다. snapshot은 complete `1`/incomplete `2`, sidecar는 `1`, current pointer는 `1`이었고 종료 후 process/listener는 `0`이었다. acceptance UID는 `d3aff07f-6551-4351-bcf1-b01fdcd60923`이다.
- 자동 검증: `scripts/verify-automation-phase-c.ps1`이 세 schema, V0009/V0010 guard, ProfileImport/Admin API/migration 시험, editor JavaScript, API route, CLI와 live receipt를 함께 검사한다.
- 비변경 경계: 이 구현과 검증에서 Golden, Micron game runtime, client, hosts와 공식 서비스는 변경하거나 실행하지 않았다.

이 문단은 초기 기반 구현 시점의 상태 기록이다. fresh external fetch와 stable progression template 결박은 이후 통과했고, Control Center 브라우저 등록·선택 적용도 아래 최종 acceptance로 완료됐다.

#### Phase C 실제 operator acceptance — 2026-08-29

실제 로컬 credential-bearing 캡처와 exact StaticData를 read-only로 사용한 disposable Windows-native PostgreSQL acceptance에서 `materialize → account 생성 → synchro local edit → fetched diff → account_state_only 선택 apply → 동일 캡처 재비교`가 통과했다. source `771`, local edit `772`, detected diff `1`, apply 뒤 source 복원, 두 번째 동일 캡처 observation diff `0`을 확인했다. acceptance UID는 `f470fdd1-785e-483e-a6c5-9c839a34c631`이다.

이 과정에서 CLI draft file handoff 결손, exact StaticData pack/archive 형식 경계, catalog상 `core_level=not_applicable` 29건을 `Ready(0)`으로 잃어버리던 materialization 결함, incomplete snapshot current pointer의 SQL NULL Boolean 결함을 발견했다. 앞의 세 runtime 결함은 수정했고 최종 실행 뒤 PostgreSQL process/listener와 decoded archive 잔존 수는 모두 `0`이었다. 자세한 관측과 실패 이력은 [PHASE_C_OPERATOR_FETCH_ACCEPTANCE_REPORT.md](PHASE_C_OPERATOR_FETCH_ACCEPTANCE_REPORT.md)에 기록한다.

실제 snapshot은 roster/detail/equipment-character `193/193/193`, missing `0`이었다. 이 문단 당시에는 `profile_import_not_write_ready`와 `progression_summary_missing` 때문에 incomplete였지만, 후속 same-capture progression 결박으로 `progression_summary_missing`을 해소했다. historical verdict는 보존하되 현재 상태는 아래 최종 acceptance가 대체한다.

#### Phase C progression v2 historical acceptance — 2026-08-29

보존된 2026-08-26 progression source와 그 source에서 만든 candidate DB를 읽기 전용으로 정규화했다. `MainQuestData`와 `Triggers`는 `observed`, `CompletedScenarios`와 `ContentsOpenUnlocked`는 `derived`, 비어 있는 `StageClearHistorys`는 빈 관측값으로 승격하지 않고 `unavailable`로 보존한다. source-free 결과는 각각 `595`, `4786`, `611`, `73`, `null`건이며 main quest reward attestation `595`건을 유지한다.

원본 quest/scenario/content/trigger ID는 local HMAC identity secret으로 파생한 UUID로 치환한다. raw path, raw hash, 공식 user identifier, credential/session은 observation과 receipt에 남기지 않는다. candidate의 main quest와 trigger closure는 private source에서 파생한 UID 집합과 exact parity를 통과해야 한다.

이 historical source는 2026-08-29 account fetch와 동일 capture가 아니다. 따라서 current snapshot에 결박하려는 시도는 `fetched_progression_observation_invalid`로 거부되며, current snapshot의 `progression_summary_missing`도 아직 해소된 것으로 보지 않는다. read-only acceptance UID는 `1d689f54-4d8b-453f-b0f0-ef0ded6133eb`이고 verdict는 `historical_progression_v2_materialized_current_snapshot_refetch_pending`이다. 다음 단계는 새 account fetch와 같은 시점의 progression source를 수집해 같은 snapshot UID로 materialize하는 것이다.

#### Phase C progression v2 Control Center/PostgreSQL 연결 — 2026-08-29

v2 sidecar는 이제 CLI 산출물에만 머물지 않는다. Admin API 요청의 선택 필드로 전달할 수 있고, 서비스는 canonical byte 일치, source-free 다섯 flag, snapshot UID, capture time, main-quest hash/count, scenario/content count와 상세 reason-code 포함 관계를 검증한다. 통과한 sidecar만 parent fetched snapshot과 같은 PostgreSQL transaction에 저장된다. 기존 v1 snapshot+draft만 등록하는 경로는 sidecar `null`로 계속 호환된다.

합성 live acceptance는 available/derived/unavailable `2/2/1`, scenario `3`, main quest completed/reward `2/2`, content `1`, stage history `null`, trigger `2`가 저장 및 API projection 재조회에서 동일함을 확인했다. 다른 snapshot UID를 가진 canonical sidecar는 `fetched_progression_observation_snapshot_parity_invalid`로 거부됐다. acceptance receipt SHA-256은 `fdf73809641f983db66e3fba5eef0689cb48db08554387ad38698f34f2d73bc3`다. 이는 저장 경로 완결을 뜻하지만, historical observation을 8월 29일 current snapshot에 합치는 허가가 아니며 fresh same-capture refetch 필요성은 그대로다.

Phase C 종합 verification UID는 `bf04bd42-a1fa-43d4-86d3-a73752984821`, receipt SHA-256은 `55a8eaa8e000dccaf676a474c9a5f65d86148b52528b872be7a04cec105d3e32`다. verdict는 계속 `phase_c_operator_same_capture_verified_fresh_refetch_pending`이다.

#### Phase C fresh same-capture gate — 2026-08-29

fresh account raw와 progression trigger archive를 같은 관측으로 묶는 source-free request/inspection 계약을 추가했다. request 시각 이후 생성된 두 입력, raw basic-info shape, raw와 trigger archive의 1:1 계정 대응, parent progression seal/DB, exact StaticData와 runtime cold가 모두 통과해야 offline materialization이 열린다. 공식 로그인·fetch·client 실행은 자동화하지 않는다.

이 문단은 최초 fail-closed 감사 기록이다. 이후 fresh raw와 운영자가 명시한 stable progression template으로 live 흐름을 실행했으며, 같은 snapshot UID/capture time 결박과 PostgreSQL/API diff/apply가 통과했다.

#### Phase C 최종 acceptance — 2026-08-29

마지막 두 항목인 commander lobby projection과 실제 Control Center 브라우저 인수를 완료했다. source commander `896`, local lobby `897`, diff `1`을 관측하고 `commander_level`만 선택 적용해 `896`으로 복귀했다. display name, icon/frame, lobby character/background selection은 보존됐다.

Playwright Chromium이 실제 Control Center에서 source-free snapshot/draft/progression 세 파일을 등록하고 같은 diff/apply를 수행했다. 최초 1 MiB Admin API 본문 상한은 실제 약 1.48 MiB 등록을 거부했으므로 검증된 관리 API 상한 4 MiB로 조정했고, Admin API 단위 시험으로 기본값을 고정했다. acceptance UID는 `f42acebe-6d82-4cc1-839f-e90b98406b4f`, browser receipt SHA-256은 `ad40db35edee3458d0c55a1374e32ae89fb29cc143956f73542f8818efe8f902`, screenshot SHA-256은 `15073ae4637f65bd418dd8babd0c201dc1deb151bbbcced0de545b6f0e74f452`다. 종료 후 PostgreSQL process/listener는 `0/0`, Golden/game runtime 변경은 `false/false`다.

따라서 Phase C는 완료다. `StageClearHistorys` unavailable은 가용하지 않은 source field로 계속 보존하며 허위로 채우지 않는다. 다음 구현 단계는 Phase D 실행 프로그램이다.

최종 종합 verification UID는 `c4b9c6ec-3ca5-4c34-b4b9-e786b8be107f`, receipt SHA-256은 `5b2048681bbb2baa4707f50a9d50aa878131e305155f047cfaffcdcc0735e26b`, verdict는 `phase_c_completed`다.

### Phase D — 실행 프로그램

1. Control Center에서 account와 boss를 선택한다.
2. 선택 revision을 candidate DB/runtime에 projection한다.
3. start tool을 실행하고 상태를 표시한다.
4. client 종료를 감지한 뒤 completion을 실행한다.
5. 성공·실패 receipt와 마지막 정상 실행을 account history에 연결한다.

완료 기준은 PowerShell 명령을 직접 입력하지 않고도 선택 계정으로 시즌 26을 시작하고 정상 completion까지 끝내는 것이다.

#### Phase D 구현·설치 상태 — 2026-08-29

Phase D의 저장소 구현은 다음 경계로 구성한다.

- Control Center의 `Solo Raid Launch` 영역은 선택 account의 workspace가 `ready`일 때만 시즌 26 Challenge 또는 Practice 실행을 요청한다. 실행 API는 source-free runtime candidate와 lobby projection을 먼저 고정하고 `LaunchContext/v1` 및 filesystem execution state를 생성한다.
- runtime materializer는 영속 PostgreSQL의 private alias를 process-local HMAC secret으로 역결박하고, v8 부모 DB를 복사한 파생 runtime DB에 선택 revision의 닉네임·지휘관 레벨·synchro·캐릭터·스킬·돌파·호감도·장비·오버로드·큐브·소장품/애장품·콘솔 값을 투영한다. 공식 `C:\NIKKE`, v8 부모 runtime과 Golden은 수정하지 않는다.
- 실행마다 `artifacts/automation/phase-d-executions/<launch-context-uid>/` 아래에 별도 runtime, tool, source manifest, validation receipt와 상태를 만든다. 39 GB cache는 복제하지 않고 검증된 기존 cache junction target을 새 파생 runtime에 다시 연결한다.
- Launch 직전까지만 Control Center PostgreSQL을 사용한다. candidate DB materialization이 끝나면 native PostgreSQL을 `fast` 정지하여 기존 game preflight의 cold 조건을 만족시키고, client 종료와 completion 뒤 watcher가 같은 영속 cluster를 자동 재시작한다. HTTP 연결이 끊겨도 시작/rollback 경계는 중단하지 않는다.
- completion은 v8의 기존 startup-only/client-exit 정리 계약을 사용한다. 성공 시 hosts, firewall, SQLite runtime과 active pointer를 정리하고 execution state를 `completed`로 바꾼다. 실패 시 pinned process와 정확한 before image만 사용해 emergency rollback을 수행한다.

영속 Control Center는 `C:\NLL\ControlCenter`에 설치한다. PostgreSQL data와 DPAPI 보호 secret은 저장소·D: Golden과 분리하며 Windows service, scheduled task, Docker, WSL2와 Hyper-V를 사용하지 않는다. 실행 중에만 native PostgreSQL과 Admin API가 올라온다.

운영 파일은 다음과 같다.

- 1회 설치: 바탕화면 `NLL Phase D Install.cmd`
- 설치 본체: `scripts/deploy-nll-phase-d-control-center-offline.ps1`
- 설치 후 실행: 바탕화면 `NLL Control Center.cmd`
- 설치 root: `C:\NLL\ControlCenter`
- 파생 실행 조정기: `scripts/invoke-nll-phase-d-execution.ps1`
- client 종료/completion 감시기: `scripts/watch-nll-phase-d-execution.ps1`
- 계정 DB materializer: `tools/NikkeLocalLab.PhaseD.RuntimeMaterializer/`
- 최초 영속 account bootstrap: `tools/NikkeLocalLab.ControlCenterBootstrap/`

#### Phase D 보스 약점 변형 자동화 계약 — 2026-09-01

시즌 26에서 실행 전 약점 코드를 `작열·수냉·풍압·전격·철갑` 중 선택할 수 있다. 선택값은 Control Center 요청, 실행 상태, materialization receipt와 `LaunchContext/v1`을 거쳐 단일 실행에 결박된다. 내부 코드는 각각 `fire`, `water`, `wind`, `electric`, `iron`으로 고정하고 사용자 노출 명칭은 공식 명칭만 사용한다. 공통 입력은 `BossRuntimeVariantProfile/v1`이며 season, source-free selected-manager observation hash, Challenge wave selector, 원본 속성/약점, 속성 실드·FX 상태와 허용 변형 table을 선언한다. 철갑은 원본 StaticData를 그대로 쓰고, 나머지 네 속성은 profile과 실제 Challenge manager→preset→wave→target monster chain이 모두 일치한 뒤 `ElementTable` 의미 필드만 바꾼 파생 `StaticData.pack`을 실행 디렉터리에 만든다. 부모 v9 runtime, 공유 cache 원본, 공식 설치본, Golden은 수정하지 않는다.

파생 pack은 원본 서명으로 재서명할 수 없으므로 receipt에 `original_signature_not_valid_for_derived_payload`와 `pending_original_client_runtime_observation`을 명시한다. 따라서 Actions green은 원본 client 수락을 뜻하지 않는다. 비기본 속성의 Solo Raid 메인 화면 공식 약점 아이콘과 전투 진입은 별도 local actual-client gate로 확인한 뒤에만 지원 판정을 갱신한다.

새 보스 추가 pipeline도 동일한 입력·산출물 경계를 재사용한다. pipeline이 보스별 `BossRuntimeVariantProfile/v1`을 생성하고 `BossRuntimeVariantRegistry/v1`에 시즌·profile 경로·exact SHA-256·운영 상태를 등록한다. 실행 조정기는 시즌 번호로 enabled profile을 유일하게 해소하므로 새 보스용 파일명을 코드에 추가하지 않는다. 공통 변형기는 profile만 입력받으며, `BossCandidate/v1`도 profile hash와 원본 속성/약점, 속성 실드·FX 판정을 보존한다. 각 boss candidate는 요청 weakness, 수정 table/row 수, source/profile/variant/server hash, 공식 설치본·부모 runtime mutation 0, client acceptance 상태를 receipt로 남겨야 한다. 속성 실드 또는 FX가 `unresolved`인 profile은 변형 전에 fail closed한다. `scripts/verify-automation-boss-weakness-variant.ps1`은 다섯 코드의 UI/API/조정기 전달, 공식 아이콘 materialization, registry/profile 계약, 파생 lane 경계와 22개 server source manifest를 검사하며 Actions와 pre-commit에서 실행된다. 원본 asset과 파생 pack 자체는 GitHub 입력·artifact가 아니다.

DPAPI는 `nlloperator` current-user scope를 사용하고 평문 database password와 identity secret을 receipt, log, command line 또는 source-free artifact에 기록하지 않는다. 초기 설치는 승인된 raw fetch와 exact StaticData를 읽어 새 영속 secret에 맞는 catalog alias와 `계정_1` revision을 한 번 다시 materialize하며 raw source를 설치 root로 복사하지 않는다.

저장소 빌드와 Admin API 정적 검사는 통과했고 `C:\NLL\ControlCenter` 영속 설치도 완료했다. bootstrap account는 `계정_1`이며 runtime candidate는 총 `9,080` 값 중 ready `8,158`, not-applicable `601`, unresolved `321`이다. unresolved는 장비 manufacturer 관측 결손 `312`와 bond level 0 의미 미확정 `9`로 구성되며 임의 기본값은 넣지 않았다. 따라서 편집·검토는 가능하지만 Launch는 candidate가 ready가 될 때까지 계속 fail closed한다.

최초 installation smoke에서 Admin API가 Phase D 편집기와 무관한 private-server 시즌 directory를 함께 bootstrap하려다 `raid_season_directory_source_not_found`로 종료됐다. 이는 filesystem 경로 결손이 아니라 역사 v1 catalog 6종을 요구하는 DB composition이 Phase D에 과다 결합된 문제다. Phase D 전용 기동 모드는 private-server 관리 API를 구성하지 않고 profile/account/candidate/execution API만 올리도록 분리했다. Windows PowerShell wrapper가 `pg_ctl` 출력을 pipeline으로 캡처하면 postgres 자식이 handle을 유지해 대기하는 문제도 관측해 capture를 제거했다. PowerShell 5.1이 bootstrap `204` 응답의 session cookie를 보존하지 않는 경우는 exact `nll_admin_session`을 in-memory CookieContainer에 객체로 결박해 검증했다.

수정 후 installation smoke는 2026-08-29에 통과했다. PostgreSQL 기동, CurrentUser DPAPI secret 2개 해제, Admin API 기동, one-time bootstrap 교환, 인증된 account/workspace/candidate 조회와 종료 후 cold 복귀가 모두 성공했다. account `1`, candidate value `9,080`, unresolved `321`이며 DB·게임 runtime·Golden·공식 설치본·D: backup 변경은 모두 false다. inspection UID는 `1b6beb08-a5db-4741-b71f-064271a45b21`, receipt SHA-256은 `cfcfcc793472a6ce240d98529ea71b023e0b35625dc5caa5ddc281e43d816c65`다. 이제 남은 Phase D 완료 gate는 운영자의 Control Center 기능 점검, `321`개 unresolved의 명시적 검토, original-client 시작→종료→자동 completion 인수다. 그전에는 D: backup을 갱신하지 않는다.

### Phase E — 시즌 29 Mother Whale 변종

1. existing static snapshot의 source fingerprint를 재검증한다.
2. behavior/runtime과 client asset closure를 완결한다.
3. boss-add pipeline으로 selected manager와 derived lane을 생성한다.
4. 시즌 29 메뉴·전투·Regroup·완주·재진입을 실제 client에서 검증한다.

### Phase F — 시즌 34 Altruia

시즌 29와 동일한 pipeline을 season parameter만 바꿔 수행한다. 별도 수작업 분기를 추가하지 않고도 성공해야 한다.

Phase E/F 완료 뒤 Control Center가 노출할 Solo Raid 집합은 기존 시즌 26과 추가 시즌 29·34의 정확히 세 개다. 그 밖의 시즌은 별도 운영자 결정과 새 admission evidence 없이는 자동으로 노출하지 않는다.

### Phase G — 일반 업데이트 자동화 완성

1. 새 build/static-data input을 한 번 지정하면 전체 diff와 영향 보고서를 생성한다.
2. 호환 변화는 catalog rebase와 candidate build까지 자동 처리한다.
3. unresolved 변화는 필요한 확인 항목과 막힌 pipeline stage를 정확히 표시한다.
4. 성공한 account/boss 조합을 선택해 회귀 test matrix를 실행한다.

## 6. 우선순위와 의존 관계

```text
공통 manifest/state machine
├─ account manager core ─ fetch 통합 ─ Control Center 실행
├─ boss-add pipeline ─ 시즌 29 ─ 시즌 34
└─ update diff/rebase ─ 자동 candidate build ─ 회귀 test matrix
```

가장 먼저 공통 manifest와 account manager core를 만든다. 그 위에서 시즌 29를 첫 boss-add 자동화 사례로 구현하고 시즌 34로 일반성을 검증한다. 마지막으로 이 두 흐름을 일반 업데이트 pipeline에 연결한다.

## 7. 전체 완료 기준

- 사용자는 Control Center에서 여러 계정을 이름으로 구분할 수 있다.
- 각 계정의 요청된 모든 console·니케·장비·OL·스킬·소장품/애장품 필드를 편집할 수 있다.
- `Save`, `Save As`, `Fetch`, `Launch`가 UI에서 동작한다.
- fetch 결과는 roster/detail completeness와 stage/main-quest progression을 함께 제공한다.
- 시즌 29와 시즌 34가 동일한 boss-add pipeline으로 생성되고 original client 전투까지 검증된다.
- 일반 업데이트에서 변경점, 필요한 rebase, 재빌드 대상과 막힌 항목이 자동 보고된다.
- 실제 플레이 성공 전에는 D: Golden을 덮어쓰지 않으며, 성공 checkpoint는 additive backup으로 남는다.

## 8. 첫 착수 단위

첫 구현 단위는 `Phase A — 요구 schema와 pipeline manifest`다. 이 단계에서 코드를 크게 옮기지 않고 다음 네 가지를 먼저 고정한다.

1. `FetchedAccountSnapshot/v1`의 필드 목록과 `getFromBlaLink.py` packet → snapshot mapping
2. account label, current revision과 Save As lineage 계약
3. boss-add pipeline의 공통 입력·출력 manifest
4. 일반 update assessment의 diff category와 종료 코드

이 네 계약이 고정되면 account UI, 시즌 29와 update pipeline을 서로 다른 수작업 script 묶음으로 만들지 않고 같은 core 위에서 병렬적으로 확장할 수 있다.
