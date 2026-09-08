# Phase 3B-2 user progression reconstruction plan

> 보관 기록: 2026-09-06 문서 정리 때 이동했습니다. 본문의 ‘현재·다음·미완료’는 작성 당시 기준입니다. 현행 안내는 [문서 색인](../README.md)과 [현재 경로](../MICRON_CURRENT_PATHS.md)를 따릅니다.

## 1. 목적

이 계획은 lobby 진입이 검증된 Epinel Golden runtime을 부모 기준선으로 유지하면서, 운영자가 제공한 실제 진행도와 로컬 official-client cache에서 읽기 전용으로 확인한 진행 이력을 local-only compatibility 사용자에게 투영한다.

목표는 다음과 같다.

- 이미 완료한 opening 및 mainline scenario가 다시 재생되지 않도록 한다.
- Normal 48-44, Hard 48-44, Story 48-6 진행도를 일관되게 표시한다.
- 완료한 main quest와 보상 수령 상태를 복원한다.
- campaign 진행 조건과 Solo Raid 6-4 해금 조건을 충족한다.
- 기존 character/costume 데이터와 lobby 성공 경로를 보존한다.

이 작업은 official account, login, session, token을 사용하지 않으며 official outbound를 수행하지 않는다. 기존 운영자 cache와 전용 `nlloperator` LocalLow는 수정하지 않는다.

## 2. 변경 금지 경계

다음 항목은 수정하거나 새 hash binding을 추가하지 않는다.

- lobby 성공 Golden start/completion wrapper
- inner start/completion tool
- physical bootstrap
- Epinel server binary
- native cache 및 locale overlay
- hosts, firewall, certificate 상태
- `C:\NIKKE` 주 설치본
- 기존 운영자 및 `nlloperator` LocalLow

진행도 적용 대상은 Golden `db.json`에서 파생한 candidate와, 필요할 경우 cold 상태에서 새로 구성하는 local Epinel SQLite database뿐이다. Golden 원본은 직접 편집하지 않는다.

## 3. 현재 Golden 기준선

- runtime은 cold 상태여야 한다.
- 활성 `db.json`은 lobby 성공 Golden과 일치해야 한다.
- cold 기준선에서는 `epinelps.db`, `epinelps.db-shm`, `epinelps.db-wal`이 존재하지 않는 것이 정상이다.
- SQLite 부재 자체를 기준선 상태로 기록한다.
- progression candidate 적용 전 Golden `db.json`과 SQLite 부재 상태를 별도 rollback artifact로 봉인한다.

## 4. 데이터 출처와 신뢰 등급

### 4.1 운영자 제공 progression capture

다음 값의 권위로 사용한다.

- Normal 마지막 완료 stage: 48-44
- Hard 마지막 완료 stage: 48-44
- Story 마지막 완료 stage: 48-6

원본 capture, 원본 사용자 식별자, credential/session 필드는 repository에 복사하거나 커밋하지 않는다.

### 4.2 official-client local trigger cache

운영자 capture와 연결되는 계정별 `NKSD_TRIGGER` archive를 Samsung에서만 읽기 전용으로 사용한다. `trigger.txt`의 progression 관련 record에서 다음 항목만 투영한다.

- `CampaignClear`
- `ChapterClear`
- `HardChapterClear`
- `CampaignGroupClear`
- `MainQuestClear`

그 밖의 commerce, gacha, social, event, reward, inventory trigger는 이번 candidate에 포함하지 않는다.

### 4.3 exact client static tables

stage, field, quest, scenario, contents-open 참조를 검증하는 데 사용한다. cache record의 조건 ID가 exact client table에 존재하지 않으면 추정하거나 새 row를 만들지 않고 `unresolved`로 제외한다.

## 5. 데이터 투영 규칙

### 5.1 마지막 완료 stage

`LastNormalStageCleared`, `LastHardStageCleared`, `LastStoryStageCleared`는 운영자 제공 progression capture의 세 값을 그대로 사용한다.

