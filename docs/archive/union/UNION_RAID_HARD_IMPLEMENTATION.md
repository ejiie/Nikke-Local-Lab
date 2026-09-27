# 유니온 레이드 하드 도입

> 2026-09-27 보관: 작성 당시의 기록이며 현재 작업 지시가 아닙니다. 현행 문서는 [문서 색인](../../README.md)에서 찾습니다.

## 2026-09-18 콘텐츠 개방 API 연결 및 사용자 요청 레벨 상한 1200

- `/user/getcontentsdata`의 `GuildLevel`을 NLL 소속의 `LocalUnionRaid.Level`에서 공급한다. 길드 표시 응답과 같은 값이며 미가입·다른 길드·선택 상태 부재는 0이다. 레벨 2는 미개방, 3은 개방으로 원본 조건과 대조한다. 다른 콘텐츠의 단계/가챠/시뮬레이션 응답은 유지한다.
- 사용자 요청에 따라 `JsonDb.ValidateDb()`의 캐릭터 레벨 상한을 1000→1200으로 변경했다. 관리도구 입력·저장·materializer는 기존부터 1200을 허용했으므로 해당 경로는 변경하지 않았다. 기존 계정의 설정 레벨을 자동으로 1200으로 올리거나 저장 revision을 변경하지 않는다.
- 현재 152 원본 능력치 표는 1~1400이며 1200 행이 54개 그룹에 존재한다. 상한 1200은 이번 사용자 요구에 따른 값이다. 과거 BE-013 문서의 원본 최대치 1400 제안과 구분한다. `artifacts/union-unlock-synchro-20260918/level-source.receipt.json` 참조.
- 검사: 서버 177개 통과. 개방 API 실제 dispatcher의 미가입/다른 길드/선택 없음/레벨 2·3 경계와 기존 가챠 응답 유지 검사 추가. 레벨 1000·1001·1199·1200 보존, 1201→1200 제한 및 검증 재실행 멱등성 확인.
- 게시 DLL `6e50e5dc1b2eb281b8db2677ec106d0463fcc00550a271c002e6e7baa5db69c1`의 실제 시작 DB 로드와 dispatcher/protobuf 31회 통과. 원본 조건표에 대해 길드 표시 레벨=개방 판정 레벨=3, 하드 Open 확인. 시작 시 1001~1200 보존, 싱크로 API/기준 캐릭터 응답의 1200 확인. 기존 랭크 참조·사격장 표시 키 및 합성 PostgreSQL 재전송/재시작 검사도 통과했다. `artifacts/union-unlock-synchro-20260918/dispatcher.receipt.json`, `postgresql-runtime.receipt.json`.
- 설치와 사용자 실게임 확인은 아래에 별도로 기록한다.

### 개방 API·1200 상한 설치 완료 — 2026-09-18 01:43 KST

전후 필수 gate 8개 통과 후 최종 DLL을 서버/자료 조립 도구에 적용했다. 파일 6개 백업·교체 및 source manifest/bundle/selection/활성 설정 해시 갱신. 설치 DLL과 위 dispatcher 검사 DLL 해시 일치, S26/S41 공통 준비 ready. 운영 DB 데이터·스키마, 기존 계정의 설정 레벨, 게임 파일은 변경하지 않았다. `artifacts/union-unlock-synchro-20260918/installation.receipt.json` 참조. 설치 이후 사용자 실게임 확인은 아래 기록을 따른다.

### 사용자 실게임 확인 — 2026-09-18

사용자가 싱크로 및 유니온 레이드 정상 작동 확인 완료를 보고했다. 이번 싱크로 상한 및 유니온 개방 수정은 사용자 실게임 확인까지 완료했다. 이 확인을 모든 보스·API별 실게임 검증 완료로 확대하지 않는다.

## 2026-09-18 랭크 수정 후 잠금 유지 — 개방 판정 API의 GuildLevel 누락

- 최신 실행 `0aca7202-f13f-4a8e-834f-c2f46dda3a53`의 DLL은 설치된 랭크 수정본 `730640fb9bcc8bf2d7a0e333942d5b348790d31169c806121993f8b18c5c6ed1`과 일치한다. `Player.log`에서 이전 랭크 조회 예외는 사라졌고 GuildInfo 전환, 상점·사격장 진입이 확인된다. 사용자는 `Reach Union Lv. 3` 문구도 여전히 남는다고 확인했다.
- **직접 원인**: 길드 표시용 `/guild/get`의 `NetGuildData.Grade`는 3이지만, 별도의 `/user/getcontentsdata` 처리기 `GetContentsData.cs`가 `ResGetContentsOpenData.GuildLevel`을 설정하지 않아 protobuf 기본값 0을 보낸다. 해당 요청은 로그인 때와 유니온 화면 복귀 때 실제로 호출됐다. 원본 `ContentsOpenTable`의 `UnionRaid` 개방 조건은 `GuildLevel >= 3`이다.
- 원본 표 대조: 유니온 레이드 조건은 레벨 3이며 단계 클리어나 별도 unlock animation 조건이 아니다. `EnableUnlockPlayPopup/Button`은 false다. 기능 플래그는 Open=true, 실행 입력의 레벨 3·노멀 완료·선택 시즌 45도 정상이다. 개방 연출 확인 목록(`/contentsopen/get/unlock`)을 조작하거나 레벨을 임의로 높일 사유가 없다.
- **재현**: 현행 게시 DLL의 실제 dispatcher로 `ReqGetContentsOpenData`를 보내고 protobuf 응답을 읽었다. 합성 NLL 회원의 길드 응답은 레벨 3, 개방 판정 응답은 0, 현재 원본 표 요구값은 3으로 조건 불충족을 확인했다. `artifacts/union-raid-lock-20260918/diagnosis.receipt.json`과 `conditions.private.json` 참조. 원본 클라이언트나 운영 DB를 자동 조작하지 않았다.
- 앞선 랭크 오류는 실제 결함이었고 제거됐지만, 그것만으로 잠금이 해소될 것이라는 설명은 불완전했다. 29회 API 검사에 `/user/getcontentsdata`를 포함하지 않아 서로 다른 API의 레벨 불일치를 놓쳤다. 서버 레이드 Open만 확인하는 검사로 콘텐츠 개방 인수를 대체할 수 없다.
- 수정 방향: 개방 판정 응답도 같은 로컬 유니온 소속/레벨에서 값을 해소한다. 미가입은 0을 유지하며 레벨 2/3 경계와 `/guild/get` 대비 일치, 원본 조건 평가까지 실제 dispatcher 검사에 추가한다. 다른 콘텐츠의 기존 단계/가챠/시뮬레이션 진행 응답을 유지한다. 이번 요청은 조사이며 서버 소스·설치·DB는 변경하지 않았다.