### 5.2 `FieldInfoNew`

1. `CampaignClear` 조건 ID를 중복 제거한다.
2. exact static stage/field table에 존재하는 항목만 인정한다.
3. 각 stage를 정확한 field의 `CompletedStages`에 배치한다.
4. event, archive, side-story stage를 main campaign field에 혼합하지 않는다.
5. 마지막 완료 stage와 모순되는 항목이 있으면 candidate 생성을 실패시킨다.

### 5.3 `MainQuestData`

`MainQuestClear`에서 얻은 고유 quest ID를 exact quest table과 교차검증한다. 확인된 모든 quest에 대해 값을 `true`로 설정한다.

이 계획에서 `true`는 운영자가 확인한 실제 상태인 "quest 완료 및 보상 수령 완료"를 뜻한다. source에 없는 quest는 추가하지 않는다.

### 5.4 `Triggers`

progression 일관성에 필요한 다섯 trigger type만 local Epinel SQLite에 투영한다.

- `Type`, `ConditionId`, `Value`, `CreatedAt`은 읽기 전용 cache record에서 가져온다.
- official user identifier는 복사하지 않는다.
- `UserId`는 local Epinel user에 연결한다.
- primary sequence는 충돌 없는 local 연속 번호로 다시 만든다.
- 동일한 `(Type, ConditionId)` record는 중복 제거한다.
- `/trigger/sync`의 2,000건 pagination과 종료 조건을 오프라인에서 검증한다.

### 5.5 `CompletedScenarios`

LocalLow에는 authoritative completed-scenario 목록이 없으므로 source-exact 추출이라고 주장하지 않는다. 다음의 제한된 파생 closure만 만든다.

1. 검증된 completed campaign stage를 exact static stage table과 연결한다.
2. 해당 stage에 명시적으로 연결된 mainline `EnterScenario`와 `ExitScenario`만 수집한다.
3. 검증된 Normal, Hard, Story 진행 범위를 벗어나는 scenario는 제외한다.
4. event, archive, side story 및 모호한 참조는 자동 완료하지 않는다.
5. provenance를 `derived_from_campaign_clear_and_static_scenario_links`로 기록한다.

### 5.6 `ContentsOpenUnlocked`

이 데이터는 실제 admission이 아니라 unlock button/popup을 이미 확인했는지 나타내는 UI 상태로 취급한다.

- exact `ContentsOpenTable`에서 현재 진행 조건을 만족한 content만 대상으로 한다.
- 대상 row의 `ButtonAnimationPlayed`와 `PopupAnimationPlayed`를 `true`로 설정한다.
- 이 목록만으로 content를 강제로 해금하지 않는다.
- Solo Raid는 별도의 6-4 조건 검증을 통과해야 한다.

### 5.7 `StageClearHistorys`

비워 둔다. 현재 자료에는 당시 squad, character level, combat, clear timestamp snapshot이 완전하게 존재하지 않으며, 이 객체는 campaign 진행도나 Solo Raid admission의 권위가 아니다. 값을 합성하지 않는다.

### 5.8 tutorial 상태

- 기존 lobby 성공 경로에서 검증한 tutorial terminal group 처리를 유지한다.
- exact client tutorial table에서 확인한 group 외에는 추가하지 않는다.
- official-client `.nkcache`의 빈 `TutorialInfo`를 복사하거나 수정하지 않는다.
- tutorial completion과 `CompletedScenarios`를 별도 데이터로 검증한다.

## 6. 구현 순서