## 2026-09-18 길드 랭크 참조 수정

- `LocalUnion.ResolveRankTier`가 현재 pack의 `Beginner` 행을 정확히 하나 해소한다. NLL에는 정산 완료된 시즌 랭크가 없으므로 미랭크를 공급하며, 실시간 로컬 순위 1위라는 이유로 Challenger를 부여하지 않는다. 향후 정산 랭크를 도입할 때에는 이 공통 해소기의 입력에 명시적으로 연결해야 한다.
- `/guild/get`의 일반/간략 응답에 `UnionRaidTier`와 `UnionRaidTierNumber`를 모두 채운다. `/guild/publicinfo`도 같은 길드 변환을 사용한다. 월드 랭킹 응답의 간략 길드와 tier 행 참조에도 동일한 해소기를 사용한다. 레벨 3·노멀 완료·하드 개방·피해/참여 기록은 변경하지 않는다.
- 결손 또는 복수 Beginner 행은 임의 선택하지 않고 실패한다. 원본 행의 tier number를 그대로 사용한다. 회귀 검사는 protobuf 왕복 후 원본과 같은 복합 키 조회를 수행하며, 누락된 기존 `(0,0)` 키가 유효하지 않다는 점도 검사한다. 서버 검사 171개 통과.
- 최종 게시 DLL `730640fb9bcc8bf2d7a0e333942d5b348790d31169c806121993f8b18c5c6ed1`로 실제 152 랭크 표를 읽어 dispatcher/protobuf 29회 통과. 길드 일반·간략·공개 정보·월드 랭킹 네 응답의 복합 랭크 키가 모두 원본 행에 존재하며, 랭킹의 행 ID와도 일치한다. 레벨 3·노멀 완료·하드 Open과 이전 사격장 15키 유일성도 확인했다. 합성 PostgreSQL의 재전송·롤백·재시작·오래된 선택 거부 통과. 증거: `artifacts/union-tier-fix-20260918/dispatcher.receipt.json`, `postgresql-runtime.receipt.json`.
- 설치 결과는 아래에 별도로 기록한다. 원본 화면의 잠금 해제는 사용자 실행 확인 전까지 미인수다.

### 랭크 수정본 설치 완료 — 2026-09-18 01:18 KST

필수 gate 8개 전후 통과. 검사한 DLL을 서버와 자료 조립 도구에 적용하고 source manifest·bundle·selection·활성 설정을 갱신했다. 파일 6개 백업·교체, 설치 DLL과 dispatcher 검사 DLL 해시 일치. S26/철갑·S41/수냉 공통 준비 ready. 운영 DB 데이터·스키마 및 게임 파일은 변경하지 않았다. `artifacts/union-tier-fix-20260918/installation.receipt.json`에 결과와 백업 위치를 기록했다. 게임은 자동 실행하지 않았으며 유니온 콘텐츠 잠금 해제/하드 진입은 사용자 확인 대기다.

## 2026-09-18 유니온 진입 성공 후 콘텐츠 잠금 — 길드 랭크 참조 결손

- 사용자 인수: 사격장 표시 키 수정본으로 유니온 화면 진입 성공. 상단 레벨 3 표시와 함께 콘텐츠에 `Reach Union Lv. 3` 잠금이 남는다. 실행 `0c662c67-3071-40e9-8270-168bdc074f1c`의 DLL은 설치본 `7d1b3772714c24fede779558a1c549875bbae0ef357ab9b105dfa931ac8328ae`와 동일하다.
- 확인된 상태: 실행 입력은 유니온 레벨 3, 노멀 완료, 마지막 노멀 레벨 10, 시즌 45, 선택 manager 존재다. 레벨 3 설정 누락이나 노멀 미완료가 확인된 상황은 아니다. 유니온/레이드/사격장 조회 응답은 Success다.
- 직접 실패: 최신 `Player.log:1975`에 `IndexKeyNotFoundException: UnionRaidRankingTierTable[x.TierType, x.TierNumber], (Challenger, 0)`. `ViewGuildInfo.<OnSubscribe>b__55_0` → `OnSubscribe` → `OnProcessShowAsync`에서 발생하여 화면 구독/갱신 도중 중단된다. 이전 사격장 `ToDictionary` 예외와는 다르다.
- 구현 결함: `LocalUnion.Get`의 `NetGuildData` 생성에서 `UnionRaidTier`/`UnionRaidTierNumber`를 지정하지 않는다. protobuf 기본값 `(0,0)`은 원본 enum에서 `(Challenger,0)`이며 해당 표에 없다. 원본 Challenger 번호는 1~10, 미랭크 Beginner는 별도 enum과 번호 0 조합이다. 랭킹 목록의 `NetSimpleGuildData`에는 값을 넣으면서 일반 길드 응답에서 누락했다.
- 재현: 설치 DLL과 같은 게시 DLL의 `LocalUnion.Get`을 합성 계정으로 호출하고 일반/간략 두 응답을 protobuf 왕복했다. 두 응답 모두 레벨 3이면서 원본 랭크 표 조회에 실패한다. `Beginner` 행은 정확히 하나이며 해당 키는 유효하다. `artifacts/union-content-lock-20260918/diagnosis.receipt.json` 참조. 운영 DB·설치 파일은 변경하지 않았다.
- 판단의 한계: 잘못된 랭크 값과 화면 갱신 중단은 직접 확인했다. 그 결과 초기 잠금 상태가 유지됐다는 인과는 현재 가장 직접적인 설명이지만, 수정 후 원본 UI 재확인 전에는 다른 개방 조건까지 해소됐다고 주장하지 않는다. 레벨을 임의로 올려 우회할 근거는 없다.
- 수정 방향: 길드 정보·공개 정보·랭킹에서 공통으로 유효한 랭크 쌍을 선택하고, 미기록 상태는 원본 Beginner 행으로 해소한다. 레벨/노멀 완료 조건은 유지한다. 검사에는 응답의 모든 랭크 참조가 원본 표에 존재하는지를 포함한다. 이번 요청은 조사이며 코드 수정/재설치는 수행하지 않았다.