1. Golden `db.json`과 SQLite 부재 상태를 backup하고 manifest와 rollback plan으로 봉인한다.
2. 대상 trigger archive를 읽기 전용으로 다시 식별하고 source-free aggregate manifest를 만든다.
3. Golden `db.json` 복사본에서 progression candidate를 생성한다. 중간 산출물은 Samsung의 보호된 작업 영역에만 두며 D:에는 쓰지 않는다.
4. 별도의 cold SQLite migration proof에 progression trigger만 생성한다. 이 역시 Samsung의 보호된 작업 영역에만 두고 Micron runtime에는 직접 적용하지 않는다.
5. JSON round-trip, SQLite integrity, static reference, deduplication, pagination 검사를 수행한다.
6. Golden과 candidate를 비교해 허용된 progression 필드와 trigger table 외 변경이 0인지 검증한다.
7. Samsung에서 Micron runtime의 데이터 파일만 offline 적용한다.
8. Golden locale-overlay 구현을 복제한 별도 UserProgression v2 파생
   start/completion 경로로 한 번만 검증한다. Golden 도구 네 개는 수정하지
   않는다.

### 6.1 UserProgression v2 파생 lane 경계

파생 lane의 실행 기준은 Micron `E:\NLL`의 실제 성공 Golden이다. D의
성공 로비 백업은 E와의 읽기 전용 비교 및 장애 시 복구에만 사용한다.

- inner start 변경은 evidence root와 expected DB digest 두 곳뿐이다.
- inner completion 변경은 evidence root, expected DB digest, receipt
  contract ID 세 곳뿐이다.
- outer start는 성공한 locale/cache/network preflight를 보존하고 strict
  progression receipt 검증과 새 inner 호출만 추가한다.
- derived tool self-hash, circular receipt hash, Golden wrapper 재결박은
  사용하지 않는다.
- Golden 도구 네 개, server binary, cache, hosts, LocalLow는 배치 전후
  동일해야 한다.
- DB 교체는 모든 신규 파일을 배치한 뒤 마지막에 수행하며, 배치 실패 시
  Micron에서 캡처한 Golden DB로 즉시 복구한다.

## 7. Micron 1회 검증 조건

- 4/7을 통과하고 lobby에 진입한다.
- opening story가 다시 재생되지 않는다.
- 전투 tutorial이 나타나지 않는다.
- Normal 48-44, Hard 48-44, Story 48-6 진행도가 일관되게 응답된다.
- campaign field와 main quest 상태가 반영된다.
- 기존 character/costume 상태가 유지된다.
- Solo Raid 6-4 unlock 조건이 충족된다.
- trigger pagination이 종료되고 반복 보상·무한 popup이 발생하지 않는다.
- official outbound와 launcher 실행은 0이다.
- operator가 client를 닫은 뒤 기존 completion 경로가 정상적으로 runtime을 정리한다.

## 8. 실패와 rollback

- 실패 run 위에 추가 repair나 wrapper binding을 누적하지 않는다.
- client를 닫고 기존 completion으로 evidence를 수집한다.
- candidate `db.json`과 SQLite runtime만 제거하고 Golden `db.json` 및 SQLite 부재 상태를 복원한다.
- cache, wrapper, server binary, LocalLow는 rollback 대상이 아니며 변경되어서도 안 된다.
- 원인 분류 뒤 새 candidate revision을 Samsung에서 다시 만든다.

## 9. 진행도 성공 뒤 남는 작업

후보 생성·오프라인 검증·실패한 재시도 단계에서는 D:에 새 백업을 만들지 않는다. 기존 D: 봉인물은 읽기 전용 입력으로만 사용한다. 아래 1번은 Micron 실제 플레이에서 진행도 표시, 콘텐츠 해금, 튜토리얼 억제, 전투 진입까지 문제가 없다고 운영자가 확인한 뒤에만 수행한다.

1. 성공한 runtime/data를 D 드라이브에 progression Golden으로 별도 봉인한다.
2. Solo Raid 메뉴 진입과 시즌 26 표시를 확인한다.
3. 시즌 26 manager, preset, Challenge wave, monster/stat closure를 검증한다.
4. squad 편성 및 Challenge session 생성을 검증한다.
5. original client의 battle, HUD, damage, result를 검증한다.
6. 관측으로 필요성이 확인된 server endpoint만 추가한다.

## 10. 2026-08-27 오프라인 적용 상태

- strict audit UID: `8bd0bb59-0a75-44f8-8143-a689497486a8`
- candidate assessment UID: `a69002f5-14e9-4f05-b9ab-9ca58b13925a`
- application UID: `45845cb4-85d0-490d-9cbe-a507700c2e00`
- candidate DB SHA-256:
  `d73e92c9e8159b347f42eff5c6c2270e3695e91cd542c05f45bcbb121cd9a1ee`
- Micron Golden 도구 4개: 적용 후 무변경 확인
- D Golden 성공 로비 백업: 읽기 전용 일치 확인
- derived tool: 신규 4개 추가
- cache: 40,113 files / 39,031,656,543 bytes / partial 0
- server, cache, hosts, LocalLow 변경: 0
- D write: 0
- rollback readiness audit: 통과
- 다음 단계: Micron에서 `nlloperator`로 derived start를 한 번만 실행한다.

## 11. 2026-08-27 실제 UI 관측과 메뉴 Golden 체크포인트

UserProgression v2의 단일 Micron run은 assessment UID
`ebd24444-3ac6-49de-9982-505737a6eccd`로 실행됐다. Client 시작 영수증은
required asset, catalog, SAUS preflight와 loopback-only 경계를 모두
통과했고 official outbound와 launcher 실행은 0이었다.

운영자 관측과 두 스크린샷으로 다음 상태를 확인했다.

- lobby 진입: 성공
- Solo Raid 메뉴 진입: 성공
- 표시 boss: Providence
- Challenge 버튼 표시: 확인
- battle 진입: 실패
- 차단 UI: `The season has ended. See you at the next season.`
- Normal 단계 상태: I만 열리고 II~VII는 잠김
- 요구 상태: Normal I~VII 기본 clear, Challenge 개방

따라서 이 결과는 actual battle Golden이 아니다. 범위는
`lobby_and_solo_raid_menu_entry_checkpoint`이며 남은 문제는 다음 두 개로
분리한다.

1. Solo Raid season/admission 판정이 UI의 잔여 시간 표시와 불일치한다.
2. Normal I~VII의 기본 clear 상태가 Epinel 응답에 투영되지 않았다.

첫 completion 시도는 `solo_raid_menu` 뒤에 Markdown backtick이 붙어
실행되지 않았다. 운영자가 Micron으로 돌아가 같은 active pointer에 대해
backtick 없는 명령을 실행했고 completion receipt가 정상 생성됐다.

- completion receipt SHA-256:
  `2d8f9dfb7206ad03d9c4509dede6bd46ae8c125873a30e8b8674ec879fe8b0db`
- observed stage: `solo_raid_menu`
- outcome: `success` — 메뉴 단계 성공이며 battle 성공을 뜻하지 않는다.
- active pointer: archive 완료, 활성 pointer 없음
- active DB: candidate `d73e92c9…`로 복원
- SQLite runtime: 3개 관측 후 0개로 제거
- hosts: base `dda2e817…`로 복원
- extension firewall: 제거
- final runtime: cold

실제 성공 입력은 run의 immutable `db.before.bin`에 보존돼 있다.

- candidate DB SHA-256:
  `d73e92c9e8159b347f42eff5c6c2270e3695e91cd542c05f45bcbb121cd9a1ee`
- parent Golden 도구: 4/4 불변
- derived progression 도구: 4/4 일치
- server DLL SHA-256:
  `aaa1e49d7a879a6b5ec17ad4c4094ce7d98ce86f860c1529a9ab4d6aecb51f7c`
- cache: 40,113 files / 39,031,656,543 bytes

이 입력과 관측 증거를 기존 full Golden의 read-only overlay로 D에 봉인했다.
변형 runtime DB, SQLite, active pointer, 적용 hosts, raw server log와 LocalLow는
백업에 넣지 않았다.