## 2026-09-18 사격장 순위 표시 키 수정

- 요구: 유니온 화면 진입 실패 해결. 직접 관측한 표시 키는 `(ShootingRangeType, ShootingRangeBattleLengthType)`이며 `SpecActiveSpot`을 구분하지 않는다.
- 수정: 로컬 길드 순위에는 일반 사격장(`SpecActiveSpot=false`)의 빈 순위 버킷을 조합별로 하나씩 공급한다. 고정 육성 행은 별도 순위 항목으로 추가하지 않는다. 이는 NLL의 미기록 사격장 순위 공급 정책이며 공식 서버의 순위 선택 동작을 실측했다는 주장이 아니다. 사격장 전투는 이번 범위에 없다.
- 원본 152에는 각 표시 조합마다 일반 행이 정확히 하나 있다. ID 최솟값이나 입력 순서로 임의 선택하지 않고, 일반 행이 없거나 두 개 이상이면 결손/모호성을 오류로 남긴다. 빈 버킷의 자기 계정 정보는 기존 공통 프로필 변환을 유지한다.
- 회귀 검사: 5속성 × 3길이 × 2변형의 합성 자료에서 이전 중복 예외를 재현한 뒤 protobuf 왕복 응답을 클라이언트 표시 키로 `ToDictionary`한다. 15개 조합 충족, 일반 행 선택, 자기 계정 정보, 입력 순서 불변, 일반 행 결손/중복 거부를 확인한다. 서버 검사 168개 통과.
- 최종 게시 DLL `7d1b3772714c24fede779558a1c549875bbae0ef357ab9b105dfa931ac8328ae`로 실제 152 `ShootingRangeTable.mpk`를 읽어 dispatcher/protobuf 28회 통과. 기존 30행의 표시 키 중복 예외 재현, 수정 응답의 15개 키 사전 구성·전체 조합 충족·자기 계정 정보 확인. 별도 합성 PostgreSQL에서 동시 재전송·실패 롤백·DB 재시작·오래된 선택 거부도 통과했다. 증거: `artifacts/union-ranking-fix-20260918/dispatcher.receipt.json`, `postgresql-runtime.receipt.json`. 최초 검사 환경에서 PostgreSQL 기동 권한 및 SQLite 네이티브 파일 누락을 보완한 뒤 재실행했다.
- DB·보스 조립·유니온 전투 상태는 변경하지 않는다. 설치 결과는 아래에 별도로 기록하며 원본 클라이언트 화면 인수는 사용자 실행으로 확인한다.

### 수정본 설치 완료 — 2026-09-18 00:58 KST

필수 gate 8개 전후 통과 후, 검사한 서버 DLL을 실행 서버/자료 조립 도구에 적용하고 source manifest·bundle·selection·활성 설정의 해시를 갱신했다. 교체 파일 6개를 백업했으며 설치된 DLL 해시는 위 dispatcher 검사의 DLL과 일치한다. S26/철갑과 S41/수냉 공통 준비 ready. 운영 DB 데이터·스키마, 게임 파일, 음성 설정은 변경하지 않았다. `artifacts/union-ranking-fix-20260918/installation.receipt.json`에 설치 시각·백업·해시·준비 결과를 기록했다. 원본 유니온 화면 인수는 사용자 실행 대기다.

## 2026-09-18 DB 수정 후 유니온 화면 진입 실패 — 사격장 순위 중복 키