- seal UID: `0f3a28ce-fb15-4b15-9a09-4de7174ac5c4`
- backup root:
  `D:\NikkeLocalLab\Backups\phase3b2-user-progression-solo-menu-golden-v1\0f3a28ce-fb15-4b15-9a09-4de7174ac5c4`
- seal receipt SHA-256:
  `ca1fafd7b56c7ca0c4865561e5b4609778a193b529a5f3b9dcc0608c6a613fe2`
- overlay manifest SHA-256:
  `f6e5294cbea7adff513942fba2f78a2c8d18152b7331905825b663b45d626961`
- manifest member-order canonical SHA-256:
  `53072a7fd440af9ab3b6b87fe11d284c4ec2c70a4a7340800284d3e6418ed104`
- copied member count: 32, digest mismatch: 0
- 기존 full Golden 수정: 0
- Micron 수정: 0
- `ccccc` cache/LocalLow inspect·수정: 0

기존 base seal을 수정하지 않고 completion과 archived pointer를 D 체크포인트에
additive extension으로 붙였다.

- post-completion audit SHA-256:
  `cd2b3c52719a8379a4594966e2b274c223e79881bf7fad3087db46d3400cdbcf`
- post-completion manifest SHA-256:
  `aaa4d518af24b976c44e1a42c2f98fd974a51997830c966858aa5d14080e2962`
- extension canonical SHA-256:
  `16871f00ac2fba3942254eb5247350ddf53ef8fd395f48efc02d4bf008c7befb`
- extension member count: 2, digest mismatch: 0
- base seal SHA-256 유지:
  `ca1fafd7b56c7ca0c4865561e5b4609778a193b529a5f3b9dcc0608c6a613fe2`

다음 순서는 Normal I~VII clear 응답과 season/admission 판정을
데이터·시간·운영 policy 축으로 분리해 원인을 분류하는 것이다. 이
체크포인트 위에서 전투 성공을 주장하거나 자동 재시도하지 않는다.

## 12. 2026-08-27 `LastClearLevel=7` 선행 검증 lane

Challenge의 `trial/open` 경로를 처음 검증하기 전에 Normal I~VII clear
호환 상태만 응답에 투영하는 파생 lane을 만들었다. DB의 `SoloRaidData`를
수정하지 않으며, 저장값이 없거나 7보다 작을 때 응답의
`LastClearLevel`만 7을 하한으로 삼는다. Normal battle, Normal reward,
Quick Battle은 계속 구현하지 않는다.

- Epinel external head: `317c4f352b91e76470e2b035ada426ff443f9de4`
- Epinel external tree: `e429f0ac08cde7561456e158c9403abb7d9d0362`
- focused tests: 67/67 pass
- derived server DLL SHA-256:
  `f602c58985a7a90cd206e2b58d793a4c7c2c0f1ea6ba778d0d74d61d68f9635b`
- deployment UID: `aa97b831-27be-436d-afbe-75b1981a1729`
- deployment receipt SHA-256:
  `f3dd7b557b118eda3309d1c139d5ebff34abea4286663d27d31333fede79b1c5`
- Golden runtime manifest: 576 members /
  `cbec33c9994a7a490b11c29d55fd32d54ac9a830fe22543068ba749cf0803440`
- parallel runtime manifest: Golden과 동일한 576 members / 동일 hash
  (`EpinelPS.dll`과 `db.json`은 manifest 비교에서 별도 고정 검증)
- Golden runtime, Golden DB, Golden tools, progression tools, cache: 변경 0
- D drive inspect/write: 0
- duration policy 변경: 0
- commander level 변경: 0

39 GB cache는 복사하지 않는다. Samsung에서는 E: Golden cache를 가리키는
파생 runtime junction을 만들고, Micron 부팅 뒤 관리자 start wrapper가 그
junction만 C: Golden cache로 재결합한다. Golden cache 자체는 수정하지
않는다.

다음 단일 검증은 Micron `nlloperator`에서
`Start-Phase3B2-Epinel-SoloRaidUnlock-v1.ps1`을 실행한 뒤 Solo Raid
Challenge를 한 번 눌러 `trial/open` 요청 발생과 응답 성패를 관측하는
것이다. 이 결과가 나오기 전에는 기간 또는 지휘관 레벨 변경을 섞지 않는다.

## 13. 2026-08-27 Challenge 무요청 분류와 지휘관 레벨 단일 변수 lane

> 정정: 이 절의 server stdout만 사용한 `trial/open` 무요청 판정과
> Mock/Practice 진단 배제는 뒤의 절 14에서 철회한다. server stdout의 HTTP
> client trace는 encrypted lobby route 전체를 나타내지 않았고, 전용
> `nlloperator` Player.log에는 `OpenTrial`과 `GetLevelTrial` 성공 응답 및 그
> 직후 client 예외가 남아 있었다.

`LastClearLevel=7` 검증 run에서 Normal I~VII의 clear 표시는 실제 UI로
확인됐다. 그러나 outer start wrapper가 긴 run-binding 경로에 영수증을
쓰기 위해 `WriteAllText`를 호출하다 `PathTooLongException`을 냈다. 이
예외는 client와 server가 시작된 뒤에 발생했으며, 운영자가 실행한 completion은
정상적으로 runtime을 cold 상태로 복원했다. 따라서 해당 예외와 Solo Raid
버튼 동작은 별개의 문제로 분류한다.

완료된 assessment `ea78341b-13e0-47a6-8ade-2c700ba31610`의 server stdout에
노출된 HTTP client trace만 분류한 당시 결과는 다음과 같았다.

- `/v1/soloraid/getperiod`: 4회, 모두 HTTP 200
- `/v1/soloraid/get`: 0회
- `/v1/soloraid/trial/open`: 0회
- `/v1/soloraid/trial/enter`: 0회
- `/v1/soloraid/practice/open`: 0회

이 trace만으로 실제 Challenge와 Mock Battle 클릭이 Epinel route에 도달하지
않았다고 결론 낸 것은 오류였다. 화면의 약 5일 잔여 시간이
`GetSoloRaidPeriod()`의 rolling window와 일치하므로 정적인 만료 timestamp로
단정할 근거가 없다는 부분만 유지한다. Practice는 기존 first-proof 인수 범위
밖이지만, 실전 3회 제한을 소모하지 않는 진단 경로로서의 Mock Battle 관측을
배제해서는 안 된다.

남은 직접 후보 중 지휘관 레벨만 분리하기 위해 운영자 제공 원본 capture의
`phase_1_initial_load[18].data.player_level=893`을 사용했다. 정확히 하나의
`Users[0].userPointData.UserLevel` 필드만 893으로 바꿨으며
`ExperiencePoint`는 0으로 보존했다. 사용자 capture 원문, credential, session,
identifier는 runtime이나 영수증에 복사하지 않았다.

- source capture SHA-256:
  `efb1b38b4557e45cbefc1922649c22f6725071cb8c5cb2ad269650d7807fe605`
- parent SoloRaidUnlock DB SHA-256:
  `d73e92c9e8159b347f42eff5c6c2270e3695e91cd542c05f45bcbb121cd9a1ee`
- derived SoloRaidLevel DB SHA-256:
  `dee9c6aa5421287ca030e325b81a90a302a5d9e113d57c3065e5d36f6e7c4019`
- deployment UID: `62eb7d7b-fe02-428f-9237-5e50867415f2`
- deployment receipt SHA-256:
  `37f63eb633b22195258ac7a72fc66e6b2935704a6e3338b0abdc07247e1ad5fa`
- derived runtime root: `C:\NLL\Runtime\EpinelPS-SoloRaidLevel-v1`
- short run evidence root: `C:\NLL\E\P3SRL1`
- planned maximum evidence path length: 99 characters