- 최신 사용자 실행 `1b08623c-1089-4b24-bf09-e969117be4ff`: `/guild/unionraid/get`과 `/shootingrange/v2/get` 모두 HTTP 200이고, 클라이언트의 `ResGetGuild`, `ResGetUnionRaidData`, `ResGetShootingRangeRankingV2`도 Success다. 앞선 DB 연결 거부와 별개의 응답 내용 결함이다. 실행 서버 DLL과 설치 DLL SHA-256은 모두 `46c4516ceb7e5823e52a6d5b244bd2b36c8d06569d2642f464efd85e3f144da9`로 일치한다.
- 직접 실패: `ViewGuildInfo.UpdateContextFromServerAsync`의 `Enumerable.ToDictionary`에서 `ArgumentException: An item with the same key has already been added. Key: (Fire, Short)`. 화면 준비가 실패하여 Home→GuildInfo 전환이 취소된다.
- 구현 원인: `LocalGuildQueries.cs`의 `LocalShootingRangeRanking.Build`가 사격장 원본 행을 전부 `RankingList`에 넣는다. 원본 30행은 `SpecActiveSpot=false` 15행과 `true` 15행으로 나뉘며, `(ShootingRangeType, ShootingRangeBattleLengthType)` 조합은 각각 동일한 15개다. 클라이언트의 표시 키에는 사격장 ID나 `SpecActiveSpot`이 포함되지 않으므로 15개 키가 전부 중복된다. 같은 키 생성 방식으로 로컬 사전 삽입을 수행하여 중복 예외를 재현했다.
- 놓친 검사: `ShootingRangeReturnsSourceKeysAndNonNullSelfProfilesIncludingBothVariants`는 두 변형을 모두 보내는 잘못된 전제를 기대값으로 사용했다. 앞선 dispatcher 왕복 검사도 Success와 항목 수를 검사했으나 클라이언트가 생성하는 표시 키의 유일성을 검사하지 않았다. 해당 통과를 UI 호환성의 증거로 사용할 수 없다.
- 수정 방향: 길드 랭킹 대상 사격장 선택 근거를 확인하여 각 속성/전투 길이 조합을 정확히 한 번 공급하고, 원본 ID 유일성과 별도로 클라이언트 표시 키 유일성·필요 조합 충족을 검사한다. 임의 ID 순서의 첫 행으로 의미 차이를 덮지 않는다. 보스 조립이나 유니온 전투 상태를 변경할 사유는 확인되지 않았다.
- 이번 요청에서는 조사와 기록만 수행했다. 수정·재설치 및 원본 유니온 화면 인수는 미완료다. 서버 증거는 해당 실행의 `evidence/d0e78b58-6fdc-4b02-be30-cb5738b844a1/server.stdout.log`, 클라이언트 증거는 `Player.log`의 `GuildInfo` 예외다.

## 2026-09-18 DB 수명주기 수정

- 수정: 공통 coordinator에서 관리 PostgreSQL 중단을 제거하고 지정 cluster의 실행 상태를 확인한다. 보스/시즌/프로필별 예외는 없다. 유니온 API의 transaction, 행 잠금, 재전송 중복 방지와 schema 25는 그대로 유지한다.
- 종료/실패 복구: `Ensure-PhaseDPostgresRunning`은 실행 중인 DB에는 상태 조회만 수행한다. 상태 코드 3(중단)일 때만 시작하고 다시 실행 상태를 확인하며, 알 수 없는 상태나 시작 실패는 성공으로 처리하지 않는다. rollback 필요 여부는 DB 종료 여부 대신 런타임 수명주기 진입 여부로 판단하여 기존 복구 증명을 유지한다.
- 관리도구 종료/재시작: 게임 또는 시작 coordinator가 살아 있으면 DB 종료/재시작을 막고, 종료 watcher의 완료를 기다린다. 화면을 먼저 닫는 것으로 실행 중 transaction 저장소가 중단되지 않게 한다.
- 검사: 합성 PostgreSQL에서 **실제 coordinator의 DB 인계 구간 → 설치된 서버 DLL의 dispatcher/protobuf 28회 → 실제 watcher의 DB 준비 구간 → 동일 구간 재실행**을 수행했다. 정상 경로의 postmaster PID 불변을 확인했다. 별도로 DB 중단 후 watcher의 재기동, 저장된 전투 기록과 결과 재전송의 멱등성 복원을 확인했다. 시작 시 DB 중단/상태 실패, 복구 시작 실패, 복구 후 미기동, 관리도구 조기 종료와 watcher 미완료는 합성 회귀 검사로 확인했다. 실제 게임은 실행하지 않았다.
- 증거: `artifacts/union-db-lifecycle-20260918/runtime-lifecycle.receipt.json`, `dispatcher.receipt.json`. 운영 DB는 검사에 사용하지 않았다. 시작 전 전체 검사 첫 시도는 NuGet 취약점 조회의 네트워크 실패로 중단되어, 이후 오프라인 검사에서 `NuGetAudit=false`를 사용했다. 이전 DB 중단 동작을 요구하던 검사 항목은 새 계약과 실제 수명주기 검사로 갱신했다.
- 설치와 원본 게임 인수는 아래에 별도로 기록한다. 서버 DLL/DB schema 변경 없이 실행 스크립트만 적용한다.

### 재설치 완료 — 2026-09-18 00:36 KST

`artifacts/union-db-lifecycle-20260918/installation.receipt.json`: 설치된 `Start-NLL-ControlCenter.ps1`을 백업 후 교체했고, 공통 coordinator/watcher/DB helper는 저장소의 수정본을 다음 실행의 봉인 묶음에 사용한다. 설치 기록에 네 스크립트의 SHA-256을 남겼다. 서버 DLL과 bundle 해시는 이전과 동일하며 운영 DB 데이터·스키마는 변경하지 않았다. S26/철갑·S41/수냉 준비 상태는 모두 ready다.

필수 gate 8개, 전체 PostgreSQL 회귀 120개 및 위 공통 DB 인계/종료를 포함한 유니온 API 28회 통과. 관리도구 DB 보호 및 실행 실패/종료/복구 순서 검사도 통과했다. 게임을 자동 실행하지 않았으며, 원본 클라이언트의 InitSuccess 통과와 유니온 하드 전 구간 인수는 사용자 재실행 확인이 남아 있다.

## 2026-09-18 설치 후 InitSuccess System Error — 원인 확인, 수정 전

사용자 재실행에서 `/v1/guild/unionraid/get`이 HTTP 500으로 실패했다. 서버 예외는 `LocalUnionRuntimeStore.Execute`의 `NpgsqlConnection.Open()`에서 `127.0.0.1:55433` 연결 거부(SocketException 10061)이며, 클라이언트도 `ReqGetUnionRaidData`의 HTTP 500 재시도를 기록했다. 실행 증거는 `artifacts/automation/phase-d-executions/37568511-6551-4a96-9527-82113299f4d0/evidence/380a1282-5db2-4aaf-bc52-89214995b0a4/server.stdout.log`이다.

원인은 새 유니온 API와 기존 공통 실행기의 DB 수명 불일치다. `scripts/invoke-nll-phase-d-execution.ps1`은 게임 시작 전에 관리 PostgreSQL을 `pg_ctl stop`으로 종료하고, `scripts/watch-nll-phase-d-execution.ps1`은 게임 종료 처리 뒤 다시 시작하여 진행도를 저장한다. 그런데 새 `LocalUnionApi.Execute`는 초기 조회부터 전투 결과까지 관리 PostgreSQL에 직접 접속한다. 준비 단계에서는 DB가 살아 있어 성공하지만 게임 실행 중에는 접속할 수 없다. 운영 PostgreSQL 로그에도 00:05:21 기동, 00:05:25 정상 종료가 확인된다. DB 스키마 결손이나 비밀번호 오류가 아니라 종료된 DB에 접속하도록 연결한 구현 결함이다.

앞선 dispatcher/protobuf 28회 및 DB 회귀 검사는 DB를 켜 둔 조건에서 수행했다. 공통 실행기가 DB를 종료하는 실제 수명주기를 검사에 포함하지 않아 이 결함을 놓쳤다. 해당 검사 통과 기록은 유지하되 원본 게임 인수는 실패 상태로 갱신한다.

후속 수정은 공통 실행·종료·복구 경로와 런타임 저장소의 수명을 일치시켜야 한다. 초기 조회만 우회하면 입장/결과/편성 저장에서 같은 오류가 재발한다. DB를 실행 중 유지하는 방안과 기존 실행 중 저장/종료 후 영속화 경로를 재사용하는 방안의 영향 범위를 확인한 뒤 선택한다. 실제 공통 시작·종료 순서를 포함한 초기 조회, 입장/결과 재전송, 종료 후 저장, 재실행 복원 검사가 필요하다. 이번 조사는 로그와 코드를 읽고 원인을 기록한 것이며 런타임·DB·설치 파일은 변경하지 않았다.

## 전 구간 API 연결 — 2026-09-17 후속 작업

사용자가 조회·하드 전투·결과·기록까지 연결하도록 범위를 확장했다. 아래 초기 도입의 "handler 미구현" 표기는 이전 인수 범위의 기록이다.

- 경로 근거: 152 protobuf의 각 요청 선언에 있는 `Path` 주석. `/guild/unionraid/` 아래 21개 요청을 대조했다. 연습 결과 주소의 `pratice` 철자도 원본 계약 그대로다. URL을 추정하여 별칭을 등록하지 않는다.
- 유니온 정보·공개 정보·멤버/빈 채팅 이력과 화면 준비에 필요한 `/shootingrange/v2/get`을 공급한다. 초기 구현은 일반/고정 육성 두 종류를 모두 전송했으나 표시 키 중복 결함이 확인되어, 현재는 위 수정 항목의 일반 사격장 15조합만 공급한다. 사격장 자체 전투 구현은 이번 유니온 레이드 전투 범위가 아니다.
- 하드 현황·참여 정보·전투 중 여부·입장·피해 제출·보스 팝업·월드/개인/보스/멤버 기록·로컬 유니온 랭킹·하드 연습전을 연결한다. 노멀은 완료 상태 조회를 유지하며 새 노멀 전투와 노멀 연습전은 명시적으로 닫힌 응답을 반환한다.
- HP 근거: 선택 manager → Hard preset → wave target → monster stat group → 해당 monster level의 HP × 원본 HP 비율. 현재 최신 시즌은 5보스/16단계이며, 일반 단계는 `LeftHp`, 원본 `IsTrial` 단계는 `LastBossTotalDamage` oneof를 사용한다. 참여 수와 편성 수는 `ConfigGameTable`에서 읽는다. 시간 정책은 로컬 공통 raid day(서울 05:00)를 사용한다. 이를 공식 서버 동작을 실측한 증거로 표현하지 않는다.
- schema 25 `local_union_raid_runtime`: 로컬 유니온/시즌이 저장 키이며 client build는 키에 없다. HP는 전체 계정 공유, 사용 캐릭터·참여·편성·팝업은 계정별이다. 캐릭터는 논리 UID로 저장해 새 실행의 Csn으로 복원한다. 같은 시즌을 새 자료로 재조립해도 누적 상태를 초기화하지 않는다.
- 유니온 행 잠금과 단일 DB transaction 안에서 입장·결과를 반영한 후 응답한다. 같은 활성 입장과 같은 결과 패킷 재시도는 중복 소비·가산하지 않는다. 결과 기록은 실전/연습을 구분하고 연습은 실전 HP/참여/랭킹을 변경하지 않는다. 선택 시즌이 바뀐 오래된 실행의 쓰기는 거부한다.
- 원본 클라이언트가 계산한 전투 피해를 받아 처리하며 독자 전투 시뮬레이터를 만들지 않는다. 다른 계정이 먼저 처치한 단계의 늦은 결과는 이미 사라진 HP를 다시 가산하지 않는다. 최대 HP 초과 피해도 점수에 중복 반영하지 않는다.
- 확인: 서버 단위/회귀 166개, 원본 HP 변환, 별도 합성 PostgreSQL의 동시 재전송·롤백·DB 재시작·오래된 선택 거부 통과. 기록은 `artifacts/union-api-20260917`. 최종 설치 및 원본 게임 전 구간 인수는 별도 항목으로 기록한다.

실게임에서 확인할 순서: 유니온 화면 → 하드 보스 선택 → 편성 → 전투 입장 → 완료/중도 종료 → 남은 HP/횟수 → 기록/랭킹 → 재실행 복원 → 연습전이 실전 상태를 바꾸지 않는지 확인. 자동 검사 통과를 실제 화면/전투 통과로 승격하지 않는다.

### 후속 설치 완료 — 2026-09-18 00:01 KST