새 outer wrapper는 별도 run-binding 영수증을 만들지 않는다. inner start가
만드는 short-path active pointer와 start receipt만 completion 계약의 권위로
사용하므로 기존 `WriteAllText` 장경로 실패 지점 자체가 제거됐다. Golden,
parent SoloRaidUnlock lane, cache, LocalLow, D backup은 변경하지 않았다.

다음 검증은 한 번만 수행한다.

1. Micron의 `nlloperator`로 부팅한다.
2. `Start-Phase3B2-Epinel-SoloRaidLevel-v1.ps1`을 한 번 실행한다.
3. 프로필에서 지휘관 레벨 893을 확인한다.
4. Solo Raid 메뉴에 들어가 실제 Challenge만 한 번 누른다.
5. 실제 Challenge와 Mock Battle 결과를 서로 다른 route로 기록한다.
6. client를 닫고 전용 completion을 실행한다.

이 run에서 `/soloraid/get` 또는 `/soloraid/trial/open`이 처음 발생하면 지휘관
레벨이 client-side 선행조건이었는지 판정할 수 있다. 여전히 `getperiod`만
발생한다면 레벨 가설을 기각하고, 다음에는 추가 mutation 없이 client-side
초기화 상태와 Solo Raid 응답 shape를 Golden과 비교한다.

## 14. 2026-08-27 지휘관 레벨 검증 결과와 wire-shape 결손

지휘관 레벨 단일 변수 run은 assessment
`6e859a33-e6c2-4d68-bf1e-15931ec282c1`로 완료됐다. start receipt는 source
level 1, applied level 893, ExperiencePoint 불변과 short evidence path 사용을
확인했고 completion은 runtime을 cold 상태로 정상 복원했다.

전용 `nlloperator` Player.log의 실제 client packet/stack trace는 이전 server
stdout 기반 추정을 반박한다.

- `ResGetSoloRaidInfo`: Success, 첫 Solo Raid 메뉴 진입 성공
- `ResOpenSoloRaidTrial`: Success
- `ResGetLevelTrialSoloRaid`: Success
- 직후 `NKUserSoloRaid.UpdateJoinData(joinData)`에서 NullReferenceException
- 후속 Solo Raid 재진입의 `ResGetSoloRaidInfo` 처리 중
  `NKUserSoloRaid.UpdatePeriod(netSoloRaidPeriodData)`에서
  NullReferenceException 반복

따라서 지휘관 레벨은 현재 병목이 아니다. client가 Challenge route를 호출했고
server도 success를 반환했지만, success response의 필수 nested message가
비어 있었다. 현재 `GetLevelTrialInfo`는 먼저 `PeriodResult=Success`를 설정한 뒤
open level이 없으면 `Raid`와 `JoinData`를 설정하지 않고 반환한다. 기존 focused
test도 `GetLevelTrialWithoutOpenRunIsWireSuccessWithoutMutation`에서 이
`success + null Raid` shape를 허용하며, `JoinData` non-null을 검사하지 않는다.

가장 유력한 발생 순서는 client가 OpenTrial과 GetLevelTrial을 결합 호출하고,
GetLevelTrial이 OpenTrial의 active-run materialization을 보기 전에 처리되는
경합이다. coordinator의 개별 요청 atomicity는 보장되지만 두 요청 묶음의
순서나 wire-safe idempotency는 보장하지 않는다. 이 가설은 다음 두 검증으로
확정해야 한다.

1. `OpenTrial -> GetLevelTrial` 순차 및 역순/동시 호출에서 response nested
   message와 active run을 검사한다.
2. `ResGetSoloRaidInfo`의 allowed/denied 모든 결과에서 `Info.Period`가 non-null인
   wire-safe shape인지 검사한다.

Mock Battle은 existing selected-manager policy에서 Practice route로 controlled
failure 처리되지만, 실전 entry를 소모하지 않는 운영 검증 수단이라는 요구를
별도로 기록한다. first-proof 인수 조건과 Mock capability 지원 여부를 분리해
결정하기 전에는 Practice handler를 임의로 활성화하지 않는다.