`artifacts/union-api-20260917/installation.receipt.json`: 파일 8개, schema 24→25 적용. 기존 100개 테이블의 행 수·digest 불변, migration 재실행 0건, S26/철갑·S41/수냉 공통 준비 ready. DB 및 교체 파일은 같은 디렉터리의 `installation-backup`에 보존했다. 관리도구를 다시 열었으며 게임은 실행하지 않았다.

최종 서버 DLL `46c4516ceb7e5823e52a6d5b244bd2b36c8d06569d2642f464efd85e3f144da9`로 **실제 dispatcher/protobuf 요청 왕복 28회** 통과: 유니온/사격장 조회, 편성 저장, 입장, 결과 재전송, 연습, 참여/HP, 팝업, 각 기록/랭킹, 노멀 전투 거부. 합성 계정·별도 PostgreSQL과 SQLite 계정 저장소를 사용했으며 운영 계정과 원본 클라이언트는 이 검사에 사용하지 않았다. 서버 회귀 166개, 전체 PostgreSQL 회귀 120개, 필수 계약 gate 8개 통과. 유니온 요청과 편성 저장은 계정별로 직렬 처리하고 공유 HP는 DB의 유니온 잠금으로 보호한다.

현재 bundle SHA-256: `183a95b87fb8bfb3cced21d4d38d7a9d8d01e728e6a8e0c9343eda01ff80fd6e`.
현재 configuration SHA-256: `f0667243dbd517e0698ff9e1fd0eda84acfc810ac47e8352282557428a231fc5`.
원본 게임의 유니온 화면/하드 전투 인수는 사용자 실행 대기다. 사격장 전투·유니온 채팅 전송/운영 기능·보상 경제 및 전체 프로필 영속성을 이번 완료 범위로 주장하지 않는다.

## 사용자 요구 — 2026-09-17

1. 관리도구 유니온 탭에서 시즌을 최신순 스크롤 목록으로 선택한다. `시즌 N 보스를 불러오시겠습니까?` 확인 후 해당 시즌의 보스 5개를 원본 행동 트리까지 공통 경로로 조립한다.
2. 원본 속성·QTE·FX를 유지한다. Solo의 속성 자유화 및 보정 FX 단계를 호출하지 않는다.
3. 로컬 계정은 `NLL` 유니온 소속, 유니온 레벨 3 이상, 노멀 전체 완료 상태로 하드에 접근한다. 공식 계정/서비스는 변경하지 않는다.
4. 다음 우선순위는 프로필·스킨 착용 상태 등을 포함한 전체 DB 영속성이다. 클라이언트 버전은 자료 해석 문맥이며 저장 주체의 식별자가 아니다. 기존 제한된 저장 항목의 버전 독립화 완료를 전체 저장 완료로 표현하지 않는다.

이번 요구는 기존 문서의 Union Raid 비지원 범위를 명시적으로 확장한다. 과거 Phase 계약의 인수 범위와 증거는 소급 변경하지 않는다. 새 보스의 부팅·음성·종료 예외를 만들지 않는다.

## 관측 사실

- 현행 UI 탭은 준비 중 화면이며 Epinel 서버에는 길드 추천 목록 외 가입/유니온 레이드 처리가 없다.
- 로컬 152 복호 자료: manager 45개, preset 2,617개, 참조 wave 159개. 하드 자료가 없는 시즌은 1~23이며 24~45에는 하드가 있다.
- 최신 시즌 하드에는 5개 보스 × 3단계와 마지막 보스의 별도 연습 preset이 있다. 보스 다섯 개라는 이유로 첫 5행만 고르면 틀린다. `DifficultyType`, `IsTrial`, `WaveOrder`, `WaveChangeStep`을 구분한다.
- 소스: `UnionRaidManagerTable` → `MonsterPreset` → `UnionRaidPresetTable.PresetGroupId` → `Wave` → `WaveDataTable` → target monster → `SpotAi` 계열 행동 트리.
- 원본 표와 식별자는 git 제외된 `artifacts/union-raid-20260917/tables.private.json`에만 기록한다.

## 구현 및 검증 순서

- [x] 원본 시즌/하드 5보스 자료 해석 및 공개 카탈로그, 결손 자료 표시.
- [x] 기존 행동 번들 획득/그래프 검사 재사용, 5보스 전체 성공 때만 원자적으로 게시. 동일 요청 재실행은 같은 결과 사용.
- [x] 최신순 스크롤 선택, 예/아니오 확인, 진행/실패 표시. 취소는 변경하지 않는다.
- [x] 버전 독립적인 NLL 유니온 소속·선택 시즌·노멀 완료 저장, 로비 소속 번호와 유니온 정보 응답 구현. 원본 UI 인식 여부는 실게임 확인 전이다.
- [x] 합성 회귀 검사와 로컬 자료 조립 검증, 설치. 사용자 실게임 검증은 별도 기록.
- [ ] 전체 프로필/스킨/설정 저장 항목과 복구 경로를 조사하고 누락된 영속성 구현.

확인되지 않은 원본 요청 경로나 단계 의미를 추정하여 성공 응답을 만들지 않는다. 조립 완료, 설치 완료, 실게임 성공을 구분한다.

## 구현 근거와 검사

### 2026-09-17 사용자 로비 진입 확인 / 유니온 화면 전환 실패 조사

- 사용자 확인: 멤버 응답 보완 설치 후 원본 게임 로비 진입 성공. 실행 복사본/설치본/검사한 서버 DLL 해시 일치도 확인했다. 앞선 InitSuccess 정지와 현재 유니온 화면 진입 실패를 구분한다.
- 유니온 버튼을 누르면 `/guild/get`, `/guild/unionraid/get` 외에 `/shootingrange/v2/get`을 요청한다. 최신 실행 로그에는 마지막 요청의 `No handler`가 11회 기록돼 있다. 현재 서버에는 해당 경로의 구현이 없으며 공통 EmptyHandler가 빈 성공 응답을 돌려준다.
- 게임은 `ResGetShootingRangeRankingV2`를 Success로 받은 뒤 `ShootingRangeRankDisplay.SetData`에서 `(Fire, Short)` 키를 찾지 못해 `KeyNotFoundException`을 낸다. `ViewGuildInfo.OnPrepareAsync`가 실패하여 유니온 창이 열리지 않는다. 보스 행동 트리나 하드 전투 진입 이전의 화면 정보 조회 결손이다.
- wire 계약: 응답 `RankingList`의 각 `NetShootingRangeRankingTotalData`에는 `ShootingRangeId`, `UserGuildRanking`, `GuildRankingList`가 있다. 현재 데이터의 `ShootingRangeRecord`가 종류/전투 길이 조합을 제공한다. 종류 enum은 5속성, 전투 길이는 Short/Long/Target이다. 실제 지원 조합은 현재 테이블에서 해소해야 하며 enum 곱이나 임의 원본 ID로 생성하지 않는다.
- 수정 범위: 조회 경로 구현, 현재 원본 테이블에 존재하는 사격장 항목별 명시적 미참여 응답, 필요한 중첩 메시지 완성, 등록기/직렬화/항목 결손 회귀 검사. 점수·순위·전투 완료를 조작하지 않는다. 사격장 실제 전투 구현은 이 화면 진입 수리와 별도다.
- 이번 요청은 현상 조사이며 위 조회 API 수정/설치는 아직 하지 않았다. 기록: `artifacts/union-navigation-investigation-20260917/diagnosis.json`. 유니온 화면 통과 및 하드 전투 인수는 계속 미완료다.

### 2026-09-17 S45 실행 시 InitSuccess 정지 수정

세 번째 사용자 실행에서도 `NKUserGuild.UpdateFrom` 예외가 유지되었다. 실행 복사본과 설치 서버 DLL 해시가 일치하므로 미적용 문제가 아니다. 엠블럼 0 결손 수정은 유효했지만 정지 원인을 해결한 증거가 되지 못했다.

유니온 멤버 응답을 정상 공통 `CreateWholeUserDataFromDbUser`와 대조하여 서버 번호, 현재 DB의 닉네임, 칭호, 최근 활동 시간이 누락됐음을 확인했다. 새 멤버 응답은 해당 공통 계정 표현을 사용하고 `SendMailAt`(미발송 Unix epoch), `UserTitleDisplayData`(표시 카운트 0)를 명시하여 protobuf 메시지 참조가 null로 남지 않게 한다. 서버 번호 및 계정 일치 검사를 추가했다. 실제 공통 변환과 합성 SQLite 계정 저장소를 거쳐 생성한 응답의 직렬화 왕복도 검사한다. 간단/전체 응답 검사와 기존 회귀 포함 159개 통과. 계정 식별자나 원본 패킷을 남기지 않는 응답 구조 진단 `[LocalUnion]`도 추가했다.

**이 변경은 확인된 누락 필드를 보완하는 수정이며, 클라이언트 내부 null 역참조가 어느 필드에서 발생했는지를 확정한 것은 아니다.** 원본 클라이언트 로비 진입을 통과하기 전 해결 완료로 판정하지 않는다. 검사 개수를 원본 클라이언트 인수 증거로 사용하지 않는다. 작업 기록은 `artifacts/union-member-fix-20260917`이다.

재실행 결과: 첫 경로 수정은 실제 실행 DLL 해시로 적용을 확인했다. `/guild/unionraid/get` 미등록 오류와 `UnionRaidSimpleContext` 예외는 사라졌으나 `NKUserGuild.UpdateFrom(NetGuildData, ...)`에서 추가 null 예외가 관측됐다. 최초 수정만으로 로비 통과가 완료된 것은 아니다.

추가 결함: `NetGuildData.Emblem`을 지정하지 않아 0을 보냈다. 현재 pack의 `GuildEmblemTable` 78행에는 0이 없으며, `GuildTable`에는 레벨 3이 존재한다. 서버가 현재 pack의 엠블럼 테이블을 읽고 유니온 레벨 이하에서 사용 가능한 실제 행을 선택하도록 수정했다. 유효 행이 없으면 임의 값 대신 `local_union_emblem_unresolved`로 처리한다. 원본 테이블 검사 기록은 `artifacts/union-emblem-fix-20260917/source-table-check.json`. 등록 경로·직렬화·해당 레벨의 유효 엠블럼 선택을 포함한 서버 검사 156개 통과. 엠블럼 참조 결손은 확인된 결함이며, 추가 수정으로 클라이언트 예외가 완전히 사라지는지는 사용자 재실행 검증 대상으로 구분한다.

- 관측: 사용자 실행의 서버 로그는 `/guild/unionraid/get`에 `No handler`를 기록했다. 클라이언트는 `ResGetUnionRaidData`를 성공으로 받았지만 `UnionRaidSimpleContext.UpdateFrom`에서 `NullReferenceException`을 발생시켰다. 실제 보스 전투 이전의 로비 초기화 실패다.
- 원인: 신규 처리기를 `/unionraid/get`에 등록하여 실제 요청의 `/guild` 접두사를 누락했다. 미등록 요청은 기존 공통 `EmptyHandler`로 넘어가 빈 성공 응답이 되었다. 앞선 검사는 응답 생성 함수만 확인하여 실제 주소 연결 오류를 놓쳤다.
- 수정: 관측된 `/guild/unionraid/get`으로 처리기를 등록했다. 시즌별 분기나 행동 트리/DB 변경 없이 모든 시즌에 같은 경로를 적용한다.
- 검사: 실제 등록기와 요청 dispatcher를 통해 `/v1/guild/unionraid/get`을 보내고 protobuf 응답의 `Data`가 존재하는지 확인하는 회귀 검사를 추가했다. 외부 서버 155개 통과. 이 검사의 합성 외부 길드 요청은 운영 DB를 사용하지 않는다. 기존 소속·선택 시즌 응답 검사는 별도로 유지한다.
- 설치: `artifacts/union-startup-fix-20260917/installation.receipt.json`, 22:34 KST. 서버 및 materializer 참조 DLL과 연결된 출처/해시 파일 총 6개 교체, 기존 파일 백업. S26/철갑 및 S41/수냉 공통 실행 준비 ready. DB·공식 설치본·음성 설정 변경 없음. 수정 후 원본 게임 로비 통과는 사용자 재실행 확인이 필요하다.

- `UnionRaidCatalog`는 manager의 3자리 시즌 suffix를 공개 시즌으로 분리하고 중복/범위를 검사한다. 공개 API/카탈로그에는 원본 manager·monster·wave ID를 내보내지 않는다.
- `sync-nll-union-raid-catalog.ps1`은 기존 로컬 언어 추출기를 재사용한다. 공식 설치본은 읽기만 하며 임시 해독 로케일은 완료 후 제거한다.
- `assemble-nll-union-raid.py`는 기존 `acquire-nll-boss-behavior.py`와 `inspect-nll-boss-behavior-assets.py`를 호출한다. 5개의 조립 영수증이 모두 유효할 때만 staging 디렉터리를 게시 경로로 바꾼다. 공용 캐시는 재사용하고 성공한 작업의 중복 번들은 제거한다.
- 같은 operation 재요청은 공통 작업 저장소의 job을 이어 읽는다. 조립 실패 시 기존 게시물과 선택 시즌은 유지된다. 모든 파일 게시가 끝나고 영수증이 일치한 다음 DB의 선택 시즌을 갱신한다.
- migration 24: `local_union`, `local_union_member`, `local_union_raid_season`. 기존 계정 가입과 신규 계정 생성 시 가입 트리거를 추가한다. 저장 key에 실행 버전·빌드·snapshot이 없다. 새 자료의 참조 출처는 별도 hash로 보존한다.
- 원본 클라이언트의 `ResEnterLobbyServer.Gsn`, `ResGetUserData.Gsn`에 로컬 소속을 반영한다. `ReqGetGuild`/`ReqGetUnionRaidData`에 맞는 정보 응답을 추가했다. 실제 요청 경로와 하드 화면의 해석은 운영자 실게임 확인 전이며, 준비 성공을 원본 UI 성공으로 표현하지 않는다.
- 최신 S45 및 하드 초기 S24: 각각 5보스 행동 트리의 실제 로컬 번들 연결 성공. 속성/FX 변경 없음. 기록: `artifacts/union-raid-20260917/season-45-localized/assembly.json`, `season-24-run/assembly.json`.
- 합성 카탈로그 8개 검사, 관리 API 집중 2개, UI 단위 2개, 실제 브라우저 확인/취소/요청 흐름 통과. 외부 서버 회귀 154개, 전체 PostgreSQL 120개, 필수 계약 gate 8개 통과.
- DB 검사에서는 기존 계정 소속, 미래 자료의 새 출처 hash로 같은 시즌 이어쓰기, 신규 가입 트리거, 재접속 및 migration 재실행 0건을 확인했다.

## 설치 기록 — 2026-09-17 22:14 KST

`artifacts/union-raid-20260917/installation.receipt.json`: 파일 13개, schema 23→24 적용. 기존 97개 테이블의 count/digest 불변, migration 재실행 0건, 기존 계정 3개 NLL 소속, 선택 시즌 0개(사용자 확인 전)를 확인했다. 설치본 S26/철갑 및 S41/수냉 공통 실행 준비가 ready다. 공식 설치본·음성·레지스트리 변경과 게임 실행은 수행하지 않았다.

첫 설치는 materializer를 self-contained build로 만들었던 패키징 오류가 설치 후 검사에서 발견되어 파일 15개 및 schema를 자동 복구했다. 기존 설치와 같은 framework-dependent publish로 다시 생성하고 새 백업 `installation-backup-2` 후 설치했다. 첫 실패/복구 기록은 `attempt-1`, 기존 DB 전체 백업은 각 `installation-backup*`에 보존한다.

선택 bundle SHA-256: `8df9917c2619ca9c07f8df7ea199faa3f3e251d6d6833512ec61cd389452f4a2`.
활성 pipeline configuration SHA-256: `4c5487c9382db49f5e63db1745107aff4cd3711ddf4fa328d56ae012b41ee5c8`.

## 남은 범위 구분

이번 보스 불러오기는 행동 트리까지의 조립과 유니온 접근 조건 준비다. 하드 전투 시작·피해 제출·결과 저장 handler와 실제 전투 실행까지 완료했다고 주장하지 않는다. 원본 클라이언트에서 하드 화면과 실전 흐름을 연결하는 다음 작업에서 실제 요청/응답을 확인해야 한다.

전체 DB 영속성(사용자 우선순위 2)은 후순위다. 기존 schema 23은 이미 raid head와 제한된 account preference head를 빌드와 분리했지만 모든 저장 항목의 완성을 뜻하지 않는다. 프로필 아이콘/프레임/칭호·스킨·꾸미기·편성·설정 등 저장 항목 전체의 capture/restore 경로와 누락 필드를 대조하고, 업데이트와 이전 버전 재실행에서도 계정의 마지막 상태를 유지하도록 별도 작업한다.

추가 수정 설치: 2026-09-17 22:49 KST, artifacts/union-emblem-fix-20260917/installation.receipt.json. 파일 6개 교체, S26/S41 준비 ready, DB 변경 없음. 앞선 수정의 저장소/Phase 0/2B(2A1·2A2 포함)/Phase 3 계약/Actions 검사는 통과했고, 추가 엠블럼 변경은 서버 156개로 검증했다.
